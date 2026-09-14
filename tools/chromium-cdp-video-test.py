#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
"""Exercise a local HTML5 video through a running Chromium DevTools endpoint.

The probe deliberately measures HTMLVideoElement presentation telemetry rather
than treating a successful navigation as proof of playback.  It is intended for
the ZPU SmolVM validation path, where the accompanying Chromium launch must
still enforce the ZPU-only ICD and forbid software-compositing fallback.
"""

import argparse
import base64
import json
import os
import socket
import struct
import urllib.parse
import urllib.request


def receive_exact(connection: socket.socket, size: int) -> bytes:
    result = bytearray()
    while len(result) < size:
        chunk = connection.recv(size - len(result))
        if not chunk:
            raise RuntimeError("DevTools WebSocket closed unexpectedly")
        result.extend(chunk)
    return bytes(result)


def receive_frame(connection: socket.socket) -> tuple[int, bytes]:
    header = receive_exact(connection, 2)
    opcode = header[0] & 0x0F
    size = header[1] & 0x7F
    if size == 126:
        size = struct.unpack("!H", receive_exact(connection, 2))[0]
    elif size == 127:
        size = struct.unpack("!Q", receive_exact(connection, 8))[0]
    return opcode, receive_exact(connection, size)


def send_text(connection: socket.socket, value: str) -> None:
    payload = value.encode()
    mask = os.urandom(4)
    size = len(payload)
    if size < 126:
        header = bytes((0x81, 0x80 | size))
    elif size <= 0xFFFF:
        header = bytes((0x81, 0xFE)) + struct.pack("!H", size)
    else:
        header = bytes((0x81, 0xFF)) + struct.pack("!Q", size)
    masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
    connection.sendall(header + mask + masked)


class DevTools:
    def __init__(self, port: int):
        with urllib.request.urlopen(
            f"http://127.0.0.1:{port}/json/version", timeout=5
        ) as response:
            version = json.load(response)
        websocket_url = urllib.parse.urlsplit(version["webSocketDebuggerUrl"])
        self.connection = socket.create_connection(
            (websocket_url.hostname, websocket_url.port), timeout=5
        )
        # Playback probes intentionally await several seconds of compositor
        # activity, so retain a bounded timeout that exceeds their default
        # sample window after the connection handshake completes.
        self.connection.settimeout(60)
        self.next_id = 1
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            f"GET {websocket_url.path} HTTP/1.1\r\n"
            f"Host: {websocket_url.hostname}:{websocket_url.port}\r\n"
            "Upgrade: websocket\r\n"
            "Connection: Upgrade\r\n"
            f"Sec-WebSocket-Key: {key}\r\n"
            "Sec-WebSocket-Version: 13\r\n"
            "Origin: http://localhost\r\n\r\n"
        )
        self.connection.sendall(request.encode())
        response = bytearray()
        while b"\r\n\r\n" not in response:
            response.extend(self.connection.recv(4096))
        if not response.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(response.decode(errors="replace"))

    def close(self) -> None:
        self.connection.close()

    def call(
        self,
        method: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float | None = None,
    ) -> dict:
        request_id = self.next_id
        self.next_id += 1
        request = {"id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        if session_id is not None:
            request["sessionId"] = session_id
        previous_timeout = self.connection.gettimeout()
        if timeout is not None:
            self.connection.settimeout(timeout)
        try:
            send_text(self.connection, json.dumps(request))
            while True:
                opcode, payload = receive_frame(self.connection)
                if opcode == 8:
                    raise RuntimeError("DevTools WebSocket closed")
                if opcode != 1:
                    continue
                response = json.loads(payload)
                if response.get("id") != request_id:
                    continue
                if "error" in response:
                    raise RuntimeError(f"{method}: {response['error']}")
                return response["result"]
        finally:
            self.connection.settimeout(previous_timeout)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument(
        "--page-url", default="http://127.0.0.1:8000/chromium_vp9_playback.html"
    )
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--screenshot")
    parser.add_argument(
        "--keep-existing-pages",
        action="store_true",
        help="leave pre-existing Chromium page targets open during the probe",
    )
    parser.add_argument(
        "--compositor",
        action="store_true",
        help="measure requestAnimationFrame delivery on a changing compositor page",
    )
    parser.add_argument(
        "--compositor-selector",
        default=".scene",
        help="selector that proves the compositor fixture has loaded",
    )
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("--duration must be positive")

    devtools = DevTools(args.port)
    try:
        target = devtools.call("Target.createTarget", {"url": "about:blank"})
        # Chromium starts a New Tab page even in headless mode. Keeping it
        # alive turns a focused video measurement into a concurrent browser-UI
        # compositor workload, so retire only other ordinary page targets once
        # the probe target exists. Browser, service-worker, and DevTools
        # targets are intentionally untouched.
        if not args.keep_existing_pages:
            targets = devtools.call("Target.getTargets").get("targetInfos", [])
            for candidate in targets:
                if (
                    candidate.get("type") == "page"
                    and candidate.get("targetId") != target["targetId"]
                ):
                    devtools.call("Target.closeTarget", {"targetId": candidate["targetId"]})
        attached = devtools.call(
            "Target.attachToTarget", {"targetId": target["targetId"], "flatten": True}
        )
        session_id = attached["sessionId"]
        devtools.call("Page.enable", session_id=session_id)
        devtools.call(
            "Page.navigate", {"url": args.page_url}, session_id=session_id
        )
        if args.compositor:
            expression = f"""(async () => {{
              const ready = await new Promise(resolve => {{
                const deadline = performance.now() + 10000;
                function probe() {{
                  if (document.querySelector({json.dumps(args.compositor_selector)}) || performance.now() >= deadline) {{
                    resolve(Boolean(document.querySelector({json.dumps(args.compositor_selector)}))); return;
                  }}
                  setTimeout(probe, 25);
                }}
                probe();
              }});
              if (!ready) return {{ loadState: 'missing-scene', callbacks: 0, callbackElapsedSeconds: 0, framesPerSecond: 0 }};
              let callbacks = 0, first = null, last = null;
              const deadline = performance.now() + {args.duration * 1000:.3f};
              await new Promise(resolve => {{
                function frame(now) {{
                  callbacks++; first ??= now; last = now;
                  if (now < deadline) requestAnimationFrame(frame); else resolve();
                }}
                requestAnimationFrame(frame);
              }});
              return {{
                loadState: 'ready', callbacks,
                callbackElapsedSeconds: first === null || last === null ? 0 : (last - first) / 1000,
                framesPerSecond: first === null || last === null ? 0 : (callbacks - 1) / ((last - first) / 1000),
                sceneLabel: document.getElementById('frame-label')?.textContent || null,
              }};
            }})()"""
            result = devtools.call(
                "Runtime.evaluate",
                {"expression": expression, "awaitPromise": True, "returnByValue": True},
                session_id,
                timeout=args.duration + 15,
            )
            if "exceptionDetails" in result:
                raise RuntimeError(json.dumps(result["exceptionDetails"], indent=2))
            telemetry = result["result"].get("value")
            if not isinstance(telemetry, dict):
                raise RuntimeError(f"unexpected compositor telemetry: {result}")
            if args.screenshot:
                capture = devtools.call("Page.captureScreenshot", {"format": "png"}, session_id)
                with open(args.screenshot, "wb") as output:
                    output.write(base64.b64decode(capture["data"]))
            print(json.dumps(telemetry, indent=2, sort_keys=True))
            return
        # `awaitPromise` makes the sample duration independent of DevTools
        # message timing. requestVideoFrameCallback measures presented frames,
        # while getVideoPlaybackQuality exposes decoded/dropped frame counts.
        expression = f"""(async () => {{
          const video = await new Promise(resolve => {{
            const deadline = performance.now() + 10000;
            function findVideo() {{
              const candidate = document.getElementById('v');
              if (candidate || performance.now() >= deadline) {{
                resolve(candidate);
                return;
              }}
              setTimeout(findVideo, 25);
            }}
            findVideo();
          }});
          if (!video) return {{
            loadState: 'missing-video', currentTime: 0, readyState: 0,
            paused: true, ended: false, error: null, videoWidth: 0,
            videoHeight: 0, callbacks: 0, callbackElapsedSeconds: 0,
            presentedFramesPerSecond: 0, totalVideoFrames: 0,
            droppedVideoFrames: 0, corruptedVideoFrames: 0,
          }};
          const loadState = await new Promise(resolve => {{
            let finished = false;
            const finish = state => {{
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              resolve(state);
            }};
            const timeout = setTimeout(() => finish('timeout'), 10000);
            if (video.readyState >= HTMLMediaElement.HAVE_CURRENT_DATA) finish('ready');
            video.onloadeddata = () => finish('ready');
            video.onerror = () => finish('error');
          }});
          if (loadState !== 'ready') return {{
            loadState, currentTime: video.currentTime, readyState: video.readyState,
            paused: video.paused, ended: video.ended, error: video.error && video.error.code,
            videoWidth: video.videoWidth, videoHeight: video.videoHeight,
            callbacks: 0, callbackElapsedSeconds: 0, presentedFramesPerSecond: 0,
            totalVideoFrames: 0, droppedVideoFrames: 0, corruptedVideoFrames: 0,
          }};
          await video.play();
          let callbacks = 0, first = null, last = null;
          const deadline = performance.now() + {args.duration * 1000:.3f};
          await new Promise(resolve => {{
            let finished = false;
            const finish = () => {{
              if (finished) return;
              finished = true;
              clearTimeout(timeout);
              resolve();
            }};
            // A compositor that cannot present the video must produce a
            // bounded negative result, not leave the host test waiting for a
            // requestVideoFrameCallback that will never arrive.
            const timeout = setTimeout(finish, {args.duration * 1000 + 1000:.3f});
            function frame(now) {{
              callbacks++; first ??= now; last = now;
              if (now < deadline) video.requestVideoFrameCallback(frame); else finish();
            }}
            video.requestVideoFrameCallback(frame);
          }});
          const quality = video.getVideoPlaybackQuality();
          const elapsed = first === null || last === null ? 0 : (last - first) / 1000;
          return {{
            loadState, currentTime: video.currentTime, readyState: video.readyState,
            paused: video.paused, ended: video.ended, error: video.error && video.error.code,
            videoWidth: video.videoWidth, videoHeight: video.videoHeight,
            callbacks, callbackElapsedSeconds: elapsed,
            presentedFramesPerSecond: elapsed > 0 ? (callbacks - 1) / elapsed : 0,
            totalVideoFrames: quality.totalVideoFrames,
            droppedVideoFrames: quality.droppedVideoFrames,
            corruptedVideoFrames: quality.corruptedVideoFrames,
          }};
        }})()"""
        try:
            result = devtools.call(
                "Runtime.evaluate",
                {"expression": expression, "awaitPromise": True, "returnByValue": True},
                session_id,
                timeout=args.duration + 15,
            )
        except TimeoutError:
            print(json.dumps({
                "devtoolsTimedOut": True,
                "reason": "renderer did not complete the bounded media evaluation",
            }, indent=2, sort_keys=True))
            return
        if "exceptionDetails" in result:
            raise RuntimeError(json.dumps(result["exceptionDetails"], indent=2))
        telemetry = result["result"].get("value")
        if not isinstance(telemetry, dict):
            raise RuntimeError(f"unexpected media telemetry: {result}")
        if args.screenshot:
            capture = devtools.call("Page.captureScreenshot", {"format": "png"}, session_id)
            with open(args.screenshot, "wb") as output:
                output.write(base64.b64decode(capture["data"]))
        print(json.dumps(telemetry, indent=2, sort_keys=True))
    finally:
        devtools.close()


if __name__ == "__main__":
    main()

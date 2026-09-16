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
import math
import os
import socket
import struct
import threading
import time
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

    def send(self, method: str, params: dict | None = None, session_id: str | None = None) -> int:
        """Send a command without waiting for its response.

        High-rate input needs this non-blocking form: a complete WebSocket/CDP
        round trip per mouse position adds unrelated transport latency to a
        60 Hz interaction probe.
        """
        request_id = self.next_id
        self.next_id += 1
        request = {"id": request_id, "method": method}
        if params is not None:
            request["params"] = params
        if session_id is not None:
            request["sessionId"] = session_id
        send_text(self.connection, json.dumps(request))
        return request_id

    def call(
        self,
        method: str,
        params: dict | None = None,
        session_id: str | None = None,
        timeout: float | None = None,
    ) -> dict:
        request_id = self.next_id
        previous_timeout = self.connection.gettimeout()
        if timeout is not None:
            self.connection.settimeout(timeout)
        try:
            self.send(method, params, session_id)
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


class PointerSweep:
    """Drive Chromium's native CDP mouse-input path on a separate connection.

    The SmolVM guest's ``/dev/uinput`` devices cannot be consumed by the host
    X server mounted into the guest, and the Chromium performance profile is
    deliberately ozone/headless.  CDP Input.dispatchMouseEvent is therefore
    the browser-visible input route for this probe.  It exercises the same
    browser input dispatch and hover work as mouse movement without pretending
    that a guest-only virtual input device reaches the headless target.
    """

    def __init__(
        self,
        port: int,
        target_id: str,
        width: int,
        height: int,
        hz: float,
        start_after: float,
        duration: float,
    ) -> None:
        self.devtools = DevTools(port)
        attached = self.devtools.call(
            "Target.attachToTarget", {"targetId": target_id, "flatten": True}
        )
        self.session_id = attached["sessionId"]
        self.width = max(1, width)
        self.height = max(1, height)
        self.hz = hz
        self.start_after = start_after
        self.duration = duration
        self.dispatched = 0
        self.skipped = 0
        self.error: Exception | None = None
        self._stop = threading.Event()
        self._thread = threading.Thread(target=self._run, name="zpu-pointer-sweep")

    @staticmethod
    def _position(progress: float, width: int, height: int) -> tuple[int, int]:
        """A figure-eight covers the 4K viewport's edges and centre."""
        theta = progress * 4.0 * math.pi
        x = round((0.5 + 0.5 * math.sin(theta)) * (width - 1))
        y = round((0.5 + 0.5 * math.sin(2.0 * theta)) * (height - 1))
        return x, y

    def start(self) -> None:
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def close(self) -> None:
        self.stop_and_join()
        self.devtools.close()

    def stop_and_join(self) -> None:
        """Stop command production but retain the connection for queued input."""
        self.stop()
        self._thread.join(timeout=5)

    def _run(self) -> None:
        try:
            started = time.monotonic() + self.start_after
            if self._stop.wait(max(0.0, started - time.monotonic())):
                return
            count = max(1, math.ceil(self.duration * self.hz))
            index = 0
            while index < count:
                deadline = started + index / self.hz
                if self._stop.wait(max(0.0, deadline - time.monotonic())):
                    return
                # Do not replay a backlog of stale pointer positions.  Record
                # each missed dispatch explicitly, since it means the input
                # producer itself could not sustain the requested cadence.
                now = time.monotonic()
                overdue = math.floor((now - deadline) * self.hz)
                if overdue > 0:
                    skipped = min(overdue, count - index - 1)
                    self.skipped += skipped
                    index += skipped
                    deadline = started + index / self.hz
                x, y = self._position(index / max(1, count - 1), self.width, self.height)
                self.devtools.send(
                    "Input.dispatchMouseEvent",
                    {"type": "mouseMoved", "x": x, "y": y, "pointerType": "mouse"},
                    self.session_id,
                )
                self.dispatched += 1
                index += 1
        except Exception as error:  # surfaced by the measuring thread
            self.error = error


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument(
        "--page-url", default="http://127.0.0.1:8000/chromium_vp9_playback.html"
    )
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument(
        "--warmup",
        type=float,
        default=0.0,
        help="seconds of active playback to exclude before collecting telemetry",
    )
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
        help="selector that proves the page has loaded (default: .scene)",
    )
    parser.add_argument(
        "--max-p99-frame-ms",
        type=float,
        help="fail a compositor probe when its p99 requestAnimationFrame interval exceeds this budget",
    )
    parser.add_argument(
        "--min-fps",
        type=float,
        help="fail a compositor probe when its measured average frame rate is below this value",
    )
    parser.add_argument(
        "--pointer-sweep",
        action="store_true",
        help="dispatch a viewport-wide 60 Hz mouse sweep through Chromium's CDP input path",
    )
    parser.add_argument(
        "--pointer-sweep-hz",
        type=float,
        default=60.0,
        help="mouse dispatch rate used with --pointer-sweep (default: 60)",
    )
    args = parser.parse_args()
    if args.duration <= 0:
        parser.error("--duration must be positive")
    if args.warmup < 0:
        parser.error("--warmup must not be negative")
    if args.max_p99_frame_ms is not None and args.max_p99_frame_ms <= 0:
        parser.error("--max-p99-frame-ms must be positive")
    if args.min_fps is not None and args.min_fps <= 0:
        parser.error("--min-fps must be positive")
    if args.pointer_sweep_hz <= 0:
        parser.error("--pointer-sweep-hz must be positive")
    if args.pointer_sweep and not args.compositor:
        parser.error("--pointer-sweep requires --compositor")

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
            "Page.addScriptToEvaluateOnNewDocument",
            {"source": "Object.defineProperty(window, '__zpuNativeRaf', { value: window.requestAnimationFrame.bind(window), writable: false, configurable: false });"},
            session_id=session_id,
        )
        # Headless Chromium otherwise treats a CDP-created tab as background
        # work and may intentionally reduce requestAnimationFrame to 1 Hz.
        devtools.call("Page.bringToFront", session_id=session_id)
        devtools.call(
            "Page.navigate", {"url": args.page_url}, session_id=session_id
        )
        # Navigation may replace or background the renderer target. Assert
        # focus again after issuing it so the compositor probe measures the
        # visible page, rather than a throttled background tab.
        devtools.call("Page.bringToFront", session_id=session_id)
        if args.compositor:
            pointer_sweep = None
            if args.pointer_sweep:
                devtools.call(
                    "Runtime.evaluate",
                    {
                        "expression": "window.__zpuPointerMoveEvents = 0; addEventListener('pointermove', () => window.__zpuPointerMoveEvents++, true);"
                    },
                    session_id,
                )
                viewport_result = devtools.call(
                    "Runtime.evaluate",
                    {
                        "expression": "({width: window.innerWidth, height: window.innerHeight})",
                        "returnByValue": True,
                    },
                    session_id,
                )
                viewport = viewport_result["result"].get("value", {})
                width = viewport.get("width")
                height = viewport.get("height")
                if not isinstance(width, int) or not isinstance(height, int):
                    raise RuntimeError(f"unexpected viewport dimensions: {viewport!r}")
                pointer_sweep = PointerSweep(
                    args.port,
                    target["targetId"],
                    width,
                    height,
                    args.pointer_sweep_hz,
                    args.warmup,
                    args.duration,
                )
                pointer_sweep.start()
            expression = f"""(async () => {{
              const ready = await new Promise(resolve => {{
                const deadline = performance.now() + 10000;
                function probe() {{
                  const matches = document.readyState === 'complete' && document.querySelector({json.dumps(args.compositor_selector)});
                  if (matches || performance.now() >= deadline) {{
                    resolve(Boolean(matches)); return;
                  }}
                  setTimeout(probe, 25);
                }}
                probe();
              }});
              if (!ready) return {{ loadState: 'missing-scene', callbacks: 0, callbackElapsedSeconds: 0, framesPerSecond: 0 }};
              // Exclude page hydration and GPU-process setup from the steady
              // compositor sample.  This is still active rendering time: rAF
              // must be delivered continuously through the whole warm-up.
              if ({args.warmup * 1000:.3f} > 0) await new Promise(resolve => {{
                const raf = window.__zpuNativeRaf || requestAnimationFrame;
                const warmupDeadline = performance.now() + {args.warmup * 1000:.3f};
                function warmupFrame(now) {{
                  if (now < warmupDeadline) raf(warmupFrame);
                  else resolve();
                }}
                raf(warmupFrame);
              }});
              let callbacks = 0, first = null, last = null, previous = null;
              const intervals = [];
              const longTasks = [];
              let observer = null;
              if (typeof PerformanceObserver !== 'undefined') try {{
                observer = new PerformanceObserver(list => {{
                  for (const entry of list.getEntries()) longTasks.push(entry.duration);
                }});
                observer.observe({{ type: 'longtask', buffered: true }});
              }} catch (_) {{}}
              const deadline = performance.now() + {args.duration * 1000:.3f};
              const raf = window.__zpuNativeRaf || requestAnimationFrame;
              await new Promise(resolve => {{
                function frame(now) {{
                  callbacks++; first ??= now;
                  if (previous !== null) intervals.push(now - previous);
                  previous = now; last = now;
                  if (now < deadline) raf(frame); else resolve();
                }}
                raf(frame);
              }});
              intervals.sort((a, b) => a - b);
              observer?.disconnect();
              const p99FrameIntervalMilliseconds = intervals.length ? intervals[Math.min(intervals.length - 1, Math.floor(intervals.length * .99))] : 0;
              return {{
                loadState: 'ready', callbacks,
                visibilityState: document.visibilityState,
                hasFocus: document.hasFocus(),
                callbackElapsedSeconds: first === null || last === null ? 0 : (last - first) / 1000,
                framesPerSecond: first === null || last === null ? 0 : (callbacks - 1) / ((last - first) / 1000),
                p99FrameIntervalMilliseconds,
                warmupSeconds: {args.warmup:.3f},
                longTaskCount: longTasks.length,
                maxLongTaskMilliseconds: longTasks.length ? Math.max(...longTasks) : 0,
                documentTitle: document.title,
                documentTextPrefix: (document.body?.innerText || '').split('\\n').join(' ').slice(0, 300),
                sceneLabel: document.getElementById('frame-label')?.textContent || null,
              }};
            }})()"""
            try:
                result = devtools.call(
                    "Runtime.evaluate",
                    {"expression": expression, "awaitPromise": True, "returnByValue": True},
                    session_id,
                    # The compositor evaluator includes up to ten seconds waiting
                    # for page readiness, followed by explicit warm-up and the
                    # measured interval.  Keep the DevTools bound larger than all
                    # three phases so a slow real-site load is reported as
                    # telemetry, not mistaken for a transport failure.
                    timeout=args.duration + args.warmup + 25,
                )
            finally:
                if pointer_sweep is not None:
                    pointer_sweep.stop_and_join()
            if "exceptionDetails" in result:
                raise RuntimeError(json.dumps(result["exceptionDetails"], indent=2))
            telemetry = result["result"].get("value")
            if not isinstance(telemetry, dict):
                raise RuntimeError(f"unexpected compositor telemetry: {result}")
            if pointer_sweep is not None:
                try:
                    if pointer_sweep.error is not None:
                        raise RuntimeError(f"pointer sweep failed: {pointer_sweep.error}")
                    delivered = devtools.call(
                        "Runtime.evaluate",
                        {
                            "expression": "window.__zpuPointerMoveEvents || 0",
                            "returnByValue": True,
                        },
                        session_id,
                    )
                    telemetry["pointerSweep"] = {
                        "source": "Chromium CDP Input.dispatchMouseEvent",
                        "viewport": {"width": pointer_sweep.width, "height": pointer_sweep.height},
                        "requestedHertz": pointer_sweep.hz,
                        "dispatchedEvents": pointer_sweep.dispatched,
                        "skippedEvents": pointer_sweep.skipped,
                        "pagePointerMoveEvents": delivered["result"].get("value", 0),
                    }
                    expected_events = math.ceil(args.duration * args.pointer_sweep_hz)
                    if pointer_sweep.skipped or pointer_sweep.dispatched != expected_events:
                        raise RuntimeError(
                            "pointer sweep could not sustain its requested cadence: "
                            f"dispatched={pointer_sweep.dispatched}, skipped={pointer_sweep.skipped}, "
                            f"expected={expected_events}"
                        )
                    # Chromium is permitted to coalesce high-frequency pointer
                    # events before page JavaScript observes them.  The dispatch
                    # count, rather than this listener count, proves the input
                    # producer maintained 60 Hz; rAF p99/FPS remains the frame
                    # delivery gate.  Keep the listener count as corroborating
                    # browser-visible evidence without treating coalescing as a
                    # dropped renderer frame.
                finally:
                    pointer_sweep.close()
            if args.screenshot:
                capture = devtools.call("Page.captureScreenshot", {"format": "png"}, session_id)
                with open(args.screenshot, "wb") as output:
                    output.write(base64.b64decode(capture["data"]))
            print(json.dumps(telemetry, indent=2, sort_keys=True))
            if args.max_p99_frame_ms is not None:
                p99 = telemetry.get("p99FrameIntervalMilliseconds", 0)
                if not isinstance(p99, (int, float)) or p99 <= 0 or p99 > args.max_p99_frame_ms:
                    raise SystemExit(
                        f"compositor p99 frame interval {p99!r} ms exceeds "
                        f"{args.max_p99_frame_ms:.3f} ms"
                    )
            if args.min_fps is not None:
                fps = telemetry.get("framesPerSecond", 0)
                if not isinstance(fps, (int, float)) or fps < args.min_fps:
                    raise SystemExit(
                        f"compositor frame rate {fps!r} fps is below "
                        f"{args.min_fps:.3f} fps"
                    )
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
          // GPU-process initialization, media decoder setup, and the first
          // compositor upload are real activity, but do not describe steady
          // playback throughput. Keep warm-up explicit and bounded so callers
          // can report both cold-start and sustained presentation rates.
          if ({args.warmup * 1000:.3f} > 0) await new Promise(resolve => setTimeout(resolve, {args.warmup * 1000:.3f}));
          const initialQuality = video.getVideoPlaybackQuality();
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
            warmupSeconds: {args.warmup:.3f},
            presentedFramesPerSecond: elapsed > 0 ? (callbacks - 1) / elapsed : 0,
            totalVideoFrames: quality.totalVideoFrames - initialQuality.totalVideoFrames,
            droppedVideoFrames: quality.droppedVideoFrames - initialQuality.droppedVideoFrames,
            corruptedVideoFrames: quality.corruptedVideoFrames - initialQuality.corruptedVideoFrames,
          }};
        }})()"""
        try:
            result = devtools.call(
                "Runtime.evaluate",
                {"expression": expression, "awaitPromise": True, "returnByValue": True},
                session_id,
                timeout=args.duration + args.warmup + 15,
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

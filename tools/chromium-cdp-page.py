#!/usr/bin/env python3
"""Navigate a Chromium DevTools page and save a deterministic screenshot."""

import argparse
import base64
import json
import os
import socket
import struct
import time
import urllib.parse
import urllib.request


def exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("DevTools WebSocket closed")
        data.extend(chunk)
    return bytes(data)


def frame(sock: socket.socket) -> tuple[int, bytes]:
    header = exact(sock, 2)
    opcode = header[0] & 0x0F
    length = header[1] & 0x7F
    if length == 126:
        length = struct.unpack("!H", exact(sock, 2))[0]
    elif length == 127:
        length = struct.unpack("!Q", exact(sock, 8))[0]
    return opcode, exact(sock, length)


def send(sock: socket.socket, value: dict) -> None:
    payload = json.dumps(value, separators=(",", ":")).encode()
    mask = os.urandom(4)
    masked = bytes(byte ^ mask[index % 4] for index, byte in enumerate(payload))
    length = len(payload)
    if length < 126:
        header = bytes((0x81, 0x80 | length))
    elif length <= 0xFFFF:
        header = bytes((0x81, 0xFE)) + struct.pack("!H", length)
    else:
        header = bytes((0x81, 0xFF)) + struct.pack("!Q", length)
    sock.sendall(header + mask + masked)


def connect(url: str) -> socket.socket:
    parsed = urllib.parse.urlsplit(url)
    sock = socket.create_connection((parsed.hostname, parsed.port), timeout=120)
    key = base64.b64encode(os.urandom(16)).decode()
    request = (
        f"GET {parsed.path} HTTP/1.1\r\n"
        f"Host: {parsed.hostname}:{parsed.port}\r\n"
        "Upgrade: websocket\r\n"
        "Connection: Upgrade\r\n"
        f"Sec-WebSocket-Key: {key}\r\n"
        "Sec-WebSocket-Version: 13\r\n"
        "Origin: http://localhost\r\n\r\n"
    )
    sock.sendall(request.encode())
    response = bytearray()
    while b"\r\n\r\n" not in response:
        response.extend(sock.recv(4096))
    if not response.startswith(b"HTTP/1.1 101"):
        raise RuntimeError(response.decode(errors="replace"))
    return sock


class Cdp:
    def __init__(self, sock: socket.socket):
        self.sock = sock
        self.next_id = 1

    def call(self, method: str, params: dict | None = None) -> dict:
        ident = self.next_id
        self.next_id += 1
        send(self.sock, {"id": ident, "method": method, "params": params or {}})
        while True:
            opcode, payload = frame(self.sock)
            if opcode != 1:
                continue
            message = json.loads(payload)
            if message.get("id") == ident:
                if "error" in message:
                    raise RuntimeError(json.dumps(message["error"]))
                return message.get("result", {})


def page_target(port: int) -> dict:
    with urllib.request.urlopen(f"http://127.0.0.1:{port}/json/list", timeout=10) as response:
        targets = json.load(response)
    pages = [target for target in targets if target.get("type") == "page"]
    if not pages:
        raise RuntimeError("Chromium has no page target")
    return next((target for target in pages if target.get("url") == "about:blank"), pages[0])


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("url")
    parser.add_argument("--port", type=int, default=9222)
    parser.add_argument("--screenshot", required=True)
    parser.add_argument("--no-screenshot", action="store_true")
    parser.add_argument("--no-scroll", action="store_true")
    parser.add_argument("--query", action="append", default=[])
    parser.add_argument("--click-selector")
    parser.add_argument("--type-selector")
    parser.add_argument("--type-text")
    parser.add_argument("--settle-seconds", type=float, default=5)
    parser.add_argument("--no-navigate", action="store_true")
    args = parser.parse_args()
    if (args.type_selector is None) != (args.type_text is None):
        parser.error("--type-selector and --type-text must be supplied together")
    target = page_target(args.port)
    with connect(target["webSocketDebuggerUrl"]) as sock:
        cdp = Cdp(sock)
        cdp.call("Page.enable")
        cdp.call("Runtime.enable")
        if not args.no_navigate:
            cdp.call("Page.navigate", {"url": args.url})
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                state = cdp.call("Runtime.evaluate", {"expression": "document.readyState", "returnByValue": True})
                if state.get("result", {}).get("value") == "complete":
                    break
                time.sleep(0.25)
        time.sleep(args.settle_seconds)
        actions = []
        if args.click_selector:
            expression = "Boolean(document.querySelector(%s))" % json.dumps(args.click_selector)
            result = cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
            if not result.get("result", {}).get("value", False):
                raise RuntimeError("click selector not found: %s" % args.click_selector)
            cdp.call(
                "Runtime.evaluate",
                {"expression": "document.querySelector(%s).click()" % json.dumps(args.click_selector)},
            )
            actions.append("click:%s" % args.click_selector)
        if args.type_selector:
            expression = "Boolean(document.querySelector(%s))" % json.dumps(args.type_selector)
            result = cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
            if not result.get("result", {}).get("value", False):
                raise RuntimeError("type selector not found: %s" % args.type_selector)
            cdp.call(
                "Runtime.evaluate",
                {"expression": "document.querySelector(%s).focus()" % json.dumps(args.type_selector)},
            )
            cdp.call("Input.insertText", {"text": args.type_text})
            actions.append("type:%s" % args.type_selector)
        if actions:
            time.sleep(1)
        checks = {}
        for selector in args.query:
            expression = f"Boolean(document.querySelector({json.dumps(selector)}))"
            result = cdp.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
            checks[selector] = result.get("result", {}).get("value", False)
        page_state_response = cdp.call(
            "Runtime.evaluate",
            {"expression": "JSON.stringify({title:document.title, readyState:document.readyState, bodyText:document.body ? document.body.innerText.slice(0, 500) : '', bodyLength:document.body ? document.body.innerText.length : 0, htmlLength:document.documentElement ? document.documentElement.outerHTML.length : 0})", "returnByValue": True},
        )
        page_state = page_state_response.get("result", {}).get("value", "")
        if not page_state:
            print(json.dumps({"page_state_response": page_state_response}, sort_keys=True))
        if not args.no_screenshot:
            if not args.no_scroll:
                cdp.call("Runtime.evaluate", {"expression": "window.scrollBy(0, Math.max(400, innerHeight));"})
            cdp.call("Runtime.evaluate", {"expression": "document.title"})
            screenshot = cdp.call("Page.captureScreenshot", {"format": "png", "fromSurface": True})
    if not args.no_screenshot:
        with open(args.screenshot, "wb") as output:
            output.write(base64.b64decode(screenshot["data"]))
    print(json.dumps({"url": args.url, "checks": checks, "actions": actions, "page": page_state, "screenshot": args.screenshot}))


if __name__ == "__main__":
    main()

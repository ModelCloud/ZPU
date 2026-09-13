#!/usr/bin/env python3

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


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=9222)
    args = parser.parse_args()

    with urllib.request.urlopen(
        f"http://127.0.0.1:{args.port}/json/version", timeout=5
    ) as response:
        version = json.load(response)
    websocket_url = urllib.parse.urlsplit(version["webSocketDebuggerUrl"])
    connection = socket.create_connection(
        (websocket_url.hostname, websocket_url.port), timeout=5
    )
    with connection:
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
        connection.sendall(request.encode())
        response = bytearray()
        while b"\r\n\r\n" not in response:
            response.extend(connection.recv(4096))
        if not response.startswith(b"HTTP/1.1 101"):
            raise RuntimeError(response.decode(errors="replace"))

        send_text(connection, json.dumps({"id": 1, "method": "SystemInfo.getInfo"}))
        while True:
            opcode, payload = receive_frame(connection)
            if opcode == 1:
                message = json.loads(payload)
                if message.get("id") == 1:
                    print(json.dumps(message["result"], indent=2, sort_keys=True))
                    return


if __name__ == "__main__":
    main()

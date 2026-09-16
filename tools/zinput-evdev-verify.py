#!/usr/bin/env python3
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
"""Prove MouseClient reaches the real guest evdev device created by uinput."""

import os
import select
import struct
import sys
import time

from zpu import MouseClient


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit("usage: zinput-evdev-verify.py <event-device> <zmouse-socket>")
    event_path, socket_path = sys.argv[1:]
    event_struct = struct.Struct("@llHHi")
    fd = os.open(event_path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        with MouseClient(socket_path) as mouse:
            mouse.move(37, -19)

        events = []
        deadline = time.monotonic() + 2.0
        while time.monotonic() < deadline:
            ready, _, _ = select.select([fd], [], [], deadline - time.monotonic())
            if not ready:
                break
            data = os.read(fd, event_struct.size * 16)
            for offset in range(0, len(data) - (len(data) % event_struct.size), event_struct.size):
                _, _, event_type, code, value = event_struct.unpack_from(data, offset)
                events.append((event_type, code, value))
            if {(2, 0, 37), (2, 1, -19)}.issubset(events):
                break
    finally:
        os.close(fd)

    expected = {(2, 0, 37), (2, 1, -19)}  # EV_REL / REL_X / REL_Y
    if not expected.issubset(events):
        raise SystemExit(f"missing MouseClient uinput motion events: {events!r}")
    print(f"zinput_mouseclient_evdev=PASS ({event_path})")


if __name__ == "__main__":
    main()

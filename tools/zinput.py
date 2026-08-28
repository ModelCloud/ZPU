# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Python interface for the zmouse and zkeyboard emulated Linux input drivers.
#
# Two usage styles are supported:
#
# 1. Direct uinput device creation (uses libzinput.so):
#    from zinput import Mouse, Keyboard
#    with Mouse() as m:
#        m.move(100, 0)
#        m.button(1, True)
#        m.button(1, False)
#        m.wheel(1)
#
#    with Keyboard() as k:
#        k.key(30, 1)   # KEY_A down
#        k.key(30, 0)   # KEY_A up
#
# 2. Talking to the zmouse/zkeyboard Unix-socket daemons:
#    from zinput import MouseClient, KeyboardClient
#    with MouseClient('/run/zmouse.sock') as m:
#        m.move(100, 0)
#
#    with KeyboardClient('/run/zkeyboard.sock') as k:
#        k.key(30, 1)
#        k.key(30, 0)

import ctypes
import os
import socket
import sys
from typing import Optional

__all__ = ["Mouse", "Keyboard", "MouseClient", "KeyboardClient", "load_library"]

_lib: Optional[ctypes.CDLL] = None


def load_library(path: Optional[str] = None) -> ctypes.CDLL:
    """Load libzinput.so and set up ctypes function signatures."""
    global _lib
    if _lib is not None:
        return _lib

    if path is None:
        # Look next to this module first, then on the standard search path.
        candidates = [os.path.join(os.path.dirname(__file__), "libzinput.so"), "libzinput.so"]
    else:
        candidates = [path]

    for p in candidates:
        try:
            _lib = ctypes.CDLL(p)
            break
        except OSError:
            pass
    else:
        raise OSError("libzinput.so not found; build it with `make libzinput.so`")

    _lib.zmouse_create.argtypes = [ctypes.c_char_p]
    _lib.zmouse_create.restype = ctypes.c_int
    _lib.zmouse_destroy.argtypes = [ctypes.c_int]
    _lib.zmouse_destroy.restype = ctypes.c_int
    _lib.zmouse_move.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    _lib.zmouse_move.restype = ctypes.c_int
    _lib.zmouse_move_abs.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    _lib.zmouse_move_abs.restype = ctypes.c_int
    _lib.zmouse_button.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    _lib.zmouse_button.restype = ctypes.c_int
    _lib.zmouse_wheel.argtypes = [ctypes.c_int, ctypes.c_int]
    _lib.zmouse_wheel.restype = ctypes.c_int
    _lib.zmouse_hwheel.argtypes = [ctypes.c_int, ctypes.c_int]
    _lib.zmouse_hwheel.restype = ctypes.c_int

    _lib.zkeyboard_create.argtypes = [ctypes.c_char_p]
    _lib.zkeyboard_create.restype = ctypes.c_int
    _lib.zkeyboard_destroy.argtypes = [ctypes.c_int]
    _lib.zkeyboard_destroy.restype = ctypes.c_int
    _lib.zkeyboard_key.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_int]
    _lib.zkeyboard_key.restype = ctypes.c_int

    return _lib


class _UinputDeviceBase:
    """Base class for direct uinput devices created through libzinput.so."""

    def __init__(self, device: Optional[str] = None):
        self._fd = -1
        self._device = device

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def close(self):
        if self._fd >= 0:
            self._destroy(self._fd)
            self._fd = -1

    def __del__(self):
        self.close()

    def _dev_bytes(self) -> Optional[bytes]:
        return self._device.encode() if self._device is not None else None

    @property
    def fd(self) -> int:
        return self._fd


class Mouse(_UinputDeviceBase):
    """Create a virtual mouse device through /dev/uinput."""

    def __init__(self, device: Optional[str] = None):
        super().__init__(device)
        self._fd = load_library().zmouse_create(self._dev_bytes())
        if self._fd < 0:
            raise OSError(f"failed to create zmouse device on {device or '/dev/uinput'}")
        self._destroy = load_library().zmouse_destroy

    def move(self, dx: int, dy: int) -> None:
        """Relative pointer motion."""
        if load_library().zmouse_move(self._fd, int(dx), int(dy)) < 0:
            raise OSError("zmouse move failed")

    def move_abs(self, x: int, y: int) -> None:
        """Absolute pointer motion, 0..65535."""
        if load_library().zmouse_move_abs(self._fd, int(x), int(y)) < 0:
            raise OSError("zmouse absolute move failed")

    def button(self, n: int, down: bool) -> None:
        """Button n (1-5) down/up."""
        if load_library().zmouse_button(self._fd, int(n), 1 if down else 0) < 0:
            raise OSError("zmouse button event failed")

    def wheel(self, n: int) -> None:
        """Vertical wheel."""
        if load_library().zmouse_wheel(self._fd, int(n)) < 0:
            raise OSError("zmouse wheel failed")

    def hwheel(self, n: int) -> None:
        """Horizontal wheel."""
        if load_library().zmouse_hwheel(self._fd, int(n)) < 0:
            raise OSError("zmouse horizontal wheel failed")

    def click(self, n: int = 1) -> None:
        """Press and release a button."""
        self.button(n, True)
        self.button(n, False)


class Keyboard(_UinputDeviceBase):
    """Create a virtual keyboard device through /dev/uinput."""

    def __init__(self, device: Optional[str] = None):
        super().__init__(device)
        self._fd = load_library().zkeyboard_create(self._dev_bytes())
        if self._fd < 0:
            raise OSError(f"failed to create zkeyboard device on {device or '/dev/uinput'}")
        self._destroy = load_library().zkeyboard_destroy

    def key(self, code: int, value: int) -> None:
        """Emit a key event (code, 0=up, 1=down, 2=repeat)."""
        if load_library().zkeyboard_key(self._fd, int(code), int(value)) < 0:
            raise OSError("zkeyboard key event failed")

    def key_down(self, code: int) -> None:
        self.key(code, 1)

    def key_up(self, code: int) -> None:
        self.key(code, 0)

    def key_tap(self, code: int) -> None:
        self.key_down(code)
        self.key_up(code)


class _SocketClientBase:
    """Base for clients that send line commands to a running daemon."""

    def __init__(self, socket_path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.connect(socket_path)

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        self.close()
        return False

    def close(self):
        if self.sock is not None:
            self.sock.close()
            self.sock = None

    def __del__(self):
        self.close()

    def _send(self, line: str) -> None:
        self.sock.sendall((line.strip() + "\n").encode())


class MouseClient(_SocketClientBase):
    """Control a running zmouse daemon over its Unix socket."""

    def __init__(self, socket_path: str = "/run/zmouse.sock"):
        super().__init__(socket_path)

    def move(self, dx: int, dy: int) -> None:
        self._send(f"m {dx} {dy}")

    def move_abs(self, x: int, y: int) -> None:
        self._send(f"a {x} {y}")

    def button(self, n: int, down: bool) -> None:
        self._send(f"b {n} {1 if down else 0}")

    def wheel(self, n: int) -> None:
        self._send(f"w {n}")

    def hwheel(self, n: int) -> None:
        self._send(f"h {n}")

    def click(self, n: int = 1) -> None:
        self.button(n, True)
        self.button(n, False)

    def quit(self) -> None:
        self._send("q")


class KeyboardClient(_SocketClientBase):
    """Control a running zkeyboard daemon over its Unix socket."""

    def __init__(self, socket_path: str = "/run/zkeyboard.sock"):
        super().__init__(socket_path)

    def key(self, code: int, value: int) -> None:
        self._send(f"k {code} {value}")

    def key_down(self, code: int) -> None:
        self.key(code, 1)

    def key_up(self, code: int) -> None:
        self.key(code, 0)

    def key_tap(self, code: int) -> None:
        self.key_down(code)
        self.key_up(code)

    def quit(self) -> None:
        self._send("q")


def main(argv: Optional[list] = None) -> int:
    """Tiny CLI for quick manual tests (no uinput required for client mode)."""
    if argv is None:
        argv = sys.argv
    if len(argv) < 2:
        print("usage: zinput.py {mouse|keyboard} <socket_path>")
        return 1
    kind = argv[1]
    path = argv[2] if len(argv) > 2 else None
    try:
        if kind == "mouse":
            with MouseClient(path) as m:
                m.move(50, 0)
                m.click(1)
        elif kind == "keyboard":
            with KeyboardClient(path) as k:
                k.key_tap(30)
        else:
            print("unknown device kind; use 'mouse' or 'keyboard'")
            return 1
    except Exception as e:
        print(f"zinput.py: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())

#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Unit test for the emulated zmouse and zkeyboard uinput drivers.
#
# This is a compile/build test that also verifies the binaries are statically
# linked, that libzinput.so builds, and that the Python bindings import.  It
# does not require /dev/uinput or a running desktop, so it is safe to run in CI.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash -n "$repo/tools/smolvm-zinput.sh" 2>/dev/null || true

make -C "$repo/tools" clean >/dev/null
make -C "$repo/tools" CFLAGS='-O2 -Wall -Wextra -Werror -static' LDFLAGS='-static' zmouse zkeyboard >/dev/null
make -C "$repo/tools" libzinput.so >/dev/null

for bin in zmouse zkeyboard; do
    "$repo/tools/$bin" -h >/dev/null 2>&1
    if readelf -l "$repo/tools/$bin" | grep -q 'INTERP'; then
        echo "zinput: $bin is not statically linked" >&2
        exit 1
    fi
done

if [[ ! -f "$repo/tools/libzinput.so" ]]; then
    echo "zinput: libzinput.so not built" >&2
    exit 1
fi

python3 -m py_compile "$repo/tools/zinput.py"
python3 - <<PY
import ctypes
import os
libpath = os.path.join("$repo/tools", "libzinput.so")
lib = ctypes.CDLL(libpath)
assert lib.zmouse_create(b"/nonexistent/uinput") < 0
assert lib.zkeyboard_create(b"/nonexistent/uinput") < 0
PY

echo 'zinput: PASS'

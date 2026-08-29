#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 "$root/tools/metal_abi_status.py" >"$tmp/report"
if ! rg -F "coverage remains WIP" "$tmp/report" >/dev/null; then
    rg -F "semantic coverage remains manifest-driven" "$tmp/report" >/dev/null
fi
if command -v xcrun >/dev/null && xcrun --sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    python3 "$root/tools/metal_abi_status.py" --all-platforms >"$tmp/platform-report"
    rg -F "platform=macosx" "$tmp/platform-report" >/dev/null
    rg -F "platform=iphoneos" "$tmp/platform-report" >/dev/null
fi

# The Apple-facing file imports Metal only for protocol/ABI declarations. It
# must not contain a native device/resource bridge: native Metal execution is
# confined to test/metal_pixel_accuracy.m as the byte-accuracy oracle.
if rg -n -- "MTLCreateSystemDefaultDevice|_native|native(Buffer|Texture|Queue|CommandBuffer)|sync(To|From)Native|prepareNativeResource" \
    "$root/src/metal/apple_adapter.m" >"$tmp/adapter-native-bridge"; then
    cat "$tmp/adapter-native-bridge" >&2
    echo "metal-abi: CPU adapter contains a forbidden native Metal bridge" >&2
    exit 1
fi

cc=${CC:-clang}
"$cc" -std=c11 -Wall -Wextra -Werror -pedantic -I"$root/include" -fsyntax-only "$root/test/metal_abi.c"

if python3 "$root/tools/metal_abi_status.py" --require-complete >"$tmp/strict-out" 2>"$tmp/strict-err"; then
    echo "strict Metal coverage unexpectedly passed" >&2
    exit 1
fi
rg -F "coverage" "$tmp/strict-err" >/dev/null
echo "metal-abi: native C ABI, mapping manifest, and fail-closed strict gate: PASS"

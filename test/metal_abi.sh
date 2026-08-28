#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

python3 "$root/tools/metal_abi_status.py" >"$tmp/report"
rg -F "coverage remains WIP" "$tmp/report" >/dev/null

cc=${CC:-clang}
"$cc" -std=c11 -Wall -Wextra -Werror -pedantic -I"$root/include" -fsyntax-only "$root/test/metal_abi.c"

if python3 "$root/tools/metal_abi_status.py" --require-complete >"$tmp/strict-out" 2>"$tmp/strict-err"; then
    echo "strict Metal coverage unexpectedly passed" >&2
    exit 1
fi
rg -F "coverage" "$tmp/strict-err" >/dev/null
echo "metal-abi: native C ABI, mapping manifest, and fail-closed strict gate: PASS"

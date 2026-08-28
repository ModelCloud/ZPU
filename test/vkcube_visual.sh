#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

manifest=${1:?installed ZPU ICD manifest required}
output=$(mktemp)
trap 'rm -f "$output"' EXIT

if ! VK_DRIVER_FILES="$manifest" ZPU_VERIFY_PRESENT=1 vkcube --wsi xcb --c 2 --suppress_popups >"$output" 2>&1; then
    sed -n '1,120p' "$output"
    exit 1
fi
if ! grep -Eq '^zpu_visual_present=BGRA\([0-9]+,[0-9]+,[0-9]+,[0-9]+\)$' "$output"; then
    sed -n '1,120p' "$output"
    exit 1
fi
if grep -Eq '^zpu_visual_present=BGRA\(51,51,51,' "$output"; then
    sed -n '1,120p' "$output"
    exit 1
fi
grep -E '^(Selected GPU|zpu_visual_present=)' "$output"

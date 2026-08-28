#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

# Deterministic regression for the eight-lane kernel ABI guards (BL-3).
#
# The kernel library is built optimized without Debug safety plumbing, so its
# ABI-input violation paths use explicit @trap() calls. This script proves the
# traps physically survived compilation in the emitted x86-64-v3 objects: each
# of the eight exported kernel functions must contain at least one `ud2`
# instruction inside its exact FUNC range.
#
# Usage: kernel_guard_regression.sh KERNEL_ARCHIVE
set -euo pipefail

archive=${1:?usage: kernel_guard_regression.sh KERNEL_ARCHIVE}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

for tool in objdump readelf; do
  command -v "$tool" >/dev/null 2>&1 || { echo "kernel-guard FAILED: missing tool $tool" >&2; exit 69; }
done
[[ -f "$archive" ]] || { echo "kernel-guard FAILED: missing archive '$archive'" >&2; exit 66; }

readelf -sW "$archive" | awk '$4 == "FUNC" && $7 != "UND" && $3 + 0 > 0 {
  h = tolower($2)
  n = 0
  for (i = 1; i <= length(h); i++) {
    c = substr(h, i, 1)
    p = index("0123456789abcdef", c) - 1
    if (p >= 0) n = n * 16 + p
  }
  print n, $3, $8
}' | sort -n >"$work/syms.txt"
{ cat "$work/syms.txt"; echo "__DIS__"; objdump -d -M intel "$archive"; } >"$work/stream.txt"

awk -v phase=1 '
  /^__DIS__$/ { phase = 2; next }
  phase == 1 { starts[++count] = $1; sizes[count] = $2; names[count] = $3; next }
  {
    line = $0
    sub(/^[ \t]+/, "", line)
    if (line !~ /^[0-9a-f]+:[ \t]/) next
    n = split(line, f, "\t")
    if (n < 3) next
    addr_hex = f[1]
    sub(/:.*/, "", addr_hex)
    addr = 0
    for (i = 1; i <= length(addr_hex); i++) {
      c = substr(addr_hex, i, 1)
      p = index("0123456789abcdef", c) - 1
      if (p >= 0) addr = addr * 16 + p
    }
    mnemonic = f[3]
    gsub(/^[ \t]+|[ \t]+$/, "", mnemonic)
    if (mnemonic == "") next
    lo = 1; hi = count; best = 0
    while (lo <= hi) {
      mid = int((lo + hi) / 2)
      if (starts[mid] <= addr) { best = mid; lo = mid + 1 } else hi = mid - 1
    }
    if (!(best && addr < starts[best] + sizes[best])) next
    name = names[best]
    tail = name
    sub(/^.*\./, "", tail)
    if (mnemonic == "ud2") traps[tail]++
    seen_export[tail]++
  }
  END {
    exports["zpu_v3_fill_span_8"] = 1
    exports["zpu_v3_blend_span_8"] = 1
    exports["zpu_v3_blend_pixels_8"] = 1
    exports["zpu_v3_fill_rows_8"] = 1
    exports["zpu_v3_blend_rows_8"] = 1
    exports["zpu_v3_blend_pixels_rows_8"] = 1
    exports["zpu_v3_fill_rects_8"] = 1
    exports["zpu_v3_blend_sprite_batch_8"] = 1
    bad = 0
    for (e in exports) {
      if (!(e in seen_export)) {
        printf "kernel-guard FAILED: export %s missing from archive\n", e > "/dev/stderr"
        bad = 1
      } else if ((traps[e] + 0) < 1) {
        printf "kernel-guard FAILED: export %s lost its @trap() guard during optimization\n", e > "/dev/stderr"
        bad = 1
      } else {
        printf "kernel-guard: %s retains %d trap instruction(s)\n", e, traps[e]
      }
    }
    exit bad
  }' "$work/stream.txt"

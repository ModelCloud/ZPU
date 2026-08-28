#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Unit test for tools/smolvm-fluid-desktop.sh.
#
# By default this runs a dry-run pass that only emits commands and never touches
# the host display or guest. Set ZPU_SMOLVM_FLUID_LIVE=1 to run the full SmolVM
# lifecycle and validate 60 fps frame-time metrics.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

bash -n "$repo/tools/smolvm-fluid-desktop.sh"

if [[ ${ZPU_SMOLVM_FLUID_LIVE:-0} == 1 ]]; then
    # Full validation pass; must run on a host with smolvm and the zpu-omarchy
    # machine already bootstrapped and staged.
    ZPU_FLUID_SCREENSHOT="$tmp/zpu-fluid-desktop.png" \
        "$repo/tools/smolvm-fluid-desktop.sh" test
    [[ -s "$tmp/zpu-fluid-desktop.png" ]]
    echo 'smolvm-fluid-desktop: live PASS'
    exit 0
fi

# Hermetic dry-run: override screenshot path and duration so the script prints
# its command sequence without any host/guest mutation.
ZPU_SMOLVM_DRY_RUN=1 \
ZPU_FLUID_DURATION=1 \
ZPU_FRAME_METRICS_COUNT=10 \
ZPU_FLUID_SCREENSHOT="$tmp/zpu-fluid-desktop.png" \
    "$repo/tools/smolvm-fluid-desktop.sh" test > "$tmp/out"

# Sanity-check that the dry-run planned all the expected lifecycle steps.
grep -F 'xtest_mouse' "$tmp/out" >/dev/null

grep -F 'vkcube --c' "$tmp/out" >/dev/null

grep -F 'scrot' "$tmp/out" >/dev/null || grep -F 'import -window root' "$tmp/out" >/dev/null

echo 'smolvm-fluid-desktop: dry-run PASS'

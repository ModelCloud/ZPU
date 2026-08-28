#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

manifest=${1:?installed ZPU ICD manifest required}
twm_output=$(mktemp)
twm_pid=
cleanup() {
    if [[ -n "$twm_pid" ]] && kill -0 "$twm_pid" 2>/dev/null; then
        kill "$twm_pid"
        wait "$twm_pid" 2>/dev/null || true
    fi
    rm -f "$twm_output"
}
trap cleanup EXIT

twm -f test/twmrc -display "${DISPLAY:?X display required}" >"$twm_output" 2>&1 &
twm_pid=$!
sleep 0.2
if ! kill -0 "$twm_pid" 2>/dev/null; then
    sed -n '1,120p' "$twm_output"
    exit 1
fi

test/vkcube_visual.sh "$manifest"
if ! kill -0 "$twm_pid" 2>/dev/null; then
    sed -n '1,120p' "$twm_output"
    exit 1
fi
printf 'desktop_session=twm vkcube_visual=pass\n'

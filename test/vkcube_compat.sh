#!/usr/bin/env bash
set -euo pipefail

manifest=${1:?installed ZPU ICD manifest required}
mode=${2:-probe}
if [[ "$mode" != probe && "$mode" != --require-ready ]]; then
    echo "usage: $0 <manifest> [--require-ready]" >&2
    exit 1
fi
if [[ ! -f "$manifest" ]]; then
    echo "ZPU ICD manifest not found: $manifest" >&2
    exit 1
fi
for program in timeout xvfb-run vkcube; do
    if ! command -v "$program" >/dev/null; then
        echo "required program not found: $program" >&2
        exit 1
    fi
done

output=$(mktemp)
trap 'rm -f "$output"' EXIT
set +e
XDG_RUNTIME_DIR=${XDG_RUNTIME_DIR:-/tmp} timeout 20s xvfb-run -a \
    -s '-screen 0 640x480x24 -nolisten tcp' \
    env VK_DRIVER_FILES="$manifest" VK_ICD_FILENAMES="$manifest" \
    vkcube --wsi xcb --c 2 --suppress_popups >"$output" 2>&1
status=$?
set -e

sed -n '1,160p' "$output"
if [[ "$status" -eq 0 ]]; then
    echo 'vkcube_status=READY'
    echo 'vkcube_frames=2'
    exit 0
fi

blocker=runtime_or_rendering
if grep -Fq 'VK_KHR_surface' "$output"; then
    blocker=VK_KHR_surface
elif grep -Fq 'VK_KHR_xcb_surface' "$output"; then
    blocker=VK_KHR_xcb_surface
elif grep -Fq 'VK_KHR_swapchain' "$output"; then
    blocker=VK_KHR_swapchain
elif [[ "$status" -eq 124 ]]; then
    blocker=timeout
fi
echo 'vkcube_status=BLOCKED'
echo "vkcube_exit=$status"
echo "vkcube_blocker=$blocker"

if [[ "$mode" == --require-ready ]]; then
    exit 2
fi

#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Reproduce the README Chromium/google.com screenshot inside SmolVM.
# Usage: tools/smolvm-chrome.sh [start-desktop|reproduce]
# Default command is "reproduce".
#
# Run a dry-run to inspect commands:
#   ZPU_SMOLVM_DRY_RUN=1 tools/smolvm-chrome.sh

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
config=${ZPU_CHROME_CONFIG:-$repo/tools/smolvm-chrome.env}
if [[ -r $config ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$config"
    set +a
fi

machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
display=${ZPU_DISPLAY:-:0}
start_desktop=${ZPU_START_DESKTOP:-1}
chrome_bin=${ZPU_CHROME_BIN:-/usr/bin/chromium}
url=${ZPU_CHROME_URL:-https://www.google.com}
guest_screenshot=${ZPU_GUEST_SCREENSHOT:-/tmp/zpu-chrome.png}
host_screenshot=${ZPU_HOST_SCREENSHOT:-$repo/docs/assets/zpu-chromium-google.png}
width=${ZPU_CHROME_WIDTH:-1280}
height=${ZPU_CHROME_HEIGHT:-720}
wait_budget=${ZPU_CHROME_WAIT:-10000}

socket_root=/tmp/.X11-unix
host_socket=$socket_root/X${display#:}

host_auth=
xvfb_pid=
twm_pid=

die() {
    printf 'zpu-chrome: %s\n' "$*" >&2
    exit 2
}

run() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

cleanup() {
    trap - EXIT
    trap '' HUP INT TERM QUIT
    if [[ -n ${twm_pid:-} ]] && kill -0 "$twm_pid" 2>/dev/null; then
        kill "$twm_pid" 2>/dev/null || true
        wait "$twm_pid" 2>/dev/null || true
    fi
    if [[ -n ${xvfb_pid:-} ]] && kill -0 "$xvfb_pid" 2>/dev/null; then
        kill "$xvfb_pid" 2>/dev/null || true
        wait "$xvfb_pid" 2>/dev/null || true
    fi
    rm -f -- "${host_auth:-}"
}
trap cleanup EXIT
trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
trap 'trap "" HUP INT TERM QUIT; exit 130' INT
trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT

require_programs() {
    local program
    for program in smolvm xauth stat python3 ps; do
        if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            command -v "$program" >/dev/null || die "$program is required"
        fi
    done
    if ! python3 -c 'from PIL import Image' 2>/dev/null; then
        die 'python3 PIL is required for PNG compression'
    fi
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        command -v Xvfb >/dev/null || die 'Xvfb is required to create a display if none exists'
        command -v twm >/dev/null || die 'twm is required for the minimal desktop'
    fi
}

machine_state() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf 'running\n'
        return 0
    fi
    smolvm machine ls --json 2>/dev/null | python3 - "$machine" <<'PY'
import json, sys
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    pass
else:
    rows = data if isinstance(data, list) else data.get("machines", [])
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and row.get("name") == sys.argv[1]:
                print(row.get("state", "unknown"))
                raise SystemExit(0)
print("missing")
PY
}

ensure_machine() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure SmolVM machine %q is running\n' "$machine"
        return 0
    fi
    local state
    state=$(machine_state)
    case $state in
        running) ;;
        stopped) run smolvm machine start --name "$machine" ;;
        missing)
            die "machine $machine not found. Build and stage ZPU first:
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh create
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh bootstrap
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh build
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh package
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh stage"
            ;;
        *) die "machine $machine in unexpected state: $state" ;;
    esac
}

ensure_display() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure host display %s with socket %s\n' "$display" "$host_socket"
        return 0
    fi
    if [[ -S $host_socket ]]; then
        return 0
    fi

    local cookie
    host_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
    chmod 600 "$host_auth"
    export XAUTHORITY="$host_auth"
    if command -v mcookie >/dev/null; then
        cookie=$(mcookie)
    elif command -v openssl >/dev/null; then
        cookie=$(openssl rand -hex 16)
    else
        die 'mcookie or openssl is required to generate an X authority cookie'
    fi
    xauth -f "$host_auth" add "$display" MIT-MAGIC-COOKIE-1 "$cookie"

    Xvfb "$display" -auth "$host_auth" -screen 0 "${width}x${height}x24" \
        -noreset +extension GLX +extension RANDR +extension RENDER \
        >/tmp/zpu-xvfb.log 2>&1 &
    xvfb_pid=$!

    local waited
    waited=0
    while [[ ! -S $host_socket ]] && (( waited < 50 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    [[ -S $host_socket ]] || die "Xvfb did not create $host_socket"
}

prepare_host_auth() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare isolated host X authority for %s\n' "$display"
        return 0
    fi
    if [[ -z ${host_auth:-} ]]; then
        host_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
        chmod 600 "$host_auth"
    fi
    xauth -f "$host_auth" nmerge - < <(xauth nlist "$display")
    local entries
    entries=$(xauth -f "$host_auth" nlist "$display" | awk 'NF { count++ } END { print count + 0 }')
    [[ $entries -ge 1 ]] || die "no X authority entry found for $display"
}

ensure_desktop() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure minimal desktop (twm) on %s\n' "$display"
        return 0
    fi
    [[ $start_desktop == 1 ]] || return 0
    if ps -C twm -o pid= 2>/dev/null | grep -q .; then
        return 0
    fi
    twm -f "$repo/test/twmrc" -display "$display" >/tmp/zpu-twm.log 2>&1 &
    twm_pid=$!
    sleep 0.2
    if ! kill -0 "$twm_pid" 2>/dev/null; then
        sed -n '1,120p' /tmp/zpu-twm.log >&2
        die 'twm failed to start'
    fi
}

ensure_zpu_staged() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure ZPU is staged in /opt/zpu on %s\n' "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- test -r /opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json || \
        die "ZPU is not staged in /opt/zpu. Run:
  ZPU_SMOLVM_MACHINE=$machine tools/smolvm-zpu.sh stage"
}

ensure_chromium() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure Chromium is installed on %s\n' "$machine"
        return 0
    fi
    if run smolvm machine exec --name "$machine" -- test -x "$chrome_bin"; then
        return 0
    fi
    run smolvm machine update --name "$machine" --net
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm
    run smolvm machine exec --name "$machine" -- pacman -S --noconfirm --needed chromium ttf-liberation
    run smolvm machine update --name "$machine" --no-net
    run smolvm machine exec --name "$machine" -- test -x "$chrome_bin" || die "chromium installation did not provide $chrome_bin"
}

prepare_guest_auth() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare guest X authority at /run/zpu-xauth on %s\n' "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -c '
        rm -rf /run/zpu-xauth /run/zpu-runtime
        install -d -m 700 /run/zpu-xauth /run/zpu-runtime
    '
    run smolvm machine cp "$host_auth" "$machine:/run/zpu-xauth/Xauthority"
    run smolvm machine exec --name "$machine" -- sh -c '
        printf "%s\n" trusted > /run/zpu-xauth/mode
        chmod 600 /run/zpu-xauth/Xauthority /run/zpu-xauth/mode
    '
}

compress_png() {
    python3 - "$1" <<'PY'
import sys
from PIL import Image
Image.open(sys.argv[1]).save(sys.argv[1], 'PNG', optimize=True, compress_level=9)
PY
}

launch_chrome() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ launch Chromium on %s and copy screenshot to %s\n' "$machine" "$host_screenshot"
        return 0
    fi
    if [[ $host_screenshot != /* ]]; then
        host_screenshot=$repo/$host_screenshot
    fi
    run smolvm machine exec --name "$machine" -- env -i \
        HOME=/root \
        PATH=/usr/bin:/bin \
        XDG_RUNTIME_DIR=/run/zpu-runtime \
        DISPLAY=:0 \
        XAUTHORITY=/run/zpu-xauth/Xauthority \
        VK_ICD_FILENAMES=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json \
        VK_DRIVER_FILES=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json \
        "$chrome_bin" --headless \
        --ozone-platform=headless \
        --use-vulkan=native \
        --enable-features=Vulkan \
        --disable-vulkan-fallback-to-gl-for-testing \
        --run-all-compositor-stages-before-draw \
        --virtual-time-budget="$wait_budget" \
        --window-size="${width},${height}" \
        --hide-scrollbars \
        --screenshot="$guest_screenshot" \
        "$url"
    run smolvm machine cp "$machine:$guest_screenshot" "$host_screenshot"
    compress_png "$host_screenshot"
    printf 'zpu-chrome: screenshot saved to %s\n' "$host_screenshot"
}

start_desktop_cmd() {
    ensure_display
    prepare_host_auth
    ensure_desktop
    printf 'zpu-chrome: host desktop ready on %s\n' "$display"
}

reproduce() {
    require_programs
    ensure_machine
    ensure_display
    prepare_host_auth
    ensure_desktop
    ensure_zpu_staged
    ensure_chromium
    prepare_guest_auth
    launch_chrome
}

usage() {
    printf 'usage: %s [start-desktop|reproduce]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
}

cmd=${1:-reproduce}
case $cmd in
    start-desktop) start_desktop_cmd ;;
    reproduce) reproduce ;;
    *) usage ;;
esac

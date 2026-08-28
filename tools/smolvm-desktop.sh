#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Reproduce the README SmolVM Linux Desktop screenshot.
# Usage: tools/smolvm-desktop.sh
#
# The script ensures a host X display is reachable, launches xclock from the
# SmolVM guest onto that display, and captures the root window.

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
host_screenshot=${ZPU_DESKTOP_SCREENSHOT:-$repo/docs/assets/zpu-desktop.png}

socket_root=/tmp/.X11-unix
host_socket=$socket_root/X${display#:}

host_auth=
xclock_pid=

die() {
    printf 'zpu-desktop: %s\n' "$*" >&2
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
    if [[ -n ${xclock_pid:-} ]] && kill -0 "$xclock_pid" 2>/dev/null; then
        kill "$xclock_pid" 2>/dev/null || true
        wait "$xclock_pid" 2>/dev/null || true
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
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        if ! command -v scrot >/dev/null && ! command -v import >/dev/null; then
            die 'scrot or ImageMagick import is required for desktop capture'
        fi
    fi
}

machine_state() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf 'running\n'
        return 0
    fi
    smolvm machine ls --json 2>/dev/null | python3 -c 'import json, sys
machine = sys.argv[1]
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    pass
else:
    rows = data if isinstance(data, list) else data.get("machines", [])
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and row.get("name") == machine:
                print(row.get("state", "unknown"))
                sys.exit(0)
print("missing")' "$machine"
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
        *) die "machine $machine is not running: $state" ;;
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
    if ! command -v Xvfb >/dev/null; then
        die 'Xvfb is required to create a host display'
    fi
    local cookie
    host_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
    chmod 600 "$host_auth"
    if command -v mcookie >/dev/null; then
        cookie=$(mcookie)
    elif command -v openssl >/dev/null; then
        cookie=$(openssl rand -hex 16)
    else
        die 'mcookie or openssl is required to generate an X authority cookie'
    fi
    xauth -f "$host_auth" add "$display" MIT-MAGIC-COOKIE-1 "$cookie"
    export XAUTHORITY="$host_auth"
    Xvfb "$display" -auth "$host_auth" -screen 0 "1280x720x24" \
        -noreset +extension GLX +extension RANDR +extension RENDER \
        >/tmp/zpu-xvfb.log 2>&1 &
    local waited=0
    while [[ ! -S $host_socket ]] && (( waited < 50 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    [[ -S $host_socket ]] || die "Xvfb did not create $host_socket"
}

prepare_host_auth() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare isolated host X authority for %s (FamilyWild)\n' "$display"
        return 0
    fi
    if [[ -z ${host_auth:-} ]]; then
        host_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
        chmod 600 "$host_auth"
    fi
    xauth nlist "$display" | awk 'NF' | sed -e 's/^..../ffff/' | head -n1 | xauth -f "$host_auth" nmerge -
    local entries
    entries=$(xauth -f "$host_auth" nlist | awk 'NF { count++ } END { print count + 0 }')
    [[ $entries -ge 1 ]] || die "no X authority entry found for $display"
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

ensure_xclock() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure xclock is installed on %s\n' "$machine"
        return 0
    fi
    if run smolvm machine exec --name "$machine" -- test -x /usr/bin/xclock; then
        return 0
    fi
    run smolvm machine update --name "$machine" --net
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm
    run smolvm machine exec --name "$machine" -- pacman -S --noconfirm --needed xorg-xclock
    run smolvm machine update --name "$machine" --no-net
    run smolvm machine exec --name "$machine" -- test -x /usr/bin/xclock || die 'xclock installation did not provide /usr/bin/xclock'
}

capture_root() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ capture host root window to %q\n' "$host_screenshot"
        return 0
    fi
    if [[ $host_screenshot != /* ]]; then
        host_screenshot=$repo/$host_screenshot
    fi
    if command -v scrot >/dev/null; then
        DISPLAY="$display" scrot "$host_screenshot"
    else
        DISPLAY="$display" import -window root "$host_screenshot"
    fi
    python3 - "$host_screenshot" <<'PY'
import sys
from PIL import Image
img = Image.open(sys.argv[1])
img = img.resize((1280, 720))
img.save(sys.argv[1], 'PNG', optimize=True, compress_level=9)
PY
    printf 'zpu-desktop: screenshot saved to %s\n' "$host_screenshot"
}

main() {
    require_programs
    ensure_machine
    ensure_display
    prepare_host_auth
    prepare_guest_auth
    ensure_xclock
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ launch xclock on %s\n' "$machine"
        capture_root
        return 0
    fi
    # Launch xclock in the guest, mapped onto the shared host X display.
    xclock_pid=$(smolvm machine exec --name "$machine" -- env -i \
        HOME=/root \
        PATH=/usr/bin:/bin \
        XDG_RUNTIME_DIR=/run/zpu-runtime \
        DISPLAY=:0 \
        XAUTHORITY=/run/zpu-xauth/Xauthority \
        sh -c '/usr/bin/xclock -geometry 300x300+100+100 >/dev/null 2>&1 & echo $!')
    [[ -n ${xclock_pid:-} ]] || die 'failed to launch xclock in the guest'
    sleep 2
    capture_root
    smolvm machine exec --name "$machine" -- kill -9 "$xclock_pid" 2>/dev/null || true
    xclock_pid=
}

main "$@"

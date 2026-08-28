#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# SmolVM + ZPU fluid 60 Hz desktop rendering test with a simulated pointer.
#
# Launches vkcube from an Arch Linux SmolVM guest onto a shared host X11 display,
# drives the pointer across the screen from a guest background process using the
# X11 XTEST extension, and verifies that the rendered frames keep a p99 frame
# time under the configured budget (default 17 ms, i.e. 60 fps with 2% slack).
#
# Usage: tools/smolvm-fluid-desktop.sh [test]
# Default command is "test".
#
# Dry-run to inspect commands without changing host or guest state:
#   ZPU_SMOLVM_DRY_RUN=1 tools/smolvm-fluid-desktop.sh
#
# Environment knobs (all have defaults):
#   ZPU_SMOLVM_MACHINE         SmolVM machine name (default: zpu-omarchy)
#   ZPU_DISPLAY                Host X display number (default: :0)
#   ZPU_START_DESKTOP          Start twm if no WM is detected (default: 1)
#   ZPU_REFRESH_HZ             Present cadence (default: 60)
#   ZPU_FLUID_WIDTH            vkcube window width (default: 256)
#   ZPU_FLUID_HEIGHT           vkcube window height (default: 256)
#   ZPU_FLUID_DURATION         Approximate vkcube runtime in seconds (default: 8)
#   ZPU_MOUSE_HZ               Pointer update frequency (default: 30)
#   ZPU_MOUSE_PATH             Path name: perimeter|figure8 (default: perimeter)
#   ZPU_FRAME_METRICS_COUNT    Number of frame-time samples to write (default: 180)
#   ZPU_FLUID_BUDGET_MS        p99 budget in milliseconds (default: 17.0)
#   ZPU_FLUID_SCREENSHOT       Host path for the captured screenshot
#                              (default: docs/assets/zpu-fluid-desktop.png)
#   ZPU_SUSPEND_COMPOSITOR     Try to suspend KWin/Plasma compositing (default: 1)

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
config=${ZPU_FLUID_CONFIG:-$repo/tools/smolvm-fluid-desktop.env}
if [[ -r $config ]]; then
    set -a
    # shellcheck source=/dev/null
    source "$config"
    set +a
fi

machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
display=${ZPU_DISPLAY:-:0}
start_desktop=${ZPU_START_DESKTOP:-1}
refresh_hz=${ZPU_REFRESH_HZ:-60}
width=${ZPU_FLUID_WIDTH:-256}
height=${ZPU_FLUID_HEIGHT:-256}
duration=${ZPU_FLUID_DURATION:-8}
mouse_hz=${ZPU_MOUSE_HZ:-30}
mouse_path=${ZPU_MOUSE_PATH:-perimeter}
metrics_count=${ZPU_FRAME_METRICS_COUNT:-180}
budget_ms=${ZPU_FLUID_BUDGET_MS:-17.0}
screenshot=${ZPU_FLUID_SCREENSHOT:-$repo/docs/assets/zpu-fluid-desktop.png}
suspend_compositor=${ZPU_SUSPEND_COMPOSITOR:-1}

socket_root=${ZPU_SOCKET_ROOT:-/tmp/.X11-unix}
host_socket=$socket_root/X${display#:}

host_auth=
xvfb_pid=
twm_pid=
capture_pid=
compositor_suspended=0

die() {
    printf 'zpu-fluid-desktop: %s\n' "$*" >&2
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
    if [[ -n ${capture_pid:-} ]] && kill -0 "$capture_pid" 2>/dev/null; then
        kill "$capture_pid" 2>/dev/null || true
        wait "$capture_pid" 2>/dev/null || true
    fi
    if [[ ${compositor_suspended:-0} == 1 ]]; then
        resume_compositor
    fi
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
    for program in smolvm xauth python3 ps awk; do
        if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            command -v "$program" >/dev/null || die "$program is required"
        fi
    done
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        if ! command -v scrot >/dev/null && ! command -v import >/dev/null; then
            die 'scrot or ImageMagick import is required for screenshot capture'
        fi
    fi
    if ! python3 -c 'from PIL import Image' 2>/dev/null; then
        die 'python3 PIL is required for PNG compression'
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
        -noreset +extension GLX +extension RANDR +extension RENDER +extension XTEST \
        >/tmp/zpu-xvfb.log 2>&1 &
    xvfb_pid=$!
    local waited=0
    while [[ ! -S $host_socket ]] && (( waited < 50 )); do
        sleep 0.1
        waited=$((waited + 1))
    done
    [[ -S $host_socket ]] || die "Xvfb did not create $host_socket"
    printf 'zpu-fluid-desktop: started Xvfb on %s (pid %s)\n' "$display" "$xvfb_pid" >&2
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

ensure_desktop() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure minimal desktop (twm) on %s\n' "$display"
        return 0
    fi
    [[ $start_desktop == 1 ]] || return 0
    if ps -C twm -o pid= 2>/dev/null | grep -q .; then
        return 0
    fi
    rm -f /tmp/zpu-twm.log
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        twm -f "$repo/test/twmrc" -display "$display" >/tmp/zpu-twm.log 2>&1 &
        twm_pid=$!
        sleep 0.2
        if ! kill -0 "$twm_pid" 2>/dev/null; then
            if [[ -f /tmp/zpu-twm.log ]] && grep -q 'another window manager' /tmp/zpu-twm.log; then
                printf 'zpu-fluid-desktop: another window manager is already running on %s, continuing\n' "$display" >&2
                return 0
            fi
            sed -n '1,120p' /tmp/zpu-twm.log >&2
            die 'twm failed to start'
        fi
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

ensure_vkcube() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure vkcube is installed on %s\n' "$machine"
        return 0
    fi
    if run smolvm machine exec --name "$machine" -- test -x /usr/bin/vkcube; then
        return 0
    fi
    run smolvm machine update --name "$machine" --net
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm
    run smolvm machine exec --name "$machine" -- pacman -S --noconfirm --needed vulkan-tools
    run smolvm machine update --name "$machine" --no-net
    run smolvm machine exec --name "$machine" -- test -x /usr/bin/vkcube || die 'vkcube installation did not provide /usr/bin/vkcube'
}

ensure_xtest_mouse() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ compile xtest_mouse on %s\n' "$machine"
        return 0
    fi
    run smolvm machine cp "$repo/tools/xtest_mouse.c" "$machine:/run/zpu-runtime/xtest_mouse.c"
    run smolvm machine exec --name "$machine" -- sh -c '
        if ! gcc -O2 -o /run/zpu-runtime/xtest_mouse /run/zpu-runtime/xtest_mouse.c -lX11 -lXtst -lm 2>/tmp/zpu-xtest-mouse-build.log; then
            cat /tmp/zpu-xtest-mouse-build.log >&2
            exit 1
        fi
    ' || die 'failed to compile xtest_mouse in the SmolVM guest'
}

suspend_compositor() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ suspend host compositor (best-effort)\n'
        return 0
    fi
    [[ $suspend_compositor == 1 ]] || return 0
    if command -v qdbus >/dev/null 2>&1; then
        local active
        active=$(qdbus org.kde.KWin /Compositor org.kde.kwin.Compositing.active 2>/dev/null || true)
        if [[ $active == "true" ]]; then
            qdbus org.kde.KWin /Compositor org.kde.kwin.Compositing.suspend >/dev/null 2>&1 || true
            compositor_suspended=1
        fi
    fi
}

resume_compositor() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ resume host compositor\n'
        return 0
    fi
    if [[ $compositor_suspended == 1 ]] && command -v qdbus >/dev/null 2>&1; then
        qdbus org.kde.KWin /Compositor org.kde.kwin.Compositing.resume >/dev/null 2>&1 || true
    fi
    compositor_suspended=0
}

compress_png() {
    python3 - "$1" <<'PY'
import sys
from PIL import Image
img = Image.open(sys.argv[1])
# Keep a readable 1280x720 max while preserving aspect ratio.
w, h = img.size
if w > 1280 or h > 720:
    scale = min(1280 / w, 720 / h)
    img = img.resize((int(w * scale), int(h * scale)), Image.Resampling.LANCZOS)
img.save(sys.argv[1], 'PNG', optimize=True, compress_level=9)
PY
}

parse_metrics() {
    python3 - "$1" "$2" "$3" <<'PY'
import struct, sys
path, budget_ms, refresh = sys.argv[1], float(sys.argv[2]), int(sys.argv[3])
with open(path, 'rb') as f:
    data = f.read()
if len(data) == 0 or len(data) % 8 != 0:
    print('invalid metric file size', len(data))
    sys.exit(1)
nums = [struct.unpack('<Q', data[i:i+8])[0] for i in range(0, len(data), 8)]
nums.sort()
avg = sum(nums) / len(nums)
p99 = nums[int(len(nums) * 0.99)]
p95 = nums[int(len(nums) * 0.95)]
budget_ns = budget_ms * 1_000_000.0
target_ns = 1_000_000_000.0 / refresh
print('frames={} avg_ms={:.3f} p95_ms={:.3f} p99_ms={:.3f} max_ms={:.3f} budget_ms={:.3f}'.format(
    len(nums), avg / 1e6, p95 / 1e6, p99 / 1e6, max(nums) / 1e6, budget_ms))
if p99 <= budget_ns:
    sys.exit(0)
else:
    print('FAIL: p99 frame time {} ms exceeds budget {} ms'.format(p99 / 1e6, budget_ms))
    sys.exit(1)
PY
}

capture_screenshot() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        if command -v scrot >/dev/null; then
            printf '+ DISPLAY=%s XAUTHORITY=%s scrot -p %q\n' "$display" '<host-auth>' "$screenshot"
        else
            printf '+ DISPLAY=%s XAUTHORITY=%s import -window root %q\n' "$display" '<host-auth>' "$screenshot"
        fi
        return 0
    fi
    local delay=$1
    (
        sleep "$delay"
        local tool
        if command -v scrot >/dev/null; then
            # -p includes the pointer so the simulated mouse motion is visible.
            DISPLAY="$display" XAUTHORITY="$host_auth" scrot -p "$screenshot"
        else
            DISPLAY="$display" XAUTHORITY="$host_auth" import -window root "$screenshot"
        fi
    ) &
    capture_pid=$!
}

run_test() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ run fluid desktop test on %s\n' "$machine"
        printf '+   vkcube %sx%s @ %s Hz, pointer %s Hz %s path\n' "$width" "$height" "$refresh_hz" "$mouse_hz" "$mouse_path"
        printf '+ smolvm machine exec %s -- xtest_mouse -display :0 -duration %s -hz %s -path %s ...\n' "$machine" '<duration>' "$mouse_hz" "$mouse_path"
        printf '+ smolvm machine exec %s -- timeout %ss vkcube --c <frames> --width %s --height %s\n' "$machine" '<timeout>' "$width" "$height"
        capture_screenshot '<delay>'
        printf '+ parse frame metrics at %s\n' '<guest-metrics>'
        return 0
    fi

    # The frame budget is 1s/Hz.  We request enough frames to fill the metric
    # buffer and still leave a margin for the screenshot window.
    local frame_count=$(( duration * refresh_hz ))
    local margin=$(( metrics_count / refresh_hz + 4 ))
    if (( frame_count < metrics_count + 60 )); then
        frame_count=$(( metrics_count + 60 ))
    fi
    local vkcube_timeout=$(( frame_count / refresh_hz + 10 ))
    local mouse_duration=$(( vkcube_timeout + 4 ))
    local screenshot_delay=$(( vkcube_timeout / 3 ))
    if (( screenshot_delay < 2 )); then
        screenshot_delay=2
    fi

    local guest_metrics=/run/zpu-runtime/zpu-fluid-metrics.bin
    local icd=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json

    # Remove any stale metrics file.
    smolvm machine exec --name "$machine" -- sh -c "rm -f $guest_metrics"

    suspend_compositor
    capture_screenshot "$screenshot_delay"

    run smolvm machine exec --name "$machine" -- env -i \
        HOME=/root \
        PATH=/usr/bin:/bin \
        XDG_RUNTIME_DIR=/run/zpu-runtime \
        DISPLAY=:0 \
        XAUTHORITY=/run/zpu-xauth/Xauthority \
        VK_ICD_FILENAMES="$icd" \
        VK_DRIVER_FILES="$icd" \
        ZPU_REFRESH_HZ="$refresh_hz" \
        ZPU_FRAME_METRICS=1 \
        ZPU_FRAME_METRICS_COUNT="$metrics_count" \
        ZPU_FRAME_METRICS_PATH="$guest_metrics" \
        sh -c "
            /run/zpu-runtime/xtest_mouse -display :0 -duration $mouse_duration -hz $mouse_hz -path $mouse_path >/dev/null 2>&1 &
            mouse=\$!
            timeout ${vkcube_timeout}s vkcube --c $frame_count --width $width --height $height
            exit=\$?
            kill \$mouse 2>/dev/null || true
            wait \$mouse 2>/dev/null || true
            echo EXIT=\$exit
            ls -l $guest_metrics 2>/dev/null || echo 'metrics-not-found'
        "

    if [[ -n ${capture_pid:-} ]]; then
        wait "$capture_pid"
        capture_pid=
    fi

    local tmp_metrics
    tmp_metrics=$(mktemp)
    run smolvm machine cp "$machine:$guest_metrics" "$tmp_metrics" || die 'frame metrics file not found in guest'
    parse_metrics "$tmp_metrics" "$budget_ms" "$refresh_hz"
    rm -f "$tmp_metrics"

    if [[ $screenshot != /* ]]; then
        screenshot=$repo/$screenshot
    fi
    compress_png "$screenshot"
    printf 'zpu-fluid-desktop: PASS — screenshot %s, p99 <= %s ms @ %s Hz\n' "$screenshot" "$budget_ms" "$refresh_hz"
}

usage() {
    printf 'usage: %s [test]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
}

main() {
    local cmd=${1:-test}
    case $cmd in
        test)
            require_programs
            ensure_machine
            ensure_display
            prepare_host_auth
            ensure_desktop
            ensure_zpu_staged
            ensure_vkcube
            ensure_xtest_mouse
            prepare_guest_auth
            run_test
            ;;
        *) usage ;;
    esac
}

main "$@"

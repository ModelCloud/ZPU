#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Reproduce the README Chromium/google.com screenshot or benchmark real sites
# inside SmolVM. ZPU Mosaic workers are constrained to exactly two guest CPUs.
# Chromium itself remains schedulable across the guest so its browser,
# renderer, and networking threads do not starve the two ZPU render lanes.
# Usage: tools/smolvm-chrome.sh [start-desktop|reproduce|benchmark]
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
smolvm_uid_drop=${ZPU_SMOLVM_UID_DROP:-on}
display=${ZPU_DISPLAY:-:0}
start_desktop=${ZPU_START_DESKTOP:-1}
chrome_bin=${ZPU_CHROME_BIN:-/usr/bin/chromium}
url=${ZPU_CHROME_URL:-https://www.google.com}
guest_screenshot=${ZPU_GUEST_SCREENSHOT:-/tmp/zpu-chrome.png}
host_screenshot=${ZPU_HOST_SCREENSHOT:-$repo/docs/assets/zpu-chromium-google.png}
width=${ZPU_CHROME_WIDTH:-2560}
height=${ZPU_CHROME_HEIGHT:-1440}
wait_budget=${ZPU_CHROME_WAIT:-10000}
chrome_cpu_set=${ZPU_CHROME_CPU_SET:-0,1}
refresh_hz=${ZPU_CHROME_REFRESH_HZ:-60}
benchmark_duration=${ZPU_CHROME_BENCHMARK_DURATION:-8}
benchmark_warmup=${ZPU_CHROME_BENCHMARK_WARMUP:-10}
# 17 ms leaves the same small scheduling margin as the desktop 60 Hz gate,
# while still rejecting a missed 60 Hz compositor deadline.
benchmark_p99_ms=${ZPU_CHROME_BENCHMARK_P99_MS:-17}
benchmark_urls=${ZPU_CHROME_BENCHMARK_URLS:-https://www.google.com,https://www.bing.com,https://www.youtube.com}
diagnose_failures=${ZPU_DIAGNOSE_FAILURES:-0}
diagnose_render=${ZPU_DIAGNOSE_RENDER:-0}
present_dump=${ZPU_PRESENT_DUMP:-}

socket_root=/tmp/.X11-unix
host_socket=$socket_root/X${display#:}
# A pre-existing X server may use a private authority file rather than the
# invoking user's default ~/.Xauthority.  Keep the default conventional while
# allowing reproducible headless hosts to name the file explicitly.
host_xauthority=${ZPU_HOST_XAUTHORITY:-${XAUTHORITY:-$HOME/.Xauthority}}

host_auth=
xvfb_auth=
xvfb_pid=
twm_pid=

die() {
    printf 'zpu-chrome: %s\n' "$*" >&2
    exit 2
}

[[ $diagnose_failures == 0 || $diagnose_failures == 1 ]] || die 'ZPU_DIAGNOSE_FAILURES must be 0 or 1'
[[ $diagnose_render == 0 || $diagnose_render == 1 ]] || die 'ZPU_DIAGNOSE_RENDER must be 0 or 1'
[[ $refresh_hz == 60 ]] || die 'ZPU_CHROME_REFRESH_HZ must be exactly 60 for the 60 fps profile'
[[ $benchmark_duration =~ ^[1-9][0-9]*$ ]] || die 'ZPU_CHROME_BENCHMARK_DURATION must be a positive integer'
[[ $benchmark_warmup =~ ^([0-9]+|[0-9]+\.[0-9]+)$ ]] || die 'ZPU_CHROME_BENCHMARK_WARMUP must be a non-negative decimal'
[[ $benchmark_p99_ms =~ ^([0-9]+|[0-9]+\.[0-9]+)$ ]] || die 'ZPU_CHROME_BENCHMARK_P99_MS must be a positive decimal'
IFS=, read -r chrome_cpu_a chrome_cpu_b chrome_cpu_extra <<<"$chrome_cpu_set"
[[ -n ${chrome_cpu_a:-} && -n ${chrome_cpu_b:-} && -z ${chrome_cpu_extra:-} && $chrome_cpu_a =~ ^[0-9]+$ && $chrome_cpu_b =~ ^[0-9]+$ && $chrome_cpu_a != "$chrome_cpu_b" ]] || \
    die 'ZPU_CHROME_CPU_SET must name exactly two distinct CPU numbers, e.g. 0,1'
case $smolvm_uid_drop in
    on) unset SMOLVM_VM_UID_DROP ;;
    off)
        export SMOLVM_VM_UID_DROP=off
        printf 'zpu-chrome: WARNING: SmolVM per-VM UID isolation is explicitly disabled (ZPU_SMOLVM_UID_DROP=off); use only for controlled bring-up.\n' >&2
        ;;
    *) die 'ZPU_SMOLVM_UID_DROP must be on or off' ;;
esac

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
    rm -f -- "${host_auth:-}" "${xvfb_auth:-}"
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

    local cookie
    xvfb_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
    chmod 600 "$xvfb_auth"
    export XAUTHORITY="$xvfb_auth"
    if command -v mcookie >/dev/null; then
        cookie=$(mcookie)
    elif command -v openssl >/dev/null; then
        cookie=$(openssl rand -hex 16)
    else
        die 'mcookie or openssl is required to generate an X authority cookie'
    fi
    xauth -f "$xvfb_auth" add "$display" MIT-MAGIC-COOKIE-1 "$cookie"

    Xvfb "$display" -auth "$xvfb_auth" -screen 0 "${width}x${height}x24" \
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
        printf '+ prepare isolated host X authority for %s (FamilyWild)\n' "$display"
        return 0
    fi
    if [[ -z ${host_auth:-} ]]; then
        host_auth=$(mktemp /tmp/zpu-xauth.XXXXXX)
        chmod 600 "$host_auth"
    fi
    local source_auth=$host_xauthority
    # If this invocation created Xvfb, its authority is the source of truth;
    # otherwise use the configured authority for the pre-existing display.
    if [[ -n ${xvfb_pid:-} ]]; then source_auth=$xvfb_auth; fi
    [[ -f $source_auth && ! -L $source_auth && -r $source_auth ]] || die "host X authority is not a readable regular file: $source_auth"
    # Normalize the host cookie to FamilyWild (0xffff) so the SmolVM guest can
    # use it regardless of its own hostname. Keep exactly one entry to avoid
    # ambiguous authorization lookups inside the guest.
    xauth -f "$source_auth" nlist "$display" | awk 'NF' | sed -e 's/^..../ffff/' | head -n1 | xauth -f "$host_auth" nmerge -
    local entries
    entries=$(xauth -f "$host_auth" nlist | awk 'NF { count++ } END { print count + 0 }')
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
    rm -f /tmp/zpu-twm.log
    XAUTHORITY="$host_auth" twm -f "$repo/test/twmrc" -display "$display" >/tmp/zpu-twm.log 2>&1 &
    twm_pid=$!
    sleep 0.2
    if ! kill -0 "$twm_pid" 2>/dev/null; then
        if [[ -f /tmp/zpu-twm.log ]] && grep -q 'another window manager' /tmp/zpu-twm.log; then
            printf 'zpu-chrome: another window manager is already running on %s, continuing\n' "$display" >&2
            return 0
        fi
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
    if run smolvm machine exec --name "$machine" -- sh -c "test -x '$chrome_bin' && command -v python3 >/dev/null && command -v xdpyinfo >/dev/null"; then
        return 0
    fi
    # SmolVM only changes persisted network state while stopped.  Keep the
    # package-install egress window bounded and restore the running isolated
    # machine even if pacman itself fails.
    local status=0
    run smolvm machine stop --name "$machine" || return $?
    run smolvm machine update --name "$machine" --net || return $?
    run smolvm machine start --name "$machine" || return $?
    if run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm &&
       run smolvm machine exec --name "$machine" -- pacman -S --noconfirm --needed chromium ttf-liberation vulkan-icd-loader libxcb xorg-xauth xorg-xdpyinfo util-linux python; then
        :
    else
        status=$?
    fi
    run smolvm machine stop --name "$machine" || return $?
    run smolvm machine update --name "$machine" --no-net || return $?
    run smolvm machine start --name "$machine" || return $?
    [[ $status -eq 0 ]] || return "$status"
    run smolvm machine exec --name "$machine" -- test -x "$chrome_bin" || die "chromium installation did not provide $chrome_bin"
}

prepare_guest_auth() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare guest X authority at /run/zpu-xauth on %s\n' "$machine"
        return 0
    fi
    # SmolVM's secure copy endpoint is the guest workspace.  Copying straight
    # into tmpfs-backed /run can report success while dropping the file under
    # UID isolation, so stage there first and install it into the private
    # runtime directory from inside the guest.
    local transfer=/workspace/.zpu-chrome-transfer
    run smolvm machine exec --name "$machine" -- sh -ceu "
        rm -rf /run/zpu-xauth /run/zpu-runtime '$transfer'
        install -d -m 700 /run/zpu-xauth /run/zpu-runtime '$transfer'
    "
    run smolvm machine cp "$host_auth" "$machine:$transfer/Xauthority"
    run smolvm machine exec --name "$machine" -- sh -c '
        test -f /workspace/.zpu-chrome-transfer/Xauthority
        install -m 600 /workspace/.zpu-chrome-transfer/Xauthority /run/zpu-xauth/Xauthority
        rm -f /workspace/.zpu-chrome-transfer/Xauthority
        printf "%s\n" trusted > /run/zpu-xauth/mode
        chmod 600 /run/zpu-xauth/Xauthority /run/zpu-xauth/mode
    '
}

verify_guest_x11() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ verify guest X11 authentication over the SmolVM Unix-socket bridge on %s\n' "$machine"
        return 0
    fi
    # This exercises a real authenticated X11 connection, rather than merely
    # checking that the guest path has socket file type.  It catches a stale
    # mount, a bridge that cannot reach the host X server, and bad Xauthority.
    run smolvm machine exec --name "$machine" -- env -i \
        PATH=/usr/bin:/bin DISPLAY=:0 XAUTHORITY=/run/zpu-xauth/Xauthority \
        xdpyinfo >/dev/null || die 'guest cannot authenticate to the host X server through the SmolVM socket bridge'
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
        ZPU_DIAGNOSE_FAILURES="$diagnose_failures" \
        ZPU_DIAGNOSE_RENDER="$diagnose_render" \
        ZPU_PRESENT_DUMP="$present_dump" \
        ZPU_LIMITED=physical-core-v1 \
        ZPU_MAX_THREADS=2 \
        ZPU_SELECTED_CPUS="$chrome_cpu_set" \
        ZPU_MOSAIC_CPU_SET="$chrome_cpu_set" \
        ZPU_REFRESH_HZ="$refresh_hz" \
        "$chrome_bin" --no-sandbox \
        --disable-gpu-sandbox \
        --headless \
        --enable-gpu \
        --ignore-gpu-blocklist \
        --use-angle=vulkan \
        --ozone-platform=headless \
        --use-vulkan=native \
        --enable-features=Vulkan \
        --disable-vulkan-fallback-to-gl-for-testing \
        --disable-software-compositing-fallback \
        --disable-background-timer-throttling \
        --disable-backgrounding-occluded-windows \
        --disable-renderer-backgrounding \
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

benchmark_chrome() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ benchmark Chromium at %sx%s @ %s Hz with ZPU restricted to CPUs %s (ZPU_MAX_THREADS=2)\n' "$width" "$height" "$refresh_hz" "$chrome_cpu_set"
        printf '+ warm up each site for %ss, then measure %ss; require compositor p99 <= %sms\n' "$benchmark_warmup" "$benchmark_duration" "$benchmark_p99_ms"
        return 0
    fi
    local guest_tool=/run/zpu-runtime/chromium-cdp-video-test.py
    local transfer_tool=/workspace/.zpu-chrome-transfer/chromium-cdp-video-test.py
    local guest_pid=/run/zpu-runtime/chromium.pid
    local guest_log=/run/zpu-runtime/chromium.log
    local site safe_url result
    run smolvm machine cp "$repo/tools/chromium-cdp-video-test.py" "$machine:$transfer_tool" || return $?
    run smolvm machine exec --name "$machine" -- sh -ceu "
        test -f '$transfer_tool'
        install -m 700 '$transfer_tool' '$guest_tool'
        rm -f '$transfer_tool'
    " || return $?
    run smolvm machine exec --name "$machine" -- env -i \
        HOME=/root PATH=/usr/bin:/bin XDG_RUNTIME_DIR=/run/zpu-runtime DISPLAY=:0 XAUTHORITY=/run/zpu-xauth/Xauthority \
        VK_ICD_FILENAMES=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json \
        VK_DRIVER_FILES=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json \
        ZPU_LIMITED=physical-core-v1 ZPU_MAX_THREADS=2 ZPU_SELECTED_CPUS="$chrome_cpu_set" \
        ZPU_MOSAIC_CPU_SET="$chrome_cpu_set" ZPU_REFRESH_HZ="$refresh_hz" \
        ZPU_DIAGNOSE_FAILURES="$diagnose_failures" \
        ZPU_DIAGNOSE_PRESENT="${ZPU_DIAGNOSE_PRESENT:-0}" \
        ZPU_TRACE_FRAMES="${ZPU_TRACE_FRAMES:-0}" ZPU_TRACE_SKIP_FRAMES="${ZPU_TRACE_SKIP_FRAMES:-0}" \
        ZPU_TRACE_PATH="${ZPU_TRACE_PATH:-}" ZPU_DIAGNOSE_RENDER="$diagnose_render" \
        ZPU_DIAGNOSE_COMMAND_TIMING="${ZPU_DIAGNOSE_COMMAND_TIMING:-0}" \
        sh -c "rm -f '$guest_pid' '$guest_log'; '$chrome_bin' --no-sandbox --disable-gpu-sandbox --headless --enable-gpu --ignore-gpu-blocklist --use-angle=vulkan --ozone-platform=headless --use-vulkan=native --enable-features=Vulkan --disable-vulkan-fallback-to-gl-for-testing --disable-software-compositing-fallback --disable-background-timer-throttling --disable-backgrounding-occluded-windows --disable-renderer-backgrounding --run-all-compositor-stages-before-draw --window-size='${width},${height}' --remote-debugging-address=127.0.0.1 --remote-debugging-port=9222 --remote-allow-origins=http://localhost --user-data-dir=/run/zpu-runtime/chromium-profile about:blank >'$guest_log' 2>&1 & echo \$! >'$guest_pid'" || return $?
    # The CDP probe reports a bounded connection error if Chromium cannot
    # start; waiting here avoids turning normal process initialization into a
    # spurious measurement failure.
    run smolvm machine exec --name "$machine" -- sh -c '
        pid=$1 log=$2
        for i in $(seq 1 100); do
            test -s "$pid" && python3 -c "import socket; s=socket.create_connection((\"127.0.0.1\", 9222), .1); s.close()" 2>/dev/null && exit 0
            sleep .1
        done
        cat "$log" >&2
        exit 1
    ' sh "$guest_pid" "$guest_log" || return $?
    IFS=, read -r -a benchmark_url_list <<<"$benchmark_urls"
    for site in "${benchmark_url_list[@]}"; do
        [[ $site =~ ^https://(www\.)?(google\.com|bing\.com|youtube\.com)/?$ ]] || die "ZPU_CHROME_BENCHMARK_URLS only permits google.com, bing.com, and youtube.com: $site"
        safe_url=${site#https://}
        safe_url=${safe_url//\//_}
        result="/run/zpu-runtime/chromium-${safe_url}.json"
        printf 'zpu-chrome: measuring %s at %sx%s with ZPU on CPUs %s\n' "$site" "$width" "$height" "$chrome_cpu_set"
        local probe_status=0
        if run smolvm machine exec --name "$machine" -- \
            sh -c 'python3 "$1" --compositor --compositor-selector body --page-url "$2" --warmup "$3" --duration "$4" --max-p99-frame-ms "$5" > "$6"' \
            sh "$guest_tool" "$site" "$benchmark_warmup" "$benchmark_duration" "$benchmark_p99_ms" "$result"; then
            :
        else
            probe_status=$?
            # The CDP probe prints valid telemetry before it rejects a gate.
            # Preserve that evidence while the guest tmpfs still exists.
            run smolvm machine exec --name "$machine" -- cat "$result" || true
            run smolvm machine exec --name "$machine" -- tail -n 120 "$guest_log" >&2 || true
            return "$probe_status"
        fi
        run smolvm machine exec --name "$machine" -- cat "$result" || return $?
    done
}

stop_benchmark_chrome() {
    run smolvm machine exec --name "$machine" -- sh -c 'test -r /run/zpu-runtime/chromium.pid && kill $(cat /run/zpu-runtime/chromium.pid) 2>/dev/null || true'
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
    verify_guest_x11
    launch_chrome
}

benchmark() {
    require_programs
    ensure_machine
    ensure_display
    prepare_host_auth
    ensure_desktop
    ensure_zpu_staged
    ensure_chromium
    # Real-site measurements require temporary guest egress.  Restore the
    # normal isolated state even when the compositor probe fails.  SmolVM
    # changes persistent network state only while a machine is stopped.
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --net
    run smolvm machine start --name "$machine"
    prepare_guest_auth
    verify_guest_x11
    local status=0
    if benchmark_chrome; then :; else status=$?; fi
    stop_benchmark_chrome || { [[ $status -ne 0 ]] || status=$?; }
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --no-net
    return "$status"
}

usage() {
    printf 'usage: %s [start-desktop|reproduce|benchmark]\n' "${BASH_SOURCE[0]}" >&2
    exit 2
}

cmd=${1:-reproduce}
case $cmd in
    start-desktop) start_desktop_cmd ;;
    reproduce) reproduce ;;
    benchmark) benchmark ;;
    *) usage ;;
esac

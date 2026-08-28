#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

# Capture a real high-resolution ZPU vkcube session. Outputs are ignored evidence.
set -euo pipefail

root=$(git rev-parse --show-toplevel)
[[ "$PWD" == "$root" ]] || { echo "run from repository root" >&2; exit 2; }
for tool in Xvfb ffmpeg ffprobe vulkaninfo vkcube python3 taskset; do
    command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
[[ "${ZPU_FANOUT_WORKER:-}" == 0 ]] || { echo "capture requires tools/cpu-fanout.sh --worker 0" >&2; exit 2; }

profile=${ZPU_CAPTURE_PROFILE:-4k240}
seconds=${ZPU_CAPTURE_SECONDS:-30}
[[ "$seconds" =~ ^[1-9][0-9]*$ ]] || { echo "ZPU_CAPTURE_SECONDS must be a positive integer" >&2; exit 2; }
case "$profile" in
    4k240) width=3840; height=2160; hz=240 ;;
    8k120) width=7680; height=4320; hz=120 ;;
    *) echo "ZPU_CAPTURE_PROFILE must be 4k240 or 8k120" >&2; exit 2 ;;
esac

zig build install -Doptimize=ReleaseFast
manifest="$root/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json"
[[ -f "$manifest" ]] || { echo "build/install the ICD first" >&2; exit 2; }

out="$root/scratch_tmp/video"
mkdir -p "$out"
video="$out/zpu-vkcube-${profile}-${seconds}s.webm"
metadata="$out/zpu-vkcube-${profile}-${seconds}s.json"
display=":$((170 + ($$ % 70)))"
runtime=$(mktemp -d)
xpid=""; cpid=""
cleanup() {
    [[ -n "$cpid" ]] && kill "$cpid" 2>/dev/null || true
    [[ -n "$xpid" ]] && kill "$xpid" 2>/dev/null || true
    rm -rf "$runtime"
}
trap cleanup EXIT

read -r driver_a driver_b xvfb_cpu capture_cpu < <(python3 -c 'import os; a=sorted(os.sched_getaffinity(0)); assert len(a)>=4,"capture requires four physical-core representatives"; print(*a[:4])')
taskset -c "$xvfb_cpu" Xvfb "$display" -screen 0 "${width}x${height}x24" -nolisten tcp -fakescreenfps "$hz" >"$runtime/xvfb.log" 2>&1 & xpid=$!
for _ in $(seq 1 100); do
    [[ -S "/tmp/.X11-unix/X${display#:}" ]] && break
    sleep 0.1
done
[[ -S "/tmp/.X11-unix/X${display#:}" ]] || { echo "Xvfb did not start" >&2; exit 1; }

export DISPLAY="$display" XDG_RUNTIME_DIR="$runtime" VK_DRIVER_FILES="$manifest"
vulkaninfo --summary >"$runtime/vulkaninfo.txt"
grep -F 'ZPU Experimental CPU' "$runtime/vulkaninfo.txt" >/dev/null
grep -E 'deviceType[[:space:]]*=[[:space:]]*PHYSICAL_DEVICE_TYPE_CPU' "$runtime/vulkaninfo.txt" >/dev/null

driver_log="$runtime/vkcube.log"
taskset -c "$driver_a,$driver_b" env ZPU_MAX_THREADS=2 ZPU_REFRESH_HZ="$hz" \
    timeout "$((seconds + 10))s" vkcube --wsi xcb --width "$width" --height "$height" \
    --suppress_popups >"$driver_log" 2>&1 & cpid=$!
sleep 1
if ! kill -0 "$cpid" 2>/dev/null; then
    cat "$driver_log" >&2
    echo "vkcube exited before the capture began" >&2
    exit 1
fi

# Encode directly to VP9: lossless raw RGB at 4K/240 would exceed 170 GiB.
taskset -c "$capture_cpu" ffmpeg -y -hide_banner -loglevel warning \
    -f x11grab -framerate "$hz" -video_size "${width}x${height}" -i "$display.0" \
    -t "$seconds" -fps_mode passthrough -c:v libvpx-vp9 -deadline realtime \
    -cpu-used 8 -crf 35 -b:v 0 -pix_fmt yuv420p "$video"

kill "$cpid" 2>/dev/null || true
wait "$cpid" 2>/dev/null || true
cpid=""
ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,width,height,r_frame_rate \
    -of default=noprint_wrappers=1 "$video" >/dev/null

commit=$(git rev-parse HEAD)
utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
python3 - "$video" "$metadata" "$profile" "$width" "$height" "$hz" "$seconds" "$commit" "$utc" "$driver_a" "$driver_b" "$xvfb_cpu" "$capture_cpu" <<'PY'
import hashlib
import json
import pathlib
import sys

(video, metadata, profile, width, height, hz, seconds, commit, utc,
 driver_a, driver_b, xvfb_cpu, capture_cpu) = sys.argv[1:]
video_path = pathlib.Path(video)
metadata_path = pathlib.Path(metadata)
metadata_path.write_text(json.dumps({
    "schema_version": 1,
    "profile": profile,
    "width": int(width),
    "height": int(height),
    "target_hz": int(hz),
    "duration_seconds": int(seconds),
    "source_commit": commit,
    "utc": utc,
    "driver_cpus": [int(driver_a), int(driver_b)],
    "xvfb_cpu": int(xvfb_cpu),
    "capture_cpu": int(capture_cpu),
    "icd": "ZPU Experimental CPU",
    "device_type": "CPU",
    "environment": "synthetic Xvfb pacing evidence; two-core ReleaseFast driver; observer isolated; not physical scanout proof",
    "video": str(video_path.relative_to(pathlib.Path.cwd())),
    "size_bytes": video_path.stat().st_size,
    "sha256": hashlib.sha256(video_path.read_bytes()).hexdigest(),
    "capture_command": "tools/capture_vkcube_highres.sh",
    "workload_command": f"ZPU_REFRESH_HZ={hz} vkcube --wsi xcb --width {width} --height {height}",
}, indent=2) + "\n")
PY

printf 'video=%s\nmetadata=%s\n' "$video" "$metadata"

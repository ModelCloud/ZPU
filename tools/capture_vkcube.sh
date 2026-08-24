#!/usr/bin/env bash
# Capture the real ZPU vkcube XCB presentation path. Outputs are ignored evidence.
set -euo pipefail
root=$(git rev-parse --show-toplevel)
[[ "$PWD" == "$root" ]] || { echo "run from repository root" >&2; exit 2; }
for tool in Xvfb ffmpeg ffprobe vulkaninfo vkcube python3; do command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }; done
[[ "${ZPU_FANOUT_WORKER:-}" == 0 ]] || { echo "capture requires tools/cpu-fanout.sh --worker 0" >&2; exit 2; }

manifest="$root/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json"
[[ -f "$manifest" ]] || { echo "build/install the ICD first" >&2; exit 2; }
out="$root/scratch_tmp/video"; shots="$root/scratch_tmp/screenshots"
mkdir -p "$out" "$shots"
video="$out/zpu-vkcube-640x480-20s.webm"; metadata="$out/zpu-vkcube-640x480-20s.json"
display=":$((170 + ($$ % 70)))"
runtime=$(mktemp -d); log="$runtime/vkcube.log"
xpid=""; cpid=""
cleanup() { [[ -n "$cpid" ]] && kill "$cpid" 2>/dev/null || true; [[ -n "$xpid" ]] && kill "$xpid" 2>/dev/null || true; rm -rf "$runtime"; }
trap cleanup EXIT
Xvfb "$display" -screen 0 640x480x24 -nolisten tcp >"$runtime/xvfb.log" 2>&1 & xpid=$!
for _ in $(seq 1 50); do [[ -S "/tmp/.X11-unix/X${display#:}" ]] && break; sleep 0.1; done
export DISPLAY="$display" XDG_RUNTIME_DIR="$runtime" VK_DRIVER_FILES="$manifest"
vulkaninfo --summary >"$runtime/vulkaninfo.txt"
grep -F 'ZPU Experimental CPU' "$runtime/vulkaninfo.txt" >/dev/null
grep -E 'deviceType[[:space:]]*=[[:space:]]*PHYSICAL_DEVICE_TYPE_CPU' "$runtime/vulkaninfo.txt" >/dev/null
vkcube --wsi xcb --suppress_popups >"$log" 2>&1 & cpid=$!
sleep 1
ffmpeg -y -hide_banner -loglevel warning -f x11grab -framerate 30 -video_size 640x480 -i "$display.0" -t 20 -c:v libvpx-vp9 -deadline good -cpu-used 4 -pix_fmt yuv420p "$video"
kill "$cpid" 2>/dev/null || true; wait "$cpid" 2>/dev/null || true; cpid=""
for second in 5 10 15; do ffmpeg -y -v error -ss "$second" -i "$video" -frames:v 1 "$shots/vkcube-${second}s.png"; done
commit=${ZPU_SOURCE_COMMIT:-$(git rev-parse HEAD)}; utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid ZPU_SOURCE_COMMIT" >&2; exit 2; }
python3 - "$video" "$metadata" "$commit" "$utc" "$shots" <<'PY'
import hashlib,json,pathlib,sys
video,metadata,commit,utc,shots=map(pathlib.Path,sys.argv[1:])
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
images=[]
for p in sorted(shots.glob("vkcube-*s.png")): images.append({"path":str(p.relative_to(pathlib.Path.cwd())),"size_bytes":p.stat().st_size,"sha256":sha(p)})
data={"schema_version":1,"source_commit":str(commit),"utc":str(utc),"video":str(video.relative_to(pathlib.Path.cwd())),"size_bytes":video.stat().st_size,"sha256":sha(video),"screenshots":images,"icd":"ZPU Experimental CPU","device_type":"CPU"}
metadata.write_text(json.dumps(data,indent=2)+"\n")
PY
python3 tools/evidence.py video --video "$video" --metadata "$metadata"
printf 'capture_metadata=%s\n' "$metadata"

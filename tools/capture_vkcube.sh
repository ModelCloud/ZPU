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
video="$out/zpu-vkcube-800x600-120hz-20s.webm"; metadata="$out/zpu-vkcube-800x600-120hz-vp9-20s.json"
lossless="$out/zpu-vkcube-800x600-120hz-20s.nut"; cadence_metadata="$out/zpu-vkcube-800x600-120hz-raw-20s.json"
display=":$((170 + ($$ % 70)))"
runtime=$(mktemp -d); log="$runtime/vkcube.log"
xpid=""; cpid=""
cleanup() { [[ -n "$cpid" ]] && kill "$cpid" 2>/dev/null || true; [[ -n "$xpid" ]] && kill "$xpid" 2>/dev/null || true; rm -rf "$runtime"; }
trap cleanup EXIT
read -r chosen_cpu xvfb_cpu capture_cpu < <(python3 -c 'import os; a=sorted(os.sched_getaffinity(0)); assert len(a)>=3,"capture requires three physical-core representatives"; print(*a[:3])')
taskset -c "$xvfb_cpu" Xvfb "$display" -screen 0 800x600x24 -nolisten tcp >"$runtime/xvfb.log" 2>&1 & xpid=$!
for _ in $(seq 1 50); do [[ -S "/tmp/.X11-unix/X${display#:}" ]] && break; sleep 0.1; done
export DISPLAY="$display" XDG_RUNTIME_DIR="$runtime" VK_DRIVER_FILES="$manifest"
taskset -pc "$chosen_cpu" $$ >/dev/null
package=$(<"/sys/devices/system/cpu/cpu${chosen_cpu}/topology/physical_package_id")
core=$(<"/sys/devices/system/cpu/cpu${chosen_cpu}/topology/core_id")
affinity="cpu=${chosen_cpu};physical_core=${package}:${core};allowed=$(python3 -c 'import os; print(",".join(map(str,sorted(os.sched_getaffinity(0)))))')"
observer="xvfb_cpu=${xvfb_cpu};capture_cpu=${capture_cpu};driver_cpu=${chosen_cpu}"
vulkaninfo --summary >"$runtime/vulkaninfo.txt"
grep -F 'ZPU Experimental CPU' "$runtime/vulkaninfo.txt" >/dev/null
grep -E 'deviceType[[:space:]]*=[[:space:]]*PHYSICAL_DEVICE_TYPE_CPU' "$runtime/vulkaninfo.txt" >/dev/null
vkcube --wsi xcb --suppress_popups >"$log" 2>&1 & cpid=$!
sleep 1
taskset -c "$capture_cpu" ffmpeg -y -hide_banner -loglevel warning -f x11grab -framerate 120 -video_size 800x600 -i "$display.0" -frames:v 2400 -fps_mode passthrough -c:v rawvideo "$lossless"
commit=${ZPU_SOURCE_COMMIT:-$(git rev-parse HEAD)}; utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
context_switches=$(awk '$1=="nr_switches"{print int($3)}' "/proc/$cpid/sched")
migrations=$(awk '$1=="se.nr_migrations"{print int($3)}' "/proc/$cpid/sched")
read -r minor_faults major_faults < <(awk '{print $10,$12}' "/proc/$cpid/stat")
python3 tools/cadence.py --video "$lossless" --metadata "$cadence_metadata" --source-commit "$commit" --utc "$utc" --affinity "$affinity" --context-switches "$context_switches" --migrations "$migrations" --minor-faults "$minor_faults" --major-faults "$major_faults"
taskset -c "$capture_cpu" ffmpeg -y -hide_banner -loglevel warning -i "$lossless" -frames:v 2400 -fps_mode passthrough -c:v libvpx-vp9 -deadline good -cpu-used 4 -pix_fmt yuv420p "$video"
kill "$cpid" 2>/dev/null || true; wait "$cpid" 2>/dev/null || true; cpid=""
for second in 5 10 15; do ffmpeg -y -v error -ss "$second" -i "$video" -frames:v 1 "$shots/vkcube-${second}s.png"; done
[[ "$commit" =~ ^[0-9a-f]{40}$ ]] || { echo "invalid ZPU_SOURCE_COMMIT" >&2; exit 2; }
python3 - "$video" "$metadata" "$commit" "$utc" "$shots" "$affinity" "$observer" <<'PY'
import hashlib,json,pathlib,struct,sys
video,metadata,commit,utc,shots=map(pathlib.Path,sys.argv[1:6]); affinity=sys.argv[6]; observer=sys.argv[7]
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
images=[]
for p in sorted(shots.glob("vkcube-*s.png")):
 raw=p.read_bytes(); width,height=struct.unpack(">II",raw[16:24])
 images.append({"path":str(p.relative_to(pathlib.Path.cwd())),"width":width,"height":height,"size_bytes":p.stat().st_size,"sha256":sha(p),"capture_command":f"ffmpeg -ss {p.stem.rsplit('-',1)[-1]} -i {video} -frames:v 1 {p}","utc":str(utc),"source_commit":str(commit)})
data={"schema_version":3,"source_commit":str(commit),"utc":str(utc),"video":str(video.relative_to(pathlib.Path.cwd())),"size_bytes":video.stat().st_size,"sha256":sha(video),"screenshots":images,"icd":"ZPU Experimental CPU","device_type":"CPU","affinity":affinity,"observer_affinity":observer,"environment":"synthetic Xvfb pacing evidence; driver pinned to one core; observer overhead isolated; not physical scanout proof","capture_command":"ffmpeg x11grab 800x600 120 Hz 2400 truthful frames to rawvideo, then offline libvpx-vp9","workload_command":"ZPU_ONE_CORE=1 vkcube --wsi xcb --suppress_popups"}
metadata.write_text(json.dumps(data,indent=2)+"\n")
PY
python3 tools/evidence.py video --video "$video" --metadata "$metadata"
printf 'capture_metadata=%s\n' "$metadata"
printf 'cadence_metadata=%s\n' "$cadence_metadata"

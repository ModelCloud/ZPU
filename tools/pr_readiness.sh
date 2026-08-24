#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel); cd "$root"
raw2d=${ZPU_2D_REPORT:-scratch_tmp/benchmarks/2d.json}
raw3d=${ZPU_3D_REPORT:-scratch_tmp/benchmarks/3d.json}
metadata=${ZPU_VIDEO_METADATA:-scratch_tmp/video/zpu-vkcube-640x480-20s.json}
video=${ZPU_VIDEO:-scratch_tmp/video/zpu-vkcube-640x480-20s.webm}
[[ -f "$raw2d" && -f "$raw3d" && -f "$metadata" && -f "$video" ]] || { echo "PR readiness: missing raw benchmark/video evidence" >&2; exit 1; }
source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$raw3d")
utc=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["utc"])' "$raw3d")
python3 tools/evidence.py video --video "$video" --metadata "$metadata"
python3 tools/evidence.py progress --2d "$raw2d" --3d "$raw3d" --output progress_benchmarks.md --source-commit "$source" --utc "$utc"
for ignored in scratch_tmp/benchmarks/2d.json scratch_tmp/benchmarks/3d.json "$video" "$metadata" scratch_tmp/screenshots/vkcube-5s.png; do
  git check-ignore -q "$ignored"
done
if git ls-files scratch_tmp | grep -q .; then echo "PR readiness: tracked scratch evidence" >&2; exit 1; fi
now=$(date -u +%s); stamp=$(date -u -d "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["utc"])' "$metadata")" +%s)
(( now - stamp <= 86400 )) || { echo "PR readiness: capture older than 24 hours" >&2; exit 1; }
echo "PR_READINESS=PASS source=$source"

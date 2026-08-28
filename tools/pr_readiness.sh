#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail
root=$(git rev-parse --show-toplevel); cd "$root"
raw2d=${ZPU_2D_REPORT:-scratch_tmp/benchmarks/2d.json}
raw3d=${ZPU_3D_REPORT:-scratch_tmp/benchmarks/3d.json}
metadata=${ZPU_VIDEO_METADATA:-scratch_tmp/video/zpu-vkcube-800x600-120hz-vp9-20s.json}
video=${ZPU_VIDEO:-scratch_tmp/video/zpu-vkcube-800x600-120hz-20s.webm}
cadence=${ZPU_CADENCE_VIDEO:-scratch_tmp/video/zpu-vkcube-800x600-120hz-20s.nut}
cadence_metadata=${ZPU_CADENCE_METADATA:-scratch_tmp/video/zpu-vkcube-800x600-120hz-raw-20s.json}
[[ -f "$raw2d" && -f "$raw3d" && -f "$metadata" && -f "$video" && -f "$cadence" && -f "$cadence_metadata" ]] || { echo "PR readiness: missing raw benchmark/video/cadence evidence" >&2; exit 1; }
source=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$raw3d")
utc=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["utc"])' "$raw3d")
for bound in "$metadata" "$cadence_metadata"; do
  [[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source_commit"])' "$bound")" == "$source" ]] || { echo "PR readiness: evidence source commit mismatch: $bound" >&2; exit 1; }
done
python3 tools/evidence.py video --video "$video" --metadata "$metadata"
python3 tools/cadence.py --validate --video "$cadence" --metadata "$cadence_metadata"
python3 tools/evidence.py progress --2d "$raw2d" --3d "$raw3d" --cadence "$cadence_metadata" --output progress_benchmarks.md --source-commit "$source" --utc "$utc"
for ignored in scratch_tmp/benchmarks/2d.json scratch_tmp/benchmarks/3d.json "$video" "$metadata" "$cadence" "$cadence_metadata" scratch_tmp/screenshots/vkcube-5s.png; do
  git check-ignore -q "$ignored"
done
if git ls-files scratch_tmp | grep -q .; then echo "PR readiness: tracked scratch evidence" >&2; exit 1; fi
now=$(date -u +%s); stamp=$(date -u -d "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["utc"])' "$metadata")" +%s)
(( now - stamp <= 86400 )) || { echo "PR readiness: capture older than 24 hours" >&2; exit 1; }
echo "PR_READINESS=PASS source=$source"

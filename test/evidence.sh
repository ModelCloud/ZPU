#!/usr/bin/env bash
set -euo pipefail
bench2=${1:?2D benchmark}; bench3=${2:?3D benchmark}
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
sha=$(git rev-parse HEAD); utc=2026-01-02T03:04:05Z
# Evidence is a repository-local build/test feature. Guard its stable entry
# points and prevent an accidental dependency on GitHub workflow configuration.
grep -F 'b.step("benchmark-3d"' build.zig >/dev/null
grep -F 'b.step("pr-readiness"' build.zig >/dev/null
grep -F '`ffmpeg` and `ffprobe`' docs/pr-readiness.md >/dev/null
if rg -n '\.github/workflows|GITHUB_TOKEN|workflow scope' tools/evidence.py tools/capture_vkcube.sh tools/pr_readiness.sh docs/pr-readiness.md; then
  echo "evidence feature depends on GitHub workflow configuration" >&2
  exit 1
fi
"$bench2" --smoke --json --source-commit "$sha" --utc "$utc" --capture "$tmp/2d.json" >/dev/null
"$bench3" --smoke --json --source-commit "$sha" --utc "$utc" --capture "$tmp/3d.json" >/dev/null
python3 - "$tmp/2d.json" "$tmp/3d.json" <<'PY'
import json,sys
for p in sys.argv[1:]:
 r=json.load(open(p)); r["sample_count"]=15 if "metrics" in r else 30
 if "metric" in r: r["warmup_iterations"]=5
 json.dump(r,open(p,"w"))
PY
python3 tools/evidence.py progress --2d "$tmp/2d.json" --3d "$tmp/3d.json" --output "$tmp/progress.md" --source-commit "$sha" --utc "$utc" --evidence-commit fixture --skip-git-binding --write
python3 tools/evidence.py progress --2d "$tmp/2d.json" --3d "$tmp/3d.json" --output "$tmp/progress.md" --source-commit "$sha" --utc "$utc" --evidence-commit fixture --skip-git-binding
for mutation in checksum counters schema sampling commit utc; do
 python3 - "$tmp/3d.json" "$tmp/bad.json" "$mutation" <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); m=sys.argv[3]
if m=="checksum": r["metric"]["checksum_hex"]="0"*16
elif m=="counters": r["metric"]["counters_per_frame"]["color_writes"]+=1
elif m=="schema": r["schema_version"]+=1
elif m=="sampling": r["sample_count"]-=1
elif m=="commit": r["source_commit"]="0"*40
else: r["utc"]="stale"
json.dump(r,open(sys.argv[2],"w"))
PY
 if python3 tools/evidence.py progress --2d "$tmp/2d.json" --3d "$tmp/bad.json" --output "$tmp/progress.md" --source-commit "$sha" --utc "$utc" --evidence-commit fixture --skip-git-binding 2>/dev/null; then echo "accepted $mutation mutant"; exit 1; fi
done
for mutation in duplicate stale order unit; do
 cp "$tmp/progress.md" "$tmp/bad.md"
 case "$mutation" in
 duplicate) sed -n '9p' "$tmp/progress.md" >>"$tmp/bad.md";;
 stale) sed -i 's/2026-01-02/2025-01-02/' "$tmp/bad.md";;
 order) sed -i '9{h;d};10{G}' "$tmp/bad.md";;
 unit) sed -i '0,/MPix\/s/s//bananas/' "$tmp/bad.md";;
 esac
 if python3 tools/evidence.py progress --2d "$tmp/2d.json" --3d "$tmp/3d.json" --output "$tmp/bad.md" --source-commit "$sha" --utc "$utc" --evidence-commit fixture --skip-git-binding 2>/dev/null; then echo "accepted $mutation table"; exit 1; fi
done
printf x >"$tmp/video.webm"; printf '{' >"$tmp/meta.json"
if python3 tools/evidence.py video --video "$tmp/video.webm" --metadata "$tmp/meta.json" 2>/dev/null; then echo accepted malformed video metadata; exit 1; fi
echo "evidence validators: correctness, malformed input, mutants, completeness/order/units/checksums/duplicates/staleness: PASS"

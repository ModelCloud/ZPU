#!/usr/bin/env bash
set -euo pipefail
root=$(git rev-parse --show-toplevel)
benchmark=${1:?benchmark executable required}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
sha=$(git rev-parse HEAD)
json="$tmp/report.json"
history="$tmp/history.md"
utc=2026-01-02T03:04:05Z
tools/limited-cpus.sh "$benchmark" --smoke --json --source-commit "$sha" --utc "$utc" --capture "$json" >/dev/null
python3 tools/benchmark_history.py "$json" "$history" --commit "$sha" --comparison-result passed --observed-threads 8
grep -F "### $sha" "$history" >/dev/null
if python3 tools/benchmark_history.py "$json" "$history" --commit "$sha" --observed-threads 8 2>/dev/null; then exit 1; fi
if python3 tools/benchmark_history.py "$json" "$history" --commit "${sha:0:12}" --observed-threads 8 2>/dev/null; then exit 1; fi
if python3 tools/benchmark_history.py "$json" "$history" --commit "0000000000000000000000000000000000000000" --observed-threads 8 2>/dev/null; then exit 1; fi
python3 - "$json" "$tmp/bad.json" <<'PY'
import json, sys
r=json.load(open(sys.argv[1])); r["workload_id"]="forged"; json.dump(r,open(sys.argv[2],"w"))
PY
if python3 tools/benchmark_history.py "$tmp/bad.json" "$tmp/bad-history.md" --commit "$sha" --observed-threads 8 2>/dev/null; then exit 1; fi
python3 - "$json" "$tmp/bad-tolerance.json" <<'PY'
import json, sys
r=json.load(open(sys.argv[1])); r["rate_tolerance_fraction"]=0.99; json.dump(r,open(sys.argv[2],"w"))
PY
if python3 tools/benchmark_history.py "$tmp/bad-tolerance.json" "$tmp/bad-history.md" --commit "$sha" --observed-threads 8 2>/dev/null; then exit 1; fi
touch "$root/.history-dirty-sentinel"
if python3 tools/benchmark_history.py "$json" "$tmp/dirty.md" --commit "$sha" --observed-threads 8 2>/dev/null; then rm -f "$root/.history-dirty-sentinel"; exit 1; fi
rm -f "$root/.history-dirty-sentinel"
python3 tools/benchmark_history.py "" "$history" --validate-history
python3 - "$history" "$tmp/bad-history.md" <<'PY'
import sys
t=open(sys.argv[1]).read().replace("Trusted CPU:", "Trusted host:")
open(sys.argv[2], "w").write(t)
PY
if python3 tools/benchmark_history.py "" "$tmp/bad-history.md" --validate-history 2>/dev/null; then exit 1; fi
echo "benchmark history formatter tests passed"

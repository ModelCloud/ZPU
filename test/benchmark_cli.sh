#!/usr/bin/env bash
set -euo pipefail
benchmark=$1
kcov_dir=${2:-}
source_path=${3:-}
unit_tests=${4:-}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
run_id=0
run_benchmark() {
  if [[ -n "$kcov_dir" ]]; then
    run_id=$((run_id+1))
    ZPU_MAX_THREADS=1 tools/limited-cpus.sh kcov --include-path="$source_path" "$kcov_dir/run-$run_id" "$benchmark" "$@"
  else
    "$benchmark" "$@"
  fi
}

run_benchmark --smoke --capture "$tmp/base.json" --compare "$tmp/base.json" --json >"$tmp/current.json"
run_benchmark --smoke >/dev/null
printf '{' >"$tmp/malformed.json"
if run_benchmark --smoke --compare "$tmp/malformed.json" >/dev/null 2>"$tmp/error"; then exit 1; fi
grep -F 'MalformedBaseline' "$tmp/error" >/dev/null

python3 - "$tmp/base.json" "$tmp" <<'PY'
import json,sys
p,out=sys.argv[1:]
r=json.load(open(p))
def emit(name, mutate):
    x=json.loads(json.dumps(r)); mutate(x)
    with open(out+'/'+name+'.json','w') as f: json.dump(x,f)
emit('fingerprint',lambda x:x['fingerprint'].__setitem__('cpu_model','forged'))
emit('missing',lambda x:x['metrics'].pop())
emit('duplicate',lambda x:x['metrics'].__setitem__(1,x['metrics'][0]))
PY
for kind in fingerprint missing duplicate; do
  if run_benchmark --smoke --compare "$tmp/$kind.json" >/dev/null 2>"$tmp/$kind.err"; then exit 1; fi
done
grep -F 'IncompatibleFingerprint' "$tmp/fingerprint.err" >/dev/null
grep -F 'MetricSetMismatch' "$tmp/missing.err" >/dev/null
grep -F 'MetricSetMismatch' "$tmp/duplicate.err" >/dev/null
if run_benchmark --smoke --capture "$tmp/no-parent/result.json" >/dev/null 2>"$tmp/path.err"; then exit 1; fi
if run_benchmark --smoke --capture /proc/1/zpu-forbidden.json >/dev/null 2>"$tmp/permission.err"; then exit 1; fi
if [[ -z "$kcov_dir" ]]; then
  if ZPU_SELECTED_CPUS=999999 ZPU_CPU_MODEL=forged ZPU_TOPOLOGY=forged run_benchmark --smoke --compare "$tmp/base.json" >/dev/null 2>"$tmp/forged.err"; then exit 1; fi
  grep -E 'UntrustedAffinityFingerprint|MissingTrustedAffinity' "$tmp/forged.err" >/dev/null
fi
if run_benchmark --capture >/dev/null 2>"$tmp/missing-arg.err"; then exit 1; fi
if run_benchmark --unknown >/dev/null 2>"$tmp/unknown-arg.err"; then exit 1; fi
if env -u ZPU_SELECTED_CPUS "$benchmark" --smoke >/dev/null 2>"$tmp/missing-env.err"; then exit 1; fi
if [[ -n "$kcov_dir" ]]; then
  ZPU_MAX_THREADS=1 tools/limited-cpus.sh kcov --include-path="$source_path" "$kcov_dir/run-unit" "$unit_tests" >/dev/null
  run_dirs=("$kcov_dir"/run-*)
  inputs=()
  for candidate in "$kcov_dir"/run-*/*; do [[ -d "$candidate" ]] && inputs+=("$candidate"); done
  (( ${#inputs[@]} > 0 )) || exit 1
  kcov --merge "$kcov_dir/merged" "${inputs[@]}" >/dev/null
  rm -rf "${run_dirs[@]}"
fi
echo "benchmark CLI: capture/compare, malformed, fingerprint, duplicate/missing, paths, forged environment: PASS"

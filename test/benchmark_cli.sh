#!/usr/bin/env bash
set -euo pipefail
benchmark=$1
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

"$benchmark" --smoke --capture "$tmp/base.json" --compare "$tmp/base.json" --json >"$tmp/current.json"
printf '{' >"$tmp/malformed.json"
if "$benchmark" --smoke --compare "$tmp/malformed.json" >/dev/null 2>"$tmp/error"; then exit 1; fi
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
  if "$benchmark" --smoke --compare "$tmp/$kind.json" >/dev/null 2>"$tmp/$kind.err"; then exit 1; fi
done
grep -F 'IncompatibleFingerprint' "$tmp/fingerprint.err" >/dev/null
grep -F 'MetricSetMismatch' "$tmp/missing.err" >/dev/null
grep -F 'MetricSetMismatch' "$tmp/duplicate.err" >/dev/null
if "$benchmark" --smoke --capture "$tmp/no-parent/result.json" >/dev/null 2>"$tmp/path.err"; then exit 1; fi
if "$benchmark" --smoke --capture /proc/1/zpu-forbidden.json >/dev/null 2>"$tmp/permission.err"; then exit 1; fi
if ZPU_SELECTED_CPUS=999999 ZPU_CPU_MODEL=forged ZPU_TOPOLOGY=forged "$benchmark" --smoke --compare "$tmp/base.json" >/dev/null 2>"$tmp/forged.err"; then exit 1; fi
grep -E 'UntrustedAffinityFingerprint|MissingTrustedAffinity' "$tmp/forged.err" >/dev/null
echo "benchmark CLI: capture/compare, malformed, fingerprint, duplicate/missing, paths, forged environment: PASS"

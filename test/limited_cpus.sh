#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mapfile -t cpu < <(taskset -pc $$ | sed 's/.*: //' | awk -F, '{
  for (i = 1; i <= NF; i++) {
    split($i, r, "-")
    for (c = r[1]; c <= (r[2] == "" ? r[1] : r[2]); c++) print c
  }
}' | sort -n | head -10)
((${#cpu[@]} >= 10)) || { echo "limited-cpus test needs at least 10 CPUs in its inherited affinity" >&2; exit 1; }
cat >"$tmp/topology" <<EOF
# CPU,Core,Socket,Online
${cpu[0]},0,0,Y
${cpu[1]},0,0,Y
${cpu[2]},1,0,Y
${cpu[3]},1,0,N
${cpu[4]},2,1,Y
${cpu[5]},3,1,Y
${cpu[6]},4,1,Y
${cpu[7]},5,1,Y
${cpu[8]},6,1,Y
${cpu[9]},7,1,Y
EOF
allowed=$(IFS=,; echo "${cpu[*]}")
expected="${cpu[0]},${cpu[2]},${cpu[4]},${cpu[5]},${cpu[6]},${cpu[7]},${cpu[8]},${cpu[9]}"
out=$(ZPU_TEST_ALLOWED_CPUS="$allowed" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
test "$out" = "$expected|8"
pair="${cpu[2]},${cpu[4]}"
out=$(ZPU_TEST_ALLOWED_CPUS="$pair" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
test "$out" = "$pair|2"
out=$(ZPU_CPU_MODEL=forged ZPU_TOPOLOGY=forged ZPU_TEST_ALLOWED_CPUS="$pair" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s|%s" "$ZPU_CPU_MODEL" "$ZPU_TOPOLOGY" "$ZPU_SELECTED_CPUS"')
test "$out" != "forged|forged|$pair"
case "$out" in *"|0:1@${cpu[2]};1:2@${cpu[4]}|$pair") :;; *) exit 1;; esac
if ZPU_TEST_ALLOWED_CPUS="${cpu[3]}" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
if ZPU_MAX_THREADS=9 ZPU_TEST_ALLOWED_CPUS="${cpu[2]}" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
printf '%s,1,0,Y,extra\n' "${cpu[2]}" >"$tmp/topology-extra"
if ZPU_TEST_ALLOWED_CPUS="${cpu[2]}" ZPU_TEST_LSCPU_FILE="$tmp/topology-extra" "$root/tools/limited-cpus.sh" true 2>"$tmp/topology-extra.err"; then exit 1; fi
grep -F 'topology rows must contain exactly CPU,CORE,SOCKET,ONLINE' "$tmp/topology-extra.err" >/dev/null
if "$root/tools/require-limited.sh" 2>"$tmp/refusal"; then exit 1; fi
grep -F 'run it through tools/limited-cpus.sh' "$tmp/refusal" >/dev/null
echo "limited-cpus: exact topology fields, unique physical cores, range/list subset, SMT, trusted fingerprint, <=8 cap: PASS"

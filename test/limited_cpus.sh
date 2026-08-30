#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

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
if ((${#cpu[@]} < 5)); then
  # The full fixture below needs five logical CPUs to exercise SMT, an offline
  # sibling, and a second socket.  Keep a useful live check on constrained
  # CI/container runners, while leaving the five-CPU topology assertions to
  # hosts that can actually provide that fixture shape.
  cat >"$tmp/topology" <<EOF
# CPU,Core,Socket,Online
${cpu[0]},0,0,Y
EOF
  out=$(ZPU_TEST_ALLOWED_CPUS="${cpu[0]}" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
  test "$out" = "${cpu[0]}|1"
  echo "limited-cpus: constrained affinity live one-core check PASS (five-CPU topology fixture skipped)"
  exit 0
fi
cat >"$tmp/topology" <<EOF
# CPU,Core,Socket,Online
${cpu[0]},0,0,Y
${cpu[1]},0,0,Y
${cpu[2]},1,0,Y
${cpu[3]},1,0,N
${cpu[4]},2,1,Y
EOF
for ((i = 5; i < ${#cpu[@]}; i++)); do
  printf '%s,%s,1,Y\n' "${cpu[i]}" "$((i - 2))" >>"$tmp/topology"
done
allowed=$(IFS=,; echo "${cpu[*]}")
expected=("${cpu[0]}" "${cpu[2]}" "${cpu[@]:4}")
expected=$(IFS=,; echo "${expected[*]}")
expected_count=$(awk -F, '{print NF}' <<<"$expected")
out=$(ZPU_TEST_ALLOWED_CPUS="$allowed" ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
test "$out" = "$expected|$expected_count"
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
if env -u ZPU_LIMITED -u ZPU_SELECTED_CPUS -u ZPU_MAX_THREADS \
  "$root/tools/require-limited.sh" 2>"$tmp/refusal"; then exit 1; fi
grep -F 'run it through tools/limited-cpus.sh' "$tmp/refusal" >/dev/null
echo "limited-cpus: exact topology fields, unique physical cores, range/list subset, SMT, trusted fingerprint, <=8 cap: PASS"

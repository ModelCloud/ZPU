#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/topology" <<'EOF'
# CPU,Core,Socket,Online
0,0,0,Y
1,0,0,Y
2,1,0,Y
3,1,0,N
8,2,1,Y
9,3,1,Y
10,4,1,Y
11,5,1,Y
12,6,1,Y
13,7,1,Y
14,8,1,Y
15,9,1,Y
EOF
out=$(ZPU_TEST_ALLOWED_CPUS=1-2,8-15 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
test "$out" = "1,2,8,9,10,11,12,13|8"
out=$(ZPU_TEST_ALLOWED_CPUS=2,8 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS"')
test "$out" = "2,8|2"
out=$(ZPU_TEST_ALLOWED_CPUS=1-2,8-15 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c '
  pids=""; i=0
  while [ "$i" -lt "$ZPU_MAX_THREADS" ]; do sleep 2 & pids="$pids $!"; i=$((i+1)); done
  observed_total=$(ps -o pid= --ppid $$ | wc -l | tr -d " ")
  observed=$((observed_total-1))
  for pid in $pids; do kill "$pid"; done
  wait 2>/dev/null || true
  printf "%s|%s" "$observed" "$ZPU_MAX_THREADS"
')
test "$out" = "8|8"
if ZPU_TEST_ALLOWED_CPUS=3 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
if ZPU_MAX_THREADS=9 ZPU_TEST_ALLOWED_CPUS=2 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
echo "limited-cpus: unique physical cores, allowed subset, <=8 cap: PASS"

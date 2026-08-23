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
out=$(ZPU_CPU_MODEL=forged ZPU_TOPOLOGY=forged ZPU_TEST_ALLOWED_CPUS=2,8 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" sh -c 'printf "%s|%s|%s" "$ZPU_CPU_MODEL" "$ZPU_TOPOLOGY" "$ZPU_SELECTED_CPUS"')
test "$out" != "forged|forged|2,8"
case "$out" in *"|0:1@2;1:2@8|2,8") :;; *) exit 1;; esac
if ZPU_TEST_ALLOWED_CPUS=3 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
if ZPU_MAX_THREADS=9 ZPU_TEST_ALLOWED_CPUS=2 ZPU_TEST_LSCPU_FILE="$tmp/topology" "$root/tools/limited-cpus.sh" true 2>/dev/null; then exit 1; fi
if "$root/tools/require-limited.sh" 2>"$tmp/refusal"; then exit 1; fi
grep -F 'run it through tools/limited-cpus.sh' "$tmp/refusal" >/dev/null
echo "limited-cpus: unique physical cores, range/list subset, SMT, trusted fingerprint, <=8 cap: PASS"

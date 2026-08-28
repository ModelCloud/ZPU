#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

# Prove where tools/limited-cpus.sh sources its ZPU_TOPOLOGY fingerprint:
# a live run must report each selected CPU's kernel physical_package_id and
# core_id from sysfs (what src/benchmark_main.zig reads back), while a run
# driven by ZPU_TEST_LSCPU_FILE must keep the fixture's socket/core values.
#
# Every command runs inside the affinity this script inherited, so nothing here
# escapes the limiter that invoked it.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
limiter="$root/tools/limited-cpus.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2" >&2
    failures=$((failures + 1))
  fi
}

expand() {
  awk -v list="$1" 'BEGIN {
    n = split(list, item, ",")
    for (i = 1; i <= n; i++) {
      p = index(item[i], "-")
      if (p) { for (c = substr(item[i], 1, p - 1) + 0; c <= substr(item[i], p + 1) + 0; c++) print c }
      else print item[i] + 0
    }
  }'
}

# --- live run: kernel ids from sysfs ----------------------------------------

live=$(env -u ZPU_MAX_THREADS "$limiter" sh -c 'printf "%s\t%s" "$ZPU_SELECTED_CPUS" "$ZPU_TOPOLOGY"' 2>/dev/null)
selected=${live%%$'\t'*}
live_topology=${live#*$'\t'}

sysfs_expected=""
lscpu_form=""
IFS=, read -r -a selected_cpus <<<"$selected"
for cpu in "${selected_cpus[@]}"; do
  package=$(<"/sys/devices/system/cpu/cpu$cpu/topology/physical_package_id")
  core=$(<"/sys/devices/system/cpu/cpu$cpu/topology/core_id")
  sysfs_expected+="${sysfs_expected:+;}$package:$core@$cpu"
  row=$(lscpu -p=CPU,CORE,SOCKET,ONLINE | awk -F, -v want="$cpu" '!/^#/ && $1 + 0 == want { print $3 ":" $2 "@" $1; exit }')
  lscpu_form+="${lscpu_form:+;}$row"
done

check 'a live run fingerprints each selected CPU as sysfs package:core@cpu' \
  "$live_topology" "$sysfs_expected"

# lscpu renumbers CORE densely, so on a host where the two encodings differ the
# live fingerprint must follow the kernel. Where they coincide there is nothing
# to distinguish, and saying so is more honest than a vacuous assertion.
if [[ "$sysfs_expected" == "$lscpu_form" ]]; then
  printf 'note this host encodes lscpu CORE identically to the kernel core_id; the two sources are indistinguishable here\n'
else
  check 'a live run does not use the dense lscpu CORE renumbering' \
    "$([[ "$live_topology" == "$lscpu_form" ]] && echo used-lscpu || echo used-sysfs)" 'used-sysfs'
fi

# --- fixture run: file-derived socket/core ----------------------------------

# Fixture CPU ids are drawn from this process's own affinity so the limiter's
# taskset call stays inside the allocation; the socket/core values are ones the
# kernel can never report, which is what makes the source unambiguous.
mapfile -t allowed < <(expand "$(taskset -pc $$ | sed 's/.*: //')" | sort -n)
first=${allowed[0]}
cat >"$tmp/topology-one" <<EOF
# CPU,Core,Socket,Online
$first,900,7,Y
EOF
fixture_one=$(env -u ZPU_MAX_THREADS ZPU_TEST_ALLOWED_CPUS="$first" \
  ZPU_TEST_LSCPU_FILE="$tmp/topology-one" "$limiter" \
  sh -c 'printf "%s|%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS" "$ZPU_TOPOLOGY"' 2>/dev/null)
check 'a one-CPU fixture run must keep file-derived socket/core values' \
  "$fixture_one" "$first|1|7:900@$first"

if ((${#allowed[@]} >= 2)); then
  second=${allowed[1]}
  cat >"$tmp/topology" <<EOF
# CPU,Core,Socket,Online
$first,900,7,Y
$second,901,7,Y
EOF
  fixture=$(env -u ZPU_MAX_THREADS ZPU_TEST_ALLOWED_CPUS="$first,$second" \
    ZPU_TEST_LSCPU_FILE="$tmp/topology" "$limiter" \
    sh -c 'printf "%s|%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS" "$ZPU_TOPOLOGY"' 2>/dev/null)
  check 'a fixture run keeps the file socket:core values instead of sysfs' \
    "$fixture" "$first,$second|2|7:900@$first;7:901@$second"

  # Same fixture CPUs declared as one physical core: the limiter must collapse
  # them and the fingerprint must still come from the file.
  cat >"$tmp/topology-smt" <<EOF
# CPU,Core,Socket,Online
$first,902,7,Y
$second,902,7,Y
EOF
  smt=$(env -u ZPU_MAX_THREADS ZPU_TEST_ALLOWED_CPUS="$first,$second" \
    ZPU_TEST_LSCPU_FILE="$tmp/topology-smt" "$limiter" \
    sh -c 'printf "%s|%s|%s" "$ZPU_SELECTED_CPUS" "$ZPU_MAX_THREADS" "$ZPU_TOPOLOGY"' 2>/dev/null)
  check 'a fixture run collapses declared SMT siblings to one core' \
    "$smt" "$first|1|7:902@$first"
else
  printf 'note supplemental two-CPU SMT-collapse proof unavailable in this one-CPU affinity\n'
fi

if ((failures)); then
  printf 'limited-cpus topology: %s check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "limited-cpus topology: live sysfs package/core fingerprint, fixture file-derived topology, SMT collapse: PASS"

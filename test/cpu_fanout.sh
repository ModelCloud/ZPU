#!/usr/bin/env bash
# Deterministic, fixture-driven proof of the four-worker CPU fanout partition.
# Every case runs the planner or a --dry-run launch, so no workload escapes the
# limited-cpus gate that invoked this script.
set -euo pipefail

# Fixtures are the only topology source; never inherit a caller's seams.
unset ZPU_FANOUT_ALLOWED_CPUS ZPU_FANOUT_CPUSET_FILE ZPU_FANOUT_LSCPU_FILE ZPU_FANOUT_TEST_GROUPS

root=$(cd "$(dirname "$0")/.." && pwd)
fanout="$root/tools/cpu-fanout.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failures=0

# Non-contiguous CPU ids, two sockets, offline CPUs, and SMT siblings whose
# logical ids are far away from their partner's.
cat >"$tmp/topology" <<'EOF'
# The following is the parsable format, which can be fed to other
# programs. Each different item in every column has an unique ID
# CPU,Core,Socket,Online
3,0,0,Y
5,1,0,Y
9,2,0,Y
11,3,0,Y
17,4,0,Y
21,5,0,Y
25,6,0,Y
29,7,0,Y
33,8,0,N
103,0,0,Y
105,1,0,Y
200,0,1,Y
202,1,1,Y
204,2,1,Y
206,3,1,Y
208,4,1,Y
210,5,1,N
300,0,1,Y
EOF

# 40 physical cores so floor(40/4) exceeds the limited-cpus safety thread cap.
{
  echo '# CPU,Core,Socket,Online'
  for core in $(seq 0 39); do echo "$((core * 2)),$core,0,Y"; done
} >"$tmp/topology-wide"

plan() { # plan <allowed> <cpuset-file> <topology-file>
  ZPU_FANOUT_ALLOWED_CPUS="$1" ZPU_FANOUT_CPUSET_FILE="$2" ZPU_FANOUT_LSCPU_FILE="$3" \
    "$fanout" --plan
}

field() { awk -F= -v key="$2" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' <<<"$1"; }

check() { # check <label> <actual> <expected>
  if [[ "$2" == "$3" ]]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n  expected: %s\n  actual:   %s\n' "$1" "$3" "$2" >&2
    failures=$((failures + 1))
  fi
}

refuses() { # refuses <label> <expected-exit> <expected-substring> -- command...
  local label="$1" want_code="$2" want_text="$3"
  shift 4
  local out code=0
  out=$("$@" 2>&1) || code=$?
  if [[ "$code" == "$want_code" && "$out" == *"$want_text"* ]]; then
    printf 'ok   %s\n' "$label"
  else
    printf 'FAIL %s\n  expected exit %s containing: %s\n  actual exit %s: %s\n' \
      "$label" "$want_code" "$want_text" "$code" "$out" >&2
    failures=$((failures + 1))
  fi
}

# --- canonical partition ----------------------------------------------------

a=$(plan 0-400 /nonexistent "$tmp/topology")
check 'offline CPUs and duplicate SMT threads leave 13 usable physical cores' \
  "$(field "$a" physical_cores)" 13
check 'effective set keeps only online, non-contiguous CPU ids' \
  "$(field "$a" allowed_cpus)" '3,5,9,11,17,21,25,29,103,105,200,202,204,206,208,300'
check 'exactly four workers' "$(field "$a" workers)" 4
check 'floor(13/4) cores per worker' "$(field "$a" cores_per_worker)" 3
check 'worker 0 group' "$(field "$a" worker0)" '3,5,9'
check 'worker 1 group' "$(field "$a" worker1)" '11,17,21'
check 'worker 2 group spans the socket boundary in topology order' "$(field "$a" worker2)" '25,29,200'
check 'worker 3 group' "$(field "$a" worker3)" '202,204,206'
check 'surplus core and duplicate SMT threads stay unused' \
  "$(field "$a" unused)" '103,105,208,300'
check 'thread cap matches the worker group width' "$(field "$a" thread_cap)" 3

# Four equal groups, pairwise disjoint, one logical CPU per physical core.
all_cpus=""
all_cores=""
for w in 0 1 2 3; do
  group=$(field "$a" "worker$w")
  cores=$(field "$a" "worker${w}_cores")
  check "worker $w holds cores_per_worker CPUs" "$(awk -F, '{print NF}' <<<"$group")" 3
  check "worker $w reports one physical core per CPU" "$(awk -F, '{print NF}' <<<"$cores")" 3
  all_cpus+="${all_cpus:+,}$group"
  all_cores+="${all_cores:+,}$cores"
done
uniq_cpus=$(tr ',' '\n' <<<"$all_cpus" | sort -u | wc -l)
check 'worker CPU groups are pairwise disjoint' "$uniq_cpus" 12
uniq_cores=$(tr ',' '\n' <<<"$all_cores" | sort -u | wc -l)
check 'no physical core is split across workers (SMT siblings stay together)' "$uniq_cores" 12
union=$(tr ',' '\n' <<<"$all_cpus,$(field "$a" unused)" | sort -n -u | paste -sd, -)
check 'assigned plus unused CPUs reconstruct the effective cpuset' \
  "$union" "$(field "$a" allowed_cpus)"

# --- restricted cpusets -----------------------------------------------------

printf '3,5,9,11,17,21,25,29,103\n' >"$tmp/cpuset"
b=$(plan 3-30 "$tmp/cpuset" "$tmp/topology")
check 'LXD/cgroup cpuset intersects the process affinity' \
  "$(field "$b" allowed_cpus)" '3,5,9,11,17,21,25,29'
check 'restricted cpuset yields 8 physical cores' "$(field "$b" physical_cores)" 8
check 'restricted cpuset yields two cores per worker' "$(field "$b" cores_per_worker)" 2
check 'restricted worker 0' "$(field "$b" worker0)" '3,5'
check 'restricted worker 3' "$(field "$b" worker3)" '25,29'
check 'restricted partition leaves nothing unused' "$(field "$b" unused)" ''

printf '  200-208\n' >"$tmp/cpuset-socket1"
c=$(plan 0-400 "$tmp/cpuset-socket1" "$tmp/topology")
check 'cgroup cpuset ranges and whitespace parse' \
  "$(field "$c" allowed_cpus)" '200,202,204,206,208'
check 'socket-1-only cpuset yields one core per worker' "$(field "$c" cores_per_worker)" 1
check 'socket-1-only surplus core is unused' "$(field "$c" unused)" '208'

# --- exact boundary ---------------------------------------------------------

d=$(plan 3,5,9,11 /nonexistent "$tmp/topology")
check 'four physical cores is the supported minimum' "$(field "$d" cores_per_worker)" 1
check 'minimum partition worker 3' "$(field "$d" worker3)" '11'

# --- safety cap -------------------------------------------------------------

e=$(plan 0-400 /nonexistent "$tmp/topology-wide" 2>/dev/null)
check 'wide host keeps floor(40/4) cores per worker' "$(field "$e" cores_per_worker)" 10
check 'thread cap never exceeds the limited-cpus safety cap of 8' "$(field "$e" thread_cap)" 8

# --- launch contract --------------------------------------------------------

launch=$(ZPU_FANOUT_ALLOWED_CPUS=0-400 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --worker 2 --dry-run -- zig build test)
check 'worker launch pins the group and matches the thread cap' \
  "$(sed -n 1p <<<"$launch")" 'worker=2 group=25,29,200 threads=3'
check 'worker launch goes through the limited-cpus gate under taskset' \
  "$(sed -n 2p <<<"$launch")" \
  "exec: env ZPU_MAX_THREADS=3 taskset -c 25,29,200 $root/tools/limited-cpus.sh zig build test"

fanned=$(ZPU_FANOUT_ALLOWED_CPUS=0-400 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --all --dry-run -- ./run.sh |
  grep -c '^exec: env ZPU_MAX_THREADS=3 taskset -c ')
check '--all launches exactly four pinned commands' "$fanned" 4

# --- failure cases ----------------------------------------------------------

refuses 'fewer than four usable physical cores is refused' 69 \
  'needs at least 4 usable physical cores' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3,5,9 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

refuses 'SMT siblings of one core do not count as separate cores' 69 \
  'yields 1 (SMT siblings of one core count once)' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3,103 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

refuses 'an all-offline cpuset is refused' 69 \
  'contains no online CPU' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=33,210 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

printf '900-999\n' >"$tmp/cpuset-empty-intersection"
refuses 'a cgroup cpuset disjoint from the process affinity is refused' 69 \
  'effective cpuset is empty' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3-30 ZPU_FANOUT_CPUSET_FILE="$tmp/cpuset-empty-intersection" \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

: >"$tmp/topology-empty"
refuses 'a topology source without CPU rows is refused' 66 \
  'expected lscpu -p=CPU,CORE,SOCKET,ONLINE format' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology-empty" "$fanout" --plan

refuses 'a missing topology source is refused' 66 \
  'is unreadable' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/absent" "$fanout" --plan

refuses 'a malformed affinity list is refused' 64 \
  'is not a valid CPU list' -- \
  env ZPU_FANOUT_ALLOWED_CPUS='3,x' ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

printf 'bogus\n' >"$tmp/cpuset-bad"
refuses 'a malformed cgroup cpuset is refused' 64 \
  'is not a valid CPU list' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=3-30 ZPU_FANOUT_CPUSET_FILE="$tmp/cpuset-bad" \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --plan

refuses 'overlapping worker groups are refused' 70 \
  'must be pairwise disjoint' -- \
  env ZPU_FANOUT_TEST_GROUPS='1,2|3,4|5,6|2,7' "$fanout" --plan

refuses 'unequal worker groups are refused' 70 \
  'must be equal size' -- \
  env ZPU_FANOUT_TEST_GROUPS='1,2|3,4|5|6,7' "$fanout" --plan

refuses 'a partition without exactly four groups is refused' 70 \
  'exactly 4 are required' -- \
  env ZPU_FANOUT_TEST_GROUPS='1,2|3,4|5,6' "$fanout" --plan

refuses 'an empty worker group is refused' 70 \
  'has an empty CPU group' -- \
  env ZPU_FANOUT_TEST_GROUPS='1,2|3,4||5,6' "$fanout" --plan

refuses 'a non-numeric worker group is refused' 64 \
  'is not a valid CPU list' -- \
  env ZPU_FANOUT_TEST_GROUPS='1,2|3,4|5,six|7,8' "$fanout" --plan

refuses 'a worker index outside 0..3 is refused' 64 \
  'outside 0..3' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=0-400 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --worker 4 --dry-run -- true

refuses 'a non-numeric worker index is refused' 64 \
  'is not a non-negative integer' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=0-400 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --worker two --dry-run -- true

refuses 'launching without a command is refused' 64 \
  'no command given' -- \
  env ZPU_FANOUT_ALLOWED_CPUS=0-400 ZPU_FANOUT_CPUSET_FILE=/nonexistent \
  ZPU_FANOUT_LSCPU_FILE="$tmp/topology" "$fanout" --worker 0 --dry-run

refuses 'an unknown argument is refused' 64 \
  "unknown argument '--nope'" -- "$fanout" --nope

if ((failures)); then
  printf 'cpu-fanout: %s check(s) failed\n' "$failures" >&2
  exit 1
fi
echo "cpu-fanout: non-contiguous ids, offline CPUs, SMT duplicates, surplus cores, restricted cpusets, four disjoint equal groups, safety cap, launch contract, failure diagnostics: PASS"

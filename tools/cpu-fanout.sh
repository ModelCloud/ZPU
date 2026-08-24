#!/usr/bin/env bash
# Topology-aware four-worker CPU fanout for ZPU experiment and optimization runs.
#
# Derives the effective allowed Linux cpuset at run time, reads online CPU
# topology, keeps SMT siblings of one physical core together, and partitions the
# usable physical cores into exactly four pairwise-disjoint, equal-size worker
# groups of floor(physical_cores / 4) cores each. Surplus cores and duplicate
# SMT threads stay unused. Every launched command still goes through
# tools/limited-cpus.sh, so the repository's limited-cpus safety contract holds.
set -euo pipefail

readonly WORKER_COUNT=4
readonly SAFETY_THREAD_CAP=8
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
readonly root

fail() { local code="$1"; shift; printf 'ZPU fanout refused: %s\n' "$*" >&2; exit "$code"; }

usage() {
  cat <<'USAGE'
Usage:
  tools/cpu-fanout.sh --plan
  tools/cpu-fanout.sh --worker N [--dry-run] -- command [args...]
  tools/cpu-fanout.sh --all [--dry-run] -- command [args...]

--plan      Print the derived partition as key=value lines.
--worker N  Run command pinned to worker N (0..3) through tools/limited-cpus.sh.
--all       Run command once per worker concurrently; each child sees
            ZPU_FANOUT_WORKER.
--dry-run   Print the exact command that would be executed instead of running it.

Exactly one of --plan, --worker, and --all may be given.

Test seams (fixture-driven tests only):
  ZPU_FANOUT_ALLOWED_CPUS   overrides the caller's taskset affinity
  ZPU_FANOUT_CPUSET_FILE    overrides the resolved cgroup cpuset.cpus.effective
  ZPU_FANOUT_LSCPU_FILE     overrides lscpu -p=CPU,CORE,SOCKET,ONLINE
  ZPU_FANOUT_TEST_GROUPS    feeds literal groups (a,b|c,d|...) to the validator
USAGE
}

validate_cpu_list() {
  [[ "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ ]] ||
    fail 64 "$2 is not a valid CPU list: '$1'"
}

# Expand "1-3,7" into one sorted, deduplicated CPU id per line.
expand_cpu_list() {
  awk -v list="$1" '
    BEGIN {
      n = split(list, item, ",")
      for (i = 1; i <= n; i++) {
        p = index(item[i], "-")
        if (p) {
          b = substr(item[i], 1, p - 1) + 0
          e = substr(item[i], p + 1) + 0
          if (e < b) exit 3
          for (c = b; c <= e; c++) print c
        } else {
          print item[i] + 0
        }
      }
    }' | sort -n -u
}

# Keep only the ids present in both newline-separated lists.
intersect_cpus() {
  awk 'NR == FNR { keep[$1] = 1; next } ($1 in keep)' <(printf '%s\n' "$1") <(printf '%s\n' "$2")
}

join_csv() { local IFS=,; printf '%s' "$*"; }

# --- effective cpuset -------------------------------------------------------

# The unified (cgroup v2) hierarchy publishes cpuset.cpus.effective inside the
# process's own cgroup directory, so walk from that cgroup toward the root and
# use the nearest file that exists. cgroup v1 is deliberately not consulted: a
# v1 cpuset is already reflected in the kernel affinity mask this tool starts
# from, and reading the v1 hierarchy would double-count the same restriction.
resolve_cpuset_file() {
  if [[ -n "${ZPU_FANOUT_CPUSET_FILE:-}" ]]; then
    printf '%s' "$ZPU_FANOUT_CPUSET_FILE"
    return
  fi
  local rel candidate
  rel=$(awk -F: '$1 == "0" && $2 == "" { print $3; exit }' /proc/self/cgroup 2>/dev/null) || rel=""
  while [[ -n "$rel" && "$rel" != "." ]]; do
    candidate="/sys/fs/cgroup${rel%/}/cpuset.cpus.effective"
    if [[ -e "$candidate" ]]; then
      printf '%s' "$candidate"
      return
    fi
    [[ "$rel" == "/" ]] && break
    rel=$(dirname "$rel")
  done
  printf '%s' "/sys/fs/cgroup/cpuset.cpus.effective"
}

derive_allowed_cpus() {
  local raw source
  if [[ -n "${ZPU_FANOUT_ALLOWED_CPUS:-}" ]]; then
    raw="$ZPU_FANOUT_ALLOWED_CPUS"
    source="ZPU_FANOUT_ALLOWED_CPUS"
  else
    raw=$(taskset -pc $$ | sed 's/.*: //')
    source="process affinity"
  fi
  validate_cpu_list "$raw" "$source"
  local allowed
  allowed=$(expand_cpu_list "$raw") || fail 64 "$source contains an inverted range: '$raw'"

  # LXD/cgroup cpuset restrictions narrow the set further when exposed.
  local cpuset_file
  cpuset_file=$(resolve_cpuset_file)
  if [[ -r "$cpuset_file" ]]; then
    local cpuset_raw
    cpuset_raw=$(tr -d '[:space:]' <"$cpuset_file")
    # A readable but empty cpuset grants no CPU at all. It takes part in the
    # intersection like any other value instead of being ignored, so the run
    # is refused rather than silently widened back to the process affinity.
    [[ -n "$cpuset_raw" ]] ||
      fail 69 "cgroup cpuset $cpuset_file is readable but empty, so the effective cpuset after intersecting $source with it is empty"
    validate_cpu_list "$cpuset_raw" "cgroup cpuset $cpuset_file"
    local cpuset_expanded
    cpuset_expanded=$(expand_cpu_list "$cpuset_raw") ||
      fail 64 "cgroup cpuset $cpuset_file contains an inverted range: '$cpuset_raw'"
    allowed=$(intersect_cpus "$allowed" "$cpuset_expanded")
  fi
  [[ -n "$allowed" ]] ||
    fail 69 "the effective cpuset is empty after intersecting $source with $cpuset_file"
  printf '%s\n' "$allowed"
}

# --- topology ---------------------------------------------------------------

TOPOLOGY_SOURCE=""

# Named separately from read_topology: that runs in a command substitution, so
# a variable it assigned would be lost with its subshell.
topology_source() {
  if [[ -n "${ZPU_FANOUT_LSCPU_FILE:-}" ]]; then
    printf '%s' "$ZPU_FANOUT_LSCPU_FILE"
  else
    printf '%s' "lscpu -p=CPU,CORE,SOCKET,ONLINE"
  fi
}

read_topology() {
  if [[ -n "${ZPU_FANOUT_LSCPU_FILE:-}" ]]; then
    [[ -r "$ZPU_FANOUT_LSCPU_FILE" ]] ||
      fail 66 "topology source '$ZPU_FANOUT_LSCPU_FILE' is unreadable"
    cat "$ZPU_FANOUT_LSCPU_FILE"
  else
    lscpu -p=CPU,CORE,SOCKET,ONLINE 2>/dev/null ||
      fail 66 "'lscpu -p=CPU,CORE,SOCKET,ONLINE' failed; install util-linux or point ZPU_FANOUT_LSCPU_FILE at a topology file"
  fi
}

# Reject malformed rows outright instead of coercing them to CPU/core/socket 0.
validate_topology() {
  local problem
  problem=$(printf '%s\n' "$1" | awk -F, '
    function bail(msg) { print "row " NR " " msg; bad = 1; exit }
    /^#/ { next }
    /^[[:space:]]*$/ { next }
    NF < 4 { bail("has " NF " field(s); expected CPU,CORE,SOCKET,ONLINE") }
    { for (i = 1; i <= 4; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i) }
    $1 !~ /^[0-9]+$/ { bail("has a non-numeric CPU id \"" $1 "\"") }
    $2 !~ /^[0-9]+$/ { bail("has a non-numeric core id \"" $2 "\"") }
    $3 !~ /^[0-9]+$/ { bail("has a non-numeric socket id \"" $3 "\"") }
    $4 != "Y" && $4 != "N" { bail("has an unknown ONLINE flag \"" $4 "\"") }
    { rows++ }
    END { if (!bad && !rows) print "contains no CPU rows" }
  ')
  [[ -z "$problem" ]] || fail 66 "topology source $TOPOLOGY_SOURCE $problem; expected lscpu -p=CPU,CORE,SOCKET,ONLINE format"
}

# Normalize validated rows to "socket core cpu online".
normalize_topology() {
  printf '%s\n' "$1" | awk -F, '
    /^#/ { next }
    /^[[:space:]]*$/ { next }
    { for (i = 1; i <= 4; i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      print $3 + 0, $2 + 0, $1 + 0, $4 }'
}

# One representative logical CPU per online, allowed physical (socket, core),
# ordered by socket then core so a worker group stays topologically adjacent.
select_core_representatives() {
  local rows="$1" allowed_csv="$2"
  printf '%s\n' "$rows" | awk -v allowed="$allowed_csv" '
    BEGIN { n = split(allowed, a, ","); for (i = 1; i <= n; i++) permitted[a[i] + 0] = 1 }
    $4 == "Y" && ($3 in permitted) { print $1, $2, $3 }
  ' | sort -k1,1n -k2,2n -k3,3n | awk '
    { key = $1 ":" $2; if (!(key in seen)) { seen[key] = 1; print $1, $2, $3 } }'
}

# --- grouping and validation ------------------------------------------------

GROUP_SIZE=0

validate_groups() {
  (($# == WORKER_COUNT)) ||
    fail 70 "grouping produced $# worker groups; exactly $WORKER_COUNT are required"
  local -A owner=()
  local expected="" group cpu idx=0
  local -a members
  for group in "$@"; do
    [[ -n "$group" ]] || fail 70 "worker $idx has an empty CPU group"
    validate_cpu_list "$group" "worker $idx CPU group"
    IFS=, read -r -a members <<<"$group"
    if [[ -z "$expected" ]]; then
      expected=${#members[@]}
    elif ((${#members[@]} != expected)); then
      fail 70 "worker $idx holds ${#members[@]} CPUs but worker 0 holds $expected; worker groups must be equal size"
    fi
    for cpu in "${members[@]}"; do
      cpu=$((cpu))
      [[ -z "${owner[$cpu]:-}" ]] ||
        fail 70 "CPU $cpu appears in worker ${owner[$cpu]} and worker $idx; worker groups must be pairwise disjoint"
      owner[$cpu]=$idx
    done
    idx=$((idx + 1))
  done
  GROUP_SIZE=$expected
}

ALLOWED_CSV=""
PHYSICAL_CORES=0
UNUSED_CSV=""
WORKER_GROUPS=()
GROUP_CORES=()

build_partition() {
  if [[ -n "${ZPU_FANOUT_TEST_GROUPS:-}" ]]; then
    local -a seam
    IFS='|' read -r -a seam <<<"$ZPU_FANOUT_TEST_GROUPS"
    validate_groups "${seam[@]}"
    WORKER_GROUPS=("${seam[@]}")
    GROUP_CORES=()
    PHYSICAL_CORES=$((WORKER_COUNT * GROUP_SIZE))
    return
  fi

  local allowed topology rows online
  allowed=$(derive_allowed_cpus)
  TOPOLOGY_SOURCE=$(topology_source)
  topology=$(read_topology)
  validate_topology "$topology"
  rows=$(normalize_topology "$topology")
  online=$(printf '%s\n' "$rows" | awk '$4 == "Y" { print $3 }' | sort -n -u)
  [[ -n "$online" ]] || fail 69 "topology source $TOPOLOGY_SOURCE reports no online CPU"
  # Offline CPUs can sit inside the cpuset; only online ones are usable.
  allowed=$(intersect_cpus "$allowed" "$online")
  [[ -n "$allowed" ]] || fail 69 "the effective cpuset contains no online CPU"
  ALLOWED_CSV=$(printf '%s' "$allowed" | paste -sd, -)

  local -a core_rows=()
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && core_rows+=("$line")
  done <<<"$(select_core_representatives "$rows" "$ALLOWED_CSV")"

  PHYSICAL_CORES=${#core_rows[@]}
  local per=$((PHYSICAL_CORES / WORKER_COUNT))
  ((per >= 1)) ||
    fail 69 "four-worker fanout needs at least $WORKER_COUNT usable physical cores; the effective cpuset $ALLOWED_CSV yields $PHYSICAL_CORES (SMT siblings of one core count once)"

  local -A assigned=()
  local w k row cpu socket core group cores
  WORKER_GROUPS=()
  GROUP_CORES=()
  for ((w = 0; w < WORKER_COUNT; w++)); do
    group=""
    cores=""
    for ((k = 0; k < per; k++)); do
      row=${core_rows[$((w * per + k))]}
      read -r socket core cpu <<<"$row"
      group+="${group:+,}$cpu"
      cores+="${cores:+,}$socket:$core"
      assigned[$cpu]=1
    done
    WORKER_GROUPS+=("$group")
    GROUP_CORES+=("$cores")
  done

  validate_groups "${WORKER_GROUPS[@]}"

  local -a unused=()
  for cpu in $allowed; do
    [[ -n "${assigned[$cpu]:-}" ]] || unused+=("$cpu")
  done
  UNUSED_CSV=$(join_csv "${unused[@]+"${unused[@]}"}")
}

thread_cap() {
  local cap=$GROUP_SIZE
  if ((cap > SAFETY_THREAD_CAP)); then
    printf 'ZPU fanout note: worker groups hold %s cores; the limited-cpus safety cap of %s governs the thread cap\n' \
      "$GROUP_SIZE" "$SAFETY_THREAD_CAP" >&2
    cap=$SAFETY_THREAD_CAP
  fi
  printf '%s' "$cap"
}

print_plan() {
  local w
  printf 'allowed_cpus=%s\n' "$ALLOWED_CSV"
  printf 'physical_cores=%s\n' "$PHYSICAL_CORES"
  printf 'workers=%s\n' "$WORKER_COUNT"
  printf 'cores_per_worker=%s\n' "$GROUP_SIZE"
  for ((w = 0; w < WORKER_COUNT; w++)); do
    printf 'worker%s=%s\n' "$w" "${WORKER_GROUPS[$w]}"
    printf 'worker%s_cores=%s\n' "$w" "${GROUP_CORES[$w]:-}"
  done
  printf 'unused=%s\n' "$UNUSED_CSV"
  printf 'thread_cap=%s\n' "$(thread_cap)"
}

run_worker() {
  local worker="$1" dry="$2"
  shift 2
  [[ "$worker" =~ ^[0-9]+$ ]] || fail 64 "worker index '$worker' is not a non-negative integer"
  ((worker < WORKER_COUNT)) || fail 64 "worker index $worker is outside 0..$((WORKER_COUNT - 1))"
  (($# > 0)) || fail 64 "no command given; pass it after --"

  local group="${WORKER_GROUPS[$worker]}" cap
  cap=$(thread_cap)
  export ZPU_FANOUT_WORKER="$worker"
  export ZPU_FANOUT_WORKERS="$WORKER_COUNT"
  export ZPU_FANOUT_GROUP_CPUS="$group"
  export ZPU_MAX_THREADS="$cap"
  # tools/limited-cpus.sh re-derives its allowed set from this affinity, so the
  # canonical marker, selection, and cap that require-limited.sh checks are the
  # ones this worker actually runs under.
  unset ZPU_TEST_ALLOWED_CPUS ZPU_TEST_LSCPU_FILE
  if ((dry)); then
    local quoted
    quoted=$(printf '%q ' "$@")
    printf 'worker=%s group=%s threads=%s\n' "$worker" "$group" "$cap"
    printf 'exec: env ZPU_MAX_THREADS=%s taskset -c %s %q %s\n' \
      "$cap" "$group" "$root/tools/limited-cpus.sh" "${quoted% }"
    return 0
  fi
  exec taskset -c "$group" "$root/tools/limited-cpus.sh" "$@"
}

run_all() {
  local dry="$1"
  shift
  (($# > 0)) || fail 64 "no command given; pass it after --"
  local -a pids=() flags=()
  local w status=0 rc
  if ((dry)); then flags+=(--dry-run); fi
  for ((w = 0; w < WORKER_COUNT; w++)); do
    "$root/tools/cpu-fanout.sh" --worker "$w" "${flags[@]+"${flags[@]}"}" -- "$@" &
    pids+=("$!")
  done
  for ((w = 0; w < WORKER_COUNT; w++)); do
    rc=0
    wait "${pids[$w]}" || rc=$?
    if ((rc != 0)); then
      printf 'ZPU fanout worker %s exited %s\n' "$w" "$rc" >&2
      status=1
    fi
  done
  return "$status"
}

# --- argument parsing -------------------------------------------------------

mode=""
worker=""
dry_run=0
cmd=()

set_mode() {
  [[ -z "$mode" ]] ||
    fail 64 "conflicting modes: --$mode and --$1 cannot be combined; choose exactly one"
  mode="$1"
}

while (($#)); do
  case "$1" in
    --plan) set_mode plan; shift ;;
    --all) set_mode all; shift ;;
    --worker)
      (($# >= 2)) || fail 64 "--worker needs an index"
      set_mode worker; worker="$2"; shift 2 ;;
    --worker=*) set_mode worker; worker="${1#*=}"; shift ;;
    --dry-run) dry_run=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; cmd=("$@"); break ;;
    *) fail 64 "unknown argument '$1'" ;;
  esac
done
[[ -n "$mode" ]] || { usage >&2; fail 64 "no mode selected"; }

build_partition

case "$mode" in
  plan) print_plan ;;
  worker) run_worker "$worker" "$dry_run" "${cmd[@]+"${cmd[@]}"}" ;;
  all) run_all "$dry_run" "${cmd[@]+"${cmd[@]}"}" ;;
esac

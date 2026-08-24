#!/usr/bin/env bash
set -euo pipefail

cap="${ZPU_MAX_THREADS:-8}"
case "$cap" in ''|*[!0-9]*) echo "ZPU_MAX_THREADS must be a positive integer" >&2; exit 64;; esac
(( cap > 0 && cap <= 8 )) || { echo "ZPU_MAX_THREADS must be in 1..8" >&2; exit 64; }

allowed="${ZPU_TEST_ALLOWED_CPUS:-$(taskset -pc $$ | sed 's/.*: //')}"
topology="${ZPU_TEST_LSCPU_FILE:-}"
if [[ -n "$topology" ]]; then
  topology_cmd=(cat "$topology")
else
  topology_cmd=(lscpu -p=CPU,CORE,SOCKET,ONLINE)
fi

topology_data="$(${topology_cmd[@]})" || { echo "topology source failed" >&2; exit 66; }
if ! awk -F, '
  /^#/ || /^[[:space:]]*$/ { next }
  NF != 4 { exit 1 }
' <<<"$topology_data"; then
  echo "topology rows must contain exactly CPU,CORE,SOCKET,ONLINE" >&2
  exit 66
fi

selected="$(awk -F, -v allowed="$allowed" -v cap="$cap" '
function permitted(cpu, list, n,a,i,p,b,e) {
  n=split(list,a,","); for(i=1;i<=n;i++){p=index(a[i],"-"); if(p){b=substr(a[i],1,p-1)+0;e=substr(a[i],p+1)+0;if(cpu>=b&&cpu<=e)return 1}else if(cpu==a[i]+0)return 1} return 0
}
/^#/ {next}
NF==4 && $4=="Y" && permitted($1+0,allowed) { key=$3 ":" $2; if(!seen[key]++ && count<cap){out=out (count?",":"") $1; count++} }
END {if(count) print out}
' <<<"$topology_data")"
[[ -n "$selected" ]] || { echo "no online physical core intersects allowed affinity $allowed" >&2; exit 69; }
count=$(awk -F, '{print NF}' <<<"$selected")
export ZPU_MAX_THREADS="$count"
export ZPU_SELECTED_CPUS="$selected"
export ZPU_LIMITED="physical-core-v1"
# Trusted host values intentionally overwrite caller-provided fingerprint data.
export ZPU_CPU_MODEL="$(lscpu | awk -F: '/^Model name:/{sub(/^[ \t]+/,"",$2); print $2; exit}')"
# lscpu's CORE column is a dense renumbering, not the kernel core_id the
# benchmark reads back from sysfs, so the trusted fingerprint comes from sysfs
# whenever a real host is being measured. Fixture runs keep using the file.
if [[ -n "$topology" ]]; then
  export ZPU_TOPOLOGY="$(awk -F, -v selected="$selected" '
BEGIN{n=split(selected,a,",");for(i=1;i<=n;i++)wanted[a[i]]=1}
!/^#/ && NF==4 && $4=="Y" && wanted[$1+0] {item=$3 ":" $2 "@" $1; out=out (out?";":"") item}
END{print out}' <<<"$topology_data")"
else
  ZPU_TOPOLOGY=""
  IFS=, read -ra selected_cpus <<<"$selected"
  for cpu in "${selected_cpus[@]}"; do
    package_file="/sys/devices/system/cpu/cpu$cpu/topology/physical_package_id"
    core_file="/sys/devices/system/cpu/cpu$cpu/topology/core_id"
    [[ -r "$package_file" && -r "$core_file" ]] || { echo "missing sysfs topology for cpu $cpu" >&2; exit 70; }
    ZPU_TOPOLOGY+="${ZPU_TOPOLOGY:+;}$(<"$package_file"):$(<"$core_file")@$cpu"
  done
  export ZPU_TOPOLOGY
fi
[[ -n "$ZPU_CPU_MODEL" && -n "$ZPU_TOPOLOGY" ]] || { echo "trusted host fingerprint collection failed" >&2; exit 70; }
printf 'ZPU affinity: cpus=%s physical_cores=%s max_threads=%s\n' "$selected" "$count" "$ZPU_MAX_THREADS" >&2

args=("$@")
if [[ "${1:-}" == "zig" && "${2:-}" == "build" ]]; then
  args=()
  inserted=0
  for arg in "$@"; do
    if [[ "$arg" == "--" && "$inserted" == 0 ]]; then args+=("-j${count}"); inserted=1; fi
    args+=("$arg")
  done
  if [[ "$inserted" == 0 ]]; then args+=("-j${count}"); fi
fi
exec taskset -c "$selected" "${args[@]}"

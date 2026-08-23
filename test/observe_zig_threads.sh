#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

PATH="${ZPU_TEST_ZIG_DIR:-/tmp/zpu-zig}:$PATH" \
  "$root/tools/limited-cpus.sh" zig build --cache-dir "$tmp/local" --global-cache-dir "$tmp/global" test >/dev/null 2>"$tmp/build.log" &
root_pid=$!
max_tasks=0
observations=0
affinity_error=0

while kill -0 "$root_pid" 2>/dev/null; do
  queue="$root_pid"
  while [[ -n "$queue" ]]; do
    pid=${queue%% *}
    if [[ "$queue" == *" "* ]]; then queue=${queue#* }; else queue=""; fi
    [[ -d "/proc/$pid/task" ]] || continue
    comm=$(cat "/proc/$pid/comm" 2>/dev/null || true)
    shopt -s nullglob
    task_dirs=("/proc/$pid/task"/*)
    tasks=${#task_dirs[@]}
    (( tasks > 0 )) || continue
    case "$comm" in zig|build|test|zpu-benchmark) :;; *)
      children=$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)
      [[ -z "$children" ]] || queue="$queue${queue:+ }$children"
      continue;;
    esac
    (( tasks > max_tasks )) && max_tasks=$tasks
    observations=$((observations + 1))
    actual=$(taskset -pc "$pid" 2>/dev/null | sed 's/.*: //' || true)
    if [[ -n "$actual" ]]; then
      count=$(awk -v list="$actual" 'BEGIN{n=split(list,a,",");for(i=1;i<=n;i++){p=index(a[i],"-");if(p)c+=substr(a[i],p+1)-substr(a[i],1,p-1)+1;else c++}print c}')
      (( count <= 8 )) || affinity_error=1
    fi
    children=$(cat "/proc/$pid/task/$pid/children" 2>/dev/null || true)
    [[ -z "$children" ]] || queue="$queue${queue:+ }$children"
  done
done
wait "$root_pid" || { cat "$tmp/build.log" >&2; exit 1; }
(( observations > 0 )) || { echo "no Zig process observations" >&2; exit 1; }
(( affinity_error == 0 )) || { echo "observed a Zig process with affinity above 8 CPUs" >&2; exit 1; }
configured=$(sed -n 's/.*configured_workers=\([0-9][0-9]*\).*/\1/p' "$tmp/build.log" | head -1)
[[ -n "$configured" ]] || { cat "$tmp/build.log" >&2; exit 1; }
(( configured >= 1 && configured <= 8 )) || { echo "invalid configured worker count $configured" >&2; exit 1; }
# One coordinating thread plus the explicitly configured workers.
(( max_tasks <= configured + 1 )) || { echo "observed $max_tasks threads in one Zig process (>1 coordinator + $configured workers)" >&2; exit 1; }
echo "Zig thread observation: samples=$observations max_process_threads=$max_tasks configured_workers=$configured affinity<=8: PASS"

#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

fail() { echo "ZPU gate refused: $*; run it through tools/limited-cpus.sh" >&2; exit 78; }
[[ "${ZPU_LIMITED:-}" == "physical-core-v1" ]] || fail "missing canonical affinity marker"
cap="${ZPU_MAX_THREADS:-}"
case "$cap" in ''|*[!0-9]*) fail "invalid explicit ZPU_MAX_THREADS";; esac
(( cap >= 1 && cap <= 8 )) || fail "ZPU_MAX_THREADS is outside 1..8"
selected="${ZPU_SELECTED_CPUS:-}"
[[ -n "$selected" ]] || fail "missing selected CPU list"
actual=$(taskset -pc $$ | sed 's/.*: //')

expanded=$(awk -v list="$actual" 'BEGIN{n=split(list,a,",");for(i=1;i<=n;i++){p=index(a[i],"-");if(p){b=substr(a[i],1,p-1)+0;e=substr(a[i],p+1)+0;for(c=b;c<=e;c++)print c}else print a[i]+0}}' | paste -sd, -)
[[ "$expanded" == "$selected" ]] || fail "process affinity $expanded does not equal canonical selection $selected"
count=$(awk -F, '{print NF}' <<<"$expanded")
[[ "$count" -eq "$cap" ]] || fail "affinity count $count differs from explicit cap $cap"
echo "ZPU gate cap verified: affinity=$selected configured_workers=$cap" >&2

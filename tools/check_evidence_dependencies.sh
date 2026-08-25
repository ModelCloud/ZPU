#!/usr/bin/env bash
set -euo pipefail
search=${ZPU_SEARCH_TOOL:-}
if [[ -z "$search" ]]; then
  if command -v rg >/dev/null 2>&1; then search=rg
  elif command -v grep >/dev/null 2>&1; then search=grep
  else echo "evidence dependency check requires rg or grep" >&2; exit 1
  fi
fi
case "$search" in rg|grep) ;; *) echo "unsupported ZPU_SEARCH_TOOL: $search" >&2; exit 1;; esac
command -v "$search" >/dev/null 2>&1 || { echo "selected evidence search tool is missing: $search" >&2; exit 1; }
args=(-n); [[ "$search" == grep ]] && args=(-En)
set +e
output=$($search "${args[@]}" '\.github/workflows|GITHUB_TOKEN|workflow scope' "$@" 2>&1)
status=$?
set -e
if (( status == 0 )); then
  printf '%s\n' "$output"; echo "evidence feature depends on GitHub workflow configuration" >&2; exit 1
elif (( status != 1 )); then
  printf '%s\n' "$output" >&2; echo "evidence dependency search failed closed: $search status=$status" >&2; exit 1
fi

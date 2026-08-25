#!/usr/bin/env bash
# Repository-local ISA truth gate.
#
# Verifies through deterministic disassembly analysis that:
#   --clean       artifacts contain zero VEX-encoded instructions anywhere
#                 (the entire AVX/AVX2/AVX-512/FMA/BMI opcode space).
#   --kernelized  VEX instructions appear ONLY inside the separately compiled
#                 eight-lane kernel objects (`zpu_v3_*` functions), which must
#                 themselves be genuinely vectorized (>0 VEX), and ZERO VEX
#                 appears in any other project-owned function.
#
# Instruction attribution is exact: every instruction is matched against ELF
# FUNC symbol ranges from readelf; alignment padding and data tables between
# functions are ignored rather than misattributed, as are foreign (standard
# library / compiler-rt) functions whose baseline-target cleanliness is proven
# by the `-Dv3-kernels=false` whole-artifact gate. Deterministic: pure
# binutils plus fixed patterns; no network, no timestamps.
set -euo pipefail

usage="usage: isa_disasm_gate.sh check (--clean|--kernelized) FILE... [--kernelized FILE...] ..."
[[ "${1:-}" == "check" ]] || { echo "$usage" >&2; exit 64; }
shift

clean_files=()
kernelized_files=()
mode="none"
while (($#)); do
  case "$1" in
    --clean) mode="clean" ;;
    --kernelized) mode="kernelized" ;;
    *) case "$mode" in
         clean) clean_files+=("$1") ;;
         kernelized) kernelized_files+=("$1") ;;
         *) echo "isa-gate: file '$1' before any --clean/--kernelized flag" >&2; exit 64 ;;
       esac ;;
  esac
  shift
done

((${#clean_files[@]} + ${#kernelized_files[@]} > 0)) || { echo "isa-gate: no input files" >&2; exit 64; }

project_symbol='^(x86_64_v3_kernels|raster|render_pipeline|simd|surface|scalar|benchmark_main|benchmark|main|command|platform|vulkan|root)([.]|$)|^zpu_|^vk_'

# Print "<hex addr> <decimal size> <name>" for every defined FUNC symbol.
symbol_ranges() {
  readelf -sW "$1" | awk '$4 == "FUNC" && $7 != "UND" && $3 + 0 > 0 {
    h = tolower($2)
    n = 0
    for (i = 1; i <= length(h); i++) {
      c = substr(h, i, 1)
      p = index("0123456789abcdef", c) - 1
      if (p >= 0) n = n * 16 + p
    }
    print n, $3, $8
  }' | sort -n
}

# Disassemble $1 and print three decimal counts: VEX-encoded instructions in
# project-owned non-kernel functions ("outside"), inside the eight-lane kernel
# objects ("kernel"), and foreign/ignored regions ("foreign": standard library,
# compiler-rt, padding, data). Legacy `verr`/`verw` are excluded because their
# mnemonics begin with 'v' without being VEX-encoded.
count_vex() {
  {
    symbol_ranges "$1"
    echo "__DISASSEMBLY__"
    objdump -d --no-show-raw-insn -M intel "$1"
  } | awk -v phase=1 -v project_re="$project_symbol" '
    /^__DISASSEMBLY__$/ { phase = 2; next }
    phase == 1 && NF >= 3 { starts[++count] = $1; sizes[count] = $2; names[count] = $3; next }
    phase == 2 && /^[ \t]*[0-9a-f]+:/ {
      raw = $0
      sub(/[^0-9a-f]*:.*/, "", raw)
      gsub(/[ \t]/, "", raw)
      addr = 0
      for (i = 1; i <= length(raw); i++) {
        c = substr(raw, i, 1)
        p = index("0123456789abcdef", c) - 1
        if (p >= 0) addr = addr * 16 + p
      }
      rest = $0
      sub(/^[^:]*:[ \t]*/, "", rest)
      split(rest, tok, "[ \t]+")
      mnemonic = tok[1]
      is_vex = (mnemonic ~ /^v[a-z0-9.]/ && mnemonic != "verr" && mnemonic != "verw")
      if (!is_vex && rest ~ /[ \t][yz]mm[0-9]+([,.]|[ \t]|$)/) is_vex = 1
      if (is_vex) {
        lo = 1; hi = count; best = 0
        while (lo <= hi) {
          mid = int((lo + hi) / 2)
          if (starts[mid] <= addr) { best = mid; lo = mid + 1 } else hi = mid - 1
        }
        if (!(best && addr < starts[best] + sizes[best])) foreign++
        else if (names[best] ~ /^zpu_v3_/) kernel++
        else if (names[best] ~ project_re) outside++
        else foreign++
      }
    }
    END { printf "%d %d %d\n", outside + 0, kernel + 0, foreign + 0 }'
}

count_vex_file() {
  local file=$1
  if [[ "${file##*.}" == "a" ]]; then
    # Static archives restart addresses per member. Zig emits one object per
    # kernel library, which readelf and objdump both process natively; refuse
    # exotic multi-member archives instead of misattributing them.
    local members=()
    mapfile -t members < <(ar t "$file")
    if ((${#members[@]} != 1)); then
      echo "isa-gate: unsupported multi-member archive '$file' (${#members[@]} members)" >&2
      exit 64
    fi
    count_vex "$file"
  else
    count_vex "$file"
  fi
}

status=0
for file in "${clean_files[@]:-}"; do
  [[ -z "$file" || -f "$file" ]] || { echo "isa-gate: missing artifact '$file'" >&2; exit 66; }
  [[ -z "$file" ]] && continue
  read -r outside kernel foreign <<< "$(count_vex_file "$file")"
  if ((outside != 0 || kernel != 0 || foreign != 0)); then
    echo "isa-gate FAILED: $outside project, $kernel kernel, $foreign foreign-region VEX instruction(s) in clean artifact $(basename "$file")" >&2
    status=1
  else
    echo "isa-gate: $(basename "$file") contains zero VEX-encoded instructions"
  fi
done

total_kernel=0
for file in "${kernelized_files[@]:-}"; do
  [[ -z "$file" || -f "$file" ]] || { echo "isa-gate: missing artifact '$file'" >&2; exit 66; }
  [[ -z "$file" ]] && continue
  read -r outside kernel foreign <<< "$(count_vex_file "$file")"
  if ((outside != 0)); then
    echo "isa-gate FAILED: $outside VEX-encoded instruction(s) in non-kernel project code of $(basename "$file")" >&2
    status=1
  fi
  if ((kernel == 0)); then
    echo "isa-gate FAILED: expected vectorized kernel objects, found none in $(basename "$file")" >&2
    status=1
  fi
  total_kernel=$((total_kernel + kernel))
done

if ((total_kernel > 0)); then
  echo "isa-gate: kernel objects verified vectorized ($total_kernel VEX instructions, all inside zpu_v3_* functions)"
fi
exit "$status"

#!/usr/bin/env bash
# Repository-local ISA truth gate.
#
# Modes (all deterministic: binutils + fixed patterns, no network/timestamps):
#   check --no-kernel-symbols FILE...
#       Artifact contains zero eight-lane kernel export symbols AND zero
#       VEX-encoded instructions inside any function. Applied to artifacts
#       that must be entirely kernel-free (fail-closed linkage proof).
#   check --clean FILE...
#       Artifact contains zero VEX-encoded instructions inside any function.
#   check --kernelized FILE...
#       All three eight-lane kernel exports must be linked, genuinely
#       vectorized (>0 VEX), and VEX-encoded instructions may appear ONLY
#       inside them. Zero VEX is tolerated in explicitly listed foreign
#       (standard library / compiler-rt / libc plumbing) symbols — their
#       baseline cleanliness is proven separately by the kernel-free checks —
#       and in unattributable padding/data tables, which are not part of any
#       function. Any OTHER symbol carrying VEX, including unknown project
#       code, fails the gate (fail closed).
#
# Detection is encoding-aware: an instruction is VEX/EVEX iff its first raw
# opcode byte is 0xc4 (VEX 3-byte), 0xc5 (VEX 2-byte) or 0x62 (EVEX), which in
# 64-bit mode cannot begin any legacy instruction. Legacy `verr`/`verw` are
# therefore naturally excluded.
set -euo pipefail

usage="usage: isa_disasm_gate.sh check (--clean|--kernelized|--no-kernel-symbols) FILE... [...]"
[[ "${1:-}" == "check" ]] || { echo "$usage" >&2; exit 64; }
shift

# Exact exported kernel symbols. Single source of truth is
# src/simd/kernel_abi.zig, whose test asserts these names appear verbatim in
# this script.
KERNEL_EXPORTS=(zpu_v3_fill_span_8 zpu_v3_blend_span_8 zpu_v3_blend_pixels_8)
kernel_symbol_re='^(zpu_v3_fill_span_8|zpu_v3_blend_span_8|zpu_v3_blend_pixels_8)$'

# Fail closed: every required tool must exist before any analysis.
missing_tools=()
for tool in objdump readelf ar awk grep mktemp sort; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]} > 0)); then
  echo "isa-gate FAILED: required tools missing: ${missing_tools[*]}" >&2
  exit 69
fi

# Explicit foreign allowlist. A FUNC symbol is foreign when its full name
# starts with one of these standard-library/compiler-rt/libm/libc roots, or
# ends in "$plt", or starts with "__". EVERYTHING else that is not an exact
# kernel export is treated as project code and fails the gate if it carries
# VEX instructions — unknown symbols fail closed by design, so adding new
# dependencies means consciously extending this auditable list.
foreign_root_re='^(Io|debug|Dwarf|dwarf|std|builtin|compiler_rt|ubsan_rt|mem|array_list|array_hash_map|multi_array_list|hash_map|hash|fmt|os|math|json|heap|compress|log|process|fs|net|unicode|posix|linux|windows|Thread|Random|sort|enums|meta|crypto|time|tz|ascii|atomic|bcmp|strlen|dynamic_library|elf|ElfFile|coff|pdb|link|BitStack|DoublyLinkedList|Progress|SinglyLinkedList|Target|static_string_map|RingBuffer|semantic_version|valgrind|c|zig|start|ceil|ceilf|ceill|ceilq|floor|floorf|floorl|floorq|round|roundf|roundl|roundq|trunc|truncf|truncl|truncq|fabs|fabsf|fabsl|fabsq|fma|fmaf|fmal|fmaq|fmax|fmaxf|fmaxl|fmaxq|fmin|fminf|fminl|fminq|fmod|fmodf|fmodl|fmodq|sin|sinf|sinl|sinq|cos|cosf|cosl|cosq|tan|tanf|tanl|tanq|exp|expf|expl|expq|exp2|exp2f|exp2l|exp2q|sincos|sincosf|sincosl|sincosq|sqrt|sqrtf|sqrtl|sqrtq)([.$]|$)|^__|[.$]plt$'

clean_files=()
kernelized_files=()
nosym_files=()
mode="none"
while (($#)); do
  case "$1" in
    --clean) mode="clean" ;;
    --kernelized) mode="kernelized" ;;
    --no-kernel-symbols) mode="nosym" ;;
    *) case "$mode" in
         clean) clean_files+=("$1") ;;
         kernelized) kernelized_files+=("$1") ;;
         nosym) nosym_files+=("$1") ;;
         *) echo "isa-gate: file '$1' before any mode flag" >&2; exit 64 ;;
       esac ;;
  esac
  shift
done

total_inputs=$((${#clean_files[@]} + ${#kernelized_files[@]} + ${#nosym_files[@]}))
((total_inputs > 0)) || { echo "isa-gate: no input files" >&2; exit 64; }

workdir=$(mktemp -d)
trap 'rm -rf "$workdir"' EXIT

# Emit "<hex addr> <decimal size> <name>" for every defined FUNC symbol.
symbol_ranges() {
  local file=$1 out="$workdir/syms.raw"
  readelf -sW "$file" >"$out" 2>"$workdir/readelf.err" || {
    cat "$workdir/readelf.err" >&2
    echo "isa-gate: readelf failed on '$file'" >&2
    return 1
  }
  awk '$4 == "FUNC" && $7 != "UND" && $3 + 0 > 0 {
    h = tolower($2)
    n = 0
    for (i = 1; i <= length(h); i++) {
      c = substr(h, i, 1)
      p = index("0123456789abcdef", c) - 1
      if (p >= 0) n = n * 16 + p
    }
    print n, $3, $8
  }' "$out" | sort -n >"$workdir/syms.sorted"
}

# Print how many distinct eight-lane kernel export symbols are present as
# defined FUNC symbols.
kernel_export_count() {
  local file=$1 out="$workdir/kernsyms.txt"
  readelf -sW "$file" >"$out" 2>/dev/null || { echo "isa-gate: readelf failed on '$file'" >&2; return 1; }
  awk -v re="$kernel_symbol_re" '$4 == "FUNC" && $7 != "UND" && $8 ~ re { print $8 }' "$out" | sort -u | wc -l
}

# Print exactly "<outside> <kernel> <padding> <foreign> <total>": counts of
# VEX/EVEX-starting instructions attributed to project non-kernel functions,
# to the eight-lane kernel exports, to no function (padding/data), to
# explicitly allowed foreign library functions, and overall.
count_vex() {
  local file=$1 dis="$workdir/dis.txt" out="$workdir/counters.txt"
  symbol_ranges "$file" || return 1
  objdump -d -M intel "$file" >"$dis" 2>"$workdir/objdump.err" || {
    cat "$workdir/objdump.err" >&2
    echo "isa-gate: objdump failed on '$file'" >&2
    return 1
  }
  cat "$workdir/syms.sorted" >"$workdir/stream.txt"
  printf '__ISA_GATE_DISASSEMBLY__\n' >>"$workdir/stream.txt"
  cat "$dis" >>"$workdir/stream.txt"
  awk -v phase=1 -v foreign_re="$foreign_root_re" -v kernel_re="$kernel_symbol_re" '
    /^__ISA_GATE_DISASSEMBLY__$/ { phase = 2; next }
    phase == 1 {
      starts[++count] = $1
      sizes[count] = $2
      names[count] = $3
      next
    }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (line !~ /^[0-9a-f]+:[ \t]/) next
      n = split(line, f, "\t")
      if (n < 3) next                       # continuation bytes, not an instruction start
      addr_hex = f[1]
      sub(/:.*/, "", addr_hex)
      addr = 0
      for (i = 1; i <= length(addr_hex); i++) {
        c = substr(addr_hex, i, 1)
        p = index("0123456789abcdef", c) - 1
        if (p >= 0) addr = addr * 16 + p
      }
      split(f[2], b, " ")
      first = tolower(b[1])
      is_vex = 0
      if (first == "c4" || first == "c5" || first == "62") is_vex = 1
      if (is_vex) {
        mnemonic = f[3]
        gsub(/^[ \t]+|[ \t]+$/, "", mnemonic)
        if (mnemonic == "") is_vex = 0      # paranoia: never count without a decoded instruction
      }
      if (is_vex) {
        lo = 1; hi = count; best = 0
        while (lo <= hi) {
          mid = int((lo + hi) / 2)
          if (starts[mid] <= addr) { best = mid; lo = mid + 1 } else hi = mid - 1
        }
        total++
        if (!(best && addr < starts[best] + sizes[best])) padding++
        else {
          name = names[best]
          tail = name
          sub(/^.*\./, "", tail)
          if (tail ~ kernel_re) kernel++
          else if (name !~ foreign_re) outside++
          else foreign++
        }
      }
    }
    END {
      printf "%d %d %d %d %d\n", outside + 0, kernel + 0, padding + 0, foreign + 0, total + 0
    }
  ' "$workdir/stream.txt" >"$out" 2>"$workdir/awk.err"
  local rc=$?
  if ((rc != 0)); then
    cat "$workdir/awk.err" >&2
    echo "isa-gate: analyzer failed on '$file'" >&2
    return 1
  fi
  cat "$out"
}

count_vex_file() {
  local file=$1 result
  if [[ "${file##*.}" == "a" ]]; then
    # Static archives restart addresses per member. Zig emits exactly one
    # object per kernel library, which readelf and objdump process natively;
    # anything else is refused rather than misattributed.
    local members_file="$workdir/members.txt"
    ar t "$file" >"$members_file" 2>&1 || { echo "isa-gate: ar failed on '$file'" >&2; return 1; }
    local member_count
    member_count=$(grep -c . "$members_file" || true)
    if ((member_count != 1)); then
      echo "isa-gate: unsupported multi-member archive '$file' ($member_count members)" >&2
      return 1
    fi
  fi
  result=$(count_vex "$file")
  local rc=$?
  if ((rc != 0)); then
    echo "isa-gate: analysis failed for '$file'" >&2
    return 1
  fi
  # Exactly five integer counters, or the analysis is invalid: fail closed.
  if [[ ! "$result" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]]; then
    echo "isa-gate: malformed analyzer output for '$file': '$result'" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

status=0
check_file() {
  local file=$1 expect=$2 outside kernel padding foreign total present
  if [[ ! -f "$file" ]]; then
    echo "isa-gate: missing artifact '$file'" >&2
    status=1
    return
  fi
  if ! read -r outside kernel padding foreign total <<< "$(count_vex_file "$file")"; then
    status=1
    return
  fi
  case "$expect" in
    nosym)
      present=$(kernel_export_count "$file") || { status=1; return; }
      if ((present != 0)); then
        echo "isa-gate FAILED: $present eight-lane kernel export symbol(s) present in kernel-free artifact $(basename "$file")" >&2
        status=1
      fi
      if ((outside != 0 || kernel != 0 || foreign != 0)); then
        echo "isa-gate FAILED: $total VEX instruction(s) ($outside project, $kernel kernel, $foreign foreign) in kernel-free artifact: $(basename "$file")" >&2
        status=1
      fi
      ((status == 0)) && echo "isa-gate: $(basename "$file") is kernel-free (zero VEX in functions, zero kernel exports, $padding data-region bytes ignored)"
      ;;
    clean)
      if ((outside != 0 || kernel != 0 || foreign != 0)); then
        echo "isa-gate FAILED: $total VEX instruction(s) ($outside project, $kernel kernel, $foreign foreign) in artifact requiring zero: $(basename "$file")" >&2
        status=1
      else
        echo "isa-gate: $(basename "$file") contains zero VEX-encoded instructions in functions ($padding data-region bytes ignored)"
      fi
      ;;
    kernelized)
      present=$(kernel_export_count "$file") || { status=1; return; }
      if ((present < ${#KERNEL_EXPORTS[@]})); then
        echo "isa-gate FAILED: only $present/${#KERNEL_EXPORTS[@]} eight-lane kernel exports linked in $(basename "$file")" >&2
        status=1
      fi
      if ((outside != 0)); then
        echo "isa-gate FAILED: $outside VEX instruction(s) in project non-kernel code of $(basename "$file")" >&2
        status=1
      fi
      if ((kernel == 0)); then
        echo "isa-gate FAILED: expected vectorized eight-lane kernels, found none in $(basename "$file")" >&2
        status=1
      fi
      if ((status == 0)); then
        echo "isa-gate: $(basename "$file") kernels verified vectorized ($kernel VEX inside kernel exports only)"
      fi
      ;;
  esac
}

for file in "${nosym_files[@]:-}"; do [[ -n "${file:-}" ]] && check_file "$file" nosym || true; done
for file in "${clean_files[@]:-}"; do [[ -n "${file:-}" ]] && check_file "$file" clean || true; done
for file in "${kernelized_files[@]:-}"; do [[ -n "${file:-}" ]] && check_file "$file" kernelized || true; done
exit "$status"

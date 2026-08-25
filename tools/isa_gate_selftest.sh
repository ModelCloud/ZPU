#!/usr/bin/env bash
# Deterministic negative/positive-control fixtures for tools/isa_disasm_gate.sh.
#
# Assembles tiny ELF objects with GNU as and proves the gate's behavior:
#   1. A VEX instruction inside a plain project-named function is REJECTED
#      by --kernelized (fail-closed leak detection).
#   2. A VEX instruction inside the exact `zpu_v3_fill_span_8` export is
#      ACCEPTED by --kernelized with all exports linked.
#   3. Any VEX instruction is REJECTED by --no-kernel-symbols/--clean modes.
#   4. A non-VEX object passes --clean.
# Fails closed if the assembler or any required tool is unavailable.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
gate="$root/tools/isa_disasm_gate.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

missing_tools=()
for tool in as objdump readelf ar; do
  command -v "$tool" >/dev/null 2>&1 || missing_tools+=("$tool")
done
if ((${#missing_tools[@]} > 0)); then
  echo "isa-gate-selftest FAILED: required tools missing: ${missing_tools[*]}" >&2
  exit 69
fi

expect_ok() {
  local label=$1
  shift
  if bash "$gate" "$@" >"$work/out.log" 2>&1; then
    echo "selftest ok:   $label"
  else
    echo "isa-gate-selftest FAILED: expected success: $label" >&2
    cat "$work/out.log" >&2
    exit 1
  fi
}

expect_fail() {
  local label=$1
  shift
  if bash "$gate" "$@" >"$work/out.log" 2>&1; then
    echo "isa-gate-selftest FAILED: expected rejection: $label" >&2
    cat "$work/out.log" >&2
    exit 1
  fi
  echo "selftest ok:   $label (rejected)"
}

cat >"$work/leak.S" <<'EOF'
.text
.globl raster.project_leaky
.type raster.project_leaky,@function
raster.project_leaky:
	vpblendd $0, %xmm1, %xmm0, %xmm0
	ret
.size raster.project_leaky, .-raster.project_leaky
EOF

cat >"$work/kernel.S" <<'EOF'
.text
.globl zpu_v3_fill_span_8
.type zpu_v3_fill_span_8,@function
zpu_v3_fill_span_8:
	vpbroadcastd %xmm1, %xmm0
	vpblendd $0, %xmm1, %xmm0, %xmm0
	ret
.size zpu_v3_fill_span_8, .-zpu_v3_fill_span_8
.globl zpu_v3_blend_span_8
.type zpu_v3_blend_span_8,@function
zpu_v3_blend_span_8:
	ret
.size zpu_v3_blend_span_8, .-zpu_v3_blend_span_8
.globl zpu_v3_blend_pixels_8
.type zpu_v3_blend_pixels_8,@function
zpu_v3_blend_pixels_8:
	ret
.size zpu_v3_blend_pixels_8, .-zpu_v3_blend_pixels_8
EOF

cat >"$work/plain.S" <<'EOF'
.text
.globl raster.project_plain
.type raster.project_plain,@function
raster.project_plain:
	xor %eax, %eax
	ret
.size raster.project_plain, .-raster.project_plain
EOF

as --64 -o "$work/leak.o" "$work/leak.S"
as --64 -o "$work/kernel.o" "$work/kernel.S"
as --64 -o "$work/plain.o" "$work/plain.S"

# Negative control: an outside-kernel VEX leak must be rejected (fail closed).
expect_fail "leaky project symbol rejected under --kernelized" check --kernelized "$work/leak.o"
expect_fail "leaky project symbol rejected under --clean" check --clean "$work/leak.o"
# --no-kernel-symbols is a pure linkage assertion and must stay agnostic to VEX.
expect_ok "leaky project object passes symbol-only --no-kernel-symbols" check --no-kernel-symbols "$work/leak.o"

# Positive control: exact kernel exports carrying VEX are accepted only when
# every export is linked, and never under kernel-free modes.
expect_ok "vectorized full kernel set accepted under --kernelized" check --kernelized "$work/kernel.o"
expect_fail "vectorized kernel set rejected under --no-kernel-symbols" check --no-kernel-symbols "$work/kernel.o"
expect_fail "incomplete kernel set rejected under --kernelized" check --kernelized "$work/leak.o"

cat >"$work/incomplete.S" <<'EOF'
.text
.globl zpu_v3_fill_span_8
.type zpu_v3_fill_span_8,@function
zpu_v3_fill_span_8:
	vpbroadcastd %xmm1, %xmm0
	ret
.size zpu_v3_fill_span_8, .-zpu_v3_fill_span_8
EOF
as --64 -o "$work/incomplete.o" "$work/incomplete.S"
expect_fail "missing sibling exports rejected under --kernelized" check --kernelized "$work/incomplete.o"

expect_ok "plain non-VEX project object passes --clean" check --clean "$work/plain.o"
expect_ok "plain non-VEX project object passes --no-kernel-symbols" check --no-kernel-symbols "$work/plain.o"

echo "isa-gate-selftest: all controls behaved as required"

#!/usr/bin/env bash
# Repository-local cross-target ISA tier evidence, appropriate to Zig 0.16.
#
# 1. Kernel-free baseline build (-Dv3-kernels=false, ReleaseFast): the ICD
#    must contain zero kernel export symbols; demo/benchmark must contain zero
#    VEX-encoded instructions inside any project function (foreign library
#    symbols on an explicit allowlist, and data tables, are reported but
#    tolerated).
# 2. Default build (baseline target + linked x86-64-v3 kernel objects,
#    installed via the deterministic `install-v3-archive` step): the ICD stays
#    symbol-free of kernels; demo/benchmark carry vectorized kernels
#    exclusively inside `zpu_v3_*` functions with no VEX in any other project
#    function (foreign/data tolerance identical to phase 1).
# 3. Explicit -Dcpu=x86_64_v3 opt-in build: must succeed. Its functional smoke
#    run is host-gated: executed only when this host supports AVX2, otherwise
#    explicitly skipped (or hard-failed with ZPU_REQUIRE_V3_RUN=1). No
#    x86_64-v3 code is ever executed on an unsupported host.
# 4. aarch64-linux-gnu cross build of the full default install set (xcb-linked
#    artifacts resolved through -Dsearch-prefix into a multiarch sysroot):
#    successful linkage proves non-x86_64 targets never reference the
#    eight-lane kernel symbols.
#
# Builds land in isolated prefixes; no repository files are modified.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

run_build() {
  local dir=$1
  shift
  zig build --prefix "$dir" "$@" >"$dir.build.log" 2>&1 || {
    cat "$dir.build.log" >&2
    exit 1
  }
}

echo "isa-cross: building kernel-free baseline ReleaseFast artifacts"
mkdir -p "$work/clean"
run_build "$work/clean" -Doptimize=ReleaseFast -Dv3-kernels=false
bash tools/isa_disasm_gate.sh check --no-kernel-symbols \
  "$work/clean/lib/libvulkan_zpu.so"
bash tools/isa_disasm_gate.sh check --clean \
  "$work/clean/bin/zpu-demo" \
  "$work/clean/bin/zpu-benchmark"

echo "isa-cross: building default baseline artifacts with linked v3 kernels"
mkdir -p "$work/default"
# Two invocations share the prefix: the default install for shipped artifacts,
# then the deterministic kernel-archive install step.
run_build "$work/default" -Doptimize=ReleaseFast
run_build "$work/default" -Doptimize=ReleaseFast install-v3-archive
V3="$work/default/isa/libzpu-x86-64-v3-kernels.a"
if [[ ! -f "$V3" ]]; then
  echo "isa-cross FAILED: kernel archive missing at deterministic path $V3" >&2
  exit 1
fi
bash tools/isa_disasm_gate.sh check \
  --no-kernel-symbols "$work/default/lib/libvulkan_zpu.so" \
  --kernelized "$work/default/bin/zpu-demo" "$work/default/bin/zpu-benchmark" "$V3"

echo "isa-cross: building explicit -Dcpu=x86_64_v3 opt-in artifacts"
mkdir -p "$work/v3"
run_build "$work/v3" -Doptimize=ReleaseFast -Dcpu=x86_64_v3 -Dv3-kernels=false
host_avx2=false
if grep -qE '^[[:space:]]*flags[[:space:]]*:.*[[:space:]]avx2([[:space:]]|$)' /proc/cpuinfo 2>/dev/null; then
  host_avx2=true
fi
if [[ "$host_avx2" == true ]]; then
  "$work/v3/bin/zpu-benchmark" --smoke --json >/dev/null
  echo "isa-cross: v3 opt-in artifact functional on this AVX2-capable host"
elif [[ "${ZPU_REQUIRE_V3_RUN:-0}" == "1" ]]; then
  echo "isa-cross FAILED: ZPU_REQUIRE_V3_RUN=1 but this host does not support AVX2" >&2
  exit 1
else
  echo "isa-cross SKIP: -Dcpu=x86_64_v3 functional smoke requires an AVX2-capable host; set ZPU_REQUIRE_V3_RUN=1 to make absence fatal"
fi

echo "isa-cross: cross-compiling aarch64-linux-gnu artifacts"
mkdir -p "$work/aarch64" "$work/sysroot"
arm64_sysroot=/usr/lib/aarch64-linux-gnu
if [[ ! -d "$arm64_sysroot" ]] || ! ls "$arm64_sysroot"/libxcb.so* >/dev/null 2>&1; then
  echo "isa-cross FAILED: aarch64 multiarch sysroot with libxcb1-dev:arm64 required (sudo apt-get install libxcb1-dev:arm64)" >&2
  exit 1
fi
# -Dsearch-prefix expects a prefix layout (prefix/lib, prefix/include).
ln -sfn "$arm64_sysroot" "$work/sysroot/lib"
ln -sfn /usr/include "$work/sysroot/include"
run_build "$work/aarch64" -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseFast \
  -Dsearch-prefix="$work/sysroot"
test -f "$work/aarch64/lib/libvulkan_zpu.so"
test -f "$work/aarch64/bin/zpu-demo"
test -f "$work/aarch64/bin/zpu-benchmark"

echo "isa-cross: all tiers verified (baseline clean, kernels gated and vectorized, v3 opt-in host-gated, aarch64 boundary-free)"

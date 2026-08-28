#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

# Deterministic regression for ISA-gate graph wiring (BL-1).
#
# Proves, via nested builds, that:
#   R1  `zig build isa-gate -Dtarget=aarch64-linux-gnu` compiles the target
#       artifacts and exits 0 through the gate's first-class skip path.
#   R2  The gated_files==0 configuration (`-Dxcb=false -Dcpu=x86_64_v3
#       -Dv3-kernels=false`) likewise skips successfully with exit 0.
#   R3  `zig build test -Dtarget=aarch64-linux-gnu` completes: unit tests are
#       compiled for the target (not executed locally), the ISA gate skips,
#       and host-side steps run normally.
#
# Prerequisite: an aarch64 multiarch sysroot (libxcb1-dev:arm64,
# libvulkan-dev:arm64). Hard-fails with install instructions otherwise.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

# Re-entry guard: this script runs as a build step, and its nested builds
# include the same step; without this sentinel each nested build would recurse
# into another regression run forever.
if [[ "${ZPU_ISA_GATE_REGRESSION:-}" == "1" ]]; then
  echo "isa-gate-regression: skipped (nested build)"
  exit 0
fi
export ZPU_ISA_GATE_REGRESSION=1

sysroot="$work/sysroot"
mkdir -p "$sysroot"
if [[ -d /usr/lib/aarch64-linux-gnu ]] && ls /usr/lib/aarch64-linux-gnu/libxcb.so* >/dev/null 2>&1 && [[ -f /usr/lib/aarch64-linux-gnu/libvulkan.so ]]; then
  ln -sfn /usr/lib/aarch64-linux-gnu "$sysroot/lib"
  ln -sfn /usr/include "$sysroot/include"
else
  echo "isa-gate-regression FAILED: aarch64 multiarch sysroot required (sudo apt-get install libxcb1-dev:arm64 libvulkan-dev:arm64)" >&2
  exit 69
fi

run_case() {
  local label=$1 expect_sub=$2
  shift 2
  if tools/limited-cpus.sh zig build --prefix "$work/prefix" "$@" >"$work/out.log" 2>&1; then
    if grep -q "$expect_sub" "$work/out.log"; then
      echo "isa-gate-regression ok:   $label"
    else
      echo "isa-gate-regression FAILED: expected '$expect_sub' in output for $label" >&2
      cat "$work/out.log" >&2
      exit 1
    fi
  else
    echo "isa-gate-regression FAILED: build failed for $label" >&2
    cat "$work/out.log" >&2
    exit 1
  fi
}

run_case "R1 aarch64 isa-gate skip path" \
  "SKIPPED (ISA tier evidence is x86-specific; target arch is aarch64)" \
  -Dtarget=aarch64-linux-gnu -Dsearch-prefix="$sysroot" isa-gate

run_case "R2 gated_files==0 skip path" \
  "SKIPPED (no scannable artifacts" \
  -Dxcb=false -Dcpu=x86_64_v3 -Dv3-kernels=false isa-gate

run_case "R3 aarch64 test graph completes" \
  "SKIPPED (ISA tier evidence is x86-specific; target arch is aarch64)" \
  -Dtarget=aarch64-linux-gnu -Dsearch-prefix="$sysroot" test

echo "isa-gate-regression: all wiring cases behaved as required"

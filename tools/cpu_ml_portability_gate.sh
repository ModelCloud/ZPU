#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

# Prove that the standalone CPU ML ABI is independent of Apple's Metal stack.
# This gate intentionally cross-compiles only cpu-ml-install: the Metal-shaped
# adapter is a separate artifact and is not part of this portability check.
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$root"

if rg -n '@cImport|@import\("(Metal|Foundation|Darwin|PJRT[^"}]*)' \
    src/cpu_ml_root.zig src/metal/ml_cpu.zig; then
    echo "cpu-ml-portability FAILED: standalone CPU ML Zig source imports Apple/PJRT code" >&2
    exit 1
fi
if rg -n -i '#[[:space:]]*include[[:space:]]*[<"]([^>"]*((Metal|Foundation|TargetConditionals|Availability|PJRT)))' \
    include/zpu/cpu_ml.h; then
    echo "cpu-ml-portability FAILED: standalone CPU ML header includes Apple/PJRT code" >&2
    exit 1
fi

build_target() {
    local target=$1
    local prefix="$work/$target"
    mkdir -p "$prefix"
    echo "cpu-ml-portability: compiling standalone CPU ML package for $target"
    zig build --prefix "$prefix" -Dtarget="$target" -Dxcb=false cpu-ml-install
    test -f "$prefix/lib/libzpu_cpu_ml.a"
    test -f "$prefix/include/zpu/cpu_ml.h"
    if nm -u "$prefix/lib/libzpu_cpu_ml.a" 2>/dev/null | rg -n -i '(Metal|Foundation|PJRT)' ; then
        echo "cpu-ml-portability FAILED: standalone archive has an Apple/PJRT dependency for $target" >&2
        exit 1
    fi
}

# Keep the package generic across the two common CPU families. M4/Apple
# silicon uses arm64 AdvSIMD/NEON; AVX is an x86_64 provider concern.
build_target x86_64-linux-gnu
build_target aarch64-linux-gnu
build_target aarch64-macos

echo "cpu-ml-portability: standalone CPU ML package is Metal/PJRT/OS independent"

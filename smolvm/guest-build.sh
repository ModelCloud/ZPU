#!/bin/sh
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -eu

src=/mnt/zpu-source
work=/var/tmp/zpu-build
prefix=/opt/zpu
cpu_tier=${ZPU_GUEST_CPU_TIER:-baseline}

for program in zig vulkaninfo vkcube tar python3 git taskset lscpu; do
    command -v "$program" >/dev/null || { echo "required guest tool not found: $program" >&2; exit 2; }
done
for header in /usr/include/vulkan/vulkan.h /usr/include/vulkan/vulkan_xcb.h /usr/include/xcb/xcb.h; do
    test -r "$header" || { echo "required guest development header not found: $header (install vulkan-headers and libxcb)" >&2; exit 2; }
done
test "$(zig version)" = 0.16.0 || {
    echo 'guest Zig must be exactly 0.16.0; install the pinned compiler before build' >&2
    exit 2
}
test -r "$src/build.zig" || { echo "guest source was not staged at $src" >&2; exit 2; }
case "$cpu_tier" in
    baseline) ;;
    native)
        # `native` intentionally creates a guest-local artifact. Do not claim
        # AVX2 execution merely from a host model string: require the guest's
        # effective CPUID mask before enabling native compiler codegen.
        grep -qm1 -w avx2 /proc/cpuinfo || {
            echo 'ZPU_GUEST_CPU_TIER=native requires guest AVX2 support' >&2
            exit 2
        }
        ;;
    *)
        echo 'ZPU_GUEST_CPU_TIER must be baseline or native' >&2
        exit 2
        ;;
esac
rm -rf "$work"
mkdir -p "$work" "$prefix/bin"
cp -a "$src/." "$work/"
cd "$work"
tools/limited-cpus.sh zig fmt --check build.zig src tools
if [ "$cpu_tier" = native ]; then
    tools/limited-cpus.sh zig build -Doptimize=ReleaseSafe -Dcpu=native --prefix "$prefix"
else
    tools/limited-cpus.sh zig build -Doptimize=ReleaseSafe --prefix "$prefix"
fi
zig cc -O2 -std=c11 -Wall -Wextra -Werror smolvm/xcb-connect.c -lxcb -o "$prefix/bin/zpu-xcb-connect"
zig cc -O2 -std=c11 -Wall -Wextra -Werror test/xcb_present.c -lvulkan -lxcb -o "$prefix/bin/zpu-xcb-present"
test -x /usr/bin/vulkaninfo
test -x /usr/bin/vkcube
test -r "$prefix/lib/libvulkan_zpu.so"
test -r "$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json"
printf '%s\n' "guest ZPU build and install complete (cpu tier: $cpu_tier)"

#!/bin/sh
set -eu

src=/mnt/zpu-source
work=/var/tmp/zpu-build
prefix=/opt/zpu

test -r "$src/build.zig"
test "$(zig version)" = 0.16.0 || {
    echo 'guest Zig must be exactly 0.16.0; install the pinned compiler before build' >&2
    exit 2
}
rm -rf "$work"
mkdir -p "$work" "$prefix"
cp -a "$src/." "$work/"
cd "$work"
zig fmt --check build.zig src tools
zig build -Doptimize=ReleaseSafe --prefix "$prefix"
zig cc -O2 -std=c11 -Wall -Wextra -Werror test/xcb_present.c -lvulkan -lxcb -o "$prefix/bin/zpu-xcb-present"
test -x /usr/bin/vulkaninfo
test -x /usr/bin/vkcube
test -r "$prefix/lib/libvulkan_zpu.so"
test -r "$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json"
printf '%s\n' 'guest ZPU build and install complete'

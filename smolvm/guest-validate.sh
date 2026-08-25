#!/bin/sh
set -eu

prefix=/opt/zpu
manifest=$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json
expected='ZPU Experimental CPU'

test -r "$manifest"
test -r "$prefix/lib/libvulkan_zpu.so"
test -S /tmp/.X11-unix/X0
test -r /run/zpu-xauth/Xauthority
test ! -e /dev/dri || {
    echo 'guest /dev/dri exists: SmolVM GPU/DRM exposure is forbidden for this workflow' >&2
    exit 2
}
if find /etc/vulkan /usr/local/share/vulkan /usr/share/vulkan -type f -name '*zpu*' -print -quit 2>/dev/null | grep -q .; then
    echo 'ZPU was installed into a guest-global Vulkan configuration directory' >&2
    exit 2
fi

# The clean environment is the process boundary: neither the Omarchy session nor
# any other guest process inherits ZPU's loader selection.
env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    DISPLAY=:0 \
    XAUTHORITY=/run/zpu-xauth/Xauthority \
    VK_DRIVER_FILES="$manifest" \
    vulkaninfo --summary > /tmp/zpu-vulkaninfo.txt
grep -F "$expected" /tmp/zpu-vulkaninfo.txt
test "$(grep -cE 'deviceName[[:space:]]*=' /tmp/zpu-vulkaninfo.txt)" -eq 1
if grep -Eqi 'venus|virtio|virgl|angle|llvmpipe|lavapipe|swiftshader|opengl|egl|glx' /tmp/zpu-vulkaninfo.txt; then
    echo 'non-ZPU or translated graphics implementation entered the validation process' >&2
    exit 2
fi

env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    DISPLAY=:0 \
    XAUTHORITY=/run/zpu-xauth/Xauthority \
    VK_DRIVER_FILES="$manifest" \
    ZPU_WINDOW_HOLD_SECONDS=2 \
    "$prefix/bin/zpu-xcb-present"

env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    DISPLAY=:0 \
    XAUTHORITY=/run/zpu-xauth/Xauthority \
    VK_DRIVER_FILES="$manifest" \
    vkcube --wsi xcb --c 120 --suppress_popups

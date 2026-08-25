#!/bin/sh
set -eu

prefix=/opt/zpu
manifest=$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json
expected='ZPU Experimental CPU'

test -r "$manifest"
test -S /tmp/.X11-unix/X0
test -r /run/zpu-xauth/Xauthority

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

#!/bin/sh
set -eu

prefix=/opt/zpu
manifest=$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json
auth=/run/zpu-xauth/Xauthority
auth_mode_file=/run/zpu-xauth/mode
runtime=/run/zpu-runtime
cleanup() { rm -f "$auth" "$auth_mode_file"; }
trap cleanup EXIT HUP INT TERM

test -r "$manifest"
test -r "$prefix/lib/libvulkan_zpu.so"
test -S /tmp/.X11-unix/X0
test -r "$auth"
test -r "$auth_mode_file"
test -d "$runtime" && test "$(stat -c %u "$runtime")" -eq "$(id -u)" && test $((8#$(stat -c %a "$runtime") & 077)) -eq 0 || {
    echo 'guest XDG_RUNTIME_DIR must exist, be owned by the guest user, and be inaccessible to group/other' >&2
    exit 2
}
test -x "$prefix/bin/zpu-xcb-connect"
test ! -e /dev/dri || {
    echo 'guest /dev/dri exists: SmolVM GPU/DRM exposure is forbidden for this workflow' >&2
    exit 2
}
if find /etc/vulkan /usr/local/share/vulkan /usr/share/vulkan -type f -name '*zpu*' -print -quit 2>/dev/null | grep -q .; then
    echo 'ZPU was installed into a guest-global Vulkan configuration directory' >&2
    exit 2
fi

auth_mode=$(cat "$auth_mode_file")
case $auth_mode in untrusted|trusted) ;; *) echo "invalid guest Xauthority mode: $auth_mode" >&2; exit 2 ;; esac
authority_entries=$(xauth -f "$auth" nlist :0 | awk 'NF { count++ } END { print count + 0 }')
test "$authority_entries" -eq 1 || {
    echo "guest Xauthority must contain exactly one entry for DISPLAY=:0; found $authority_entries" >&2
    exit 2
}
env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    XDG_RUNTIME_DIR="$runtime" \
    DISPLAY=:0 \
    XAUTHORITY="$auth" \
    "$prefix/bin/zpu-xcb-connect" || {
        echo 'guest cannot authenticate and open DISPLAY=:0 with the shipped Xauthority entry; verify X SECURITY support and the mounted X11 socket' >&2
        exit 2
    }

# The clean environment is the process boundary: neither the Omarchy session nor
# any other guest process inherits ZPU's loader selection.
env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    XDG_RUNTIME_DIR="$runtime" \
    DISPLAY=:0 \
    XAUTHORITY="$auth" \
    VK_DRIVER_FILES="$manifest" \
    vulkaninfo --summary > /tmp/zpu-vulkaninfo.txt
"$(dirname "$0")/validate-vulkaninfo.sh" /tmp/zpu-vulkaninfo.txt

if test "$auth_mode" = untrusted; then
    env -i HOME="${HOME:-/root}" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" DISPLAY=:0 XAUTHORITY="$auth" \
        VK_DRIVER_FILES="$manifest" ZPU_UNTRUSTED_X11=1 ZPU_WINDOW_HOLD_SECONDS=2 "$prefix/bin/zpu-xcb-present"
else
    env -i HOME="${HOME:-/root}" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" DISPLAY=:0 XAUTHORITY="$auth" \
        VK_DRIVER_FILES="$manifest" ZPU_WINDOW_HOLD_SECONDS=2 "$prefix/bin/zpu-xcb-present"
fi

env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    XDG_RUNTIME_DIR="$runtime" \
    DISPLAY=:0 \
    XAUTHORITY="$auth" \
    VK_DRIVER_FILES="$manifest" \
    vkcube --wsi xcb --c 120 --suppress_popups

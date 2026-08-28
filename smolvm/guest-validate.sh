#!/bin/sh
set -eu

prefix=/opt/zpu
manifest=$prefix/share/vulkan/icd.d/zpu_icd.x86_64.json
auth=/run/zpu-xauth/Xauthority
auth_mode_file=/run/zpu-xauth/mode
runtime=/run/zpu-runtime
cleanup() {
    trap - EXIT
    trap '' HUP INT TERM QUIT
    rm -f "$auth" "$auth_mode_file" /tmp/zpu-vulkaninfo.txt
}
trap cleanup EXIT
trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
trap 'trap "" HUP INT TERM QUIT; exit 130' INT
trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT

for program in xauth stat find grep awk cat env id; do
    command -v "$program" >/dev/null || { echo "required guest validation tool not found: $program" >&2; exit 2; }
done

test -r "$manifest"
test -r "$prefix/lib/libvulkan_zpu.so"
test -S /tmp/.X11-unix/X0
test -f "$auth" && test ! -L "$auth" && test -r "$auth"
test -f "$auth_mode_file" && test ! -L "$auth_mode_file" && test -r "$auth_mode_file"
test -d "$runtime" && test ! -L "$runtime" && test "$(stat -c %u "$runtime")" = "$(id -u)" && test "$(stat -c %a "$runtime")" = 700 || {
    echo 'guest XDG_RUNTIME_DIR must be a real directory owned by the guest user with mode exactly 700' >&2
    exit 2
}
for protected in "$auth" "$auth_mode_file"; do
    test "$(stat -c %u "$protected")" = "$(id -u)" && test "$(stat -c %a "$protected")" = 600 || {
        echo "guest authorization metadata must be owned by the guest user with mode exactly 600: $protected" >&2
        exit 2
    }
done
test -x "$prefix/bin/zpu-xcb-connect"
test ! -e /dev/dri || {
    echo 'guest /dev/dri exists: SmolVM GPU/DRM exposure is forbidden for this workflow' >&2
    exit 2
}
global_zpu=$(find /etc/vulkan /usr/local/share/vulkan /usr/share/vulkan -type f -name '*zpu*' -print -quit 2>/dev/null || :)
if test -n "$global_zpu"; then
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
    VK_ICD_FILENAMES="$manifest" \
    vulkaninfo --summary > /tmp/zpu-vulkaninfo.txt
"$(dirname "$0")/validate-vulkaninfo.sh" /tmp/zpu-vulkaninfo.txt

if test "$auth_mode" = untrusted; then
    env -i HOME="${HOME:-/root}" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" DISPLAY=:0 XAUTHORITY="$auth" \
        VK_DRIVER_FILES="$manifest" VK_ICD_FILENAMES="$manifest" ZPU_UNTRUSTED_X11=1 ZPU_WINDOW_HOLD_SECONDS=2 "$prefix/bin/zpu-xcb-present"
else
    env -i HOME="${HOME:-/root}" PATH=/usr/bin:/bin XDG_RUNTIME_DIR="$runtime" DISPLAY=:0 XAUTHORITY="$auth" \
        VK_DRIVER_FILES="$manifest" VK_ICD_FILENAMES="$manifest" ZPU_WINDOW_HOLD_SECONDS=2 "$prefix/bin/zpu-xcb-present"
fi

env -i \
    HOME="${HOME:-/root}" \
    PATH=/usr/bin:/bin \
    XDG_RUNTIME_DIR="$runtime" \
    DISPLAY=:0 \
    XAUTHORITY="$auth" \
    VK_DRIVER_FILES="$manifest" \
    VK_ICD_FILENAMES="$manifest" \
    vkcube --wsi xcb --c 120 --suppress_popups

#!/bin/sh
set -eu

input=${1:?vulkaninfo --summary output required}
test -r "$input" || { echo "vulkaninfo output not readable: $input" >&2; exit 2; }

names=$(awk -F= '
    /^[[:space:]]*deviceName[[:space:]]*=/ {
        value=$2
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
    }
' "$input")
count=$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n + 0 }')
test "$count" -eq 1 || {
    echo "expected exactly one Vulkan device, found $count" >&2
    exit 2
}
test "$names" = 'ZPU Experimental CPU' || {
    echo "expected only ZPU Experimental CPU, found: $names" >&2
    exit 2
}
if grep -Eiq 'venus|virtio|virgl|angle|llvmpipe|lavapipe|swiftshader|opengl|egl|glx' "$input"; then
    echo 'non-ZPU or translated graphics implementation entered the validation process' >&2
    exit 2
fi
printf '%s\n' 'vulkaninfo_device=ZPU Experimental CPU' 'vulkaninfo_device_count=1'

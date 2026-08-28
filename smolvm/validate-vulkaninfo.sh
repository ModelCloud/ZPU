#!/bin/sh
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

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
types=$(awk -F= '
    /^[[:space:]]*deviceType[[:space:]]*=/ {
        value=$2
        sub(/^[[:space:]]+/, "", value)
        sub(/[[:space:]]+$/, "", value)
        print value
    }
' "$input")
count=$(printf '%s\n' "$names" | awk 'NF { n++ } END { print n + 0 }')
type_count=$(printf '%s\n' "$types" | awk 'NF { n++ } END { print n + 0 }')
test "$count" -eq 1 || {
    echo "expected exactly one Vulkan device, found $count" >&2
    exit 2
}
test "$names" = 'ZPU Experimental CPU' || {
    echo "expected only ZPU Experimental CPU, found: $names" >&2
    exit 2
}
test "$type_count" -eq 1 || {
    echo "expected exactly one Vulkan device type, found $type_count" >&2
    exit 2
}
test "$types" = 'PHYSICAL_DEVICE_TYPE_CPU' || {
    echo "ZPU Experimental CPU must report PHYSICAL_DEVICE_TYPE_CPU, found: $types" >&2
    exit 2
}
if grep -Eiq 'venus|virtio|virgl|angle|llvmpipe|lavapipe|swiftshader|opengl|egl|glx' "$input"; then
    echo 'non-ZPU or translated graphics implementation entered the validation process' >&2
    exit 2
fi
printf '%s\n' 'vulkaninfo_device=ZPU Experimental CPU' 'vulkaninfo_device_type=PHYSICAL_DEVICE_TYPE_CPU' 'vulkaninfo_device_count=1'

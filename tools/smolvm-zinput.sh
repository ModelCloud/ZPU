#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Stage and verify the zmouse/zkeyboard uinput drivers inside a SmolVM guest.
#
# The script builds static binaries on the host, copies them into the guest,
# materializes the uinput/evdev nodes omitted by SmolVM's minimal /dev, starts
# the two drivers on Unix domain sockets, and reads back a real MouseClient
# event from the resulting guest /dev/input/event* node.
#
# Usage: tools/smolvm-zinput.sh
# Set ZPU_SMOLVM_DRY_RUN=1 to print the command sequence without mutating state.

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
guest_runtime=${ZPU_GUEST_RUNTIME:-/run/zpu-runtime}
host_tools=$repo/tools
mouse_sock=${ZPU_ZMOUSE_SOCKET:-/run/zmouse.sock}
keyboard_sock=${ZPU_ZKEYBOARD_SOCKET:-/run/zkeyboard.sock}
host_verify=$repo/tools/zinput-evdev-verify.py
guest_verify=$guest_runtime/zinput-evdev-verify.py

run() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ '
        printf '%q ' "$@"
        printf '\n'
        return 0
    fi
    "$@"
}

die() {
    printf 'smolvm-zinput: %s\n' "$*" >&2
    exit 2
}

require_programs() {
    local program
    for program in smolvm gcc make python3; do
        if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            command -v "$program" >/dev/null || die "$program is required"
        fi
    done
}

machine_state() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf 'running\n'
        return 0
    fi
    smolvm machine ls --json 2>/dev/null | python3 -c 'import json, sys
machine = sys.argv[1]
try:
    data = json.load(sys.stdin)
except (json.JSONDecodeError, ValueError):
    pass
else:
    rows = data if isinstance(data, list) else data.get("machines", [])
    if isinstance(rows, list):
        for row in rows:
            if isinstance(row, dict) and row.get("name") == machine:
                print(row.get("state", "unknown"))
                sys.exit(0)
print("missing")' "$machine"
}

ensure_machine() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ ensure SmolVM machine %q is running\n' "$machine"
        return 0
    fi
    local state
    state=$(machine_state)
    case $state in
        running) ;;
        stopped) run smolvm machine start --name "$machine" ;;
        *) die "machine $machine is not running: $state" ;;
    esac
}

build_drivers() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ make -C %q zmouse zkeyboard (static) libzinput.so\n' "$host_tools"
        return 0
    fi
    run make -C "$host_tools" clean >/dev/null
    run make -C "$host_tools" CFLAGS='-O2 -Wall -Wextra -Werror -static' LDFLAGS='-static' zmouse zkeyboard
    run make -C "$host_tools" libzinput.so
}

stage_drivers() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ stage zmouse/zkeyboard and the zpu python package into %s on %s\n' "$guest_runtime" "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -c "install -d -m 755 $guest_runtime/zpu"
    run smolvm machine cp "$host_tools/zmouse" "$machine:$guest_runtime/zmouse"
    run smolvm machine cp "$host_tools/zkeyboard" "$machine:$guest_runtime/zkeyboard"
    run smolvm machine cp "$host_tools/libzinput.so" "$machine:$guest_runtime/zpu/libzinput.so"
    run smolvm machine cp "$repo/zpu/__init__.py" "$machine:$guest_runtime/zpu/__init__.py"
    run smolvm machine cp "$repo/zpu/zinput.py" "$machine:$guest_runtime/zpu/zinput.py"
    run smolvm machine exec --name "$machine" -- sh -c "chmod +x $guest_runtime/zmouse $guest_runtime/zkeyboard"
}

start_drivers() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ materialize guest /dev/uinput and start zmouse/zkeyboard on %s\n' "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -ceu '
        uinput_sysfs=/sys/class/misc/uinput/dev
        test -r "$uinput_sysfs" || {
            echo "guest kernel does not expose CONFIG_INPUT_UINPUT" >&2
            exit 2
        }
        spec=$(cat "$uinput_sysfs")
        case "$spec" in
            [0-9]*:[0-9]*) ;;
            *) echo "invalid uinput device number: $spec" >&2; exit 2 ;;
        esac
        major=${spec%:*}
        minor=${spec#*:}
        if test -e /dev/uinput && ! test -c /dev/uinput; then
            echo "/dev/uinput exists but is not a character device" >&2
            exit 2
        fi
        if ! test -e /dev/uinput; then
            mknod -m 600 /dev/uinput c "$major" "$minor"
        fi
        test -c /dev/uinput || {
            echo "failed to materialize /dev/uinput" >&2
            exit 2
        }

        # Retire only stale drivers that this helper staged in the guest.  A
        # prior launch has an unlinked socket after the next run binds the
        # pathname, so merely removing the socket would leave duplicate evdev
        # devices behind.
        for proc in /proc/[0-9]*; do
            test -r "$proc/cmdline" || continue
            cmd=$(tr "\\000" " " < "$proc/cmdline" 2>/dev/null || :)
            case "$cmd" in
                "$3"\ *|"$4"\ *) kill "${proc##*/}" 2>/dev/null || true ;;
            esac
        done
        sleep 1
        rm -f -- "$1" "$2"
        nohup "$3" -d /dev/uinput -s "$1" > /run/zpu-runtime/zmouse.log 2>&1 &
        zmouse_pid=$!
        nohup "$4" -d /dev/uinput -s "$2" > /run/zpu-runtime/zkeyboard.log 2>&1 &
        zkeyboard_pid=$!
        sleep 1
        kill -0 "$zmouse_pid" 2>/dev/null || {
            cat /run/zpu-runtime/zmouse.log >&2
            exit 2
        }
        kill -0 "$zkeyboard_pid" 2>/dev/null || {
            cat /run/zpu-runtime/zkeyboard.log >&2
            exit 2
        }
        test -S "$1" && test -S "$2" || {
            echo "zinput driver sockets were not created" >&2
            exit 2
        }
    ' sh "$mouse_sock" "$keyboard_sock" "$guest_runtime/zmouse" "$guest_runtime/zkeyboard"
}

materialize_evdev_nodes() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ materialize guest /dev/input/event* nodes and locate zmouse on %s\n' "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -ceu '
        install -d -m 755 /dev/input
        zmouse_event=
        for event_dir in /sys/class/input/event*; do
            test -r "$event_dir/dev" || continue
            event=$(basename "$event_dir")
            spec=$(cat "$event_dir/dev")
            case "$spec" in
                [0-9]*:[0-9]*) ;;
                *) echo "invalid evdev device number for $event: $spec" >&2; exit 2 ;;
            esac
            major=${spec%:*}
            minor=${spec#*:}
            node=/dev/input/$event
            if test -e "$node" && ! test -c "$node"; then
                echo "$node exists but is not a character device" >&2
                exit 2
            fi
            if ! test -e "$node"; then
                mknod -m 600 "$node" c "$major" "$minor"
            fi
            test -c "$node" || {
                echo "failed to materialize $node" >&2
                exit 2
            }
            if test "$(cat "$event_dir/device/name" 2>/dev/null || :)" = zmouse; then
                zmouse_event=$node
            fi
        done
        test -n "$zmouse_event" || {
            echo "zmouse did not register an evdev device" >&2
            exit 2
        }
        printf "%s\\n" "$zmouse_event"
    '
}

verify_mouse_client() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ send MouseClient motion and read its EV_REL events from guest /dev/input/event* on %s\n' "$machine"
        return 0
    fi
    local event_node
    event_node=$(materialize_evdev_nodes)
    run smolvm machine cp "$host_verify" "$machine:$guest_verify"
    run smolvm machine exec --name "$machine" -- env \
        PYTHONPATH="$guest_runtime" \
        python3 "$guest_verify" "$event_node" "$mouse_sock"
}

echo_dry_run_note() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        cat <<'EOF'
# To control the drivers once they are running:
#
# Shell over Unix sockets:
#   printf 'm 50 0\n' | nc -U /run/zmouse.sock       # move right
#   printf 'k 30 1\nk 30 0\n' | nc -U /run/zkeyboard.sock  # press/release 'a'
#
# Python (from inside the guest, with PYTHONPATH set to /run/zpu-runtime):
#   from zpu.zinput import MouseClient, KeyboardClient
#   with MouseClient('/run/zmouse.sock') as m:
#       m.move(50, 0)
#       m.click(1)
#   with KeyboardClient('/run/zkeyboard.sock') as k:
#       k.key_tap(30)  # 'a'
EOF
    fi
}

main() {
    require_programs
    ensure_machine
    build_drivers
    stage_drivers
    start_drivers
    verify_mouse_client
    echo_dry_run_note
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        echo "smolvm-zinput: drivers staged on $machine ($mouse_sock, $keyboard_sock)"
    fi
}

main "$@"

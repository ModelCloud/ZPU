#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0
#
# Stage and start the zmouse/zkeyboard uinput drivers inside a SmolVM guest.
#
# The script builds static binaries on the host, copies them into the guest,
# attempts to load the uinput kernel module, and starts the two drivers on
# Unix domain sockets inside the guest.
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
        printf '+ make -C %q zmouse zkeyboard (static)\n' "$host_tools"
        return 0
    fi
    run make -C "$host_tools" clean >/dev/null
    run make -C "$host_tools" CFLAGS='-O2 -Wall -Wextra -Werror -static' LDFLAGS='-static' zmouse zkeyboard
}

stage_drivers() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ stage zmouse/zkeyboard into %s on %s\n' "$guest_runtime" "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -c "install -d -m 755 $guest_runtime"
    run smolvm machine cp "$host_tools/zmouse" "$machine:$guest_runtime/zmouse"
    run smolvm machine cp "$host_tools/zkeyboard" "$machine:$guest_runtime/zkeyboard"
    run smolvm machine exec --name "$machine" -- sh -c "chmod +x $guest_runtime/zmouse $guest_runtime/zkeyboard"
}

start_drivers() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ load uinput module and start zmouse/zkeyboard on %s\n' "$machine"
        return 0
    fi
    run smolvm machine exec --name "$machine" -- sh -c "
        rm -f $mouse_sock $keyboard_sock
        modprobe uinput 2>/dev/null || true
        if [[ ! -c /dev/uinput ]]; then
            echo 'warning: /dev/uinput is not available' >&2
        fi
        nohup $guest_runtime/zmouse -d /dev/uinput -s $mouse_sock >/dev/null 2>&1 &
        nohup $guest_runtime/zkeyboard -d /dev/uinput -s $keyboard_sock >/dev/null 2>&1 &
        sleep 1
        ss -lx 2>/dev/null | grep -E 'zmouse|zkeyboard' || true
    "
}

echo_dry_run_note() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        cat <<'EOF'
# To control the drivers once they are running, send line commands to the sockets:
#   printf 'm 50 0\n' | nc -U /run/zmouse.sock       # move right
#   printf 'k 30 1\nk 30 0\n' | nc -U /run/zkeyboard.sock  # press/release 'a'
EOF
    fi
}

main() {
    require_programs
    ensure_machine
    build_drivers
    stage_drivers
    start_drivers
    echo_dry_run_note
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
        echo "smolvm-zinput: drivers staged on $machine ($mouse_sock, $keyboard_sock)"
    fi
}

main "$@"

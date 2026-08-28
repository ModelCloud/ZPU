#!/usr/bin/env bash
# Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
socket_pid=
cleanup() {
    [[ -z $socket_pid ]] || kill "$socket_pid" >/dev/null 2>&1 || true
    rm -rf "$tmp"
}
trap cleanup EXIT
install -d -m 700 "$tmp/bin" "$tmp/runtime" "$tmp/socket-root"
ln -s "$repo/test/fixtures/smolvm/v1.7.0/smolvm" "$tmp/bin/smolvm"
[[ $(PATH="$tmp/bin:/usr/bin:/bin" command -v smolvm) == "$tmp/bin/smolvm" ]] || {
    echo 'hermetic dry-run did not select its private SmolVM fixture' >&2
    exit 1
}
python3 - "$tmp/socket-root/X0" "$tmp/ready" <<'PY' &
import pathlib, signal, socket, sys, time
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
pathlib.Path(sys.argv[2]).touch()
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit()))
try:
    while True: time.sleep(1)
finally:
    sock.close()
PY
socket_pid=$!
for _ in {1..100}; do [[ -e $tmp/ready ]] && break; sleep 0.01; done
[[ -e $tmp/ready ]] || { echo 'hermetic dry-run socket fixture did not become ready' >&2; exit 1; }
env -i HOME="${HOME:-/tmp}" USER="${USER:-test}" PATH="$tmp/bin:/usr/bin:/bin" \
    XDG_RUNTIME_DIR="$tmp/runtime" DISPLAY=:0 XAUTHORITY="$tmp/Xauthority" \
    ZPU_SMOLVM_TESTING=1 ZPU_SMOLVM_TEST_SOCKET_ROOT="$tmp/socket-root" ZPU_SMOLVM_DRY_RUN=1 \
    "$repo/tools/smolvm-zpu.sh" dry-run

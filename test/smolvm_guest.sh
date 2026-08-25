#!/usr/bin/env bash
set -euo pipefail
unset VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES VK_LAYER_PATH VK_ADD_LAYER_PATH VK_IMPLICIT_LAYER_PATH VK_ADD_IMPLICIT_LAYER_PATH VK_INSTANCE_LAYERS
unset VK_LOADER_LAYERS_ENABLE VK_LOADER_LAYERS_DISABLE VK_LOADER_LAYERS_ALLOW VK_LOADER_DRIVERS_SELECT VK_LOADER_DRIVERS_DISABLE
unset LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT ZPU_REFRESH_HZ
unset ZPU_SMOLVM_MACHINE ZPU_SMOLVM_IMAGE ZPU_SMOLVM_CPUS ZPU_SMOLVM_MEMORY ZPU_SMOLVM_ALLOW_TRUSTED_X11 ZPU_SMOLVM_DRY_RUN
unset SMOLVM_FIXTURE_OMIT SMOLVM_FIXTURE_NETWORK SMOLVM_FIXTURE_STATE SMOLVM_FIXTURE_JSON_MODE SMOLVM_FIXTURE_FAIL_PACMAN
unset SMOLVM_FIXTURE_LOG SMOLVM_FIXTURE_PACMAN_SLEEP SMOLVM_FIXTURE_PACMAN_READY SMOLVM_XAUTH_NLIST_FAIL SMOLVM_XAUTH_GENERATE_FAIL
unset SMOLVM_FIXTURE_FAIL_STOP SMOLVM_FIXTURE_FAIL_STOP_ONCE_FILE SMOLVM_FIXTURE_FAIL_HELP SMOLVM_FIXTURE_CLEANUP_READY
unset SMOLVM_XAUTH_DUPLICATE_EQUIVALENT SMOLVM_XAUTH_EQUAL_KEY SMOLVM_XAUTH_MULTIPLE_NEW
unset SMOLVM_XAUTH_READY SMOLVM_XAUTH_SLEEP SMOLVM_FIXTURE_CAPTURE_AUTH_DIR SMOLVM_TAR_LONG_LIST

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
display_fixture_pid=
untracked_probe=$repo/smolvm-review-untracked-probe
cleanup_test() {
    [[ -z $display_fixture_pid ]] || kill "$display_fixture_pid" >/dev/null 2>&1 || true
    rm -f -- "$untracked_probe"
    rm -rf "$tmp"
}
trap cleanup_test EXIT
mkdir -p "$tmp/runtime"
chmod 700 "$tmp/runtime"
mkdir -p "$tmp/bin" "$tmp/socket-root"
chmod 700 "$tmp/bin" "$tmp/socket-root"
fixture=$repo/test/fixtures/smolvm/v1.7.0/smolvm
ln -s "$fixture" "$tmp/bin/smolvm"
ln -s "$repo/test/fixtures/smolvm/xauth" "$tmp/bin/xauth"
ln -s "$repo/test/fixtures/smolvm/tar" "$tmp/bin/tar"
export PATH="$tmp/bin:/usr/bin:/bin"
export XDG_RUNTIME_DIR="$tmp/runtime" DISPLAY=:0 XAUTHORITY="$tmp/fixture-Xauthority"
export ZPU_SMOLVM_TESTING=1 ZPU_SMOLVM_TEST_SOCKET_ROOT="$tmp/socket-root"
run_isolated() {
    env -i HOME="${HOME:-/tmp}" USER="${USER:-test}" PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        DISPLAY=:0 XAUTHORITY="$XAUTHORITY" ZPU_SMOLVM_TESTING=1 ZPU_SMOLVM_TEST_SOCKET_ROOT="$ZPU_SMOLVM_TEST_SOCKET_ROOT" "$@"
}
unique_line_number() {
    local description=$1 pattern=$2 input=$3 matches count
    matches=$(grep -nF -- "$pattern" <<<"$input" || true)
    count=$(grep -c . <<<"$matches" || true)
    if [[ $count -ne 1 ]]; then
        printf 'expected exactly one %s line matching %q; found %s:\n%s\n' "$description" "$pattern" "$count" "$matches" >&2
        return 1
    fi
    printf '%s\n' "${matches%%:*}"
}
last_line_number() {
    local description=$1 pattern=$2 input=$3 matches last
    matches=$(grep -nF -- "$pattern" <<<"$input" || true)
    last=${matches##*$'\n'}
    if [[ -z $last || $last == "$matches" && $matches != *:* ]]; then
        printf 'expected at least one %s line matching %q; found none\n' "$description" "$pattern" >&2
        return 1
    fi
    printf '%s\n' "${last%%:*}"
}
first_line_number() {
    local description=$1 pattern=$2 input=$3 matches first
    matches=$(grep -nF -- "$pattern" <<<"$input" || true)
    first=${matches%%$'\n'*}
    if [[ -z $first || $first != *:* ]]; then
        printf 'expected at least one %s line matching %q; found none\n' "$description" "$pattern" >&2
        return 1
    fi
    printf '%s\n' "${first%%:*}"
}
python3 - "$tmp/socket-root/X0" <<'PY' &
import os, signal, socket, sys, time
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[1])
signal.signal(signal.SIGTERM, lambda *_: (_ for _ in ()).throw(SystemExit()))
try:
    while True: time.sleep(1)
finally:
    sock.close()
    try: os.unlink(sys.argv[1])
    except FileNotFoundError: pass
PY
display_fixture_pid=$!
for _ in {1..50}; do [[ -S $tmp/socket-root/X0 ]] && break; sleep 0.02; done
[[ -S $tmp/socket-root/X0 ]] || { echo 'test-owned X11 socket fixture failed to start' >&2; exit 1; }
mkdir "$tmp/symlink-socket-root"; chmod 700 "$tmp/symlink-socket-root"
ln -s "$tmp/socket-root/X0" "$tmp/symlink-socket-root/X0"
if ZPU_SMOLVM_TEST_SOCKET_ROOT="$tmp/symlink-socket-root" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'symlinked host socket unexpectedly passed' >&2; exit 1
fi
grep -F 'host X11 socket must not be a symlink' "$tmp/err"

# Test-only socket selection is explicit and fail-closed.
if env -i HOME="$HOME" PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY=:0 XAUTHORITY="$XAUTHORITY" \
    ZPU_SMOLVM_TEST_SOCKET_ROOT="$tmp/socket-root" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'test socket override without test mode unexpectedly passed' >&2; exit 1
fi
grep -F 'requires ZPU_SMOLVM_TESTING=1' "$tmp/err"
mkdir "$tmp/empty-socket-root"; chmod 700 "$tmp/empty-socket-root"
if env -i HOME="$HOME" PATH="$PATH" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" DISPLAY=:0 XAUTHORITY="$XAUTHORITY" \
    ZPU_SMOLVM_TESTING=1 ZPU_SMOLVM_TEST_SOCKET_ROOT="$tmp/empty-socket-root" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'test mode without an X0 socket unexpectedly passed' >&2; exit 1
fi
grep -F 'must contain a test-owned X0 Unix socket' "$tmp/err"

"$repo/tools/smolvm-zpu.sh" cli-check
ln -sfn "$repo/test/fixtures/smolvm/v1.6.9/smolvm" "$tmp/bin/smolvm"
if "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'SmolVM 1.6.9 unexpectedly satisfied the minimum' >&2; exit 1
fi
grep -F 'require >= 1.7.0 for --mount-socket' "$tmp/err"
for capability in missing-mount-socket missing-smolfile missing-cp missing-stop-name missing-update-no-net; do
    ln -sfn "$repo/test/fixtures/smolvm/negative/$capability" "$tmp/bin/smolvm"
    if "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
        echo "SmolVM missing capability unexpectedly passed: $capability" >&2; exit 1
    fi
done
ln -sfn "$fixture" "$tmp/bin/smolvm"
if SMOLVM_FIXTURE_JSON_MODE=missing-network "$repo/tools/smolvm-zpu.sh" package >"$tmp/out" 2>"$tmp/err"; then
    echo 'missing persisted network field was treated as false' >&2; exit 1
fi
grep -F 'returned an invalid schema for persisted network' "$tmp/err"
for capability in create-name image cpus mem start-name update-name update-net exec-name ls-json; do
    if SMOLVM_FIXTURE_OMIT=$capability "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
        echo "SmolVM missing capability unexpectedly passed: $capability" >&2; exit 1
    fi
done
if SMOLVM_FIXTURE_FAIL_HELP=create "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'failed CLI help capture unexpectedly passed' >&2; exit 1
fi
grep -F 'failed to capture smolvm machine create --help' "$tmp/err"
if VK_DRIVER_FILES=/host/injection "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'cli-check accepted host Vulkan injection' >&2; exit 1
fi
grep -F 'refusing host graphics injection: unset VK_DRIVER_FILES' "$tmp/err"

# Static contract: guest-only build/install, no GPU flag, process-only ICD.
out=$(XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run)
digest='registry.example/omarchy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
image_out=$(XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_IMAGE="$digest" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" create)
grep -F -- "--image $digest" <<<"$image_out"
: > "$tmp/hostile.log"
ZPU_SMOLVM_MACHINE='guest--gpu-injected' ZPU_SMOLVM_IMAGE='image --net injected' SMOLVM_FIXTURE_LOG="$tmp/hostile.log" "$repo/tools/smolvm-zpu.sh" create >/dev/null
grep -F 'machine create' "$tmp/hostile.log" >/dev/null || { echo 'hostile-value create did not reach strict fixture' >&2; exit 1; }
# Passing the strict parser proves spaces and flag-looking substrings remained
# single values for --name and --image rather than becoming options.
for invalid_machine in '--flag' 'guest name' 'guest/name'; do
    if ZPU_SMOLVM_MACHINE="$invalid_machine" "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
        echo "invalid machine name unexpectedly passed: $invalid_machine" >&2; exit 1
    fi
    grep -F 'ZPU_SMOLVM_MACHINE must be' "$tmp/err" >/dev/null
done

# This is the exact hermetic harness used by `zig build smolvm-dry-run`.
hermetic_out=$(env -i HOME="${HOME:-/tmp}" USER="${USER:-test}" PATH=/usr/bin:/bin "$repo/test/smolvm_dry_run.sh")
grep -F 'machine create' <<<"$hermetic_out" >/dev/null || { echo 'hermetic build dry-run omitted create' >&2; exit 1; }
grep -F 'guest-validate.sh' <<<"$hermetic_out" >/dev/null || { echo 'hermetic build dry-run omitted launch validation' >&2; exit 1; }
python3 "$repo/tools/check-smolfile-policy.py" "$repo/smolvm/Smolfile"
for shadow in 'image = "bad"' 'network = true' '"image" = "bad"' '[machine]'$'\n''net = true'; do
    printf '%s\n' "$shadow" > "$tmp/Smolfile.bad"
    if python3 "$repo/tools/check-smolfile-policy.py" "$tmp/Smolfile.bad" >"$tmp/out" 2>"$tmp/err"; then
        echo "Smolfile shadow unexpectedly passed: $shadow" >&2; exit 1
    fi
done
grep -F -- 'machine create' <<<"$out"
create_line=$(grep -F -- 'machine create' <<<"$out")
if grep -Eq -- '(^|[[:space:]])--net([[:space:]]|$)' <<<"$create_line"; then echo 'machine was created with networking enabled' >&2; exit 1; fi
grep -F -- '--mount-socket' <<<"$out"
grep -F -- '--smolfile' <<<"$out"
grep -F -- 'machine cp' <<<"$out"
grep -F -- 'guest-build.sh' <<<"$out"
grep -F -- 'guest-validate.sh' <<<"$out"
if grep -Eq -- '(^|[[:space:]])(--gpu|--volume|-v|--stream)([[:space:]]|$)' <<<"$out"; then echo 'forbidden flag reached smolvm' >&2; exit 1; fi
# The strict fixture validates every real argv in its behavioral cases below;
# dry-run output is inspected as data and is never replayed through eval.
grep -F -- '--net' <<<"$out"
grep -F -- 'machine stop --name' <<<"$out"
grep -F -- 'machine update --name zpu-omarchy --no-net' <<<"$out"
grep -F -- 'verify persisted SmolVM state' <<<"$out"
pacman_line=$(unique_line_number 'bootstrap package install' 'pacman -Syu' "$out")
enable_line=$(unique_line_number 'network enable' 'machine update --name zpu-omarchy --net' "$out")
stop_line=$(last_line_number 'machine stop' 'machine stop --name' "$out")
update_line=$(unique_line_number 'network disable' 'machine update --name zpu-omarchy --no-net' "$out")
stopped_proof_line=$(last_line_number 'stopped-state proof' 'is stopped' "$out")
network_proof_line=$(first_line_number 'network=false proof' 'has network=false' "$out")
restart_line=$(last_line_number 'machine restart' 'machine start --name zpu-omarchy' "$out")
build_line=$(unique_line_number 'guest build' 'guest-build.sh' "$out")
[[ $(grep -cF 'machine start --name zpu-omarchy' <<<"$out") -eq 2 ]]
((enable_line < pacman_line && pacman_line < stop_line && stop_line < update_line && update_line < stopped_proof_line && stopped_proof_line < network_proof_line && network_proof_line < restart_line && restart_line < build_line)) || { echo 'network lifecycle ordering is unsafe' >&2; exit 1; }
grep -F -- 'Xauthority' <<<"$out"
[[ $(grep -cF 'prepare X SECURITY untrusted Xauthority' <<<"$out") -eq 1 ]]
auth_line=$(unique_line_number 'Xauthority preparation' 'prepare X SECURITY untrusted Xauthority' "$out")
stage_line=$(last_line_number 'package stage' '/var/lib/zpu-native-icd.tar.gz' "$out")
((stage_line < auth_line)) || { echo 'create-time Xauthority generation returned' >&2; exit 1; }
grep -F 'vulkan-headers' "$repo/tools/smolvm-zpu.sh"
grep -F '/usr/include/vulkan/vulkan.h' "$repo/smolvm/guest-build.sh"
grep -F 'tools/limited-cpus.sh zig build' "$repo/smolvm/guest-build.sh"
grep -F 'python git util-linux' "$repo/tools/smolvm-zpu.sh"
grep -F 'Networking is therefore disabled before any source' "$repo/docs/smolvm-omarchy.md"
grep -F 'full X11 client authority' "$repo/docs/smolvm-omarchy.md"
grep -F 'untrusted timeout 300' "$repo/tools/smolvm-zpu.sh"
grep -F 'bootstrap-Xauthority' "$repo/tools/smolvm-zpu.sh"
grep -F 'It never mounts' "$repo/docs/smolvm-omarchy.md"
grep -F 'ZPU_SMOLVM_ALLOW_TRUSTED_X11=1' "$repo/docs/smolvm-omarchy.md"
grep -F 'env -i' "$repo/smolvm/guest-validate.sh"
grep -F "VK_DRIVER_FILES=\"\$manifest\"" "$repo/smolvm/guest-validate.sh"
grep -F 'test ! -e /dev/dri' "$repo/smolvm/guest-validate.sh"
grep -Fq "'venus|virtio|virgl|angle|llvmpipe|lavapipe|swiftshader|opengl|egl|glx'" "$repo/smolvm/validate-vulkaninfo.sh"
if grep -Eiq 'venus|virgl|opengl|egl|glx|/dev/dri|--gpu' "$repo/smolvm/guest-build.sh"; then
    echo 'forbidden graphics path found in guest build' >&2; exit 1
fi

# Robust device enumeration: exactly one ZPU succeeds; zero, duplicate, and
# additional devices fail, including the translation/Venus fixture.
validator=$repo/smolvm/validate-vulkaninfo.sh
"$validator" "$repo/test/fixtures/smolvm/vulkaninfo/one-zpu.txt"
for bad in zero.txt duplicate-zpu.txt additional.txt wrong-type.txt; do
    if "$validator" "$repo/test/fixtures/smolvm/vulkaninfo/$bad" >"$tmp/out" 2>"$tmp/err"; then
        echo "vulkaninfo fixture unexpectedly passed: $bad" >&2; exit 1
    fi
done

# Every mutating post-bootstrap command fails closed on persisted network=true.
for command in build package stage launch; do
    if SMOLVM_FIXTURE_NETWORK=true "$repo/tools/smolvm-zpu.sh" "$command" >"$tmp/out" 2>"$tmp/err"; then
        echo "$command accepted persisted network=true" >&2; exit 1
    fi
    grep -F 'persisted network must be exactly false' "$tmp/err"
done

# Machine selection is exact: unrelated records are ignored, while zero or
# duplicate matches and absent security fields fail closed.
SMOLVM_FIXTURE_JSON_MODE=unrelated "$repo/tools/smolvm-zpu.sh" package >/dev/null
for json_mode in zero duplicate missing-network malformed non-dict-row network-string; do
    if SMOLVM_FIXTURE_JSON_MODE=$json_mode "$repo/tools/smolvm-zpu.sh" package >"$tmp/out" 2>"$tmp/err"; then
        echo "machine JSON mode unexpectedly passed: $json_mode" >&2; exit 1
    fi
    case $json_mode in
        malformed) expected_json_error='returned invalid JSON' ;;
        *) expected_json_error='returned an invalid schema' ;;
    esac
    grep -F "$expected_json_error" "$tmp/err" >/dev/null || { echo "missing actionable JSON diagnostic: $json_mode" >&2; exit 1; }
done
if SMOLVM_FIXTURE_JSON_MODE=missing-state "$repo/tools/smolvm-zpu.sh" bootstrap >"$tmp/out" 2>"$tmp/err"; then
    echo 'missing persisted state field unexpectedly passed bootstrap' >&2; exit 1
fi
grep -F 'could not prove machine stopped with persisted network=false' "$tmp/err" >/dev/null || { echo 'missing actionable state diagnostic' >&2; exit 1; }

# A failed idempotent stop is tolerated only when persisted state proves the
# machine is already stopped. Real state strings are accepted case-insensitively.
SMOLVM_FIXTURE_FAIL_STOP_ONCE_FILE="$tmp/stop.failed" SMOLVM_FIXTURE_STATE=STOPPED "$repo/tools/smolvm-zpu.sh" bootstrap >/dev/null

# A package-manager failure after network enable triggers stop + no-net update.
: > "$tmp/lifecycle.log"
if SMOLVM_FIXTURE_FAIL_PACMAN=1 SMOLVM_FIXTURE_LOG="$tmp/lifecycle.log" "$repo/tools/smolvm-zpu.sh" bootstrap >"$tmp/out" 2>"$tmp/err"; then
    echo 'injected bootstrap failure unexpectedly passed' >&2; exit 1
fi
grep -F 'machine stop --name zpu-omarchy' "$tmp/lifecycle.log"
grep -F 'machine update --name zpu-omarchy --no-net' "$tmp/lifecycle.log"
last_cleanup_stop=$(last_line_number 'cleanup stop' 'machine stop --name zpu-omarchy' "$(<"$tmp/lifecycle.log")")
last_cleanup_update=$(last_line_number 'cleanup network disable' 'machine update --name zpu-omarchy --no-net' "$(<"$tmp/lifecycle.log")")
[[ -n $last_cleanup_stop && -n $last_cleanup_update && $last_cleanup_stop -lt $last_cleanup_update ]] || { echo 'cleanup no-net update did not follow the last stop attempt' >&2; exit 1; }
grep -F 'cleanup verified machine stopped with persisted network=false' "$tmp/err"
if SMOLVM_FIXTURE_FAIL_PACMAN=1 SMOLVM_FIXTURE_STATE=running "$repo/tools/smolvm-zpu.sh" bootstrap >"$tmp/out" 2>"$tmp/err"; then
    echo 'unsecurable bootstrap cleanup unexpectedly passed' >&2; exit 1
fi
grep -F 'could not prove machine stopped with persisted network=false' "$tmp/err"

for signal_case in INT TERM HUP QUIT; do
signal_ready="$tmp/pacman.$signal_case.ready"
signal_log="$tmp/signal.$signal_case.log"
signal_err="$tmp/signal.$signal_case.err"
cleanup_ready="$tmp/cleanup.$signal_case.ready"
: > "$signal_log"
SMOLVM_FIXTURE_PACMAN_SLEEP=0.2 SMOLVM_FIXTURE_PACMAN_READY="$signal_ready" SMOLVM_FIXTURE_CLEANUP_READY="$cleanup_ready" SMOLVM_FIXTURE_LOG="$signal_log" \
python3 - "$repo/tools/smolvm-zpu.sh" "$signal_ready" "$tmp/out" "$signal_err" "$signal_case" "$cleanup_ready" <<'PY'
import os, pathlib, signal, subprocess, sys, time
with open(sys.argv[3], "wb") as stdout, open(sys.argv[4], "wb") as stderr:
    child = subprocess.Popen([sys.argv[1], "bootstrap"], stdout=stdout, stderr=stderr, start_new_session=True)
    for _ in range(400):
        if pathlib.Path(sys.argv[2]).exists():
            break
        if child.poll() is not None:
            raise SystemExit(f"bootstrap exited before readiness with status {child.returncode}")
        time.sleep(0.01)
    else:
        child.terminate()
        child.wait()
        raise SystemExit("bootstrap signal fixture never reached pacman readiness")
    selected = getattr(signal, "SIG" + sys.argv[5])
    expected = 128 + selected
    if sys.argv[5] == "INT":
        os.killpg(child.pid, selected)
    else:
        descendants = []
        pending = [child.pid]
        while pending:
            parent = pending.pop()
            path = pathlib.Path(f"/proc/{parent}/task/{parent}/children")
            children = [int(value) for value in path.read_text().split()] if path.exists() else []
            descendants.extend(children); pending.extend(children)
        os.kill(child.pid, selected)
        for pid in reversed(descendants):
            try: os.kill(pid, selected)
            except ProcessLookupError: pass
    status = child.wait()
    if sys.argv[5] == "INT" and status != 130:
        raise SystemExit(f"Ctrl-C bootstrap status was {status}, expected 130")
    if sys.argv[5] != "INT" and status == 0:
        raise SystemExit(f"{sys.argv[5]}-interrupted bootstrap unexpectedly succeeded")
for _ in range(400):
    if "cleanup verified machine stopped with persisted network=false" in pathlib.Path(sys.argv[4]).read_text(): break
    time.sleep(0.01)
else: raise SystemExit(f"{sys.argv[5]} cleanup did not complete")
PY
grep -F 'cleanup verified machine stopped with persisted network=false' "$signal_err"
grep -F 'machine update --name zpu-omarchy --no-net' "$signal_log"
# The fixture's final persisted record is the cleanup invariant.
SMOLVM_FIXTURE_STATE=stopped SMOLVM_FIXTURE_NETWORK=false "$repo/tools/smolvm-zpu.sh" package >/dev/null
done

# A repeated signal cannot interrupt the isolated emergency cleanup worker.
double_ready="$tmp/pacman.double.ready"
double_cleanup="$tmp/cleanup.double.ready"
double_err="$tmp/signal.double.err"
SMOLVM_FIXTURE_PACMAN_SLEEP=0.2 SMOLVM_FIXTURE_PACMAN_READY="$double_ready" SMOLVM_FIXTURE_CLEANUP_READY="$double_cleanup" \
python3 - "$repo/tools/smolvm-zpu.sh" "$double_ready" "$double_cleanup" "$double_err" <<'PY'
import os, pathlib, signal, subprocess, sys, time
with open(sys.argv[4], "wb") as stderr:
    child = subprocess.Popen([sys.argv[1], "bootstrap"], stdout=subprocess.DEVNULL, stderr=stderr, start_new_session=True)
    while not pathlib.Path(sys.argv[2]).exists(): time.sleep(0.01)
    os.kill(child.pid, signal.SIGINT)
    while not pathlib.Path(sys.argv[3]).exists(): time.sleep(0.01)
    path = pathlib.Path(f"/proc/{child.pid}/task/{child.pid}/children")
    for pid in [int(value) for value in path.read_text().split()] if path.exists() else []:
        try: os.kill(pid, signal.SIGTERM)
        except ProcessLookupError: pass
    child.wait()
for _ in range(400):
    if "cleanup verified machine stopped with persisted network=false" in pathlib.Path(sys.argv[4]).read_text(): break
    time.sleep(0.01)
else: raise SystemExit("second signal interrupted bootstrap security cleanup")
PY
SMOLVM_FIXTURE_STATE=stopped SMOLVM_FIXTURE_NETWORK=false "$repo/tools/smolvm-zpu.sh" package >/dev/null

# Any host loader/driver injection fails before smolvm executes.
for command in create bootstrap build package stage launch; do
    for injected in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES VK_LAYER_PATH VK_ADD_LAYER_PATH VK_IMPLICIT_LAYER_PATH VK_ADD_IMPLICIT_LAYER_PATH VK_INSTANCE_LAYERS VK_LOADER_LAYERS_ENABLE VK_LOADER_LAYERS_DISABLE VK_LOADER_LAYERS_ALLOW VK_LOADER_DRIVERS_SELECT VK_LOADER_DRIVERS_DISABLE LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT ZPU_REFRESH_HZ; do
        if run_isolated "$injected=/host/injection" "$repo/tools/smolvm-zpu.sh" "$command" >"$tmp/out" 2>"$tmp/err"; then
            echo "host $injected was accepted by $command" >&2; exit 1
        fi
        grep -F "refusing host graphics injection: unset $injected" "$tmp/err"
    done
done

# The X SECURITY result is selected by set difference: the guest gets exactly
# one entry and never receives the trusted bootstrap key.
auth_capture="$tmp/auth-capture"
mkdir -m 700 "$auth_capture"
export SMOLVM_FIXTURE_CAPTURE_AUTH_DIR="$auth_capture"

# Every supported termination signal during credential construction removes
# all host authority material and returns its conventional status.
for signal_case in INT TERM HUP QUIT; do
    auth_ready="$tmp/auth.$signal_case.ready"
    auth_err="$tmp/auth.$signal_case.err"
    SMOLVM_XAUTH_SLEEP=30 SMOLVM_XAUTH_READY="$auth_ready" \
    python3 - "$repo/tools/smolvm-zpu.sh" "$auth_ready" "$tmp/out" "$auth_err" "$signal_case" <<'PY'
import os, pathlib, signal, subprocess, sys, time
with open(sys.argv[3], "wb") as stdout, open(sys.argv[4], "wb") as stderr:
    child = subprocess.Popen([sys.argv[1], "launch"], stdout=stdout, stderr=stderr, start_new_session=True)
    for _ in range(400):
        if pathlib.Path(sys.argv[2]).exists(): break
        if child.poll() is not None:
            raise SystemExit(f"launch exited before auth readiness with status {child.returncode}")
        time.sleep(0.01)
    else:
        child.terminate(); child.wait()
        raise SystemExit("launch auth fixture never became ready")
    selected = getattr(signal, "SIG" + sys.argv[5])
    os.killpg(child.pid, selected)
    status = child.wait()
    expected = 128 + selected
    if status != expected:
        raise SystemExit(f"{sys.argv[5]} launch status was {status}, expected {expected}")
PY
    for secret_tmp in bootstrap-Xauthority before.nlist after.nlist selected.nlist host-raw.nlist after-raw.nlist trusted-keys Xauthority mode; do
        test ! -e "$tmp/runtime/zpu-smolvm/xauth/$secret_tmp" || { echo "launch signal left host credential: $secret_tmp" >&2; exit 1; }
    done
done
"$repo/tools/smolvm-zpu.sh" launch >/dev/null
guest_auth="$auth_capture/Xauthority"
auth_mode="$auth_capture/mode"
auth_absent() { [[ ! -e $guest_auth && ! -e $auth_mode ]] || { echo 'fail-closed authorization left guest credentials staged' >&2; exit 1; }; }
clear_auth() { rm -f "$guest_auth" "$auth_mode"; }
[[ ! -e $tmp/runtime/zpu-smolvm/xauth/Xauthority && ! -e $tmp/runtime/zpu-smolvm/xauth/mode ]] || { echo 'test mode weakened host authorization cleanup' >&2; exit 1; }
[[ $(awk 'NF { count++ } END { print count + 0 }' "$guest_auth") -eq 1 ]] || { echo 'positive authorization did not contain exactly one entry' >&2; exit 1; }
grep -Eq '^ffff[[:space:]]' "$guest_auth" || { echo 'guest authorization was not FamilyWild-normalized' >&2; exit 1; }
grep -Fq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$guest_auth" || { echo 'generated untrusted key was not staged' >&2; exit 1; }
grep -Fxq untrusted "$auth_mode" || { echo 'untrusted authorization mode was not recorded' >&2; exit 1; }
if grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth"; then echo 'trusted host Xauthority key leaked to guest' >&2; exit 1; fi

# Equivalent entries differing only by address family normalize and deduplicate.
clear_auth
SMOLVM_XAUTH_DUPLICATE_EQUIVALENT=1 "$repo/tools/smolvm-zpu.sh" launch >/dev/null
[[ $(awk 'NF { count++ } END { print count + 0 }' "$guest_auth") -eq 1 ]] || { echo 'normalized equivalent entries were not deduplicated' >&2; exit 1; }
grep -Fq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$guest_auth" || { echo 'duplicate-equivalent case lost generated key' >&2; exit 1; }
grep -Fxq untrusted "$auth_mode" || { echo 'duplicate-equivalent case lost untrusted mode' >&2; exit 1; }

# Xauthority query/generation attacks fail closed with no staged credential.
clear_auth
if SMOLVM_XAUTH_NLIST_FAIL=1 "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
    echo 'Xauthority query failure unexpectedly passed' >&2; exit 1
fi
grep -F 'cannot read host Xauthority' "$tmp/err"
auth_absent
for secret_tmp in bootstrap-Xauthority before.nlist after.nlist selected.nlist host-raw.nlist after-raw.nlist trusted-keys; do
    test ! -e "$tmp/runtime/zpu-smolvm/xauth/$secret_tmp"
done
for attack in equal multiple unavailable; do
    clear_auth
    case $attack in
        equal) attack_env=SMOLVM_XAUTH_EQUAL_KEY=1 ;;
        multiple) attack_env=SMOLVM_XAUTH_MULTIPLE_NEW=1 ;;
        unavailable) attack_env=SMOLVM_XAUTH_GENERATE_FAIL=1 ;;
    esac
    if env "$attack_env" "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
        echo "Xauthority attack unexpectedly passed: $attack" >&2; exit 1
    fi
    case $attack in
        equal) expected_error='returned the original trusted authorization key' ;;
        multiple) expected_error='did not produce exactly one distinct untrusted authorization entry' ;;
        unavailable) expected_error='could not generate an untrusted authorization' ;;
    esac
    grep -F "$expected_error" "$tmp/err" >/dev/null || { echo "missing actionable Xauthority diagnostic: $attack" >&2; exit 1; }
    auth_absent
done

# Failure is closed unless the separately documented trusted fallback is
# explicit; that fallback copies exactly the original trusted authorization.
for secret_tmp in bootstrap-Xauthority before.nlist after.nlist selected.nlist host-raw.nlist after-raw.nlist trusted-keys; do
    test ! -e "$tmp/runtime/zpu-smolvm/xauth/$secret_tmp"
done
clear_auth
SMOLVM_XAUTH_GENERATE_FAIL=1 ZPU_SMOLVM_ALLOW_TRUSTED_X11=1 "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"
grep -Fq 'full-trust X11 fallback enabled' "$tmp/err"
[[ $(awk 'NF { count++ } END { print count + 0 }' "$guest_auth") -eq 1 ]] || { echo 'trusted fallback did not stage exactly one entry' >&2; exit 1; }
grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth" || { echo 'explicit trusted fallback did not preserve trusted key' >&2; exit 1; }
grep -Fxq trusted "$auth_mode" || { echo 'trusted fallback mode was not recorded' >&2; exit 1; }
grep -F 'guest Xauthority must contain exactly one entry' "$repo/smolvm/guest-validate.sh"
grep -F 'guest cannot authenticate and open DISPLAY=:0' "$repo/smolvm/guest-validate.sh"
grep -F 'ZPU_UNTRUSTED_X11=1' "$repo/smolvm/guest-validate.sh"
grep -F 'trap cleanup EXIT' "$repo/smolvm/guest-validate.sh"
grep -F "exit 131' QUIT" "$repo/smolvm/guest-validate.sh"
grep -F 'xcb_present_readback=not_attempted_untrusted_x11' "$repo/test/xcb_present.c"
grep -F 'ZPU_WINDOW_HOLD_SECONDS must be an integer from 0 through 10' "$repo/test/xcb_present.c"
grep -F 'X SECURITY correctly denies `GetImage`' "$repo/docs/smolvm-omarchy.md"
if grep -Fq '8#' "$repo/smolvm/guest-validate.sh"; then echo 'guest /bin/sh script contains bash-only base arithmetic' >&2; exit 1; fi
/bin/sh -n "$repo/smolvm/guest-validate.sh"

# Runtime roots are exact-private real directories, and automatic roots are removed.
mkdir "$tmp/unsafe-runtime"
chmod 755 "$tmp/unsafe-runtime"
if XDG_RUNTIME_DIR="$tmp/unsafe-runtime" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'unsafe runtime permissions unexpectedly passed' >&2; exit 1
fi
ln -s "$tmp/runtime" "$tmp/runtime-link"
if XDG_RUNTIME_DIR="$tmp/runtime-link" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'symlink runtime root unexpectedly passed' >&2; exit 1
fi
auto_out=$(env -u XDG_RUNTIME_DIR ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run)
auto_roots=$(grep -Eo '/tmp/zpu-smolvm-runtime-[^/ ]+' <<<"$auto_out" || true)
auto_root=${auto_roots%%$'\n'*}
[[ -n $auto_root && ! -e $auto_root ]]

# A pre-planted symlink at either launcher-owned path is rejected.
symlink_base="$tmp/symlink-base"
mkdir -m 700 "$symlink_base" "$tmp/symlink-target"
ln -s "$tmp/symlink-target" "$symlink_base/zpu-smolvm"
if XDG_RUNTIME_DIR="$symlink_base" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'symlinked launcher runtime unexpectedly passed' >&2; exit 1
fi
grep -F 'runtime and authorization paths must not be symlinks' "$tmp/err"
auth_symlink_base="$tmp/auth-symlink-base"
mkdir -m 700 "$auth_symlink_base" "$auth_symlink_base/zpu-smolvm" "$tmp/auth-symlink-target"
ln -s "$tmp/auth-symlink-target" "$auth_symlink_base/zpu-smolvm/xauth"
if XDG_RUNTIME_DIR="$auth_symlink_base" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run >"$tmp/out" 2>"$tmp/err"; then
    echo 'symlinked authorization runtime unexpectedly passed' >&2; exit 1
fi
grep -F 'runtime and authorization paths must not be symlinks' "$tmp/err"

# Source transfer removes both transient copies after extraction.
touch "$untracked_probe"
if "$repo/tools/smolvm-zpu.sh" build >"$tmp/out" 2>"$tmp/err"; then
    echo 'untracked source file unexpectedly passed export' >&2; exit 1
fi
grep -F 'untracked files are forbidden' "$tmp/err"
rm -f "$untracked_probe"
if SMOLVM_TAR_LONG_LIST=1 "$repo/tools/smolvm-zpu.sh" build >"$tmp/out" 2>"$tmp/err"; then
    echo 'early artifact in long tar listing unexpectedly passed' >&2; exit 1
fi
grep -F 'source export unexpectedly contains a build artifact' "$tmp/err"
"$repo/tools/smolvm-zpu.sh" build >/dev/null
[[ ! -e $tmp/runtime/zpu-smolvm/zpu-source.tar ]] || { echo 'host source archive remained after transfer' >&2; exit 1; }
grep -F 'rm -f /var/tmp/zpu-source.tar' <<<"$out" >/dev/null || { echo 'dry-run omitted guest source archive cleanup' >&2; exit 1; }
printf '%s\n' 'SmolVM guest isolation contract passed'

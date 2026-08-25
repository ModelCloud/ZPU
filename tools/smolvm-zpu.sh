#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
image=${ZPU_SMOLVM_IMAGE:-archlinux:base-devel}
cpus=${ZPU_SMOLVM_CPUS:-8}
memory=${ZPU_SMOLVM_MEMORY:-8192}
display=${DISPLAY:-:0}
socket_root=${ZPU_SMOLVM_TEST_SOCKET_ROOT:-/tmp/.X11-unix}
host_socket=$socket_root/X0
runtime=
runtime_base=
runtime_is_temporary=0
guest_manifest=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json

die() { printf 'zpu-smolvm: %s\n' "$*" >&2; exit 2; }
[[ $machine =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die 'ZPU_SMOLVM_MACHINE must be 1-64 letters, digits, dots, underscores, or hyphens and start alphanumeric'
[[ ! -L $host_socket ]] || die "host X11 socket must not be a symlink: $host_socket"
if [[ $socket_root != /tmp/.X11-unix ]]; then
    [[ ${ZPU_SMOLVM_TESTING:-0} == 1 ]] || die 'ZPU_SMOLVM_TEST_SOCKET_ROOT is test-only and requires ZPU_SMOLVM_TESTING=1'
    [[ ! -L $socket_root && -d $socket_root && $(stat -c %u "$socket_root") == "$UID" && $(stat -c %a "$socket_root") == 700 ]] || die 'test socket root must be a real current-user directory with mode exactly 700'
    [[ -S $host_socket ]] || die 'test socket root must contain a test-owned X0 Unix socket'
fi
run() { if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }
reject_host_injection() {
    local name
    for name in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES \
        VK_LAYER_PATH VK_ADD_LAYER_PATH VK_IMPLICIT_LAYER_PATH VK_ADD_IMPLICIT_LAYER_PATH VK_INSTANCE_LAYERS \
        VK_LOADER_LAYERS_ENABLE VK_LOADER_LAYERS_DISABLE VK_LOADER_LAYERS_ALLOW \
        VK_LOADER_DRIVERS_SELECT VK_LOADER_DRIVERS_DISABLE \
        LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT ZPU_REFRESH_HZ; do
        [[ -z ${!name+x} ]] || die "refusing host graphics injection: unset $name"
    done
}
init_runtime() {
    local base owner mode
    command -v stat >/dev/null && command -v mktemp >/dev/null && command -v install >/dev/null || die 'stat, mktemp, and install are required for private runtime setup'
    if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
        base=$XDG_RUNTIME_DIR
        [[ ! -L $base && -d $base ]] || die "XDG_RUNTIME_DIR must be a real directory, not a symlink: $base"
        owner=$(stat -c %u "$base")
        mode=$(stat -c %a "$base")
        [[ $owner == "$UID" && $mode == 700 ]] || die 'XDG_RUNTIME_DIR must be owned by the current user with mode exactly 700'
    else
        base=$(mktemp -d "/tmp/zpu-smolvm-runtime-$UID.XXXXXX")
        chmod 700 "$base"
        runtime_is_temporary=1
    fi
    runtime_base=$base
    runtime=$base/zpu-smolvm
    auth_dir=$runtime/xauth
    source_archive=$runtime/zpu-source.tar
    [[ ! -L $runtime && ! -L $auth_dir ]] || die 'runtime and authorization paths must not be symlinks'
    if [[ -e $runtime ]]; then
        [[ -d $runtime && $(stat -c %u "$runtime") == "$UID" && $(stat -c %a "$runtime") == 700 ]] || die 'existing ZPU runtime must be a current-user directory with mode exactly 700'
    fi
    install -d -m 700 "$runtime"
}
cleanup_runtime() {
    trap - EXIT
    trap '' HUP INT TERM QUIT
    if [[ -n ${runtime:-} && ! -L $runtime && -d $runtime ]]; then
        rm -f -- "$runtime/source-list" "$runtime/untracked-list" "$runtime/zpu-source.tar"
        if [[ -n ${auth_dir:-} && ! -L $auth_dir && -d $auth_dir ]]; then
            rm -f -- "$auth_dir/bootstrap-Xauthority" "$auth_dir/before.nlist" "$auth_dir/after.nlist" \
                "$auth_dir/selected.nlist" "$auth_dir/host-raw.nlist" "$auth_dir/after-raw.nlist" \
                "$auth_dir/Xauthority" "$auth_dir/mode"
        fi
    fi
    if [[ $runtime_is_temporary == 1 && -n $runtime_base && ! -L $runtime_base && -d $runtime_base ]]; then
        rm -rf -- "$runtime_base"
    fi
}
require_smolvm_cli() {
    local version version_output create_help start_help stop_help update_help exec_help cp_help ls_help
    command -v smolvm >/dev/null || die 'smolvm not found (requires smol-machines/smolvm >= 1.7.0)'
    version_output=$(smolvm --version)
    [[ $version_output =~ ([0-9]+\.[0-9]+\.[0-9]+) ]] || die 'could not parse smolvm --version'
    version=${BASH_REMATCH[1]}
    [[ $(printf '%s\n' 1.7.0 "$version" | sort -V | head -1) == 1.7.0 ]] || die "smolvm $version is too old; require >= 1.7.0 for --mount-socket"
    create_help=$(smolvm machine create --help) || die 'failed to capture smolvm machine create --help'
    start_help=$(smolvm machine start --help) || die 'failed to capture smolvm machine start --help'
    stop_help=$(smolvm machine stop --help) || die 'failed to capture smolvm machine stop --help'
    update_help=$(smolvm machine update --help) || die 'failed to capture smolvm machine update --help'
    exec_help=$(smolvm machine exec --help) || die 'failed to capture smolvm machine exec --help'
    cp_help=$(smolvm machine cp --help) || die 'failed to capture smolvm machine cp --help'
    ls_help=$(smolvm machine ls --help) || die 'failed to capture smolvm machine ls --help'
    local flag
    for flag in '--name' '--smolfile' '--image' '--mount-socket'; do
        grep -F -- "$flag" <<<"$create_help" >/dev/null || die "smolvm machine create lacks required $flag support"
    done
    grep -F -- '--cpus' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --cpus support'
    grep -F -- '--mem' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --mem support'
    grep -F -- '--name' <<<"$start_help" >/dev/null || die 'smolvm machine start lacks required --name support'
    grep -F -- '--name' <<<"$stop_help" >/dev/null || die 'smolvm machine stop lacks required --name support'
    grep -F -- '--name' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --name support'
    grep -F -- '--net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --net support'
    grep -F -- '--no-net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --no-net support'
    grep -F -- '--name' <<<"$exec_help" >/dev/null || die 'smolvm machine exec lacks required --name support'
    grep -F -- 'SRC' <<<"$cp_help" >/dev/null && grep -F -- 'DST' <<<"$cp_help" >/dev/null || die 'smolvm lacks required machine cp source/destination support'
    grep -F -- '--json' <<<"$ls_help" >/dev/null || die 'smolvm machine ls lacks required --json support'
}
machine_state_matches() {
    local field=$1 expected=$2 state
    command -v python3 >/dev/null || return 3
    state=$(smolvm machine ls --json) || return 4
    SMOLVM_STATE=$state python3 - "$machine" "$field" "$expected" <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["SMOLVM_STATE"])
except (json.JSONDecodeError, ValueError):
    raise SystemExit(5)
try:
    rows = data if isinstance(data, list) else data["machines"]
    if not isinstance(rows, list) or any(not isinstance(row, dict) for row in rows):
        raise SystemExit(6)
    matches = [row for row in rows if row.get("name") == sys.argv[1]]
    if len(matches) != 1 or sys.argv[2] not in matches[0]:
        raise SystemExit(6)
    expected = {"true": True, "false": False}.get(sys.argv[3], sys.argv[3])
    actual = matches[0][sys.argv[2]]
    if sys.argv[2] == "state" and isinstance(actual, str):
        actual = actual.lower()
    if sys.argv[2] == "state" and not isinstance(actual, str):
        raise SystemExit(6)
    if sys.argv[2] == "network" and not isinstance(actual, bool):
        raise SystemExit(6)
    raise SystemExit(0 if actual == expected else 1)
except (KeyError, TypeError):
    raise SystemExit(6)
PY
}
state_error() {
    local rc=$1 field=$2 expected=$3
    case $rc in
        1) die "machine $machine persisted $field must be exactly $expected" ;;
        4) die "smolvm machine ls --json failed while checking persisted $field for machine $machine" ;;
        5) die "smolvm machine ls --json returned invalid JSON while checking persisted $field" ;;
        6) die "smolvm machine ls --json returned an invalid schema for persisted $field on machine $machine" ;;
        3) die 'python3 is required to evaluate persisted SmolVM JSON state' ;;
        *) die "unexpected SmolVM state evaluation failure $rc while checking persisted $field" ;;
    esac
}
assert_network_disabled() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ verify persisted SmolVM state for %q has network=false\n' "$machine"
        return
    fi
    local rc=0
    machine_state_matches network false || rc=$?
    [[ $rc -eq 0 ]] || state_error "$rc" network false
}
assert_machine_stopped() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ verify persisted SmolVM state for %q is stopped\n' "$machine"; return; fi
    local rc=0
    machine_state_matches state stopped || rc=$?
    [[ $rc -eq 0 ]] || state_error "$rc" state stopped
}
require_host() {
    local program
    require_auth_tools
    [[ $(uname -s) == Linux ]] || die 'this workflow currently supports Linux hosts only'
    [[ $(uname -m) == x86_64 ]] || die 'the checked-in ICD manifest currently gates x86_64 only'
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not readable and writable by this user'
    require_display
}
require_auth_tools() {
    local program
    for program in xauth stat awk sed sort comm grep mktemp install python3; do command -v "$program" >/dev/null || die "$program not found"; done
}
require_display() {
    require_auth_tools
    [[ $display == :0 ]] || die 'current socket mapping supports DISPLAY=:0 only'
    [[ -S $host_socket ]] || die "host X11/Xwayland socket $host_socket is absent"
    xauth nlist "$display" >/dev/null || die "cannot read host Xauthority for $display"
}
preflight() {
    reject_host_injection
    require_smolvm_cli
    require_host
    smolvm --version
    printf 'READY: Linux x86_64, KVM, X11 socket, xauth, clean host Vulkan environment\n'
    printf 'NOTE: launch never passes --gpu; ZPU/Venus coexistence is rejected by construction\n'
}
prepare_auth() (
    local bootstrap_auth=$auth_dir/bootstrap-Xauthority
    local before=$auth_dir/before.nlist
    local after=$auth_dir/after.nlist
    local selected=$auth_dir/selected.nlist
    local host_raw=$auth_dir/host-raw.nlist
    local after_raw=$auth_dir/after-raw.nlist
    local trusted_keys=$auth_dir/trusted-keys
    local generated_key
    local auth_mode
    local auth_complete=0
    umask 077
    cleanup_auth_files() {
        trap - EXIT
        trap '' HUP INT TERM QUIT
        rm -f "$bootstrap_auth" "$before" "$after" "$selected" "$host_raw" "$after_raw" "$trusted_keys"
        [[ $auth_complete == 1 ]] || rm -f "$auth_dir/Xauthority" "$auth_dir/mode"
    }
    trap cleanup_auth_files EXIT
    trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
    trap 'trap "" HUP INT TERM QUIT; exit 130' INT
    trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
    trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare X SECURITY untrusted Xauthority cookie with 300-second idle timeout in %q for %q\n' "$auth_dir" "$display"
        return
    fi
    [[ ! -L $auth_dir ]] || die 'authorization path must not be a symlink'
    if [[ -e $auth_dir ]]; then
        [[ -d $auth_dir && $(stat -c %u "$auth_dir") == "$UID" && $(stat -c %a "$auth_dir") == 700 ]] || die 'existing authorization path must be a current-user directory with mode exactly 700'
    fi
    install -d -m 700 "$auth_dir"
    : > "$bootstrap_auth"
    chmod 600 "$bootstrap_auth"
    xauth nlist "$display" > "$host_raw" || die "failed to read host Xauthority for $display"
    sed -e 's/^..../ffff/' "$host_raw" | awk 'NF' | sort -u > "$before"
    [[ $(awk 'NF { count++ } END { print count + 0 }' "$before") -eq 1 ]] || die "expected exactly one trusted bootstrap Xauthority entry for $display"
    xauth -f "$bootstrap_auth" nmerge - < "$before" || die 'failed to create isolated bootstrap Xauthority'
    [[ -s $bootstrap_auth ]] || die "no Xauthority cookie for $display"
    : > "$auth_dir/Xauthority"
    chmod 600 "$auth_dir/Xauthority"
    if XAUTHORITY="$bootstrap_auth" xauth -f "$bootstrap_auth" generate "$display" . untrusted timeout 300 >/dev/null 2>&1; then
        xauth -f "$bootstrap_auth" nlist "$display" > "$after_raw" || die 'failed to read generated Xauthority entries'
        sed -e 's/^..../ffff/' "$after_raw" | awk 'NF' | sort -u > "$after"
        comm -13 "$before" "$after" > "$selected" || die 'failed to compare trusted and generated Xauthority entries'
        [[ $(awk 'NF { count++ } END { print count + 0 }' "$selected") -eq 1 ]] || die 'X SECURITY generation did not produce exactly one distinct untrusted authorization entry'
        generated_key=$(awk 'NF { print $NF }' "$selected")
        awk 'NF { print $NF }' "$before" > "$trusted_keys" || die 'failed to extract trusted Xauthority key'
        if grep -Fx "$generated_key" "$trusted_keys" >/dev/null; then
            die 'X SECURITY returned the original trusted authorization key'
        fi
        auth_mode=untrusted
    elif [[ ${ZPU_SMOLVM_ALLOW_TRUSTED_X11:-0} == 1 ]]; then
        cp "$before" "$selected"
        auth_mode=trusted
        printf 'zpu-smolvm: WARNING: X SECURITY untrusted cookie unavailable; explicit full-trust X11 fallback enabled\n' >&2
    else
        die 'X server could not generate an untrusted authorization with a 300-second idle timeout; use a nested X server, or explicitly accept full X11 authority with ZPU_SMOLVM_ALLOW_TRUSTED_X11=1'
    fi
    xauth -f "$auth_dir/Xauthority" nmerge - < "$selected" || die 'failed to construct guest Xauthority'
    printf '%s\n' "$auth_mode" > "$auth_dir/mode"
    chmod 600 "$auth_dir/mode"
    [[ $(xauth -f "$auth_dir/Xauthority" nlist "$display" | awk 'NF { count++ } END { print count + 0 }') -eq 1 ]] || die 'guest Xauthority must contain exactly one entry'
    auth_complete=1
)
prepare_source() {
    local source_list=$runtime/source-list untracked_list=$runtime/untracked-list
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ export tracked HEAD source archive without build outputs to %q\n' "$source_archive"
        return
    fi
    git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || die 'commit changes before creating the immutable guest source mount'
    install -d -m 700 "$runtime"
    git -C "$repo" ls-files --others --exclude-standard > "$untracked_list" || { rm -f "$untracked_list"; die 'failed to inspect untracked source files'; }
    if [[ -s $untracked_list ]]; then
        rm -f "$untracked_list"
        die 'untracked files are forbidden when creating the immutable guest source mount; add, ignore, or remove them first'
    fi
    rm -f "$untracked_list"
    git -C "$repo" archive --format=tar --output="$source_archive" HEAD
    if ! tar -tf "$source_archive" > "$source_list"; then
        rm -f "$source_list" "$source_archive"
        die 'failed to inspect guest source archive'
    fi
    if grep -Eq '(^|/)zig-out/|\.smolmachine$|\.(so|a|o)$' "$source_list"; then
        rm -f "$source_list" "$source_archive"
        die 'source export unexpectedly contains a build artifact'
    fi
    rm -f "$source_list"
}
create() {
    reject_host_injection
    python3 "$repo/tools/check-smolfile-policy.py" "$repo/smolvm/Smolfile"
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf 'DRY-RUN: preflight is not bypassed by real commands; run `tools/smolvm-zpu.sh preflight` on the launch host\n'
    elif [[ ${ZPU_SMOLVM_TESTING:-0} == 1 ]]; then
        require_smolvm_cli
        require_display
    else
        preflight
    fi
    run smolvm machine create --name "$machine" --smolfile "$repo/smolvm/Smolfile" --image "$image" \
        --cpus "$cpus" --mem "$memory" \
        --mount-socket "$host_socket:/tmp/.X11-unix/X0"
}
bootstrap_impl() {
    reject_host_injection
    local secured=0
    cleanup_bootstrap_inner() (
        local status=$1
        local cleanup_ok=1
        trap '' INT TERM HUP QUIT
        if [[ $secured -eq 0 && ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            printf 'zpu-smolvm: securing machine after interrupted/failed bootstrap\n' >&2
            smolvm machine stop --name "$machine" >/dev/null 2>&1 || true
            if ! machine_state_matches state stopped; then
                printf 'zpu-smolvm: first emergency stop was not proven; retrying\n' >&2
                smolvm machine stop --name "$machine" >/dev/null 2>&1 || true
            fi
            # Persist no-net even when a broken state report prevents proving
            # the stop; the final checks below still report the truth.
            smolvm machine update --name "$machine" --no-net >/dev/null 2>&1 || cleanup_ok=0
            if ! machine_state_matches state stopped || ! machine_state_matches network false; then cleanup_ok=0; fi
            if [[ $cleanup_ok -eq 0 ]]; then
                printf 'zpu-smolvm: ERROR: could not prove machine stopped with persisted network=false after bootstrap failure\n' >&2
                status=2
            else
                printf 'zpu-smolvm: cleanup verified machine stopped with persisted network=false\n' >&2
            fi
        fi
        return "$status"
    )
    cleanup_bootstrap() {
        local status=$?
        trap - EXIT
        trap '' INT TERM HUP QUIT
        # The cleanup worker inherits ignored lifecycle signals before it runs,
        # so a repeated signal cannot interrupt stop/no-net/proof operations.
        cleanup_bootstrap_inner "$status"
        exit $?
    }
    trap cleanup_bootstrap EXIT
    trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
    trap 'trap "" HUP INT TERM QUIT; exit 130' INT
    trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
    trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT
    if ! run smolvm machine stop --name "$machine"; then
        assert_machine_stopped
    fi
    assert_machine_stopped
    run smolvm machine update --name "$machine" --net
    run smolvm machine start --name "$machine"
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm zig vulkan-headers vulkan-icd-loader vulkan-tools libxcb xorg-xauth python git util-linux
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --no-net
    assert_machine_stopped
    assert_network_disabled
    run smolvm machine start --name "$machine"
    assert_network_disabled
    secured=1
    trap - EXIT HUP INT TERM QUIT
}
bootstrap() {
    # Foreground execution lets the scoped traps secure the machine before
    # returning conventional 130/143 status. No asynchronous child is left to
    # inherit ignored SIGINT, and no second wait can race with reaping.
    (set -e; bootstrap_impl)
}
sync_source() {
    assert_network_disabled
    prepare_source
    run smolvm machine exec --name "$machine" -- sh -ceu 'rm -rf /mnt/zpu-source && mkdir -p /mnt/zpu-source'
    run smolvm machine cp "$source_archive" "$machine:/var/tmp/zpu-source.tar"
    run smolvm machine exec --name "$machine" -- tar -C /mnt/zpu-source -xf /var/tmp/zpu-source.tar
    run smolvm machine exec --name "$machine" -- rm -f /var/tmp/zpu-source.tar
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then rm -f -- "$source_archive"; fi
}
build_guest() { reject_host_injection; sync_source; run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-build.sh; }
package_guest() {
    reject_host_injection
    assert_network_disabled
    run smolvm machine exec --name "$machine" -- sh -ceu \
        "tar -C /opt -czf /var/lib/zpu-native-icd.tar.gz zpu && test -s /var/lib/zpu-native-icd.tar.gz"
}
stage_guest() {
    reject_host_injection
    assert_network_disabled
    run smolvm machine exec --name "$machine" -- sh -ceu \
        "rm -rf /opt/zpu && mkdir -p /opt && tar -C /opt -xzf /var/lib/zpu-native-icd.tar.gz && test -r '$guest_manifest'"
}
launch() (
    reject_host_injection
    assert_network_disabled
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ revalidate host DISPLAY=:0, X11 socket, and Xauthority\n'
    else
        rm -f "$auth_dir/Xauthority" "$auth_dir/mode"
        require_display
    fi
    cleanup_host_auth() {
        trap - EXIT
        trap '' HUP INT TERM QUIT
        rm -f -- "$auth_dir/Xauthority" "$auth_dir/mode"
    }
    trap cleanup_host_auth EXIT
    trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
    trap 'trap "" HUP INT TERM QUIT; exit 130' INT
    trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
    trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT
    prepare_auth
    run smolvm machine exec --name "$machine" -- install -d -m 700 /run/zpu-xauth /run/zpu-runtime
    run smolvm machine cp "$auth_dir/Xauthority" "$machine:/run/zpu-xauth/Xauthority"
    run smolvm machine cp "$auth_dir/mode" "$machine:/run/zpu-xauth/mode"
    run smolvm machine exec --name "$machine" -- chmod 600 /run/zpu-xauth/Xauthority /run/zpu-xauth/mode
    run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-validate.sh
)
dry_run() { ZPU_SMOLVM_DRY_RUN=1; export ZPU_SMOLVM_DRY_RUN; create; bootstrap; build_guest; package_guest; stage_guest; launch; }
usage() { printf 'usage: tools/smolvm-zpu.sh {cli-check|preflight|create|bootstrap|build|package|stage|launch|dry-run}\n' >&2; exit 2; }

command=${1:-}
case $command in
    build|launch|dry-run)
        init_runtime
        trap cleanup_runtime EXIT
        trap 'trap "" HUP INT TERM QUIT; exit 129' HUP
        trap 'trap "" HUP INT TERM QUIT; exit 130' INT
        trap 'trap "" HUP INT TERM QUIT; exit 143' TERM
        trap 'trap "" HUP INT TERM QUIT; exit 131' QUIT
        ;;
esac
case $command in
    cli-check) reject_host_injection; require_smolvm_cli ;;
    preflight) preflight ;;
    create) create ;;
    bootstrap) bootstrap ;;
    build) build_guest ;;
    package) package_guest ;;
    stage) stage_guest ;;
    launch) launch ;;
    dry-run) dry_run ;;
    *) usage ;;
esac

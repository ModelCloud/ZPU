#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
image=${ZPU_SMOLVM_IMAGE:-archlinux:base-devel}
cpus=${ZPU_SMOLVM_CPUS:-8}
memory=${ZPU_SMOLVM_MEMORY:-8192}
display=${DISPLAY:-:0}
runtime=
runtime_base=
runtime_is_temporary=0
guest_manifest=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json

die() { printf 'zpu-smolvm: %s\n' "$*" >&2; exit 2; }
run() { if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }
reject_host_injection() {
    local name
    for name in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES \
        VK_LAYER_PATH VK_IMPLICIT_LAYER_PATH VK_INSTANCE_LAYERS \
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
    install -d -m 700 "$runtime"
}
cleanup_runtime() {
    if [[ $runtime_is_temporary == 1 && -n $runtime_base && ! -L $runtime_base && -d $runtime_base ]]; then
        rm -rf -- "$runtime_base"
    fi
}
require_smolvm_cli() {
    local version version_output create_help start_help stop_help update_help exec_help cp_help ls_help
    command -v smolvm >/dev/null || die 'smolvm not found (requires smol-machines/smolvm >= 1.7.0)'
    version_output=$(smolvm --version)
    version=$(printf '%s\n' "$version_output" | sed -nE 's/^[^0-9]*([0-9]+\.[0-9]+\.[0-9]+).*$/\1/p' | sed -n '1p')
    [[ -n $version ]] || die 'could not parse smolvm --version'
    [[ $(printf '%s\n' 1.7.0 "$version" | sort -V | head -1) == 1.7.0 ]] || die "smolvm $version is too old; require >= 1.7.0 for --mount-socket"
    create_help=$(smolvm machine create --help); start_help=$(smolvm machine start --help)
    stop_help=$(smolvm machine stop --help); update_help=$(smolvm machine update --help)
    exec_help=$(smolvm machine exec --help); cp_help=$(smolvm machine cp --help); ls_help=$(smolvm machine ls --help)
    local flag
    for flag in '--name' '--smolfile' '--image' '--mount-socket'; do
        grep -F -- "$flag" <<<"$create_help" >/dev/null || die "smolvm machine create lacks required $flag support"
    done
    grep -E -- '--cpus[[:space:]]+<[^>]+>' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --cpus VALUE support'
    grep -E -- '--mem[[:space:]]+<[^>]+>' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --mem VALUE support'
    grep -E -- '--name([=[:space:]]|$)' <<<"$start_help" >/dev/null || die 'smolvm machine start lacks required --name support'
    grep -E -- '--name([=[:space:]]|$)' <<<"$stop_help" >/dev/null || die 'smolvm machine stop lacks required --name support'
    grep -E -- '--name([=[:space:]]|$)' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --name support'
    grep -F -- '--net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --net support'
    grep -F -- '--no-net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --no-net support'
    grep -E -- '--name([=[:space:]]|$)' <<<"$exec_help" >/dev/null || die 'smolvm machine exec lacks required --name support'
    grep -E -- 'machine cp.*<SRC>.*<DST>' <<<"$cp_help" >/dev/null || die 'smolvm lacks required machine cp SRC DST support'
    grep -F -- '--json' <<<"$ls_help" >/dev/null || die 'smolvm machine ls lacks required --json support'
}
machine_state_matches() {
    local field=$1 expected=$2 state
    command -v python3 >/dev/null || return 2
    state=$(smolvm machine ls --json) || return 2
    SMOLVM_STATE=$state python3 - "$machine" "$field" "$expected" <<'PY'
import json, os, sys
try:
    data = json.loads(os.environ["SMOLVM_STATE"])
    rows = data if isinstance(data, list) else data["machines"]
    matches = [row for row in rows if row.get("name") == sys.argv[1]]
    if len(matches) != 1 or sys.argv[2] not in matches[0]:
        raise SystemExit(1)
    expected = {"true": True, "false": False}.get(sys.argv[3], sys.argv[3])
    raise SystemExit(0 if matches[0][sys.argv[2]] == expected else 1)
except (KeyError, TypeError, ValueError):
    raise SystemExit(2)
PY
}
assert_network_disabled() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ verify persisted SmolVM state for %q has network=false\n' "$machine"
        return
    fi
    machine_state_matches network false || die "machine $machine must exist and persisted network must be exactly false; run bootstrap or stop it and apply machine update --no-net"
}
assert_machine_stopped() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ verify persisted SmolVM state for %q is stopped\n' "$machine"; return; fi
    machine_state_matches state stopped || die "machine $machine must be positively reported stopped"
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
    [[ -S /tmp/.X11-unix/X0 ]] || die 'host X11/Xwayland socket /tmp/.X11-unix/X0 is absent'
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
    local generated_key
    local auth_mode
    umask 077
    cleanup_auth_files() { rm -f "$bootstrap_auth" "$before" "$after" "$selected" "$host_raw" "$after_raw"; }
    trap cleanup_auth_files EXIT
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare X SECURITY untrusted Xauthority cookie with 300-second idle timeout in %q for %q\n' "$auth_dir" "$display"
        return
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
        ! awk 'NF { print $NF }' "$before" | grep -Fxq "$generated_key" || die 'X SECURITY returned the original trusted authorization key'
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
)
prepare_source() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ export tracked HEAD source archive without build outputs to %q\n' "$source_archive"
        return
    fi
    git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || die 'commit changes before creating the immutable guest source mount'
    install -d -m 700 "$runtime"
    git -C "$repo" archive --format=tar --output="$source_archive" HEAD
    if tar -tf "$source_archive" | grep -Eq '(^|/)zig-out/|\.smolmachine$|\.(so|a|o)$'; then
        die 'source export unexpectedly contains a build artifact'
    fi
}
create() {
    reject_host_injection
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf 'DRY-RUN: preflight is not bypassed by real commands; run `tools/smolvm-zpu.sh preflight` on the launch host\n'
    else
        preflight
    fi
    run smolvm machine create --name "$machine" --smolfile "$repo/smolvm/Smolfile" --image "$image" \
        --cpus "$cpus" --mem "$memory" \
        --mount-socket /tmp/.X11-unix/X0:/tmp/.X11-unix/X0
}
bootstrap_impl() {
    reject_host_injection
    local secured=0
    cleanup_bootstrap() {
        local status=$?
        local cleanup_ok=1
        trap - EXIT INT TERM
        if [[ $secured -eq 0 && ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            printf 'zpu-smolvm: securing machine after interrupted/failed bootstrap\n' >&2
            smolvm machine stop --name "$machine" >/dev/null 2>&1 || true
            if ! machine_state_matches state stopped; then
                printf 'zpu-smolvm: first emergency stop was not proven; retrying\n' >&2
                smolvm machine stop --name "$machine" >/dev/null 2>&1 || true
            fi
            if machine_state_matches state stopped; then
                smolvm machine update --name "$machine" --no-net >/dev/null 2>&1 || cleanup_ok=0
            else
                cleanup_ok=0
            fi
            if ! machine_state_matches state stopped || ! machine_state_matches network false; then cleanup_ok=0; fi
            if [[ $cleanup_ok -eq 0 ]]; then
                printf 'zpu-smolvm: ERROR: could not prove machine stopped with persisted network=false after bootstrap failure\n' >&2
                status=2
            else
                printf 'zpu-smolvm: cleanup verified machine stopped with persisted network=false\n' >&2
            fi
        fi
        exit "$status"
    }
    trap cleanup_bootstrap EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --net
    run smolvm machine start --name "$machine"
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm zig vulkan-headers vulkan-icd-loader vulkan-tools libxcb xorg-xauth python git util-linux
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --no-net
    assert_machine_stopped
    assert_network_disabled
    run smolvm machine start --name "$machine"
    secured=1
    trap - EXIT INT TERM
}
bootstrap() {
    local child status interrupted=0 cleanup_status
    (set -e; bootstrap_impl) &
    child=$!
    trap 'interrupted=130; kill -INT "$child" 2>/dev/null || true' INT
    trap 'interrupted=143; kill -TERM "$child" 2>/dev/null || true' TERM
    set +e
    wait "$child"
    status=$?
    if [[ $interrupted -ne 0 ]]; then
        wait "$child"
        cleanup_status=$?
        if [[ $cleanup_status -eq 2 ]]; then status=2; else status=$interrupted; fi
    fi
    set -e
    trap - INT TERM
    return "$status"
}
sync_source() {
    assert_network_disabled
    prepare_source
    run smolvm machine exec --name "$machine" -- sh -ceu 'rm -rf /mnt/zpu-source && mkdir -p /mnt/zpu-source'
    run smolvm machine cp "$source_archive" "$machine:/var/tmp/zpu-source.tar"
    run smolvm machine exec --name "$machine" -- tar -C /mnt/zpu-source -xf /var/tmp/zpu-source.tar
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
launch() {
    reject_host_injection
    assert_network_disabled
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ revalidate host DISPLAY=:0, X11 socket, and Xauthority\n'
    else
        require_display
    fi
    prepare_auth
    run smolvm machine exec --name "$machine" -- install -d -m 700 /run/zpu-xauth /run/zpu-runtime
    run smolvm machine cp "$auth_dir/Xauthority" "$machine:/run/zpu-xauth/Xauthority"
    run smolvm machine cp "$auth_dir/mode" "$machine:/run/zpu-xauth/mode"
    run smolvm machine exec --name "$machine" -- chmod 600 /run/zpu-xauth/Xauthority /run/zpu-xauth/mode
    run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-validate.sh
}
dry_run() { ZPU_SMOLVM_DRY_RUN=1; export ZPU_SMOLVM_DRY_RUN; create; bootstrap; build_guest; package_guest; stage_guest; launch; }
usage() { printf 'usage: tools/smolvm-zpu.sh {cli-check|preflight|create|bootstrap|build|package|stage|launch|dry-run}\n' >&2; exit 2; }

command=${1:-}
case $command in
    build|launch|dry-run) init_runtime; trap cleanup_runtime EXIT ;;
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

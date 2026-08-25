#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
image=${ZPU_SMOLVM_IMAGE:-archlinux:base-devel}
cpus=${ZPU_SMOLVM_CPUS:-8}
memory=${ZPU_SMOLVM_MEMORY:-8192}
display=${DISPLAY:-:0}
runtime=
auth_dir=$runtime/xauth
source_archive=$runtime/zpu-source.tar
guest_manifest=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json

die() { printf 'zpu-smolvm: %s\n' "$*" >&2; exit 2; }
run() { if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }
reject_host_injection() {
    local name
    for name in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES LD_PRELOAD LD_LIBRARY_PATH ZPU_REFRESH_HZ; do
        [[ -z ${!name+x} ]] || die "refusing host graphics injection: unset $name"
    done
}
init_runtime() {
    local base owner mode
    if [[ -n ${XDG_RUNTIME_DIR:-} ]]; then
        base=$XDG_RUNTIME_DIR
        [[ -d $base ]] || die "XDG_RUNTIME_DIR is not a directory: $base"
        owner=$(stat -c %u "$base")
        mode=$(stat -c %a "$base")
        [[ $owner == "$UID" && $((8#$mode & 077)) -eq 0 ]] || die 'XDG_RUNTIME_DIR must be owned by the current user and inaccessible to group/other'
    else
        base=$(mktemp -d "/tmp/zpu-smolvm-runtime-$UID.XXXXXX")
        chmod 700 "$base"
    fi
    runtime=$base/zpu-smolvm
    auth_dir=$runtime/xauth
    source_archive=$runtime/zpu-source.tar
    install -d -m 700 "$runtime"
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
    for flag in '--name <NAME>' '--smolfile <PATH>' '--image <IMAGE>' '--net' '--mount-socket <HOST_PATH:GUEST_PATH>'; do
        grep -F -- "$flag" <<<"$create_help" >/dev/null || die "smolvm machine create lacks required $flag support"
    done
    grep -E -- '--cpus[[:space:]]+<[^>]+>' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --cpus VALUE support'
    grep -E -- '--mem[[:space:]]+<[^>]+>' <<<"$create_help" >/dev/null || die 'smolvm machine create lacks required --mem VALUE support'
    grep -F -- '--name <NAME>' <<<"$start_help" >/dev/null || die 'smolvm machine start lacks required --name support'
    grep -F -- '--name <NAME>' <<<"$stop_help" >/dev/null || die 'smolvm machine stop lacks required --name support'
    grep -F -- '--name <NAME>' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --name support'
    grep -F -- '--net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --net support'
    grep -F -- '--no-net' <<<"$update_help" >/dev/null || die 'smolvm machine update lacks required --no-net support'
    grep -F -- '--name <NAME>' <<<"$exec_help" >/dev/null || die 'smolvm machine exec lacks required --name support'
    grep -E -- 'machine cp (\[OPTIONS\] )?<SRC> <DST>' <<<"$cp_help" >/dev/null || die 'smolvm lacks required machine cp SRC DST support'
    grep -F -- '--json' <<<"$ls_help" >/dev/null || die 'smolvm machine ls lacks required --json support'
}
assert_network_disabled() {
    local state
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ verify persisted SmolVM state for %q has network=false\n' "$machine"
        return
    fi
    command -v python3 >/dev/null || die 'host python3 is required to verify persisted SmolVM network state'
    state=$(smolvm machine ls --json) || die 'could not read persisted SmolVM machine state'
    SMOLVM_STATE=$state python3 - "$machine" <<'PY' || die "machine $machine must exist and persisted network must be exactly false; run bootstrap or 'smolvm machine stop --name $machine && smolvm machine update --name $machine --no-net'"
import json, os, sys
data = json.loads(os.environ["SMOLVM_STATE"])
rows = data if isinstance(data, list) else data.get("machines", [])
matches = [row for row in rows if row.get("name") == sys.argv[1]]
raise SystemExit(0 if len(matches) == 1 and matches[0].get("network") is False else 1)
PY
}
require_host() {
    command -v xauth >/dev/null || die 'xauth not found'
    [[ $(uname -s) == Linux ]] || die 'this workflow currently supports Linux hosts only'
    [[ $(uname -m) == x86_64 ]] || die 'the checked-in ICD manifest currently gates x86_64 only'
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not readable and writable by this user'
    [[ $display == :0 ]] || die 'current socket mapping supports DISPLAY=:0 only'
    [[ -S /tmp/.X11-unix/X0 ]] || die 'host X11/Xwayland socket /tmp/.X11-unix/X0 is absent'
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
    local generated_key
    local auth_mode
    umask 077
    cleanup_auth_files() { rm -f "$bootstrap_auth" "$before" "$after" "$selected"; }
    trap cleanup_auth_files EXIT
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare X SECURITY untrusted Xauthority cookie with 300-second idle timeout in %q for %q\n' "$auth_dir" "$display"
        return
    fi
    install -d -m 700 "$auth_dir"
    : > "$bootstrap_auth"
    chmod 600 "$bootstrap_auth"
    xauth nlist "$display" | sed -e 's/^..../ffff/' | xauth -f "$bootstrap_auth" nmerge -
    [[ -s $bootstrap_auth ]] || die "no Xauthority cookie for $display"
    xauth -f "$bootstrap_auth" nlist "$display" > "$before"
    [[ $(awk 'NF { count++ } END { print count + 0 }' "$before") -eq 1 ]] || die "expected exactly one trusted bootstrap Xauthority entry for $display"
    : > "$auth_dir/Xauthority"
    chmod 600 "$auth_dir/Xauthority"
    if XAUTHORITY="$bootstrap_auth" xauth -f "$bootstrap_auth" generate "$display" . untrusted timeout 300 >/dev/null 2>&1; then
        xauth -f "$bootstrap_auth" nlist "$display" > "$after"
        if grep -Fvx -f "$before" "$after" > "$selected"; then
            :
        else
            status=$?
            [[ $status -eq 1 ]] || die "failed to compare trusted and generated Xauthority entries (grep exit $status)"
        fi
        [[ $(awk 'NF { count++ } END { print count + 0 }' "$selected") -eq 1 ]] || die 'X SECURITY generation did not produce exactly one distinct untrusted authorization entry'
        generated_key=$(awk 'NF { print $NF }' "$selected")
        ! awk 'NF { print $NF }' "$before" | grep -Fxq "$generated_key" || die 'X SECURITY returned the original trusted authorization key'
        sed -i 's/^..../ffff/' "$selected"
        auth_mode=untrusted
    elif [[ ${ZPU_SMOLVM_ALLOW_TRUSTED_X11:-0} == 1 ]]; then
        cp "$before" "$selected"
        sed -i 's/^..../ffff/' "$selected"
        auth_mode=trusted
        printf 'zpu-smolvm: WARNING: X SECURITY untrusted cookie unavailable; explicit full-trust X11 fallback enabled\n' >&2
    else
        die 'X server could not generate an untrusted authorization with a 300-second idle timeout; use a nested X server, or explicitly accept full X11 authority with ZPU_SMOLVM_ALLOW_TRUSTED_X11=1'
    fi
    xauth -f "$auth_dir/Xauthority" nmerge - < "$selected"
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
    run smolvm machine create --name "$machine" --smolfile "$repo/smolvm/Smolfile" --image "$image" --net \
        --cpus "$cpus" --mem "$memory" \
        --mount-socket /tmp/.X11-unix/X0:/tmp/.X11-unix/X0
}
bootstrap() (
    reject_host_injection
    local secured=0
    cleanup_bootstrap() {
        local status=$?
        if [[ $secured -eq 0 && ${ZPU_SMOLVM_DRY_RUN:-0} != 1 ]]; then
            smolvm machine stop --name "$machine" >/dev/null 2>&1 || true
            if ! smolvm machine update --name "$machine" --no-net >/dev/null 2>&1; then
                printf 'zpu-smolvm: WARNING: emergency network-disable update failed; machine was left stopped\n' >&2
            fi
        fi
        return "$status"
    }
    trap cleanup_bootstrap EXIT
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --net
    run smolvm machine start --name "$machine"
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm zig vulkan-headers vulkan-icd-loader vulkan-tools libxcb xorg-xauth python git util-linux
    run smolvm machine stop --name "$machine"
    run smolvm machine update --name "$machine" --no-net
    secured=1
    run smolvm machine start --name "$machine"
    assert_network_disabled
)
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
    prepare_auth
    run smolvm machine exec --name "$machine" -- install -d -m 700 /run/zpu-xauth /run/zpu-runtime
    run smolvm machine cp "$auth_dir/Xauthority" "$machine:/run/zpu-xauth/Xauthority"
    run smolvm machine cp "$auth_dir/mode" "$machine:/run/zpu-xauth/mode"
    run smolvm machine exec --name "$machine" -- chmod 600 /run/zpu-xauth/Xauthority /run/zpu-xauth/mode
    run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-validate.sh
}
dry_run() { ZPU_SMOLVM_DRY_RUN=1; export ZPU_SMOLVM_DRY_RUN; create; bootstrap; build_guest; package_guest; stage_guest; launch; }
usage() { printf 'usage: tools/smolvm-zpu.sh {cli-check|preflight|create|bootstrap|build|package|stage|launch|dry-run}\n' >&2; exit 2; }

init_runtime
case ${1:-} in
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

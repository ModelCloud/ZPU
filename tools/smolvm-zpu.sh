#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
machine=${ZPU_SMOLVM_MACHINE:-zpu-omarchy}
image=${ZPU_SMOLVM_IMAGE:-archlinux:base-devel}
cpus=${ZPU_SMOLVM_CPUS:-8}
memory=${ZPU_SMOLVM_MEMORY:-8192}
display=${DISPLAY:-:0}
runtime=${XDG_RUNTIME_DIR:-/tmp}/zpu-smolvm-$UID
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
require_smolvm_cli() {
    local version
    command -v smolvm >/dev/null || die 'smolvm not found (requires smol-machines/smolvm >= 1.7.0)'
    version=$(smolvm --version | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)
    [[ -n $version ]] || die 'could not parse smolvm --version'
    [[ $(printf '%s\n' 1.7.0 "$version" | sort -V | head -1) == 1.7.0 ]] || die "smolvm $version is too old; require >= 1.7.0 for --mount-socket"
    smolvm machine create --help | grep -Fq -- '--mount-socket <HOST_PATH:GUEST_PATH>' || die 'smolvm machine create lacks required --mount-socket HOST_PATH:GUEST_PATH'
    smolvm machine create --help | grep -Fq -- '--smolfile <PATH>' || die 'smolvm machine create lacks required --smolfile support'
    smolvm machine cp --help | grep -Fq -- 'machine cp <SRC> <DST>' || die 'smolvm lacks required machine cp SRC DST support'
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
prepare_auth() {
    local bootstrap_auth=$auth_dir/bootstrap-Xauthority
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare 300-second untrusted Xauthority cookie in %q for %q\n' "$auth_dir" "$display"
        return
    fi
    install -d -m 700 "$auth_dir"
    : > "$bootstrap_auth"
    chmod 600 "$bootstrap_auth"
    xauth nlist "$display" | sed -e 's/^..../ffff/' | xauth -f "$bootstrap_auth" nmerge -
    [[ -s $bootstrap_auth ]] || die "no Xauthority cookie for $display"
    if xauth -f "$bootstrap_auth" generate "$display" . untrusted timeout 300 >/dev/null 2>&1; then
        printf '%s\n' untrusted > "$auth_dir/mode"
    elif [[ ${ZPU_SMOLVM_ALLOW_TRUSTED_X11:-0} == 1 ]]; then
        printf '%s\n' trusted-fallback > "$auth_dir/mode"
        printf 'zpu-smolvm: WARNING: X SECURITY untrusted cookie unavailable; explicit full-trust X11 fallback enabled\n' >&2
    else
        die 'X server could not generate a 300-second untrusted cookie; use a nested X server, or explicitly accept full X11 authority with ZPU_SMOLVM_ALLOW_TRUSTED_X11=1'
    fi
    : > "$auth_dir/Xauthority"
    chmod 600 "$auth_dir/Xauthority"
    xauth -f "$bootstrap_auth" nlist "$display" | sed -e 's/^..../ffff/' | xauth -f "$auth_dir/Xauthority" nmerge -
    [[ -s $auth_dir/Xauthority ]] || die "generated Xauthority cookie for $display is empty"
    rm -f "$bootstrap_auth"
}
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
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        reject_host_injection
        printf 'DRY-RUN: preflight is not bypassed by real commands; run `tools/smolvm-zpu preflight` on the launch host\n'
    else
        preflight
    fi
    prepare_auth
    run smolvm machine create --name "$machine" --smolfile "$repo/smolvm/Smolfile" --image "$image" --net \
        --cpus "$cpus" --mem "$memory" \
        --mount-socket /tmp/.X11-unix/X0:/tmp/.X11-unix/X0
}
bootstrap() {
    run smolvm machine start --name "$machine"
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm zig vulkan-headers vulkan-icd-loader vulkan-tools libxcb
}
sync_source() {
    prepare_source
    run smolvm machine exec --name "$machine" -- sh -ceu 'rm -rf /mnt/zpu-source && mkdir -p /mnt/zpu-source'
    run smolvm machine cp "$source_archive" "$machine:/var/tmp/zpu-source.tar"
    run smolvm machine exec --name "$machine" -- tar -C /mnt/zpu-source -xf /var/tmp/zpu-source.tar
}
build_guest() { sync_source; run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-build.sh; }
package_guest() {
    run smolvm machine exec --name "$machine" -- sh -ceu \
        "tar -C /opt -czf /var/lib/zpu-native-icd.tar.gz zpu && test -s /var/lib/zpu-native-icd.tar.gz"
}
stage_guest() {
    run smolvm machine exec --name "$machine" -- sh -ceu \
        "rm -rf /opt/zpu && mkdir -p /opt && tar -C /opt -xzf /var/lib/zpu-native-icd.tar.gz && test -r '$guest_manifest'"
}
launch() {
    reject_host_injection
    prepare_auth
    run smolvm machine exec --name "$machine" -- mkdir -p /run/zpu-xauth
    run smolvm machine cp "$auth_dir/Xauthority" "$machine:/run/zpu-xauth/Xauthority"
    run smolvm machine exec --name "$machine" -- /mnt/zpu-source/smolvm/guest-validate.sh
}
dry_run() { ZPU_SMOLVM_DRY_RUN=1; export ZPU_SMOLVM_DRY_RUN; create; bootstrap; build_guest; package_guest; stage_guest; launch; }
usage() { printf 'usage: tools/smolvm-zpu.sh {cli-check|preflight|create|bootstrap|build|package|stage|launch|dry-run}\n' >&2; exit 2; }

case ${1:-} in
    cli-check) require_smolvm_cli ;;
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

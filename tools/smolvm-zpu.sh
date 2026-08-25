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
source_dir=$runtime/source
guest_manifest=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json

die() { printf 'zpu-smolvm: %s\n' "$*" >&2; exit 2; }
run() { if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then printf '+ '; printf '%q ' "$@"; printf '\n'; else "$@"; fi; }
reject_host_injection() {
    local name
    for name in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES LD_PRELOAD LD_LIBRARY_PATH ZPU_REFRESH_HZ; do
        [[ -z ${!name+x} ]] || die "refusing host graphics injection: unset $name"
    done
}
require_host() {
    local version
    command -v smolvm >/dev/null || die 'smolvm not found (requires smol-machines/smolvm >= 1.6.6)'
    command -v xauth >/dev/null || die 'xauth not found'
    [[ $(uname -s) == Linux ]] || die 'this workflow currently supports Linux hosts only'
    [[ $(uname -m) == x86_64 ]] || die 'the checked-in ICD manifest currently gates x86_64 only'
    [[ -r /dev/kvm && -w /dev/kvm ]] || die '/dev/kvm is not readable and writable by this user'
    [[ $display == :0 ]] || die 'current socket mapping supports DISPLAY=:0 only'
    [[ -S /tmp/.X11-unix/X0 ]] || die 'host X11/Xwayland socket /tmp/.X11-unix/X0 is absent'
    version=$(smolvm --version | sed -nE 's/.*[^0-9]([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' | head -1)
    [[ -n $version ]] || die 'could not parse smolvm --version'
    [[ $(printf '%s\n' 1.6.6 "$version" | sort -V | head -1) == 1.6.6 ]] || die "smolvm $version is too old; require >= 1.6.6"
}
preflight() {
    reject_host_injection
    require_host
    smolvm --version
    printf 'READY: Linux x86_64, KVM, X11 socket, xauth, clean host Vulkan environment\n'
    printf 'NOTE: launch never passes --gpu; ZPU/Venus coexistence is rejected by construction\n'
}
prepare_auth() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ prepare Xauthority cookie in %q for %q\n' "$auth_dir" "$display"
        return
    fi
    install -d -m 700 "$auth_dir"
    : > "$auth_dir/Xauthority"
    chmod 600 "$auth_dir/Xauthority"
    xauth nlist "$display" | sed -e 's/^..../ffff/' | xauth -f "$auth_dir/Xauthority" nmerge -
    [[ -s $auth_dir/Xauthority ]] || die "no Xauthority cookie for $display"
}
prepare_source() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        printf '+ export tracked HEAD source without build outputs to %q\n' "$source_dir"
        return
    fi
    git -C "$repo" diff --quiet && git -C "$repo" diff --cached --quiet || die 'commit changes before creating the immutable guest source mount'
    rm -rf "$source_dir"
    install -d -m 700 "$source_dir"
    git -C "$repo" archive --format=tar HEAD | tar -C "$source_dir" -xf -
    [[ ! -e $source_dir/zig-out ]] || die 'source export unexpectedly contains zig-out'
}
create() {
    if [[ ${ZPU_SMOLVM_DRY_RUN:-0} == 1 ]]; then
        reject_host_injection
        printf 'DRY-RUN: preflight is not bypassed by real commands; run `tools/smolvm-zpu preflight` on the launch host\n'
    else
        preflight
    fi
    prepare_auth
    prepare_source
    run smolvm machine create --name "$machine" --image "$image" --net \
        --cpus "$cpus" --mem "$memory" \
        --volume "$source_dir:/mnt/zpu-source:ro" \
        --volume "$auth_dir:/run/zpu-xauth:ro" \
        --mount-socket /tmp/.X11-unix/X0:/tmp/.X11-unix/X0 \
        -- /bin/sh -c 'exec sleep infinity'
}
bootstrap() {
    run smolvm machine start --name "$machine"
    run smolvm machine exec --name "$machine" -- pacman -Syu --noconfirm zig vulkan-icd-loader vulkan-tools libxcb
}
build_guest() { run smolvm machine exec --stream --name "$machine" -- /mnt/zpu-source/smolvm/guest-build.sh; }
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
    run smolvm machine exec --stream --name "$machine" -- /mnt/zpu-source/smolvm/guest-validate.sh
}
dry_run() { ZPU_SMOLVM_DRY_RUN=1; export ZPU_SMOLVM_DRY_RUN; create; bootstrap; build_guest; package_guest; stage_guest; launch; }
usage() { printf 'usage: tools/smolvm-zpu.sh {preflight|create|bootstrap|build|package|stage|launch|dry-run}\n' >&2; exit 2; }

case ${1:-} in
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

#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime"
fixture=$repo/test/fixtures/smolvm/v1.7.0/smolvm
ln -s "$fixture" "$tmp/runtime/smolvm"
PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check
ln -sfn "$repo/test/fixtures/smolvm/v1.6.9/smolvm" "$tmp/runtime/smolvm"
if PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'SmolVM 1.6.9 unexpectedly satisfied the minimum' >&2; exit 1
fi
grep -F 'require >= 1.7.0 for --mount-socket' "$tmp/err"
for capability in missing-mount-socket missing-smolfile missing-cp missing-stop-name missing-update-no-net; do
    ln -sfn "$repo/test/fixtures/smolvm/negative/$capability" "$tmp/runtime/smolvm"
    if PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
        echo "SmolVM missing capability unexpectedly passed: $capability" >&2; exit 1
    fi
done
ln -sfn "$fixture" "$tmp/runtime/smolvm"
if VK_DRIVER_FILES=/host/injection PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'cli-check accepted host Vulkan injection' >&2; exit 1
fi
grep -F 'refusing host graphics injection: unset VK_DRIVER_FILES' "$tmp/err"

# Static contract: guest-only build/install, no GPU flag, process-only ICD.
out=$(XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run)
digest='registry.example/omarchy@sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef'
image_out=$(XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_IMAGE="$digest" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" create)
grep -F -- "--image $digest" <<<"$image_out"
if grep -Eq '^[[:space:]]*image[[:space:]]*=' "$repo/smolvm/Smolfile"; then echo 'Smolfile may shadow ZPU_SMOLVM_IMAGE' >&2; exit 1; fi
grep -F -- 'machine create' <<<"$out"
grep -F -- '--mount-socket' <<<"$out"
grep -F -- '--smolfile' <<<"$out"
grep -F -- 'machine cp' <<<"$out"
grep -F -- 'guest-build.sh' <<<"$out"
grep -F -- 'guest-validate.sh' <<<"$out"
if grep -Eq -- '(^|[[:space:]])(--gpu|--volume|-v|--stream)([[:space:]]|$)' <<<"$out"; then echo 'forbidden flag reached smolvm' >&2; exit 1; fi
while IFS= read -r line; do
    [[ $line == '+ smolvm '* ]] || continue
    eval "set -- ${line#+ }"
    [[ $1 == smolvm ]]; shift
    "$fixture" "$@"
done <<<"$out"
grep -F -- '--net' <<<"$out"
grep -F -- 'machine stop --name' <<<"$out"
grep -F -- 'machine update --name zpu-omarchy --no-net' <<<"$out"
pacman_line=$(grep -nF 'pacman -Syu' <<<"$out" | cut -d: -f1)
stop_line=$(grep -nF 'machine stop --name' <<<"$out" | cut -d: -f1)
update_line=$(grep -nF 'machine update --name zpu-omarchy --no-net' <<<"$out" | cut -d: -f1)
restart_line=$(grep -nF 'machine start --name zpu-omarchy' <<<"$out" | tail -1 | cut -d: -f1)
build_line=$(grep -nF 'guest-build.sh' <<<"$out" | cut -d: -f1)
[[ $(grep -cF 'machine start --name zpu-omarchy' <<<"$out") -eq 2 ]]
((pacman_line < stop_line && stop_line < update_line && update_line < restart_line && restart_line < build_line)) || { echo 'network teardown ordering is unsafe' >&2; exit 1; }
grep -F -- 'Xauthority' <<<"$out"
[[ $(grep -cF 'prepare X SECURITY untrusted Xauthority' <<<"$out") -eq 1 ]]
auth_line=$(grep -nF 'prepare X SECURITY untrusted Xauthority' <<<"$out" | cut -d: -f1)
stage_line=$(grep -nF '/var/lib/zpu-native-icd.tar.gz' <<<"$out" | tail -1 | cut -d: -f1)
((stage_line < auth_line)) || { echo 'create-time Xauthority generation returned' >&2; exit 1; }
grep -F 'vulkan-headers' "$repo/tools/smolvm-zpu.sh"
grep -F '/usr/include/vulkan/vulkan.h' "$repo/smolvm/guest-build.sh"
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
for bad in zero.txt duplicate-zpu.txt additional.txt; do
    if "$validator" "$repo/test/fixtures/smolvm/vulkaninfo/$bad" >"$tmp/out" 2>"$tmp/err"; then
        echo "vulkaninfo fixture unexpectedly passed: $bad" >&2; exit 1
    fi
done

# Any host loader/driver injection fails before smolvm executes.
for command in create bootstrap build package stage launch; do
    for injected in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES LD_PRELOAD LD_LIBRARY_PATH ZPU_REFRESH_HZ; do
        if env "$injected=/host/injection" "$repo/tools/smolvm-zpu.sh" "$command" >"$tmp/out" 2>"$tmp/err"; then
            echo "host $injected was accepted by $command" >&2; exit 1
        fi
        grep -F "refusing host graphics injection: unset $injected" "$tmp/err"
    done
done

# The X SECURITY result is selected by set difference: the guest gets exactly
# one entry and never receives the trusted bootstrap key.
ln -sfn "$repo/test/fixtures/smolvm/xauth" "$tmp/runtime/xauth"
PATH="$tmp/runtime:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" "$repo/tools/smolvm-zpu.sh" launch >/dev/null
guest_auth="$tmp/runtime/zpu-smolvm-$UID/xauth/Xauthority"
[[ $(awk 'NF { count++ } END { print count + 0 }' "$guest_auth") -eq 1 ]]
grep -Eq '^ffff[[:space:]]' "$guest_auth"
grep -Fq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb' "$guest_auth"
if grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth"; then echo 'trusted host Xauthority key leaked to guest' >&2; exit 1; fi

# A scanner execution error is not treated like the legitimate "no new line"
# status, and every temporary file that held the trusted key is removed.
mkdir -p "$tmp/grep-error"
ln -s "$fixture" "$tmp/grep-error/smolvm"
ln -s "$repo/test/fixtures/smolvm/xauth" "$tmp/grep-error/xauth"
ln -s "$repo/test/fixtures/smolvm/grep-error" "$tmp/grep-error/grep"
if PATH="$tmp/grep-error:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
    echo 'Xauthority set-difference scanner error unexpectedly passed' >&2; exit 1
fi
grep -F 'failed to compare trusted and generated Xauthority entries (grep exit 2)' "$tmp/err"
for secret_tmp in bootstrap-Xauthority before.nlist after.nlist selected.nlist; do
    test ! -e "$tmp/runtime/zpu-smolvm-$UID/xauth/$secret_tmp"
done
if grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth"; then echo 'trusted key survived auth error cleanup' >&2; exit 1; fi

# Failure is closed unless the separately documented trusted fallback is
# explicit; that fallback copies exactly the original trusted authorization.
if PATH="$tmp/runtime:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" SMOLVM_XAUTH_GENERATE_FAIL=1 "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
    echo 'X SECURITY failure unexpectedly fell back to trusted authority' >&2; exit 1
fi
for secret_tmp in bootstrap-Xauthority before.nlist after.nlist selected.nlist; do
    test ! -e "$tmp/runtime/zpu-smolvm-$UID/xauth/$secret_tmp"
done
if grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth"; then echo 'trusted key survived fail-closed auth cleanup' >&2; exit 1; fi
PATH="$tmp/runtime:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" SMOLVM_XAUTH_GENERATE_FAIL=1 ZPU_SMOLVM_ALLOW_TRUSTED_X11=1 "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"
grep -Fq 'full-trust X11 fallback enabled' "$tmp/err"
[[ $(awk 'NF { count++ } END { print count + 0 }' "$guest_auth") -eq 1 ]]
grep -Fq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' "$guest_auth"
grep -F 'guest Xauthority must contain exactly one entry' "$repo/smolvm/guest-validate.sh"
grep -F 'guest cannot authenticate and open DISPLAY=:0' "$repo/smolvm/guest-validate.sh"
grep -F 'ZPU_UNTRUSTED_X11=1' "$repo/smolvm/guest-validate.sh"
grep -F 'X SECURITY correctly denies `GetImage`' "$repo/docs/smolvm-omarchy.md"
printf '%s\n' 'SmolVM guest isolation contract passed'

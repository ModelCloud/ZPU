#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/runtime"
fixture=$repo/test/fixtures/smolvm/v1.7.0/smolvm
ln -s "$fixture" "$tmp/runtime/smolvm"
PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check
ln -sfn "$repo/test/fixtures/smolvm/v1.7.0/smolvm-1.6.9" "$tmp/runtime/smolvm"
if PATH="$tmp/runtime:$PATH" "$repo/tools/smolvm-zpu.sh" cli-check >"$tmp/out" 2>"$tmp/err"; then
    echo 'SmolVM 1.6.9 unexpectedly satisfied the minimum' >&2; exit 1
fi
grep -F 'require >= 1.7.0 for --mount-socket' "$tmp/err"

# Static contract: guest-only build/install, no GPU flag, process-only ICD.
out=$(XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run)
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
grep -F -- 'Xauthority' <<<"$out"
grep -F 'vulkan-headers' "$repo/tools/smolvm-zpu.sh"
grep -F '/usr/include/vulkan/vulkan.h' "$repo/smolvm/guest-build.sh"
grep -F 'Outbound networking remains enabled for the machine lifetime' "$repo/docs/smolvm-omarchy.md"
grep -F 'full X11 client authority' "$repo/docs/smolvm-omarchy.md"
grep -F 'untrusted timeout 300' "$repo/tools/smolvm-zpu.sh"
grep -F 'bootstrap-Xauthority' "$repo/tools/smolvm-zpu.sh"
grep -F 'never mounts the host authority file' "$repo/docs/smolvm-omarchy.md"
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
for injected in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES LD_PRELOAD LD_LIBRARY_PATH ZPU_REFRESH_HZ; do
    if env "$injected=/host/injection" "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
        echo "host $injected was accepted" >&2; exit 1
    fi
    grep -F "refusing host graphics injection: unset $injected" "$tmp/err"
done
printf '%s\n' 'SmolVM guest isolation contract passed'

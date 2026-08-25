#!/usr/bin/env bash
set -euo pipefail

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/runtime" "$tmp/xauth"
touch "$tmp/kvm"
chmod 666 "$tmp/kvm"

cat > "$tmp/bin/uname" <<'EOF'
#!/bin/sh
test "$1" = -s && echo Linux || echo x86_64
EOF
cat > "$tmp/bin/smolvm" <<'EOF'
#!/bin/sh
printf 'smolvm %s\n' "$*"
EOF
cat > "$tmp/bin/xauth" <<'EOF'
#!/bin/sh
case "$1" in nlist) echo '0000 00' ;; -f) printf cookie > "$2" ;; esac
EOF
chmod +x "$tmp/bin/"*

# Static contract: guest-only build/install, no GPU flag, process-only ICD.
out=$(PATH="$tmp/bin:$PATH" XDG_RUNTIME_DIR="$tmp/runtime" ZPU_SMOLVM_DRY_RUN=1 "$repo/tools/smolvm-zpu.sh" dry-run)
grep -F -- 'machine create' <<<"$out"
grep -F -- '--mount-socket' <<<"$out"
grep -F -- '/source:/mnt/zpu-source:ro' <<<"$out"
grep -F -- 'guest-build.sh' <<<"$out"
grep -F -- 'guest-validate.sh' <<<"$out"
if grep -Eq -- '(^|[[:space:]])--gpu([[:space:]]|$)' <<<"$out"; then echo 'forbidden --gpu reached smolvm' >&2; exit 1; fi
grep -F 'env -i' "$repo/smolvm/guest-validate.sh"
grep -F "VK_DRIVER_FILES=\"\$manifest\"" "$repo/smolvm/guest-validate.sh"
! rg -i 'venus|virgl|opengl|egl|glx|/dev/dri|--gpu' "$repo/smolvm/guest-build.sh" "$repo/smolvm/guest-validate.sh"

# Any host loader/driver injection fails before smolvm executes.
for injected in VK_DRIVER_FILES VK_ICD_FILENAMES VK_ADD_DRIVER_FILES LD_PRELOAD LD_LIBRARY_PATH ZPU_REFRESH_HZ; do
    if env PATH="$tmp/bin:$PATH" "$injected=/host/injection" "$repo/tools/smolvm-zpu.sh" launch >"$tmp/out" 2>"$tmp/err"; then
        echo "host $injected was accepted" >&2; exit 1
    fi
    grep -F "refusing host graphics injection: unset $injected" "$tmp/err"
done
printf '%s\n' 'SmolVM guest isolation contract passed'

<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Native ZPU in an Omarchy SmolVM guest

This workflow displays a guest `vkcube` XCB window on an Omarchy host while
the complete ZPU Vulkan path—loader, ICD manifest, shared library, CPU renderer,
and application—executes inside a hardware-virtualized SmolVM guest. The host
supplies only an X11/Xwayland Unix-socket endpoint and displays the pixels. It
does not build, install, discover, load, or execute ZPU.

## Supported boundary

The supported host is Omarchy on x86-64 Linux with KVM, its normal Hyprland
session, Xwayland enabled, `DISPLAY=:0`, an Xauthority cookie, and
`smol-machines/smolvm` 1.7.0 or newer. Version 1.7.0 is the pinned capability
floor because its published CLI provides `--mount-socket
HOST_PATH:GUEST_PATH`, `--smolfile`, and `machine cp`. SmolVM runs as the
invoking host user;
KVM, the host kernel, libkrun/libkrunfw, SmolVM, Xwayland, Hyprland, and the X11
socket relay are in the trusted computing base. The guest receives a copied
tracked-source archive, a copied short-lived Xauthority entry, and the single
X11 socket. It receives no host-directory mount, host `/dev/dri`, Vulkan files,
libraries, loader variables, home directory, Wayland socket, or broad runtime
directory.

Networking is enabled only for bootstrap package installation. Immediately
after `pacman` completes, the launcher stops the machine, runs the documented
SmolVM 1.7.0 `machine update --name NAME --no-net` operation while it is
stopped, positively proves both `state: stopped` and `network: false`, and only
then restarts it. Every build, package, stage, and launch independently
reads `machine ls --json` and fails unless the unique persisted record has
`network: false`. If package installation fails, an exit trap safely stops the
machine, rechecks its actual state, retries a safe stop when needed, applies the
same `--no-net` update, and fails loudly unless both stopped state and disabled
networking are proven. `INT` and `TERM` take the same cleanup path.
Networking is therefore disabled before any source, build, package, stage, or
launch work. The package transaction still has network authority and
must be treated as a supply-chain boundary; inspect or pin the Arch repositories
and image when reproducible inputs are required.

The launcher copies the current MIT-MAGIC-COOKIE-1 entry into a private
bootstrap authority database, then uses it to ask the X SECURITY extension for
a separate **untrusted** cookie with a 300-second idle timeout. It computes the
exact before/after entry difference, requires one newly generated key distinct
from the trusted key, normalizes that selected entry's address family to Xauthority
`FamilyWild` so it remains valid when the guest hostname differs, and constructs
a fresh guest authority file containing exactly that one entry. It never mounts
the host authority file. An
untrusted X client can create and draw its own windows, which is enough
for ZPU's XCB WSI, while the X server restricts access to resources belonging to
trusted clients. The X SECURITY timeout purges an authorization after the
configured period of disuse; it is not an absolute credential lifetime, and
active use can keep it valid. X server enforcement and a disposable nested X
server remain the strongest boundary for hostile code.

If Xwayland cannot generate or uniquely identify an untrusted cookie, launch
fails closed and does not copy the trusted bootstrap key. Setting
`ZPU_SMOLVM_ALLOW_TRUSTED_X11=1` explicitly enables a fallback cookie with
**full X11 client authority** for that display. A malicious guest with that
credential may inspect other X11 windows, capture X11-visible content or input,
synthesize input, manipulate windows, and act as the host user toward other X11
clients. The fallback entry is also normalized to `FamilyWild` for the hostname
boundary, but retains the original trusted key and is labeled `trusted` for the
guest validator. This fallback is a powerful host credential; use it only with a fully
trusted guest or a disposable nested X server.

Modern Xwayland builds may omit the X SECURITY extension entirely; verify it
with `xdpyinfo -queryExtensions | grep SECURITY`. The fail-closed launcher will
not weaken the boundary on such a server. A disposable nested X server is a
supported security boundary when it owns the expected `:0` socket, exposes
SECURITY, and is run with `-noreset`; without `-noreset`, the server can discard
the generated authorization as soon as `xauth` disconnects. This was validated
with Xephyr presented through a headless Wayland compositor. It preserves the
XCB-only ZPU path: the host compositor and nested X server display pixels but do
not load or execute ZPU.

`--gpu` is intentionally forbidden: SmolVM documents that option as
virtio-gpu/Venus. ZPU is a CPU ICD, so there is no ZPU DRM/KMS device and no
GPU passthrough. There is no OpenGL, EGL, GLX, ANGLE, virgl, or API translation
in the validation path. XCB is ZPU's currently supported WSI and Xwayland is
only the remote display server.

The host launcher rejects driver selectors, all explicit/implicit Vulkan layer
path selectors (including `VK_ADD_LAYER_PATH` and
`VK_ADD_IMPLICIT_LAYER_PATH`) and enable/disable/allow selectors, `LD_PRELOAD`, `LD_LIBRARY_PATH`,
`LD_AUDIT`, and `ZPU_REFRESH_HZ` in
its own environment. The guest source archive is an export of tracked `HEAD`,
not the live checkout, and cannot contain host `zig-out`. In the guest,
`guest-validate.sh` starts each probe with `env -i` and sets
`VK_DRIVER_FILES=/opt/zpu/share/vulkan/icd.d/zpu_icd.x86_64.json` for that
process only. It does not change `/etc`, `/usr/share/vulkan`, the Omarchy login
session, or the compositor environment. Validation also fails if `/dev/dri`
exists, if ZPU appears in a guest-global Vulkan directory, if loader output
contains a second device, or if it names Venus, virtio, virgl, ANGLE, software
translation ICDs, or OpenGL-family APIs.

## Omarchy host preparation

Keep Xwayland enabled in Omarchy. From a terminal in the logged-in graphical
session, verify `printf '%s\n' "$DISPLAY"` prints `:0` and
`test -S /tmp/.X11-unix/X0`. Install `xorg-xauth`, enable KVM access for the
current user, then install the real SmolVM CLI from the upstream project. Check
the downloaded release checksum according to upstream's instructions; SmolVM
notes that releases currently have checksums but no signatures or provenance
attestations.

```sh
sudo pacman -S --needed xorg-xauth
test -r /dev/kvm && test -w /dev/kvm
smolvm --version
tools/smolvm-zpu.sh preflight
```

The launcher default OCI userspace tag is `archlinux:base-devel`, matching
Omarchy's Arch base, but it is mutable and therefore non-deterministic. For reproducibility,
set `ZPU_SMOLVM_IMAGE` to an immutable `name@sha256:...` digest (preferably an
organization-maintained Omarchy-derived OCI root filesystem). Record that
digest with test evidence. Do not run Omarchy's interactive
bare-metal installer in this ephemeral OCI workload: it assumes systemd boot,
real seat/input devices, and ownership of the desktop. The checked-in
`smolvm/Smolfile` is actually passed to `machine create --smolfile`; it records
resources and the no-GPU policy. It deliberately has neither an image nor a
network field: the launcher is the sole source of both creation-time settings.
It always passes `--image "$ZPU_SMOLVM_IMAGE"`, so an immutable digest cannot
be shadowed by the Smolfile. Creation is network-disabled; bootstrap alone
persists a temporary `--net` window and then proves `--no-net` while stopped.
The X11 socket is supplied separately because its host path is session-specific.

## Exact lifecycle

Preview every SmolVM command without changing state, then create and provision
the persistent guest:

```sh
tools/smolvm-zpu.sh dry-run
tools/smolvm-zpu.sh create
tools/smolvm-zpu.sh bootstrap
tools/smolvm-zpu.sh build
tools/smolvm-zpu.sh package
tools/smolvm-zpu.sh stage
tools/smolvm-zpu.sh launch
```

`bootstrap` stops the machine, explicitly persists `--net`, starts it, installs
the required packages, stops it,
persists `--no-net`, proves stopped/offline persisted JSON state, and only then
restarts it. Do not proceed to `build` if that command fails; failure cleanup
returns nonzero unless it can prove the machine is both stopped and offline.

Commit the intended source first: `build` refuses a dirty index or worktree,
exports tracked `HEAD` to a source-only tar archive, rejects binary/build
entries, copies the archive with `smolvm machine cp`, and extracts it into
guest-private storage. There is no host-directory volume mount. Zig then runs
only in the guest. `package` creates `/var/lib/zpu-native-icd.tar.gz` inside the
guest;
`stage` installs that guest archive to `/opt/zpu`. Neither artifact is copied to
the host. `launch` first checks `vulkaninfo --summary` names exactly `ZPU
Experimental CPU`, opens a two-second 2D clear/present window, then opens a
120-frame 3D `vkcube` window. X SECURITY correctly denies `GetImage` to the
untrusted guest, so that mode reports unambiguous submitted-pixel evidence but
does not claim readback. The explicit trusted fallback retains exact pixel
readback. Guest authorization files are deleted on validation success or
failure. The repo's
deterministic `zpu-demo` is also built into `/opt/zpu/bin/zpu-demo` and may be
run inside the guest. These windows separately exercise XCB 2D image transport
and ZPU's vkcube-specific 3D CPU rasterizer.

Machine name, image, CPU count, and memory can be set with
`ZPU_SMOLVM_MACHINE`, `ZPU_SMOLVM_IMAGE`, `ZPU_SMOLVM_CPUS`, and
`ZPU_SMOLVM_MEMORY`. Delete or export the machine only with explicit SmolVM
commands. `.smolmachine` files and staging/build outputs are ignored and must
not be committed.

## Hardware and software gates

Preflight is fail-closed and reports the first remediation:

- Linux x86-64, because the checked-in ICD manifest is x86-64;
- `/dev/kvm` readable and writable by the invoking user;
- SmolVM 1.7.0 or newer available as `smolvm`, with help output proving
  `--mount-socket HOST_PATH:GUEST_PATH`, `--smolfile`, and `machine cp`;
- Omarchy's Xwayland socket at `/tmp/.X11-unix/X0`, `DISPLAY=:0`, and a usable
  Xauthority cookie;
- no host graphics-loader injection variables, and no host build output in the
  immutable source export;
- guest Arch package network access only during bootstrap, followed by a
  successful stop/update-`--no-net`/restart sequence;
- guest Zig exactly 0.16.0, `vulkan-headers`, Vulkan loader/tools, `libxcb`, and
  `xorg-xauth` packages, with readable Vulkan and XCB development headers (if the
  rolling Arch `zig` package has moved, install upstream's 0.16.0 archive in
  the guest and place it first on `PATH` before `build`), plus Python, Git, and
  util-linux (`taskset`/`lscpu`) required by the repository CPU limiter;
- guest-installed ZPU manifest/library and exact device-name discovery;
- exactly one guest Xauthority entry that successfully opens `DISPLAY=:0`
  through a Vulkan-independent XCB probe, followed by an XCB surface capable of
  displaying the validation window.

Run `zig build smolvm-guest-test` for the no-hardware command/isolation gate and
`zig build smolvm-dry-run` for the generated lifecycle. A real Vulkan smoke is
`tools/smolvm-zpu.sh launch` and cannot be claimed without KVM, SmolVM, and the
active Omarchy display.

Image, networking, CPU, and memory are deliberately absent from
`smolvm/Smolfile`. The launcher owns those settings, supplies explicit
`--image`, `--cpus`, and `--mem` values, and preflight capability-gates each
flag. This avoids relying on undocumented Smolfile/CLI precedence.
The source transfer is commit-bound: staged or unstaged changes and untracked
files are rejected, archive contents are fully materialized before artifact
checks, and both host and guest transfer archives are removed after use.

During bootstrap, INT, TERM, HUP, and QUIT synchronously enter an
interrupt-resistant cleanup that attempts stop, persists `--no-net`, and proves
both stopped state and `network=false`. Credential preparation and launch handle
the same signals and remove all temporary host authority material.

`zig build smolvm-dry-run` invokes `test/smolvm_dry_run.sh`, which constructs a
private socket/runtime and fixture-only `PATH`, then runs the launcher under
`env -i`. It needs neither an installed SmolVM nor a live X server and cannot
mutate a machine. Calling `tools/smolvm-zpu.sh dry-run` directly remains the
production command preview; it is also non-mutating but uses production path
defaults unless explicit test mode is selected.

The no-hardware isolation gate does not inspect ambient `DISPLAY`,
`XAUTHORITY`, or `/tmp/.X11-unix/X0`. It sets `ZPU_SMOLVM_TESTING=1` and a
private `ZPU_SMOLVM_TEST_SOCKET_ROOT` containing a test-owned Unix socket. That
override is rejected outside explicit test mode; production preflight and
launch remain fixed to the real `/tmp/.X11-unix/X0` boundary.

## Current compositor limitation and roadmap

This does **not** run Hyprland or the complete Omarchy compositor inside the
guest. With SmolVM's GPU device disabled there is no DRM/KMS device on which a
Wayland compositor can own a seat or scan out, and enabling it would introduce
Venus in violation of this boundary. The supported graphical milestone is an
Omarchy-host-visible guest XCB Vulkan application window through Xwayland.

No real Omarchy image or Hyprland session was available in the reference test
environment. The tested substitute was an Arch guest displaying through nested
Xephyr on headless Weston/Xwayland; this validates the Vulkan/XCB and security
assumptions, but the real Omarchy/Hyprland host session remains an explicit
hardware/session integration gate.

The roadmap stays Vulkan-only: generalize ZPU's SPIR-V and pipeline execution,
broaden Vulkan WSI beyond XCB when a guest-display transport can preserve the
same boundary, add more Vulkan applications, and investigate conformance. It
does not add OpenGL compatibility, translation layers, Venus, or a ZPU
DRM/KMS/display driver.

## Licensing

ZPU and these scripts are MIT licensed under the repository `LICENSE`.
SmolVM/libkrun components are separately distributed by their upstream authors
(SmolVM is Apache-2.0); Arch/Omarchy, Zig, Vulkan loader/tools, libxcb, and each
OCI image retain their own licenses. Packaging ZPU inside a guest does not
relicense or redistribute those dependencies. Review the selected image's
package license metadata before distributing a `.smolmachine`; this repository
does not ship one.

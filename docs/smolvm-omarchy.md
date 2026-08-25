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
stopped, and restarts it. Networking is therefore disabled before any source,
build, package, stage, or launch work. Failure of stop, update, or restart aborts
the bootstrap chain. The package transaction still has network authority and
must be treated as a supply-chain boundary; inspect or pin the Arch repositories
and image when reproducible inputs are required.

The launcher copies the current MIT-MAGIC-COOKIE-1 entry into a private
bootstrap authority database, then uses it to ask the X SECURITY extension for
a separate **untrusted** cookie with a 300-second idle timeout. It computes the
exact before/after entry difference, requires one newly generated key distinct
from the trusted key, normalizes only that selected entry to Xauthority
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
clients. This fallback is a powerful host credential; use it only with a fully
trusted guest or a disposable nested X server.

`--gpu` is intentionally forbidden: SmolVM documents that option as
virtio-gpu/Venus. ZPU is a CPU ICD, so there is no ZPU DRM/KMS device and no
GPU passthrough. There is no OpenGL, EGL, GLX, ANGLE, virgl, or API translation
in the validation path. XCB is ZPU's currently supported WSI and Xwayland is
only the remote display server.

The host launcher rejects `VK_DRIVER_FILES`, legacy `VK_ICD_FILENAMES`,
`VK_ADD_DRIVER_FILES`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, and `ZPU_REFRESH_HZ` in
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
It always passes `--image "$ZPU_SMOLVM_IMAGE"` and `--net`, so an immutable
digest cannot be shadowed by the Smolfile; bootstrap later persists `--no-net`.
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

`bootstrap` starts the machine, installs the required packages, stops it,
persists `--no-net`, and restarts it. Do not proceed to `build` if that command
fails.

Commit the intended source first: `build` refuses a dirty index or worktree,
exports tracked `HEAD` to a source-only tar archive, rejects binary/build
entries, copies the archive with `smolvm machine cp`, and extracts it into
guest-private storage. There is no host-directory volume mount. Zig then runs
only in the guest. `package` creates `/var/lib/zpu-native-icd.tar.gz` inside the
guest;
`stage` installs that guest archive to `/opt/zpu`. Neither artifact is copied to
the host. `launch` first checks `vulkaninfo --summary` names exactly `ZPU
Experimental CPU`, opens a two-second 2D clear/present window whose pixel is
read back and checked, then opens a 120-frame 3D `vkcube` window. The repo's
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
  the guest and place it first on `PATH` before `build`);
- guest-installed ZPU manifest/library and exact device-name discovery;
- exactly one guest Xauthority entry that successfully opens `DISPLAY=:0`
  through a Vulkan-independent XCB probe, followed by an XCB surface capable of
  displaying the validation window.

Run `zig build smolvm-guest-test` for the no-hardware command/isolation gate and
`zig build smolvm-dry-run` for the generated lifecycle. A real Vulkan smoke is
`tools/smolvm-zpu.sh launch` and cannot be claimed without KVM, SmolVM, and the
active Omarchy display.

## Current compositor limitation and roadmap

This does **not** run Hyprland or the complete Omarchy compositor inside the
guest. With SmolVM's GPU device disabled there is no DRM/KMS device on which a
Wayland compositor can own a seat or scan out, and enabling it would introduce
Venus in violation of this boundary. The supported graphical milestone is an
Omarchy-host-visible guest XCB Vulkan application window through Xwayland.

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

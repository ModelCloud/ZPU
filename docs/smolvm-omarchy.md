# Native ZPU in an Omarchy SmolVM guest

This workflow displays a guest `vkcube` XCB window on an Omarchy host while
the complete ZPU Vulkan path—loader, ICD manifest, shared library, CPU renderer,
and application—executes inside a hardware-virtualized SmolVM guest. The host
supplies only an X11/Xwayland Unix-socket endpoint and displays the pixels. It
does not build, install, discover, load, or execute ZPU.

## Supported boundary

The supported host is Omarchy on x86-64 Linux with KVM, its normal Hyprland
session, Xwayland enabled, `DISPLAY=:0`, an Xauthority cookie, and
`smol-machines/smolvm` 1.6.6 or newer. SmolVM runs as the invoking host user;
KVM, the host kernel, libkrun/libkrunfw, SmolVM, Xwayland, Hyprland, and the X11
socket relay are in the trusted computing base. The guest receives read-only
access to this repository and the one-cookie Xauthority directory, plus the
single X11 socket. The current SmolVM CLI records networking at machine creation, so this machine
continues to have outbound networking after bootstrap; stop it when validation
is complete. It receives no host `/dev/dri`, Vulkan files, libraries, loader variables,
credentials, home directory, Wayland socket, or broad runtime directory.

`--gpu` is intentionally forbidden: SmolVM documents that option as
virtio-gpu/Venus. ZPU is a CPU ICD, so there is no ZPU DRM/KMS device and no
GPU passthrough. There is no OpenGL, EGL, GLX, ANGLE, virgl, or API translation
in the validation path. XCB is ZPU's currently supported WSI and Xwayland is
only the remote display server.

The host launcher rejects `VK_DRIVER_FILES`, legacy `VK_ICD_FILENAMES`,
`VK_ADD_DRIVER_FILES`, `LD_PRELOAD`, `LD_LIBRARY_PATH`, and `ZPU_REFRESH_HZ` in
its own environment. The read-only guest source mount is an export of tracked
`HEAD`, not the live checkout, and cannot contain host `zig-out`. In the guest,
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

The default OCI userspace is `archlinux:base-devel`, matching Omarchy's Arch
base. For an organization-maintained Omarchy-derived OCI root filesystem, set
`ZPU_SMOLVM_IMAGE` to its immutable digest. Do not run Omarchy's interactive
bare-metal installer in this ephemeral OCI workload: it assumes systemd boot,
real seat/input devices, and ownership of the desktop. The checked-in
`smolvm/Smolfile` records the resource and no-GPU policy; the launcher supplies
the dynamic absolute mounts that a portable Smolfile cannot.

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

Commit the intended source first: `create` refuses a dirty index or worktree and
exports tracked `HEAD` without ignored build output. `build` copies that
read-only source mount to guest-private storage and invokes
Zig there. `package` creates `/var/lib/zpu-native-icd.tar.gz` inside the guest;
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
- SmolVM 1.6.6 or newer available as `smolvm`;
- Omarchy's Xwayland socket at `/tmp/.X11-unix/X0`, `DISPLAY=:0`, and a usable
  Xauthority cookie;
- no host graphics-loader injection variables, and no host build output in the
  immutable source export;
- guest Arch package network access during bootstrap;
- guest Zig exactly 0.16.0, Vulkan loader/tools, and `libxcb` packages (if the
  rolling Arch `zig` package has moved, install upstream's 0.16.0 archive in
  the guest and place it first on `PATH` before `build`);
- guest-installed ZPU manifest/library and exact device-name discovery;
- an XCB surface capable of displaying the validation window.

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

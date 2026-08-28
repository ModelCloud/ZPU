<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Desktop readiness

ZPU now reaches its first Vulkan-window compatibility milestone. The ICD exposes
XCB window-system integration (WSI), swapchains, color targets, binary
semaphores, render objects, draw commands, and the acquire/submit/present
lifecycle used by `vkcube`.

Xfce is not itself a direct Vulkan acceptance test. `xfwm4` is an X11 window
manager with an embedded compositor built around X.org extensions, as described
by the [Xfce project](https://docs.xfce.org/xfce/xfwm4/introduction). A complete
physical desktop path would also require an X server backed by a kernel
DRM/KMS driver, while ZPU is intentionally a userspace Vulkan ICD. Running Xfce
on Xvfb would test Xfce and the virtual framebuffer, not ZPU.

The first honest integration target is therefore a tiny Vulkan application
such as `vkcube` under a virtual X11 or Wayland server. That test becomes useful
only after the ICD can create a platform surface, render into a color attachment,
and present swapchain images.

## Reproducible probe

Build and query the current boundary with:

```sh
tools/limited-cpus.sh zig build desktop-probe
```

The probe loads only ZPU through the system Vulkan loader and reports:

- a graphics queue;
- `VK_KHR_surface` and an X11 or Wayland surface extension;
- `VK_KHR_swapchain`;
- optimal-tiled BGRA8 color-attachment support;
- the core render-pass, shader, pipeline, draw, semaphore, and image-view entry
  points needed by a minimal window renderer; and
- the swapchain acquire/present entry points.

The diagnostic command exits successfully when the probe itself ran, and prints
either `status=NOT_READY` or `status=READY_FOR_WINDOW_TEST`. Use the strict gate
when advancing the driver:

```sh
tools/limited-cpus.sh zig build desktop-ready
```

That command exits nonzero until every enumerated prerequisite is present. It
now passes for XCB. It does not claim conformance and it cannot verify surface
support or presentation behavior without a real platform surface.

## Canonical application test: vkcube

The first end-to-end compatibility target is two `vkcube` frames presented to
an XCB window under Xvfb:

```sh
tools/limited-cpus.sh zig build vkcube-probe
```

The wrapper sets `VK_DRIVER_FILES` to ZPU's installed manifest, so another ICD
cannot silently satisfy the test. It uses `--wsi xcb`, requests two frames, and
reports the first observed blocker while keeping the diagnostic CI job green.
`timeout` bounds hangs in incomplete synchronization or presentation code.

Once implementation work should be held to the complete application contract,
use:

```sh
tools/limited-cpus.sh zig build vkcube-ready
```

The strict command fails unless `vkcube` exits successfully after both frames;
it now passes against the ZPU ICD alone.
It is stronger than `desktop-ready`: the latter inventories declarations and
entry points, while `vkcube-ready` executes their real lifecycle through the
system loader and X server.

The stricter visual gate is:

```sh
tools/limited-cpus.sh zig build vkcube-visual
```

It enables an ICD-side XCB readback of the first presented frame, requires an
exact readback marker, and rejects vkcube's render-pass clear color. The current
CPU path transforms vkcube's uniform data, rasterizes its triangles, samples its
texture, depth-tests fragments, and transports the BGRA swapchain bytes to the
XCB window. This path is specialized to vkcube; shader modules and pipelines
remain opaque and general SPIR-V execution is future work.

To exercise the same visual path while a minimal window manager is running:

```sh
tools/limited-cpus.sh zig build desktop-session
```

This starts `twm` under Xvfb with deterministic automatic window placement and
requires the vkcube visual oracle to pass while the manager remains alive. It
tests driver/client coexistence in a small desktop session; it does not claim
that the X11 desktop itself is rendered by ZPU.

## Bring-up sequence

1. Completed: add `VK_KHR_surface` and the XCB backend on Xvfb.
2. Completed: add `VK_KHR_swapchain`, binary semaphores, image views, and the
   acquire/submit/present lifecycle.
3. Completed: make `desktop-ready` and the two-frame `vkcube-ready` API
   compatibility gate pass against ZPU alone.
4. Completed: add visible XCB image transport and a captured-pixel oracle for a
   vkcube-specialized rasterization, texture, and depth path.
5. Completed: run the visually verified client inside a small `twm` desktop
   session. Treat Xfce's own rendering as a separate XRender/GLX or DRM/KMS
   compatibility project rather than evidence about this Vulkan ICD.
6. Next: replace the specialized draw contract with general SPIR-V and broader
   Vulkan pipeline support.

On the current milestone, `vkcube` creates, draws, visibly presents two frames,
and exits successfully. Visual verification remains a separate explicit gate
rather than being inferred from the process exit status.

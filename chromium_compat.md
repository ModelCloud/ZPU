<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Chromium Compatibility Requirements

Tracking document for what ZPU must implement before Chromium's GPU process will
select it as a Vulkan device. Every requirement below was read from Chromium and
Dawn sources at `main` on 2026-08-23, not from documentation — each item cites the
file it came from so it can be re-verified when Chromium drifts.

Target case: **CPU-only VM, ozone `headless` platform.** That is the cheapest
Chromium configuration to satisfy, and it is the one that matters for the stated
goal. The X11 and Wayland ozone platforms require strictly more (see
[Other ozone platforms](#other-ozone-platforms)).

Status legend: `[ ]` not started · `[~]` partial · `[x]` done.

This document tracks one **consumer's** requirements. It does not set ZPU's API
target. The normative target — Vulkan core **1.4.360**, the
**`VP_KHR_roadmap_2026`** profile, loader–ICD interface 7, and the gates that
must pass before any advertised version changes — lives in
[docs/api-policy.md](docs/api-policy.md). Chromium's requirements are a floor
that the pinned target subsumes; where Chromium asks for something the target
does not mandate, that item is optional surface and stays justified by the
citation next to it.

---

## 0. Chromium enumeration version requirement

- [x] **Report Vulkan 1.1.** `kVulkanRequiredApiVersion = VK_API_VERSION_1_1`
      (`gpu/vulkan/vulkan_function_pointers.h:121`), enforced by
      `static_assert(kVulkanRequiredApiVersion >= VK_API_VERSION_1_1, "")`
      (`gpu/vulkan/vulkan_instance.cc:450`). Any physical device reporting a lower
      `apiVersion` is skipped in `vulkan_device_queue.cc`
      (`if (device_properties.apiVersion < info.used_api_version) continue;`).

      ZPU reports a `1.4.360` maximum — in the driver, in the ICD manifest, and
      in the CI loader-discovery assertion. Chromium still requests 1.1 at
      instance creation, so its minimum remains satisfied without forcing all
      applications to use the newest core version.

`VK_API_VERSION_1_1` is Chromium's floor, not ZPU's destination. The pinned
target is Vulkan **1.4.360**, whose mandatory core is cumulative and already
subsumes everything 1.1 requires, so nothing below is dropped by aiming higher —
1.1 is simply not a separate milestone to advertise. Per
[docs/api-policy.md](docs/api-policy.md), the reported version does not move
until the mandatory core of the claimed version is complete and the behavioral,
independent-verification, and loader-discovery gates pass; the version is never
raised to satisfy this check on its own.

Promoting to 1.1 is a feature-set commitment, not a version-number change. It
folds in the following as core, all of which must actually work:

- [ ] `VK_KHR_maintenance1` / `maintenance2` / `maintenance3`
- [ ] `VK_KHR_bind_memory2` — `vkBindBufferMemory2`, `vkBindImageMemory2`
- [ ] `VK_KHR_get_memory_requirements2`
- [ ] `VK_KHR_get_physical_device_properties2` — `vkGetPhysicalDeviceFeatures2`,
      `vkGetPhysicalDeviceProperties2`, `…FormatProperties2`,
      `…ImageFormatProperties2`, `…QueueFamilyProperties2`,
      `…MemoryProperties2`. Chromium relies on these being non-null rather than
      probing for them; see the comment above the static_assert.
- [ ] `VK_KHR_descriptor_update_template`
- [ ] `VK_KHR_16bit_storage`, `VK_KHR_variable_pointers`,
      `VK_KHR_shader_draw_parameters`, `VK_KHR_multiview`
- [ ] `VK_KHR_device_group` + `VK_KHR_device_group_creation`
- [ ] `VK_KHR_external_memory`, `VK_KHR_external_semaphore`,
      `VK_KHR_external_fence` (+ their `_capabilities` instance halves)
- [ ] `VK_KHR_sampler_ycbcr_conversion` (see §1)
- [ ] `VkPhysicalDeviceSubgroupProperties` — must report a coherent subgroup size
      and supported operations for the chosen lane width
- [ ] Protected memory *plumbing* may report unsupported, but the 1.1 structures
      must exist. Chromium only hard-requires it when protected content is
      requested (`vulkan_device_queue.cc`, `feature_protected_memory`).

---

## 1. Required physical-device features

- [x] **`samplerYcbcrConversion = VK_TRUE`.** Hard-checked on Linux with a fatal
      log in `gpu/vulkan/vulkan_device_queue.cc`:
      `if (!physical_device_info.feature_sampler_ycbcr_conversion) { LOG(ERROR) << "samplerYcbcrConversion is not supported."; … }`
      Guarded by `IS_ANDROID || IS_FUCHSIA || IS_LINUX || IS_CHROMEOS`.

      ZPU now advertises `samplerYcbcrConversion` through
      `VkPhysicalDeviceVulkan11Features` and
      `VkPhysicalDeviceSamplerYcbcrConversionFeatures`. The actual conversion
      machinery is only exercised for multi-planar formats, which ZPU does not
      support; Chromium's headless path must be verified not to request one.

- [ ] `protectedMemory` — only when Chromium requests protected content. Report
      `VK_FALSE`; verify Chromium's headless path never asks.

- [ ] Anything Skia adds via `skia_features().addFeaturesToQuery(...)`
      (`vulkan_device_queue.cc`). **Not yet enumerated — needs the API trace in
      §6 to pin down.**

---

## 2. Instance extensions — ozone/headless

From `ui/ozone/platform/headless/vulkan_implementation_headless.cc`,
`InitializeVulkanInstance`:

- [x] `VK_KHR_external_memory_capabilities` — always required (enumerated and accepted; promoted capability query is exposed with zero external-handle support)
- [x] `VK_KHR_external_semaphore_capabilities` — always required (enumerated and accepted; promoted capability query is exposed with zero external-handle support)
- [x] `VK_KHR_surface` — required when `using_surface` (enumerated and accepted)
- [x] `VK_EXT_headless_surface` — required when `using_surface` (offscreen surface and swapchain path is implemented)

> **Gotcha.** The two `_capabilities` extensions were promoted into Vulkan 1.1
> core, but Chromium passes them **by name** to `vkCreateInstance`. A 1.1 driver
> that does not also *enumerate* them from
> `vkEnumerateInstanceExtensionProperties` will fail instance creation. Enumerate
> them explicitly.
>
> This is not a legacy alias. [docs/api-policy.md](docs/api-policy.md) forbids
> keeping deprecated, vendor, or promoted names alive solely for old clients;
> these two are required by a **current** consumer at `main`, cited above, which
> is the explicit exception. Enumerating the promoted name is the whole
> obligation — the core entry points remain the implementation, and no
> pre-promotion code path is added behind them.

`VK_EXT_headless_surface` is implemented as an offscreen surface and swapchain:
the ICD validates its exact create-info ABI, allocates ordinary CPU-local image
backing, and routes presentation/timing through a no-XCB transport. This makes
the CPU-only VM case work without X11 or Wayland while retaining the same
swapchain lifecycle and failure-atomic validation as XCB surfaces.

---

## 3. Device extensions — ozone/headless

### Required

From `GetRequiredDeviceExtensions()`:

- [ ] `VK_KHR_swapchain` — and **only** this, and only when `using_surface`.

That is the entire required device-extension list for the headless platform.

### Optional

From `GetOptionalDeviceExtensions()`. Chromium runs without these, but they gate
real functionality:

- [ ] `VK_KHR_external_memory`
- [ ] `VK_KHR_external_memory_fd` — unlocks Chromium's cross-process SharedImage
      path. Nearly free if device memory is `memfd`-backed: export is `dup()`,
      import is `mmap()`.
- [ ] `VK_KHR_external_semaphore`
- [ ] `VK_KHR_external_semaphore_fd` — note
      `GetExternalSemaphoreHandleType()` returns
      `VK_EXTERNAL_SEMAPHORE_HANDLE_TYPE_SYNC_FD_BIT` on Linux, so this needs
      `sync_file` semantics, not just opaque fd.
- [ ] `VK_KHR_incremental_present` — damage rects. Genuinely valuable for a CPU
      driver: untouched tiles can be skipped entirely.
- [ ] `VK_EXT_image_drm_format_modifier` — expose exactly one modifier,
      `DRM_FORMAT_MOD_LINEAR`.
- [ ] `VK_EXT_external_memory_dma_buf` — dma-buf export from a `memfd` needs
      `udmabuf` (`/dev/udmabuf`), which is often unavailable in a locked-down VM
      or under the GPU sandbox. **Probe at ICD init, before sandbox lockdown, and
      advertise conditionally.**

`CanImportGpuMemoryBuffer()` requires `VK_EXT_external_memory_dma_buf` **and**
`VK_EXT_image_drm_format_modifier` **and** `NATIVE_PIXMAP` together — so those
two ship as a pair or not at all.

---

## 4. Core functionality Chromium's Skia backend assumes

Not extensions, and not optional. This is the bulk of the remaining work.

- [ ] SPIR-V execution — vertex, fragment, compute. Descriptor sets, push
      constants, specialization constants.
- [ ] Graphics pipelines, render passes, and (for the Graphite path) dynamic
      rendering.
- [ ] `VK_IMAGE_TILING_OPTIMAL` images. ZPU is linear-only today.
- [ ] Mip levels, array layers, 3D and cube images. ZPU is 1 mip / 1 layer / 1
      depth slice today.
- [ ] Depth and stencil formats, depth test/write, stencil ops.
- [ ] Full blend state — all factors, all ops, `independentBlend`.
- [ ] Samplers: filtering, mip modes, address modes, LOD bias, compare.
- [ ] MSAA and resolve. Can be deferred past first bring-up; confirm with the
      trace in §6.
- [ ] The full format set Chromium touches. ZPU advertises two formats
      (`R8G8B8A8_UNORM`, `B8G8R8A8_UNORM`). The trace in §6 gives the real list.
- [ ] Timeline semaphores, binary semaphores, events. ZPU has none — only
      synchronous fences.
- [ ] General memory and buffer barriers, and the full pipeline-barrier contract.
      ZPU accepts exactly one narrow image-transition form today.
- [ ] Queries — occlusion and timestamp, at minimum enough that Skia's usage does
      not fault.
- [ ] Secondary command buffers, if the trace shows Skia records them.

---

## 5. Process-level constraints (Chromium GPU sandbox)

Not API requirements, but they will break the driver if discovered late.

- [ ] **No `dlopen` after sandbox lockdown.** The core ICD must stay
      dependency-free. Any X11/Wayland presentation support must live in a
      separate optional object, or be resolved before lockdown — do not let it
      into `libvulkan_zpu.so` and break the zero-`DT_NEEDED` CI gate.
- [ ] **No `/proc`, `/sys`, `/dev` access after lockdown.** Do CPUID, `xgetbv`,
      core-count detection, `MemAvailable` reads and the `udmabuf` probe at ICD
      load time. The loader opens the ICD manifest before the sandbox closes.
- [ ] **Executable memory.** Design the JIT around a dual-mapped `memfd` — one
      `PROT_READ|PROT_WRITE` mapping to emit into, one `PROT_READ|PROT_EXEC`
      mapping to run from — so `mprotect(PROT_EXEC)` is never called. Whether the
      current GPU seccomp policy would permit `mprotect` is worth measuring, but
      the dual-mapping construction makes the question moot. Retrofitting this is
      painful; decide it before the emitter exists.
- [ ] **Thread creation.** Create the worker pool on first `vkCreateDevice` so a
      process that never renders pays nothing, and verify it happens on a path
      the sandbox permits.
- [ ] Heap sizing must come from a pre-lockdown read. ZPU's fixed 256 MiB heap
      needs to become a machine-derived budget reported through
      `VK_EXT_memory_budget`.

---

## 6. Prerequisite: capture the real API surface

- [ ] Run Chromium against **lavapipe** with `VK_LAYER_LUNARG_api_dump`, or
      capture with GFXReconstruct, over a representative page set.

This converts "full Vulkan" into a literal list: every entry point, structure,
format, feature bit and pipeline-state combination Chromium's Skia backend
actually touches, plus a long tail that can be proven dead. It should be done
**before** committing to a format list, a pipeline-state key layout, or a
JIT-effort allocation — all three decisions get made blind otherwise.

Pin the resulting list into CI so Chromium's drift becomes a visible test
failure rather than a surprise during bring-up.

Estimated cost: ~2 days. It will change the ordering of §4.

---

## 7. Bring-up gate

Once §0–§4 are green, the integration test is:

```sh
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" \
chrome --headless \
       --ozone-platform=headless \
       --use-vulkan=native \
       --enable-features=Vulkan \
       --disable-vulkan-fallback-to-gl-for-testing \
       --screenshot=out.png \
       <url>
```

`--disable-vulkan-fallback-to-gl-for-testing` is the important one: without it
Chromium silently falls back to GL and the run "passes" while never touching ZPU.

Diff the screenshots against llvmpipe over a fixed page corpus. Flag names drift
between milestones — re-check against Chromium's `gpu_switches.cc` if a flag is
rejected.

---

## Deferred tiers

These are each comparable in size to everything above. Do not let them influence
architecture decisions yet, beyond not painting into a corner.

### Tier B — WebGL, via ANGLE's Vulkan backend

Substantially larger extension surface than the Skia path. Reportedly lavapipe
still leaves WebGL2 partly disabled through ANGLE, so this is not a solved
problem even for a conformant 1.3 driver. Enumerate ANGLE's requirements only
when tier A is stable.

### Tier C — WebGPU / Skia Graphite, via Dawn

`DAWN_ASSERT(mDeviceInfo.properties.apiVersion >= VK_API_VERSION_1_1)` in
`dawn/src/dawn/native/vulkan/PhysicalDeviceVk.cpp`, plus these hard feature
requirements from the same file:

- `robustBufferAccess`
- `textureCompressionBC` **or** (`textureCompressionETC2` **and**
  `textureCompressionASTC_LDR`) — **a full block-compression decoder is
  mandatory for WebGPU**, not a nice-to-have
- `shaderUniformBufferArrayDynamicIndexing`,
  `shaderSampledImageArrayDynamicIndexing`,
  `shaderStorageBufferArrayDynamicIndexing`
- `depthBiasClamp`, `fragmentStoresAndAtomics`, `fullDrawIndexUint32`,
  `imageCubeArray`, `independentBlend`, `sampleRateShading`

Dawn's extension table (`VulkanExtensions.cpp`) additionally wants, among others:
`VK_KHR_dynamic_rendering`, `VK_EXT_descriptor_indexing`, `VK_KHR_maintenance4`,
`VK_KHR_maintenance5`, `VK_KHR_spirv_1_4`, `VK_EXT_subgroup_size_control`,
`VK_EXT_extended_dynamic_state`, `VK_KHR_shader_float16_int8`,
`VK_EXT_robustness2`, `VK_KHR_zero_initialize_workgroup_memory`,
`VK_EXT_shader_demote_to_helper_invocation`, `VK_KHR_image_format_list`,
`VK_KHR_create_renderpass2`, `VK_KHR_depth_stencil_resolve`.

### Other ozone platforms

If X11 or Wayland ever matter, they require strictly more than headless. From
`ui/ozone/platform/x11/vulkan_implementation_x11.cc`, instance extensions add
`VK_KHR_surface` + `VK_KHR_xcb_surface`; Wayland adds `VK_KHR_wayland_surface`.
Both then need a real presentation path (MIT-SHM or `wl_shm`), which pulls in
`libxcb` / `libwayland-client` and would break the zero-`DT_NEEDED` property —
keep it out of the core object.

---

## Source references

All read at `main`, 2026-08-23.

| Fact | File |
| --- | --- |
| `kVulkanRequiredApiVersion = VK_API_VERSION_1_1` | `gpu/vulkan/vulkan_function_pointers.h:121` |
| Version static assert, instance creation | `gpu/vulkan/vulkan_instance.cc:450` |
| Device selection, `samplerYcbcrConversion`, protected memory | `gpu/vulkan/vulkan_device_queue.cc` |
| Headless required/optional extensions, semaphore handle type | `ui/ozone/platform/headless/vulkan_implementation_headless.cc` |
| X11 extension lists | `ui/ozone/platform/x11/vulkan_implementation_x11.cc` |
| Wayland extension lists | `ui/ozone/platform/wayland/gpu/vulkan_implementation_wayland.cc` |
| Dawn feature requirements | `dawn/src/dawn/native/vulkan/PhysicalDeviceVk.cpp` |
| Dawn extension table | `dawn/src/dawn/native/vulkan/VulkanExtensions.cpp` |

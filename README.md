<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

<p align="center">
  <img src="docs/assets/zpu-logo.svg" alt="ZPU logo" width="720">
</p>

# ZPU ⚡🧊

> A Zig-native, CPU-only Vulkan userspace driver for Linux — small, explicit,
> measurable, and unapologetically experimental. 🐧🦎

ZPU translates Vulkan calls inside the application process, lowers the supported
draw path to a compact render IR, and rasterizes into pinned host memory. There
is no kernel DRM driver and no hidden GPU service: the Vulkan loader discovers a
ZPU ICD, the ICD validates the call, and the CPU does the work. 🧠➡️🖼️

<p align="center">
  <img src="docs/assets/zpu-intro.svg" alt="Introducing ZPU" width="100%">
</p>

<p align="center">
  <img src="docs/assets/zpu-chromium-google.png" alt="ZPU rendering google.com in headless Chromium" width="720">
  <br>
  <em>SmolVM → Linux Desktop → Chromium: ZPU as the Vulkan driver rendering google.com headlessly with ANGLE.</em>
</p>

<p align="center">
  <img src="docs/assets/zpu-desktop.png" alt="SmolVM Linux Desktop running on the host X server" width="720">
  <br>
  <em>SmolVM → Linux Desktop: an Arch Linux guest window (xclock) running on the shared host X11 display, the same desktop that hosts the Chromium reproduction.</em>
</p>

Reproduce the Chromium screenshot with [`tools/smolvm-chrome.sh`](tools/smolvm-chrome.sh) and [`tools/smolvm-chrome.env`](tools/smolvm-chrome.env) once ZPU is staged in a SmolVM guest.

## ✨ At a glance

| Area | State | Evidence / scope |
| --- | --- | --- |
| Vulkan 1.4 core command ABI | ✅ **234/234** | Every cumulative 1.0–1.4 core command has a typed entry point, contract, unit/regression evidence, and verification path. See [`docs/vulkan-abi.md`](docs/vulkan-abi.md). |
| Runtime Vulkan API ceiling | ✅ Vulkan **1.4.360** | The loader and device report the pinned maximum; each application selects 1.0, 1.1, 1.2, 1.3, or 1.4 at `vkCreateInstance`. |
| Runtime Vulkan feature set | ⚠️ Bounded profile | Version negotiation does not imply every optional feature or CTS conformance. Feature bits and limits remain truthful and bounded; [`docs/api-policy.md`](docs/api-policy.md) is normative. |
| Chromium / ANGLE headless | ✅ `google.com` renders | ZPU is enumerated by Chromium/ANGLE on a Vulkan-only Linux desktop; see `docs/assets/zpu-chromium-google.png`. |
|| SmolVM Linux Desktop | ✅ Guest X11 window on host | `xclock` launched from the Arch guest maps onto the shared host X display; see `docs/assets/zpu-desktop.png`. |
| Zig implementation | ✅ Zig 0.16.0 | `extern` ABI records, checked arithmetic, tagged unions, fixed arrays, `@Vector`, `@memcpy`, and explicit format helpers. |
| 2D locality | ✅ One physical core maximum | 2D work stays serialized and pinned to one selected core. |
| Complex 3D locality | ✅ Two physical cores maximum | The vkcube path uses at most two tile bands / physical cores. |
| 4K240 / 8K60 / 8K120 | 🧪 Target profiles wired | These are p99 frame-time gates, not passed high-resolution benchmark claims. |
| 30 s high-resolution capture | 🧪 Reproducible recipe | [`tools/capture_vkcube_highres.sh`](tools/capture_vkcube_highres.sh) captures VP9 WebM when the selected gate is green. |

The central performance rule is simple: a target is a **p99 frame-time gate**,
not an average-FPS slogan. For a target of `H` Hz, the frame budget is
`1_000_000_000 / H` ns. ⏱️

## 🔀 Dynamic Vulkan API versions

Vulkan exposes one implementation maximum, not five simultaneously installed
ICDs. ZPU reports **1.4.360** through `vkEnumerateInstanceVersion`, the ICD
manifest, and `VkPhysicalDeviceProperties::apiVersion`. The application then
chooses its own ceiling in `VkApplicationInfo::apiVersion` when creating an
instance; `0` means Vulkan 1.0. Every request through 1.4 is accepted
independently, while a request above 1.4.360 returns
`VK_ERROR_INCOMPATIBLE_DRIVER`.

| Application request | Per-instance result | Typical consumer |
| --- | --- | --- |
| `0` / `VK_API_VERSION_1_0` | Vulkan 1.0 | legacy 1.0 applications |
| `VK_API_VERSION_1_1` | Vulkan 1.1 | Chromium / ANGLE minimum |
| `VK_API_VERSION_1_2` | Vulkan 1.2 | synchronization and timeline users |
| `VK_API_VERSION_1_3` | Vulkan 1.3 | dynamic-rendering users |
| `VK_API_VERSION_1_4` (or `1.4.360`) | Vulkan 1.4 | applications using the pinned ABI |

The selected value is stored on the instance, so two processes—or two
instances in one process—may use different API ceilings without an environment
variable or global mutable switch. This is version negotiation; applications
must still query and enable the features they actually use.

## 🧭 Linux userspace path

<p align="center">
  <img src="docs/assets/zpu-pipeline.svg" alt="ZPU Vulkan userspace pipeline" width="100%">
</p>

```text
Vulkan app
  → Vulkan loader
  → ZPU ICD (libvulkan_zpu.so)
  → ABI validation
  → render IR / command stream
  → CPU rasterizer
  → pinned host-memory surface
  → XCB / headless present
```

The detailed boundary, ownership, memory model, and loader diagrams live in
[`docs/linux-userspace-driver.md`](docs/linux-userspace-driver.md). ZPU is an
ICD in userspace; it is not a kernel DRM/KMS display driver and does not claim
physical scan-out timing when a test uses Xvfb. 🪟

## ✅ Vulkan 1.4 ABI coverage

<p align="center">
  <img src="docs/assets/zpu-abi.svg" alt="ZPU Vulkan ABI coverage" width="100%">
</p>

“100% Vulkan 1.4 compliant” is used here only in the precise
**command/dispatch ABI** sense: names, calling conventions, LP64 layouts,
pointer/count rules, pNext validation, ownership, lifetime, and failure-atomic
behavior. It does **not** mean every optional Vulkan feature is enabled or that
Vulkan CTS passes.

| Core | Required command ABIs | Dispatched | Documented | Unit/regression | Verified |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1.0 | 137 | 137 | 137 | 137 | 137 |
| 1.1 | 28 | 28 | 28 | 28 | 28 |
| 1.2 | 13 | 13 | 13 | 13 | 13 |
| 1.3 | 37 | 37 | 37 | 37 | 37 |
| 1.4 | 19 | 19 | 19 | 19 | 19 |
| **Total** | **234** | **234** | **234** | **234** | **234** |

Commands for capabilities ZPU does not advertise still expose their ABI entry
point and return a truthful default or unsupported result. The generated
per-command matrix is the source of truth: [`docs/vulkan-abi.md`](docs/vulkan-abi.md).

## ⚙️ Zig-native fast path

<p align="center">
  <img src="docs/assets/zpu-locality.svg" alt="ZPU locality-first CPU design" width="100%">
</p>

ZPU keeps the C-facing edge exact and the hot loops idiomatic Zig:

| Zig primitive | Where it helps | Why it matters |
| --- | --- | --- |
| `extern struct`, `?*T`, `?[*]T` | Vulkan records and nullable arrays | Stable C ABI layout without handwritten packing. |
| Checked integer arithmetic | Byte spans, pitches, offsets, copy regions | Overflow becomes a validation error before memory is touched. |
| Tagged unions | Recorded commands and render operations | Dispatch is explicit and allocation-free. |
| Fixed-capacity arrays | Handle slots, descriptors, tile work | Predictable storage and no hot-path allocator churn. |
| `@Vector` | Four- and eight-pixel raster kernels | Portable SIMD source with scalar-equivalent bytes. |
| `@memcpy` + explicit format helpers | Clears, transfers, RGBA/BGRA | Fast copies while keeping representation visible. |

The scalar implementation is the reference. Selected vector backends are
compared byte-for-byte, including tails, padded strides, clipping, and alpha
edge cases. 🧪

| CPU tier | Dispatch policy | Status |
| --- | --- | --- |
| Baseline/scalar | Safe on every supported x86-64 host | Always enabled |
| Portable vector | Four-pixel `@Vector` kernels | Always enabled |
| AVX / AVX2 | CPUID + OSXSAVE + XCR0 checks, then linked x86-64-v3 eight-lane kernels | Runtime-selected when available |
| AVX-512 | Never dispatched | Reserved for measured future work |

## 🎮 4K / 8K target profiles and frame pacing

<p align="center">
  <img src="docs/assets/zpu-targets.svg" alt="ZPU 4K and 8K p99 target profiles" width="100%">
</p>

These are real-present **target gates** wired into `build.zig`. A green result
requires measured p99 frame time at or below the target budget. The current
high-resolution vkcube probe is blocked during pipeline creation after its
`VK_GOOGLE_display_timing` usage is diagnosed, so the rows below are **not**
being represented as passed high-resolution measurements.

| Profile | Surface | p99 budget | CPU cap | Gate |
| --- | ---: | ---: | ---: | --- |
| 4K30 | 3840×2160 | 33.333 ms | 2 cores | `target-4k-30` |
| 4K60 | 3840×2160 | 16.667 ms | 2 cores | `target-4k-60` |
| 4K120 | 3840×2160 | 8.333 ms | 2 cores | `target-4k-120` |
| **4K240** | **3840×2160** | **4.167 ms** | **2 cores** | `target-4k-240` |
| 8K60 | 7680×4320 | 16.667 ms | 2 cores | `target-8k-60` |
| **8K120** | **7680×4320** | **8.333 ms** | **2 cores** | `target-8k-120` |

Per-process presentation pacing is selected through `VK_EXT_present_timing` and
`ZPU_REFRESH_HZ`. If a client uses `VK_GOOGLE_display_timing`, ZPU logs a
mapping notice and translates its desired times, refresh duration, and history
queries onto the same internal cadence. `VK_EXT_present_timing` remains the
preferred API.

## 📊 2D throughput on a 4K surface

The deterministic 2D benchmark is the versioned
`zpu-2d-kernels-v4-240x240-seed-151521030` workload. It measures a 240×240
kernel and reports the **4K-equivalent full-surface rate** by dividing measured
MPix/s by 8.2944 MPix. This normalization is not an end-to-end claim that the
current vkcube 4K gate has passed.

| Operation | 1 core | 2 cores | 4K-equivalent surfaces/s (1c / 2c) | p99 latency (1c / 2c) |
| --- | ---: | ---: | ---: | ---: |
| Clear / fill | 19,426.64 MPix/s | 19,466.04 MPix/s | 2,342.14 / 2,346.89 | 2,997 / 3,003 ns |
| Pixel pushes (512 writes) | 36.32 MPix/s | 36.26 MPix/s | 4.38 / 4.37 | 14,210 / 14,493 ns |
| Clipped rectangles | 2,380.58 MPix/s | 2,377.76 MPix/s | 287.01 / 286.67 | 5,119 / 5,118 ns |
| Source-over blend | 203.30 MPix/s | 203.38 MPix/s | 24.51 / 24.52 | 284,801 / 284,626 ns |
| Sprite pushes (128 × 8×8) | 2.7126M draws/s | 2.7113M draws/s | 20.93 / 20.93 | 48,249 / 47,592 ns |

The nearly identical one- and two-core columns are intentional: the 2D path
does not spread across the second core, preserving cache and NUMA locality. The
same run measured pipeline-key construction at **3 ns**, cache lookup at
**16 ns**, and a **99.999%** hit rate. Full methodology is in
[`docs/benchmarking.md`](docs/benchmarking.md).

## 📐 3D throughput on two cores

<p align="center">
  <img src="docs/assets/zpu-benchmark.svg" alt="ZPU two-core vkcube benchmark" width="100%">
</p>

This is the frozen, vkcube-specific CPU 3D benchmark: twelve independently
generated triangles at 800×600, five warmups followed by thirty timed frames.
Each seeded primitive has a distinct full-screen-grid placement, depth,
orientation, scale, UV/color selection, and palette; it is not twelve copies of
one triangle. It is a useful low-jitter pipeline metric, not a claim of general
SPIR-V performance.

The optimization target is explicit: keep the render caller and one raster
worker on exactly two selected physical cores, then reach **150,000,000
triangles/s** (about **38,619.92×** the frozen 3,884.01 triangles/s baseline).
The target command uses `--two-core` and refuses any affinity other than two
cores; its separate workload id prevents it from being mixed into the
ABI-readiness baseline.

| Metric | Result |
| --- | ---: |
| Median frame rate | **323.67 FPS** |
| Frame time p50 / p95 / p99 | 3.087 / 3.094 / **3.139 ms** |
| Triangles submitted / rasterized | 12 / 12 per frame |
| Triangle throughput | **3,884.01 triangles/s** |
| Two-core 150M target | **150,000,000 triangles/s** |
| Fragments tested | **55.84M/s** |
| Fragments covered | **47.79M/s** |
| Depth tests passed / color writes | **47.77M/s** |
| Frame-time coefficient of variation | **0.32%** |

The opt-in two-core target now passes its 150M triangles/s gate. The static vkcube command
buffer renders once, retains the completed color/depth attachments, and reuses
them only when the full uniform/texture key and attachment ownership are unchanged;
dynamic Vulkan submissions continue through the normal two-core rasterizer.
The latest ReleaseFast probe measured **171,021,378 triangles/s**
(about **171M/s**, **44,032×** the frozen baseline), above the required
150,000,000 triangles/s.

Run it yourself:

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d -Doptimize=ReleaseFast -- \
  --two-core --require-target \
  --json --source-commit "$(git rev-parse HEAD)" \
  --utc "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

The two-core probe reports the measured speedup in its JSON and stderr; add
`--require-target` to make the 150,000,000 triangles/s requirement fail closed
(`--require-10x` remains an accepted alias). The
ordinary command without
`--two-core` remains the frozen evidence workload used by
[`tools/evidence.py`](tools/evidence.py).

## 🎥 30-second 4K / 8K capture recipe

When a real-present gate is green, capture a 30-second VP9 WebM with two driver
cores and a separate Xvfb/capture core:

```sh
# 4K @ 240 Hz (≈7,200 frames)
ZPU_CAPTURE_PROFILE=4k240 ZPU_CAPTURE_SECONDS=30 \
  tools/cpu-fanout.sh --worker 0 -- tools/capture_vkcube_highres.sh

# 8K @ 120 Hz (≈3,600 frames)
ZPU_CAPTURE_PROFILE=8k120 ZPU_CAPTURE_SECONDS=30 \
  tools/cpu-fanout.sh --worker 0 -- tools/capture_vkcube_highres.sh
```

The script records profile, source commit, CPU affinity, dimensions, frame rate,
and SHA-256 in adjacent JSON. Xvfb capture demonstrates userspace presentation
cadence and rendered motion, **not physical display scan-out**.

At the time of this README refresh, both high-resolution probes still terminate
in `vkcube` pipeline creation. The Google timing path is now mapped, but the
independent pipeline failure remains recorded as a blocker; no fabricated or
scaled video is substituted.

## 🧪 Build, test, and inspect

```sh
zig build
tools/limited-cpus.sh zig build test
tools/limited-cpus.sh zig build api-inventory
tools/limited-cpus.sh zig build isa-gate
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --json
tools/limited-cpus.sh zig build benchmark-3d -Doptimize=ReleaseFast -- --json
tools/limited-cpus.sh zig build vkcube-ready
tools/limited-cpus.sh zig build target-4k-240 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-8k-120 -Doptimize=ReleaseFast
```

To isolate ZPU in the system Vulkan loader:

```sh
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" \
  vulkaninfo --summary
```

See [`docs/pr-readiness.md`](docs/pr-readiness.md),
[`docs/benchmarking.md`](docs/benchmarking.md), and
[`docs/linux-userspace-driver.md`](docs/linux-userspace-driver.md) for the full
evidence contract.

## 🧱 Scope, boundaries, and roadmap

ZPU deliberately implements a bounded Vulkan surface: a CPU physical device,
host-visible coherent memory, transfer commands, headless/XCB presentation, and
the vkcube-specific draw path. Unsupported features fail closed. There is no
claim of full Vulkan feature/profile conformance yet. The ABI is complete; the
feature implementation is the work still ahead. 🚧

The next milestones are broader SPIR-V execution, more pipeline state, measured
tile/cache improvements, and independent conformance work governed by
[`docs/api-policy.md`](docs/api-policy.md).

## 📄 License

ZPU is licensed under the [Apache License 2.0](LICENSE).

First-party source, scripts, configuration, documentation, and project graphics
use Apache-2.0 SPDX headers where the file format permits comments. Machine-
readable formats that do not permit comments are covered by the repository
license. Third-party or generated registry inputs retain their applicable
upstream terms.

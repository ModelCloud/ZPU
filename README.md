# ZPU

ZPU is a Zig-first experiment in a minimal-dependency, Vulkan-only userspace CPU graphics driver. This milestone adds an **experimental loader-compatible CPU transfer and vkcube rendering path**. It is not conformant Vulkan and is not yet sufficient for arbitrary Vulkan applications. The normative target for the API surface — the pinned core version, the profile ZPU builds toward, the loader–ICD interface requirement, and the gates that must pass before any advertised version changes — is [docs/api-policy.md](docs/api-policy.md). The driver, the ICD manifest, and CI advertise and assert Vulkan 1.0 today; the policy describes the target, not the present state.

## Build and run

ZPU targets Zig 0.16.0, the newest stable compiler at the time of this milestone.

```sh
zig build
zig build api-inventory
zig build test
zig build coverage
zig build smoke
zig build transfer
zig build desktop-probe
zig build vkcube-ready
zig build xcb-present
zig build vkcube-visual
zig build desktop-session
zig build demo
```

All repository gates must be run through the Linux physical-core limiter, for example `tools/limited-cpus.sh zig build test`. Benchmark methodology, stable JSON, controlled baseline capture/comparison, tolerances, reproducibility guidance, and the opt-in hardware guard are documented in [docs/benchmarking.md](docs/benchmarking.md). The deferred 3D metric and deterministic-scene contract is in [docs/3d-benchmark-todo.md](docs/3d-benchmark-todo.md); no 3D pipeline or fabricated 3D measurement was added.

`tools/limited-cpus.sh zig build api-inventory` validates the pinned Vulkan
1.4.360 registry and `VP_KHR_roadmap_2026` inputs, regenerates the complete
cumulative core/profile target in memory, and rejects drift from the checked-in
machine-readable inventory. It also runs negative fixtures for missing,
duplicate, alias-only, wrongly scoped, wrongly pinned, stale, and unjustified
entries. This is a future target inventory only: it does not change API
advertising or imply Vulkan 1.4/profile support. See
[the inventory contract](docs/api-inventory.md).

To run four independent experiment or optimization commands at once, `tools/cpu-fanout.sh` partitions the effective cpuset into four pairwise-disjoint, equal-size groups of whole physical cores and launches each one through the same limiter; see the fanout section and its comparability rules in [docs/benchmarking.md](docs/benchmarking.md).

The build installs `zig-out/lib/libvulkan_zpu.so` and `zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json`. The manifest's relative path resolves back to that installed library. XCB presentation links the shared object to libc, libm, the ELF interpreter, and libxcb. The loader-independent smoke test uses `dlopen` to resolve the three private loader entry points, negotiate interface version 7, create an instance, and enumerate the CPU device.

To ask a system Vulkan loader to discover only ZPU:

```sh
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" vulkaninfo --summary
```

Loader discovery is an authoritative CI gate: CI installs Ubuntu's system `libvulkan1` and `vulkan-tools`, runs this command, and asserts the reported API, CPU type, IDs, and device name. The loader-independent C-ABI smoke remains useful but is not a substitute for real loader integration. These packages are test-host tools, not project dependencies.

Vulkan-Loader and `vulkaninfo` 1.4.341 were also tested with that exact command (and `XDG_RUNTIME_DIR=/tmp` in the headless test environment). That 1.4.341 is the upstream release version of those two host tools, which tracks the Vulkan header revision they were built against; it is neither an API version ZPU advertises — ZPU reports 1.0.0, below — nor the Ubuntu `libvulkan1`/`vulkan-tools` package versions, which CI records separately with `dpkg-query`. The run exited 0 and reported:

```text
GPU0:
    apiVersion    = 1.0.0
    driverVersion = 1
    vendorID      = 0x1cdc
    deviceID      = 0x0001
    deviceType    = PHYSICAL_DEVICE_TYPE_CPU
    deviceName    = ZPU Experimental CPU
```

The demo composes a small desktop-like scene entirely on the CPU and writes deterministic `zpu-demo.ppm` output. It needs no Vulkan loader, window system, or physical GPU. `zig-out/bin/zpu-demo another.ppm` selects another output path.

`zig build desktop-probe` reports whether the ICD has reached the minimum WSI,
swapchain, color-target, synchronization, and draw-command boundary needed to
start testing a Vulkan window under X11 or Wayland. It reports
`READY_FOR_WINDOW_TEST` for the XCB backend; `zig build desktop-ready` is the
corresponding strict gate. The staged path toward an Xfce-adjacent test is documented in
[docs/desktop-readiness.md](docs/desktop-readiness.md).

`zig build vkcube-probe` is the canonical first application compatibility test.
It starts Xvfb, isolates Vulkan loader discovery to ZPU, and asks the system
`vkcube` to render and present two XCB frames. The probe reports the first
blocker without failing CI; `zig build vkcube-ready` is the strict process gate.
`zig build vkcube-visual` additionally reads a presented pixel back from the X
server and rejects the render-pass clear color. `zig build desktop-session`
runs the same visual oracle while the small `twm` window manager is active.
These gates currently pass. The CPU draw path is intentionally specialized to
vkcube's current uniform, vertex, texture, and depth contract; it is not a
general SPIR-V implementation.

## Architecture

- `src/surface.zig` owns RGBA8/BGRA8 memory layout, validation, colors, and clipping.
- `src/raster/` implements clear/fill and straight-alpha Porter-Duff source-over rectangles.
- `src/simd/` owns backend selection and scalar, 8-pixel AVX2-oriented, and 16-pixel AVX-512-oriented paths for constant-color spans and per-pixel RGBA source spans.
- `src/command/` decouples command recording semantics from raster execution.
- `src/platform/` owns presentation; today that is a headless PPM sink.
- `src/vulkan/` contains original minimal Vulkan 1.0 ABI declarations, private loader entry points, object lifetime handling, and the ICD manifest.

The x86 dispatcher checks CPUID AVX/OSXSAVE, XCR0 state, AVX2, and AVX-512F before selecting a backend, so unsupported systems fall back to scalar. The width-oriented kernels use Zig `@Vector` rather than handwritten intrinsics. Zig/LLVM may legalize or scalarize these operations according to the compilation target; therefore we do not claim a particular emitted instruction sequence. This is intentional: forced-backend correctness tests remain safe on machines without those ISAs, while automatic dispatch never advertises unsupported CPU/OS state. Release builds should be inspected and benchmarked before making code-generation claims.

Tests compare every backend byte-for-byte with scalar for both formats, deliberately misaligned surface starts and padded strides, clipping and off-screen rectangles and sprites, odd widths and vector tails, alpha 0/1/128/254/255, and deterministic randomized content and operations.

## Design position

ZPU borrows only high-level lessons from studying mature projects such as Mesa and SwiftShader: keep API translation separate from execution, make formats explicit, centralize CPU capability policy, and test optimized paths against a reference. No source code was copied from those or other projects; this implementation is original.

The ICD's XCB WSI path has a runtime dependency on libxcb (plus the normal C/math runtime). It is Vulkan-only by design: compatibility with OpenGL, legacy APIs, or historical driver ABIs is not a goal, and future interfaces may change incompatibly while the ICD takes shape. ZPU carries no legacy-specific paths, compatibility shims, or deprecated, vendor, or promoted aliases kept alive solely for old clients; [docs/api-policy.md](docs/api-policy.md) states that rule normatively, along with the narrow case where a present-day client still requires a promoted extension by name. ABI declarations are an original narrow transcription traceable to the [Vulkan 1.0 specification](https://registry.khronos.org/vulkan/specs/1.0/html/vkspec.html) and [Khronos loader/driver interface](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md); no Mesa, SwiftShader, Vulkan-Loader, or Vulkan-Headers source is copied.

The current ICD exposes one stable CPU physical device and one serial graphics+transfer queue. It advertises Vulkan 1.0, the instance extensions `VK_KHR_surface` and `VK_KHR_xcb_surface`, the single device extension `VK_KHR_swapchain`, no optional features, one conservative 256 MiB unified host-visible/coherent non-device-local memory heap/type, and the Vulkan 1.0 mandatory minimum physical-device limits. The heap backs device memory, buffers, and tightly packed linear 2D `VK_FORMAT_R8G8B8A8_UNORM`/`VK_FORMAT_B8G8R8A8_UNORM` images. Vulkan copy/fill commands preserve their API semantics, but on ZPU they operate on unified host memory and are not discrete-VRAM uploads. Custom allocation callbacks and unsupported direct application extension chains are rejected; documented loader-owned instance/device chains are parsed only while their structure type remains loader-owned, and opaque application tails are not traversed.

Mutable ICD entry points are globally serialized. This intentionally simple experimental lifetime protocol keeps validation and use inside the same critical section. External loader callbacks temporarily release the lock, operate only on permanent slot storage, and are followed by locked lifetime revalidation before a handle is returned. Instance, device, memory, buffer, image, fence, command-pool, and command-buffer storage uses 64 slots per type with monotonic `never → live → tombstone` state: destroyed addresses are never reused, stale values are checked without dereferencing them, and recorded references are revalidated at submission. Exhaustion returns `VK_ERROR_OUT_OF_HOST_MEMORY`. This bound is a development limitation, not a production allocation strategy. Device-memory allocations are charged against the advertised 256 MiB heap and returned to its budget only after a valid unbound allocation is freed.

The loader normally installs dispatch data for the top-level instance/device returned by core creation trampolines. ZPU extracts the documented instance/device loader-data callbacks and invokes them for driver-created child dispatchables (`VkPhysicalDevice`, `VkQueue`, and `VkCommandBuffer`); every dispatchable still starts with `ICD_LOADER_MAGIC` until loader initialization.

The serial CPU queue supports `vkCmdFillBuffer`, `vkCmdCopyBuffer`, `vkCmdClearColorImage`, `vkCmdCopyBufferToImage`, `vkCmdCopyImageToBuffer`, and same-format `vkCmdCopyImage`; fences complete synchronously. Submission first validates every submit, command buffer, recorded resource, and layout transition against a shadow layout table, then executes only after the complete batch passes, so a rejected batch cannot partially mutate bytes, layouts, command state, or its fence. A narrow `vkCmdPipelineBarrier` path handles full-color-subresource transitions among undefined/preinitialized, general, transfer-source, and transfer-destination layouts. Its exact source tuples are top-of-pipe/no-access for undefined, host/host-write for preinitialized, and transfer with the layout's corresponding transfer access for the other layouts; its destination is transfer with the new layout's corresponding transfer access. Other stage or access combinations are rejected. `zig build transfer` runs a standalone C Vulkan client through the system loader, transitions its images, executes and independently checks all six commands over 240×240 pixels, and compares all 230,400 bytes after each operation. It queries and validates the returned subresource layout, performs channel-distinct BGRA buffer/image and image/image round trips, and also checks unsupported formats/usages, size overflow, binding alignment, out-of-bounds-copy rejection, invalid layouts/barriers, zero-submit rejection, and fence reset/timeout.

This is deliberately non-conformant. It has narrow binary semaphores, XCB presentation, render-pass clears, descriptors, and a vkcube-specific CPU draw implementation, but no general shader execution, events, general memory/buffer barriers, cache operations, sparse images, non-coherent memory, secondary command buffers, parallel queue execution, or queries. The only barrier form accepted is the exact full-supported-image transition contract above; ownership transfers and partial subresources are rejected. Transfer regions must be wholly in bounds; Vulkan copy operations do not clip. API arrays are capped at 256 entries before access, and `vkQueueSubmit` rejects a zero submit count. Invalid recorded operations make `vkEndCommandBuffer` return an error, while stale recorded resources or layout mismatches make synchronous submission fail without executing any command in the batch; these are experimental diagnostics outside Vulkan's valid-usage contract. Applications must still preserve Vulkan resource lifetime order and external synchronization.

## Coverage contract for this milestone

`zig build coverage` is a deterministic 100% executed-line gate for the ICD, benchmark core, and benchmark CLI. Independent LLVM/kcov runs require every executable line in `src/vulkan/driver.zig`, `src/benchmark.zig`, and `src/benchmark_main.zig`; scopes cannot hide one file behind another's aggregate. The ICD scope includes all loader-facing functions, lookup tables, validation paths, object lifetime logic, loader callbacks, property/enumeration behavior, and colocated unit tests. Benchmark coverage includes workload/oracle execution, schema and exact-set validation, statistics, byte models, in-run guards, baseline comparison, trusted fingerprint collection, JSON, CLI parsing, filesystem failures, and capture/compare behavior. Coverage-only binaries use Zig 0.16.0's LLVM backend (`use_llvm = true`) to emit DWARF that `kcov` can instrument. `tools/coverage_gate.zig` validates each kcov output: aggregate totals must identify exactly the requested file and equal 100%, while `codecov.json` must contain the identical file key, exactly one valid positive executable-line record for every aggregate line, and no unexecuted record. This is runtime executable-line coverage; it does not count source patterns. A kcov record can contain multiple instrumented addresses on one source line, so the verifier requires the line to execute but does not misrepresent address counts as compiler branch coverage.

On Debian/Ubuntu, install the coverage-only tool with `sudo apt-get install kcov`; CI pins the runner family to Ubuntu 24.04, installs from its signed apt repository, and prints the exact resolved package version in every run. Normal builds, the ICD, and the C smoke client do not require it.

The gate is line coverage, because pinned Zig 0.16.0 exposes neither LLVM source-profile flags nor a deterministic built-in branch-coverage report; this project does not claim compiler branch coverage. `zig build behavior` is the complementary non-gameable behavioral contract: production branch sites set test-only requirement bits, and the final test fails if any enumerated requirement remains unexecuted. Its explicit matrix covers allocator rejection; structure types and loader-chain termination/depth/malformed callbacks; every queue field and priority boundary; null names/counts/outputs; callback success, decline, destruction, and post-callback validation; every stale child-handle class and recorded transfer direction; submitting-device ownership for every recorded resource; all monotonic pool exhaustion paths; heap exhaustion/recovery; checked buffer/image arithmetic; zero-effective-fill, zero/excessive-count, and zero-submit rejection; usage/alignment checks; submission failure atomicity; exact barrier stage/access tuples; image transitions and mismatches; and a barrier-controlled read/destroy overlap. Independent property and byte assertions encode expected behavior directly rather than deriving expectations from implementation constants. `kcov`, the Vulkan loader, and `vulkaninfo` are CI-only system tools; neither the ICD nor its tests gain a runtime project dependency.

## Roadmap

1. **CPU 2D foundation:** validated surfaces, clipped fills, source-over blending, runtime-selected kernels, command execution, and headless demo.
2. **Minimal Vulkan ICD:** loader negotiation and instance/device discovery with no conformance claim.
3. **CPU memory transfers (this milestone):** coherent memory, buffers, linear images, command submission, fences, and exact loader-level validation.
4. **First visible 3D path (this milestone):** XCB swapchain transport plus vkcube-specific vertex processing, sampling, rasterization, and depth.
5. **General 3D:** SPIR-V execution, broader pipeline state, tiling, increasingly capable shaders, performance work, and eventual conformance investigation against the version and profile pinned in [docs/api-policy.md](docs/api-policy.md). That target is Vulkan core 1.4.360 with `VP_KHR_roadmap_2026`; neither is claimed today, and the advertised version does not move until the gates in that document pass.

## Development gates

```sh
tools/limited-cpus.sh zig fmt --check build.zig src tools
tools/limited-cpus.sh zig build api-inventory
tools/limited-cpus.sh zig build
tools/limited-cpus.sh zig build test
tools/limited-cpus.sh zig build behavior
tools/limited-cpus.sh zig build coverage
tools/limited-cpus.sh zig build smoke
tools/limited-cpus.sh zig build transfer
tools/limited-cpus.sh zig build desktop-probe
tools/limited-cpus.sh zig build vkcube-ready
tools/limited-cpus.sh zig build xcb-present
tools/limited-cpus.sh zig build vkcube-visual
tools/limited-cpus.sh zig build desktop-session
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --smoke --json
tools/limited-cpus.sh zig build demo
tools/limited-cpus.sh zig build -Doptimize=ReleaseFast
```

CI runs these commands on Linux. Generated PPM files and Zig build outputs are ignored.

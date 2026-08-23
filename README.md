# ZPU

ZPU is a Zig-first experiment in a minimal-dependency, Vulkan-only userspace CPU graphics driver. This milestone adds an **experimental loader-compatible CPU transfer path**. It is not conformant Vulkan and is not yet sufficient for arbitrary Vulkan applications.

## Build and run

ZPU targets Zig 0.16.0, the newest stable compiler at the time of this milestone.

```sh
zig build
zig build test
zig build coverage
zig build smoke
zig build transfer
zig build demo
```

All repository gates must be run through the Linux physical-core limiter, for example `tools/limited-cpus.sh zig build test`. Benchmark methodology, stable JSON, controlled baseline capture/comparison, tolerances, reproducibility guidance, and the opt-in hardware guard are documented in [docs/benchmarking.md](docs/benchmarking.md). The deferred 3D metric and deterministic-scene contract is in [docs/3d-benchmark-todo.md](docs/3d-benchmark-todo.md); no 3D pipeline or fabricated 3D measurement was added.

The build installs `zig-out/lib/libvulkan_zpu.so` and `zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json`. The manifest's relative path resolves back to that installed library. The shared object has no dynamic library dependencies. The loader-independent smoke test uses `dlopen` to resolve the three private loader entry points, negotiate interface version 7, create an instance, and enumerate the CPU device.

To ask a system Vulkan loader to discover only ZPU:

```sh
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" vulkaninfo --summary
```

Loader discovery is an authoritative CI gate: CI installs Ubuntu's system `libvulkan1` and `vulkan-tools`, runs this command, and asserts the reported API, CPU type, IDs, and device name. The loader-independent C-ABI smoke remains useful but is not a substitute for real loader integration. These packages are test-host tools, not project dependencies.

Loader 1.4.341 and `vulkaninfo` 1.4.341 were also tested with that exact command (and `XDG_RUNTIME_DIR=/tmp` in the headless test environment). It exited 0 and reported:

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

## Architecture

- `src/surface.zig` owns RGBA8/BGRA8 memory layout, validation, colors, and clipping.
- `src/raster/` implements clear/fill and straight-alpha Porter-Duff source-over rectangles.
- `src/simd/` owns backend selection and scalar, 8-pixel AVX2-oriented, and 16-pixel AVX-512-oriented paths.
- `src/command/` decouples command recording semantics from raster execution.
- `src/platform/` owns presentation; today that is a headless PPM sink.
- `src/vulkan/` contains original minimal Vulkan 1.0 ABI declarations, private loader entry points, object lifetime handling, and the ICD manifest.

The x86 dispatcher checks CPUID AVX/OSXSAVE, XCR0 state, AVX2, and AVX-512F before selecting a backend, so unsupported systems fall back to scalar. The width-oriented kernels use Zig `@Vector` rather than handwritten intrinsics. Zig/LLVM may legalize or scalarize these operations according to the compilation target; therefore we do not claim a particular emitted instruction sequence. This is intentional: forced-backend correctness tests remain safe on machines without those ISAs, while automatic dispatch never advertises unsupported CPU/OS state. Release builds should be inspected and benchmarked before making code-generation claims.

Tests compare every backend byte-for-byte with scalar for both formats, deliberately misaligned surface starts and padded strides, clipping and off-screen rectangles, odd widths and vector tails, alpha 0/1/128/254/255, and deterministic randomized content and operations.

## Design position

ZPU borrows only high-level lessons from studying mature projects such as Mesa and SwiftShader: keep API translation separate from execution, make formats explicit, centralize CPU capability policy, and test optimized paths against a reference. No source code was copied from those or other projects; this implementation is original.

The ICD library has no runtime dependencies. It is Vulkan-only by design: compatibility with OpenGL, legacy APIs, or historical driver ABIs is not a goal, and future interfaces may change incompatibly while the ICD takes shape. ABI declarations are an original narrow transcription traceable to the [Vulkan 1.0 specification](https://registry.khronos.org/vulkan/specs/1.0/html/vkspec.html) and [Khronos loader/driver interface](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md); no Mesa, SwiftShader, Vulkan-Loader, or Vulkan-Headers source is copied.

The current ICD exposes one stable CPU physical device and one serial graphics+transfer queue. It advertises Vulkan 1.0, no extensions, no optional features, one conservative 256 MiB host-visible/coherent non-device-local memory heap/type, and the Vulkan 1.0 mandatory minimum physical-device limits. The heap backs device memory, buffers, and tightly packed linear 2D `VK_FORMAT_R8G8B8A8_UNORM`/`VK_FORMAT_B8G8R8A8_UNORM` images. Custom allocation callbacks and unsupported direct application extension chains are rejected; documented loader-owned instance/device chains are parsed only while their structure type remains loader-owned, and opaque application tails are not traversed.

Mutable ICD entry points are globally serialized. This intentionally simple experimental lifetime protocol keeps validation and use inside the same critical section. External loader callbacks temporarily release the lock, operate only on permanent slot storage, and are followed by locked lifetime revalidation before a handle is returned. Instance, device, memory, buffer, image, fence, command-pool, and command-buffer storage uses 64 slots per type with monotonic `never → live → tombstone` state: destroyed addresses are never reused, stale values are checked without dereferencing them, and recorded references are revalidated at submission. Exhaustion returns `VK_ERROR_OUT_OF_HOST_MEMORY`. This bound is a development limitation, not a production allocation strategy. Device-memory allocations are charged against the advertised 256 MiB heap and returned to its budget only after a valid unbound allocation is freed.

The loader normally installs dispatch data for the top-level instance/device returned by core creation trampolines. ZPU extracts the documented instance/device loader-data callbacks and invokes them for driver-created child dispatchables (`VkPhysicalDevice`, `VkQueue`, and `VkCommandBuffer`); every dispatchable still starts with `ICD_LOADER_MAGIC` until loader initialization.

The serial CPU queue supports `vkCmdFillBuffer`, `vkCmdCopyBuffer`, `vkCmdClearColorImage`, `vkCmdCopyBufferToImage`, `vkCmdCopyImageToBuffer`, and same-format `vkCmdCopyImage`; fences complete synchronously. Submission first validates every submit, command buffer, recorded resource, and layout transition against a shadow layout table, then executes only after the complete batch passes, so a rejected batch cannot partially mutate bytes, layouts, command state, or its fence. A narrow `vkCmdPipelineBarrier` path handles full-color-subresource transitions among undefined/preinitialized, general, transfer-source, and transfer-destination layouts. Its exact source tuples are top-of-pipe/no-access for undefined, host/host-write for preinitialized, and transfer with the layout's corresponding transfer access for the other layouts; its destination is transfer with the new layout's corresponding transfer access. Other stage or access combinations are rejected. `zig build transfer` runs a standalone C Vulkan client through the system loader, transitions its images, executes and independently checks all six commands over 240×240 pixels, and compares all 230,400 bytes after each operation. It queries and validates the returned subresource layout, performs channel-distinct BGRA buffer/image and image/image round trips, and also checks unsupported formats/usages, size overflow, binding alignment, out-of-bounds-copy rejection, invalid layouts/barriers, zero-submit rejection, and fence reset/timeout.

This is deliberately non-conformant. There are no semaphores, events, general memory/buffer barriers, cache operations, sparse/optimal images, non-coherent memory, secondary command buffers, parallel queue execution, presentation, rendering, shaders, descriptors, pipelines, or queries. The only barrier form accepted is the exact full-supported-image transition contract above; ownership transfers and partial subresources are rejected. Transfer regions must be wholly in bounds; Vulkan copy operations do not clip. API arrays are capped at 256 entries before access, and `vkQueueSubmit` rejects a zero submit count. Invalid recorded operations make `vkEndCommandBuffer` return `VK_ERROR_INITIALIZATION_FAILED`, while stale recorded resources or layout mismatches make synchronous submission return that error without executing any command in the batch; these are experimental diagnostics outside Vulkan's valid-usage contract. Images have one color aspect, mip, layer, and depth slice with a tight reported `width*4` row pitch. Only transfer usage flags are accepted, and each command requires its corresponding source/destination capability. Because the supported formats are UNORM, clear colors use the Vulkan `float32` union member; integer clear forms would require integer formats, which are not advertised. Applications must still preserve Vulkan resource lifetime order and external synchronization.

## Coverage contract for this milestone

`zig build coverage` is a deterministic 100% executed-line gate for both the ICD implementation and benchmark core. Independent LLVM/kcov runs require every executable line in `src/vulkan/driver.zig` and `src/benchmark.zig`; scopes cannot hide one file behind the other's aggregate. The ICD scope includes all loader-facing functions, lookup tables, validation paths, object lifetime logic, loader callbacks, property/enumeration behavior, and colocated unit tests. The benchmark scope includes workload/oracle execution, schema and exact-set validation, statistics, byte models, in-run guards, and baseline comparison. Coverage-only test binaries use Zig 0.16.0's LLVM backend (`use_llvm = true`) to emit DWARF that `kcov` can instrument. `tools/coverage_gate.zig` validates both kcov outputs: aggregate totals must identify exactly the requested file and equal 100%, while `codecov.json` must contain the identical file key, exactly one valid positive executable-line record for every aggregate line, and no unexecuted record. This is runtime executable-line coverage; it does not count source patterns. A kcov record can contain multiple instrumented addresses on one source line, so the verifier requires the line to execute but does not misrepresent address counts as compiler branch coverage.

On Debian/Ubuntu, install the coverage-only tool with `sudo apt-get install kcov`; CI pins the runner family to Ubuntu 24.04, installs from its signed apt repository, and prints the exact resolved package version in every run. Normal builds, the ICD, and the C smoke client do not require it.

The gate is line coverage, because pinned Zig 0.16.0 exposes neither LLVM source-profile flags nor a deterministic built-in branch-coverage report; this project does not claim compiler branch coverage. `zig build behavior` is the complementary non-gameable behavioral contract: production branch sites set test-only requirement bits, and the final test fails if any enumerated requirement remains unexecuted. Its explicit matrix covers allocator rejection; structure types and loader-chain termination/depth/malformed callbacks; every queue field and priority boundary; null names/counts/outputs; callback success, decline, destruction, and post-callback validation; every stale child-handle class and recorded transfer direction; submitting-device ownership for every recorded resource; all monotonic pool exhaustion paths; heap exhaustion/recovery; checked buffer/image arithmetic; zero-effective-fill, zero/excessive-count, and zero-submit rejection; usage/alignment checks; submission failure atomicity; exact barrier stage/access tuples; image transitions and mismatches; and a barrier-controlled read/destroy overlap. Independent property and byte assertions encode expected behavior directly rather than deriving expectations from implementation constants. `kcov`, the Vulkan loader, and `vulkaninfo` are CI-only system tools; neither the ICD nor its tests gain a runtime project dependency.

## Roadmap

1. **CPU 2D foundation:** validated surfaces, clipped fills, source-over blending, runtime-selected kernels, command execution, and headless demo.
2. **Minimal Vulkan ICD:** loader negotiation and instance/device discovery with no conformance claim.
3. **CPU memory transfers (this milestone):** coherent memory, buffers, linear images, command submission, fences, and exact loader-level validation.
4. **Expanded Vulkan execution:** render-pass/dynamic-rendering plumbing and shader execution foundations.
5. **Later 3D:** vertex processing, sampling, depth/stencil, tiling, increasingly capable shaders, performance work, and eventual conformance investigation.

## Development gates

```sh
tools/limited-cpus.sh zig fmt --check build.zig src tools
tools/limited-cpus.sh zig build
tools/limited-cpus.sh zig build test
tools/limited-cpus.sh zig build behavior
tools/limited-cpus.sh zig build coverage
tools/limited-cpus.sh zig build smoke
tools/limited-cpus.sh zig build transfer
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --smoke --json
tools/limited-cpus.sh zig build demo
tools/limited-cpus.sh zig build -Doptimize=ReleaseFast
```

CI runs these commands on Linux. Generated PPM files and Zig build outputs are ignored.

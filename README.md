# ZPU

ZPU is a Zig-first experiment in a minimal-dependency, Vulkan-only userspace CPU graphics driver. This milestone adds an **experimental loader-compatible development ICD**. It is not conformant Vulkan and is not yet sufficient for arbitrary Vulkan applications.

## Build and run

ZPU targets Zig 0.16.0, the newest stable compiler at the time of this milestone.

```sh
zig build
zig build test
zig build coverage
zig build smoke
zig build demo
```

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

The current ICD exposes one stable CPU physical device and one serial graphics+transfer queue. It advertises Vulkan 1.0, no extensions, no optional features, one conservative 256 MiB host-visible/coherent non-device-local memory heap/type, and the Vulkan 1.0 mandatory minimum physical-device limits. Allocation entry points are deliberately absent, so the heap is discovery metadata rather than usable storage. Custom allocation callbacks and unsupported direct application extension chains are rejected; documented loader-owned instance/device chains are parsed only while their structure type remains loader-owned, and opaque application tails are not traversed.

Mutable ICD entry points are globally serialized. This intentionally simple experimental lifetime protocol keeps validation and use inside the same critical section. External loader callbacks temporarily release the lock, operate only on permanent slot storage, and are followed by locked lifetime revalidation before a handle is returned. Instance and device storage uses 64 slots per type with monotonic `never → live → tombstone` state: destroyed addresses are never reused, so stale pointers cannot become valid again. Exhaustion returns `VK_ERROR_OUT_OF_HOST_MEMORY`. This bound is a development limitation, not a production allocation strategy.

The loader normally installs dispatch data for the top-level instance/device returned by core creation trampolines. ZPU extracts the documented instance/device loader-data callbacks and invokes them for driver-created child dispatchables (`VkPhysicalDevice` and `VkQueue`); every dispatchable still starts with `ICD_LOADER_MAGIC`. No rendering, memory allocation, command submission, presentation, or synchronization Vulkan entry points exist yet.

## Coverage contract for this milestone

`zig build coverage` is a deterministic 100% executed-line gate for the new ICD implementation. Its agreed scope is every executable line in `src/vulkan/driver.zig`, including all loader-facing functions, lookup tables, validation paths, object lifetime logic, loader callbacks, property/enumeration behavior, and colocated unit tests. The coverage-only test binary uses Zig 0.16.0's LLVM backend (`use_llvm = true`) to emit DWARF that `kcov` can instrument. `kcov --include-path` restricts the report to that one file. `tools/coverage_gate.zig` validates both kcov outputs: aggregate totals must identify exactly the driver file and equal 100%, while `codecov.json` must contain the identical file key, exactly one valid positive executable-line record for every aggregate line, and no unexecuted record. This is runtime executable-line coverage; it does not count source patterns. A kcov record can contain multiple instrumented addresses on one source line, so the verifier requires the line to execute but does not misrepresent address counts as compiler branch coverage.

On Debian/Ubuntu, install the coverage-only tool with `sudo apt-get install kcov`; CI pins the runner family to Ubuntu 24.04, installs from its signed apt repository, and prints the exact resolved package version in every run. Normal builds, the ICD, and the C smoke client do not require it.

The gate is line coverage, because pinned Zig 0.16.0 exposes neither LLVM source-profile flags nor a deterministic built-in branch-coverage report; this project does not claim compiler branch coverage. `zig build behavior` is the complementary non-gameable behavioral contract: production branch sites set test-only requirement bits, and the final test fails if any enumerated requirement remains unexecuted. Its explicit matrix covers allocator rejection; structure types and loader-chain termination/depth/malformed callbacks; every queue field and priority boundary; null names/counts/outputs; callback success, decline, destruction, and post-callback validation (including a callback that both destroys and declines); stale handles; both monotonic pool exhaustion paths; and a barrier-controlled read/destroy overlap. Independent property assertions encode the Vulkan 1.0 minima and cross-field rules directly rather than deriving expectations from the implementation's constants. Tests additionally cover enumeration, memory, and proc-address scopes. `kcov`, the Vulkan loader, and `vulkaninfo` are CI-only system tools; neither the ICD nor its tests gain a runtime project dependency.

## Forward rendering-test contract

The later rendering milestone—not this loader-discovery PR—must add a real Vulkan client that renders through the loader and ICD into an exact 240×240 target. Every newly supported 2D and 3D operation must have an isolated deterministic scene plus combined-operation coverage, with all 57,600 output pixels compared channel-by-channel against checked-in golden data. Any mismatch must fail with the operation, coordinate, expected pixel, and actual pixel. No tolerance or perceptual comparison is permitted for formats whose specified result is exact; any operation with specification-permitted numeric variance must document and enforce its per-channel rule explicitly. This PR does not implement or claim that rendering validation.

## Roadmap

1. **CPU 2D foundation:** validated surfaces, clipped fills, source-over blending, runtime-selected kernels, command execution, and headless demo.
2. **Minimal Vulkan ICD (this milestone):** loader negotiation and instance/device discovery with no conformance claim.
3. **Expanded Vulkan execution:** synchronization, images, transfer operations, render-pass/dynamic-rendering plumbing, and shader execution foundations.
4. **Later 3D:** vertex processing, sampling, depth/stencil, tiling, increasingly capable shaders, performance work, and eventual conformance investigation.

## Development gates

```sh
zig fmt --check build.zig src tools
zig build
zig build test
zig build coverage
zig build smoke
zig build demo
zig build -Doptimize=ReleaseFast
```

CI runs these commands on Linux. Generated PPM files and Zig build outputs are ignored.

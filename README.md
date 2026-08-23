# ZPU

ZPU is a Zig-first experiment in a minimal-dependency, Vulkan-only userspace CPU graphics driver. This milestone adds an **experimental loader-compatible development ICD**. It is not conformant Vulkan and is not yet sufficient for arbitrary Vulkan applications.

## Build and run

ZPU targets Zig 0.16.0, the newest stable compiler at the time of this milestone.

```sh
zig build
zig build test
zig build smoke
zig build demo
```

The build installs `zig-out/lib/libvulkan_zpu.so` and `zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json`. The shared object has no dynamic library dependencies. The loader-independent smoke test uses `dlopen` to resolve the three private loader entry points, negotiate interface version 7, create an instance, and enumerate the CPU device.

To ask a system Vulkan loader to discover only ZPU:

```sh
VK_DRIVER_FILES="$PWD/zig-out/share/vulkan/icd.d/zpu_icd.x86_64.json" vulkaninfo --summary
```

Loader discovery is optional for development because the Vulkan loader and `vulkaninfo` are system tools, not project dependencies. The C-ABI smoke test is the authoritative project gate.

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

The current ICD exposes one stable CPU physical device and one serial graphics+transfer queue. It advertises Vulkan 1.0, no extensions, no optional features, no usable device memory heaps, and conservative properties. Custom allocation callbacks and non-null extension chains are rejected. No rendering, memory allocation, command submission, presentation, or synchronization Vulkan entry points exist yet.

## Roadmap

1. **CPU 2D foundation:** validated surfaces, clipped fills, source-over blending, runtime-selected kernels, command execution, and headless demo.
2. **Minimal Vulkan ICD (this milestone):** loader negotiation and instance/device discovery with no conformance claim.
3. **Expanded Vulkan execution:** synchronization, images, transfer operations, render-pass/dynamic-rendering plumbing, and shader execution foundations.
4. **Later 3D:** vertex processing, sampling, depth/stencil, tiling, increasingly capable shaders, performance work, and eventual conformance investigation.

## Development gates

```sh
zig fmt --check build.zig src
zig build
zig build test
zig build smoke
zig build demo
zig build -Doptimize=ReleaseFast
```

CI runs these commands on Linux. Generated PPM files and Zig build outputs are ignored.

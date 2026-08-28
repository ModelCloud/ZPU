# ZPU

🎉 **Vulkan 1.4.360 command ABI coverage is now 100% (234/234).** Every
required cumulative core command from Vulkan 1.0 through 1.4 has a C-callable
ICD entry point, typed LP64/pointer-count handling, pNext and ownership
validation, a documented contract, unit/regression evidence, and a reproducible
verification path. The complete per-command status is generated in
[`docs/vulkan-abi.md`](docs/vulkan-abi.md).

The phrase *100% Vulkan 1.4 ABI compliant* is deliberately scoped to the
command/dispatch ABI: calling conventions, record layouts, enumeration and
count rules, pNext handling, lifetime/error behavior, and loader lookup. It is
not a claim that every optional feature is enabled, that
`VP_KHR_roadmap_2026` is met, or that the Vulkan CTS has passed. Commands for
capabilities ZPU does not advertise still implement their ABI with an explicit
default or unsupported result. Runtime version advertisement remains governed
by [`docs/api-policy.md`](docs/api-policy.md).

ZPU includes the bounded `zpu_spirv_render_profile_v1` frontend. It validates
and lowers a small SPIR-V 1.0 subset to owned canonical render IR, while the
public CPU-cube and scalar graphics/compute paths execute only the interfaces
described by the implementation contract. Arbitrary SPIR-V, textures outside
the supported formats, and unsupported execution features fail closed rather
than being silently misinterpreted.

The v1 frontend accepts only Shader + Logical GLSL450, a selected straight-line
Vertex or Fragment entry, bounded scalar/vector/mat4 and read-only uniform data,
and the small arithmetic/composite operation list documented in
[`design/render-ir.md`](design/render-ir.md). Textures, sampling, ExtInst,
control flow, calls, derivatives, discard, atomics, barriers, push constants,
storage writes, dynamic indexing, undefined/non-finite values, and all later
SPIR-V versions are rejected rather than interpreted.
In particular, every profile-v1 access-chain index must be a scalar `u32`
ordinary or specialized constant after specialization. A runtime scalar `u32`
index is dynamic indexing and is rejected by both the frontend and canonical
IR executor setup.

Pipeline creation treats that rejection as pipeline failure and publishes no
pipeline or cache result. The only exception is an exact `cpu_cube_v1`
compatibility predicate for the immutable vertex/fragment module identities
embedded by the readiness vkcube: both stages, `main`, exact word counts and
full digests, and no specialization must match. This bridge does not create a
frontend program and is not broader shader acceptance.

Internally, the pipeline ABI is a typed choice among `cpu_cube_v1`,
`profile_v1_metadata`, and `profile_v1_scalar_synthetic`. The last is a private,
non-advertised, non-conformant test hook that owns one selected vertex or
fragment scalar executor and accepts explicit interface-indexed byte bindings
and outputs. It is never reached by Vulkan drawing and provides no Vulkan API,
extension, feature, or profile-support claim.

ZPU is a Zig-first experiment in a minimal-dependency, Vulkan-only userspace CPU graphics driver. The command ABI is complete for the pinned Vulkan 1.4.360 core, while feature support remains intentionally bounded and non-CTS-conformant. The normative target for the API surface — the pinned core version, the profile ZPU builds toward, the loader–ICD interface requirement, and the gates that must pass before any advertised version changes — is [docs/api-policy.md](docs/api-policy.md). The driver, the ICD manifest, and CI advertise and assert Vulkan 1.0 today; the policy describes the runtime-advertisement gates, not a missing command entry point.

## Build and run

ZPU targets Zig 0.16.0, the newest stable compiler at the time of this milestone.

```sh
zig build
zig build api-inventory
zig build test
zig build isa-gate
zig build isa-cross
zig build coverage
zig build smoke
zig build transfer
zig build headless-present
zig build desktop-probe
zig build vkcube-ready
zig build xcb-present
zig build vkcube-visual
zig build desktop-session
zig build demo
zig build benchmark-3d
zig build pr-readiness
```

All repository gates must be run through the Linux physical-core limiter, for example `tools/limited-cpus.sh zig build test`. Benchmark methodology, stable JSON, controlled baseline capture/comparison, tolerances, reproducibility guidance, and the opt-in hardware guard are documented in [docs/benchmarking.md](docs/benchmarking.md). The deterministic vkcube-specific 3D benchmark, real 20-second capture, progress table, and commit-bound gate are documented in [docs/pr-readiness.md](docs/pr-readiness.md); this narrow workload is not general SPIR-V.

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

For the hardware-isolated Omarchy workflow, [the SmolVM guest guide](docs/smolvm-omarchy.md)
builds and stages ZPU wholly inside a real `smol-machines/smolvm` guest, rejects
host ICD injection, and displays the guest's native XCB Vulkan validation window
through the host Xwayland socket without enabling SmolVM's Venus GPU path.
The real graphical proof used a nested Xephyr display through headless
Weston/Xwayland. No real Omarchy image or Hyprland session was available for
that run, so native Omarchy/Hyprland confirmation remains an explicit gate.
The `smolvm-dry-run` build gate uses a transcribed CLI fixture, private test
socket, and `env -i`; it requires neither real SmolVM nor a live display.

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

The end-to-end Linux boundary is mapped in
[`docs/linux-userspace-driver.md`](docs/linux-userspace-driver.md). It includes
component, loader-discovery, frame-sequence, memory/presentation, and CPU-thread
diagrams, plus an explicit account of which work stays in the application
process, which work crosses into the X server, and why ZPU is not a kernel
DRM/KMS driver.

- `src/surface.zig` owns RGBA8/BGRA8 memory layout, validation, colors, and clipping.
- `src/raster/` implements clear/fill and straight-alpha Porter-Duff source-over rectangles.
- `src/simd/` owns backend selection and the scalar and portable four-pixel vector tiers; the eight-pixel tier is compiled separately in `src/x86_64_v3_kernels.zig` (see [design/isa-tiers.md](design/isa-tiers.md)).
- `src/command/` decouples command recording semantics from raster execution.
- `src/platform/` owns presentation; today that is a headless PPM sink.
- `src/vulkan/` contains original Vulkan 1.4.360 command ABI declarations, private loader entry points, object lifetime handling, and the ICD manifest.

ISA tiers are enforced by a build/code-generation boundary, not by naming conventions. Default builds pin every artifact to the x86-64 baseline CPU model, so no VEX-encoded (AVX, AVX2, AVX-512, FMA, BMI) instruction can exist inside any project function (foreign library code on an explicit allowlist and data tables are reported separately); `-Dcpu=` remains an explicit opt into a higher artifact tier. The eight-lane kernels are compiled as their own x86-64-v3 static library that baseline codegen reaches only through extern symbols after runtime CPUID AVX/OSXSAVE, XCR0, and AVX2 checks pass; a tripwire panics if an unsupported host ever reaches them, and the comptime boundary flag is tied to actual linkage so AVX2 availability can never be advertised without the kernel objects present. The width-oriented kernels use Zig `@Vector` rather than handwritten intrinsics, so pixel results are identical across tiers. AVX-512 is intentionally reserved (detected only as a disassembly hazard, never selected for rendering) until controlled frame-tail measurements justify a separate kernel tier. `zig build isa-gate` enforces all of this with deterministic raw-prefix disassembly analysis (ReleaseFast kernel-free twins must be fully clean; default artifacts may carry VEX only inside genuinely vectorized `zpu_v3_*` kernels), with fixture-based negative controls proving leaks fail closed.

### Zig primitives and CPU tiers ⚙️

The Vulkan command layer uses Zig `extern` records for stable C ABI layout,
`?*T`/`?[*]T` pointers for nullable Vulkan arrays, checked integer arithmetic
for byte spans, tagged unions for recorded commands, and fixed-capacity arrays
for allocation-free hot paths. The raster layer uses comptime-sized
`@Vector` lanes, `@memcpy`, and explicit endian/format helpers; scalar code is
the reference implementation and every optimized result is compared byte for
byte against it.

| Tier | How ZPU uses it | Status |
| --- | --- | --- |
| Baseline/scalar | Zig scalar arithmetic and bounds-checked slices; safe on every supported x86-64 host. | Always enabled |
| Portable vector | Four-pixel `@Vector` kernels compiled into the baseline artifact. | Always enabled |
| AVX/AVX2 | AVX/OSXSAVE/XCR0 are prerequisites; the linked x86-64-v3 AVX2 library executes eight-pixel `@Vector` kernels only after CPUID gating. | Runtime-selected when available |
| AVX-512 | No AVX-512 instructions are dispatched or advertised; disassembly gates reject accidental leakage. | Reserved for measured future work |

Tests compare every backend byte-for-byte with scalar for both formats, deliberately misaligned surface starts and padded strides, clipping and off-screen rectangles and sprites, odd widths and vector tails, alpha 0/1/128/254/255, and deterministic randomized content and operations.

## Design position

ZPU borrows only high-level lessons from studying mature projects such as Mesa and SwiftShader: keep API translation separate from execution, make formats explicit, centralize CPU capability policy, and test optimized paths against a reference. No source code was copied from those or other projects; this implementation is original.

The ICD's XCB WSI path has a runtime dependency on libxcb (plus the normal C/math runtime). It is Vulkan-only by design: compatibility with OpenGL, legacy APIs, or historical driver ABIs is not a goal, and future interfaces may change incompatibly while the ICD takes shape. ZPU carries no legacy-specific paths, compatibility shims, or deprecated, vendor, or promoted aliases kept alive solely for old clients; [docs/api-policy.md](docs/api-policy.md) states that rule normatively, along with the narrow case where a present-day client still requires a promoted extension by name. ABI declarations are an original narrow transcription traceable to the [pinned Vulkan 1.4.360 specification](https://registry.khronos.org/vulkan/specs/1.4/html/vkspec.html) and [Khronos loader/driver interface](https://github.com/KhronosGroup/Vulkan-Loader/blob/main/docs/LoaderDriverInterface.md); no Mesa, SwiftShader, Vulkan-Loader, or Vulkan-Headers source is copied.

The current ICD exposes one stable CPU physical device and one serial graphics+transfer queue. It advertises Vulkan 1.0, the instance extensions `VK_KHR_surface`, `VK_KHR_xcb_surface`, `VK_EXT_headless_surface`, `VK_KHR_external_memory_capabilities`, and `VK_KHR_external_semaphore_capabilities`, the single device extension `VK_KHR_swapchain`, no optional features, one conservative 256 MiB unified host-visible/coherent non-device-local memory heap/type, and the Vulkan 1.0 mandatory minimum physical-device limits. `VK_EXT_headless_surface` creates an offscreen surface and swapchain that never touches XCB; `zig build headless-present` verifies that lifecycle through the system Vulkan loader. The promoted external-capability names return an explicit zero-handle policy and do not imply external-memory import/export support. The heap backs device memory, buffers, and tightly packed linear 2D `VK_FORMAT_R8G8B8A8_UNORM`/`VK_FORMAT_B8G8R8A8_UNORM` images. Vulkan copy/fill commands preserve their API semantics, but on ZPU they operate on unified host memory and are not discrete-VRAM uploads. Custom allocation callbacks and unsupported direct application extension chains are rejected; documented loader-owned instance/device chains are parsed only while their structure type remains loader-owned, and opaque application tails are not traversed.

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
5. **General 3D:** broader SPIR-V execution, pipeline state, tiling, increasingly capable shaders, performance work, and eventual conformance investigation against the version and profile pinned in [docs/api-policy.md](docs/api-policy.md). The command ABI is already complete for Vulkan core 1.4.360; `VP_KHR_roadmap_2026` and unrestricted feature conformance remain future gates, and the advertised runtime version does not move until those gates pass.

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
tools/limited-cpus.sh zig build target-800x600 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-4k-30 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-4k-60 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-4k-120 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-4k-240 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build target-8k-60 -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build demo
tools/limited-cpus.sh zig build -Doptimize=ReleaseFast
tools/limited-cpus.sh zig build smolvm-guest-test
tools/limited-cpus.sh zig build smolvm-dry-run
```

These are the repository's Linux gates; the CI configuration is the exact
authoritative list run by CI. The SmolVM isolation fixture and dry-run commands
above are local review gates and are not currently CI jobs. Generated PPM files
and Zig build outputs are ignored.

`target-800x600` runs the real `vkcube` XCB path at 800x600, discards 120 warmup
frames, then times 1,000 consecutive presented frames. It fails unless p99 frame
time is at most 4,166,666 ns, equivalent to a 240 FPS 1% low. The measurement
includes command submission, ZPU's CPU cube rasterizer, and XCB image upload.
Presentation pacing defaults to 120 Hz and follows the validated
`ZPU_REFRESH_HZ=1..1000` setting; this target explicitly selects 240 Hz.
ZPU also exposes `VK_EXT_present_timing`: applications can attach
`VkPresentTimingsInfoEXT` to each `vkQueuePresentKHR` call and select an absolute
monotonic or relative target time per swapchain. Untimed presents retain the
process-local `ZPU_REFRESH_HZ` cadence. When the swapchain timing queue is
enabled with `vkSetSwapchainPresentTimingQueueSizeEXT`,
`vkGetPastPresentationTimingEXT` returns bounded FIFO history with queue,
dequeue, first-pixel-out, and first-pixel-visible timestamps for the requested
present stages. The optional `VkPresentId2KHR` chain supplies application
present IDs; otherwise ZPU assigns monotonic per-swapchain IDs. Count queries,
`VK_INCOMPLETE`, and queue-full backpressure are failure-atomic and
allocation-free on the warm path.

`target-4k-30`, `target-4k-60`, `target-4k-120`, and `target-4k-240` apply the same individual-frame ultra-low
1% timing gate to real 3840x2160 `vkcube`: after 120 warmup frames, p99 across
1,000 frames must not exceed 33,333,333 ns, 16,666,666 ns, 8,333,333 ns, and
4,166,666 ns respectively. The strict floors use explicit 31 Hz, 63 Hz, 122 Hz,
and 255 Hz pacing guard bands so ordinary wake jitter cannot turn an exact
nominal cadence into a dishonest sub-target 1% low.
`target-8k-60` extends the same real-present p99 gate to 7680x4320: 1,000
post-warmup frames must remain at or below 16,666,666 ns with the standard
63 Hz pacing guard. ZPU advertises and enforces an 8192x8192 maximum 2D image,
framebuffer, viewport, and XCB surface extent to support this workload.
With the canonical eight-core gate, the harness dedicates one inherited CPU to
Xvfb and confines the client process to the other seven; ZPU itself selects at
most two of those CPUs and never escapes the caller's original affinity budget.
The vkcube-specific rasterizer uses 32x32 tiles at 4K and 8K to reduce
classification overhead without removing per-pixel coverage or depth tests.
It conservatively records every tile touched by transformed, non-culled
triangles and clears only those dirty tiles before the next draw, preserving
unchanged background tiles without weakening color or depth correctness. The
4K and 8K paths add one swapchain image, within the advertised four-image
limit, to absorb rare producer stalls without expanding the CPU set.

ZPU ranks CPUs within the process's inherited affinity mask once and keeps all
assignments on one NUMA node for the process lifetime. Every 2D path executes
only on the pinned render CPU. A complex 3D pipeline may use one additional
pinned raster CPU; presentation may migrate only between those same two
cache-local CPUs, and ZPU never schedules work on a third CPU. Large color,
depth, and XCB SHM caches are bound before first touch to the selected node and
receive transparent huge-page advice; ZPU never expands the CPU mask supplied
by the caller.

`VK_GOOGLE_display_timing` is deliberately unsupported with no compatibility
alias. Requests for that extension, its device procedures, or
`VkPresentTimesInfoGOOGLE` emit an explicit driver error directing applications
to `VK_EXT_present_timing` and `ZPU_REFRESH_HZ`.

# CPU Metal layer (WIP)

This branch adds a native, Metal-shaped command layer in `src/metal`. Its
portable core is a CPU implementation with a separate optional Apple
Objective-C adapter. The public types are intentionally a new ZPU ABI where
Metal has no safe 1:1 Vulkan mapping; no Vulkan translation is performed by
the command recorder. The adapter objects declare the corresponding Metal
protocols and expose the selector surface for normal Objective-C capability
checks, but all supported work stays in ZPU-owned CPU resources and ZPU's
portable runtime.

The current increment covers an ordered render-pass path plus a native CPU
triangle path:

- `MTLRenderPassDescriptor`-shaped load/store and clear state
- command-buffer recording and end/commit lifecycle
- `clear` and clipped rectangle fill into RGBA8/BGRA8 surfaces, serialized on
  the submitting core
- clip-space point, line, line-strip, triangle, and triangle-strip draws with
  viewport, scissor, cull, winding, fill-mode, color interpolation, and depth
- two screen-band workers for a 3D draw: the submitting core plus one worker
- owned RGBA8/BGRA8 buffers and 2D textures with checked region read/write
- buffer and texture resource options preserve the requested storage mode, CPU
  cache mode, hazard mode, texture usage, optimization flag, compression mode,
  and swizzle metadata; indirect command buffers preserve their resource
  options, and texture views inherit those properties from their ZPU-owned
  backing resource
- heap-backed buffers and textures with bounded allocation accounting; heap
  storage/cache mismatches are rejected and default heap hazard tracking is
  resolved as untracked, matching Metal's heap rules
- owned depth32-float textures bound as render-pass depth attachments, with
  configurable Metal compare functions, write masks, and depth clears
- fixed-function render pipeline, depth-stencil, and sampler state objects;
  pipeline attachment format validation, blending factors/operations, color
  write masks, and Metal top-left triangle edge inclusion
- Metal pixel-grid coordinates: texture row/column zero is the upper-left
  texel, `MTLViewport` and `MTLScissorRect` origins are applied in that same
  top-left space, and clip-space `+Y` maps toward decreasing row indices
  (`originY`); this is covered by an asymmetric non-zero-origin native-oracle
  test. This is the Metal texture coordinate space on both macOS and iOS; any
  AppKit/UIKit view-coordinate conversion belongs to the caller and is not
  silently applied by the CPU adapter
- buffer-backed texture views that alias storage with checked row strides and
  preserve the backing resource lifetime
- CPU-owned `MTLTextureViewPool` slots that create/copy ZPU texture views or
  buffer-backed views and return synthetic resource IDs usable by MTL4
  argument tables
- ordered render, parallel-render, and blit encoders, command-buffer status,
  buffer copies/fills, texture transfers, indexed and indirect draws, render
  indirect command buffers (including CPU blit-copy of encoded commands),
  texture views, and ordered MTLFence update/wait commands
- a deferred CPU compute encoder for the explicit
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8` and
  `ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE` kernels; they operate
  directly on ZPU-owned buffers/textures and never invoke Apple's Metal runtime
- CPU-owned Metal 4 command allocators, command buffers, command queues, and
  argument tables; Metal 4 compute dispatches bridge process-local argument
  table resource IDs to ZPU-owned resources and execute through the same
  deferred CPU kernels
- CPU-owned Metal 4 render encoders for ordinary render passes; they bridge
  MTL4 attachment descriptors, GPU-address argument tables, fixed-function
  raster state, indexed/indirect draws, fences, and viewport/scissor state to
  the existing ZPU raster encoder. The MTL4 path preserves the same upper-left
  pixel grid and clip-space +Y direction as the legacy adapter
- indirect threadgroup dispatch arguments are read from ZPU buffers at commit
  time, preserving Metal's deferred argument-buffer semantics
- Metal 4 indirect thread dispatch arguments (grid and threadgroup dimensions)
  are also read from the ZPU buffer at commit time, rather than when the
  encoder records the call
- compute `setBytes` bindings are copied into command-buffer-owned ZPU buffers
  and follow the same deferred lifetime rules
- compute sampler/resource declarations, stage-in metadata, and memory
  barriers are accepted on the CPU encoder; barriers are ordered no-ops because
  the current ZPU command buffer executes serially, and registered kernels do
  not sample or consume stage-in/threadgroup metadata
- argument encoders retain ZPU resources, provide aligned CPU constant storage,
  and serialize supported buffer/texture/sampler bindings into deterministic
  CPU-side 16-byte slots containing synthetic resource IDs and buffer offsets;
  arbitrary shader-specific Metal layouts are still not synthesized
- CPU-owned Metal 4 timestamp counter heaps; timestamps are monotonic values
  from the adapter's CPU clock domain, resolve into ZPU buffers, and support
  immediate CPU-range invalidation. `queryTimestampFrequency` reports
  nanoseconds for this CPU clock domain; no hardware GPU timestamp is exposed
- CPU-owned legacy timestamp counter sets/sample buffers; draw, dispatch, and
  blit sample points resolve to `MTLCounterResultTimestamp` records in shared
  ZPU buffers. Unsupported hardware-only counters remain unavailable rather
  than being reported as fabricated statistics
- CPU library metadata can discover the two registered kernel names from
  source text and create ZPU-owned `MTLFunction` descriptors; unsupported
  arbitrary MSL, file/data libraries, and stitched libraries fail closed
- CPU indirect compute commands for those registered kernels; the command
  buffer inherits the ZPU encoder's texture bindings and records pipeline,
  buffer, and dispatch state for deferred execution
- Metal 4 basic buffer/texture copy and buffer-fill commands append deferred
  ZPU work; tensor, advanced optimization, acceleration-structure,
  sparse, drawable, residency, machine-learning, and tile/mesh render-pass
  features remain explicit fail-closed boundaries. Suspending/resuming render
  passes are represented as sequential ordinary CPU passes because the CPU
  implementation has no tile-memory stitching requirement. The
  adapter never routes them to native Metal
- classic Metal resource, pipeline, blit, event, indirect-command, and
  command-buffer selectors that have no portable CPU meaning are represented
  explicitly: metadata-only operations are deterministic no-ops, while
  arbitrary shader compilation, binary linking, sparse/placement
  resources, ray tracing, tensors, I/O, and unsupported Metal 4 advanced
  families return nil or a stable error. They never fall through to Apple's
  native Metal runtime

The C header exposes both `zpu_metal_render`, an opt-in single-pass entry
point, and a resource/command-buffer API for C, C++, and Objective-C clients.
The latter owns RGBA8/BGRA8/depth32-float buffers and textures, records
render/blit work, and executes it at command-buffer commit. Its render state
uses a fixed `zpu_metal_vertex` ABI; it does not parse MSL or execute arbitrary
shader functions. The optional Apple adapter supplies the supported
Metal-shaped Objective-C objects, while malformed resources are rejected with stable
negative error codes. The Apple adapter also delivers scheduled/completed
command-buffer handlers and explicit shared-event notifications for the
implemented synchronous runtime.

On macOS, `zig build metal-pixel` compiles a tiny runtime MSL shader, renders a
known triangle pair using Apple's Metal framework, renders the same vertices
through ZPU, and compares every output byte. The test covers clear, triangle
coverage, color interpolation, BGRA channel order, object lifetimes, depth
ordering, pipeline/depth/sampler state, blending, texture views, indirect
draws, render and compute indirect command buffers, the CPU compute path
  against a native Metal oracle, the Metal 4 CPU argument-table compute and
  ordinary render paths, and deferred indirect-thread dispatch,
and the explicit adapter; it is not a claim that every Metal feature is
implemented.

Use `zig build metal-install` to install the standalone static library without
requiring the repository's Linux Vulkan/XCB install artifacts.

The focused checks are:

```sh
tools/limited-cpus.sh zig build metal-test
tools/limited-cpus.sh zig build metal-c-api
tools/limited-cpus.sh zig build metal-pixel
tools/limited-cpus.sh zig build metal-install -Dtarget=aarch64-ios -Dxcb=false
```

The last command is a compile-only iOS arm64 check; an iOS device or simulator
is still required for runtime execution.

On Apple targets, `include/zpu/metal_apple.h` exposes the explicit
`ZPUMetalCreateSystemDefaultDevice()` factory. It returns a ZPU-backed
`id<MTLDevice>`-shaped object for the implemented core methods; it does not
interpose Apple's global `MTLCreateSystemDefaultDevice` symbol.
`ZPUMetalCreateCPUFunction()` creates a ZPU-owned function descriptor without
compiling MSL; registered kernel names select CPU kernels, while fixed render
function names provide metadata for the CPU raster path. Native `MTLFunction`
objects are needed only by the separate oracle side of the pixel test. The adapter's
`newLibraryWithSource:` is a CPU metadata registry for named ZPU kernels; it
does not compile or execute arbitrary MSL.

The API inventory is checked in at `api/metal-abi.json`. It intentionally marks
the implementation as WIP: Apple's complete current Metal/Metal 4 framework
surface is substantially larger than this CPU renderer and is not claimed as
covered here. `tools/metal_abi_status.py --require-complete` is the fail-closed
gate to run with the target SDK; non-Apple builds can only validate the native
ABI and mapping manifest. The Apple documentation is the normative API
reference: <https://developer.apple.com/documentation/metal>.

## Mapping policy

1. ABI-compatible values such as color, viewport, scissor, attachment
   load/store actions, formats, and basic topology are listed in
   `src/metal/mapping.zig` as direct Vulkan remaps. No translation pass is
   involved.
2. Metal object lifetime, encoder lifecycle, and pass ownership are native
   ABI entries because Vulkan does not provide a 1:1 mapping for those
   semantics. This label does not authorize native Apple execution: the ZPU
   adapter and portable runtime execute on the CPU, while Apple Metal is used
   only by the pixel-accuracy oracle test.
3. CPU scheduling is bounded by workload: 2D uses one core, 3D uses at most
   two rendering lanes. This is an execution policy, not an API promise that
   an Apple device has a particular topology.

## Coverage status

The current checked-in implementation is intentionally not 100% of the Apple
Metal ABI. The remaining framework surface includes additional compute and
Metal 4 encoders, resource and pipeline descriptors beyond the fixed-function state
implemented here, Metal 4 tile/mesh render and remaining copy/optimization families, ICB patch/mesh commands, other
synchronization families, ray tracing, sparse resources, machine
learning/tensors, and arbitrary shader compilation. A strict completeness claim
belongs only after the Apple SDK inventory and macOS/iOS behavior tests pass.

The SDK inventory on the current Xcode 26.6 host contains 96 headers, 253
Metal-named types, 446 Objective-C selectors, and 11 C functions. Those counts
are useful review gates; they are not implementation coverage. ZPU cannot
replace Apple's system `MTLCreateSystemDefaultDevice` from an ordinary app, so
the supported integration is explicit selection of this portable ABI.

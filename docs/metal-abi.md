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
  viewport, scissor, cull, winding, fill-mode, color interpolation, depth
  bias/slope scale, and clip-vs-clamp depth behavior
- two screen-band workers for a 3D draw: the submitting core plus one worker
- owned RGBA8/BGRA8 buffers and 1D/2D/3D textures with checked region read/write
- CPU-owned R32Float and RGBA16Float textures preserve native texel widths for
  raw transfers, views, buffer-backed storage, and heap allocation accounting;
  render/compute paths accept R32Float and RGBA16Float as CPU color targets;
  formats without a corresponding CPU shader profile remain rejected
  profile
- ordinary device-created 1D, 1D-array, 2D, and 2D-array textures with independently
  allocated CPU/ZPU slice×mip levels, exact level/slice read/write,
  level/slice-range views, and level/slice-aware blit copies; CPU mipmap
  generation uses Metal's destination-center linear filter and matches the
  native RGBA8/R32Float/RGBA16Float oracles; buffer-backed and
  heap-backed textures use independently allocated CPU/ZPU slice×mip levels
  with full allocation-size accounting; linear buffer-backed textures remain
  explicitly limited to one 2D level because their caller-supplied stride
  cannot describe a portable mip layout; 3D textures use one ZPU-owned 2D
  plane per z slice, including mip-level depth reduction, explicit
  `bytesPerImage` transfers, 3D views, heap placement, and legacy/Metal 4
  texture and buffer copies plus center-sampled mipmap generation
- buffer and texture resource options preserve the requested storage mode, CPU
  cache mode, hazard mode, texture usage, optimization flag, compression mode,
  and swizzle metadata; indirect command buffers preserve their resource
  options, and texture views inherit those properties from their ZPU-owned
  backing resource
- `newBufferWithBytesNoCopy` aliases caller-owned CPU memory through the ZPU
  buffer while deferring the supplied deallocator until the adapter resource
  is released
- heap-backed buffers and textures with bounded allocation accounting; heap
  storage/cache mismatches are rejected, heap offsets are retained for
  resources, explicit aligned append placement is supported for heap buffers,
  and default heap hazard tracking is resolved as untracked, matching Metal's
  heap rules
- owned depth32-float textures bound as render-pass depth attachments, with
  configurable Metal compare functions, write masks, and depth clears
- owned Stencil8 textures bound as render-pass stencil attachments, with
  front/back compare functions, fail/depth-fail/pass operations, read/write
  masks, references, and clear/load/store behavior
- depth-only render passes are accepted by the legacy, parallel, and Metal 4
  adapters; a private discarded CPU color surface preserves the portable
  raster ABI while public depth bytes remain exact
- up to eight RGBA8/BGRA8/R32Float/RGBA16Float color attachments can be
  described and cleared by a CPU render pass; the explicit
  `zpu_test_mrt_fragment` profile mirrors one logical fragment color to every
  extra target, while ordinary single-output profiles leave extra targets at
  their load/clear value
- the bounded `zpu_test_sample_fragment` profile samples a ZPU-owned color
  texture with interpolated normalized coordinates and nearest filtering;
  native Metal is used only as the byte-accuracy oracle
- the bounded `zpu_cpu_uniform_color_fragment` profile consumes a 16-byte
  `float4` from `setFragmentBytes:length:atIndex:0` and applies it through
  the CPU raster path; it also consumes a ZPU-owned 16-byte `float4` buffer
  binding at fragment index 0 with commit-time reads, so writes made before
  commit are visible; other fragment byte layouts remain unsupported
- fixed-function render pipeline, depth-stencil, and sampler state objects;
  pipeline attachment format validation, blending factors/operations, color
  write masks, depth bounds, and Metal top-left triangle edge inclusion
- Metal pixel-grid coordinates: texture row/column zero is the upper-left
  texel, `MTLViewport` and `MTLScissorRect` origins are applied in that same
  top-left space, and clip-space `+Y` maps toward decreasing row indices
  (`originY`); this is covered by an asymmetric non-zero-origin native-oracle
  test. This is the Metal texture coordinate space on both macOS and iOS; any
  AppKit/UIKit view-coordinate conversion belongs to the caller and is not
  silently applied by the CPU adapter
- render-pass attachment mip levels and single array slices select the
  corresponding ZPU texture and use that target's width/height for
  rasterization; multi-layer render passes and depth planes remain explicitly
  rejected
- buffer-backed texture views that alias storage with checked row strides and
  preserve the backing resource lifetime
- CPU-owned `MTLTextureViewPool` slots that create/copy ZPU texture views or
  buffer-backed views and return synthetic resource IDs usable by MTL4
  argument tables
- ordered render, parallel-render, and blit encoders, command-buffer status,
  buffer copies/fills, texture transfers, indexed and indirect draws, render
  indirect command buffers (including CPU blit-copy of encoded commands),
  texture views, level-aware mipmap generation/copies, ordered MTLFence
  update/wait commands, and CPU-owned visibility result buffers with aligned
  boolean/counting modes plus reset/accumulate behavior
- a deferred CPU compute encoder for the explicit
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8`,
  `ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE`, and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY` and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D`,
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT`, and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT` kernels; they operate directly
  on ZPU-owned buffers/textures and never invoke Apple's Metal runtime. Array
  dispatches expand the logical z grid into ordered per-slice ZPU commands;
  3D dispatches expand z into plane commands while preserving the z coordinate
  in the CPU kernel; indirect array/3D dispatches resolve the deferred z
  extent at commit and skip slices outside that extent
- CPU-owned Metal 4 command allocators, command buffers, command queues, and
  argument tables; Metal 4 compute dispatches bridge process-local argument
  table resource IDs to ZPU-owned resources and execute through the same
  deferred CPU kernels
- CPU-owned Metal 4 compiler metadata for the registered ZPU kernel set:
  MTL4LibraryFunctionDescriptor objects resolve through ZPU libraries,
  compiler-created compute pipeline descriptors instantiate the existing ZPU
  CPU kernels, binary functions expose deterministic name/type metadata, and
  asynchronous compiler tasks complete synchronously after CPU construction;
  render/tile/mesh, dynamic-library, machine-learning, and arbitrary-MSL
  compiler requests remain fail-closed
- CPU-owned Metal 4 pipeline-data serializers record those registered compute
  names and emit deterministic ZPU metadata scripts or the existing ZPU
  binary-archive format; these outputs are not Apple metal-tt scripts or
  native GPU binaries
- owner-checked CPU function handles expose registered compute names/types and
  the required zero gpuResourceID sentinel; visible/intersection function
  tables and GPU function-pointer execution remain unsupported
- supported Apple-adapter render state and draw selectors propagate ZPU
  validation failures to `MTLCommandBufferStatusError`; invalid state is not
  silently reported as successful CPU work
- CPU-owned Metal 4 commit options and feedback; the explicit
  `ZPUMetalCreateCPUCommitOptions()` extension creates options whose feedback
  handlers receive host-time start/end values after the ZPU command buffers
  complete
- CPU-owned Metal 4 render encoders for ordinary render passes; they bridge
  MTL4 attachment descriptors, GPU-address argument tables, fixed-function
  raster state, indexed/indirect draws, fences, and viewport/scissor state to
  the existing ZPU raster encoder. The MTL4 path preserves the same upper-left
  pixel grid and clip-space +Y direction as the legacy adapter
- indirect threadgroup dispatch arguments are read from ZPU buffers at commit
  time, preserving Metal's deferred argument-buffer semantics
- direct and indexed render draws read ZPU vertex and index buffer bindings at
  commit time; inline `setVertexBytes` data remains an encode-time snapshot,
  and filled-geometry oracles avoid conflating point raster coordinates with
  resource visibility
- direct and indexed indirect render draws read their ZPU argument buffers at
  commit time, including `vertexStart`, `instanceCount`, `indexStart`, and
  signed `baseVertex`; indexed `indexStart` is converted from elements to
  bytes using the bound index type
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
- CPU library metadata can discover the six registered kernel names and fixed
  CPU render profiles from source text, UTF-8 file/URL/data inputs, and the
  default bundle query; unsupported arbitrary MSL and stitched libraries fail
  closed
- `newDefaultLibrary` returns the same CPU metadata library for the registered
  ZPU kernels, including the array and 3D kernels; it does not load or compile an Apple
  `.metallib`
- CPU binary archives persist and reload deterministic metadata for registered
  ZPU compute/render functions; the Metal 4 archive view can reopen registered
  compute metadata; neither archive API serializes Apple GPU binaries
- CPU resource-state encoders preserve Metal encoder boundaries and fence
  ordering. Resource/cache transitions are ordered no-ops over ZPU's unified
  CPU memory, while sparse texture mapping requests fail closed
- CPU residency sets track ZPU allocations, committed byte totals, and
  request/end-residency state without introducing a GPU residency domain
- process-local shared-event handles round-trip the same ZPU event and
  preserve monotonic signaling; decoded or foreign handles fail closed because
  the CPU adapter does not invent a cross-process GPU primitive
- process-local shared-texture handles round-trip shareable ZPU textures and
  preserve their CPU bytes and metadata; IOSurface-backed and foreign handles
  remain unsupported rather than importing native storage
- CPU visible/intersection function tables retain ZPU-owned function handles,
  buffer bindings, opaque-intersection signatures, and visible-table links;
  they expose deterministic CPU resource metadata and IDs, while arbitrary
  function-pointer dispatch and ray tracing remain unsupported
- CPU render pipeline states resolve vertex/fragment function handles by
  owner, stage, and name, including Metal 4 binary-function metadata; foreign
  functions and unsupported stages fail closed
- CPU indirect compute commands for those registered kernels; the command
  buffer inherits the ZPU encoder's texture bindings and records pipeline,
  buffer, and dispatch state for deferred execution
- Metal 4 basic buffer/texture copy and buffer-fill commands append deferred
  ZPU work; tensor, advanced optimization, acceleration-structure,
  sparse, drawable, machine-learning, and tile/mesh render-pass
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
The latter owns RGBA8/BGRA8/depth32-float/Stencil8 buffers and textures, records
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
  ordinary render paths, compiler-created Metal 4 compute/render and archive
  metadata paths, deferred indirect-thread dispatch, and deferred
  indirect array z filtering, explicit 3D texture plane/stride copies, and
  legacy/Metal 4 3D mipmap generation, 2D float mipmap raw-byte exactness, and
  legacy/Metal 4 visibility result byte exactness, and CPU depth-bounds output
  against an equivalent native Metal fragment-discard oracle,
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
synchronization families, ray tracing execution, sparse resources, machine
learning/tensors, and arbitrary shader compilation. Function-table storage is
implemented, but it does not imply ray-tracing or arbitrary function-pointer
execution. A strict completeness claim belongs only after the Apple SDK
inventory and macOS/iOS behavior tests pass.

The SDK inventory on the current Xcode 26.6 host contains 96 headers, 253
Metal-named types, 446 Objective-C selectors, and 11 C functions. Those counts
are useful review gates; they are not implementation coverage. ZPU cannot
replace Apple's system `MTLCreateSystemDefaultDevice` from an ordinary app, so
the supported integration is explicit selection of this portable ABI.

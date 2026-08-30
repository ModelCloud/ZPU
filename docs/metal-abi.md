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
  homogeneous X/Y/W clipping, viewport, scissor, cull, winding, fill-mode,
  color interpolation, depth bias/slope scale, and clip-vs-clamp depth behavior
- two screen-band workers for a 3D draw: the submitting core plus one worker
- owned A8/R8/R8Unorm_sRGB/R8Snorm/R16Unorm/R16Snorm/R16Float/RG8/RG8Unorm_sRGB/RG8Snorm/
  RG16Unorm/RG16Snorm/RG16Float/R32Uint/R32Sint/
  R8Uint/R8Sint/R16Uint/R16Sint/RG8Uint/RG8Sint/RG16Uint/RG16Sint/
  RG32Uint/RG32Sint/RGBA8/BGRA8/RGBA8Unorm_sRGB/BGRA8Unorm_sRGB/RGBA8Snorm/RGBA8Uint/RGBA8Sint/
  B5G6R5/A1BGR5/ABGR4/BGR5A1/RGB10A2/RG11B10/RGB9E5/BGR10A2 packed formats/
  R32Float/RGBA16Unorm/RGBA16Snorm/RGBA16Float/RGBA16Uint/RGBA16Sint/
  RGBA32Uint/RGBA32Sint/
  RG32Float/RGBA32Float buffers and
  Depth16Unorm/Depth32Float/Stencil8/Depth24Unorm_Stencil8/
  Depth32Float_Stencil8/X32_Stencil8/X24_Stencil8 raw CPU resources and
  1D/2D/3D textures with
  checked region read/write
- CPU-owned A8, R8Unorm/R8Unorm_sRGB/R8Snorm, R16Unorm/R16Snorm, R16Float,
  RG8Unorm/RG8Unorm_sRGB/RG8Snorm, RG16Unorm/RG16Snorm, RG16Float,
  R8/R16/RG8/RG16/R32/RG32/RGBA8/RGBA16 Uint/Sint,
  R32Float, RGBA16Unorm/RGBA16Snorm, RGBA16Float, RG32Float, RGBA32Float,
  and packed B5G6R5/A1BGR5/ABGR4/BGR5A1/RGB10A2/RG11B10/RGB9E5/BGR10A2 textures preserve
  native texel widths for raw transfers, views, buffer-backed storage, and heap
  allocation accounting. Depth16Unorm and the combined depth/stencil formats
  use CPU-owned raw storage; Depth16Unorm, Depth24Unorm_Stencil8, and
  Depth32Float_Stencil8 are accepted by the CPU depth/stencil attachment path
  with explicit pack/unpack semantics, while X32_Stencil8 and X24_Stencil8
  remain stencil-only. Native combined-format availability and raw readback
  are device-specific, so CPU tests are the packing oracle; render paths accept
  A8Unorm, R8Unorm/R8Unorm_sRGB, R8Snorm,
  R16Unorm/R16Snorm, RG8Unorm/RG8Unorm_sRGB/RG8Snorm,
  RG16Unorm/RG16Snorm, R16Float, RG16Float, RGBA8Unorm/RGBA8Unorm_sRGB,
  RGBA8Snorm, BGRA8Unorm/BGRA8Unorm_sRGB, RGBA16Unorm/RGBA16Snorm,
  RGBA16Float, RG11B10Float, RGB9E5Float, R32Float, RG32Float, and RGBA32Float
  as CPU color targets; the registered `zpu_cpu_rgba8_uint_fragment` and
  `zpu_cpu_rgba8_sint_fragment` profiles additionally target RGBA8Uint and
  RGBA8Sint, while the matching registered profiles cover R8/R16/RG8/RG16/
  R32/RG32 Uint/Sint, RGB10A2Uint, and RGBA16Uint/RGBA16Sint. These integer render
  profiles use raw integer clears and exact native fragment conversion; integer
  mipmap generation remains rejected because no integer filtering profile is
  registered. RGBA32Uint/RGBA32Sint remain transfer-only while preserving their
  native texel widths;
  sRGB RGB channels
  use Apple's 12-bit linear fixed-point transfer profile for CPU sampling,
  attachment stores, clears, and mip generation; 2D mip levels are filtered
  from the base level while 3D mip levels are filtered recursively, matching
  the Apple GPU profile exercised by the native oracle; signed-normalized
  attachment stores and 2D/3D mip generation use integer-domain normalized
  filtering with native-oracle quantization; all other Uint/Sint formats remain
  transfer-only; packed normalized B5G6R5/A1BGR5/ABGR4/BGR5A1/RGB10A2/BGR10A2
  and packed RG11B10Float/RGB9E5Float formats use CPU decode/encode profiles
  for sampling, render targets, and 2D/3D mip generation, including the
  native packed-float mipmap truncation rule;
  fixed CPU compute profiles remain explicitly format-specific;
- formats without a corresponding CPU shader profile remain rejected
- CPU-owned `MTLDevice` identity and capability metadata, including a stable,
  copyable `MTLArchitecture` named `ZPU CPU`; this metadata never wraps or
  retains Apple's native Metal device
- ordinary device-created 1D, 1D-array, 2D, 2D-array, cube, and cube-array
  textures with independently allocated CPU/ZPU slice×mip levels (six faces
  per cube), exact level/slice read/write,
  level/slice-range views, and level/slice-aware blit copies; CPU mipmap
  generation uses Metal's destination-center linear filter and matches the
  native R8/R16Unorm/R16Float/RG8/RG16Unorm/RG16Float/RGBA8/R32Float/
  RGBA16Unorm/RGBA16Float/RG32Float/RGBA32Float and signed-normalized
  oracles; ordinary integer formats have native raw-byte/width oracles; buffer-backed and
  heap-backed textures use independently allocated CPU/ZPU slice×mip levels
  with full allocation-size accounting; linear buffer-backed textures remain
  explicitly limited to one 2D level because their caller-supplied stride
  cannot describe a portable mip layout; 3D textures use one ZPU-owned 2D
  plane per z slice, including mip-level depth reduction, explicit
  `bytesPerImage` transfers, 3D views, heap placement, and legacy/Metal 4
  texture and buffer copies plus center-sampled mipmap generation
- CPU-owned direct layered color render passes for up to eight 2D-array slices.
  The expanded direct instance index selects the corresponding ZPU-owned
  slice, preserving Apple's top-left X/Y pixel grid while keeping execution
  entirely on the CPU. Layered depth/stencil planes, indirect layered draws,
  and layered multisample passes remain explicitly rejected.
- CPU-owned 2D multisample textures with Apple-verified 2x and 4x default
  sample locations, represented as independent ZPU sample planes. Ordered
  render encoders can store those planes or resolve them into a matching
  single-sample color texture using `MultisampleResolve` or
  `StoreAndMultisampleResolve`; the resolver averages logical sample colors
  before the destination format encode. This bounded profile supports 2D
  multisample depth/stencil attachments by maintaining independent ZPU depth
  and stencil planes for every sample. Parallel render encoders support ordered
  2x/4x CPU child passes with the same top-left sample positions and resolve
  semantics. Legacy, parallel, and Metal 4 render encoders also support 2x/4x
  MRT with independent CPU sample planes and per-attachment resolves. Sparse
  placement and direct CPU transfers remain rejected.
  2D multisample texture
  views are CPU-owned aliases of every sample plane, including same-size
  compatible color-format reinterpretations.
  Custom sample positions are accepted for
  1x/2x/4x passes after finite `[0, 1]` validation and are interpreted in
  Metal's top-left, pixel-local coordinates; other sample counts remain unsupported.
- buffer and texture resource options preserve the requested storage mode, CPU
  cache mode, hazard mode, texture usage, optimization flag, compression mode,
  and swizzle metadata; indirect command buffers preserve their resource
  options, and texture views inherit those properties from their ZPU-owned
  backing resource; CPU resources remain non-volatile, so
  `setPurgeableState:` returns the prior `MTLPurgeableStateNonVolatile` state
  without discarding ZPU storage
- `newBufferWithBytesNoCopy` aliases caller-owned CPU memory through the ZPU
  buffer while deferring the supplied deallocator until the adapter resource
  is released
- heap-backed buffers and textures with bounded allocation accounting; heap
  storage/cache mismatches are rejected, heap offsets are retained for
  resources, explicit aligned append placement is supported for heap buffers,
  and default heap hazard tracking is resolved as untracked, matching Metal's
  heap rules
- owned Depth16Unorm/Depth32Float and combined depth/stencil textures bound as
  render-pass depth attachments, with configurable Metal compare functions,
  write masks, explicit CPU pack/unpack, and depth clears
- owned Stencil8/X32_Stencil8/X24_Stencil8 and combined textures bound as
  render-pass stencil attachments, with
  front/back compare functions, fail/depth-fail/pass operations, read/write
  masks, references, and clear/load/store behavior
- depth-only render passes are accepted by the legacy, parallel, and Metal 4
  adapters; a private discarded CPU color surface preserves the portable
  raster ABI while public depth bytes remain exact
- up to eight R8/R16Unorm/R16Float/RG8/RG16Unorm/RG16Float/RGBA8/BGRA8/
  B5G6R5/A1BGR5/ABGR4/BGR5A1/RGB10A2/RG11B10Float/RGB9E5Float/BGR10A2Unorm/
  R32Float/RGBA16Unorm/RGBA16Float/RG32Float/RGBA32Float color attachments can be
  described and cleared by a CPU render pass; the explicit
  R8/R16/RG8/RG16/R32/RG32/RGBA8 Uint/Sint, RGB10A2Uint, and RGBA16 Uint/Sint
  attachments are available through their matching registered CPU fragment
  profiles;
  `zpu_test_mrt_fragment` profile mirrors one logical fragment color to every
  extra target, while ordinary single-output profiles leave extra targets at
  their load/clear value
- the bounded `zpu_test_sample_fragment` profile samples a ZPU-owned color
  texture with interpolated normalized or texel-space coordinates; nearest/
  linear minification and magnification filters selected from CPU-computed
  texture footprints, nearest/linear mip selection, LOD bias and clamps,
  sampler address modes, linear filtering, the three Metal border-color modes,
  and weighted/minimum/maximum reduction are carried through the CPU raster path;
  native Metal is used only as the byte-accuracy oracle where the native GPU
  exposes the requested feature
- the bounded `zpu_cpu_uniform_color_fragment` profile consumes a 16-byte
  `float4` from `setFragmentBytes:length:atIndex:0` and applies it through
  the CPU raster path; it also consumes a ZPU-owned 16-byte `float4` buffer
  binding at fragment index 0 with commit-time reads, so writes made before
  commit are visible; other fragment byte layouts remain unsupported
- bounded CPU anisotropic sampler footprints for normalized coordinates and
  linear min/mag filters, with the configured tap count capped for predictable
  CPU work; native Metal remains only the byte-accuracy oracle
- fixed-function render pipeline, depth-stencil, and sampler state objects;
  pipeline attachment format validation, blending factors/operations, color
  write masks, depth bounds, nil depth-stencil disabling, and Metal top-left
  triangle edge inclusion
- deprecated sparse-texture access-counter selectors validate sparse tile
  regions and write ordered zero counters through the CPU/ZPU blit stream; the
  CPU adapter has no GPU cache-miss stream, so zero is the explicit
  deterministic value
- Metal pixel-grid coordinates: texture row/column zero is the upper-left
  texel, `MTLViewport` and `MTLScissorRect` origins are applied in that same
  top-left space, and clip-space `+Y` maps toward decreasing row indices
  (`originY`); this is covered by an asymmetric non-zero-origin native-oracle
  test. This is the Metal texture coordinate space on both macOS and iOS; any
  AppKit/UIKit view-coordinate conversion belongs to the caller and is not
  silently applied by the CPU adapter
- render-pass attachment mip levels and single array/cube face slices select
  the corresponding ZPU texture and use that target's width/height for
  rasterization; multi-layer render passes and depth planes remain explicitly
  rejected
- buffer-backed texture views that alias storage with checked row strides and
  preserve the backing resource lifetime
- compatible pixel-format views for all supported color and integer formats
  with the same bytes-per-texel create
  view-owned ZPU handles over the same bytes, so CPU sampling, rendering, and
  transfers observe the view interpretation while the parent remains the
  storage owner; depth/stencil views remain same-format only, and 2D
  multisample views alias every sample plane
- CPU-owned `MTLTextureViewPool` slots that create/copy ZPU texture views or
  buffer-backed views and return synthetic resource IDs usable by MTL4
  argument tables
- ordered render, parallel-render, and blit encoders, command-buffer status,
  buffer copies/fills, texture transfers, indexed and indirect draws, render
  indirect command buffers (including CPU blit-copy of encoded commands),
  command-buffer `retainedReferences`/`errorOptions` metadata and explicit
  unretained-reference lifetime mode,
  process-local synthetic `gpuResourceID` values for CPU indirect command
  buffers and argument-buffer serialization of those identities,
  including CPU replay of fragment-buffer bindings and Metal 4 fixed-function
  indirect render state when the corresponding SDK/runtime selectors are used,
  descriptor inheritance and binding-count enforcement, indexed ICB ownership,
  index-type/alignment/range validation, and legal reset no-ops,
  texture views, level-aware mipmap generation/copies, ordered MTLFence
  update/wait commands, and CPU-owned visibility result buffers with aligned
  boolean/counting modes plus reset/accumulate behavior
- generic CPU blit synchronization accepts both ZPU buffers and textures;
  texture synchronization and CPU/GPU-access optimization retain the requested
  ZPU resource or valid mip/slice subresource without invoking native Metal
- compute-pass descriptors preserve the Metal serial/concurrent dispatch type
  on the CPU compute encoder; compute- and blit-pass descriptor sampling
  attachments schedule ZPU timestamp samples at encoder start/end while
  retaining the CPU-owned counter buffers; resource-state pass descriptors
  and acceleration-structure pass descriptors use the same CPU-owned start/end
  timestamp semantics
- render-pass descriptors schedule CPU timestamp samples for the configured
  vertex and fragment start/end boundaries while preserving the top-left
  ZPU raster grid
- identity rasterization-rate maps advertise capability consistently through
  `supportsRasterizationRateMapWithLayerCount:` and preserve native physical
  size/coordinate mappings; variable-rate maps remain rejected because the
  CPU renderer owns a fixed 1:1 pixel grid
- a deferred CPU compute encoder for the explicit
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8`,
  `ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE`, and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY` and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D`,
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT`, and
  `ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT`, and the bounded
  `ZPU_METAL_COMPUTE_TRACE_TRIANGLES_RGBA8` kernel; they operate directly
  on ZPU-owned buffers/textures and never invoke Apple's Metal runtime. Array
  dispatches expand the logical z grid into ordered per-slice ZPU commands;
  3D dispatches expand z into plane commands while preserving the z coordinate
  in the CPU kernel; indirect array/3D dispatches resolve the deferred z
  extent at commit and skip slices outside that extent. The triangle trace
  profile consumes a CPU-serialized legacy
  `MTLPrimitiveAccelerationStructureDescriptor` or Metal 4
  `MTL4PrimitiveAccelerationStructureDescriptor` containing Float3 triangle
  geometry, including Metal 4 GPU-address ranges, casts one orthographic
  primary ray per output texel, and writes exact RGBA8 hit/miss values on
  Metal's top-left grid; indexed UInt16/UInt32 geometry and explicit vertex
  strides are supported; legacy and Metal 4 primitive transformation matrix
  buffers support finite column-major and row-major CPU transforms. Supported
  refits re-read those current matrix and geometry bytes. Legacy
  default/UserID and Metal 4 indirect instance descriptors flatten already-built
  CPU triangle children with finite affine transforms, while motion instances,
  curves, custom intersection functions, and arbitrary ray tracing remain
  fail-closed
- CPU-owned Metal 4 command allocators, command buffers, command queues, and
  argument tables; Metal 4 compute dispatches bridge process-local argument
  table resource IDs to ZPU-owned resources and execute through the same
  deferred CPU kernels
- CPU-owned Metal 4 compiler metadata for the registered ZPU kernel set:
  MTL4LibraryFunctionDescriptor objects resolve through ZPU libraries,
  compiler-created compute pipeline descriptors instantiate the existing ZPU
  CPU kernels, binary functions expose deterministic name/type metadata, and
  compute pipeline binary linking accepts only same-device registered visible
  CPU functions while preserving the base ZPU kernel and exported handles;
  Metal 4 compiler and archive dynamic-linking descriptors accept the same
  registered visible binary functions and ZPU-owned dynamic libraries;
  fixed render pipelines also support CPU specialization of an unspecialized
  first-color blend state;
  asynchronous compiler tasks complete synchronously after CPU construction;
  dynamic libraries preserve registered symbol names and install names through
  a deterministic CPU serialization format; the registered
  `zpu_cpu_ml_identity` tensor pipeline executes through deferred CPU/ZPU
  copies, while arbitrary ML graphs and arbitrary-MSL compiler requests remain
  fail-closed; the registered `zpu_cpu_tile_gradient_rgba8` tile profile is
  also compiled as CPU metadata and dispatches ordered ZPU tile work with
  exact upper-left `(0,0)` coordinates and RGBA8/BGRA8 storage ordering; the
  registered `zpu_cpu_mesh_gradient_rgba8` plus
  `zpu_cpu_mesh_gradient_fragment` profile similarly dispatches one ordered
  CPU/ZPU pixel per mesh-grid thread; the registered
  `zpu_cpu_tessellated_triangle_vertex` plus
  `zpu_cpu_tessellated_triangle_fragment` profile accepts factor-one triangle
  patches and rasterizes their three control points through the ordinary
  top-left-origin ZPU triangle path
- CPU-owned Metal 4 pipeline-data serializers record those registered compute
  names and emit deterministic ZPU metadata scripts or the existing ZPU
  binary-archive format; these outputs are not Apple metal-tt scripts or
  native GPU binaries
- the registered `zpu_cpu_ml_identity` Metal 4 machine-learning profile also
  preserves CPU fence update/wait ordering through the deferred ZPU command
  buffer; arbitrary ML graphs remain fail-closed
- owner-checked CPU function handles expose registered compute and visible
  callable names/types plus synthetic CPU resource IDs; visible function-table
  invocation remains unsupported because the fixed CPU kernels do not execute
  arbitrary function-pointer shader code
- supported Apple-adapter render state and draw selectors propagate ZPU
  validation failures to `MTLCommandBufferStatusError`; invalid state is not
  silently reported as successful CPU work
- legacy and Metal 4 color attachment maps validate an eight-entry unique
  logical-to-physical permutation, preserve the physical attachment order,
  and route registered CPU fragment outputs without translating through native
  Metal. Non-identity maps require the render-pass opt-in; Metal 4 pipelines
  additionally require inherited mapping state, and deferred render ICBs must
  set `supportColorAttachmentMapping` before a non-identity map can be replayed.
  Missing or unrepresentable physical targets fail closed
- legacy and Metal 4 render pipeline callable linking accepts only same-device
  registered visible CPU functions for vertex and fragment stages; derived
  pipeline states retain the fixed ZPU raster profile and expose stage-scoped
  handles plus synthetic CPU resource IDs. The bounded registered tile and mesh
  profiles are executable through both legacy and Metal 4 encoders; tile/mesh
  binary linking and arbitrary tile/object/mesh functions remain fail-closed
- CPU-owned Metal 4 commit options and feedback; the explicit
  `ZPUMetalCreateCPUCommitOptions()` extension creates options whose feedback
  handlers receive host-time start/end values after the ZPU command buffers
  complete
- CPU-owned Metal 4 render encoders for ordinary render passes and the bounded
  registered tile and mesh profiles; they bridge MTL4 attachment descriptors,
  GPU-address argument tables, fixed-function raster state, indexed/indirect
  draws, fences, viewport/scissor state, tile dispatch, and mesh-grid dispatch
  to the existing ZPU
  encoders. The MTL4 path preserves the same upper-left pixel grid and
  clip-space +Y direction as the legacy adapter, including clipped edge tiles,
  and rejects GPU addresses and argument-table resources that are not owned by
  the ZPU device recording the command
- MTL4 argument-table application binds zero resource IDs as explicit nulls for
  CPU compute and render-stage state, so replacing a table cannot leak a prior
  texture, sampler, or buffer binding into the next dispatch or draw; bounded
  CPU compute profiles preserve texture-0 and texture-1 bindings independently
- matching registered legacy tile, object, and mesh stage resource setters
  validate and retain ZPU-owned buffers, textures, samplers, offsets, threadgroup
  metadata, and inline byte snapshots; these bindings are metadata for the
  fixed CPU profiles and do not route execution to native Metal. Ordinary
  pipelines and arbitrary stage profiles remain fail-closed
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
- legacy and Metal 4 mesh-threadgroup indirect grid arguments are read from
  the ZPU buffer at commit time; the CPU mesh profile multiplies the deferred
  threadgroup grid by the mesh threadgroup dimensions before clipping to the
  upper-left render target
- legacy triangle-patch draws accept half-precision, per-patch-and-per-instance
  tessellation factors and execute factor-one patches, including patch-index,
  control-point-index, and indirect argument buffers. All of those buffers are
  ZPU-owned and read at commit time; non-factor-one tessellation, quad patches,
  and arbitrary tessellation shader profiles fail closed
- compute `setBytes` bindings are copied into command-buffer-owned ZPU buffers
  and follow the same deferred lifetime rules
- CPU command buffers expose host-clock `GPUStartTime`/`GPUEndTime` around
  synchronous ZPU execution; `kernelStartTime`/`kernelEndTime` are exposed for
  command buffers that create a CPU compute encoder, and remain zero for
  render/blit-only buffers
- compute sampler/resource declarations, stage-in metadata, and memory
  barriers are accepted on the CPU encoder; barriers are ordered no-ops because
  the current ZPU command buffer executes serially, and registered kernels do
  not sample or consume stage-in/threadgroup metadata
- argument encoders retain ZPU resources, provide aligned CPU constant storage,
  and serialize supported buffer/texture/sampler/depth-stencil bindings into
  deterministic CPU-side 16-byte slots containing synthetic resource IDs and
  buffer offsets; rebinding captures direct constant writes, while arbitrary
  shader-specific Metal layouts are still not synthesized
- CPU-owned Metal 4 timestamp counter heaps; timestamps are monotonic values
  from the adapter's CPU clock domain, resolve into ZPU buffers, and support
  immediate CPU-range invalidation. `queryTimestampFrequency` reports
  nanoseconds for this CPU clock domain; no hardware GPU timestamp is exposed
- CPU-owned legacy timestamp counter sets/sample buffers; draw, dispatch, and
  blit sample points resolve to `MTLCounterResultTimestamp` records in shared
  ZPU buffers. Unsupported hardware-only counters remain unavailable rather
  than being reported as fabricated statistics
- CPU integer geometry for `sparseTileSizeWithTextureType:...`,
  `convertSparsePixelRegions:...`, and `convertSparseTileRegions:...`; supported
  color/depth formats and 1D/2D/3D texture types match the native tile oracle,
  while outward and inward alignment are overflow checked; placement sparse
  buffers and Tier 1 placement sparse textures provide CPU-owned page mapping,
  copied-page aliasing, legacy and Metal 4 map/unmap/copy operations,
  resource-state move operations, unmap-to-zero behavior, and exact mapped
  tile transfers. Sparse resources never allocate native Metal storage;
  unbacked texture reads return zero and unbacked writes are discarded. For
  1D/2D and array textures, lower mipmaps are CPU-packed into the native
  sparse-tail byte size; mapping the first tail level maps every tail level,
  and tail copy/move/unmap operations preserve the same CPU page-range model.
  3D tails also match the native first-tail and allocation-size contract for
  read-only and writable RGBA8 shapes across 16/64/256 KiB sparse pages,
  including depth-packed reservations; the opaque native physical byte layout
  is not exposed by Metal, so raw depth-packed backing-store equivalence
  remains an explicit oracle boundary
- CPU library metadata can discover the registered CPU kernel names and fixed
  CPU render profiles from source text, UTF-8 file/URL/data inputs, and the
  default bundle query; unsupported arbitrary MSL and stitched libraries fail
  closed
- CPU-created Metal 4 render pipelines retain a ZPU-owned specialization
  descriptor, so supported unspecialized blend state can be resolved through
  `newRenderPipelineDescriptorForSpecialization` and the CPU compiler path
- `newDefaultLibrary` returns the same CPU metadata library for the registered
  ZPU kernels, including the array, 3D, and bounded tile kernels; it does not load or compile an Apple
  `.metallib`
- CPU binary archives persist and reload deterministic metadata for registered
  ZPU compute/render functions; the Metal 4 archive view can reopen registered
  compute metadata; neither archive API serializes Apple GPU binaries
- CPU Metal I/O handles decode Apple `MTLIOCompressionContext` pack files for
  zlib, LZFSE, LZ4, LZMA, and LZBitmap through the system CPU compression API;
  load-bytes, buffer, and texture operations consume the decoded ZPU-owned
  bytes, with native Metal used only as the test oracle
- CPU resource-state encoders preserve Metal encoder boundaries and fence
  ordering. Resource/cache transitions are ordered no-ops over ZPU's unified
  CPU memory; legacy sparse texture map, batch, indirect, and move operations
  are deferred into the same ZPU command stream as following blit/compute work,
  while updating the same CPU-owned physical-page store as the Metal 4 queue
  operations
- CPU residency sets track ZPU allocations, committed byte totals, and
  request/end-residency state without introducing a GPU residency domain
- process-local shared-event handles round-trip the same ZPU event and
  preserve monotonic signaling; CPU waits honor zero, finite, and indefinite
  timeouts and wake when a later CPU or command-buffer signal reaches the
  requested value. Decoded or foreign handles fail closed because the CPU
  adapter does not invent a cross-process GPU primitive
- process-local shared-texture handles round-trip shareable ZPU textures and
  preserve their CPU bytes and metadata; IOSurface-backed and foreign handles
  use a retained CPU no-copy view when explicitly created through the
  IOSurface texture initializer; foreign handles remain unsupported rather
  than importing native storage
- CPU visible/intersection function tables retain ZPU-owned function handles,
  buffer bindings, opaque-intersection signatures, and visible-table links;
  they expose deterministic CPU resource metadata and IDs; valid table and
  acceleration-structure bindings on legacy compute encoders retain the same
  CPU resources and preserve command ordering, while arbitrary function-pointer
  dispatch and arbitrary ray tracing remain unsupported; the bounded triangle
  trace profile is the explicit fixed-function exception
- CPU acceleration-structure resources expose deterministic ZPU-backed storage,
  heap placement, resource IDs, and descriptor-derived size queries. Their CPU
  command encoder supports build, refit, copy, compact-size, and compaction
  metadata/storage operations; refit rebuilds supported CPU triangle and
  instance payloads from current ZPU-owned geometry; the fixed Float3 triangle
  trace profile traverses CPU-serialized legacy and Metal 4 primitive and
  bounded instance geometry, while arbitrary ray intersection execution
  remains fail-closed
- CPU render pipeline states resolve vertex/fragment function handles by
  owner, stage, and name, including Metal 4 binary-function metadata; foreign
  functions and unsupported stages fail closed. The Metal 4 device-level
  function-handle selector also returns handles for ZPU-owned CPU functions.
- compiler/archive-created fixed CPU pipelines expose deterministic modern
  binding reflection (and compatibility argument reflection) for their known
  buffer, texture, and sampler interfaces; ordinary device-created pipelines
  retain Metal's default `nil` `pipelineState.reflection` behavior while the
  legacy `options:reflection:` creation selectors return the same fixed CPU
  binding metadata
- registered CPU library functions expose matching binding reflection with a
  `nil` user annotation; unregistered functions and arbitrary specialized
  descriptors remain unsupported
- CPU indirect compute commands for those registered kernels; the command
  buffer inherits the ZPU encoder's texture bindings and records pipeline,
  buffer, and dispatch state for deferred execution, with device ownership,
  command-type, buffer-offset, dimension, and CPU threadgroup-limit checks.
  The fixed CPU kernel ABI has one representable kernel-buffer binding, so an
  ICB binding at any other index fails closed rather than being replayed at
  index zero.
  Indirect imageblock dimensions, stage-in regions, and kernel threadgroup
  memory bindings are retained through copy/reset and checked against the
  descriptor's bind limit; they are metadata-only for the registered ZPU
  kernels, whose CPU execution has no hidden threadgroup storage. Reset slots
  remain legal no-ops
- CPU indirect mesh command recording, copy, reset, and replay for the
  registered mesh-gradient profile; its thread dimensions, object/mesh buffer
  bindings, and object threadgroup-memory metadata remain in the CPU-owned ICB
  and are applied at replay, while arbitrary mesh shader execution fails closed
  at replay
- CPU indirect patch and indexed-patch command recording, copy, reset, and
  replay for the registered factor-one triangle profile; patch buffers,
  tessellation-factor buffers, offsets, strides, and draw ranges are retained
  in the CPU-owned ICB, while arbitrary tessellation shader execution fails
  closed at replay
- CPU indirect render commands preserve the same one-slot constraint as the
  CPU raster ABI for vertex and fragment buffers; descriptor capacity beyond
  slot zero is accepted as metadata, but recording a non-zero binding fails
  closed instead of silently rebinding it at slot zero
- Metal 4 buffer/texture/tensor copies, buffer-fill, indirect-command reset/copy,
  and CPU/GPU access optimization commands append or apply CPU-owned ZPU work;
  CPU-owned tensors also provide contiguous and strided byte-addressable slice
  transfers. Acceleration-structure build/refit/copy/compaction commands use
  the same CPU-owned storage path, and the bounded Float3 triangle trace
  profile executes from that storage. An explicit `ZPUMetalCreateCPUDrawable`
  factory wraps a ZPU texture in a CPU-owned `MTLDrawable`; ordinary command
  buffers defer presentation until synchronous CPU completion, deliver
  presented handlers, and expose host-time/monotonic-ID metadata. Metal 4
  drawable signal/wait validates the same ownership graph and remains a CPU
  no-op. Tensor shader binding, arbitrary ML graph execution, arbitrary
  ray-intersection execution, opaque native 3D sparse-tail backing layout, and arbitrary
  tile/mesh render-pass features remain explicit fail-closed
  boundaries. The registered tile and mesh profiles are the bounded
  exceptions. Suspending/resuming render
  passes are represented as sequential ordinary CPU passes because the CPU
  implementation has no tile-memory stitching requirement. The
  adapter never routes them to native Metal
- classic Metal resource, pipeline, blit, event, indirect-command, and
  command-buffer selectors that have no portable CPU meaning are represented
  explicitly: metadata-only operations are deterministic no-ops, while
  arbitrary shader compilation, unregistered or arbitrary binary linking, opaque
  native sparse-texture tail layouts, CAMetalLayer drawable acquisition, arbitrary ray tracing,
  tensor shader and arbitrary ML execution, and unsupported
  Metal 4 advanced families return nil or a stable error. They never fall through to Apple's
  native Metal runtime

The C header exposes both `zpu_metal_render`, an opt-in single-pass entry
point, and a resource/command-buffer API for C, C++, and Objective-C clients.
The latter owns A8/R8/R8Unorm_sRGB/R8Snorm/R16Unorm/R16Snorm/R16Float/RG8/RG8Unorm_sRGB/RG8Snorm/
RG16Unorm/RG16Snorm/RG16Float/R32Uint/R32Sint/
R8Uint/R8Sint/R16Uint/R16Sint/RG8Uint/RG8Sint/RG16Uint/RG16Sint/
RG32Uint/RG32Sint/RGBA8/BGRA8/RGBA8Unorm_sRGB/BGRA8Unorm_sRGB/RGBA8Snorm/RGBA8Uint/RGBA8Sint/
packed B5G6R5/A1BGR5/ABGR4/BGR5A1/RGB10A2/RG11B10/RGB9E5/BGR10A2/
  R32Float/RGBA16Unorm/RGBA16Snorm/RGBA16Float/RGBA16Uint/RGBA16Sint/RGBA32Uint/RGBA32Sint/RG32Float/RGBA32Float/
  Depth16Unorm/Depth32Float/Stencil8/Depth24Unorm_Stencil8/Depth32Float_Stencil8/
  X32_Stencil8/X24_Stencil8 buffers and textures, records
render/blit work, and executes it at command-buffer commit. Its render state
uses a fixed `zpu_metal_vertex` ABI; it does not parse MSL or execute arbitrary
shader functions. The optional Apple adapter supplies the supported
Metal-shaped Objective-C objects, while malformed resources are rejected with stable
negative error codes. The Apple adapter also delivers scheduled/completed
command-buffer handlers and explicit shared-event notifications for the
implemented synchronous runtime.

The portable ABI also exposes CPU-owned placement-sparse buffers. A sparse
buffer reports no public contents pointer; page-aligned map/unmap operations
are recorded on the resource-state encoder, and mapping copies preserve page
aliases. Ordinary ZPU blit/fill commands are the deterministic access path,
with unmapped reads returning zero. The bounded ABI covers sparse buffers and
single-level 2D sparse textures for the Apple page-size/tile geometries exposed
by the portable constructors. The single-region, legacy batch, and indirect
texture mapping entry points use sparse-tile coordinates and preserve the
caller's deferred order; move operations transfer pages only into unmapped
destination tiles, matching Metal's resource-state rule. Only mip level 0 and
slice 0 are representable in this portable profile. Arbitrary sparse texture
mip/tail/3D layouts are still outside this ABI; the Apple adapter's
Objective-C resource-state implementation additionally covers its documented
CPU page model for those layouts.

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
  legacy/Metal 4 3D mipmap generation, cube/cube-array face and view transfers,
  packed normalized 2D/3D mipmap raw-byte exactness, 2D float mipmap raw-byte exactness, and
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
implemented here, arbitrary Metal 4 tile/mesh render and remaining copy/optimization families. The registered RGBA8 tile and mesh profiles are CPU/ZPU-owned
through legacy and Metal 4 pipeline creation, binary archives, and the Metal 4
pipeline-data serializer; the registered factor-one triangle-patch profile is
CPU/ZPU-owned through the legacy render encoder and ICB path. Arbitrary
tile/mesh/tessellation functions remain unsupported. ICB arbitrary mesh/tessellation-shader execution, other
synchronization families, arbitrary ray-tracing execution beyond the bounded triangle and
legacy/Metal 4 instance profiles, opaque native 3D sparse-texture tail
backing layout, arbitrary machine-learning/tensor execution, and arbitrary shader compilation. Function-table storage is
implemented, but it does not imply ray-tracing or arbitrary function-pointer
execution. A strict completeness claim belongs only after the Apple SDK
inventory and macOS/iOS behavior tests pass.

The SDK inventory on the current Xcode 26.6 host contains 96 headers, 253
Metal-named types, 446 Objective-C selectors, and 11 C functions. Those counts
are useful review gates; they are not implementation coverage. ZPU cannot
replace Apple's system `MTLCreateSystemDefaultDevice` from an ordinary app, so
the supported integration is explicit selection of this portable ABI.

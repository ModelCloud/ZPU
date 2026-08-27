# Vulkan 1.4.360 driver implementation plan

This plan is limited to the ZPU Vulkan ICD. Window managers, fonts, toolkit
rendering, native APIs, and unrelated VM integration are outside its scope.

The normative inputs are the pinned Khronos Vulkan-Headers `v1.4.360`
`vk.xml`, the Vulkan 1.4.360 specification, and `VP_KHR_roadmap_2026`; see
`api/registry/README.md`. Runtime version reporting stays at Vulkan 1.0 until
all gates in `docs/api-policy.md` pass. Landing a command name is not enough:
its object lifetime, valid execution behavior, synchronization, failure
atomicity, feature/limit reporting, and required formats must all work before
the command is marked complete.

## Baseline gap

The pinned cumulative core contains 234 commands, 603 types, and 390 enums.
The current dispatch tables expose all 234 core command names, including the
97 commands introduced by Vulkan 1.1 through 1.4. Some commands are still
intentionally narrow, capability-gated, or opaque placeholders, so name
coverage is only a lower-bound inventory, not a conformance percentage.

## Current checkpoint

The implementation now dispatches and tests all 234 cumulative core command
entry points. The completed slices include timeline semaphores, compute
pipeline records and dispatch envelopes, render-pass2, copy-commands2,
synchronization2, dynamic rendering, queue-submit2, private data,
memory-requirement/address queries, device-group peer queries, host image
copies/layouts, including the Vulkan 1.4 `VK_HOST_IMAGE_COPY_MEMCPY_BIT`
full-image/zero-offset contract and host transition old/new layout domains,
descriptor templates, push descriptors, and the
supported/unsupported YCbCr policy. Maintenance-6 rendering attachment
locations and input-attachment indices now have command-buffer-owned state,
inside-render-pass validation, atomic rollback, reset/begin lifecycle reset,
and allocation-free warm-path coverage. Line stipple state now likewise owns
the Vulkan default and accepts the complete 16-bit pattern domain while
keeping factor validation bounded. Render-pass recording now also exercises a
real two-subpass path: each subpass has its own compatible CPU-cube pipeline,
`vkCmdNextSubpass` resets bindings, draw validation keys off the active
subpass, and malformed extra transitions fail atomically; the warm path is
allocation-free. The `vkCmdNextSubpass` bound check runs before reading the
fixed eight-entry subpass-layout table, so advancing beyond the advertised
maximum is a failure-atomic, allocation-free invalidation rather than an
out-of-bounds access. Ending a traditional render pass before its final
subpass is likewise rejected without recording or closing the active scope.
`VK_EXT_present_timing` now retains a bounded per-swapchain FIFO when its
timing queue is enabled: each completed present receives a stable process-local
ID, requested stage timestamps, and completion metadata through
`vkGetPastPresentationTimingEXT`; an optional `VkPresentId2KHR` chain is
retained when provided, with monotonic per-swapchain IDs otherwise. Count/
incomplete behavior, queue-full backpressure, and the allocation-free warm
path are covered by direct tests.
Compute command recording now requires an owned bound compute
pipeline, carries pipeline/layout/descriptor lifetime snapshots through
submission prevalidation, and has a 4096-iteration allocation-free warm path.
Pipeline creation also accepts the promoted Vulkan 1.4
`VkPipelineCreateFlags2CreateInfo` pNext ABI: zero flags are accepted for
both graphics and compute pipelines, and the compute dispatch-base bit is
honored through the same canonical, failure-atomic path as the legacy flag;
unsupported or high flag bits leave outputs and registries unchanged.
The promoted `VkPipelineRobustnessCreateInfo` ABI is accepted on graphics and
compute pipeline and shader-stage chains when all behavior fields request the
device-default policy; non-default robustness values, duplicate nodes, and
unknown chain entries remain transactional rejections because the optional
robustness feature is not advertised.

The promoted `VkPhysicalDeviceMaintenance5Properties`,
`VkPhysicalDeviceMaintenance6Properties`, and
`VkPhysicalDevicePipelineRobustnessProperties` query nodes now use typed LP64
field layouts (including the 12-byte Maintenance 6 payload) and return the
truthful all-zero optional-capability/device-default policy. Duplicate or
unknown property nodes leave the complete `vkGetPhysicalDeviceProperties2`
output untouched.

The promoted vertex-attribute-divisor feature and property nodes now use the
registry sTypes (`1000191002` and `1000526000`) and typed two-field bodies;
feature queries report both controls disabled, while property queries report
the bounded divisor policy and reject the former incorrect sType.
The promoted line-rasterization feature and property nodes now expose typed
LP64 fields (all six feature controls remain `VK_FALSE`; the property reports
`lineSubPixelPrecisionBits = 4`) instead of opaque payloads, with the KHR/EXT
aliases sharing the same layouts.
The promoted subgroup-size-control feature and property nodes likewise expose
typed LP64 fields; all controls and limits remain zero because subgroup-size
control is outside the advertised execution profile.
The promoted texel-buffer-alignment property node now exposes its four typed
alignment fields (256-byte storage/uniform alignment and single-texel flags
false) with the EXT alias sharing the same LP64 layout.
The remaining small promoted physical-property nodes (protected memory,
subgroup, multiview, point clipping, maintenance 3/4, timeline semaphore,
sampler filter min/max, depth/stencil resolve, inline uniform block, and push
descriptor) now likewise expose named typed fields and are populated through
the same bounded, allocation-free query path.

Graphics pipeline vertex-input chains accept the feature-disabled,
zero-entry `VkPipelineVertexInputDivisorStateCreateInfo` form with bounded,
allocation-free validation; nonzero divisor entries and duplicate/unknown
nodes remain transactional rejections.
Graphics pipeline rasterization chains also accept the typed
`VkPipelineRasterizationLineStateCreateInfo` ABI in its feature-disabled
default form (default mode, stippling disabled, factor one, and zero pattern)
with bounded, allocation-free validation; non-default line modes, stippling,
and duplicate/unknown nodes remain transactional rejections.
Graphics pipeline creation now also consumes the Vulkan 1.3
`VkPipelineRenderingCreateInfo` pNext for `renderPass = VK_NULL_HANDLE`:
the bounded dynamic-rendering profile records one BGRA8 color format and
optional D32 depth format in its canonical compatibility key. Direct,
indexed, and indirect draws validate those formats against the active
dynamic-rendering attachments before recording, while secondary command
buffers validate against their inherited rendering formats before execution.
Color-only dynamic scopes now carry the optional-depth contract through
submission prevalidation and both scalar raster paths, skipping depth storage
without allocating a synthetic attachment.
Dynamic-rendering begin also enforces the advertised 256-layer device limit
for attachmentless scopes and bounds their render areas to the same 8192x8192
framebuffer envelope used by image creation and device limits; malformed
values fail before command state or recording mutation. The secondary-command
contents bit is accepted and carried into the primary scope so direct draws
are rejected while inherited secondary execution remains legal; suspend and
resume scopes remain intentionally rejected.
The bounded compute profile now also admits direct scalar StorageBuffer
`OpLoad` reads (including read/write aliasing of the descriptor range) with
transactional output commits; static access-chain reads share the same
validated interface path. Constant-folded scalar integer comparisons and nested
boolean logical expressions, signed integer negation, component-wise integer
multiply, bitwise operations, bounded integer bit reversal and population count,
bit-field insertion and signed/unsigned extraction, integer division/remainder,
dynamic vector component extraction/insertion, integer division/remainder, and
static vector composite insertion, raw numeric bitcasts preserving payload bits,
and exact `OpCopyObject` value copies,
and bounded `OpQuantizeToF16` f32 precision rounding with normalized-f16
subnormal flush-to-signed-zero semantics, plus scalar extended integer
carry/borrow and high-word arithmetic with pair extraction,
exact 32-bit `OpSConvert`, `OpUConvert`, and `OpFConvert` type conversions,
integer division/remainder, and bounded
integer shifts, floating remainder/modulo
with truncating/flooring quotient, component-wise scalar/vector integer
comparisons, ordered/unordered scalar/vector floating-point comparisons with NaN
semantics, and component-wise scalar/vector boolean logical operations, scalar-or-
vector `OpSelect`, bounded f32 4x4 column-major matrix/vector arithmetic
(`OpMatrixTimesScalar`, `OpVectorTimesMatrix`, `OpMatrixTimesMatrix`,
`OpTranspose`, `OpOuterProduct`, and `OpDot`), plus
bounded floating classification/reduction (`OpIsNan`, `OpIsInf`, `OpIsFinite`,
`OpIsNormal`, `OpSignBitSet`, `OpLessOrGreater`, `OpOrdered`, `OpUnordered`,
`OpAny`, and `OpAll`), plus
statically resolved, acyclic `OpBranch`,
`OpBranchConditional`, and constant-selector `OpSwitch` paths now prune
unselected blocks before lowering, while dynamic conditions, loops, dynamic
indexing, atomics, shared memory, and complete memory-visibility semantics
remain deferred.
The `vkGetPhysicalDeviceFeatures2` query also accepts promoted Vulkan
1.1/1.2/1.3/1.4 feature-chain structures, preserving caller-owned links and
writing the truthful all-false feature payloads instead of rejecting every
non-null `pNext`. It also accepts the individual core-promoted feature
structures (16-bit storage, descriptor indexing, line rasterization, and the
other 1.1–1.4 feature forms) with exact LP64-sized VkBool32 payloads; unknown
feature chains remain transactional rejections.
The base `VkPhysicalDeviceFeatures` payload is likewise represented by all 55
registry field names (rather than an opaque word array), with the same 220-byte
LP64 layout and allocation-free all-false query behavior.
Core entry points that consume barrier, viewport/scissor, sampler, pipeline,
descriptor-update, and sparse-query arrays now use their concrete ABI pointer
types internally as well (including counted viewport/scissor and pipeline
create arrays), while retaining the same bounded validation and failure-atomic
behavior.
The Vulkan 1.1 individual storage, variable-pointer, sampler-YCbCr,
multiview, protected-memory, and shader-draw-parameter nodes expose their
registry field names directly, preserving the same all-false and failure-
atomic query behavior.
The remaining promoted individual feature nodes for Vulkan 1.2–1.4 now do the
same (memory model, address, storage-width, synchronization, rendering,
maintenance, host-copy, robustness, and related controls), so callers no
longer need to address synthetic `values[]` fields for the core feature ABI.
The Vulkan 1.1 aggregate body is represented by named fields for 16-bit
storage, multiview, variable pointers, protected memory, YCbCr conversion,
and shader draw parameters. The Vulkan 1.2 aggregate body is represented by
named fields for promoted descriptor-indexing, storage, memory-model,
timeline-semaphore, and buffer-address features. The Vulkan 1.3 aggregate body is represented by
named fields for robust image access, inline uniform blocks, private data,
dynamic rendering, synchronization2, subgroup controls, and maintenance.
The Vulkan 1.4 aggregate body is now represented by named fields for global
priority query, subgroup rotation, line rasterization, divisor, index-type
uint8, dynamic-rendering local-read, maintenance, robustness, host-image-copy,
and push-descriptor features; its all-false query remains allocation-free.
`vkGetPhysicalDeviceProperties2` now accepts aggregate and individual
promoted property chains with exact LP64-sized payloads and the same
transactional unknown-chain rejection. Aggregate Vulkan 1.1/1.2/1.3/1.4
nodes now populate their typed identity and bounded-limit fields (UUIDs,
driver strings/class, multiview and descriptor limits, heap-backed
allocation/buffer limits, texel alignment, line precision, vertex-divisor
policy, and stable layout UUIDs) instead of leaving the entire promoted
payload opaque. The individual forms likewise populate the supported limit
fields, retain caller links, and zero unsupported capability fields; the
FloatControls, DescriptorIndexing, ShaderIntegerDotProduct, and HostImageCopy
forms now expose every registry field with exact LP64 offsets (including the
trailing alignment padding) rather than synthetic byte arrays. Identity nodes
additionally report the single-device node mask and an explicit zero
conformance version so diagnostics are useful without overstating conformance.
`vkGetPhysicalDeviceImageFormatProperties2` also accepts the promoted
external-image input and external-image/YCbCr output chains, reports the
truthful no-external-handle/no-YCbCr policy, and rejects unknown chains without
mutating the base result.  The external-buffer query now uses its correct
promoted sTypes rather than the adjacent image-query values.
The Vulkan 1.1 external-buffer, external-fence, and external-semaphore
capability queries now validate reserved flags, usage domains, handle-type
bits, ownership, and output chains before publishing their explicit zero
capability result. Malformed inputs leave every output field untouched, and a
4096-iteration warm path covers the allocation-free query behavior.
The same query now handles core image-format-list and separate-stencil input
chains and the Vulkan 1.4 host-image-copy performance output, reporting the
CPU-local layout policy without mutating results on rejected chains.
`vkGetImageMemoryRequirements2` accepts the promoted image-plane requirements
input for ZPU's non-disjoint images and rejects nonzero plane aspects without
mutating requirements.
Image creation and device-image requirement queries accept the core
image-format-list and separate-stencil create-info chains with bounded format
lists, preserving the same failure-atomic policy.
Memory allocation and buffer creation now accept the core dedicated-allocation,
allocation-flags, external-memory, and opaque-capture pNext forms when their
requested capabilities match ZPU's single-device/no-external-handle policy;
unsupported handles remain failure-atomic.
Buffer creation and device-buffer requirement queries also consume the Vulkan
1.4 `VkBufferUsageFlags2CreateInfo` chain. Its 64-bit usage value overrides the
legacy field only for the supported low-bit usage policy; high bits, duplicate
nodes, and unknown nodes fail before publication, and the valid path has a
4096-call allocation-free requirement-query warm test.
Fence and semaphore creation now consume the promoted zero-handle
`VkExportFenceCreateInfo` and `VkExportSemaphoreCreateInfo` nodes. Timeline and
export semaphore nodes may be chained in either order; real external-handle
requests and malformed/duplicate chains remain transactional rejections.
Image-view creation now consumes the promoted `VkImageViewUsageCreateInfo`
node, retains the restricted usage mask on the view, and applies it to sampled
and framebuffer attachment validation.
`vkGetPhysicalDeviceFormatProperties2` also accepts `VkFormatProperties3` and
mirrors the validated format feature masks into its 64-bit fields.
The `VkMemoryRequirements2` family now accepts the core
`VkMemoryDedicatedRequirements` output chain on buffer, image, and device
memory-requirement queries. Its ABI is checked explicitly, the shared-host
memory policy reports both dedicated-allocation booleans as false, caller
links are preserved, unknown chains remain failure-atomic, and the valid
warm path is allocation-free.
`vkCreateDevice` now validates the loader chain followed by
`VkPhysicalDeviceFeatures2` or individual core-promoted 1.1–1.4 feature
structures. Enabled optional bits return `VK_ERROR_FEATURE_NOT_PRESENT`, while
the all-false feature chain is accepted without publishing partial device
state.
Promoted device-group ABI chains are now validated in their single-device
form: `VkDeviceGroupDeviceCreateInfo`, `VkDeviceGroupSubmitInfo`,
`VkProtectedSubmitInfo`, `VkBindBufferMemoryDeviceGroupInfo`,
`VkBindImageMemoryDeviceGroupInfo`, `VkBindImagePlaneMemoryInfo`,
`VkDeviceGroupCommandBufferBeginInfo`, and
`VkDeviceGroupRenderPassBeginInfo`. Nonzero masks, indices, protected submits,
split-instance regions, and mismatched physical members fail transactionally;
the valid chains are covered by LP64 size assertions and 4096-iteration
allocation-free warm-path tests.
The Vulkan 1.4 `VkBindMemoryStatus` pNext node is also accepted by both
`vkBindBufferMemory2` and `vkBindImageMemory2`. Its non-null result pointer is
validated with the rest of the batch, and each per-bind result is written only
after every bind in the batch has passed validation and been committed.
Descriptor-set layout support and allocation now also consume the promoted
descriptor-indexing pNext ABI: zero-valued
`VkDescriptorSetLayoutBindingFlagsCreateInfo`,
`VkDescriptorSetVariableDescriptorCountAllocateInfo`, and
`VkDescriptorSetVariableDescriptorCountLayoutSupport` chains are accepted,
while nonzero flags/counts fail atomically because those optional features are
not advertised.
The Vulkan 1.2 render-pass2 wrapper now accepts the ABI-exact zero-valued
`VkRenderPassMultiviewCreateInfo` and
`VkRenderPassInputAttachmentAspectCreateInfo` top-level chains; nonzero view
masks, offsets, or aspect references remain transactional rejections under
the single-subpass ZPU profile. Attachment and subpass descriptions now also
accept the ABI-exact zero-valued `VkAttachmentDescriptionStencilLayout` and
`VkSubpassDescriptionDepthStencilResolve` nested chains, while nonzero stencil
layouts, resolve modes, attachments, unknown nodes, and duplicate nodes fail
before the canonical render-pass object is published. The nested validators
have a 4096-iteration allocation-free warm path.
Queue-family-properties2 now preserves and populates the promoted
`VkQueueFamilyGlobalPriorityProperties` output chain, reporting the ordinary
medium priority (`VK_QUEUE_GLOBAL_PRIORITY_MEDIUM`) for the single ZPU queue;
the full 16-entry `VK_MAX_GLOBAL_PRIORITY_SIZE` array is retained for the
exact LP64 output ABI, with unused entries zeroed;
invalid counts leave the caller’s chain untouched.
Logical-device queue creation accepts the promoted
`VkDeviceQueueGlobalPriorityCreateInfo` chain for the ordinary medium queue
priority and rejects other priorities before publishing device state.
The sampler-YCbCr conversion create record is also ABI-exact: its core body
ends at `forceExplicitReconstruction`; Android `externalFormat`, when used,
belongs to a separate pNext extension and is not folded into the core struct.
The first execution slice now compiles and runs a bounded straight-line
SPIR-V compute profiles that either store a constant `u32`, load one
statically indexed uniform-block `u32`, or choose scalar values with a boolean
select, then apply scalar arithmetic before writing through a
`VK_DESCRIPTOR_TYPE_STORAGE_BUFFER`;
invocation multiplication is bounded, uniform/storage ranges are validated at
record and submit time, and the output is written synchronously. One bounded,
side-effect-free runtime conditional or one-case runtime `OpSwitch` with a
two-arm `OpPhi` merge is lowered to SSA compare/select; generic SPIR-V compute
control flow, dynamic loads, atomics,
shared memory, and general arbitrary graphics execution remain explicitly
deferred. A final dynamic vector component in an access chain is now lowered
with runtime bounds checks; dynamic structure, matrix, aggregate, and
descriptor-array indexing remain deferred. A bounded scalar graphics profile
now executes f32x4 vertex-input
triangles with builtin-position output, perspective-correct f32x4 fragment
varyings, bool/f32x4 fragment output, and descriptor-backed set-0 binding-0
uniform blocks for direct, indexed, and bounded multi-draw indirect commands;
indirect profile bindings are snapshotted at record time and their post-record
argument ranges are revalidated at submit. The scalar profile now applies the
static RGBA color-write mask in logical channel order to its BGRA8 attachment;
bounded source/destination color and alpha blend factors, equations, and finite
blend constants are applied before the masked write; the legacy CPU-cube bridge
remains fail-closed for partial masks or enabled blending.
The unrestricted SPIR-V graphics space is still intentionally deferred.
Because `drawIndirectFirstInstance` remains disabled in the truthful feature
policy, all positive indexed and non-indexed indirect argument records now
validate `firstInstance == 0` at submission, including every record in the
bounded four-draw indirect-count variants; commands whose Vulkan valid usage
permits an empty range remain no-ops, while required-positive descriptor bind
and push-update counts are rejected.
Positive indirect draws also enforce the Vulkan command-structure stride
minimum (16 bytes non-indexed, 20 bytes indexed) and four-byte alignment;
short or zero strides fail before recording without mutating command state.
The `multiDrawIndirect` feature is now advertised and accepted at device
creation, with `maxDrawIndirectCount = 4`; every post-record argument and
indexed range is prevalidated before the first draw executes.
Direct indexed draws use checked first-index and bound-offset arithmetic, so
overflow invalidates the command buffer before publishing a draw record.
Indirect dispatch now retains its argument buffer and consumes the three group
counts at submission, including post-record writes and failure-atomic invalid
group rejection.
Dynamic rendering now records finite
`loadOp=CLEAR` attachment values for submission, validates clear domains, and
accepts bounded nonzero `layerCount` values against array-view layer ranges;
layered clears and framebuffer-free indexed CPU-cube draws execute each
selected layer, while rejecting command-buffer completion while a rendering
scope remains open. Color attachments are optional for depth-only/no-target
scopes; depth clears and attachment clears remain executable while color draws
are rejected without a color target. Dynamic pipeline declarations may also
set `colorAttachmentCount` to zero for rasterizer-discard or depth-only bounded
draws; discard draws remain a validated no-op while depth-only draws update
the D32 attachment without a color target. In both cases pipeline, descriptor,
depth, index, and indirect resources are checked for ownership/liveness.
Attachment layouts are snapshotted when dynamic commands
are recorded (including transitions earlier in the same command buffer) and
checked again at submit, so a post-record host layout change fails atomically
instead of executing against stale state. The promoted
`VK_ATTACHMENT_LOAD_OP_NONE` and `VK_ATTACHMENT_STORE_OP_NONE` values are
accepted for dynamic attachments; DONT_CARE and load-none record a
submission-time content discard at begin, while DONT_CARE and store-none record
another discard at the end of the rendering scope. Secondary command buffers can now carry the bounded
`VkCommandBufferInheritanceRenderingInfo` chain, including zero-color
depth-only inheritance; execution validates the inherited color/depth formats
and sample count against the active primary scope, requires
`VK_RENDERING_CONTENTS_SECONDARY_COMMAND_BUFFERS_BIT` on dynamic-rendering
primaries, and then binds the primary's live attachment images into the copied
draw records. `vkCmdClearAttachments` in a secondary follows the same
deferred-binding path when inheritance omits a framebuffer: the clear value and
bounded rectangle are recorded without allocation, then the primary's live
color/depth image, layer range, extent, and layout are resolved atomically by
`vkCmdExecuteCommands`. Malformed chains, mismatched scopes, unresolved
attachment targets, inline dynamic-rendering secondary execution, and
non-inherited active-query secondary execution remain failure-atomic. Traditional
render-pass secondaries also accept
`occlusionQueryEnable = VK_TRUE` with the active primary query inherited;
`VK_QUERY_CONTROL_PRECISE_BIT` remains rejected while the precise-query
feature is disabled. Device
limits now also match the bounded
execution profile: one sample, four indirect draws per command, and four color
attachments;
vertex-input binding/attribute stride, location, and offset bounds are checked
against the same reported limits; viewport/scissor setters also reject
non-finite or oversized domains, and oversized requests reject atomically.
Maintenance-4 vertex/index binding commands now retain their explicit range
and stride arguments: `vkCmdBindIndexBuffer2` resolves `VK_WHOLE_SIZE` and
rejects ranges outside the bound buffer, while `vkCmdBindVertexBuffers2`
records per-binding sizes and strides and rejects ranges or strides outside
the reported limits. The legacy binding commands retain the corresponding
buffer-to-end ranges.
`VK_DYNAMIC_STATE_VERTEX_INPUT_BINDING_STRIDE` is now decoded as a per-binding
draw requirement. A pipeline records the bindings used by its vertex
attributes; each such binding must receive a non-NULL `pStrides` update through
`vkCmdBindVertexBuffers2` before a draw, and the profile executor uses the
supplied stride bit-for-bit, including an explicit zero, rather than falling
back to the pipeline's static stride. The stride initialization mask and
values are copied into direct, indexed, and indirect draw snapshots, with
missing-state rejection and allocation-free warm coverage.
The Vulkan 1.3 extended dynamic-state values for cull mode and front face are
now decoded when graphics pipelines are created. A pipeline that declares
either state requires the matching command-buffer value before a draw can be
recorded; snapshots carry the resolved state into direct and indirect CPU
raster execution, while pipelines that do not declare the state continue to
use their baked values. Missing-state and 4096-call resolution coverage is
failure-atomic and allocation-free.
Primitive-topology and primitive-restart dynamic states now follow the same
pipeline-owned requirement and snapshot path. The bounded executor accepts
only the triangle-list/no-restart combination it can execute; missing state,
non-triangle topology, and enabled restart are rejected before command
recording rather than being silently rendered with different semantics.
The promoted viewport-with-count and scissor-with-count dynamic enum values
are also decoded as aliases of the one-viewport/one-scissor count-aware
commands, so their pipeline declarations enforce the same initialized state
and bounded domain checks.
Rasterizer-discard dynamic state is now decoded and snapshotted for direct and
indirect draws. A set discard value suppresses CPU raster work at submission,
while an unset value rejects recording when the pipeline declares the dynamic
state; static discard is retained in the pipeline identity and follows the
same no-raster execution path.
Promoted `VK_DYNAMIC_STATE_LINE_STIPPLE` is decoded as a pipeline-owned
requirement. `vkCmdSetLineStipple` validates factor range, tracks lifecycle
initialization, and resolves factor/pattern into direct and indirect draw
snapshots; the bounded triangle-list executor retains this state but does not
claim line-rasterization behavior.
Depth-test enable, depth-write enable, and depth-compare-op dynamic values are
also decoded and required before recording. The scalar graphics profile applies
the Vulkan NEVER/LESS/EQUAL/LESS_OR_EQUAL/GREATER/NOT_EQUAL/GREATER_OR_EQUAL/
ALWAYS comparisons and independently controls depth writes; the legacy
CPU-cube path rejects non-default depth modes rather than silently changing its
fixed depth behavior.
Core `VK_DYNAMIC_STATE_DEPTH_BOUNDS` is now decoded as an initialized draw
requirement. Ordered finite bounds are snapshotted into direct and indirect
draws, the scalar profile applies the inclusive Vulkan depth-bounds test, and
the legacy CPU-cube path rejects non-default bounds instead of silently
ignoring them.
The promoted depth-bounds-test-enable state is likewise initialized, resolved,
and snapshotted for direct and indirect draws, so a dynamic pipeline cannot
silently fall back to its static enable value.
The promoted stencil-test-enable state follows the same initialized snapshot
contract; because the advertised attachment policy is D32-only, an enabled
resolved stencil test rejects the draw rather than silently dropping stencil
semantics.
The promoted depth-bias-enable state is initialized and resolved in the same
draw snapshot. The bounded scalar CPU raster profile now applies finite
constant-factor and slope-factor bias in post-projection depth space, clamps
the result to the requested finite depth-bias clamp, and carries the exact
state through direct, indexed, and indirect draws. The legacy CPU-cube path
continues to reject enabled depth bias rather than silently changing its fixed
depth behavior.
Core dynamic line width, depth-bias values, blend constants, and stencil
compare/write/reference masks are now decoded into pipeline-owned requirements.
The command buffer must initialize each declared value before a direct, indexed,
or indirect draw can be recorded; the bounded backend keeps its truthful policy
(line width 1, zero depth-bias clamp, and no stencil attachment) while rejecting
missing or unsupported state rather than silently substituting baked values.
Query commands now enforce Vulkan render-scope rules: occlusion begin/end
must be inside a traditional or dynamic render-pass instance, while timestamp
writes must be outside one. The existing reset-history, availability,
submission-lifetime, exact result, rollback, and allocation-free warm paths
remain covered. Ending either rendering form while an occlusion query is
active is now rejected atomically; the active query and render scope remain
open until the application records `vkCmdEndQuery`. `vkCmdNextSubpass` applies
the same nesting rule and leaves the current subpass unchanged on rejection.
Swapchain acquisition and presentation now validate synchronization ownership
and type before mutating image state: acquire accepts only same-device binary
semaphores and unsignaled fences, while present rejects foreign or timeline
wait semaphores and duplicate wait entries. Rejected synchronization leaves
the acquired image and semaphore state unchanged, with a 4096-call warm
rejection path covered.
Swapchain replacement now honors a valid same-device, same-surface
`oldSwapchain`: the replacement is published before the old object is retired,
so allocation or registry failures leave the old swapchain usable. Retired
swapchains remain destroyable but reject new image acquisition and presentation,
with lifecycle coverage in the presentation fixture.
The memory and sampler handle registries now meet the required 4096 and 4000
allocation limits respectively. The generated command matrix is a
234/234 dispatch/name-coverage artifact, not a Vulkan-conformance claim:
several commands intentionally expose only the narrow behavior behind the
currently advertised Vulkan 1.0 profile. Runtime version reporting remains at
Vulkan 1.0 until the broader feature, CTS, and performance gates below pass.
The two promoted instance capability names required by Chromium's headless
bootstrap, `VK_KHR_external_memory_capabilities` and
`VK_KHR_external_semaphore_capabilities`, are now enumerated and accepted;
their KHR physical-device query aliases resolve to the same zero-capability
core implementations, without adding external-handle support.
`VK_EXT_headless_surface` is now also enumerated and accepted. Its exact
create-info ABI produces a CPU-backed offscreen surface; swapchains created
from it use the shared lifecycle/timing path with a no-XCB transport, so
headless presentation is usable without an X11 connection. The independent
`zig build headless-present` C client exercises that extension through the
system Vulkan loader and verifies the no-XCB acquire/present lifecycle.
The single queue family now reports graphics, compute, and transfer capability,
matching the bounded compute pipeline and dispatch commands that can be
submitted through it; queue count, timestamp, and granularity limits are
unchanged.
Bounded 2D array images are now backed by per-layer memory (up to 256 layers),
with matching image-format limits, requirements, subresource-layout offsets,
2D-array views, host copies, clear ranges, attachment clears, buffer/image
copies, image copies, and blit/resolve layer selection. Core buffer/image copies, image copies,
blits, and resolves now execute matching multi-layer regions, with checked
per-layer buffer strides honoring row length and image height. Image copies
reject mismatched formats before recording, while blit and resolve accept the
advertised RGBA8 UNORM and BGRA8 UNORM transfer formats. Invalid layer ranges
fail before recording, and the array path has a positive
isolation/rollback test plus an allocation-free warm path. Swapchain images
remain explicitly single-layer because the surface capability reports one
layer.
Traditional render-pass begin/end now honor the canonical attachment load
operation and image-layout contract for color-only, color+depth, and depth-only
D32 subpasses: LOAD preserves existing pixels, CLEAR requires only the
attachment-indexed clear values it consumes, UNDEFINED captures the tracked
prior layout as a discard transition, DONT_CARE and promoted LOAD_OP_NONE record
an explicit begin-time content discard after any initial-layout transition, and
begin/end record the subpass, each
declared inter-subpass, and final layout transitions for submission-time
validation. Depth-only framebuffers bind a single depth view and use the same
draw/clear lifecycle without fabricating a color target. Legal zero-attachment
subpasses are also supported for rasterizer-discard render-pass instances;
their framebuffer extent supplies render-area bounds, begin/end record no
image work, and multi-subpass advancement remains a bounded NEXT_SUBPASS
envelope. Failure-atomic positive/negative, two-subpass, depth-clear,
attachmentless, and 4096-iteration allocation-free tests cover the paths. Clear and draw commands also snapshot the active
subpass layouts, rejecting host-side layout changes after recording and
propagating those expectations into secondary command-buffer execution. The
promoted LOAD_OP_NONE/STORE_OP_NONE enum values are accepted as well;
load-none records a bounded content discard at begin, while DONT_CARE and
store-none record a bounded content discard at end-of-pass; both retain bytes
until submission.

The Vulkan 1.4 host-image-copy commands accept both advertised four-byte color
formats (RGBA8 UNORM and BGRA8 UNORM) with identical row/layer addressing and
format-preserving copies. The host-image-copy layout queries now also consume the promoted
`VkSubresourceHostMemcpySize` output chain.  The chain is ABI-checked, links are
preserved, the reported byte count matches the exact selected subresource, and
unknown or duplicate output nodes leave the layout untouched; a 4096-call
allocation-free warm path covers both image-backed and device-image queries.
The device-image form also validates the live logical-device identity before
writing, with null and stale devices remaining failure-atomic.
Descriptor-update-template writes now stage every decoded descriptor in a local
candidate before publishing it to the destination set. Invalid handles, ranges,
alignment, or a null data pointer therefore leave all prior bindings untouched;
the valid path remains allocation-free and is exercised for 4096 updates.
Pipeline-cache merges now parse ZPU's valid length-prefixed canonical records and
deduplicate by record identity before publication, while retaining opaque initial
payloads byte-for-byte; repeated duplicate merges remain allocation-free and
failure-atomic.
Combined-image-sampler descriptors now retain the typed sampler state and the
sampler object identity in every ordinary, template, push-descriptor, and
recorded-draw snapshot. Submit-time validation rejects a destroyed or
cross-device sampler without publishing a replacement descriptor; direct
filter/address-state, stale-lifetime, and allocation-free warm-path coverage
exercise the bounded behavior. General sampler filtering remains outside the
CPU raster profile.

Synchronization2 now normalizes the promoted 64-bit stage/access aliases that
have exact meaning in the bounded CPU backend: copy/resolve/blit/clear stages,
index/vertex-attribute input, compute, pre-rasterization vertex work, and
sampled or storage shader access, together with the core generic `MEMORY_READ` and
`MEMORY_WRITE` access domains. The mapping is applied consistently to dependency
barriers, event/timestamp commands, and `vkQueueSubmit2`; promoted aliases are
normalized before dynamic/traditional render-pass scope checks, and mixed
barriers lower through the union of their canonical stages so graphics-only
self-dependencies are not accidentally widened to `ALL_COMMANDS`. Dynamic and
traditional framebuffer-space source stages now require
`VK_DEPENDENCY_BY_REGION_BIT`, with the same rule enforced by legacy and
synchronization2 lowering. Unknown high bits remain rejected before command
state or submission state is published. ABI, rollback, high-bit
positive/negative, scoped graphics alias, transfer rejection, missing-BY_REGION
negative, and 4096-iteration allocation-free tests cover the conversion path.
The legacy stage-mask validator now accepts the complete Vulkan 1.0 stage
domain, including tessellation-control/evaluation and geometry stages; those
stages remain synchronization-only because their shader features are not
advertised.
`vkCmdSetEvent2`, `vkCmdResetEvent2`, and
`vkCmdWaitEvents2` now also accept valid empty `VkDependencyInfo` nodes, which
record the event operation without inventing a barrier; non-empty nodes still
lower through the canonical barrier path.

Queue submission and host timeline waits now reject duplicate semaphore handles
within each wait or signal array before consuming or publishing synchronization
state. The duplicate path is failure-atomic for binary and timeline semaphores,
and `vkQueueSubmit2` inherits the same validation through its canonical submit
conversion. Because the bounded executor has no asynchronous producer, a
timeline wait is accepted only when its target is already satisfied by the
current counter or an earlier submit in the same batch; unsatisfied waits fail
before publication instead of spinning forever.
Host and queue timeline signal operations additionally enforce the Vulkan
strictly-increasing counter rule: values equal to or below the currently
published value are rejected transactionally, and the counter remains
unchanged. Positive, lower/equal negative, and queue-signal rollback cases are
covered by the timeline semaphore ABI test.

Legacy `vkCmdWaitEvents` now honors the Vulkan host-signal source-scope rule:
`VK_PIPELINE_STAGE_HOST_BIT` is accepted in `srcStageMask` for an already
host-signaled event outside a render-pass instance, while HOST remains invalid
as a destination stage and inside render-pass scope. The rejection paths leave
the command buffer count untouched and the positive path is covered by the
allocation-free event tests.

All four event command families now enforce the device-group execution rule as
well: `vkCmdSetEvent`, `vkCmdResetEvent`, `vkCmdWaitEvents`, and their
synchronization2 counterparts reject a command buffer whose current device mask
does not select exactly one physical device. ZPU advertises a single-device
profile, so mask `1` is the only valid value. Each rejection is failure-atomic,
including the synchronization2 lowering wrappers, and the direct event fixture
covers every entry point.

Event signal provenance is now retained through recording and submission.
`vkCmdWaitEvents` rejects an event signaled by `vkCmdSetEvent2`, including a
signal recorded earlier in the same command buffer and one completed by an
earlier submission. It also requires `srcStageMask` to include the union of
preceding legacy signal stages, or `HOST` for a host signal. Synchronization2
waits use the separate lowering path, reject legacy signals, and can consume
synchronization2 signals. These rejections leave the command count untouched;
the warm rejection path is covered by 4096 allocation-free iterations.

Event wait validation now folds the latest recorded signal state, including
resets in the same command buffer. A `vkCmdResetEvent`/`vkCmdResetEvent2`
therefore clears stale stage or dependency provenance before a following wait,
while already-signaled set operations remain no-ops.

Synchronization2 event waits also retain a canonical pointer-independent key
for each `VkDependencyInfo`. A wait on a synchronization2 signal is rejected
unless its dependency payload matches the latest signal payload; same-buffer
mismatches and mismatches from an earlier submission are failure-atomic and
covered directly.
When the last signal is a host `vkSetEvent`, `vkCmdWaitEvents2` now requires
every first-scope source stage in the dependency to be HOST or NONE, so a host
signal cannot satisfy device-stage work. Host-only waits, mixed-stage rollback,
and a 4096-iteration allocation-free predicate path are covered directly.

Host event transitions are idempotent: `vkSetEvent` does not overwrite an
already-signaled event (or its signal provenance), and `vkResetEvent` does not
rewrite an already-unsignaled event. This matches the Vulkan host event
operation rules and keeps subsequent legacy/synchronization2 waits tied to the
signal that actually occurred.

The bounded execution checkpoint for `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC`
is complete. Descriptor writes and update templates preserve the dynamic type,
require the advertised 256-byte uniform-buffer alignment, and
`vkCmdBindDescriptorSets` applies one checked per-bind offset without mutating the
descriptor set. Draw snapshots capture the effective offset, so rebinding the
same set with a different offset is isolated and allocation-free. The focused
dynamic-offset test covers rejected count/null/alignment cases, rollback, effective
range bounds, snapshot isolation, and a 4096-iteration warm path. The bounded
compute execution slice is also covered by an end-to-end dispatch that writes a
mapped storage buffer and verifies the result after queue submission. General
SPIR-V compute execution and unrestricted arbitrary graphics execution remain
the next execution-semantic gap; the driver still executes only the bounded
scalar graphics profile described above, with the same failure-atomic and
allocation-free warm-path guarantees as the other advertised subsets.

| Core revision | Mandatory commands | Names dispatched now | Missing names |
| --- | ---: | ---: | ---: |
| 1.0 | 137 | 137 | 0 |
| 1.1 | 28 | 28 | 0 |
| 1.2 | 13 | 13 | 0 |
| 1.3 | 37 | 37 | 0 |
| 1.4 | 19 | 19 | 0 |

## Required proof for every slice

Each slice must land with all of the following:

1. ABI layout and dispatch tests derived from the pinned registry.
2. Positive, negative, ownership, stale-handle, teardown, and failure-atomicity
   unit tests appropriate to the command.
3. An independent C client through the system Vulkan loader for externally
   observable behavior.
4. A deterministic performance-regression test. Control-plane commands prove
   bounded passes and zero steady-state allocation; data-plane commands also
   enter the controlled baseline benchmark with p50/p95/p99 comparison.
5. `zig build behavior`, 100% driver executed-line coverage, the independent
   client, and the full limited-CPU test suite.
6. No feature, format, limit, extension, or core-version advertisement before
   the behavior behind it is complete.

## Dependency order

### A. Finish mandatory Vulkan 1.0

- [x] **A1 — coherent mapped-memory ABI:**
  `vkFlushMappedMemoryRanges`, `vkInvalidateMappedMemoryRanges`, and
  `vkGetDeviceMemoryCommitment`.
- [ ] **A2 — administrative objects:** layer enumeration, command-pool and
  descriptor-pool reset/free, real pipeline-cache data/merge behavior,
  buffer views, and render-area granularity.
  `vkFreeCommandBuffers` now prevalidates the complete void-returning batch
  (device/pool ownership and duplicate handles) so malformed input cannot
  partially release command buffers; the rejection path is allocation-free.
- [ ] **A3 — events and synchronization:** typed host events and command-buffer
  set/reset operations are complete; wait-event semantics, full stage/access
  masks, and asynchronous queue ordering remain.
- [ ] **A4 — query pools:** reset, begin/end, timestamps, result availability,
  host result reads, and buffer copies. Host resets reject ranges that overlap
  a query actively begun by any recording command buffer; empty in-range
  resets remain allocation-free no-ops.
- [ ] **A5 — complete transfer commands:** update, blit, resolve,
  depth/stencil clear, and attachment clear with format/layout handling.
  Transfer recording is failure-atomic: `vkCmdFillBuffer` now rejects ended
  or previously-invalid command buffers before appending any command.
  Buffer-copy bound offsets and aliased overlap endpoints use checked arithmetic
  and reject wrapping ranges conservatively before recording.
- [ ] **A6 — general graphics input and drawing:** vertex/index binding,
  indexed and indirect draws, dynamic state, push constants, subpasses, and
  removal of the vkcube-only execution restriction. Static/dynamic viewport and
  scissor selection plus aligned dynamic uniform-buffer descriptor offsets and
  maintenance-4 binding ranges/strides are now covered; bounded scalar
  graphics now advertises and executes up to four multi-draw indirect records
  per command, while indirect-count argument buffers are consumed at
  submission. The vkcube-only shader/draw execution restriction remains.
- [ ] **A7 — compute:** compute pipeline records, dispatch envelopes, and the
  bounded straight-line storage-buffer read/write profile are implemented with
  ownership, submit-time validation, transactional descriptor aliasing, and
  end-to-end write tests. Static acyclic branch and constant-selector switch
  profiles are also lowered with unselected side-effect blocks removed.
  Indirect dispatch arguments are consumed at submission. The bounded compute
  profile now also supports signed integer negation, component-wise integer
  multiply, bitwise operations, bounded integer bit reversal and population count,
  bit-field insertion and signed/unsigned extraction, integer division/remainder,
  dynamic vector component extraction/insertion, and bounded integer shifts,
  static vector composite insertion, raw numeric bitcasts preserving payload bits,
  and exact `OpCopyObject` value copies,
  and bounded `OpQuantizeToF16` f32 precision rounding with normalized-f16
  subnormal flush-to-signed-zero semantics, plus scalar extended integer
  carry/borrow and high-word arithmetic with pair extraction,
  and executes bounded floating
  remainder/modulo and dynamic scalar/vector integer comparisons,
  ordered/unordered scalar/vector floating-point comparisons with NaN semantics, and
  component-wise scalar/vector boolean logical operations, scalar-or-vector
  `OpSelect`, bounded f32 4x4 column-major
  matrix/vector arithmetic (including transpose, outer-product, and vector
  dot), floating classification/reduction, and constant-folds
  scalar integer equality, and resolves predecessor-selected `OpPhi` values at
  static acyclic branch joins, preserving only the incoming value from the
  selected predecessor before lowering to straight-line canonical IR. The
  bounded `GLSL.std.450` import path now lowers component-wise `FAbs` and
  `SAbs` with strict import/opcode/type checks; signed `INT_MIN` absolute value
  is rejected as a numeric-domain error. It also lowers scalar/vector `FMin`
  and `FMax` with strict floating-point shape checks and a deterministic
  implementation-defined NaN operand choice. Scalar/vector `FSign` and `SSign`
  are likewise lowered with strict scalar-domain checks; floating NaNs map
  deterministically to canonical `+0`, signed zero keeps its sign bit, and
  signed integer extrema map to `-1` without overflow. Scalar/vector unsigned
  and signed integer `UMin`/`SMin`/`UMax`/`SMax` are also lowered with exact
  32-bit ordering. Scalar/vector `FClamp`/`UClamp`/`SClamp` use the same
  component-wise min/max ordering and reject inverted bounds as a numeric
  domain error. Scalar/vector `FMix` and `Fma` now lower as strict three-input
  floating-point operations; `FMix` computes the linear blend and `Fma` uses a
  fused multiply-add with canonical NaN output. Scalar/vector `Step` and
  `SmoothStep` now lower with exact threshold and Hermite interpolation
  semantics; inverted smooth-step edges are rejected as a numeric-domain
  error. Scalar/vector `Round`, `RoundEven`, and `Trunc` now lower with
  deterministic nearest, nearest-even, and toward-zero semantics while
  preserving finite IEEE values. Scalar/vector `Floor`, `Ceil`, and `Fract` now
  lower with signed-zero and non-finite canonicalization consistent with the
  bounded floating-point executor. Scalar/vector `Radians`, `Degrees`, `Sin`,
  `Cos`, `Tan`, `Asin`, `Acos`, and `Atan` now lower through the same
  component-wise f32 path, preserving signed zero and canonicalizing runtime
  NaNs. `Sinh`, `Cosh`, `Tanh`, `Asinh`, `Acosh`, and `Atanh` now use the same
  strict component-wise path with explicit domain-result canonicalization. A
  single bounded family of `Exp`, `Log`, `Exp2`, `Log2`, `Sqrt`, and
  `InverseSqrt` operations now follows IEEE zero/infinity/NaN behavior through
  the same executor. `Atan2` and `Pow` now lower as strict binary f32
  operations with operand-order and poison-domain validation. `Determinant`
  and `MatrixInverse` now lower for column-major f32 4x4 matrices, with
  singular inverses rejected atomically and NaN results canonicalized. A single
  bounded vector family now also lowers `Length`, `Distance`, `Cross`,
  `Normalize`, `FaceForward`, `Reflect`, and `Refract` for f32 vectors with
  strict arity/shape checks, explicit zero-normal and total-internal-reflection
  behavior, and allocation-free warm execution. A single
  integer bit-index family now lowers `FindILsb`, `FindSMsb`, and `FindUMsb`
  to signed lane positions with the specified `-1` zero/sentinel behavior.
  `Ldexp` now lowers scalar/vector f32 values with same-width signed i32
  exponents, rejects non-finite/overflowing results atomically, and keeps the
  warm path allocation-free. `NMin`, `NMax`, and `NClamp` now lower the
  non-NaN-preferred floating-point family with explicit NaN selection,
  inverted-bound rejection, and allocation-free warm execution.
  Normalized pack/unpack operations now cover `PackSnorm4x8`, `PackUnorm4x8`,
  `PackSnorm2x16`, `PackUnorm2x16`, `UnpackSnorm2x16`, `UnpackUnorm2x16`,
  `UnpackSnorm4x8`, and `UnpackUnorm4x8` with fixed lane counts, little-endian
  bit placement, and allocation-free warm execution. `PackHalf2x16` and
  `UnpackHalf2x16` now preserve IEEE-754 binary16 payloads (with canonical
  NaNs) through the same bounded path; double and aggregate-return variants
  remain capability-gated and unsupported.
  The frontend uses the normative GLSL.std.450 opcode numbers for the vector
  and bit-index families (`Length` 65 through `FindUMsb` 74); stale offset
  encodings are rejected instead of being misinterpreted.
  Fragment interpolation queries (`InterpolateAtCentroid`, `InterpolateAtSample`,
  and `InterpolateAtOffset`) are accepted for the single-sample graphics
  profile.  Centroid queries preserve the incoming interpolated value; sample
  queries require sample zero and offset queries require a zero f32x2 offset,
  which are lowered to an exact value copy.  Non-fragment stages, nonzero
  samples, and nonzero offsets remain rejected because the profile does not
  expose multisample coverage data.
  The deprecated `GLSL.std.450` `Modf` and `Frexp` forms now have a bounded
  pointer-result lowering: scalar/vector f32 inputs return the fractional part
  or significand while writing the integral part or signed exponent to an
  entry-point output interface. Scalar `ModfStruct` and `FrexpStruct` forms are
  represented as two-lane values (`(fraction, integral)` and `(significand,
  exponent-bits)` respectively); scalar/vec2 `ModfStruct` and `FrexpStruct`
  forms flatten to two/four lanes, and `FrexpStruct` exponent extraction preserves
  its signed i32 result type while extracting vec2 significand/exponent members
  with their original f32/i32 vector types. Wider vector aggregate forms remain rejected because
  the canonical IR has no mixed vector-member ABI. Function-local pointers
  remain outside the bounded profile; non-finite `Frexp`/`FrexpStruct` inputs
  are surfaced as numeric-domain errors and warm execution remains
  allocation-free.
  A single
  side-effect-free dynamic conditional or one-case runtime switch with a common
  merge is also lowered to compare/select; generic SPIR-V dynamic control flow,
  aggregate/descriptor-array indexing, atomics, shared-memory execution,
  and complete compute memory-visibility semantics remain.

### Latest audit slice — submission-time buffer span validation

Command buffers retain pointers to bound buffers and images until queue
submission.  The submission prevalidator now rechecks each retained buffer's
offset and size, plus each image's bound/owned byte span, against live storage
before any execution path calls `bufferBytes` or `imageBytes`.  This covers
fills, updates, copies, image transfers, query-result copies,
indirect dispatch/draw argument and count buffers, index buffers, vertex
bindings, descriptor-backed uniform/storage buffers, and the scalar graphics
profile.  A malformed post-record bound offset is rejected failure-atomically;
the regression runs 4096 times with allocation injection enabled and remains
allocation-free on the warm path.

### Latest audit slice — immediate host-image span validation

Immediate Vulkan 1.4 host-image-copy commands now share the same retained
storage-span check before deriving CPU slices.  `vkGetImageMemoryRequirements`
also leaves its output untouched when an internally malformed image size cannot
be represented, instead of unwrapping a missing size.  The host-copy regression
corrupts a bound image offset and exercises memory-to-image, image-to-memory,
and image-to-image rejection 4096 times with allocation injection enabled;
the malformed-size requirements query remains failure-atomic.

### Latest audit slice — transfer overlap arithmetic

Buffer/image overlap detection now checks every row, layer, byte-width, and
base-address multiplication/addition.  Any wrapping intermediate is treated
conservatively as overlap, preventing malformed retained offsets from becoming
apparently disjoint transfers.  A 4096-iteration warm regression covers the
buffer-to-image, image-region, and image-copy overlap helpers with allocation
injection enabled.

### Latest audit slice — swapchain-present image validation

`vkQueuePresentKHR` now validates each retained swapchain image handle and its
owned backing span before consuming waits or transitioning the image lifecycle.
Malformed image dimensions therefore fail atomically instead of reaching the
presentation transport with an inconsistent byte envelope; the regression
repeats that rejection 4096 times without allocations before presenting the
restored image successfully.

### Latest audit slice — query-pool retirement pins

Query-pool slot storage is now retired rather than freed immediately when a
pool is destroyed. Host `vkGetQueryPoolResults` calls and queue submissions
(including secondary command buffers) pin every referenced pool while they
execute without the registry mutex; the final pin release performs the deferred
free. Host resets are rejected while a pool is pinned, preventing slot writes
from racing queue execution. Destruction and device teardown remain
tombstone/failure-atomic, and the warm-path regressions verify pinned
destroy/release and reset rejection without allocations.

### Latest audit slice — command-buffer submission pins

Queue submission now pins primary and secondary command-buffer records before
releasing the registry mutex. Free, pool-destroy, device-destroy, and reset
paths defer recorded-command teardown while a pin is active, preventing owned
update payloads and retained secondary references from being freed underneath
the executor. One-time command buffers retire their records after the final
pin release; the secondary-lifetime regression covers the deferred path.

### Latest audit slice — submitted resource storage pins

Queue submission now retains every image and backing memory allocation reached
by copied command records, including framebuffer attachments, descriptor
uniform/storage buffers, vertex/index streams, indirect/count buffers, and
image-transfer sources and destinations.  The fixed-size pin lists keep the
submission warm path allocation-free. `vkDestroyImage`, `vkFreeMemory`, and
device teardown tombstone handles immediately but defer private image bytes,
dirty-tile metadata, and memory pages until the final submission pin releases;
this prevents a concurrent destruction from invalidating CPU slices while the
synchronous executor runs outside the registry mutex.  The lifetime regression
pins a bound allocation, destroys its last buffer, verifies the bytes remain
available through deferred free, and confirms release returns the storage.
Shared swapchain transport storage follows the same rule: transport teardown
waits for all pinned swapchain images instead of freeing shared presentation
bytes underneath a submitted image.

- [ ] **A8 — secondary command buffers:** inheritance, execution, reset, and
  lifetime rules. Traditional render-pass inheritance now matches the active
  subpass for multi-subpass execution, and the bounded dynamic rendering
  inheritance chain is covered; unrestricted secondary state inheritance and
  full command-scope rules remain.
- [ ] **A9 — sparse-disabled core contracts:** sparse-requirement queries and
  zero-bind queue behavior remain truthful while sparse features stay false.
  The Vulkan 1.1–1.3 `*Sparse*2` query paths now validate supplied output
  entry sTypes/pNext chains and preserve count/output bytes on malformed input;
  `vkQueueBindSparse` now validates top-level bind-info ABI before reporting
  unsupported, while sparse residency and nonzero sparse binds remain
  deferred.
- [ ] **A10 — replace opaque placeholders:** samplers, descriptor pools, and
  descriptor frees/resets become typed, owned objects. Pipeline caches are
  typed and owned, and valid canonical records now merge with identity-based
  deduplication while opaque initial payloads remain byte-preserving.
- [ ] **A11 — mandatory features, formats, and limits:** run the Vulkan 1.0 CTS
  subset and correct every remaining reporting/execution mismatch. The sample
  count masks are now truthful: ZPU advertises only `VK_SAMPLE_COUNT_1_BIT`,
  matching image, render-pass, and pipeline creation.

### B. Vulkan 1.1 core

- [ ] Extensible `*2` feature/property/format/memory/queue queries and complete
  recognized output `pNext` chains.
- [ ] Device groups, bind-memory2 and requirements2, queue2, descriptor update
  templates, YCbCr conversion, and the remaining 1.1 commands and mandatory
  feature/property structures. External capability queries now have a
  failure-atomic zero-capability contract; descriptor-layout support now
  validates its output chain before publication; native external-handle
  support remains intentionally unadvertised.

### C. Vulkan 1.2 core

- [ ] Timeline semaphores, buffer device addresses, render-pass2, indirect
  count draws, host query reset, descriptor indexing, scalar block layout,
  and all required 1.2 feature/property chains.

### D. Vulkan 1.3 core

- [ ] Synchronization2, dynamic rendering, copy_commands2, extended dynamic
  state, maintenance4, private data, zero-initialize-workgroup-memory, and all
  required 1.3 features, formats, and limits.

### E. Vulkan 1.4 core

- [ ] Host image copy, maintenance5/6, push descriptors, line stipple,
  rendering local read, map/unmap2, remaining 1.4 commands, feature/property
  chains, mandatory formats, and promoted-core behavior.

### F. Final advertisement and profile gates

- [ ] Generate and compile-check the full pinned command/type/enum ABI rather
  than extending the handwritten declaration block indefinitely.
- [ ] Pass the complete applicable Vulkan CTS with no validation errors.
- [ ] Pass every `VP_KHR_roadmap_2026` required capability and format gate.
- [ ] Require loader–ICD interface 7, then update driver properties, instance
  version, manifest, loader discovery, CI, and documentation to 1.4.360 in one
  final version-advertisement change.

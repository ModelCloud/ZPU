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
Before the first slice, ZPU's dispatch tables named 83 of 137 Vulkan 1.0
commands and none of the 97 commands introduced by Vulkan 1.1 through 1.4.
Some named 1.0 commands are intentionally narrow or opaque placeholders, so
name coverage is only a lower-bound inventory, not a conformance percentage.

## Current checkpoint

The implementation now dispatches and tests all 234 cumulative core command
entry points. The completed slices include timeline semaphores, compute
pipeline records and dispatch envelopes, render-pass2, copy-commands2,
synchronization2, dynamic rendering, queue-submit2, private data,
memory-requirement/address queries, device-group peer queries, host image
copies/layouts, descriptor templates, push descriptors, and the
supported/unsupported YCbCr policy. Maintenance-6 rendering attachment
locations and input-attachment indices now have command-buffer-owned state,
inside-render-pass validation, atomic rollback, reset/begin lifecycle reset,
and allocation-free warm-path coverage. Line stipple state now likewise owns
the Vulkan default and accepts the complete 16-bit pattern domain while
keeping factor validation bounded. Render-pass recording now also exercises a
real two-subpass path: each subpass has its own compatible CPU-cube pipeline,
`vkCmdNextSubpass` resets bindings, draw validation keys off the active
subpass, and malformed extra transitions fail atomically; the warm path is
allocation-free. Compute command recording now requires an owned bound compute
pipeline, carries pipeline/layout/descriptor lifetime snapshots through
submission prevalidation, and has a 4096-iteration allocation-free warm path.
The `vkGetPhysicalDeviceFeatures2` query also accepts promoted Vulkan
1.1/1.2/1.3/1.4 feature-chain structures, preserving caller-owned links and
writing the truthful all-false feature payloads instead of rejecting every
non-null `pNext`. It also accepts the individual core-promoted feature
structures (16-bit storage, descriptor indexing, line rasterization, and the
other 1.1–1.4 feature forms) with exact LP64-sized VkBool32 payloads; unknown
feature chains remain transactional rejections.
`vkGetPhysicalDeviceProperties2` now accepts aggregate and individual
promoted property chains with exact LP64-sized payloads and the same
transactional unknown-chain rejection.  The individual forms retain caller
links while zeroing unsupported capability fields; identity nodes additionally
report deterministic ZPU UUIDs, the single-device node mask, driver name/info,
the registered software-CPU driver class, and an explicit zero conformance
version so diagnostics are useful without overstating conformance.
`vkGetPhysicalDeviceImageFormatProperties2` also accepts the promoted
external-image input and external-image/YCbCr output chains, reports the
truthful no-external-handle/no-YCbCr policy, and rejects unknown chains without
mutating the base result.  The external-buffer query now uses its correct
promoted sTypes rather than the adjacent image-query values.
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
invalid counts leave the caller’s chain untouched.
Logical-device queue creation accepts the promoted
`VkDeviceQueueGlobalPriorityCreateInfo` chain for the ordinary medium queue
priority and rejects other priorities before publishing device state.
The first execution slice now compiles and runs a bounded straight-line
SPIR-V compute profiles that either store a constant `u32`, load one
statically indexed uniform-block `u32`, or choose scalar values with a boolean
select, then apply scalar arithmetic before writing through a
`VK_DESCRIPTOR_TYPE_STORAGE_BUFFER`;
invocation multiplication is bounded, uniform/storage ranges are validated at
record and submit time, and the output is written synchronously. Generic
SPIR-V compute control flow, dynamic loads, atomics,
shared memory, and arbitrary graphics execution remain explicitly deferred.
Indirect dispatch now retains its argument buffer and consumes the three group
counts at submission, including post-record writes and failure-atomic invalid
group rejection.
Dynamic rendering now records finite
`loadOp=CLEAR` attachment values for submission, validates clear domains, and
accepts framebuffer-free indexed CPU-cube draws against the active color/depth
views, while rejecting command-buffer completion while a rendering scope
remains open. Device
limits now also match the bounded
execution profile: one sample, one indirect draw, and four color attachments;
vertex-input binding/attribute stride, location, and offset bounds are checked
against the same reported limits; viewport/scissor setters also reject
non-finite or oversized domains, and oversized requests reject atomically.
Maintenance-4 vertex/index binding commands now retain their explicit range
and stride arguments: `vkCmdBindIndexBuffer2` resolves `VK_WHOLE_SIZE` and
rejects ranges outside the bound buffer, while `vkCmdBindVertexBuffers2`
records per-binding sizes and strides and rejects ranges or strides outside
the reported limits. The legacy binding commands retain the corresponding
buffer-to-end ranges.
The memory and sampler handle registries now meet the required 4096 and 4000
allocation limits respectively. The generated command matrix is a
234/234 dispatch/name-coverage artifact, not a Vulkan-conformance claim:
several commands intentionally expose only the narrow behavior behind the
currently advertised Vulkan 1.0 profile. Runtime version reporting remains at
Vulkan 1.0 until the broader feature, CTS, and performance gates below pass.
Bounded 2D array images are now backed by per-layer memory (up to 256 layers),
with matching image-format limits, requirements, subresource-layout offsets,
2D-array views, host copies, clear ranges, buffer/image copies, image copies,
and blit/resolve layer selection. Invalid layer ranges fail before recording,
and the array path has a positive isolation/rollback test plus an allocation-free
warm path. Swapchain images remain explicitly single-layer because the surface
capability reports one layer.
The Vulkan 1.4 host-image-copy layout queries now also consume the promoted
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

Synchronization2 now normalizes the promoted 64-bit stage/access aliases that
have exact meaning in the bounded CPU backend: copy/resolve/blit/clear stages,
index/vertex-attribute input, pre-rasterization vertex work, and sampled or
storage shader access. The mapping is applied consistently to dependency
barriers, event/timestamp commands, and `vkQueueSubmit2`; unknown high bits
remain rejected before command state or submission state is published. ABI,
rollback, high-bit positive/negative, and 4096-iteration allocation-free tests
cover the conversion path.

The next execution-semantic checkpoint adds `VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER_DYNAMIC`
for the bounded descriptor path. Descriptor writes and update templates preserve
the dynamic type, require the advertised 256-byte uniform-buffer alignment, and
`vkCmdBindDescriptorSets` applies one checked per-bind offset without mutating the
descriptor set. Draw snapshots capture the effective offset, so rebinding the
same set with a different offset is isolated and allocation-free. The focused
dynamic-offset test covers rejected count/null/alignment cases, rollback, effective
range bounds, snapshot isolation, and a 4096-iteration warm path. The bounded
compute execution slice is also covered by an end-to-end dispatch that writes a
mapped storage buffer and verifies the result after queue submission. General
SPIR-V compute execution and arbitrary graphics execution remain explicitly
deferred.

| Core revision | Mandatory commands | Names present before slice 1 | Missing names |
| --- | ---: | ---: | ---: |
| 1.0 | 137 | 83 | 54 |
| 1.1 | 28 | 0 | 28 |
| 1.2 | 13 | 0 | 13 |
| 1.3 | 37 | 0 | 37 |
| 1.4 | 19 | 0 | 19 |

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
- [ ] **A3 — events and synchronization:** typed host events and command-buffer
  set/reset operations are complete; wait-event semantics, full stage/access
  masks, and asynchronous queue ordering remain.
- [ ] **A4 — query pools:** reset, begin/end, timestamps, result availability,
  host result reads, and buffer copies.
- [ ] **A5 — complete transfer commands:** update, blit, resolve,
  depth/stencil clear, and attachment clear with format/layout handling.
- [ ] **A6 — general graphics input and drawing:** vertex/index binding,
  indexed and indirect draws, dynamic state, push constants, subpasses, and
  removal of the vkcube-only execution restriction. Static/dynamic viewport and
  scissor selection plus aligned dynamic uniform-buffer descriptor offsets and
  maintenance-4 binding ranges/strides are now covered; indirect draw and
  indirect-count argument buffers are consumed at submission, but the
  vkcube-only shader/draw execution restriction remains.
- [ ] **A7 — compute:** compute pipeline records, dispatch envelopes, and the
  bounded straight-line storage-buffer-store profile are implemented with
  ownership, submit-time validation, and an end-to-end write test. Indirect
  dispatch arguments are consumed at submission. Generic SPIR-V control
  flow/load/atomic/shared-memory execution and complete compute memory-
  visibility semantics remain.
- [ ] **A8 — secondary command buffers:** inheritance, execution, reset, and
  lifetime rules.
- [ ] **A9 — sparse-disabled core contracts:** sparse-requirement queries and
  zero-bind queue behavior remain truthful while sparse features stay false.
- [ ] **A10 — replace opaque placeholders:** samplers, descriptor pools,
  descriptor frees/resets, and pipeline caches become typed, owned objects.
- [ ] **A11 — mandatory features, formats, and limits:** run the Vulkan 1.0 CTS
  subset and correct every remaining reporting/execution mismatch. The sample
  count masks are now truthful: ZPU advertises only `VK_SAMPLE_COUNT_1_BIT`,
  matching image, render-pass, and pipeline creation.

### B. Vulkan 1.1 core

- [ ] Extensible `*2` feature/property/format/memory/queue queries and complete
  recognized output `pNext` chains.
- [ ] Device groups, external capability queries, bind-memory2 and
  requirements2, queue2, descriptor update templates, YCbCr conversion, and
  the remaining 1.1 commands and mandatory feature/property structures.

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

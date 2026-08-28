# CPU Metal layer (WIP)

This branch adds a native, Metal-shaped command layer in `src/metal`. It is a
CPU implementation and does not link Apple's Objective-C Metal framework.
The public types are intentionally a new ZPU ABI where Metal has no safe 1:1
Vulkan mapping; no Vulkan translation is performed by the command recorder.

The current increment covers an ordered render-pass path plus a native CPU
triangle path:

- `MTLRenderPassDescriptor`-shaped load/store and clear state
- command-buffer recording and end/commit lifecycle
- `clear` and clipped rectangle fill into RGBA8/BGRA8 surfaces, serialized on
  the submitting core
- clip-space point, line, line-strip, triangle, and triangle-strip draws with
  viewport, scissor, cull, winding, fill-mode, color interpolation, and depth
- two screen-band workers for a 3D draw: the submitting core plus one worker

The API inventory is checked in at `api/metal-abi.json`. It intentionally marks
the implementation as WIP: Apple's complete current Metal/Metal 4 framework
surface is substantially larger than this CPU renderer and is not claimed as
covered here. `tools/metal_abi_status.py --require-complete` is the fail-closed
gate to run on macOS with the target SDK; the Linux build can only validate the
native ABI and mapping manifest. The Apple documentation is the normative API
reference: <https://developer.apple.com/documentation/metal>.

## Mapping policy

1. ABI-compatible values such as color, viewport, scissor, attachment
   load/store actions, formats, and basic topology are listed in
   `src/metal/mapping.zig` as direct Vulkan remaps. No translation pass is
   involved.
2. Metal object lifetime, encoder lifecycle, and pass ownership are native
   entries because Vulkan does not provide a 1:1 ABI for those semantics.
3. CPU scheduling is bounded by workload: 2D uses one core, 3D uses at most
   two rendering lanes. This is an execution policy, not an API promise that
   an Apple device has a particular topology.

## Coverage status

The current checked-in implementation is intentionally not 100% of the Apple
Metal ABI. The remaining framework surface includes compute/blit/parallel and
Metal 4 encoders, resources and pipeline objects, argument tables, indirect
command buffers, synchronization, ray tracing, sparse resources, machine
learning/tensors, and shader compilation. A strict completeness claim belongs
only after the Apple SDK inventory and macOS/iOS behavior tests pass.

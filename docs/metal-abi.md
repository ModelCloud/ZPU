# CPU Metal layer (WIP)

This branch adds a native, Metal-shaped command layer in `src/metal`. It is a
CPU implementation and does not link Apple's Objective-C Metal framework.
The public types are intentionally a new ZPU ABI where Metal has no safe 1:1
Vulkan mapping; no Vulkan translation is performed by the command recorder.

The first increment covers the ordered 2D render-pass path:

- `MTLRenderPassDescriptor`-shaped load/store and clear state
- command-buffer recording and end/commit lifecycle
- `clear` and clipped rectangle fill into RGBA8/BGRA8 surfaces
- one-core 2D execution contract

The existing CPU cube rasterizer provides the two-core 3D machinery used by
the Vulkan path, but it is not yet exposed through a Metal render encoder.
Apple's complete current Metal/Metal 4 framework surface is substantially
larger than this layer and is not claimed as covered here. Coverage must be
generated and validated against the SDK headers on macOS/iOS CI before any
100% claim is made. The Apple documentation is the normative API reference:
<https://developer.apple.com/documentation/metal>.

## Mapping policy

1. Metal object and encoder lifetime semantics remain native to this layer.
2. A command is mapped to Vulkan only when its semantics and synchronization
   are identical; otherwise it receives a Metal-specific ABI entry point.
3. CPU scheduling is bounded by workload: 2D uses one core, 3D uses at most
   two physical-core lanes. This is an execution policy, not an API promise
   that an Apple device has a particular topology.

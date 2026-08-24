# Render IR and specialized 2D kernels

## Decision

StableHLO is not ZPU's primary IR. It preserves tensor-program semantics and
would add an ill-fitting execution model and dependency to this renderer. ZPU
uses a small, purpose-built render IR whose operations and canonical forms are
owned by the pixel semantics implemented here.

The dependency-safe path is staged:

1. Capture complete, typed, immutable pipeline state. A semantic 2D key names
   destination format, operation, source kind, blend equation, lane width, CPU
   feature requirements, Zig compiler version, serialization version, and
   kernel ABI version. Dynamic geometry, pixels, and colors remain arguments.
2. Canonicalize the render IR: clip geometry, fold transparent and opaque
   source-over constants, eliminate empty/dead operations, and apply only
   ordering-safe fusion such as consecutive overwrites of the same region.
3. Specialize the canonical operation and key into ahead-of-time Zig comptime
   fill, straight-alpha source-over, and RGBA8 sprite kernel families.
4. Cache validated selections in a bounded deterministic FIFO cache. Invalid
   or unsupported state returns a safe error and never changes semantics.

Scalar code is the pixel reference. Portable four-lane Zig vectors are always
available; the eight-lane AVX2 family is selected only after CPUID, OSXSAVE,
and XCR0 checks. AVX-512 is excluded from this ABI because there is no
controlled evidence that its state and frequency costs improve frame-time
tails. It must not be selected merely because CPUID advertises it.

Presentation stays outside kernels: XCB interaction, FIFO ownership, waits,
pacing, and frame publication are neither render-IR operations nor key traits.

Real 3D lowering is deferred until ZPU owns actual SPIR-V module and graphics
pipeline state. The existing CPU vkcube specialization remains evidence for
the current path; it is not a placeholder 3D render IR.

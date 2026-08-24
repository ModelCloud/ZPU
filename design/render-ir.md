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

## Frontend-only 3D profile

`zpu_spirv_render_profile_v1` is a deliberately bounded, non-conformant
frontend profile for SPIR-V 1.0. It decodes and semantically validates one
selected Vertex or Fragment entry point, applies supported specialization
values, and lowers straight-line shader data flow into ZPU-owned immutable
SSA-like render IR. Canonical serialization is versioned, little endian, does
not contain source SPIR-V IDs, and uses a SHA-256 digest plus full-byte equality
for collision-safe identity.

This is not general SPIR-V or Vulkan shader execution. Unsupported opcodes,
capabilities, types, storage classes, decorations, execution modes and dynamic
control flow are rejected by the profile compiler. Debug and unreachable
declarations do not participate in identity. Floating-point operations retain
their order and exact literal bits; the frontend performs no reassociation,
contraction, NaN rewriting, or signed-zero rewriting.

The programs are attached independently to graphics-pipeline objects and own
all of their memory after shader modules and caller buffers are destroyed.
They are metadata only: `cpu_cube_v1` remains the sole execution ABI and
`vkCmdDraw` does not interpret this IR, so existing pixels and command behavior
are unchanged.

### Profile v1 boundary

The only accepted capability and memory model are `Shader` and
`Logical GLSL450`. A caller selects one Vertex or Fragment entry. Its reachable
function is void, parameterless, nonrecursive, one-block and straight-line.
Values are bool, 32-bit signed/unsigned integer, finite binary32, vec2–vec4,
mat4, or pointers into bounded Input, Output and read-only Uniform interfaces.
Uniform blocks have at most 16 scalar/vector/mat4 members with explicit,
aligned, nonoverlapping offsets. Interface variables use Location or vertex
Position; uniform variables use DescriptorSet and Binding.

Accepted value operations are constants and specialization constants,
composite construction/extraction, bounded vector shuffle, constant access
chains, load, Output store, FNegate, IAdd, ISub, FAdd, FSub, FMul, FDiv,
VectorTimesScalar, MatrixTimesVector, and exact 32-bit numeric/bit conversions.
The implementation limits a module to 1 MiB, 16,384 decoded instructions,
8,192 profile IDs, 4,096 canonical instructions, 64 interfaces, 64
specialization entries, and 16 uniform-block members.

Everything else is outside the profile: later SPIR-V, additional capabilities,
execution modes, ExtInst, images/samplers, derivatives, discard, atomics,
barriers, undefined values, calls, recursion, branches, loops, switches, push
constants, storage writes, dynamic indexing, non-finite constants, duplicate
interfaces and mismatched pipeline interfaces/descriptors. Structurally broken
SPIR-V is classified as malformed; well-formed constructs beyond this list are
classified as unsupported.

The separately exercised frontend sequence is decode, semantic validation,
entry selection/reachability, specialization, lowering, canonicalization, and
serialization/identity. Canonicalization sorts semantic interfaces and scalar
constants, deterministically renumbers SSA values, removes debug and dead
declarations, and preserves operation/literal order and bits. SHA-256 is an
index only: equality also compares every canonical byte, including in forced
digest-collision tests.

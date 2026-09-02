# ZML/cpu integration boundary

`zpu_cpu_ml` is the only ML artifact that belongs to the portable ZPU
distribution. It is a host-OS-neutral static library plus
`include/zpu/cpu_ml.h`:

- it owns no Metal, Foundation, PJRT, Objective-C, or Apple SDK dependency;
- it consumes ordinary CPU memory and does not inspect the host OS to choose a
  backend;
- arm64 providers may dispatch AdvSIMD/NEON kernels, including on Apple
  silicon, and x86_64 providers may dispatch an AVX tier after their own
  target/runtime checks;
- `zpu_cpu_ml_compiled_cpu_arch()` and
  `zpu_cpu_ml_compiled_cpu_features()` report only the ISA compiled into the
  artifact. They are not runtime probes; a provider remains responsible for
  checking the running CPU before selecting AVX/AVX2 or another optional path;
- the optional Apple-shaped adapter stages ZPU-owned tensor views into this
  ABI and copies successful results back into ZPU-owned storage.

ZPU does not vendor or directly link a ZML runtime. A ZML bridge is an
integration-owned component that may use ZML's CPU runtime, graph compiler,
and CPU plugin, then register the resulting entry points with one of the
versioned callbacks in `zpu/cpu_ml.h`:

1. use `zpu_cpu_ml_set_backend` for transpose;
2. use `zpu_cpu_ml_set_operation_backend` for the fixed operation IDs;
3. use the named-operation v1/v2 ABI for single-output graph functions, or
   the additive v3 ABI for multi-output and mixed-element-type graph
   functions;
4. optionally register the named catalog so those CPU functions are visible
   through the Metal-shaped function-name API.

The callback receives dense, offset-zero CPU views borrowed for the callback
duration. The v3 callback has separate input/output arrays and element-type
arrays, allowing a graph provider to own arbitrary graph wiring, transposes,
and mixed-precision conversions without changing the Metal adapter. It never
receives an `MTLTexture`, `MTLBuffer`, PJRT device buffer, or platform-specific
layout object. Argument records and view metadata are immutable; providers may
write through destination data pointers, but may not redirect or reshape a
staged view. A provider decline returns
`ZPU_CPU_ML_STATUS_UNSUPPORTED`; fixed operations then use the exact portable
ZPU CPU reference path for supported operation/type combinations, while named
graph operations fail closed because there is no safe generic graph fallback.

The specialized transpose backend remains compatible with the operation entry
point: an operation with `ZPU_CPU_ML_OPERATION_TRANSPOSE` gives the registered
transpose callback first chance, then tries the generic operation provider and
finally the exact ZPU reference implementation if both providers decline.

Backend selection is explicit provider registration, not `macOS` detection.
Running ZPU on macOS therefore still uses the same CPU-only ZML contract as
running it on Linux or iOS. Apple Metal is used only by the optional
`metal-pixel` oracle tests; it is never an execution dependency of this
package.

The portability gate checks all of these boundaries by building the package
and its public C header for x86_64 Linux, arm64 Linux, arm64 macOS, and arm64
iOS, and by rejecting Metal/Foundation/PJRT symbols from the standalone
archive.

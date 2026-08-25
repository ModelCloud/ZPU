# ISA feature tiers: build/code-generation boundary

## Problem

The dispatcher exposed a `Backend` enum (`scalar`, `portable_vector`, `avx2`)
whose names promised more than the toolchain delivered:

1. `zig build` used `standardTargetOptions` with its default target. In
   Zig 0.16 that default resolves the CPU model to the *build host*, so LLVM
   was free to emit VEX-encoded instructions (AVX2, AVX-512, FMA, BMI) into
   every artifact — including the scalar and "portable" four-lane paths.
   Disassembling a natively built `libvulkan_zpu.so` found ~50,000 VEX-encoded
   instructions; such artifacts fault with `#UD` on baseline-only x86-64 CPUs.
2. The `avx2` backend merely instantiated `@Vector(8)` in the same compilation
   unit as everything else. Runtime gating therefore guarded nothing: the
   eight-lane code was compiled into the same artifact at whatever features
   the host had, and the "portable" tier could itself contain AVX2/AVX-512.

## Decision

Keep the three-tier model but make every claim enforceable by construction.
Zig 0.16 has no per-function multiversioning (no `target_clones` equivalent),
and inline AVX2 assembly is rejected by the integrated assembler under
baseline features, so a real boundary requires separate compilation:

1. **Baseline-pinned default codegen.** `build.zig` resolves
   `standardTargetOptions` with `.cpu_model = .baseline`. Every default
   artifact — ICD shared library, demo, benchmark — is compiled for the x86-64
   baseline, where LLVM cannot emit any VEX-encoded instruction. `-Dcpu=`
   remains an explicit user opt into a higher *whole-artifact* tier.
2. **Eight-lane kernels as a separate x86-64-v3 library.**
   `src/x86_64_v3_kernels.zig` exports three C-ABI wrappers around the same
   `@Vector(8)` kernel functions in `src/simd/vector.zig`, so pixel results
   are bit-for-bit identical across tiers. `build.zig` compiles it with an
   explicit `x86_64_v3` CPU model on the consumer's OS/ABI and links it into
   consumers of the raster stack (the ICD never references it). The file lives
   at `src/` depth because a Zig module cannot import files outside its root
   path. Kernels are always ReleaseFast: they are hot loops, and Debug safety
   plumbing would otherwise drag std.debug machinery into the v3 tier.
3. **Runtime gating before reachability.** `simd/dispatch.available(.avx2)`
   checks OSXSAVE/AVX state, `XGETBV`, and AVX2 CPUID bits (cached after first
   probe) *and* the comptime-known presence of the linked boundary
   (`eight_lane_boundary`). Every `.avx2` dispatch prong re-checks support via
   a tripwire that panics loudly on caller misuse instead of executing
   unsupported instructions silently. On non-x86_64 targets the extern symbols
   are comptime-unreachable, so cross builds neither reference nor link them.
4. **Kernel-free builds are one flag away.** `-Dv3-kernels=false` skips the
   kernel library entirely and flips `eight_lane_boundary` through the
   generated `zpu_config` options module, producing artifacts whose entire
   disassembly — project code *and* standard library — contains zero VEX
   instructions. This build is the reference evidence for the gate below.

## Enforcement: `zig build isa-gate`

`tools/isa_disasm_gate.sh` performs deterministic disassembly analysis
(binutils only, fixed patterns, no network or timestamps):

- **Clean mode** (`--clean`): an artifact must contain zero VEX-encoded
  instructions anywhere. Applied to all shipped artifacts built with
  `-Dv3-kernels=false`.
- **Kernelized mode** (`--kernelized`): applied to default-build demo,
  benchmark, and the kernel archive. Every instruction is attributed to its
  exact ELF FUNC symbol range from `readelf`; alignment padding and data
  tables are ignored rather than misattributed, and legacy `verr`/`verw`
  mnemonics are excluded from the VEX family. Requirements: zero VEX inside
  any project-owned non-kernel function, >0 VEX inside `zpu_v3_*` functions
  (positive control proving both vectorization and detector sensitivity).
  Foreign (standard library / compiler-rt) regions are not scanned here;
  their cleanliness follows from the baseline target plus clean-mode evidence.

`tools/isa_cross_target_gate.sh` (`zig build isa-cross`) collects the full
cross-target story: kernel-free ReleaseFast artifacts fully clean, default
artifacts clean-outside/vectorized-inside, an explicit `-Dcpu=x86_64_v3`
opt-in build verified vectorized outside the kernels too (sensitivity control
for the tier knob), and a successful `aarch64-linux-gnu` cross build proving
non-x86_64 targets never reference the kernel symbols.

Both gates run under the canonical physical-core limiter like every other
repository gate, and `isa-gate` participates in `zig build test`.

## Cache identity compatibility policy

`render_pipeline.Key` is the public cache identity: `(format, operation,
source, blend, lanes, cpu, compiler triple, kernel_abi, serialization)`. The
boundary work preserves it exactly:

- Backend tag names and their mapping to `lanes`/`cpu.avx2` are unchanged
  (`scalar→1/false`, `portable_vector→4/false`, `avx2→8/true`) and pinned by
  `"backend tier identity mapping is stable"`.
- The serialized 15-byte layout is pinned by
  `"serialized key layout is pinned for compatibility across compiler versions"`
  using a synthetic compiler version, so layout changes must bump
  `serialization_version` to fail loudly rather than alias old entries.
- `compile()` still rejects keys whose `cpu.avx2` flag disagrees with the
  lanes-derived backend or whose backend fails `dispatch.available`.

## Known limitations

- A `-Dcpu=native` (or similar explicit higher-tier) build compiles the
  portable tier with those features by user request; such artifacts are
  intentionally exempt from the baseline guarantee.
- The 32-bit x86 target never gets the eight-lane tier (`available(.avx2)`
  returns false); the previous code path claimed runtime-gated AVX2 there but
  had no separately compiled boundary to back that claim.
- AVX-512 stays excluded pending controlled frame-time-tail measurements.

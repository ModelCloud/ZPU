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
   `src/x86_64_v3_kernels.zig` publishes three C-ABI wrappers (exported via
   `@export`) around the same `@Vector(8)` kernel functions in
   `src/simd/vector.zig`, so pixel results are bit-for-bit identical across
   tiers. Symbol names and function-pointer types live once in
   `src/simd/kernel_abi.zig`: `simd/dispatch.zig` resolves the externs with
   `@extern` from that module, the kernel side exports under those exact
   names, and `tools/isa_disasm_gate.sh` matches the same names as the only
   legitimate VEX-carrying functions (a Zig test asserts the script stays in
   sync). `build.zig` compiles the library with an explicit `x86_64_v3` CPU
   model on the consumer's OS/ABI and links it into consumers of the raster
   stack; the ICD never references it. The file lives at `src/` depth because
   a Zig module cannot import files outside its root path. Kernels are always
   ReleaseFast because Debug safety plumbing would drag std.debug machinery
   into this v3-feature tier; as compensating safety every wrapper validates
   its ABI inputs explicitly (format tag and span bounds) and traps via
   `unreachable` on violation instead of corrupting pixels, while correctness
   is pinned by differential oracle tests that compare every tier byte-for-
   byte against scalar.
3. **Runtime gating before reachability.** `simd/dispatch.available(.avx2)`
   checks OSXSAVE/AVX state, `XGETBV`, and AVX2 CPUID bits (cached after first
   probe) *and* the comptime-known presence of the linked boundary
   (`eight_lane_boundary`). Every `.avx2` dispatch prong re-checks support via
   a tripwire that panics loudly on caller misuse instead of executing
   unsupported instructions silently. On non-x86_64 targets the extern symbols
   are comptime-unreachable. A comptime materialization of the extern pointers
   (`linkage_proof`) forces symbol resolution whenever the boundary is claimed,
   so an artifact reporting AVX2 availability cannot exist without the kernel
   objects physically linked — a misconfiguration is a hard link error.
4. **Kernel-free builds are one flag away.** `-Dv3-kernels=false` skips the
   kernel library entirely and flips `eight_lane_boundary` through the
   generated `zpu_config` options module, producing artifacts whose functions
   contain zero VEX instructions.

## Enforcement: `zig build isa-gate`

`tools/isa_disasm_gate.sh` performs deterministic disassembly analysis
(binutils only, fixed patterns, no network or timestamps). Required tools are
preflighted, intermediate steps check exit status, counters are validated to
be exactly five integers, and any analyzer failure fails the gate closed.

Detection is encoding-aware: objdump's raw byte column decides — an
instruction is VEX/EVEX iff its first opcode byte is `c4`, `c5` or `62`
(legal only as such in 64-bit mode), so BMI1/2, FMA and AVX-512 mask
operations cannot slip through by mnemonic spelling. Every instruction is
attributed to its exact ELF FUNC symbol range from `readelf`; alignment
padding and data tables between functions are reported separately rather than
misattributed, and legacy `verr`/`verw` mnemonics are excluded by
construction. Modes:

- **`--clean`**: zero VEX-encoded instructions inside any function.
- **`--no-kernel-symbols`**: additionally requires that none of the eight-lane
  kernel export symbols exist in the artifact — the deterministic half of the
  linkage-consistency proof.
- **`--kernelized`**: all three kernel exports must be linked and genuinely
  vectorized (>0 VEX), zero VEX may appear in project non-kernel functions,
  and foreign (standard library/compiler-rt/libc) symbols are tolerated only
  if they match an explicit auditable root list embedded in the script;
  unknown symbols are treated as project code and fail the gate (fail closed).

The gate consumes ReleaseFast kernel-free twins of every shipped artifact
(built in-graph with the boundary compiled out) under `--no-kernel-symbols`,
plus the default-tree ICD; when the v3 tier applies (`x86_64` target and
`-Dv3-kernels`, default on) demo/benchmark and the kernel archive run under
`--kernelized`, otherwise demo/benchmark also prove kernel-freedom.
`tools/isa_gate_selftest.sh` assembles deterministic fixture objects and
proves both directions: a VEX leak inside a project-named function is
rejected in every mode, and an exact full kernel export set is accepted only
under `--kernelized`.

`tools/isa_cross_target_gate.sh` (`zig build isa-cross`) collects the
cross-target story: kernel-free ReleaseFast artifacts fully clean, default
artifacts clean-outside/vectorized-inside with the archive installed at the
deterministic path provided by `zig build install-v3-archive`, an explicit
`-Dcpu=x86_64_v3` opt-in build whose functional smoke executes only on hosts
that actually support AVX2 (explicitly skipped otherwise, fatal with
`ZPU_REQUIRE_V3_RUN=1`), and a successful `aarch64-linux-gnu` build of the
default install set (xcb-linked artifacts resolved via `-Dsearch-prefix`
against a multiarch sysroot), proving non-x86_64 targets never reference the
kernel symbols.

Both gates run under the canonical physical-core limiter like every other
repository gate, and both participate in `zig build test`.

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

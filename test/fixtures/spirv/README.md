<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# SPIR-V frontend fixtures

These hand-authored SPIR-V 1.0 assembly fixtures are original ZPU test data
(CC0-1.0). They are deliberately small enough to audit against the binary word
fixtures in `src/vulkan/spirv_frontend.zig`. `vertex_position.spvasm` is the
positive baseline; each file under `negative/` names the profile boundary it
crosses. Binary words are encoded directly in Zig so tests do not depend on an
external assembler or its version.

The deterministic property corpus uses seed `0x5a50554952334431`; failures must
report that seed and the mutated word offset so they can be replayed exactly.

`chromium_skia_vertex.spvasm` disassembles the binary fixture embedded from
`src/vulkan/fixtures/chromium_skia_vertex.spv`. It captures the first vertex
shader submitted by Chromium 152's Skia Vulkan backend during GPU-process
startup. The fixture exercises `vec2` inputs and varyings, a push-constant
block, member-decorated `sk_PerVertex`, and output access chains.

`chromium_skia_vertex_relaxed.spvasm` captures a later Chromium Skia vertex
shader with relaxed-precision decorations, multiple `vec4` inputs and
varyings, and function-local storage.

`chromium_skia_vertex_flat.spvasm` captures Chromium's flat-color vertex path.
It exercises `Flat` interpolation metadata on a `vec4` output while retaining
the structured position and push-constant interfaces.

`chromium_skia_fragment_flat.spvasm` captures the matching fragment path. It
exercises the fragment origin mode, output index zero, `FrontFacing`, and a flat
`vec4` input.

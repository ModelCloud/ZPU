<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan ABI submission benchmarks

`benchmark-vulkan-abi` measures the command-stream boundary used by the
`cpu_cube_v1` Vulkan bridge. It compares one CPU-raster dispatch per recorded
draw, the legacy 256-command chunking, and the existing Vulkan ABI's adaptive
private Mosaic executor. Large streams use immutable prepared geometry and
spatial supertile ownership; small streams stay on the tuned prepared batch
kernel when that is faster.

The profiles are deterministic usage-shape references drawn from open-source
projects:

| profile | open-source reference | stream shape |
| --- | --- | --- |
| `wezterm_terminal` | [WezTerm](https://github.com/wezterm/wezterm), whose WebGPU front end can select Vulkan | 120×40 terminal cells plus a background; 4,801 draws, 19 legacy chunks versus one Mosaic batch |
| `imgui_vulkan_app` | [Dear ImGui SDL2 + Vulkan example](https://github.com/ocornut/imgui/tree/master/examples/example_sdl2_vulkan) | 192 opaque UI panels, controls, icons, and text-like quads |
| `khronos_complex_demo` | [Khronos Vulkan Samples](https://github.com/KhronosGroup/Vulkan-Samples) | 128 objects, six textured quad faces each, animated transforms and depth |
| `vkquake_fps` | [vkQuake](https://github.com/Novum/vkQuake) | 2,048 BSP-like surfaces, entities, particles, sky, and HUD; static world geometry with moving actors |
| `vkquake2_fps` | [vkQuake2](https://github.com/kondrak/vkQuake2) | 1,536 materialized surfaces, dynamic-light-like sprites, and HUD; mostly static world |
| `vkdoom_fps` | [VkDoom](https://github.com/nashmuhandes/VkDoom) | 1,792 sector-wall-like quads, masked sprites, particles, sky, and HUD |
| `vulkan_voxel_world` | [vulkan-voxel-game](https://github.com/pimpale/vulkan-voxel-game) | 1,024 chunk-face and atlas-material draws with a static chunk mesh |
| `space_menace_platformer` | [Space Menace](https://github.com/amethyst/space-menace) | 768 Vulkan platformer-shaped tile, sprite, particle, and HUD draws |

These are not external runtime dependencies and the suite does not claim to
run those projects or implement general SPIR-V, blending, or alpha-compositor
semantics. They provide realistic draw-count, static-versus-dynamic update,
texture, depth, and command-boundary shapes for the narrow renderer that ZPU
actually exposes. The repository search did not identify a maintained
Vulkan-based project named `Penguin Run`; `space_menace_platformer` is the
verified Vulkan platformer proxy, while the Quake/Doom profiles use actual
open-source Vulkan source ports.

## Run

The benchmark accepts the existing physical-core gate at widths 1 through 8.
Two cores remains the historical evidence profile; use a different
`ZPU_MAX_THREADS` value to measure scaling without changing the workload or
affinity policy:

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-vulkan-abi \
  -Doptimize=ReleaseFast -- --json
```

Focused runs are available with `--scenario`:

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-vulkan-abi \
  -Doptimize=ReleaseFast -- --scenario wezterm_terminal --json
```

Add `--smoke` for three samples. Normal runs use two warmups and six measured
frames per mode. The report includes p50/p95/p99 frame time, FPS,
legacy/Mosaic batch counts, checksums, and both per-draw and legacy-to-Mosaic
speedups. Clear and checksum work is kept identical between modes; the
comparison isolates draw submission and raster execution.

For a controlled core-width sweep:

```sh
for cores in 2 3 4; do
  ZPU_MAX_THREADS=$cores tools/limited-cpus.sh zig build benchmark-vulkan-abi \
    -Doptimize=ReleaseFast -- --json > "mosaic-${cores}c.json"
done
```

The Mosaic raster scheduler now creates bounded 256×256-pixel Morton
supertiles, partitions them into per-core queues, keeps the render thread on
the first selected CPU, and pins worker `i` through the existing locality
mapping. Workers drain own work, then same-LLC and same-NUMA queues. Without
the explicit `physical-core-v1` harness marker, generic callers retain the
two-band compatibility profile.

The driver-side Mosaic bridge only accepts adjacent commands with the exact
opaque `cpu_cube_v1` contract: single-layer, non-indexed, one instance,
triangle-list geometry, no blend/cull/bias, full color writes, and compatible
attachments. It can join compatible runs across primary command-buffer streams
within one queue submit, but never crosses a non-draw command or submit
boundary. Any other command remains on the original executor.

## Mosaic runtime result

The merged runtime bridge now gives each begun command buffer a lazy bounded
8,192-command recording arena and stages eligible adjacent draws in thread-local
storage. The queue executor joins compatible primary streams before sending the
complete bounded run to the prepared scalar Mosaic executor. This fixes two
mismatches where the benchmark modeled one 8,192-command batch while the real
driver stopped at 256 commands and dispatched each primary independently.

The arena is released with command-buffer contents, including the deferred
retirement path used when a command buffer is destroyed while a queue submit
still pins it. Unsupported commands remain hard Mosaic barriers, so stream
coalescing does not reorder observable Vulkan work.

The current ReleaseFast probe uses static geometry revisions for the world and
chunk portions of the game-shaped streams, while actor/sprite transforms still
change every frame. At four selected physical cores, Mosaic versus per-draw
dispatch measured 4.40× for the vkQuake-shaped stream, 3.85× for vkQuake2,
3.78× for VkDoom, 4.15× for the voxel world, and 3.05× for the platformer
profile. The WezTerm-shaped stream measured 2.41× in the same three-sample
smoke run and remains sensitive to placement and cache state. These are
workload-specific measurements, not claims about the upstream applications;
the byte-identical color/depth oracle is the correctness gate.

## Core-width scaling result

The spatial bridge now uses all selected workers for the long stream. The
latest four-core run improves the WezTerm-shaped path from 2.91× to 3.10×
versus per-draw dispatch as the host width changes from two to four cores; the
absolute p50 is sensitive to CPU placement and background load. The short
ImGui and Khronos profiles intentionally stay on their already-cheaper
prepared batch path and remain approximately 1.00× over legacy at all widths.

The next target is to route more of the broad, textured game geometry through
Mosaic's physical `LOCAL`/`MACRO`/`GLOBAL` packet executor. Large primitives
that cross supertile boundaries currently take the strict ordered batch
fallback because the existing interpolator is not yet proven bit-identical
when segmented. The scalar packet path must first retain byte identity there;
SIMD and visibility/deferred paths follow that gate.

## Next 4× target

The long-stream submission problem is no longer the only target. Short and
medium streams already pay only one dispatch, so increasing the Mosaic batch
limit cannot improve them. The adaptive policy keeps those streams on the
prepared batch kernel instead of forcing them through a more expensive spatial
plan.

The next target is the broad textured primitive path used by FPS and voxel
profiles: preserve one-time static preparation, then make segmented
`LOCAL`/`MACRO`/`GLOBAL` execution use one global interpolation origin. The
current strict fallback is intentional and keeps Vulkan ordering and output
correct while this kernel is developed. The physical scalar executor and its
differential test now exist in `src/render/scalar_packet.zig`; driver lowering
remains gated until the broader game corpus is byte-identical.

## Correctness contract

`src/benchmark_vulkan_abi.zig` requires the legacy-chunked, Mosaic-batched, and
per-draw paths to produce byte-identical color and depth attachments for all
eight profiles. The profiles intentionally fit under the 8,192-command Mosaic
limit, keeping each complete frame in one bounded submission. Driver tests
continue to cover the full Vulkan command executor and the existing serial
raster oracle.

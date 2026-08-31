<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan ABI submission benchmarks

`benchmark-vulkan-abi` measures the command-stream boundary used by the
`cpu_cube_v1` Vulkan bridge. It compares one CPU-raster dispatch per recorded
draw, the pre-Mosaic 256-command chunking, and the private Mosaic 8,192-command
batch bridge. The current optimization target is command-stream fragmentation:
long application streams should reach Mosaic as one ordered batch where Vulkan
semantics allow it.

The profiles are deterministic usage-shape references drawn from open-source
projects:

| profile | open-source reference | stream shape |
| --- | --- | --- |
| `wezterm_terminal` | [WezTerm](https://github.com/wezterm/wezterm), whose WebGPU front end can select Vulkan | 120×40 terminal cells plus a background; 4,801 draws, 19 legacy chunks versus one Mosaic batch |
| `imgui_vulkan_app` | [Dear ImGui SDL2 + Vulkan example](https://github.com/ocornut/imgui/tree/master/examples/example_sdl2_vulkan) | 192 opaque UI panels, controls, icons, and text-like quads |
| `khronos_complex_demo` | [Khronos Vulkan Samples](https://github.com/KhronosGroup/Vulkan-Samples) | 128 objects, six textured quad faces each, animated transforms and depth |

These are not external runtime dependencies and the suite does not claim to
run those projects or implement general SPIR-V, blending, or alpha-compositor
semantics. They provide realistic draw-count, update, texture, depth, and
command-boundary shapes for the narrow renderer that ZPU actually exposes.

## Run

Use the same two-physical-core gate as the 3D renderer benchmarks:

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

On the validation host, the smoke probe measured the 4,801-draw WezTerm-shaped
stream at 30.17 ms p50 with 256-command chunking and 3.00 ms p50 through Mosaic
(10.05×). The ImGui-shaped 192-draw and Khronos-shaped 128-object streams
remain one batch in both modes: 0.997× and 1.002× respectively. These are
workload-specific measurements; the byte-identical color/depth oracle is the
correctness gate.

## Next 4× target

The long-stream submission problem is no longer the highest-value target.
Short and medium streams already pay only one dispatch, so increasing the
Mosaic batch limit cannot improve them. A Mosaic-only attempt to force those
batches through the parallel scheduler regressed the ImGui-shaped frame by
about 19% and was discarded.

The next target is the one-batch raster path used by both short workloads:
execute prepared geometry through tile-local physical packets, first with the
scalar executor and then with portable primitive batches. The physical
`LOCAL`/`MACRO`/`GLOBAL` scalar executor and its differential test now exist in
`src/render/scalar_packet.zig`; driver lowering remains gated until its output
matches the existing reference path across the broader semantic corpus. This
is the measured route toward another 4×, rather than claiming a speedup from a
submission change that these workloads do not exercise.

## Correctness contract

`src/benchmark_vulkan_abi.zig` requires the legacy-chunked, Mosaic-batched, and
per-draw paths to produce byte-identical color and depth attachments for all
three profiles. The terminal profile intentionally fits under the 8,192-command
Mosaic limit, keeping the complete frame in one bounded submission. Driver
tests continue to cover the full Vulkan command executor and the existing
serial raster oracle.

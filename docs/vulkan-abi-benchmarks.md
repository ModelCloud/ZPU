<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan ABI submission benchmarks

`benchmark-vulkan-abi` measures the command-stream boundary used by the
`cpu_cube_v1` Vulkan bridge. It compares one CPU-raster dispatch per recorded
draw, the pre-Mosaic 256-command chunking, and the private Mosaic 8,192-command
batch bridge. The target for this pass is a 2× p50 frame-time improvement.

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
attachments. Any other command remains on the original per-command executor.

## Mosaic runtime result

The merged runtime bridge now stages eligible adjacent draws in thread-local
storage and sends the complete bounded stream to the prepared scalar Mosaic
executor. This fixes a mismatch where the benchmark modeled one 8,192-command
batch while the real driver stopped at 256 commands.

On the validation host, the smoke probe measured the 4,801-draw WezTerm-shaped
stream at 31.3 ms p50 with 256-command chunking and 2.86 ms p50 through Mosaic
(10.9×). The ImGui-shaped 192-draw and Khronos-shaped 128-object streams remain
one batch in both modes and therefore remain within measurement noise. These
are workload-specific measurements; the byte-identical color/depth oracle is
the correctness gate.

## Correctness contract

`src/benchmark_vulkan_abi.zig` requires the legacy-chunked, Mosaic-batched, and
per-draw paths to produce byte-identical color and depth attachments for all
three profiles. The terminal profile intentionally fits under the 8,192-command
Mosaic limit, keeping the complete frame in one bounded submission. Driver
tests continue to cover the full Vulkan command executor and the existing
serial raster oracle.

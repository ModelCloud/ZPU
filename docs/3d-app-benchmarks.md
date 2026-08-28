<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Usage-shaped 3D application benchmarks

`benchmark-3d-apps` complements the frozen vkcube gate with three deterministic
draw-usage profiles. They exercise the existing `cpu_cube.zig` renderer through
its two-core batch APIs; they are not end-to-end Windows, terminal, or
game-engine benchmarks and make no general SPIR-V performance claim.

## Workloads

| workload | application shape | frame contents |
| --- | --- | --- |
| `desktop` | desktop window compositor | 12 layered windows, each with a shadow, surface, and title-bar draw; clipped edges and depth ordering |
| `terminal` | terminal text repaint | one background plus a 24×10 glyph grid; every glyph is a clipped textured quad sampled from a 16×16 atlas |
| `game` | dynamic game-engine scene | 32 moving objects, six quads/12 triangles per object, changing transforms and overlapping depth |

The fixed 800×600 frame starts from a color clear and a depth value of one.
Each draw is submitted separately, so draw-call overhead and raster work are
both visible. The desktop profile represents an unchanged compositor frame and
uses the immutable batch replay contract after its first rendered frame; the
terminal profile repaints its glyph atlas selection every frame; the game
profile changes every object's position, rotation, scale, and depth each frame.
The workloads use opaque textured surfaces because the current CPU 3D API does
not implement a general fragment-blend contract. Alpha-compositor arithmetic
is covered by the existing 2D benchmark.

## Run

Use exactly two selected physical cores, matching the vkcube 3D gate:

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d-apps -Doptimize=ReleaseFast -- --json
```

Useful focused runs are:

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d-apps -Doptimize=ReleaseFast -- --scenario desktop
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d-apps -Doptimize=ReleaseFast -- --scenario terminal
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d-apps -Doptimize=ReleaseFast -- --scenario game
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d-apps -Doptimize=ReleaseFast -- --smoke --json
```

Full runs use three warmups and twelve measured frames per profile. Terminal and
game frames include attachment clear, all profile draw calls, depth testing,
and the XxHash3-64 framebuffer integrity checksum. Desktop renders its first
measured frame, then measures immutable replay plus the same checksum; this is
intended to represent a compositor that has no changed surfaces, not raw
raster throughput. XxHash3-64 keeps the in-frame oracle inexpensive while
remaining independent of the renderer; the canonical fixed-FNV vkcube
benchmark is unchanged. The report includes FPS, draw/s and triangles/s,
p50/p95/p99/max/CV frame time, first/final checksums, and counters from the
first measured frame. The smoke mode is for CI and correctness checks, not
performance claims.

The terminal profile also exercises the opt-in
`drawUncountedParallelBatchOpaqueOverlay` Vulkan-facing API. It renders the
background and stable glyph geometry once, then updates only the opaque glyph
colors from the 16×16 atlas while preserving depth and avoiding a full-frame
clear. The API contract is deliberately narrow: callers must guarantee opaque,
depth-passing overlays and must clear or cover obsolete coverage themselves.
This models steady-state terminal/compositor text updates; it is not a
general-purpose alpha or blending path.

Batch callers that can track their own data lifetimes may set the optional
`DrawCommand` `uniform_revision`, `geometry_revision`, and `texture_revision`
keys. Non-zero keys avoid defensive byte scans while retaining pointer checks;
zero keeps the original byte-comparison behavior. Callers must advance a key
whenever the corresponding bytes change.

## Correctness contract

`src/benchmark_3d_apps.zig` contains two focused tests:

- the profile-shape test freezes draw-call and triangle counts and asserts that
  clipping, atlas dimensions, and dynamic-mesh sizes are actually represented;
- the application oracle test renders each profile through both the serial and
  two-core paths, requiring identical color/depth attachments and checksums,
  matching submitted/rasterized triangle counts, nonzero coverage, and a
  changed but still matching game frame after animation.
- the terminal overlay test compares an incremental overlay update against a
  fully cleared redraw and requires byte-identical color and depth attachments.

Run them with:

```sh
zig test src/benchmark_3d_apps.zig -O ReleaseFast -lc
```

The serial comparison is a unit-test oracle, not a second performance result.
The canonical low-jitter evidence workload remains
[`benchmark-3d`](3d-benchmark-todo.md) and is intentionally kept separate from
these application-shaped profiles.

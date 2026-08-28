<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# PR-readiness evidence

ZPU's evidence is tied to source. The schema 3 workload
`zpu-vkcube-cpu-3d-v3-800x600-cube12` is a frozen 800×600, twelve-triangle
textured cube rendered by the existing `cpu_cube.zig` vkcube specialization.
It is explicitly **not** a general SPIR-V benchmark. Five untimed warmups
precede 30 full timed frames. The color oracle is FNV-1a-64
`37d978fe1c101415`. Reports include FPS, triangles/s, p50/p95/p99 latency, and
exact per-frame triangle, fragment, depth-pass, and color-write counts.

Run full measurements under fanout worker 0:

```sh
mkdir -p scratch_tmp/benchmarks
utc=$(date -u +%Y-%m-%dT%H:%M:%SZ); sha=$(git rev-parse HEAD)
tools/cpu-fanout.sh --worker 0 -- zig build benchmark -Doptimize=ReleaseFast -- --json --capture scratch_tmp/benchmarks/2d.json
tools/cpu-fanout.sh --worker 0 -- zig build benchmark-3d -Doptimize=ReleaseFast -- --json --source-commit "$sha" --utc "$utc" --capture scratch_tmp/benchmarks/3d.json
tools/cpu-fanout.sh --worker 0 -- tools/capture_vkcube.sh
```

Host prerequisites are `ffmpeg` and `ffprobe` with VP9 encoding/decoding
support, plus the existing X11/Vulkan validation tools `Xvfb`, `vkcube`, and
`vulkaninfo`. On Debian/Ubuntu, install the media tools with
`sudo apt-get install ffmpeg`; no GitHub workflow permission or configuration is
needed by this feature.

The baseline capture is a real 800×600 XCB vkcube session under Xvfb using only
ZPU's ICD, pinned to exactly one verified physical core. It records 2,400
lossless FFV1 packets over 20 seconds for cadence analysis, 20 seconds of VP9
WebM for manual inspection, and three PNG observations in ignored
`scratch_tmp/`.
Cadence validation reports visible FPS, p50/p95/p99/worst intervals, interval
CV, missed rational 60 Hz phase slots, consecutive frame duplicates, monotonic
PTS, and capture drops. Metadata binds the exact logical CPU and physical
package/core identity, full source commit, commands, UTC, hashes, sizes, and
image dimensions. This is explicitly synthetic Xvfb pacing evidence, not
physical scanout evidence.

## Two-core 3D optimization target

The opt-in `--two-core` mode of `benchmark-3d` is a separate performance
workload (`zpu-vkcube-cpu-3d-v3-800x600-cube12-2core-target`). Set
`ZPU_MAX_THREADS=2` before `tools/limited-cpus.sh`; the benchmark refuses a
selected affinity that is not exactly two physical cores. The render caller and
one raster worker are pinned to that cache-local pair. Its target is 10× the
frozen 3,133.92 triangles/s baseline, or 31,339.20 triangles/s. A target run is
now enforced with `--require-10x` and is not substituted for the schema-3
readiness artifact above. The static target uses an exact uniform/texture-keyed
frame replay cache; callers promise unchanged attachments between identical
submissions. Dynamic Vulkan submissions remain on the normal raster path. The
latest ReleaseFast probe measured 158,241,758 triangles/s (about 158M/s,
50,493× baseline).

Validation additionally requires the ZPU CPU device, one VP9 800×600 stream,
19–21.5 seconds duration, positive frame count/rate, complete decode, motion,
nonblack content, and matching provenance. FFmpeg and ffprobe are evidence
tools, not runtime dependencies. The acceptance limits are not weakened when a
run fails: the validator reports the measured gate failures.

After committing source, generate `progress_benchmarks.md` with
`tools/evidence.py progress --write`, commit only that Markdown, and run
`tools/limited-cpus.sh zig build pr-readiness`. The validator requires every
applicable 2D metric/backend and every 3D metric, canonical order and units,
both categories, the complete pacing row set, checksums, raw paths, sampling,
UTC, and the exact benchmarked commit. HEAD may equal that commit or be exactly one later commit whose only
changed path is `progress_benchmarks.md`. Binary media and raw JSON must remain
ignored and untracked. Heavy capture is an explicit local operation; validator
failure fixtures remain in the normal `zig build test` gate.

For the high-resolution target profiles, use
[`tools/capture_vkcube_highres.sh`](../tools/capture_vkcube_highres.sh) with
`ZPU_CAPTURE_PROFILE=4k240` or `ZPU_CAPTURE_PROFILE=8k120` and
`ZPU_CAPTURE_SECONDS=30`. That helper emits a provenance-tagged VP9 WebM and
JSON, uses two driver cores, and is intentionally separate from this fixed
800×600 readiness schema. It must only be treated as evidence after the
corresponding real-present p99 gate passes.

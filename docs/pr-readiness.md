# PR-readiness evidence

ZPU's evidence is tied to source. The 3D workload
`zpu-vkcube-cpu-3d-v1-320x240-cube12` is a frozen 320×240, twelve-triangle
textured cube rendered by the existing `cpu_cube.zig` vkcube specialization.
It is explicitly **not** a general SPIR-V benchmark. Five untimed warmups
precede 30 full timed frames. The color oracle is FNV-1a-64
`b63a7b2fb2f50601`. Reports include FPS, triangles/s, p50/p95/p99 latency, and
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

The capture is a real 640×480 XCB vkcube session under Xvfb using only ZPU's
ICD. It records 20 seconds of VP9 WebM and three PNG observations in ignored
`scratch_tmp/`. Validation requires the ZPU CPU device, one VP9 640×480 stream,
19–21.5 seconds duration, positive frame count/rate, complete decode, motion,
nonblack content, and size/SHA-256/UTC/source metadata. FFmpeg and ffprobe are
evidence tools, not runtime dependencies.

After committing source, generate `progress_benchmarks.md` with
`tools/evidence.py progress --write`, commit only that Markdown, and run
`tools/limited-cpus.sh zig build pr-readiness`. The validator requires every
applicable 2D metric/backend and every 3D metric, canonical order and units,
both categories, checksums, raw paths, sampling, UTC, and the exact benchmarked
commit. HEAD may equal that commit or be exactly one later commit whose only
changed path is `progress_benchmarks.md`. Binary media and raw JSON must remain
ignored and untracked. Heavy capture is an explicit local operation; validator
failure fixtures remain in the normal `zig build test` gate.

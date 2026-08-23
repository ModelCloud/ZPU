# 2D performance methodology

`tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --json` runs the versioned `zpu-2d-v1-240x240-seed-151521030` workload. It measures clear, single-pixel draws, rectangle fill, transfer-style byte fill/copy, alpha blend, sprite draws, and complete deterministic 240×240 frames. Raster operations run with scalar, each CPU/OS-available vector backend, and normal runtime dispatch; byte transfers have no dispatch choice and run once. Results include MPix/s, effective GiB/s (documented bytes read plus written), draws/s, FPS, per-operation p50/p95/p99 latency, iteration counts, and an FNV-1a output checksum.

Each case starts from the same seeded bytes, executes an unmeasured warmup, resets, then takes 15 monotonic-clock samples with 20 operations per sample. The reported rates use the median. ReleaseFast is the meaningful performance configuration. `--smoke` reduces this to three samples of two operations for CI schema/correctness checks, not performance claims. Checksums must match between scalar and runtime-dispatched raster paths, which both prevents dead-code elimination and detects output changes.

The always-on guard validates schema, workload identity, required cases, finite ordered values, exact scalar/dispatch checksums, and a deliberately broad same-process dispatch sanity bound (runtime dispatch may not be more than 4× slower than scalar). This relative check detects catastrophic routing regressions without pretending heterogeneous CI machines share a universal speed floor.

## Controlled baseline workflow

Pin frequency/power policy, stop unrelated work, use the same ReleaseFast compiler and checkout, and preserve the same CPU allocation. Capture with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --capture baselines/my-host-v1.json
```

Commit reviewed baselines only when the machine is controlled. Compare later with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --compare baselines/my-host-v1.json
```

The comparison rejects unknown fields, malformed/non-finite data, schema or workload changes, metric/checksum changes, and incompatible architecture, OS, CPU-model, selected-affinity, or thread-cap fingerprints. Tolerances are recorded in the v1 baseline: the defaults permit a 20% median-rate decrease and a deliberately wider 100% p95 increase (short operations have outlier-sensitive tails). Re-run multiple times before accepting a baseline update: turbo, thermal state, NUMA placement, virtualization, kernel activity, and compiler changes all introduce noise. Controlled-hardware comparison is intentionally opt-in; ordinary CI runs only smoke/schema/correctness and the broad in-run guard.

## Thread limit

Every repository gate is invoked through `tools/limited-cpus.sh`. On Linux it intersects the caller's allowed affinity with `lscpu`'s online topology, chooses at most eight distinct physical cores with one logical CPU per core, applies `taskset`, exports `ZPU_MAX_THREADS` and the fingerprint, and passes Zig builds an explicit `-jN`. Fewer cores are supported; an empty intersection fails. This avoids assuming CPUs 0–7 and prevents Zig's worker pool from relying on affinity discovery alone.

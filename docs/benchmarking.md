# 2D performance methodology

`tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --json` runs the versioned `zpu-2d-v2-240x240-seed-151521030` workload. It measures clear, single-pixel draws, rectangle fill, transfer-style byte fill/copy, alpha blend, sprite draws, and complete deterministic 240×240 frames. Raster operations run with scalar, every CPU/OS-available vector backend, and normal runtime dispatch; byte transfers have no dispatch choice and run once. Results include MPix/s, modeled effective GiB/s, draws/s, FPS, per-operation p50/p95/p99 latency, iteration counts, and a fixed-output FNV-1a checksum.

Effective bytes are an operation model, not measured hardware memory bandwidth. Writes count four bytes/pixel; alpha blending counts four bytes read plus four written. Thus 128 8×8 sprites model exactly 65,536 bytes, while a frame models its 230,400-byte clear plus 131,072 bytes for 64 blended 16×16 sprites, or 361,472 bytes total. Unit tests freeze these hand-computed cases.

Each case starts from the same seeded bytes, executes an unmeasured warmup, resets, then takes 15 monotonic-clock samples with 100 operations per sample. Amortizing each sample limits scheduler-interruption distortion in tail percentiles; the reported rates use the median. A separate canonical iteration produces the checksum, so correctness identity never depends on sample count or timing. An independently implemented reference renderer and eight fixed checksums define the oracle; scalar, every available SIMD backend, and dispatch must all match it. ReleaseFast is the meaningful performance configuration. `--smoke` reduces timing to three samples of two operations for CI schema/correctness checks, not performance claims.

The always-on guard validates schema/workload/fingerprint, the exact unique canonical `(name, backend)` sequence for the host's available ISAs, field applicability, finite nonnegative rates, ordered nonzero percentiles, and oracle checksums. It compares every emitted SIMD/dispatch route with scalar using a deliberately broad 4× same-process sanity bound. Baseline comparison resolves unique keys rather than pairing positions, checks every applicable rate independently, and checks p50, p95, and p99 independently with ratio math that avoids overflow. There is no universal absolute speed floor.

## Controlled baseline workflow

Pin frequency/power policy, stop unrelated work, use the same ReleaseFast compiler and checkout, and preserve the same CPU allocation. Capture with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --capture baselines/my-host-v1.json
```

Commit reviewed baselines only when the machine is controlled. Compare later with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --compare baselines/my-host-v1.json
```

The comparison rejects unknown fields, malformed/non-finite data, schema or workload changes, metric/checksum changes, and incompatible architecture, OS, CPU model, selected affinity/topology, compiler, build mode, or thread-cap fingerprints. Tolerances are recorded in the v2 baseline: defaults permit a 20% rate decrease and a deliberately wider 150% latency-percentile increase. The latter is intentionally tail-oriented: p99 is the maximum of 15 samples and microsecond-scale operations remain sensitive to a single scheduler interruption even after 100-operation amortization. Re-run multiple times before accepting a baseline update: turbo, thermal state, NUMA placement, virtualization, kernel activity, and compiler changes all introduce noise. Controlled-hardware comparison is intentionally opt-in; ordinary CI runs smoke/schema/correctness and the broad in-run guard.

## Thread limit

Every runnable repository correctness, behavior, coverage, pixel, transfer, and benchmark gate is invoked through `tools/limited-cpus.sh`. On Linux it intersects the caller's allowed affinity with `lscpu`'s online topology, chooses at most eight distinct physical cores with one logical CPU per core, applies `taskset`, overwrites fingerprint variables from `lscpu`/sysfs, exports `ZPU_MAX_THREADS`, and inserts Zig's explicit `-jN` before any application `--` arguments. The benchmark independently verifies affinity from `/proc`, topology from sysfs, and CPU model from `/proc/cpuinfo`, so forged environment values cannot authorize a baseline.

Direct test-like build steps require the canonical marker, exact limited affinity, and cap or refuse with directions to the wrapper. Zig may still parse the build graph or compile prerequisites before a dependency refusal; no repository test workload executes, but only the wrapper's `-jN` controls build-runner job concurrency from process start. Therefore the wrapper—not a direct command—is the supported compile-and-run entry point. `test/observe_zig_threads.sh` uses fresh caches to sustain a real Zig build/test workload and samples `/proc` task counts and descendant affinity; it requires no process to exceed one coordinator plus eight workers. Fewer cores are supported and an empty intersection fails.

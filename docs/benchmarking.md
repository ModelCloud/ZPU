# 2D performance methodology

`tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --json` runs the versioned `zpu-2d-kernels-v4-240x240-seed-151521030` workload. It measures clear, pixel writes, deliberately clipped rectangles, straight-alpha source-over blends, clipped RGBA sprite draws, complete deterministic 240×240 frames, and Vulkan host-memory fill/copy operations. Constant-color spans and per-pixel RGBA sprite spans use the selected scalar or vector backend. Raster operations run with scalar, every CPU/OS-available vector backend, and normal runtime dispatch; Vulkan host-memory operations have no raster dispatch choice and run once. Results include pixels/s (serialized as `mpix_s`), bytes/s and modeled GiB/s, draws/s, frames/s (`fps`), per-operation p50/p95/p99 latency, iteration counts, and a fixed-output FNV-1a checksum.

ZPU exposes one unified host-visible, host-coherent, non-device-local heap. The `vulkan_host_memory_fill` and `vulkan_host_memory_copy` rows exercise the same CPU helpers used when validated `vkCmdFillBuffer` and `vkCmdCopyBuffer` commands execute. They preserve Vulkan API command semantics, but are host-memory operations—not discrete-VRAM uploads or GPU-transfer measurements.

Effective bytes are an operation model, not measured hardware memory bandwidth. Writes count four bytes/pixel; alpha blending counts four bytes read plus four written. The clipped-rectangle case counts its exact 12,060 in-bounds pixels (48,240 bytes). The sprite rate reports complete draw calls while its byte model counts the submitted 128×8×8 pixels (65,536 bytes), including clipped fragments; a frame models its 230,400-byte clear plus 131,072 bytes for 64 blended 16×16 rectangles, or 361,472 bytes total. Unit tests freeze these hand-computed cases.

Each case starts from the same seeded bytes, executes an unmeasured warmup, resets, then takes 15 monotonic-clock samples with 100 operations per sample. Amortizing each sample limits scheduler-interruption distortion in tail percentiles; the reported rates use the median. A separate canonical iteration produces the checksum, so correctness identity never depends on sample count or timing. An independently implemented reference renderer and eight fixed checksums define the oracle; scalar, every available SIMD backend, and dispatch must all match it. ReleaseFast is the meaningful performance configuration. `--smoke` reduces timing to three samples of two operations for CI schema/correctness checks, not performance claims.

Optional `avx2` raster rows are emitted only when the runtime CPUID/XGETBV checks report that the linked x86-64-v3 eight-lane kernel tier is supported; hosts without AVX2 intentionally have no AVX2 execution to verify, and a result without those rows makes no AVX2 correctness or performance claim. AVX-512 rows are never emitted: that tier is excluded pending controlled frame-time-tail evidence. The ISA tiers themselves are enforced by a build/code-generation boundary described in [design/isa-tiers.md](../design/isa-tiers.md) and verified by `zig build isa-gate`.

The always-on guard validates schema/workload/fingerprint, the exact unique canonical `(name, backend)` sequence for the host's available ISAs, field applicability, finite nonnegative rates, ordered nonzero percentiles, and oracle checksums. Full runs compare every emitted SIMD/dispatch route with scalar using a deliberately broad 16× catastrophic-route sanity bound; this avoids turning ordinary clock noise into a failure while still catching a disabled, no-op, or catastrophically wrong route. Smoke runs remain correctness-only because their three samples of two operations are too short to support even that broad performance assertion; the full-run relative check has direct regression coverage. Baseline comparison resolves unique keys rather than pairing positions, checks every applicable rate independently, and checks p50, p95, and p99 independently with ratio math that avoids overflow. There is no universal absolute speed floor.

## Controlled baseline workflow

Pin frequency/power policy, stop unrelated work, use the same ReleaseFast compiler and checkout, and preserve the same CPU allocation. Capture with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --capture baselines/my-host-v1.json
```

Commit reviewed baselines only when the machine is controlled. Compare later with:

```sh
tools/limited-cpus.sh zig build benchmark -Doptimize=ReleaseFast -- --compare baselines/my-host-v1.json
```

The comparison rejects unknown fields, malformed/non-finite data, schema or workload changes, metric/checksum changes, and incompatible architecture, OS, CPU model, selected affinity/topology, compiler, build mode, or thread-cap fingerprints. The current code owns bounded tolerances: a 20% rate decrease and a deliberately wider 150% latency-percentile increase. Baseline JSON tolerance fields must equal those policy constants and cannot weaken them. The latter is intentionally tail-oriented: p99 is the maximum of 15 samples and microsecond-scale operations remain sensitive to a single scheduler interruption even after 100-operation amortization. Re-run multiple times before accepting a baseline update: turbo, thermal state, NUMA placement, virtualization, kernel activity, and compiler changes all introduce noise. Controlled-hardware comparison is intentionally opt-in; ordinary CI runs smoke/schema/correctness and the broad in-run guard.

Append controlled results with `tools/benchmark_history.py`; it refuses dirty worktrees, abbreviated or mismatched commits, untrusted fingerprints, malformed or non-oracle reports, duplicate source commits, and results outside the physical-core gate. Entries are append-only and name the exact benchmarked source commit; the commit containing the append follows it.

## Four-worker CPU fanout

`tools/cpu-fanout.sh` partitions this host into exactly four concurrent experiment or optimization workers without letting two workers share a physical core. It derives the effective allowed cpuset at run time from the caller's `sched_getaffinity` mask (`taskset -pc $$`) intersected with the cgroup cpuset described below, so LXD and cgroup restrictions narrow the partition instead of being ignored. It then reads `lscpu -p=CPU,CORE,SOCKET,ONLINE`, drops offline CPUs, groups the remaining logical CPUs by physical `(socket, core)`, and keeps the lowest logical CPU of each physical core. SMT siblings are therefore never split across workers: a duplicate thread is left out entirely rather than handed to a second worker.

Every topology row must carry exactly four fields: a numeric CPU, core, and socket id and an `ONLINE` flag of exactly `Y` or `N`. A malformed row is refused by position and value rather than coerced to CPU/core/socket `0`, which would otherwise fabricate a physical core that does not exist. A failing live `lscpu` becomes a fanout refusal naming the command.

### cgroup cpuset scope

The cgroup lookup targets the **unified cgroup v2 hierarchy**. The tool reads the process's own cgroup from `/proc/self/cgroup`, then walks from that directory toward `/sys/fs/cgroup` and uses the nearest readable `cpuset.cpus.effective`, continuing toward a readable ancestor when a nearer existing file cannot be opened, so a delegated or nested cgroup is honored rather than only the root. cgroup v1 is deliberately not consulted: a v1 cpuset is already reflected in the kernel affinity mask the tool starts from, so reading the v1 hierarchy would apply the same restriction twice.

A `cpuset.cpus.effective` that is readable but **empty** grants no CPU. It takes part in the intersection like any other value, so the run is refused with an empty-effective-cpuset diagnostic instead of being silently ignored and widened back to the bare process affinity. A file that does not exist or cannot be read is a different case: there is no cgroup restriction to apply, and the process affinity stands on its own.

The surviving representatives are ordered by socket then core, so each worker receives a topologically adjacent run of cores. The partition uses `floor(physical_core_count / 4)` cores per worker; surplus cores beyond `4 x floor(physical_core_count / 4)` and every duplicate SMT thread stay unused. Non-contiguous CPU ids are supported throughout — nothing assumes `0..n-1`.

Inspect the partition:

```sh
tools/cpu-fanout.sh --plan
```

It prints `allowed_cpus`, `physical_cores`, `workers`, `cores_per_worker`, `workerN`, `workerN_cores` (the `socket:core` identity behind each CPU), `unused`, and `thread_cap`.

Run one worker, or fan a command out to all four concurrently:

```sh
tools/cpu-fanout.sh --worker 0 -- zig build benchmark -Doptimize=ReleaseFast -- --json
tools/cpu-fanout.sh --all -- zig build benchmark -Doptimize=ReleaseFast -- --json
```

Exactly one of `--plan`, `--worker`, and `--all` may be given; combining or repeating them is refused rather than resolved last-one-wins. Add `--dry-run` to print the exact command without running it — its arguments are shell-quoted, so the printed line can be pasted and run verbatim. Each worker is launched as `taskset -c <group> tools/limited-cpus.sh <command>` with `ZPU_MAX_THREADS` set to the worker's core count, so the existing limited-cpus safety contract still owns the canonical marker, the selection, and the cap that `tools/require-limited.sh` verifies. Because that contract caps threads at eight, a host wide enough for groups larger than eight keeps the full group affinity but reports a thread cap of eight; the wrapper then narrows the selection to eight cores and the gate stays consistent. Each command additionally sees `ZPU_FANOUT_WORKER`, `ZPU_FANOUT_WORKERS`, and `ZPU_FANOUT_GROUP_CPUS`. `ZPU_FANOUT_GROUP_CPUS` is the planned group before the limiter's at-most-eight-core cap; `ZPU_SELECTED_CPUS` and the process affinity are the actual CPUs after that cap. `--all` exits non-zero if any worker fails and names the failing worker.

The tool refuses, with a diagnostic naming the effective cpuset, when fewer than four usable physical cores survive or the effective cpuset is empty (exit 69), when the topology source is unreadable, malformed, or has no CPU rows (exit 66), when a CPU list is malformed, a worker index is outside `0..3`, or modes conflict (exit 64), and when a partition is not four equal-size, pairwise-disjoint groups (exit 70).

### Comparability rules

Fanout is a throughput tool for running four independent experiments at once. It is not a way to produce comparable performance numbers.

* A fanout result is comparable only with another result from the **same worker index on the same host, same partition, and same `cores_per_worker`**. `--plan` output is the record of that partition; capture it alongside the result.
* Never compare a fanout result with a `tools/limited-cpus.sh` result, or a worker-0 result with a worker-3 result. Different physical cores mean different cache slices, different memory-controller distance, and on multi-socket hosts different NUMA nodes.
* Never commit a fanout result as a controlled baseline. Baselines under `## Controlled baseline workflow` require a quiet machine; three sibling workers saturating the rest of the package is the opposite of that. Baseline capture and comparison stay on `tools/limited-cpus.sh`.
* `tools/benchmark_history.py` remains the only path for appending controlled results, and fanout runs are not eligible for it.
* Use fanout for parameter sweeps, A/B search, and optimization iteration where relative ranking within one worker matters and absolute rates do not.

`test/cpu_fanout.sh` proves the partition against checked-in `lscpu` fixtures covering non-contiguous ids, offline CPUs, SMT duplicates, surplus cores, restricted cgroup cpusets, a readable-but-empty cpuset, malformed topology fields, the four-core minimum, the eight-thread safety cap, pairwise disjointness, four equal groups, mode conflicts, and every failure diagnostic.

It also proves the launch path for real, not only through `--dry-run`: it fans `tools/require-limited.sh` itself out to all four workers on this host's live partition and asserts that each worker satisfies the gate — canonical `physical-core-v1` marker, a thread cap equal to the partition width, a selected CPU list equal to the actual process affinity, and four equal-size pairwise-disjoint affinities. Those assertions hold for any supported host cpuset; when the invoking allocation yields fewer than four usable physical cores the suite fails clearly because the mandatory live proof cannot run.

`test/limited_cpus_topology.sh` covers the fingerprint source in `tools/limited-cpus.sh`: a live run must reproduce each selected CPU's sysfs `physical_package_id`/`core_id`, and a run driven by `ZPU_TEST_LSCPU_FILE` must keep the fixture's socket/core values. Its fixture CPU ids come from the invoking affinity, so the limiter's `taskset` call stays inside the allocation.

Both scripts run every command inside the affinity they inherit, so nothing escapes the limiter that invoked them, and `zig build test` runs both behind `tools/require-limited.sh`.

## Thread limit

Every runnable repository correctness, behavior, coverage, pixel, transfer, and benchmark gate is invoked through `tools/limited-cpus.sh`. On Linux it intersects the caller's allowed affinity with `lscpu`'s online topology, chooses at most eight distinct physical cores with one logical CPU per core, applies `taskset`, overwrites fingerprint variables from `lscpu`/sysfs, exports `ZPU_MAX_THREADS`, and inserts Zig's explicit `-jN` before any application `--` arguments. The benchmark independently verifies affinity from `/proc`, topology from sysfs, and CPU model from `/proc/cpuinfo`, so forged environment values cannot authorize a baseline. The exported `ZPU_TOPOLOGY` fingerprint therefore names each selected CPU's kernel `physical_package_id`/`core_id` read from sysfs; `lscpu`'s `CORE` column is a dense renumbering of those ids and is used only for grouping and for fixture-driven tests.

Direct test-like build steps require the canonical marker, exact limited affinity, and cap or refuse with directions to the wrapper. Zig may still parse the build graph or compile prerequisites before a dependency refusal; no repository test workload executes, but only the wrapper's `-jN` controls build-runner job concurrency from process start. Therefore the wrapper—not a direct command—is the supported compile-and-run entry point. `test/observe_zig_threads.sh` uses fresh caches to sustain a real Zig build/test workload and samples `/proc` task counts and descendant affinity; it requires no process to exceed one coordinator plus eight workers. Fewer cores are supported and an empty intersection fails.

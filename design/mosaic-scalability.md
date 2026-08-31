# Mosaic scalability contract

Mosaic must scale from one to several physical cores inside a single NUMA
domain before it attempts cross-NUMA scheduling. More cores are not useful if
they only add wakeups, barriers, cache-line ownership transfers, or an
unbalanced tail to one large raster job.

This document describes the scheduling boundary that makes scaling a property
of the renderer architecture rather than a property of an individual SIMD
kernel. It is the companion to [the Mosaic renderer design](mosaic-renderer.md).

## Current measurement boundary

The Vulkan benchmark still exercises Mosaic's prepared scalar batch bridge;
it does not yet lower every Vulkan draw into the physical
`LOCAL`/`MACRO`/`GLOBAL` packet executor. A separate
`benchmark-mosaic-scaling` gate now measures the physical scalar executor
directly. It prepares and validates one immutable pass plan, constructs a
tile-local index for `LOCAL` packets without expanding `MACRO` or `GLOBAL`
commands, and excludes planning and thread creation from frame timing.

The current host topology used for the 1/2/3/4-core sweep has one NUMA node
and one package. The selected CPUs are consequently on one coherent NUMA
fabric. They are not all in one cache domain: two selected workers share an
LLC group, while the remaining workers are in neighboring LLC groups. This
distinguishes the two questions that benchmarks must report:

1. does work scale within a NUMA memory domain?
2. does work remain cache-local within each LLC domain?

Cross-NUMA optimization is deliberately out of scope for the first Mosaic
scaling gate. A machine with multiple NUMA nodes must select and report one
render domain for this gate; a later domain scheduler may add remote work
stealing.

## Implemented scalar scheduling checkpoint

The scalar physical-packet path now has this execution shape:

```text
admitted immutable pass plan
        ↓
Morton-ordered supertiles partitioned into per-core queues
        ↓
persistent workers pinned to reported CPU / NUMA / LLC identities
        ↓
own queue → same-LLC steal → same-NUMA steal
        ↓
one completion barrier per pass
```

Each plan owns stable packet slices, validated prepared-cluster ranges,
tile-local `LOCAL` packet indices, compact `MACRO`/`GLOBAL` streams, load
operation, and setup accounting. Queue cursors and worker results occupy
separate cache lines. A plan containing workers from different NUMA nodes is
rejected; cross-NUMA stealing does not exist.

The first 800×600 ReleaseFast median sweep produced the following exact-output
checkpoint. These are five-sample scheduler medians, not p95/p99 release
claims:

| Workload | 1 core | 4 cores, one LLC | Speedup | 4 cores, three LLCs | Speedup |
| --- | ---: | ---: | ---: | ---: | ---: |
| Terminal glyph grid | 2,127 µs | 575 µs | 3.70× | 984 µs | 2.17× |
| Desktop UI | 1,719 µs | 475 µs | 3.62× | 866 µs | 1.98× |
| Complex 3D demo | 3,748 µs | 942 µs | 3.98× | 1,350 µs | 2.77× |

Color, depth, visibility, counters, and checksums match the serial physical
packet oracle for every 1/2/3/4-core run. The one-LLC result demonstrates that
the queue and completion design can scale approximately linearly. The
multi-LLC result deliberately remains visible: cache-domain placement and
same-NUMA memory traffic are the next topology costs, rather than a reason to
hide a fixed worker ceiling.

## Non-negotiable invariants

For a selected set of physical CPUs:

- the render thread and all workers in an intra-NUMA run belong to the same
  selected NUMA node;
- each worker has a stable CPU and LLC-domain identity for the duration of a
  pass;
- no hot-loop operation increments a process-global work counter shared by
  every worker;
- no worker waits for the whole frame when only its spatial dependency is
  incomplete;
- a prepared cluster is produced once and can be consumed by many spatial
  work items;
- independent tiles may execute concurrently, while each tile's
  `OrderKey(submission, command, primitive_group)` order remains deterministic;
- a small workload can stay serial when measured queue overhead exceeds the
  available work, but this choice is based on estimated work, not a permanent
  two-worker ceiling.

## Work graph

Mosaic should schedule bounded spatial work, not whole draws and not one
record per tile for broad commands:

```text
frame/pass plan
  ├─ hierarchy work items
  ├─ macrobin count/write work items
  ├─ prepared-cluster slots       (one triangle setup per cluster)
  └─ raster supertile/tile-group work items
       ├─ local packet range
       ├─ clipped macro packet range
       └─ references to global packet epochs
```

The dependency graph is expressed with per-item readiness counters. A raster
group becomes runnable when its packet ranges and prepared-cluster slots are
ready; it does not wait for unrelated groups in the pass. `GLOBAL` commands
remain pass-level references and are split into bounded spatial execution
items, never copied into every tile header.

## Topology-aware scheduler

The first implementation should use a two-level scheduler:

```text
same NUMA node
  ├─ LLC domain A: local deque + worker-local arena
  ├─ LLC domain B: local deque + worker-local arena
  └─ LLC domain C: local deque + worker-local arena
```

Steal order is:

1. the worker's own deque and arena;
2. another worker in the same LLC domain;
3. a neighboring LLC domain in the same NUMA node;
4. another NUMA node only in a future cross-domain mode.

Deque operations move batches of spatial work. They must not publish one
atomic operation per primitive-to-tile relationship. Counting and packet
construction use worker-local arenas followed by deterministic prefix sums and
range writes. This keeps the synchronization cost proportional to work-item
waves instead of packet fanout.

Spatial assignment should use Morton or supertile order so adjacent work tends
to remain in the same LLC domain. A work item must have a bounded cost estimate
and a split point. A giant macro/global range is therefore divisible, while a
tiny triangle cluster is not fragmented into queue overhead.

## Frame phases and synchronization

The intended execution shape is:

```text
immutable pass plan
       ↓
parallel hierarchy / macrobin construction
       ↓
parallel prepared-cluster production
       ↓
ready spatial packet groups
       ↓
LLC-local raster deques
       ↓
ordered tile commit / pass completion
```

There may be narrow phase boundaries where ordering requires one, but a single
global `prepare complete` or `raster complete` barrier must not surround every
draw. In particular, preparation should publish a slot as soon as its cluster
is complete, allowing ready tile groups to run while other clusters are still
being prepared.

All frame-plan memory is frame-owned and immutable after publication. Mutable
state is worker-local wherever possible. Shared state is restricted to
read-mostly plan data, bounded readiness counters, per-domain queue metadata,
and final statistics. Cache-line ownership for queue cursors, counters, and
completion flags must be explicit and padded where necessary.

## Required instrumentation

Before SIMD work, every benchmark run must report:

- selected CPU, core, package, NUMA node, and LLC domain for each worker;
- hierarchy, macrobin, preparation, packet, and raster work-item counts;
- work items completed by each worker and each LLC domain;
- local deque hits, same-LLC steals, same-NUMA steals, and cross-NUMA steals;
- queue wait, dependency wait, preparation, raster, and tail time;
- largest work item and the imbalance between the busiest and least-busy worker;
- p50, p95, p99, worst frame, and parallel efficiency;
- cache misses and migrations when the platform exposes them;
- remote NUMA traffic when the platform exposes it.

The key measurements are:

```text
speedup(N)   = T(1) / T(N)
efficiency(N) = T(1) / (N * T(N))
```

The 3/4-core gate is only valid when all selected CPUs are in the same NUMA
domain. A run with mixed NUMA placement is a topology experiment, not a
failure of the intra-NUMA gate.

## Hard gates

The scalability work proceeds in this order:

### Gate A: topology and accounting

Run 1, 2, 3, and 4 physical-core jobs. Verify affinity, NUMA placement, LLC
groups, identical output checksums, and complete per-worker accounting. No
speedup claim is valid without this report.

### Gate B: scalar physical packet execution

Execute `LOCAL`/`MACRO`/`GLOBAL` packets through the scalar path. Require:

```text
physical packet execution
  == expanded tile packet execution
  == cpu_cube scalar reference
```

Run the serial executor and the parallel executor on the same immutable plan;
compare color, depth, counters, and visible primitive results.

### Gate C: same-NUMA scaling

Use representative terminal/UI, 3D demo, and mixed-overdraw workloads. Require
no correctness mismatch, no fixed worker-role ceiling, and improving p95/p99
time from 1 to 2 to 3 to 4 cores. The target is measured efficiency, not a
claim of perfect linear scaling; any flattening must be attributable to a
reported serial phase, queue wait, cache miss, or bandwidth limit.

### Gate D: only then optimize kernels

Portable primitive SIMD, AVX2, pixel SIMD, visibility buffering, and startup
autotuning come after Gates A-C. Kernel speedups cannot repair a scheduler that
still serializes preparation or funnels all workers through one queue.

## Implementation sequence

1. Add topology identity and per-worker/per-LLC accounting to the benchmark
   report.
2. Introduce immutable frame/pass plans and bounded spatial work-item types.
3. Replace the whole-batch dispatch barrier with persistent per-core queues,
   same-LLC/same-NUMA stealing, and one pass completion barrier. **Done for the
   scalar physical-packet executor.**
4. Make physical packet execution match the current expanded packet and
   `cpu_cube` references.
5. Route a narrow eligible Vulkan draw subset through the new scheduler;
   preserve the strict conventional fallback for unsupported semantics.
6. Tune batch size and scheduler geometry from measured p95/p99 and cache
   behavior, then add SIMD.

This order keeps Mosaic's public Vulkan ABI unchanged while making scalability
an architectural guarantee of the existing path rather than a new private fast
ABI.

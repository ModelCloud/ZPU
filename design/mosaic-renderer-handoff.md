<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Mosaic renderer continuation handoff

> **Current status:** Mosaic is the canonical name for this pipeline. PR #84
> has been synchronized with `main` at `9785b9a`, and the Phase-9 scalar packet
> differential gate exists. Older sections below remain useful as architectural
> history, but any unresolved-item list must be read together with this status
> and the current code. The next milestone is broad scalar semantic parity,
> physical packet execution, and then the first narrow Vulkan Mosaic path—not
> SIMD.

This document is the continuation record for PR #84. It is intended for another engineering agent to pick up the work without reconstructing the design history from the commit stream.

It records the design rationale, current invariants, known defects, implementation order, and validation targets. It is not a transcript of internal reasoning; it is the engineering decision record needed to continue the work safely.

## Current branch / PR

PR: `#84`

Branch: `perf/host-tuned-tiles`

Current PR title:

```text
WIP: feat(experimental): introduce the Mosaic render pipeline
```

The branch now implements planning, prepared primitives, and a scalar packet
differential gate. `src/vulkan/cpu_cube.zig` remains the production Vulkan
raster executor until Mosaic reaches broad scalar semantic parity.

## Product goal

The goal is a CPU-native graphics backend that can serve real game-engine workloads while scaling to extremely large *logical source geometry* counts.

The intended interpretation of the trillion-scale target is:

```text
trillions of logical source triangles represented by hierarchy
                        !=
trillions of individually visited Vulkan draw calls / leaf clusters
```

The only credible way to reach that scale on CPUs is to reject geometry multiplicatively before triangle setup and raster work.

The primary throughput metric should therefore be:

```text
logical source triangles rejected per hierarchy/HZB test
```

not only:

```text
triangles rasterized per second
```

## Target architecture

```text
Vulkan eligible path ---------------------------+
                                                 |
Native Mosaic path -----------------------------+
                                                 v
                                      resource-aware pass DAG
                                                 |
                                                 v
                                  instance / cluster hierarchy
                              frustum + cone + LOD rejection
                                                 |
                                                 v
                                    valid HZB visibility source
                                                 |
                                                 v
                                            macrobins
                                                 |
                                                 v
                                   visible leaf-cluster setup
                                  triangle preparation once
                                                 |
                                                 v
                                prepared primitive subsets / masks
                                                 |
                     +---------------------------+---------------------------+
                     |                                                       |
                     v                                                       v
              primitive-SIMD                                          pixel-SIMD
             tiny primitives                                      normal/large primitives
                     |                                                       |
                     +---------------------------+---------------------------+
                                                 v
                                 eligible opaque visibility buffer
                                                 |
                                                 v
                                    2x2 quad/material shading
                                                 |
                                                 v
                               strict fallback for ineligible Vulkan work
```

The current branch has a prepared scalar packet executor with differential
coverage against `cpu_cube`. Compact physical packet streams are planned but
not yet the Vulkan execution representation. A narrow private Vulkan bridge
now routes eligible opaque `cpu_cube_v1` draw runs through the prepared scalar
Mosaic executor; general Vulkan draw lowering remains future work.

## Core design decisions and rationale

### 1. Scheduler tiles and SIMD microtiles are separate

Do not couple screen scheduling granularity to vector width.

Scheduler tiles solve:

- CPU worker ownership;
- cache locality;
- binning fanout;
- work stealing granularity;
- per-tile packet metadata.

Microtiles solve:

- SIMD lane utilization;
- coverage stepping;
- inner depth/raster loop shape.

Current candidate defaults:

```text
portable vector -> scheduler 16x16, micro 4x2, 4 lanes
AVX2            -> scheduler 32x32, micro 8x4, 8 lanes
future AVX-512  -> scheduler 64x16, micro 16x4, 16 lanes
```

These are candidate defaults, not measured optima.

### 2. Host ISA capability is not executable-kernel capability

There must be two concepts:

```text
host_class       = what CPU + OS vector state can support
executable_class = what kernel objects this artifact actually contains
```

CPU feature bits alone must never enable an executable backend.

This matters especially because the current AVX2 boundary in `src/simd/dispatch.zig` proves availability of the existing 2D/surface eight-lane kernels, not yet a future Mosaic triangle AVX2 implementation.

Long-term, compiled capability should become granular enough to distinguish at least:

```text
surface_avx2
mosaic_primitive_avx2
mosaic_pixel_avx2
surface_avx512
mosaic_primitive_avx512
mosaic_pixel_avx512
```

Do not claim a 3D raster executable class merely because unrelated AVX2 surface kernels are linked.

### 3. HZB must always be conservative

HZB = Hierarchical Z-Buffer.

The hierarchy is built from repeated 2x2 reductions.

For normal-Z LESS-family tests:

```text
coarse value = maximum/farthest depth
```

For reverse-Z GREATER-family tests:

```text
coarse value = minimum/farthest-in-compare-space depth
```

Correct rejection conditions for cluster best possible depth `z_best` and aggregate HZB value `z_hzb`:

```text
LESS          -> occluded when z_best >= z_hzb
LESS_OR_EQUAL -> occluded when z_best >  z_hzb
GREATER       -> occluded when z_best <= z_hzb
GREATER_EQUAL -> occluded when z_best <  z_hzb
```

### 4. HZB mip coordinate mapping uses exact powers of two

Never infer a level footprint using:

```text
ceil(base_dimension / mip_dimension)
```

That is wrong for odd dimensions.

Each level `L` represents base footprints of `2^L`, with only the final block truncated.

Therefore coordinate mapping is:

```text
first_cell = min_pixel >> L
last_cell  = (max_pixel - 1) >> L
```

The current `footprint_shift` design is correct and should be retained.

### 5. HZB provenance is part of correctness

An HZB cannot be treated as an arbitrary depth image.

Supported conceptual sources:

```text
same_frame_completed
    completed earlier occluder work

depth_prepass
    completed dedicated prepass

previous_frame_conservative
    accepted only with explicit conservative reprojection validity
```

A stale previous-frame depth buffer must not be accepted by default.

### 6. Cluster hierarchy is mandatory for trillion-scale logical geometry

A flat list of 128-triangle clusters does not solve the scale problem.

Example:

```text
1e12 logical triangles / 128 triangles per cluster
= 7.8125 billion leaf clusters
```

Walking all of them is still impossible.

The hierarchy must allow one parent test to reject thousands or millions of descendant triangles.

Future hierarchy node data should eventually include:

```text
object-space bounds
screen-space/conservative projected bounds
best depth bound
LOD geometric error
normal/backface cone
first child / child count
first leaf / leaf count
instance identity
```

### 7. Macrobins are a real hierarchy level

The intended path is:

```text
visible leaves
    -> macrobins
        -> scheduler tiles
```

Tile construction must consume macrobin references. It must not rescan the complete visible cluster list.

Current implementation now follows this rule.

### 8. Per-tile streams carry cluster/range packets, not one packet per triangle

A packet represents coarse work such as:

```text
order key
ordering class
draw id
cluster id
material id
triangle range
prepared range reference in future
raster path
extent class
```

Do not create one queue record per triangle.

### 9. Triangle setup happens once after leaf visibility

The intended boundary is:

```text
hierarchy/HZB reject
       -> visible leaf cluster
           -> vertex/triangle preparation exactly once
               -> prepared primitive subsets / masks
                   -> tile execution
```

Never redo full vertex or triangle setup independently for every tile touched by a cluster.

### 10. Tiny and large primitive execution are different problems

For tiny/subpixel primitives, vectorizing across neighboring pixels wastes lanes.

Target split:

```text
tiny primitive batches -> SIMD across primitives
normal/large triangles -> SIMD across pixels
```

The current `estimated_covered_samples` field is only a temporary classifier input. The permanent classifier belongs after triangle setup and should operate on prepared primitive batches.

### 11. Visibility-buffer rendering is an eligible opaque fast path only

A visibility buffer must not silently replace all Vulkan fragment semantics.

Future fast-path eligibility must conservatively exclude or separately implement cases involving:

```text
blending
fragment storage writes
atomics
fragment depth output
discard / complex alpha testing
sample shading / complex MSAA
framebuffer feedback / interlocks
stencil cases not fully modeled
observable query/statistics behavior
```

Everything else retains a strict conventional path.

### 12. Preserve p99 frame-time quality over peak FPS

Every optimization should be measured by:

```text
p50 / p95 / p99 / worst frame time
missed presentation deadlines
worker imbalance
cache misses / memory bandwidth
planning bytes per frame
packet amplification
```

Peak triangles/sec alone is not a sufficient success metric.

## Current code map

### `src/vulkan/tile_profile.zig`

Contains:

- CPU capability model;
- compiled-kernel capability model;
- scheduler/microtile candidate policy;
- CPUID/XGETBV detection.

### `src/vulkan/cpu_locality.zig`

Contains:

- CPU/NUMA discovery;
- capacity ranking;
- CPU-role pinning;
- selected tile profile initialization.

Raster worker IDs now map across all selected CPUs; there is no five-role ceiling.
Topology-local persistent queues and stealing remain future execution work.

### `src/render/pass_dag.zig`

Contains:

- bounded pass DAG;
- CSR adjacency construction;
- deterministic sequence-keyed ready heap;
- initial resource-use vocabulary.

Complexity target is now approximately:

```text
O(V + E + V log V)
```

The DAG is not yet a complete Vulkan hazard graph.

### `src/render/mosaic_pipeline.zig`

Contains:

- `Cluster` and `ClusterNode`;
- ordering keys/classes;
- depth compare convention;
- HZB construction and queries;
- visibility-buffer storage type;
- hierarchy culling;
- macrobins;
- macrobin-driven tile packets;
- raster-path classifier.

### `src/render/mosaic_backend.zig`

Contains:

- experimental submission structure;
- scratch arenas;
- requirements helper;
- end-to-end planning function:

```text
depth
 -> HZB
 -> hierarchy/leaf visibility
 -> macrobins
 -> ordered tile packets
```

### `design/mosaic-renderer.md`

Main architectural design document.

## Historical review findings and current disposition

### Completed: artifact capability isolation

`cpu_locality.zig` previously imported:

```text
../simd/dispatch.zig
```

only to read `eight_lane_boundary`. It now consumes the small artifact
capability layer in `src/vulkan/build_caps.zig`; host capability and linked
Mosaic kernels are separate facts.

That dispatcher imports `zpu_config`.

Several direct build roots historically compile the 3D/Vulkan path without explicitly injecting `zpu_config` into the root module. This makes the dependency fragile and may fail once CI reaches Zig compilation.

Implemented shape:

Create a very small build-capability module that owns artifact-level compiled-kernel facts, for example:

```text
src/vulkan/build_caps.zig
```

or pass a `CompiledKernels` value from a root that already owns build configuration.

Do not make CPU topology code import the complete SIMD dispatcher.

Also separate surface AVX2 capability from future Mosaic-raster AVX2 capability.

### Completed: hierarchy admission validation

Mosaic validates hierarchy topology, ranges, parentage, conservative bounds,
and depth invariants before traversal. Validation can be cached by hierarchy
revision.

The admission validator checks:

```text
root indices in range
child ranges in range
leaf ranges in range
no self-cycle
no ancestor cycle
no duplicate parent unless DAG semantics intentionally supported
internal node cannot simultaneously contain direct leaf range unless explicitly allowed
parent bounds conservatively contain descendants
parent depth bound conservatively contains descendant best-depth bounds
```

For LESS-family depth:

```text
parent.best_depth <= every descendant best_depth
```

For GREATER-family depth:

```text
parent.best_depth >= every descendant best_depth
```

If this invariant is violated, an HZB test may reject a parent while a visible child actually exists.

Validation runs at admission and can be reused while the hierarchy revision
and slice identities remain unchanged.

Use DFS coloring or an iterative equivalent:

```text
0 = unseen
1 = visiting
2 = complete
```

A `visiting -> visiting` edge is a cycle.

## High-priority design corrections

### 1. Completed: extent classification uses full cluster fanout

The obsolete implementation calculated `ExtentClass` after clipping a cluster
to one macrobin. Mosaic now classifies the complete cluster fanout first.

With default geometry:

```text
macro = 256x256
tile  = 32x32
```

one macrobin contains at most:

```text
8 * 8 = 64 scheduler tiles
```

Therefore a threshold such as `>256 -> global` can never fire after macro clipping.

Correct approach:

```text
full cluster bounds
   -> full scheduler-tile fanout
       -> classify LOCAL / MACRO / GLOBAL once
           -> macrobin subdivision
```

The classification is retained in the physical packet representation before
macrobin clipping.

### 2. Interim complete: insertion sort replaced by O(n log n) heapsort

Current tile streams use sub-quadratic heapsort. Stable ordered construction
remains the preferred final representation when planning is parallelized.

Correctness is good, scalability is not.

Preferred architecture:

1. establish global strict `OrderKey` order once;
2. walk clusters in that order;
3. count/prefix/write bins stably;
4. tile streams are already ordered by construction.

If parallel construction later breaks order, use:

```text
radix sort by fixed-width OrderKey
or
stable merge of already sorted producer runs
```

Do not use insertion sort on very hot tiles.

### 3. Completed: remove the five-raster-worker ceiling

The obsolete role enum had only:

```text
raster_1 ... raster_5
```

and `pinRasterWorker()` cycled those roles. Worker-index pinning now follows:

```text
if selected_count <= 1:
    worker -> selected_cpus[0]
else:
    worker -> selected_cpus[1 + worker_index % (selected_count - 1)]
```

Later upgrade this to per-LLC/CCD worker groups rather than flat modulo assignment.

### 4. Move raster-path classification after preparation

Current `Cluster.estimated_covered_samples` is conceptually post-setup data stored in a pre-setup structure.

Introduce something like:

```zig
const PreparedPrimitiveBatch = struct {
    first_primitive: u32,
    primitive_count: u16,
    estimated_covered_samples: u32,
    raster_path: RasterPath,
    // prepared edge/depth/varying storage reference
};
```

A cluster may produce multiple batches with different paths.

### 5. Completed: expose checked tile-packet capacity requirements

`mosaic_backend.requirements()` directly returns:

```text
tile_packets_upper_bound
```

Use checked math.

A safe current bound with exact macro/tile divisibility is roughly:

```text
macro_refs_upper_bound * tiles_per_macro
```

but the caller should not have to duplicate internal formulas.

### 6. Completed: alias HZB level 0 instead of copying it

The obsolete HZB storage duplicated full-resolution depth.

At 4K D32:

```text
base depth ~= 31.6 MiB
full copied pyramid ~= 42 MiB
```

At 8K D32:

```text
base depth ~= 126.6 MiB
full copied pyramid ~= 169 MiB
```

Implemented representation:

```zig
const Hzb = struct {
    base_depth: []const f32,
    coarse_values: []f32,
    levels: []HzbLevel,
    ...
};
```

Level 0 aliases `base_depth`.

Scratch only stores level 1+.

### 7. Completed: reject non-finite HZB source depth

Cluster `best_depth` already fails open when non-finite.

HZB construction rejects non-finite source depth before the hierarchy can use
it for correctness-sensitive rejection.

Optimized-path contract:

```text
source depth must be finite
```


### 8. Completed: experimental APIs are explicitly namespaced

The API now exports the redesign under:

```zig
pub const experimental = struct {
    pub const mosaic = struct {
        pub const pass_dag = ...;
        pub const pipeline = ...;
        pub const backend = ...;
    };
};
```

This namespace remains intentionally unstable until Vulkan execution and
hazard contracts are complete.

### 9. Inclusive depth compare and packet reordering

For:

```text
LESS_EQUAL
GREATER_EQUAL
```

equal-depth fragments can change the final winning primitive if packets are reordered.

Do not mark such work `depth_reorderable` unless visibility resolution includes a deterministic original-order tie-break.

A future visibility record may need:

```text
depth
primitive/material identity
order key / compact order token
```

### 10. `addDependency()` is still O(E) per edge

The final topological sort is scalable, but graph construction checks duplicates by scanning all prior edges.

For expected normal pass counts this is acceptable.

If the graph becomes highly granular, either:

- allow duplicates and deduplicate while building CSR;
- use a temporary hash/set during graph construction;
- sort/deduplicate edges once before CSR generation.

This is lower priority than the items above.

## Physical macro/global packet design

Mosaic planning now emits physical `LOCAL`, `MACRO`, and `GLOBAL` streams.
The remaining gate is to execute those streams directly and compare them with
expanded tile packets and `cpu_cube`.

Permanent design should have three physical storage classes:

```text
LOCAL
    explicit tile packet

MACRO
    one packet referenced by a rectangular scheduler-tile range / macrobin

GLOBAL
    one pass-level packet implicitly visible to all affected tiles
```

A full-screen operation must not emit tens of thousands of duplicate records.

Example 8K at 32x32 scheduler tiles:

```text
240 * 135 = 32,400 tiles
```

One fullscreen cluster becoming 32,400 packet records is unacceptable for the long-term backend.

## Prepared primitive storage direction

After visibility, prepare triangles once into SoA/AoSoA batches.

Possible conceptual layout:

```text
x0[8]
y0[8]
x1[8]
y1[8]
x2[8]
y2[8]

edge_a[8]
edge_b[8]
edge_c[8]

depth_origin[8]
depth_dx[8]
depth_dy[8]

varying gradients...
```

For AVX2 primitive-SIMD, eight lanes may represent eight different tiny primitives.

For pixel-SIMD, lanes represent neighboring samples/pixels for one or a small number of larger primitives.

Tile packets should eventually reference prepared batch ranges rather than raw source triangle ranges.

## Visibility buffer direction

Current conceptual storage:

```text
primitive/material identity + depth
```

Permanent implementation should avoid unnecessary duplication and account for reconstruction requirements.

Possible future compact identity fields:

```text
prepared primitive id
instance id
material/PSO id or lookup token
front-face bit
optional barycentric/reconstruction data
optional order tie token
```

Avoid permanently committing to 8-byte ID + separate 4-byte depth per pixel without profiling memory pressure.

## Pass DAG direction

Current DAG now has an efficient scheduling algorithm, but it is not yet a complete Vulkan hazard DAG.

Required eventual resource keys include:

```text
buffer id + byte range
image id + aspect/mip/layer range
read/write/read-write
pipeline stages
access masks
image layout
queue ownership
```

The graph should derive ordering edges only for actual conflicts.

Do not use one global epoch barrier if independent resources can continue in parallel.

## Worker scheduling direction

Final target:

```text
NUMA node
  -> LLC / CCD domain
      -> persistent worker set
          -> local Morton/supertile work deque
```

Workers should:

1. consume local cache-domain work first;
2. prefer spatially neighboring tile groups;
3. steal batches, not individual tiny tasks, when necessary;
4. avoid one central atomic counter at high core counts.

Worker count should be calibrated rather than blindly using SMT threads.

Start from physical cores, then test SMT separately.

## Dynamic tile selection direction

Startup CPUID detection only determines legal implementation candidates.

Actual scheduler geometry should eventually consider per-pass properties:

```text
active executable kernel
L1/L2/LLC topology
physical worker count
color bytes/sample
depth/stencil bytes/sample
MRT count
MSAA samples
shadow/depth-only vs G-buffer vs UI
observed primitive-size distribution
```

First-order active attachment footprint:

```text
tile_bytes = tile_w * tile_h * bytes_per_sample * samples
```

Do not fill the whole L1 with framebuffer data. Leave room for packet data, primitive data, shader state, texture lines, stack/spills, etc.

## CI / validation handoff

Current GitHub CI is not giving compiler feedback because the Ubuntu dependency-install step fails before:

```text
zig fmt --check
zig build
zig build test
```

Reorder CI so a minimal compiler gate runs before optional integration/coverage dependencies.

Recommended stage order:

```text
1. setup Zig
2. zig fmt --check
3. minimal zig build
4. zig build test
5. install kcov / Vulkan / X11 integration dependencies
6. behavior / coverage / desktop tests
7. performance gates
```

The artifact-capability layer now isolates topology code from `zpu_config` and
the SIMD dispatcher. Package-heavy CI dependencies still need to be split so
they cannot block normal build/test evidence.

## Tests the next agent should add immediately

### Hierarchy validation tests

```text
self-cycle
2-node cycle
ancestor cycle
duplicate parent if disallowed
out-of-range child
out-of-range leaf range
node with both child and leaf ranges
parent bounds not containing child
LESS parent best-depth too far
GREATER parent best-depth too near
```

### HZB property tests

For dimensions at least 1..33:

```text
odd widths
odd heights
prime dimensions
all edge rectangles
background holes at block boundaries
normal Z
reverse Z
strict compare
inclusive compare
non-finite source depth behavior
```

Compare HZB result against a brute-force full-resolution conservative oracle.

### Binning tests

```text
full-screen cluster extent classification
cluster crossing multiple macrobins
macro/tile exact-divisibility validation
stable output order with intentionally shuffled input
packet capacity upper bound
u32 count overflow handling
```

### CPU worker tests

```text
1 CPU
2 CPUs
6 CPUs
32 CPUs
128 CPUs
worker indexes beyond 5
```

### Build-capability tests

```text
no v3 kernels linked -> never executable AVX2
AVX2 CPU + v3 surface kernels only -> Mosaic raster capability remains false
future Mosaic AVX2 kernel linked -> Mosaic AVX2 capability true
```

## Performance benchmarks to add before integration is called successful

Record separately:

```text
hierarchy nodes/sec
leaf clusters reached/sec
HZB tests/sec
logical triangles rejected/sec
macro refs generated/frame
tile packets/frame
packet amplification ratio
planning bytes/frame
planning time/frame
triangle preparation time
raster time
shading time
p50/p95/p99 total frame time
```

Synthetic cases:

```text
fully occluded deep hierarchy
fully visible hierarchy
50/50 occluded hierarchy
many tiny primitives
few giant triangles
full-screen geometry
high-overdraw opaque scene
mixed material scene
4K
8K
1x and 4x MSAA once supported
```

## Historical implementation order

Steps 1–7 established the current foundation. Continue with broad Phase-9B
scalar semantic parity and physical packet execution before SIMD.

### Step 1 - make the current branch compile reliably

Files:

```text
src/vulkan/cpu_locality.zig
src/simd/dispatch.zig or new build capability module
build.zig
.github/workflows/ci.yml
```

Tasks:

- remove `cpu_locality -> full simd dispatcher` coupling;
- make compiled-kernel capability explicit;
- run compiler/test gates before package-heavy CI steps;
- get a green baseline.

### Step 2 - hierarchy admission validator

Files:

```text
src/render/mosaic_pipeline.zig
src/render/mosaic_backend.zig
```

Add a validated hierarchy object/revision concept.

Do not repeatedly validate static hierarchy topology every frame.

### Step 3 - fix extent and ordering construction

Files:

```text
src/render/mosaic_pipeline.zig
```

- classify extent from original full-cluster fanout;
- replace per-tile insertion sort with ordered construction;
- add physical macro/global packet planning structures or at minimum make their future boundary explicit.

### Step 4 - remove worker-count ceiling

File:

```text
src/vulkan/cpu_locality.zig
```

Generalize raster worker pinning beyond five named roles.

### Step 5 - reduce HZB memory

File:

```text
src/render/mosaic_pipeline.zig
```

Alias level 0, store only coarse levels.

Add finite-depth contract.

### Step 6 - add prepared-cluster / prepared-batch representation

New likely module:

```text
src/render/prepared_primitives.zig
```

or equivalent.

This is the key boundary before integrating with `cpu_cube.zig`.

### Step 7 - integrate existing scalar raster path first

Do not jump directly to AVX kernels.

Route ordered tile packets through the existing scalar/reference triangle raster logic and prove identical output.

Required invariant:

```text
old path pixels == packet path pixels
```

for supported scenes.

### Step 8 - add primitive-SIMD

First portable 4-lane, then separately compiled AVX2 8-lane.

Use differential tests against scalar.

### Step 9 - eligible visibility buffer path

Add explicit eligibility predicate before any deferred opaque optimization.

### Step 10 - material/quad shading

Only after visibility semantics are proven.

## Do not do these things

Do not:

- hard-code scheduler tile size as an architectural constant;
- assume widest host ISA is fastest;
- infer executable ISA only from CPUID;
- treat all Vulkan opaque-looking draws as reorderable;
- build one queue entry per triangle;
- redo triangle setup in every tile;
- rescan all clusters after macrobins exist;
- use a single central atomic tile counter as the permanent scheduler;
- treat previous-frame depth as automatically valid HZB input;
- use cluster bounding-box area / triangle count as primitive-size estimate;
- duplicate full-screen operations into every tile in the permanent representation;
- optimize average FPS at the cost of p99 regressions.

## Definition of done for this architectural foundation

Before the planning foundation should be considered stable enough to build major execution work on top of it:

```text
[x] current branch synced to current main
[x] dependency-free Zig build/test gates green
[x] artifact capability dependency cleaned up
[x] hierarchy validator rejects malformed topology and non-conservative bounds
[x] HZB property tests pass normal/reverse Z and dimensions 1..33
[x] extent classification uses full cluster fanout
[x] tile ordering construction is sub-quadratic
[x] raster worker count is not capped at five
[x] tile packet upper-bound helper exposed
[x] HZB level 0 aliases source depth
[x] experimental Mosaic API namespace made explicit
[x] scalar packet executor has a real `cpu_cube` differential gate
```

## Final architectural summary for the next agent

The branch should evolve toward this principle:

```text
Reject the largest possible unit as early as possible.
Prepare surviving geometry once.
Move only compact references through spatial bins.
Own each tile by one worker.
Vectorize tiny geometry across primitives and large geometry across pixels.
Shade only surviving visible samples when Vulkan semantics permit it.
Keep the strict fallback path correct for everything else.
```

That is the core strategy for making a CPU Vulkan backend scale beyond conventional software-rasterizer designs while preserving correctness and predictable frame-time tails.

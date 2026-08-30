<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Mosaic: host-tuned packetized tile renderer

## Goal

**Mosaic** is ZPU's hierarchy-first, packetized tile renderer. It preserves
Vulkan semantics while using clusters, macrobins, and cache-local tile work to
avoid triangle-by-triangle processing when coarse geometry can be rejected.

The target hierarchy is:

```text
Vulkan eligible path ------------------------┐
                                             │
Native Mosaic API ---------------------------┤
                                             v
                               resource-aware pass graph
                                             │
                                             v
                              instance / cluster hierarchy
                           frustum + cone + LOD selection
                                             │
                                             v
                         valid HZB source: prepass or temporal
                                             │
                                             v
                                      macrobin assignment
                                             │
                                             v
                              visible leaf-cluster expansion
                                  triangle setup exactly once
                                             │
                                             v
                        tile primitive subsets / coverage masks
                                             │
                     +-----------------------+-----------------------+
                     v                                               v
            primitive-SIMD batches                           pixel-SIMD tiles
             tiny triangles                                normal/large triangles
                     │                                               │
                     +-----------------------+-----------------------+
                                             v
                          eligible opaque visibility buffer
                                             │
                                             v
                              2x2 quad/material shading
                                             │
                                             v
                  strict ordered fallback for ineligible Vulkan work
```

The current branch implements Mosaic planning, prepared primitives, physical
packet streams, and a scalar packet executor with differential coverage against
`cpu_cube.zig`. The Vulkan driver now has a narrow private bridge for eligible
opaque `cpu_cube_v1` streams: it coalesces the complete bounded command run and
routes it through the prepared scalar Mosaic executor. Full Vulkan draw
lowering into hierarchy/physical cluster packets remains a later step.

## Current executable foundation

Implemented in this branch:

- runtime host SIMD/OS-state detection;
- explicit separation between host capability and compiled executable kernels;
- scheduler-tile and microtile profiles;
- bounded common pass DAG with deterministic sequence ordering;
- coarse leaf-cluster packets;
- optional cluster hierarchy and iterative subtree culling;
- conservative HZB construction for normal-Z and reverse-Z depth tests;
- explicit HZB source/provenance policy;
- exact HZB power-of-two footprints for odd framebuffer dimensions;
- two-pass contiguous macrobins;
- tile packet construction that consumes macrobins rather than rescanning the full cluster list;
- stable per-tile order keys;
- O(n log n) ordered tile construction instead of insertion sorting;
- admission-time hierarchy validation with topology and conservative-bound checks;
- physical `LOCAL` / `MACRO` / `GLOBAL` packet streams;
- prepared primitives that perform scalar triangle setup once;
- scalar packet execution and differential testing against `cpu_cube`;
- private Vulkan ABI bridge for eligible opaque streams using the prepared
  scalar Mosaic executor;
- primitive-SIMD versus pixel-SIMD path classification using a post-setup coverage estimate;
- compact visibility/depth storage for the future opaque deferred-shading path;
- caller-owned bounded scratch and capacity helpers;
- CPU role fanout across available selected CPUs instead of forcing all raster roles onto one secondary CPU.

Not implemented yet:

- full Vulkan draw lowering into Mosaic hierarchy/physical cluster submissions;
- a stable public native Mosaic API;
- instance/frustum/cone/LOD hierarchy generation;
- actual primitive-SIMD triangle kernels;
- actual pixel-SIMD packet execution;
- visibility-buffer material reconstruction and quad shading;
- complete Vulkan resource hazard derivation;
- per-LLC work queues and work stealing;
- startup benchmarking/autotuning;
- x86-64-v4 AVX-512 kernel objects.

## Scheduler tiles versus microtiles

These are separate decisions.

```text
scheduler tile
+-----------------------------------+
|  micro  |  micro  |  micro        |
|  tile   |  tile   |  tile         |
|         |         |               |
+-----------------------------------+
|          more microtiles          |
+-----------------------------------+
```

Scheduler tiles control:

- work ownership;
- tile-packet metadata;
- cache locality;
- worker scheduling;
- binning fanout.

Microtiles control:

- SIMD lane shape;
- coverage stepping;
- depth/vector operations;
- inner raster-loop geometry.

The current deterministic defaults are candidates, not measured optima:

| Executable kernel | Scheduler tile | Microtile | Vector lanes |
| --- | ---: | ---: | ---: |
| portable vector | 16x16 | 4x2 | 4 |
| AVX2 | 32x32 | 8x4 | 8 |
| future AVX-512 | 64x16 | 16x4 | 16 |

An AVX-512-capable host does **not** receive the AVX-512 profile unless compiled and validated AVX-512 kernel objects exist.

## ISA safety boundary

```text
CPUID + OS vector state
          │
          v
    host capability
          │
          +-----------------------------+
                                        │
compiled kernel boundary ---------------+
                                        v
                                executable kernel class
```

`host_class` records what the machine could support.

`executable_class` records what the artifact can actually execute.

Both conditions are required before a wider backend is selected.

## HZB model

HZB means **Hierarchical Z-Buffer**. It is a mip-like hierarchy built by repeatedly reducing 2x2 depth blocks.

```text
level 0: full-resolution depth
             │
             v 2x2 reduction
level 1: half-ish dimensions
             │
             v 2x2 reduction
level 2: quarter-ish dimensions
             │
             v
          ...
```

For normal-Z LESS-family depth tests, each coarse cell stores the maximum/farthest depth in its covered region.

For reverse-Z GREATER-family depth tests, each coarse cell stores the minimum/farthest-in-compare-space depth.

Every HZB level stores an exact `footprint_shift`. Level `L` covers base pixels in blocks of `2^L`; odd framebuffer dimensions only truncate the final block. Coordinate mapping therefore uses shifts, never `ceil(base_width / mip_width)` approximations.

### Conservative occlusion conditions

For a cluster's best possible depth `z_best` and the aggregate occluder depth `z_hzb`:

```text
LESS          occluded when z_best >= z_hzb
LESS_OR_EQUAL occluded when z_best >  z_hzb
GREATER       occluded when z_best <= z_hzb
GREATER_EQUAL occluded when z_best <  z_hzb
```

A hole/background sample makes the relevant coarse aggregate conservative and prevents false rejection.

### HZB provenance

The planner requires an explicit source policy:

```text
same_frame_completed
    depth written by completed earlier work

depth_prepass
    dedicated completed occluder/depth pass

previous_frame_conservative
    accepted only when conservative reprojection validity is explicitly proven
```

A stale previous-frame depth buffer is not accepted by default.

## Cluster hierarchy

The performance target is not to inspect every source triangle or every leaf cluster.

```text
root node
  ├── internal node
  │     ├── leaf cluster range
  │     └── leaf cluster range
  └── internal node
        ├── subtree
        └── subtree
```

Internal nodes carry conservative screen bounds and best possible depth. If an internal node is HZB-occluded, the entire subtree is rejected without visiting its leaf clusters.

The current hierarchy is intentionally minimal. Future node data should include object-space bounds, LOD error and normal-cone data so frustum, backface/cone and LOD rejection can occur before screen-space HZB tests.

## Macrobins are a real hierarchy level

The current execution-planning chain is:

```text
visible leaf clusters
       │
       v
   macrobins
       │
       v
scheduler tiles inside each macrobin
```

Tile packet generation consumes macrobin headers and references. It does not independently rescan all visible clusters.

Macro dimensions must be exact multiples of scheduler-tile dimensions in this implementation. This gives each scheduler tile exactly one macrobin parent and prevents duplicate cluster-to-tile emission across macrobin boundaries.

## Ordered tile packet streams

A tile packet represents a cluster triangle range, not one triangle.

```text
TilePacket
  order_key
  ordering class
  draw id
  cluster id
  material id
  triangle range
  raster path
  extent class
```

Order is explicit:

```text
OrderKey = submission / command / primitive-group
```

Tile streams are stably sorted by that key after construction. This remains correct if cluster generation or macrobin construction is later parallelized.

Ordering classes reserve room for safe optimization:

```text
strict             preserve API-visible order

depth_reorderable  may later be front-to-back reordered only when semantics allow

commutative        may later be freely combined/reordered when proven safe
```

No reordering optimization is implied merely by setting a packet's extent or raster path.

## Local, macro and global extent

The planner classifies packet extent by scheduler-tile fanout:

```text
LOCAL   small tile fanout
MACRO   medium/broad fanout
GLOBAL  very broad/full-surface fanout
```

The current packet structure carries this class, but physical storage is still one per-tile stream. A later optimization must materialize macro/global packets as range or pass-level references so a full-screen operation does not create tens of thousands of duplicate packet records.

## Triangle setup boundary

Hierarchy and HZB rejection happen before expensive leaf work.

The required next-stage rule is:

```text
visible leaf cluster
       │
       v
vertex/primitive preparation exactly once
       │
       v
prepared primitive ranges / coverage masks
       │
       v
tile execution
```

The tile executor must not independently redo full triangle setup for every tile touched by the same cluster.

## Primitive-SIMD versus pixel-SIMD

Cluster bounding-box area divided by triangle count is not a valid primitive-size estimate. Sparse tiny triangles can cover a very large cluster bounding rectangle.

The current classifier therefore consumes an optional post-setup `estimated_covered_samples` value:

```text
estimated samples / triangle <= threshold
        -> primitive-SIMD

larger estimated coverage
        -> pixel-SIMD

unknown estimate
        -> primitive-SIMD conservative default
```

Future classification should operate on prepared primitive batches and measured kernel crossover points.

## Pass graph

The pass graph uses CSR adjacency plus a deterministic sequence-keyed ready heap.

Complexity is:

```text
O(V + E + V log V)
```

rather than repeated full scans of all passes and edges.

The current graph is still a generic bounded DAG. `ResourceUse` defines the start of a resource-access vocabulary, but complete Vulkan dependency derivation still requires image subresources, buffer ranges, stage/access masks, layouts and queue ownership before the graph can be called a complete Vulkan hazard graph.

## Storage model

High-rate structures are caller-owned reusable arrays:

```text
HZB values / levels
visibility mask
hierarchy stack
macrobin headers / refs / cursors
tile headers / packets / cursors
```

The planner exposes fixed requirements and conservative upper bounds before execution where possible.

Two-pass bin construction is:

```text
pass 1: count references
pass 2: prefix offsets + dense writes
```

No linked lists or one-allocation-per-tile queues are used.

## Visibility buffer eligibility

The visibility buffer is an optimization for eligible opaque work, not a replacement for all Vulkan fragment semantics.

The future fast-path predicate must exclude or conservatively handle pipelines involving at least:

- blending;
- fragment storage writes or atomics;
- fragment shader depth output;
- discard / complex alpha testing;
- sample shading / MSAA complications;
- framebuffer feedback/interlocks;
- query/statistics semantics that observe execution;
- unsupported stencil behavior.

Ineligible work remains on a strict conventional ordered path.

## Multicore scheduling

The CPU-locality layer now allows raster roles to map to distinct selected CPUs when enough CPUs are available. This is only the foundation.

The target worker model is:

```text
NUMA node
  ├── LLC domain
  │     ├── persistent worker
  │     ├── persistent worker
  │     └── local tile-group deque
  └── LLC domain
        ├── persistent worker
        └── local tile-group deque
```

Workers should prefer local Morton-like tile groups, then steal batches when local work is exhausted.

## Autotuning

Startup detection determines legal executable kernels. Final scheduler geometry should eventually consider:

- executable vector width;
- L1/L2/LLC capacity and sharing;
- selected worker count;
- attachment bytes per pixel;
- depth/stencil format;
- MSAA sample count;
- depth-only versus G-buffer versus UI pass;
- primitive-size distribution;
- measured p95/p99 frame time;
- frequency/power side effects of wide vectors.

The current hard-coded geometry values are defaults/candidates only.

## Implementation phases

### Foundation implemented in this branch

- [x] host/OS SIMD capability detection
- [x] compiled-kernel gating
- [x] scheduler/microtile candidate profile
- [x] scalable deterministic pass DAG
- [x] normal-Z and reverse-Z HZB
- [x] exact odd-size HZB mapping
- [x] HZB provenance contract
- [x] minimal hierarchy traversal
- [x] contiguous macrobins
- [x] macrobin-driven tile packets
- [x] explicit stable order keys
- [x] checked count/capacity helpers
- [x] primitive/pixel SIMD classifier input
- [x] visibility-buffer storage type
- [x] raster-worker CPU fanout foundation

### Next integration stage

- [ ] lower eligible Vulkan draws to coarse cluster submissions
- [ ] prepare visible cluster triangles exactly once
- [ ] add prepared primitive subsets / microtile coverage masks
- [ ] execute tile packets through existing scalar oracle first
- [ ] add portable primitive-SIMD kernels
- [ ] add AVX2 primitive-SIMD kernels behind the existing v3 boundary
- [ ] write visibility/depth for eligible opaque work
- [ ] implement quad/material shading
- [ ] preserve strict fallback for all ineligible Vulkan semantics

### Scale stage

- [ ] richer instance/cluster hierarchy with LOD and cone/frustum tests
- [ ] physical macro/global packet streams
- [ ] parallel hierarchy traversal and bin construction
- [ ] LLC-local worker queues and stealing
- [ ] pass-aware dynamic tile selection
- [ ] bounded startup autotuning
- [ ] optional validated x86-64-v4 kernels

## Success metrics

Do not report only triangle rate or average FPS. Track:

```text
logical source triangles
hierarchy nodes tested
leaf clusters reached
clusters HZB-rejected
triangles expanded
triangles rasterized
tile packet references
covered samples
shaded samples
planning bytes/frame
p50/p95/p99 frame time
missed presentation deadlines
```

The trillion-scale goal should mean **logical source geometry rejected through hierarchy**, not one trillion individually processed Vulkan draws or leaf clusters per second.

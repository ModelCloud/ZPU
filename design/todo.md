<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# ZPU Design TODO

## Locked 120 Hz low-jitter milestone

- [x] Rational 120/1 per-swapchain phase clocks with absolute monotonic deadlines, late-slot skipping, and saturating arithmetic.
- [x] FIFO ownership through XCB completion, enqueue rollback, and transport-failure release.
- [x] Cache-local 8x8 vkcube traversal, conservative tile rejection, precomputed reciprocal attributes, and an untiled scalar oracle.
- [x] Persistent XCB resources and a synchronous `ZPU_ONE_CORE=1` mode without an extra handoff.
- [x] Upload complete frames to the off-screen pixmap before the phase deadline;
  deadline work is limited to CopyArea+flush, with a bounded 100 us spin tail.
- [ ] Physical scanout validation; Xvfb is synthetic pacing evidence only.

The locked 800x600 CPU-7 gate is 119–121 visible FPS, mean near 8.333 ms,
CV <=0.010, p95 <=8.50 ms, p99 <=8.75 ms, p99.9 <=9.0 ms, worst <=10.0 ms,
missed slots and duplicates <=1%, zero capture drops, and monotonic PTS.

## Parallel rendering architecture

Make ZPU internally massively parallel while preserving standard Vulkan API
semantics. The Vulkan path should initially expose one ordered graphics queue
backed by tile-parallel execution, giving modern CPU scaling without forcing
applications to manage rendering races.

Future ZPU should also provide a native, direct API alongside Vulkan. Unlike
the Vulkan compatibility surface, this API should be designed specifically to
make full use of ZPU's parallel architecture. It may allow applications to
describe independent rendering regions and resource-access domains explicitly,
so non-conflicting draws can be scheduled concurrently. Conflicting work must
have clearly defined synchronization and ordering rules rather than silently
producing nondeterministic corruption.

The native API must not weaken Vulkan behavior: Vulkan submissions continue to
observe Vulkan ordering, synchronization, blending, depth/stencil, and
rasterization requirements. Both APIs should ultimately feed the same internal
dependency analysis, tile binning, worker scheduling, and resource-lifetime
systems.

## Frame-time quality before peak FPS

ZPU prioritizes smooth, predictable frame delivery over maximum unconstrained
throughput. Average FPS alone is not a sufficient performance measure: every
rendering benchmark and readiness review must report frame-time distribution,
including median, p95, p99, worst-frame latency, jitter, and missed presentation
deadlines.

For a locked 60 FPS mode, ZPU should target a monotonic 16.667 ms presentation
cadence with drift correction and bounded work in flight. A lower but stable
frame rate is preferable to a higher average frame rate with visible hitching,
bursts, or long-tail stalls. Frame-rate locking must regulate scheduling,
backpressure, and presentation timing rather than merely limiting the number of
frames counted per second.

This priority applies to both the Vulkan path and the future native ZPU API.
Vulkan presentation and synchronization semantics remain conformant while the
internal scheduler uses CPU parallelism to reduce frame-time variance and tail
latency.

## First FIFO pacing milestone

The first implementation uses a bounded per-image lifecycle (`available`,
`acquired`, `queued`) and a single ordered presentation worker. Queued images
are released only after their pixels have reached the XCB transport. Acquire
honors zero, finite, and infinite timeouts; swapchain and device/queue teardown
drain pending work without sleeping, waiting on X, or uploading while the
global driver mutex is held.

Synthetic Xvfb pacing is phase-locked to absolute `CLOCK_MONOTONIC` deadlines
at the exact rational rate 1,000,000,000/60 ns. Lateness advances to the next
future phase slot, never drops a FIFO entry, and never issues catch-up bursts.
This is deterministic synthetic pacing evidence, not a claim about physical
display scanout. A later physical backend must source real vblank/scanout
completion timestamps and retain the same image-lifecycle contract.

XCB swapchains own a persistent GC and off-screen pixmap. Unchecked image
chunks are uploaded to the hidden pixmap without per-strip round trips; one
ordered full-surface copy exposes the completed frame. Future transport work
should evaluate MIT-SHM while preserving complete-frame visibility and the
same bounded FIFO ownership rules.

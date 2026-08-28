<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Deterministic 3D benchmark (implemented)

The authoritative low-jitter workload is the exact 800x600 vkcube CPU renderer
at a 120 Hz presentation target. Reports include p50/p95/p99/p99.9/max and CV,
source commit, CPU topology/affinity, checksum, and an ignored raw artifact;
peak FPS alone is not readiness evidence.

Low-jitter evidence also records a preallocated monotonic producer trace:
render completion, rational deadline, wake error, XCB upload completion,
CopyArea, flush, and frame completion. Observer CPUs are reported separately
from the single CPU-7 driver affinity.

The vkcube-specific renderer and benchmark now exist. The frozen scene,
reference checksum, sampling schedule, exact work counters, capture procedure,
and commit-bound evidence rules are documented in
[pr-readiness.md](pr-readiness.md). This remains deliberately narrow and is not
a general SPIR-V claim.

The next optimization gate is an opt-in two-core profile. Run
`ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-3d -- --two-core`;
the process must expose exactly two selected physical cores. The target is
31,339.20 triangles/s (10× the frozen 3,133.92 triangles/s baseline), with
the measured speedup and affinity recorded in the target report. Until that
number is measured, it is a goal rather than a performance claim.

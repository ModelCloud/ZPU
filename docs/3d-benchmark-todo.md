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

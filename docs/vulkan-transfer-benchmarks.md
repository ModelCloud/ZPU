<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan transfer benchmarks

`benchmark-vulkan-transfer` measures the pitched row copies used by the CPU
Vulkan backend for texture uploads and readbacks. The workload is deliberately
non-trivial: four 1920×1080 RGBA layers copied from a 2048-texel row-pitch
buffer, with a checksum over the complete destination after every sample.
It compares the old overlap-safe `copyForwards` loop with the production
validated non-overlapping bulk-copy path.

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-vulkan-transfer \
  -Doptimize=ReleaseFast -- --json
```

On the pinned two-core host used for the current evidence, the six-sample
report was:

| path | p50 | p95 |
| --- | ---: | ---: |
| `copyForwards` | 8.31 ms | 8.33 ms |
| validated bulk copy | 1.08 ms | 1.10 ms |

That is a 7.72× p50 improvement for 33,177,600 destination bytes, with
checksum `62659341af8e0a6d`. The benchmark is an API-shape reference rather
than a claim to implement a discrete GPU transfer engine.

The fast path is used only after command recording has rejected overlapping
buffer/image and image/image memory ranges. Host-pointer image copies retain
the overlap-safe behavior required by the Vulkan host-image-copy contract.

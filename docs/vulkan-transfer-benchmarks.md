<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan transfer benchmarks

`benchmark-vulkan-transfer` measures the row copies used by the CPU Vulkan
backend for texture uploads, readbacks, and image-to-image transfers. The
buffer/image workload is deliberately non-trivial: four 1920×1080 RGBA layers
copied from a 2048-texel row-pitch buffer, with a checksum over the complete
destination after every sample. The image workload copies four tightly packed
1920×1080 layers. Both compare the old overlap-safe `copyForwards` loop with
the production validated non-overlapping bulk-copy path.

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-vulkan-transfer \
  -Doptimize=ReleaseFast -- --json
```

On the pinned two-core host used for the current evidence, the six-sample
report was:

| path | p50 | p95 |
| --- | ---: | ---: |
| `copyForwards` | 8.25 ms | 8.47 ms |
| validated bulk copy | 1.03 ms | 1.04 ms |

That is a 7.98× p50 improvement for 33,177,600 destination bytes. The
image-to-image result is also recorded in the JSON report:

| image path | p50 | p95 |
| --- | ---: | ---: |
| `image_copy_forwards` | 8.04 ms | 8.24 ms |
| `image_copy_bulk` | 0.79 ms | 0.81 ms |

The image path is a 10.12× p50 improvement, with report checksum
`49ab2b7e15af5319`. The benchmark is an API-shape reference rather than a
claim to implement a discrete GPU transfer engine.

The fast path is used only after command recording has rejected overlapping
buffer/image and image/image memory ranges. `vkCmdCopyBufferToImage`,
`vkCmdCopyImageToBuffer`, and `vkCmdCopyImage` now copy one complete layer per
dispatch; tight image layers collapse to one contiguous `memcpy`, while
pitched rows retain explicit strides. Host-pointer image copies retain the
overlap-safe behavior required by the Vulkan host-image-copy contract.

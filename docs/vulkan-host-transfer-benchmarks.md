<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

# Vulkan host-transfer benchmarks

`benchmark-vulkan-host-transfer` measures the host-pointer image upload path
used by Vulkan 1.4 host-image-copy calls. It copies four 1920×1080 RGBA
layers from a 2048-texel row-pitch host buffer, mutates the source for every
sample, and hashes the complete destination after every copy. The baseline
uses overlap-safe `std.mem.copyForwards`; the production path uses bulk row
copies only when the complete source and destination spans are disjoint.

```sh
ZPU_MAX_THREADS=2 tools/limited-cpus.sh zig build benchmark-vulkan-host-transfer \
  -Doptimize=ReleaseFast -- --json
```

Current pinned two-core evidence:

| path | p50 | p95 |
| --- | ---: | ---: |
| overlap-safe baseline | 8.21 ms | 8.32 ms |
| disjoint host bulk copy | 1.02 ms | 1.03 ms |

That is an 8.03× p50 improvement for 33,177,600 destination bytes, with
checksum `62659341af8e0a6d`.

The overlap check is conservative: if row-span arithmetic overflows or the
bounding spans intersect, every row retains `copyForwards` semantics. This
keeps aliased host pointers safe while making normal disjoint uploads and
readbacks use the compiler's tuned `@memcpy` lowering.

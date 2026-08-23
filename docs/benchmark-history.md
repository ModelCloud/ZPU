# Controlled benchmark history

This file is append-only. Each entry records a validated JSON report and names the exact 40-character source commit that was benchmarked. The history append commit follows that source commit; entries are never rewritten. `observed` is the maximum `/proc` task count observed by the wrapper's sustained Zig workload.

### 49190796e94dda1c224366534b15be602c7e5b8a

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T08:22:37Z
- Schema/workload: v2 / `zpu-2d-v2-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `passed`

| name | backend | MPix/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 3995.28335 | 14.8835903 | 0 | 0 | 14417 | 22416 | 22416 | `89fcf336d86c4f25` |
| pixel | scalar | 107.812171 | 0.401631635 | 0 | 0 | 4749 | 4877 | 4877 | `3d0737332ec9e1cc` |
| fill | scalar | 2122.36777 | 7.90643605 | 0 | 0 | 6031 | 13805 | 13805 | `b5cb439ce748a598` |
| transfer_fill | scalar | 1607.81577 | 5.98958049 | 0 | 0 | 35825 | 43551 | 43551 | `50dbc316a6090325` |
| transfer_copy | scalar | 1014.74552 | 7.56044329 | 0 | 0 | 56763 | 65305 | 65305 | `4e61ac2d0cc0777b` |
| blend | scalar | 43.114547 | 0.321228407 | 0 | 0 | 1335976 | 1461110 | 1461110 | `d5f99fe5b4e7eef8` |
| sprites | scalar | 0 | 0.325873646 | 683406.568 | 0 | 187297 | 198264 | 198264 | `3717a00e187d9381` |
| frame | scalar | 0 | 0.883757344 | 0 | 2625.1749 | 380927 | 428409 | 428409 | `2e480a89ab6181ef` |
| clear | avx2 | 16951.1477 | 63.1479462 | 0 | 0 | 3398 | 3699 | 3699 | `89fcf336d86c4f25` |
| pixel | avx2 | 104.810645 | 0.390450078 | 0 | 0 | 4885 | 4931 | 4931 | `3d0737332ec9e1cc` |
| fill | avx2 | 3377.30871 | 12.5814554 | 0 | 0 | 3790 | 3877 | 3877 | `b5cb439ce748a598` |
| blend | avx2 | 66.3495863 | 0.49434294 | 0 | 0 | 868129 | 943425 | 943425 | `d5f99fe5b4e7eef8` |
| sprites | avx2 | 0 | 0.478197031 | 1002851.86 | 0 | 127636 | 143353 | 143353 | `3717a00e187d9381` |
| frame | avx2 | 0 | 1.29228131 | 0 | 3838.68318 | 260506 | 286486 | 286486 | `2e480a89ab6181ef` |
| clear | runtime | 15991.116 | 59.5715495 | 0 | 0 | 3602 | 3687 | 3687 | `89fcf336d86c4f25` |
| pixel | runtime | 100.668502 | 0.375019393 | 0 | 0 | 5086 | 10476 | 10476 | `3d0737332ec9e1cc` |
| fill | runtime | 3182.49627 | 11.8557225 | 0 | 0 | 4022 | 6330 | 6330 | `b5cb439ce748a598` |
| blend | runtime | 65.4513473 | 0.487650538 | 0 | 0 | 880043 | 949992 | 949992 | `d5f99fe5b4e7eef8` |
| sprites | runtime | 0 | 0.481604288 | 1009997.4 | 0 | 126733 | 150090 | 150090 | `3717a00e187d9381` |
| frame | runtime | 0 | 1.29212258 | 0 | 3838.2117 | 260538 | 272789 | 272789 | `2e480a89ab6181ef` |

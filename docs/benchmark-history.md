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

### 9800e39bfd143fa3aa04298839d38f358063189a

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T08:26:34Z
- Schema/workload: v2 / `zpu-2d-v2-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `passed`

| name | backend | MPix/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 4001.38937 | 14.906337 | 0 | 0 | 14395 | 14902 | 14902 | `89fcf336d86c4f25` |
| pixel | scalar | 107.001045 | 0.398609955 | 0 | 0 | 4785 | 5283 | 5283 | `3d0737332ec9e1cc` |
| fill | scalar | 2172.06856 | 8.09158592 | 0 | 0 | 5893 | 5992 | 5992 | `b5cb439ce748a598` |
| transfer_fill | scalar | 1597.33777 | 5.9505469 | 0 | 0 | 36060 | 56683 | 56683 | `50dbc316a6090325` |
| transfer_copy | scalar | 1003.58923 | 7.47732241 | 0 | 0 | 57394 | 64536 | 64536 | `4e61ac2d0cc0777b` |
| blend | scalar | 44.577903 | 0.332131259 | 0 | 0 | 1292120 | 1327947 | 1327947 | `d5f99fe5b4e7eef8` |
| sprites | scalar | 0 | 0.337746351 | 708305.435 | 0 | 180713 | 198135 | 198135 | `3717a00e187d9381` |
| frame | scalar | 0 | 0.883490622 | 0 | 2624.38261 | 381042 | 395337 | 395337 | `2e480a89ab6181ef` |
| clear | avx2 | 17107.2171 | 63.7293499 | 0 | 0 | 3367 | 9055 | 9055 | `89fcf336d86c4f25` |
| pixel | avx2 | 104.128534 | 0.387909016 | 0 | 0 | 4917 | 5023 | 5023 | `3d0737332ec9e1cc` |
| fill | avx2 | 3261.1465 | 12.1487174 | 0 | 0 | 3925 | 4117 | 4117 | `b5cb439ce748a598` |
| blend | avx2 | 69.0658248 | 0.514580494 | 0 | 0 | 833987 | 886985 | 886985 | `d5f99fe5b4e7eef8` |
| sprites | avx2 | 0 | 0.507277789 | 1063838.63 | 0 | 120319 | 132224 | 132224 | `3717a00e187d9381` |
| frame | avx2 | 0 | 1.36520959 | 0 | 4055.31449 | 246590 | 257276 | 257276 | `2e480a89ab6181ef` |
| clear | runtime | 16125.4199 | 60.0718704 | 0 | 0 | 3572 | 3632 | 3632 | `89fcf336d86c4f25` |
| pixel | runtime | 100.274187 | 0.373550457 | 0 | 0 | 5106 | 11652 | 11652 | `3d0737332ec9e1cc` |
| fill | runtime | 3203.2032 | 11.9328618 | 0 | 0 | 3996 | 4128 | 4128 | `b5cb439ce748a598` |
| blend | runtime | 68.4472457 | 0.509971721 | 0 | 0 | 841524 | 907609 | 907609 | `d5f99fe5b4e7eef8` |
| sprites | runtime | 0 | 0.48603383 | 1019286.82 | 0 | 125578 | 149758 | 149758 | `3717a00e187d9381` |
| frame | runtime | 0 | 1.31333451 | 0 | 3901.22108 | 256330 | 270417 | 270417 | `2e480a89ab6181ef` |

### d399ef5dd63132e488f826ede3ee371905ba2e35

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T09:11:23Z
- Schema/workload: v2 / `zpu-2d-v2-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `not-run`

| name | backend | MPix/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 4042.95641 | 15.0611863 | 0 | 0 | 14247 | 15136 | 15136 | `89fcf336d86c4f25` |
| pixel | scalar | 106.934002 | 0.398360199 | 0 | 0 | 4788 | 5418 | 5418 | `3d0737332ec9e1cc` |
| fill | scalar | 2141.90094 | 7.97920278 | 0 | 0 | 5976 | 9455 | 9455 | `b5cb439ce748a598` |
| transfer_fill | scalar | 1589.66716 | 5.92197166 | 0 | 0 | 36234 | 46489 | 46489 | `50dbc316a6090325` |
| transfer_copy | scalar | 1015.98053 | 7.5696448 | 0 | 0 | 56694 | 60892 | 60892 | `4e61ac2d0cc0777b` |
| blend | scalar | 43.3706527 | 0.323136543 | 0 | 0 | 1328087 | 1393316 | 1393316 | `d5f99fe5b4e7eef8` |
| sprites | scalar | 0 | 0.319293336 | 669606.658 | 0 | 191157 | 204050 | 204050 | `3717a00e187d9381` |
| frame | scalar | 0 | 0.875654266 | 0 | 2601.10495 | 384452 | 399252 | 399252 | `2e480a89ab6181ef` |
| clear | avx2 | 17512.9219 | 65.2407179 | 0 | 0 | 3289 | 3363 | 3363 | `89fcf336d86c4f25` |
| pixel | avx2 | 104.767751 | 0.390290287 | 0 | 0 | 4887 | 8629 | 8629 | `3d0737332ec9e1cc` |
| fill | avx2 | 3370.19484 | 12.5549541 | 0 | 0 | 3798 | 5426 | 5426 | `b5cb439ce748a598` |
| blend | avx2 | 67.9863414 | 0.506537716 | 0 | 0 | 847229 | 885705 | 885705 | `d5f99fe5b4e7eef8` |
| sprites | avx2 | 0 | 0.481308059 | 1009376.16 | 0 | 126811 | 135554 | 135554 | `3717a00e187d9381` |
| frame | avx2 | 0 | 1.33561472 | 0 | 3967.40381 | 252054 | 270460 | 270460 | `2e480a89ab6181ef` |
| clear | runtime | 16532.721 | 61.5891852 | 0 | 0 | 3484 | 9501 | 9501 | `89fcf336d86c4f25` |
| pixel | runtime | 100.490677 | 0.374356945 | 0 | 0 | 5095 | 5128 | 5128 | `3d0737332ec9e1cc` |
| fill | runtime | 3173.81602 | 11.823386 | 0 | 0 | 4033 | 10020 | 10020 | `b5cb439ce748a598` |
| blend | runtime | 65.6943298 | 0.489460899 | 0 | 0 | 876788 | 915107 | 915107 | `d5f99fe5b4e7eef8` |
| sprites | runtime | 0 | 0.472913454 | 991771.397 | 0 | 129062 | 163877 | 163877 | `3717a00e187d9381` |
| frame | runtime | 0 | 1.36801119 | 0 | 4063.63655 | 246085 | 260389 | 260389 | `2e480a89ab6181ef` |

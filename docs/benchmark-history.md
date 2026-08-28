<!-- Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team -->
<!-- SPDX-License-Identifier: Apache-2.0 -->

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

### 805f39cafcccf1a2e7fd3f5a82123bd7b1da5b7f

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T09:22:54Z
- Schema/workload: v2 / `zpu-2d-v2-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `not-run`

| name | backend | MPix/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 3989.47223 | 14.8619422 | 0 | 0 | 14438 | 16345 | 16345 | `89fcf336d86c4f25` |
| pixel | scalar | 107.67613 | 0.401124844 | 0 | 0 | 4755 | 10099 | 10099 | `3d0737332ec9e1cc` |
| fill | scalar | 2131.55704 | 7.94066875 | 0 | 0 | 6005 | 11720 | 11720 | `b5cb439ce748a598` |
| transfer_fill | scalar | 1503.40615 | 5.60062436 | 0 | 0 | 38313 | 53847 | 53847 | `50dbc316a6090325` |
| transfer_copy | scalar | 993.65167 | 7.40328185 | 0 | 0 | 57968 | 76819 | 76819 | `4e61ac2d0cc0777b` |
| blend | scalar | 42.9350265 | 0.319890875 | 0 | 0 | 1341562 | 1384346 | 1384346 | `d5f99fe5b4e7eef8` |
| sprites | scalar | 0 | 0.31356683 | 657597.304 | 0 | 194648 | 210106 | 210106 | `3717a00e187d9381` |
| frame | scalar | 0 | 0.837845186 | 0 | 2488.7942 | 401801 | 437768 | 437768 | `2e480a89ab6181ef` |
| clear | avx2 | 16111.8881 | 60.0214605 | 0 | 0 | 3575 | 8208 | 8208 | `89fcf336d86c4f25` |
| pixel | avx2 | 107.045787 | 0.398776632 | 0 | 0 | 4783 | 7793 | 7793 | `3d0737332ec9e1cc` |
| fill | avx2 | 3286.26444 | 12.242289 | 0 | 0 | 3895 | 8469 | 8469 | `b5cb439ce748a598` |
| blend | avx2 | 64.8881749 | 0.483454577 | 0 | 0 | 887681 | 954408 | 954408 | `d5f99fe5b4e7eef8` |
| sprites | avx2 | 0 | 0.464619127 | 974376.932 | 0 | 131366 | 144714 | 144714 | `3717a00e187d9381` |
| frame | avx2 | 0 | 1.30641331 | 0 | 3880.66189 | 257688 | 284233 | 284233 | `2e480a89ab6181ef` |
| clear | runtime | 15258.2781 | 56.8415155 | 0 | 0 | 3775 | 12390 | 12390 | `89fcf336d86c4f25` |
| pixel | runtime | 103.959391 | 0.38727891 | 0 | 0 | 4925 | 4979 | 4979 | `3d0737332ec9e1cc` |
| fill | runtime | 3138.02403 | 11.6900505 | 0 | 0 | 4079 | 10582 | 10582 | `b5cb439ce748a598` |
| blend | runtime | 63.8670147 | 0.47584634 | 0 | 0 | 901874 | 959688 | 959688 | `d5f99fe5b4e7eef8` |
| sprites | runtime | 0 | 0.445008613 | 933250.702 | 0 | 137155 | 147176 | 147176 | `3717a00e187d9381` |
| frame | runtime | 0 | 1.3051471 | 0 | 3876.90065 | 257938 | 268152 | 268152 | `2e480a89ab6181ef` |

### 9ab5b3a893d5090ec8cc4e98734fb98e2c112719

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T11:51:36Z
- Schema/workload: v3 / `zpu-2d-host-memory-v3-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `passed`

| name | backend | MPix/s | bytes/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 4064.06548 | 1.62562619e+10 | 15.1398237 | 0 | 0 | 14173 | 17154 | 17154 | `89fcf336d86c4f25` |
| pixel_write | scalar | 108.199493 | 432797971 | 0.403074521 | 0 | 0 | 4732 | 4824 | 4824 | `3d0737332ec9e1cc` |
| clipped_rectangle | scalar | 2119.88047 | 8.47952188e+09 | 7.89717015 | 0 | 0 | 5689 | 5721 | 5721 | `2cf726772c9ab549` |
| vulkan_host_memory_fill | scalar | 6401.42254 | 2.56056902e+10 | 23.8471573 | 0 | 0 | 8998 | 9537 | 9537 | `50dbc316a6090325` |
| vulkan_host_memory_copy | scalar | 1022.87257 | 8.18298054e+09 | 7.6209945 | 0 | 0 | 56312 | 57259 | 57259 | `4e61ac2d0cc0777b` |
| source_over_blend | scalar | 45.3709429 | 362967543 | 0.338039867 | 0 | 0 | 1269535 | 1293593 | 1293593 | `d5f99fe5b4e7eef8` |
| sprite_draw | scalar | 0 | 427058693 | 0.397729402 | 834099.01 | 0 | 153459 | 171075 | 171075 | `e73fc1dc4f99be0c` |
| frame | scalar | 0 | 966264983 | 0.899904392 | 0 | 2673.13923 | 374092 | 383441 | 383441 | `2e480a89ab6181ef` |
| clear | avx2 | 17307.6923 | 6.92307692e+10 | 64.4761782 | 0 | 0 | 3328 | 3869 | 3869 | `89fcf336d86c4f25` |
| pixel_write | avx2 | 109.12191 | 436487639 | 0.406510791 | 0 | 0 | 4692 | 4879 | 4879 | `3d0737332ec9e1cc` |
| clipped_rectangle | avx2 | 3225.46135 | 1.29018454e+10 | 12.0157799 | 0 | 0 | 3739 | 3916 | 3916 | `2cf726772c9ab549` |
| source_over_blend | avx2 | 65.1872038 | 521497631 | 0.485682516 | 0 | 0 | 883609 | 1010989 | 1010989 | `d5f99fe5b4e7eef8` |
| sprite_draw | avx2 | 0 | 425011998 | 0.395823268 | 830101.558 | 0 | 154198 | 161199 | 161199 | `e73fc1dc4f99be0c` |
| frame | avx2 | 0 | 1.44271403e+09 | 1.34363214 | 0 | 3991.21932 | 250550 | 255935 | 255935 | `2e480a89ab6181ef` |
| clear | runtime | 16391.5766 | 6.55663062e+10 | 61.0633811 | 0 | 0 | 3514 | 4410 | 4410 | `89fcf336d86c4f25` |
| pixel_write | runtime | 103.980504 | 415922015 | 0.387357561 | 0 | 0 | 4924 | 6575 | 6575 | `3d0737332ec9e1cc` |
| clipped_rectangle | runtime | 3064.80305 | 1.22592122e+10 | 11.4172811 | 0 | 0 | 3935 | 4017 | 4017 | `2cf726772c9ab549` |
| source_over_blend | runtime | 67.5084122 | 540067297 | 0.502976866 | 0 | 0 | 853227 | 998549 | 998549 | `d5f99fe5b4e7eef8` |
| sprite_draw | runtime | 0 | 404848095 | 0.377044171 | 790718.936 | 0 | 161878 | 179598 | 179598 | `e73fc1dc4f99be0c` |
| frame | runtime | 0 | 1.45373819e+09 | 1.35389919 | 0 | 4021.71727 | 248650 | 258014 | 258014 | `2e480a89ab6181ef` |

### c5422df938371235922c52be7dcb911afb3daed3

- Entry semantics: benchmarked source commit; the history append commit follows this source commit.
- UTC: 2026-08-23T12:09:20Z
- Schema/workload: v3 / `zpu-2d-host-memory-v3-240x240-seed-151521030`
- Zig/compiler: `0.16.0`; build mode: `ReleaseFast`
- Trusted CPU: `AMD EPYC 7V13 64-Core Processor`; topology: `0:0@0;0:1@1;0:2@2;0:3@3;0:4@4;0:5@5;0:6@6;0:7@7`; affinity: `0,1,2,3,4,5,6,7`
- Threads: configured `8`, observed `8`
- Available backends: avx2, runtime, scalar
- Baseline comparison: `passed`

| name | backend | MPix/s | bytes/s | modeled GiB/s | draws/s | FPS | p50 ns | p95 ns | p99 ns | checksum_hex |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---|
| clear | scalar | 3891.10315 | 1.55644126e+10 | 14.4954888 | 0 | 0 | 14803 | 15451 | 15451 | `89fcf336d86c4f25` |
| pixel_write | scalar | 107.068172 | 428272689 | 0.398860024 | 0 | 0 | 4782 | 9736 | 9736 | `3d0737332ec9e1cc` |
| clipped_rectangle | scalar | 2064.71495 | 8.25885978e+09 | 7.69166256 | 0 | 0 | 5841 | 15313 | 15313 | `2cf726772c9ab549` |
| vulkan_host_memory_fill | scalar | 6155.81917 | 2.46232767e+10 | 22.9322134 | 0 | 0 | 9357 | 15937 | 15937 | `50dbc316a6090325` |
| vulkan_host_memory_copy | scalar | 995.317171 | 7.96253737e+09 | 7.4156908 | 0 | 0 | 57871 | 68589 | 68589 | `4e61ac2d0cc0777b` |
| source_over_blend | scalar | 41.993924 | 335951392 | 0.312879115 | 0 | 0 | 1371627 | 1392424 | 1392424 | `d5f99fe5b4e7eef8` |
| sprite_draw | scalar | 0 | 395724896 | 0.368547529 | 772900.187 | 0 | 165610 | 179567 | 179567 | `e73fc1dc4f99be0c` |
| frame | scalar | 0 | 889744379 | 0.828639025 | 0 | 2461.44758 | 406265 | 423219 | 423219 | `2e480a89ab6181ef` |
| clear | avx2 | 15677.7354 | 6.27109418e+10 | 58.4041157 | 0 | 0 | 3674 | 10273 | 10273 | `89fcf336d86c4f25` |
| pixel_write | avx2 | 109.471884 | 437887535 | 0.407814546 | 0 | 0 | 4677 | 7730 | 7730 | `3d0737332ec9e1cc` |
| clipped_rectangle | avx2 | 3205.74163 | 1.28229665e+10 | 11.9423182 | 0 | 0 | 3762 | 8468 | 8468 | `2cf726772c9ab549` |
| source_over_blend | avx2 | 64.4956852 | 515965481 | 0.480530301 | 0 | 0 | 893083 | 927686 | 927686 | `d5f99fe5b4e7eef8` |
| sprite_draw | avx2 | 0 | 375859557 | 0.350046491 | 734100.698 | 0 | 174363 | 188365 | 188365 | `e73fc1dc4f99be0c` |
| frame | avx2 | 0 | 1.24572063e+09 | 1.16016774 | 0 | 3446.24377 | 290171 | 311062 | 311062 | `2e480a89ab6181ef` |
| clear | runtime | 14761.6607 | 5.90466427e+10 | 54.9914713 | 0 | 0 | 3902 | 11480 | 11480 | `89fcf336d86c4f25` |
| pixel_write | runtime | 103.246622 | 412986489 | 0.38462364 | 0 | 0 | 4959 | 13491 | 13491 | `3d0737332ec9e1cc` |
| clipped_rectangle | runtime | 3002.24048 | 1.20089619e+10 | 11.1842173 | 0 | 0 | 4017 | 11541 | 11541 | `2cf726772c9ab549` |
| source_over_blend | runtime | 63.0457673 | 504366138 | 0.46972757 | 0 | 0 | 913622 | 947687 | 947687 | `d5f99fe5b4e7eef8` |
| sprite_draw | runtime | 0 | 393940851 | 0.366886008 | 769415.725 | 0 | 166360 | 192143 | 192143 | `e73fc1dc4f99be0c` |
| frame | runtime | 0 | 1.3210006e+09 | 1.23027768 | 0 | 3654.50326 | 273635 | 291347 | 291347 | `2e480a89ab6181ef` |

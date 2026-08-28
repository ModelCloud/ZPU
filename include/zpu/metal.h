/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#ifndef ZPU_METAL_H
#define ZPU_METAL_H

#include <stdint.h>

/* Native ZPU CPU Metal-layer ABI. This is intentionally separate from the
 * Apple Objective-C framework ABI; it is the portable FFI surface used by
 * clients that select ZPU's CPU renderer. */
#define ZPU_METAL_ABI_VERSION 1u

typedef enum zpu_metal_workload {
    ZPU_METAL_2D = 0,
    ZPU_METAL_3D = 1,
} zpu_metal_workload;

typedef enum zpu_metal_pixel_format {
    ZPU_METAL_RGBA8_UNORM = 70,
    ZPU_METAL_BGRA8_UNORM = 80,
} zpu_metal_pixel_format;

typedef struct zpu_metal_color { float red, green, blue, alpha; } zpu_metal_color;
typedef struct zpu_metal_origin { uint32_t x, y, z; } zpu_metal_origin;
typedef struct zpu_metal_size { uint32_t width, height, depth; } zpu_metal_size;
typedef struct zpu_metal_region { zpu_metal_origin origin; zpu_metal_size size; } zpu_metal_region;

/* The implementation caps execution at one CPU core for 2D and two for 3D. */
static inline uint8_t zpu_metal_max_cpu_cores(zpu_metal_workload workload) {
    return workload == ZPU_METAL_2D ? 1u : 2u;
}

#endif

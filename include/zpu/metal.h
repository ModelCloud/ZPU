/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#ifndef ZPU_METAL_H
#define ZPU_METAL_H

#include <stdint.h>

/* Native ZPU CPU Metal-layer ABI. This is intentionally separate from the
 * Apple Objective-C framework ABI; it is the portable FFI surface used by
 * clients that select ZPU's CPU renderer. */
#define ZPU_METAL_ABI_VERSION 2u

typedef uint8_t zpu_metal_workload;
enum {
    ZPU_METAL_2D = 0,
    ZPU_METAL_3D = 1,
};

typedef uint16_t zpu_metal_pixel_format;
enum {
    ZPU_METAL_RGBA8_UNORM = 70,
    ZPU_METAL_BGRA8_UNORM = 80,
};

typedef uint8_t zpu_metal_load_action;
enum {
    ZPU_METAL_LOAD_DONT_CARE = 0,
    ZPU_METAL_LOAD_LOAD = 1,
    ZPU_METAL_LOAD_CLEAR = 2,
};

typedef uint8_t zpu_metal_store_action;
enum {
    ZPU_METAL_STORE_DONT_CARE = 0,
    ZPU_METAL_STORE_STORE = 1,
};

typedef uint8_t zpu_metal_primitive_type;
enum {
    ZPU_METAL_POINT = 0,
    ZPU_METAL_LINE = 1,
    ZPU_METAL_LINE_STRIP = 2,
    ZPU_METAL_TRIANGLE = 3,
    ZPU_METAL_TRIANGLE_STRIP = 4,
};

typedef uint8_t zpu_metal_cull_mode;
enum {
    ZPU_METAL_CULL_NONE = 0,
    ZPU_METAL_CULL_FRONT = 1,
    ZPU_METAL_CULL_BACK = 2,
};

typedef uint8_t zpu_metal_winding;
enum {
    ZPU_METAL_WINDING_CLOCKWISE = 0,
    ZPU_METAL_WINDING_COUNTER_CLOCKWISE = 1,
};

typedef uint8_t zpu_metal_triangle_fill_mode;
enum {
    ZPU_METAL_FILL = 0,
    ZPU_METAL_LINES = 1,
};

typedef struct zpu_metal_color { float red, green, blue, alpha; } zpu_metal_color;
typedef struct zpu_metal_origin { uint32_t x, y, z; } zpu_metal_origin;
typedef struct zpu_metal_size { uint32_t width, height, depth; } zpu_metal_size;
typedef struct zpu_metal_region { zpu_metal_origin origin; zpu_metal_size size; } zpu_metal_region;
typedef struct zpu_metal_viewport {
    float origin_x, origin_y, width, height, znear, zfar;
} zpu_metal_viewport;
typedef struct zpu_metal_scissor_rect {
    uint32_t x, y, width, height;
} zpu_metal_scissor_rect;
typedef struct zpu_metal_vertex {
    float position[4];
    zpu_metal_color color;
} zpu_metal_vertex;
typedef struct zpu_metal_render_pass_color_attachment_descriptor {
    zpu_metal_load_action load_action;
    zpu_metal_store_action store_action;
    zpu_metal_color clear_color;
} zpu_metal_render_pass_color_attachment_descriptor;
typedef struct zpu_metal_render_pass_depth_attachment_descriptor {
    zpu_metal_load_action load_action;
    zpu_metal_store_action store_action;
    float clear_depth;
} zpu_metal_render_pass_depth_attachment_descriptor;
typedef struct zpu_metal_render_pass_descriptor {
    zpu_metal_render_pass_color_attachment_descriptor color;
    zpu_metal_render_pass_depth_attachment_descriptor depth;
} zpu_metal_render_pass_descriptor;

/* The implementation caps execution at one CPU core for 2D and two for 3D. */
static inline uint8_t zpu_metal_max_cpu_cores(zpu_metal_workload workload) {
    return workload == ZPU_METAL_2D ? 1u : 2u;
}

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(zpu_metal_color) == 16, "Metal color ABI drift");
_Static_assert(sizeof(zpu_metal_vertex) == 32, "Metal vertex ABI drift");
_Static_assert(sizeof(zpu_metal_viewport) == 24, "Metal viewport ABI drift");
_Static_assert(sizeof(zpu_metal_render_pass_descriptor) == 28, "Metal pass ABI drift");
#endif

#endif

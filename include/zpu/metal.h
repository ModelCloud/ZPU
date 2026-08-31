/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#ifndef ZPU_METAL_H
#define ZPU_METAL_H

#include <stddef.h>
#include <stdint.h>

/* Native ZPU CPU Metal-layer ABI. This is intentionally separate from the
 * Apple Objective-C framework ABI; it is the portable FFI surface used by
 * clients that select ZPU's CPU renderer. */
#define ZPU_METAL_ABI_VERSION 38u

typedef uint8_t zpu_metal_workload;
enum {
    ZPU_METAL_2D = 0,
    ZPU_METAL_3D = 1,
};

typedef uint16_t zpu_metal_pixel_format;
enum {
    ZPU_METAL_A8_UNORM = 1,
    ZPU_METAL_R8_UNORM = 10,
    ZPU_METAL_R8_UNORM_SRGB = 11,
    ZPU_METAL_R8_SNORM = 12,
    ZPU_METAL_R8_UINT = 13,
    ZPU_METAL_R8_SINT = 14,
    ZPU_METAL_R16_UNORM = 20,
    ZPU_METAL_R16_SNORM = 22,
    ZPU_METAL_R16_UINT = 23,
    ZPU_METAL_R16_SINT = 24,
    ZPU_METAL_R16_FLOAT = 25,
    ZPU_METAL_RG8_UNORM = 30,
    ZPU_METAL_RG8_UNORM_SRGB = 31,
    ZPU_METAL_RG8_SNORM = 32,
    ZPU_METAL_RG8_UINT = 33,
    ZPU_METAL_RG8_SINT = 34,
    ZPU_METAL_RG16_UNORM = 60,
    ZPU_METAL_RG16_SNORM = 62,
    ZPU_METAL_RG16_UINT = 63,
    ZPU_METAL_RG16_SINT = 64,
    ZPU_METAL_RG16_FLOAT = 65,
    ZPU_METAL_R32_UINT = 53,
    ZPU_METAL_R32_SINT = 54,
    ZPU_METAL_RGBA8_UNORM = 70,
    ZPU_METAL_RGBA8_UNORM_SRGB = 71,
    ZPU_METAL_RGBA8_SNORM = 72,
    ZPU_METAL_RGBA8_UINT = 73,
    ZPU_METAL_RGBA8_SINT = 74,
    ZPU_METAL_BGRA8_UNORM = 80,
    ZPU_METAL_BGRA8_UNORM_SRGB = 81,
    ZPU_METAL_B5G6R5_UNORM = 40,
    ZPU_METAL_A1BGR5_UNORM = 41,
    ZPU_METAL_ABGR4_UNORM = 42,
    ZPU_METAL_BGR5A1_UNORM = 43,
    ZPU_METAL_RGB10A2_UNORM = 90,
    ZPU_METAL_RGB10A2_UINT = 91,
    ZPU_METAL_RG11B10_FLOAT = 92,
    ZPU_METAL_RGB9E5_FLOAT = 93,
    ZPU_METAL_BGR10A2_UNORM = 94,
    ZPU_METAL_R32_FLOAT = 55,
    ZPU_METAL_RGBA16_UNORM = 110,
    ZPU_METAL_RGBA16_SNORM = 112,
    ZPU_METAL_RGBA16_UINT = 113,
    ZPU_METAL_RGBA16_SINT = 114,
    ZPU_METAL_RGBA16_FLOAT = 115,
    ZPU_METAL_RG32_FLOAT = 105,
    ZPU_METAL_RG32_UINT = 103,
    ZPU_METAL_RG32_SINT = 104,
    ZPU_METAL_RGBA32_FLOAT = 125,
    ZPU_METAL_RGBA32_UINT = 123,
    ZPU_METAL_RGBA32_SINT = 124,
    ZPU_METAL_DEPTH32_FLOAT = 252,
    ZPU_METAL_STENCIL8 = 253,
    ZPU_METAL_DEPTH16_UNORM = 250,
    ZPU_METAL_DEPTH24_UNORM_STENCIL8 = 255,
    ZPU_METAL_DEPTH32_FLOAT_STENCIL8 = 260,
    ZPU_METAL_X32_STENCIL8 = 261,
    ZPU_METAL_X24_STENCIL8 = 262,
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

typedef uint8_t zpu_metal_index_type;
enum {
    ZPU_METAL_INDEX_UINT16 = 0,
    ZPU_METAL_INDEX_UINT32 = 1,
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

typedef uint8_t zpu_metal_depth_clip_mode;
enum {
    ZPU_METAL_DEPTH_CLIP = 0,
    ZPU_METAL_DEPTH_CLAMP = 1,
};

typedef uint8_t zpu_metal_sampler_filter;
enum {
    ZPU_METAL_SAMPLER_NEAREST = 0,
    ZPU_METAL_SAMPLER_LINEAR = 1,
};

typedef uint8_t zpu_metal_sampler_mip_filter;
enum {
    ZPU_METAL_SAMPLER_NOT_MIPMAPPED = 0,
    ZPU_METAL_SAMPLER_MIP_NEAREST = 1,
    ZPU_METAL_SAMPLER_MIP_LINEAR = 2,
};

typedef uint8_t zpu_metal_sampler_reduction_mode;
enum {
    ZPU_METAL_SAMPLER_REDUCTION_WEIGHTED_AVERAGE = 0,
    ZPU_METAL_SAMPLER_REDUCTION_MINIMUM = 1,
    ZPU_METAL_SAMPLER_REDUCTION_MAXIMUM = 2,
};

typedef uint8_t zpu_metal_sampler_address_mode;
enum {
    ZPU_METAL_SAMPLER_CLAMP_TO_EDGE = 0,
    ZPU_METAL_SAMPLER_MIRROR_CLAMP_TO_EDGE = 1,
    ZPU_METAL_SAMPLER_REPEAT = 2,
    ZPU_METAL_SAMPLER_MIRROR_REPEAT = 3,
    ZPU_METAL_SAMPLER_CLAMP_TO_ZERO = 4,
    ZPU_METAL_SAMPLER_CLAMP_TO_BORDER_COLOR = 5,
};

typedef uint8_t zpu_metal_sampler_border_color;
enum {
    ZPU_METAL_SAMPLER_BORDER_TRANSPARENT_BLACK = 0,
    ZPU_METAL_SAMPLER_BORDER_OPAQUE_BLACK = 1,
    ZPU_METAL_SAMPLER_BORDER_OPAQUE_WHITE = 2,
};

typedef uint8_t zpu_metal_texture_swizzle;
enum {
    ZPU_METAL_TEXTURE_SWIZZLE_ZERO = 0,
    ZPU_METAL_TEXTURE_SWIZZLE_ONE = 1,
    ZPU_METAL_TEXTURE_SWIZZLE_RED = 2,
    ZPU_METAL_TEXTURE_SWIZZLE_GREEN = 3,
    ZPU_METAL_TEXTURE_SWIZZLE_BLUE = 4,
    ZPU_METAL_TEXTURE_SWIZZLE_ALPHA = 5,
};

typedef uint8_t zpu_metal_compare_function;
enum {
    ZPU_METAL_COMPARE_NEVER = 0,
    ZPU_METAL_COMPARE_LESS = 1,
    ZPU_METAL_COMPARE_EQUAL = 2,
    ZPU_METAL_COMPARE_LESS_EQUAL = 3,
    ZPU_METAL_COMPARE_GREATER = 4,
    ZPU_METAL_COMPARE_NOT_EQUAL = 5,
    ZPU_METAL_COMPARE_GREATER_EQUAL = 6,
    ZPU_METAL_COMPARE_ALWAYS = 7,
};

typedef uint8_t zpu_metal_stencil_operation;
enum {
    ZPU_METAL_STENCIL_KEEP = 0,
    ZPU_METAL_STENCIL_ZERO = 1,
    ZPU_METAL_STENCIL_REPLACE = 2,
    ZPU_METAL_STENCIL_INCREMENT_CLAMP = 3,
    ZPU_METAL_STENCIL_DECREMENT_CLAMP = 4,
    ZPU_METAL_STENCIL_INVERT = 5,
    ZPU_METAL_STENCIL_INCREMENT_WRAP = 6,
    ZPU_METAL_STENCIL_DECREMENT_WRAP = 7,
};

typedef uint8_t zpu_metal_blend_factor;
enum {
    ZPU_METAL_BLEND_ZERO = 0,
    ZPU_METAL_BLEND_ONE = 1,
    ZPU_METAL_BLEND_SOURCE_COLOR = 2,
    ZPU_METAL_BLEND_ONE_MINUS_SOURCE_COLOR = 3,
    ZPU_METAL_BLEND_SOURCE_ALPHA = 4,
    ZPU_METAL_BLEND_ONE_MINUS_SOURCE_ALPHA = 5,
    ZPU_METAL_BLEND_DESTINATION_COLOR = 6,
    ZPU_METAL_BLEND_ONE_MINUS_DESTINATION_COLOR = 7,
    ZPU_METAL_BLEND_DESTINATION_ALPHA = 8,
    ZPU_METAL_BLEND_ONE_MINUS_DESTINATION_ALPHA = 9,
    ZPU_METAL_BLEND_SOURCE_ALPHA_SATURATED = 10,
    ZPU_METAL_BLEND_BLEND_COLOR = 11,
    ZPU_METAL_BLEND_ONE_MINUS_BLEND_COLOR = 12,
    ZPU_METAL_BLEND_BLEND_ALPHA = 13,
    ZPU_METAL_BLEND_ONE_MINUS_BLEND_ALPHA = 14,
};

typedef uint8_t zpu_metal_blend_operation;
enum {
    ZPU_METAL_BLEND_ADD = 0,
    ZPU_METAL_BLEND_SUBTRACT = 1,
    ZPU_METAL_BLEND_REVERSE_SUBTRACT = 2,
    ZPU_METAL_BLEND_MIN = 3,
    ZPU_METAL_BLEND_MAX = 4,
};

typedef uint8_t zpu_metal_color_write_mask;
enum {
    ZPU_METAL_COLOR_WRITE_NONE = 0,
    ZPU_METAL_COLOR_WRITE_RED = 1,
    ZPU_METAL_COLOR_WRITE_GREEN = 2,
    ZPU_METAL_COLOR_WRITE_BLUE = 4,
    ZPU_METAL_COLOR_WRITE_ALPHA = 8,
    ZPU_METAL_COLOR_WRITE_ALL = 15,
};

typedef uint8_t zpu_metal_visibility_result_mode;
enum {
    ZPU_METAL_VISIBILITY_DISABLED = 0,
    ZPU_METAL_VISIBILITY_BOOLEAN = 1,
    ZPU_METAL_VISIBILITY_COUNTING = 2,
};

typedef uint8_t zpu_metal_visibility_result_type;
enum {
    ZPU_METAL_VISIBILITY_RESET = 0,
    ZPU_METAL_VISIBILITY_ACCUMULATE = 1,
};

typedef struct zpu_metal_color { float red, green, blue, alpha; } zpu_metal_color;
/* Sample coordinates are pixel-local and top-left, matching Metal's
 * MTLSamplePosition convention: (0, 0) is the upper-left pixel corner and
 * both coordinates are in the half-open [0, 1) range. */
typedef struct zpu_metal_sample_position { float x, y; } zpu_metal_sample_position;
typedef struct zpu_metal_vertex_amplification_view_mapping {
    uint32_t viewport_array_index_offset;
    uint32_t render_target_array_index_offset;
} zpu_metal_vertex_amplification_view_mapping;
typedef struct zpu_metal_origin { uint32_t x, y, z; } zpu_metal_origin;
typedef struct zpu_metal_size { uint32_t width, height, depth; } zpu_metal_size;
typedef struct zpu_metal_region { zpu_metal_origin origin; zpu_metal_size size; } zpu_metal_region;
/* Pixel-grid coordinates follow Metal's render-target convention: (0, 0)
 * is the upper-left texel, viewport/scissor origins are in that same space,
 * and clip-space +Y maps toward decreasing row indices. No AppKit/UIKit
 * view-coordinate conversion is applied by this CPU ABI. */
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

#define ZPU_METAL_MAX_COLOR_ATTACHMENTS 8u

/* The opt-in C entry point below is a bounded ZPU rendering ABI.  It is not
 * a replacement for Apple's Objective-C Metal framework and does not make
 * MTLCreateSystemDefaultDevice return a ZPU object. */
typedef struct zpu_metal_draw_state {
    zpu_metal_viewport viewport;
    zpu_metal_scissor_rect scissor;
    zpu_metal_cull_mode cull_mode;
    zpu_metal_winding winding;
    zpu_metal_triangle_fill_mode fill_mode;
} zpu_metal_draw_state;

typedef struct zpu_metal_surface {
    uint8_t *pixels;
    size_t byte_length;
    uint32_t width;
    uint32_t height;
    size_t stride;
    zpu_metal_pixel_format format;
} zpu_metal_surface;

typedef struct zpu_metal_stats {
    uint64_t primitives_submitted;
    uint64_t primitives_rasterized;
    uint64_t fragments_tested;
    uint64_t fragments_covered;
    uint64_t depth_tests_passed;
    uint64_t color_writes;
} zpu_metal_stats;

/* Opaque handles for the opt-in command/resource ABI.  These names mirror
 * Metal's ownership graph, but they are not Objective-C MTL protocols.  A
 * caller must destroy resources after all command buffers referring to them
 * have completed. */
typedef struct zpu_metal_device zpu_metal_device;
typedef struct zpu_metal_command_queue zpu_metal_command_queue;
typedef struct zpu_metal_command_buffer zpu_metal_command_buffer;
typedef struct zpu_metal_render_encoder zpu_metal_render_encoder;
typedef struct zpu_metal_blit_encoder zpu_metal_blit_encoder;
typedef struct zpu_metal_resource_state_encoder zpu_metal_resource_state_encoder;
typedef struct zpu_metal_compute_encoder zpu_metal_compute_encoder;
typedef struct zpu_metal_buffer zpu_metal_buffer;
typedef struct zpu_metal_texture zpu_metal_texture;
typedef struct zpu_metal_heap zpu_metal_heap;
typedef struct zpu_metal_fence zpu_metal_fence;
typedef struct zpu_metal_shared_event zpu_metal_shared_event;

typedef struct zpu_metal_texture_descriptor {
    uint32_t width;
    uint32_t height;
    zpu_metal_pixel_format format;
} zpu_metal_texture_descriptor;

typedef struct zpu_metal_heap_descriptor {
    size_t size;
} zpu_metal_heap_descriptor;

/* Placement-sparse buffers use CPU-owned ZPU pages. The public contents
 * pointer is intentionally NULL for these resources; ordinary copy/fill
 * commands provide the access path, matching private Metal resources. */
enum {
    ZPU_METAL_SPARSE_PAGE_SIZE_16K = 16u * 1024u,
    ZPU_METAL_SPARSE_PAGE_SIZE_64K = 64u * 1024u,
    ZPU_METAL_SPARSE_PAGE_SIZE_256K = 256u * 1024u,
};

typedef uint8_t zpu_metal_sparse_mapping_mode;
enum {
    ZPU_METAL_SPARSE_MAPPING_MAP = 0,
    ZPU_METAL_SPARSE_MAPPING_UNMAP = 1,
};

/* Layout-compatible with Apple's MTLMapIndirectArguments after the six
 * 32-bit region coordinates. The count word precedes an array of these
 * records in the indirect buffer. */
typedef struct zpu_metal_sparse_texture_mapping_arguments {
    zpu_metal_region region;
    uint32_t mip_level;
    uint32_t slice;
} zpu_metal_sparse_texture_mapping_arguments;

/* CPU compute kernels are explicit ZPU operations.  They are not MSL and
 * do not invoke Apple's Metal compiler or command encoder. */
typedef uint8_t zpu_metal_compute_kernel;
enum {
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8 = 1,
    ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE = 2,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY = 3,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D = 4,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT = 5,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT = 6,
    /* Fixed CPU ray-query profile: orthographic primary rays against the
     * triangle payload produced by the ZPU acceleration encoder. */
    ZPU_METAL_COMPUTE_TRACE_TRIANGLES_RGBA8 = 7,
    /* Fixed CPU buffer arithmetic profile. Bind left/right/output buffers at
     * indices 0/1/2 and dispatch one thread per Float32 element. */
    ZPU_METAL_COMPUTE_ADD_F32 = 8,
    ZPU_METAL_COMPUTE_MUL_F32 = 9,
    /* Fixed CPU integer-texture profiles. The kernels write all four
     * RGBA32 lanes directly, preserving the texture's native uint/sint
     * storage width and the Metal upper-left dispatch grid. */
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA32_UINT = 10,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA32_SINT = 11,
    /* Fixed CPU integer-texture profiles for scalar and dual-channel
     * 32-bit targets. Unused lanes are ignored by the target format. */
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_UINT = 12,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_SINT = 13,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG32_UINT = 14,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG32_SINT = 15,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R8_UINT = 16,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R8_SINT = 17,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG8_UINT = 18,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG8_SINT = 19,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_UINT = 20,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_SINT = 21,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R16_UINT = 22,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_R16_SINT = 23,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG16_UINT = 24,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RG16_SINT = 25,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_UINT = 26,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_SINT = 27,
    ZPU_METAL_COMPUTE_FILL_GRADIENT_RGB10A2_UINT = 28,
};

#define ZPU_METAL_CPU_ACCELERATION_STRUCTURE_MAGIC 0x5a505541u
#define ZPU_METAL_CPU_ACCELERATION_STRUCTURE_VERSION 1u
#define ZPU_METAL_CPU_ACCELERATION_STRUCTURE_HEADER_BYTES 32u
#define ZPU_METAL_CPU_ACCELERATION_STRUCTURE_TRIANGLE_OFFSET 256u

/* Stable little-endian CPU payload shared by the Objective-C adapter and the
 * ZPU runtime. The payload is intentionally a registered profile rather than
 * an Apple hardware BVH representation. */
typedef struct zpu_metal_cpu_acceleration_structure_header {
    uint32_t magic;
    uint32_t version;
    uint32_t triangle_count;
    uint32_t flags;
    uint32_t triangle_offset;
    uint32_t reserved[3];
} zpu_metal_cpu_acceleration_structure_header;

typedef struct zpu_metal_cpu_acceleration_triangle {
    float positions[9];
} zpu_metal_cpu_acceleration_triangle;

/* Tile kernels are explicit CPU/ZPU operations. They are not MSL and do not
 * invoke Apple's Metal tile encoder. The bounded profile emits one logical
 * pixel per tile thread in attachment-global top-left coordinates, clipped
 * by the recorded scissor and passed through fixed-function depth/stencil and
 * color-write state at profile depth 0.5. */
typedef uint8_t zpu_metal_tile_kernel;
enum {
    ZPU_METAL_TILE_FILL_GRADIENT_RGBA8 = 1,
};

/* Mesh kernels are explicit CPU/ZPU operations. They are not MSL and do not
 * invoke Apple's Metal mesh encoder. The bounded profile emits one logical
 * pixel per mesh-grid thread in the upper-left-origin render target, clipped
 * by the recorded attachment-global scissor rectangle, at fixed profile
 * depth 0.5 through the ordinary depth/stencil/color-write path. */
typedef uint8_t zpu_metal_mesh_kernel;
enum {
    ZPU_METAL_MESH_FILL_GRADIENT_RGBA8 = 1,
};

/* Triangle-patch kernels are explicit CPU/ZPU operations. They are not MSL
 * and do not invoke Apple's Metal tessellator. The bounded profile accepts
 * uniform integer factors 1 through 16; filled patches use the equivalent
 * ordinary top-left-origin triangle while line-filled patches expose the
 * generated CPU triangle grid. */
typedef uint8_t zpu_metal_patch_kernel;
enum {
    ZPU_METAL_PATCH_TRIANGLE_RGBA8 = 1,
};

typedef uint8_t zpu_metal_tessellation_control_point_index_type;
enum {
    ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_NONE = 0,
    ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_UINT16 = 1,
    ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_UINT32 = 2,
};

typedef uint8_t zpu_metal_command_buffer_status;
enum {
    ZPU_METAL_COMMAND_BUFFER_CREATED = 0,
    ZPU_METAL_COMMAND_BUFFER_COMMITTED = 1,
    ZPU_METAL_COMMAND_BUFFER_COMPLETED = 2,
    ZPU_METAL_COMMAND_BUFFER_ERROR = 3,
};

enum {
    ZPU_METAL_OK = 0,
    ZPU_METAL_INVALID_ARGUMENT = -1,
    ZPU_METAL_UNSUPPORTED_FORMAT = -2,
    ZPU_METAL_INVALID_DEPTH = -3,
    ZPU_METAL_INVALID_COMMAND = -4,
    ZPU_METAL_OUT_OF_MEMORY = -5,
    ZPU_METAL_UNSUPPORTED_OPERATION = -6,
};

/* Execute one complete, shader-independent render pass through ZPU's CPU
 * Metal-shaped layer. All pointers are borrowed for the duration of the
 * call. The function is deterministic and writes only the supplied surface
 * and optional depth buffer. */
int zpu_metal_render(
    zpu_metal_surface *surface,
    const zpu_metal_render_pass_descriptor *pass,
    const zpu_metal_draw_state *state,
    const zpu_metal_vertex *vertices,
    size_t vertex_count,
    zpu_metal_primitive_type primitive,
    float *depth,
    size_t depth_count,
    zpu_metal_stats *stats);

/* Core resource and command-buffer operations.  The CPU implementation is
 * deterministic and completes a committed buffer synchronously; the status
 * API is retained so clients can use the same lifecycle checks as Metal. */
zpu_metal_device *zpu_metal_device_create(void);
void zpu_metal_device_destroy(zpu_metal_device *device);
zpu_metal_command_queue *zpu_metal_device_new_command_queue(zpu_metal_device *device);
void zpu_metal_command_queue_destroy(zpu_metal_command_queue *queue);
zpu_metal_buffer *zpu_metal_device_new_buffer(zpu_metal_device *device, size_t length, const void *initial_bytes);
zpu_metal_buffer *zpu_metal_device_new_sparse_buffer(zpu_metal_device *device, size_t length, size_t page_bytes);
zpu_metal_buffer *zpu_metal_device_new_buffer_no_copy(zpu_metal_device *device, size_t length, void *bytes);
void zpu_metal_buffer_destroy(zpu_metal_buffer *buffer);
zpu_metal_texture *zpu_metal_buffer_new_texture(zpu_metal_buffer *buffer, const zpu_metal_texture_descriptor *descriptor, size_t offset, size_t bytes_per_row);
size_t zpu_metal_buffer_length(const zpu_metal_buffer *buffer);
void *zpu_metal_buffer_contents(zpu_metal_buffer *buffer);
int zpu_metal_buffer_is_sparse(const zpu_metal_buffer *buffer);
size_t zpu_metal_buffer_sparse_page_size(const zpu_metal_buffer *buffer);
size_t zpu_metal_buffer_heap_offset(const zpu_metal_buffer *buffer);
int zpu_metal_buffer_write(zpu_metal_buffer *buffer, size_t offset, const void *bytes, size_t length);
zpu_metal_texture *zpu_metal_device_new_texture(zpu_metal_device *device, const zpu_metal_texture_descriptor *descriptor);
zpu_metal_texture *zpu_metal_device_new_sparse_texture(zpu_metal_device *device, const zpu_metal_texture_descriptor *descriptor, size_t page_bytes);
zpu_metal_heap *zpu_metal_device_new_heap(zpu_metal_device *device, size_t size);
void zpu_metal_heap_destroy(zpu_metal_heap *heap);
size_t zpu_metal_heap_size(const zpu_metal_heap *heap);
size_t zpu_metal_heap_used_size(const zpu_metal_heap *heap);
size_t zpu_metal_heap_max_available_size(const zpu_metal_heap *heap, size_t alignment);
zpu_metal_buffer *zpu_metal_heap_new_buffer(zpu_metal_heap *heap, size_t length, const void *initial_bytes);
zpu_metal_buffer *zpu_metal_heap_new_buffer_at_offset(zpu_metal_heap *heap, size_t length, const void *initial_bytes, size_t offset);
zpu_metal_texture *zpu_metal_heap_new_texture(zpu_metal_heap *heap, const zpu_metal_texture_descriptor *descriptor);
zpu_metal_texture *zpu_metal_heap_new_texture_at_offset(zpu_metal_heap *heap, const zpu_metal_texture_descriptor *descriptor, size_t offset);
void zpu_metal_texture_destroy(zpu_metal_texture *texture);
/* Creates a shared-storage view with a Metal-compatible pixel format. The
 * source remains the owner of its bytes; destroy the returned view handle
 * before releasing the source texture. */
zpu_metal_texture *zpu_metal_texture_view(const zpu_metal_texture *texture, zpu_metal_pixel_format format);
uint32_t zpu_metal_texture_width(const zpu_metal_texture *texture);
uint32_t zpu_metal_texture_height(const zpu_metal_texture *texture);
int zpu_metal_texture_is_sparse(const zpu_metal_texture *texture);
size_t zpu_metal_texture_sparse_page_size(const zpu_metal_texture *texture);
size_t zpu_metal_texture_sparse_tile_width(const zpu_metal_texture *texture);
size_t zpu_metal_texture_sparse_tile_height(const zpu_metal_texture *texture);
size_t zpu_metal_texture_heap_offset(const zpu_metal_texture *texture);
int zpu_metal_texture_get_bytes(const zpu_metal_texture *texture, void *destination, size_t destination_length, size_t bytes_per_row, zpu_metal_region region);
int zpu_metal_texture_replace_region(zpu_metal_texture *texture, zpu_metal_region region, const void *source, size_t source_length, size_t bytes_per_row);
zpu_metal_fence *zpu_metal_device_new_fence(zpu_metal_device *device);
void zpu_metal_fence_destroy(zpu_metal_fence *fence);
zpu_metal_device *zpu_metal_fence_device(const zpu_metal_fence *fence);
zpu_metal_shared_event *zpu_metal_device_new_shared_event(zpu_metal_device *device);
void zpu_metal_shared_event_destroy(zpu_metal_shared_event *event);
uint64_t zpu_metal_shared_event_signaled_value(const zpu_metal_shared_event *event);
int zpu_metal_shared_event_set_signaled_value(zpu_metal_shared_event *event, uint64_t value);
int zpu_metal_shared_event_wait_until_signaled_value(const zpu_metal_shared_event *event, uint64_t value, uint64_t timeout_ms);

zpu_metal_command_buffer *zpu_metal_command_queue_command_buffer(zpu_metal_command_queue *queue);
void zpu_metal_command_buffer_destroy(zpu_metal_command_buffer *command_buffer);
zpu_metal_command_buffer_status zpu_metal_command_buffer_get_status(const zpu_metal_command_buffer *command_buffer);
void zpu_metal_command_buffer_mark_error(zpu_metal_command_buffer *command_buffer);
int zpu_metal_command_buffer_commit(zpu_metal_command_buffer *command_buffer);
int zpu_metal_command_buffer_wait_until_completed(zpu_metal_command_buffer *command_buffer);
int zpu_metal_command_buffer_encode_signal_event(zpu_metal_command_buffer *command_buffer, zpu_metal_shared_event *event, uint64_t value);
int zpu_metal_command_buffer_encode_wait_for_event(zpu_metal_command_buffer *command_buffer, zpu_metal_shared_event *event, uint64_t value);

zpu_metal_render_encoder *zpu_metal_command_buffer_render_encoder(
    zpu_metal_command_buffer *command_buffer,
    zpu_metal_texture *color_texture,
    const zpu_metal_render_pass_descriptor *pass);
int zpu_metal_render_encoder_set_vertex_buffer(zpu_metal_render_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, uint32_t index);
int zpu_metal_render_encoder_set_vertex_buffer_stride(zpu_metal_render_encoder *encoder, size_t stride);
int zpu_metal_render_encoder_set_vertex_bytes(zpu_metal_render_encoder *encoder, const void *bytes, size_t length, uint32_t index);
int zpu_metal_render_encoder_set_viewport(zpu_metal_render_encoder *encoder, zpu_metal_viewport viewport);
/* The CPU profile records up to Metal's sixteen viewport entries. The array
 * index selected by a vertex-amplification mapping is resolved at commit time
 * without changing Apple's attachment-global top-left pixel origin. */
int zpu_metal_render_encoder_set_viewports(zpu_metal_render_encoder *encoder, const zpu_metal_viewport *viewports, size_t count);
int zpu_metal_render_encoder_set_scissor_rect(zpu_metal_render_encoder *encoder, zpu_metal_scissor_rect scissor);
int zpu_metal_render_encoder_set_scissor_rects(zpu_metal_render_encoder *encoder, const zpu_metal_scissor_rect *scissors, size_t count);
int zpu_metal_render_encoder_set_cull_mode(zpu_metal_render_encoder *encoder, zpu_metal_cull_mode cull_mode);
int zpu_metal_render_encoder_set_front_facing(zpu_metal_render_encoder *encoder, zpu_metal_winding winding);
int zpu_metal_render_encoder_set_triangle_fill_mode(zpu_metal_render_encoder *encoder, zpu_metal_triangle_fill_mode fill_mode);
int zpu_metal_render_encoder_set_depth_clip_mode(zpu_metal_render_encoder *encoder, zpu_metal_depth_clip_mode depth_clip_mode);
int zpu_metal_render_encoder_set_depth_bias(zpu_metal_render_encoder *encoder, float depth_bias, float slope_scale, float clamp);
int zpu_metal_render_encoder_set_depth_test_bounds(zpu_metal_render_encoder *encoder, float min_bound, float max_bound);
int zpu_metal_render_encoder_set_pipeline_formats(zpu_metal_render_encoder *encoder, uint16_t color_format, uint16_t depth_format);
int zpu_metal_render_encoder_set_pipeline_formats_with_stencil(zpu_metal_render_encoder *encoder, uint16_t color_format, uint16_t depth_format, uint16_t stencil_format);
int zpu_metal_render_encoder_set_raster_sample_count(zpu_metal_render_encoder *encoder, uint8_t sample_count);
/* count 0 restores Apple's default sample table; otherwise count must match
 * the active 1x/2x/4x raster sample count. */
int zpu_metal_render_encoder_set_sample_positions(zpu_metal_render_encoder *encoder, const zpu_metal_sample_position *positions, size_t count);
/* Vertex amplification is CPU-expanded into ordered per-view draws. The
 * bounded profile supports Apple's two-view maximum and preserves the
 * top-left viewport grid; viewport/render-target array offsets select the
 * corresponding recorded CPU state and ZPU-owned slice. */
int zpu_metal_render_encoder_set_vertex_amplification_count(zpu_metal_render_encoder *encoder, size_t count, const zpu_metal_vertex_amplification_view_mapping *view_mappings);
/* Installs CPU-owned sample planes for a 2x/4x render target. The first
 * sample must be the color attachment passed to the render-encoder factory;
 * resolve_texture may be NULL when the multisample surface is intentionally
 * not resolved. */
int zpu_metal_render_encoder_set_multisample_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t sample_count, zpu_metal_texture *resolve_texture);
/* Layered draws select these ZPU-owned color/depth/stencil slices
 * by expanded instance index. The bounded CPU profile supports up to eight
 * layers; the registered tile profile broadcasts to each slice, supports a
 * contiguous RGBA8/BGRA8 attachment signature, and routes its logical output
 * through an opted-in color attachment map. The registered mesh profile
 * accepts the same contiguous RGBA8/BGRA8 attachment signature and routes its
 * logical outputs through an opted-in map. Uniform integer triangle patches honor
 * baseInstance, while the registered mesh-gradient profile maps mesh-grid Z to
 * layered slices and preserves attachment-global top-left X/Y; arbitrary mesh
 * shader execution remains rejected. Layered multisample
 * color attachments use the explicit per-layer sample-plane entry point below.
 * Direct and indirect primitive/indexed draws honor
 * baseInstance and select the corresponding slices. */
int zpu_metal_render_encoder_set_render_target_array(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *textures, size_t count);
int zpu_metal_render_encoder_set_color_attachment_array_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *textures, size_t count, const zpu_metal_render_pass_color_attachment_descriptor *attachment, uint32_t index);
int zpu_metal_render_encoder_set_depth_texture_array(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *textures, size_t count);
int zpu_metal_render_encoder_set_stencil_texture_array(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *textures, size_t count, uint8_t load_action, uint8_t store_action, uint8_t clear_value);
/* Installs per-sample CPU-owned color planes for an additional 2x/4x MRT
 * attachment and its optional matching single-sample resolve target. */
int zpu_metal_render_encoder_set_multisample_color_attachment_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t sample_count, zpu_metal_texture *resolve_texture, const zpu_metal_render_pass_color_attachment_descriptor *attachment, uint32_t index);
/* Installs flattened [array-slice][sample] CPU-owned color planes for a
 * layered 2x/4x render pass. resolve_textures may be NULL when no resolve is
 * requested; otherwise it contains one resolve target per array slice. */
int zpu_metal_render_encoder_set_multisample_color_attachment_array_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t array_count, size_t sample_count, zpu_metal_texture *const *resolve_textures, const zpu_metal_render_pass_color_attachment_descriptor *attachment, uint32_t index);
/* Installs per-sample CPU-owned depth planes for a 2x/4x render pass. */
int zpu_metal_render_encoder_set_multisample_depth_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t sample_count);
/* Installs flattened [array-slice][sample] CPU-owned depth planes for a
 * layered 2x/4x render pass. */
int zpu_metal_render_encoder_set_multisample_depth_attachment_array_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t array_count, size_t sample_count);
/* Installs per-sample CPU-owned stencil planes and their pass actions for a 2x/4x render pass. */
int zpu_metal_render_encoder_set_multisample_stencil_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t sample_count, zpu_metal_load_action load_action, zpu_metal_store_action store_action, uint8_t clear_value);
/* Installs flattened [array-slice][sample] CPU-owned stencil planes and pass
 * actions for a layered 2x/4x render pass. */
int zpu_metal_render_encoder_set_multisample_stencil_attachment_array_targets(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *sample_textures, size_t array_count, size_t sample_count, zpu_metal_load_action load_action, zpu_metal_store_action store_action, uint8_t clear_value);
int zpu_metal_render_encoder_set_color_attachment(zpu_metal_render_encoder *encoder, zpu_metal_texture *texture, const zpu_metal_render_pass_color_attachment_descriptor *attachment, uint32_t index);
/* Maps logical fragment outputs to physical pass attachments. A NULL map with
 * count 0 restores identity mapping; otherwise count must be exactly eight
 * unique indices in [0, 7]. */
int zpu_metal_render_encoder_set_color_attachment_map(zpu_metal_render_encoder *encoder, const uint8_t *logical_to_physical, size_t count);
int zpu_metal_render_encoder_set_color_store_action(zpu_metal_render_encoder *encoder, zpu_metal_store_action store_action, uint32_t index);
int zpu_metal_render_encoder_set_depth_store_action(zpu_metal_render_encoder *encoder, zpu_metal_store_action store_action);
int zpu_metal_render_encoder_set_stencil_store_action(zpu_metal_render_encoder *encoder, zpu_metal_store_action store_action);
int zpu_metal_render_encoder_set_pipeline_color_formats(zpu_metal_render_encoder *encoder, const uint16_t *color_formats, size_t color_format_count, uint16_t depth_format, uint16_t stencil_format);
int zpu_metal_render_encoder_set_multi_target_output(zpu_metal_render_encoder *encoder, int enabled);
int zpu_metal_render_encoder_set_sample_texture(zpu_metal_render_encoder *encoder, int enabled);
int zpu_metal_render_encoder_set_fragment_texture(zpu_metal_render_encoder *encoder, zpu_metal_texture *texture, uint32_t index);
int zpu_metal_render_encoder_set_fragment_texture_levels(zpu_metal_render_encoder *encoder, zpu_metal_texture *const *textures, size_t count, uint32_t index);
int zpu_metal_render_encoder_set_fragment_sampler(zpu_metal_render_encoder *encoder, zpu_metal_sampler_filter filter, zpu_metal_sampler_address_mode address_s, zpu_metal_sampler_address_mode address_t);
int zpu_metal_render_encoder_set_fragment_sampler_with_border(zpu_metal_render_encoder *encoder, zpu_metal_sampler_filter filter, zpu_metal_sampler_address_mode address_s, zpu_metal_sampler_address_mode address_t, zpu_metal_sampler_border_color border_color);
int zpu_metal_render_encoder_set_fragment_sampler_with_filters(zpu_metal_render_encoder *encoder, zpu_metal_sampler_filter min_filter, zpu_metal_sampler_filter mag_filter, zpu_metal_sampler_address_mode address_s, zpu_metal_sampler_address_mode address_t, zpu_metal_sampler_border_color border_color);
int zpu_metal_render_encoder_set_fragment_sampler_with_filters_and_mip_filter(zpu_metal_render_encoder *encoder, zpu_metal_sampler_filter min_filter, zpu_metal_sampler_filter mag_filter, zpu_metal_sampler_address_mode address_s, zpu_metal_sampler_address_mode address_t, zpu_metal_sampler_border_color border_color, zpu_metal_sampler_mip_filter mip_filter);
int zpu_metal_render_encoder_set_fragment_sampler_lod_clamps(zpu_metal_render_encoder *encoder, float lod_min_clamp, float lod_max_clamp);
int zpu_metal_render_encoder_set_fragment_sampler_lod_bias(zpu_metal_render_encoder *encoder, float lod_bias);
int zpu_metal_render_encoder_set_fragment_sampler_max_anisotropy(zpu_metal_render_encoder *encoder, uint32_t max_anisotropy);
int zpu_metal_render_encoder_set_fragment_sampler_normalized_coordinates(zpu_metal_render_encoder *encoder, int normalized_coordinates);
int zpu_metal_render_encoder_set_fragment_sampler_reduction_mode(zpu_metal_render_encoder *encoder, zpu_metal_sampler_reduction_mode reduction_mode);
int zpu_metal_render_encoder_set_fragment_texture_swizzle(zpu_metal_render_encoder *encoder, zpu_metal_texture_swizzle red, zpu_metal_texture_swizzle green, zpu_metal_texture_swizzle blue, zpu_metal_texture_swizzle alpha);
int zpu_metal_render_encoder_set_fragment_uniform_enabled(zpu_metal_render_encoder *encoder, int enabled);
/* Select the registered CPU fragment profile whose output is Metal's
 * attachment-global fragment position: ((x + 1) / 8, (y + 1) / 8, 1/4, 1).
 * The profile is CPU/ZPU-only and exists to make the top-left X/Y grid
 * contract testable against Apple's native oracle. */
int zpu_metal_render_encoder_set_fragment_position_gradient_enabled(zpu_metal_render_encoder *encoder, int enabled);
int zpu_metal_render_encoder_set_fragment_bytes(zpu_metal_render_encoder *encoder, const void *bytes, size_t length, uint32_t index);
int zpu_metal_render_encoder_set_fragment_buffer(zpu_metal_render_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, uint32_t index);
int zpu_metal_render_encoder_set_fragment_buffer_offset(zpu_metal_render_encoder *encoder, size_t offset, uint32_t index);
int zpu_metal_render_encoder_set_rasterization_enabled(zpu_metal_render_encoder *encoder, int enabled);
int zpu_metal_render_encoder_set_depth_compare_function(zpu_metal_render_encoder *encoder, zpu_metal_compare_function compare_function, int depth_write_enabled);
int zpu_metal_render_encoder_set_blend_state(zpu_metal_render_encoder *encoder, int blending_enabled,
    zpu_metal_blend_factor source_rgb_factor, zpu_metal_blend_factor destination_rgb_factor,
    zpu_metal_blend_operation rgb_operation, zpu_metal_blend_factor source_alpha_factor,
    zpu_metal_blend_factor destination_alpha_factor, zpu_metal_blend_operation alpha_operation,
    zpu_metal_color_write_mask write_mask);
int zpu_metal_render_encoder_set_blend_color(zpu_metal_render_encoder *encoder, zpu_metal_color color);
int zpu_metal_render_encoder_set_depth_texture(zpu_metal_render_encoder *encoder, zpu_metal_texture *texture);
int zpu_metal_render_encoder_set_depth_buffer(zpu_metal_render_encoder *encoder, float *depth, size_t depth_count);
int zpu_metal_render_encoder_set_stencil_texture(zpu_metal_render_encoder *encoder, zpu_metal_texture *texture, zpu_metal_load_action load_action, zpu_metal_store_action store_action, uint8_t clear_value);
int zpu_metal_render_encoder_set_stencil_state(zpu_metal_render_encoder *encoder, int front_face, zpu_metal_compare_function compare, zpu_metal_stencil_operation stencil_failure, zpu_metal_stencil_operation depth_failure, zpu_metal_stencil_operation depth_pass, uint8_t read_mask, uint8_t write_mask);
int zpu_metal_render_encoder_set_stencil_reference(zpu_metal_render_encoder *encoder, uint8_t front_reference, uint8_t back_reference);
int zpu_metal_render_encoder_set_visibility_result_buffer(zpu_metal_render_encoder *encoder, zpu_metal_buffer *buffer);
int zpu_metal_render_encoder_set_visibility_result_mode(zpu_metal_render_encoder *encoder, zpu_metal_visibility_result_mode mode, size_t offset);
int zpu_metal_render_encoder_set_visibility_result_type(zpu_metal_render_encoder *encoder, zpu_metal_visibility_result_type result_type);
/* Passing NULL unbinds the factor buffer, matching Metal's nullable selector. */
int zpu_metal_render_encoder_set_tessellation_factor_buffer(zpu_metal_render_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, size_t instance_stride);
int zpu_metal_render_encoder_set_tessellation_factor_scale(zpu_metal_render_encoder *encoder, float scale);
/* Sets the maximum factor enforced by the registered CPU triangle-patch
 * profile. The adapter supplies the value from the pipeline descriptor. */
int zpu_metal_render_encoder_set_patch_max_tessellation_factor(zpu_metal_render_encoder *encoder, uint32_t max_factor);
int zpu_metal_render_encoder_update_fence(zpu_metal_render_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_render_encoder_wait_for_fence(zpu_metal_render_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_render_encoder_draw_primitives(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t vertex_start, size_t vertex_count, size_t instance_count);
int zpu_metal_render_encoder_draw_primitives_base_instance(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t vertex_start, size_t vertex_count, size_t instance_count, size_t base_instance);
int zpu_metal_render_encoder_draw_primitives_indirect(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
int zpu_metal_render_encoder_draw_indexed_primitives(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t index_count, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, size_t instance_count);
int zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t index_count, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, size_t instance_count, int64_t base_vertex);
int zpu_metal_render_encoder_draw_indexed_primitives_base_vertex_instance(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t index_count, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, size_t instance_count, int64_t base_vertex, size_t base_instance);
int zpu_metal_render_encoder_draw_indexed_primitives_indirect(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
int zpu_metal_render_encoder_dispatch_threads_per_tile(zpu_metal_render_encoder *encoder, zpu_metal_tile_kernel kernel, zpu_metal_size tile_size, zpu_metal_size threads_per_tile);
int zpu_metal_render_encoder_draw_mesh_threadgroups(zpu_metal_render_encoder *encoder, zpu_metal_mesh_kernel kernel, zpu_metal_size threadgroups_per_grid, zpu_metal_size threads_per_object_threadgroup, zpu_metal_size threads_per_mesh_threadgroup);
int zpu_metal_render_encoder_draw_mesh_threads(zpu_metal_render_encoder *encoder, zpu_metal_mesh_kernel kernel, zpu_metal_size threads_per_grid, zpu_metal_size threads_per_object_threadgroup, zpu_metal_size threads_per_mesh_threadgroup);
int zpu_metal_render_encoder_draw_mesh_threadgroups_indirect(zpu_metal_render_encoder *encoder, zpu_metal_mesh_kernel kernel, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset, zpu_metal_size threads_per_object_threadgroup, zpu_metal_size threads_per_mesh_threadgroup);
int zpu_metal_render_encoder_draw_patches(zpu_metal_render_encoder *encoder, zpu_metal_patch_kernel kernel, uint32_t control_point_count, size_t patch_start, size_t patch_count, zpu_metal_buffer *patch_index_buffer, size_t patch_index_buffer_offset, size_t instance_count, size_t base_instance, zpu_metal_tessellation_control_point_index_type control_point_index_type, zpu_metal_buffer *control_point_index_buffer, size_t control_point_index_buffer_offset);
int zpu_metal_render_encoder_draw_patches_indirect(zpu_metal_render_encoder *encoder, zpu_metal_patch_kernel kernel, uint32_t control_point_count, zpu_metal_buffer *patch_index_buffer, size_t patch_index_buffer_offset, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset, zpu_metal_tessellation_control_point_index_type control_point_index_type, zpu_metal_buffer *control_point_index_buffer, size_t control_point_index_buffer_offset);
int zpu_metal_render_encoder_end_encoding(zpu_metal_render_encoder *encoder);
void zpu_metal_render_encoder_destroy(zpu_metal_render_encoder *encoder);

zpu_metal_blit_encoder *zpu_metal_command_buffer_blit_encoder(zpu_metal_command_buffer *command_buffer);
int zpu_metal_blit_encoder_copy_buffer(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *source, size_t source_offset, zpu_metal_buffer *destination, size_t destination_offset, size_t length);
int zpu_metal_blit_encoder_copy_buffer_to_texture(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *source, size_t source_offset, size_t source_bytes_per_row, zpu_metal_texture *destination, zpu_metal_region destination_region);
int zpu_metal_blit_encoder_copy_texture_to_buffer(zpu_metal_blit_encoder *encoder, zpu_metal_texture *source, zpu_metal_region source_region, zpu_metal_buffer *destination, size_t destination_offset, size_t destination_bytes_per_row);
int zpu_metal_blit_encoder_copy_texture_to_texture(zpu_metal_blit_encoder *encoder, zpu_metal_texture *source, zpu_metal_region source_region, zpu_metal_texture *destination, zpu_metal_region destination_region);
int zpu_metal_blit_encoder_generate_mipmap(zpu_metal_blit_encoder *encoder, zpu_metal_texture *source, zpu_metal_texture *destination);
int zpu_metal_blit_encoder_generate_mipmap_3d(zpu_metal_blit_encoder *encoder, zpu_metal_texture *source0, zpu_metal_texture *source1, zpu_metal_texture *destination);
int zpu_metal_blit_encoder_generate_mipmap_3d_weighted(zpu_metal_blit_encoder *encoder, zpu_metal_texture *source0, zpu_metal_texture *source1, zpu_metal_texture *destination, uint32_t source1_weight_numerator, uint32_t source1_weight_denominator);
int zpu_metal_blit_encoder_generate_mipmap_3d_array(zpu_metal_blit_encoder *encoder, zpu_metal_texture *const *source_planes, size_t source_count, zpu_metal_texture *destination);
int zpu_metal_blit_encoder_fill_buffer(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, size_t length, uint8_t value);
int zpu_metal_blit_encoder_synchronize_resource(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *buffer);
int zpu_metal_blit_encoder_update_fence(zpu_metal_blit_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_blit_encoder_wait_for_fence(zpu_metal_blit_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_blit_encoder_end_encoding(zpu_metal_blit_encoder *encoder);
void zpu_metal_blit_encoder_destroy(zpu_metal_blit_encoder *encoder);

zpu_metal_resource_state_encoder *zpu_metal_command_buffer_resource_state_encoder(zpu_metal_command_buffer *command_buffer);
int zpu_metal_resource_state_encoder_update_fence(zpu_metal_resource_state_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_resource_state_encoder_wait_for_fence(zpu_metal_resource_state_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_resource_state_encoder_update_buffer_mapping(zpu_metal_resource_state_encoder *encoder, zpu_metal_buffer *buffer, zpu_metal_sparse_mapping_mode mode, size_t offset, size_t length);
int zpu_metal_resource_state_encoder_copy_buffer_mappings(zpu_metal_resource_state_encoder *encoder, zpu_metal_buffer *source, zpu_metal_buffer *destination, size_t source_offset, size_t destination_offset, size_t length);
int zpu_metal_resource_state_encoder_update_texture_mapping(zpu_metal_resource_state_encoder *encoder, zpu_metal_texture *texture, zpu_metal_sparse_mapping_mode mode, zpu_metal_region region);
/* Regions are sparse-tile coordinates in the bounded portable profile. Each
 * mip-level and slice entry corresponds to one region entry; only level 0 and
 * slice 0 are currently representable by the portable 2D texture object. */
int zpu_metal_resource_state_encoder_update_texture_mappings(zpu_metal_resource_state_encoder *encoder, zpu_metal_texture *texture, zpu_metal_sparse_mapping_mode mode, const zpu_metal_region *regions, size_t region_count, const size_t *mip_levels, const size_t *slices);
int zpu_metal_resource_state_encoder_update_texture_mapping_indirect(zpu_metal_resource_state_encoder *encoder, zpu_metal_texture *texture, zpu_metal_sparse_mapping_mode mode, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
int zpu_metal_resource_state_encoder_move_texture_mappings(zpu_metal_resource_state_encoder *encoder, zpu_metal_texture *source, zpu_metal_texture *destination, zpu_metal_region source_region, zpu_metal_origin destination_origin);
int zpu_metal_resource_state_encoder_copy_texture_mappings(zpu_metal_resource_state_encoder *encoder, zpu_metal_texture *source, zpu_metal_texture *destination, zpu_metal_region source_region, zpu_metal_origin destination_origin);
int zpu_metal_resource_state_encoder_end_encoding(zpu_metal_resource_state_encoder *encoder);
void zpu_metal_resource_state_encoder_destroy(zpu_metal_resource_state_encoder *encoder);

zpu_metal_compute_encoder *zpu_metal_command_buffer_compute_encoder(zpu_metal_command_buffer *command_buffer);
int zpu_metal_compute_encoder_set_kernel(zpu_metal_compute_encoder *encoder, zpu_metal_compute_kernel kernel);
int zpu_metal_compute_encoder_set_buffer(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, uint32_t index);
int zpu_metal_compute_encoder_set_acceleration_structure(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *acceleration_structure, uint32_t index);
int zpu_metal_compute_encoder_set_buffer_offset(zpu_metal_compute_encoder *encoder, size_t offset, uint32_t index);
int zpu_metal_compute_encoder_set_bytes(zpu_metal_compute_encoder *encoder, const void *bytes, size_t length, uint32_t index);
int zpu_metal_compute_encoder_set_texture(zpu_metal_compute_encoder *encoder, zpu_metal_texture *texture, uint32_t index);
int zpu_metal_compute_encoder_set_array_slice(zpu_metal_compute_encoder *encoder, uint32_t slice, uint32_t index);
int zpu_metal_compute_encoder_copy_buffer(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *source, size_t source_offset, zpu_metal_buffer *destination, size_t destination_offset, size_t length);
int zpu_metal_compute_encoder_copy_buffer_to_texture(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *source, size_t source_offset, size_t source_bytes_per_row, zpu_metal_texture *destination, zpu_metal_region destination_region);
int zpu_metal_compute_encoder_copy_texture_to_buffer(zpu_metal_compute_encoder *encoder, zpu_metal_texture *source, zpu_metal_region source_region, zpu_metal_buffer *destination, size_t destination_offset, size_t destination_bytes_per_row);
int zpu_metal_compute_encoder_copy_texture_to_texture(zpu_metal_compute_encoder *encoder, zpu_metal_texture *source, zpu_metal_region source_region, zpu_metal_texture *destination, zpu_metal_region destination_region);
int zpu_metal_compute_encoder_generate_mipmap(zpu_metal_compute_encoder *encoder, zpu_metal_texture *source, zpu_metal_texture *destination);
int zpu_metal_compute_encoder_generate_mipmap_3d(zpu_metal_compute_encoder *encoder, zpu_metal_texture *source0, zpu_metal_texture *source1, zpu_metal_texture *destination);
int zpu_metal_compute_encoder_generate_mipmap_3d_weighted(zpu_metal_compute_encoder *encoder, zpu_metal_texture *source0, zpu_metal_texture *source1, zpu_metal_texture *destination, uint32_t source1_weight_numerator, uint32_t source1_weight_denominator);
int zpu_metal_compute_encoder_generate_mipmap_3d_array(zpu_metal_compute_encoder *encoder, zpu_metal_texture *const *source_planes, size_t source_count, zpu_metal_texture *destination);
int zpu_metal_compute_encoder_fill_buffer(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, size_t length, uint8_t value);
int zpu_metal_compute_encoder_dispatch_threads(zpu_metal_compute_encoder *encoder, zpu_metal_size threads_per_grid, zpu_metal_size threads_per_threadgroup);
int zpu_metal_compute_encoder_dispatch_threadgroups(zpu_metal_compute_encoder *encoder, zpu_metal_size threadgroups_per_grid, zpu_metal_size threads_per_threadgroup);
int zpu_metal_compute_encoder_dispatch_threadgroups_indirect(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset, zpu_metal_size threads_per_threadgroup);
int zpu_metal_compute_encoder_dispatch_threads_indirect(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *indirect_buffer);
int zpu_metal_compute_encoder_dispatch_threads_indirect_offset(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
int zpu_metal_compute_encoder_update_fence(zpu_metal_compute_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_compute_encoder_wait_for_fence(zpu_metal_compute_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_compute_encoder_end_encoding(zpu_metal_compute_encoder *encoder);
void zpu_metal_compute_encoder_destroy(zpu_metal_compute_encoder *encoder);

/* The implementation caps execution at one CPU core for 2D and two for 3D. */
static inline uint8_t zpu_metal_max_cpu_cores(zpu_metal_workload workload) {
    return workload == ZPU_METAL_2D ? 1u : 2u;
}

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(zpu_metal_color) == 16, "Metal color ABI drift");
_Static_assert(sizeof(zpu_metal_vertex) == 32, "Metal vertex ABI drift");
_Static_assert(sizeof(zpu_metal_viewport) == 24, "Metal viewport ABI drift");
_Static_assert(sizeof(zpu_metal_render_pass_descriptor) == 28, "Metal pass ABI drift");
_Static_assert(sizeof(zpu_metal_draw_state) == 44, "Metal draw state ABI drift");
_Static_assert(sizeof(zpu_metal_surface) == 40, "Metal surface ABI drift");
_Static_assert(sizeof(zpu_metal_stats) == 48, "Metal stats ABI drift");
_Static_assert(sizeof(zpu_metal_texture_descriptor) == 12, "Metal texture descriptor ABI drift");
#endif

#endif

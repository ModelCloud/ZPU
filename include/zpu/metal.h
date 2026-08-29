/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#ifndef ZPU_METAL_H
#define ZPU_METAL_H

#include <stddef.h>
#include <stdint.h>

/* Native ZPU CPU Metal-layer ABI. This is intentionally separate from the
 * Apple Objective-C framework ABI; it is the portable FFI surface used by
 * clients that select ZPU's CPU renderer. */
#define ZPU_METAL_ABI_VERSION 16u

typedef uint8_t zpu_metal_workload;
enum {
    ZPU_METAL_2D = 0,
    ZPU_METAL_3D = 1,
};

typedef uint16_t zpu_metal_pixel_format;
enum {
    ZPU_METAL_R8_UNORM = 10,
    ZPU_METAL_R8_SNORM = 12,
    ZPU_METAL_R8_UINT = 13,
    ZPU_METAL_R8_SINT = 14,
    ZPU_METAL_R16_UNORM = 20,
    ZPU_METAL_R16_SNORM = 22,
    ZPU_METAL_R16_UINT = 23,
    ZPU_METAL_R16_SINT = 24,
    ZPU_METAL_R16_FLOAT = 25,
    ZPU_METAL_RG8_UNORM = 30,
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
    ZPU_METAL_RGBA8_SNORM = 72,
    ZPU_METAL_RGBA8_UINT = 73,
    ZPU_METAL_RGBA8_SINT = 74,
    ZPU_METAL_BGRA8_UNORM = 80,
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
    ZPU_METAL_DEPTH32_FLOAT = 252,
    ZPU_METAL_STENCIL8 = 253,
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
zpu_metal_buffer *zpu_metal_device_new_buffer_no_copy(zpu_metal_device *device, size_t length, void *bytes);
void zpu_metal_buffer_destroy(zpu_metal_buffer *buffer);
zpu_metal_texture *zpu_metal_buffer_new_texture(zpu_metal_buffer *buffer, const zpu_metal_texture_descriptor *descriptor, size_t offset, size_t bytes_per_row);
size_t zpu_metal_buffer_length(const zpu_metal_buffer *buffer);
void *zpu_metal_buffer_contents(zpu_metal_buffer *buffer);
size_t zpu_metal_buffer_heap_offset(const zpu_metal_buffer *buffer);
int zpu_metal_buffer_write(zpu_metal_buffer *buffer, size_t offset, const void *bytes, size_t length);
zpu_metal_texture *zpu_metal_device_new_texture(zpu_metal_device *device, const zpu_metal_texture_descriptor *descriptor);
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
int zpu_metal_render_encoder_set_scissor_rect(zpu_metal_render_encoder *encoder, zpu_metal_scissor_rect scissor);
int zpu_metal_render_encoder_set_cull_mode(zpu_metal_render_encoder *encoder, zpu_metal_cull_mode cull_mode);
int zpu_metal_render_encoder_set_front_facing(zpu_metal_render_encoder *encoder, zpu_metal_winding winding);
int zpu_metal_render_encoder_set_triangle_fill_mode(zpu_metal_render_encoder *encoder, zpu_metal_triangle_fill_mode fill_mode);
int zpu_metal_render_encoder_set_depth_clip_mode(zpu_metal_render_encoder *encoder, zpu_metal_depth_clip_mode depth_clip_mode);
int zpu_metal_render_encoder_set_depth_bias(zpu_metal_render_encoder *encoder, float depth_bias, float slope_scale, float clamp);
int zpu_metal_render_encoder_set_depth_test_bounds(zpu_metal_render_encoder *encoder, float min_bound, float max_bound);
int zpu_metal_render_encoder_set_pipeline_formats(zpu_metal_render_encoder *encoder, uint16_t color_format, uint16_t depth_format);
int zpu_metal_render_encoder_set_pipeline_formats_with_stencil(zpu_metal_render_encoder *encoder, uint16_t color_format, uint16_t depth_format, uint16_t stencil_format);
int zpu_metal_render_encoder_set_color_attachment(zpu_metal_render_encoder *encoder, zpu_metal_texture *texture, const zpu_metal_render_pass_color_attachment_descriptor *attachment, uint32_t index);
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
int zpu_metal_render_encoder_update_fence(zpu_metal_render_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_render_encoder_wait_for_fence(zpu_metal_render_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_render_encoder_draw_primitives(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t vertex_start, size_t vertex_count, size_t instance_count);
int zpu_metal_render_encoder_draw_primitives_indirect(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
int zpu_metal_render_encoder_draw_indexed_primitives(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t index_count, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, size_t instance_count);
int zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, size_t index_count, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, size_t instance_count, int64_t base_vertex);
int zpu_metal_render_encoder_draw_indexed_primitives_indirect(zpu_metal_render_encoder *encoder, zpu_metal_primitive_type primitive, zpu_metal_index_type index_type, zpu_metal_buffer *index_buffer, size_t index_buffer_offset, zpu_metal_buffer *indirect_buffer, size_t indirect_buffer_offset);
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
int zpu_metal_blit_encoder_fill_buffer(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, size_t length, uint8_t value);
int zpu_metal_blit_encoder_synchronize_resource(zpu_metal_blit_encoder *encoder, zpu_metal_buffer *buffer);
int zpu_metal_blit_encoder_update_fence(zpu_metal_blit_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_blit_encoder_wait_for_fence(zpu_metal_blit_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_blit_encoder_end_encoding(zpu_metal_blit_encoder *encoder);
void zpu_metal_blit_encoder_destroy(zpu_metal_blit_encoder *encoder);

zpu_metal_resource_state_encoder *zpu_metal_command_buffer_resource_state_encoder(zpu_metal_command_buffer *command_buffer);
int zpu_metal_resource_state_encoder_update_fence(zpu_metal_resource_state_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_resource_state_encoder_wait_for_fence(zpu_metal_resource_state_encoder *encoder, zpu_metal_fence *fence);
int zpu_metal_resource_state_encoder_end_encoding(zpu_metal_resource_state_encoder *encoder);
void zpu_metal_resource_state_encoder_destroy(zpu_metal_resource_state_encoder *encoder);

zpu_metal_compute_encoder *zpu_metal_command_buffer_compute_encoder(zpu_metal_command_buffer *command_buffer);
int zpu_metal_compute_encoder_set_kernel(zpu_metal_compute_encoder *encoder, zpu_metal_compute_kernel kernel);
int zpu_metal_compute_encoder_set_buffer(zpu_metal_compute_encoder *encoder, zpu_metal_buffer *buffer, size_t offset, uint32_t index);
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

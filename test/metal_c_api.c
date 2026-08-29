/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include "zpu/metal.h"

static int check_equal(const uint8_t *actual, const uint8_t *expected, size_t length) {
    return memcmp(actual, expected, length) == 0 ? 0 : 1;
}

int main(void) {
    uint8_t pixels[4 * 4 * 4];
    memset(pixels, 0xa5, sizeof(pixels));

    zpu_metal_surface surface = {
        .pixels = pixels,
        .byte_length = sizeof(pixels),
        .width = 4,
        .height = 4,
        .stride = 4 * 4,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    const zpu_metal_render_pass_descriptor pass = {
        .color = {
            .load_action = ZPU_METAL_LOAD_CLEAR,
            .store_action = ZPU_METAL_STORE_STORE,
            .clear_color = {0.0f, 0.0f, 0.0f, 1.0f},
        },
        .depth = {ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f},
    };
    const zpu_metal_draw_state state = {
        .viewport = {0.0f, 0.0f, 4.0f, 4.0f, 0.0f, 1.0f},
        .scissor = {0, 0, 4, 4},
        .cull_mode = ZPU_METAL_CULL_NONE,
        .winding = ZPU_METAL_WINDING_CLOCKWISE,
        .fill_mode = ZPU_METAL_FILL,
    };
    const zpu_metal_vertex vertices[] = {
        {{-1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{-1.0f,  1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
    };
    zpu_metal_stats stats = {0};
    if (zpu_metal_render(&surface, &pass, &state, vertices, 3,
                         ZPU_METAL_TRIANGLE, NULL, 0, &stats) != ZPU_METAL_OK) {
        return 2;
    }
    if (stats.primitives_submitted != 1 || stats.color_writes == 0) return 3;

    const uint8_t expected_interior_pixel[] = {255, 0, 0, 255};
    if (check_equal(pixels + 1 * surface.stride, expected_interior_pixel, sizeof(expected_interior_pixel)) != 0) return 4;

    surface.format = 999;
    if (zpu_metal_render(&surface, &pass, &state, NULL, 0,
                         ZPU_METAL_POINT, NULL, 0, NULL) != ZPU_METAL_UNSUPPORTED_FORMAT) {
        return 5;
    }
    surface.format = ZPU_METAL_RGBA8_UNORM;
    zpu_metal_draw_state invalid_state = state;
    invalid_state.cull_mode = 99;
    if (zpu_metal_render(&surface, &pass, &invalid_state, NULL, 0,
                         ZPU_METAL_POINT, NULL, 0, NULL) != ZPU_METAL_INVALID_ARGUMENT) {
        return 6;
    }

    zpu_metal_device *device = zpu_metal_device_create();
    if (device == NULL) return 7;
    zpu_metal_command_queue *queue = zpu_metal_device_new_command_queue(device);
    zpu_metal_texture_descriptor texture_descriptor = {
        .width = 4,
        .height = 4,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture *texture = zpu_metal_device_new_texture(device, &texture_descriptor);
    const zpu_metal_vertex triangle[] = {
        {{-1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.5f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{ 0.0f,  1.0f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
    };
    zpu_metal_buffer *vertex_buffer = zpu_metal_device_new_buffer(
        device, sizeof(triangle), triangle);
    zpu_metal_command_buffer *render_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    if (queue == NULL || texture == NULL || vertex_buffer == NULL || render_buffer == NULL) return 8;
    const zpu_metal_render_pass_descriptor render_pass = {
        .color = {
            .load_action = ZPU_METAL_LOAD_CLEAR,
            .store_action = ZPU_METAL_STORE_STORE,
            .clear_color = {0.0f, 0.0f, 0.0f, 1.0f},
        },
        .depth = {ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f},
    };
    zpu_metal_render_encoder *render_encoder =
        zpu_metal_command_buffer_render_encoder(render_buffer, texture, &render_pass);
    if (render_encoder == NULL) return 9;
    if (zpu_metal_render_encoder_set_vertex_buffer(render_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_draw_primitives(render_encoder, ZPU_METAL_TRIANGLE, 0, 3, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(render_encoder) != 0 ||
        zpu_metal_command_buffer_get_status(render_buffer) != ZPU_METAL_COMMAND_BUFFER_CREATED ||
        zpu_metal_command_buffer_commit(render_buffer) != 0 ||
        zpu_metal_command_buffer_get_status(render_buffer) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 10;
    zpu_metal_render_encoder_destroy(render_encoder);

    uint8_t rendered[4 * 4 * 4];
    memset(rendered, 0, sizeof(rendered));
    if (zpu_metal_texture_get_bytes(texture, rendered, sizeof(rendered), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0) return 11;
    int has_colored_pixel = 0;
    for (size_t i = 0; i < sizeof(rendered); i += 4) {
        if (rendered[i] != 0 || rendered[i + 1] != 0 || rendered[i + 2] != 0) {
            has_colored_pixel = 1;
            break;
        }
    }
    if (!has_colored_pixel) return 11;

    zpu_metal_texture_descriptor compute_descriptor = {
        .width = 4,
        .height = 4,
        .format = ZPU_METAL_BGRA8_UNORM,
    };
    zpu_metal_texture *compute_texture =
        zpu_metal_device_new_texture(device, &compute_descriptor);
    zpu_metal_command_buffer *compute_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_compute_encoder *compute_encoder =
        zpu_metal_command_buffer_compute_encoder(compute_buffer);
    if (compute_texture == NULL || compute_buffer == NULL || compute_encoder == NULL ||
        zpu_metal_compute_encoder_set_kernel(
            compute_encoder, ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8) != 0 ||
        zpu_metal_compute_encoder_set_texture(compute_encoder, compute_texture, 0) != 0 ||
        zpu_metal_compute_encoder_dispatch_threads(
            compute_encoder, (zpu_metal_size){4, 4, 1}, (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_compute_encoder_end_encoding(compute_encoder) != 0 ||
        zpu_metal_command_buffer_get_status(compute_buffer) != ZPU_METAL_COMMAND_BUFFER_CREATED ||
        zpu_metal_command_buffer_commit(compute_buffer) != 0 ||
        zpu_metal_command_buffer_get_status(compute_buffer) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 37;
    uint8_t compute_pixels[4 * 4 * 4] = {0};
    if (zpu_metal_texture_get_bytes(compute_texture, compute_pixels, sizeof(compute_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        memcmp(compute_pixels, (const uint8_t[]){64, 32, 32, 255}, 4) != 0 ||
        memcmp(compute_pixels + 1 * 4, (const uint8_t[]){64, 32, 64, 255}, 4) != 0 ||
        memcmp(compute_pixels + 15 * 4, (const uint8_t[]){64, 128, 128, 255}, 4) != 0) return 38;
    zpu_metal_compute_encoder_destroy(compute_encoder);
    zpu_metal_command_buffer_destroy(compute_buffer);
    zpu_metal_texture_destroy(compute_texture);

    uint8_t compute_copy_source[4 * 4 * 4];
    for (size_t index = 0; index < sizeof(compute_copy_source); ++index) {
        compute_copy_source[index] = (uint8_t)((index * 13u + 9u) & 0xffu);
    }
    zpu_metal_texture_descriptor compute_copy_descriptor = {
        .width = 4,
        .height = 4,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture *compute_copy_texture =
        zpu_metal_device_new_texture(device, &compute_copy_descriptor);
    zpu_metal_buffer *compute_copy_buffer =
        zpu_metal_device_new_buffer(device, sizeof(compute_copy_source), compute_copy_source);
    zpu_metal_command_buffer *compute_copy_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_compute_encoder *compute_copy_encoder =
        zpu_metal_command_buffer_compute_encoder(compute_copy_commands);
    if (compute_copy_texture == NULL || compute_copy_buffer == NULL || compute_copy_commands == NULL ||
        compute_copy_encoder == NULL ||
        zpu_metal_compute_encoder_set_kernel(
            compute_copy_encoder, ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE) != 0 ||
        zpu_metal_compute_encoder_set_bytes(compute_copy_encoder, compute_copy_source,
                                            sizeof(compute_copy_source), 0) != 0 ||
        zpu_metal_compute_encoder_set_texture(compute_copy_encoder, compute_copy_texture, 1) != 0 ||
        zpu_metal_compute_encoder_dispatch_threads(
            compute_copy_encoder, (zpu_metal_size){4, 4, 1}, (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_compute_encoder_end_encoding(compute_copy_encoder) != 0 ||
        zpu_metal_command_buffer_commit(compute_copy_commands) != 0) return 39;
    uint8_t compute_copy_pixels[sizeof(compute_copy_source)] = {0};
    if (zpu_metal_texture_get_bytes(compute_copy_texture, compute_copy_pixels,
                                    sizeof(compute_copy_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        memcmp(compute_copy_pixels, compute_copy_source, sizeof(compute_copy_source)) != 0) return 40;
    zpu_metal_compute_encoder_destroy(compute_copy_encoder);
    zpu_metal_command_buffer_destroy(compute_copy_commands);
    zpu_metal_texture_destroy(compute_copy_texture);

    zpu_metal_texture_descriptor compute_bgra_copy_descriptor = {
        .width = 4,
        .height = 4,
        .format = ZPU_METAL_BGRA8_UNORM,
    };
    zpu_metal_texture *compute_bgra_copy_texture =
        zpu_metal_device_new_texture(device, &compute_bgra_copy_descriptor);
    zpu_metal_command_buffer *compute_bgra_copy_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_compute_encoder *compute_bgra_copy_encoder =
        zpu_metal_command_buffer_compute_encoder(compute_bgra_copy_commands);
    if (compute_bgra_copy_texture == NULL || compute_bgra_copy_commands == NULL ||
        compute_bgra_copy_encoder == NULL ||
        zpu_metal_compute_encoder_set_kernel(
            compute_bgra_copy_encoder, ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE) != 0 ||
        zpu_metal_compute_encoder_set_buffer(
            compute_bgra_copy_encoder, compute_copy_buffer, 0, 0) != 0 ||
        zpu_metal_compute_encoder_set_texture(
            compute_bgra_copy_encoder, compute_bgra_copy_texture, 1) != 0 ||
        zpu_metal_compute_encoder_dispatch_threads(
            compute_bgra_copy_encoder, (zpu_metal_size){4, 4, 1}, (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_compute_encoder_end_encoding(compute_bgra_copy_encoder) != 0 ||
        zpu_metal_command_buffer_commit(compute_bgra_copy_commands) != 0) return 43;
    uint8_t compute_bgra_copy_pixels[sizeof(compute_copy_source)] = {0};
    if (zpu_metal_texture_get_bytes(compute_bgra_copy_texture, compute_bgra_copy_pixels,
                                    sizeof(compute_bgra_copy_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        memcmp(compute_bgra_copy_pixels, (const uint8_t[]){35, 22, 9, 48}, 4) != 0 ||
        memcmp(compute_bgra_copy_pixels + 1 * 4, (const uint8_t[]){87, 74, 61, 100}, 4) != 0) return 44;
    zpu_metal_compute_encoder_destroy(compute_bgra_copy_encoder);
    zpu_metal_command_buffer_destroy(compute_bgra_copy_commands);
    zpu_metal_texture_destroy(compute_bgra_copy_texture);

    const uint8_t indirect_dispatch_args[] = {2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 0, 0};
    const uint8_t initial_indirect_dispatch_args[] = {1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0};
    zpu_metal_texture *compute_indirect_texture =
        zpu_metal_device_new_texture(device, &compute_copy_descriptor);
    zpu_metal_buffer *compute_indirect_args =
        zpu_metal_device_new_buffer(device, sizeof(initial_indirect_dispatch_args), initial_indirect_dispatch_args);
    zpu_metal_command_buffer *compute_indirect_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_compute_encoder *compute_indirect_encoder =
        zpu_metal_command_buffer_compute_encoder(compute_indirect_commands);
    if (compute_indirect_texture == NULL || compute_indirect_args == NULL ||
        compute_indirect_commands == NULL || compute_indirect_encoder == NULL ||
        zpu_metal_compute_encoder_set_kernel(
            compute_indirect_encoder, ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE) != 0 ||
        zpu_metal_compute_encoder_set_buffer(
            compute_indirect_encoder, compute_copy_buffer, 0, 0) != 0 ||
        zpu_metal_compute_encoder_set_texture(
            compute_indirect_encoder, compute_indirect_texture, 1) != 0 ||
        zpu_metal_compute_encoder_dispatch_threadgroups_indirect(
            compute_indirect_encoder, compute_indirect_args, 0,
            (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_buffer_write(compute_indirect_args, 0, indirect_dispatch_args,
                               sizeof(indirect_dispatch_args)) != 0 ||
        zpu_metal_compute_encoder_end_encoding(compute_indirect_encoder) != 0 ||
        zpu_metal_command_buffer_commit(compute_indirect_commands) != 0 ||
        zpu_metal_command_buffer_get_status(compute_indirect_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 41;
    uint8_t compute_indirect_pixels[sizeof(compute_copy_source)] = {0};
    if (zpu_metal_texture_get_bytes(compute_indirect_texture, compute_indirect_pixels,
                                    sizeof(compute_indirect_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        memcmp(compute_indirect_pixels, compute_copy_source, sizeof(compute_copy_source)) != 0) return 42;
    zpu_metal_compute_encoder_destroy(compute_indirect_encoder);
    zpu_metal_command_buffer_destroy(compute_indirect_commands);
    zpu_metal_buffer_destroy(compute_indirect_args);
    zpu_metal_texture_destroy(compute_indirect_texture);
    zpu_metal_buffer_destroy(compute_copy_buffer);

    zpu_metal_heap *heap = zpu_metal_device_new_heap(device, 128);
    zpu_metal_buffer *heap_buffer = zpu_metal_heap_new_buffer(heap, 16, NULL);
    zpu_metal_texture *heap_texture = zpu_metal_heap_new_texture(heap, &texture_descriptor);
    if (heap == NULL || heap_buffer == NULL || heap_texture == NULL ||
        zpu_metal_heap_size(heap) != 128 || zpu_metal_heap_used_size(heap) != 80 ||
        zpu_metal_heap_max_available_size(heap, 4) != 48) return 35;
    zpu_metal_texture_destroy(heap_texture);
    zpu_metal_buffer_destroy(heap_buffer);
    if (zpu_metal_heap_used_size(heap) != 0) return 36;
    zpu_metal_heap_destroy(heap);

    const uint8_t source_bytes[] = {1, 2, 3, 4, 5, 6, 7, 8};
    zpu_metal_buffer *source_buffer = zpu_metal_device_new_buffer(
        device, sizeof(source_bytes), source_bytes);
    zpu_metal_buffer *destination_buffer = zpu_metal_device_new_buffer(
        device, sizeof(source_bytes), NULL);
    zpu_metal_command_buffer *blit_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *blit_encoder =
        zpu_metal_command_buffer_blit_encoder(blit_buffer);
    if (source_buffer == NULL || destination_buffer == NULL || blit_buffer == NULL || blit_encoder == NULL) return 12;
    if (zpu_metal_blit_encoder_fill_buffer(blit_encoder, destination_buffer, 0,
                                            sizeof(source_bytes), 0xee) != 0 ||
        zpu_metal_blit_encoder_copy_buffer(blit_encoder, source_buffer, 2,
                                            destination_buffer, 0, 4) != 0 ||
        zpu_metal_blit_encoder_end_encoding(blit_encoder) != 0 ||
        zpu_metal_command_buffer_commit(blit_buffer) != 0) return 13;
    zpu_metal_blit_encoder_destroy(blit_encoder);
    const uint8_t expected_buffer[] = {3, 4, 5, 6, 0xee, 0xee, 0xee, 0xee};
    if (memcmp(zpu_metal_buffer_contents(destination_buffer), expected_buffer,
               sizeof(expected_buffer)) != 0) return 14;

    const uint8_t texel[] = {
        9, 8, 7, 6, 5, 4, 3, 2,
        1, 0, 11, 12, 13, 14, 15, 16,
    };
    if (zpu_metal_texture_replace_region(texture,
                                         (zpu_metal_region){{1, 1, 0}, {2, 2, 1}},
                                         texel, sizeof(texel), 2 * 4) != 0) return 15;
    uint8_t texel_copy[sizeof(texel)] = {0};
    if (zpu_metal_texture_get_bytes(texture, texel_copy, sizeof(texel_copy), 2 * 4,
                                    (zpu_metal_region){{1, 1, 0}, {2, 2, 1}}) != 0 ||
        memcmp(texel_copy, texel, sizeof(texel)) != 0) return 16;

    zpu_metal_buffer *texture_upload = zpu_metal_device_new_buffer(
        device, sizeof(texel), texel);
    zpu_metal_buffer *texture_download = zpu_metal_device_new_buffer(
        device, sizeof(texel), NULL);
    zpu_metal_texture *texture_copy_destination =
        zpu_metal_device_new_texture(device, &texture_descriptor);
    zpu_metal_command_buffer *texture_copy_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *texture_copy_encoder =
        zpu_metal_command_buffer_blit_encoder(texture_copy_commands);
    if (texture_upload == NULL || texture_download == NULL || texture_copy_destination == NULL ||
        texture_copy_commands == NULL || texture_copy_encoder == NULL) return 17;
    const zpu_metal_region copy_region = {{1, 1, 0}, {2, 2, 1}};
    if (zpu_metal_blit_encoder_copy_buffer_to_texture(
            texture_copy_encoder, texture_upload, 0, 2 * 4, texture, copy_region) != 0 ||
        zpu_metal_blit_encoder_copy_texture_to_buffer(
            texture_copy_encoder, texture, copy_region, texture_download, 0, 2 * 4) != 0 ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            texture_copy_encoder, texture, copy_region, texture_copy_destination,
            (zpu_metal_region){{0, 0, 0}, {2, 2, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(texture_copy_encoder) != 0 ||
        zpu_metal_command_buffer_commit(texture_copy_commands) != 0 ||
        memcmp(zpu_metal_buffer_contents(texture_download), texel, sizeof(texel)) != 0) return 18;
    uint8_t copied_texture[sizeof(texel)] = {0};
    if (zpu_metal_texture_get_bytes(texture_copy_destination, copied_texture,
                                    sizeof(copied_texture), 2 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {2, 2, 1}}) != 0 ||
        memcmp(copied_texture, texel, sizeof(texel)) != 0) return 19;
    zpu_metal_blit_encoder_destroy(texture_copy_encoder);
    zpu_metal_command_buffer_destroy(texture_copy_commands);
    zpu_metal_buffer_destroy(texture_download);
    zpu_metal_buffer_destroy(texture_upload);
    zpu_metal_texture_destroy(texture_copy_destination);

    zpu_metal_texture_descriptor depth_descriptor = {
        .width = 4,
        .height = 4,
        .format = ZPU_METAL_DEPTH32_FLOAT,
    };
    const zpu_metal_render_pass_descriptor depth_pass = {
        .color = {
            .load_action = ZPU_METAL_LOAD_CLEAR,
            .store_action = ZPU_METAL_STORE_STORE,
            .clear_color = {0.0f, 0.0f, 0.0f, 1.0f},
        },
        .depth = {ZPU_METAL_LOAD_CLEAR, ZPU_METAL_STORE_STORE, 1.0f},
    };
    zpu_metal_texture *depth_texture =
        zpu_metal_device_new_texture(device, &depth_descriptor);
    zpu_metal_command_buffer *depth_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *depth_encoder =
        zpu_metal_command_buffer_render_encoder(depth_commands, texture, &depth_pass);
    if (depth_texture == NULL || depth_commands == NULL || depth_encoder == NULL) return 20;
    if (
        zpu_metal_render_encoder_set_depth_texture(depth_encoder, depth_texture) != 0) return 21;
    const zpu_metal_vertex far_triangle[] = {
        {{-1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{-1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{-1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
    };
    const zpu_metal_vertex near_triangle[] = {
        {{-1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{-1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{-1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
    };
    if (zpu_metal_render_encoder_set_vertex_bytes(depth_encoder, far_triangle,
        sizeof(far_triangle), 0) != 0 ||
        zpu_metal_render_encoder_set_pipeline_formats(depth_encoder,
                                                       ZPU_METAL_RGBA8_UNORM,
                                                       ZPU_METAL_DEPTH32_FLOAT) != 0 ||
        zpu_metal_render_encoder_set_depth_compare_function(depth_encoder,
                                                             ZPU_METAL_COMPARE_LESS_EQUAL, 1) != 0 ||
        zpu_metal_render_encoder_draw_primitives(depth_encoder, ZPU_METAL_TRIANGLE,
                                                  0, 6, 1) != 0 ||
        zpu_metal_render_encoder_set_vertex_bytes(depth_encoder, near_triangle,
        sizeof(near_triangle), 0) != 0 ||
        zpu_metal_render_encoder_draw_primitives(depth_encoder, ZPU_METAL_TRIANGLE,
                                                  0, 6, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(depth_encoder) != 0 ||
        zpu_metal_command_buffer_commit(depth_commands) != 0) return 22;
    uint8_t depth_pixels[4 * 4 * 4] = {0};
    if (zpu_metal_texture_get_bytes(texture, depth_pixels, sizeof(depth_pixels),
                                    4 * 4, (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        depth_pixels[0] != 0 || depth_pixels[1] != 255 || depth_pixels[2] != 0) return 23;
    zpu_metal_render_encoder_destroy(depth_encoder);
    zpu_metal_command_buffer_destroy(depth_commands);
    zpu_metal_texture_destroy(depth_texture);

    uint8_t aliased_bytes[32] = {0};
    zpu_metal_buffer *aliased_buffer = zpu_metal_device_new_buffer(device, sizeof(aliased_bytes), aliased_bytes);
    zpu_metal_texture_descriptor aliased_descriptor = {
        .width = 2,
        .height = 2,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture *aliased_texture =
        zpu_metal_buffer_new_texture(aliased_buffer, &aliased_descriptor, 4, 12);
    const uint8_t aliased_source[] = {
        1, 2, 3, 4, 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
        9, 10, 11, 12, 13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd,
    };
    const uint8_t aliased_expected[] = {
        5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
        13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd,
    };
    if (aliased_buffer == NULL || aliased_texture == NULL ||
        zpu_metal_buffer_write(aliased_buffer, 0, aliased_source, sizeof(aliased_source)) != 0) return 24;
    uint8_t aliased_copy[16] = {0};
    if (zpu_metal_texture_get_bytes(aliased_texture, aliased_copy, sizeof(aliased_copy), 8,
                                    (zpu_metal_region){{0, 0, 0}, {2, 2, 1}}) != 0 ||
        memcmp(aliased_copy, aliased_expected, sizeof(aliased_copy)) != 0 ||
        zpu_metal_texture_replace_region(aliased_texture,
                                         (zpu_metal_region){{1, 1, 0}, {1, 1, 1}},
                                         (const uint8_t[]){31, 32, 33, 34}, 4, 4) != 0 ||
        memcmp((uint8_t *)zpu_metal_buffer_contents(aliased_buffer) + 20,
               (const uint8_t[]){31, 32, 33, 34}, 4) != 0) return 25;
    zpu_metal_texture_destroy(aliased_texture);
    zpu_metal_buffer_destroy(aliased_buffer);

    const uint32_t indirect_draw_arguments[] = {3, 1, 0, 0};
    zpu_metal_buffer *indirect_draw_buffer = zpu_metal_device_new_buffer(
        device, sizeof(indirect_draw_arguments), indirect_draw_arguments);
    zpu_metal_command_buffer *indirect_command_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *indirect_encoder =
        zpu_metal_command_buffer_render_encoder(indirect_command_buffer, texture, &render_pass);
    if (indirect_draw_buffer == NULL || indirect_command_buffer == NULL || indirect_encoder == NULL ||
        zpu_metal_render_encoder_set_vertex_buffer(indirect_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_blend_state(indirect_encoder, 1,
            ZPU_METAL_BLEND_SOURCE_ALPHA, ZPU_METAL_BLEND_ONE_MINUS_SOURCE_ALPHA,
            ZPU_METAL_BLEND_ADD, ZPU_METAL_BLEND_ONE,
            ZPU_METAL_BLEND_ONE_MINUS_SOURCE_ALPHA, ZPU_METAL_BLEND_ADD,
            ZPU_METAL_COLOR_WRITE_ALL) != 0 ||
        zpu_metal_render_encoder_set_blend_color(indirect_encoder,
            (zpu_metal_color){0.0f, 0.0f, 0.0f, 0.0f}) != 0 ||
        zpu_metal_render_encoder_draw_primitives_indirect(indirect_encoder, ZPU_METAL_TRIANGLE,
                                                           indirect_draw_buffer, 0) != 0 ||
        zpu_metal_render_encoder_end_encoding(indirect_encoder) != 0 ||
        zpu_metal_command_buffer_commit(indirect_command_buffer) != 0) return 26;
    uint8_t indirect_pixels[4 * 4 * 4] = {0};
    if (zpu_metal_texture_get_bytes(texture, indirect_pixels, sizeof(indirect_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0) return 27;
    int indirect_has_colored_pixel = 0;
    for (size_t i = 0; i < sizeof(indirect_pixels); i += 4) {
        if (indirect_pixels[i] != 0 || indirect_pixels[i + 1] != 0 || indirect_pixels[i + 2] != 0) {
            indirect_has_colored_pixel = 1;
            break;
        }
    }
    if (!indirect_has_colored_pixel) return 27;
    zpu_metal_render_encoder_destroy(indirect_encoder);
    zpu_metal_command_buffer_destroy(indirect_command_buffer);
    zpu_metal_buffer_destroy(indirect_draw_buffer);

    const zpu_metal_vertex base_vertex_triangle[] = {
        {{0.0f, 0.0f, 0.5f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}},
        {{-1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.5f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        {{ 0.0f,  1.0f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
    };
    const uint16_t base_vertex_indices[] = {0, 1, 2};
    zpu_metal_buffer *base_vertex_buffer = zpu_metal_device_new_buffer(
        device, sizeof(base_vertex_triangle), base_vertex_triangle);
    zpu_metal_buffer *base_index_buffer = zpu_metal_device_new_buffer(
        device, sizeof(base_vertex_indices), base_vertex_indices);
    zpu_metal_command_buffer *base_vertex_command_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *base_vertex_encoder =
        zpu_metal_command_buffer_render_encoder(base_vertex_command_buffer, texture, &render_pass);
    if (base_vertex_buffer == NULL || base_index_buffer == NULL ||
        base_vertex_command_buffer == NULL || base_vertex_encoder == NULL ||
        zpu_metal_render_encoder_set_vertex_buffer(base_vertex_encoder, base_vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(
            base_vertex_encoder, ZPU_METAL_TRIANGLE, 3, ZPU_METAL_INDEX_UINT16,
            base_index_buffer, 0, 1, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(base_vertex_encoder) != 0 ||
        zpu_metal_command_buffer_commit(base_vertex_command_buffer) != 0) return 33;
    uint8_t base_vertex_pixels[4 * 4 * 4] = {0};
    if (zpu_metal_texture_get_bytes(texture, base_vertex_pixels, sizeof(base_vertex_pixels), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0) return 34;
    int base_vertex_has_colored_pixel = 0;
    for (size_t i = 0; i < sizeof(base_vertex_pixels); i += 4) {
        if (base_vertex_pixels[i] != 0 || base_vertex_pixels[i + 1] != 0 || base_vertex_pixels[i + 2] != 0) {
            base_vertex_has_colored_pixel = 1;
            break;
        }
    }
    if (!base_vertex_has_colored_pixel) return 34;
    zpu_metal_render_encoder_destroy(base_vertex_encoder);
    zpu_metal_command_buffer_destroy(base_vertex_command_buffer);
    zpu_metal_buffer_destroy(base_index_buffer);
    zpu_metal_buffer_destroy(base_vertex_buffer);

    zpu_metal_fence *fence = zpu_metal_device_new_fence(device);
    zpu_metal_command_buffer *fence_signal_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *fence_signal_encoder =
        zpu_metal_command_buffer_blit_encoder(fence_signal_buffer);
    if (fence == NULL || fence_signal_buffer == NULL || fence_signal_encoder == NULL ||
        zpu_metal_blit_encoder_update_fence(fence_signal_encoder, fence) != 0 ||
        zpu_metal_blit_encoder_end_encoding(fence_signal_encoder) != 0 ||
        zpu_metal_command_buffer_commit(fence_signal_buffer) != 0) return 28;
    zpu_metal_blit_encoder_destroy(fence_signal_encoder);
    zpu_metal_command_buffer *fence_wait_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *fence_wait_encoder =
        zpu_metal_command_buffer_blit_encoder(fence_wait_buffer);
    if (fence_wait_buffer == NULL || fence_wait_encoder == NULL ||
        zpu_metal_blit_encoder_wait_for_fence(fence_wait_encoder, fence) != 0 ||
        zpu_metal_blit_encoder_end_encoding(fence_wait_encoder) != 0 ||
        zpu_metal_command_buffer_commit(fence_wait_buffer) != 0) return 29;
    zpu_metal_blit_encoder_destroy(fence_wait_encoder);
    zpu_metal_command_buffer_destroy(fence_wait_buffer);
    zpu_metal_command_buffer_destroy(fence_signal_buffer);
    zpu_metal_fence_destroy(fence);

    zpu_metal_shared_event *event = zpu_metal_device_new_shared_event(device);
    if (event == NULL || zpu_metal_shared_event_signaled_value(event) != 0 ||
        zpu_metal_shared_event_wait_until_signaled_value(event, 1, 0) == 0 ||
        zpu_metal_shared_event_set_signaled_value(event, 7) != 0 ||
        zpu_metal_shared_event_signaled_value(event) != 7 ||
        zpu_metal_shared_event_wait_until_signaled_value(event, 7, 0) != 0 ||
        zpu_metal_shared_event_set_signaled_value(event, 6) == 0) return 30;
    zpu_metal_shared_event_destroy(event);

    zpu_metal_shared_event *command_event = zpu_metal_device_new_shared_event(device);
    zpu_metal_command_buffer *event_commands =
        zpu_metal_command_queue_command_buffer(queue);
    if (command_event == NULL || event_commands == NULL ||
        zpu_metal_command_buffer_encode_signal_event(event_commands, command_event, 11) != 0 ||
        zpu_metal_command_buffer_encode_wait_for_event(event_commands, command_event, 11) != 0 ||
        zpu_metal_shared_event_signaled_value(command_event) != 0 ||
        zpu_metal_command_buffer_commit(event_commands) != 0 ||
        zpu_metal_shared_event_signaled_value(command_event) != 11 ||
        zpu_metal_command_buffer_get_status(event_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 52;
    zpu_metal_command_buffer_destroy(event_commands);
    zpu_metal_shared_event_destroy(command_event);

    zpu_metal_command_buffer *error_command_buffer =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *error_encoder =
        zpu_metal_command_buffer_render_encoder(error_command_buffer, texture, &render_pass);
    if (error_command_buffer == NULL || error_encoder == NULL ||
        zpu_metal_render_encoder_set_pipeline_formats(error_encoder, ZPU_METAL_BGRA8_UNORM, 0) !=
            ZPU_METAL_INVALID_ARGUMENT) return 31;
    zpu_metal_command_buffer_mark_error(error_command_buffer);
    if (zpu_metal_command_buffer_get_status(error_command_buffer) != ZPU_METAL_COMMAND_BUFFER_ERROR ||
        zpu_metal_command_buffer_commit(error_command_buffer) != ZPU_METAL_INVALID_COMMAND) return 32;
    zpu_metal_render_encoder_destroy(error_encoder);
    zpu_metal_command_buffer_destroy(error_command_buffer);

    zpu_metal_command_buffer_destroy(blit_buffer);
    zpu_metal_buffer_destroy(destination_buffer);
    zpu_metal_buffer_destroy(source_buffer);
    zpu_metal_command_buffer_destroy(render_buffer);
    zpu_metal_buffer_destroy(vertex_buffer);
    zpu_metal_texture_destroy(texture);
    zpu_metal_command_queue_destroy(queue);
    zpu_metal_device_destroy(device);
    return 0;
}

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
    zpu_metal_texture *texture_levels[] = {texture};
    if (zpu_metal_render_encoder_set_vertex_buffer(render_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_fragment_texture_levels(render_encoder, texture_levels, 1, 0) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_with_filters(
            render_encoder, ZPU_METAL_SAMPLER_LINEAR, ZPU_METAL_SAMPLER_NEAREST,
            ZPU_METAL_SAMPLER_CLAMP_TO_EDGE, ZPU_METAL_SAMPLER_CLAMP_TO_BORDER_COLOR,
            ZPU_METAL_SAMPLER_BORDER_OPAQUE_WHITE) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_normalized_coordinates(render_encoder, 1) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_lod_bias(render_encoder, 0.0f) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_max_anisotropy(render_encoder, 1) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_reduction_mode(
            render_encoder, ZPU_METAL_SAMPLER_REDUCTION_WEIGHTED_AVERAGE) != 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_lod_bias(render_encoder, 16.0f) == 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_max_anisotropy(render_encoder, 0) == 0 ||
        zpu_metal_render_encoder_set_fragment_sampler_max_anisotropy(render_encoder, 17) == 0 ||
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

    zpu_metal_texture *r32_view = zpu_metal_texture_view(texture, ZPU_METAL_R32_FLOAT);
    uint8_t view_bytes[sizeof(rendered)];
    memset(view_bytes, 0, sizeof(view_bytes));
    if (r32_view == NULL || zpu_metal_texture_width(r32_view) != 4 ||
        zpu_metal_texture_height(r32_view) != 4 ||
        zpu_metal_texture_get_bytes(r32_view, view_bytes, sizeof(view_bytes), 4 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {4, 4, 1}}) != 0 ||
        memcmp(rendered, view_bytes, sizeof(rendered)) != 0) return 12;
    zpu_metal_texture_destroy(r32_view);

    zpu_metal_texture_descriptor narrow_r8_descriptor = {
        .width = 3,
        .height = 2,
        .format = ZPU_METAL_R8_UNORM,
    };
    zpu_metal_texture_descriptor narrow_rg8_descriptor = narrow_r8_descriptor;
    narrow_rg8_descriptor.format = ZPU_METAL_RG8_UNORM;
    zpu_metal_texture *narrow_r8 =
        zpu_metal_device_new_texture(device, &narrow_r8_descriptor);
    zpu_metal_texture *narrow_rg8 =
        zpu_metal_device_new_texture(device, &narrow_rg8_descriptor);
    const uint8_t narrow_r8_values[] = {1, 2, 3, 9, 8, 7};
    const uint8_t narrow_rg8_values[] = {
        10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 60, 61,
    };
    uint8_t narrow_r8_copy[sizeof(narrow_r8_values)] = {0};
    uint8_t narrow_rg8_copy[sizeof(narrow_rg8_values)] = {0};
    if (narrow_r8 == NULL || narrow_rg8 == NULL ||
        zpu_metal_texture_replace_region(
            narrow_r8, (zpu_metal_region){{0, 0, 0}, {3, 2, 1}},
            narrow_r8_values, sizeof(narrow_r8_values), 3) != 0 ||
        zpu_metal_texture_replace_region(
            narrow_rg8, (zpu_metal_region){{0, 0, 0}, {3, 2, 1}},
            narrow_rg8_values, sizeof(narrow_rg8_values), 6) != 0 ||
        zpu_metal_texture_get_bytes(
            narrow_r8, narrow_r8_copy, sizeof(narrow_r8_copy), 3,
            (zpu_metal_region){{0, 0, 0}, {3, 2, 1}}) != 0 ||
        zpu_metal_texture_get_bytes(
            narrow_rg8, narrow_rg8_copy, sizeof(narrow_rg8_copy), 6,
            (zpu_metal_region){{0, 0, 0}, {3, 2, 1}}) != 0 ||
        memcmp(narrow_r8_copy, narrow_r8_values, sizeof(narrow_r8_copy)) != 0 ||
        memcmp(narrow_rg8_copy, narrow_rg8_values, sizeof(narrow_rg8_copy)) != 0) return 72;
    zpu_metal_texture_destroy(narrow_r8);
    zpu_metal_texture_destroy(narrow_rg8);

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

    uint8_t ray_payload[512] = {0};
    const zpu_metal_cpu_acceleration_structure_header ray_header = {
        ZPU_METAL_CPU_ACCELERATION_STRUCTURE_MAGIC,
        ZPU_METAL_CPU_ACCELERATION_STRUCTURE_VERSION,
        1,
        1,
        ZPU_METAL_CPU_ACCELERATION_STRUCTURE_TRIANGLE_OFFSET,
        {0, 0, 0},
    };
    const zpu_metal_cpu_acceleration_triangle ray_triangle = {
        .positions = {-0.80f, -0.65f, 0.0f, 0.80f, -0.65f, 0.0f, -0.05f, 0.65f, 0.0f},
    };
    memcpy(ray_payload, &ray_header, sizeof(ray_header));
    memcpy(ray_payload + ZPU_METAL_CPU_ACCELERATION_STRUCTURE_TRIANGLE_OFFSET,
           &ray_triangle, sizeof(ray_triangle));
    zpu_metal_texture_descriptor ray_descriptor = {
        .width = 7,
        .height = 5,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture *ray_texture = zpu_metal_device_new_texture(device, &ray_descriptor);
    zpu_metal_buffer *ray_acceleration_structure =
        zpu_metal_device_new_buffer(device, sizeof(ray_payload), ray_payload);
    zpu_metal_command_buffer *ray_commands = zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_compute_encoder *ray_encoder =
        zpu_metal_command_buffer_compute_encoder(ray_commands);
    if (ray_texture == NULL || ray_acceleration_structure == NULL || ray_commands == NULL ||
        ray_encoder == NULL ||
        zpu_metal_compute_encoder_set_kernel(ray_encoder, ZPU_METAL_COMPUTE_TRACE_TRIANGLES_RGBA8) != 0 ||
        zpu_metal_compute_encoder_set_texture(ray_encoder, ray_texture, 0) != 0 ||
        zpu_metal_compute_encoder_set_acceleration_structure(ray_encoder, ray_acceleration_structure, 0) != 0 ||
        zpu_metal_compute_encoder_dispatch_threads(
            ray_encoder, (zpu_metal_size){7, 5, 1}, (zpu_metal_size){7, 5, 1}) != 0 ||
        zpu_metal_compute_encoder_end_encoding(ray_encoder) != 0 ||
        zpu_metal_command_buffer_commit(ray_commands) != 0 ||
        zpu_metal_command_buffer_get_status(ray_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 80;
    uint8_t ray_pixels[7 * 5 * 4] = {0};
    if (zpu_metal_texture_get_bytes(ray_texture, ray_pixels, sizeof(ray_pixels), 7 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {7, 5, 1}}) != 0 ||
        memcmp(ray_pixels + (0 * 7 + 3) * 4, (const uint8_t[]){0, 0, 0, 255}, 4) != 0 ||
        memcmp(ray_pixels + (1 * 7 + 3) * 4, (const uint8_t[]){255, 0, 0, 255}, 4) != 0 ||
        memcmp(ray_pixels + (3 * 7 + 3) * 4, (const uint8_t[]){255, 0, 0, 255}, 4) != 0 ||
        memcmp(ray_pixels + (4 * 7 + 3) * 4, (const uint8_t[]){0, 0, 0, 255}, 4) != 0) return 81;
    zpu_metal_compute_encoder_destroy(ray_encoder);
    zpu_metal_command_buffer_destroy(ray_commands);
    zpu_metal_buffer_destroy(ray_acceleration_structure);
    zpu_metal_texture_destroy(ray_texture);

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

    const zpu_metal_texture_descriptor mesh_descriptor = {
        .width = 5,
        .height = 3,
        .format = ZPU_METAL_BGRA8_UNORM,
    };
    zpu_metal_texture *mesh_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    const uint32_t mesh_arguments_initial[] = {0, 1, 1, 1};
    zpu_metal_buffer *mesh_arguments = zpu_metal_device_new_buffer(
        device, sizeof(mesh_arguments_initial), mesh_arguments_initial);
    zpu_metal_command_buffer *mesh_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *mesh_encoder =
        zpu_metal_command_buffer_render_encoder(mesh_commands, mesh_texture, &render_pass);
    const uint32_t mesh_arguments_updated[] = {3, 2, 1};
    if (mesh_texture == NULL || mesh_arguments == NULL || mesh_commands == NULL ||
        mesh_encoder == NULL ||
        zpu_metal_render_encoder_draw_mesh_threadgroups_indirect(
            mesh_encoder, ZPU_METAL_MESH_FILL_GRADIENT_RGBA8, mesh_arguments,
            sizeof(uint32_t), (zpu_metal_size){1, 1, 1},
            (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_buffer_write(mesh_arguments, sizeof(uint32_t), mesh_arguments_updated,
                               sizeof(mesh_arguments_updated)) != 0 ||
        zpu_metal_render_encoder_end_encoding(mesh_encoder) != 0 ||
        zpu_metal_command_buffer_get_status(mesh_commands) != ZPU_METAL_COMMAND_BUFFER_CREATED ||
        zpu_metal_command_buffer_commit(mesh_commands) != 0 ||
        zpu_metal_command_buffer_get_status(mesh_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 45;
    uint8_t mesh_pixels[5 * 3 * 4] = {0};
    uint8_t expected_mesh_pixels[sizeof(mesh_pixels)] = {0};
    for (size_t y = 0; y < 3; ++y) {
        for (size_t x = 0; x < 5; ++x) {
            const size_t pixel = (y * 5 + x) * 4;
            expected_mesh_pixels[pixel + 0] = 64;
            expected_mesh_pixels[pixel + 1] = (uint8_t)(((y + 1) * 255 + 4) / 8);
            expected_mesh_pixels[pixel + 2] = (uint8_t)(((x + 1) * 255 + 4) / 8);
            expected_mesh_pixels[pixel + 3] = 255;
        }
    }
    if (zpu_metal_texture_get_bytes(mesh_texture, mesh_pixels, sizeof(mesh_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(mesh_pixels, expected_mesh_pixels, sizeof(mesh_pixels)) != 0) return 46;
    zpu_metal_render_encoder_destroy(mesh_encoder);
    zpu_metal_command_buffer_destroy(mesh_commands);
    zpu_metal_buffer_destroy(mesh_arguments);
    zpu_metal_texture_destroy(mesh_texture);

    zpu_metal_texture *mesh_threads_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    zpu_metal_command_buffer *mesh_threads_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *mesh_threads_encoder =
        zpu_metal_command_buffer_render_encoder(
            mesh_threads_commands, mesh_threads_texture, &render_pass);
    if (mesh_threads_texture == NULL || mesh_threads_commands == NULL ||
        mesh_threads_encoder == NULL ||
        zpu_metal_render_encoder_draw_mesh_threads(
            mesh_threads_encoder, ZPU_METAL_MESH_FILL_GRADIENT_RGBA8,
            (zpu_metal_size){5, 3, 1}, (zpu_metal_size){1, 1, 1},
            (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_render_encoder_end_encoding(mesh_threads_encoder) != 0 ||
        zpu_metal_command_buffer_commit(mesh_threads_commands) != 0 ||
        zpu_metal_command_buffer_get_status(mesh_threads_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 47;
    uint8_t mesh_threads_pixels[5 * 3 * 4] = {0};
    uint8_t expected_mesh_threads_pixels[sizeof(mesh_threads_pixels)] = {0};
    for (size_t y = 0; y < 3; ++y) {
        for (size_t x = 0; x < 5; ++x) {
            const size_t pixel = (y * 5 + x) * 4;
            expected_mesh_threads_pixels[pixel + 3] = 255;
            if (x < 4 && y < 2) {
                expected_mesh_threads_pixels[pixel + 0] = 64;
                expected_mesh_threads_pixels[pixel + 1] =
                    (uint8_t)(((y + 1) * 255 + 4) / 8);
                expected_mesh_threads_pixels[pixel + 2] =
                    (uint8_t)(((x + 1) * 255 + 4) / 8);
            }
        }
    }
    if (zpu_metal_texture_get_bytes(mesh_threads_texture, mesh_threads_pixels,
                                    sizeof(mesh_threads_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(mesh_threads_pixels, expected_mesh_threads_pixels,
               sizeof(mesh_threads_pixels)) != 0) return 48;
    zpu_metal_render_encoder_destroy(mesh_threads_encoder);
    zpu_metal_command_buffer_destroy(mesh_threads_commands);
    zpu_metal_texture_destroy(mesh_threads_texture);

    zpu_metal_texture *patch_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    zpu_metal_texture *patch_reference_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    const uint16_t initial_patch_factors[] = {0, 0, 0, 0};
    const uint16_t committed_patch_factors[] = {0x3c00, 0x3c00, 0x3c00, 0x3c00};
    zpu_metal_buffer *patch_factor_buffer = zpu_metal_device_new_buffer(
        device, sizeof(initial_patch_factors), initial_patch_factors);
    zpu_metal_command_buffer *patch_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *patch_encoder =
        zpu_metal_command_buffer_render_encoder(patch_commands, patch_texture, &render_pass);
    zpu_metal_command_buffer *patch_reference_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *patch_reference_encoder =
        zpu_metal_command_buffer_render_encoder(
            patch_reference_commands, patch_reference_texture, &render_pass);
    uint8_t patch_before_commit[5 * 3 * 4] = {0};
    if (patch_texture == NULL || patch_reference_texture == NULL || patch_factor_buffer == NULL ||
        patch_commands == NULL || patch_encoder == NULL || patch_reference_commands == NULL ||
        patch_reference_encoder == NULL ||
        zpu_metal_render_encoder_set_vertex_buffer(patch_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_buffer(
            patch_encoder, NULL, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_buffer(
            patch_encoder, patch_factor_buffer, 0, sizeof(committed_patch_factors)) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_scale(patch_encoder, 1.0f) != 0 ||
        zpu_metal_render_encoder_draw_patches(
            patch_encoder, ZPU_METAL_PATCH_TRIANGLE_RGBA8, 3, 0, 1, NULL, 0, 1, 0,
            ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_NONE, NULL, 0) != 0 ||
        zpu_metal_buffer_write(patch_factor_buffer, 0, committed_patch_factors,
                               sizeof(committed_patch_factors)) != 0 ||
        zpu_metal_render_encoder_end_encoding(patch_encoder) != 0 ||
        zpu_metal_render_encoder_set_vertex_buffer(
            patch_reference_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_draw_primitives(
            patch_reference_encoder, ZPU_METAL_TRIANGLE, 0, 3, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(patch_reference_encoder) != 0 ||
        zpu_metal_texture_get_bytes(patch_texture, patch_before_commit, sizeof(patch_before_commit), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(patch_before_commit, (const uint8_t[sizeof(patch_before_commit)]){0},
               sizeof(patch_before_commit)) != 0) return 49;
    if (zpu_metal_command_buffer_commit(patch_commands) != 0 ||
        zpu_metal_command_buffer_commit(patch_reference_commands) != 0 ||
        zpu_metal_command_buffer_get_status(patch_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED ||
        zpu_metal_command_buffer_get_status(patch_reference_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 50;
    uint8_t patch_pixels[5 * 3 * 4] = {0};
    uint8_t patch_reference_pixels[sizeof(patch_pixels)] = {0};
    if (zpu_metal_texture_get_bytes(patch_texture, patch_pixels, sizeof(patch_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        zpu_metal_texture_get_bytes(patch_reference_texture, patch_reference_pixels,
                                    sizeof(patch_reference_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(patch_pixels, patch_reference_pixels, sizeof(patch_pixels)) != 0) return 51;
    zpu_metal_render_encoder_destroy(patch_encoder);
    zpu_metal_render_encoder_destroy(patch_reference_encoder);
    zpu_metal_command_buffer_destroy(patch_commands);
    zpu_metal_command_buffer_destroy(patch_reference_commands);
    zpu_metal_buffer_destroy(patch_factor_buffer);
    zpu_metal_texture_destroy(patch_texture);
    zpu_metal_texture_destroy(patch_reference_texture);

    zpu_metal_texture *indexed_patch_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    zpu_metal_texture *indexed_patch_reference_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    const uint32_t indexed_patch_ids[] = {1};
    const uint16_t indexed_patch_control_points[] = {0, 0, 0, 0, 1, 2};
    const uint8_t indexed_patch_initial_factors[20] = {0};
    const uint16_t indexed_patch_factors[] = {0x3c00, 0x3c00, 0x3c00, 0x3c00};
    zpu_metal_buffer *indexed_patch_id_buffer = zpu_metal_device_new_buffer(
        device, sizeof(indexed_patch_ids), indexed_patch_ids);
    zpu_metal_buffer *indexed_patch_control_point_buffer = zpu_metal_device_new_buffer(
        device, sizeof(indexed_patch_control_points), indexed_patch_control_points);
    zpu_metal_buffer *indexed_patch_factor_buffer = zpu_metal_device_new_buffer(
        device, sizeof(indexed_patch_initial_factors), indexed_patch_initial_factors);
    zpu_metal_command_buffer *indexed_patch_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *indexed_patch_encoder =
        zpu_metal_command_buffer_render_encoder(indexed_patch_commands, indexed_patch_texture, &render_pass);
    zpu_metal_command_buffer *indexed_patch_reference_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *indexed_patch_reference_encoder =
        zpu_metal_command_buffer_render_encoder(
            indexed_patch_reference_commands, indexed_patch_reference_texture, &render_pass);
    if (indexed_patch_texture == NULL || indexed_patch_reference_texture == NULL ||
        indexed_patch_id_buffer == NULL || indexed_patch_control_point_buffer == NULL ||
        indexed_patch_factor_buffer == NULL || indexed_patch_commands == NULL ||
        indexed_patch_encoder == NULL || indexed_patch_reference_commands == NULL ||
        indexed_patch_reference_encoder == NULL ||
        zpu_metal_render_encoder_set_vertex_buffer(indexed_patch_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_buffer(
            indexed_patch_encoder, indexed_patch_factor_buffer, sizeof(uint32_t),
            sizeof(indexed_patch_factors)) != 0 ||
        zpu_metal_render_encoder_draw_patches(
            indexed_patch_encoder, ZPU_METAL_PATCH_TRIANGLE_RGBA8, 3, 0, 1,
            indexed_patch_id_buffer, 0, 1, 0,
            ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_UINT16,
            indexed_patch_control_point_buffer, 0) != 0 ||
        zpu_metal_buffer_write(indexed_patch_factor_buffer, sizeof(uint32_t),
                               indexed_patch_factors, sizeof(indexed_patch_factors)) != 0 ||
        zpu_metal_render_encoder_end_encoding(indexed_patch_encoder) != 0 ||
        zpu_metal_render_encoder_set_vertex_buffer(
            indexed_patch_reference_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_draw_primitives(
            indexed_patch_reference_encoder, ZPU_METAL_TRIANGLE, 0, 3, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(indexed_patch_reference_encoder) != 0 ||
        zpu_metal_command_buffer_commit(indexed_patch_commands) != 0 ||
        zpu_metal_command_buffer_commit(indexed_patch_reference_commands) != 0 ||
        zpu_metal_command_buffer_get_status(indexed_patch_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED ||
        zpu_metal_command_buffer_get_status(indexed_patch_reference_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 53;
    uint8_t indexed_patch_pixels[5 * 3 * 4] = {0};
    uint8_t indexed_patch_reference_pixels[sizeof(indexed_patch_pixels)] = {0};
    if (zpu_metal_texture_get_bytes(indexed_patch_texture, indexed_patch_pixels,
                                    sizeof(indexed_patch_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        zpu_metal_texture_get_bytes(indexed_patch_reference_texture,
                                    indexed_patch_reference_pixels,
                                    sizeof(indexed_patch_reference_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(indexed_patch_pixels, indexed_patch_reference_pixels,
               sizeof(indexed_patch_pixels)) != 0) return 54;
    zpu_metal_render_encoder_destroy(indexed_patch_encoder);
    zpu_metal_render_encoder_destroy(indexed_patch_reference_encoder);
    zpu_metal_command_buffer_destroy(indexed_patch_commands);
    zpu_metal_command_buffer_destroy(indexed_patch_reference_commands);
    zpu_metal_buffer_destroy(indexed_patch_id_buffer);
    zpu_metal_buffer_destroy(indexed_patch_control_point_buffer);
    zpu_metal_buffer_destroy(indexed_patch_factor_buffer);
    zpu_metal_texture_destroy(indexed_patch_texture);
    zpu_metal_texture_destroy(indexed_patch_reference_texture);

    zpu_metal_texture *indirect_patch_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    zpu_metal_texture *indirect_patch_reference_texture =
        zpu_metal_device_new_texture(device, &mesh_descriptor);
    const uint32_t initial_indirect_patch_args[] = {0, 0, 0, 0};
    const uint32_t committed_indirect_patch_args[] = {1, 1, 0, 0};
    const uint16_t initial_indirect_patch_factors[] = {0, 0, 0, 0};
    const uint16_t committed_indirect_patch_factors[] = {0x3c00, 0x3c00, 0x3c00, 0x3c00};
    zpu_metal_buffer *indirect_patch_args = zpu_metal_device_new_buffer(
        device, sizeof(initial_indirect_patch_args), initial_indirect_patch_args);
    zpu_metal_buffer *indirect_patch_factor_buffer = zpu_metal_device_new_buffer(
        device, sizeof(initial_indirect_patch_factors), initial_indirect_patch_factors);
    zpu_metal_command_buffer *indirect_patch_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *indirect_patch_encoder =
        zpu_metal_command_buffer_render_encoder(indirect_patch_commands, indirect_patch_texture, &render_pass);
    zpu_metal_command_buffer *indirect_patch_reference_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *indirect_patch_reference_encoder =
        zpu_metal_command_buffer_render_encoder(
            indirect_patch_reference_commands, indirect_patch_reference_texture, &render_pass);
    uint8_t indirect_patch_before_commit[5 * 3 * 4] = {0};
    if (indirect_patch_texture == NULL || indirect_patch_reference_texture == NULL ||
        indirect_patch_args == NULL || indirect_patch_factor_buffer == NULL ||
        indirect_patch_commands == NULL || indirect_patch_encoder == NULL ||
        indirect_patch_reference_commands == NULL || indirect_patch_reference_encoder == NULL ||
        zpu_metal_render_encoder_set_vertex_buffer(indirect_patch_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_buffer(
            indirect_patch_encoder, indirect_patch_factor_buffer, 0,
            sizeof(committed_indirect_patch_factors)) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_scale(indirect_patch_encoder, 1.0f) != 0 ||
        zpu_metal_render_encoder_draw_patches_indirect(
            indirect_patch_encoder, ZPU_METAL_PATCH_TRIANGLE_RGBA8, 3,
            NULL, 0, indirect_patch_args, 0,
            ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_NONE, NULL, 0) != 0 ||
        zpu_metal_buffer_write(indirect_patch_args, 0, committed_indirect_patch_args,
                               sizeof(committed_indirect_patch_args)) != 0 ||
        zpu_metal_buffer_write(indirect_patch_factor_buffer, 0, committed_indirect_patch_factors,
                               sizeof(committed_indirect_patch_factors)) != 0 ||
        zpu_metal_render_encoder_end_encoding(indirect_patch_encoder) != 0 ||
        zpu_metal_render_encoder_set_vertex_buffer(
            indirect_patch_reference_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_draw_primitives(
            indirect_patch_reference_encoder, ZPU_METAL_TRIANGLE, 0, 3, 1) != 0 ||
        zpu_metal_render_encoder_end_encoding(indirect_patch_reference_encoder) != 0 ||
        zpu_metal_texture_get_bytes(indirect_patch_texture, indirect_patch_before_commit,
                                    sizeof(indirect_patch_before_commit), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(indirect_patch_before_commit, (const uint8_t[sizeof(indirect_patch_before_commit)]){0},
               sizeof(indirect_patch_before_commit)) != 0) return 55;
    if (zpu_metal_command_buffer_commit(indirect_patch_commands) != 0 ||
        zpu_metal_command_buffer_commit(indirect_patch_reference_commands) != 0 ||
        zpu_metal_command_buffer_get_status(indirect_patch_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED ||
        zpu_metal_command_buffer_get_status(indirect_patch_reference_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 56;
    uint8_t indirect_patch_pixels[5 * 3 * 4] = {0};
    uint8_t indirect_patch_reference_pixels[sizeof(indirect_patch_pixels)] = {0};
    if (zpu_metal_texture_get_bytes(indirect_patch_texture, indirect_patch_pixels,
                                    sizeof(indirect_patch_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        zpu_metal_texture_get_bytes(indirect_patch_reference_texture,
                                    indirect_patch_reference_pixels,
                                    sizeof(indirect_patch_reference_pixels), 5 * 4,
                                    (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
        memcmp(indirect_patch_pixels, indirect_patch_reference_pixels,
               sizeof(indirect_patch_pixels)) != 0) return 57;
    zpu_metal_render_encoder_destroy(indirect_patch_encoder);
    zpu_metal_render_encoder_destroy(indirect_patch_reference_encoder);
    zpu_metal_command_buffer_destroy(indirect_patch_commands);
    zpu_metal_command_buffer_destroy(indirect_patch_reference_commands);
    zpu_metal_buffer_destroy(indirect_patch_args);
    zpu_metal_buffer_destroy(indirect_patch_factor_buffer);
    zpu_metal_texture_destroy(indirect_patch_texture);
    zpu_metal_texture_destroy(indirect_patch_reference_texture);

    zpu_metal_texture *layer_patch_textures[3] = {0};
    zpu_metal_texture *layer_patch_reference_textures[3] = {0};
    for (size_t layer = 0; layer < 3; ++layer) {
        layer_patch_textures[layer] = zpu_metal_device_new_texture(device, &mesh_descriptor);
        layer_patch_reference_textures[layer] = zpu_metal_device_new_texture(device, &mesh_descriptor);
    }
    const uint16_t layer_patch_initial_factors[12] = {0};
    const uint16_t layer_patch_committed_factors[] = {
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
    };
    zpu_metal_buffer *layer_patch_factor_buffer = zpu_metal_device_new_buffer(
        device, sizeof(layer_patch_initial_factors), layer_patch_initial_factors);
    zpu_metal_command_buffer *layer_patch_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *layer_patch_encoder =
        zpu_metal_command_buffer_render_encoder(layer_patch_commands, layer_patch_textures[0], &render_pass);
    zpu_metal_command_buffer *layer_patch_reference_commands =
        zpu_metal_command_queue_command_buffer(queue);
    const zpu_metal_viewport layer_patch_viewport = {1.0f, 1.0f, 3.0f, 2.0f, 0.0f, 1.0f};
    const zpu_metal_scissor_rect layer_patch_scissor = {1, 1, 3, 2};
    int layer_patch_setup_failed = layer_patch_factor_buffer == NULL ||
        layer_patch_commands == NULL || layer_patch_encoder == NULL ||
        layer_patch_reference_commands == NULL;
    for (size_t layer = 0; layer < 3; ++layer) {
        if (layer_patch_textures[layer] == NULL || layer_patch_reference_textures[layer] == NULL) {
            layer_patch_setup_failed = 1;
        }
    }
    if (layer_patch_setup_failed ||
        zpu_metal_render_encoder_set_render_target_array(layer_patch_encoder, layer_patch_textures, 3) != 0 ||
        zpu_metal_render_encoder_set_viewport(layer_patch_encoder, layer_patch_viewport) != 0 ||
        zpu_metal_render_encoder_set_scissor_rect(layer_patch_encoder, layer_patch_scissor) != 0 ||
        zpu_metal_render_encoder_set_vertex_buffer(layer_patch_encoder, vertex_buffer, 0, 0) != 0 ||
        zpu_metal_render_encoder_set_tessellation_factor_buffer(
            layer_patch_encoder, layer_patch_factor_buffer, 0, sizeof(uint16_t) * 4) != 0 ||
        zpu_metal_render_encoder_draw_patches(
            layer_patch_encoder, ZPU_METAL_PATCH_TRIANGLE_RGBA8, 3, 0, 1, NULL, 0, 2, 1,
            ZPU_METAL_TESSELLATION_CONTROL_POINT_INDEX_NONE, NULL, 0) != 0 ||
        zpu_metal_buffer_write(layer_patch_factor_buffer, 0, layer_patch_committed_factors,
                               sizeof(layer_patch_committed_factors)) != 0 ||
        zpu_metal_render_encoder_end_encoding(layer_patch_encoder) != 0) return 58;
    for (size_t layer = 0; layer < 3; ++layer) {
        zpu_metal_render_encoder *reference_encoder =
            zpu_metal_command_buffer_render_encoder(
                layer_patch_reference_commands, layer_patch_reference_textures[layer], &render_pass);
        if (reference_encoder == NULL ||
            zpu_metal_render_encoder_set_viewport(reference_encoder, layer_patch_viewport) != 0 ||
            zpu_metal_render_encoder_set_scissor_rect(reference_encoder, layer_patch_scissor) != 0 ||
            (layer != 0 && zpu_metal_render_encoder_set_vertex_buffer(reference_encoder, vertex_buffer, 0, 0) != 0) ||
            (layer != 0 && zpu_metal_render_encoder_draw_primitives(reference_encoder, ZPU_METAL_TRIANGLE, 0, 3, 1) != 0) ||
            zpu_metal_render_encoder_end_encoding(reference_encoder) != 0) return 59;
        zpu_metal_render_encoder_destroy(reference_encoder);
    }
    uint8_t layer_patch_before[3][5 * 3 * 4] = {{0}};
    for (size_t layer = 0; layer < 3; ++layer) {
        if (zpu_metal_texture_get_bytes(layer_patch_textures[layer], layer_patch_before[layer],
                                        sizeof(layer_patch_before[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            memcmp(layer_patch_before[layer], (const uint8_t[sizeof(layer_patch_before[layer])]){0},
                   sizeof(layer_patch_before[layer])) != 0) return 60;
    }
    if (zpu_metal_command_buffer_commit(layer_patch_commands) != 0 ||
        zpu_metal_command_buffer_commit(layer_patch_reference_commands) != 0 ||
        zpu_metal_command_buffer_get_status(layer_patch_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED ||
        zpu_metal_command_buffer_get_status(layer_patch_reference_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 61;
    uint8_t layer_patch_pixels[3][5 * 3 * 4] = {{0}};
    uint8_t layer_patch_reference_pixels[3][5 * 3 * 4] = {{0}};
    for (size_t layer = 0; layer < 3; ++layer) {
        if (zpu_metal_texture_get_bytes(layer_patch_textures[layer], layer_patch_pixels[layer],
                                        sizeof(layer_patch_pixels[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            zpu_metal_texture_get_bytes(layer_patch_reference_textures[layer], layer_patch_reference_pixels[layer],
                                        sizeof(layer_patch_reference_pixels[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            memcmp(layer_patch_pixels[layer], layer_patch_reference_pixels[layer],
                   sizeof(layer_patch_pixels[layer])) != 0) return 62;
    }
    if (memcmp(layer_patch_pixels[0], layer_patch_pixels[1], sizeof(layer_patch_pixels[0])) == 0 ||
        memcmp(layer_patch_pixels[1], layer_patch_pixels[2], sizeof(layer_patch_pixels[1])) != 0) return 63;
    zpu_metal_render_encoder_destroy(layer_patch_encoder);
    for (size_t layer = 0; layer < 3; ++layer) {
        zpu_metal_texture_destroy(layer_patch_textures[layer]);
        zpu_metal_texture_destroy(layer_patch_reference_textures[layer]);
    }
    zpu_metal_command_buffer_destroy(layer_patch_commands);
    zpu_metal_command_buffer_destroy(layer_patch_reference_commands);
    zpu_metal_buffer_destroy(layer_patch_factor_buffer);

    zpu_metal_texture *layer_tile_textures[3] = {0};
    zpu_metal_texture *layer_tile_reference_textures[3] = {0};
    for (size_t layer = 0; layer < 3; ++layer) {
        layer_tile_textures[layer] = zpu_metal_device_new_texture(device, &mesh_descriptor);
        layer_tile_reference_textures[layer] = zpu_metal_device_new_texture(device, &mesh_descriptor);
    }
    zpu_metal_command_buffer *layer_tile_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_render_encoder *layer_tile_encoder =
        zpu_metal_command_buffer_render_encoder(layer_tile_commands, layer_tile_textures[0], &render_pass);
    zpu_metal_command_buffer *layer_tile_reference_commands =
        zpu_metal_command_queue_command_buffer(queue);
    int layer_tile_setup_failed = layer_tile_commands == NULL || layer_tile_encoder == NULL ||
        layer_tile_reference_commands == NULL;
    for (size_t layer = 0; layer < 3; ++layer) {
        if (layer_tile_textures[layer] == NULL || layer_tile_reference_textures[layer] == NULL) {
            layer_tile_setup_failed = 1;
        }
    }
    if (layer_tile_setup_failed ||
        zpu_metal_render_encoder_set_render_target_array(layer_tile_encoder, layer_tile_textures, 3) != 0 ||
        zpu_metal_render_encoder_dispatch_threads_per_tile(
            layer_tile_encoder, ZPU_METAL_TILE_FILL_GRADIENT_RGBA8,
            (zpu_metal_size){2, 2, 1}, (zpu_metal_size){2, 2, 1}) != 0 ||
        zpu_metal_render_encoder_end_encoding(layer_tile_encoder) != 0) return 86;
    for (size_t layer = 0; layer < 3; ++layer) {
        zpu_metal_render_encoder *reference_encoder = zpu_metal_command_buffer_render_encoder(
            layer_tile_reference_commands, layer_tile_reference_textures[layer], &render_pass);
        if (reference_encoder == NULL ||
            zpu_metal_render_encoder_dispatch_threads_per_tile(
                reference_encoder, ZPU_METAL_TILE_FILL_GRADIENT_RGBA8,
                (zpu_metal_size){2, 2, 1}, (zpu_metal_size){2, 2, 1}) != 0 ||
            zpu_metal_render_encoder_end_encoding(reference_encoder) != 0) return 87;
        zpu_metal_render_encoder_destroy(reference_encoder);
    }
    uint8_t layer_tile_before[3][5 * 3 * 4] = {{0}};
    for (size_t layer = 0; layer < 3; ++layer) {
        if (zpu_metal_texture_get_bytes(layer_tile_textures[layer], layer_tile_before[layer],
                                        sizeof(layer_tile_before[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            memcmp(layer_tile_before[layer], (const uint8_t[sizeof(layer_tile_before[layer])]){0},
                   sizeof(layer_tile_before[layer])) != 0) return 88;
    }
    if (zpu_metal_command_buffer_commit(layer_tile_commands) != 0 ||
        zpu_metal_command_buffer_commit(layer_tile_reference_commands) != 0 ||
        zpu_metal_command_buffer_get_status(layer_tile_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED ||
        zpu_metal_command_buffer_get_status(layer_tile_reference_commands) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) return 89;
    uint8_t layer_tile_pixels[3][5 * 3 * 4] = {{0}};
    uint8_t layer_tile_reference_pixels[3][5 * 3 * 4] = {{0}};
    for (size_t layer = 0; layer < 3; ++layer) {
        if (zpu_metal_texture_get_bytes(layer_tile_textures[layer], layer_tile_pixels[layer],
                                        sizeof(layer_tile_pixels[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            zpu_metal_texture_get_bytes(layer_tile_reference_textures[layer], layer_tile_reference_pixels[layer],
                                        sizeof(layer_tile_reference_pixels[layer]), 5 * 4,
                                        (zpu_metal_region){{0, 0, 0}, {5, 3, 1}}) != 0 ||
            memcmp(layer_tile_pixels[layer], layer_tile_reference_pixels[layer],
                   sizeof(layer_tile_pixels[layer])) != 0) return 90;
    }
    if (memcmp(layer_tile_pixels[0], (const uint8_t[]){64, 32, 32, 255}, 4) != 0 ||
        memcmp(layer_tile_pixels[0] + 2 * 5 * 4 + 4 * 4,
               (const uint8_t[]){64, 96, 159, 255}, 4) != 0 ||
        memcmp(layer_tile_pixels[0], layer_tile_pixels[1], sizeof(layer_tile_pixels[0])) != 0 ||
        memcmp(layer_tile_pixels[1], layer_tile_pixels[2], sizeof(layer_tile_pixels[1])) != 0) return 91;
    zpu_metal_render_encoder_destroy(layer_tile_encoder);
    for (size_t layer = 0; layer < 3; ++layer) {
        zpu_metal_texture_destroy(layer_tile_textures[layer]);
        zpu_metal_texture_destroy(layer_tile_reference_textures[layer]);
    }
    zpu_metal_command_buffer_destroy(layer_tile_commands);
    zpu_metal_command_buffer_destroy(layer_tile_reference_commands);

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
        zpu_metal_render_encoder_draw_primitives_base_instance(
            base_vertex_encoder, ZPU_METAL_TRIANGLE, 1, 3, 1, 0) != 0 ||
        zpu_metal_render_encoder_draw_indexed_primitives_base_vertex_instance(
            base_vertex_encoder, ZPU_METAL_TRIANGLE, 3, ZPU_METAL_INDEX_UINT16,
            base_index_buffer, 0, 1, 1, 0) != 0 ||
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

    const size_t sparse_page_bytes = ZPU_METAL_SPARSE_PAGE_SIZE_16K;
    uint8_t sparse_pattern[ZPU_METAL_SPARSE_PAGE_SIZE_16K];
    for (size_t index = 0; index < sizeof(sparse_pattern); ++index) {
        sparse_pattern[index] = (uint8_t)((index * 37u + 5u) & 0xffu);
    }
    zpu_metal_buffer *sparse_upload = zpu_metal_device_new_buffer(
        device, sizeof(sparse_pattern), sparse_pattern);
    zpu_metal_buffer *sparse_source = zpu_metal_device_new_sparse_buffer(
        device, sparse_page_bytes * 2, sparse_page_bytes);
    zpu_metal_buffer *sparse_destination = zpu_metal_device_new_sparse_buffer(
        device, sparse_page_bytes * 2, sparse_page_bytes);
    zpu_metal_buffer *sparse_readback = zpu_metal_device_new_buffer(
        device, sizeof(sparse_pattern), NULL);
    if (sparse_upload == NULL || sparse_source == NULL || sparse_destination == NULL ||
        sparse_readback == NULL || zpu_metal_buffer_is_sparse(sparse_source) != 1 ||
        zpu_metal_buffer_sparse_page_size(sparse_source) != sparse_page_bytes ||
        zpu_metal_buffer_contents(sparse_source) != NULL ||
        zpu_metal_device_new_sparse_buffer(device, sizeof(sparse_pattern), 1234) != NULL) return 58;

    zpu_metal_command_buffer *sparse_upload_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_upload_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_upload_commands);
    zpu_metal_blit_encoder *sparse_upload_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_upload_commands);
    if (sparse_upload_commands == NULL || sparse_upload_state == NULL ||
        sparse_upload_encoder != NULL ||
        zpu_metal_resource_state_encoder_update_buffer_mapping(
            sparse_upload_state, sparse_source, ZPU_METAL_SPARSE_MAPPING_MAP,
            0, sparse_page_bytes) != 0 ||
        zpu_metal_resource_state_encoder_update_buffer_mapping(
            sparse_upload_state, sparse_destination, ZPU_METAL_SPARSE_MAPPING_MAP,
            0, sparse_page_bytes) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_upload_state) != 0) return 59;
    zpu_metal_resource_state_encoder_destroy(sparse_upload_state);
    sparse_upload_encoder = zpu_metal_command_buffer_blit_encoder(sparse_upload_commands);
    if (sparse_upload_encoder == NULL ||
        zpu_metal_blit_encoder_copy_buffer(sparse_upload_encoder, sparse_upload, 0,
                                           sparse_source, 0, sparse_page_bytes) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_upload_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_upload_commands) != 0) return 60;
    zpu_metal_blit_encoder_destroy(sparse_upload_encoder);
    zpu_metal_command_buffer_destroy(sparse_upload_commands);

    zpu_metal_command_buffer *sparse_copy_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_copy_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_copy_commands);
    if (sparse_copy_commands == NULL || sparse_copy_state == NULL ||
        zpu_metal_resource_state_encoder_copy_buffer_mappings(
            sparse_copy_state, sparse_source, sparse_destination,
            0, sparse_page_bytes, sparse_page_bytes) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_copy_state) != 0) return 61;
    zpu_metal_resource_state_encoder_destroy(sparse_copy_state);
    zpu_metal_blit_encoder *sparse_copy_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_copy_commands);
    if (sparse_copy_encoder == NULL ||
        zpu_metal_blit_encoder_copy_buffer(sparse_copy_encoder, sparse_destination,
                                           sparse_page_bytes, sparse_readback, 0,
                                           sparse_page_bytes) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_copy_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_copy_commands) != 0 ||
        check_equal((const uint8_t *)zpu_metal_buffer_contents(sparse_readback),
                    sparse_pattern, sparse_page_bytes) != 0) return 62;
    zpu_metal_blit_encoder_destroy(sparse_copy_encoder);
    zpu_metal_command_buffer_destroy(sparse_copy_commands);

    memset(sparse_pattern, 0, sizeof(sparse_pattern));
    if (zpu_metal_buffer_write(sparse_upload, 0, sparse_pattern,
                               sparse_page_bytes) != 0) return 63;
    zpu_metal_command_buffer *sparse_alias_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *sparse_alias_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_alias_commands);
    if (sparse_alias_commands == NULL || sparse_alias_encoder == NULL ||
        zpu_metal_blit_encoder_copy_buffer(sparse_alias_encoder, sparse_upload, 0,
                                           sparse_source, 0, sparse_page_bytes) != 0 ||
        zpu_metal_blit_encoder_copy_buffer(sparse_alias_encoder, sparse_destination,
                                           sparse_page_bytes, sparse_readback, 0,
                                           sparse_page_bytes) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_alias_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_alias_commands) != 0 ||
        check_equal((const uint8_t *)zpu_metal_buffer_contents(sparse_readback),
                    sparse_pattern, sparse_page_bytes) != 0) return 64;
    zpu_metal_blit_encoder_destroy(sparse_alias_encoder);
    zpu_metal_command_buffer_destroy(sparse_alias_commands);

    zpu_metal_command_buffer *sparse_unmap_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_unmap_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_unmap_commands);
    if (sparse_unmap_commands == NULL || sparse_unmap_state == NULL ||
        zpu_metal_resource_state_encoder_update_buffer_mapping(
            sparse_unmap_state, sparse_destination, ZPU_METAL_SPARSE_MAPPING_UNMAP,
            sparse_page_bytes, sparse_page_bytes) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_unmap_state) != 0) return 65;
    zpu_metal_resource_state_encoder_destroy(sparse_unmap_state);
    zpu_metal_blit_encoder *sparse_unmap_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_unmap_commands);
    if (sparse_unmap_encoder == NULL ||
        zpu_metal_blit_encoder_copy_buffer(sparse_unmap_encoder, sparse_destination,
                                           sparse_page_bytes, sparse_readback, 0,
                                           sparse_page_bytes) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_unmap_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_unmap_commands) != 0) return 66;
    const uint8_t sparse_zero[ZPU_METAL_SPARSE_PAGE_SIZE_16K] = {0};
    if (check_equal((const uint8_t *)zpu_metal_buffer_contents(sparse_readback),
                    sparse_zero, sparse_page_bytes) != 0) return 67;
    zpu_metal_blit_encoder_destroy(sparse_unmap_encoder);
    zpu_metal_command_buffer_destroy(sparse_unmap_commands);
    zpu_metal_buffer_destroy(sparse_readback);
    zpu_metal_buffer_destroy(sparse_destination);
    zpu_metal_buffer_destroy(sparse_source);
    zpu_metal_buffer_destroy(sparse_upload);

    const size_t sparse_texture_tile_bytes = 64u * 64u * 4u;
    uint8_t sparse_texture_pattern[64u * 64u * 4u];
    for (size_t index = 0; index < sizeof(sparse_texture_pattern); ++index) {
        sparse_texture_pattern[index] = (uint8_t)((index * 23u + 9u) & 0xffu);
    }
    zpu_metal_texture_descriptor sparse_texture_descriptor = {
        .width = 128,
        .height = 64,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture_descriptor sparse_tile_descriptor = {
        .width = 64,
        .height = 64,
        .format = ZPU_METAL_RGBA8_UNORM,
    };
    zpu_metal_texture *sparse_texture_source = zpu_metal_device_new_texture(
        device, &sparse_tile_descriptor);
    zpu_metal_texture *sparse_texture = zpu_metal_device_new_sparse_texture(
        device, &sparse_texture_descriptor, sparse_page_bytes);
    zpu_metal_texture *sparse_texture_destination = zpu_metal_device_new_sparse_texture(
        device, &sparse_texture_descriptor, sparse_page_bytes);
    zpu_metal_texture *sparse_texture_readback = zpu_metal_device_new_texture(
        device, &sparse_tile_descriptor);
    if (sparse_texture_source == NULL || sparse_texture == NULL ||
        sparse_texture_destination == NULL || sparse_texture_readback == NULL ||
        zpu_metal_texture_is_sparse(sparse_texture) != 1 ||
        zpu_metal_texture_sparse_page_size(sparse_texture) != sparse_page_bytes ||
        zpu_metal_texture_sparse_tile_width(sparse_texture) != 64 ||
        zpu_metal_texture_sparse_tile_height(sparse_texture) != 64 ||
        zpu_metal_texture_is_sparse(sparse_texture_source) != 0 ||
        zpu_metal_texture_sparse_page_size(sparse_texture_source) != 0 ||
        zpu_metal_texture_view(sparse_texture, ZPU_METAL_RGBA8_UNORM) != NULL ||
        zpu_metal_device_new_sparse_texture(device, &sparse_texture_descriptor, 1234) != NULL) return 68;
    if (zpu_metal_texture_replace_region(
            sparse_texture_source, (zpu_metal_region){{0, 0, 0}, {64, 64, 1}},
            sparse_texture_pattern, sizeof(sparse_texture_pattern), 64u * 4u) != 0) return 69;

    zpu_metal_command_buffer *sparse_texture_upload_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_upload_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_upload_commands);
    const zpu_metal_region sparse_texture_mapping_regions[] = {
        {{0, 0, 0}, {1, 1, 1}},
        {{1, 0, 0}, {1, 1, 1}},
    };
    const size_t sparse_texture_mapping_levels[] = {0, 0};
    const size_t sparse_texture_mapping_slices[] = {0, 0};
    const size_t sparse_texture_invalid_levels[] = {1, 0};
    const struct {
        uint32_t count;
        zpu_metal_sparse_texture_mapping_arguments mappings[2];
    } sparse_texture_indirect_data = {
        .count = 0,
        .mappings = {
            {{{0, 0, 0}, {1, 1, 1}}, 0, 0},
            {{{1, 0, 0}, {1, 1, 1}}, 0, 0},
        },
    };
    zpu_metal_buffer *sparse_texture_indirect_buffer = zpu_metal_device_new_buffer(
        device, sizeof(sparse_texture_indirect_data),
        (const uint8_t *)&sparse_texture_indirect_data);
    if (sparse_texture_upload_commands == NULL || sparse_texture_upload_state == NULL ||
        sparse_texture_indirect_buffer == NULL ||
        zpu_metal_resource_state_encoder_update_texture_mappings(
            sparse_texture_upload_state, sparse_texture, ZPU_METAL_SPARSE_MAPPING_MAP,
            sparse_texture_mapping_regions, 2, sparse_texture_mapping_levels,
            sparse_texture_mapping_slices) != 0 ||
        zpu_metal_resource_state_encoder_update_texture_mapping_indirect(
            sparse_texture_upload_state, sparse_texture_destination,
            ZPU_METAL_SPARSE_MAPPING_MAP, sparse_texture_indirect_buffer, 1) == 0 ||
        zpu_metal_resource_state_encoder_update_texture_mapping_indirect(
            sparse_texture_upload_state, sparse_texture_destination,
            ZPU_METAL_SPARSE_MAPPING_MAP, sparse_texture_indirect_buffer, 0) != 0 ||
        zpu_metal_buffer_write(sparse_texture_indirect_buffer, 0,
                               (const uint32_t[]){2}, sizeof(uint32_t)) != 0 ||
        zpu_metal_resource_state_encoder_update_texture_mappings(
            sparse_texture_upload_state, sparse_texture, ZPU_METAL_SPARSE_MAPPING_MAP,
            sparse_texture_mapping_regions, 2, sparse_texture_invalid_levels,
            sparse_texture_mapping_slices) == 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_upload_state) != 0) return 70;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_upload_state);
    zpu_metal_blit_encoder *sparse_texture_upload_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_upload_commands);
    if (sparse_texture_upload_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_upload_encoder, sparse_texture_source,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}, sparse_texture,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_upload_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_upload_commands) != 0) return 71;
    zpu_metal_blit_encoder_destroy(sparse_texture_upload_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_upload_commands);

    zpu_metal_command_buffer *sparse_texture_copy_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_copy_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_copy_commands);
    if (sparse_texture_copy_commands == NULL || sparse_texture_copy_state == NULL ||
        zpu_metal_resource_state_encoder_copy_texture_mappings(
            sparse_texture_copy_state, sparse_texture, sparse_texture_destination,
            (zpu_metal_region){{0, 0, 0}, {1, 1, 1}},
            (zpu_metal_origin){1, 0, 0}) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_copy_state) != 0) return 72;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_copy_state);
    zpu_metal_blit_encoder *sparse_texture_copy_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_copy_commands);
    if (sparse_texture_copy_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_copy_encoder, sparse_texture_destination,
            (zpu_metal_region){{64, 0, 0}, {64, 64, 1}}, sparse_texture_readback,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_copy_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_copy_commands) != 0) return 73;
    uint8_t sparse_texture_readback_bytes[64u * 64u * 4u];
    if (zpu_metal_texture_get_bytes(
            sparse_texture_readback, sparse_texture_readback_bytes,
            sizeof(sparse_texture_readback_bytes), 64u * 4u,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        check_equal(sparse_texture_readback_bytes, sparse_texture_pattern,
                    sparse_texture_tile_bytes) != 0) return 74;
    zpu_metal_blit_encoder_destroy(sparse_texture_copy_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_copy_commands);

    zpu_metal_command_buffer *sparse_texture_occupied_move_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_occupied_move_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_occupied_move_commands);
    if (sparse_texture_occupied_move_commands == NULL || sparse_texture_occupied_move_state == NULL ||
        zpu_metal_resource_state_encoder_move_texture_mappings(
            sparse_texture_occupied_move_state, sparse_texture, sparse_texture_destination,
            (zpu_metal_region){{0, 0, 0}, {1, 1, 1}}, (zpu_metal_origin){1, 0, 0}) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_occupied_move_state) != 0) return 80;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_occupied_move_state);
    zpu_metal_blit_encoder *sparse_texture_occupied_move_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_occupied_move_commands);
    if (sparse_texture_occupied_move_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_occupied_move_encoder, sparse_texture_destination,
            (zpu_metal_region){{64, 0, 0}, {64, 64, 1}}, sparse_texture_readback,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_occupied_move_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_occupied_move_commands) != 0) return 81;
    if (zpu_metal_texture_get_bytes(
            sparse_texture_readback, sparse_texture_readback_bytes,
            sizeof(sparse_texture_readback_bytes), 64u * 4u,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        check_equal(sparse_texture_readback_bytes, sparse_texture_pattern,
                    sparse_texture_tile_bytes) != 0) return 82;
    zpu_metal_blit_encoder_destroy(sparse_texture_occupied_move_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_occupied_move_commands);

    zpu_metal_command_buffer *sparse_texture_transfer_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_transfer_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_transfer_commands);
    if (sparse_texture_transfer_commands == NULL || sparse_texture_transfer_state == NULL ||
        zpu_metal_resource_state_encoder_update_texture_mapping(
            sparse_texture_transfer_state, sparse_texture_destination,
            ZPU_METAL_SPARSE_MAPPING_UNMAP,
            (zpu_metal_region){{1, 0, 0}, {1, 1, 1}}) != 0 ||
        zpu_metal_resource_state_encoder_move_texture_mappings(
            sparse_texture_transfer_state, sparse_texture, sparse_texture_destination,
            (zpu_metal_region){{0, 0, 0}, {1, 1, 1}}, (zpu_metal_origin){1, 0, 0}) != 0 ||
        zpu_metal_resource_state_encoder_update_texture_mapping(
            sparse_texture_transfer_state, sparse_texture,
            ZPU_METAL_SPARSE_MAPPING_UNMAP,
            (zpu_metal_region){{0, 0, 0}, {1, 1, 1}}) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_transfer_state) != 0) return 83;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_transfer_state);
    zpu_metal_blit_encoder *sparse_texture_transfer_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_transfer_commands);
    if (sparse_texture_transfer_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_transfer_encoder, sparse_texture_destination,
            (zpu_metal_region){{64, 0, 0}, {64, 64, 1}}, sparse_texture_readback,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_transfer_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_transfer_commands) != 0 ||
        zpu_metal_texture_get_bytes(
            sparse_texture_readback, sparse_texture_readback_bytes,
            sizeof(sparse_texture_readback_bytes), 64u * 4u,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        check_equal(sparse_texture_readback_bytes, sparse_texture_pattern,
                    sparse_texture_tile_bytes) != 0) return 84;
    zpu_metal_blit_encoder_destroy(sparse_texture_transfer_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_transfer_commands);

    zpu_metal_command_buffer *sparse_texture_move_restore_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_move_restore_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_move_restore_commands);
    if (sparse_texture_move_restore_commands == NULL || sparse_texture_move_restore_state == NULL ||
        zpu_metal_resource_state_encoder_update_texture_mapping(
            sparse_texture_move_restore_state, sparse_texture_destination,
            ZPU_METAL_SPARSE_MAPPING_UNMAP,
            (zpu_metal_region){{1, 0, 0}, {1, 1, 1}}) != 0 ||
        zpu_metal_resource_state_encoder_update_texture_mapping(
            sparse_texture_move_restore_state, sparse_texture,
            ZPU_METAL_SPARSE_MAPPING_MAP,
            (zpu_metal_region){{0, 0, 0}, {1, 1, 1}}) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_move_restore_state) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_move_restore_commands) != 0) return 85;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_move_restore_state);
    zpu_metal_command_buffer_destroy(sparse_texture_move_restore_commands);

    memset(sparse_texture_pattern, 0, sizeof(sparse_texture_pattern));
    if (zpu_metal_texture_replace_region(
            sparse_texture_source, (zpu_metal_region){{0, 0, 0}, {64, 64, 1}},
            sparse_texture_pattern, sizeof(sparse_texture_pattern), 64u * 4u) != 0) return 75;
    zpu_metal_command_buffer *sparse_texture_alias_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_blit_encoder *sparse_texture_alias_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_alias_commands);
    if (sparse_texture_alias_commands == NULL || sparse_texture_alias_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_alias_encoder, sparse_texture_source,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}, sparse_texture,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_alias_encoder, sparse_texture_destination,
            (zpu_metal_region){{64, 0, 0}, {64, 64, 1}}, sparse_texture_readback,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_alias_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_alias_commands) != 0 ||
        zpu_metal_texture_get_bytes(
            sparse_texture_readback, sparse_texture_readback_bytes,
            sizeof(sparse_texture_readback_bytes), 64u * 4u,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        check_equal(sparse_texture_readback_bytes, sparse_texture_pattern,
                    sparse_texture_tile_bytes) != 0) return 76;
    zpu_metal_blit_encoder_destroy(sparse_texture_alias_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_alias_commands);

    zpu_metal_command_buffer *sparse_texture_unmap_commands =
        zpu_metal_command_queue_command_buffer(queue);
    zpu_metal_resource_state_encoder *sparse_texture_unmap_state =
        zpu_metal_command_buffer_resource_state_encoder(sparse_texture_unmap_commands);
    if (sparse_texture_unmap_commands == NULL || sparse_texture_unmap_state == NULL ||
        zpu_metal_resource_state_encoder_update_texture_mapping(
            sparse_texture_unmap_state, sparse_texture_destination,
            ZPU_METAL_SPARSE_MAPPING_UNMAP,
            (zpu_metal_region){{1, 0, 0}, {1, 1, 1}}) != 0 ||
        zpu_metal_resource_state_encoder_end_encoding(sparse_texture_unmap_state) != 0) return 77;
    zpu_metal_resource_state_encoder_destroy(sparse_texture_unmap_state);
    zpu_metal_blit_encoder *sparse_texture_unmap_encoder =
        zpu_metal_command_buffer_blit_encoder(sparse_texture_unmap_commands);
    if (sparse_texture_unmap_encoder == NULL ||
        zpu_metal_blit_encoder_copy_texture_to_texture(
            sparse_texture_unmap_encoder, sparse_texture_destination,
            (zpu_metal_region){{64, 0, 0}, {64, 64, 1}}, sparse_texture_readback,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0 ||
        zpu_metal_blit_encoder_end_encoding(sparse_texture_unmap_encoder) != 0 ||
        zpu_metal_command_buffer_commit(sparse_texture_unmap_commands) != 0 ||
        zpu_metal_texture_get_bytes(
            sparse_texture_readback, sparse_texture_readback_bytes,
            sizeof(sparse_texture_readback_bytes), 64u * 4u,
            (zpu_metal_region){{0, 0, 0}, {64, 64, 1}}) != 0) return 78;
    const uint8_t sparse_texture_zero[64u * 64u * 4u] = {0};
    if (check_equal(sparse_texture_readback_bytes, sparse_texture_zero,
                    sparse_texture_tile_bytes) != 0) return 79;
    zpu_metal_blit_encoder_destroy(sparse_texture_unmap_encoder);
    zpu_metal_command_buffer_destroy(sparse_texture_unmap_commands);
    zpu_metal_texture_destroy(sparse_texture_readback);
    zpu_metal_texture_destroy(sparse_texture_destination);
    zpu_metal_texture_destroy(sparse_texture);
    zpu_metal_texture_destroy(sparse_texture_source);
    zpu_metal_buffer_destroy(sparse_texture_indirect_buffer);

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

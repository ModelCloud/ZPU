/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "zpu/metal.h"
#include "zpu/metal_apple.h"

static const char *const kShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vertex { float4 position [[position]]; float4 color; };\n"
    "vertex Vertex zpu_test_vertex(uint vertex_id [[vertex_id]], "
    "device const Vertex *vertices [[buffer(0)]]) { return vertices[vertex_id]; }\n"
    "vertex void zpu_test_no_raster_vertex(uint vertex_id [[vertex_id]]) { (void)vertex_id; }\n"
    "fragment float4 zpu_test_fragment(Vertex input [[stage_in]]) { return input.color; }\n"
    "fragment float4 zpu_test_uniform_fragment(Vertex input [[stage_in]], "
    "constant float4 &uniformColor [[buffer(0)]]) { (void)input; return uniformColor; }\n"
    "fragment float4 zpu_test_depth_bounds_oracle(Vertex input [[stage_in]]) { "
    "if (input.position.z < 0.5 || input.position.z > 1.0) discard_fragment(); "
    "return input.color; }\n"
    "struct MRTOutput { float4 first [[color(0)]]; float4 second [[color(1)]]; };\n"
    "fragment MRTOutput zpu_test_mrt_fragment(Vertex input [[stage_in]]) { "
    "MRTOutput output; output.first = input.color; output.second = input.color; return output; }\n"
    "fragment float4 zpu_test_sample_fragment(Vertex input [[stage_in]], "
    "texture2d<float> source [[texture(0)]], sampler sourceSampler [[sampler(0)]]) { "
    "return source.sample(sourceSampler, input.color.xy); }\n"
    "kernel void zpu_cpu_fill_gradient_rgba8(texture2d<float, access::write> output [[texture(0)]], "
    "uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write(float4((float(gid.x) + 1.0) / 8.0, (float(gid.y) + 1.0) / 8.0, 0.25, 1.0), gid); }\n"
    "kernel void zpu_cpu_fill_gradient_rgba8_array(texture2d_array<float, access::write> output [[texture(0)]], "
    "uint3 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height() || gid.z >= output.get_array_size()) return; "
    "output.write(float4((float(gid.x) + 1.0) / 8.0, (float(gid.y) + 1.0) / 8.0, 0.25, 1.0), gid.xy, gid.z); }\n"
    "kernel void zpu_cpu_fill_gradient_rgba8_3d(texture3d<float, access::write> output [[texture(0)]], "
    "uint3 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height() || gid.z >= output.get_depth()) return; "
    "output.write(float4((float(gid.x) + 1.0) / 8.0, (float(gid.y) + 1.0) / 8.0, "
    "(float(gid.z) + 1.0) / 8.0, 1.0), gid); }\n"
    "kernel void zpu_cpu_copy_rgba8_buffer_to_texture(device const uchar4 *source [[buffer(0)]], "
    "texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write(float4(source[gid.y * output.get_width() + gid.x]) / 255.0, gid); }\n"
    "kernel void zpu_cpu_fill_gradient_r32_float(texture2d<float, access::write> output [[texture(0)]], "
    "uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write((float(gid.x) + 1.0) / 8.0, gid); }\n"
    "kernel void zpu_cpu_fill_gradient_rgba16_float(texture2d<float, access::write> output [[texture(0)]], "
    "uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write(float4((float(gid.x) + 1.0) / 8.0, (float(gid.y) + 1.0) / 8.0, 0.25, 1.0), gid); }\n";

static void fail_with_error(const char *message, NSError *error) {
    if (error != nil) {
        fprintf(stderr, "metal-pixel: %s: %s\n", message, error.localizedDescription.UTF8String);
    } else {
        fprintf(stderr, "metal-pixel: %s\n", message);
    }
}

int main(void) {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        if (device == nil) {
            fprintf(stderr, "metal-pixel: no system Metal device\n");
            return 2;
        }

        NSError *error = nil;
        id<MTLLibrary> library = [device newLibraryWithSource:[NSString stringWithUTF8String:kShaderSource]
                                                        options:nil
                                                          error:&error];
        if (library == nil) {
            fail_with_error("shader compilation failed", error);
            return 3;
        }
        id<MTLFunction> vertex_function = [library newFunctionWithName:@"zpu_test_vertex"];
        id<MTLFunction> no_raster_vertex_function = [library newFunctionWithName:@"zpu_test_no_raster_vertex"];
        id<MTLFunction> fragment_function = [library newFunctionWithName:@"zpu_test_fragment"];
        id<MTLFunction> depth_bounds_oracle_fragment = [library newFunctionWithName:@"zpu_test_depth_bounds_oracle"];
        id<MTLFunction> mrt_fragment_function = [library newFunctionWithName:@"zpu_test_mrt_fragment"];
        id<MTLFunction> sample_fragment_function = [library newFunctionWithName:@"zpu_test_sample_fragment"];
        if (vertex_function == nil || no_raster_vertex_function == nil || fragment_function == nil ||
            depth_bounds_oracle_fragment == nil || mrt_fragment_function == nil || sample_fragment_function == nil) {
            fprintf(stderr, "metal-pixel: test functions missing\n");
            return 4;
        }

        MTLRenderPipelineDescriptor *pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        pipeline_descriptor.vertexFunction = vertex_function;
        pipeline_descriptor.fragmentFunction = fragment_function;
        pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        pipeline_descriptor.supportIndirectCommandBuffers = YES;
        id<MTLRenderPipelineState> pipeline = [device newRenderPipelineStateWithDescriptor:pipeline_descriptor
                                                                                        error:&error];
        if (pipeline == nil) {
            fail_with_error("pipeline creation failed", error);
            return 5;
        }

        enum { width = 8, height = 8, byte_count = width * height * 4 };
        MTLTextureDescriptor *texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        texture_descriptor.storageMode = MTLStorageModeShared;
        texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> texture = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLCommandQueue> queue = [device newCommandQueue];
        if (texture == nil || queue == nil) {
            fprintf(stderr, "metal-pixel: texture or command queue creation failed\n");
            return 6;
        }

        /* The square is placed away from the render-target boundary so the
         * comparison exercises pixel-center coverage without relying on a
         * vendor-specific edge convention. */
        const float x0 = -0.5f;
        const float x1 =  0.5f;
        const float y0 = -0.5f;
        const float y1 =  0.5f;
        const zpu_metal_vertex vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {1.0f, 1.0f, 1.0f, 1.0f}},
        };

        id<MTLBuffer> vertex_buffer = [device newBufferWithBytes:vertices
                                                             length:sizeof(vertices)
                                                            options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *metal_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_pass.colorAttachments[0].texture = texture;
        metal_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> encoder = [command_buffer renderCommandEncoderWithDescriptor:metal_pass];
        [encoder setRenderPipelineState:pipeline];
        [encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [encoder endEncoding];
        [command_buffer commit];
        [command_buffer waitUntilCompleted];
        if (command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: Metal command buffer did not complete\n");
            return 7;
        }

        uint8_t metal_pixels[byte_count];
        [texture getBytes:metal_pixels
              bytesPerRow:(NSUInteger)width * 4
               fromRegion:MTLRegionMake2D(0, 0, width, height)
              mipmapLevel:0];

        uint8_t zpu_pixels[byte_count];
        memset(zpu_pixels, 0xa5, sizeof(zpu_pixels));
        zpu_metal_surface zpu_surface = {
            .pixels = zpu_pixels,
            .byte_length = sizeof(zpu_pixels),
            .width = width,
            .height = height,
            .stride = (size_t)width * 4,
            .format = ZPU_METAL_RGBA8_UNORM,
        };
        const zpu_metal_render_pass_descriptor zpu_pass = {
            .color = {
                .load_action = ZPU_METAL_LOAD_CLEAR,
                .store_action = ZPU_METAL_STORE_STORE,
                .clear_color = {0.0f, 0.0f, 0.0f, 1.0f},
            },
            .depth = {ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f},
        };
        const zpu_metal_draw_state zpu_state = {
            .viewport = {0.0f, 0.0f, (float)width, (float)height, 0.0f, 1.0f},
            .scissor = {0, 0, width, height},
            .cull_mode = ZPU_METAL_CULL_NONE,
            .winding = ZPU_METAL_WINDING_CLOCKWISE,
            .fill_mode = ZPU_METAL_FILL,
        };
        zpu_metal_stats stats = {0};
        if (zpu_metal_render(&zpu_surface, &zpu_pass, &zpu_state, vertices, 6,
                             ZPU_METAL_TRIANGLE, NULL, 0, &stats) != ZPU_METAL_OK) {
            fprintf(stderr, "metal-pixel: ZPU render failed\n");
            return 8;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_pixels[index] != zpu_pixels[index]) {
                fprintf(stderr, "metal-pixel: mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_pixels[index], zpu_pixels[index]);
                return 9;
            }
        }

        /* Metal's stage-in varyings are perspective-correct. Use distinct
         * clip-space W values so a screen-space linear interpolation would
         * produce a visibly different pixel result. */
        const zpu_metal_vertex perspective_vertices[] = {
            {{-0.50f, -0.50f, 0.5f, 1.00f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 0.75f, -0.75f, 0.5f, 1.50f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{ 0.00f,  0.25f, 0.5f, 0.50f}, {0.0f, 0.0f, 1.0f, 1.0f}},
        };
        id<MTLBuffer> perspective_vertex_buffer =
            [device newBufferWithBytes:perspective_vertices length:sizeof(perspective_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLTexture> perspective_texture = [device newTextureWithDescriptor:texture_descriptor];
        if (perspective_vertex_buffer == nil || perspective_texture == nil) {
            fprintf(stderr, "metal-pixel: perspective interpolation resources failed\n");
            return 10;
        }
        MTLRenderPassDescriptor *perspective_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        perspective_pass.colorAttachments[0].texture = perspective_texture;
        perspective_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        perspective_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        perspective_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> perspective_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> perspective_encoder =
            [perspective_command_buffer renderCommandEncoderWithDescriptor:perspective_pass];
        [perspective_encoder setRenderPipelineState:pipeline];
        [perspective_encoder setVertexBuffer:perspective_vertex_buffer offset:0 atIndex:0];
        [perspective_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [perspective_encoder endEncoding];
        [perspective_command_buffer commit];
        [perspective_command_buffer waitUntilCompleted];
        uint8_t metal_perspective_pixels[byte_count];
        [perspective_texture getBytes:metal_perspective_pixels
                          bytesPerRow:(NSUInteger)width * 4
                           fromRegion:MTLRegionMake2D(0, 0, width, height)
                          mipmapLevel:0];
        uint8_t zpu_perspective_pixels[byte_count];
        memset(zpu_perspective_pixels, 0xa5, sizeof(zpu_perspective_pixels));
        zpu_metal_surface perspective_surface = {
            .pixels = zpu_perspective_pixels,
            .byte_length = sizeof(zpu_perspective_pixels),
            .width = width,
            .height = height,
            .stride = (size_t)width * 4,
            .format = ZPU_METAL_RGBA8_UNORM,
        };
        if (zpu_metal_render(&perspective_surface, &zpu_pass, &zpu_state, perspective_vertices, 3,
                             ZPU_METAL_TRIANGLE, NULL, 0, &stats) != ZPU_METAL_OK) {
            fprintf(stderr, "metal-pixel: ZPU perspective render failed\n");
            return 11;
        }
        if (perspective_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: Metal perspective command did not complete\n");
            return 12;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_perspective_pixels[index] != zpu_perspective_pixels[index]) {
                fprintf(stderr, "metal-pixel: perspective mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_perspective_pixels[index], zpu_perspective_pixels[index]);
                return 13;
            }
        }

        /* Metal texture rows and MTLViewport/MTLScissorRect coordinates are
         * top-left based on both Apple GPU families. Keep this asymmetric
         * oracle separate from the centered square above: a symmetric test
         * can pass even when clip-space Y is accidentally mapped upside down
         * or a non-zero viewport origin is ignored. */
        const zpu_metal_vertex origin_vertices[] = {
            {{-0.75f,  0.90f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 0.75f,  0.90f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 0.75f,  0.10f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-0.75f,  0.90f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 0.75f,  0.10f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-0.75f,  0.10f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-0.75f, -0.10f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{ 0.75f, -0.10f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{ 0.75f, -0.90f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{-0.75f, -0.10f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{ 0.75f, -0.90f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{-0.75f, -0.90f, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
        };
        const MTLViewport origin_viewport = {1.0, 2.0, 6.0, 4.0, 0.0, 1.0};
        const MTLScissorRect origin_scissor = {1, 2, 6, 4};
        id<MTLBuffer> origin_vertex_buffer =
            [device newBufferWithBytes:origin_vertices
                                  length:sizeof(origin_vertices)
                                 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *origin_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        origin_texture_descriptor.storageMode = MTLStorageModeShared;
        origin_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> origin_texture = [device newTextureWithDescriptor:origin_texture_descriptor];
        if (origin_vertex_buffer == nil || origin_texture == nil) {
            fprintf(stderr, "metal-pixel: origin-coordinate Metal resources failed\n");
            return 40;
        }
        MTLRenderPassDescriptor *origin_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        origin_pass.colorAttachments[0].texture = origin_texture;
        origin_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        origin_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        origin_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> origin_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> origin_encoder =
            [origin_command_buffer renderCommandEncoderWithDescriptor:origin_pass];
        [origin_encoder setRenderPipelineState:pipeline];
        [origin_encoder setViewport:origin_viewport];
        [origin_encoder setScissorRect:origin_scissor];
        [origin_encoder setVertexBuffer:origin_vertex_buffer offset:0 atIndex:0];
        [origin_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [origin_encoder endEncoding];
        [origin_command_buffer commit];
        [origin_command_buffer waitUntilCompleted];
        if (origin_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: origin-coordinate Metal command did not complete\n");
            return 42;
        }
        uint8_t metal_origin_pixels[byte_count];
        [origin_texture getBytes:metal_origin_pixels
                      bytesPerRow:(NSUInteger)width * 4
                       fromRegion:MTLRegionMake2D(0, 0, width, height)
                      mipmapLevel:0];
        uint8_t zpu_origin_pixels[byte_count];
        memset(zpu_origin_pixels, 0xa5, sizeof(zpu_origin_pixels));
        const zpu_metal_draw_state origin_state = {
            .viewport = {1.0f, 2.0f, 6.0f, 4.0f, 0.0f, 1.0f},
            .scissor = {1, 2, 6, 4},
            .cull_mode = ZPU_METAL_CULL_NONE,
            .winding = ZPU_METAL_WINDING_CLOCKWISE,
            .fill_mode = ZPU_METAL_FILL,
        };
        const zpu_metal_render_pass_descriptor origin_zpu_pass = {
            .color = {
                .load_action = ZPU_METAL_LOAD_CLEAR,
                .store_action = ZPU_METAL_STORE_STORE,
                .clear_color = {0.0f, 0.0f, 0.0f, 1.0f},
            },
            .depth = {ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f},
        };
        if (zpu_metal_render(&(zpu_metal_surface){
                                 .pixels = zpu_origin_pixels,
                                 .byte_length = sizeof(zpu_origin_pixels),
                                 .width = width,
                                 .height = height,
                                 .stride = (size_t)width * 4,
                                 .format = ZPU_METAL_RGBA8_UNORM,
                             },
                             &origin_zpu_pass, &origin_state, origin_vertices, 12,
                             ZPU_METAL_TRIANGLE, NULL, 0, NULL) != ZPU_METAL_OK) {
            fprintf(stderr, "metal-pixel: origin-coordinate ZPU render failed\n");
            return 43;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_origin_pixels[index] != zpu_origin_pixels[index]) {
                fprintf(stderr, "metal-pixel: origin-coordinate mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_origin_pixels[index], zpu_origin_pixels[index]);
                return 44;
            }
        }

        /* Repeat the reference comparison for BGRA8. This catches a channel
         * order bug even when geometry and interpolation are otherwise exact. */
        MTLRenderPipelineDescriptor *bgra_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        bgra_pipeline_descriptor.vertexFunction = vertex_function;
        bgra_pipeline_descriptor.fragmentFunction = fragment_function;
        bgra_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> bgra_pipeline =
            [device newRenderPipelineStateWithDescriptor:bgra_pipeline_descriptor error:&error];
        MTLTextureDescriptor *bgra_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        bgra_texture_descriptor.storageMode = MTLStorageModeShared;
        bgra_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> bgra_texture = [device newTextureWithDescriptor:bgra_texture_descriptor];
        if (bgra_pipeline == nil || bgra_texture == nil) {
            fail_with_error("BGRA pipeline or texture creation failed", error);
            return 10;
        }
        MTLRenderPassDescriptor *bgra_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        bgra_pass.colorAttachments[0].texture = bgra_texture;
        bgra_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        bgra_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        bgra_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> bgra_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> bgra_encoder =
            [bgra_command_buffer renderCommandEncoderWithDescriptor:bgra_pass];
        [bgra_encoder setRenderPipelineState:bgra_pipeline];
        [bgra_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [bgra_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [bgra_encoder endEncoding];
        [bgra_command_buffer commit];
        [bgra_command_buffer waitUntilCompleted];
        if (bgra_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: BGRA Metal command buffer did not complete\n");
            return 11;
        }
        uint8_t metal_bgra_pixels[byte_count];
        [bgra_texture getBytes:metal_bgra_pixels
                    bytesPerRow:(NSUInteger)width * 4
                     fromRegion:MTLRegionMake2D(0, 0, width, height)
                    mipmapLevel:0];
        uint8_t zpu_bgra_pixels[byte_count];
        memset(zpu_bgra_pixels, 0xa5, sizeof(zpu_bgra_pixels));
        zpu_metal_surface zpu_bgra_surface = {
            .pixels = zpu_bgra_pixels,
            .byte_length = sizeof(zpu_bgra_pixels),
            .width = width,
            .height = height,
            .stride = (size_t)width * 4,
            .format = ZPU_METAL_BGRA8_UNORM,
        };
        if (zpu_metal_render(&zpu_bgra_surface, &zpu_pass, &zpu_state, vertices, 6,
                             ZPU_METAL_TRIANGLE, NULL, 0, NULL) != ZPU_METAL_OK) {
            fprintf(stderr, "metal-pixel: ZPU BGRA render failed\n");
            return 12;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_bgra_pixels[index] != zpu_bgra_pixels[index]) {
                fprintf(stderr, "metal-pixel: BGRA mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_bgra_pixels[index], zpu_bgra_pixels[index]);
                return 13;
            }
        }

        /* Exercise the command-buffer/resource path as well as the one-shot
         * C entry point.  Both paths must produce the same bytes as Apple's
         * reference rasterizer, not merely the same non-zero coverage. */
        zpu_metal_device *zpu_device = zpu_metal_device_create();
        zpu_metal_command_queue *zpu_queue = zpu_metal_device_new_command_queue(zpu_device);
        const zpu_metal_texture_descriptor zpu_texture_descriptor = {
            .width = width,
            .height = height,
            .format = ZPU_METAL_RGBA8_UNORM,
        };
        zpu_metal_texture *zpu_texture =
            zpu_metal_device_new_texture(zpu_device, &zpu_texture_descriptor);
        zpu_metal_buffer *zpu_vertex_buffer =
            zpu_metal_device_new_buffer(zpu_device, sizeof(vertices), vertices);
        zpu_metal_command_buffer *zpu_command_buffer =
            zpu_metal_command_queue_command_buffer(zpu_queue);
        if (zpu_device == NULL || zpu_queue == NULL || zpu_texture == NULL ||
            zpu_vertex_buffer == NULL || zpu_command_buffer == NULL) {
            fprintf(stderr, "metal-pixel: ZPU object allocation failed\n");
            return 14;
        }
        zpu_metal_render_encoder *zpu_encoder =
            zpu_metal_command_buffer_render_encoder(zpu_command_buffer, zpu_texture, &zpu_pass);
        if (zpu_encoder == NULL ||
            zpu_metal_render_encoder_set_viewport(zpu_encoder, zpu_state.viewport) != 0 ||
            zpu_metal_render_encoder_set_scissor_rect(zpu_encoder, zpu_state.scissor) != 0 ||
            zpu_metal_render_encoder_set_vertex_buffer(zpu_encoder, zpu_vertex_buffer, 0, 0) != 0 ||
            zpu_metal_render_encoder_draw_primitives(zpu_encoder, ZPU_METAL_TRIANGLE, 0, 6, 1) != 0 ||
            zpu_metal_render_encoder_end_encoding(zpu_encoder) != 0 ||
            zpu_metal_command_buffer_commit(zpu_command_buffer) != 0 ||
            zpu_metal_command_buffer_get_status(zpu_command_buffer) != ZPU_METAL_COMMAND_BUFFER_COMPLETED) {
            fprintf(stderr, "metal-pixel: ZPU object command failed\n");
            return 15;
        }
        uint8_t zpu_object_pixels[byte_count];
        memset(zpu_object_pixels, 0xa5, sizeof(zpu_object_pixels));
        if (zpu_metal_texture_get_bytes(zpu_texture, zpu_object_pixels,
                                        sizeof(zpu_object_pixels), width * 4,
                                        (zpu_metal_region){{0, 0, 0}, {width, height, 1}}) != 0) {
            fprintf(stderr, "metal-pixel: ZPU object texture read failed\n");
            return 16;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_pixels[index] != zpu_object_pixels[index]) {
                fprintf(stderr, "metal-pixel: object mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_pixels[index], zpu_object_pixels[index]);
                return 17;
            }
        }

        /* Finally exercise the explicit Objective-C adapter. This is the
         * supported way to use ZPU through Metal-shaped objects; it must keep
         * the same byte contract as both C entry points and Apple's device. */
        id<MTLDevice> adapter_device = ZPUMetalCreateSystemDefaultDevice();
        MTLTextureDescriptor *adapter_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        id<MTLTexture> adapter_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLBuffer> adapter_vertex_buffer =
            [adapter_device newBufferWithBytes:vertices length:sizeof(vertices)
                                       options:MTLResourceStorageModeShared];
        const NSUInteger adapter_initial_allocated_size = adapter_texture.allocatedSize + adapter_vertex_buffer.length;
        if (adapter_device.currentAllocatedSize != adapter_initial_allocated_size) {
            fprintf(stderr, "metal-pixel: direct CPU allocation accounting failed\n");
            return 19;
        }

        /* Non-renderable resource formats still have a byte-exact contract.
         * The adapter must preserve the native Metal texel width for both
         * scalar R32Float and packed RGBA16Float transfers. */
        enum { raw_format_width = 3, raw_format_height = 2,
               raw_r32_bytes = raw_format_width * raw_format_height * 4,
               raw_rgba16_bytes = raw_format_width * raw_format_height * 8 };
        const uint32_t raw_r32_source[raw_format_width * raw_format_height] = {
            0x3f800000, 0x40000000, 0x40400000, 0xc0800000, 0x00000000, 0x7f800000,
        };
        const uint8_t raw_rgba16_source[raw_rgba16_bytes] = {
            0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
            0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
            0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27,
            0x80, 0x81, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
            0x90, 0x91, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97,
            0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
        };
        MTLTextureDescriptor *native_r32_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                width:raw_format_width
                                                               height:raw_format_height
                                                            mipmapped:NO];
        native_r32_descriptor.storageMode = MTLStorageModeShared;
        native_r32_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        MTLTextureDescriptor *native_rgba16_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                width:raw_format_width
                                                               height:raw_format_height
                                                            mipmapped:NO];
        native_rgba16_descriptor.storageMode = MTLStorageModeShared;
        native_rgba16_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_r32_texture = [device newTextureWithDescriptor:native_r32_descriptor];
        id<MTLTexture> native_rgba16_texture = [device newTextureWithDescriptor:native_rgba16_descriptor];
        MTLTextureDescriptor *adapter_r32_descriptor = [native_r32_descriptor copy];
        MTLTextureDescriptor *adapter_rgba16_descriptor = [native_rgba16_descriptor copy];
        id<MTLTexture> adapter_r32_texture = [adapter_device newTextureWithDescriptor:adapter_r32_descriptor];
        id<MTLTexture> adapter_rgba16_texture = [adapter_device newTextureWithDescriptor:adapter_rgba16_descriptor];
        if (native_r32_texture == nil || native_rgba16_texture == nil ||
            adapter_r32_texture == nil || adapter_rgba16_texture == nil ||
            adapter_r32_texture.allocatedSize != raw_r32_bytes ||
            adapter_rgba16_texture.allocatedSize != raw_rgba16_bytes) {
            fprintf(stderr, "metal-pixel: scalar/half-float texture allocation failed\n");
            return 75;
        }
        [native_r32_texture replaceRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height)
                              mipmapLevel:0 withBytes:raw_r32_source bytesPerRow:raw_format_width * 4];
        [native_rgba16_texture replaceRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height)
                                mipmapLevel:0 withBytes:raw_rgba16_source bytesPerRow:raw_format_width * 8];
        [adapter_r32_texture replaceRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height)
                              mipmapLevel:0 withBytes:raw_r32_source bytesPerRow:raw_format_width * 4];
        [adapter_rgba16_texture replaceRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height)
                                mipmapLevel:0 withBytes:raw_rgba16_source bytesPerRow:raw_format_width * 8];
        uint8_t native_r32_bytes[raw_r32_bytes];
        uint8_t adapter_r32_bytes[raw_r32_bytes];
        uint8_t native_rgba16_bytes[raw_rgba16_bytes];
        uint8_t adapter_rgba16_bytes[raw_rgba16_bytes];
        [native_r32_texture getBytes:native_r32_bytes bytesPerRow:raw_format_width * 4
                          fromRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height) mipmapLevel:0];
        [adapter_r32_texture getBytes:adapter_r32_bytes bytesPerRow:raw_format_width * 4
                            fromRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height) mipmapLevel:0];
        [native_rgba16_texture getBytes:native_rgba16_bytes bytesPerRow:raw_format_width * 8
                              fromRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height) mipmapLevel:0];
        [adapter_rgba16_texture getBytes:adapter_rgba16_bytes bytesPerRow:raw_format_width * 8
                                fromRegion:MTLRegionMake2D(0, 0, raw_format_width, raw_format_height) mipmapLevel:0];
        if (memcmp(native_r32_bytes, adapter_r32_bytes, raw_r32_bytes) != 0 ||
            memcmp(native_rgba16_bytes, adapter_rgba16_bytes, raw_rgba16_bytes) != 0) {
            fprintf(stderr, "metal-pixel: non-renderable texture format byte mismatch\n");
            return 76;
        }
        id<MTLFunction> adapter_vertex_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_vertex");
        id<MTLFunction> adapter_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_fragment");
        id<MTLFunction> adapter_uniform_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_uniform_color_fragment");
        id<MTLFunction> adapter_sample_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_sample_fragment");
        id<MTLCommandQueue> adapter_queue = [adapter_device newCommandQueue];
        NSError *adapter_pipeline_error = nil;

        /* Float color attachments use the same CPU raster path as normalized
         * targets, but their stored representation must remain native Metal's
         * R32Float or RGBA16Float bytes rather than an RGBA8 conversion. */
        const zpu_metal_vertex float_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
        };
        id<MTLBuffer> native_float_vertex_buffer =
            [device newBufferWithBytes:float_vertices length:sizeof(float_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_float_vertex_buffer =
            [adapter_device newBufferWithBytes:float_vertices length:sizeof(float_vertices)
                                        options:MTLResourceStorageModeShared];
        const MTLPixelFormat float_formats[] = {
            MTLPixelFormatR32Float, MTLPixelFormatRGBA16Float,
        };
        for (NSUInteger format_index = 0; format_index < sizeof(float_formats) / sizeof(float_formats[0]); ++format_index) {
            const MTLPixelFormat format = float_formats[format_index];
            const NSUInteger bytes_per_pixel = format == MTLPixelFormatR32Float ? 4 : 8;
            const NSUInteger float_byte_count = (NSUInteger)width * height * bytes_per_pixel;
            MTLRenderPipelineDescriptor *native_float_pipeline_descriptor = [pipeline_descriptor copy];
            native_float_pipeline_descriptor.colorAttachments[0].pixelFormat = format;
            id<MTLRenderPipelineState> native_float_pipeline =
                [device newRenderPipelineStateWithDescriptor:native_float_pipeline_descriptor error:&error];
            MTLTextureDescriptor *native_float_texture_descriptor = [texture_descriptor copy];
            native_float_texture_descriptor.pixelFormat = format;
            id<MTLTexture> native_float_texture = [device newTextureWithDescriptor:native_float_texture_descriptor];
            MTLRenderPassDescriptor *native_float_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            native_float_pass.colorAttachments[0].texture = native_float_texture;
            native_float_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            native_float_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            native_float_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            id<MTLCommandBuffer> native_float_command_buffer = [queue commandBuffer];
            id<MTLRenderCommandEncoder> native_float_encoder =
                [native_float_command_buffer renderCommandEncoderWithDescriptor:native_float_pass];
            [native_float_encoder setRenderPipelineState:native_float_pipeline];
            [native_float_encoder setVertexBuffer:native_float_vertex_buffer offset:0 atIndex:0];
            [native_float_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [native_float_encoder endEncoding];
            [native_float_command_buffer commit];
            [native_float_command_buffer waitUntilCompleted];

            MTLRenderPipelineDescriptor *adapter_float_pipeline_descriptor = [native_float_pipeline_descriptor copy];
            adapter_float_pipeline_descriptor.vertexFunction = adapter_vertex_function;
            adapter_float_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
            id<MTLRenderPipelineState> adapter_float_pipeline =
                [adapter_device newRenderPipelineStateWithDescriptor:adapter_float_pipeline_descriptor error:&adapter_pipeline_error];
            MTLTextureDescriptor *adapter_float_texture_descriptor = [native_float_texture_descriptor copy];
            id<MTLTexture> adapter_float_texture = [adapter_device newTextureWithDescriptor:adapter_float_texture_descriptor];
            MTLRenderPassDescriptor *adapter_float_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            adapter_float_pass.colorAttachments[0].texture = adapter_float_texture;
            adapter_float_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            adapter_float_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            adapter_float_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            id<MTLCommandBuffer> adapter_float_command_buffer = [adapter_queue commandBuffer];
            id<MTLRenderCommandEncoder> adapter_float_encoder =
                [adapter_float_command_buffer renderCommandEncoderWithDescriptor:adapter_float_pass];
            [adapter_float_encoder setRenderPipelineState:adapter_float_pipeline];
            [adapter_float_encoder setVertexBuffer:adapter_float_vertex_buffer offset:0 atIndex:0];
            [adapter_float_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
            [adapter_float_encoder endEncoding];
            [adapter_float_command_buffer commit];
            [adapter_float_command_buffer waitUntilCompleted];
            uint8_t native_float_bytes[float_byte_count];
            uint8_t adapter_float_bytes[float_byte_count];
            [native_float_texture getBytes:native_float_bytes bytesPerRow:(NSUInteger)width * bytes_per_pixel
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            [adapter_float_texture getBytes:adapter_float_bytes bytesPerRow:(NSUInteger)width * bytes_per_pixel
                                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            if (native_float_pipeline == nil || native_float_texture == nil ||
                native_float_command_buffer.status != MTLCommandBufferStatusCompleted ||
                adapter_float_pipeline == nil || adapter_float_texture == nil ||
                adapter_float_command_buffer.status != MTLCommandBufferStatusCompleted) {
                fail_with_error("float render target allocation or execution failed", adapter_pipeline_error);
                return 90 + (int)format_index;
            }
            for (NSUInteger byte = 0; byte < float_byte_count; ++byte) {
                if (native_float_bytes[byte] != adapter_float_bytes[byte]) {
                    fprintf(stderr, "metal-pixel: float render mismatch format=%lu byte=%lu: Metal=%u ZPU=%u\n",
                            (unsigned long)format, (unsigned long)byte,
                            native_float_bytes[byte], adapter_float_bytes[byte]);
                    return 92 + (int)format_index;
                }
            }
        }

        const uint8_t sample_source_bytes[] = {
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        };
        MTLTextureDescriptor *sample_source_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:2 height:2 mipmapped:NO];
        sample_source_descriptor.storageMode = MTLStorageModeShared;
        sample_source_descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> native_sample_source = [device newTextureWithDescriptor:sample_source_descriptor];
        id<MTLTexture> adapter_sample_source = [adapter_device newTextureWithDescriptor:sample_source_descriptor];
        [native_sample_source replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0
                                  withBytes:sample_source_bytes bytesPerRow:2 * 4];
        [adapter_sample_source replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0
                                   withBytes:sample_source_bytes bytesPerRow:2 * 4];
        const zpu_metal_vertex sample_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {0.25f, 0.25f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.75f, 0.25f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.75f, 0.75f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.25f, 0.25f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.75f, 0.75f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.25f, 0.75f, 0.0f, 1.0f}},
        };
        id<MTLBuffer> native_sample_vertex_buffer =
            [device newBufferWithBytes:sample_vertices length:sizeof(sample_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_sample_vertex_buffer =
            [adapter_device newBufferWithBytes:sample_vertices length:sizeof(sample_vertices)
                                        options:MTLResourceStorageModeShared];
        MTLRenderPipelineDescriptor *native_sample_pipeline_descriptor = [pipeline_descriptor copy];
        native_sample_pipeline_descriptor.fragmentFunction = sample_fragment_function;
        native_sample_pipeline_descriptor.supportIndirectCommandBuffers = NO;
        id<MTLRenderPipelineState> native_sample_pipeline =
            [device newRenderPipelineStateWithDescriptor:native_sample_pipeline_descriptor error:&error];
        MTLRenderPipelineDescriptor *adapter_sample_pipeline_descriptor = [native_sample_pipeline_descriptor copy];
        adapter_sample_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_sample_pipeline_descriptor.fragmentFunction = adapter_sample_fragment_function;
        id<MTLRenderPipelineState> adapter_sample_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_sample_pipeline_descriptor error:&adapter_pipeline_error];
        MTLTextureDescriptor *sample_output_descriptor = [texture_descriptor copy];
        id<MTLTexture> native_sample_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_sample_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        MTLSamplerDescriptor *sample_sampler_descriptor = [MTLSamplerDescriptor new];
        sample_sampler_descriptor.minFilter = MTLSamplerMinMagFilterNearest;
        sample_sampler_descriptor.magFilter = MTLSamplerMinMagFilterNearest;
        sample_sampler_descriptor.mipFilter = MTLSamplerMipFilterNotMipmapped;
        id<MTLSamplerState> native_sample_sampler = [device newSamplerStateWithDescriptor:sample_sampler_descriptor];
        id<MTLSamplerState> adapter_sample_sampler = [adapter_device newSamplerStateWithDescriptor:sample_sampler_descriptor];
        if (native_sample_pipeline == nil || native_sample_source == nil || native_sample_vertex_buffer == nil ||
            native_sample_output == nil || native_sample_sampler == nil || adapter_sample_fragment_function == nil ||
            adapter_sample_pipeline == nil || adapter_sample_source == nil || adapter_sample_vertex_buffer == nil ||
            adapter_sample_output == nil || adapter_sample_sampler == nil ||
            native_sample_pipeline.supportIndirectCommandBuffers || adapter_sample_pipeline.supportIndirectCommandBuffers) {
            fail_with_error("sample pipeline or resource allocation failed", adapter_pipeline_error);
            return 94;
        }
        MTLRenderPassDescriptor *native_sample_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_sample_pass.colorAttachments[0].texture = native_sample_output;
        native_sample_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_sample_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_sample_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_sample_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_sample_encoder =
            [native_sample_command_buffer renderCommandEncoderWithDescriptor:native_sample_pass];
        [native_sample_encoder setRenderPipelineState:native_sample_pipeline];
        [native_sample_encoder setVertexBuffer:native_sample_vertex_buffer offset:0 atIndex:0];
        [native_sample_encoder setFragmentTexture:native_sample_source atIndex:0];
        [native_sample_encoder setFragmentSamplerState:native_sample_sampler atIndex:0];
        [native_sample_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_sample_encoder endEncoding];
        [native_sample_command_buffer commit];
        [native_sample_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_sample_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_sample_pass.colorAttachments[0].texture = adapter_sample_output;
        adapter_sample_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_sample_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_sample_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_sample_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_sample_encoder =
            [adapter_sample_command_buffer renderCommandEncoderWithDescriptor:adapter_sample_pass];
        [adapter_sample_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_sample_encoder setVertexBuffer:adapter_sample_vertex_buffer offset:0 atIndex:0];
        [adapter_sample_encoder setFragmentTexture:adapter_sample_source atIndex:0];
        [adapter_sample_encoder setFragmentSamplerState:adapter_sample_sampler atIndex:0];
        [adapter_sample_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_sample_encoder endEncoding];
        [adapter_sample_command_buffer commit];
        [adapter_sample_command_buffer waitUntilCompleted];
        uint8_t native_sample_bytes[byte_count];
        uint8_t adapter_sample_bytes[byte_count];
        [native_sample_output getBytes:native_sample_bytes bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_sample_output getBytes:adapter_sample_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_sample_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_sample_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("sample pipeline allocation or execution failed", adapter_pipeline_error);
            return 94;
        }
        if (memcmp(native_sample_bytes, adapter_sample_bytes, byte_count) != 0) {
            for (size_t byte = 0; byte < byte_count; ++byte) {
                if (native_sample_bytes[byte] != adapter_sample_bytes[byte]) {
                    fprintf(stderr, "metal-pixel: sample mismatch at byte %zu: Metal=%u ZPU=%u\n",
                            byte, native_sample_bytes[byte], adapter_sample_bytes[byte]);
                    break;
                }
            }
            return 95;
        }

        const float uniform_color[4] = {0.2f, 0.6f, 0.88f, 0.4f};
        MTLRenderPipelineDescriptor *native_uniform_pipeline_descriptor = [pipeline_descriptor copy];
        native_uniform_pipeline_descriptor.fragmentFunction = [library newFunctionWithName:@"zpu_test_uniform_fragment"];
        id<MTLRenderPipelineState> native_uniform_pipeline =
            [device newRenderPipelineStateWithDescriptor:native_uniform_pipeline_descriptor error:&error];
        MTLRenderPipelineDescriptor *adapter_uniform_pipeline_descriptor = [native_uniform_pipeline_descriptor copy];
        adapter_uniform_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_uniform_pipeline_descriptor.fragmentFunction = adapter_uniform_fragment_function;
        id<MTLRenderPipelineState> adapter_uniform_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_uniform_pipeline_descriptor error:&adapter_pipeline_error];
        id<MTLTexture> native_uniform_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_uniform_output = [adapter_device newTextureWithDescriptor:texture_descriptor];
        if (native_uniform_pipeline == nil || adapter_uniform_pipeline == nil ||
            native_uniform_output == nil || adapter_uniform_output == nil) {
            fail_with_error("uniform fragment pipeline allocation failed", adapter_pipeline_error);
            return 96;
        }
        MTLRenderPassDescriptor *native_uniform_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_uniform_pass.colorAttachments[0].texture = native_uniform_output;
        native_uniform_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_uniform_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_uniform_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_uniform_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_uniform_encoder =
            [native_uniform_command_buffer renderCommandEncoderWithDescriptor:native_uniform_pass];
        [native_uniform_encoder setRenderPipelineState:native_uniform_pipeline];
        [native_uniform_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_uniform_encoder setFragmentBytes:uniform_color length:sizeof(uniform_color) atIndex:0];
        [native_uniform_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_uniform_encoder endEncoding];
        [native_uniform_command_buffer commit];
        [native_uniform_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_uniform_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_uniform_pass.colorAttachments[0].texture = adapter_uniform_output;
        adapter_uniform_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_uniform_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_uniform_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_uniform_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_uniform_encoder =
            [adapter_uniform_command_buffer renderCommandEncoderWithDescriptor:adapter_uniform_pass];
        [adapter_uniform_encoder setRenderPipelineState:adapter_uniform_pipeline];
        [adapter_uniform_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_uniform_encoder setFragmentBytes:uniform_color length:sizeof(uniform_color) atIndex:0];
        [adapter_uniform_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_uniform_encoder endEncoding];
        [adapter_uniform_command_buffer commit];
        [adapter_uniform_command_buffer waitUntilCompleted];
        uint8_t native_uniform_bytes[byte_count];
        uint8_t adapter_uniform_bytes[byte_count];
        [native_uniform_output getBytes:native_uniform_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_uniform_output getBytes:adapter_uniform_bytes bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_uniform_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_uniform_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_uniform_bytes, adapter_uniform_bytes, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_uniform_bytes[mismatch] == adapter_uniform_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: uniform fragment mismatch or command failure (native=%lu adapter=%lu encoder=%d mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_uniform_command_buffer.status,
                    (unsigned long)adapter_uniform_command_buffer.status,
                    adapter_uniform_encoder != nil,
                    mismatch,
                    mismatch < byte_count ? native_uniform_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_uniform_bytes[mismatch] : 0);
            return 97;
        }

        uint8_t initial_uniform_storage[8 + sizeof(uniform_color)] = {0};
        const float initial_uniform_color[4] = {0.9f, 0.1f, 0.2f, 1.0f};
        memcpy(initial_uniform_storage + 8, initial_uniform_color, sizeof(initial_uniform_color));
        id<MTLBuffer> native_uniform_buffer =
            [device newBufferWithBytes:initial_uniform_storage length:sizeof(initial_uniform_storage)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_uniform_buffer =
            [adapter_device newBufferWithBytes:initial_uniform_storage length:sizeof(initial_uniform_storage)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_uniform_buffer_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_uniform_buffer_output = [adapter_device newTextureWithDescriptor:texture_descriptor];
        if (native_uniform_buffer == nil || adapter_uniform_buffer == nil ||
            native_uniform_buffer_output == nil || adapter_uniform_buffer_output == nil) {
            fprintf(stderr, "metal-pixel: uniform fragment buffer resource allocation failed\n");
            return 98;
        }
        MTLRenderPassDescriptor *native_uniform_buffer_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_uniform_buffer_pass.colorAttachments[0].texture = native_uniform_buffer_output;
        native_uniform_buffer_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_uniform_buffer_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_uniform_buffer_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_uniform_buffer_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_uniform_buffer_encoder =
            [native_uniform_buffer_command_buffer renderCommandEncoderWithDescriptor:native_uniform_buffer_pass];
        [native_uniform_buffer_encoder setRenderPipelineState:native_uniform_pipeline];
        [native_uniform_buffer_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_uniform_buffer_encoder setFragmentBuffer:native_uniform_buffer offset:0 atIndex:0];
        [native_uniform_buffer_encoder setFragmentBufferOffset:8 atIndex:0];
        [native_uniform_buffer_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_uniform_buffer_encoder endEncoding];
        memcpy((uint8_t *)native_uniform_buffer.contents + 8, uniform_color, sizeof(uniform_color));
        [native_uniform_buffer_command_buffer commit];
        [native_uniform_buffer_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_uniform_buffer_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_uniform_buffer_pass.colorAttachments[0].texture = adapter_uniform_buffer_output;
        adapter_uniform_buffer_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_uniform_buffer_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_uniform_buffer_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_uniform_buffer_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_uniform_buffer_encoder =
            [adapter_uniform_buffer_command_buffer renderCommandEncoderWithDescriptor:adapter_uniform_buffer_pass];
        [adapter_uniform_buffer_encoder setRenderPipelineState:adapter_uniform_pipeline];
        [adapter_uniform_buffer_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_uniform_buffer_encoder setFragmentBuffer:adapter_uniform_buffer offset:0 atIndex:0];
        [adapter_uniform_buffer_encoder setFragmentBufferOffset:8 atIndex:0];
        [adapter_uniform_buffer_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_uniform_buffer_encoder endEncoding];
        memcpy((uint8_t *)adapter_uniform_buffer.contents + 8, uniform_color, sizeof(uniform_color));
        [adapter_uniform_buffer_command_buffer commit];
        [adapter_uniform_buffer_command_buffer waitUntilCompleted];
        uint8_t native_uniform_buffer_bytes[byte_count];
        uint8_t adapter_uniform_buffer_bytes[byte_count];
        [native_uniform_buffer_output getBytes:native_uniform_buffer_bytes bytesPerRow:(NSUInteger)width * 4
                                      fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_uniform_buffer_output getBytes:adapter_uniform_buffer_bytes bytesPerRow:(NSUInteger)width * 4
                                        fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_uniform_buffer_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_uniform_buffer_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_uniform_buffer_bytes, adapter_uniform_buffer_bytes, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_uniform_buffer_bytes[mismatch] == adapter_uniform_buffer_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: uniform fragment buffer mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_uniform_buffer_command_buffer.status,
                    (unsigned long)adapter_uniform_buffer_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_uniform_buffer_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_uniform_buffer_bytes[mismatch] : 0);
            return 99;
        }

        const zpu_metal_vertex linear_sample_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 1.0f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 1.0f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        };
        id<MTLBuffer> native_linear_vertex_buffer =
            [device newBufferWithBytes:linear_sample_vertices length:sizeof(linear_sample_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_linear_vertex_buffer =
            [adapter_device newBufferWithBytes:linear_sample_vertices length:sizeof(linear_sample_vertices)
                                        options:MTLResourceStorageModeShared];
        MTLSamplerDescriptor *linear_sample_sampler_descriptor = [sample_sampler_descriptor copy];
        linear_sample_sampler_descriptor.minFilter = MTLSamplerMinMagFilterLinear;
        linear_sample_sampler_descriptor.magFilter = MTLSamplerMinMagFilterLinear;
        id<MTLSamplerState> native_linear_sample_sampler =
            [device newSamplerStateWithDescriptor:linear_sample_sampler_descriptor];
        id<MTLSamplerState> adapter_linear_sample_sampler =
            [adapter_device newSamplerStateWithDescriptor:linear_sample_sampler_descriptor];
        MTLTextureDescriptor *native_linear_output_descriptor = [sample_output_descriptor copy];
        MTLTextureDescriptor *adapter_linear_output_descriptor = [sample_output_descriptor copy];
        id<MTLTexture> native_linear_output = [device newTextureWithDescriptor:native_linear_output_descriptor];
        id<MTLTexture> adapter_linear_output = [adapter_device newTextureWithDescriptor:adapter_linear_output_descriptor];
        if (native_linear_vertex_buffer == nil || adapter_linear_vertex_buffer == nil ||
            native_linear_sample_sampler == nil || adapter_linear_sample_sampler == nil ||
            native_linear_output == nil || adapter_linear_output == nil) {
            fprintf(stderr, "metal-pixel: linear sampler resource allocation failed\n");
            return 96;
        }
        MTLRenderPassDescriptor *native_linear_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_linear_pass.colorAttachments[0].texture = native_linear_output;
        native_linear_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_linear_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_linear_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_linear_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_linear_encoder =
            [native_linear_command_buffer renderCommandEncoderWithDescriptor:native_linear_pass];
        [native_linear_encoder setRenderPipelineState:native_sample_pipeline];
        [native_linear_encoder setVertexBuffer:native_linear_vertex_buffer offset:0 atIndex:0];
        [native_linear_encoder setFragmentTexture:native_sample_source atIndex:0];
        [native_linear_encoder setFragmentSamplerState:native_linear_sample_sampler atIndex:0];
        [native_linear_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_linear_encoder endEncoding];
        [native_linear_command_buffer commit];
        [native_linear_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_linear_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_linear_pass.colorAttachments[0].texture = adapter_linear_output;
        adapter_linear_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_linear_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_linear_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_linear_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_linear_encoder =
            [adapter_linear_command_buffer renderCommandEncoderWithDescriptor:adapter_linear_pass];
        [adapter_linear_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_linear_encoder setVertexBuffer:adapter_linear_vertex_buffer offset:0 atIndex:0];
        [adapter_linear_encoder setFragmentTexture:adapter_sample_source atIndex:0];
        [adapter_linear_encoder setFragmentSamplerState:adapter_linear_sample_sampler atIndex:0];
        [adapter_linear_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_linear_encoder endEncoding];
        [adapter_linear_command_buffer commit];
        [adapter_linear_command_buffer waitUntilCompleted];
        uint8_t native_linear_bytes[byte_count];
        uint8_t adapter_linear_bytes[byte_count];
        [native_linear_output getBytes:native_linear_bytes bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_linear_output getBytes:adapter_linear_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_linear_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_linear_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("linear sampler execution failed", adapter_pipeline_error);
            return 97;
        }
        if (memcmp(native_linear_bytes, adapter_linear_bytes, byte_count) != 0) {
            for (size_t byte = 0; byte < byte_count; ++byte) {
                if (native_linear_bytes[byte] != adapter_linear_bytes[byte]) {
                    fprintf(stderr, "metal-pixel: linear sample mismatch at byte %zu: Metal=%u ZPU=%u\n",
                            byte, native_linear_bytes[byte], adapter_linear_bytes[byte]);
                    break;
                }
            }
            return 98;
        }

        const MTLTextureSwizzleChannels sample_swizzle = MTLTextureSwizzleChannelsMake(
            MTLTextureSwizzleBlue, MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleOne);
        id<MTLTexture> native_sample_swizzled_source =
            [native_sample_source newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                     textureType:MTLTextureType2D
                                                          levels:NSMakeRange(0, 1)
                                                          slices:NSMakeRange(0, 1)
                                                         swizzle:sample_swizzle];
        id<MTLTexture> adapter_sample_swizzled_source =
            [adapter_sample_source newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                      textureType:MTLTextureType2D
                                                           levels:NSMakeRange(0, 1)
                                                           slices:NSMakeRange(0, 1)
                                                          swizzle:sample_swizzle];
        id<MTLTexture> native_swizzle_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_swizzle_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        if (native_sample_swizzled_source == nil || adapter_sample_swizzled_source == nil ||
            native_swizzle_output == nil || adapter_swizzle_output == nil ||
            native_sample_swizzled_source.swizzle.red != sample_swizzle.red ||
            adapter_sample_swizzled_source.swizzle.blue != sample_swizzle.blue) {
            fprintf(stderr, "metal-pixel: texture-view swizzle allocation or metadata failed\n");
            return 99;
        }
        MTLRenderPassDescriptor *native_swizzle_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_swizzle_pass.colorAttachments[0].texture = native_swizzle_output;
        native_swizzle_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_swizzle_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_swizzle_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_swizzle_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_swizzle_encoder =
            [native_swizzle_command_buffer renderCommandEncoderWithDescriptor:native_swizzle_pass];
        [native_swizzle_encoder setRenderPipelineState:native_sample_pipeline];
        [native_swizzle_encoder setVertexBuffer:native_sample_vertex_buffer offset:0 atIndex:0];
        [native_swizzle_encoder setFragmentTexture:native_sample_swizzled_source atIndex:0];
        [native_swizzle_encoder setFragmentSamplerState:native_sample_sampler atIndex:0];
        [native_swizzle_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_swizzle_encoder endEncoding];
        [native_swizzle_command_buffer commit];
        [native_swizzle_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_swizzle_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_swizzle_pass.colorAttachments[0].texture = adapter_swizzle_output;
        adapter_swizzle_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_swizzle_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_swizzle_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_swizzle_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_swizzle_encoder =
            [adapter_swizzle_command_buffer renderCommandEncoderWithDescriptor:adapter_swizzle_pass];
        [adapter_swizzle_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_swizzle_encoder setVertexBuffer:adapter_sample_vertex_buffer offset:0 atIndex:0];
        [adapter_swizzle_encoder setFragmentTexture:adapter_sample_swizzled_source atIndex:0];
        [adapter_swizzle_encoder setFragmentSamplerState:adapter_sample_sampler atIndex:0];
        [adapter_swizzle_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_swizzle_encoder endEncoding];
        [adapter_swizzle_command_buffer commit];
        [adapter_swizzle_command_buffer waitUntilCompleted];
        uint8_t native_swizzle_bytes[byte_count];
        uint8_t adapter_swizzle_bytes[byte_count];
        [native_swizzle_output getBytes:native_swizzle_bytes bytesPerRow:(NSUInteger)width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_swizzle_output getBytes:adapter_swizzle_bytes bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_swizzle_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_swizzle_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("texture-view swizzle execution failed", adapter_pipeline_error);
            return 100;
        }
        if (memcmp(native_swizzle_bytes, adapter_swizzle_bytes, byte_count) != 0) {
            for (size_t byte = 0; byte < byte_count; ++byte) {
                if (native_swizzle_bytes[byte] != adapter_swizzle_bytes[byte]) {
                    fprintf(stderr, "metal-pixel: texture-view swizzle mismatch at byte %zu: Metal=%u ZPU=%u\n",
                            byte, native_swizzle_bytes[byte], adapter_swizzle_bytes[byte]);
                    break;
                }
            }
            return 101;
        }

        const zpu_metal_vertex address_sample_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, { 1.25f, -0.25f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, { 1.25f,  1.25f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, { 1.25f,  1.25f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {-0.25f,  1.25f, 0.0f, 1.0f}},
        };
        id<MTLBuffer> native_address_vertex_buffer =
            [device newBufferWithBytes:address_sample_vertices length:sizeof(address_sample_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_address_vertex_buffer =
            [adapter_device newBufferWithBytes:address_sample_vertices length:sizeof(address_sample_vertices)
                                        options:MTLResourceStorageModeShared];
        MTLSamplerDescriptor *address_sampler_descriptor = [sample_sampler_descriptor copy];
        address_sampler_descriptor.sAddressMode = MTLSamplerAddressModeRepeat;
        address_sampler_descriptor.tAddressMode = MTLSamplerAddressModeMirrorRepeat;
        id<MTLSamplerState> native_address_sampler =
            [device newSamplerStateWithDescriptor:address_sampler_descriptor];
        id<MTLSamplerState> adapter_address_sampler =
            [adapter_device newSamplerStateWithDescriptor:address_sampler_descriptor];
        id<MTLTexture> native_address_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_address_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        if (native_address_vertex_buffer == nil || adapter_address_vertex_buffer == nil ||
            native_address_sampler == nil || adapter_address_sampler == nil ||
            native_address_output == nil || adapter_address_output == nil) {
            fprintf(stderr, "metal-pixel: address-mode sampler resource allocation failed\n");
            return 102;
        }
        MTLRenderPassDescriptor *native_address_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_address_pass.colorAttachments[0].texture = native_address_output;
        native_address_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_address_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_address_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_address_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_address_encoder =
            [native_address_command_buffer renderCommandEncoderWithDescriptor:native_address_pass];
        [native_address_encoder setRenderPipelineState:native_sample_pipeline];
        [native_address_encoder setVertexBuffer:native_address_vertex_buffer offset:0 atIndex:0];
        [native_address_encoder setFragmentTexture:native_sample_source atIndex:0];
        [native_address_encoder setFragmentSamplerState:native_address_sampler atIndex:0];
        [native_address_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_address_encoder endEncoding];
        [native_address_command_buffer commit];
        [native_address_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_address_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_address_pass.colorAttachments[0].texture = adapter_address_output;
        adapter_address_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_address_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_address_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_address_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_address_encoder =
            [adapter_address_command_buffer renderCommandEncoderWithDescriptor:adapter_address_pass];
        [adapter_address_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_address_encoder setVertexBuffer:adapter_address_vertex_buffer offset:0 atIndex:0];
        [adapter_address_encoder setFragmentTexture:adapter_sample_source atIndex:0];
        [adapter_address_encoder setFragmentSamplerState:adapter_address_sampler atIndex:0];
        [adapter_address_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_address_encoder endEncoding];
        [adapter_address_command_buffer commit];
        [adapter_address_command_buffer waitUntilCompleted];
        uint8_t native_address_bytes[byte_count];
        uint8_t adapter_address_bytes[byte_count];
        [native_address_output getBytes:native_address_bytes bytesPerRow:(NSUInteger)width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_address_output getBytes:adapter_address_bytes bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_address_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_address_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("sampler address-mode execution failed", adapter_pipeline_error);
            return 103;
        }
        if (memcmp(native_address_bytes, adapter_address_bytes, byte_count) != 0) {
            for (size_t byte = 0; byte < byte_count; ++byte) {
                if (native_address_bytes[byte] != adapter_address_bytes[byte]) {
                    fprintf(stderr, "metal-pixel: sampler address mismatch at byte %zu: Metal=%u ZPU=%u\n",
                            byte, native_address_bytes[byte], adapter_address_bytes[byte]);
                    break;
                }
            }
            return 104;
        }
        MTLRenderPipelineDescriptor *adapter_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        adapter_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        adapter_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_pipeline_descriptor.supportIndirectCommandBuffers = YES;
        id<MTLCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderPipelineState> adapter_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor error:&adapter_pipeline_error];

        /* Bound vertex resources are read when the draw executes. Mutating
         * native and ZPU-owned storage after encoding but before commit checks
         * the CPU adapter's deferred buffer-binding semantics. */
        const zpu_metal_vertex commit_initial_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        };
        const zpu_metal_vertex commit_updated_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
        };
        id<MTLBuffer> native_commit_vertex_buffer =
            [device newBufferWithBytes:commit_initial_vertices length:sizeof(commit_initial_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_commit_vertex_buffer =
            [adapter_device newBufferWithBytes:commit_initial_vertices length:sizeof(commit_initial_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_commit_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_commit_output = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *native_commit_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_commit_pass.colorAttachments[0].texture = native_commit_output;
        native_commit_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_commit_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_commit_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_commit_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_commit_encoder =
            [native_commit_command_buffer renderCommandEncoderWithDescriptor:native_commit_pass];
        [native_commit_encoder setRenderPipelineState:pipeline];
        [native_commit_encoder setVertexBytes:commit_initial_vertices length:sizeof(commit_initial_vertices) atIndex:0];
        [native_commit_encoder setVertexBuffer:native_commit_vertex_buffer offset:0 atIndex:0];
        [native_commit_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_commit_encoder endEncoding];
        MTLRenderPassDescriptor *adapter_commit_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_commit_pass.colorAttachments[0].texture = adapter_commit_output;
        adapter_commit_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_commit_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_commit_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_commit_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_commit_encoder =
            [adapter_commit_command_buffer renderCommandEncoderWithDescriptor:adapter_commit_pass];
        [adapter_commit_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_commit_encoder setVertexBytes:commit_initial_vertices length:sizeof(commit_initial_vertices) atIndex:0];
        [adapter_commit_encoder setVertexBuffer:adapter_commit_vertex_buffer offset:0 atIndex:0];
        [adapter_commit_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_commit_encoder endEncoding];
        memcpy(native_commit_vertex_buffer.contents, commit_updated_vertices, sizeof(commit_updated_vertices));
        memcpy(adapter_commit_vertex_buffer.contents, commit_updated_vertices, sizeof(commit_updated_vertices));
        [native_commit_command_buffer commit];
        [native_commit_command_buffer waitUntilCompleted];
        [adapter_commit_command_buffer commit];
        [adapter_commit_command_buffer waitUntilCompleted];
        uint8_t native_commit_bytes[byte_count];
        uint8_t adapter_commit_bytes[byte_count];
        [native_commit_output getBytes:native_commit_bytes bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_commit_output getBytes:adapter_commit_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        const size_t commit_pixel_offset = (4 * (size_t)width + 4) * 4;
        if (native_commit_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_commit_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_commit_bytes, adapter_commit_bytes, byte_count) != 0 ||
            memcmp(native_commit_bytes + commit_pixel_offset, (const uint8_t[]){0, 0, 255, 255}, 4) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_commit_bytes[mismatch] == adapter_commit_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: deferred vertex buffer mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_commit_command_buffer.status,
                    (unsigned long)adapter_commit_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_commit_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_commit_bytes[mismatch] : 0);
            return 120;
        }

        const zpu_metal_vertex indexed_commit_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
        };
        const uint16_t indexed_initial_indices[] = {0, 1, 2, 0, 2, 3};
        const uint16_t indexed_updated_indices[] = {4, 5, 6, 4, 6, 7};
        id<MTLBuffer> native_indexed_commit_vertices =
            [device newBufferWithBytes:indexed_commit_vertices length:sizeof(indexed_commit_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_indexed_commit_vertices =
            [adapter_device newBufferWithBytes:indexed_commit_vertices length:sizeof(indexed_commit_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> native_indexed_commit_indices =
            [device newBufferWithBytes:indexed_initial_indices length:sizeof(indexed_initial_indices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_indexed_commit_indices =
            [adapter_device newBufferWithBytes:indexed_initial_indices length:sizeof(indexed_initial_indices)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_indexed_commit_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_indexed_commit_output = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *native_indexed_commit_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_indexed_commit_pass.colorAttachments[0].texture = native_indexed_commit_output;
        native_indexed_commit_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_indexed_commit_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_indexed_commit_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_indexed_commit_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_indexed_commit_encoder =
            [native_indexed_commit_command_buffer renderCommandEncoderWithDescriptor:native_indexed_commit_pass];
        [native_indexed_commit_encoder setRenderPipelineState:pipeline];
        [native_indexed_commit_encoder setVertexBuffer:native_indexed_commit_vertices offset:0 atIndex:0];
        [native_indexed_commit_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16
                                                indexBuffer:native_indexed_commit_indices indexBufferOffset:0];
        [native_indexed_commit_encoder endEncoding];
        MTLRenderPassDescriptor *adapter_indexed_commit_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_indexed_commit_pass.colorAttachments[0].texture = adapter_indexed_commit_output;
        adapter_indexed_commit_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_indexed_commit_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_indexed_commit_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_indexed_commit_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_indexed_commit_encoder =
            [adapter_indexed_commit_command_buffer renderCommandEncoderWithDescriptor:adapter_indexed_commit_pass];
        [adapter_indexed_commit_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_indexed_commit_encoder setVertexBuffer:adapter_indexed_commit_vertices offset:0 atIndex:0];
        [adapter_indexed_commit_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:6 indexType:MTLIndexTypeUInt16
                                                 indexBuffer:adapter_indexed_commit_indices indexBufferOffset:0];
        [adapter_indexed_commit_encoder endEncoding];
        memcpy(native_indexed_commit_indices.contents, indexed_updated_indices, sizeof(indexed_updated_indices));
        memcpy(adapter_indexed_commit_indices.contents, indexed_updated_indices, sizeof(indexed_updated_indices));
        [native_indexed_commit_command_buffer commit];
        [native_indexed_commit_command_buffer waitUntilCompleted];
        [adapter_indexed_commit_command_buffer commit];
        [adapter_indexed_commit_command_buffer waitUntilCompleted];
        uint8_t native_indexed_commit_bytes[byte_count];
        uint8_t adapter_indexed_commit_bytes[byte_count];
        [native_indexed_commit_output getBytes:native_indexed_commit_bytes bytesPerRow:(NSUInteger)width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_indexed_commit_output getBytes:adapter_indexed_commit_bytes bytesPerRow:(NSUInteger)width * 4
                                     fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_indexed_commit_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_indexed_commit_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_indexed_commit_bytes, adapter_indexed_commit_bytes, byte_count) != 0 ||
            memcmp(native_indexed_commit_bytes + commit_pixel_offset, (const uint8_t[]){0, 0, 255, 255}, 4) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_indexed_commit_bytes[mismatch] == adapter_indexed_commit_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: deferred index buffer mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_indexed_commit_command_buffer.status,
                    (unsigned long)adapter_indexed_commit_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_indexed_commit_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_indexed_commit_bytes[mismatch] : 0);
            return 121;
        }

        MTLRenderPipelineDescriptor *native_no_raster_descriptor = [pipeline_descriptor copy];
        native_no_raster_descriptor.rasterizationEnabled = NO;
        native_no_raster_descriptor.vertexFunction = no_raster_vertex_function;
        native_no_raster_descriptor.fragmentFunction = nil;
        id<MTLRenderPipelineState> native_no_raster_pipeline =
            [device newRenderPipelineStateWithDescriptor:native_no_raster_descriptor error:&error];
        MTLRenderPipelineDescriptor *adapter_no_raster_descriptor = [native_no_raster_descriptor copy];
        adapter_no_raster_descriptor.vertexFunction = adapter_vertex_function;
        adapter_no_raster_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_no_raster_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_no_raster_descriptor error:&adapter_pipeline_error];
        id<MTLTexture> native_no_raster_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_no_raster_output = [adapter_device newTextureWithDescriptor:texture_descriptor];
        if (native_no_raster_pipeline == nil || adapter_no_raster_pipeline == nil ||
            native_no_raster_output == nil || adapter_no_raster_output == nil) {
            fail_with_error("rasterization-disabled pipeline allocation failed", adapter_pipeline_error);
            return 105;
        }
        MTLRenderPassDescriptor *native_no_raster_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_no_raster_pass.colorAttachments[0].texture = native_no_raster_output;
        native_no_raster_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_no_raster_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_no_raster_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_no_raster_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_no_raster_encoder =
            [native_no_raster_command_buffer renderCommandEncoderWithDescriptor:native_no_raster_pass];
        [native_no_raster_encoder setRenderPipelineState:native_no_raster_pipeline];
        [native_no_raster_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_no_raster_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_no_raster_encoder endEncoding];
        [native_no_raster_command_buffer commit];
        [native_no_raster_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_no_raster_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_no_raster_pass.colorAttachments[0].texture = adapter_no_raster_output;
        adapter_no_raster_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_no_raster_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_no_raster_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_no_raster_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_no_raster_encoder =
            [adapter_no_raster_command_buffer renderCommandEncoderWithDescriptor:adapter_no_raster_pass];
        [adapter_no_raster_encoder setRenderPipelineState:adapter_no_raster_pipeline];
        [adapter_no_raster_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_no_raster_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_no_raster_encoder endEncoding];
        [adapter_no_raster_command_buffer commit];
        [adapter_no_raster_command_buffer waitUntilCompleted];
        uint8_t native_no_raster_bytes[byte_count];
        uint8_t adapter_no_raster_bytes[byte_count];
        [native_no_raster_output getBytes:native_no_raster_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_no_raster_output getBytes:adapter_no_raster_bytes bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_no_raster_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_no_raster_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_no_raster_bytes, adapter_no_raster_bytes, byte_count) != 0) {
            fail_with_error("rasterization-disabled pipeline execution failed", adapter_pipeline_error);
            return 106;
        }

        /* Multiple color attachments use an explicit CPU shader profile. The
         * native oracle writes the same interpolated color to RGBA8 target 0
         * and BGRA8 target 1, including each target's native byte order. */
        MTLRenderPipelineDescriptor *mrt_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        mrt_pipeline_descriptor.vertexFunction = vertex_function;
        mrt_pipeline_descriptor.fragmentFunction = mrt_fragment_function;
        mrt_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        mrt_pipeline_descriptor.colorAttachments[1].pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLRenderPipelineState> metal_mrt_pipeline =
            [device newRenderPipelineStateWithDescriptor:mrt_pipeline_descriptor error:&error];
        MTLTextureDescriptor *native_mrt_bgra_descriptor = [texture_descriptor copy];
        native_mrt_bgra_descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLTexture> native_mrt_rgba = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> native_mrt_bgra = [device newTextureWithDescriptor:native_mrt_bgra_descriptor];
        MTLRenderPassDescriptor *native_mrt_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_mrt_pass.colorAttachments[0].texture = native_mrt_rgba;
        native_mrt_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_mrt_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_mrt_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        native_mrt_pass.colorAttachments[1].texture = native_mrt_bgra;
        native_mrt_pass.colorAttachments[1].loadAction = MTLLoadActionClear;
        native_mrt_pass.colorAttachments[1].storeAction = MTLStoreActionStore;
        native_mrt_pass.colorAttachments[1].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
        id<MTLCommandBuffer> native_mrt_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_mrt_encoder =
            [native_mrt_command_buffer renderCommandEncoderWithDescriptor:native_mrt_pass];
        [native_mrt_encoder setRenderPipelineState:metal_mrt_pipeline];
        [native_mrt_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_mrt_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_mrt_encoder endEncoding];
        [native_mrt_command_buffer commit];
        [native_mrt_command_buffer waitUntilCompleted];
        if (metal_mrt_pipeline == nil || native_mrt_rgba == nil || native_mrt_bgra == nil ||
            native_mrt_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("MRT reference allocation or execution failed", error);
            return 85;
        }
        uint8_t native_mrt_rgba_bytes[byte_count];
        uint8_t native_mrt_bgra_bytes[byte_count];
        [native_mrt_rgba getBytes:native_mrt_rgba_bytes bytesPerRow:(NSUInteger)width * 4
                       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [native_mrt_bgra getBytes:native_mrt_bgra_bytes bytesPerRow:(NSUInteger)width * 4
                       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLFunction> adapter_mrt_fragment =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_mrt_fragment");
        MTLRenderPipelineDescriptor *adapter_mrt_pipeline_descriptor = [mrt_pipeline_descriptor copy];
        adapter_mrt_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_mrt_pipeline_descriptor.fragmentFunction = adapter_mrt_fragment;
        id<MTLRenderPipelineState> adapter_mrt_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_mrt_pipeline_descriptor error:&adapter_pipeline_error];
        MTLTextureDescriptor *adapter_mrt_bgra_descriptor = [adapter_texture_descriptor copy];
        adapter_mrt_bgra_descriptor.pixelFormat = MTLPixelFormatBGRA8Unorm;
        id<MTLTexture> adapter_mrt_rgba = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLTexture> adapter_mrt_bgra = [adapter_device newTextureWithDescriptor:adapter_mrt_bgra_descriptor];
        MTLRenderPassDescriptor *adapter_mrt_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_mrt_pass.colorAttachments[0].texture = adapter_mrt_rgba;
        adapter_mrt_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_mrt_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_mrt_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_mrt_pass.colorAttachments[1].texture = adapter_mrt_bgra;
        adapter_mrt_pass.colorAttachments[1].loadAction = MTLLoadActionClear;
        adapter_mrt_pass.colorAttachments[1].storeAction = MTLStoreActionStore;
        adapter_mrt_pass.colorAttachments[1].clearColor = MTLClearColorMake(1.0, 1.0, 1.0, 1.0);
        id<MTLCommandBuffer> adapter_mrt_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_mrt_encoder =
            [adapter_mrt_command_buffer renderCommandEncoderWithDescriptor:adapter_mrt_pass];
        if (adapter_mrt_fragment == nil || adapter_mrt_pipeline == nil || adapter_mrt_rgba == nil ||
            adapter_mrt_bgra == nil || adapter_mrt_command_buffer == nil || adapter_mrt_encoder == nil) {
            fail_with_error("MRT adapter allocation failed", adapter_pipeline_error);
            return 86;
        }
        [adapter_mrt_encoder setRenderPipelineState:adapter_mrt_pipeline];
        [adapter_mrt_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mrt_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_mrt_encoder endEncoding];
        [adapter_mrt_command_buffer commit];
        [adapter_mrt_command_buffer waitUntilCompleted];
        if (adapter_mrt_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: MRT adapter command did not complete\n");
            return 87;
        }
        uint8_t adapter_mrt_rgba_bytes[byte_count];
        uint8_t adapter_mrt_bgra_bytes[byte_count];
        [adapter_mrt_rgba getBytes:adapter_mrt_rgba_bytes bytesPerRow:(NSUInteger)width * 4
                        fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_mrt_bgra getBytes:adapter_mrt_bgra_bytes bytesPerRow:(NSUInteger)width * 4
                        fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; ++index) {
            if (native_mrt_rgba_bytes[index] != adapter_mrt_rgba_bytes[index]) {
                fprintf(stderr, "metal-pixel: MRT RGBA mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, native_mrt_rgba_bytes[index], adapter_mrt_rgba_bytes[index]);
                return 88;
            }
            if (native_mrt_bgra_bytes[index] != adapter_mrt_bgra_bytes[index]) {
                fprintf(stderr, "metal-pixel: MRT BGRA mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, native_mrt_bgra_bytes[index], adapter_mrt_bgra_bytes[index]);
                return 89;
            }
        }
        MTLSamplerDescriptor *adapter_sampler_descriptor = [MTLSamplerDescriptor new];
        id<MTLSamplerState> adapter_sampler =
            [adapter_device newSamplerStateWithDescriptor:adapter_sampler_descriptor];
        MTLRenderPassDescriptor *adapter_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_pass.colorAttachments[0].texture = adapter_texture;
        adapter_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLRenderCommandEncoder> adapter_encoder =
            [adapter_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
        if (adapter_device == nil || adapter_texture == nil || adapter_vertex_buffer == nil ||
            adapter_vertex_function == nil || adapter_fragment_function == nil ||
            adapter_vertex_function.functionType != MTLFunctionTypeVertex ||
            adapter_fragment_function.functionType != MTLFunctionTypeFragment ||
            adapter_queue == nil || adapter_command_buffer == nil || adapter_encoder == nil ||
            adapter_pipeline == nil || adapter_sampler == nil) {
            fail_with_error("Objective-C adapter pipeline/resource allocation failed", adapter_pipeline_error);
            fprintf(stderr, "metal-pixel: Objective-C adapter allocation failed\n");
            return 18;
        }
        const BOOL adapter_protocols_ok =
            [adapter_device conformsToProtocol:@protocol(MTLDevice)] &&
            [adapter_queue conformsToProtocol:@protocol(MTLCommandQueue)] &&
            [adapter_command_buffer conformsToProtocol:@protocol(MTLCommandBuffer)] &&
            [adapter_texture conformsToProtocol:@protocol(MTLTexture)] &&
            [adapter_vertex_buffer conformsToProtocol:@protocol(MTLBuffer)] &&
            [adapter_pipeline conformsToProtocol:@protocol(MTLRenderPipelineState)] &&
            [adapter_sampler conformsToProtocol:@protocol(MTLSamplerState)] &&
            [adapter_encoder conformsToProtocol:@protocol(MTLRenderCommandEncoder)];
        const BOOL adapter_selector_resource_state = [adapter_command_buffer respondsToSelector:@selector(resourceStateCommandEncoder)];
        const BOOL adapter_selector_acceleration = [adapter_command_buffer respondsToSelector:@selector(accelerationStructureCommandEncoder)];
        const BOOL adapter_selector_event = [adapter_command_buffer respondsToSelector:@selector(encodeSignalEvent:value:)];
        const BOOL adapter_selector_viewports = [adapter_encoder respondsToSelector:@selector(setViewports:count:)];
        const BOOL adapter_selector_scissors = [adapter_encoder respondsToSelector:@selector(setScissorRects:count:)];
        const BOOL adapter_selectors_ok = adapter_selector_resource_state && adapter_selector_acceleration &&
            adapter_selector_event && adapter_selector_viewports && adapter_selector_scissors;
        id<MTLCommandBuffer> adapter_resource_state_command_buffer = [adapter_queue commandBuffer];
        id<MTLResourceStateCommandEncoder> adapter_resource_state_encoder =
            [adapter_resource_state_command_buffer resourceStateCommandEncoderWithDescriptor:
                [MTLResourceStatePassDescriptor resourceStatePassDescriptor]];
        id<MTLFence> adapter_resource_state_fence = [adapter_device newFence];
        [adapter_resource_state_encoder updateFence:adapter_resource_state_fence];
        [adapter_resource_state_encoder endEncoding];
        id<MTLBlitCommandEncoder> adapter_resource_state_followup =
            [adapter_resource_state_command_buffer blitCommandEncoder];
        [adapter_resource_state_followup waitForFence:adapter_resource_state_fence];
        [adapter_resource_state_followup endEncoding];
        [adapter_resource_state_command_buffer commit];
        [adapter_resource_state_command_buffer waitUntilCompleted];
        id<MTLLibrary> adapter_conformance_default_library = [adapter_device newDefaultLibrary];
        const BOOL adapter_fail_closed_ok =
            adapter_conformance_default_library != nil &&
            [adapter_conformance_default_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"] != nil &&
            adapter_resource_state_encoder != nil &&
            [adapter_resource_state_encoder conformsToProtocol:@protocol(MTLResourceStateCommandEncoder)] &&
            adapter_resource_state_command_buffer.status == MTLCommandBufferStatusCompleted &&
            [adapter_command_buffer accelerationStructureCommandEncoder] == nil;
        if (!adapter_protocols_ok || !adapter_selectors_ok || !adapter_fail_closed_ok) {
            fprintf(stderr, "metal-pixel: protocol flags=%d selectors=%d fail-closed=%d (%d,%d,%d,%d,%d)\n",
                    adapter_protocols_ok, adapter_selectors_ok, adapter_selector_resource_state,
                    adapter_fail_closed_ok, adapter_selector_acceleration, adapter_selector_event,
                    adapter_selector_viewports, adapter_selector_scissors);
            fprintf(stderr, "metal-pixel: CPU adapter protocol/selector conformance failed\n");
            return 54;
        }
        /* Supported render state must not discard a runtime validation error.
         * This intentionally exercises only the CPU adapter: an invalid
         * enum is rejected by ZPU and must surface as command-buffer error. */
        id<MTLCommandBuffer> adapter_invalid_state_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_invalid_state_encoder =
            [adapter_invalid_state_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
        [adapter_invalid_state_encoder setCullMode:(MTLCullMode)99];
        [adapter_invalid_state_encoder endEncoding];
        [adapter_invalid_state_command_buffer commit];
        [adapter_invalid_state_command_buffer waitUntilCompleted];
        if (adapter_invalid_state_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: invalid CPU render state did not fail closed\n");
            return 55;
        }
        NSError *adapter_residency_error = nil;
        MTLResidencySetDescriptor *adapter_residency_descriptor = [MTLResidencySetDescriptor new];
        adapter_residency_descriptor.label = @"zpu-cpu-residency";
        id<MTLResidencySet> adapter_residency_set =
            [adapter_device newResidencySetWithDescriptor:adapter_residency_descriptor error:&adapter_residency_error];
        id<MTLAllocation> adapter_allocations[] = {
            (id<MTLAllocation>)adapter_vertex_buffer,
            (id<MTLAllocation>)adapter_texture,
        };
        [adapter_residency_set addAllocations:adapter_allocations count:2];
        [adapter_residency_set addAllocation:(id<MTLAllocation>)adapter_texture];
        [adapter_residency_set commit];
        [adapter_queue addResidencySet:adapter_residency_set];
        const uint64_t adapter_expected_residency_size =
            (uint64_t)adapter_vertex_buffer.length + (uint64_t)adapter_texture.allocatedSize;
        BOOL adapter_residency_ok =
            adapter_residency_set != nil &&
            [adapter_residency_set conformsToProtocol:@protocol(MTLResidencySet)] &&
            adapter_residency_set.allocationCount == 2 &&
            [adapter_residency_set containsAllocation:(id<MTLAllocation>)adapter_vertex_buffer] &&
            [adapter_residency_set containsAllocation:(id<MTLAllocation>)adapter_texture] &&
            adapter_residency_set.allocatedSize == adapter_expected_residency_size &&
            adapter_residency_set.allAllocations.count == 2;
        [adapter_residency_set requestResidency];
        [adapter_residency_set removeAllocation:(id<MTLAllocation>)adapter_texture];
        [adapter_residency_set removeAllAllocations];
        [adapter_residency_set endResidency];
        adapter_residency_ok = adapter_residency_ok && adapter_residency_set.allocationCount == 0;
        if (!adapter_residency_ok) {
            fail_with_error("CPU residency-set metadata failed", adapter_residency_error);
            return 66;
        }
        MTLSizeAndAlign adapter_heap_size_align =
            [adapter_device heapTextureSizeAndAlignWithDescriptor:adapter_texture_descriptor];
        id<MTLCommandQueue> adapter_limited_queue =
            [adapter_device newCommandQueueWithMaxCommandBufferCount:1];
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        const BOOL adapter_supports_legacy_feature_set =
            [adapter_device supportsFeatureSet:(NSUInteger)10005];
        #pragma clang diagnostic pop
        if (![adapter_device supportsFamily:MTLGPUFamilyApple7] ||
            !adapter_supports_legacy_feature_set ||
            adapter_limited_queue == nil || adapter_heap_size_align.size != byte_count ||
            adapter_heap_size_align.align != 4) {
            fprintf(stderr, "metal-pixel: adapter device capability query failed\n");
            return 41;
        }

        /* Resource options are observable Metal state even though the ZPU
         * implementation keeps the backing bytes in CPU memory. Preserve
         * the caller's storage/cache/hazard metadata and propagate texture
         * descriptor state through views. */
        const MTLResourceOptions adapter_metadata_buffer_options =
            MTLResourceStorageModePrivate | MTLResourceCPUCacheModeWriteCombined |
            MTLResourceHazardTrackingModeUntracked;
        id<MTLBuffer> adapter_metadata_buffer =
            [adapter_device newBufferWithLength:16 options:adapter_metadata_buffer_options];
        MTLTextureDescriptor *adapter_metadata_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:2
                                                               height:2
                                                            mipmapped:NO];
        adapter_metadata_descriptor.usage = MTLTextureUsageShaderRead;
        adapter_metadata_descriptor.storageMode = MTLStorageModePrivate;
        adapter_metadata_descriptor.cpuCacheMode = MTLCPUCacheModeWriteCombined;
        adapter_metadata_descriptor.hazardTrackingMode = MTLHazardTrackingModeUntracked;
        adapter_metadata_descriptor.allowGPUOptimizedContents = YES;
        id<MTLTexture> adapter_metadata_texture =
            [adapter_device newTextureWithDescriptor:adapter_metadata_descriptor];
        id<MTLTexture> adapter_metadata_view =
            [adapter_metadata_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
        if (adapter_metadata_buffer == nil ||
            adapter_metadata_buffer.resourceOptions != adapter_metadata_buffer_options ||
            adapter_metadata_buffer.storageMode != MTLStorageModePrivate ||
            adapter_metadata_buffer.cpuCacheMode != MTLCPUCacheModeWriteCombined ||
            adapter_metadata_buffer.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_metadata_texture == nil ||
            adapter_metadata_texture.resourceOptions != adapter_metadata_descriptor.resourceOptions ||
            adapter_metadata_texture.usage != MTLTextureUsageShaderRead ||
            adapter_metadata_texture.storageMode != MTLStorageModePrivate ||
            adapter_metadata_texture.cpuCacheMode != MTLCPUCacheModeWriteCombined ||
            adapter_metadata_texture.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            !adapter_metadata_texture.allowGPUOptimizedContents ||
            adapter_metadata_texture.compressionType != adapter_metadata_descriptor.compressionType ||
            adapter_metadata_texture.swizzle.red != adapter_metadata_descriptor.swizzle.red ||
            adapter_metadata_texture.swizzle.green != adapter_metadata_descriptor.swizzle.green ||
            adapter_metadata_texture.swizzle.blue != adapter_metadata_descriptor.swizzle.blue ||
            adapter_metadata_texture.swizzle.alpha != adapter_metadata_descriptor.swizzle.alpha ||
            adapter_metadata_view == nil ||
            adapter_metadata_view.resourceOptions != adapter_metadata_texture.resourceOptions ||
            adapter_metadata_view.usage != adapter_metadata_texture.usage ||
            adapter_metadata_view.storageMode != adapter_metadata_texture.storageMode ||
            adapter_metadata_view.hazardTrackingMode != adapter_metadata_texture.hazardTrackingMode) {
            fprintf(stderr, "metal-pixel: adapter resource metadata propagation failed\n");
            return 55;
        }

        /* Mip levels are independent ZPU textures in the CPU adapter. Apple
         * Metal remains the byte oracle; no native texture is used by the
         * adapter implementation. Exercise the level coordinate space,
         * level-range views, and legacy blit level selection. */
        MTLTextureDescriptor *mip_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:4
                                                               height:4
                                                            mipmapped:YES];
        mip_descriptor.storageMode = MTLStorageModeShared;
        mip_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_mip_texture = [device newTextureWithDescriptor:mip_descriptor];
        id<MTLTexture> adapter_mip_texture = [adapter_device newTextureWithDescriptor:mip_descriptor];
        const uint8_t mip_level_one[] = {
            0x03, 0x17, 0x29, 0x3b,  0x4d, 0x5f, 0x71, 0x83,
            0x95, 0xa7, 0xb9, 0xcb,  0xdd, 0xef, 0x01, 0x13,
        };
        [native_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                              mipmapLevel:1
                                withBytes:mip_level_one
                              bytesPerRow:2 * 4];
        [adapter_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                               mipmapLevel:1
                                 withBytes:mip_level_one
                               bytesPerRow:2 * 4];
        uint8_t native_mip_level_one[sizeof(mip_level_one)];
        uint8_t adapter_mip_level_one[sizeof(mip_level_one)];
        [native_mip_texture getBytes:native_mip_level_one
                         bytesPerRow:2 * 4
                          fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                         mipmapLevel:1];
        [adapter_mip_texture getBytes:adapter_mip_level_one
                          bytesPerRow:2 * 4
                           fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                          mipmapLevel:1];
        id<MTLTexture> adapter_mip_view =
            [adapter_mip_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                    textureType:MTLTextureType2D
                                                         levels:NSMakeRange(1, 1)
                                                         slices:NSMakeRange(0, 1)];
        uint8_t adapter_mip_view_bytes[sizeof(mip_level_one)];
        [adapter_mip_view getBytes:adapter_mip_view_bytes
                        bytesPerRow:2 * 4
                         fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                        mipmapLevel:0];
        id<MTLTexture> adapter_mip_copy = [adapter_device newTextureWithDescriptor:mip_descriptor];
        id<MTLBuffer> adapter_mip_buffer =
            [adapter_device newBufferWithLength:sizeof(mip_level_one) options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_mip_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_mip_blit = [adapter_mip_command_buffer blitCommandEncoder];
        [adapter_mip_blit copyFromTexture:adapter_mip_texture
                              sourceSlice:0
                              sourceLevel:1
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(2, 2, 1)
                                 toBuffer:adapter_mip_buffer
                        destinationOffset:0
                   destinationBytesPerRow:2 * 4
                 destinationBytesPerImage:0];
        [adapter_mip_blit copyFromBuffer:adapter_mip_buffer
                            sourceOffset:0
                       sourceBytesPerRow:2 * 4
                     sourceBytesPerImage:0
                            sourceSize:MTLSizeMake(2, 2, 1)
                              toTexture:adapter_mip_copy
                       destinationSlice:0
                       destinationLevel:1
                      destinationOrigin:MTLOriginMake(0, 0, 0)];
        [adapter_mip_blit copyFromTexture:adapter_mip_texture
                              sourceSlice:0
                              sourceLevel:1
                             sourceOrigin:MTLOriginMake(0, 0, 0)
                               sourceSize:MTLSizeMake(2, 2, 1)
                             toTexture:adapter_mip_copy
                      destinationSlice:0
                      destinationLevel:1
                     destinationOrigin:MTLOriginMake(0, 0, 0)];
        [adapter_mip_blit endEncoding];
        [adapter_mip_command_buffer commit];
        [adapter_mip_command_buffer waitUntilCompleted];
        uint8_t adapter_mip_copy_bytes[sizeof(mip_level_one)];
        [adapter_mip_copy getBytes:adapter_mip_copy_bytes
                        bytesPerRow:2 * 4
                         fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                        mipmapLevel:1];
        const NSUInteger expected_mip_allocated_size = (4 * 4 + 2 * 2 + 1) * 4;
        if (native_mip_texture == nil || adapter_mip_texture == nil ||
            native_mip_texture.mipmapLevelCount != 3 || adapter_mip_texture.mipmapLevelCount != 3 ||
            adapter_mip_texture.allocatedSize != expected_mip_allocated_size ||
            adapter_mip_view == nil || adapter_mip_view.width != 2 || adapter_mip_view.height != 2 ||
            adapter_mip_view.mipmapLevelCount != 1 || adapter_mip_view.parentRelativeLevel != 1 ||
            adapter_mip_buffer == nil || adapter_mip_copy == nil ||
            adapter_mip_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_mip_level_one, mip_level_one, sizeof(mip_level_one)) != 0 ||
            memcmp(adapter_mip_level_one, native_mip_level_one, sizeof(mip_level_one)) != 0 ||
            memcmp(adapter_mip_view_bytes, native_mip_level_one, sizeof(mip_level_one)) != 0 ||
            memcmp(adapter_mip_copy_bytes, native_mip_level_one, sizeof(mip_level_one)) != 0) {
            fprintf(stderr, "metal-pixel: mip-level/view/blit exactness failed\n");
            return 69;
        }

        MTLTextureDescriptor *generate_mip_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:4
                                                               height:4
                                                            mipmapped:YES];
        generate_mip_descriptor.storageMode = MTLStorageModeShared;
        generate_mip_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_generate_mip_texture = [device newTextureWithDescriptor:generate_mip_descriptor];
        id<MTLTexture> adapter_generate_mip_texture = [adapter_device newTextureWithDescriptor:generate_mip_descriptor];
        uint8_t generate_mip_base[4 * 4 * 4];
        for (size_t index = 0; index < sizeof(generate_mip_base); ++index) {
            generate_mip_base[index] = (uint8_t)((index * 29u + 7u) & 0xffu);
        }
        [native_generate_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                                       mipmapLevel:0
                                         withBytes:generate_mip_base
                                       bytesPerRow:4 * 4];
        [adapter_generate_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                                        mipmapLevel:0
                                          withBytes:generate_mip_base
                                        bytesPerRow:4 * 4];
        id<MTLCommandBuffer> native_generate_mip_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_generate_mip_blit = [native_generate_mip_command_buffer blitCommandEncoder];
        [native_generate_mip_blit generateMipmapsForTexture:native_generate_mip_texture];
        [native_generate_mip_blit endEncoding];
        [native_generate_mip_command_buffer commit];
        [native_generate_mip_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_generate_mip_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_generate_mip_blit = [adapter_generate_mip_command_buffer blitCommandEncoder];
        [adapter_generate_mip_blit generateMipmapsForTexture:adapter_generate_mip_texture];
        [adapter_generate_mip_blit endEncoding];
        uint8_t adapter_deferred_mip_level_one[sizeof(mip_level_one)];
        [adapter_generate_mip_texture getBytes:adapter_deferred_mip_level_one
                                   bytesPerRow:2 * 4
                                    fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                   mipmapLevel:1];
        [adapter_generate_mip_command_buffer commit];
        [adapter_generate_mip_command_buffer waitUntilCompleted];
        uint8_t native_generated_mip_level_one[sizeof(mip_level_one)];
        uint8_t adapter_generated_mip_level_one[sizeof(mip_level_one)];
        [native_generate_mip_texture getBytes:native_generated_mip_level_one
                                  bytesPerRow:2 * 4
                                   fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                  mipmapLevel:1];
        [adapter_generate_mip_texture getBytes:adapter_generated_mip_level_one
                                   bytesPerRow:2 * 4
                                    fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                   mipmapLevel:1];
        if (native_generate_mip_texture == nil || adapter_generate_mip_texture == nil ||
            native_generate_mip_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_generate_mip_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(adapter_deferred_mip_level_one, (const uint8_t[sizeof(mip_level_one)]){0}, sizeof(mip_level_one)) != 0 ||
            memcmp(native_generated_mip_level_one, adapter_generated_mip_level_one, sizeof(mip_level_one)) != 0) {
            fprintf(stderr, "metal-pixel: mipmap generation exactness failed\n");
            return 71;
        }

        MTLTextureDescriptor *mip_render_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:4
                                                               height:4
                                                            mipmapped:YES];
        mip_render_descriptor.storageMode = MTLStorageModeShared;
        mip_render_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> native_mip_render_texture = [device newTextureWithDescriptor:mip_render_descriptor];
        id<MTLTexture> adapter_mip_render_texture = [adapter_device newTextureWithDescriptor:mip_render_descriptor];
        const zpu_metal_vertex mip_render_vertices[] = {
            {{-0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{ 0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{ 0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{-0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{ 0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
            {{-0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.5f, 0.75f, 1.0f}},
        };
        id<MTLBuffer> native_mip_render_vertex_buffer =
            [device newBufferWithBytes:mip_render_vertices length:sizeof(mip_render_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_mip_render_vertex_buffer =
            [adapter_device newBufferWithBytes:mip_render_vertices length:sizeof(mip_render_vertices)
                                       options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *native_mip_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_mip_render_pass.colorAttachments[0].texture = native_mip_render_texture;
        native_mip_render_pass.colorAttachments[0].level = 1;
        native_mip_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_mip_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_mip_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> native_mip_render_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_mip_render_encoder =
            [native_mip_render_command_buffer renderCommandEncoderWithDescriptor:native_mip_render_pass];
        [native_mip_render_encoder setRenderPipelineState:pipeline];
        [native_mip_render_encoder setVertexBuffer:native_mip_render_vertex_buffer offset:0 atIndex:0];
        [native_mip_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_mip_render_encoder endEncoding];
        [native_mip_render_command_buffer commit];
        [native_mip_render_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_mip_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_mip_render_pass.colorAttachments[0].texture = adapter_mip_render_texture;
        adapter_mip_render_pass.colorAttachments[0].level = 1;
        adapter_mip_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_mip_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_mip_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_mip_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_mip_render_encoder =
            [adapter_mip_render_command_buffer renderCommandEncoderWithDescriptor:adapter_mip_render_pass];
        [adapter_mip_render_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_mip_render_encoder setVertexBuffer:adapter_mip_render_vertex_buffer offset:0 atIndex:0];
        [adapter_mip_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_mip_render_encoder endEncoding];
        [adapter_mip_render_command_buffer commit];
        [adapter_mip_render_command_buffer waitUntilCompleted];
        uint8_t native_mip_render_pixels[2 * 2 * 4];
        uint8_t adapter_mip_render_pixels[2 * 2 * 4];
        [native_mip_render_texture getBytes:native_mip_render_pixels
                                bytesPerRow:2 * 4
                                 fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                mipmapLevel:1];
        [adapter_mip_render_texture getBytes:adapter_mip_render_pixels
                                 bytesPerRow:2 * 4
                                  fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                 mipmapLevel:1];
        if (native_mip_render_texture == nil || adapter_mip_render_texture == nil ||
            native_mip_render_vertex_buffer == nil || adapter_mip_render_vertex_buffer == nil ||
            native_mip_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_mip_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_mip_render_pixels, adapter_mip_render_pixels, sizeof(native_mip_render_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: mip-level render exactness failed\n");
            return 72;
        }

        MTLTextureDescriptor *array_descriptor = [MTLTextureDescriptor new];
        array_descriptor.textureType = MTLTextureType2DArray;
        array_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        array_descriptor.width = 4;
        array_descriptor.height = 4;
        array_descriptor.arrayLength = 2;
        array_descriptor.mipmapLevelCount = 3;
        array_descriptor.sampleCount = 1;
        array_descriptor.storageMode = MTLStorageModeShared;
        array_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_array_texture = [device newTextureWithDescriptor:array_descriptor];
        id<MTLTexture> adapter_array_texture = [adapter_device newTextureWithDescriptor:array_descriptor];
        const uint8_t array_level_one[] = {
            0x21, 0x32, 0x43, 0x54,  0x65, 0x76, 0x87, 0x98,
            0xa9, 0xba, 0xcb, 0xdc,  0xed, 0xfe, 0x0f, 0x10,
        };
        [native_array_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                                mipmapLevel:1
                                      slice:1
                                  withBytes:array_level_one
                                bytesPerRow:2 * 4
                              bytesPerImage:sizeof(array_level_one)];
        [adapter_array_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                                 mipmapLevel:1
                                       slice:1
                                   withBytes:array_level_one
                                 bytesPerRow:2 * 4
                               bytesPerImage:sizeof(array_level_one)];
        uint8_t native_array_level_one[sizeof(array_level_one)];
        uint8_t adapter_array_level_one[sizeof(array_level_one)];
        [native_array_texture getBytes:native_array_level_one
                           bytesPerRow:2 * 4
                         bytesPerImage:sizeof(array_level_one)
                          fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                         mipmapLevel:1
                                slice:1];
        [adapter_array_texture getBytes:adapter_array_level_one
                            bytesPerRow:2 * 4
                          bytesPerImage:sizeof(array_level_one)
                           fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                          mipmapLevel:1
                                 slice:1];
        id<MTLTexture> adapter_array_view =
            [adapter_array_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                       textureType:MTLTextureType2DArray
                                                            levels:NSMakeRange(1, 1)
                                                            slices:NSMakeRange(1, 1)];
        uint8_t adapter_array_view_bytes[sizeof(array_level_one)];
        [adapter_array_view getBytes:adapter_array_view_bytes
                         bytesPerRow:2 * 4
                       bytesPerImage:sizeof(array_level_one)
                        fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                       mipmapLevel:0
                              slice:0];
        id<MTLTexture> adapter_array_copy = [adapter_device newTextureWithDescriptor:array_descriptor];
        id<MTLCommandBuffer> adapter_array_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_array_blit = [adapter_array_command_buffer blitCommandEncoder];
        [adapter_array_blit copyFromTexture:adapter_array_texture
                                sourceSlice:1
                                sourceLevel:1
                               sourceOrigin:MTLOriginMake(0, 0, 0)
                                 sourceSize:MTLSizeMake(2, 2, 1)
                               toTexture:adapter_array_copy
                        destinationSlice:0
                        destinationLevel:1
                       destinationOrigin:MTLOriginMake(0, 0, 0)];
        [adapter_array_blit endEncoding];
        [adapter_array_command_buffer commit];
        [adapter_array_command_buffer waitUntilCompleted];
        uint8_t adapter_array_copy_bytes[sizeof(array_level_one)];
        [adapter_array_copy getBytes:adapter_array_copy_bytes
                          bytesPerRow:2 * 4
                        bytesPerImage:sizeof(array_level_one)
                         fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                        mipmapLevel:1
                               slice:0];
        const NSUInteger expected_array_allocated_size = 2 * (4 * 4 + 2 * 2 + 1) * 4;
        if (native_array_texture == nil || adapter_array_texture == nil ||
            native_array_texture.arrayLength != 2 || adapter_array_texture.arrayLength != 2 ||
            native_array_texture.mipmapLevelCount != 3 || adapter_array_texture.mipmapLevelCount != 3 ||
            adapter_array_texture.allocatedSize != expected_array_allocated_size ||
            adapter_array_view == nil || adapter_array_view.arrayLength != 1 ||
            adapter_array_view.width != 2 || adapter_array_view.height != 2 ||
            adapter_array_view.mipmapLevelCount != 1 || adapter_array_view.parentRelativeLevel != 1 ||
            adapter_array_view.parentRelativeSlice != 1 || adapter_array_copy == nil ||
            adapter_array_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_array_level_one, array_level_one, sizeof(array_level_one)) != 0 ||
            memcmp(adapter_array_level_one, native_array_level_one, sizeof(array_level_one)) != 0 ||
            memcmp(adapter_array_view_bytes, native_array_level_one, sizeof(array_level_one)) != 0 ||
            memcmp(adapter_array_copy_bytes, native_array_level_one, sizeof(array_level_one)) != 0) {
            fprintf(stderr, "metal-pixel: 2D-array slice/level exactness failed\n");
            return 75;
        }

        MTLTextureDescriptor *one_d_descriptor = [MTLTextureDescriptor new];
        one_d_descriptor.textureType = MTLTextureType1D;
        one_d_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        one_d_descriptor.width = width;
        one_d_descriptor.height = 1;
        one_d_descriptor.depth = 1;
        one_d_descriptor.arrayLength = 1;
        one_d_descriptor.mipmapLevelCount = 1;
        one_d_descriptor.sampleCount = 1;
        one_d_descriptor.storageMode = MTLStorageModeShared;
        one_d_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_one_d_texture = [device newTextureWithDescriptor:one_d_descriptor];
        id<MTLTexture> adapter_one_d_texture = [adapter_device newTextureWithDescriptor:one_d_descriptor];
        uint8_t one_d_bytes[width * 4];
        for (NSUInteger index = 0; index < sizeof(one_d_bytes); ++index) {
            one_d_bytes[index] = (uint8_t)((index * 29u + 7u) & 0xffu);
        }
        [native_one_d_texture replaceRegion:MTLRegionMake1D(0, width)
                                mipmapLevel:0
                                  withBytes:one_d_bytes
                                bytesPerRow:sizeof(one_d_bytes)];
        [adapter_one_d_texture replaceRegion:MTLRegionMake1D(0, width)
                                 mipmapLevel:0
                                   withBytes:one_d_bytes
                                 bytesPerRow:sizeof(one_d_bytes)];
        uint8_t native_one_d_bytes[sizeof(one_d_bytes)];
        uint8_t adapter_one_d_bytes[sizeof(one_d_bytes)];
        [native_one_d_texture getBytes:native_one_d_bytes
                           bytesPerRow:sizeof(native_one_d_bytes)
                            fromRegion:MTLRegionMake1D(0, width)
                           mipmapLevel:0];
        [adapter_one_d_texture getBytes:adapter_one_d_bytes
                            bytesPerRow:sizeof(adapter_one_d_bytes)
                             fromRegion:MTLRegionMake1D(0, width)
                            mipmapLevel:0];

        MTLTextureDescriptor *buffer_texture_descriptor = [texture_descriptor copy];
        id<MTLBuffer> native_buffer_backing =
            [device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_buffer_backing =
            [adapter_device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        uint8_t buffer_texture_bytes[byte_count];
        for (NSUInteger index = 0; index < sizeof(buffer_texture_bytes); ++index) {
            buffer_texture_bytes[index] = (uint8_t)((index * 47u + 23u) & 0xffu);
        }
        if (native_buffer_backing != nil) memcpy(native_buffer_backing.contents, buffer_texture_bytes, sizeof(buffer_texture_bytes));
        if (adapter_buffer_backing != nil) memcpy(adapter_buffer_backing.contents, buffer_texture_bytes, sizeof(buffer_texture_bytes));
        id<MTLTexture> native_buffer_texture =
            [native_buffer_backing newTextureWithDescriptor:buffer_texture_descriptor offset:0 bytesPerRow:width * 4];
        id<MTLTexture> adapter_buffer_texture =
            [adapter_buffer_backing newTextureWithDescriptor:buffer_texture_descriptor offset:0 bytesPerRow:width * 4];
        uint8_t native_buffer_texture_bytes[byte_count];
        uint8_t adapter_buffer_texture_bytes[byte_count];
        [native_buffer_texture getBytes:native_buffer_texture_bytes
                            bytesPerRow:width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height)
                            mipmapLevel:0];
        [adapter_buffer_texture getBytes:adapter_buffer_texture_bytes
                             bytesPerRow:width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height)
                             mipmapLevel:0];

        MTLTextureDescriptor *one_d_array_descriptor = [one_d_descriptor copy];
        one_d_array_descriptor.textureType = MTLTextureType1DArray;
        one_d_array_descriptor.arrayLength = 2;
        id<MTLTexture> native_one_d_array_texture = [device newTextureWithDescriptor:one_d_array_descriptor];
        id<MTLTexture> adapter_one_d_array_texture = [adapter_device newTextureWithDescriptor:one_d_array_descriptor];
        uint8_t one_d_array_bytes[width * 4];
        for (NSUInteger index = 0; index < sizeof(one_d_array_bytes); ++index) {
            one_d_array_bytes[index] = (uint8_t)((index * 43u + 19u) & 0xffu);
        }
        [native_one_d_array_texture replaceRegion:MTLRegionMake1D(0, width)
                                      mipmapLevel:0
                                            slice:1
                                        withBytes:one_d_array_bytes
                                      bytesPerRow:sizeof(one_d_array_bytes)
                                    bytesPerImage:sizeof(one_d_array_bytes)];
        [adapter_one_d_array_texture replaceRegion:MTLRegionMake1D(0, width)
                                       mipmapLevel:0
                                             slice:1
                                         withBytes:one_d_array_bytes
                                       bytesPerRow:sizeof(one_d_array_bytes)
                                     bytesPerImage:sizeof(one_d_array_bytes)];
        uint8_t native_one_d_array_bytes[sizeof(one_d_array_bytes)];
        uint8_t adapter_one_d_array_bytes[sizeof(one_d_array_bytes)];
        [native_one_d_array_texture getBytes:native_one_d_array_bytes
                                  bytesPerRow:sizeof(native_one_d_array_bytes)
                                bytesPerImage:sizeof(native_one_d_array_bytes)
                                 fromRegion:MTLRegionMake1D(0, width)
                                mipmapLevel:0
                                       slice:1];
        [adapter_one_d_array_texture getBytes:adapter_one_d_array_bytes
                                   bytesPerRow:sizeof(adapter_one_d_array_bytes)
                                 bytesPerImage:sizeof(adapter_one_d_array_bytes)
                                  fromRegion:MTLRegionMake1D(0, width)
                                 mipmapLevel:0
                                        slice:1];
        const NSUInteger expected_one_d_array_allocated_size = 2 * width * 4;
        if (native_one_d_texture == nil || adapter_one_d_texture == nil ||
            native_one_d_texture.textureType != MTLTextureType1D ||
            adapter_one_d_texture.textureType != MTLTextureType1D ||
            native_one_d_texture.height != 1 || adapter_one_d_texture.height != 1 ||
            native_one_d_array_texture == nil || adapter_one_d_array_texture == nil ||
            native_one_d_array_texture.textureType != MTLTextureType1DArray ||
            adapter_one_d_array_texture.textureType != MTLTextureType1DArray ||
            native_one_d_array_texture.arrayLength != 2 || adapter_one_d_array_texture.arrayLength != 2 ||
            adapter_one_d_array_texture.allocatedSize != expected_one_d_array_allocated_size ||
            native_buffer_backing == nil || adapter_buffer_backing == nil ||
            native_buffer_texture == nil || adapter_buffer_texture == nil ||
            memcmp(native_one_d_bytes, one_d_bytes, sizeof(one_d_bytes)) != 0 ||
            memcmp(adapter_one_d_bytes, native_one_d_bytes, sizeof(one_d_bytes)) != 0 ||
            memcmp(native_buffer_texture_bytes, buffer_texture_bytes, sizeof(buffer_texture_bytes)) != 0 ||
            memcmp(adapter_buffer_texture_bytes, native_buffer_texture_bytes, sizeof(buffer_texture_bytes)) != 0 ||
            memcmp(native_one_d_array_bytes, one_d_array_bytes, sizeof(one_d_array_bytes)) != 0 ||
            memcmp(adapter_one_d_array_bytes, native_one_d_array_bytes, sizeof(one_d_array_bytes)) != 0) {
            fprintf(stderr, "metal-pixel: 1D texture and 1D-array exactness failed\n");
            return 77;
        }

        /* 3D textures are represented by one CPU/ZPU-owned 2D plane per
         * depth slice. Native Metal supplies the volume byte oracle; every
         * adapter operation below maps the same top-left x/y coordinates and
         * explicit z plane range without creating an MTLTexture. */
        enum {
            three_d_width = 4,
            three_d_height = 3,
            three_d_depth = 3,
            three_d_row_bytes = three_d_width * 4,
            three_d_plane_bytes = three_d_row_bytes * three_d_height,
            three_d_bytes = three_d_plane_bytes * three_d_depth,
            three_d_mip_bytes = 2 * 1 * 1 * 4,
            three_d_copy_width = 3,
            three_d_copy_height = 2,
            three_d_copy_depth = 2,
            three_d_copy_row_bytes = three_d_copy_width * 4,
            three_d_copy_row_stride = 16,
            three_d_copy_image_stride = 32,
            three_d_copy_buffer_length = three_d_copy_image_stride * three_d_copy_depth,
        };
        MTLTextureDescriptor *three_d_descriptor = [MTLTextureDescriptor new];
        three_d_descriptor.textureType = MTLTextureType3D;
        three_d_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        three_d_descriptor.width = three_d_width;
        three_d_descriptor.height = three_d_height;
        three_d_descriptor.depth = three_d_depth;
        three_d_descriptor.arrayLength = 1;
        three_d_descriptor.mipmapLevelCount = 2;
        three_d_descriptor.sampleCount = 1;
        three_d_descriptor.storageMode = MTLStorageModeShared;
        three_d_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_three_d_texture = [device newTextureWithDescriptor:three_d_descriptor];
        id<MTLTexture> adapter_three_d_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        uint8_t three_d_source[three_d_bytes];
        for (NSUInteger index = 0; index < sizeof(three_d_source); ++index) {
            three_d_source[index] = (uint8_t)((index * 31u + 13u) & 0xffu);
        }
        [native_three_d_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                  mipmapLevel:0 slice:0 withBytes:three_d_source
                                  bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        [adapter_three_d_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                   mipmapLevel:0 slice:0 withBytes:three_d_source
                                   bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        uint8_t native_three_d_bytes[three_d_bytes];
        uint8_t adapter_three_d_bytes[three_d_bytes];
        memset(native_three_d_bytes, 0xa5, sizeof(native_three_d_bytes));
        memset(adapter_three_d_bytes, 0xa5, sizeof(adapter_three_d_bytes));
        [native_three_d_texture getBytes:native_three_d_bytes
                            bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                             fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                            mipmapLevel:0 slice:0];
        [adapter_three_d_texture getBytes:adapter_three_d_bytes
                             bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                              fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                             mipmapLevel:0 slice:0];
        enum { three_d_sub_width = 2, three_d_sub_height = 2, three_d_sub_depth = 2,
               three_d_sub_row_bytes = three_d_sub_width * 4,
               three_d_sub_bytes = three_d_sub_row_bytes * three_d_sub_height * three_d_sub_depth };
        uint8_t three_d_sub_source[three_d_sub_bytes];
        for (NSUInteger index = 0; index < sizeof(three_d_sub_source); ++index) {
            three_d_sub_source[index] = (uint8_t)((index * 17u + 91u) & 0xffu);
        }
        const MTLRegion three_d_sub_region = MTLRegionMake3D(1, 1, 1, three_d_sub_width, three_d_sub_height, three_d_sub_depth);
        [native_three_d_texture replaceRegion:three_d_sub_region
                                  mipmapLevel:0 slice:0 withBytes:three_d_sub_source
                                  bytesPerRow:three_d_sub_row_bytes bytesPerImage:three_d_sub_row_bytes * three_d_sub_height];
        [adapter_three_d_texture replaceRegion:three_d_sub_region
                                   mipmapLevel:0 slice:0 withBytes:three_d_sub_source
                                   bytesPerRow:three_d_sub_row_bytes bytesPerImage:three_d_sub_row_bytes * three_d_sub_height];
        uint8_t native_three_d_sub_bytes[sizeof(three_d_sub_source)];
        uint8_t adapter_three_d_sub_bytes[sizeof(three_d_sub_source)];
        memset(native_three_d_sub_bytes, 0xa5, sizeof(native_three_d_sub_bytes));
        memset(adapter_three_d_sub_bytes, 0xa5, sizeof(adapter_three_d_sub_bytes));
        [native_three_d_texture getBytes:native_three_d_sub_bytes
                            bytesPerRow:three_d_sub_row_bytes bytesPerImage:three_d_sub_row_bytes * three_d_sub_height
                             fromRegion:three_d_sub_region
                            mipmapLevel:0 slice:0];
        [adapter_three_d_texture getBytes:adapter_three_d_sub_bytes
                             bytesPerRow:three_d_sub_row_bytes bytesPerImage:three_d_sub_row_bytes * three_d_sub_height
                              fromRegion:three_d_sub_region
                             mipmapLevel:0 slice:0];
        uint8_t native_three_d_mip_bytes[three_d_mip_bytes];
        memset(native_three_d_mip_bytes, 0xa5, sizeof(native_three_d_mip_bytes));
        [native_three_d_texture getBytes:native_three_d_mip_bytes
                            bytesPerRow:2 * 4 bytesPerImage:2 * 4
                             fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                            mipmapLevel:1 slice:0];
        id<MTLTexture> adapter_three_d_view =
            [adapter_three_d_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                         textureType:MTLTextureType3D
                                                              levels:NSMakeRange(1, 1)
                                                              slices:NSMakeRange(0, 1)];
        uint8_t adapter_three_d_view_bytes[three_d_mip_bytes];
        memset(adapter_three_d_view_bytes, 0xa5, sizeof(adapter_three_d_view_bytes));
        [adapter_three_d_view getBytes:adapter_three_d_view_bytes
                            bytesPerRow:2 * 4
                             fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                            mipmapLevel:0];

        id<MTLTexture> native_three_d_copy = [device newTextureWithDescriptor:three_d_descriptor];
        id<MTLTexture> adapter_three_d_copy = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        uint8_t three_d_clear[three_d_bytes] = {0};
        [native_three_d_copy replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                mipmapLevel:0 slice:0 withBytes:three_d_clear
                                bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        [adapter_three_d_copy replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                 mipmapLevel:0 slice:0 withBytes:three_d_clear
                                 bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        const MTLSize three_d_copy_size = MTLSizeMake(three_d_copy_width, three_d_copy_height, three_d_copy_depth);
        const MTLOrigin three_d_copy_source_origin = MTLOriginMake(1, 0, 1);
        const MTLOrigin three_d_copy_destination_origin = MTLOriginMake(0, 1, 0);
        id<MTLCommandBuffer> native_three_d_copy_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_three_d_copy_blit = [native_three_d_copy_command_buffer blitCommandEncoder];
        [native_three_d_copy_blit copyFromTexture:native_three_d_texture
                                       sourceSlice:0
                                       sourceLevel:0
                                      sourceOrigin:three_d_copy_source_origin
                                        sourceSize:three_d_copy_size
                                          toTexture:native_three_d_copy
                                   destinationSlice:0
                                   destinationLevel:0
                                  destinationOrigin:three_d_copy_destination_origin];
        [native_three_d_copy_blit endEncoding];
        [native_three_d_copy_command_buffer commit];
        [native_three_d_copy_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_three_d_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_three_d_copy_blit = [adapter_three_d_copy_command_buffer blitCommandEncoder];
        [adapter_three_d_copy_blit copyFromTexture:adapter_three_d_texture
                                       sourceSlice:0
                                       sourceLevel:0
                                      sourceOrigin:three_d_copy_source_origin
                                        sourceSize:three_d_copy_size
                                          toTexture:adapter_three_d_copy
                                   destinationSlice:0
                                   destinationLevel:0
                                  destinationOrigin:three_d_copy_destination_origin];
        [adapter_three_d_copy_blit endEncoding];
        [adapter_three_d_copy_command_buffer commit];
        [adapter_three_d_copy_command_buffer waitUntilCompleted];
        uint8_t native_three_d_copy_bytes[three_d_bytes];
        uint8_t adapter_three_d_copy_bytes[three_d_bytes];
        memset(native_three_d_copy_bytes, 0xa5, sizeof(native_three_d_copy_bytes));
        memset(adapter_three_d_copy_bytes, 0xa5, sizeof(adapter_three_d_copy_bytes));
        [native_three_d_copy getBytes:native_three_d_copy_bytes
                          bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                           fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                          mipmapLevel:0 slice:0];
        [adapter_three_d_copy getBytes:adapter_three_d_copy_bytes
                           bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                            fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                           mipmapLevel:0 slice:0];

        id<MTLBuffer> native_three_d_to_buffer =
            [device newBufferWithLength:three_d_copy_buffer_length options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_three_d_to_buffer =
            [adapter_device newBufferWithLength:three_d_copy_buffer_length options:MTLResourceStorageModeShared];
        if (native_three_d_to_buffer != nil) memset(native_three_d_to_buffer.contents, 0xcd, native_three_d_to_buffer.length);
        if (adapter_three_d_to_buffer != nil) memset(adapter_three_d_to_buffer.contents, 0xcd, adapter_three_d_to_buffer.length);
        id<MTLCommandBuffer> native_three_d_to_buffer_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_three_d_to_buffer_blit = [native_three_d_to_buffer_command_buffer blitCommandEncoder];
        [native_three_d_to_buffer_blit copyFromTexture:native_three_d_texture
                                           sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(1, 0, 1)
                                           sourceSize:three_d_copy_size toBuffer:native_three_d_to_buffer
                                      destinationOffset:0 destinationBytesPerRow:three_d_copy_row_stride
                                    destinationBytesPerImage:three_d_copy_image_stride];
        [native_three_d_to_buffer_blit endEncoding];
        [native_three_d_to_buffer_command_buffer commit];
        [native_three_d_to_buffer_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_three_d_to_buffer_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_three_d_to_buffer_blit = [adapter_three_d_to_buffer_command_buffer blitCommandEncoder];
        [adapter_three_d_to_buffer_blit copyFromTexture:adapter_three_d_texture
                                            sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(1, 0, 1)
                                            sourceSize:three_d_copy_size toBuffer:adapter_three_d_to_buffer
                                       destinationOffset:0 destinationBytesPerRow:three_d_copy_row_stride
                                     destinationBytesPerImage:three_d_copy_image_stride];
        [adapter_three_d_to_buffer_blit endEncoding];
        [adapter_three_d_to_buffer_command_buffer commit];
        [adapter_three_d_to_buffer_command_buffer waitUntilCompleted];

        enum { three_d_upload_offset = 4, three_d_upload_buffer_length = three_d_upload_offset + three_d_copy_buffer_length };
        id<MTLBuffer> native_three_d_upload_buffer =
            [device newBufferWithLength:three_d_upload_buffer_length options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_three_d_upload_buffer =
            [adapter_device newBufferWithLength:three_d_upload_buffer_length options:MTLResourceStorageModeShared];
        uint8_t three_d_upload_bytes[three_d_copy_buffer_length];
        for (NSUInteger index = 0; index < sizeof(three_d_upload_bytes); ++index) {
            three_d_upload_bytes[index] = (uint8_t)((index * 23u + 47u) & 0xffu);
        }
        if (native_three_d_upload_buffer != nil) {
            memset(native_three_d_upload_buffer.contents, 0xee, native_three_d_upload_buffer.length);
            memcpy((uint8_t *)native_three_d_upload_buffer.contents + three_d_upload_offset,
                   three_d_upload_bytes, sizeof(three_d_upload_bytes));
        }
        if (adapter_three_d_upload_buffer != nil) {
            memset(adapter_three_d_upload_buffer.contents, 0xee, adapter_three_d_upload_buffer.length);
            memcpy((uint8_t *)adapter_three_d_upload_buffer.contents + three_d_upload_offset,
                   three_d_upload_bytes, sizeof(three_d_upload_bytes));
        }
        id<MTLTexture> native_three_d_upload_texture = [device newTextureWithDescriptor:three_d_descriptor];
        id<MTLTexture> adapter_three_d_upload_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        [native_three_d_upload_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                          mipmapLevel:0 slice:0 withBytes:three_d_clear
                                          bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        [adapter_three_d_upload_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                           mipmapLevel:0 slice:0 withBytes:three_d_clear
                                           bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        id<MTLCommandBuffer> native_three_d_upload_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_three_d_upload_blit = [native_three_d_upload_command_buffer blitCommandEncoder];
        [native_three_d_upload_blit copyFromBuffer:native_three_d_upload_buffer sourceOffset:three_d_upload_offset
                                  sourceBytesPerRow:three_d_copy_row_stride sourceBytesPerImage:three_d_copy_image_stride
                                         sourceSize:three_d_copy_size toTexture:native_three_d_upload_texture
                                    destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 1, 0)];
        [native_three_d_upload_blit endEncoding];
        [native_three_d_upload_command_buffer commit];
        [native_three_d_upload_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_three_d_upload_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_three_d_upload_blit = [adapter_three_d_upload_command_buffer blitCommandEncoder];
        [adapter_three_d_upload_blit copyFromBuffer:adapter_three_d_upload_buffer sourceOffset:three_d_upload_offset
                                   sourceBytesPerRow:three_d_copy_row_stride sourceBytesPerImage:three_d_copy_image_stride
                                          sourceSize:three_d_copy_size toTexture:adapter_three_d_upload_texture
                                     destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 1, 0)];
        [adapter_three_d_upload_blit endEncoding];
        [adapter_three_d_upload_command_buffer commit];
        [adapter_three_d_upload_command_buffer waitUntilCompleted];
        uint8_t native_three_d_upload_texture_bytes[three_d_bytes];
        uint8_t adapter_three_d_upload_texture_bytes[three_d_bytes];
        memset(native_three_d_upload_texture_bytes, 0xa5, sizeof(native_three_d_upload_texture_bytes));
        memset(adapter_three_d_upload_texture_bytes, 0xa5, sizeof(adapter_three_d_upload_texture_bytes));
        [native_three_d_upload_texture getBytes:native_three_d_upload_texture_bytes
                                    bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                     fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                    mipmapLevel:0 slice:0];
        [adapter_three_d_upload_texture getBytes:adapter_three_d_upload_texture_bytes
                                     bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                      fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                     mipmapLevel:0 slice:0];

        id<MTLTexture> native_three_d_mipmap_texture = [device newTextureWithDescriptor:three_d_descriptor];
        id<MTLTexture> adapter_three_d_mipmap_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        [native_three_d_mipmap_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                          mipmapLevel:0 slice:0 withBytes:three_d_source
                                          bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        [adapter_three_d_mipmap_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                           mipmapLevel:0 slice:0 withBytes:three_d_source
                                           bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        id<MTLCommandBuffer> native_three_d_mipmap_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_three_d_mipmap_blit = [native_three_d_mipmap_command_buffer blitCommandEncoder];
        [native_three_d_mipmap_blit generateMipmapsForTexture:native_three_d_mipmap_texture];
        [native_three_d_mipmap_blit endEncoding];
        [native_three_d_mipmap_command_buffer commit];
        [native_three_d_mipmap_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_three_d_mipmap_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_three_d_mipmap_blit = [adapter_three_d_mipmap_command_buffer blitCommandEncoder];
        [adapter_three_d_mipmap_blit generateMipmapsForTexture:adapter_three_d_mipmap_texture];
        [adapter_three_d_mipmap_blit endEncoding];
        uint8_t adapter_three_d_mipmap_deferred[three_d_mip_bytes];
        memset(adapter_three_d_mipmap_deferred, 0xa5, sizeof(adapter_three_d_mipmap_deferred));
        [adapter_three_d_mipmap_texture getBytes:adapter_three_d_mipmap_deferred
                                      bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                       fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                                      mipmapLevel:1 slice:0];
        [adapter_three_d_mipmap_command_buffer commit];
        [adapter_three_d_mipmap_command_buffer waitUntilCompleted];
        uint8_t native_three_d_mipmap_level_one[three_d_mip_bytes];
        uint8_t adapter_three_d_mipmap_level_one[three_d_mip_bytes];
        memset(native_three_d_mipmap_level_one, 0xa5, sizeof(native_three_d_mipmap_level_one));
        memset(adapter_three_d_mipmap_level_one, 0xa5, sizeof(adapter_three_d_mipmap_level_one));
        [native_three_d_mipmap_texture getBytes:native_three_d_mipmap_level_one
                                      bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                       fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                                      mipmapLevel:1 slice:0];
        [adapter_three_d_mipmap_texture getBytes:adapter_three_d_mipmap_level_one
                                       bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                        fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                                       mipmapLevel:1 slice:0];

        MTLSizeAndAlign three_d_heap_size_align =
            [adapter_device heapTextureSizeAndAlignWithDescriptor:three_d_descriptor];
        MTLHeapDescriptor *three_d_heap_descriptor = [MTLHeapDescriptor new];
        three_d_heap_descriptor.size = three_d_heap_size_align.size;
        three_d_heap_descriptor.storageMode = MTLStorageModeShared;
        id<MTLHeap> adapter_three_d_heap = [adapter_device newHeapWithDescriptor:three_d_heap_descriptor];
        id<MTLTexture> adapter_three_d_heap_texture =
            [adapter_three_d_heap newTextureWithDescriptor:three_d_descriptor];
        const NSUInteger expected_three_d_allocated_size = three_d_bytes + three_d_mip_bytes;
        if (native_three_d_texture == nil || adapter_three_d_texture == nil ||
            native_three_d_texture.textureType != MTLTextureType3D || adapter_three_d_texture.textureType != MTLTextureType3D ||
            native_three_d_texture.width != three_d_width || adapter_three_d_texture.width != three_d_width ||
            native_three_d_texture.height != three_d_height || adapter_three_d_texture.height != three_d_height ||
            native_three_d_texture.depth != three_d_depth || adapter_three_d_texture.depth != three_d_depth ||
            native_three_d_texture.arrayLength != 1 || adapter_three_d_texture.arrayLength != 1 ||
            adapter_three_d_texture.mipmapLevelCount != 2 ||
            adapter_three_d_texture.allocatedSize != expected_three_d_allocated_size ||
            memcmp(native_three_d_bytes, adapter_three_d_bytes, sizeof(native_three_d_bytes)) != 0 ||
            memcmp(native_three_d_sub_bytes, adapter_three_d_sub_bytes, sizeof(native_three_d_sub_bytes)) != 0 ||
            adapter_three_d_view == nil || adapter_three_d_view.depth != 1 || adapter_three_d_view.width != 2 ||
            adapter_three_d_view.height != 1 || adapter_three_d_view.mipmapLevelCount != 1 ||
            memcmp(native_three_d_mip_bytes, adapter_three_d_view_bytes, sizeof(native_three_d_mip_bytes)) != 0 ||
            native_three_d_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_three_d_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_three_d_copy_bytes, adapter_three_d_copy_bytes, sizeof(native_three_d_copy_bytes)) != 0 ||
            native_three_d_to_buffer == nil || adapter_three_d_to_buffer == nil ||
            native_three_d_to_buffer_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_three_d_to_buffer_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_three_d_to_buffer.contents, adapter_three_d_to_buffer.contents, three_d_copy_buffer_length) != 0 ||
            native_three_d_upload_buffer == nil || adapter_three_d_upload_buffer == nil ||
            native_three_d_upload_texture == nil || adapter_three_d_upload_texture == nil ||
            native_three_d_upload_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_three_d_upload_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_three_d_upload_texture_bytes, adapter_three_d_upload_texture_bytes,
                   sizeof(native_three_d_upload_texture_bytes)) != 0 ||
            native_three_d_mipmap_texture == nil || adapter_three_d_mipmap_texture == nil ||
            native_three_d_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_three_d_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(adapter_three_d_mipmap_deferred, (const uint8_t[three_d_mip_bytes]){0}, three_d_mip_bytes) != 0 ||
            memcmp(native_three_d_mipmap_level_one, adapter_three_d_mipmap_level_one,
                   sizeof(native_three_d_mipmap_level_one)) != 0 ||
            three_d_heap_size_align.size != expected_three_d_allocated_size || three_d_heap_size_align.align != 4 ||
            adapter_three_d_heap == nil || adapter_three_d_heap_texture == nil ||
            adapter_three_d_heap_texture.depth != three_d_depth ||
            adapter_three_d_heap_texture.allocatedSize != expected_three_d_allocated_size ||
            adapter_three_d_heap.usedSize != expected_three_d_allocated_size) {
            fprintf(stderr, "metal-pixel: 3D texture bytes/view/heap/blit exactness failed\n");
            return 81;
        }

        enum { fractional_three_d_width = 5, fractional_three_d_height = 3, fractional_three_d_depth = 5,
               fractional_three_d_row_bytes = fractional_three_d_width * 4,
               fractional_three_d_plane_bytes = fractional_three_d_row_bytes * fractional_three_d_height,
               fractional_three_d_bytes = fractional_three_d_plane_bytes * fractional_three_d_depth,
               fractional_three_d_mip_bytes = 2 * 1 * 2 * 4 };
        MTLTextureDescriptor *fractional_three_d_descriptor = [MTLTextureDescriptor new];
        fractional_three_d_descriptor.textureType = MTLTextureType3D;
        fractional_three_d_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        fractional_three_d_descriptor.width = fractional_three_d_width;
        fractional_three_d_descriptor.height = fractional_three_d_height;
        fractional_three_d_descriptor.depth = fractional_three_d_depth;
        fractional_three_d_descriptor.arrayLength = 1;
        fractional_three_d_descriptor.mipmapLevelCount = 2;
        fractional_three_d_descriptor.sampleCount = 1;
        fractional_three_d_descriptor.storageMode = MTLStorageModeShared;
        fractional_three_d_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_fractional_three_d = [device newTextureWithDescriptor:fractional_three_d_descriptor];
        id<MTLTexture> adapter_fractional_three_d = [adapter_device newTextureWithDescriptor:fractional_three_d_descriptor];
        uint8_t fractional_three_d_source[fractional_three_d_bytes];
        for (NSUInteger index = 0; index < sizeof(fractional_three_d_source); ++index) {
            fractional_three_d_source[index] = (uint8_t)((index * 19u + 23u) & 0xffu);
        }
        [native_fractional_three_d replaceRegion:MTLRegionMake3D(0, 0, 0, fractional_three_d_width,
                                                                  fractional_three_d_height, fractional_three_d_depth)
                                      mipmapLevel:0 slice:0 withBytes:fractional_three_d_source
                                      bytesPerRow:fractional_three_d_row_bytes bytesPerImage:fractional_three_d_plane_bytes];
        [adapter_fractional_three_d replaceRegion:MTLRegionMake3D(0, 0, 0, fractional_three_d_width,
                                                                   fractional_three_d_height, fractional_three_d_depth)
                                       mipmapLevel:0 slice:0 withBytes:fractional_three_d_source
                                       bytesPerRow:fractional_three_d_row_bytes bytesPerImage:fractional_three_d_plane_bytes];
        id<MTLCommandBuffer> native_fractional_three_d_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_fractional_three_d_blit =
            [native_fractional_three_d_command_buffer blitCommandEncoder];
        [native_fractional_three_d_blit generateMipmapsForTexture:native_fractional_three_d];
        [native_fractional_three_d_blit endEncoding];
        [native_fractional_three_d_command_buffer commit];
        [native_fractional_three_d_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_fractional_three_d_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_fractional_three_d_blit =
            [adapter_fractional_three_d_command_buffer blitCommandEncoder];
        [adapter_fractional_three_d_blit generateMipmapsForTexture:adapter_fractional_three_d];
        [adapter_fractional_three_d_blit endEncoding];
        [adapter_fractional_three_d_command_buffer commit];
        [adapter_fractional_three_d_command_buffer waitUntilCompleted];
        uint8_t native_fractional_three_d_mip[fractional_three_d_mip_bytes];
        uint8_t adapter_fractional_three_d_mip[fractional_three_d_mip_bytes];
        [native_fractional_three_d getBytes:native_fractional_three_d_mip
                                bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                 fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 2)
                                mipmapLevel:1 slice:0];
        [adapter_fractional_three_d getBytes:adapter_fractional_three_d_mip
                                 bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                  fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 2)
                                 mipmapLevel:1 slice:0];
        if (native_fractional_three_d == nil || adapter_fractional_three_d == nil ||
            native_fractional_three_d_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_fractional_three_d_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_fractional_three_d_mip, adapter_fractional_three_d_mip,
                   sizeof(native_fractional_three_d_mip)) != 0) {
            fprintf(stderr, "metal-pixel: fractional 3D mipmap exactness failed\n");
            return 86;
        }
        MTLTextureDescriptor *array_render_descriptor = [array_descriptor copy];
        array_render_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> native_array_render_texture = [device newTextureWithDescriptor:array_render_descriptor];
        id<MTLTexture> adapter_array_render_texture = [adapter_device newTextureWithDescriptor:array_render_descriptor];
        MTLRenderPassDescriptor *native_array_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_array_render_pass.colorAttachments[0].texture = native_array_render_texture;
        native_array_render_pass.colorAttachments[0].level = 1;
        native_array_render_pass.colorAttachments[0].slice = 1;
        native_array_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_array_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_array_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> native_array_render_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_array_render_encoder =
            [native_array_render_command_buffer renderCommandEncoderWithDescriptor:native_array_render_pass];
        [native_array_render_encoder setRenderPipelineState:pipeline];
        [native_array_render_encoder setVertexBuffer:native_mip_render_vertex_buffer offset:0 atIndex:0];
        [native_array_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_array_render_encoder endEncoding];
        [native_array_render_command_buffer commit];
        [native_array_render_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_array_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_array_render_pass.colorAttachments[0].texture = adapter_array_render_texture;
        adapter_array_render_pass.colorAttachments[0].level = 1;
        adapter_array_render_pass.colorAttachments[0].slice = 1;
        adapter_array_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_array_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_array_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_array_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_array_render_encoder =
            [adapter_array_render_command_buffer renderCommandEncoderWithDescriptor:adapter_array_render_pass];
        [adapter_array_render_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_array_render_encoder setVertexBuffer:adapter_mip_render_vertex_buffer offset:0 atIndex:0];
        [adapter_array_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_array_render_encoder endEncoding];
        [adapter_array_render_command_buffer commit];
        [adapter_array_render_command_buffer waitUntilCompleted];
        uint8_t native_array_render_pixels[2 * 2 * 4];
        uint8_t adapter_array_render_pixels[2 * 2 * 4];
        [native_array_render_texture getBytes:native_array_render_pixels
                                  bytesPerRow:2 * 4
                                bytesPerImage:sizeof(native_array_render_pixels)
                                 fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                mipmapLevel:1
                                       slice:1];
        [adapter_array_render_texture getBytes:adapter_array_render_pixels
                                   bytesPerRow:2 * 4
                                 bytesPerImage:sizeof(adapter_array_render_pixels)
                                  fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                 mipmapLevel:1
                                        slice:1];
        if (native_array_render_texture == nil || adapter_array_render_texture == nil ||
            native_array_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_array_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_array_render_pixels, adapter_array_render_pixels, sizeof(native_array_render_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: 2D-array slice/level render exactness failed\n");
            return 77;
        }

        id<MTLTexture> native_array_mipmap_texture = [device newTextureWithDescriptor:array_descriptor];
        id<MTLTexture> adapter_array_mipmap_texture = [adapter_device newTextureWithDescriptor:array_descriptor];
        uint8_t array_mipmap_base[2][4 * 4 * 4];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            for (NSUInteger index = 0; index < sizeof(array_mipmap_base[slice]); ++index) {
                array_mipmap_base[slice][index] = (uint8_t)((index * 37u + slice * 61u + 11u) & 0xffu);
            }
            [native_array_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                                          mipmapLevel:0
                                                slice:slice
                                            withBytes:array_mipmap_base[slice]
                                          bytesPerRow:4 * 4
                                        bytesPerImage:4 * 4 * 4];
            [adapter_array_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                                           mipmapLevel:0
                                                 slice:slice
                                             withBytes:array_mipmap_base[slice]
                                           bytesPerRow:4 * 4
                                         bytesPerImage:4 * 4 * 4];
        }
        id<MTLCommandBuffer> native_array_mipmap_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_array_mipmap_blit = [native_array_mipmap_command_buffer blitCommandEncoder];
        [native_array_mipmap_blit generateMipmapsForTexture:native_array_mipmap_texture];
        [native_array_mipmap_blit endEncoding];
        [native_array_mipmap_command_buffer commit];
        [native_array_mipmap_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_array_mipmap_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_array_mipmap_blit = [adapter_array_mipmap_command_buffer blitCommandEncoder];
        [adapter_array_mipmap_blit generateMipmapsForTexture:adapter_array_mipmap_texture];
        [adapter_array_mipmap_blit endEncoding];
        uint8_t adapter_array_deferred_mip_level_one[2][2 * 2 * 4];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [adapter_array_mipmap_texture getBytes:adapter_array_deferred_mip_level_one[slice]
                                      bytesPerRow:2 * 4
                                    bytesPerImage:2 * 2 * 4
                                     fromRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 1)
                                    mipmapLevel:1
                                           slice:slice];
        }
        [adapter_array_mipmap_command_buffer commit];
        [adapter_array_mipmap_command_buffer waitUntilCompleted];
        uint8_t native_array_mip_level_one[2][2 * 2 * 4];
        uint8_t adapter_array_mip_level_one[2][2 * 2 * 4];
        uint8_t native_array_mip_level_two[2][4];
        uint8_t adapter_array_mip_level_two[2][4];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [native_array_mipmap_texture getBytes:native_array_mip_level_one[slice]
                                     bytesPerRow:2 * 4
                                   bytesPerImage:2 * 2 * 4
                                    fromRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 1)
                                   mipmapLevel:1
                                          slice:slice];
            [adapter_array_mipmap_texture getBytes:adapter_array_mip_level_one[slice]
                                      bytesPerRow:2 * 4
                                    bytesPerImage:2 * 2 * 4
                                     fromRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 1)
                                    mipmapLevel:1
                                           slice:slice];
            [native_array_mipmap_texture getBytes:native_array_mip_level_two[slice]
                                     bytesPerRow:4
                                   bytesPerImage:4
                                    fromRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
                                   mipmapLevel:2
                                          slice:slice];
            [adapter_array_mipmap_texture getBytes:adapter_array_mip_level_two[slice]
                                      bytesPerRow:4
                                    bytesPerImage:4
                                     fromRegion:MTLRegionMake3D(0, 0, 0, 1, 1, 1)
                                    mipmapLevel:2
                                           slice:slice];
        }
        BOOL array_mipmap_exact = native_array_mipmap_texture != nil && adapter_array_mipmap_texture != nil &&
            native_array_mipmap_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_array_mipmap_command_buffer.status == MTLCommandBufferStatusCompleted;
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            array_mipmap_exact = array_mipmap_exact &&
                memcmp(adapter_array_deferred_mip_level_one[slice], (const uint8_t[2 * 2 * 4]){0}, 2 * 2 * 4) == 0 &&
                memcmp(native_array_mip_level_one[slice], adapter_array_mip_level_one[slice], 2 * 2 * 4) == 0 &&
                memcmp(native_array_mip_level_two[slice], adapter_array_mip_level_two[slice], 4) == 0;
        }
        if (!array_mipmap_exact) {
            fprintf(stderr, "metal-pixel: 2D-array mipmap generation exactness failed\n");
            return 78;
        }

        /* Float mipmaps must use the same footprint and IEEE storage as the
         * Apple blit path. Compare raw level-one bytes for both formats. */
        enum { float_mipmap_width = 4, float_mipmap_height = 4 };
        float r32_mipmap_source[float_mipmap_width * float_mipmap_height];
        for (NSUInteger index = 0; index < sizeof(r32_mipmap_source) / sizeof(r32_mipmap_source[0]); ++index) {
            r32_mipmap_source[index] = (float)index * 0.75f - 1.25f;
        }
        uint16_t rgba16_mipmap_source[float_mipmap_width * float_mipmap_height * 4];
        for (NSUInteger index = 0; index < sizeof(rgba16_mipmap_source) / sizeof(rgba16_mipmap_source[0]); index += 4) {
            rgba16_mipmap_source[index + 0] = 0x3c00; /* 1.0 */
            rgba16_mipmap_source[index + 1] = 0x4000; /* 2.0 */
            rgba16_mipmap_source[index + 2] = 0x3800; /* 0.5 */
            rgba16_mipmap_source[index + 3] = 0x3c00; /* 1.0 */
        }
        MTLTextureDescriptor *native_r32_mipmap_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                width:float_mipmap_width
                                                               height:float_mipmap_height
                                                            mipmapped:YES];
        native_r32_mipmap_descriptor.storageMode = MTLStorageModeShared;
        native_r32_mipmap_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        MTLTextureDescriptor *adapter_r32_mipmap_descriptor = [native_r32_mipmap_descriptor copy];
        id<MTLTexture> native_r32_mipmap_texture = [device newTextureWithDescriptor:native_r32_mipmap_descriptor];
        id<MTLTexture> adapter_r32_mipmap_texture = [adapter_device newTextureWithDescriptor:adapter_r32_mipmap_descriptor];
        [native_r32_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, float_mipmap_width, float_mipmap_height)
                                      mipmapLevel:0 withBytes:r32_mipmap_source bytesPerRow:float_mipmap_width * sizeof(float)];
        [adapter_r32_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, float_mipmap_width, float_mipmap_height)
                                       mipmapLevel:0 withBytes:r32_mipmap_source bytesPerRow:float_mipmap_width * sizeof(float)];
        id<MTLCommandBuffer> native_r32_mipmap_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_r32_mipmap_blit = [native_r32_mipmap_command_buffer blitCommandEncoder];
        [native_r32_mipmap_blit generateMipmapsForTexture:native_r32_mipmap_texture];
        [native_r32_mipmap_blit endEncoding];
        [native_r32_mipmap_command_buffer commit];
        [native_r32_mipmap_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_r32_mipmap_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_r32_mipmap_blit = [adapter_r32_mipmap_command_buffer blitCommandEncoder];
        [adapter_r32_mipmap_blit generateMipmapsForTexture:adapter_r32_mipmap_texture];
        [adapter_r32_mipmap_blit endEncoding];
        [adapter_r32_mipmap_command_buffer commit];
        [adapter_r32_mipmap_command_buffer waitUntilCompleted];
        uint8_t native_r32_mipmap_level_one[2 * 2 * sizeof(float)];
        uint8_t adapter_r32_mipmap_level_one[2 * 2 * sizeof(float)];
        [native_r32_mipmap_texture getBytes:native_r32_mipmap_level_one bytesPerRow:2 * sizeof(float)
                                 fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1];
        [adapter_r32_mipmap_texture getBytes:adapter_r32_mipmap_level_one bytesPerRow:2 * sizeof(float)
                                  fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1];

        MTLTextureDescriptor *native_rgba16_mipmap_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                width:float_mipmap_width
                                                               height:float_mipmap_height
                                                            mipmapped:YES];
        native_rgba16_mipmap_descriptor.storageMode = MTLStorageModeShared;
        native_rgba16_mipmap_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        MTLTextureDescriptor *adapter_rgba16_mipmap_descriptor = [native_rgba16_mipmap_descriptor copy];
        id<MTLTexture> native_rgba16_mipmap_texture = [device newTextureWithDescriptor:native_rgba16_mipmap_descriptor];
        id<MTLTexture> adapter_rgba16_mipmap_texture = [adapter_device newTextureWithDescriptor:adapter_rgba16_mipmap_descriptor];
        [native_rgba16_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, float_mipmap_width, float_mipmap_height)
                                         mipmapLevel:0 withBytes:rgba16_mipmap_source
                                       bytesPerRow:float_mipmap_width * 4 * sizeof(uint16_t)];
        [adapter_rgba16_mipmap_texture replaceRegion:MTLRegionMake2D(0, 0, float_mipmap_width, float_mipmap_height)
                                          mipmapLevel:0 withBytes:rgba16_mipmap_source
                                        bytesPerRow:float_mipmap_width * 4 * sizeof(uint16_t)];
        id<MTLCommandBuffer> native_rgba16_mipmap_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_rgba16_mipmap_blit = [native_rgba16_mipmap_command_buffer blitCommandEncoder];
        [native_rgba16_mipmap_blit generateMipmapsForTexture:native_rgba16_mipmap_texture];
        [native_rgba16_mipmap_blit endEncoding];
        [native_rgba16_mipmap_command_buffer commit];
        [native_rgba16_mipmap_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_rgba16_mipmap_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_rgba16_mipmap_blit = [adapter_rgba16_mipmap_command_buffer blitCommandEncoder];
        [adapter_rgba16_mipmap_blit generateMipmapsForTexture:adapter_rgba16_mipmap_texture];
        [adapter_rgba16_mipmap_blit endEncoding];
        [adapter_rgba16_mipmap_command_buffer commit];
        [adapter_rgba16_mipmap_command_buffer waitUntilCompleted];
        uint8_t native_rgba16_mipmap_level_one[2 * 2 * 8];
        uint8_t adapter_rgba16_mipmap_level_one[2 * 2 * 8];
        [native_rgba16_mipmap_texture getBytes:native_rgba16_mipmap_level_one bytesPerRow:2 * 8
                                    fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1];
        [adapter_rgba16_mipmap_texture getBytes:adapter_rgba16_mipmap_level_one bytesPerRow:2 * 8
                                     fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:1];
        if (native_r32_mipmap_texture == nil || adapter_r32_mipmap_texture == nil ||
            native_r32_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_r32_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_r32_mipmap_level_one, adapter_r32_mipmap_level_one,
                   sizeof(native_r32_mipmap_level_one)) != 0 ||
            native_rgba16_mipmap_texture == nil || adapter_rgba16_mipmap_texture == nil ||
            native_rgba16_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_rgba16_mipmap_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_rgba16_mipmap_level_one, adapter_rgba16_mipmap_level_one,
                   sizeof(native_rgba16_mipmap_level_one)) != 0) {
            fprintf(stderr, "metal-pixel: float mipmap generation exactness failed\n");
            return 85;
        }

        /* Library/function discovery is also CPU metadata. The source text
         * is inspected only for registered ZPU kernel names; it is never sent
         * to Apple's compiler by the adapter. */
        NSError *adapter_library_error = nil;
        NSString *adapter_cpu_source =
            @"kernel void zpu_cpu_fill_gradient_rgba8() {}\n"
             "kernel void zpu_cpu_copy_rgba8_buffer_to_texture() {}\n"
             "kernel void zpu_cpu_fill_gradient_rgba8_array() {}\n"
             "kernel void zpu_cpu_fill_gradient_rgba8_3d() {}";
        id<MTLLibrary> adapter_library =
            [adapter_device newLibraryWithSource:adapter_cpu_source options:nil error:&adapter_library_error];
        id<MTLFunction> adapter_library_function =
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLFunction> adapter_constant_function =
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"
                                  constantValues:[MTLFunctionConstantValues new]
                                             error:&adapter_library_error];
        __block BOOL adapter_library_completion_called = NO;
        [adapter_device newLibraryWithSource:adapter_cpu_source options:nil completionHandler:^(id<MTLLibrary> library, NSError *library_error) {
            adapter_library_completion_called = library != nil && library_error == nil;
        }];
        id<MTLLibrary> unsupported_adapter_library =
            [adapter_device newLibraryWithSource:@"kernel void arbitrary_msl() {}" options:nil error:&adapter_library_error];
        if (adapter_library == nil || adapter_library_function == nil ||
            adapter_constant_function == nil ||
            ![adapter_library_function.name isEqualToString:@"zpu_cpu_fill_gradient_rgba8"] ||
            adapter_library_function.functionType != MTLFunctionTypeKernel ||
            adapter_library.functionNames.count != 4 ||
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_array"] == nil ||
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_3d"] == nil ||
            !adapter_library_completion_called ||
            unsupported_adapter_library != nil || adapter_library_error == nil) {
            fail_with_error("CPU library/function metadata failed", adapter_library_error);
            return 50;
        }

        NSURL *adapter_source_url = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
        NSError *adapter_source_error = nil;
        BOOL adapter_source_written = [adapter_cpu_source writeToURL:adapter_source_url
                                                            atomically:YES
                                                              encoding:NSUTF8StringEncoding
                                                                 error:&adapter_source_error];
        #pragma clang diagnostic push
        #pragma clang diagnostic ignored "-Wdeprecated-declarations"
        id<MTLLibrary> adapter_file_library =
            [adapter_device newLibraryWithFile:adapter_source_url.path error:&adapter_source_error];
        #pragma clang diagnostic pop
        id<MTLLibrary> adapter_url_library =
            [adapter_device newLibraryWithURL:adapter_source_url error:&adapter_source_error];
        dispatch_data_t adapter_source_data = dispatch_data_create(
            adapter_cpu_source.UTF8String,
            [adapter_cpu_source lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
            dispatch_get_main_queue(), DISPATCH_DATA_DESTRUCTOR_DEFAULT);
        id<MTLLibrary> adapter_data_library =
            [adapter_device newLibraryWithData:adapter_source_data error:&adapter_source_error];
        id<MTLLibrary> adapter_bundle_library =
            [adapter_device newDefaultLibraryWithBundle:[NSBundle mainBundle] error:&adapter_source_error];
        [[NSFileManager defaultManager] removeItemAtURL:adapter_source_url error:nil];
        if (!adapter_source_written || adapter_file_library == nil || adapter_url_library == nil ||
            adapter_data_library == nil || adapter_bundle_library == nil ||
            [adapter_file_library newFunctionWithName:@"zpu_cpu_copy_rgba8_buffer_to_texture"] == nil ||
            [adapter_url_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"] == nil ||
            [adapter_data_library newFunctionWithName:@"zpu_cpu_copy_rgba8_buffer_to_texture"] == nil ||
            [adapter_bundle_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"] == nil) {
            fail_with_error("CPU library file/data loading failed", adapter_source_error);
            return 65;
        }

        /* Binary archives remain CPU metadata caches. They persist only the
         * registered ZPU function names and never contain native Metal code. */
        NSError *adapter_archive_error = nil;
        MTLBinaryArchiveDescriptor *adapter_archive_descriptor = [MTLBinaryArchiveDescriptor new];
        id<MTLBinaryArchive> adapter_archive =
            [adapter_device newBinaryArchiveWithDescriptor:adapter_archive_descriptor error:&adapter_archive_error];
        MTLComputePipelineDescriptor *adapter_archive_compute_descriptor = [MTLComputePipelineDescriptor new];
        adapter_archive_compute_descriptor.computeFunction = adapter_library_function;
        MTLRenderPipelineDescriptor *adapter_archive_render_descriptor = [MTLRenderPipelineDescriptor new];
        adapter_archive_render_descriptor.vertexFunction = adapter_vertex_function;
        adapter_archive_render_descriptor.fragmentFunction = adapter_fragment_function;
        adapter_archive_render_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        BOOL adapter_archive_compute_added =
            [adapter_archive addComputePipelineFunctionsWithDescriptor:adapter_archive_compute_descriptor
                                                                   error:&adapter_archive_error];
        BOOL adapter_archive_render_added =
            [adapter_archive addRenderPipelineFunctionsWithDescriptor:adapter_archive_render_descriptor
                                                                  error:&adapter_archive_error];
        NSURL *adapter_archive_url = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
        BOOL adapter_archive_serialized = [adapter_archive serializeToURL:adapter_archive_url error:&adapter_archive_error];
        MTLBinaryArchiveDescriptor *adapter_reload_descriptor = [MTLBinaryArchiveDescriptor new];
        adapter_reload_descriptor.url = adapter_archive_url;
        id<MTLBinaryArchive> adapter_reloaded_archive =
            [adapter_device newBinaryArchiveWithDescriptor:adapter_reload_descriptor error:&adapter_archive_error];
        BOOL adapter_archive_reloaded =
            [adapter_reloaded_archive addComputePipelineFunctionsWithDescriptor:adapter_archive_compute_descriptor
                                                                             error:&adapter_archive_error];
        id<MTL4Archive> adapter_mtl4_archive =
            [adapter_device newArchiveWithURL:adapter_archive_url error:&adapter_archive_error];
        MTL4LibraryFunctionDescriptor *adapter_archive_function_descriptor = [MTL4LibraryFunctionDescriptor new];
        adapter_archive_function_descriptor.name = @"zpu_cpu_fill_gradient_rgba8";
        adapter_archive_function_descriptor.library = adapter_library;
        MTL4BinaryFunctionDescriptor *adapter_archive_binary_descriptor = [MTL4BinaryFunctionDescriptor new];
        adapter_archive_binary_descriptor.name = @"zpu_cpu_fill_gradient_rgba8";
        adapter_archive_binary_descriptor.functionDescriptor = adapter_archive_function_descriptor;
        id<MTL4BinaryFunction> adapter_archive_binary_function =
            [adapter_mtl4_archive newBinaryFunctionWithDescriptor:adapter_archive_binary_descriptor
                                                              error:&adapter_archive_error];
        MTL4ComputePipelineDescriptor *adapter_archive_mtl4_compute_descriptor = [MTL4ComputePipelineDescriptor new];
        adapter_archive_mtl4_compute_descriptor.computeFunctionDescriptor = adapter_archive_function_descriptor;
        id<MTLComputePipelineState> adapter_archive_mtl4_compute_pipeline =
            [adapter_mtl4_archive newComputePipelineStateWithDescriptor:adapter_archive_mtl4_compute_descriptor
                                                                    error:&adapter_archive_error];
        [[NSFileManager defaultManager] removeItemAtURL:adapter_archive_url error:nil];
        if (adapter_archive == nil ||
            ![adapter_archive conformsToProtocol:@protocol(MTLBinaryArchive)] ||
            !adapter_archive_compute_added || !adapter_archive_render_added ||
            !adapter_archive_serialized || !adapter_reloaded_archive || !adapter_archive_reloaded ||
            adapter_mtl4_archive == nil || adapter_archive_binary_function == nil ||
            ![adapter_archive_binary_function conformsToProtocol:@protocol(MTL4BinaryFunction)] ||
            adapter_archive_mtl4_compute_pipeline == nil) {
            fail_with_error("CPU binary archive metadata failed", adapter_archive_error);
            return 64;
        }

        /* Apple Metal is used only as the oracle. The adapter receives a
         * ZPU-owned CPU function descriptor, records a ZPU compute command,
         * and executes the registered CPU kernel against its ZPU texture. */
        id<MTLFunction> native_compute_function = [library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLComputePipelineState> native_compute_pipeline =
            [device newComputePipelineStateWithFunction:native_compute_function error:&error];
        MTLTextureDescriptor *compute_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width height:height mipmapped:NO];
        compute_texture_descriptor.storageMode = MTLStorageModeShared;
        compute_texture_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_compute_texture = [device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> native_compute_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_compute_encoder =
            [native_compute_command_buffer computeCommandEncoder];
        [native_compute_encoder setComputePipelineState:native_compute_pipeline];
        [native_compute_encoder setTexture:native_compute_texture atIndex:0];
        [native_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                          threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [native_compute_encoder endEncoding];
        [native_compute_command_buffer commit];
        [native_compute_command_buffer waitUntilCompleted];
        uint8_t native_compute_pixels[byte_count];
        [native_compute_texture getBytes:native_compute_pixels bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        NSError *adapter_compute_error = nil;
        id<MTLFunction> adapter_compute_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_fill_gradient_rgba8");
        id<MTLComputePipelineState> adapter_compute_pipeline =
            [adapter_device newComputePipelineStateWithFunction:adapter_compute_function error:&adapter_compute_error];
        id<MTLLibrary> adapter_default_library = [adapter_device newDefaultLibrary];
        id<MTLFunction> adapter_default_compute_function =
            [adapter_default_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLTexture> adapter_compute_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_compute_encoder =
            [adapter_compute_command_buffer computeCommandEncoder];
        [adapter_compute_encoder setComputePipelineState:adapter_compute_pipeline];
        [adapter_compute_encoder setTexture:adapter_compute_texture atIndex:0];
        [adapter_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_compute_encoder endEncoding];
        [adapter_compute_command_buffer commit];
        [adapter_compute_command_buffer waitUntilCompleted];
        uint8_t adapter_compute_pixels[byte_count];
        [adapter_compute_texture getBytes:adapter_compute_pixels bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_compute_function == nil || native_compute_pipeline == nil || native_compute_texture == nil ||
            native_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_compute_function == nil || adapter_compute_pipeline == nil || adapter_default_library == nil ||
            adapter_default_compute_function == nil || adapter_compute_texture == nil || adapter_compute_encoder == nil ||
            adapter_compute_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("compute adapter execution failed", adapter_compute_error);
            return 42;
        }
        for (size_t index = 0; index < byte_count; ++index) {
            if (native_compute_pixels[index] != adapter_compute_pixels[index]) {
                fprintf(stderr, "metal-pixel: compute mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, native_compute_pixels[index], adapter_compute_pixels[index]);
                return 43;
            }
        }

        /* Metal 4 compiler-created compute pipelines are still CPU-owned.
         * The compiler accepts only registered ZPU library functions; the
         * native Metal compiler above remains the pixel oracle. */
        NSError *adapter_mtl4_compiler_error = nil;
        MTL4PipelineDataSetSerializerDescriptor *adapter_mtl4_serializer_descriptor =
            [MTL4PipelineDataSetSerializerDescriptor new];
        adapter_mtl4_serializer_descriptor.configuration =
            MTL4PipelineDataSetSerializerConfigurationCaptureDescriptors |
            MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
        id<MTL4PipelineDataSetSerializer> adapter_mtl4_serializer =
            [adapter_device newPipelineDataSetSerializerWithDescriptor:adapter_mtl4_serializer_descriptor];
        MTL4CompilerDescriptor *adapter_mtl4_compiler_descriptor = [MTL4CompilerDescriptor new];
        adapter_mtl4_compiler_descriptor.label = @"zpu-cpu-compiler";
        adapter_mtl4_compiler_descriptor.pipelineDataSetSerializer = adapter_mtl4_serializer;
        id<MTL4Compiler> adapter_mtl4_compiler =
            [adapter_device newCompilerWithDescriptor:adapter_mtl4_compiler_descriptor
                                                 error:&adapter_mtl4_compiler_error];
        MTL4LibraryDescriptor *adapter_mtl4_library_descriptor = [MTL4LibraryDescriptor new];
        adapter_mtl4_library_descriptor.name = @"zpu-cpu-library";
        adapter_mtl4_library_descriptor.source = [NSString stringWithUTF8String:kShaderSource];
        id<MTLLibrary> adapter_mtl4_library =
            [adapter_mtl4_compiler newLibraryWithDescriptor:adapter_mtl4_library_descriptor
                                                       error:&adapter_mtl4_compiler_error];
        MTL4LibraryFunctionDescriptor *adapter_mtl4_function_descriptor = [MTL4LibraryFunctionDescriptor new];
        adapter_mtl4_function_descriptor.name = @"zpu_cpu_fill_gradient_rgba8";
        adapter_mtl4_function_descriptor.library = adapter_mtl4_library;
        MTL4ComputePipelineDescriptor *adapter_mtl4_compute_descriptor = [MTL4ComputePipelineDescriptor new];
        adapter_mtl4_compute_descriptor.computeFunctionDescriptor = adapter_mtl4_function_descriptor;
        adapter_mtl4_compute_descriptor.maxTotalThreadsPerThreadgroup = 64;
        adapter_mtl4_compute_descriptor.requiredThreadsPerThreadgroup = MTLSizeMake(8, 8, 1);
        adapter_mtl4_compute_descriptor.supportIndirectCommandBuffers =
            MTL4IndirectCommandBufferSupportStateEnabled;
        id<MTLComputePipelineState> adapter_mtl4_compiled_pipeline =
            [adapter_mtl4_compiler newComputePipelineStateWithDescriptor:adapter_mtl4_compute_descriptor
                                                        compilerTaskOptions:nil
                                                                      error:&adapter_mtl4_compiler_error];
        MTL4RenderPipelineDescriptor *adapter_mtl4_render_descriptor = [MTL4RenderPipelineDescriptor new];
        MTL4LibraryFunctionDescriptor *adapter_mtl4_vertex_descriptor = [MTL4LibraryFunctionDescriptor new];
        adapter_mtl4_vertex_descriptor.name = @"zpu_test_vertex";
        adapter_mtl4_vertex_descriptor.library = adapter_mtl4_library;
        MTL4LibraryFunctionDescriptor *adapter_mtl4_fragment_descriptor = [MTL4LibraryFunctionDescriptor new];
        adapter_mtl4_fragment_descriptor.name = @"zpu_test_fragment";
        adapter_mtl4_fragment_descriptor.library = adapter_mtl4_library;
        adapter_mtl4_render_descriptor.vertexFunctionDescriptor = adapter_mtl4_vertex_descriptor;
        adapter_mtl4_render_descriptor.fragmentFunctionDescriptor = adapter_mtl4_fragment_descriptor;
        adapter_mtl4_render_descriptor.rasterSampleCount = 1;
        adapter_mtl4_render_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError *adapter_mtl4_render_error = nil;
        id<MTLRenderPipelineState> adapter_mtl4_compiled_render_pipeline =
            [adapter_mtl4_compiler newRenderPipelineStateWithDescriptor:adapter_mtl4_render_descriptor
                                                        compilerTaskOptions:nil
                                                                      error:&adapter_mtl4_render_error];
        NSError *adapter_mtl4_archive_render_error = nil;
        id<MTLRenderPipelineState> adapter_mtl4_archived_render_pipeline =
            [adapter_mtl4_archive newRenderPipelineStateWithDescriptor:adapter_mtl4_render_descriptor
                                                                   error:&adapter_mtl4_archive_render_error];
        MTL4BinaryFunctionDescriptor *adapter_mtl4_binary_descriptor = [MTL4BinaryFunctionDescriptor new];
        adapter_mtl4_binary_descriptor.name = @"zpu_cpu_fill_gradient_rgba8";
        adapter_mtl4_binary_descriptor.functionDescriptor = adapter_mtl4_function_descriptor;
        adapter_mtl4_binary_descriptor.options = MTL4BinaryFunctionOptionPipelineIndependent;
        id<MTL4BinaryFunction> adapter_mtl4_binary_function =
            [adapter_mtl4_compiler newBinaryFunctionWithDescriptor:adapter_mtl4_binary_descriptor
                                                  compilerTaskOptions:nil
                                                                error:&adapter_mtl4_compiler_error];
        id<MTLFunctionHandle> adapter_mtl4_binary_handle =
            [adapter_device functionHandleWithBinaryFunction:adapter_mtl4_binary_function];
        id<MTLFunction> adapter_mtl4_compiler_function =
            [adapter_mtl4_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLFunctionHandle> adapter_mtl4_named_handle =
            [adapter_mtl4_compiled_pipeline functionHandleWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLFunctionHandle> adapter_mtl4_function_handle =
            [adapter_mtl4_compiled_pipeline functionHandleWithFunction:adapter_mtl4_compiler_function];
        __block id<MTL4BinaryFunction> adapter_mtl4_async_binary_function = nil;
        __block NSError *adapter_mtl4_async_error = nil;
        id<MTL4CompilerTask> adapter_mtl4_binary_task =
            [adapter_mtl4_compiler newBinaryFunctionWithDescriptor:adapter_mtl4_binary_descriptor
                                                  compilerTaskOptions:nil
                                                    completionHandler:^(id<MTL4BinaryFunction> function, NSError *binary_error) {
                adapter_mtl4_async_binary_function = function;
                adapter_mtl4_async_error = binary_error;
            }];
        [adapter_mtl4_binary_task waitUntilCompleted];
        NSData *adapter_mtl4_pipeline_script =
            [adapter_mtl4_serializer serializeAsPipelinesScriptWithError:&adapter_mtl4_compiler_error];
        NSURL *adapter_mtl4_serializer_url = [NSURL fileURLWithPath:
            [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
        BOOL adapter_mtl4_archive_flushed =
            [adapter_mtl4_serializer serializeAsArchiveAndFlushToURL:adapter_mtl4_serializer_url
                                                                  error:&adapter_mtl4_compiler_error];
        id<MTL4Archive> adapter_mtl4_serializer_archive =
            [adapter_device newArchiveWithURL:adapter_mtl4_serializer_url
                                         error:&adapter_mtl4_compiler_error];
        id<MTL4BinaryFunction> adapter_mtl4_serializer_binary =
            [adapter_mtl4_serializer_archive newBinaryFunctionWithDescriptor:adapter_mtl4_binary_descriptor
                                                                          error:&adapter_mtl4_compiler_error];
        [[NSFileManager defaultManager] removeItemAtURL:adapter_mtl4_serializer_url error:nil];
        id<MTLTexture> adapter_mtl4_compiler_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_mtl4_compiler_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_mtl4_compiler_encoder =
            [adapter_mtl4_compiler_command_buffer computeCommandEncoder];
        [adapter_mtl4_compiler_encoder setComputePipelineState:adapter_mtl4_compiled_pipeline];
        [adapter_mtl4_compiler_encoder setTexture:adapter_mtl4_compiler_texture atIndex:0];
        [adapter_mtl4_compiler_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_mtl4_compiler_encoder endEncoding];
        [adapter_mtl4_compiler_command_buffer commit];
        [adapter_mtl4_compiler_command_buffer waitUntilCompleted];
        uint8_t adapter_mtl4_compiler_pixels[byte_count];
        [adapter_mtl4_compiler_texture getBytes:adapter_mtl4_compiler_pixels
                                      bytesPerRow:(NSUInteger)width * 4
                                       fromRegion:MTLRegionMake2D(0, 0, width, height)
                                      mipmapLevel:0];
        id<MTLTexture> adapter_mtl4_compiler_render_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_mtl4_compiler_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_mtl4_compiler_render_pass.colorAttachments[0].texture = adapter_mtl4_compiler_render_texture;
        adapter_mtl4_compiler_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_mtl4_compiler_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_mtl4_compiler_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_mtl4_compiler_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_mtl4_compiler_render_encoder =
            [adapter_mtl4_compiler_render_command_buffer renderCommandEncoderWithDescriptor:adapter_mtl4_compiler_render_pass];
        [adapter_mtl4_compiler_render_encoder setRenderPipelineState:adapter_mtl4_compiled_render_pipeline];
        [adapter_mtl4_compiler_render_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mtl4_compiler_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_mtl4_compiler_render_encoder endEncoding];
        [adapter_mtl4_compiler_render_command_buffer commit];
        [adapter_mtl4_compiler_render_command_buffer waitUntilCompleted];
        uint8_t adapter_mtl4_compiler_render_pixels[byte_count];
        [adapter_mtl4_compiler_render_texture getBytes:adapter_mtl4_compiler_render_pixels
                                           bytesPerRow:(NSUInteger)width * 4
                                            fromRegion:MTLRegionMake2D(0, 0, width, height)
                                           mipmapLevel:0];
        if (adapter_mtl4_serializer == nil ||
            ![adapter_mtl4_serializer conformsToProtocol:@protocol(MTL4PipelineDataSetSerializer)] ||
            adapter_mtl4_pipeline_script.length == 0 || !adapter_mtl4_archive_flushed ||
            adapter_mtl4_serializer_archive == nil || adapter_mtl4_serializer_binary == nil ||
            adapter_mtl4_compiler == nil || adapter_mtl4_library == nil ||
            adapter_mtl4_compiled_pipeline == nil || adapter_mtl4_compiled_render_pipeline == nil ||
            adapter_mtl4_archived_render_pipeline == nil || adapter_mtl4_binary_function == nil ||
            adapter_mtl4_compiled_pipeline.maxTotalThreadsPerThreadgroup != 64 ||
            adapter_mtl4_compiled_pipeline.requiredThreadsPerThreadgroup.width != 8 ||
            adapter_mtl4_compiled_pipeline.requiredThreadsPerThreadgroup.height != 8 ||
            adapter_mtl4_compiled_pipeline.requiredThreadsPerThreadgroup.depth != 1 ||
            !adapter_mtl4_compiled_pipeline.supportIndirectCommandBuffers ||
            adapter_mtl4_binary_handle == nil || adapter_mtl4_named_handle == nil ||
            adapter_mtl4_function_handle == nil ||
            ![adapter_mtl4_binary_function conformsToProtocol:@protocol(MTL4BinaryFunction)] ||
            ![adapter_mtl4_binary_function.name isEqualToString:@"zpu_cpu_fill_gradient_rgba8"] ||
            adapter_mtl4_binary_function.functionType != MTLFunctionTypeKernel ||
            adapter_mtl4_binary_task == nil || adapter_mtl4_binary_task.status != MTL4CompilerTaskStatusFinished ||
            adapter_mtl4_async_binary_function == nil || adapter_mtl4_async_error != nil ||
            adapter_mtl4_compiler_texture == nil || adapter_mtl4_compiler_encoder == nil ||
            adapter_mtl4_compiler_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_mtl4_compiler_render_texture == nil || adapter_mtl4_compiler_render_encoder == nil ||
            adapter_mtl4_compiler_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_pixels, adapter_mtl4_compiler_render_pixels, byte_count) != 0 ||
            memcmp(native_compute_pixels, adapter_mtl4_compiler_pixels, byte_count) != 0) {
            fail_with_error("Metal 4 CPU compiler compute path failed", adapter_mtl4_compiler_error);
            return 101;
        }

        const MTLPixelFormat compute_float_formats[] = {
            MTLPixelFormatR32Float, MTLPixelFormatRGBA16Float,
        };
        NSString *compute_float_names[] = {
            @"zpu_cpu_fill_gradient_r32_float", @"zpu_cpu_fill_gradient_rgba16_float",
        };
        for (NSUInteger format_index = 0; format_index < sizeof(compute_float_formats) / sizeof(compute_float_formats[0]); ++format_index) {
            const MTLPixelFormat format = compute_float_formats[format_index];
            const NSUInteger bytes_per_pixel = format == MTLPixelFormatR32Float ? 4 : 8;
            const NSUInteger compute_float_byte_count = (NSUInteger)width * height * bytes_per_pixel;
            MTLTextureDescriptor *native_compute_float_descriptor = [compute_texture_descriptor copy];
            native_compute_float_descriptor.pixelFormat = format;
            MTLTextureDescriptor *adapter_compute_float_descriptor = [native_compute_float_descriptor copy];
            id<MTLTexture> native_compute_float_texture = [device newTextureWithDescriptor:native_compute_float_descriptor];
            id<MTLTexture> adapter_compute_float_texture = [adapter_device newTextureWithDescriptor:adapter_compute_float_descriptor];
            id<MTLFunction> native_compute_float_function = [library newFunctionWithName:compute_float_names[format_index]];
            id<MTLComputePipelineState> native_compute_float_pipeline =
                [device newComputePipelineStateWithFunction:native_compute_float_function error:&error];
            id<MTLFunction> adapter_compute_float_function =
                ZPUMetalCreateCPUFunction(adapter_device, compute_float_names[format_index]);
            id<MTLComputePipelineState> adapter_compute_float_pipeline =
                [adapter_device newComputePipelineStateWithFunction:adapter_compute_float_function error:&adapter_compute_error];
            id<MTLCommandBuffer> native_compute_float_command_buffer = [queue commandBuffer];
            id<MTLComputeCommandEncoder> native_compute_float_encoder =
                [native_compute_float_command_buffer computeCommandEncoder];
            [native_compute_float_encoder setComputePipelineState:native_compute_float_pipeline];
            [native_compute_float_encoder setTexture:native_compute_float_texture atIndex:0];
            [native_compute_float_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                      threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [native_compute_float_encoder endEncoding];
            [native_compute_float_command_buffer commit];
            [native_compute_float_command_buffer waitUntilCompleted];
            id<MTLCommandBuffer> adapter_compute_float_command_buffer = [adapter_queue commandBuffer];
            id<MTLComputeCommandEncoder> adapter_compute_float_encoder =
                [adapter_compute_float_command_buffer computeCommandEncoder];
            [adapter_compute_float_encoder setComputePipelineState:adapter_compute_float_pipeline];
            [adapter_compute_float_encoder setTexture:adapter_compute_float_texture atIndex:0];
            [adapter_compute_float_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                       threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [adapter_compute_float_encoder endEncoding];
            [adapter_compute_float_command_buffer commit];
            [adapter_compute_float_command_buffer waitUntilCompleted];
            uint8_t native_compute_float_bytes[compute_float_byte_count];
            uint8_t adapter_compute_float_bytes[compute_float_byte_count];
            [native_compute_float_texture getBytes:native_compute_float_bytes bytesPerRow:(NSUInteger)width * bytes_per_pixel
                                        fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            [adapter_compute_float_texture getBytes:adapter_compute_float_bytes bytesPerRow:(NSUInteger)width * bytes_per_pixel
                                          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            if (native_compute_float_function == nil || native_compute_float_pipeline == nil ||
                native_compute_float_texture == nil ||
                native_compute_float_command_buffer.status != MTLCommandBufferStatusCompleted ||
                adapter_compute_float_function == nil || adapter_compute_float_pipeline == nil ||
                adapter_compute_float_texture == nil ||
                adapter_compute_float_command_buffer.status != MTLCommandBufferStatusCompleted ||
                memcmp(native_compute_float_bytes, adapter_compute_float_bytes, compute_float_byte_count) != 0) {
                fail_with_error("float compute adapter execution failed", adapter_compute_error);
                return 45 + (int)format_index;
            }
        }

        MTLTextureDescriptor *compute_array_descriptor = [MTLTextureDescriptor new];
        compute_array_descriptor.textureType = MTLTextureType2DArray;
        compute_array_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        compute_array_descriptor.width = width;
        compute_array_descriptor.height = height;
        compute_array_descriptor.arrayLength = 2;
        compute_array_descriptor.mipmapLevelCount = 1;
        compute_array_descriptor.sampleCount = 1;
        compute_array_descriptor.storageMode = MTLStorageModeShared;
        compute_array_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLFunction> native_array_compute_function =
            [library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_array"];
        id<MTLComputePipelineState> native_array_compute_pipeline =
            [device newComputePipelineStateWithFunction:native_array_compute_function error:&error];
        id<MTLTexture> native_array_compute_texture = [device newTextureWithDescriptor:compute_array_descriptor];
        id<MTLCommandBuffer> native_array_compute_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_array_compute_encoder =
            [native_array_compute_command_buffer computeCommandEncoder];
        [native_array_compute_encoder setComputePipelineState:native_array_compute_pipeline];
        [native_array_compute_encoder setTexture:native_array_compute_texture atIndex:0];
        [native_array_compute_encoder dispatchThreads:MTLSizeMake(width, height, 3)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [native_array_compute_encoder endEncoding];
        [native_array_compute_command_buffer commit];
        [native_array_compute_command_buffer waitUntilCompleted];
        id<MTLFunction> adapter_array_compute_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_fill_gradient_rgba8_array");
        id<MTLComputePipelineState> adapter_array_compute_pipeline =
            [adapter_device newComputePipelineStateWithFunction:adapter_array_compute_function error:&adapter_compute_error];
        id<MTLTexture> adapter_array_compute_texture =
            [adapter_device newTextureWithDescriptor:compute_array_descriptor];
        id<MTLCommandBuffer> adapter_array_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_array_compute_encoder =
            [adapter_array_compute_command_buffer computeCommandEncoder];
        [adapter_array_compute_encoder setComputePipelineState:adapter_array_compute_pipeline];
        [adapter_array_compute_encoder setTexture:adapter_array_compute_texture atIndex:0];
        [adapter_array_compute_encoder dispatchThreads:MTLSizeMake(width, height, 3)
                                   threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_array_compute_encoder endEncoding];
        uint8_t adapter_array_compute_deferred[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [adapter_array_compute_texture getBytes:adapter_array_compute_deferred[slice]
                                       bytesPerRow:(NSUInteger)width * 4
                                     bytesPerImage:byte_count
                                      fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                     mipmapLevel:0
                                            slice:slice];
        }
        [adapter_array_compute_command_buffer commit];
        [adapter_array_compute_command_buffer waitUntilCompleted];
        uint8_t native_array_compute_pixels[2][byte_count];
        uint8_t adapter_array_compute_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [native_array_compute_texture getBytes:native_array_compute_pixels[slice]
                                      bytesPerRow:(NSUInteger)width * 4
                                    bytesPerImage:byte_count
                                     fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                    mipmapLevel:0
                                           slice:slice];
            [adapter_array_compute_texture getBytes:adapter_array_compute_pixels[slice]
                                       bytesPerRow:(NSUInteger)width * 4
                                     bytesPerImage:byte_count
                                      fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                     mipmapLevel:0
                                            slice:slice];
        }
        BOOL array_compute_exact = native_array_compute_function != nil && native_array_compute_pipeline != nil &&
            native_array_compute_texture != nil &&
            native_array_compute_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_array_compute_function != nil && adapter_array_compute_pipeline != nil &&
            adapter_array_compute_texture != nil &&
            adapter_array_compute_command_buffer.status == MTLCommandBufferStatusCompleted;
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            array_compute_exact = array_compute_exact &&
                memcmp(adapter_array_compute_deferred[slice], (const uint8_t[byte_count]){0}, byte_count) == 0 &&
                memcmp(native_array_compute_pixels[slice], adapter_array_compute_pixels[slice], byte_count) == 0;
        }
        if (!array_compute_exact) {
            fprintf(stderr, "metal-pixel: 2D-array compute exactness failed\n");
            return 44;
        }

        id<MTLFunction> native_three_d_compute_function =
            [library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_3d"];
        id<MTLComputePipelineState> native_three_d_compute_pipeline =
            [device newComputePipelineStateWithFunction:native_three_d_compute_function error:&error];
        id<MTLTexture> native_three_d_compute_texture = [device newTextureWithDescriptor:three_d_descriptor];
        id<MTLCommandBuffer> native_three_d_compute_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_three_d_compute_encoder =
            [native_three_d_compute_command_buffer computeCommandEncoder];
        [native_three_d_compute_encoder setComputePipelineState:native_three_d_compute_pipeline];
        [native_three_d_compute_encoder setTexture:native_three_d_compute_texture atIndex:0];
        [native_three_d_compute_encoder dispatchThreads:MTLSizeMake(three_d_width, three_d_height, three_d_depth + 1)
                                  threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [native_three_d_compute_encoder endEncoding];
        [native_three_d_compute_command_buffer commit];
        [native_three_d_compute_command_buffer waitUntilCompleted];
        id<MTLFunction> adapter_three_d_compute_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_fill_gradient_rgba8_3d");
        id<MTLComputePipelineState> adapter_three_d_compute_pipeline =
            [adapter_device newComputePipelineStateWithFunction:adapter_three_d_compute_function
                                                           error:&adapter_compute_error];
        id<MTLTexture> adapter_three_d_compute_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        id<MTLCommandBuffer> adapter_three_d_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_three_d_compute_encoder =
            [adapter_three_d_compute_command_buffer computeCommandEncoder];
        [adapter_three_d_compute_encoder setComputePipelineState:adapter_three_d_compute_pipeline];
        [adapter_three_d_compute_encoder setTexture:adapter_three_d_compute_texture atIndex:0];
        [adapter_three_d_compute_encoder dispatchThreads:MTLSizeMake(three_d_width, three_d_height, three_d_depth + 1)
                                   threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [adapter_three_d_compute_encoder endEncoding];
        uint8_t native_three_d_compute_bytes[three_d_bytes];
        uint8_t adapter_three_d_compute_deferred[three_d_bytes];
        memset(adapter_three_d_compute_deferred, 0, sizeof(adapter_three_d_compute_deferred));
        [adapter_three_d_compute_texture getBytes:adapter_three_d_compute_deferred
                                       bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                        fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                       mipmapLevel:0 slice:0];
        [adapter_three_d_compute_command_buffer commit];
        [adapter_three_d_compute_command_buffer waitUntilCompleted];
        memset(native_three_d_compute_bytes, 0, sizeof(native_three_d_compute_bytes));
        [native_three_d_compute_texture getBytes:native_three_d_compute_bytes
                                      bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                       fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                      mipmapLevel:0 slice:0];
        uint8_t adapter_three_d_compute_bytes[three_d_bytes];
        memset(adapter_three_d_compute_bytes, 0, sizeof(adapter_three_d_compute_bytes));
        [adapter_three_d_compute_texture getBytes:adapter_three_d_compute_bytes
                                       bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                        fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                       mipmapLevel:0 slice:0];
        if (native_three_d_compute_function == nil || native_three_d_compute_pipeline == nil ||
            native_three_d_compute_texture == nil || native_three_d_compute_encoder == nil ||
            native_three_d_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_three_d_compute_function == nil || adapter_three_d_compute_pipeline == nil ||
            adapter_three_d_compute_texture == nil || adapter_three_d_compute_encoder == nil ||
            adapter_three_d_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(adapter_three_d_compute_deferred, (const uint8_t[three_d_bytes]){0}, three_d_bytes) != 0 ||
            memcmp(native_three_d_compute_bytes, adapter_three_d_compute_bytes, three_d_bytes) != 0) {
            fail_with_error("3D CPU compute adapter execution failed", adapter_compute_error);
            return 83;
        }

        /* Indirect array dispatch must preserve Metal's deferred grid
         * semantics. The CPU adapter records one ZPU command per slice and
         * resolves the indirect z extent at commit time; native Metal is the
         * oracle for the full two-slice dispatch. */
        const uint32_t array_indirect_threadgroups[] = {1, 1, 2};
        id<MTLBuffer> native_array_indirect_buffer =
            [device newBufferWithBytes:array_indirect_threadgroups
                                length:sizeof(array_indirect_threadgroups)
                               options:MTLResourceStorageModeShared];
        id<MTLTexture> native_array_indirect_texture = [device newTextureWithDescriptor:compute_array_descriptor];
        id<MTLCommandBuffer> native_array_indirect_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_array_indirect_encoder =
            [native_array_indirect_command_buffer computeCommandEncoder];
        [native_array_indirect_encoder setComputePipelineState:native_array_compute_pipeline];
        [native_array_indirect_encoder setTexture:native_array_indirect_texture atIndex:0];
        [native_array_indirect_encoder dispatchThreadgroupsWithIndirectBuffer:native_array_indirect_buffer
                                                           indirectBufferOffset:0
                                                           threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [native_array_indirect_encoder endEncoding];
        [native_array_indirect_command_buffer commit];
        [native_array_indirect_command_buffer waitUntilCompleted];
        uint8_t native_array_indirect_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [native_array_indirect_texture getBytes:native_array_indirect_pixels[slice]
                                        bytesPerRow:(NSUInteger)width * 4
                                      bytesPerImage:byte_count
                                       fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                      mipmapLevel:0
                                             slice:slice];
        }

        id<MTLBuffer> adapter_array_indirect_buffer =
            [adapter_device newBufferWithBytes:array_indirect_threadgroups
                                         length:sizeof(array_indirect_threadgroups)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_array_indirect_texture =
            [adapter_device newTextureWithDescriptor:compute_array_descriptor];
        id<MTLCommandBuffer> adapter_array_indirect_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_array_indirect_encoder =
            [adapter_array_indirect_command_buffer computeCommandEncoder];
        [adapter_array_indirect_encoder setComputePipelineState:adapter_array_compute_pipeline];
        [adapter_array_indirect_encoder setTexture:adapter_array_indirect_texture atIndex:0];
        [adapter_array_indirect_encoder dispatchThreadgroupsWithIndirectBuffer:adapter_array_indirect_buffer
                                                            indirectBufferOffset:0
                                                            threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        uint8_t adapter_array_indirect_deferred[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [adapter_array_indirect_texture getBytes:adapter_array_indirect_deferred[slice]
                                        bytesPerRow:(NSUInteger)width * 4
                                      bytesPerImage:byte_count
                                       fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                      mipmapLevel:0
                                             slice:slice];
        }
        [adapter_array_indirect_encoder endEncoding];
        [adapter_array_indirect_command_buffer commit];
        [adapter_array_indirect_command_buffer waitUntilCompleted];
        uint8_t adapter_array_indirect_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [adapter_array_indirect_texture getBytes:adapter_array_indirect_pixels[slice]
                                        bytesPerRow:(NSUInteger)width * 4
                                      bytesPerImage:byte_count
                                       fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                      mipmapLevel:0
                                             slice:slice];
        }
        BOOL array_indirect_exact = native_array_indirect_buffer != nil &&
            native_array_indirect_texture != nil && native_array_indirect_encoder != nil &&
            native_array_indirect_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_array_indirect_buffer != nil && adapter_array_indirect_texture != nil &&
            adapter_array_indirect_encoder != nil &&
            adapter_array_indirect_command_buffer.status == MTLCommandBufferStatusCompleted;
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            array_indirect_exact = array_indirect_exact &&
                memcmp(adapter_array_indirect_deferred[slice], (const uint8_t[byte_count]){0}, byte_count) == 0 &&
                memcmp(native_array_indirect_pixels[slice], adapter_array_indirect_pixels[slice], byte_count) == 0;
        }
        if (!array_indirect_exact) {
            fprintf(stderr, "metal-pixel: deferred 2D-array indirect compute exactness failed\n");
            return 45;
        }

        /* A changed indirect z extent must affect the already-recorded
         * commands at commit time, just as it does for a native indirect
         * dispatch. Only slice zero is selected here; slice one stays clear. */
        const uint32_t array_indirect_one_threadgroup[] = {1, 1, 2};
        id<MTLBuffer> adapter_array_indirect_one_buffer =
            [adapter_device newBufferWithBytes:array_indirect_one_threadgroup
                                         length:sizeof(array_indirect_one_threadgroup)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_array_indirect_one_texture =
            [adapter_device newTextureWithDescriptor:compute_array_descriptor];
        id<MTLCommandBuffer> adapter_array_indirect_one_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_array_indirect_one_encoder =
            [adapter_array_indirect_one_command_buffer computeCommandEncoder];
        [adapter_array_indirect_one_encoder setComputePipelineState:adapter_array_compute_pipeline];
        [adapter_array_indirect_one_encoder setTexture:adapter_array_indirect_one_texture atIndex:0];
        [adapter_array_indirect_one_encoder dispatchThreadgroupsWithIndirectBuffer:adapter_array_indirect_one_buffer
                                                                indirectBufferOffset:0
                                                                threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_array_indirect_one_encoder endEncoding];
        ((uint32_t *)adapter_array_indirect_one_buffer.contents)[2] = 1;
        [adapter_array_indirect_one_command_buffer commit];
        [adapter_array_indirect_one_command_buffer waitUntilCompleted];
        uint8_t adapter_array_indirect_one_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [adapter_array_indirect_one_texture getBytes:adapter_array_indirect_one_pixels[slice]
                                            bytesPerRow:(NSUInteger)width * 4
                                          bytesPerImage:byte_count
                                           fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                          mipmapLevel:0
                                                 slice:slice];
        }
        if (adapter_array_indirect_one_buffer == nil || adapter_array_indirect_one_texture == nil ||
            adapter_array_indirect_one_encoder == nil ||
            adapter_array_indirect_one_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(adapter_array_indirect_one_pixels[0], native_array_compute_pixels[0], byte_count) != 0 ||
            memcmp(adapter_array_indirect_one_pixels[1], (const uint8_t[byte_count]){0}, byte_count) != 0) {
            fprintf(stderr, "metal-pixel: deferred 2D-array indirect z filtering failed\n");
            return 46;
        }

        uint8_t compute_source_bytes[byte_count];
        for (size_t index = 0; index < byte_count; ++index) {
            compute_source_bytes[index] = (uint8_t)((index * 17u + 3u) & 0xffu);
        }
        id<MTLBuffer> adapter_copy_buffer =
            [adapter_device newBufferWithBytes:compute_source_bytes length:sizeof(compute_source_bytes)
                                       options:MTLResourceStorageModeShared];

        /* Metal 4 command submission is also CPU-owned. The only native
         * Metal execution in this test remains the reference command above;
         * this path uses a synthetic ZPU resource ID in an argument table and
         * dispatches through the existing CPU kernel implementation. */
        NSError *metal4_error = nil;
        MTL4CommandAllocatorDescriptor *metal4_allocator_descriptor = [MTL4CommandAllocatorDescriptor new];
        metal4_allocator_descriptor.label = @"zpu-cpu-allocator";
        id<MTL4CommandAllocator> metal4_allocator =
            [adapter_device newCommandAllocatorWithDescriptor:metal4_allocator_descriptor error:&metal4_error];
        MTL4CommandQueueDescriptor *metal4_queue_descriptor = [MTL4CommandQueueDescriptor new];
        metal4_queue_descriptor.label = @"zpu-cpu-queue";
        id<MTL4CommandQueue> metal4_queue =
            [adapter_device newMTL4CommandQueueWithDescriptor:metal4_queue_descriptor error:&metal4_error];
        id<MTLEvent> metal4_event = [adapter_device newEvent];
        [metal4_queue signalEvent:metal4_event value:13];
        [metal4_queue waitForEvent:metal4_event value:13];
        MTL4ArgumentTableDescriptor *metal4_table_descriptor = [MTL4ArgumentTableDescriptor new];
        metal4_table_descriptor.maxTextureBindCount = 1;
        metal4_table_descriptor.label = @"zpu-cpu-table";
        id<MTL4ArgumentTable> metal4_table =
            [adapter_device newArgumentTableWithDescriptor:metal4_table_descriptor error:&metal4_error];
        [metal4_table setTexture:adapter_compute_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_command_buffer = [adapter_device newCommandBuffer];
        [metal4_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_encoder = [metal4_command_buffer computeCommandEncoder];
        [metal4_encoder setComputePipelineState:adapter_compute_pipeline];
        [metal4_encoder setArgumentTable:metal4_table];
        [metal4_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [metal4_encoder endEncoding];
        [metal4_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_command_buffers[] = {metal4_command_buffer};
        MTL4CommitOptions *metal4_commit_options = ZPUMetalCreateCPUCommitOptions();
        __block BOOL metal4_feedback_called = NO;
        __block NSError *metal4_feedback_error = nil;
        __block CFTimeInterval metal4_feedback_start = 0.0;
        __block CFTimeInterval metal4_feedback_end = 0.0;
        [metal4_commit_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            metal4_feedback_called = YES;
            metal4_feedback_error = feedback.error;
            metal4_feedback_start = feedback.GPUStartTime;
            metal4_feedback_end = feedback.GPUEndTime;
        }];
        [metal4_queue commit:metal4_command_buffers count:1 options:metal4_commit_options];
        uint8_t metal4_pixels[byte_count];
        [adapter_compute_texture getBytes:metal4_pixels bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (metal4_allocator == nil || metal4_queue == nil || metal4_table == nil ||
            metal4_event == nil || ((id<MTLSharedEvent>)metal4_event).signaledValue != 13 ||
            metal4_command_buffer == nil || metal4_encoder == nil ||
            !metal4_feedback_called || metal4_feedback_error != nil || metal4_feedback_start <= 0.0 ||
            metal4_feedback_end < metal4_feedback_start ||
            ![metal4_allocator conformsToProtocol:@protocol(MTL4CommandAllocator)] ||
            ![metal4_queue conformsToProtocol:@protocol(MTL4CommandQueue)] ||
            ![metal4_command_buffer conformsToProtocol:@protocol(MTL4CommandBuffer)] ||
            ![metal4_table conformsToProtocol:@protocol(MTL4ArgumentTable)] ||
            memcmp(native_compute_pixels, metal4_pixels, byte_count) != 0) {
            fail_with_error("Metal 4 CPU command submission failed", metal4_error);
            return 60;
        }

        id<MTLTexture> metal4_mip_copy = [adapter_device newTextureWithDescriptor:mip_descriptor];
        id<MTL4CommandBuffer> metal4_mip_command_buffer = [adapter_device newCommandBuffer];
        [metal4_mip_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_mip_encoder = [metal4_mip_command_buffer computeCommandEncoder];
        [metal4_mip_encoder copyFromTexture:adapter_mip_texture
                                sourceSlice:0
                                sourceLevel:1
                               sourceOrigin:MTLOriginMake(0, 0, 0)
                                 sourceSize:MTLSizeMake(2, 2, 1)
                               toTexture:metal4_mip_copy
                        destinationSlice:0
                        destinationLevel:1
                       destinationOrigin:MTLOriginMake(0, 0, 0)];
        [metal4_mip_encoder endEncoding];
        [metal4_mip_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_mip_command_buffers[] = {metal4_mip_command_buffer};
        [metal4_queue commit:metal4_mip_command_buffers count:1];
        uint8_t metal4_mip_copy_bytes[sizeof(mip_level_one)];
        [metal4_mip_copy getBytes:metal4_mip_copy_bytes
                       bytesPerRow:2 * 4
                        fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                       mipmapLevel:1];
        if (metal4_mip_copy == nil || metal4_mip_command_buffer == nil || metal4_mip_encoder == nil ||
            memcmp(metal4_mip_copy_bytes, native_mip_level_one, sizeof(mip_level_one)) != 0) {
            fail_with_error("Metal 4 CPU mip-level copy failed", metal4_error);
            return 70;
        }

        id<MTLTexture> metal4_three_d_copy = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        id<MTLTexture> metal4_three_d_upload_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        id<MTLBuffer> metal4_three_d_to_buffer =
            [adapter_device newBufferWithLength:three_d_copy_buffer_length options:MTLResourceStorageModeShared];
        if (metal4_three_d_to_buffer != nil) memset(metal4_three_d_to_buffer.contents, 0xcd, metal4_three_d_to_buffer.length);
        [metal4_three_d_copy replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                mipmapLevel:0 slice:0 withBytes:three_d_clear
                                bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        [metal4_three_d_upload_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                           mipmapLevel:0 slice:0 withBytes:three_d_clear
                                           bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        id<MTL4CommandBuffer> metal4_three_d_command_buffer = [adapter_device newCommandBuffer];
        [metal4_three_d_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_three_d_encoder =
            [metal4_three_d_command_buffer computeCommandEncoder];
        [metal4_three_d_encoder copyFromTexture:adapter_three_d_texture
                                     sourceSlice:0 sourceLevel:0 sourceOrigin:three_d_copy_source_origin
                                     sourceSize:three_d_copy_size toTexture:metal4_three_d_copy
                               destinationSlice:0 destinationLevel:0
                              destinationOrigin:three_d_copy_destination_origin];
        [metal4_three_d_encoder copyFromTexture:adapter_three_d_texture
                                     sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(1, 0, 1)
                                     sourceSize:three_d_copy_size toBuffer:metal4_three_d_to_buffer
                                destinationOffset:0 destinationBytesPerRow:three_d_copy_row_stride
                              destinationBytesPerImage:three_d_copy_image_stride];
        [metal4_three_d_encoder copyFromBuffer:adapter_three_d_upload_buffer sourceOffset:three_d_upload_offset
                               sourceBytesPerRow:three_d_copy_row_stride sourceBytesPerImage:three_d_copy_image_stride
                                      sourceSize:three_d_copy_size toTexture:metal4_three_d_upload_texture
                                destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 1, 0)];
        [metal4_three_d_encoder endEncoding];
        [metal4_three_d_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_three_d_command_buffers[] = {metal4_three_d_command_buffer};
        [metal4_queue commit:metal4_three_d_command_buffers count:1];
        uint8_t metal4_three_d_copy_bytes[three_d_bytes];
        uint8_t metal4_three_d_upload_texture_bytes[three_d_bytes];
        memset(metal4_three_d_copy_bytes, 0xa5, sizeof(metal4_three_d_copy_bytes));
        memset(metal4_three_d_upload_texture_bytes, 0xa5, sizeof(metal4_three_d_upload_texture_bytes));
        [metal4_three_d_copy getBytes:metal4_three_d_copy_bytes
                           bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                            fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                           mipmapLevel:0 slice:0];
        [metal4_three_d_upload_texture getBytes:metal4_three_d_upload_texture_bytes
                                    bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                     fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                    mipmapLevel:0 slice:0];
        if (metal4_three_d_copy == nil || metal4_three_d_upload_texture == nil || metal4_three_d_to_buffer == nil ||
            metal4_three_d_command_buffer == nil || metal4_three_d_encoder == nil ||
            memcmp(metal4_three_d_copy_bytes, native_three_d_copy_bytes, sizeof(metal4_three_d_copy_bytes)) != 0 ||
            memcmp(metal4_three_d_upload_texture_bytes, native_three_d_upload_texture_bytes,
                   sizeof(metal4_three_d_upload_texture_bytes)) != 0 ||
            memcmp(metal4_three_d_to_buffer.contents, native_three_d_to_buffer.contents,
                   three_d_copy_buffer_length) != 0) {
            fail_with_error("Metal 4 CPU 3D texture copy failed", metal4_error);
            return 82;
        }

        MTL4ArgumentTableDescriptor *metal4_three_d_compute_table_descriptor = [MTL4ArgumentTableDescriptor new];
        metal4_three_d_compute_table_descriptor.maxTextureBindCount = 1;
        id<MTL4ArgumentTable> metal4_three_d_compute_table =
            [adapter_device newArgumentTableWithDescriptor:metal4_three_d_compute_table_descriptor error:&metal4_error];
        id<MTLTexture> metal4_three_d_compute_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        [metal4_three_d_compute_table setTexture:metal4_three_d_compute_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_three_d_compute_command_buffer = [adapter_device newCommandBuffer];
        [metal4_three_d_compute_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_three_d_compute_encoder =
            [metal4_three_d_compute_command_buffer computeCommandEncoder];
        [metal4_three_d_compute_encoder setComputePipelineState:adapter_three_d_compute_pipeline];
        [metal4_three_d_compute_encoder setArgumentTable:metal4_three_d_compute_table];
        [metal4_three_d_compute_encoder dispatchThreads:MTLSizeMake(three_d_width, three_d_height, three_d_depth + 1)
                                   threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [metal4_three_d_compute_encoder endEncoding];
        [metal4_three_d_compute_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_three_d_compute_command_buffers[] = {metal4_three_d_compute_command_buffer};
        [metal4_queue commit:metal4_three_d_compute_command_buffers count:1];
        uint8_t metal4_three_d_compute_bytes[three_d_bytes];
        memset(metal4_three_d_compute_bytes, 0, sizeof(metal4_three_d_compute_bytes));
        [metal4_three_d_compute_texture getBytes:metal4_three_d_compute_bytes
                                      bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                       fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                      mipmapLevel:0 slice:0];

        const uint32_t metal4_three_d_indirect_threads[] = {
            three_d_width, three_d_height, three_d_depth + 1, 2, 2, 1,
        };
        id<MTLBuffer> metal4_three_d_indirect_buffer =
            [adapter_device newBufferWithBytes:metal4_three_d_indirect_threads
                                         length:sizeof(metal4_three_d_indirect_threads)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_three_d_indirect_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        [metal4_three_d_compute_table setTexture:metal4_three_d_indirect_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_three_d_indirect_command_buffer = [adapter_device newCommandBuffer];
        [metal4_three_d_indirect_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_three_d_indirect_encoder =
            [metal4_three_d_indirect_command_buffer computeCommandEncoder];
        [metal4_three_d_indirect_encoder setComputePipelineState:adapter_three_d_compute_pipeline];
        [metal4_three_d_indirect_encoder setArgumentTable:metal4_three_d_compute_table];
        [metal4_three_d_indirect_encoder dispatchThreadsWithIndirectBuffer:metal4_three_d_indirect_buffer.gpuAddress];
        [metal4_three_d_indirect_encoder endEncoding];
        [metal4_three_d_indirect_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_three_d_indirect_command_buffers[] = {metal4_three_d_indirect_command_buffer};
        [metal4_queue commit:metal4_three_d_indirect_command_buffers count:1];
        uint8_t metal4_three_d_indirect_bytes[three_d_bytes];
        memset(metal4_three_d_indirect_bytes, 0, sizeof(metal4_three_d_indirect_bytes));
        [metal4_three_d_indirect_texture getBytes:metal4_three_d_indirect_bytes
                                       bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes
                                        fromRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                       mipmapLevel:0 slice:0];
        if (metal4_three_d_compute_table == nil || metal4_three_d_compute_texture == nil ||
            metal4_three_d_compute_command_buffer == nil || metal4_three_d_compute_encoder == nil ||
            metal4_three_d_indirect_buffer == nil || metal4_three_d_indirect_texture == nil ||
            metal4_three_d_indirect_command_buffer == nil || metal4_three_d_indirect_encoder == nil ||
            memcmp(metal4_three_d_compute_bytes, native_three_d_compute_bytes, sizeof(metal4_three_d_compute_bytes)) != 0 ||
            memcmp(metal4_three_d_indirect_bytes, native_three_d_compute_bytes, sizeof(metal4_three_d_indirect_bytes)) != 0) {
            fail_with_error("Metal 4 CPU 3D compute dispatch failed", metal4_error);
            return 84;
        }

        id<MTLTexture> metal4_generate_mip_texture = [adapter_device newTextureWithDescriptor:generate_mip_descriptor];
        [metal4_generate_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 4, 4)
                                       mipmapLevel:0
                                         withBytes:generate_mip_base
                                       bytesPerRow:4 * 4];
        id<MTL4CommandBuffer> metal4_generate_mip_command_buffer = [adapter_device newCommandBuffer];
        [metal4_generate_mip_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_generate_mip_encoder =
            [metal4_generate_mip_command_buffer computeCommandEncoder];
        [metal4_generate_mip_encoder generateMipmapsForTexture:metal4_generate_mip_texture];
        [metal4_generate_mip_encoder endEncoding];
        [metal4_generate_mip_command_buffer endCommandBuffer];
        uint8_t metal4_deferred_generated_mip_level_one[sizeof(mip_level_one)];
        [metal4_generate_mip_texture getBytes:metal4_deferred_generated_mip_level_one
                                  bytesPerRow:2 * 4
                                   fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                  mipmapLevel:1];
        id<MTL4CommandBuffer> metal4_generate_mip_command_buffers[] = {metal4_generate_mip_command_buffer};
        [metal4_queue commit:metal4_generate_mip_command_buffers count:1];
        uint8_t metal4_generated_mip_level_one[sizeof(mip_level_one)];
        [metal4_generate_mip_texture getBytes:metal4_generated_mip_level_one
                                  bytesPerRow:2 * 4
                                   fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                                  mipmapLevel:1];
        if (metal4_generate_mip_texture == nil || metal4_generate_mip_command_buffer == nil ||
            metal4_generate_mip_encoder == nil ||
            memcmp(metal4_deferred_generated_mip_level_one, (const uint8_t[sizeof(mip_level_one)]){0}, sizeof(mip_level_one)) != 0 ||
            memcmp(metal4_generated_mip_level_one, native_generated_mip_level_one, sizeof(mip_level_one)) != 0) {
            fail_with_error("Metal 4 CPU mipmap generation failed", metal4_error);
            return 73;
        }

        id<MTLTexture> metal4_three_d_mipmap_texture = [adapter_device newTextureWithDescriptor:three_d_descriptor];
        [metal4_three_d_mipmap_texture replaceRegion:MTLRegionMake3D(0, 0, 0, three_d_width, three_d_height, three_d_depth)
                                          mipmapLevel:0 slice:0 withBytes:three_d_source
                                          bytesPerRow:three_d_row_bytes bytesPerImage:three_d_plane_bytes];
        id<MTL4CommandBuffer> metal4_three_d_mipmap_command_buffer = [adapter_device newCommandBuffer];
        [metal4_three_d_mipmap_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_three_d_mipmap_encoder =
            [metal4_three_d_mipmap_command_buffer computeCommandEncoder];
        [metal4_three_d_mipmap_encoder generateMipmapsForTexture:metal4_three_d_mipmap_texture];
        [metal4_three_d_mipmap_encoder endEncoding];
        [metal4_three_d_mipmap_command_buffer endCommandBuffer];
        uint8_t metal4_three_d_mipmap_deferred[three_d_mip_bytes];
        memset(metal4_three_d_mipmap_deferred, 0xa5, sizeof(metal4_three_d_mipmap_deferred));
        [metal4_three_d_mipmap_texture getBytes:metal4_three_d_mipmap_deferred
                                    bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                     fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                                    mipmapLevel:1 slice:0];
        id<MTL4CommandBuffer> metal4_three_d_mipmap_command_buffers[] = {metal4_three_d_mipmap_command_buffer};
        [metal4_queue commit:metal4_three_d_mipmap_command_buffers count:1];
        uint8_t metal4_three_d_mipmap_level_one[three_d_mip_bytes];
        [metal4_three_d_mipmap_texture getBytes:metal4_three_d_mipmap_level_one
                                    bytesPerRow:2 * 4 bytesPerImage:2 * 4
                                     fromRegion:MTLRegionMake3D(0, 0, 0, 2, 1, 1)
                                    mipmapLevel:1 slice:0];
        if (metal4_three_d_mipmap_texture == nil || metal4_three_d_mipmap_command_buffer == nil ||
            metal4_three_d_mipmap_encoder == nil ||
            memcmp(metal4_three_d_mipmap_deferred, (const uint8_t[three_d_mip_bytes]){0}, three_d_mip_bytes) != 0 ||
            memcmp(metal4_three_d_mipmap_level_one, native_three_d_mipmap_level_one,
                   sizeof(metal4_three_d_mipmap_level_one)) != 0) {
            fail_with_error("Metal 4 CPU 3D mipmap generation failed", metal4_error);
            return 85;
        }

        id<MTLTexture> metal4_array_copy = [adapter_device newTextureWithDescriptor:array_descriptor];
        id<MTL4CommandBuffer> metal4_array_command_buffer = [adapter_device newCommandBuffer];
        [metal4_array_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_array_encoder = [metal4_array_command_buffer computeCommandEncoder];
        [metal4_array_encoder copyFromTexture:adapter_array_texture
                                  sourceSlice:1
                                  sourceLevel:1
                                 sourceOrigin:MTLOriginMake(0, 0, 0)
                                   sourceSize:MTLSizeMake(2, 2, 1)
                                 toTexture:metal4_array_copy
                          destinationSlice:0
                          destinationLevel:1
                         destinationOrigin:MTLOriginMake(0, 0, 0)];
        [metal4_array_encoder endEncoding];
        [metal4_array_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_array_command_buffers[] = {metal4_array_command_buffer};
        [metal4_queue commit:metal4_array_command_buffers count:1];
        uint8_t metal4_array_copy_bytes[sizeof(array_level_one)];
        [metal4_array_copy getBytes:metal4_array_copy_bytes
                         bytesPerRow:2 * 4
                       bytesPerImage:sizeof(array_level_one)
                        fromRegion:MTLRegionMake2D(0, 0, 2, 2)
                       mipmapLevel:1
                              slice:0];
        if (metal4_array_copy == nil || metal4_array_command_buffer == nil || metal4_array_encoder == nil ||
            memcmp(metal4_array_copy_bytes, native_array_level_one, sizeof(array_level_one)) != 0) {
            fail_with_error("Metal 4 CPU array slice/level copy failed", metal4_error);
            return 76;
        }

        id<MTLTexture> metal4_array_compute_texture =
            [adapter_device newTextureWithDescriptor:compute_array_descriptor];
        MTL4ArgumentTableDescriptor *metal4_array_compute_table_descriptor = [MTL4ArgumentTableDescriptor new];
        metal4_array_compute_table_descriptor.maxTextureBindCount = 1;
        id<MTL4ArgumentTable> metal4_array_compute_table =
            [adapter_device newArgumentTableWithDescriptor:metal4_array_compute_table_descriptor error:&metal4_error];
        [metal4_array_compute_table setTexture:metal4_array_compute_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_array_compute_command_buffer = [adapter_device newCommandBuffer];
        [metal4_array_compute_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_array_compute_encoder =
            [metal4_array_compute_command_buffer computeCommandEncoder];
        [metal4_array_compute_encoder setComputePipelineState:adapter_array_compute_pipeline];
        [metal4_array_compute_encoder setArgumentTable:metal4_array_compute_table];
        [metal4_array_compute_encoder dispatchThreads:MTLSizeMake(width, height, 3)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [metal4_array_compute_encoder endEncoding];
        [metal4_array_compute_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_array_compute_command_buffers[] = {metal4_array_compute_command_buffer};
        [metal4_queue commit:metal4_array_compute_command_buffers count:1];
        uint8_t metal4_array_compute_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [metal4_array_compute_texture getBytes:metal4_array_compute_pixels[slice]
                                      bytesPerRow:(NSUInteger)width * 4
                                    bytesPerImage:byte_count
                                     fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                    mipmapLevel:0
                                           slice:slice];
        }
        BOOL metal4_array_compute_exact = metal4_array_compute_texture != nil &&
            metal4_array_compute_table != nil && metal4_array_compute_command_buffer != nil &&
            metal4_array_compute_encoder != nil;
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            metal4_array_compute_exact = metal4_array_compute_exact &&
                memcmp(native_array_compute_pixels[slice], metal4_array_compute_pixels[slice], byte_count) == 0;
        }
        if (!metal4_array_compute_exact) {
            fail_with_error("Metal 4 CPU array compute failed", metal4_error);
            return 79;
        }

        const uint32_t metal4_array_indirect_threads[] = {width, height, 2, 8, 8, 1};
        id<MTLBuffer> metal4_array_indirect_buffer =
            [adapter_device newBufferWithBytes:metal4_array_indirect_threads
                                         length:sizeof(metal4_array_indirect_threads)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_array_indirect_texture =
            [adapter_device newTextureWithDescriptor:compute_array_descriptor];
        [metal4_array_compute_table setTexture:metal4_array_indirect_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_array_indirect_command_buffer = [adapter_device newCommandBuffer];
        [metal4_array_indirect_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_array_indirect_encoder =
            [metal4_array_indirect_command_buffer computeCommandEncoder];
        [metal4_array_indirect_encoder setComputePipelineState:adapter_array_compute_pipeline];
        [metal4_array_indirect_encoder setArgumentTable:metal4_array_compute_table];
        [metal4_array_indirect_encoder dispatchThreadsWithIndirectBuffer:metal4_array_indirect_buffer.gpuAddress];
        [metal4_array_indirect_encoder endEncoding];
        ((uint32_t *)metal4_array_indirect_buffer.contents)[2] = 1;
        [metal4_array_indirect_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_array_indirect_command_buffers[] = {metal4_array_indirect_command_buffer};
        [metal4_queue commit:metal4_array_indirect_command_buffers count:1];
        uint8_t metal4_array_indirect_pixels[2][byte_count];
        for (NSUInteger slice = 0; slice < 2; ++slice) {
            [metal4_array_indirect_texture getBytes:metal4_array_indirect_pixels[slice]
                                        bytesPerRow:(NSUInteger)width * 4
                                      bytesPerImage:byte_count
                                       fromRegion:MTLRegionMake3D(0, 0, 0, width, height, 1)
                                      mipmapLevel:0
                                             slice:slice];
        }
        if (metal4_array_indirect_buffer == nil || metal4_array_indirect_texture == nil ||
            metal4_array_indirect_command_buffer == nil || metal4_array_indirect_encoder == nil ||
            memcmp(metal4_array_indirect_pixels[0], native_array_compute_pixels[0], byte_count) != 0 ||
            memcmp(metal4_array_indirect_pixels[1], (const uint8_t[byte_count]){0}, byte_count) != 0) {
            fail_with_error("Metal 4 CPU indirect array z filtering failed", metal4_error);
            return 80;
        }

        const uint32_t metal4_indirect_threads[] = {width, height, 1, 8, 8, 1};
        id<MTLBuffer> metal4_indirect_threads_buffer =
            [adapter_device newBufferWithBytes:metal4_indirect_threads
                                         length:sizeof(metal4_indirect_threads)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_indirect_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        [metal4_table setTexture:metal4_indirect_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_indirect_command_buffer = [adapter_device newCommandBuffer];
        [metal4_indirect_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_indirect_encoder = [metal4_indirect_command_buffer computeCommandEncoder];
        [metal4_indirect_encoder setComputePipelineState:adapter_compute_pipeline];
        [metal4_indirect_encoder setArgumentTable:metal4_table];
        [metal4_indirect_encoder dispatchThreadsWithIndirectBuffer:metal4_indirect_threads_buffer.gpuAddress];
        [metal4_indirect_encoder endEncoding];
        [metal4_indirect_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_indirect_command_buffers[] = {metal4_indirect_command_buffer};
        [metal4_queue commit:metal4_indirect_command_buffers count:1];
        uint8_t metal4_indirect_pixels[byte_count];
        [metal4_indirect_texture getBytes:metal4_indirect_pixels bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (metal4_indirect_threads_buffer == nil || metal4_indirect_texture == nil ||
            metal4_indirect_command_buffer == nil || metal4_indirect_encoder == nil ||
            memcmp(native_compute_pixels, metal4_indirect_pixels, byte_count) != 0) {
            fail_with_error("Metal 4 CPU indirect-thread dispatch failed", metal4_error);
            return 63;
        }

        /* Metal 4 timestamp counters are CPU-owned too. Their values are
         * deliberately not compared with native Metal timestamps: the
         * portable adapter exposes a monotonic CPU clock domain, while the
         * native path is used only as the pixel oracle above. Exercise the
         * command-buffer, compute, and render encoder write paths,
         * GPU-address resolution, CPU resolution, and immediate invalidation. */
        MTL4CounterHeapDescriptor *adapter_counter_descriptor = [MTL4CounterHeapDescriptor new];
        adapter_counter_descriptor.type = MTL4CounterHeapTypeTimestamp;
        adapter_counter_descriptor.count = 4;
        id<MTL4CounterHeap> adapter_counter_heap =
            [adapter_device newCounterHeapWithDescriptor:adapter_counter_descriptor error:&metal4_error];
        id<MTLBuffer> adapter_counter_buffer =
            [adapter_device newBufferWithLength:4 * sizeof(MTL4TimestampHeapEntry)
                                        options:MTLResourceStorageModeShared];
        id<MTL4CommandBuffer> adapter_counter_command_buffer = [adapter_device newCommandBuffer];
        [adapter_counter_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        [adapter_counter_command_buffer writeTimestampIntoHeap:adapter_counter_heap atIndex:0];
        id<MTL4ComputeCommandEncoder> adapter_counter_compute_encoder =
            [adapter_counter_command_buffer computeCommandEncoder];
        [adapter_counter_compute_encoder writeTimestampWithGranularity:MTL4TimestampGranularityPrecise
                                                               intoHeap:adapter_counter_heap atIndex:1];
        [adapter_counter_compute_encoder endEncoding];
        [adapter_counter_command_buffer endCommandBuffer];
        [adapter_counter_command_buffer resolveCounterHeap:adapter_counter_heap
                                                 withRange:NSMakeRange(0, 2)
                                                intoBuffer:MTL4BufferRangeMake(adapter_counter_buffer.gpuAddress,
                                                                                2 * sizeof(MTL4TimestampHeapEntry))
                                                 waitFence:nil
                                               updateFence:nil];
        id<MTL4CommandBuffer> adapter_counter_command_buffers[] = {adapter_counter_command_buffer};
        [metal4_queue commit:adapter_counter_command_buffers count:1];
        const MTL4TimestampHeapEntry *adapter_counter_entries =
            (const MTL4TimestampHeapEntry *)adapter_counter_buffer.contents;
        NSData *adapter_counter_resolved = [adapter_counter_heap resolveCounterRange:NSMakeRange(0, 2)];
        if (adapter_counter_heap == nil || adapter_counter_heap.count != 4 ||
            adapter_counter_heap.type != MTL4CounterHeapTypeTimestamp ||
            [adapter_device sizeOfCounterHeapEntry:MTL4CounterHeapTypeTimestamp] != sizeof(MTL4TimestampHeapEntry) ||
            [adapter_device queryTimestampFrequency] != 1000000000ULL ||
            adapter_counter_buffer == nil || adapter_counter_command_buffer == nil ||
            adapter_counter_compute_encoder == nil ||
            adapter_counter_resolved.length != 2 * sizeof(MTL4TimestampHeapEntry) ||
            adapter_counter_entries[0].timestamp == 0 || adapter_counter_entries[1].timestamp == 0 ||
            adapter_counter_entries[0].timestamp >= adapter_counter_entries[1].timestamp) {
            fail_with_error("Metal 4 CPU timestamp counter path failed", metal4_error);
            return 64;
        }
        const uint64_t preserved_counter_timestamp = adapter_counter_entries[1].timestamp;
        [adapter_counter_heap invalidateCounterRange:NSMakeRange(0, 1)];
        NSData *adapter_counter_invalidated = [adapter_counter_heap resolveCounterRange:NSMakeRange(0, 2)];
        const MTL4TimestampHeapEntry *adapter_counter_invalidated_entries =
            (const MTL4TimestampHeapEntry *)adapter_counter_invalidated.bytes;
        if (adapter_counter_invalidated.length != 2 * sizeof(MTL4TimestampHeapEntry) ||
            adapter_counter_invalidated_entries[0].timestamp != 0 ||
            adapter_counter_invalidated_entries[1].timestamp != preserved_counter_timestamp) {
            fail_with_error("Metal 4 CPU timestamp counter invalidation failed", metal4_error);
            return 65;
        }

        MTLCounterSampleBufferDescriptor *adapter_legacy_counter_descriptor =
            [MTLCounterSampleBufferDescriptor new];
        adapter_legacy_counter_descriptor.counterSet = adapter_device.counterSets.firstObject;
        adapter_legacy_counter_descriptor.label = @"zpu-cpu-legacy-timestamps";
        adapter_legacy_counter_descriptor.storageMode = MTLStorageModeShared;
        adapter_legacy_counter_descriptor.sampleCount = 4;
        id<MTLCounterSampleBuffer> adapter_legacy_counter_sample_buffer =
            [adapter_device newCounterSampleBufferWithDescriptor:adapter_legacy_counter_descriptor
                                                            error:&metal4_error];
        id<MTLBuffer> adapter_legacy_counter_buffer =
            [adapter_device newBufferWithLength:4 * sizeof(MTLCounterResultTimestamp)
                                        options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_legacy_counter_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_legacy_counter_encoder =
            [adapter_legacy_counter_command_buffer blitCommandEncoder];
        [adapter_legacy_counter_encoder sampleCountersInBuffer:adapter_legacy_counter_sample_buffer
                                                  atSampleIndex:0 withBarrier:YES];
        [adapter_legacy_counter_encoder sampleCountersInBuffer:adapter_legacy_counter_sample_buffer
                                                  atSampleIndex:1 withBarrier:NO];
        [adapter_legacy_counter_encoder resolveCounters:adapter_legacy_counter_sample_buffer
                                                 inRange:NSMakeRange(0, 2)
                                      destinationBuffer:adapter_legacy_counter_buffer
                                      destinationOffset:0];
        [adapter_legacy_counter_encoder endEncoding];
        [adapter_legacy_counter_command_buffer commit];
        [adapter_legacy_counter_command_buffer waitUntilCompleted];
        const MTLCounterResultTimestamp *adapter_legacy_counter_entries =
            (const MTLCounterResultTimestamp *)adapter_legacy_counter_buffer.contents;
        NSData *adapter_legacy_counter_resolved =
            [adapter_legacy_counter_sample_buffer resolveCounterRange:NSMakeRange(0, 2)];
        if (![adapter_device supportsCounterSampling:MTLCounterSamplingPointAtDrawBoundary] ||
            ![adapter_device supportsCounterSampling:MTLCounterSamplingPointAtDispatchBoundary] ||
            ![adapter_device supportsCounterSampling:MTLCounterSamplingPointAtBlitBoundary] ||
            [adapter_device supportsCounterSampling:MTLCounterSamplingPointAtTileDispatchBoundary] ||
            adapter_device.counterSets.count != 1 || adapter_legacy_counter_sample_buffer == nil ||
            ![adapter_legacy_counter_sample_buffer.label isEqualToString:@"zpu-cpu-legacy-timestamps"] ||
            adapter_legacy_counter_sample_buffer.sampleCount != 4 || adapter_legacy_counter_buffer == nil ||
            adapter_legacy_counter_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_legacy_counter_encoder == nil ||
            adapter_legacy_counter_resolved.length != 2 * sizeof(MTLCounterResultTimestamp) ||
            adapter_legacy_counter_entries[0].timestamp == MTLCounterErrorValue ||
            adapter_legacy_counter_entries[1].timestamp == MTLCounterErrorValue ||
            adapter_legacy_counter_entries[0].timestamp == 0 || adapter_legacy_counter_entries[1].timestamp == 0) {
            fail_with_error("legacy CPU timestamp counter path failed", metal4_error);
            return 68;
        }

        MTLResourceViewPoolDescriptor *adapter_view_pool_descriptor = [MTLResourceViewPoolDescriptor new];
        adapter_view_pool_descriptor.resourceViewCount = 2;
        id<MTLTextureViewPool> adapter_view_pool =
            [adapter_device newTextureViewPoolWithDescriptor:adapter_view_pool_descriptor error:&metal4_error];
        id<MTLTexture> adapter_pool_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        MTLResourceID adapter_pool_texture_id =
            [adapter_view_pool setTextureView:adapter_pool_texture atIndex:0];
        MTLResourceViewPoolDescriptor *adapter_view_pool_copy_descriptor = [MTLResourceViewPoolDescriptor new];
        adapter_view_pool_copy_descriptor.resourceViewCount = 1;
        id<MTLTextureViewPool> adapter_view_pool_copy =
            [adapter_device newTextureViewPoolWithDescriptor:adapter_view_pool_copy_descriptor error:&metal4_error];
        MTLResourceID adapter_copied_view_id =
            [adapter_view_pool_copy copyResourceViewsFromPool:adapter_view_pool
                                                    sourceRange:NSMakeRange(0, 1)
                                               destinationIndex:0];
        MTL4ArgumentTableDescriptor *adapter_pool_table_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_pool_table_descriptor.maxTextureBindCount = 1;
        id<MTL4ArgumentTable> adapter_pool_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_pool_table_descriptor error:&metal4_error];
        [adapter_pool_table setTexture:adapter_copied_view_id atIndex:0];
        id<MTL4CommandBuffer> adapter_pool_command_buffer = [adapter_device newCommandBuffer];
        [adapter_pool_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> adapter_pool_encoder = [adapter_pool_command_buffer computeCommandEncoder];
        [adapter_pool_encoder setComputePipelineState:adapter_compute_pipeline];
        [adapter_pool_encoder setArgumentTable:adapter_pool_table];
        [adapter_pool_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                        threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_pool_encoder endEncoding];
        [adapter_pool_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_pool_command_buffers[] = {adapter_pool_command_buffer};
        [metal4_queue commit:adapter_pool_command_buffers count:1];
        uint8_t adapter_pool_pixels[byte_count];
        [adapter_pool_texture getBytes:adapter_pool_pixels bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (adapter_view_pool == nil || adapter_pool_texture == nil || adapter_pool_texture_id._impl == 0 ||
            adapter_view_pool.baseResourceID._impl != adapter_pool_texture_id._impl ||
            adapter_view_pool.resourceViewCount != 2 || adapter_view_pool_copy == nil ||
            adapter_copied_view_id._impl == 0 || adapter_pool_table == nil ||
            adapter_pool_command_buffer == nil || adapter_pool_encoder == nil ||
            memcmp(native_compute_pixels, adapter_pool_pixels, byte_count) != 0) {
            fail_with_error("CPU texture view pool or resource-ID dispatch failed", metal4_error);
            return 64;
        }

        id<MTLBuffer> metal4_buffer_copy =
            [adapter_device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_texture_copy = [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLBuffer> metal4_texture_back =
            [adapter_device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_buffer_texture = [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLBuffer> metal4_buffer_back =
            [adapter_device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        id<MTLBuffer> metal4_filled_buffer =
            [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTL4CommandBuffer> metal4_copy_command_buffer = [adapter_device newCommandBuffer];
        [metal4_copy_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_copy_encoder = [metal4_copy_command_buffer computeCommandEncoder];
        [metal4_copy_encoder fillBuffer:metal4_filled_buffer range:NSMakeRange(0, 16) value:0xa7];
        [metal4_copy_encoder copyFromBuffer:adapter_copy_buffer sourceOffset:0
                                  toBuffer:metal4_buffer_copy destinationOffset:0 size:byte_count];
        [metal4_copy_encoder copyFromTexture:adapter_compute_texture sourceSlice:0 sourceLevel:0
                                 sourceOrigin:(MTLOrigin){0, 0, 0}
                                   sourceSize:MTLSizeMake(width, height, 1)
                                    toTexture:metal4_texture_copy destinationSlice:0 destinationLevel:0
                              destinationOrigin:(MTLOrigin){0, 0, 0}];
        [metal4_copy_encoder copyFromTexture:metal4_texture_copy sourceSlice:0 sourceLevel:0
                                 sourceOrigin:(MTLOrigin){0, 0, 0}
                                   sourceSize:MTLSizeMake(width, height, 1)
                                    toBuffer:metal4_texture_back destinationOffset:0
                           destinationBytesPerRow:width * 4 destinationBytesPerImage:0];
        [metal4_copy_encoder copyFromBuffer:adapter_copy_buffer sourceOffset:0
                           sourceBytesPerRow:width * 4 sourceBytesPerImage:0
                                  sourceSize:MTLSizeMake(width, height, 1)
                                  toTexture:metal4_buffer_texture destinationSlice:0 destinationLevel:0
                              destinationOrigin:(MTLOrigin){0, 0, 0}];
        [metal4_copy_encoder copyFromTexture:metal4_buffer_texture sourceSlice:0 sourceLevel:0
                                 sourceOrigin:(MTLOrigin){0, 0, 0}
                                   sourceSize:MTLSizeMake(width, height, 1)
                                    toBuffer:metal4_buffer_back destinationOffset:0
                           destinationBytesPerRow:width * 4 destinationBytesPerImage:0];
        [metal4_copy_encoder endEncoding];
        [metal4_copy_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_copy_command_buffers[] = {metal4_copy_command_buffer};
        [metal4_queue commit:metal4_copy_command_buffers count:1];
        if (metal4_buffer_copy == nil || metal4_texture_copy == nil || metal4_texture_back == nil ||
            metal4_buffer_texture == nil || metal4_buffer_back == nil || metal4_filled_buffer == nil ||
            metal4_copy_command_buffer == nil ||
            metal4_copy_encoder == nil ||
            memcmp(adapter_copy_buffer.contents, metal4_buffer_copy.contents, byte_count) != 0 ||
            memcmp(metal4_pixels, metal4_texture_back.contents, byte_count) != 0 ||
            memcmp(adapter_copy_buffer.contents, metal4_buffer_back.contents, byte_count) != 0 ||
            memcmp(metal4_filled_buffer.contents, (const uint8_t[]){0xa7, 0xa7, 0xa7, 0xa7,
                                                                      0xa7, 0xa7, 0xa7, 0xa7,
                                                                      0xa7, 0xa7, 0xa7, 0xa7,
                                                                      0xa7, 0xa7, 0xa7, 0xa7}, 16) != 0) {
            fail_with_error("Metal 4 CPU copy/fill operations failed", metal4_error);
            return 61;
        }

        /* Repeat the compute oracle with BGRA storage and asymmetric
         * coordinates. Equal red/green values at (0,0) must not be enough to
         * hide a channel-order error. */
        MTLTextureDescriptor *bgra_compute_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        bgra_compute_texture_descriptor.storageMode = MTLStorageModeShared;
        bgra_compute_texture_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_bgra_compute_texture =
            [device newTextureWithDescriptor:bgra_compute_texture_descriptor];
        id<MTLCommandBuffer> native_bgra_compute_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_bgra_compute_encoder =
            [native_bgra_compute_command_buffer computeCommandEncoder];
        [native_bgra_compute_encoder setComputePipelineState:native_compute_pipeline];
        [native_bgra_compute_encoder setTexture:native_bgra_compute_texture atIndex:0];
        [native_bgra_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [native_bgra_compute_encoder endEncoding];
        [native_bgra_compute_command_buffer commit];
        [native_bgra_compute_command_buffer waitUntilCompleted];
        uint8_t native_bgra_compute_pixels[byte_count] = {0};
        [native_bgra_compute_texture getBytes:native_bgra_compute_pixels
                                  bytesPerRow:(NSUInteger)width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height)
                                  mipmapLevel:0];

        id<MTLTexture> adapter_bgra_compute_texture =
            [adapter_device newTextureWithDescriptor:bgra_compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_bgra_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_bgra_compute_encoder =
            [adapter_bgra_compute_command_buffer computeCommandEncoder];
        [adapter_bgra_compute_encoder setComputePipelineState:adapter_compute_pipeline];
        [adapter_bgra_compute_encoder setTexture:adapter_bgra_compute_texture atIndex:0];
        [adapter_bgra_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                   threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [adapter_bgra_compute_encoder endEncoding];
        [adapter_bgra_compute_command_buffer commit];
        [adapter_bgra_compute_command_buffer waitUntilCompleted];
        uint8_t adapter_bgra_compute_pixels[byte_count] = {0};
        [adapter_bgra_compute_texture getBytes:adapter_bgra_compute_pixels
                                    bytesPerRow:(NSUInteger)width * 4
                                     fromRegion:MTLRegionMake2D(0, 0, width, height)
                                    mipmapLevel:0];
        if (native_bgra_compute_texture == nil || native_bgra_compute_encoder == nil ||
            native_bgra_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_bgra_compute_texture == nil || adapter_bgra_compute_encoder == nil ||
            adapter_bgra_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_bgra_compute_pixels, adapter_bgra_compute_pixels, byte_count) != 0 ||
            memcmp(adapter_bgra_compute_pixels + 1 * 4, (const uint8_t[]){64, 32, 64, 255}, 4) != 0 ||
            memcmp(adapter_bgra_compute_pixels + 3 * 4, (const uint8_t[]){64, 32, 128, 255}, 4) != 0) {
            fprintf(stderr, "metal-pixel: BGRA compute channel/order mismatch\n");
            return 55;
        }

        id<MTLFunction> native_copy_function = [library newFunctionWithName:@"zpu_cpu_copy_rgba8_buffer_to_texture"];
        id<MTLComputePipelineState> native_copy_pipeline =
            [device newComputePipelineStateWithFunction:native_copy_function error:&error];
        id<MTLBuffer> native_copy_buffer =
            [device newBufferWithBytes:compute_source_bytes length:sizeof(compute_source_bytes)
                               options:MTLResourceStorageModeShared];
        id<MTLTexture> native_copy_texture = [device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> native_copy_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_copy_encoder =
            [native_copy_command_buffer computeCommandEncoder];
        [native_copy_encoder setComputePipelineState:native_copy_pipeline];
        [native_copy_encoder setBuffer:native_copy_buffer offset:0 atIndex:0];
        [native_copy_encoder setTexture:native_copy_texture atIndex:1];
        [native_copy_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                          threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [native_copy_encoder endEncoding];
        [native_copy_command_buffer commit];
        [native_copy_command_buffer waitUntilCompleted];
        uint8_t native_copy_pixels[byte_count];
        [native_copy_texture getBytes:native_copy_pixels bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLFunction> adapter_copy_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_copy_rgba8_buffer_to_texture");
        id<MTLComputePipelineState> adapter_copy_pipeline =
            [adapter_device newComputePipelineStateWithFunction:adapter_copy_function error:&adapter_compute_error];
        id<MTLTexture> adapter_copy_texture = [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_copy_encoder =
            [adapter_copy_command_buffer computeCommandEncoder];
        [adapter_copy_encoder setComputePipelineState:adapter_copy_pipeline];
        [adapter_copy_encoder setBuffer:adapter_copy_buffer offset:0 atIndex:0];
        [adapter_copy_encoder setTexture:adapter_copy_texture atIndex:1];
        [adapter_copy_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                            threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [adapter_copy_encoder endEncoding];
        [adapter_copy_command_buffer commit];
        [adapter_copy_command_buffer waitUntilCompleted];
        uint8_t adapter_copy_pixels[byte_count];
        [adapter_copy_texture getBytes:adapter_copy_pixels bytesPerRow:(NSUInteger)width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_copy_function == nil || native_copy_pipeline == nil || native_copy_buffer == nil ||
            native_copy_texture == nil || native_copy_encoder == nil ||
            native_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_copy_function == nil || adapter_copy_pipeline == nil || adapter_copy_buffer == nil ||
            adapter_copy_texture == nil || adapter_copy_encoder == nil ||
            adapter_copy_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("buffer compute adapter execution failed", adapter_compute_error);
            return 44;
        }
        for (size_t index = 0; index < byte_count; ++index) {
            if (native_copy_pixels[index] != adapter_copy_pixels[index]) {
                fprintf(stderr, "metal-pixel: buffer compute mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, native_copy_pixels[index], adapter_copy_pixels[index]);
                return 45;
            }
        }

        id<MTLBuffer> adapter_pool_view_storage =
            [adapter_device newBufferWithLength:byte_count options:MTLResourceStorageModeShared];
        MTLResourceID adapter_pool_buffer_view_id =
            [adapter_view_pool setTextureViewFromBuffer:adapter_pool_view_storage
                                             descriptor:compute_texture_descriptor
                                                 offset:0 bytesPerRow:width * 4 atIndex:1];
        MTL4ArgumentTableDescriptor *adapter_pool_copy_table_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_pool_copy_table_descriptor.maxBufferBindCount = 1;
        adapter_pool_copy_table_descriptor.maxTextureBindCount = 2;
        id<MTL4ArgumentTable> adapter_pool_copy_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_pool_copy_table_descriptor error:&metal4_error];
        [adapter_pool_copy_table setAddress:adapter_copy_buffer.gpuAddress atIndex:0];
        [adapter_pool_copy_table setTexture:adapter_pool_buffer_view_id atIndex:1];
        id<MTL4CommandBuffer> adapter_pool_copy_command_buffer = [adapter_device newCommandBuffer];
        [adapter_pool_copy_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> adapter_pool_copy_encoder = [adapter_pool_copy_command_buffer computeCommandEncoder];
        [adapter_pool_copy_encoder setComputePipelineState:adapter_copy_pipeline];
        [adapter_pool_copy_encoder setArgumentTable:adapter_pool_copy_table];
        [adapter_pool_copy_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                             threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [adapter_pool_copy_encoder endEncoding];
        [adapter_pool_copy_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_pool_copy_command_buffers[] = {adapter_pool_copy_command_buffer};
        [metal4_queue commit:adapter_pool_copy_command_buffers count:1];
        if (adapter_pool_view_storage == nil || adapter_pool_buffer_view_id._impl == 0 ||
            adapter_pool_copy_table == nil || adapter_pool_copy_command_buffer == nil ||
            adapter_pool_copy_encoder == nil ||
            memcmp(compute_source_bytes, adapter_pool_view_storage.contents, byte_count) != 0) {
            fail_with_error("CPU buffer-backed texture view pool dispatch failed", metal4_error);
            return 65;
        }

        MTLTextureDescriptor *bgra_copy_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        bgra_copy_texture_descriptor.storageMode = MTLStorageModeShared;
        bgra_copy_texture_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_bgra_copy_texture =
            [device newTextureWithDescriptor:bgra_copy_texture_descriptor];
        id<MTLCommandBuffer> native_bgra_copy_command_buffer = [queue commandBuffer];
        id<MTLComputeCommandEncoder> native_bgra_copy_encoder =
            [native_bgra_copy_command_buffer computeCommandEncoder];
        [native_bgra_copy_encoder setComputePipelineState:native_copy_pipeline];
        [native_bgra_copy_encoder setBuffer:native_copy_buffer offset:0 atIndex:0];
        [native_bgra_copy_encoder setTexture:native_bgra_copy_texture atIndex:1];
        [native_bgra_copy_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [native_bgra_copy_encoder endEncoding];
        [native_bgra_copy_command_buffer commit];
        [native_bgra_copy_command_buffer waitUntilCompleted];
        uint8_t native_bgra_copy_pixels[byte_count] = {0};
        [native_bgra_copy_texture getBytes:native_bgra_copy_pixels bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLTexture> adapter_bgra_copy_texture =
            [adapter_device newTextureWithDescriptor:bgra_copy_texture_descriptor];
        id<MTLCommandBuffer> adapter_bgra_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_bgra_copy_encoder =
            [adapter_bgra_copy_command_buffer computeCommandEncoder];
        [adapter_bgra_copy_encoder setComputePipelineState:adapter_copy_pipeline];
        [adapter_bgra_copy_encoder setBuffer:adapter_copy_buffer offset:0 atIndex:0];
        [adapter_bgra_copy_encoder setTexture:adapter_bgra_copy_texture atIndex:1];
        [adapter_bgra_copy_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                 threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        [adapter_bgra_copy_encoder endEncoding];
        [adapter_bgra_copy_command_buffer commit];
        [adapter_bgra_copy_command_buffer waitUntilCompleted];
        uint8_t adapter_bgra_copy_pixels[byte_count] = {0};
        [adapter_bgra_copy_texture getBytes:adapter_bgra_copy_pixels bytesPerRow:(NSUInteger)width * 4
                                 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_bgra_copy_texture == nil || native_bgra_copy_encoder == nil ||
            native_bgra_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_bgra_copy_texture == nil || adapter_bgra_copy_encoder == nil ||
            adapter_bgra_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_bgra_copy_pixels, adapter_bgra_copy_pixels, byte_count) != 0 ||
            memcmp(adapter_bgra_copy_pixels + 1 * 4, (const uint8_t[]){105, 88, 71, 122}, 4) != 0) {
            fprintf(stderr, "metal-pixel: BGRA buffer compute channel/order mismatch "
                    "native=[%u,%u,%u,%u] adapter=[%u,%u,%u,%u]\n",
                    native_bgra_copy_pixels[4], native_bgra_copy_pixels[5],
                    native_bgra_copy_pixels[6], native_bgra_copy_pixels[7],
                    adapter_bgra_copy_pixels[4], adapter_bgra_copy_pixels[5],
                    adapter_bgra_copy_pixels[6], adapter_bgra_copy_pixels[7]);
            return 57;
        }

        /* Indirect compute is still CPU-recorded on the adapter. Apple's
         * implementation is used only to establish the byte oracle. The
         * output texture is inherited from the compute encoder while the
         * indirect command supplies the pipeline, source buffer, and grid. */
        MTLIndirectCommandBufferDescriptor *compute_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        compute_icb_descriptor.commandTypes = MTLIndirectCommandTypeConcurrentDispatchThreads;
        compute_icb_descriptor.inheritBuffers = YES;
        compute_icb_descriptor.maxKernelBufferBindCount = 1;
        MTLComputePipelineDescriptor *adapter_icb_compute_descriptor = [MTLComputePipelineDescriptor new];
        adapter_icb_compute_descriptor.computeFunction = adapter_copy_function;
        adapter_icb_compute_descriptor.supportIndirectCommandBuffers = YES;
        id<MTLComputePipelineState> adapter_icb_compute_pipeline =
            [adapter_device newComputePipelineStateWithDescriptor:adapter_icb_compute_descriptor
                                                            options:0 reflection:nil error:&adapter_compute_error];
        id<MTLIndirectCommandBuffer> adapter_compute_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:compute_icb_descriptor
                                                     maxCommandCount:1 options:MTLResourceStorageModeShared];
        id<MTLIndirectComputeCommand> adapter_compute_icb_command =
            [adapter_compute_icb indirectComputeCommandAtIndex:0];
        [adapter_compute_icb_command setComputePipelineState:adapter_icb_compute_pipeline];
        [adapter_compute_icb_command setKernelBuffer:adapter_copy_buffer offset:0 atIndex:0];
        [adapter_compute_icb_command concurrentDispatchThreads:MTLSizeMake(width, height, 1)
                                           threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        id<MTLTexture> adapter_compute_icb_texture = [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_compute_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_compute_icb_encoder =
            [adapter_compute_icb_command_buffer computeCommandEncoder];
        [adapter_compute_icb_encoder setTexture:adapter_compute_icb_texture atIndex:1];
        [adapter_compute_icb_encoder executeCommandsInBuffer:adapter_compute_icb withRange:NSMakeRange(0, 1)];
        [adapter_compute_icb_encoder endEncoding];
        [adapter_compute_icb_command_buffer commit];
        [adapter_compute_icb_command_buffer waitUntilCompleted];
        uint8_t adapter_compute_icb_pixels[byte_count];
        [adapter_compute_icb_texture getBytes:adapter_compute_icb_pixels bytesPerRow:(NSUInteger)width * 4
                                    fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (adapter_icb_compute_pipeline == nil || adapter_compute_icb == nil || adapter_compute_icb_command == nil ||
            adapter_compute_icb_texture == nil || adapter_compute_icb_encoder == nil ||
            adapter_compute_icb_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fail_with_error("indirect compute adapter execution failed", adapter_compute_error);
            return 46;
        }
        for (size_t index = 0; index < byte_count; ++index) {
            if (native_copy_pixels[index] != adapter_compute_icb_pixels[index]) {
                fprintf(stderr, "metal-pixel: indirect compute mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, native_copy_pixels[index], adapter_compute_icb_pixels[index]);
                return 47;
            }
        }

        id<MTLIndirectCommandBuffer> adapter_copied_compute_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:compute_icb_descriptor
                                                    maxCommandCount:1 options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_compute_icb_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_compute_icb_copy_encoder =
            [adapter_compute_icb_copy_command_buffer blitCommandEncoder];
        [adapter_compute_icb_copy_encoder copyIndirectCommandBuffer:adapter_compute_icb
                                                           sourceRange:NSMakeRange(0, 1)
                                                          destination:adapter_copied_compute_icb
                                                     destinationIndex:0];
        [adapter_compute_icb_copy_encoder endEncoding];
        [adapter_compute_icb_copy_command_buffer commit];
        [adapter_compute_icb_copy_command_buffer waitUntilCompleted];
        id<MTLTexture> adapter_copied_compute_icb_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_copied_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_copied_compute_encoder =
            [adapter_copied_compute_command_buffer computeCommandEncoder];
        [adapter_copied_compute_encoder setTexture:adapter_copied_compute_icb_texture atIndex:1];
        [adapter_copied_compute_encoder executeCommandsInBuffer:adapter_copied_compute_icb withRange:NSMakeRange(0, 1)];
        [adapter_copied_compute_encoder endEncoding];
        [adapter_copied_compute_command_buffer commit];
        [adapter_copied_compute_command_buffer waitUntilCompleted];
        uint8_t adapter_copied_compute_icb_pixels[byte_count];
        [adapter_copied_compute_icb_texture getBytes:adapter_copied_compute_icb_pixels
                                          bytesPerRow:(NSUInteger)width * 4
                                           fromRegion:MTLRegionMake2D(0, 0, width, height)
                                          mipmapLevel:0];
        if (adapter_copied_compute_icb == nil ||
            adapter_compute_icb_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_copied_compute_icb_texture == nil || adapter_copied_compute_encoder == nil ||
            adapter_copied_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_copy_pixels, adapter_copied_compute_icb_pixels, byte_count) != 0) {
            fprintf(stderr, "metal-pixel: copied indirect compute command buffer mismatch\n");
            return 59;
        }

        MTLArgumentDescriptor *adapter_argument_descriptor = [MTLArgumentDescriptor argumentDescriptor];
        adapter_argument_descriptor.dataType = MTLDataTypePointer;
        adapter_argument_descriptor.index = 0;
        id<MTLArgumentEncoder> adapter_argument_encoder =
            [adapter_device newArgumentEncoderWithArguments:@[adapter_argument_descriptor]];
        id<MTLBuffer> adapter_argument_buffer =
            [adapter_device newBufferWithLength:128 options:MTLResourceStorageModeShared];
        uint32_t argument_constant = 0x5a50555f;
        void *constant_data = [adapter_argument_encoder constantDataAtIndex:5];
        if (constant_data == NULL) {
            fprintf(stderr, "metal-pixel: CPU argument encoder constant storage failed\n");
            return 48;
        }
        memcpy(constant_data, &argument_constant, sizeof(argument_constant));
        [adapter_argument_encoder setArgumentBuffer:adapter_argument_buffer offset:0];
        void *bound_constant_data = [adapter_argument_encoder constantDataAtIndex:5];
        [adapter_argument_encoder setBuffer:adapter_copy_buffer offset:0 atIndex:0];
        [adapter_argument_encoder setTexture:adapter_compute_icb_texture atIndex:1];
        [adapter_argument_encoder setSamplerState:adapter_sampler atIndex:4];
        [adapter_argument_encoder setComputePipelineState:adapter_icb_compute_pipeline atIndex:2];
        [adapter_argument_encoder setIndirectCommandBuffer:adapter_compute_icb atIndex:3];
        id<MTLArgumentEncoder> nested_argument_encoder =
            [adapter_argument_encoder newArgumentEncoderForBufferAtIndex:0];
        uint64_t encoded_argument_resource = 0;
        uint64_t encoded_argument_offset = 0;
        if (adapter_argument_buffer != nil) {
            memcpy(&encoded_argument_resource, adapter_argument_buffer.contents, sizeof(encoded_argument_resource));
            memcpy(&encoded_argument_offset, (uint8_t *)adapter_argument_buffer.contents + sizeof(encoded_argument_resource), sizeof(encoded_argument_offset));
        }
        if (adapter_argument_encoder == nil || adapter_argument_buffer == nil || nested_argument_encoder == nil ||
            [adapter_argument_encoder encodedLength] < 16 || [adapter_argument_encoder alignment] != 16 ||
            bound_constant_data == NULL || memcmp(bound_constant_data, &argument_constant, sizeof(argument_constant)) != 0 ||
            encoded_argument_resource != adapter_copy_buffer.gpuAddress || encoded_argument_offset != 0) {
            fprintf(stderr, "metal-pixel: CPU argument encoder allocation failed\n");
            return 49;
        }

        __block BOOL no_copy_freed = NO;
        uint8_t *no_copy_memory = (uint8_t *)malloc(16);
        if (no_copy_memory == NULL) {
            fprintf(stderr, "metal-pixel: no-copy test allocation failed\n");
            return 42;
        }
        memset(no_copy_memory, 0x4d, 16);
        @autoreleasepool {
            id<MTLBuffer> no_copy_buffer =
                [adapter_device newBufferWithBytesNoCopy:no_copy_memory length:16
                                                 options:MTLResourceStorageModeShared
                                             deallocator:^(void *pointer, NSUInteger length) {
                                                 (void)length;
                                                 no_copy_freed = YES;
                                                 free(pointer);
                                             }];
            if (no_copy_buffer == nil) {
                free(no_copy_memory);
                fprintf(stderr, "metal-pixel: no-copy adapter allocation failed\n");
                return 43;
            }
            if (no_copy_buffer.contents != no_copy_memory) {
                no_copy_buffer = nil;
                fprintf(stderr, "metal-pixel: no-copy adapter did not alias caller storage\n");
                return 43;
            }
            ((uint8_t *)no_copy_buffer.contents)[0] = 0x91;
            if (no_copy_memory[0] != 0x91) {
                no_copy_buffer = nil;
                fprintf(stderr, "metal-pixel: no-copy adapter alias write failed\n");
                return 43;
            }
            no_copy_buffer = nil;
        }
        if (!no_copy_freed) {
            fprintf(stderr, "metal-pixel: no-copy adapter deallocator was not deferred\n");
            return 43;
        }
        id<MTLSharedEvent> adapter_event = [adapter_device newSharedEvent];
        MTLSharedEventListener *adapter_event_listener = [MTLSharedEventListener new];
        __block BOOL adapter_event_notified = NO;
        [adapter_event notifyListener:adapter_event_listener atValue:7 block:^(id<MTLSharedEvent> event, uint64_t value) {
            (void)event;
            adapter_event_notified = value >= 7;
        }];
        adapter_event.signaledValue = 7;
        dispatch_sync(adapter_event_listener.dispatchQueue, ^{});
        MTLSharedEventHandle *adapter_event_handle = [adapter_event newSharedEventHandle];
        id<MTLSharedEvent> adapter_event_from_handle =
            [adapter_device newSharedEventWithHandle:adapter_event_handle];
        adapter_event_from_handle.signaledValue = 11;
        if (adapter_event == nil || !adapter_event_notified ||
            adapter_event_handle == nil || adapter_event_from_handle != adapter_event ||
            adapter_event.signaledValue != 11 ||
            ![adapter_event waitUntilSignaledValue:7 timeoutMS:0]) {
            fprintf(stderr, "metal-pixel: shared event adapter failed\n");
            return 19;
        }
        id<MTLTexture> adapter_shared_texture =
            [adapter_device newSharedTextureWithDescriptor:adapter_texture_descriptor];
        MTLSharedTextureHandle *adapter_shared_texture_handle = [adapter_shared_texture newSharedTextureHandle];
        id<MTLTexture> adapter_shared_texture_from_handle =
            [adapter_device newSharedTextureWithHandle:adapter_shared_texture_handle];
        if (adapter_shared_texture == nil || !adapter_shared_texture.isShareable ||
            adapter_shared_texture_handle == nil || adapter_shared_texture_from_handle != adapter_shared_texture ||
            adapter_shared_texture_from_handle.width != adapter_shared_texture.width ||
            adapter_shared_texture_from_handle.height != adapter_shared_texture.height) {
            fprintf(stderr, "metal-pixel: shared texture handle adapter failed\n");
            return 74;
        }
        id<MTLEvent> adapter_command_event = [adapter_device newEvent];
        id<MTLCommandBuffer> adapter_event_command_buffer = [adapter_queue commandBuffer];
        [adapter_event_command_buffer encodeSignalEvent:adapter_command_event value:9];
        [adapter_event_command_buffer encodeWaitForEvent:adapter_command_event value:9];
        [adapter_event_command_buffer commit];
        [adapter_event_command_buffer waitUntilScheduled];
        [adapter_event_command_buffer waitUntilCompleted];
        if (adapter_command_event == nil || adapter_event_command_buffer == nil ||
            adapter_event_command_buffer.status != MTLCommandBufferStatusCompleted ||
            ((id<MTLSharedEvent>)adapter_command_event).signaledValue != 9) {
            fprintf(stderr, "metal-pixel: deferred command event adapter failed\n");
            return 51;
        }
        id<MTLTexture> adapter_origin_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLBuffer> adapter_origin_vertex_buffer =
            [adapter_device newBufferWithBytes:origin_vertices length:sizeof(origin_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_origin_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_origin_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_origin_pass.colorAttachments[0].texture = adapter_origin_texture;
        adapter_origin_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_origin_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_origin_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLRenderCommandEncoder> adapter_origin_encoder =
            [adapter_origin_command_buffer renderCommandEncoderWithDescriptor:adapter_origin_pass];
        [adapter_origin_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_origin_encoder setViewport:origin_viewport];
        [adapter_origin_encoder setScissorRect:origin_scissor];
        [adapter_origin_encoder setVertexBuffer:adapter_origin_vertex_buffer offset:0 atIndex:0];
        [adapter_origin_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [adapter_origin_encoder sampleCountersInBuffer:adapter_legacy_counter_sample_buffer
                                          atSampleIndex:2 withBarrier:YES];
        [adapter_origin_encoder endEncoding];
        [adapter_origin_command_buffer commit];
        [adapter_origin_command_buffer waitUntilCompleted];
        uint8_t adapter_origin_pixels[byte_count];
        [adapter_origin_texture getBytes:adapter_origin_pixels
                              bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height)
                              mipmapLevel:0];
        if (adapter_origin_texture == nil || adapter_origin_vertex_buffer == nil ||
            adapter_origin_command_buffer == nil || adapter_origin_encoder == nil ||
            adapter_origin_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_origin_pixels, adapter_origin_pixels, sizeof(metal_origin_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: Objective-C adapter origin-coordinate mismatch\n");
            return 53;
        }
        /* Visibility results are produced by the CPU rasterizer from the
         * same covered-fragment/depth/stencil accounting used for color.
         * Native Metal is only the oracle: both adapter resources and writes
         * stay in ZPU-owned CPU memory. Test both 64-bit counting and boolean
         * modes at aligned offsets. */
        enum { visibility_result_bytes = 16 };
        id<MTLBuffer> native_visibility_buffer =
            [device newBufferWithLength:visibility_result_bytes options:MTLResourceStorageModeShared];
        id<MTLTexture> native_visibility_texture = [device newTextureWithDescriptor:texture_descriptor];
        if (native_visibility_buffer == nil || native_visibility_texture == nil) {
            fprintf(stderr, "metal-pixel: native visibility resources failed\n");
            return 90;
        }
        memset(native_visibility_buffer.contents, 0xa5, visibility_result_bytes);
        MTLRenderPassDescriptor *native_visibility_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_visibility_pass.colorAttachments[0].texture = native_visibility_texture;
        native_visibility_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_visibility_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_visibility_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        native_visibility_pass.visibilityResultBuffer = native_visibility_buffer;
        id<MTLCommandBuffer> native_visibility_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_visibility_encoder =
            [native_visibility_command_buffer renderCommandEncoderWithDescriptor:native_visibility_pass];
        [native_visibility_encoder setRenderPipelineState:pipeline];
        [native_visibility_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_visibility_encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
        [native_visibility_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_visibility_encoder setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:8];
        [native_visibility_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_visibility_encoder endEncoding];
        [native_visibility_command_buffer commit];
        [native_visibility_command_buffer waitUntilCompleted];
        if (native_visibility_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: native visibility command did not complete\n");
            return 91;
        }

        id<MTLBuffer> adapter_visibility_buffer =
            [adapter_device newBufferWithLength:visibility_result_bytes options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_visibility_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_visibility_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_visibility_pass.colorAttachments[0].texture = adapter_visibility_texture;
        adapter_visibility_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_visibility_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_visibility_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_visibility_pass.visibilityResultBuffer = adapter_visibility_buffer;
        id<MTLCommandBuffer> adapter_visibility_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_visibility_encoder =
            [adapter_visibility_command_buffer renderCommandEncoderWithDescriptor:adapter_visibility_pass];
        if (adapter_visibility_buffer == nil || adapter_visibility_texture == nil ||
            adapter_visibility_command_buffer == nil || adapter_visibility_encoder == nil) {
            fprintf(stderr, "metal-pixel: adapter visibility resources failed\n");
            return 92;
        }
        memset(adapter_visibility_buffer.contents, 0xa5, visibility_result_bytes);
        [adapter_visibility_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_visibility_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_visibility_encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
        [adapter_visibility_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_visibility_encoder setVisibilityResultMode:MTLVisibilityResultModeBoolean offset:8];
        [adapter_visibility_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_visibility_encoder endEncoding];
        [adapter_visibility_command_buffer commit];
        [adapter_visibility_command_buffer waitUntilCompleted];
        if (adapter_visibility_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_visibility_buffer.contents, adapter_visibility_buffer.contents, visibility_result_bytes) != 0) {
            const uint64_t native_count = *(const uint64_t *)native_visibility_buffer.contents;
            const uint64_t adapter_count = *(const uint64_t *)adapter_visibility_buffer.contents;
            const uint64_t native_boolean = *(const uint64_t *)((const uint8_t *)native_visibility_buffer.contents + 8);
            const uint64_t adapter_boolean = *(const uint64_t *)((const uint8_t *)adapter_visibility_buffer.contents + 8);
            fprintf(stderr, "metal-pixel: visibility mismatch count=%llu/%llu boolean=%llu/%llu\n",
                    (unsigned long long)native_count, (unsigned long long)adapter_count,
                    (unsigned long long)native_boolean, (unsigned long long)adapter_boolean);
            return 93;
        }
        NSData *adapter_legacy_render_counter_resolved =
            [adapter_legacy_counter_sample_buffer resolveCounterRange:NSMakeRange(2, 1)];
        const MTLCounterResultTimestamp *adapter_legacy_render_counter_entry =
            (const MTLCounterResultTimestamp *)adapter_legacy_render_counter_resolved.bytes;
        if (adapter_legacy_render_counter_resolved.length != sizeof(MTLCounterResultTimestamp) ||
            adapter_legacy_render_counter_entry[0].timestamp == MTLCounterErrorValue ||
            adapter_legacy_render_counter_entry[0].timestamp == 0) {
            fail_with_error("legacy CPU render timestamp path failed", metal4_error);
            return 69;
        }

        /* MTL4 uses the same top-left attachment pixel grid as legacy Metal,
         * but carries vertex/index resources as opaque GPU addresses. Verify
         * that the CPU-owned MTL4 bridge preserves both the non-zero viewport
         * origin and the clip-space +Y-to-row direction. The reference bytes
         * above came from Apple's native Metal path; this command executes
         * only through ZPU. */
        id<MTLTexture> adapter_metal4_origin_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTL4RenderPassDescriptor *adapter_metal4_origin_pass = [MTL4RenderPassDescriptor new];
        adapter_metal4_origin_pass.colorAttachments[0].texture = adapter_metal4_origin_texture;
        adapter_metal4_origin_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_origin_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_origin_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        MTL4ArgumentTableDescriptor *adapter_metal4_origin_table_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_origin_table_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_origin_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_origin_table_descriptor error:&metal4_error];
        [adapter_metal4_origin_table setAddress:adapter_origin_vertex_buffer.gpuAddress atIndex:0];
        id<MTL4CommandBuffer> adapter_metal4_origin_command_buffer = [adapter_device newCommandBuffer];
        [adapter_metal4_origin_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_origin_encoder =
            [adapter_metal4_origin_command_buffer renderCommandEncoderWithDescriptor:adapter_metal4_origin_pass];
        [adapter_metal4_origin_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_metal4_origin_encoder setViewport:origin_viewport];
        [adapter_metal4_origin_encoder setScissorRect:origin_scissor];
        [adapter_metal4_origin_encoder setArgumentTable:adapter_metal4_origin_table
                                                atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [adapter_metal4_origin_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [adapter_metal4_origin_encoder writeTimestampWithGranularity:MTL4TimestampGranularityPrecise
                                                            afterStage:MTLRenderStageFragment
                                                             intoHeap:adapter_counter_heap atIndex:2];
        [adapter_metal4_origin_encoder endEncoding];
        [adapter_metal4_origin_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_origin_command_buffers[] = {adapter_metal4_origin_command_buffer};
        [metal4_queue commit:adapter_metal4_origin_command_buffers count:1];
        uint8_t adapter_metal4_origin_pixels[byte_count];
        [adapter_metal4_origin_texture getBytes:adapter_metal4_origin_pixels
                                      bytesPerRow:(NSUInteger)width * 4
                                       fromRegion:MTLRegionMake2D(0, 0, width, height)
                                      mipmapLevel:0];
        if (adapter_metal4_origin_texture == nil || adapter_metal4_origin_table == nil ||
            adapter_metal4_origin_command_buffer == nil || adapter_metal4_origin_encoder == nil ||
            memcmp(metal_origin_pixels, adapter_metal4_origin_pixels, sizeof(metal_origin_pixels)) != 0) {
            fail_with_error("Metal 4 CPU origin-coordinate render failed", metal4_error);
            return 62;
        }
        NSData *adapter_render_counter_resolved = [adapter_counter_heap resolveCounterRange:NSMakeRange(2, 1)];
        const MTL4TimestampHeapEntry *adapter_render_counter_entry =
            (const MTL4TimestampHeapEntry *)adapter_render_counter_resolved.bytes;
        if (adapter_render_counter_resolved.length != sizeof(MTL4TimestampHeapEntry) ||
            adapter_render_counter_entry[0].timestamp == 0) {
            fail_with_error("Metal 4 CPU render timestamp path failed", metal4_error);
            return 67;
        }

        /* Metal 4 splits argument-table bindings by stage. Bind the vertex
         * buffer through one table and the uniform fragment buffer through a
         * second table, then compare the CPU/ZPU result with the native
         * buffer-binding oracle above. The uniform buffer is already the
         * post-encode value, proving the CPU path reads it at commit. */
        id<MTLTexture> adapter_metal4_uniform_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLBuffer> adapter_metal4_uniform_buffer =
            [adapter_device newBufferWithBytes:uniform_color length:sizeof(uniform_color)
                                        options:MTLResourceStorageModeShared];
        MTL4RenderPassDescriptor *adapter_metal4_uniform_pass = [MTL4RenderPassDescriptor new];
        adapter_metal4_uniform_pass.colorAttachments[0].texture = adapter_metal4_uniform_texture;
        adapter_metal4_uniform_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_uniform_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_uniform_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        MTL4ArgumentTableDescriptor *adapter_metal4_uniform_vertex_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_uniform_vertex_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_uniform_vertex_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_uniform_vertex_descriptor error:&metal4_error];
        [adapter_metal4_uniform_vertex_table setAddress:adapter_vertex_buffer.gpuAddress atIndex:0];
        MTL4ArgumentTableDescriptor *adapter_metal4_uniform_fragment_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_uniform_fragment_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_uniform_fragment_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_uniform_fragment_descriptor error:&metal4_error];
        [adapter_metal4_uniform_fragment_table setAddress:adapter_metal4_uniform_buffer.gpuAddress atIndex:0];
        id<MTL4CommandBuffer> adapter_metal4_uniform_command_buffer = [adapter_device newCommandBuffer];
        [adapter_metal4_uniform_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_uniform_encoder =
            [adapter_metal4_uniform_command_buffer renderCommandEncoderWithDescriptor:adapter_metal4_uniform_pass];
        [adapter_metal4_uniform_encoder setRenderPipelineState:adapter_uniform_pipeline];
        [adapter_metal4_uniform_encoder setArgumentTable:adapter_metal4_uniform_vertex_table atStages:MTLRenderStageVertex];
        [adapter_metal4_uniform_encoder setArgumentTable:adapter_metal4_uniform_fragment_table atStages:MTLRenderStageFragment];
        [adapter_metal4_uniform_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_metal4_uniform_encoder endEncoding];
        [adapter_metal4_uniform_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_uniform_command_buffers[] = {adapter_metal4_uniform_command_buffer};
        [metal4_queue commit:adapter_metal4_uniform_command_buffers count:1];
        uint8_t adapter_metal4_uniform_pixels[byte_count];
        [adapter_metal4_uniform_texture getBytes:adapter_metal4_uniform_pixels
                                      bytesPerRow:(NSUInteger)width * 4
                                       fromRegion:MTLRegionMake2D(0, 0, width, height)
                                      mipmapLevel:0];
        if (adapter_metal4_uniform_texture == nil || adapter_metal4_uniform_buffer == nil ||
            adapter_metal4_uniform_vertex_table == nil ||
            adapter_metal4_uniform_fragment_table == nil || adapter_metal4_uniform_command_buffer == nil ||
            adapter_metal4_uniform_encoder == nil ||
            memcmp(native_uniform_buffer_bytes, adapter_metal4_uniform_pixels, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_uniform_buffer_bytes[mismatch] == adapter_metal4_uniform_pixels[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: Metal 4 uniform fragment buffer mismatch (mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    mismatch,
                    mismatch < byte_count ? native_uniform_buffer_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_metal4_uniform_pixels[mismatch] : 0);
            return 100;
        }

        /* MTL4 carries the same visibility mode but sources its result buffer
         * from the render-pass descriptor. Verify that descriptor path also
         * stays CPU-owned and agrees with the native legacy oracle. */
        id<MTLBuffer> adapter_metal4_visibility_buffer =
            [adapter_device newBufferWithLength:sizeof(uint64_t) options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_metal4_visibility_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTL4RenderPassDescriptor *adapter_metal4_visibility_pass = [MTL4RenderPassDescriptor new];
        adapter_metal4_visibility_pass.colorAttachments[0].texture = adapter_metal4_visibility_texture;
        adapter_metal4_visibility_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_visibility_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_visibility_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_metal4_visibility_pass.visibilityResultBuffer = adapter_metal4_visibility_buffer;
        adapter_metal4_visibility_pass.visibilityResultType = MTLVisibilityResultTypeReset;
        MTL4ArgumentTableDescriptor *adapter_metal4_visibility_table_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_visibility_table_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_visibility_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_visibility_table_descriptor error:&metal4_error];
        [adapter_metal4_visibility_table setAddress:adapter_vertex_buffer.gpuAddress atIndex:0];
        id<MTL4CommandBuffer> adapter_metal4_visibility_command_buffer = [adapter_device newCommandBuffer];
        [adapter_metal4_visibility_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_visibility_encoder =
            [adapter_metal4_visibility_command_buffer renderCommandEncoderWithDescriptor:adapter_metal4_visibility_pass];
        [adapter_metal4_visibility_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_metal4_visibility_encoder setArgumentTable:adapter_metal4_visibility_table
                                                    atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [adapter_metal4_visibility_encoder setVisibilityResultMode:MTLVisibilityResultModeCounting offset:0];
        [adapter_metal4_visibility_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_metal4_visibility_encoder endEncoding];
        [adapter_metal4_visibility_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_visibility_command_buffers[] = {adapter_metal4_visibility_command_buffer};
        [metal4_queue commit:adapter_metal4_visibility_command_buffers count:1];
        const uint64_t native_visibility_count = *(const uint64_t *)native_visibility_buffer.contents;
        const uint64_t adapter_metal4_visibility_count = *(const uint64_t *)adapter_metal4_visibility_buffer.contents;
        if (adapter_metal4_visibility_buffer == nil || adapter_metal4_visibility_texture == nil ||
            adapter_metal4_visibility_table == nil || adapter_metal4_visibility_encoder == nil ||
            adapter_metal4_visibility_command_buffer == nil ||
            native_visibility_count != adapter_metal4_visibility_count) {
            fprintf(stderr, "metal-pixel: Metal 4 visibility mismatch native=%llu adapter=%llu\n",
                    (unsigned long long)native_visibility_count,
                    (unsigned long long)adapter_metal4_visibility_count);
            return 94;
        }

        id<MTLTexture> adapter_metal4_split_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTL4RenderPassDescriptor *adapter_metal4_split_pass_a = [MTL4RenderPassDescriptor new];
        adapter_metal4_split_pass_a.colorAttachments[0].texture = adapter_metal4_split_texture;
        adapter_metal4_split_pass_a.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_split_pass_a.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_split_pass_a.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        MTL4RenderPassDescriptor *adapter_metal4_split_pass_b = [MTL4RenderPassDescriptor new];
        adapter_metal4_split_pass_b.colorAttachments[0].texture = adapter_metal4_split_texture;
        adapter_metal4_split_pass_b.colorAttachments[0].loadAction = MTLLoadActionLoad;
        adapter_metal4_split_pass_b.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTL4CommandBuffer> adapter_metal4_split_command_buffer_a = [adapter_device newCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_split_command_buffer_b = [adapter_device newCommandBuffer];
        [adapter_metal4_split_command_buffer_a beginCommandBufferWithAllocator:metal4_allocator];
        [adapter_metal4_split_command_buffer_b beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_split_encoder_a =
            [adapter_metal4_split_command_buffer_a renderCommandEncoderWithDescriptor:adapter_metal4_split_pass_a
                                                                                options:MTL4RenderEncoderOptionSuspending];
        id<MTL4RenderCommandEncoder> adapter_metal4_split_encoder_b =
            [adapter_metal4_split_command_buffer_b renderCommandEncoderWithDescriptor:adapter_metal4_split_pass_b
                                                                                options:MTL4RenderEncoderOptionResuming];
        [adapter_metal4_split_encoder_a setRenderPipelineState:adapter_pipeline];
        [adapter_metal4_split_encoder_a setViewport:origin_viewport];
        [adapter_metal4_split_encoder_a setScissorRect:origin_scissor];
        [adapter_metal4_split_encoder_a setArgumentTable:adapter_metal4_origin_table
                                                 atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [adapter_metal4_split_encoder_a drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_metal4_split_encoder_a endEncoding];
        [adapter_metal4_split_encoder_b setRenderPipelineState:adapter_pipeline];
        [adapter_metal4_split_encoder_b setViewport:origin_viewport];
        [adapter_metal4_split_encoder_b setScissorRect:origin_scissor];
        [adapter_metal4_split_encoder_b setArgumentTable:adapter_metal4_origin_table
                                                 atStages:MTLRenderStageVertex | MTLRenderStageFragment];
        [adapter_metal4_split_encoder_b drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:6 vertexCount:6];
        [adapter_metal4_split_encoder_b endEncoding];
        [adapter_metal4_split_command_buffer_a endCommandBuffer];
        [adapter_metal4_split_command_buffer_b endCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_split_command_buffers[] = {
            adapter_metal4_split_command_buffer_a, adapter_metal4_split_command_buffer_b};
        [metal4_queue commit:adapter_metal4_split_command_buffers count:2];
        uint8_t adapter_metal4_split_pixels[byte_count];
        [adapter_metal4_split_texture getBytes:adapter_metal4_split_pixels
                                     bytesPerRow:(NSUInteger)width * 4
                                      fromRegion:MTLRegionMake2D(0, 0, width, height)
                                     mipmapLevel:0];
        if (adapter_metal4_split_texture == nil || adapter_metal4_split_command_buffer_a == nil ||
            adapter_metal4_split_command_buffer_b == nil || adapter_metal4_split_encoder_a == nil ||
            adapter_metal4_split_encoder_b == nil ||
            memcmp(metal_origin_pixels, adapter_metal4_split_pixels, sizeof(metal_origin_pixels)) != 0) {
            fail_with_error("Metal 4 CPU suspending/resuming render failed", metal4_error);
            return 66;
        }
        [adapter_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_encoder setViewport:(MTLViewport){0.0, 0.0, width, height, 0.0, 1.0}];
        [adapter_encoder setScissorRect:(MTLScissorRect){0, 0, width, height}];
        [adapter_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_encoder endEncoding];
        __block BOOL adapter_scheduled = NO;
        __block BOOL adapter_scheduled_state = NO;
        __block BOOL adapter_completed = NO;
        [adapter_command_buffer addScheduledHandler:^(id<MTLCommandBuffer> buffer) {
            adapter_scheduled = YES;
            adapter_scheduled_state = buffer.status == MTLCommandBufferStatusScheduled;
        }];
        [adapter_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            (void)buffer;
            adapter_completed = YES;
        }];
        [adapter_command_buffer commit];
        [adapter_command_buffer waitUntilCompleted];
        if (adapter_command_buffer.status != MTLCommandBufferStatusCompleted ||
            !adapter_scheduled || !adapter_scheduled_state || !adapter_completed) {
            fprintf(stderr, "metal-pixel: Objective-C adapter command did not complete\n");
            return 20;
        }
        uint8_t adapter_pixels[byte_count];
        memset(adapter_pixels, 0xa5, sizeof(adapter_pixels));
        [adapter_texture getBytes:adapter_pixels
                       bytesPerRow:(NSUInteger)width * 4
                        fromRegion:MTLRegionMake2D(0, 0, width, height)
                       mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_pixels[index] != adapter_pixels[index]) {
                fprintf(stderr, "metal-pixel: Objective-C adapter mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_pixels[index], adapter_pixels[index]);
                return 21;
            }
        }

        /* Blend factors and write masks are part of the render-pipeline
         * contract. Compare a translucent red quad over a blue clear in both
         * implementations so channel arithmetic and destination preservation
         * are tested byte-for-byte. */
        const zpu_metal_vertex blend_vertices[] = {
            {{-1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
            {{ 1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
            {{ 1.0f,  1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
            {{-1.0f, -1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
            {{ 1.0f,  1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
            {{-1.0f,  1.0f, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 0.5f}},
        };
        MTLRenderPipelineDescriptor *blend_descriptor = [MTLRenderPipelineDescriptor new];
        blend_descriptor.vertexFunction = vertex_function;
        blend_descriptor.fragmentFunction = fragment_function;
        blend_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        blend_descriptor.colorAttachments[0].blendingEnabled = YES;
        blend_descriptor.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
        blend_descriptor.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        blend_descriptor.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
        blend_descriptor.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
        blend_descriptor.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        blend_descriptor.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
        blend_descriptor.colorAttachments[0].writeMask = MTLColorWriteMaskAll;
        id<MTLRenderPipelineState> metal_blend_pipeline =
            [device newRenderPipelineStateWithDescriptor:blend_descriptor error:&error];
        id<MTLTexture> metal_blend_texture = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLBuffer> metal_blend_buffer =
            [device newBufferWithBytes:blend_vertices length:sizeof(blend_vertices)
                               options:MTLResourceStorageModeShared];
        MTLRenderPassDescriptor *blend_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        blend_pass.colorAttachments[0].texture = metal_blend_texture;
        blend_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        blend_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        blend_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0);
        id<MTLCommandBuffer> metal_blend_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_blend_encoder =
            [metal_blend_command_buffer renderCommandEncoderWithDescriptor:blend_pass];
        if (metal_blend_pipeline == nil || metal_blend_texture == nil || metal_blend_buffer == nil ||
            metal_blend_encoder == nil) {
            fail_with_error("blend reference allocation failed", error);
            return 22;
        }
        [metal_blend_encoder setRenderPipelineState:metal_blend_pipeline];
        [metal_blend_encoder setVertexBuffer:metal_blend_buffer offset:0 atIndex:0];
        [metal_blend_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_blend_encoder endEncoding];
        [metal_blend_command_buffer commit];
        [metal_blend_command_buffer waitUntilCompleted];
        uint8_t metal_blend_pixels[byte_count];
        [metal_blend_texture getBytes:metal_blend_pixels bytesPerRow:(NSUInteger)width * 4
                           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLRenderPipelineState> adapter_blend_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:blend_descriptor error:&adapter_pipeline_error];
        id<MTLTexture> adapter_blend_texture = [adapter_device newTextureWithDescriptor:texture_descriptor];
        id<MTLBuffer> adapter_blend_buffer =
            [adapter_device newBufferWithBytes:blend_vertices length:sizeof(blend_vertices)
                                       options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_blend_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_blend_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_blend_pass.colorAttachments[0].texture = adapter_blend_texture;
        adapter_blend_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_blend_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_blend_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 1.0, 1.0);
        id<MTLRenderCommandEncoder> adapter_blend_encoder =
            [adapter_blend_command_buffer renderCommandEncoderWithDescriptor:adapter_blend_pass];
        if (adapter_blend_pipeline == nil || adapter_blend_texture == nil || adapter_blend_buffer == nil ||
            adapter_blend_command_buffer == nil || adapter_blend_encoder == nil) {
            fail_with_error("blend adapter allocation failed", adapter_pipeline_error);
            return 23;
        }
        [adapter_blend_encoder setRenderPipelineState:adapter_blend_pipeline];
        [adapter_blend_encoder setVertexBuffer:adapter_blend_buffer offset:0 atIndex:0];
        [adapter_blend_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_blend_encoder endEncoding];
        [adapter_blend_command_buffer commit];
        [adapter_blend_command_buffer waitUntilCompleted];
        uint8_t adapter_blend_pixels[byte_count];
        [adapter_blend_texture getBytes:adapter_blend_pixels bytesPerRow:(NSUInteger)width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_blend_pixels[index] != adapter_blend_pixels[index]) {
                fprintf(stderr, "metal-pixel: blend mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_blend_pixels[index], adapter_blend_pixels[index]);
                return 24;
            }
        }
        id<MTLTexture> adapter_view =
            [adapter_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm];
        id<MTLTexture> adapter_range_view =
            [adapter_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                               textureType:MTLTextureType2D
                                                    levels:NSMakeRange(0, 1)
                                                    slices:NSMakeRange(0, 1)];
        MTLTextureViewDescriptor *adapter_view_descriptor = [MTLTextureViewDescriptor new];
        adapter_view_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_view_descriptor.textureType = MTLTextureType2D;
        adapter_view_descriptor.levelRange = NSMakeRange(0, 1);
        adapter_view_descriptor.sliceRange = NSMakeRange(0, 1);
        adapter_view_descriptor.swizzle = MTLTextureSwizzleChannelsDefault;
        id<MTLTexture> adapter_descriptor_view =
            [adapter_texture newTextureViewWithDescriptor:adapter_view_descriptor];
        uint8_t adapter_view_pixels[byte_count];
        if (adapter_view == nil || adapter_range_view == nil || adapter_descriptor_view == nil ||
            adapter_view.parentTexture != adapter_texture) {
            fprintf(stderr, "metal-pixel: texture view creation/lifetime failed\n");
            return 30;
        }
        [adapter_view getBytes:adapter_view_pixels bytesPerRow:(NSUInteger)width * 4
                    fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (memcmp(adapter_pixels, adapter_view_pixels, sizeof(adapter_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: texture view byte identity failed\n");
            return 31;
        }
        const uint8_t adapter_alias_source[] = {
            1, 2, 3, 4, 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
            9, 10, 11, 12, 13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd,
        };
        const uint8_t adapter_alias_expected[] = {
            5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee,
            13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd,
        };
        id<MTLBuffer> adapter_alias_buffer =
            [adapter_device newBufferWithBytes:adapter_alias_source length:32 options:MTLResourceStorageModeShared];
        MTLTextureDescriptor *adapter_alias_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:2 height:2 mipmapped:NO];
        id<MTLTexture> adapter_alias_texture =
            [adapter_alias_buffer newTextureWithDescriptor:adapter_alias_descriptor offset:4 bytesPerRow:12];
        uint8_t adapter_alias_copy[16] = {0};
        if (adapter_alias_texture == nil || adapter_alias_texture.buffer != adapter_alias_buffer ||
            adapter_alias_texture.bufferOffset != 4 || adapter_alias_texture.bufferBytesPerRow != 12) {
            fprintf(stderr, "metal-pixel: buffer-backed texture creation failed\n");
            return 32;
        }
        [adapter_alias_texture getBytes:adapter_alias_copy bytesPerRow:8
                            fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
        if (memcmp(adapter_alias_copy, adapter_alias_expected, sizeof(adapter_alias_copy)) != 0) {
            fprintf(stderr, "metal-pixel: buffer-backed texture read failed\n");
            return 33;
        }
        [adapter_alias_texture replaceRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0
                                    withBytes:(const uint8_t[]){31, 32, 33, 34} bytesPerRow:4];
        if (memcmp((uint8_t *)adapter_alias_buffer.contents + 20,
                   (const uint8_t[]){31, 32, 33, 34}, 4) != 0) {
            fprintf(stderr, "metal-pixel: buffer-backed texture alias write failed\n");
            return 34;
        }

        MTLHeapDescriptor *adapter_heap_descriptor = [MTLHeapDescriptor new];
        adapter_heap_descriptor.size = 64;
        adapter_heap_descriptor.storageMode = MTLStorageModeShared;
        id<MTLHeap> adapter_heap = [adapter_device newHeapWithDescriptor:adapter_heap_descriptor];
        const NSUInteger adapter_allocated_before_heap_resources = adapter_device.currentAllocatedSize;
        id<MTLBuffer> adapter_heap_mismatched_buffer =
            [adapter_heap newBufferWithLength:4 options:MTLResourceStorageModePrivate];
        MTLTextureDescriptor *adapter_heap_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:2 height:2 mipmapped:NO];
        adapter_heap_texture_descriptor.storageMode = MTLStorageModeShared;
        MTLTextureDescriptor *adapter_heap_mismatched_texture_descriptor =
            [adapter_heap_texture_descriptor copy];
        adapter_heap_mismatched_texture_descriptor.storageMode = MTLStorageModePrivate;
        id<MTLTexture> adapter_heap_mismatched_texture =
            [adapter_heap newTextureWithDescriptor:adapter_heap_mismatched_texture_descriptor];
        id<MTLBuffer> adapter_heap_buffer =
            [adapter_heap newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_heap_texture =
            [adapter_heap newTextureWithDescriptor:adapter_heap_texture_descriptor];
        const uint8_t heap_pixels[] = {
            17, 18, 19, 20, 21, 22, 23, 24,
            25, 26, 27, 28, 29, 30, 31, 32,
        };
        uint8_t heap_pixels_copy[sizeof(heap_pixels)] = {0};
        if (adapter_heap == nil || adapter_heap_mismatched_buffer != nil ||
            adapter_heap_mismatched_texture != nil || adapter_heap_buffer == nil || adapter_heap_texture == nil ||
            adapter_heap.size != 64 || adapter_heap.usedSize != 32 ||
            [adapter_heap maxAvailableSizeWithAlignment:4] != 32 ||
            adapter_heap_buffer.heapOffset != 0 || adapter_heap_texture.heapOffset != adapter_heap_buffer.length ||
            adapter_heap.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_heap_buffer.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_heap_texture.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_device.currentAllocatedSize != adapter_allocated_before_heap_resources + adapter_heap.usedSize) {
            fprintf(stderr, "metal-pixel: heap allocation/accounting failed\n");
            return 37;
        }
        [adapter_heap_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0
                                  withBytes:heap_pixels bytesPerRow:8];
        [adapter_heap_texture getBytes:heap_pixels_copy bytesPerRow:8
                            fromRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0];
        if (memcmp(heap_pixels, heap_pixels_copy, sizeof(heap_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: heap texture byte identity failed\n");
            return 38;
        }
        id<MTLBuffer> adapter_heap_offset_buffer =
            [adapter_heap newBufferWithLength:16 options:MTLResourceStorageModeShared offset:32];
        id<MTLBuffer> adapter_heap_bad_offset_buffer =
            [adapter_heap newBufferWithLength:4 options:MTLResourceStorageModeShared offset:49];
        if (adapter_heap_offset_buffer == nil || adapter_heap_bad_offset_buffer != nil ||
            adapter_heap_offset_buffer.heapOffset != 32 || adapter_heap.usedSize != 48 ||
            adapter_device.currentAllocatedSize != adapter_allocated_before_heap_resources + adapter_heap.usedSize) {
            fprintf(stderr, "metal-pixel: explicit heap buffer offset handling failed\n");
            return 40;
        }

        MTLHeapDescriptor *adapter_mip_heap_descriptor = [MTLHeapDescriptor new];
        adapter_mip_heap_descriptor.size = 256;
        adapter_mip_heap_descriptor.storageMode = MTLStorageModeShared;
        id<MTLHeap> adapter_mip_heap = [adapter_device newHeapWithDescriptor:adapter_mip_heap_descriptor];
        id<MTLBuffer> adapter_mip_heap_prefix =
            [adapter_mip_heap newBufferWithLength:4 options:MTLResourceStorageModeShared];
        const NSUInteger adapter_allocated_before_mip_heap_texture = adapter_device.currentAllocatedSize;
        MTLTextureDescriptor *adapter_heap_mip_descriptor = [MTLTextureDescriptor new];
        adapter_heap_mip_descriptor.textureType = MTLTextureType2DArray;
        adapter_heap_mip_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_heap_mip_descriptor.width = 4;
        adapter_heap_mip_descriptor.height = 4;
        adapter_heap_mip_descriptor.arrayLength = 2;
        adapter_heap_mip_descriptor.mipmapLevelCount = 3;
        adapter_heap_mip_descriptor.sampleCount = 1;
        adapter_heap_mip_descriptor.storageMode = MTLStorageModeShared;
        adapter_heap_mip_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        MTLSizeAndAlign adapter_heap_mip_size_align =
            [adapter_device heapTextureSizeAndAlignWithDescriptor:adapter_heap_mip_descriptor];
        id<MTLTexture> adapter_heap_mip_texture =
            [adapter_mip_heap newTextureWithDescriptor:adapter_heap_mip_descriptor offset:adapter_mip_heap_prefix.length];
        uint8_t adapter_heap_mip_bytes[sizeof(array_level_one)] = {0};
        [adapter_heap_mip_texture replaceRegion:MTLRegionMake2D(0, 0, 2, 2)
                                    mipmapLevel:1
                                          slice:1
                                      withBytes:array_level_one
                                    bytesPerRow:2 * 4
                                  bytesPerImage:2 * 2 * 4];
        [adapter_heap_mip_texture getBytes:adapter_heap_mip_bytes
                               bytesPerRow:2 * 4
                             bytesPerImage:2 * 2 * 4
                              fromRegion:MTLRegionMake3D(0, 0, 0, 2, 2, 1)
                             mipmapLevel:1
                                    slice:1];
        const NSUInteger expected_heap_mip_size = 2 * (4 * 4 + 2 * 2 + 1) * 4;
        if (adapter_mip_heap == nil || adapter_heap_mip_texture == nil ||
            adapter_heap_mip_size_align.size != expected_heap_mip_size || adapter_heap_mip_size_align.align != 4 ||
            adapter_mip_heap_prefix == nil || adapter_mip_heap.usedSize != 4 + expected_heap_mip_size ||
            adapter_heap_mip_texture.heapOffset != adapter_mip_heap_prefix.length ||
            adapter_heap_mip_texture.arrayLength != 2 ||
            adapter_heap_mip_texture.mipmapLevelCount != 3 || adapter_heap_mip_texture.allocatedSize != expected_heap_mip_size ||
            adapter_device.currentAllocatedSize != adapter_allocated_before_mip_heap_texture + adapter_heap_mip_texture.allocatedSize ||
            memcmp(adapter_heap_mip_bytes, native_array_level_one, sizeof(adapter_heap_mip_bytes)) != 0) {
            fprintf(stderr, "metal-pixel: heap array/mipmap texture exactness failed\n");
            return 39;
        }

        MTLHeapDescriptor *adapter_one_d_heap_descriptor = [MTLHeapDescriptor new];
        adapter_one_d_heap_descriptor.size = expected_one_d_array_allocated_size;
        adapter_one_d_heap_descriptor.storageMode = MTLStorageModeShared;
        id<MTLHeap> adapter_one_d_heap = [adapter_device newHeapWithDescriptor:adapter_one_d_heap_descriptor];
        MTLSizeAndAlign adapter_one_d_heap_size_align =
            [adapter_device heapTextureSizeAndAlignWithDescriptor:one_d_array_descriptor];
        id<MTLTexture> adapter_one_d_heap_texture =
            [adapter_one_d_heap newTextureWithDescriptor:one_d_array_descriptor];
        uint8_t adapter_one_d_heap_bytes[sizeof(one_d_array_bytes)] = {0};
        [adapter_one_d_heap_texture replaceRegion:MTLRegionMake1D(0, width)
                                      mipmapLevel:0
                                            slice:1
                                        withBytes:one_d_array_bytes
                                      bytesPerRow:sizeof(one_d_array_bytes)
                                    bytesPerImage:sizeof(one_d_array_bytes)];
        [adapter_one_d_heap_texture getBytes:adapter_one_d_heap_bytes
                                  bytesPerRow:sizeof(adapter_one_d_heap_bytes)
                                bytesPerImage:sizeof(adapter_one_d_heap_bytes)
                                 fromRegion:MTLRegionMake1D(0, width)
                                mipmapLevel:0
                                       slice:1];
        if (adapter_one_d_heap == nil || adapter_one_d_heap_texture == nil ||
            adapter_one_d_heap_size_align.size != expected_one_d_array_allocated_size ||
            adapter_one_d_heap_size_align.align != 4 || adapter_one_d_heap.usedSize != expected_one_d_array_allocated_size ||
            adapter_one_d_heap_texture.heapOffset != 0 ||
            memcmp(adapter_one_d_heap_bytes, one_d_array_bytes, sizeof(one_d_array_bytes)) != 0) {
            fprintf(stderr, "metal-pixel: heap 1D-array texture exactness failed\n");
            return 41;
        }

        const uint32_t adapter_indirect_arguments[] = {6, 1, 0, 0};
        id<MTLBuffer> adapter_indirect_buffer =
            [adapter_device newBufferWithBytes:adapter_indirect_arguments
                                         length:sizeof(adapter_indirect_arguments)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> adapter_indirect_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLCommandBuffer> adapter_indirect_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_indirect_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_indirect_pass.colorAttachments[0].texture = adapter_indirect_texture;
        adapter_indirect_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_indirect_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_indirect_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLRenderCommandEncoder> adapter_indirect_encoder =
            [adapter_indirect_command_buffer renderCommandEncoderWithDescriptor:adapter_indirect_pass];
        if (adapter_indirect_buffer == nil || adapter_indirect_texture == nil ||
            adapter_indirect_command_buffer == nil || adapter_indirect_encoder == nil) {
            fprintf(stderr, "metal-pixel: indirect adapter allocation failed\n");
            return 35;
        }
        [adapter_indirect_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_indirect_encoder drawPrimitives:MTLPrimitiveTypeTriangle
                                  indirectBuffer:adapter_indirect_buffer indirectBufferOffset:0];
        [adapter_indirect_encoder endEncoding];
        [adapter_indirect_command_buffer commit];
        [adapter_indirect_command_buffer waitUntilCompleted];
        uint8_t adapter_indirect_pixels[byte_count];
        [adapter_indirect_texture getBytes:adapter_indirect_pixels bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (memcmp(metal_pixels, adapter_indirect_pixels, sizeof(metal_pixels)) != 0) {
            fprintf(stderr, "metal-pixel: indirect adapter mismatch\n");
            return 36;
        }

        const zpu_metal_vertex deferred_indirect_vertices[] = {
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y0, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x1, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
            {{x0, y1, 0.5f, 1.0f}, {0.0f, 0.0f, 1.0f, 1.0f}},
        };
        const uint32_t deferred_initial_arguments[] = {6, 1, 0, 0};
        const uint32_t deferred_updated_arguments[] = {6, 1, 6, 0};
        id<MTLBuffer> native_deferred_vertex_buffer =
            [device newBufferWithBytes:deferred_indirect_vertices length:sizeof(deferred_indirect_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_deferred_vertex_buffer =
            [adapter_device newBufferWithBytes:deferred_indirect_vertices length:sizeof(deferred_indirect_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> native_deferred_arguments =
            [device newBufferWithBytes:deferred_initial_arguments length:sizeof(deferred_initial_arguments)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_deferred_arguments =
            [adapter_device newBufferWithBytes:deferred_initial_arguments length:sizeof(deferred_initial_arguments)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_deferred_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_deferred_output = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *native_deferred_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_deferred_pass.colorAttachments[0].texture = native_deferred_output;
        native_deferred_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_deferred_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_deferred_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_deferred_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_deferred_encoder =
            [native_deferred_command_buffer renderCommandEncoderWithDescriptor:native_deferred_pass];
        [native_deferred_encoder setRenderPipelineState:pipeline];
        [native_deferred_encoder setVertexBuffer:native_deferred_vertex_buffer offset:0 atIndex:0];
        [native_deferred_encoder drawPrimitives:MTLPrimitiveTypeTriangle
                                  indirectBuffer:native_deferred_arguments indirectBufferOffset:0];
        [native_deferred_encoder endEncoding];
        MTLRenderPassDescriptor *adapter_deferred_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_deferred_pass.colorAttachments[0].texture = adapter_deferred_output;
        adapter_deferred_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_deferred_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_deferred_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_deferred_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_deferred_encoder =
            [adapter_deferred_command_buffer renderCommandEncoderWithDescriptor:adapter_deferred_pass];
        [adapter_deferred_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_deferred_encoder setVertexBuffer:adapter_deferred_vertex_buffer offset:0 atIndex:0];
        [adapter_deferred_encoder drawPrimitives:MTLPrimitiveTypeTriangle
                                    indirectBuffer:adapter_deferred_arguments indirectBufferOffset:0];
        [adapter_deferred_encoder endEncoding];
        memcpy(native_deferred_arguments.contents, deferred_updated_arguments, sizeof(deferred_updated_arguments));
        memcpy(adapter_deferred_arguments.contents, deferred_updated_arguments, sizeof(deferred_updated_arguments));
        [native_deferred_command_buffer commit];
        [native_deferred_command_buffer waitUntilCompleted];
        [adapter_deferred_command_buffer commit];
        [adapter_deferred_command_buffer waitUntilCompleted];
        uint8_t native_deferred_bytes[byte_count];
        uint8_t adapter_deferred_bytes[byte_count];
        [native_deferred_output getBytes:native_deferred_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_deferred_output getBytes:adapter_deferred_bytes bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_deferred_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_deferred_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_deferred_bytes, adapter_deferred_bytes, byte_count) != 0 ||
            memcmp(native_deferred_bytes + (4 * (size_t)width + 4) * 4, (const uint8_t[]){0, 0, 255, 255}, 4) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_deferred_bytes[mismatch] == adapter_deferred_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: deferred render arguments mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_deferred_command_buffer.status,
                    (unsigned long)adapter_deferred_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_deferred_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_deferred_bytes[mismatch] : 0);
            return 122;
        }

        const uint16_t deferred_index_values[] = {0, 1, 2, 0, 2, 3, 6, 7, 8, 6, 8, 11};
        const uint32_t indexed_deferred_initial_arguments[] = {6, 1, 0, 0, 0};
        const uint32_t indexed_deferred_updated_arguments[] = {6, 1, 6, 0, 0};
        id<MTLBuffer> native_indexed_deferred_indices =
            [device newBufferWithBytes:deferred_index_values length:sizeof(deferred_index_values)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_indexed_deferred_indices =
            [adapter_device newBufferWithBytes:deferred_index_values length:sizeof(deferred_index_values)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> native_indexed_deferred_arguments =
            [device newBufferWithBytes:indexed_deferred_initial_arguments length:sizeof(indexed_deferred_initial_arguments)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_indexed_deferred_arguments =
            [adapter_device newBufferWithBytes:indexed_deferred_initial_arguments length:sizeof(indexed_deferred_initial_arguments)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_indexed_deferred_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_indexed_deferred_output = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *native_indexed_deferred_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_indexed_deferred_pass.colorAttachments[0].texture = native_indexed_deferred_output;
        native_indexed_deferred_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_indexed_deferred_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_indexed_deferred_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_indexed_deferred_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_indexed_deferred_encoder =
            [native_indexed_deferred_command_buffer renderCommandEncoderWithDescriptor:native_indexed_deferred_pass];
        [native_indexed_deferred_encoder setRenderPipelineState:pipeline];
        [native_indexed_deferred_encoder setVertexBuffer:native_deferred_vertex_buffer offset:0 atIndex:0];
        [native_indexed_deferred_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16
                                                  indexBuffer:native_indexed_deferred_indices indexBufferOffset:0
                                                 indirectBuffer:native_indexed_deferred_arguments indirectBufferOffset:0];
        [native_indexed_deferred_encoder endEncoding];
        MTLRenderPassDescriptor *adapter_indexed_deferred_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_indexed_deferred_pass.colorAttachments[0].texture = adapter_indexed_deferred_output;
        adapter_indexed_deferred_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_indexed_deferred_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_indexed_deferred_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_indexed_deferred_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_indexed_deferred_encoder =
            [adapter_indexed_deferred_command_buffer renderCommandEncoderWithDescriptor:adapter_indexed_deferred_pass];
        [adapter_indexed_deferred_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_indexed_deferred_encoder setVertexBuffer:adapter_deferred_vertex_buffer offset:0 atIndex:0];
        [adapter_indexed_deferred_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt16
                                                   indexBuffer:adapter_indexed_deferred_indices indexBufferOffset:0
                                                  indirectBuffer:adapter_indexed_deferred_arguments indirectBufferOffset:0];
        [adapter_indexed_deferred_encoder endEncoding];
        memcpy(native_indexed_deferred_arguments.contents, indexed_deferred_updated_arguments, sizeof(indexed_deferred_updated_arguments));
        memcpy(adapter_indexed_deferred_arguments.contents, indexed_deferred_updated_arguments, sizeof(indexed_deferred_updated_arguments));
        [native_indexed_deferred_command_buffer commit];
        [native_indexed_deferred_command_buffer waitUntilCompleted];
        [adapter_indexed_deferred_command_buffer commit];
        [adapter_indexed_deferred_command_buffer waitUntilCompleted];
        uint8_t native_indexed_deferred_bytes[byte_count];
        uint8_t adapter_indexed_deferred_bytes[byte_count];
        [native_indexed_deferred_output getBytes:native_indexed_deferred_bytes bytesPerRow:(NSUInteger)width * 4
                                      fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_indexed_deferred_output getBytes:adapter_indexed_deferred_bytes bytesPerRow:(NSUInteger)width * 4
                                        fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_indexed_deferred_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_indexed_deferred_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_indexed_deferred_bytes, adapter_indexed_deferred_bytes, byte_count) != 0 ||
            memcmp(native_indexed_deferred_bytes + (4 * (size_t)width + 4) * 4, (const uint8_t[]){0, 0, 255, 255}, 4) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_indexed_deferred_bytes[mismatch] == adapter_indexed_deferred_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: deferred indexed render arguments mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_indexed_deferred_command_buffer.status,
                    (unsigned long)adapter_indexed_deferred_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_indexed_deferred_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_indexed_deferred_bytes[mismatch] : 0);
            return 123;
        }

        /* Indexed indirect arguments use element-based indexStart and a
         * signed baseVertex. Exercise the uint32 path with a zero-based
         * index buffer selecting the same blue vertices. */
        const uint32_t base_vertex_indices[] = {0, 1, 2, 0, 2, 5};
        const uint32_t base_vertex_arguments[] = {6, 1, 0, 6, 0};
        id<MTLBuffer> native_base_vertex_indices =
            [device newBufferWithBytes:base_vertex_indices length:sizeof(base_vertex_indices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_base_vertex_indices =
            [adapter_device newBufferWithBytes:base_vertex_indices length:sizeof(base_vertex_indices)
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> native_base_vertex_arguments =
            [device newBufferWithBytes:base_vertex_arguments length:sizeof(base_vertex_arguments)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_base_vertex_arguments =
            [adapter_device newBufferWithBytes:base_vertex_arguments length:sizeof(base_vertex_arguments)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_base_vertex_output = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_base_vertex_output = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *native_base_vertex_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_base_vertex_pass.colorAttachments[0].texture = native_base_vertex_output;
        native_base_vertex_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_base_vertex_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_base_vertex_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_base_vertex_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_base_vertex_encoder =
            [native_base_vertex_command_buffer renderCommandEncoderWithDescriptor:native_base_vertex_pass];
        [native_base_vertex_encoder setRenderPipelineState:pipeline];
        [native_base_vertex_encoder setVertexBuffer:native_deferred_vertex_buffer offset:0 atIndex:0];
        [native_base_vertex_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt32
                                             indexBuffer:native_base_vertex_indices indexBufferOffset:0
                                            indirectBuffer:native_base_vertex_arguments indirectBufferOffset:0];
        [native_base_vertex_encoder endEncoding];
        MTLRenderPassDescriptor *adapter_base_vertex_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_base_vertex_pass.colorAttachments[0].texture = adapter_base_vertex_output;
        adapter_base_vertex_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_base_vertex_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_base_vertex_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_base_vertex_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_base_vertex_encoder =
            [adapter_base_vertex_command_buffer renderCommandEncoderWithDescriptor:adapter_base_vertex_pass];
        [adapter_base_vertex_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_base_vertex_encoder setVertexBuffer:adapter_deferred_vertex_buffer offset:0 atIndex:0];
        [adapter_base_vertex_encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexType:MTLIndexTypeUInt32
                                              indexBuffer:adapter_base_vertex_indices indexBufferOffset:0
                                             indirectBuffer:adapter_base_vertex_arguments indirectBufferOffset:0];
        [adapter_base_vertex_encoder endEncoding];
        [native_base_vertex_command_buffer commit];
        [native_base_vertex_command_buffer waitUntilCompleted];
        [adapter_base_vertex_command_buffer commit];
        [adapter_base_vertex_command_buffer waitUntilCompleted];
        uint8_t native_base_vertex_bytes[byte_count];
        uint8_t adapter_base_vertex_bytes[byte_count];
        [native_base_vertex_output getBytes:native_base_vertex_bytes bytesPerRow:(NSUInteger)width * 4
                                 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_base_vertex_output getBytes:adapter_base_vertex_bytes bytesPerRow:(NSUInteger)width * 4
                                  fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_base_vertex_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_base_vertex_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_base_vertex_bytes, adapter_base_vertex_bytes, byte_count) != 0 ||
            memcmp(native_base_vertex_bytes, native_deferred_bytes, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_base_vertex_bytes[mismatch] == adapter_base_vertex_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: uint32/baseVertex indexed indirect mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)native_base_vertex_command_buffer.status,
                    (unsigned long)adapter_base_vertex_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? native_base_vertex_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_base_vertex_bytes[mismatch] : 0);
            return 124;
        }

        /* Indirect command buffers must preserve the same draw state and
         * vertex data as a directly encoded draw. Compare Apple's native ICB
         * execution with the explicit ZPU adapter byte-for-byte. */
        MTLIndirectCommandBufferDescriptor *icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        icb_descriptor.commandTypes = MTLIndirectCommandTypeDraw;
        icb_descriptor.inheritPipelineState = YES;
        icb_descriptor.inheritBuffers = YES;
        icb_descriptor.maxVertexBufferBindCount = 1;
        id<MTLIndirectCommandBuffer> metal_icb =
            [device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                           maxCommandCount:1
                                                   options:0];
        id<MTLIndirectRenderCommand> metal_icb_command =
            [metal_icb indirectRenderCommandAtIndex:0];
        [metal_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                              vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> metal_icb_texture = [device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *metal_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_icb_pass.colorAttachments[0].texture = metal_icb_texture;
        metal_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> metal_icb_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_icb_encoder =
            [metal_icb_command_buffer renderCommandEncoderWithDescriptor:metal_icb_pass];
        [metal_icb_encoder setRenderPipelineState:pipeline];
        [metal_icb_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [metal_icb_encoder useResource:vertex_buffer usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [metal_icb_encoder useResource:metal_icb usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
        [metal_icb_encoder executeCommandsInBuffer:metal_icb withRange:NSMakeRange(0, 1)];
        [metal_icb_encoder endEncoding];
        [metal_icb_command_buffer commit];
        [metal_icb_command_buffer waitUntilCompleted];
        uint8_t metal_icb_pixels[byte_count];
        [metal_icb_texture getBytes:metal_icb_pixels bytesPerRow:(NSUInteger)width * 4
                         fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLIndirectCommandBuffer> adapter_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModePrivate |
                                                                    MTLResourceHazardTrackingModeUntracked];
        id<MTLIndirectRenderCommand> adapter_icb_command =
            [adapter_icb indirectRenderCommandAtIndex:0];
        [adapter_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> adapter_icb_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_icb_pass.colorAttachments[0].texture = adapter_icb_texture;
        adapter_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_icb_encoder =
            [adapter_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_icb_pass];
        [adapter_icb_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_icb_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_icb_encoder executeCommandsInBuffer:adapter_icb withRange:NSMakeRange(0, 1)];
        [adapter_icb_encoder endEncoding];
        [adapter_icb_command_buffer commit];
        [adapter_icb_command_buffer waitUntilCompleted];
        uint8_t adapter_icb_pixels[byte_count];
        [adapter_icb_texture getBytes:adapter_icb_pixels bytesPerRow:(NSUInteger)width * 4
                           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (metal_icb == nil || metal_icb_command == nil || metal_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_icb == nil || adapter_icb_command == nil || adapter_icb_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: indirect command buffer did not complete (Metal=%ld adapter=%ld)\n",
                    (long)metal_icb_command_buffer.status, (long)adapter_icb_command_buffer.status);
            fail_with_error("native indirect command buffer error", metal_icb_command_buffer.error);
            fail_with_error("adapter indirect command buffer error", adapter_icb_command_buffer.error);
            return 39;
        }
        if (adapter_icb.resourceOptions != (MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked) ||
            adapter_icb.storageMode != MTLStorageModePrivate ||
            adapter_icb.hazardTrackingMode != MTLHazardTrackingModeUntracked) {
            fprintf(stderr, "metal-pixel: indirect command buffer resource metadata failed\n");
            return 56;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_icb_pixels[index] != adapter_icb_pixels[index]) {
                fprintf(stderr, "metal-pixel: indirect command buffer mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_icb_pixels[index], adapter_icb_pixels[index]);
                return 40;
            }
        }

        /* Blit-copy an encoded render command entirely within the CPU-owned
         * ICB representation, then execute the copy through the same ZPU
         * render path. The native ICB above remains the byte oracle. */
        id<MTLIndirectCommandBuffer> adapter_copied_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_icb_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_icb_copy_encoder =
            [adapter_icb_copy_command_buffer blitCommandEncoder];
        [adapter_icb_copy_encoder copyIndirectCommandBuffer:adapter_icb
                                                  sourceRange:NSMakeRange(0, 1)
                                                 destination:adapter_copied_icb
                                            destinationIndex:0];
        [adapter_icb_copy_encoder endEncoding];
        [adapter_icb_copy_command_buffer commit];
        [adapter_icb_copy_command_buffer waitUntilCompleted];
        id<MTLTexture> adapter_copied_icb_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_copied_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_copied_icb_pass.colorAttachments[0].texture = adapter_copied_icb_texture;
        adapter_copied_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_copied_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_copied_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_copied_icb_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_copied_icb_render_encoder =
            [adapter_copied_icb_render_command_buffer renderCommandEncoderWithDescriptor:adapter_copied_icb_pass];
        [adapter_copied_icb_render_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_copied_icb_render_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_copied_icb_render_encoder executeCommandsInBuffer:adapter_copied_icb withRange:NSMakeRange(0, 1)];
        [adapter_copied_icb_render_encoder endEncoding];
        [adapter_copied_icb_render_command_buffer commit];
        [adapter_copied_icb_render_command_buffer waitUntilCompleted];
        uint8_t adapter_copied_icb_pixels[byte_count];
        [adapter_copied_icb_texture getBytes:adapter_copied_icb_pixels
                                  bytesPerRow:(NSUInteger)width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height)
                                  mipmapLevel:0];
        if (adapter_copied_icb == nil || adapter_icb_copy_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_copied_icb_texture == nil || adapter_copied_icb_render_encoder == nil ||
            adapter_copied_icb_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_icb_pixels, adapter_copied_icb_pixels, byte_count) != 0) {
            fprintf(stderr, "metal-pixel: copied indirect command buffer mismatch\n");
            return 58;
        }

        id<MTLTexture> parallel_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLCommandBuffer> parallel_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *parallel_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        parallel_pass.colorAttachments[0].texture = parallel_texture;
        parallel_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        parallel_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        parallel_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLParallelRenderCommandEncoder> parallel_encoder =
            [parallel_command_buffer parallelRenderCommandEncoderWithDescriptor:parallel_pass];
        id<MTLRenderCommandEncoder> parallel_child_one = [parallel_encoder renderCommandEncoder];
        if (parallel_texture == nil || parallel_command_buffer == nil || parallel_encoder == nil ||
            parallel_child_one == nil) {
            fprintf(stderr, "metal-pixel: parallel adapter allocation failed\n");
            return 22;
        }
        [parallel_child_one setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [parallel_child_one drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [parallel_child_one endEncoding];
        id<MTLRenderCommandEncoder> parallel_child_two = [parallel_encoder renderCommandEncoder];
        if (parallel_child_two == nil) {
            fprintf(stderr, "metal-pixel: parallel adapter second child failed\n");
            return 23;
        }
        [parallel_child_two setVertexBuffer:adapter_vertex_buffer offset:sizeof(zpu_metal_vertex) * 3 atIndex:0];
        [parallel_child_two drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [parallel_child_two endEncoding];
        [parallel_encoder endEncoding];
        [parallel_command_buffer commit];
        [parallel_command_buffer waitUntilCompleted];
        if (parallel_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: parallel adapter command did not complete\n");
            return 24;
        }
        uint8_t parallel_pixels[byte_count];
        [parallel_texture getBytes:parallel_pixels bytesPerRow:(NSUInteger)width * 4
                         fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_pixels[index] != parallel_pixels[index]) {
                fprintf(stderr, "metal-pixel: parallel mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_pixels[index], parallel_pixels[index]);
                return 25;
            }
        }

        /* Depth attachments are part of the byte-accurate contract too. The
         * reference uses Metal's less-equal depth test; the bounded ZPU
         * adapter exposes the same fixed-function test through a depth32-float
         * texture. */
        const zpu_metal_vertex depth_vertices[] = {
            {{-1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-1.0f, -1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-1.0f,  1.0f, 0.75f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{ 1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{-1.0f, -1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
            {{-1.0f,  1.0f, 0.25f, 1.0f}, {0.0f, 1.0f, 0.0f, 1.0f}},
        };
        const zpu_metal_vertex depth_clip_vertices[] = {
            {{-1.0f, -1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f, -1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-1.0f, -1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
            {{-1.0f,  1.0f, 1.25f, 1.0f}, {1.0f, 0.0f, 0.0f, 1.0f}},
        };
        MTLRenderPipelineDescriptor *depth_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        depth_pipeline_descriptor.vertexFunction = vertex_function;
        depth_pipeline_descriptor.fragmentFunction = fragment_function;
        depth_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        depth_pipeline_descriptor.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        id<MTLRenderPipelineState> depth_pipeline =
            [device newRenderPipelineStateWithDescriptor:depth_pipeline_descriptor error:&error];
        MTLDepthStencilDescriptor *depth_state_descriptor = [MTLDepthStencilDescriptor new];
        depth_state_descriptor.depthCompareFunction = MTLCompareFunctionLessEqual;
        depth_state_descriptor.depthWriteEnabled = YES;
        id<MTLDepthStencilState> depth_state =
            [device newDepthStencilStateWithDescriptor:depth_state_descriptor];
        MTLTextureDescriptor *metal_depth_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        metal_depth_texture_descriptor.storageMode = MTLStorageModePrivate;
        metal_depth_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> metal_depth_texture =
            [device newTextureWithDescriptor:metal_depth_texture_descriptor];
        id<MTLTexture> metal_depth_color = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLBuffer> metal_depth_vertex_buffer =
            [device newBufferWithBytes:depth_vertices length:sizeof(depth_vertices)
                               options:MTLResourceStorageModeShared];
        if (depth_pipeline == nil || depth_state == nil || metal_depth_texture == nil ||
            metal_depth_color == nil || metal_depth_vertex_buffer == nil) {
            fail_with_error("depth reference allocation failed", error);
            return 26;
        }
        MTLRenderPassDescriptor *metal_depth_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_depth_pass.colorAttachments[0].texture = metal_depth_color;
        metal_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_depth_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_depth_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        metal_depth_pass.depthAttachment.texture = metal_depth_texture;
        metal_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        metal_depth_pass.depthAttachment.storeAction = MTLStoreActionStore;
        metal_depth_pass.depthAttachment.clearDepth = 1.0;
        id<MTLCommandBuffer> metal_depth_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_depth_encoder =
            [metal_depth_command_buffer renderCommandEncoderWithDescriptor:metal_depth_pass];
        [metal_depth_encoder setRenderPipelineState:depth_pipeline];
        [metal_depth_encoder setDepthStencilState:depth_state];
        [metal_depth_encoder setDepthBias:0.125f slopeScale:0.0f clamp:0.0f];
        [metal_depth_encoder setVertexBuffer:metal_depth_vertex_buffer offset:0 atIndex:0];
        [metal_depth_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [metal_depth_encoder endEncoding];
        [metal_depth_command_buffer commit];
        [metal_depth_command_buffer waitUntilCompleted];
        if (metal_depth_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: depth reference command did not complete\n");
            return 27;
        }
        uint8_t metal_depth_pixels[byte_count];
        [metal_depth_color getBytes:metal_depth_pixels bytesPerRow:(NSUInteger)width * 4
                          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];

        id<MTLTexture> adapter_depth_color =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLTextureDescriptor *adapter_depth_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        adapter_depth_texture_descriptor.storageMode = MTLStorageModeShared;
        adapter_depth_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> adapter_depth_texture =
            [adapter_device newTextureWithDescriptor:adapter_depth_texture_descriptor];
        id<MTLBuffer> adapter_depth_vertex_buffer =
            [adapter_device newBufferWithBytes:depth_vertices length:sizeof(depth_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_depth_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_depth_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_depth_pass.colorAttachments[0].texture = adapter_depth_color;
        adapter_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_depth_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_depth_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_depth_pass.depthAttachment.texture = adapter_depth_texture;
        adapter_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        adapter_depth_pass.depthAttachment.storeAction = MTLStoreActionStore;
        adapter_depth_pass.depthAttachment.clearDepth = 1.0;
        id<MTLRenderCommandEncoder> adapter_depth_encoder =
            [adapter_depth_command_buffer renderCommandEncoderWithDescriptor:adapter_depth_pass];
        NSError *adapter_depth_pipeline_error = nil;
        id<MTLRenderPipelineState> adapter_depth_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:depth_pipeline_descriptor error:&adapter_depth_pipeline_error];
        id<MTLDepthStencilState> adapter_depth_state =
            [adapter_device newDepthStencilStateWithDescriptor:depth_state_descriptor];
        if (adapter_depth_color == nil || adapter_depth_texture == nil ||
            adapter_depth_vertex_buffer == nil || adapter_depth_command_buffer == nil ||
            adapter_depth_encoder == nil || adapter_depth_pipeline == nil || adapter_depth_state == nil) {
            fail_with_error("depth adapter pipeline allocation failed", adapter_depth_pipeline_error);
            fprintf(stderr, "metal-pixel: depth adapter allocation failed\n");
            return 28;
        }
        [adapter_depth_encoder setRenderPipelineState:adapter_depth_pipeline];
        [adapter_depth_encoder setDepthStencilState:adapter_depth_state];
        [adapter_depth_encoder setDepthBias:0.125f slopeScale:0.0f clamp:0.0f];
        [adapter_depth_encoder setVertexBuffer:adapter_depth_vertex_buffer offset:0 atIndex:0];
        [adapter_depth_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [adapter_depth_encoder endEncoding];
        [adapter_depth_command_buffer commit];
        [adapter_depth_command_buffer waitUntilCompleted];
        uint8_t adapter_depth_pixels[byte_count];
        [adapter_depth_color getBytes:adapter_depth_pixels bytesPerRow:(NSUInteger)width * 4
                           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_depth_pixels[index] != adapter_depth_pixels[index]) {
                fprintf(stderr, "metal-pixel: depth mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_depth_pixels[index], adapter_depth_pixels[index]);
                return 29;
            }
        }

        /* Depth bounds are a fixed-function test on the interpolated depth
         * value. The current M4 Metal runtime traps when the SDK 26 native
         * selector is called, so the native oracle uses an equivalent
         * fragment discard; the adapter still exercises the real public
         * setDepthTestMinBound:maxBound: selector entirely on CPU. */
        MTLRenderPipelineDescriptor *metal_depth_bounds_oracle_descriptor = [depth_pipeline_descriptor copy];
        metal_depth_bounds_oracle_descriptor.fragmentFunction = depth_bounds_oracle_fragment;
        id<MTLRenderPipelineState> metal_depth_bounds_oracle_pipeline =
            [device newRenderPipelineStateWithDescriptor:metal_depth_bounds_oracle_descriptor error:&error];
        id<MTLTexture> metal_depth_bounds_texture =
            [device newTextureWithDescriptor:metal_depth_texture_descriptor];
        id<MTLTexture> metal_depth_bounds_color = [device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *metal_depth_bounds_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_depth_bounds_pass.colorAttachments[0].texture = metal_depth_bounds_color;
        metal_depth_bounds_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_depth_bounds_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_depth_bounds_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        metal_depth_bounds_pass.depthAttachment.texture = metal_depth_bounds_texture;
        metal_depth_bounds_pass.depthAttachment.loadAction = MTLLoadActionClear;
        metal_depth_bounds_pass.depthAttachment.storeAction = MTLStoreActionStore;
        metal_depth_bounds_pass.depthAttachment.clearDepth = 1.0;
        id<MTLCommandBuffer> metal_depth_bounds_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_depth_bounds_encoder =
            [metal_depth_bounds_command_buffer renderCommandEncoderWithDescriptor:metal_depth_bounds_pass];
        [metal_depth_bounds_encoder setRenderPipelineState:metal_depth_bounds_oracle_pipeline];
        [metal_depth_bounds_encoder setDepthStencilState:depth_state];
        [metal_depth_bounds_encoder setVertexBuffer:metal_depth_vertex_buffer offset:0 atIndex:0];
        [metal_depth_bounds_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [metal_depth_bounds_encoder endEncoding];
        [metal_depth_bounds_command_buffer commit];
        [metal_depth_bounds_command_buffer waitUntilCompleted];
        uint8_t metal_depth_bounds_pixels[byte_count];
        [metal_depth_bounds_color getBytes:metal_depth_bounds_pixels
                               bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height)
                               mipmapLevel:0];

        id<MTLTexture> adapter_depth_bounds_texture =
            [adapter_device newTextureWithDescriptor:adapter_depth_texture_descriptor];
        id<MTLTexture> adapter_depth_bounds_color =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        id<MTLCommandBuffer> adapter_depth_bounds_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_depth_bounds_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_depth_bounds_pass.colorAttachments[0].texture = adapter_depth_bounds_color;
        adapter_depth_bounds_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_depth_bounds_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_depth_bounds_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_depth_bounds_pass.depthAttachment.texture = adapter_depth_bounds_texture;
        adapter_depth_bounds_pass.depthAttachment.loadAction = MTLLoadActionClear;
        adapter_depth_bounds_pass.depthAttachment.storeAction = MTLStoreActionStore;
        adapter_depth_bounds_pass.depthAttachment.clearDepth = 1.0;
        id<MTLRenderCommandEncoder> adapter_depth_bounds_encoder =
            [adapter_depth_bounds_command_buffer renderCommandEncoderWithDescriptor:adapter_depth_bounds_pass];
        id<MTLRenderPipelineState> adapter_depth_bounds_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:depth_pipeline_descriptor error:&adapter_depth_pipeline_error];
        id<MTLDepthStencilState> adapter_depth_bounds_state =
            [adapter_device newDepthStencilStateWithDescriptor:depth_state_descriptor];
        if (metal_depth_bounds_oracle_pipeline == nil || metal_depth_bounds_texture == nil || metal_depth_bounds_color == nil ||
            metal_depth_bounds_command_buffer == nil || metal_depth_bounds_encoder == nil ||
            metal_depth_bounds_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_depth_bounds_texture == nil || adapter_depth_bounds_color == nil ||
            adapter_depth_bounds_command_buffer == nil || adapter_depth_bounds_encoder == nil ||
            adapter_depth_bounds_pipeline == nil || adapter_depth_bounds_state == nil) {
            fail_with_error("depth bounds allocation or execution failed", adapter_depth_pipeline_error);
            return 95;
        }
        [adapter_depth_bounds_encoder setRenderPipelineState:adapter_depth_bounds_pipeline];
        [adapter_depth_bounds_encoder setDepthStencilState:adapter_depth_bounds_state];
        [adapter_depth_bounds_encoder setDepthTestMinBound:0.5f maxBound:1.0f];
        [adapter_depth_bounds_encoder setVertexBuffer:adapter_depth_vertex_buffer offset:0 atIndex:0];
        [adapter_depth_bounds_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [adapter_depth_bounds_encoder endEncoding];
        [adapter_depth_bounds_command_buffer commit];
        [adapter_depth_bounds_command_buffer waitUntilCompleted];
        uint8_t adapter_depth_bounds_pixels[byte_count];
        [adapter_depth_bounds_color getBytes:adapter_depth_bounds_pixels
                                  bytesPerRow:(NSUInteger)width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height)
                                  mipmapLevel:0];
        if (adapter_depth_bounds_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_depth_bounds_pixels, adapter_depth_bounds_pixels, byte_count) != 0) {
            fprintf(stderr, "metal-pixel: depth bounds color mismatch\n");
            return 96;
        }

        /* Depth clip mode uses the same top-left pixel grid but differs at
         * the normalized depth boundary: clip discards out-of-range depth,
         * while clamp retains the fragment at the nearest endpoint. */
        id<MTLBuffer> metal_depth_clip_vertex_buffer =
            [device newBufferWithBytes:depth_clip_vertices length:sizeof(depth_clip_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_depth_clip_vertex_buffer =
            [adapter_device newBufferWithBytes:depth_clip_vertices length:sizeof(depth_clip_vertices)
                                        options:MTLResourceStorageModeShared];
        if (metal_depth_clip_vertex_buffer == nil || adapter_depth_clip_vertex_buffer == nil) {
            fprintf(stderr, "metal-pixel: depth clip vertex allocation failed\n");
            return 80;
        }
        metal_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        id<MTLCommandBuffer> metal_depth_clip_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_depth_clip_encoder =
            [metal_depth_clip_command_buffer renderCommandEncoderWithDescriptor:metal_depth_pass];
        [metal_depth_clip_encoder setRenderPipelineState:depth_pipeline];
        [metal_depth_clip_encoder setDepthStencilState:depth_state];
        [metal_depth_clip_encoder setDepthClipMode:MTLDepthClipModeClip];
        [metal_depth_clip_encoder setVertexBuffer:metal_depth_clip_vertex_buffer offset:0 atIndex:0];
        [metal_depth_clip_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_depth_clip_encoder endEncoding];
        [metal_depth_clip_command_buffer commit];
        [metal_depth_clip_command_buffer waitUntilCompleted];
        adapter_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        id<MTLCommandBuffer> adapter_depth_clip_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_depth_clip_encoder =
            [adapter_depth_clip_command_buffer renderCommandEncoderWithDescriptor:adapter_depth_pass];
        [adapter_depth_clip_encoder setRenderPipelineState:adapter_depth_pipeline];
        [adapter_depth_clip_encoder setDepthStencilState:adapter_depth_state];
        [adapter_depth_clip_encoder setDepthClipMode:MTLDepthClipModeClip];
        [adapter_depth_clip_encoder setVertexBuffer:adapter_depth_clip_vertex_buffer offset:0 atIndex:0];
        [adapter_depth_clip_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_depth_clip_encoder endEncoding];
        [adapter_depth_clip_command_buffer commit];
        [adapter_depth_clip_command_buffer waitUntilCompleted];
        uint8_t metal_depth_clip_pixels[byte_count];
        uint8_t adapter_depth_clip_pixels[byte_count];
        [metal_depth_color getBytes:metal_depth_clip_pixels bytesPerRow:(NSUInteger)width * 4
                          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_depth_color getBytes:adapter_depth_clip_pixels bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_depth_clip_pixels[index] != adapter_depth_clip_pixels[index]) {
                fprintf(stderr, "metal-pixel: depth clip mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_depth_clip_pixels[index], adapter_depth_clip_pixels[index]);
                return 81;
            }
        }

        metal_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        metal_depth_clip_command_buffer = [queue commandBuffer];
        metal_depth_clip_encoder =
            [metal_depth_clip_command_buffer renderCommandEncoderWithDescriptor:metal_depth_pass];
        [metal_depth_clip_encoder setRenderPipelineState:depth_pipeline];
        [metal_depth_clip_encoder setDepthStencilState:depth_state];
        [metal_depth_clip_encoder setDepthClipMode:MTLDepthClipModeClamp];
        [metal_depth_clip_encoder setVertexBuffer:metal_depth_clip_vertex_buffer offset:0 atIndex:0];
        [metal_depth_clip_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_depth_clip_encoder endEncoding];
        [metal_depth_clip_command_buffer commit];
        [metal_depth_clip_command_buffer waitUntilCompleted];
        adapter_depth_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_depth_pass.depthAttachment.loadAction = MTLLoadActionClear;
        adapter_depth_clip_command_buffer = [adapter_queue commandBuffer];
        adapter_depth_clip_encoder =
            [adapter_depth_clip_command_buffer renderCommandEncoderWithDescriptor:adapter_depth_pass];
        [adapter_depth_clip_encoder setRenderPipelineState:adapter_depth_pipeline];
        [adapter_depth_clip_encoder setDepthStencilState:adapter_depth_state];
        [adapter_depth_clip_encoder setDepthClipMode:MTLDepthClipModeClamp];
        [adapter_depth_clip_encoder setVertexBuffer:adapter_depth_clip_vertex_buffer offset:0 atIndex:0];
        [adapter_depth_clip_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_depth_clip_encoder endEncoding];
        [adapter_depth_clip_command_buffer commit];
        [adapter_depth_clip_command_buffer waitUntilCompleted];
        uint8_t metal_depth_clamp_pixels[byte_count];
        uint8_t adapter_depth_clamp_pixels[byte_count];
        [metal_depth_color getBytes:metal_depth_clamp_pixels bytesPerRow:(NSUInteger)width * 4
                          fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_depth_color getBytes:adapter_depth_clamp_pixels bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_depth_clamp_pixels[index] != adapter_depth_clamp_pixels[index]) {
                fprintf(stderr, "metal-pixel: depth clamp mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_depth_clamp_pixels[index], adapter_depth_clamp_pixels[index]);
                return 82;
            }
        }

        /* A depth-only pass has no color attachment at all. The adapter uses
         * an internal discarded CPU color surface solely to keep the portable
         * raster ABI shape; the public depth texture must still match native
         * Metal byte-for-byte. */
        MTLRenderPipelineDescriptor *depth_only_pipeline_descriptor = [depth_pipeline_descriptor copy];
        depth_only_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        id<MTLRenderPipelineState> metal_depth_only_pipeline =
            [device newRenderPipelineStateWithDescriptor:depth_only_pipeline_descriptor error:&error];
        MTLTextureDescriptor *metal_depth_only_texture_descriptor = [metal_depth_texture_descriptor copy];
        metal_depth_only_texture_descriptor.storageMode = MTLStorageModeShared;
        id<MTLTexture> metal_depth_only_texture =
            [device newTextureWithDescriptor:metal_depth_only_texture_descriptor];
        if (metal_depth_only_pipeline == nil || metal_depth_only_texture == nil) {
            fail_with_error("depth-only reference allocation failed", error);
            return 77;
        }
        MTLRenderPassDescriptor *metal_depth_only_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_depth_only_pass.depthAttachment.texture = metal_depth_only_texture;
        metal_depth_only_pass.depthAttachment.loadAction = MTLLoadActionClear;
        metal_depth_only_pass.depthAttachment.storeAction = MTLStoreActionStore;
        metal_depth_only_pass.depthAttachment.clearDepth = 1.0;
        id<MTLCommandBuffer> metal_depth_only_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_depth_only_encoder =
            [metal_depth_only_command_buffer renderCommandEncoderWithDescriptor:metal_depth_only_pass];
        [metal_depth_only_encoder setRenderPipelineState:metal_depth_only_pipeline];
        [metal_depth_only_encoder setDepthStencilState:depth_state];
        [metal_depth_only_encoder setVertexBuffer:metal_depth_vertex_buffer offset:0 atIndex:0];
        [metal_depth_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [metal_depth_only_encoder endEncoding];
        [metal_depth_only_command_buffer commit];
        [metal_depth_only_command_buffer waitUntilCompleted];
        if (metal_depth_only_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: depth-only reference command did not complete\n");
            return 78;
        }
        uint8_t metal_depth_only_pixels[width * height * sizeof(float)];
        [metal_depth_only_texture getBytes:metal_depth_only_pixels
                               bytesPerRow:(NSUInteger)width * sizeof(float)
                                fromRegion:MTLRegionMake2D(0, 0, width, height)
                               mipmapLevel:0];

        id<MTLTexture> adapter_depth_only_texture =
            [adapter_device newTextureWithDescriptor:metal_depth_only_texture_descriptor];
        id<MTLCommandBuffer> adapter_depth_only_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_depth_only_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_depth_only_pass.depthAttachment.texture = adapter_depth_only_texture;
        adapter_depth_only_pass.depthAttachment.loadAction = MTLLoadActionClear;
        adapter_depth_only_pass.depthAttachment.storeAction = MTLStoreActionStore;
        adapter_depth_only_pass.depthAttachment.clearDepth = 1.0;
        id<MTLRenderCommandEncoder> adapter_depth_only_encoder =
            [adapter_depth_only_command_buffer renderCommandEncoderWithDescriptor:adapter_depth_only_pass];
        NSError *adapter_depth_only_pipeline_error = nil;
        id<MTLRenderPipelineState> adapter_depth_only_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:depth_only_pipeline_descriptor
                                                            error:&adapter_depth_only_pipeline_error];
        if (adapter_depth_only_texture == nil || adapter_depth_only_command_buffer == nil ||
            adapter_depth_only_encoder == nil || adapter_depth_only_pipeline == nil) {
            fail_with_error("depth-only adapter pipeline allocation failed", adapter_depth_only_pipeline_error);
            return 79;
        }
        [adapter_depth_only_encoder setRenderPipelineState:adapter_depth_only_pipeline];
        [adapter_depth_only_encoder setDepthStencilState:depth_state];
        [adapter_depth_only_encoder setVertexBuffer:adapter_depth_vertex_buffer offset:0 atIndex:0];
        [adapter_depth_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:12];
        [adapter_depth_only_encoder endEncoding];
        [adapter_depth_only_command_buffer commit];
        [adapter_depth_only_command_buffer waitUntilCompleted];
        uint8_t adapter_depth_only_pixels[width * height * sizeof(float)];
        [adapter_depth_only_texture getBytes:adapter_depth_only_pixels
                                  bytesPerRow:(NSUInteger)width * sizeof(float)
                                   fromRegion:MTLRegionMake2D(0, 0, width, height)
                                  mipmapLevel:0];
        for (size_t index = 0; index < sizeof(adapter_depth_only_pixels); index++) {
            if (metal_depth_only_pixels[index] != adapter_depth_only_pixels[index]) {
                fprintf(stderr, "metal-pixel: depth-only mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_depth_only_pixels[index], adapter_depth_only_pixels[index]);
                return 80;
            }
        }

        /* Stencil is also a CPU-owned attachment. Use native Metal only as
         * the oracle: a passing draw increments the clear value, then a
         * reference mismatch takes the stencil-failure operation and leaves
         * the first color result intact. Both the color and Stencil8 bytes
         * must match exactly. */
        enum { stencil_byte_count = width * height };
        MTLRenderPipelineDescriptor *stencil_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        stencil_pipeline_descriptor.vertexFunction = vertex_function;
        stencil_pipeline_descriptor.fragmentFunction = fragment_function;
        stencil_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        stencil_pipeline_descriptor.stencilAttachmentPixelFormat = MTLPixelFormatStencil8;
        id<MTLRenderPipelineState> metal_stencil_pipeline =
            [device newRenderPipelineStateWithDescriptor:stencil_pipeline_descriptor error:&error];
        MTLDepthStencilDescriptor *stencil_state_descriptor = [MTLDepthStencilDescriptor new];
        stencil_state_descriptor.depthCompareFunction = MTLCompareFunctionAlways;
        stencil_state_descriptor.depthWriteEnabled = NO;
        MTLStencilDescriptor *stencil_face = [MTLStencilDescriptor new];
        stencil_face.stencilCompareFunction = MTLCompareFunctionEqual;
        stencil_face.stencilFailureOperation = MTLStencilOperationZero;
        stencil_face.depthFailureOperation = MTLStencilOperationDecrementClamp;
        stencil_face.depthStencilPassOperation = MTLStencilOperationIncrementClamp;
        stencil_face.readMask = 0xff;
        stencil_face.writeMask = 0xff;
        stencil_state_descriptor.frontFaceStencil = stencil_face;
        stencil_state_descriptor.backFaceStencil = stencil_face;
        id<MTLDepthStencilState> metal_stencil_state =
            [device newDepthStencilStateWithDescriptor:stencil_state_descriptor];
        MTLTextureDescriptor *metal_stencil_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        metal_stencil_texture_descriptor.storageMode = MTLStorageModeShared;
        metal_stencil_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> metal_stencil_color = [device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> metal_stencil_texture =
            [device newTextureWithDescriptor:metal_stencil_texture_descriptor];
        if (metal_stencil_pipeline == nil || metal_stencil_state == nil ||
            metal_stencil_color == nil || metal_stencil_texture == nil) {
            fail_with_error("stencil reference allocation failed", error);
            return 30;
        }
        MTLRenderPassDescriptor *metal_stencil_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_stencil_pass.colorAttachments[0].texture = metal_stencil_color;
        metal_stencil_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_stencil_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_stencil_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        metal_stencil_pass.stencilAttachment.texture = metal_stencil_texture;
        metal_stencil_pass.stencilAttachment.loadAction = MTLLoadActionClear;
        metal_stencil_pass.stencilAttachment.storeAction = MTLStoreActionStore;
        metal_stencil_pass.stencilAttachment.clearStencil = 3;
        id<MTLCommandBuffer> metal_stencil_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_stencil_encoder =
            [metal_stencil_command_buffer renderCommandEncoderWithDescriptor:metal_stencil_pass];
        [metal_stencil_encoder setRenderPipelineState:metal_stencil_pipeline];
        [metal_stencil_encoder setDepthStencilState:metal_stencil_state];
        [metal_stencil_encoder setStencilReferenceValue:3];
        [metal_stencil_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [metal_stencil_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_stencil_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_stencil_encoder endEncoding];
        [metal_stencil_command_buffer commit];
        [metal_stencil_command_buffer waitUntilCompleted];
        if (metal_stencil_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: stencil reference command did not complete\n");
            return 31;
        }
        uint8_t metal_stencil_pixels[byte_count];
        uint8_t metal_stencil_values[stencil_byte_count];
        [metal_stencil_color getBytes:metal_stencil_pixels
                           bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height)
                           mipmapLevel:0];
        [metal_stencil_texture getBytes:metal_stencil_values
                            bytesPerRow:(NSUInteger)width
                             fromRegion:MTLRegionMake2D(0, 0, width, height)
                            mipmapLevel:0];

        MTLTextureDescriptor *adapter_stencil_color_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        adapter_stencil_color_descriptor.storageMode = MTLStorageModeShared;
        adapter_stencil_color_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> adapter_stencil_color =
            [adapter_device newTextureWithDescriptor:adapter_stencil_color_descriptor];
        MTLTextureDescriptor *adapter_stencil_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatStencil8
                                                                width:width
                                                               height:height
                                                            mipmapped:NO];
        adapter_stencil_texture_descriptor.storageMode = MTLStorageModeShared;
        adapter_stencil_texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> adapter_stencil_texture =
            [adapter_device newTextureWithDescriptor:adapter_stencil_texture_descriptor];
        id<MTLRenderPipelineState> adapter_stencil_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:stencil_pipeline_descriptor error:&error];
        id<MTLDepthStencilState> adapter_stencil_state =
            [adapter_device newDepthStencilStateWithDescriptor:stencil_state_descriptor];
        if (adapter_stencil_color == nil || adapter_stencil_texture == nil ||
            adapter_stencil_pipeline == nil || adapter_stencil_state == nil) {
            fail_with_error("stencil adapter allocation failed", error);
            return 32;
        }
        MTLRenderPassDescriptor *adapter_stencil_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_stencil_pass.colorAttachments[0].texture = adapter_stencil_color;
        adapter_stencil_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_stencil_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_stencil_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        adapter_stencil_pass.stencilAttachment.texture = adapter_stencil_texture;
        adapter_stencil_pass.stencilAttachment.loadAction = MTLLoadActionClear;
        adapter_stencil_pass.stencilAttachment.storeAction = MTLStoreActionStore;
        adapter_stencil_pass.stencilAttachment.clearStencil = 3;
        id<MTLCommandBuffer> adapter_stencil_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_stencil_encoder =
            [adapter_stencil_command_buffer renderCommandEncoderWithDescriptor:adapter_stencil_pass];
        [adapter_stencil_encoder setRenderPipelineState:adapter_stencil_pipeline];
        [adapter_stencil_encoder setDepthStencilState:adapter_stencil_state];
        [adapter_stencil_encoder setStencilReferenceValue:3];
        [adapter_stencil_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_stencil_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_stencil_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_stencil_encoder endEncoding];
        [adapter_stencil_command_buffer commit];
        [adapter_stencil_command_buffer waitUntilCompleted];
        if (adapter_stencil_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: stencil adapter command did not complete\n");
            return 33;
        }
        uint8_t adapter_stencil_pixels[byte_count];
        uint8_t adapter_stencil_values[stencil_byte_count];
        [adapter_stencil_color getBytes:adapter_stencil_pixels
                            bytesPerRow:(NSUInteger)width * 4
                             fromRegion:MTLRegionMake2D(0, 0, width, height)
                            mipmapLevel:0];
        [adapter_stencil_texture getBytes:adapter_stencil_values
                              bytesPerRow:(NSUInteger)width
                               fromRegion:MTLRegionMake2D(0, 0, width, height)
                              mipmapLevel:0];
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_stencil_pixels[index] != adapter_stencil_pixels[index]) {
                fprintf(stderr, "metal-pixel: stencil color mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_stencil_pixels[index], adapter_stencil_pixels[index]);
                return 34;
            }
        }
        for (size_t index = 0; index < stencil_byte_count; index++) {
            if (metal_stencil_values[index] != adapter_stencil_values[index]) {
                fprintf(stderr, "metal-pixel: stencil value mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_stencil_values[index], adapter_stencil_values[index]);
                return 35;
            }
        }

        /* Stencil-only passes use the same no-color path as depth-only
         * passes, with stencil bytes as the observable attachment. */
        MTLRenderPipelineDescriptor *stencil_only_pipeline_descriptor = [stencil_pipeline_descriptor copy];
        stencil_only_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatInvalid;
        id<MTLRenderPipelineState> metal_stencil_only_pipeline =
            [device newRenderPipelineStateWithDescriptor:stencil_only_pipeline_descriptor error:&error];
        id<MTLTexture> metal_stencil_only_texture =
            [device newTextureWithDescriptor:metal_stencil_texture_descriptor];
        if (metal_stencil_only_pipeline == nil || metal_stencil_only_texture == nil) {
            fail_with_error("stencil-only reference allocation failed", error);
            return 81;
        }
        MTLRenderPassDescriptor *metal_stencil_only_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_stencil_only_pass.stencilAttachment.texture = metal_stencil_only_texture;
        metal_stencil_only_pass.stencilAttachment.loadAction = MTLLoadActionClear;
        metal_stencil_only_pass.stencilAttachment.storeAction = MTLStoreActionStore;
        metal_stencil_only_pass.stencilAttachment.clearStencil = 3;
        id<MTLCommandBuffer> metal_stencil_only_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_stencil_only_encoder =
            [metal_stencil_only_command_buffer renderCommandEncoderWithDescriptor:metal_stencil_only_pass];
        [metal_stencil_only_encoder setRenderPipelineState:metal_stencil_only_pipeline];
        [metal_stencil_only_encoder setDepthStencilState:metal_stencil_state];
        [metal_stencil_only_encoder setStencilReferenceValue:3];
        [metal_stencil_only_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [metal_stencil_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_stencil_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [metal_stencil_only_encoder endEncoding];
        [metal_stencil_only_command_buffer commit];
        [metal_stencil_only_command_buffer waitUntilCompleted];
        if (metal_stencil_only_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: stencil-only reference command did not complete\n");
            return 82;
        }
        uint8_t metal_stencil_only_values[stencil_byte_count];
        [metal_stencil_only_texture getBytes:metal_stencil_only_values
                                bytesPerRow:(NSUInteger)width
                                 fromRegion:MTLRegionMake2D(0, 0, width, height)
                                mipmapLevel:0];

        id<MTLTexture> adapter_stencil_only_texture =
            [adapter_device newTextureWithDescriptor:adapter_stencil_texture_descriptor];
        id<MTLCommandBuffer> adapter_stencil_only_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_stencil_only_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_stencil_only_pass.stencilAttachment.texture = adapter_stencil_only_texture;
        adapter_stencil_only_pass.stencilAttachment.loadAction = MTLLoadActionClear;
        adapter_stencil_only_pass.stencilAttachment.storeAction = MTLStoreActionStore;
        adapter_stencil_only_pass.stencilAttachment.clearStencil = 3;
        id<MTLRenderCommandEncoder> adapter_stencil_only_encoder =
            [adapter_stencil_only_command_buffer renderCommandEncoderWithDescriptor:adapter_stencil_only_pass];
        NSError *adapter_stencil_only_pipeline_error = nil;
        id<MTLRenderPipelineState> adapter_stencil_only_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:stencil_only_pipeline_descriptor
                                                            error:&adapter_stencil_only_pipeline_error];
        if (adapter_stencil_only_texture == nil || adapter_stencil_only_command_buffer == nil ||
            adapter_stencil_only_encoder == nil || adapter_stencil_only_pipeline == nil) {
            fail_with_error("stencil-only adapter pipeline allocation failed", adapter_stencil_only_pipeline_error);
            return 83;
        }
        [adapter_stencil_only_encoder setRenderPipelineState:adapter_stencil_only_pipeline];
        [adapter_stencil_only_encoder setDepthStencilState:adapter_stencil_state];
        [adapter_stencil_only_encoder setStencilReferenceValue:3];
        [adapter_stencil_only_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_stencil_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_stencil_only_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_stencil_only_encoder endEncoding];
        [adapter_stencil_only_command_buffer commit];
        [adapter_stencil_only_command_buffer waitUntilCompleted];
        uint8_t adapter_stencil_only_values[stencil_byte_count];
        [adapter_stencil_only_texture getBytes:adapter_stencil_only_values
                                   bytesPerRow:(NSUInteger)width
                                    fromRegion:MTLRegionMake2D(0, 0, width, height)
                                   mipmapLevel:0];
        for (size_t index = 0; index < stencil_byte_count; index++) {
            if (metal_stencil_only_values[index] != adapter_stencil_only_values[index]) {
                fprintf(stderr, "metal-pixel: stencil-only mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_stencil_only_values[index], adapter_stencil_only_values[index]);
                return 84;
            }
        }
        zpu_metal_render_encoder_destroy(zpu_encoder);
        zpu_metal_command_buffer_destroy(zpu_command_buffer);
        zpu_metal_buffer_destroy(zpu_vertex_buffer);
        zpu_metal_texture_destroy(zpu_texture);
        zpu_metal_command_queue_destroy(zpu_queue);
        zpu_metal_device_destroy(zpu_device);
        printf("metal-pixel: exact Metal/ZPU bytes for RGBA8/BGRA8 core, CPU compute, uniform fragment bytes/buffers, deferred vertex/index/indirect render arguments, visibility results, legacy/Metal 4 counters, compiler-created Metal 4 compute/render, render/dispatch/copy, view pools, argument encoders, depth/stencil, heaps, ICBs, and parallel adapter (%ux%u, %zu bytes)\n",
               width, height, (size_t)byte_count);
        return 0;
    }
}

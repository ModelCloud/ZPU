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
    "fragment float4 zpu_test_fragment(Vertex input [[stage_in]]) { return input.color; }\n"
    "kernel void zpu_cpu_fill_gradient_rgba8(texture2d<float, access::write> output [[texture(0)]], "
    "uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write(float4((float(gid.x) + 1.0) / 8.0, (float(gid.y) + 1.0) / 8.0, 0.25, 1.0), gid); }\n"
    "kernel void zpu_cpu_copy_rgba8_buffer_to_texture(device const uchar4 *source [[buffer(0)]], "
    "texture2d<float, access::write> output [[texture(1)]], uint2 gid [[thread_position_in_grid]]) { "
    "if (gid.x >= output.get_width() || gid.y >= output.get_height()) return; "
    "output.write(float4(source[gid.y * output.get_width() + gid.x]) / 255.0, gid); }\n";

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
        id<MTLFunction> fragment_function = [library newFunctionWithName:@"zpu_test_fragment"];
        if (vertex_function == nil || fragment_function == nil) {
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
        id<MTLFunction> adapter_vertex_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_vertex");
        id<MTLFunction> adapter_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_fragment");
        MTLRenderPipelineDescriptor *adapter_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        adapter_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        adapter_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_pipeline_descriptor.supportIndirectCommandBuffers = YES;
        id<MTLCommandQueue> adapter_queue = [adapter_device newCommandQueue];
        id<MTLCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
        NSError *adapter_pipeline_error = nil;
        id<MTLRenderPipelineState> adapter_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor error:&adapter_pipeline_error];
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

        /* Library/function discovery is also CPU metadata. The source text
         * is inspected only for registered ZPU kernel names; it is never sent
         * to Apple's compiler by the adapter. */
        NSError *adapter_library_error = nil;
        NSString *adapter_cpu_source =
            @"kernel void zpu_cpu_fill_gradient_rgba8() {}\n"
             "kernel void zpu_cpu_copy_rgba8_buffer_to_texture() {}";
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
            adapter_library.functionNames.count != 2 || !adapter_library_completion_called ||
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
        [[NSFileManager defaultManager] removeItemAtURL:adapter_archive_url error:nil];
        if (adapter_archive == nil ||
            ![adapter_archive conformsToProtocol:@protocol(MTLBinaryArchive)] ||
            !adapter_archive_compute_added || !adapter_archive_render_added ||
            !adapter_archive_serialized || !adapter_reloaded_archive || !adapter_archive_reloaded) {
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
        no_copy_buffer = nil;
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
        if (adapter_event == nil || !adapter_event_notified ||
            ![adapter_event waitUntilSignaledValue:7 timeoutMS:0]) {
            fprintf(stderr, "metal-pixel: shared event adapter failed\n");
            return 19;
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
        __block BOOL adapter_completed = NO;
        [adapter_command_buffer addScheduledHandler:^(id<MTLCommandBuffer> buffer) {
            (void)buffer;
            adapter_scheduled = YES;
        }];
        [adapter_command_buffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
            (void)buffer;
            adapter_completed = YES;
        }];
        [adapter_command_buffer commit];
        [adapter_command_buffer waitUntilCompleted];
        if (adapter_command_buffer.status != MTLCommandBufferStatusCompleted ||
            !adapter_scheduled || !adapter_completed) {
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
            adapter_heap.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_heap_buffer.hazardTrackingMode != MTLHazardTrackingModeUntracked ||
            adapter_heap_texture.hazardTrackingMode != MTLHazardTrackingModeUntracked) {
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
        zpu_metal_render_encoder_destroy(zpu_encoder);
        zpu_metal_command_buffer_destroy(zpu_command_buffer);
        zpu_metal_buffer_destroy(zpu_vertex_buffer);
        zpu_metal_texture_destroy(zpu_texture);
        zpu_metal_command_queue_destroy(zpu_queue);
        zpu_metal_device_destroy(zpu_device);
        printf("metal-pixel: exact Metal/ZPU bytes for RGBA8/BGRA8 core, CPU compute, legacy/Metal 4 counters, render/dispatch/copy, view pools, argument encoders, depth, heaps, ICBs, and parallel adapter (%ux%u, %zu bytes)\n",
               width, height, (size_t)byte_count);
        return 0;
    }
}

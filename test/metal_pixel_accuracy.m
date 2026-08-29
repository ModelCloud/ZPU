/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Metal/MTLIOCompressor.h>
#import <IOSurface/IOSurfaceRef.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <float.h>

#include "zpu/metal.h"
#include "zpu/metal_apple.h"

static const char *const kShaderSource =
    "#include <metal_stdlib>\n"
    "using namespace metal;\n"
    "struct Vertex { float4 position [[position]]; float4 color; };\n"
    "vertex Vertex zpu_test_vertex(uint vertex_id [[vertex_id]], "
    "device const Vertex *vertices [[buffer(0)]]) { return vertices[vertex_id]; }\n"
    "struct StageVertex { float4 position [[attribute(0)]]; float4 color [[attribute(1)]]; };\n"
    "vertex Vertex zpu_test_stage_in_vertex(StageVertex input [[stage_in]]) { "
    "Vertex output; output.position = input.position; output.color = input.color; return output; }\n"
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
    "[[visible]] float4 zpu_test_visible(float4 value) { return value; }\n"
    "[[visible]] float4 zpu_test_visible_secondary(float4 value) { return value + 1.0; }\n"
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

static int test_vertex_attribute_stride_against_native(
    id<MTLDevice> native_device, id<MTLDevice> adapter_device,
    id<MTLFunction> native_vertex_function, id<MTLFunction> native_fragment_function,
    id<MTLFunction> adapter_vertex_function, id<MTLFunction> adapter_fragment_function)
    API_AVAILABLE(macos(14.0), ios(17.0)) {
    enum { width = 8, height = 8, byte_count = width * height * 4, vertex_count = 6 };
    const NSUInteger stride = 48;
    const zpu_metal_vertex vertices[vertex_count] = {
        {{-0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        {{ 0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        {{ 0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        {{-0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        {{ 0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        {{-0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
    };
    uint8_t padded_vertices[vertex_count * stride];
    memset(padded_vertices, 0xcd, sizeof(padded_vertices));
    for (NSUInteger index = 0; index < vertex_count; ++index) {
        memcpy(padded_vertices + index * stride, &vertices[index], sizeof(vertices[index]));
    }
    for (NSUInteger case_index = 0; case_index < 2; ++case_index) {
        const BOOL dynamic_stride = case_index == 0;
        MTLVertexDescriptor *vertex_descriptor = [MTLVertexDescriptor vertexDescriptor];
        vertex_descriptor.attributes[0].format = MTLVertexFormatFloat4;
        vertex_descriptor.attributes[0].offset = 0;
        vertex_descriptor.attributes[0].bufferIndex = 0;
        vertex_descriptor.attributes[1].format = MTLVertexFormatFloat4;
        vertex_descriptor.attributes[1].offset = sizeof(float) * 4;
        vertex_descriptor.attributes[1].bufferIndex = 0;
        vertex_descriptor.layouts[0].stride = dynamic_stride ? MTLBufferLayoutStrideDynamic : stride;
        vertex_descriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
        vertex_descriptor.layouts[0].stepRate = 1;

        MTLRenderPipelineDescriptor *native_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        native_pipeline_descriptor.vertexFunction = native_vertex_function;
        native_pipeline_descriptor.fragmentFunction = native_fragment_function;
        native_pipeline_descriptor.vertexDescriptor = vertex_descriptor;
        native_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        native_pipeline_descriptor.supportIndirectCommandBuffers = YES;
        MTLRenderPipelineDescriptor *adapter_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
        adapter_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        adapter_pipeline_descriptor.vertexDescriptor = [vertex_descriptor copy];
        adapter_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_pipeline_descriptor.supportIndirectCommandBuffers = YES;
        NSError *native_error = nil;
        NSError *adapter_error = nil;
        id<MTLRenderPipelineState> native_pipeline =
            [native_device newRenderPipelineStateWithDescriptor:native_pipeline_descriptor error:&native_error];
        id<MTLRenderPipelineState> adapter_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor error:&adapter_error];
        MTLTextureDescriptor *texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:width height:height mipmapped:NO];
        texture_descriptor.storageMode = MTLStorageModeShared;
        texture_descriptor.usage = MTLTextureUsageRenderTarget;
        id<MTLTexture> native_texture = [native_device newTextureWithDescriptor:texture_descriptor];
        id<MTLTexture> adapter_texture = [adapter_device newTextureWithDescriptor:texture_descriptor];
        id<MTLBuffer> native_buffer =
            [native_device newBufferWithBytes:padded_vertices length:sizeof(padded_vertices)
                                       options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_buffer =
            [adapter_device newBufferWithBytes:padded_vertices length:sizeof(padded_vertices)
                                        options:MTLResourceStorageModeShared];
        if (native_pipeline == nil || adapter_pipeline == nil || native_texture == nil ||
            adapter_texture == nil || native_buffer == nil || adapter_buffer == nil) {
            fail_with_error(dynamic_stride ? "dynamic vertex-stride pipeline allocation failed" :
                            "static vertex-stride pipeline allocation failed", adapter_error ?: native_error);
            return dynamic_stride ? 140 : 141;
        }
        MTLRenderPassDescriptor *native_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_pass.colorAttachments[0].texture = native_texture;
        native_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        MTLRenderPassDescriptor *adapter_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_pass.colorAttachments[0].texture = adapter_texture;
        adapter_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandQueue> native_queue = [native_device newCommandQueue];
        id<MTLCommandQueue> adapter_queue = [adapter_device newCommandQueue];
        id<MTLCommandBuffer> native_command_buffer = [native_queue commandBuffer];
        id<MTLCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> native_encoder =
            [native_command_buffer renderCommandEncoderWithDescriptor:native_pass];
        id<MTLRenderCommandEncoder> adapter_encoder =
            [adapter_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
        [native_encoder setRenderPipelineState:native_pipeline];
        [adapter_encoder setRenderPipelineState:adapter_pipeline];
        if (dynamic_stride) {
            [native_encoder setVertexBuffer:native_buffer offset:0 attributeStride:stride atIndex:0];
            [adapter_encoder setVertexBuffer:adapter_buffer offset:0 attributeStride:stride atIndex:0];
        } else {
            [native_encoder setVertexBuffer:native_buffer offset:0 atIndex:0];
            [adapter_encoder setVertexBuffer:adapter_buffer offset:0 atIndex:0];
        }
        [native_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertex_count];
        [adapter_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:vertex_count];
        [native_encoder endEncoding];
        [adapter_encoder endEncoding];
        [native_command_buffer commit];
        [adapter_command_buffer commit];
        [native_command_buffer waitUntilCompleted];
        [adapter_command_buffer waitUntilCompleted];
        uint8_t native_pixels[byte_count];
        uint8_t adapter_pixels[byte_count];
        [native_texture getBytes:native_pixels bytesPerRow:width * 4
                       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_texture getBytes:adapter_pixels bytesPerRow:width * 4
                         fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_pixels, adapter_pixels, sizeof(native_pixels)) != 0) {
            size_t mismatch = 0;
            while (mismatch < sizeof(native_pixels) && native_pixels[mismatch] == adapter_pixels[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: %s vertex-stride bytes mismatch at %zu native=%u adapter=%u statuses=%ld/%ld\n",
                    dynamic_stride ? "dynamic" : "static", mismatch,
                    mismatch < sizeof(native_pixels) ? native_pixels[mismatch] : 0,
                    mismatch < sizeof(adapter_pixels) ? adapter_pixels[mismatch] : 0,
                    (long)native_command_buffer.status, (long)adapter_command_buffer.status);
            return dynamic_stride ? 142 : 143;
        }
    }
    MTLVertexDescriptor *unsupported_vertex_descriptor = [MTLVertexDescriptor vertexDescriptor];
    unsupported_vertex_descriptor.attributes[2].format = MTLVertexFormatFloat4;
    MTLRenderPipelineDescriptor *unsupported_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
    unsupported_pipeline_descriptor.vertexFunction = adapter_vertex_function;
    unsupported_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
    unsupported_pipeline_descriptor.vertexDescriptor = unsupported_vertex_descriptor;
    unsupported_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    NSError *unsupported_error = nil;
    if ([adapter_device newRenderPipelineStateWithDescriptor:unsupported_pipeline_descriptor
                                                       error:&unsupported_error] != nil) {
        fail_with_error("unsupported extra vertex attribute was accepted", unsupported_error);
        return 145;
    }
    return 0;
}

static int test_mip_sampler_against_native(
    id<MTLDevice> native_device, id<MTLDevice> adapter_device,
    id<MTLFunction> native_vertex_function, id<MTLFunction> native_fragment_function,
    id<MTLFunction> adapter_vertex_function, id<MTLFunction> adapter_fragment_function,
    MTLSamplerMinMagFilter min_filter, MTLSamplerMinMagFilter mag_filter,
    MTLSamplerMipFilter mip_filter, MTLSamplerReductionMode reduction_mode,
    float lod_bias, float lod_min_clamp, float lod_max_clamp,
    BOOL normalized_coordinates, NSUInteger max_anisotropy, float v_scale) {
    enum { output_width = 4, output_height = 4, mip_width = 16, mip_height = 16,
           mip_levels = 5, byte_count = output_width * output_height * 4 };
    const zpu_metal_vertex vertices[] = {
        {{-1.0f, -1.0f, 0.5f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f, -1.0f, 0.5f, 1.0f}, {normalized_coordinates ? 1.0f : 16.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.5f, 1.0f}, {normalized_coordinates ? 1.0f : 16.0f, (normalized_coordinates ? 1.0f : 16.0f) * v_scale, 0.0f, 1.0f}},
        {{-1.0f, -1.0f, 0.5f, 1.0f}, {0.0f, 0.0f, 0.0f, 1.0f}},
        {{ 1.0f,  1.0f, 0.5f, 1.0f}, {normalized_coordinates ? 1.0f : 16.0f, (normalized_coordinates ? 1.0f : 16.0f) * v_scale, 0.0f, 1.0f}},
        {{-1.0f,  1.0f, 0.5f, 1.0f}, {0.0f, (normalized_coordinates ? 1.0f : 16.0f) * v_scale, 0.0f, 1.0f}},
    };
    const uint8_t level_colors[mip_levels][4] = {
        {255, 0, 0, 255}, {0, 255, 0, 255}, {0, 0, 255, 255},
        {255, 255, 0, 255}, {255, 0, 255, 255},
    };
    MTLTextureDescriptor *source_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:mip_width height:mip_height mipmapped:YES];
    source_descriptor.storageMode = MTLStorageModeShared;
    source_descriptor.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> native_source = [native_device newTextureWithDescriptor:source_descriptor];
    id<MTLTexture> adapter_source = [adapter_device newTextureWithDescriptor:source_descriptor];
    uint8_t level_bytes[mip_width * mip_height * 4];
    for (NSUInteger level = 0; level < mip_levels; ++level) {
        const NSUInteger level_width = MAX((NSUInteger)1, (NSUInteger)mip_width >> level);
        const NSUInteger level_height = MAX((NSUInteger)1, (NSUInteger)mip_height >> level);
        for (NSUInteger pixel = 0; pixel < level_width * level_height; ++pixel) {
            if (level == 0) {
                const BOOL checker = (((pixel % level_width) ^ (pixel / level_width)) & 1) != 0;
                memcpy(level_bytes + pixel * 4, checker ? (const uint8_t[]){255, 0, 0, 255} :
                    (const uint8_t[]){0, 0, 255, 255}, 4);
            } else memcpy(level_bytes + pixel * 4, level_colors[level], 4);
        }
        [native_source replaceRegion:MTLRegionMake2D(0, 0, level_width, level_height)
                          mipmapLevel:level withBytes:level_bytes bytesPerRow:level_width * 4];
        [adapter_source replaceRegion:MTLRegionMake2D(0, 0, level_width, level_height)
                           mipmapLevel:level withBytes:level_bytes bytesPerRow:level_width * 4];
    }

    MTLRenderPipelineDescriptor *native_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
    native_pipeline_descriptor.vertexFunction = native_vertex_function;
    native_pipeline_descriptor.fragmentFunction = native_fragment_function;
    native_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    native_pipeline_descriptor.supportIndirectCommandBuffers = NO;
    NSError *native_error = nil;
    id<MTLRenderPipelineState> native_pipeline =
        [native_device newRenderPipelineStateWithDescriptor:native_pipeline_descriptor error:&native_error];
    MTLRenderPipelineDescriptor *adapter_pipeline_descriptor = [native_pipeline_descriptor copy];
    adapter_pipeline_descriptor.vertexFunction = adapter_vertex_function;
    adapter_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
    NSError *adapter_error = nil;
    id<MTLRenderPipelineState> adapter_pipeline =
        [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor error:&adapter_error];
    MTLTextureDescriptor *output_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:output_width height:output_height mipmapped:NO];
    output_descriptor.storageMode = MTLStorageModeShared;
    output_descriptor.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> native_output = [native_device newTextureWithDescriptor:output_descriptor];
    id<MTLTexture> adapter_output = [adapter_device newTextureWithDescriptor:output_descriptor];
    id<MTLBuffer> native_vertex_buffer =
        [native_device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
    id<MTLBuffer> adapter_vertex_buffer =
        [adapter_device newBufferWithBytes:vertices length:sizeof(vertices) options:MTLResourceStorageModeShared];
    MTLSamplerDescriptor *sampler_descriptor = [MTLSamplerDescriptor new];
    sampler_descriptor.minFilter = min_filter;
    sampler_descriptor.magFilter = mag_filter;
    sampler_descriptor.mipFilter = mip_filter;
    sampler_descriptor.normalizedCoordinates = normalized_coordinates;
    sampler_descriptor.lodMinClamp = lod_min_clamp;
    sampler_descriptor.lodMaxClamp = lod_max_clamp;
    sampler_descriptor.maxAnisotropy = max_anisotropy;
    if (@available(macOS 26.0, iOS 26.0, *)) {
        sampler_descriptor.lodBias = lod_bias;
        sampler_descriptor.reductionMode = reduction_mode;
    }
    id<MTLSamplerState> native_sampler = [native_device newSamplerStateWithDescriptor:sampler_descriptor];
    id<MTLSamplerState> adapter_sampler = [adapter_device newSamplerStateWithDescriptor:sampler_descriptor];
    if (native_source == nil || adapter_source == nil || native_pipeline == nil || adapter_pipeline == nil ||
        native_output == nil || adapter_output == nil || native_vertex_buffer == nil || adapter_vertex_buffer == nil ||
        native_sampler == nil || adapter_sampler == nil) {
        fail_with_error("mip sampler resource allocation failed", adapter_error ?: native_error);
        return 150;
    }

    MTLRenderPassDescriptor *native_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    native_pass.colorAttachments[0].texture = native_output;
    native_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    native_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    native_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLCommandQueue> native_queue = [native_device newCommandQueue];
    id<MTLCommandBuffer> native_command_buffer = [native_queue commandBuffer];
    id<MTLRenderCommandEncoder> native_encoder =
        [native_command_buffer renderCommandEncoderWithDescriptor:native_pass];
    [native_encoder setRenderPipelineState:native_pipeline];
    [native_encoder setVertexBuffer:native_vertex_buffer offset:0 atIndex:0];
    [native_encoder setFragmentTexture:native_source atIndex:0];
    [native_encoder setFragmentSamplerState:native_sampler atIndex:0];
    [native_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [native_encoder endEncoding];
    [native_command_buffer commit];
    [native_command_buffer waitUntilCompleted];

    MTLRenderPassDescriptor *adapter_pass = [MTLRenderPassDescriptor renderPassDescriptor];
    adapter_pass.colorAttachments[0].texture = adapter_output;
    adapter_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    adapter_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    adapter_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
    id<MTLCommandQueue> adapter_queue = [adapter_device newCommandQueue];
    id<MTLCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
    id<MTLRenderCommandEncoder> adapter_encoder =
        [adapter_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
    [adapter_encoder setRenderPipelineState:adapter_pipeline];
    [adapter_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
    [adapter_encoder setFragmentTexture:adapter_source atIndex:0];
    [adapter_encoder setFragmentSamplerState:adapter_sampler atIndex:0];
    [adapter_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
    [adapter_encoder endEncoding];
    [adapter_command_buffer commit];
    [adapter_command_buffer waitUntilCompleted];

    uint8_t native_bytes[byte_count];
    uint8_t adapter_bytes[byte_count];
    [native_output getBytes:native_bytes bytesPerRow:output_width * 4
                  fromRegion:MTLRegionMake2D(0, 0, output_width, output_height) mipmapLevel:0];
    [adapter_output getBytes:adapter_bytes bytesPerRow:output_width * 4
                    fromRegion:MTLRegionMake2D(0, 0, output_width, output_height) mipmapLevel:0];
    if (native_command_buffer.status != MTLCommandBufferStatusCompleted ||
        adapter_command_buffer.status != MTLCommandBufferStatusCompleted ||
        memcmp(native_bytes, adapter_bytes, byte_count) != 0) {
        size_t mismatch = 0;
        while (mismatch < byte_count && native_bytes[mismatch] == adapter_bytes[mismatch]) mismatch += 1;
        fprintf(stderr, "metal-pixel: mip sampler mismatch filter=%ld lod=%g..%g at byte %zu Metal=%u ZPU=%u\n",
                (long)mip_filter, lod_min_clamp, lod_max_clamp, mismatch,
                mismatch < byte_count ? native_bytes[mismatch] : 0,
                mismatch < byte_count ? adapter_bytes[mismatch] : 0);
        return 151;
    }
    return 0;
}

static int test_cpu_io_against_native(id<MTLDevice> native_device, id<MTLDevice> adapter_device) {
    const uint8_t source_bytes[] = {
        0x10, 0x20, 0x30, 0xff, 0x40, 0x50, 0x60, 0xff, 0x70, 0x80, 0x90, 0xff,
        0xa0, 0xb0, 0xc0, 0xff, 0xd0, 0xe0, 0xf0, 0xff, 0x01, 0x02, 0x03, 0xff,
    };
    NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
        stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
    NSError *error = nil;
    NSData *source = [NSData dataWithBytes:source_bytes length:sizeof(source_bytes)];
    if (![source writeToURL:url options:NSDataWritingAtomic error:&error]) {
        fail_with_error("Metal I/O test source file creation failed", error);
        return 60;
    }

    MTLIOCommandQueueDescriptor *native_descriptor = [MTLIOCommandQueueDescriptor new];
    native_descriptor.maxCommandBufferCount = 4;
    native_descriptor.type = MTLIOCommandQueueTypeSerial;
    id<MTLIOCommandQueue> native_queue =
        [native_device newIOCommandQueueWithDescriptor:native_descriptor error:&error];
    id<MTLIOFileHandle> native_handle = [native_device newIOFileHandleWithURL:url error:&error];
    MTLIOCommandQueueDescriptor *adapter_descriptor = [MTLIOCommandQueueDescriptor new];
    adapter_descriptor.maxCommandBufferCount = 4;
    adapter_descriptor.type = MTLIOCommandQueueTypeSerial;
    id<MTLIOCommandQueue> adapter_queue =
        [adapter_device newIOCommandQueueWithDescriptor:adapter_descriptor error:&error];
    id<MTLIOFileHandle> adapter_handle = [adapter_device newIOFileHandleWithURL:url error:&error];
    if (native_queue == nil || native_handle == nil || adapter_queue == nil || adapter_handle == nil) {
        fail_with_error("Metal I/O raw queue or handle creation failed", error);
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 61;
    }
    native_queue.label = @"native-io-oracle";
    adapter_queue.label = @"zpu-cpu-io";
    native_handle.label = @"native-raw-file";
    adapter_handle.label = @"zpu-raw-file";
    if (![adapter_queue.label isEqualToString:@"zpu-cpu-io"] ||
        ![adapter_handle.label isEqualToString:@"zpu-raw-file"]) {
        fprintf(stderr, "metal-pixel: CPU Metal I/O labels did not round-trip\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 62;
    }

    id<MTLBuffer> native_buffer =
        [native_device newBufferWithLength:sizeof(source_bytes) options:MTLResourceStorageModeShared];
    id<MTLBuffer> adapter_buffer =
        [adapter_device newBufferWithLength:sizeof(source_bytes) options:MTLResourceStorageModeShared];
    id<MTLBuffer> native_status = [native_device newBufferWithLength:sizeof(uint32_t)
                                                               options:MTLResourceStorageModeShared];
    id<MTLBuffer> adapter_status = [adapter_device newBufferWithLength:sizeof(uint32_t)
                                                                 options:MTLResourceStorageModeShared];
    MTLTextureDescriptor *texture_descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:8 height:8 mipmapped:NO];
    texture_descriptor.storageMode = MTLStorageModeShared;
    texture_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    id<MTLTexture> native_texture = [native_device newTextureWithDescriptor:texture_descriptor];
    id<MTLTexture> adapter_texture = [adapter_device newTextureWithDescriptor:texture_descriptor];
    id<MTLIOCommandBuffer> native_command_buffer = [native_queue commandBuffer];
    id<MTLIOCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
    if (native_buffer == nil || adapter_buffer == nil || native_status == nil || adapter_status == nil ||
        native_texture == nil || adapter_texture == nil || native_command_buffer == nil ||
        adapter_command_buffer == nil) {
        fprintf(stderr, "metal-pixel: Metal I/O resource or command buffer creation failed\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 63;
    }
    const MTLSize texture_size = MTLSizeMake(3, 2, 1);
    const MTLOrigin texture_origin = MTLOriginMake(2, 3, 0);
    [native_command_buffer loadBuffer:native_buffer offset:0 size:sizeof(source_bytes)
                         sourceHandle:native_handle sourceHandleOffset:0];
    [adapter_command_buffer loadBuffer:adapter_buffer offset:0 size:sizeof(source_bytes)
                         sourceHandle:adapter_handle sourceHandleOffset:0];
    [native_command_buffer loadTexture:native_texture slice:0 level:0 size:texture_size
                    sourceBytesPerRow:12 sourceBytesPerImage:24 destinationOrigin:texture_origin
                         sourceHandle:native_handle sourceHandleOffset:0];
    [adapter_command_buffer loadTexture:adapter_texture slice:0 level:0 size:texture_size
                    sourceBytesPerRow:12 sourceBytesPerImage:24 destinationOrigin:texture_origin
                         sourceHandle:adapter_handle sourceHandleOffset:0];
    [native_command_buffer copyStatusToBuffer:native_status offset:0];
    [adapter_command_buffer copyStatusToBuffer:adapter_status offset:0];
    [native_command_buffer commit];
    [native_command_buffer waitUntilCompleted];
    [adapter_command_buffer commit];
    [adapter_command_buffer waitUntilCompleted];
    if (native_command_buffer.status != MTLIOStatusComplete ||
        adapter_command_buffer.status != MTLIOStatusComplete ||
        memcmp(native_buffer.contents, adapter_buffer.contents, sizeof(source_bytes)) != 0 ||
        memcmp(native_status.contents, adapter_status.contents, sizeof(uint32_t)) != 0) {
        fprintf(stderr, "metal-pixel: native/CPU Metal I/O buffer or status mismatch\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 64;
    }
    uint8_t native_texture_bytes[8 * 8 * 4];
    uint8_t adapter_texture_bytes[8 * 8 * 4];
    [native_texture getBytes:native_texture_bytes bytesPerRow:8 * 4
                   fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    [adapter_texture getBytes:adapter_texture_bytes bytesPerRow:8 * 4
                    fromRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0];
    if (memcmp(native_texture_bytes, adapter_texture_bytes, sizeof(native_texture_bytes)) != 0 ||
        memcmp(adapter_texture_bytes + (3 * 8 + 2) * 4, source_bytes, 12) != 0 ||
        memcmp(adapter_texture_bytes + (4 * 8 + 2) * 4, source_bytes + 12, 12) != 0) {
        fprintf(stderr, "metal-pixel: native/CPU Metal I/O texture origin or bytes mismatch\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 65;
    }

    uint8_t native_bytes[8] = {0};
    uint8_t adapter_bytes[8] = {0};
    id<MTLIOCommandBuffer> native_bytes_command_buffer = [native_queue commandBuffer];
    id<MTLIOCommandBuffer> adapter_bytes_command_buffer = [adapter_queue commandBuffer];
    [native_bytes_command_buffer loadBytes:native_bytes size:sizeof(native_bytes)
                              sourceHandle:native_handle sourceHandleOffset:4];
    [adapter_bytes_command_buffer loadBytes:adapter_bytes size:sizeof(adapter_bytes)
                              sourceHandle:adapter_handle sourceHandleOffset:4];
    [native_bytes_command_buffer commit];
    [native_bytes_command_buffer waitUntilCompleted];
    [adapter_bytes_command_buffer commit];
    [adapter_bytes_command_buffer waitUntilCompleted];
    if (native_bytes_command_buffer.status != MTLIOStatusComplete ||
        adapter_bytes_command_buffer.status != MTLIOStatusComplete ||
        memcmp(native_bytes, adapter_bytes, sizeof(native_bytes)) != 0 ||
        memcmp(adapter_bytes, source_bytes + 4, sizeof(adapter_bytes)) != 0) {
        fprintf(stderr, "metal-pixel: native/CPU Metal I/O loadBytes mismatch\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 66;
    }

    id<MTLSharedEvent> event = [adapter_device newSharedEvent];
    id<MTLIOCommandBuffer> signal_command_buffer = [adapter_queue commandBuffer];
    id<MTLIOCommandBuffer> wait_command_buffer = [adapter_queue commandBuffer];
    [signal_command_buffer signalEvent:event value:7];
    [signal_command_buffer commit];
    [wait_command_buffer waitForEvent:event value:7];
    [wait_command_buffer commit];
    id<MTLIOCommandBuffer> cancelled_command_buffer = [adapter_queue commandBuffer];
    [cancelled_command_buffer tryCancel];
    if (event.signaledValue != 7 || wait_command_buffer.status != MTLIOStatusComplete ||
        cancelled_command_buffer.status != MTLIOStatusCancelled) {
        fprintf(stderr, "metal-pixel: CPU Metal I/O shared-event or cancellation semantics failed\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 67;
    }
    uint8_t compressed_source[128];
    memset(compressed_source, 0x5a, sizeof(compressed_source));
    uint8_t patterned_source[128];
    memcpy(patterned_source, compressed_source, sizeof(compressed_source));
    for (size_t index = 64; index < sizeof(patterned_source); ++index) {
        patterned_source[index] = (uint8_t)((index * 37 + 11) & 0xff);
    }
    const MTLIOCompressionMethod compression_methods[] = {
        MTLIOCompressionMethodZlib,
        MTLIOCompressionMethodLZFSE,
        MTLIOCompressionMethodLZ4,
        MTLIOCompressionMethodLZMA,
        MTLIOCompressionMethodLZBitmap,
    };
    for (NSUInteger method_index = 0;
         method_index < sizeof(compression_methods) / sizeof(compression_methods[0]); ++method_index) {
        NSURL *compressed_url = [NSURL fileURLWithPath:[NSTemporaryDirectory()
            stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
        MTLIOCompressionContext compression_context = MTLIOCreateCompressionContext(
            compressed_url.path.fileSystemRepresentation, compression_methods[method_index], 64);
        if (compression_context == NULL) {
            fprintf(stderr, "metal-pixel: native compressed Metal I/O context creation failed for method %lu\n",
                    (unsigned long)method_index);
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            return 68;
        }
        MTLIOCompressionContextAppendData(compression_context, patterned_source, sizeof(patterned_source));
        if (MTLIOFlushAndDestroyCompressionContext(compression_context) != MTLIOCompressionStatusComplete) {
            fprintf(stderr, "metal-pixel: native compressed Metal I/O pack creation failed for method %lu\n",
                    (unsigned long)method_index);
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            return 69;
        }
        NSError *compressed_error = nil;
        id<MTLIOFileHandle> native_compressed_handle = [native_device
            newIOFileHandleWithURL:compressed_url compressionMethod:compression_methods[method_index]
            error:&compressed_error];
        id<MTLIOFileHandle> adapter_compressed_handle = [adapter_device
            newIOFileHandleWithURL:compressed_url compressionMethod:compression_methods[method_index]
            error:&compressed_error];
        uint8_t native_compressed_bytes[sizeof(patterned_source)] = {0};
        uint8_t adapter_compressed_bytes[sizeof(patterned_source)] = {0};
        id<MTLIOCommandBuffer> native_compressed_command_buffer = [native_queue commandBuffer];
        id<MTLIOCommandBuffer> adapter_compressed_command_buffer = [adapter_queue commandBuffer];
        [native_compressed_command_buffer loadBytes:native_compressed_bytes size:sizeof(native_compressed_bytes)
                                       sourceHandle:native_compressed_handle sourceHandleOffset:0];
        [adapter_compressed_command_buffer loadBytes:adapter_compressed_bytes size:sizeof(adapter_compressed_bytes)
                                        sourceHandle:adapter_compressed_handle sourceHandleOffset:0];
        [native_compressed_command_buffer commit];
        [native_compressed_command_buffer waitUntilCompleted];
        [adapter_compressed_command_buffer commit];
        [adapter_compressed_command_buffer waitUntilCompleted];
        if (native_compressed_handle == nil || adapter_compressed_handle == nil ||
            native_compressed_command_buffer.status != MTLIOStatusComplete ||
            adapter_compressed_command_buffer.status != MTLIOStatusComplete ||
            memcmp(native_compressed_bytes, patterned_source, sizeof(patterned_source)) != 0 ||
            memcmp(adapter_compressed_bytes, patterned_source, sizeof(patterned_source)) != 0 ||
            memcmp(native_compressed_bytes, adapter_compressed_bytes, sizeof(patterned_source)) != 0) {
            fail_with_error("native/CPU compressed Metal I/O bytes mismatch", compressed_error);
            [[NSFileManager defaultManager] removeItemAtURL:compressed_url error:nil];
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
            return 70;
        }
        [[NSFileManager defaultManager] removeItemAtURL:compressed_url error:nil];
    }
    if ([adapter_device newIOFileHandleWithURL:url compressionMethod:MTLIOCompressionMethodZlib error:&error] != nil) {
        fprintf(stderr, "metal-pixel: raw file was accepted as a compressed Metal I/O pack\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 71;
    }
    id<MTLDevice> foreign_device = ZPUMetalCreateSystemDefaultDevice();
    id<MTLBuffer> foreign_buffer = [foreign_device newBufferWithLength:sizeof(source_bytes)
                                                                   options:MTLResourceStorageModeShared];
    id<MTLIOCommandBuffer> invalid_command_buffer = [adapter_queue commandBuffer];
    [invalid_command_buffer loadBuffer:foreign_buffer offset:0 size:4
                          sourceHandle:adapter_handle sourceHandleOffset:0];
    [invalid_command_buffer commit];
    if (foreign_device == nil || foreign_buffer == nil ||
        invalid_command_buffer.status != MTLIOStatusError || invalid_command_buffer.error == nil) {
        fprintf(stderr, "metal-pixel: CPU Metal I/O foreign-resource validation failed\n");
        [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
        return 72;
    }
    [[NSFileManager defaultManager] removeItemAtURL:url error:nil];
    return 0;
}

static int test_cpu_drawable_lifecycle(id<MTLDevice> native_device, id<MTLDevice> adapter_device) {
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:4 height:4 mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> native_texture = [native_device newTextureWithDescriptor:descriptor];
    id<MTLTexture> adapter_texture = [adapter_device newTextureWithDescriptor:descriptor];
    if (native_texture == nil || adapter_texture == nil ||
        ZPUMetalCreateCPUDrawable(native_texture) != nil) {
        fprintf(stderr, "metal-pixel: CPU drawable ownership validation failed\n");
        return 131;
    }

    id<MTLDrawable> drawable = ZPUMetalCreateCPUDrawable(adapter_texture);
    id<MTLCommandQueue> queue = [adapter_device newCommandQueue];
    id<MTLCommandBuffer> command_buffer = [queue commandBuffer];
    if (drawable == nil || queue == nil || command_buffer == nil) {
        fprintf(stderr, "metal-pixel: CPU drawable or command queue creation failed\n");
        return 132;
    }
    __block NSUInteger presented_count = 0;
    __block BOOL presented_object_matches = NO;
    if (@available(macOS 10.15.4, *)) {
        if (drawable.drawableID != 0 || drawable.presentedTime != 0.0) {
            fprintf(stderr, "metal-pixel: CPU drawable initial ID/time mismatch\n");
            return 133;
        }
        [drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            presented_count += 1;
            presented_object_matches = presented == drawable;
        }];
    }
    [command_buffer presentDrawable:drawable];
    if (@available(macOS 10.15.4, *)) {
        if (presented_count != 0 || drawable.presentedTime != 0.0) {
            fprintf(stderr, "metal-pixel: CPU drawable presented before command commit\n");
            return 134;
        }
    }
    [command_buffer commit];
    [command_buffer waitUntilCompleted];
    BOOL drawable_presentation_ok = YES;
    if (@available(macOS 10.15.4, *)) {
        drawable_presentation_ok = presented_count == 1 && presented_object_matches && drawable.presentedTime > 0.0;
    }
    if (command_buffer.status != MTLCommandBufferStatusCompleted || !drawable_presentation_ok) {
        fprintf(stderr, "metal-pixel: CPU drawable command-buffer presentation failed\n");
        return 135;
    }

    id<MTLDrawable> direct_drawable = ZPUMetalCreateCPUDrawable(adapter_texture);
    if (direct_drawable == nil) {
        fprintf(stderr, "metal-pixel: second CPU drawable allocation failed\n");
        return 136;
    }
    __block NSUInteger direct_presented_count = 0;
    if (@available(macOS 10.15.4, *)) {
        [direct_drawable addPresentedHandler:^(id<MTLDrawable> presented) {
            if (presented == direct_drawable) direct_presented_count += 1;
        }];
        [direct_drawable presentAfterMinimumDuration:0.001];
        if (direct_presented_count != 1 || direct_drawable.presentedTime <= 0.0) {
            fprintf(stderr, "metal-pixel: CPU drawable direct presentation failed\n");
            return 137;
        }
    } else {
        [direct_drawable present];
    }

    /* Metal 4 drawable synchronization is also CPU-only. A valid drawable
     * is accepted by signal/wait; no native command queue is touched. */
    if (@available(macOS 26.0, *)) {
        id<MTL4CommandQueue> queue4 = [adapter_device newMTL4CommandQueue];
        if (queue4 == nil) {
            fprintf(stderr, "metal-pixel: CPU Metal 4 drawable queue creation failed\n");
            return 138;
        }
        [queue4 signalDrawable:direct_drawable];
        [queue4 waitForDrawable:direct_drawable];
    }
    return 0;
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
        id<MTLFunction> stage_in_vertex_function = [library newFunctionWithName:@"zpu_test_stage_in_vertex"];
        id<MTLFunction> no_raster_vertex_function = [library newFunctionWithName:@"zpu_test_no_raster_vertex"];
        id<MTLFunction> fragment_function = [library newFunctionWithName:@"zpu_test_fragment"];
        id<MTLFunction> depth_bounds_oracle_fragment = [library newFunctionWithName:@"zpu_test_depth_bounds_oracle"];
        id<MTLFunction> mrt_fragment_function = [library newFunctionWithName:@"zpu_test_mrt_fragment"];
        id<MTLFunction> sample_fragment_function = [library newFunctionWithName:@"zpu_test_sample_fragment"];
        if (vertex_function == nil || stage_in_vertex_function == nil || no_raster_vertex_function == nil || fragment_function == nil ||
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

        /* Identity rasterization-rate maps preserve the same top-left,
         * 1:1 physical pixel grid. Variable-rate maps are intentionally
         * rejected by the CPU adapter because silently treating them as
         * identity would change their observable rasterization semantics. */
        MTLRasterizationRateLayerDescriptor *native_identity_layer =
            [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(1, 1, 0)];
        native_identity_layer.horizontal[0] = @1.0f;
        native_identity_layer.vertical[0] = @1.0f;
        MTLRasterizationRateMapDescriptor *identity_rate_descriptor =
            [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width, height, 0)
                                                                                          layer:native_identity_layer];
        id<MTLRasterizationRateMap> native_identity_rate_map =
            [device newRasterizationRateMapWithDescriptor:identity_rate_descriptor];
        id<MTLDevice> adapter_rate_map_device = ZPUMetalCreateSystemDefaultDevice();
        id<MTLRasterizationRateMap> adapter_identity_rate_map =
            [adapter_rate_map_device newRasterizationRateMapWithDescriptor:identity_rate_descriptor];
        if (![adapter_rate_map_device supportsRasterizationRateMapWithLayerCount:1] ||
            [adapter_rate_map_device supportsRasterizationRateMapWithLayerCount:0]) {
            fprintf(stderr, "metal-pixel: CPU rasterization-rate map capability advertisement is inconsistent\n");
            return 47;
        }
        const MTLCoordinate2D identity_screen_coordinate = {2.25f, 3.75f};
        const MTLCoordinate2D identity_physical_coordinate = {4.5f, 1.5f};
        const MTLSize native_identity_physical_size = [native_identity_rate_map physicalSizeForLayer:0];
        const MTLSize adapter_identity_physical_size = [adapter_identity_rate_map physicalSizeForLayer:0];
        const MTLCoordinate2D native_identity_screen_to_physical =
            [native_identity_rate_map mapScreenToPhysicalCoordinates:identity_screen_coordinate forLayer:0];
        const MTLCoordinate2D adapter_identity_screen_to_physical =
            [adapter_identity_rate_map mapScreenToPhysicalCoordinates:identity_screen_coordinate forLayer:0];
        const MTLCoordinate2D native_identity_physical_to_screen =
            [native_identity_rate_map mapPhysicalToScreenCoordinates:identity_physical_coordinate forLayer:0];
        const MTLCoordinate2D adapter_identity_physical_to_screen =
            [adapter_identity_rate_map mapPhysicalToScreenCoordinates:identity_physical_coordinate forLayer:0];
        if (native_identity_rate_map == nil || adapter_identity_rate_map == nil ||
            native_identity_rate_map.layerCount != adapter_identity_rate_map.layerCount ||
            native_identity_rate_map.screenSize.width != adapter_identity_rate_map.screenSize.width ||
            native_identity_rate_map.screenSize.height != adapter_identity_rate_map.screenSize.height ||
            native_identity_rate_map.physicalGranularity.width != adapter_identity_rate_map.physicalGranularity.width ||
            native_identity_rate_map.physicalGranularity.height != adapter_identity_rate_map.physicalGranularity.height ||
            native_identity_physical_size.width != adapter_identity_physical_size.width ||
            native_identity_physical_size.height != adapter_identity_physical_size.height ||
            native_identity_screen_to_physical.x != adapter_identity_screen_to_physical.x ||
            native_identity_screen_to_physical.y != adapter_identity_screen_to_physical.y ||
            native_identity_physical_to_screen.x != adapter_identity_physical_to_screen.x ||
            native_identity_physical_to_screen.y != adapter_identity_physical_to_screen.y) {
            fprintf(stderr, "metal-pixel: identity rasterization-rate map mismatch nativeMap=%p adapterMap=%p layers=%zu/%zu screen=%zux%zu/%zux%zu granularity=%zux%zu/%zux%zu physical=%zux%zu/%zux%zu screenToPhysical=(%g,%g)/(%g,%g) physicalToScreen=(%g,%g)/(%g,%g)\n",
                    native_identity_rate_map, adapter_identity_rate_map,
                    native_identity_rate_map.layerCount, adapter_identity_rate_map.layerCount,
                    native_identity_rate_map.screenSize.width, native_identity_rate_map.screenSize.height,
                    adapter_identity_rate_map.screenSize.width, adapter_identity_rate_map.screenSize.height,
                    native_identity_rate_map.physicalGranularity.width, native_identity_rate_map.physicalGranularity.height,
                    adapter_identity_rate_map.physicalGranularity.width, adapter_identity_rate_map.physicalGranularity.height,
                    native_identity_physical_size.width, native_identity_physical_size.height,
                    adapter_identity_physical_size.width, adapter_identity_physical_size.height,
                    native_identity_screen_to_physical.x, native_identity_screen_to_physical.y,
                    adapter_identity_screen_to_physical.x, adapter_identity_screen_to_physical.y,
                    native_identity_physical_to_screen.x, native_identity_physical_to_screen.y,
                    adapter_identity_physical_to_screen.x, adapter_identity_physical_to_screen.y);
            return 45;
        }
        MTLRasterizationRateLayerDescriptor *variable_rate_layer =
            [[MTLRasterizationRateLayerDescriptor alloc] initWithSampleCount:MTLSizeMake(1, 1, 0)];
        variable_rate_layer.horizontal[0] = @0.5f;
        variable_rate_layer.vertical[0] = @1.0f;
        MTLRasterizationRateMapDescriptor *variable_rate_descriptor =
            [MTLRasterizationRateMapDescriptor rasterizationRateMapDescriptorWithScreenSize:MTLSizeMake(width, height, 0)
                                                                                          layer:variable_rate_layer];
        if ([adapter_rate_map_device newRasterizationRateMapWithDescriptor:variable_rate_descriptor] != nil) {
            fprintf(stderr, "metal-pixel: variable-rate map was not rejected by CPU adapter\n");
            return 46;
        }

        const int io_result = test_cpu_io_against_native(device, adapter_rate_map_device);
        if (io_result != 0) return io_result;
        const int drawable_result = test_cpu_drawable_lifecycle(device, adapter_rate_map_device);
        if (drawable_result != 0) return drawable_result;

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
        const MTLRegion sparse_pixels[] = {
            MTLRegionMake3D(1, 2, 1, 7, 5, 3),
            MTLRegionMake3D(8, 7, 0, 4, 2, 2),
        };
        const MTLSize sparse_tile_size = MTLSizeMake(4, 3, 2);
        MTLRegion adapter_sparse_outward[2];
        MTLRegion adapter_sparse_inward[2];
        MTLRegion adapter_sparse_roundtrip[2];
        [adapter_device convertSparsePixelRegions:sparse_pixels
                                     toTileRegions:adapter_sparse_outward
                                      withTileSize:sparse_tile_size
                                     alignmentMode:MTLSparseTextureRegionAlignmentModeOutward
                                        numRegions:2];
        [adapter_device convertSparsePixelRegions:sparse_pixels
                                     toTileRegions:adapter_sparse_inward
                                      withTileSize:sparse_tile_size
                                     alignmentMode:MTLSparseTextureRegionAlignmentModeInward
                                        numRegions:2];
        [adapter_device convertSparseTileRegions:adapter_sparse_outward
                                     toPixelRegions:adapter_sparse_roundtrip
                                      withTileSize:sparse_tile_size
                                        numRegions:2];
        const MTLRegion expected_sparse_outward[] = {
            MTLRegionMake3D(0, 0, 0, 2, 3, 2),
            MTLRegionMake3D(2, 2, 0, 1, 1, 1),
        };
        const MTLRegion expected_sparse_inward[] = {
            MTLRegionMake3D(1, 1, 1, 1, 1, 1),
            MTLRegionMake3D(2, 3, 0, 1, 0, 1),
        };
        const MTLRegion expected_sparse_roundtrip[] = {
            MTLRegionMake3D(0, 0, 0, 8, 9, 4),
            MTLRegionMake3D(8, 6, 0, 4, 3, 2),
        };
        const BOOL sparse_geometry_ok =
            memcmp(adapter_sparse_outward, expected_sparse_outward, sizeof(expected_sparse_outward)) == 0 &&
            memcmp(adapter_sparse_inward, expected_sparse_inward, sizeof(expected_sparse_inward)) == 0 &&
            memcmp(adapter_sparse_roundtrip, expected_sparse_roundtrip, sizeof(expected_sparse_roundtrip)) == 0;
        MTLSize native_sparse_tile_size =
            [device sparseTileSizeWithTextureType:MTLTextureType2D
                                       pixelFormat:MTLPixelFormatRGBA8Unorm
                                       sampleCount:1];
        BOOL native_sparse_geometry_ok = YES;
        if (native_sparse_tile_size.width != 0 && native_sparse_tile_size.height != 0 &&
            native_sparse_tile_size.depth != 0) {
            MTLRegion native_sparse_outward[2];
            MTLRegion adapter_native_sparse_outward[2];
            [device convertSparsePixelRegions:sparse_pixels
                                 toTileRegions:native_sparse_outward
                                  withTileSize:native_sparse_tile_size
                                 alignmentMode:MTLSparseTextureRegionAlignmentModeOutward
                                    numRegions:2];
            [adapter_device convertSparsePixelRegions:sparse_pixels
                                         toTileRegions:adapter_native_sparse_outward
                                          withTileSize:native_sparse_tile_size
                                         alignmentMode:MTLSparseTextureRegionAlignmentModeOutward
                                            numRegions:2];
            native_sparse_geometry_ok = memcmp(native_sparse_outward, adapter_native_sparse_outward,
                                               sizeof(native_sparse_outward)) == 0;
        }
        if (!sparse_geometry_ok || !native_sparse_geometry_ok) {
            fprintf(stderr, "metal-pixel: sparse region conversion mismatch\n");
            return 18;
        }
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

        /* CPU-owned resources cannot be discarded to satisfy a purge request.
         * Match Metal's observable previous-state result instead of claiming
         * that live ZPU storage became volatile or empty. */
        const MTLPurgeableState native_buffer_purge_state =
            [vertex_buffer setPurgeableState:MTLPurgeableStateVolatile];
        const MTLPurgeableState adapter_buffer_purge_state =
            [adapter_vertex_buffer setPurgeableState:MTLPurgeableStateVolatile];
        const MTLPurgeableState native_texture_purge_state =
            [texture setPurgeableState:MTLPurgeableStateEmpty];
        const MTLPurgeableState adapter_texture_purge_state =
            [adapter_texture setPurgeableState:MTLPurgeableStateEmpty];
        if (native_buffer_purge_state != adapter_buffer_purge_state ||
            native_texture_purge_state != adapter_texture_purge_state ||
            adapter_buffer_purge_state != MTLPurgeableStateNonVolatile ||
            adapter_texture_purge_state != MTLPurgeableStateNonVolatile) {
            fprintf(stderr, "metal-pixel: purgeability state mismatch\n");
            return 20;
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
        id<MTLFunction> adapter_stage_in_vertex_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_stage_in_vertex");
        id<MTLFunction> adapter_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_fragment");
        id<MTLFunction> adapter_uniform_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_cpu_uniform_color_fragment");
        id<MTLFunction> adapter_sample_fragment_function =
            ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_sample_fragment");
        id<MTLCommandQueue> adapter_queue = [adapter_device newCommandQueue];
        NSError *adapter_pipeline_error = nil;

        const int mip_nearest_result = test_mip_sampler_against_native(
            device, adapter_device, vertex_function, sample_fragment_function,
            adapter_vertex_function, adapter_sample_fragment_function,
            MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest,
            MTLSamplerMipFilterNearest, MTLSamplerReductionModeWeightedAverage,
            0.0f, 0.0f, FLT_MAX, YES, 1, 1.0f);
        if (mip_nearest_result != 0) return mip_nearest_result;
        const int mip_linear_result = test_mip_sampler_against_native(
            device, adapter_device, vertex_function, sample_fragment_function,
            adapter_vertex_function, adapter_sample_fragment_function,
            MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest,
            MTLSamplerMipFilterLinear, MTLSamplerReductionModeWeightedAverage,
            0.0f, 1.5f, 1.5f, YES, 1, 1.0f);
        if (mip_linear_result != 0) return mip_linear_result;
        const int unnormalized_sampler_result = test_mip_sampler_against_native(
            device, adapter_device, vertex_function, sample_fragment_function,
            adapter_vertex_function, adapter_sample_fragment_function,
            MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest,
            MTLSamplerMipFilterNotMipmapped, MTLSamplerReductionModeWeightedAverage,
            0.0f, 0.0f, 0.0f, NO, 1, 1.0f);
        if (unnormalized_sampler_result != 0) return unnormalized_sampler_result;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            const int lod_bias_result = test_mip_sampler_against_native(
                device, adapter_device, vertex_function, sample_fragment_function,
                adapter_vertex_function, adapter_sample_fragment_function,
                MTLSamplerMinMagFilterNearest, MTLSamplerMinMagFilterNearest,
                MTLSamplerMipFilterNearest, MTLSamplerReductionModeWeightedAverage,
                1.0f, 0.0f, FLT_MAX, YES, 1, 1.0f);
            if (lod_bias_result != 0) return lod_bias_result;
        }
        if (@available(macOS 26.0, iOS 26.0, *)) {
            /* The reductionMode property is present in the SDK on all 26.x
             * systems, but native execution is only defined on Apple10 and
             * later. Older devices, including this M4 host (Apple9), accept
             * the property and silently use weighted averaging. The adapter
             * remains a CPU implementation, so keep its reduction unit tests
             * independent of this native capability gate. */
            if ([device supportsFamily:MTLGPUFamilyApple10]) {
                const int reduction_min_result = test_mip_sampler_against_native(
                    device, adapter_device, vertex_function, sample_fragment_function,
                    adapter_vertex_function, adapter_sample_fragment_function,
                    MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear,
                    MTLSamplerMipFilterLinear, MTLSamplerReductionModeMinimum,
                    0.0f, 0.0f, 0.0f, YES, 1, 1.0f);
                if (reduction_min_result != 0) return reduction_min_result;
                const int reduction_max_result = test_mip_sampler_against_native(
                    device, adapter_device, vertex_function, sample_fragment_function,
                    adapter_vertex_function, adapter_sample_fragment_function,
                    MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear,
                    MTLSamplerMipFilterLinear, MTLSamplerReductionModeMaximum,
                    0.0f, 0.0f, 0.0f, YES, 1, 1.0f);
                if (reduction_max_result != 0) return reduction_max_result;
            }
        }
        const int anisotropy_result = test_mip_sampler_against_native(
            device, adapter_device, vertex_function, sample_fragment_function,
            adapter_vertex_function, adapter_sample_fragment_function,
            MTLSamplerMinMagFilterLinear, MTLSamplerMinMagFilterLinear,
            MTLSamplerMipFilterNotMipmapped, MTLSamplerReductionModeWeightedAverage,
            0.0f, 0.0f, 0.0f, YES, 2, 0.0625f);
        if (anisotropy_result != 0) return anisotropy_result;
        MTLSamplerDescriptor *anisotropy_descriptor = [MTLSamplerDescriptor new];
        anisotropy_descriptor.maxAnisotropy = 2;
        id<MTLSamplerState> adapter_anisotropic_sampler =
            [adapter_device newSamplerStateWithDescriptor:anisotropy_descriptor];
        MTLSamplerDescriptor *invalid_anisotropy_descriptor = [anisotropy_descriptor copy];
        invalid_anisotropy_descriptor.normalizedCoordinates = NO;
        id<MTLSamplerState> adapter_invalid_anisotropic_sampler =
            [adapter_device newSamplerStateWithDescriptor:invalid_anisotropy_descriptor];
        if (adapter_anisotropic_sampler == nil || adapter_invalid_anisotropic_sampler != nil) {
            fprintf(stderr, "metal-pixel: CPU sampler anisotropy validation mismatch\n");
            return 152;
        }

        if (adapter_stage_in_vertex_function == nil ||
            ZPUMetalCreateCPUFunction(adapter_device, @"arbitrary_unregistered_vertex") != nil) {
            fprintf(stderr, "metal-pixel: CPU function factory accepted an unregistered profile\n");
            return 146;
        }

        if (@available(macOS 14.0, iOS 17.0, *)) {
            const int vertex_stride_result = test_vertex_attribute_stride_against_native(
                device, adapter_device, stage_in_vertex_function, fragment_function,
                adapter_stage_in_vertex_function, adapter_fragment_function);
            if (vertex_stride_result != 0) return vertex_stride_result;
        }

        /* Log-state registration is metadata-only for the CPU adapter: no
         * shader can execute an Apple GPU log instruction here, but callers
         * still receive a real CPU-owned MTLLogState with native descriptor
         * validation and handler lifetime semantics. */
        if (@available(macOS 15.0, iOS 18.0, *)) {
            MTLLogStateDescriptor *log_descriptor = [MTLLogStateDescriptor new];
            log_descriptor.level = MTLLogLevelInfo;
            log_descriptor.bufferSize = 1024;
            NSError *log_error = nil;
            id<MTLLogState> log_state = [adapter_device newLogStateWithDescriptor:log_descriptor error:&log_error];
            [log_state addLogHandler:^(NSString *subSystem, NSString *category, MTLLogLevel logLevel, NSString *message) {
                (void)subSystem;
                (void)category;
                (void)logLevel;
                (void)message;
            }];
            MTLLogStateDescriptor *invalid_log_descriptor = [MTLLogStateDescriptor new];
            invalid_log_descriptor.level = MTLLogLevelInfo;
            invalid_log_descriptor.bufferSize = 1023;
            NSError *invalid_log_error = nil;
            id<MTLLogState> invalid_log_state =
                [adapter_device newLogStateWithDescriptor:invalid_log_descriptor error:&invalid_log_error];
            if (log_state == nil || log_error != nil ||
                ![log_state conformsToProtocol:@protocol(MTLLogState)] || invalid_log_state != nil ||
                invalid_log_error == nil) {
                fail_with_error("CPU Metal log-state implementation failed", log_error ?: invalid_log_error);
                return 107;
            }
        }

        /* MTLTensor resources are CPU-owned too. Exercise both the directly
         * allocated form and a strided buffer view; the optional native block
         * is only an oracle probe and is allowed to be unavailable on a host
         * whose Metal runtime exposes the SDK declarations without tensor
         * execution support. */
        if (@available(macOS 26.0, iOS 26.0, *)) {
            const NSInteger tensor_dimension_values[] = {3, 2};
            const NSInteger tensor_packed_stride_values[] = {1, 3};
            const NSInteger tensor_buffer_stride_values[] = {1, 4};
            MTLTensorExtents *tensor_dimensions =
                [[MTLTensorExtents alloc] initWithRank:2 values:tensor_dimension_values];
            MTLTensorExtents *tensor_packed_strides =
                [[MTLTensorExtents alloc] initWithRank:2 values:tensor_packed_stride_values];
            MTLTensorExtents *tensor_buffer_strides =
                [[MTLTensorExtents alloc] initWithRank:2 values:tensor_buffer_stride_values];
            MTLTensorDescriptor *tensor_descriptor = [MTLTensorDescriptor new];
            tensor_descriptor.dimensions = tensor_dimensions;
            tensor_descriptor.dataType = MTLTensorDataTypeUInt8;
            tensor_descriptor.usage = MTLTensorUsageCompute | MTLTensorUsageRender;
            tensor_descriptor.resourceOptions = MTLResourceStorageModeShared;
            tensor_descriptor.storageMode = MTLStorageModeShared;
            MTLSizeAndAlign adapter_tensor_size_align =
                [adapter_device tensorSizeAndAlignWithDescriptor:tensor_descriptor];
            id<MTLTensor> adapter_tensor =
                [adapter_device newTensorWithDescriptor:tensor_descriptor error:&adapter_pipeline_error];
            const uint8_t tensor_initial_values[] = {10, 11, 12, 20, 21, 22};
            uint8_t adapter_tensor_values[sizeof(tensor_initial_values)] = {0};
            if (adapter_tensor == nil || adapter_tensor_size_align.size != sizeof(tensor_initial_values) ||
                adapter_tensor_size_align.align == 0 || adapter_tensor.buffer != nil ||
                adapter_tensor.bufferOffset != 0 || adapter_tensor.strides != nil ||
                adapter_tensor.dimensions.rank != 2 ||
                [adapter_tensor.dimensions extentAtDimensionIndex:0] != 3 ||
                [adapter_tensor.dimensions extentAtDimensionIndex:1] != 2 ||
                adapter_tensor.dataType != MTLTensorDataTypeUInt8 ||
                adapter_tensor.usage != tensor_descriptor.usage) {
                fail_with_error("CPU tensor metadata allocation failed", adapter_pipeline_error);
                return 105;
            }
            [adapter_tensor replaceSliceOrigin:
                                  [[MTLTensorExtents alloc] initWithRank:2 values:(const NSInteger[]){0, 0}]
                             sliceDimensions:tensor_dimensions
                                   withBytes:tensor_initial_values
                                     strides:tensor_packed_strides];
            [adapter_tensor getBytes:adapter_tensor_values
                             strides:tensor_packed_strides
                    fromSliceOrigin:[[MTLTensorExtents alloc] initWithRank:2 values:(const NSInteger[]){0, 0}]
                     sliceDimensions:tensor_dimensions];
            if (memcmp(adapter_tensor_values, tensor_initial_values, sizeof(tensor_initial_values)) != 0) {
                fprintf(stderr, "metal-pixel: standalone tensor strided transfer mismatch\n");
                return 106;
            }

            if (@available(macOS 26.4, iOS 26.4, *)) {
                MTLTensorDescriptor *unsupported_tensor_descriptor = [tensor_descriptor copy];
                unsupported_tensor_descriptor.dataType = MTLTensorDataTypeInt4;
                NSError *unsupported_tensor_error = nil;
                id<MTLTensor> unsupported_tensor =
                    [adapter_device newTensorWithDescriptor:unsupported_tensor_descriptor
                                                       error:&unsupported_tensor_error];
                if (unsupported_tensor != nil || unsupported_tensor_error == nil) {
                    fail_with_error("unsupported sub-byte tensor was not rejected", unsupported_tensor_error);
                    return 111;
                }
            }

            BOOL native_tensor_oracle_ok = NO;
            id<MTLTensor> native_tensor = nil;
            @try {
                native_tensor = [device newTensorWithDescriptor:tensor_descriptor error:&error];
                if (native_tensor != nil) {
                    uint8_t native_tensor_values[sizeof(tensor_initial_values)] = {0};
                    [native_tensor replaceSliceOrigin:
                                      [[MTLTensorExtents alloc] initWithRank:2 values:(const NSInteger[]){0, 0}]
                                 sliceDimensions:tensor_dimensions
                                       withBytes:tensor_initial_values
                                         strides:tensor_packed_strides];
                    [native_tensor getBytes:native_tensor_values
                                     strides:tensor_packed_strides
                            fromSliceOrigin:[[MTLTensorExtents alloc] initWithRank:2 values:(const NSInteger[]){0, 0}]
                             sliceDimensions:tensor_dimensions];
                    native_tensor_oracle_ok = memcmp(native_tensor_values, adapter_tensor_values,
                                                     sizeof(native_tensor_values)) == 0;
                }
            } @catch (NSException *exception) {
                (void)exception;
                native_tensor_oracle_ok = NO;
            }
            if (native_tensor != nil && !native_tensor_oracle_ok) {
                fprintf(stderr, "metal-pixel: native tensor transfer oracle mismatch\n");
                return 107;
            }

            MTLTensorDescriptor *tensor_buffer_descriptor = [tensor_descriptor copy];
            tensor_buffer_descriptor.strides = tensor_buffer_strides;
            id<MTLBuffer> adapter_tensor_source_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> adapter_tensor_destination_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLTensor> adapter_source_tensor =
                [adapter_tensor_source_buffer newTensorWithDescriptor:tensor_buffer_descriptor
                                                                  offset:1 error:&adapter_pipeline_error];
            id<MTLTensor> adapter_destination_tensor =
                [adapter_tensor_destination_buffer newTensorWithDescriptor:tensor_buffer_descriptor
                                                                       offset:2 error:&adapter_pipeline_error];
            const NSInteger tensor_zero_values[] = {0, 0};
            MTLTensorExtents *tensor_zero =
                [[MTLTensorExtents alloc] initWithRank:2 values:tensor_zero_values];
            const uint8_t tensor_committed_values[] = {30, 31, 32, 40, 41, 42};
            uint8_t adapter_tensor_copy_values[sizeof(tensor_committed_values)] = {0};
            id<MTLCommandBuffer> adapter_tensor_command_buffer = [adapter_queue commandBuffer];
            id<MTLBlitCommandEncoder> adapter_tensor_blit_encoder =
                [adapter_tensor_command_buffer blitCommandEncoder];
            if (adapter_source_tensor == nil || adapter_destination_tensor == nil ||
                adapter_source_tensor.buffer != adapter_tensor_source_buffer ||
                adapter_destination_tensor.buffer != adapter_tensor_destination_buffer ||
                adapter_source_tensor.bufferOffset != 1 || adapter_destination_tensor.bufferOffset != 2 ||
                [adapter_source_tensor.strides extentAtDimensionIndex:0] != 1 ||
                [adapter_source_tensor.strides extentAtDimensionIndex:1] != 4 ||
                adapter_tensor_blit_encoder == nil) {
                fail_with_error("buffer-backed CPU tensor allocation failed", adapter_pipeline_error);
                return 108;
            }
            [adapter_source_tensor replaceSliceOrigin:tensor_zero
                                       sliceDimensions:tensor_dimensions
                                             withBytes:tensor_initial_values
                                               strides:tensor_packed_strides];
            [adapter_tensor_blit_encoder copyFromTensor:adapter_source_tensor
                                           sourceOrigin:tensor_zero
                                       sourceDimensions:tensor_dimensions
                                               toTensor:adapter_destination_tensor
                                      destinationOrigin:tensor_zero
                                  destinationDimensions:tensor_dimensions];
            [adapter_tensor_blit_encoder endEncoding];
            /* This mutation occurs after encoding and therefore proves the
             * tensor copy is deferred with the surrounding ZPU command. */
            [adapter_source_tensor replaceSliceOrigin:tensor_zero
                                       sliceDimensions:tensor_dimensions
                                             withBytes:tensor_committed_values
                                               strides:tensor_packed_strides];
            [adapter_tensor_command_buffer commit];
            [adapter_tensor_command_buffer waitUntilCompleted];
            [adapter_destination_tensor getBytes:adapter_tensor_copy_values
                                         strides:tensor_packed_strides
                                fromSliceOrigin:tensor_zero
                                 sliceDimensions:tensor_dimensions];
            if (adapter_tensor_command_buffer.status != MTLCommandBufferStatusCompleted ||
                memcmp(adapter_tensor_copy_values, tensor_committed_values,
                       sizeof(tensor_committed_values)) != 0) {
                fail_with_error("deferred CPU tensor copy failed", adapter_pipeline_error);
                return 109;
            }

            BOOL native_tensor_copy_oracle_ok = NO;
            id<MTLTensor> native_source_tensor = nil;
            id<MTLTensor> native_destination_tensor = nil;
            @try {
                id<MTLBuffer> native_tensor_source_buffer =
                    [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
                id<MTLBuffer> native_tensor_destination_buffer =
                    [device newBufferWithLength:16 options:MTLResourceStorageModeShared];
                native_source_tensor =
                    [native_tensor_source_buffer newTensorWithDescriptor:tensor_buffer_descriptor
                                                                     offset:1 error:&error];
                native_destination_tensor =
                    [native_tensor_destination_buffer newTensorWithDescriptor:tensor_buffer_descriptor
                                                                          offset:2 error:&error];
                if (native_source_tensor != nil && native_destination_tensor != nil) {
                    [native_source_tensor replaceSliceOrigin:tensor_zero
                                               sliceDimensions:tensor_dimensions
                                                     withBytes:tensor_initial_values
                                                       strides:tensor_packed_strides];
                    id<MTLCommandBuffer> native_tensor_command_buffer = [queue commandBuffer];
                    id<MTLBlitCommandEncoder> native_tensor_blit_encoder =
                        [native_tensor_command_buffer blitCommandEncoder];
                    [native_tensor_blit_encoder copyFromTensor:native_source_tensor
                                                   sourceOrigin:tensor_zero
                                               sourceDimensions:tensor_dimensions
                                                       toTensor:native_destination_tensor
                                              destinationOrigin:tensor_zero
                                          destinationDimensions:tensor_dimensions];
                    [native_tensor_blit_encoder endEncoding];
                    [native_source_tensor replaceSliceOrigin:tensor_zero
                                               sliceDimensions:tensor_dimensions
                                                     withBytes:tensor_committed_values
                                                       strides:tensor_packed_strides];
                    [native_tensor_command_buffer commit];
                    [native_tensor_command_buffer waitUntilCompleted];
                    uint8_t native_tensor_copy_values[sizeof(tensor_committed_values)] = {0};
                    [native_destination_tensor getBytes:native_tensor_copy_values
                                                 strides:tensor_packed_strides
                                        fromSliceOrigin:tensor_zero
                                         sliceDimensions:tensor_dimensions];
                    native_tensor_copy_oracle_ok =
                        native_tensor_command_buffer.status == MTLCommandBufferStatusCompleted &&
                        memcmp(native_tensor_copy_values, adapter_tensor_copy_values,
                               sizeof(native_tensor_copy_values)) == 0;
                }
            } @catch (NSException *exception) {
                (void)exception;
                native_tensor_copy_oracle_ok = NO;
            }
            if (native_source_tensor != nil && native_destination_tensor != nil &&
                !native_tensor_copy_oracle_ok) {
                fprintf(stderr, "metal-pixel: native tensor copy oracle mismatch\n");
                return 110;
            }
        }

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

        /* Border color is part of Metal's sampler state, not an implicit
         * transparent-black fallback. Use a full-screen pair of triangles
         * with an out-of-range normalized coordinate so the native result is
         * a compact oracle for the CPU raster sampler. */
        MTLSamplerDescriptor *native_border_sampler_descriptor = [sample_sampler_descriptor copy];
        native_border_sampler_descriptor.sAddressMode = MTLSamplerAddressModeClampToBorderColor;
        native_border_sampler_descriptor.tAddressMode = MTLSamplerAddressModeClampToBorderColor;
        native_border_sampler_descriptor.borderColor = MTLSamplerBorderColorOpaqueWhite;
        MTLSamplerDescriptor *adapter_border_sampler_descriptor = [native_border_sampler_descriptor copy];
        id<MTLSamplerState> native_border_sampler =
            [device newSamplerStateWithDescriptor:native_border_sampler_descriptor];
        id<MTLSamplerState> adapter_border_sampler =
            [adapter_device newSamplerStateWithDescriptor:adapter_border_sampler_descriptor];
        const zpu_metal_vertex border_vertices[] = {
            {{-1.0f, -1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{ 1.0f, -1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{-1.0f, -1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{ 1.0f,  1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
            {{-1.0f,  1.0f, 0.5f, 1.0f}, {-0.25f, -0.25f, 0.0f, 1.0f}},
        };
        id<MTLBuffer> native_border_vertex_buffer =
            [device newBufferWithBytes:border_vertices length:sizeof(border_vertices)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_border_vertex_buffer =
            [adapter_device newBufferWithBytes:border_vertices length:sizeof(border_vertices)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> native_border_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_border_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        MTLRenderPassDescriptor *native_border_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_border_pass.colorAttachments[0].texture = native_border_output;
        native_border_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_border_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_border_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_border_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_border_encoder =
            [native_border_command_buffer renderCommandEncoderWithDescriptor:native_border_pass];
        [native_border_encoder setRenderPipelineState:native_sample_pipeline];
        [native_border_encoder setVertexBuffer:native_border_vertex_buffer offset:0 atIndex:0];
        [native_border_encoder setFragmentTexture:native_sample_source atIndex:0];
        [native_border_encoder setFragmentSamplerState:native_border_sampler atIndex:0];
        [native_border_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_border_encoder endEncoding];
        [native_border_command_buffer commit];
        [native_border_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_border_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_border_pass.colorAttachments[0].texture = adapter_border_output;
        adapter_border_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_border_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_border_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_border_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_border_encoder =
            [adapter_border_command_buffer renderCommandEncoderWithDescriptor:adapter_border_pass];
        [adapter_border_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_border_encoder setVertexBuffer:adapter_border_vertex_buffer offset:0 atIndex:0];
        [adapter_border_encoder setFragmentTexture:adapter_sample_source atIndex:0];
        [adapter_border_encoder setFragmentSamplerState:adapter_border_sampler atIndex:0];
        [adapter_border_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_border_encoder endEncoding];
        [adapter_border_command_buffer commit];
        [adapter_border_command_buffer waitUntilCompleted];
        uint8_t native_border_bytes[byte_count];
        uint8_t adapter_border_bytes[byte_count];
        [native_border_output getBytes:native_border_bytes bytesPerRow:(NSUInteger)width * 4
                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_border_output getBytes:adapter_border_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_border_sampler == nil || adapter_border_sampler == nil ||
            native_border_vertex_buffer == nil || adapter_border_vertex_buffer == nil ||
            native_border_output == nil || adapter_border_output == nil ||
            native_border_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_border_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_border_bytes, adapter_border_bytes, byte_count) != 0 ||
            memcmp(adapter_border_bytes + (4 * width + 4) * 4, (const uint8_t[]){255, 255, 255, 255}, 4) != 0) {
            size_t border_mismatch = 0;
            while (border_mismatch < byte_count && native_border_bytes[border_mismatch] == adapter_border_bytes[border_mismatch]) {
                border_mismatch += 1;
            }
            fprintf(stderr, "metal-pixel: border statuses=%lu/%lu center=%u,%u,%u,%u vs %u,%u,%u,%u mismatch=%zu nativeByte=%u adapterByte=%u\n",
                    (unsigned long)native_border_command_buffer.status,
                    (unsigned long)adapter_border_command_buffer.status,
                    native_border_bytes[(4 * width + 4) * 4], native_border_bytes[(4 * width + 4) * 4 + 1],
                    native_border_bytes[(4 * width + 4) * 4 + 2], native_border_bytes[(4 * width + 4) * 4 + 3],
                    adapter_border_bytes[(4 * width + 4) * 4], adapter_border_bytes[(4 * width + 4) * 4 + 1],
                    adapter_border_bytes[(4 * width + 4) * 4 + 2], adapter_border_bytes[(4 * width + 4) * 4 + 3],
                    border_mismatch,
                    border_mismatch < byte_count ? native_border_bytes[border_mismatch] : 0,
                    border_mismatch < byte_count ? adapter_border_bytes[border_mismatch] : 0);
            fail_with_error("sampler border-color CPU/native oracle mismatch", adapter_pipeline_error);
            return 137;
        }

        id<MTLCommandBuffer> invalid_fragment_sampler_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> invalid_fragment_sampler_encoder =
            [invalid_fragment_sampler_command_buffer renderCommandEncoderWithDescriptor:adapter_sample_pass];
        [invalid_fragment_sampler_encoder setRenderPipelineState:adapter_sample_pipeline];
        [invalid_fragment_sampler_encoder setVertexBuffer:adapter_sample_vertex_buffer offset:0 atIndex:0];
        [invalid_fragment_sampler_encoder setFragmentTexture:adapter_sample_source atIndex:0];
        [invalid_fragment_sampler_encoder setFragmentSamplerState:adapter_sample_sampler atIndex:1];
        [invalid_fragment_sampler_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [invalid_fragment_sampler_encoder endEncoding];
        [invalid_fragment_sampler_command_buffer commit];
        [invalid_fragment_sampler_command_buffer waitUntilCompleted];
        if (invalid_fragment_sampler_encoder == nil ||
            invalid_fragment_sampler_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: unrepresentable fragment sampler index did not fail closed\n");
            return 134;
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

        /* Metal chooses minification and magnification filters from the
         * fragment footprint when mipmapping is disabled. A 16x16 source
         * projected over the four-pixel square forces minification, so this
         * catches adapters that silently preserve only magFilter. */
        uint8_t minmag_source_bytes[16 * 16 * 4];
        for (NSUInteger y = 0; y < 16; ++y) {
            for (NSUInteger x = 0; x < 16; ++x) {
                const BOOL checker = ((x ^ y) & 1) != 0;
                const NSUInteger offset = (y * 16 + x) * 4;
                minmag_source_bytes[offset + 0] = checker ? 255 : 0;
                minmag_source_bytes[offset + 1] = 0;
                minmag_source_bytes[offset + 2] = checker ? 0 : 255;
                minmag_source_bytes[offset + 3] = 255;
            }
        }
        MTLTextureDescriptor *minmag_source_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:16 height:16 mipmapped:NO];
        minmag_source_descriptor.storageMode = MTLStorageModeShared;
        minmag_source_descriptor.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> native_minmag_source = [device newTextureWithDescriptor:minmag_source_descriptor];
        id<MTLTexture> adapter_minmag_source = [adapter_device newTextureWithDescriptor:minmag_source_descriptor];
        [native_minmag_source replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0
                                  withBytes:minmag_source_bytes bytesPerRow:16 * 4];
        [adapter_minmag_source replaceRegion:MTLRegionMake2D(0, 0, 16, 16) mipmapLevel:0
                                    withBytes:minmag_source_bytes bytesPerRow:16 * 4];
        MTLSamplerDescriptor *minmag_sampler_descriptor = [sample_sampler_descriptor copy];
        minmag_sampler_descriptor.minFilter = MTLSamplerMinMagFilterLinear;
        minmag_sampler_descriptor.magFilter = MTLSamplerMinMagFilterNearest;
        id<MTLSamplerState> native_minmag_sampler =
            [device newSamplerStateWithDescriptor:minmag_sampler_descriptor];
        id<MTLSamplerState> adapter_minmag_sampler =
            [adapter_device newSamplerStateWithDescriptor:minmag_sampler_descriptor];
        id<MTLTexture> native_minmag_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_minmag_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        if (native_minmag_source == nil || adapter_minmag_source == nil ||
            native_minmag_sampler == nil || adapter_minmag_sampler == nil ||
            native_minmag_output == nil || adapter_minmag_output == nil) {
            fprintf(stderr, "metal-pixel: min/mag sampler resource allocation failed\n");
            return 104;
        }
        MTLRenderPassDescriptor *native_minmag_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_minmag_pass.colorAttachments[0].texture = native_minmag_output;
        native_minmag_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_minmag_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_minmag_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_minmag_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_minmag_encoder =
            [native_minmag_command_buffer renderCommandEncoderWithDescriptor:native_minmag_pass];
        [native_minmag_encoder setRenderPipelineState:native_sample_pipeline];
        [native_minmag_encoder setVertexBuffer:native_linear_vertex_buffer offset:0 atIndex:0];
        [native_minmag_encoder setFragmentTexture:native_minmag_source atIndex:0];
        [native_minmag_encoder setFragmentSamplerState:native_minmag_sampler atIndex:0];
        [native_minmag_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_minmag_encoder endEncoding];
        [native_minmag_command_buffer commit];
        [native_minmag_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_minmag_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_minmag_pass.colorAttachments[0].texture = adapter_minmag_output;
        adapter_minmag_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_minmag_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_minmag_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_minmag_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_minmag_encoder =
            [adapter_minmag_command_buffer renderCommandEncoderWithDescriptor:adapter_minmag_pass];
        [adapter_minmag_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_minmag_encoder setVertexBuffer:adapter_linear_vertex_buffer offset:0 atIndex:0];
        [adapter_minmag_encoder setFragmentTexture:adapter_minmag_source atIndex:0];
        [adapter_minmag_encoder setFragmentSamplerState:adapter_minmag_sampler atIndex:0];
        [adapter_minmag_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_minmag_encoder endEncoding];
        [adapter_minmag_command_buffer commit];
        [adapter_minmag_command_buffer waitUntilCompleted];
        uint8_t native_minmag_bytes[byte_count];
        uint8_t adapter_minmag_bytes[byte_count];
        [native_minmag_output getBytes:native_minmag_bytes bytesPerRow:(NSUInteger)width * 4
                              fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_minmag_output getBytes:adapter_minmag_bytes bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_minmag_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_minmag_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_minmag_bytes, adapter_minmag_bytes, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_minmag_bytes[mismatch] == adapter_minmag_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: min/mag sampler mismatch at byte %zu: Metal=%u ZPU=%u\n",
                    mismatch, mismatch < byte_count ? native_minmag_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_minmag_bytes[mismatch] : 0);
            return 105;
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

        /* A compatible pixel-format view must reinterpret the shared texels
         * while preserving their raw bytes. This exercises the CPU view
         * handles rather than merely copying the parent's metadata. */
        id<MTLTexture> native_bgra_view =
            [native_sample_source newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
        id<MTLTexture> adapter_bgra_view =
            [adapter_sample_source newTextureViewWithPixelFormat:MTLPixelFormatBGRA8Unorm];
        enum { format_view_width = 2, format_view_height = 2,
               format_view_byte_count = format_view_width * format_view_height * 4 };
        uint8_t native_bgra_view_raw_bytes[format_view_byte_count];
        uint8_t adapter_bgra_view_raw_bytes[format_view_byte_count];
        if (native_bgra_view == nil || adapter_bgra_view == nil ||
            native_bgra_view.pixelFormat != MTLPixelFormatBGRA8Unorm ||
            adapter_bgra_view.pixelFormat != MTLPixelFormatBGRA8Unorm ||
            adapter_bgra_view.parentTexture != adapter_sample_source) {
            fprintf(stderr, "metal-pixel: compatible pixel-format view creation failed\n");
            return 106;
        }
        [native_bgra_view getBytes:native_bgra_view_raw_bytes bytesPerRow:format_view_width * 4
                        fromRegion:MTLRegionMake2D(0, 0, format_view_width, format_view_height) mipmapLevel:0];
        [adapter_bgra_view getBytes:adapter_bgra_view_raw_bytes bytesPerRow:format_view_width * 4
                          fromRegion:MTLRegionMake2D(0, 0, format_view_width, format_view_height) mipmapLevel:0];
        if (memcmp(native_bgra_view_raw_bytes, adapter_bgra_view_raw_bytes, format_view_byte_count) != 0) {
            fprintf(stderr, "metal-pixel: compatible pixel-format view bytes changed\n");
            return 107;
        }
        id<MTLTexture> native_format_view_output = [device newTextureWithDescriptor:sample_output_descriptor];
        id<MTLTexture> adapter_format_view_output = [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        if (native_format_view_output == nil || adapter_format_view_output == nil) {
            fprintf(stderr, "metal-pixel: compatible pixel-format view output allocation failed\n");
            return 108;
        }
        MTLRenderPassDescriptor *native_format_view_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_format_view_pass.colorAttachments[0].texture = native_format_view_output;
        native_format_view_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_format_view_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_format_view_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> native_format_view_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_format_view_encoder =
            [native_format_view_command_buffer renderCommandEncoderWithDescriptor:native_format_view_pass];
        [native_format_view_encoder setRenderPipelineState:native_sample_pipeline];
        [native_format_view_encoder setVertexBuffer:native_sample_vertex_buffer offset:0 atIndex:0];
        [native_format_view_encoder setFragmentTexture:native_bgra_view atIndex:0];
        [native_format_view_encoder setFragmentSamplerState:native_sample_sampler atIndex:0];
        [native_format_view_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_format_view_encoder endEncoding];
        [native_format_view_command_buffer commit];
        [native_format_view_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_format_view_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_format_view_pass.colorAttachments[0].texture = adapter_format_view_output;
        adapter_format_view_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_format_view_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_format_view_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_format_view_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_format_view_encoder =
            [adapter_format_view_command_buffer renderCommandEncoderWithDescriptor:adapter_format_view_pass];
        [adapter_format_view_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_format_view_encoder setVertexBuffer:adapter_sample_vertex_buffer offset:0 atIndex:0];
        [adapter_format_view_encoder setFragmentTexture:adapter_bgra_view atIndex:0];
        [adapter_format_view_encoder setFragmentSamplerState:adapter_sample_sampler atIndex:0];
        [adapter_format_view_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_format_view_encoder endEncoding];
        [adapter_format_view_command_buffer commit];
        [adapter_format_view_command_buffer waitUntilCompleted];
        uint8_t native_format_view_bytes[byte_count];
        uint8_t adapter_format_view_bytes[byte_count];
        [native_format_view_output getBytes:native_format_view_bytes bytesPerRow:(NSUInteger)width * 4
                                 fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        [adapter_format_view_output getBytes:adapter_format_view_bytes bytesPerRow:(NSUInteger)width * 4
                                   fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
        if (native_format_view_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_format_view_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_format_view_bytes, adapter_format_view_bytes, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_format_view_bytes[mismatch] == adapter_format_view_bytes[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: compatible pixel-format view sample mismatch at byte %zu: Metal=%u ZPU=%u\n",
                    mismatch, mismatch < byte_count ? native_format_view_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_format_view_bytes[mismatch] : 0);
            return 109;
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
        adapter_pipeline_descriptor.label = @"zpu cpu render pipeline";
        adapter_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        adapter_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        adapter_pipeline_descriptor.supportIndirectCommandBuffers = YES;
        id<MTLCommandBuffer> adapter_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderPipelineState> adapter_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor error:&adapter_pipeline_error];
        MTLRenderPipelineReflection *native_legacy_render_reflection = nil;
        MTLRenderPipelineReflection *adapter_legacy_render_reflection = nil;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            [device newRenderPipelineStateWithDescriptor:pipeline_descriptor
                                                  options:MTLPipelineOptionBindingInfo
                                               reflection:&native_legacy_render_reflection
                                                    error:&error];
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_pipeline_descriptor
                                                          options:MTLPipelineOptionBindingInfo
                                                       reflection:&adapter_legacy_render_reflection
                                                            error:&adapter_pipeline_error];
        }
        const BOOL adapter_legacy_render_reflection_ok =
            adapter_legacy_render_reflection != nil &&
            adapter_legacy_render_reflection.vertexBindings.count == 1 &&
            [adapter_legacy_render_reflection.vertexBindings[0].name isEqualToString:@"vertices"] &&
            adapter_legacy_render_reflection.vertexBindings[0].type == MTLBindingTypeBuffer &&
            adapter_legacy_render_reflection.fragmentBindings.count == 0 &&
            (native_legacy_render_reflection == nil ||
             (native_legacy_render_reflection.vertexBindings.count == 1 &&
              native_legacy_render_reflection.fragmentBindings.count == 0));
        MTLRenderPipelineDescriptor *foreign_function_descriptor = [pipeline_descriptor copy];
        if ([adapter_device newRenderPipelineStateWithDescriptor:foreign_function_descriptor
                                                           error:&adapter_pipeline_error] != nil) {
            fprintf(stderr, "metal-pixel: adapter accepted a native Metal render function\n");
            return 129;
        }

        /* Render-pipeline callable linking is also CPU metadata. Native Metal
         * supplies the byte oracle for the same fixed vertex/fragment draw;
         * the adapter links only registered visible CPU functions and keeps
         * the rasterizer entirely on ZPU. */
        BOOL adapter_render_link_ok = YES;
        if (@available(macOS 12.0, iOS 15.0, tvOS 16.0, *)) {
            MTLRenderPipelineDescriptor *native_render_link_descriptor = [pipeline_descriptor copy];
            native_render_link_descriptor.supportAddingVertexBinaryFunctions = YES;
            native_render_link_descriptor.supportAddingFragmentBinaryFunctions = YES;
            MTLLinkedFunctions *native_vertex_linked_functions = [MTLLinkedFunctions new];
            native_vertex_linked_functions.functions = @[[library newFunctionWithName:@"zpu_test_visible"]];
            native_render_link_descriptor.vertexLinkedFunctions = native_vertex_linked_functions;
            MTLLinkedFunctions *native_fragment_linked_functions = [MTLLinkedFunctions new];
            native_fragment_linked_functions.functions = @[[library newFunctionWithName:@"zpu_test_visible"]];
            native_render_link_descriptor.fragmentLinkedFunctions = native_fragment_linked_functions;
            id<MTLRenderPipelineState> native_render_link_base =
                [device newRenderPipelineStateWithDescriptor:native_render_link_descriptor error:&error];
            MTLFunctionDescriptor *native_render_additional_descriptor = [MTLFunctionDescriptor new];
            native_render_additional_descriptor.name = @"zpu_test_visible_secondary";
            native_render_additional_descriptor.options = MTLFunctionOptionCompileToBinary;
            id<MTLFunction> native_render_additional_function =
                [library newFunctionWithDescriptor:native_render_additional_descriptor error:&error];
            MTLRenderPipelineFunctionsDescriptor *native_render_functions =
                [MTLRenderPipelineFunctionsDescriptor new];
            native_render_functions.vertexAdditionalBinaryFunctions = @[native_render_additional_function];
            native_render_functions.fragmentAdditionalBinaryFunctions = @[native_render_additional_function];
            id<MTLRenderPipelineState> native_render_linked_pipeline =
                [native_render_link_base newRenderPipelineStateWithAdditionalBinaryFunctions:native_render_functions
                                                                                          error:&error];

            MTLRenderPipelineDescriptor *adapter_render_link_descriptor = [adapter_pipeline_descriptor copy];
            adapter_render_link_descriptor.supportAddingVertexBinaryFunctions = YES;
            adapter_render_link_descriptor.supportAddingFragmentBinaryFunctions = YES;
            MTLLinkedFunctions *adapter_vertex_linked_functions = [MTLLinkedFunctions new];
            adapter_vertex_linked_functions.functions = @[
                ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_visible")];
            adapter_render_link_descriptor.vertexLinkedFunctions = adapter_vertex_linked_functions;
            MTLLinkedFunctions *adapter_fragment_linked_functions = [MTLLinkedFunctions new];
            adapter_fragment_linked_functions.functions = @[
                ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_visible")];
            adapter_render_link_descriptor.fragmentLinkedFunctions = adapter_fragment_linked_functions;
            id<MTLRenderPipelineState> adapter_render_link_base =
                [adapter_device newRenderPipelineStateWithDescriptor:adapter_render_link_descriptor
                                                                  error:&adapter_pipeline_error];
            id<MTLFunction> adapter_render_additional_function =
                ZPUMetalCreateCPUFunction(adapter_device, @"zpu_test_visible_secondary");
            MTLRenderPipelineFunctionsDescriptor *adapter_render_functions =
                [MTLRenderPipelineFunctionsDescriptor new];
            adapter_render_functions.vertexAdditionalBinaryFunctions = @[adapter_render_additional_function];
            adapter_render_functions.fragmentAdditionalBinaryFunctions = @[adapter_render_additional_function];
            id<MTLRenderPipelineState> adapter_render_linked_pipeline =
                [adapter_render_link_base newRenderPipelineStateWithAdditionalBinaryFunctions:adapter_render_functions
                                                                                          error:&adapter_pipeline_error];
            id<MTLFunctionHandle> adapter_render_vertex_handle =
                [adapter_render_linked_pipeline functionHandleWithFunction:adapter_render_additional_function
                                                                       stage:MTLRenderStageVertex];
            id<MTLFunctionHandle> adapter_render_fragment_handle =
                [adapter_render_linked_pipeline functionHandleWithFunction:adapter_render_additional_function
                                                                       stage:MTLRenderStageFragment];
            id<MTLTexture> native_render_link_texture = [device newTextureWithDescriptor:texture_descriptor];
            id<MTLTexture> adapter_render_link_texture =
                [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
            MTLRenderPassDescriptor *native_render_link_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            native_render_link_pass.colorAttachments[0].texture = native_render_link_texture;
            native_render_link_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            native_render_link_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            native_render_link_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> native_render_link_command_buffer = [queue commandBuffer];
            id<MTLRenderCommandEncoder> native_render_link_encoder =
                [native_render_link_command_buffer renderCommandEncoderWithDescriptor:native_render_link_pass];
            if (native_render_linked_pipeline != nil && native_render_link_encoder != nil) {
                [native_render_link_encoder setRenderPipelineState:native_render_linked_pipeline];
                [native_render_link_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
                [native_render_link_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [native_render_link_encoder endEncoding];
                [native_render_link_command_buffer commit];
                [native_render_link_command_buffer waitUntilCompleted];
            }
            MTLRenderPassDescriptor *adapter_render_link_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            adapter_render_link_pass.colorAttachments[0].texture = adapter_render_link_texture;
            adapter_render_link_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            adapter_render_link_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            adapter_render_link_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> adapter_render_link_command_buffer = [adapter_queue commandBuffer];
            id<MTLRenderCommandEncoder> adapter_render_link_encoder =
                [adapter_render_link_command_buffer renderCommandEncoderWithDescriptor:adapter_render_link_pass];
            if (adapter_render_linked_pipeline != nil && adapter_render_link_encoder != nil) {
                [adapter_render_link_encoder setRenderPipelineState:adapter_render_linked_pipeline];
                [adapter_render_link_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
                [adapter_render_link_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
                [adapter_render_link_encoder endEncoding];
                [adapter_render_link_command_buffer commit];
                [adapter_render_link_command_buffer waitUntilCompleted];
            }
            uint8_t native_render_link_pixels[byte_count] = {0};
            uint8_t adapter_render_link_pixels[byte_count] = {0};
            if (native_render_link_texture != nil) {
                [native_render_link_texture getBytes:native_render_link_pixels bytesPerRow:(NSUInteger)width * 4
                                           fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            }
            if (adapter_render_link_texture != nil) {
                [adapter_render_link_texture getBytes:adapter_render_link_pixels bytesPerRow:(NSUInteger)width * 4
                                            fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            }
            adapter_render_link_ok = native_render_link_base != nil && native_render_additional_function != nil &&
                native_render_linked_pipeline != nil && adapter_render_link_base != nil &&
                adapter_render_additional_function != nil && adapter_render_linked_pipeline != nil &&
                adapter_render_vertex_handle != nil && adapter_render_fragment_handle != nil &&
                native_render_link_command_buffer.status == MTLCommandBufferStatusCompleted &&
                adapter_render_link_command_buffer.status == MTLCommandBufferStatusCompleted &&
                memcmp(native_render_link_pixels, adapter_render_link_pixels, byte_count) == 0;
        }
        if (!adapter_render_link_ok) {
            fail_with_error("render pipeline callable linking failed", adapter_pipeline_error);
            return 137;
        }

        /* Cover every core Metal primitive topology through the same
         * Objective-C adapter. Constant vertex colors isolate coverage and
         * the asymmetric viewport/scissor below keeps the test sensitive to
         * the upper-left pixel-grid origin on both Apple platforms. */
        const zpu_metal_vertex primitive_vertices[] = {
            {{-0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
            {{ 0.75f, -0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
            {{ 0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
            {{-0.75f,  0.75f, 0.5f, 1.0f}, {0.25f, 0.50f, 0.75f, 1.0f}},
        };
        const MTLPrimitiveType primitive_types[] = {
            MTLPrimitiveTypePoint, MTLPrimitiveTypeLine, MTLPrimitiveTypeLineStrip,
            MTLPrimitiveTypeTriangleStrip,
        };
        const NSUInteger primitive_vertex_counts[] = {1, 2, 3, 4};
        const MTLViewport primitive_viewport = {1.0, 1.0, 6.0, 6.0, 0.0, 1.0};
        const MTLScissorRect primitive_scissor = {2, 1, 4, 5};
        for (NSUInteger primitive_index = 0; primitive_index < sizeof(primitive_types) / sizeof(primitive_types[0]); ++primitive_index) {
            id<MTLBuffer> native_primitive_buffer =
                [device newBufferWithBytes:primitive_vertices
                                     length:sizeof(primitive_vertices)
                                    options:MTLResourceStorageModeShared];
            id<MTLBuffer> adapter_primitive_buffer =
                [adapter_device newBufferWithBytes:primitive_vertices
                                             length:sizeof(primitive_vertices)
                                            options:MTLResourceStorageModeShared];
            id<MTLTexture> native_primitive_texture = [device newTextureWithDescriptor:texture_descriptor];
            id<MTLTexture> adapter_primitive_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
            MTLRenderPassDescriptor *native_primitive_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            native_primitive_pass.colorAttachments[0].texture = native_primitive_texture;
            native_primitive_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            native_primitive_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            native_primitive_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> native_primitive_command_buffer = [queue commandBuffer];
            id<MTLRenderCommandEncoder> native_primitive_encoder =
                [native_primitive_command_buffer renderCommandEncoderWithDescriptor:native_primitive_pass];
            [native_primitive_encoder setRenderPipelineState:pipeline];
            [native_primitive_encoder setViewport:primitive_viewport];
            [native_primitive_encoder setScissorRect:primitive_scissor];
            [native_primitive_encoder setVertexBuffer:native_primitive_buffer offset:0 atIndex:0];
            [native_primitive_encoder drawPrimitives:primitive_types[primitive_index]
                                         vertexStart:0
                                         vertexCount:primitive_vertex_counts[primitive_index]];
            [native_primitive_encoder endEncoding];
            [native_primitive_command_buffer commit];
            [native_primitive_command_buffer waitUntilCompleted];

            MTLRenderPassDescriptor *adapter_primitive_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            adapter_primitive_pass.colorAttachments[0].texture = adapter_primitive_texture;
            adapter_primitive_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            adapter_primitive_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            adapter_primitive_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> adapter_primitive_command_buffer = [adapter_queue commandBuffer];
            id<MTLRenderCommandEncoder> adapter_primitive_encoder =
                [adapter_primitive_command_buffer renderCommandEncoderWithDescriptor:adapter_primitive_pass];
            [adapter_primitive_encoder setRenderPipelineState:adapter_pipeline];
            [adapter_primitive_encoder setViewport:primitive_viewport];
            [adapter_primitive_encoder setScissorRect:primitive_scissor];
            [adapter_primitive_encoder setVertexBuffer:adapter_primitive_buffer offset:0 atIndex:0];
            [adapter_primitive_encoder drawPrimitives:primitive_types[primitive_index]
                                          vertexStart:0
                                          vertexCount:primitive_vertex_counts[primitive_index]];
            [adapter_primitive_encoder endEncoding];
            [adapter_primitive_command_buffer commit];
            [adapter_primitive_command_buffer waitUntilCompleted];
            uint8_t native_primitive_pixels[byte_count];
            uint8_t adapter_primitive_pixels[byte_count];
            [native_primitive_texture getBytes:native_primitive_pixels
                                   bytesPerRow:(NSUInteger)width * 4
                                    fromRegion:MTLRegionMake2D(0, 0, width, height)
                                   mipmapLevel:0];
            [adapter_primitive_texture getBytes:adapter_primitive_pixels
                                       bytesPerRow:(NSUInteger)width * 4
                                        fromRegion:MTLRegionMake2D(0, 0, width, height)
                                       mipmapLevel:0];
            if (native_primitive_command_buffer.status != MTLCommandBufferStatusCompleted ||
                adapter_primitive_command_buffer.status != MTLCommandBufferStatusCompleted ||
                native_primitive_encoder == nil || adapter_primitive_encoder == nil ||
                memcmp(native_primitive_pixels, adapter_primitive_pixels, byte_count) != 0) {
                fprintf(stderr, "metal-pixel: primitive topology mismatch at index %zu\n", primitive_index);
                for (size_t byte = 0; byte < byte_count; ++byte) {
                    if (native_primitive_pixels[byte] != adapter_primitive_pixels[byte]) {
                        fprintf(stderr, "metal-pixel: primitive mismatch at byte %zu: Metal=%u ZPU=%u\n",
                                byte, native_primitive_pixels[byte], adapter_primitive_pixels[byte]);
                        break;
                    }
                }
                return 105;
            }
        }

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
        adapter_sampler_descriptor.label = @"zpu cpu sampler";
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
        if (@available(macOS 26.0, iOS 26.0, *)) {
            if (!adapter_legacy_render_reflection_ok) {
                fprintf(stderr, "metal-pixel: legacy CPU render pipeline reflection failed\n");
                return 134;
            }
        }
        [adapter_encoder setLabel:@"zpu cpu render encoder"];
        if (![adapter_pipeline.label isEqualToString:@"zpu cpu render pipeline"] ||
            ![adapter_sampler.label isEqualToString:@"zpu cpu sampler"] ||
            ![adapter_encoder.label isEqualToString:@"zpu cpu render encoder"]) {
            fprintf(stderr, "metal-pixel: CPU Metal object labels were not retained\n");
            return 127;
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

        /* Acceleration structures are CPU-owned allocations and metadata. The
         * native object is created only as an oracle for availability/shape;
         * no native build or ray-tracing command is submitted here. */
        BOOL adapter_acceleration_resources_ok = YES;
        id<MTLAccelerationStructureCommandEncoder> adapter_acceleration_encoder = nil;
        if (@available(macOS 13.0, iOS 16.0, *)) {
            MTLPrimitiveAccelerationStructureDescriptor *native_as_descriptor =
                [MTLPrimitiveAccelerationStructureDescriptor descriptor];
            native_as_descriptor.geometryDescriptors = @[];
            MTLAccelerationStructureSizes native_as_sizes =
                [device accelerationStructureSizesWithDescriptor:native_as_descriptor];
            MTLAccelerationStructureSizes adapter_as_sizes =
                [adapter_device accelerationStructureSizesWithDescriptor:native_as_descriptor];
            const NSUInteger native_as_allocation_size = native_as_sizes.accelerationStructureSize == 0 ?
                256 : native_as_sizes.accelerationStructureSize;
            const NSUInteger adapter_as_allocation_size = adapter_as_sizes.accelerationStructureSize == 0 ?
                256 : adapter_as_sizes.accelerationStructureSize;
            id<MTLAccelerationStructure> native_as =
                [device newAccelerationStructureWithSize:native_as_allocation_size];
            id<MTLAccelerationStructure> adapter_as =
                [adapter_device newAccelerationStructureWithSize:adapter_as_allocation_size];
            id<MTLAccelerationStructure> adapter_descriptor_as =
                [adapter_device newAccelerationStructureWithDescriptor:native_as_descriptor];
            MTLArgumentDescriptor *as_argument_descriptor = [MTLArgumentDescriptor argumentDescriptor];
            as_argument_descriptor.dataType = MTLDataTypePointer;
            as_argument_descriptor.index = 1;
            id<MTLArgumentEncoder> as_argument_encoder =
                [adapter_device newArgumentEncoderWithArguments:@[as_argument_descriptor]];
            id<MTLBuffer> as_argument_buffer =
                [adapter_device newBufferWithLength:64 options:MTLResourceStorageModeShared];
            [as_argument_encoder setArgumentBuffer:as_argument_buffer offset:0];
            [as_argument_encoder setAccelerationStructure:adapter_as atIndex:1];
            uint64_t encoded_as_resource = 0;
            if (as_argument_buffer != nil) {
                memcpy(&encoded_as_resource, (uint8_t *)as_argument_buffer.contents + 16,
                       sizeof(encoded_as_resource));
            }
            MTLHeapDescriptor *as_heap_descriptor = [MTLHeapDescriptor new];
            as_heap_descriptor.size = adapter_as_allocation_size + 512;
            as_heap_descriptor.storageMode = MTLStorageModeShared;
            as_heap_descriptor.cpuCacheMode = MTLCPUCacheModeDefaultCache;
            as_heap_descriptor.hazardTrackingMode = MTLHazardTrackingModeTracked;
            id<MTLHeap> adapter_as_heap = [adapter_device newHeapWithDescriptor:as_heap_descriptor];
            id<MTLAccelerationStructure> adapter_heap_as =
                [adapter_as_heap newAccelerationStructureWithSize:256];
            id<MTLAccelerationStructure> adapter_copy_as =
                [adapter_device newAccelerationStructureWithSize:adapter_as_allocation_size];
            const NSUInteger adapter_compacted_size = adapter_as_sizes.accelerationStructureSize / 2 == 0 ?
                1 : adapter_as_sizes.accelerationStructureSize / 2;
            id<MTLAccelerationStructure> adapter_compacted_as =
                [adapter_device newAccelerationStructureWithSize:adapter_compacted_size];
            id<MTLBuffer> adapter_as_status_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> adapter_as_scratch = [adapter_device newBufferWithLength:
                adapter_as_sizes.buildScratchBufferSize == 0 ? 1 : adapter_as_sizes.buildScratchBufferSize
                                                                       options:MTLResourceStorageModeShared];
            id<MTLCommandBuffer> adapter_as_command_buffer = [adapter_queue commandBuffer];
            adapter_acceleration_encoder = [adapter_as_command_buffer accelerationStructureCommandEncoder];
            [adapter_acceleration_encoder buildAccelerationStructure:adapter_as descriptor:native_as_descriptor
                                                       scratchBuffer:adapter_as_scratch scratchBufferOffset:0];
            [adapter_acceleration_encoder writeCompactedAccelerationStructureSize:adapter_as
                                                                          toBuffer:adapter_as_status_buffer offset:0
                                                                      sizeDataType:MTLDataTypeULong];
            [adapter_acceleration_encoder endEncoding];
            [adapter_as_command_buffer commit];
            [adapter_as_command_buffer waitUntilCompleted];
            uint64_t adapter_compacted_size_value = 0;
            if (adapter_as_status_buffer != nil) {
                memcpy(&adapter_compacted_size_value, adapter_as_status_buffer.contents, sizeof(adapter_compacted_size_value));
            }
            id<MTLCommandBuffer> adapter_as_copy_command_buffer = [adapter_queue commandBuffer];
            id<MTLAccelerationStructureCommandEncoder> adapter_as_copy_encoder =
                [adapter_as_copy_command_buffer accelerationStructureCommandEncoder];
            [adapter_as_copy_encoder copyAccelerationStructure:adapter_as
                                      toAccelerationStructure:adapter_copy_as];
            [adapter_as_copy_encoder endEncoding];
            [adapter_as_copy_command_buffer commit];
            [adapter_as_copy_command_buffer waitUntilCompleted];
            id<MTLCommandBuffer> adapter_as_compact_command_buffer = [adapter_queue commandBuffer];
            id<MTLAccelerationStructureCommandEncoder> adapter_as_compact_encoder =
                [adapter_as_compact_command_buffer accelerationStructureCommandEncoder];
            [adapter_as_compact_encoder copyAndCompactAccelerationStructure:adapter_as
                                                    toAccelerationStructure:adapter_compacted_as];
            [adapter_as_compact_encoder endEncoding];
            [adapter_as_compact_command_buffer commit];
            [adapter_as_compact_command_buffer waitUntilCompleted];
            adapter_acceleration_resources_ok =
                adapter_as != nil && adapter_as.size == adapter_as_allocation_size &&
                adapter_descriptor_as != nil && adapter_descriptor_as.size == adapter_as_allocation_size &&
                adapter_as.device == adapter_device && adapter_as.heap == nil &&
                adapter_as.gpuResourceID._impl != 0 &&
                as_argument_encoder != nil && as_argument_buffer != nil &&
                encoded_as_resource == adapter_as.gpuResourceID._impl &&
                adapter_as_heap != nil && adapter_heap_as != nil &&
                adapter_heap_as.heap == adapter_as_heap && adapter_heap_as.heapOffset == 0 &&
                adapter_heap_as.gpuResourceID._impl != 0 &&
                adapter_copy_as != nil && adapter_compacted_as != nil &&
                adapter_as_status_buffer != nil && adapter_compacted_size_value == adapter_compacted_size &&
                adapter_acceleration_encoder != nil && adapter_as_copy_encoder != nil &&
                adapter_as_compact_encoder != nil &&
                adapter_as_command_buffer.status == MTLCommandBufferStatusCompleted &&
                adapter_as_copy_command_buffer.status == MTLCommandBufferStatusCompleted &&
                adapter_as_compact_command_buffer.status == MTLCommandBufferStatusCompleted &&
                (native_as == nil || (native_as.device == device && native_as.size >= native_as_allocation_size));
        }
        BOOL adapter_iosurface_ok = YES;
        if (@available(macOS 10.11, iOS 11.0, *)) {
            const NSUInteger iosurface_width = 4;
            const NSUInteger iosurface_height = 4;
            const NSUInteger iosurface_stride = 32;
            NSDictionary *iosurface_properties = @{
                (id)kIOSurfaceWidth: @(iosurface_width),
                (id)kIOSurfaceHeight: @(iosurface_height),
                (id)kIOSurfaceBytesPerElement: @(4),
                (id)kIOSurfaceBytesPerRow: @(iosurface_stride),
                (id)kIOSurfaceAllocSize: @(iosurface_stride * iosurface_height),
            };
            IOSurfaceRef iosurface = IOSurfaceCreate((CFDictionaryRef)iosurface_properties);
            BOOL iosurface_locked = NO;
            if (iosurface != NULL && IOSurfaceLock(iosurface, 0, NULL) == kIOReturnSuccess) {
                iosurface_locked = YES;
                uint8_t *iosurface_bytes = (uint8_t *)IOSurfaceGetBaseAddress(iosurface);
                for (NSUInteger y = 0; y < iosurface_height; ++y) {
                    for (NSUInteger x = 0; x < iosurface_width; ++x) {
                        uint8_t *pixel = iosurface_bytes + y * iosurface_stride + x * 4;
                        pixel[0] = (uint8_t)(x + 1);
                        pixel[1] = (uint8_t)(y + 17);
                        pixel[2] = (uint8_t)(x + y + 33);
                        pixel[3] = 255;
                    }
                }
                MTLTextureDescriptor *iosurface_descriptor =
                    [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                        width:iosurface_width
                                                                       height:iosurface_height
                                                                    mipmapped:NO];
                iosurface_descriptor.storageMode = MTLStorageModeShared;
                iosurface_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
                id<MTLTexture> native_iosurface_texture =
                    [device newTextureWithDescriptor:iosurface_descriptor iosurface:iosurface plane:0];
                id<MTLTexture> adapter_iosurface_texture =
                    [adapter_device newTextureWithDescriptor:iosurface_descriptor iosurface:iosurface plane:0];
                uint8_t adapter_iosurface_bytes[iosurface_width * iosurface_height * 4];
                memset(adapter_iosurface_bytes, 0, sizeof(adapter_iosurface_bytes));
                if (adapter_iosurface_texture != nil) {
                    [adapter_iosurface_texture getBytes:adapter_iosurface_bytes
                                            bytesPerRow:iosurface_width * 4
                                             fromRegion:MTLRegionMake2D(0, 0, iosurface_width, iosurface_height)
                                            mipmapLevel:0];
                }
                BOOL native_iosurface_match = YES;
                if (native_iosurface_texture != nil) {
                    uint8_t native_iosurface_bytes[sizeof(adapter_iosurface_bytes)];
                    [native_iosurface_texture getBytes:native_iosurface_bytes
                                            bytesPerRow:iosurface_width * 4
                                             fromRegion:MTLRegionMake2D(0, 0, iosurface_width, iosurface_height)
                                            mipmapLevel:0];
                    native_iosurface_match = memcmp(native_iosurface_bytes, adapter_iosurface_bytes,
                                                     sizeof(adapter_iosurface_bytes)) == 0;
                }
                const uint8_t iosurface_patch[] = {
                    91, 92, 93, 255, 101, 102, 103, 255,
                    111, 112, 113, 255, 121, 122, 123, 255,
                };
                if (adapter_iosurface_texture != nil) {
                    [adapter_iosurface_texture replaceRegion:MTLRegionMake2D(1, 1, 2, 2)
                                                 mipmapLevel:0 withBytes:iosurface_patch bytesPerRow:8];
                }
                uint8_t adapter_iosurface_after[sizeof(adapter_iosurface_bytes)];
                memset(adapter_iosurface_after, 0, sizeof(adapter_iosurface_after));
                if (adapter_iosurface_texture != nil) {
                    [adapter_iosurface_texture getBytes:adapter_iosurface_after
                                            bytesPerRow:iosurface_width * 4
                                             fromRegion:MTLRegionMake2D(0, 0, iosurface_width, iosurface_height)
                                            mipmapLevel:0];
                }
                BOOL iosurface_matches_surface = YES;
                for (NSUInteger y = 0; y < iosurface_height; ++y) {
                    iosurface_matches_surface = iosurface_matches_surface &&
                        memcmp(adapter_iosurface_after + y * iosurface_width * 4,
                               iosurface_bytes + y * iosurface_stride, iosurface_width * 4) == 0;
                }
                adapter_iosurface_ok = adapter_iosurface_texture != nil &&
                    [adapter_iosurface_texture iosurface] == iosurface &&
                    adapter_iosurface_texture.iosurfacePlane == 0 &&
                    native_iosurface_match &&
                    iosurface_matches_surface &&
                    memcmp(iosurface_bytes + iosurface_stride + 4, iosurface_patch, 8) == 0 &&
                    memcmp(iosurface_bytes + 2 * iosurface_stride + 4, iosurface_patch + 8, 8) == 0;
            } else {
                adapter_iosurface_ok = NO;
            }
            if (iosurface_locked) IOSurfaceUnlock(iosurface, 0, NULL);
            if (iosurface != NULL) CFRelease(iosurface);
        }
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
            adapter_acceleration_resources_ok &&
            adapter_iosurface_ok &&
            [adapter_command_buffer accelerationStructureCommandEncoder] != nil;
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
        /* Mesh/object/tile shader stages have no CPU/ZPU execution path yet.
         * Their resource setters must not masquerade as fragment bindings,
         * because doing so can silently produce the wrong pixels. */
        id<MTLCommandBuffer> adapter_unsupported_stage_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_unsupported_stage_encoder =
            [adapter_unsupported_stage_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
        uint32_t adapter_unsupported_stage_bytes = 0x12345678u;
        [adapter_unsupported_stage_encoder setObjectBytes:&adapter_unsupported_stage_bytes
                                                    length:sizeof(adapter_unsupported_stage_bytes)
                                                   atIndex:0];
        [adapter_unsupported_stage_encoder setMeshBytes:&adapter_unsupported_stage_bytes
                                                  length:sizeof(adapter_unsupported_stage_bytes)
                                                 atIndex:0];
        [adapter_unsupported_stage_encoder setTileBytes:&adapter_unsupported_stage_bytes
                                                  length:sizeof(adapter_unsupported_stage_bytes)
                                                 atIndex:0];
        [adapter_unsupported_stage_encoder endEncoding];
        [adapter_unsupported_stage_command_buffer commit];
        [adapter_unsupported_stage_command_buffer waitUntilCompleted];
        if (adapter_unsupported_stage_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: unsupported CPU shader stage did not fail closed\n");
            return 56;
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

        /* Cube storage is six ordinary CPU/ZPU-owned 2D faces. The native
         * texture is used only as the Metal slice, mipmap, copy, and view
         * oracle; no adapter operation below submits a native Metal command. */
        enum {
            cube_size = 4,
            cube_face_bytes = cube_size * cube_size * 4,
            cube_mip_bytes = (cube_size * cube_size + 2 * 2 + 1) * 4,
            cube_face_count = 6,
            cube_array_count = 2,
            cube_array_slice_count = cube_face_count * cube_array_count,
        };
        MTLTextureDescriptor *cube_descriptor = [MTLTextureDescriptor new];
        cube_descriptor.textureType = MTLTextureTypeCube;
        cube_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        cube_descriptor.width = cube_size;
        cube_descriptor.height = cube_size;
        cube_descriptor.depth = 1;
        cube_descriptor.arrayLength = 1;
        cube_descriptor.mipmapLevelCount = 3;
        cube_descriptor.sampleCount = 1;
        cube_descriptor.storageMode = MTLStorageModeShared;
        cube_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        MTLTextureDescriptor *cube_array_descriptor = [cube_descriptor copy];
        cube_array_descriptor.textureType = MTLTextureTypeCubeArray;
        cube_array_descriptor.arrayLength = cube_array_count;
        id<MTLTexture> native_cube_texture = [device newTextureWithDescriptor:cube_descriptor];
        id<MTLTexture> adapter_cube_texture = [adapter_device newTextureWithDescriptor:cube_descriptor];
        id<MTLTexture> native_cube_array_texture = [device newTextureWithDescriptor:cube_array_descriptor];
        id<MTLTexture> adapter_cube_array_texture = [adapter_device newTextureWithDescriptor:cube_array_descriptor];
        uint8_t cube_face_source[cube_face_count][cube_face_bytes];
        uint8_t cube_array_source[cube_array_slice_count][cube_face_bytes];
        for (NSUInteger slice = 0; slice < cube_face_count; ++slice) {
            for (NSUInteger index = 0; index < cube_face_bytes; ++index) {
                cube_face_source[slice][index] = (uint8_t)((slice * 37u + index * 19u + 11u) & 0xffu);
            }
        }
        for (NSUInteger slice = 0; slice < cube_array_slice_count; ++slice) {
            for (NSUInteger index = 0; index < cube_face_bytes; ++index) {
                cube_array_source[slice][index] = (uint8_t)((slice * 53u + index * 23u + 17u) & 0xffu);
            }
        }
        for (NSUInteger slice = 0; slice < cube_face_count; ++slice) {
            [native_cube_texture replaceRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                    mipmapLevel:0
                                          slice:slice
                                      withBytes:cube_face_source[slice]
                                    bytesPerRow:cube_size * 4
                                  bytesPerImage:cube_face_bytes];
            [adapter_cube_texture replaceRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                     mipmapLevel:0
                                           slice:slice
                                       withBytes:cube_face_source[slice]
                                     bytesPerRow:cube_size * 4
                                   bytesPerImage:cube_face_bytes];
        }
        for (NSUInteger slice = 0; slice < cube_array_slice_count; ++slice) {
            [native_cube_array_texture replaceRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                         mipmapLevel:0
                                               slice:slice
                                           withBytes:cube_array_source[slice]
                                         bytesPerRow:cube_size * 4
                                       bytesPerImage:cube_face_bytes];
            [adapter_cube_array_texture replaceRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                          mipmapLevel:0
                                                slice:slice
                                            withBytes:cube_array_source[slice]
                                          bytesPerRow:cube_size * 4
                                        bytesPerImage:cube_face_bytes];
        }
        uint8_t native_cube_bytes[cube_face_bytes];
        uint8_t adapter_cube_bytes[cube_face_bytes];
        uint8_t native_cube_array_bytes[cube_face_bytes];
        uint8_t adapter_cube_array_bytes[cube_face_bytes];
        BOOL cube_bytes_match = YES;
        for (NSUInteger slice = 0; slice < cube_face_count; ++slice) {
            [native_cube_texture getBytes:native_cube_bytes
                              bytesPerRow:cube_size * 4
                            bytesPerImage:cube_face_bytes
                             fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                            mipmapLevel:0
                                   slice:slice];
            [adapter_cube_texture getBytes:adapter_cube_bytes
                               bytesPerRow:cube_size * 4
                             bytesPerImage:cube_face_bytes
                              fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                             mipmapLevel:0
                                    slice:slice];
            cube_bytes_match = cube_bytes_match &&
                memcmp(native_cube_bytes, cube_face_source[slice], cube_face_bytes) == 0 &&
                memcmp(adapter_cube_bytes, native_cube_bytes, cube_face_bytes) == 0;
        }
        BOOL cube_array_bytes_match = YES;
        for (NSUInteger slice = 0; slice < cube_array_slice_count; ++slice) {
            [native_cube_array_texture getBytes:native_cube_array_bytes
                                      bytesPerRow:cube_size * 4
                                    bytesPerImage:cube_face_bytes
                                     fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                    mipmapLevel:0
                                           slice:slice];
            [adapter_cube_array_texture getBytes:adapter_cube_array_bytes
                                         bytesPerRow:cube_size * 4
                                       bytesPerImage:cube_face_bytes
                                        fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                       mipmapLevel:0
                                              slice:slice];
            cube_array_bytes_match = cube_array_bytes_match &&
                memcmp(native_cube_array_bytes, cube_array_source[slice], cube_face_bytes) == 0 &&
                memcmp(adapter_cube_array_bytes, native_cube_array_bytes, cube_face_bytes) == 0;
        }
        id<MTLCommandBuffer> native_cube_mip_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_cube_mip_blit = [native_cube_mip_command_buffer blitCommandEncoder];
        [native_cube_mip_blit generateMipmapsForTexture:native_cube_texture];
        [native_cube_mip_blit endEncoding];
        [native_cube_mip_command_buffer commit];
        [native_cube_mip_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_cube_mip_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_cube_mip_blit = [adapter_cube_mip_command_buffer blitCommandEncoder];
        [adapter_cube_mip_blit generateMipmapsForTexture:adapter_cube_texture];
        [adapter_cube_mip_blit endEncoding];
        [adapter_cube_mip_command_buffer commit];
        [adapter_cube_mip_command_buffer waitUntilCompleted];
        BOOL cube_mips_match = native_cube_mip_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_cube_mip_command_buffer.status == MTLCommandBufferStatusCompleted;
        for (NSUInteger level = 1; level < cube_descriptor.mipmapLevelCount; ++level) {
            const NSUInteger levelSize = cube_size >> level;
            const NSUInteger levelBytes = levelSize * levelSize * 4;
            for (NSUInteger slice = 0; slice < cube_face_count; ++slice) {
                [native_cube_texture getBytes:native_cube_bytes
                                  bytesPerRow:levelSize * 4
                                bytesPerImage:levelBytes
                                 fromRegion:MTLRegionMake2D(0, 0, levelSize, levelSize)
                                mipmapLevel:level slice:slice];
                [adapter_cube_texture getBytes:adapter_cube_bytes
                                   bytesPerRow:levelSize * 4
                                 bytesPerImage:levelBytes
                                    fromRegion:MTLRegionMake2D(0, 0, levelSize, levelSize)
                                   mipmapLevel:level slice:slice];
                cube_mips_match = cube_mips_match &&
                    memcmp(native_cube_bytes, adapter_cube_bytes, levelBytes) == 0;
            }
        }
        id<MTLTexture> native_cube_array_copy = [device newTextureWithDescriptor:cube_array_descriptor];
        id<MTLTexture> adapter_cube_array_copy = [adapter_device newTextureWithDescriptor:cube_array_descriptor];
        id<MTLCommandBuffer> native_cube_copy_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_cube_copy_blit = [native_cube_copy_command_buffer blitCommandEncoder];
        [native_cube_copy_blit copyFromTexture:native_cube_array_texture
                                   sourceSlice:0 sourceLevel:0
                                      toTexture:native_cube_array_copy
                              destinationSlice:0 destinationLevel:0
                                  sliceCount:cube_array_slice_count levelCount:1];
        [native_cube_copy_blit endEncoding];
        [native_cube_copy_command_buffer commit];
        [native_cube_copy_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_cube_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_cube_copy_blit = [adapter_cube_copy_command_buffer blitCommandEncoder];
        [adapter_cube_copy_blit copyFromTexture:adapter_cube_array_texture
                                    sourceSlice:0 sourceLevel:0
                                       toTexture:adapter_cube_array_copy
                               destinationSlice:0 destinationLevel:0
                                   sliceCount:cube_array_slice_count levelCount:1];
        [adapter_cube_copy_blit endEncoding];
        [adapter_cube_copy_command_buffer commit];
        [adapter_cube_copy_command_buffer waitUntilCompleted];
        BOOL cube_copy_match = native_cube_copy_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_cube_copy_command_buffer.status == MTLCommandBufferStatusCompleted;
        for (NSUInteger slice = 0; slice < cube_array_slice_count; ++slice) {
            [native_cube_array_copy getBytes:native_cube_array_bytes
                                   bytesPerRow:cube_size * 4
                                 bytesPerImage:cube_face_bytes
                                    fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                   mipmapLevel:0 slice:slice];
            [adapter_cube_array_copy getBytes:adapter_cube_array_bytes
                                      bytesPerRow:cube_size * 4
                                    bytesPerImage:cube_face_bytes
                                       fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                      mipmapLevel:0 slice:slice];
            cube_copy_match = cube_copy_match &&
                memcmp(native_cube_array_bytes, adapter_cube_array_bytes, cube_face_bytes) == 0 &&
                memcmp(adapter_cube_array_bytes, cube_array_source[slice], cube_face_bytes) == 0;
        }
        id<MTLTexture> native_cube_array_view =
            [native_cube_array_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                           textureType:MTLTextureTypeCubeArray
                                                                levels:NSMakeRange(0, 1)
                                                                slices:NSMakeRange(cube_face_count, cube_face_count)];
        id<MTLTexture> adapter_cube_array_view =
            [adapter_cube_array_texture newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            textureType:MTLTextureTypeCubeArray
                                                                 levels:NSMakeRange(0, 1)
                                                                 slices:NSMakeRange(cube_face_count, cube_face_count)];
        uint8_t native_cube_view_bytes[cube_face_bytes];
        uint8_t adapter_cube_view_bytes[cube_face_bytes];
        if (native_cube_array_view != nil) {
            [native_cube_array_view getBytes:native_cube_view_bytes
                                  bytesPerRow:cube_size * 4
                                bytesPerImage:cube_face_bytes
                                   fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                  mipmapLevel:0 slice:0];
        }
        if (adapter_cube_array_view != nil) {
            [adapter_cube_array_view getBytes:adapter_cube_view_bytes
                                     bytesPerRow:cube_size * 4
                                   bytesPerImage:cube_face_bytes
                                      fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                     mipmapLevel:0 slice:0];
        }
        MTLRenderPipelineDescriptor *cube_render_pipeline_descriptor = [pipeline_descriptor copy];
        cube_render_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        cube_render_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_cube_render_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:cube_render_pipeline_descriptor
                                                            error:&adapter_pipeline_error];
        const NSUInteger cube_render_slice = 4;
        MTLRenderPassDescriptor *native_cube_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        native_cube_render_pass.colorAttachments[0].texture = native_cube_texture;
        native_cube_render_pass.colorAttachments[0].slice = cube_render_slice;
        native_cube_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        native_cube_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        native_cube_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> native_cube_render_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> native_cube_render_encoder =
            [native_cube_render_command_buffer renderCommandEncoderWithDescriptor:native_cube_render_pass];
        [native_cube_render_encoder setRenderPipelineState:pipeline];
        [native_cube_render_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [native_cube_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [native_cube_render_encoder endEncoding];
        [native_cube_render_command_buffer commit];
        [native_cube_render_command_buffer waitUntilCompleted];
        MTLRenderPassDescriptor *adapter_cube_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_cube_render_pass.colorAttachments[0].texture = adapter_cube_texture;
        adapter_cube_render_pass.colorAttachments[0].slice = cube_render_slice;
        adapter_cube_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_cube_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_cube_render_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_cube_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_cube_render_encoder =
            [adapter_cube_render_command_buffer renderCommandEncoderWithDescriptor:adapter_cube_render_pass];
        [adapter_cube_render_encoder setRenderPipelineState:adapter_cube_render_pipeline];
        [adapter_cube_render_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_cube_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_cube_render_encoder endEncoding];
        [adapter_cube_render_command_buffer commit];
        [adapter_cube_render_command_buffer waitUntilCompleted];
        uint8_t native_cube_render_bytes[cube_face_bytes];
        uint8_t adapter_cube_render_bytes[cube_face_bytes];
        [native_cube_texture getBytes:native_cube_render_bytes
                          bytesPerRow:cube_size * 4
                        bytesPerImage:cube_face_bytes
                         fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                        mipmapLevel:0 slice:cube_render_slice];
        [adapter_cube_texture getBytes:adapter_cube_render_bytes
                           bytesPerRow:cube_size * 4
                         bytesPerImage:cube_face_bytes
                          fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                         mipmapLevel:0 slice:cube_render_slice];
        const BOOL cube_render_match = native_cube_render_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_cube_render_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_cube_render_encoder != nil && adapter_cube_render_pipeline != nil &&
            memcmp(native_cube_render_bytes, adapter_cube_render_bytes, cube_face_bytes) == 0;
        MTLSizeAndAlign cube_heap_size_align =
            [adapter_device heapTextureSizeAndAlignWithDescriptor:cube_descriptor];
        MTLHeapDescriptor *cube_heap_descriptor = [MTLHeapDescriptor new];
        cube_heap_descriptor.size = cube_heap_size_align.size;
        cube_heap_descriptor.storageMode = MTLStorageModeShared;
        id<MTLHeap> adapter_cube_heap = [adapter_device newHeapWithDescriptor:cube_heap_descriptor];
        id<MTLTexture> adapter_cube_heap_texture =
            [adapter_cube_heap newTextureWithDescriptor:cube_descriptor];
        uint8_t adapter_cube_heap_bytes[cube_face_bytes];
        [adapter_cube_heap_texture replaceRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                                      mipmapLevel:0
                                            slice:cube_face_count - 1
                                        withBytes:cube_face_source[cube_face_count - 1]
                                      bytesPerRow:cube_size * 4
                                    bytesPerImage:cube_face_bytes];
        [adapter_cube_heap_texture getBytes:adapter_cube_heap_bytes
                                bytesPerRow:cube_size * 4
                              bytesPerImage:cube_face_bytes
                               fromRegion:MTLRegionMake2D(0, 0, cube_size, cube_size)
                              mipmapLevel:0
                                     slice:cube_face_count - 1];
        const NSUInteger expected_cube_allocated_size = cube_face_count * cube_mip_bytes;
        const NSUInteger expected_cube_array_allocated_size = cube_array_count * expected_cube_allocated_size;
        if (native_cube_texture == nil || adapter_cube_texture == nil ||
            native_cube_array_texture == nil || adapter_cube_array_texture == nil ||
            native_cube_texture.textureType != MTLTextureTypeCube ||
            adapter_cube_texture.textureType != MTLTextureTypeCube ||
            native_cube_array_texture.textureType != MTLTextureTypeCubeArray ||
            adapter_cube_array_texture.textureType != MTLTextureTypeCubeArray ||
            native_cube_texture.arrayLength != 1 || adapter_cube_texture.arrayLength != 1 ||
            native_cube_array_texture.arrayLength != cube_array_count ||
            adapter_cube_array_texture.arrayLength != cube_array_count ||
            native_cube_texture.width != cube_size || adapter_cube_texture.width != cube_size ||
            native_cube_texture.height != cube_size || adapter_cube_texture.height != cube_size ||
            native_cube_texture.mipmapLevelCount != 3 || adapter_cube_texture.mipmapLevelCount != 3 ||
            adapter_cube_texture.allocatedSize != expected_cube_allocated_size ||
            adapter_cube_array_texture.allocatedSize != expected_cube_array_allocated_size ||
            cube_heap_size_align.size != expected_cube_allocated_size || cube_heap_size_align.align != 4 ||
            adapter_cube_heap == nil || adapter_cube_heap_texture == nil ||
            adapter_cube_heap_texture.arrayLength != 1 ||
            adapter_cube_heap_texture.allocatedSize != expected_cube_allocated_size ||
            adapter_cube_heap.usedSize != expected_cube_allocated_size ||
            memcmp(adapter_cube_heap_bytes, cube_face_source[cube_face_count - 1], cube_face_bytes) != 0 ||
            !cube_bytes_match || !cube_array_bytes_match || !cube_mips_match || !cube_copy_match || !cube_render_match ||
            native_cube_array_view == nil || adapter_cube_array_view == nil ||
            native_cube_array_view.arrayLength != 1 || adapter_cube_array_view.arrayLength != 1 ||
            adapter_cube_array_view.parentRelativeSlice != cube_face_count ||
            memcmp(native_cube_view_bytes, adapter_cube_view_bytes, cube_face_bytes) != 0 ||
            memcmp(adapter_cube_view_bytes, cube_array_source[cube_face_count], cube_face_bytes) != 0) {
            fprintf(stderr, "metal-pixel: cube/cube-array slice, mipmap, copy, or view exactness failed\n");
            return 78;
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

        /* RGBA16Float is the first supported format whose texel width is not
         * four bytes. Exercise the padded 3D buffer paths with a non-zero
         * x/y/z destination so a hard-coded RGBA8 row width cannot pass. */
        enum {
            f16_three_d_width = 3,
            f16_three_d_height = 3,
            f16_three_d_depth = 3,
            f16_three_d_bytes_per_pixel = 8,
            f16_three_d_row_bytes = f16_three_d_width * f16_three_d_bytes_per_pixel,
            f16_three_d_plane_bytes = f16_three_d_row_bytes * f16_three_d_height,
            f16_three_d_bytes = f16_three_d_plane_bytes * f16_three_d_depth,
            f16_copy_width = 2,
            f16_copy_height = 2,
            f16_copy_depth = 2,
            f16_copy_row_bytes = f16_copy_width * f16_three_d_bytes_per_pixel,
            f16_copy_row_stride = f16_copy_row_bytes + 8,
            f16_copy_image_stride = f16_copy_row_stride * f16_copy_height + 8,
            f16_upload_offset = 8,
            f16_upload_buffer_length = f16_upload_offset + f16_copy_image_stride * f16_copy_depth,
            f16_download_offset = 4,
            f16_download_buffer_length = f16_download_offset + f16_copy_image_stride * f16_copy_depth,
        };
        MTLTextureDescriptor *f16_three_d_descriptor = [MTLTextureDescriptor new];
        f16_three_d_descriptor.textureType = MTLTextureType3D;
        f16_three_d_descriptor.pixelFormat = MTLPixelFormatRGBA16Float;
        f16_three_d_descriptor.width = f16_three_d_width;
        f16_three_d_descriptor.height = f16_three_d_height;
        f16_three_d_descriptor.depth = f16_three_d_depth;
        f16_three_d_descriptor.arrayLength = 1;
        f16_three_d_descriptor.mipmapLevelCount = 1;
        f16_three_d_descriptor.sampleCount = 1;
        f16_three_d_descriptor.storageMode = MTLStorageModeShared;
        f16_three_d_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        id<MTLTexture> native_f16_three_d = [device newTextureWithDescriptor:f16_three_d_descriptor];
        id<MTLTexture> adapter_f16_three_d = [adapter_device newTextureWithDescriptor:f16_three_d_descriptor];
        uint8_t f16_three_d_clear[f16_three_d_bytes];
        memset(f16_three_d_clear, 0, sizeof(f16_three_d_clear));
        [native_f16_three_d replaceRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                           f16_three_d_height, f16_three_d_depth)
                               mipmapLevel:0 slice:0 withBytes:f16_three_d_clear
                               bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes];
        [adapter_f16_three_d replaceRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                            f16_three_d_height, f16_three_d_depth)
                                mipmapLevel:0 slice:0 withBytes:f16_three_d_clear
                                bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes];

        uint8_t f16_upload_source[f16_upload_buffer_length];
        memset(f16_upload_source, 0xd7, sizeof(f16_upload_source));
        for (NSUInteger plane = 0; plane < f16_copy_depth; ++plane) {
            for (NSUInteger row = 0; row < f16_copy_height; ++row) {
                for (NSUInteger column = 0; column < f16_copy_width; ++column) {
                    const NSUInteger pixel_offset = f16_upload_offset + plane * f16_copy_image_stride +
                        row * f16_copy_row_stride + column * f16_three_d_bytes_per_pixel;
                    for (NSUInteger byte = 0; byte < f16_three_d_bytes_per_pixel; ++byte) {
                        f16_upload_source[pixel_offset + byte] =
                            (uint8_t)((plane * 67u + row * 29u + column * 13u + byte * 11u + 5u) & 0xffu);
                    }
                }
            }
        }
        id<MTLBuffer> native_f16_upload_buffer =
            [device newBufferWithBytes:f16_upload_source length:sizeof(f16_upload_source)
                               options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_f16_upload_buffer =
            [adapter_device newBufferWithBytes:f16_upload_source length:sizeof(f16_upload_source)
                                        options:MTLResourceStorageModeShared];
        const MTLSize f16_copy_size = MTLSizeMake(f16_copy_width, f16_copy_height, f16_copy_depth);
        const MTLOrigin f16_destination_origin = MTLOriginMake(1, 1, 1);
        id<MTLCommandBuffer> native_f16_upload_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_f16_upload_blit =
            [native_f16_upload_command_buffer blitCommandEncoder];
        [native_f16_upload_blit copyFromBuffer:native_f16_upload_buffer sourceOffset:f16_upload_offset
                              sourceBytesPerRow:f16_copy_row_stride sourceBytesPerImage:f16_copy_image_stride
                                     sourceSize:f16_copy_size toTexture:native_f16_three_d
                                destinationSlice:0 destinationLevel:0 destinationOrigin:f16_destination_origin];
        [native_f16_upload_blit endEncoding];
        [native_f16_upload_command_buffer commit];
        [native_f16_upload_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_f16_upload_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_f16_upload_blit =
            [adapter_f16_upload_command_buffer blitCommandEncoder];
        [adapter_f16_upload_blit copyFromBuffer:adapter_f16_upload_buffer sourceOffset:f16_upload_offset
                               sourceBytesPerRow:f16_copy_row_stride sourceBytesPerImage:f16_copy_image_stride
                                      sourceSize:f16_copy_size toTexture:adapter_f16_three_d
                                 destinationSlice:0 destinationLevel:0 destinationOrigin:f16_destination_origin];
        [adapter_f16_upload_blit endEncoding];
        [adapter_f16_upload_command_buffer commit];
        [adapter_f16_upload_command_buffer waitUntilCompleted];

        uint8_t native_f16_three_d_bytes[f16_three_d_bytes];
        uint8_t adapter_f16_three_d_bytes[f16_three_d_bytes];
        memset(native_f16_three_d_bytes, 0xa5, sizeof(native_f16_three_d_bytes));
        memset(adapter_f16_three_d_bytes, 0xa5, sizeof(adapter_f16_three_d_bytes));
        [native_f16_three_d getBytes:native_f16_three_d_bytes
                         bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes
                          fromRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                      f16_three_d_height, f16_three_d_depth)
                         mipmapLevel:0 slice:0];
        [adapter_f16_three_d getBytes:adapter_f16_three_d_bytes
                          bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes
                           fromRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                       f16_three_d_height, f16_three_d_depth)
                          mipmapLevel:0 slice:0];

        id<MTLBuffer> native_f16_download_buffer =
            [device newBufferWithLength:f16_download_buffer_length options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_f16_download_buffer =
            [adapter_device newBufferWithLength:f16_download_buffer_length options:MTLResourceStorageModeShared];
        if (native_f16_download_buffer != nil) memset(native_f16_download_buffer.contents, 0xab,
                                                       native_f16_download_buffer.length);
        if (adapter_f16_download_buffer != nil) memset(adapter_f16_download_buffer.contents, 0xab,
                                                        adapter_f16_download_buffer.length);
        const MTLOrigin f16_source_origin = MTLOriginMake(1, 1, 1);
        id<MTLCommandBuffer> native_f16_download_command_buffer = [queue commandBuffer];
        id<MTLBlitCommandEncoder> native_f16_download_blit =
            [native_f16_download_command_buffer blitCommandEncoder];
        [native_f16_download_blit copyFromTexture:native_f16_three_d
                                       sourceSlice:0 sourceLevel:0 sourceOrigin:f16_source_origin
                                       sourceSize:f16_copy_size toBuffer:native_f16_download_buffer
                                  destinationOffset:f16_download_offset
                             destinationBytesPerRow:f16_copy_row_stride
                           destinationBytesPerImage:f16_copy_image_stride];
        [native_f16_download_blit endEncoding];
        [native_f16_download_command_buffer commit];
        [native_f16_download_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_f16_download_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_f16_download_blit =
            [adapter_f16_download_command_buffer blitCommandEncoder];
        [adapter_f16_download_blit copyFromTexture:adapter_f16_three_d
                                        sourceSlice:0 sourceLevel:0 sourceOrigin:f16_source_origin
                                        sourceSize:f16_copy_size toBuffer:adapter_f16_download_buffer
                                   destinationOffset:f16_download_offset
                              destinationBytesPerRow:f16_copy_row_stride
                            destinationBytesPerImage:f16_copy_image_stride];
        [adapter_f16_download_blit endEncoding];
        [adapter_f16_download_command_buffer commit];
        [adapter_f16_download_command_buffer waitUntilCompleted];
        if (native_f16_three_d == nil || adapter_f16_three_d == nil ||
            native_f16_upload_buffer == nil || adapter_f16_upload_buffer == nil ||
            native_f16_download_buffer == nil || adapter_f16_download_buffer == nil ||
            native_f16_upload_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_f16_upload_command_buffer.status != MTLCommandBufferStatusCompleted ||
            native_f16_download_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_f16_download_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(native_f16_three_d_bytes, adapter_f16_three_d_bytes, sizeof(native_f16_three_d_bytes)) != 0 ||
            memcmp(native_f16_download_buffer.contents, adapter_f16_download_buffer.contents,
                   f16_download_buffer_length) != 0) {
            fprintf(stderr, "metal-pixel: RGBA16Float 3D padded blit exactness failed\n");
            return 87;
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
             "kernel void zpu_cpu_fill_gradient_rgba8_3d() {}\n"
             "[[visible]] float4 zpu_test_visible(float4 value) { return value; }\n"
             "[[visible]] float4 zpu_test_visible_secondary(float4 value) { return value + 1.0; }";
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
            adapter_library.functionNames.count != 6 ||
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_array"] == nil ||
            [adapter_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8_3d"] == nil ||
            [adapter_library newFunctionWithName:@"zpu_test_visible"].functionType != MTLFunctionTypeVisible ||
            [adapter_library newFunctionWithName:@"zpu_test_visible_secondary"].functionType != MTLFunctionTypeVisible ||
            !adapter_library_completion_called ||
            unsupported_adapter_library != nil || adapter_library_error == nil) {
            fail_with_error("CPU library/function metadata failed", adapter_library_error);
            return 50;
        }

        /* Dynamic libraries are CPU symbol packages. The adapter accepts the
         * same registered ZPU names, preserves the install name, and round
         * trips its own deterministic file format; no native Metal library
         * is created for this path. */
        BOOL adapter_dynamic_library_ok = YES;
        if (@available(macOS 11.0, iOS 14.0, *)) {
            MTLCompileOptions *adapter_dynamic_options = [MTLCompileOptions new];
            adapter_dynamic_options.libraryType = MTLLibraryTypeDynamic;
            adapter_dynamic_options.installName = @"@loader_path/zpu_cpu_dynamic.metallib";
            NSError *adapter_dynamic_error = nil;
            id<MTLLibrary> adapter_dynamic_source_library =
                [adapter_device newLibraryWithSource:adapter_cpu_source
                                             options:adapter_dynamic_options
                                               error:&adapter_dynamic_error];
            id<MTLDynamicLibrary> adapter_dynamic_library =
                [adapter_device newDynamicLibrary:adapter_dynamic_source_library error:&adapter_dynamic_error];
            NSURL *adapter_dynamic_url = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
            BOOL adapter_dynamic_serialized =
                [adapter_dynamic_library serializeToURL:adapter_dynamic_url error:&adapter_dynamic_error];
            id<MTLDynamicLibrary> adapter_dynamic_reloaded =
                [adapter_device newDynamicLibraryWithURL:adapter_dynamic_url error:&adapter_dynamic_error];
            adapter_dynamic_library_ok =
                adapter_dynamic_source_library != nil &&
                adapter_dynamic_source_library.type == MTLLibraryTypeDynamic &&
                [adapter_dynamic_source_library.installName isEqualToString:adapter_dynamic_options.installName] &&
                adapter_dynamic_library != nil &&
                [adapter_dynamic_library conformsToProtocol:@protocol(MTLDynamicLibrary)] &&
                adapter_dynamic_library.device == adapter_device &&
                [adapter_dynamic_library.installName isEqualToString:adapter_dynamic_options.installName] &&
                adapter_dynamic_serialized && adapter_dynamic_reloaded != nil &&
                adapter_dynamic_reloaded.device == adapter_device &&
                [adapter_dynamic_reloaded.installName isEqualToString:adapter_dynamic_options.installName];
            [[NSFileManager defaultManager] removeItemAtURL:adapter_dynamic_url error:nil];
        }
        if (!adapter_dynamic_library_ok) {
            fail_with_error("CPU dynamic library metadata failed", adapter_library_error);
            return 136;
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
        MTLComputePipelineDescriptor *adapter_default_stage_input_descriptor = [MTLComputePipelineDescriptor new];
        adapter_default_stage_input_descriptor.computeFunction = adapter_compute_function;
        NSError *adapter_default_stage_input_error = nil;
        id<MTLComputePipelineState> adapter_default_stage_input_pipeline =
            [adapter_device newComputePipelineStateWithDescriptor:adapter_default_stage_input_descriptor
                                                           options:0 reflection:nil
                                                              error:&adapter_default_stage_input_error];
        MTLComputePipelineDescriptor *adapter_configured_stage_input_descriptor = [MTLComputePipelineDescriptor new];
        adapter_configured_stage_input_descriptor.computeFunction = adapter_compute_function;
        MTLStageInputOutputDescriptor *adapter_stage_input_descriptor =
            [MTLStageInputOutputDescriptor stageInputOutputDescriptor];
        adapter_stage_input_descriptor.attributes[0].format = MTLAttributeFormatFloat4;
        adapter_stage_input_descriptor.layouts[0].stride = sizeof(float) * 4;
        adapter_configured_stage_input_descriptor.stageInputDescriptor = adapter_stage_input_descriptor;
        NSError *adapter_configured_stage_input_error = nil;
        id<MTLComputePipelineState> adapter_configured_stage_input_pipeline =
            [adapter_device newComputePipelineStateWithDescriptor:adapter_configured_stage_input_descriptor
                                                           options:0 reflection:nil
                                                              error:&adapter_configured_stage_input_error];
        if (adapter_default_stage_input_pipeline == nil || adapter_default_stage_input_error != nil ||
            adapter_configured_stage_input_pipeline != nil || adapter_configured_stage_input_error == nil) {
            fail_with_error("CPU compute stage-input descriptor validation failed",
                            adapter_default_stage_input_error ?: adapter_configured_stage_input_error);
            return 147;
        }
        MTLComputePipelineDescriptor *adapter_compute_link_descriptor = [MTLComputePipelineDescriptor new];
        adapter_compute_link_descriptor.computeFunction = adapter_compute_function;
        adapter_compute_link_descriptor.supportAddingBinaryFunctions = YES;
        MTLLinkedFunctions *adapter_linked_functions = [MTLLinkedFunctions new];
        adapter_linked_functions.functions = @[[adapter_library newFunctionWithName:@"zpu_test_visible"]];
        adapter_compute_link_descriptor.linkedFunctions = adapter_linked_functions;
        id<MTLComputePipelineState> adapter_compute_pipeline =
            [adapter_device newComputePipelineStateWithDescriptor:adapter_compute_link_descriptor
                                                            options:0 reflection:nil error:&adapter_compute_error];
        /* Additional binary functions remain CPU-side metadata. The linked
         * state reuses the same ZPU kernel and records the extra registered
         * callable names so function handles stay device-scoped. Native Metal
         * is queried only for the matching output oracle. */
        BOOL adapter_compute_link_ok = YES;
        id<MTLComputePipelineState> native_linked_compute_pipeline = nil;
        id<MTLComputePipelineState> adapter_linked_compute_pipeline = nil;
        id<MTLFunctionHandle> adapter_prelinked_function_handle = nil;
        id<MTLFunctionHandle> adapter_linked_function_handle = nil;
        uint8_t native_linked_compute_pixels[byte_count] = {0};
        uint8_t adapter_linked_compute_pixels[byte_count] = {0};
        NSError *native_link_error = nil;
        NSError *adapter_link_error = nil;
        if (@available(macOS 11.0, iOS 14.0, tvOS 16.0, *)) {
            MTLComputePipelineDescriptor *native_compute_link_descriptor = [MTLComputePipelineDescriptor new];
            native_compute_link_descriptor.computeFunction = native_compute_function;
            native_compute_link_descriptor.supportAddingBinaryFunctions = YES;
            MTLLinkedFunctions *native_linked_functions = [MTLLinkedFunctions new];
            native_linked_functions.functions = @[[library newFunctionWithName:@"zpu_test_visible"]];
            native_compute_link_descriptor.linkedFunctions = native_linked_functions;
            id<MTLComputePipelineState> native_compute_link_pipeline =
                [device newComputePipelineStateWithDescriptor:native_compute_link_descriptor
                                                        options:0 reflection:nil error:&native_link_error];
            MTLFunctionDescriptor *native_additional_function_descriptor = [MTLFunctionDescriptor new];
            native_additional_function_descriptor.name = @"zpu_test_visible_secondary";
            native_additional_function_descriptor.options = MTLFunctionOptionCompileToBinary;
            id<MTLFunction> native_additional_compute_function =
                [library newFunctionWithDescriptor:native_additional_function_descriptor error:&native_link_error];
            id<MTLFunction> adapter_additional_compute_function =
                [adapter_library newFunctionWithName:@"zpu_test_visible_secondary"];
            native_linked_compute_pipeline =
                [native_compute_link_pipeline newComputePipelineStateWithAdditionalBinaryFunctions:@[
                    native_additional_compute_function] error:&native_link_error];
            adapter_linked_compute_pipeline =
                [adapter_compute_pipeline newComputePipelineStateWithAdditionalBinaryFunctions:@[
                    adapter_additional_compute_function] error:&adapter_link_error];
            adapter_prelinked_function_handle =
                [adapter_compute_pipeline functionHandleWithFunction:
                    [adapter_library newFunctionWithName:@"zpu_test_visible"]];
            adapter_linked_function_handle =
                [adapter_linked_compute_pipeline functionHandleWithFunction:adapter_additional_compute_function];
            id<MTLTexture> native_linked_compute_texture = nil;
            id<MTLCommandBuffer> native_linked_compute_command_buffer = nil;
            id<MTLComputeCommandEncoder> native_linked_compute_encoder = nil;
            if (native_linked_compute_pipeline != nil) {
                native_linked_compute_texture = [device newTextureWithDescriptor:compute_texture_descriptor];
                native_linked_compute_command_buffer = [queue commandBuffer];
                native_linked_compute_encoder =
                    [native_linked_compute_command_buffer computeCommandEncoder];
            }
            if (native_linked_compute_pipeline != nil && native_linked_compute_texture != nil &&
                native_linked_compute_command_buffer != nil && native_linked_compute_encoder != nil) {
                [native_linked_compute_encoder setComputePipelineState:native_linked_compute_pipeline];
                [native_linked_compute_encoder setTexture:native_linked_compute_texture atIndex:0];
                [native_linked_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                          threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [native_linked_compute_encoder endEncoding];
                [native_linked_compute_command_buffer commit];
                [native_linked_compute_command_buffer waitUntilCompleted];
                [native_linked_compute_texture getBytes:native_linked_compute_pixels
                                             bytesPerRow:(NSUInteger)width * 4
                                              fromRegion:MTLRegionMake2D(0, 0, width, height)
                                             mipmapLevel:0];
            }
            id<MTLTexture> adapter_linked_compute_texture = nil;
            id<MTLCommandBuffer> adapter_linked_compute_command_buffer = nil;
            id<MTLComputeCommandEncoder> adapter_linked_compute_encoder = nil;
            if (adapter_linked_compute_pipeline != nil) {
                adapter_linked_compute_texture =
                    [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
                adapter_linked_compute_command_buffer = [adapter_queue commandBuffer];
                adapter_linked_compute_encoder =
                    [adapter_linked_compute_command_buffer computeCommandEncoder];
            }
            if (adapter_linked_compute_pipeline != nil && adapter_linked_compute_texture != nil &&
                adapter_linked_compute_command_buffer != nil && adapter_linked_compute_encoder != nil) {
                [adapter_linked_compute_encoder setComputePipelineState:adapter_linked_compute_pipeline];
                [adapter_linked_compute_encoder setTexture:adapter_linked_compute_texture atIndex:0];
                [adapter_linked_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                           threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
                [adapter_linked_compute_encoder endEncoding];
                [adapter_linked_compute_command_buffer commit];
                [adapter_linked_compute_command_buffer waitUntilCompleted];
                [adapter_linked_compute_texture getBytes:adapter_linked_compute_pixels
                                              bytesPerRow:(NSUInteger)width * 4
                                               fromRegion:MTLRegionMake2D(0, 0, width, height)
                                              mipmapLevel:0];
                adapter_compute_link_ok =
                    adapter_linked_compute_command_buffer.status == MTLCommandBufferStatusCompleted;
            } else {
                adapter_compute_link_ok = NO;
            }
            adapter_compute_link_ok = adapter_compute_link_ok &&
                native_linked_compute_pipeline != nil && adapter_prelinked_function_handle != nil &&
                adapter_linked_function_handle != nil &&
                memcmp(native_linked_compute_pixels, adapter_linked_compute_pixels, byte_count) == 0;
        }
        MTLComputePipelineReflection *native_legacy_compute_reflection = nil;
        MTLComputePipelineReflection *adapter_legacy_compute_reflection = nil;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            [device newComputePipelineStateWithFunction:native_compute_function
                                                 options:MTLPipelineOptionBindingInfo
                                              reflection:&native_legacy_compute_reflection
                                                   error:&error];
            [adapter_device newComputePipelineStateWithFunction:adapter_compute_function
                                                         options:MTLPipelineOptionBindingInfo
                                                      reflection:&adapter_legacy_compute_reflection
                                                           error:&adapter_compute_error];
        }
        const BOOL adapter_legacy_compute_reflection_ok =
            adapter_legacy_compute_reflection != nil &&
            adapter_legacy_compute_reflection.bindings.count == 1 &&
            [adapter_legacy_compute_reflection.bindings[0].name isEqualToString:@"output"] &&
            adapter_legacy_compute_reflection.bindings[0].type == MTLBindingTypeTexture &&
            adapter_legacy_compute_reflection.bindings[0].access == MTLBindingAccessWriteOnly &&
            (native_legacy_compute_reflection == nil ||
             (native_legacy_compute_reflection.bindings.count == 1 &&
              native_legacy_compute_reflection.bindings[0].type == MTLBindingTypeTexture));
        if (@available(macOS 26.0, iOS 26.0, *)) {
            if (!adapter_legacy_compute_reflection_ok) {
                fail_with_error("legacy CPU compute pipeline reflection failed", adapter_compute_error);
                return 135;
            }
        }
        id<MTLLibrary> adapter_default_library = [adapter_device newDefaultLibrary];
        id<MTLFunction> adapter_default_compute_function =
            [adapter_default_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLArgumentEncoder> adapter_non_argument_buffer_encoder =
            [adapter_compute_function newArgumentEncoderWithBufferIndex:0];
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
            adapter_compute_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_compute_command_buffer.GPUStartTime <= 0.0 ||
            adapter_compute_command_buffer.GPUEndTime < adapter_compute_command_buffer.GPUStartTime ||
            adapter_compute_command_buffer.kernelStartTime <= 0.0 ||
            adapter_compute_command_buffer.kernelEndTime < adapter_compute_command_buffer.kernelStartTime ||
            adapter_non_argument_buffer_encoder != nil || !adapter_compute_link_ok) {
            if (!adapter_compute_link_ok) {
                fprintf(stderr, "metal-pixel: compute pipeline link probe native=%p adapter=%p handle=%p first=%u/%u native_error=%s adapter_error=%s\n",
                        native_linked_compute_pipeline, adapter_linked_compute_pipeline,
                        adapter_linked_function_handle, native_linked_compute_pixels[0],
                        adapter_linked_compute_pixels[0],
                        native_link_error.localizedDescription == nil ? "(null)" :
                        native_link_error.localizedDescription.UTF8String,
                        adapter_link_error.localizedDescription == nil ? "(null)" :
                        adapter_link_error.localizedDescription.UTF8String);
            }
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

        /* Every CPU adapter resource is scoped to the device that created
         * it. Cross-device buffers and events must be rejected before their
         * opaque ZPU pointers can reach an encoder. */
        id<MTLDevice> foreign_adapter_device = ZPUMetalCreateSystemDefaultDevice();
        id<MTLBuffer> foreign_adapter_buffer =
            [foreign_adapter_device newBufferWithBytes:vertices length:sizeof(vertices)
                                                options:MTLResourceStorageModeShared];
        const uint32_t foreign_compute_range_words[] = {0, 0};
        id<MTLBuffer> foreign_compute_range_buffer =
            [foreign_adapter_device newBufferWithBytes:foreign_compute_range_words
                                                length:sizeof(foreign_compute_range_words)
                                               options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> foreign_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> foreign_compute_encoder =
            [foreign_compute_command_buffer computeCommandEncoder];
        [foreign_compute_encoder setComputePipelineState:adapter_compute_pipeline];
        [foreign_compute_encoder setBuffer:foreign_adapter_buffer offset:0 atIndex:0];
        [foreign_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                              threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [foreign_compute_encoder endEncoding];
        [foreign_compute_command_buffer commit];
        [foreign_compute_command_buffer waitUntilCompleted];

        MTLIndirectCommandBufferDescriptor *foreign_compute_icb_descriptor =
            [MTLIndirectCommandBufferDescriptor new];
        foreign_compute_icb_descriptor.commandTypes = MTLIndirectCommandTypeConcurrentDispatchThreads;
        foreign_compute_icb_descriptor.maxKernelBufferBindCount = 1;
        id<MTLIndirectCommandBuffer> foreign_compute_icb =
            [foreign_adapter_device newIndirectCommandBufferWithDescriptor:foreign_compute_icb_descriptor
                                                            maxCommandCount:1 options:0];
        id<MTLIndirectCommandBuffer> adapter_foreign_range_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:foreign_compute_icb_descriptor
                                                     maxCommandCount:1 options:0];
        id<MTLFence> foreign_compute_fence = [foreign_adapter_device newFence];
        id<MTLCommandBuffer> foreign_compute_state_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> foreign_compute_state_encoder =
            [foreign_compute_state_command_buffer computeCommandEncoder];
        [foreign_compute_state_encoder setComputePipelineState:adapter_compute_pipeline];
        [foreign_compute_state_encoder updateFence:foreign_compute_fence];
        [foreign_compute_state_encoder executeCommandsInBuffer:foreign_compute_icb withRange:NSMakeRange(0, 1)];
        [foreign_compute_state_encoder endEncoding];
        [foreign_compute_state_command_buffer commit];
        [foreign_compute_state_command_buffer waitUntilCompleted];

        id<MTLCommandBuffer> foreign_indirect_dispatch_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> foreign_indirect_dispatch_encoder =
            [foreign_indirect_dispatch_command_buffer computeCommandEncoder];
        [foreign_indirect_dispatch_encoder setComputePipelineState:adapter_compute_pipeline];
        [foreign_indirect_dispatch_encoder dispatchThreadgroupsWithIndirectBuffer:foreign_adapter_buffer
                                                                 indirectBufferOffset:0
                                                               threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [foreign_indirect_dispatch_encoder endEncoding];
        [foreign_indirect_dispatch_command_buffer commit];
        [foreign_indirect_dispatch_command_buffer waitUntilCompleted];

        id<MTLCommandBuffer> foreign_indirect_icb_range_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> foreign_indirect_icb_range_encoder =
            [foreign_indirect_icb_range_command_buffer computeCommandEncoder];
        [foreign_indirect_icb_range_encoder executeCommandsInBuffer:adapter_foreign_range_icb
                                                    indirectBuffer:foreign_compute_range_buffer
                                               indirectBufferOffset:0];
        [foreign_indirect_icb_range_encoder endEncoding];
        [foreign_indirect_icb_range_command_buffer commit];
        [foreign_indirect_icb_range_command_buffer waitUntilCompleted];

        id<MTLTexture> foreign_render_texture = [adapter_device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *foreign_render_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        foreign_render_pass.colorAttachments[0].texture = foreign_render_texture;
        foreign_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        foreign_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        MTLHeapDescriptor *foreign_heap_descriptor = [MTLHeapDescriptor new];
        foreign_heap_descriptor.size = 4096;
        id<MTLHeap> foreign_adapter_heap = [foreign_adapter_device newHeapWithDescriptor:foreign_heap_descriptor];
        id<MTLCommandBuffer> foreign_use_resource_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> foreign_use_resource_encoder =
            [foreign_use_resource_command_buffer renderCommandEncoderWithDescriptor:foreign_render_pass];
        [foreign_use_resource_encoder setRenderPipelineState:adapter_pipeline];
        [foreign_use_resource_encoder useResource:foreign_adapter_buffer
                                           usage:MTLResourceUsageRead
                                           stages:MTLRenderStageVertex];
        [foreign_use_resource_encoder endEncoding];
        [foreign_use_resource_command_buffer commit];
        [foreign_use_resource_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> foreign_use_heap_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> foreign_use_heap_encoder =
            [foreign_use_heap_command_buffer renderCommandEncoderWithDescriptor:foreign_render_pass];
        [foreign_use_heap_encoder setRenderPipelineState:adapter_pipeline];
        [foreign_use_heap_encoder useHeap:foreign_adapter_heap stages:MTLRenderStageVertex];
        [foreign_use_heap_encoder endEncoding];
        [foreign_use_heap_command_buffer commit];
        [foreign_use_heap_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> foreign_render_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> foreign_render_encoder =
            [foreign_render_command_buffer renderCommandEncoderWithDescriptor:foreign_render_pass];
        [foreign_render_encoder setRenderPipelineState:adapter_pipeline];
        [foreign_render_encoder setVertexBuffer:foreign_adapter_buffer offset:0 atIndex:0];
        [foreign_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [foreign_render_encoder endEncoding];
        [foreign_render_command_buffer commit];
        [foreign_render_command_buffer waitUntilCompleted];

        id<MTLBuffer> foreign_blit_destination =
            [adapter_device newBufferWithLength:sizeof(vertices) options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> foreign_blit_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> foreign_blit_encoder = [foreign_blit_command_buffer blitCommandEncoder];
        [foreign_blit_encoder copyFromBuffer:foreign_adapter_buffer sourceOffset:0
                                     toBuffer:foreign_blit_destination destinationOffset:0 size:sizeof(vertices)];
        [foreign_blit_encoder endEncoding];
        [foreign_blit_command_buffer commit];
        [foreign_blit_command_buffer waitUntilCompleted];

        id<MTLSharedEvent> foreign_adapter_event = [foreign_adapter_device newSharedEvent];
        id<MTLCommandBuffer> foreign_event_command_buffer = [adapter_queue commandBuffer];
        [foreign_event_command_buffer encodeSignalEvent:foreign_adapter_event value:1];
        [foreign_event_command_buffer commit];
        [foreign_event_command_buffer waitUntilCompleted];
        if (foreign_adapter_device == nil || foreign_adapter_buffer == nil ||
            foreign_compute_range_buffer == nil ||
            foreign_compute_encoder == nil ||
            foreign_compute_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_compute_icb == nil || adapter_foreign_range_icb == nil || foreign_compute_fence == nil ||
            foreign_compute_state_encoder == nil ||
            foreign_compute_state_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_indirect_dispatch_encoder == nil ||
            foreign_indirect_dispatch_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_indirect_icb_range_encoder == nil ||
            foreign_indirect_icb_range_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_render_texture == nil || foreign_render_encoder == nil ||
            foreign_render_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_adapter_heap == nil || foreign_use_resource_encoder == nil ||
            foreign_use_resource_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_use_heap_encoder == nil ||
            foreign_use_heap_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_blit_destination == nil || foreign_blit_encoder == nil ||
            foreign_blit_command_buffer.status != MTLCommandBufferStatusError ||
            foreign_adapter_event == nil ||
            foreign_event_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: cross-device resource ownership did not fail closed\n");
            return 131;
        }

        /* The bounded ZPU compute ABI has no threadgroup-memory or imageblock
         * storage. Reject non-zero requests instead of running a kernel with
         * different memory semantics. */
        id<MTLTexture> unsupported_compute_texture = [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> unsupported_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> unsupported_compute_encoder =
            [unsupported_compute_command_buffer computeCommandEncoder];
        [unsupported_compute_encoder setComputePipelineState:adapter_compute_pipeline];
        [unsupported_compute_encoder setTexture:unsupported_compute_texture atIndex:0];
        [unsupported_compute_encoder setThreadgroupMemoryLength:16 atIndex:0];
        [unsupported_compute_encoder setImageblockWidth:1 height:1];
        [unsupported_compute_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [unsupported_compute_encoder endEncoding];
        [unsupported_compute_command_buffer commit];
        [unsupported_compute_command_buffer waitUntilCompleted];
        if (unsupported_compute_texture == nil || unsupported_compute_encoder == nil ||
            unsupported_compute_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: unsupported CPU compute memory did not fail closed\n");
            return 132;
        }

        /* The fixed ZPU vertex ABI has no vertex texture or sampler inputs.
         * These bindings must poison the command rather than being retained
         * and silently ignored by the CPU rasterizer. */
        id<MTLCommandBuffer> unsupported_vertex_resource_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> unsupported_vertex_resource_encoder =
            [unsupported_vertex_resource_command_buffer renderCommandEncoderWithDescriptor:adapter_pass];
        [unsupported_vertex_resource_encoder setRenderPipelineState:adapter_pipeline];
        [unsupported_vertex_resource_encoder setVertexTexture:adapter_sample_source atIndex:0];
        [unsupported_vertex_resource_encoder setVertexSamplerState:adapter_sample_sampler atIndex:0];
        [unsupported_vertex_resource_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [unsupported_vertex_resource_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [unsupported_vertex_resource_encoder endEncoding];
        [unsupported_vertex_resource_command_buffer commit];
        [unsupported_vertex_resource_command_buffer waitUntilCompleted];
        if (unsupported_vertex_resource_encoder == nil ||
            unsupported_vertex_resource_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: unsupported CPU vertex resources did not fail closed\n");
            return 133;
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
        BOOL adapter_mtl4_dynamic_library_ok = YES;
        id<MTLDynamicLibrary> adapter_mtl4_dynamic_reloaded = nil;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTLCompileOptions *adapter_mtl4_dynamic_options = [MTLCompileOptions new];
            adapter_mtl4_dynamic_options.libraryType = MTLLibraryTypeDynamic;
            adapter_mtl4_dynamic_options.installName = @"@loader_path/zpu_cpu_mtl4_dynamic.metallib";
            MTL4LibraryDescriptor *adapter_mtl4_dynamic_descriptor = [MTL4LibraryDescriptor new];
            adapter_mtl4_dynamic_descriptor.source = adapter_mtl4_library_descriptor.source;
            adapter_mtl4_dynamic_descriptor.options = adapter_mtl4_dynamic_options;
            id<MTLLibrary> adapter_mtl4_dynamic_source_library =
                [adapter_mtl4_compiler newLibraryWithDescriptor:adapter_mtl4_dynamic_descriptor
                                                           error:&adapter_mtl4_compiler_error];
            id<MTLDynamicLibrary> adapter_mtl4_dynamic_library =
                [adapter_mtl4_compiler newDynamicLibrary:adapter_mtl4_dynamic_source_library
                                                    error:&adapter_mtl4_compiler_error];
            NSURL *adapter_mtl4_dynamic_url = [NSURL fileURLWithPath:
                [NSTemporaryDirectory() stringByAppendingPathComponent:[[NSUUID UUID] UUIDString]]];
            BOOL adapter_mtl4_dynamic_serialized =
                [adapter_mtl4_dynamic_library serializeToURL:adapter_mtl4_dynamic_url
                                                        error:&adapter_mtl4_compiler_error];
            adapter_mtl4_dynamic_reloaded =
                [adapter_mtl4_compiler newDynamicLibraryWithURL:adapter_mtl4_dynamic_url
                                                           error:&adapter_mtl4_compiler_error];
            adapter_mtl4_dynamic_library_ok =
                adapter_mtl4_dynamic_source_library != nil &&
                adapter_mtl4_dynamic_source_library.type == MTLLibraryTypeDynamic &&
                adapter_mtl4_dynamic_library != nil &&
                adapter_mtl4_dynamic_library.device == adapter_device &&
                [adapter_mtl4_dynamic_library.installName isEqualToString:adapter_mtl4_dynamic_options.installName] &&
                adapter_mtl4_dynamic_serialized && adapter_mtl4_dynamic_reloaded != nil &&
                adapter_mtl4_dynamic_reloaded.device == adapter_device &&
                [adapter_mtl4_dynamic_reloaded.installName isEqualToString:adapter_mtl4_dynamic_options.installName];
            [[NSFileManager defaultManager] removeItemAtURL:adapter_mtl4_dynamic_url error:nil];
        }
        MTLFunctionReflection *adapter_mtl4_function_reflection = nil;
        MTLFunctionReflection *adapter_mtl4_no_raster_reflection = nil;
        MTLFunctionReflection *native_function_reflection = nil;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            adapter_mtl4_function_reflection =
                [adapter_mtl4_library reflectionForFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
            adapter_mtl4_no_raster_reflection =
                [adapter_mtl4_library reflectionForFunctionWithName:@"zpu_test_no_raster_vertex"];
            native_function_reflection =
                [library reflectionForFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        }
        MTL4LibraryFunctionDescriptor *adapter_mtl4_function_descriptor = [MTL4LibraryFunctionDescriptor new];
        adapter_mtl4_function_descriptor.name = @"zpu_cpu_fill_gradient_rgba8";
        adapter_mtl4_function_descriptor.library = adapter_mtl4_library;
        MTL4ComputePipelineDescriptor *adapter_mtl4_compute_descriptor = [MTL4ComputePipelineDescriptor new];
        adapter_mtl4_compute_descriptor.computeFunctionDescriptor = adapter_mtl4_function_descriptor;
        adapter_mtl4_compute_descriptor.maxTotalThreadsPerThreadgroup = 64;
        adapter_mtl4_compute_descriptor.requiredThreadsPerThreadgroup = MTLSizeMake(8, 8, 1);
        adapter_mtl4_compute_descriptor.supportBinaryLinking = YES;
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
        adapter_mtl4_render_descriptor.supportVertexBinaryLinking = YES;
        adapter_mtl4_render_descriptor.supportFragmentBinaryLinking = YES;
        adapter_mtl4_render_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        NSError *adapter_mtl4_render_error = nil;
        NSError *adapter_mtl4_dynamic_error = nil;
        id<MTLRenderPipelineState> adapter_mtl4_compiled_render_pipeline =
            [adapter_mtl4_compiler newRenderPipelineStateWithDescriptor:adapter_mtl4_render_descriptor
                                                        compilerTaskOptions:nil
                                                                      error:&adapter_mtl4_render_error];
        id<MTLRenderPipelineState> adapter_mtl4_unspecialized_render_pipeline = nil;
        id<MTLRenderPipelineState> adapter_mtl4_specialized_render_pipeline = nil;
        BOOL adapter_mtl4_specialization_ok = YES;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTL4RenderPipelineDescriptor *adapter_mtl4_unspecialized_render_descriptor =
                [adapter_mtl4_render_descriptor copy];
            adapter_mtl4_unspecialized_render_descriptor.colorAttachments[0].blendingState =
                MTL4BlendStateUnspecialized;
            adapter_mtl4_unspecialized_render_pipeline =
                [adapter_mtl4_compiler newRenderPipelineStateWithDescriptor:
                    adapter_mtl4_unspecialized_render_descriptor compilerTaskOptions:nil
                    error:&adapter_mtl4_dynamic_error];
            MTL4RenderPipelineDescriptor *adapter_mtl4_specialized_render_descriptor =
                [adapter_mtl4_unspecialized_render_descriptor copy];
            adapter_mtl4_specialized_render_descriptor.colorAttachments[0].blendingState =
                MTL4BlendStateEnabled;
            adapter_mtl4_specialized_render_pipeline =
                [adapter_mtl4_compiler newRenderPipelineStateBySpecializationWithDescriptor:
                    adapter_mtl4_specialized_render_descriptor
                    pipeline:adapter_mtl4_unspecialized_render_pipeline error:&adapter_mtl4_dynamic_error];
            adapter_mtl4_specialization_ok = adapter_mtl4_unspecialized_render_pipeline != nil &&
                adapter_mtl4_specialized_render_pipeline != nil;
        }
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
        id<MTL4BinaryFunction> adapter_mtl4_additional_binary_function = nil;
        id<MTLComputePipelineState> adapter_mtl4_binary_linked_pipeline = nil;
        id<MTLFunctionHandle> adapter_mtl4_binary_linked_handle = nil;
        id<MTLComputePipelineState> adapter_mtl4_dynamic_compute_pipeline = nil;
        id<MTLFunctionHandle> adapter_mtl4_dynamic_compute_handle = nil;
        BOOL adapter_mtl4_binary_link_ok = YES;
        BOOL adapter_mtl4_dynamic_compute_ok = YES;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTL4LibraryFunctionDescriptor *adapter_mtl4_additional_function_descriptor =
                [MTL4LibraryFunctionDescriptor new];
            adapter_mtl4_additional_function_descriptor.name =
                @"zpu_test_visible_secondary";
            adapter_mtl4_additional_function_descriptor.library = adapter_mtl4_library;
            MTL4BinaryFunctionDescriptor *adapter_mtl4_additional_binary_descriptor =
                [MTL4BinaryFunctionDescriptor new];
            adapter_mtl4_additional_binary_descriptor.name =
                @"zpu_test_visible_secondary";
            adapter_mtl4_additional_binary_descriptor.functionDescriptor =
                adapter_mtl4_additional_function_descriptor;
            adapter_mtl4_additional_binary_descriptor.options = MTL4BinaryFunctionOptionPipelineIndependent;
            adapter_mtl4_additional_binary_function =
                [adapter_mtl4_compiler newBinaryFunctionWithDescriptor:
                    adapter_mtl4_additional_binary_descriptor compilerTaskOptions:nil
                    error:&adapter_mtl4_compiler_error];
            if (adapter_mtl4_additional_binary_function != nil && adapter_mtl4_compiled_pipeline != nil) {
                adapter_mtl4_binary_linked_pipeline =
                    [adapter_mtl4_compiled_pipeline newComputePipelineStateWithBinaryFunctions:@[
                        adapter_mtl4_additional_binary_function] error:&adapter_mtl4_compiler_error];
                adapter_mtl4_binary_linked_handle =
                    [adapter_mtl4_binary_linked_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_additional_binary_function];
            }
            adapter_mtl4_binary_link_ok = adapter_mtl4_additional_binary_function != nil &&
                adapter_mtl4_binary_linked_pipeline != nil && adapter_mtl4_binary_linked_handle != nil;
            if (adapter_mtl4_additional_binary_function != nil) {
                MTL4PipelineStageDynamicLinkingDescriptor *adapter_mtl4_compute_dynamic_linking =
                    [MTL4PipelineStageDynamicLinkingDescriptor new];
                adapter_mtl4_compute_dynamic_linking.binaryLinkedFunctions = @[
                    adapter_mtl4_additional_binary_function];
                adapter_mtl4_compute_dynamic_linking.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_dynamic_compute_pipeline =
                    [adapter_mtl4_compiler newComputePipelineStateWithDescriptor:adapter_mtl4_compute_descriptor
                        dynamicLinkingDescriptor:adapter_mtl4_compute_dynamic_linking compilerTaskOptions:nil
                        error:&adapter_mtl4_dynamic_error];
                adapter_mtl4_dynamic_compute_handle =
                    [adapter_mtl4_dynamic_compute_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_additional_binary_function];
                adapter_mtl4_dynamic_compute_ok = adapter_mtl4_dynamic_compute_pipeline != nil &&
                    adapter_mtl4_dynamic_compute_handle != nil;
            }
        }
        id<MTLFunctionHandle> adapter_mtl4_binary_handle =
            [adapter_device functionHandleWithBinaryFunction:adapter_mtl4_binary_function];
        id<MTLFunction> adapter_mtl4_compiler_function =
            [adapter_mtl4_library newFunctionWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLFunctionHandle> adapter_mtl4_named_handle =
            [adapter_mtl4_compiled_pipeline functionHandleWithName:@"zpu_cpu_fill_gradient_rgba8"];
        id<MTLFunctionHandle> adapter_mtl4_function_handle =
            [adapter_mtl4_compiled_pipeline functionHandleWithFunction:adapter_mtl4_compiler_function];
        MTL4BinaryFunctionDescriptor *adapter_mtl4_render_binary_descriptor = [MTL4BinaryFunctionDescriptor new];
        adapter_mtl4_render_binary_descriptor.name = @"zpu_test_fragment";
        adapter_mtl4_render_binary_descriptor.functionDescriptor = adapter_mtl4_fragment_descriptor;
        adapter_mtl4_render_binary_descriptor.options = MTL4BinaryFunctionOptionPipelineIndependent;
        id<MTL4BinaryFunction> adapter_mtl4_render_binary_function =
            [adapter_mtl4_compiler newBinaryFunctionWithDescriptor:adapter_mtl4_render_binary_descriptor
                                                   compilerTaskOptions:nil
                                                                 error:&adapter_mtl4_compiler_error];
        id<MTL4BinaryFunction> adapter_mtl4_render_additional_binary_function = nil;
        id<MTLRenderPipelineState> adapter_mtl4_binary_render_linked_pipeline = nil;
        id<MTLFunctionHandle> adapter_mtl4_binary_render_fragment_handle = nil;
        id<MTLRenderPipelineState> adapter_mtl4_dynamic_render_pipeline = nil;
        id<MTLFunctionHandle> adapter_mtl4_dynamic_render_fragment_handle = nil;
        BOOL adapter_mtl4_render_binary_link_ok = YES;
        BOOL adapter_mtl4_dynamic_render_ok = YES;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTL4LibraryFunctionDescriptor *adapter_mtl4_render_additional_function_descriptor =
                [MTL4LibraryFunctionDescriptor new];
            adapter_mtl4_render_additional_function_descriptor.name = @"zpu_test_visible_secondary";
            adapter_mtl4_render_additional_function_descriptor.library = adapter_mtl4_library;
            MTL4BinaryFunctionDescriptor *adapter_mtl4_render_additional_binary_descriptor =
                [MTL4BinaryFunctionDescriptor new];
            adapter_mtl4_render_additional_binary_descriptor.name = @"zpu_test_visible_secondary";
            adapter_mtl4_render_additional_binary_descriptor.functionDescriptor =
                adapter_mtl4_render_additional_function_descriptor;
            adapter_mtl4_render_additional_binary_descriptor.options = MTL4BinaryFunctionOptionPipelineIndependent;
            adapter_mtl4_render_additional_binary_function =
                [adapter_mtl4_compiler newBinaryFunctionWithDescriptor:
                    adapter_mtl4_render_additional_binary_descriptor compilerTaskOptions:nil
                    error:&adapter_mtl4_compiler_error];
            MTL4RenderPipelineBinaryFunctionsDescriptor *adapter_mtl4_render_binary_functions =
                [MTL4RenderPipelineBinaryFunctionsDescriptor new];
            if (adapter_mtl4_render_additional_binary_function != nil &&
                adapter_mtl4_compiled_render_pipeline != nil) {
                adapter_mtl4_render_binary_functions.vertexAdditionalBinaryFunctions = @[
                    adapter_mtl4_render_additional_binary_function];
                adapter_mtl4_render_binary_functions.fragmentAdditionalBinaryFunctions = @[
                    adapter_mtl4_render_additional_binary_function];
                adapter_mtl4_binary_render_linked_pipeline =
                    [adapter_mtl4_compiled_render_pipeline newRenderPipelineStateWithBinaryFunctions:
                        adapter_mtl4_render_binary_functions error:&adapter_mtl4_compiler_error];
                adapter_mtl4_binary_render_fragment_handle =
                    [adapter_mtl4_binary_render_linked_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_render_additional_binary_function stage:MTLRenderStageFragment];
            }
            adapter_mtl4_render_binary_link_ok = adapter_mtl4_render_additional_binary_function != nil &&
                adapter_mtl4_binary_render_linked_pipeline != nil &&
                adapter_mtl4_binary_render_fragment_handle != nil;
            if (adapter_mtl4_render_additional_binary_function != nil) {
                MTL4RenderPipelineDynamicLinkingDescriptor *adapter_mtl4_render_dynamic_linking =
                    [MTL4RenderPipelineDynamicLinkingDescriptor new];
                adapter_mtl4_render_dynamic_linking.vertexLinkingDescriptor.binaryLinkedFunctions = @[
                    adapter_mtl4_render_additional_binary_function];
                adapter_mtl4_render_dynamic_linking.vertexLinkingDescriptor.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_render_dynamic_linking.fragmentLinkingDescriptor.binaryLinkedFunctions = @[
                    adapter_mtl4_render_additional_binary_function];
                adapter_mtl4_render_dynamic_linking.fragmentLinkingDescriptor.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_dynamic_render_pipeline =
                    [adapter_mtl4_compiler newRenderPipelineStateWithDescriptor:adapter_mtl4_render_descriptor
                        dynamicLinkingDescriptor:adapter_mtl4_render_dynamic_linking compilerTaskOptions:nil
                        error:&adapter_mtl4_dynamic_error];
                adapter_mtl4_dynamic_render_fragment_handle =
                    [adapter_mtl4_dynamic_render_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_render_additional_binary_function stage:MTLRenderStageFragment];
                adapter_mtl4_dynamic_render_ok = adapter_mtl4_dynamic_render_pipeline != nil &&
                    adapter_mtl4_dynamic_render_fragment_handle != nil;
            }
        }
        id<MTLFunctionHandle> adapter_mtl4_render_binary_handle = nil;
        id<MTLFunctionHandle> adapter_mtl4_render_function_handle = nil;
        id<MTLFunctionHandle> adapter_device_function_handle = nil;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            adapter_device_function_handle = [adapter_device functionHandleWithFunction:adapter_fragment_function];
        }
        if (@available(macOS 12.0, iOS 15.0, *)) {
            adapter_mtl4_render_function_handle =
                [adapter_mtl4_compiled_render_pipeline functionHandleWithFunction:adapter_fragment_function
                                                                               stage:MTLRenderStageFragment];
            adapter_mtl4_render_binary_handle =
                [adapter_mtl4_compiled_render_pipeline functionHandleWithBinaryFunction:adapter_mtl4_render_binary_function
                                                                                      stage:MTLRenderStageFragment];
        }
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
        id<MTL4BinaryFunction> adapter_mtl4_archive_visible_binary = nil;
        id<MTLComputePipelineState> adapter_mtl4_archive_dynamic_compute_pipeline = nil;
        id<MTLRenderPipelineState> adapter_mtl4_archive_dynamic_render_pipeline = nil;
        id<MTLFunctionHandle> adapter_mtl4_archive_dynamic_compute_handle = nil;
        id<MTLFunctionHandle> adapter_mtl4_archive_dynamic_render_fragment_handle = nil;
        BOOL adapter_mtl4_archive_dynamic_ok = YES;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTL4LibraryFunctionDescriptor *adapter_mtl4_archive_visible_function_descriptor =
                [MTL4LibraryFunctionDescriptor new];
            adapter_mtl4_archive_visible_function_descriptor.name = @"zpu_test_visible_secondary";
            adapter_mtl4_archive_visible_function_descriptor.library = adapter_mtl4_library;
            MTL4BinaryFunctionDescriptor *adapter_mtl4_archive_visible_binary_descriptor =
                [MTL4BinaryFunctionDescriptor new];
            adapter_mtl4_archive_visible_binary_descriptor.name = @"zpu_test_visible_secondary";
            adapter_mtl4_archive_visible_binary_descriptor.functionDescriptor =
                adapter_mtl4_archive_visible_function_descriptor;
            adapter_mtl4_archive_visible_binary_descriptor.options = MTL4BinaryFunctionOptionPipelineIndependent;
            adapter_mtl4_archive_visible_binary =
                [adapter_mtl4_serializer_archive newBinaryFunctionWithDescriptor:
                    adapter_mtl4_archive_visible_binary_descriptor error:&adapter_mtl4_dynamic_error];
            if (adapter_mtl4_archive_visible_binary != nil && adapter_mtl4_serializer_archive != nil) {
                MTL4PipelineStageDynamicLinkingDescriptor *adapter_mtl4_archive_compute_dynamic_linking =
                    [MTL4PipelineStageDynamicLinkingDescriptor new];
                adapter_mtl4_archive_compute_dynamic_linking.binaryLinkedFunctions = @[
                    adapter_mtl4_archive_visible_binary];
                adapter_mtl4_archive_compute_dynamic_linking.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_archive_dynamic_compute_pipeline =
                    [adapter_mtl4_serializer_archive newComputePipelineStateWithDescriptor:
                        adapter_mtl4_compute_descriptor dynamicLinkingDescriptor:
                        adapter_mtl4_archive_compute_dynamic_linking error:&adapter_mtl4_dynamic_error];
                adapter_mtl4_archive_dynamic_compute_handle =
                    [adapter_mtl4_archive_dynamic_compute_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_archive_visible_binary];
                MTL4RenderPipelineDynamicLinkingDescriptor *adapter_mtl4_archive_render_dynamic_linking =
                    [MTL4RenderPipelineDynamicLinkingDescriptor new];
                adapter_mtl4_archive_render_dynamic_linking.vertexLinkingDescriptor.binaryLinkedFunctions = @[
                    adapter_mtl4_archive_visible_binary];
                adapter_mtl4_archive_render_dynamic_linking.vertexLinkingDescriptor.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_archive_render_dynamic_linking.fragmentLinkingDescriptor.binaryLinkedFunctions = @[
                    adapter_mtl4_archive_visible_binary];
                adapter_mtl4_archive_render_dynamic_linking.fragmentLinkingDescriptor.preloadedLibraries =
                    adapter_mtl4_dynamic_reloaded == nil ? @[] : @[adapter_mtl4_dynamic_reloaded];
                adapter_mtl4_archive_dynamic_render_pipeline =
                    [adapter_mtl4_serializer_archive newRenderPipelineStateWithDescriptor:
                        adapter_mtl4_render_descriptor dynamicLinkingDescriptor:
                        adapter_mtl4_archive_render_dynamic_linking error:&adapter_mtl4_dynamic_error];
                adapter_mtl4_archive_dynamic_render_fragment_handle =
                    [adapter_mtl4_archive_dynamic_render_pipeline functionHandleWithBinaryFunction:
                        adapter_mtl4_archive_visible_binary stage:MTLRenderStageFragment];
            }
            adapter_mtl4_archive_dynamic_ok = adapter_mtl4_archive_visible_binary != nil &&
                adapter_mtl4_archive_dynamic_compute_pipeline != nil &&
                adapter_mtl4_archive_dynamic_compute_handle != nil &&
                adapter_mtl4_archive_dynamic_render_pipeline != nil &&
                adapter_mtl4_archive_dynamic_render_fragment_handle != nil;
        }
        [[NSFileManager defaultManager] removeItemAtURL:adapter_mtl4_serializer_url error:nil];
        id<MTLTexture> adapter_mtl4_compiler_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> adapter_mtl4_compiler_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> adapter_mtl4_compiler_encoder =
            [adapter_mtl4_compiler_command_buffer computeCommandEncoder];
        [adapter_mtl4_compiler_encoder setComputePipelineState:
            adapter_mtl4_dynamic_compute_pipeline ?: adapter_mtl4_binary_linked_pipeline ?: adapter_mtl4_compiled_pipeline];
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
        id<MTLTexture> adapter_mtl4_archive_dynamic_texture = nil;
        id<MTLCommandBuffer> adapter_mtl4_archive_dynamic_command_buffer = nil;
        uint8_t adapter_mtl4_archive_dynamic_pixels[byte_count] = {0};
        if (adapter_mtl4_archive_dynamic_compute_pipeline != nil) {
            adapter_mtl4_archive_dynamic_texture =
                [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
            adapter_mtl4_archive_dynamic_command_buffer = [adapter_queue commandBuffer];
            id<MTLComputeCommandEncoder> adapter_mtl4_archive_dynamic_encoder =
                [adapter_mtl4_archive_dynamic_command_buffer computeCommandEncoder];
            [adapter_mtl4_archive_dynamic_encoder setComputePipelineState:
                adapter_mtl4_archive_dynamic_compute_pipeline];
            [adapter_mtl4_archive_dynamic_encoder setTexture:adapter_mtl4_archive_dynamic_texture atIndex:0];
            [adapter_mtl4_archive_dynamic_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                              threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
            [adapter_mtl4_archive_dynamic_encoder endEncoding];
            [adapter_mtl4_archive_dynamic_command_buffer commit];
            [adapter_mtl4_archive_dynamic_command_buffer waitUntilCompleted];
            [adapter_mtl4_archive_dynamic_texture getBytes:adapter_mtl4_archive_dynamic_pixels
                                                bytesPerRow:(NSUInteger)width * 4
                                                 fromRegion:MTLRegionMake2D(0, 0, width, height)
                                                mipmapLevel:0];
        }
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
        [adapter_mtl4_compiler_render_encoder setRenderPipelineState:
            adapter_mtl4_dynamic_render_pipeline ?: adapter_mtl4_binary_render_linked_pipeline ?: adapter_mtl4_compiled_render_pipeline];
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
        id<MTLTexture> adapter_mtl4_specialized_render_texture = nil;
        id<MTLCommandBuffer> adapter_mtl4_specialized_render_command_buffer = nil;
        uint8_t adapter_mtl4_specialized_render_pixels[byte_count] = {0};
        if (adapter_mtl4_specialized_render_pipeline != nil) {
            adapter_mtl4_specialized_render_texture =
                [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
            MTLRenderPassDescriptor *adapter_mtl4_specialized_render_pass =
                [MTLRenderPassDescriptor renderPassDescriptor];
            adapter_mtl4_specialized_render_pass.colorAttachments[0].texture =
                adapter_mtl4_specialized_render_texture;
            adapter_mtl4_specialized_render_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            adapter_mtl4_specialized_render_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            adapter_mtl4_specialized_render_pass.colorAttachments[0].clearColor =
                MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
            adapter_mtl4_specialized_render_command_buffer = [adapter_queue commandBuffer];
            id<MTLRenderCommandEncoder> adapter_mtl4_specialized_render_encoder =
                [adapter_mtl4_specialized_render_command_buffer
                    renderCommandEncoderWithDescriptor:adapter_mtl4_specialized_render_pass];
            [adapter_mtl4_specialized_render_encoder setRenderPipelineState:
                adapter_mtl4_specialized_render_pipeline];
            [adapter_mtl4_specialized_render_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
            [adapter_mtl4_specialized_render_encoder drawPrimitives:MTLPrimitiveTypeTriangle
                                                            vertexStart:0 vertexCount:6];
            [adapter_mtl4_specialized_render_encoder endEncoding];
            [adapter_mtl4_specialized_render_command_buffer commit];
            [adapter_mtl4_specialized_render_command_buffer waitUntilCompleted];
            [adapter_mtl4_specialized_render_texture getBytes:adapter_mtl4_specialized_render_pixels
                                                    bytesPerRow:(NSUInteger)width * 4
                                                     fromRegion:MTLRegionMake2D(0, 0, width, height)
                                                    mipmapLevel:0];
        }
        MTLComputePipelineReflection *adapter_mtl4_compute_reflection =
            adapter_mtl4_compiled_pipeline.reflection;
        MTLRenderPipelineReflection *adapter_mtl4_render_reflection =
            adapter_mtl4_compiled_render_pipeline.reflection;
        MTLComputePipelineReflection *native_compute_reflection = nil;
        MTLRenderPipelineReflection *native_render_reflection = nil;
        [device newComputePipelineStateWithFunction:native_compute_function
                                             options:MTLPipelineOptionBindingInfo
                                          reflection:&native_compute_reflection
                                               error:&error];
        [device newRenderPipelineStateWithDescriptor:pipeline_descriptor
                                              options:MTLPipelineOptionBindingInfo
                                           reflection:&native_render_reflection
                                                error:&error];
        if (adapter_mtl4_serializer == nil ||
            ![adapter_mtl4_serializer conformsToProtocol:@protocol(MTL4PipelineDataSetSerializer)] ||
            adapter_mtl4_pipeline_script.length == 0 || !adapter_mtl4_archive_flushed ||
            adapter_mtl4_serializer_archive == nil || adapter_mtl4_serializer_binary == nil ||
            adapter_mtl4_compiler == nil || adapter_mtl4_library == nil ||
            !adapter_mtl4_dynamic_library_ok ||
            adapter_mtl4_function_reflection == nil ||
            adapter_mtl4_function_reflection.bindings.count != 1 ||
            ![adapter_mtl4_function_reflection.bindings[0].name isEqualToString:@"output"] ||
            adapter_mtl4_function_reflection.bindings[0].type != MTLBindingTypeTexture ||
            adapter_mtl4_no_raster_reflection == nil ||
            adapter_mtl4_no_raster_reflection.bindings.count != 0 ||
            (native_function_reflection != nil && native_function_reflection.bindings.count != 1) ||
            adapter_mtl4_compiled_pipeline == nil || adapter_mtl4_compiled_render_pipeline == nil ||
            adapter_mtl4_archived_render_pipeline == nil || adapter_mtl4_binary_function == nil ||
            !adapter_mtl4_binary_link_ok || !adapter_mtl4_render_binary_link_ok ||
            !adapter_mtl4_dynamic_compute_ok || !adapter_mtl4_dynamic_render_ok ||
            !adapter_mtl4_archive_dynamic_ok || !adapter_mtl4_specialization_ok ||
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
            (adapter_mtl4_archive_dynamic_compute_pipeline != nil &&
             (adapter_mtl4_archive_dynamic_texture == nil ||
              adapter_mtl4_archive_dynamic_command_buffer == nil ||
              adapter_mtl4_archive_dynamic_command_buffer.status != MTLCommandBufferStatusCompleted ||
              memcmp(native_compute_pixels, adapter_mtl4_archive_dynamic_pixels, byte_count) != 0)) ||
            adapter_mtl4_compiler_render_texture == nil || adapter_mtl4_compiler_render_encoder == nil ||
            adapter_mtl4_compiler_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
            (adapter_mtl4_specialized_render_pipeline != nil &&
             (adapter_mtl4_specialized_render_texture == nil ||
              adapter_mtl4_specialized_render_command_buffer == nil ||
              adapter_mtl4_specialized_render_command_buffer.status != MTLCommandBufferStatusCompleted ||
              memcmp(metal_pixels, adapter_mtl4_specialized_render_pixels, byte_count) != 0)) ||
            adapter_mtl4_compute_reflection == nil ||
            adapter_mtl4_compute_reflection.bindings.count != 1 ||
            ![adapter_mtl4_compute_reflection.bindings[0].name isEqualToString:@"output"] ||
            adapter_mtl4_compute_reflection.bindings[0].type != MTLBindingTypeTexture ||
            adapter_mtl4_compute_reflection.bindings[0].access != MTLBindingAccessWriteOnly ||
            adapter_mtl4_render_reflection == nil ||
            adapter_mtl4_render_reflection.vertexBindings.count != 1 ||
            ![adapter_mtl4_render_reflection.vertexBindings[0].name isEqualToString:@"vertices"] ||
            adapter_mtl4_render_reflection.vertexBindings[0].type != MTLBindingTypeBuffer ||
            adapter_mtl4_render_reflection.vertexBindings[0].access != MTLBindingAccessReadOnly ||
            adapter_mtl4_render_reflection.fragmentBindings.count != 0 ||
            (native_compute_reflection != nil && native_compute_reflection.bindings.count != 1) ||
            (native_render_reflection != nil && native_render_reflection.vertexBindings.count != 1) ||
            memcmp(metal_pixels, adapter_mtl4_compiler_render_pixels, byte_count) != 0 ||
            memcmp(native_compute_pixels, adapter_mtl4_compiler_pixels, byte_count) != 0) {
            if (!adapter_mtl4_dynamic_compute_ok || !adapter_mtl4_dynamic_render_ok ||
                !adapter_mtl4_archive_dynamic_ok || !adapter_mtl4_specialization_ok) {
                fprintf(stderr, "metal-pixel: Metal 4 dynamic/specialization failed compute=%d render=%d archive=%d specialization=%d compute_pipeline=%p render_pipeline=%p archive_compute=%p archive_render=%p error=%s\n",
                        adapter_mtl4_dynamic_compute_ok, adapter_mtl4_dynamic_render_ok,
                        adapter_mtl4_archive_dynamic_ok, adapter_mtl4_specialization_ok,
                        adapter_mtl4_dynamic_compute_pipeline,
                        adapter_mtl4_dynamic_render_pipeline, adapter_mtl4_archive_dynamic_compute_pipeline,
                        adapter_mtl4_archive_dynamic_render_pipeline,
                        adapter_mtl4_dynamic_error.localizedDescription == nil ? "(null)" :
                        adapter_mtl4_dynamic_error.localizedDescription.UTF8String);
            }
            fail_with_error("Metal 4 CPU compiler compute path failed", adapter_mtl4_compiler_error);
            return 101;
        }

        /* Function tables retain CPU-side handles/resources only. The native
         * table and handle below are an API/oracle probe; no native object is
         * passed into the adapter and no native table participates in ZPU
         * execution. */
        id<MTLVisibleFunctionTable> native_visible_function_table = nil;
        id<MTLFunctionHandle> native_visible_function_handle = nil;
        if (@available(macOS 12.0, iOS 15.0, *)) {
            MTLVisibleFunctionTableDescriptor *native_visible_descriptor = [MTLVisibleFunctionTableDescriptor new];
            native_visible_descriptor.functionCount = 2;
            native_visible_function_table =
                [pipeline newVisibleFunctionTableWithDescriptor:native_visible_descriptor
                                                          stage:MTLRenderStageFragment];
            native_visible_function_handle =
                [pipeline functionHandleWithFunction:fragment_function stage:MTLRenderStageFragment];
            if (native_visible_function_table != nil && native_visible_function_handle != nil) {
                [native_visible_function_table setFunction:native_visible_function_handle atIndex:0];
            }
        }
        MTLVisibleFunctionTableDescriptor *adapter_visible_descriptor = [MTLVisibleFunctionTableDescriptor new];
        adapter_visible_descriptor.functionCount = 4;
        id<MTLVisibleFunctionTable> adapter_visible_function_table =
            [adapter_mtl4_compiled_pipeline newVisibleFunctionTableWithDescriptor:adapter_visible_descriptor];
        id<MTLFunctionHandle> adapter_table_handle = adapter_mtl4_render_function_handle;
        id<MTLFunctionHandle> adapter_table_handles[] = {adapter_table_handle, nil};
        [adapter_visible_function_table setFunction:adapter_table_handle atIndex:0];
        [adapter_visible_function_table setFunctions:adapter_table_handles withRange:NSMakeRange(1, 2)];
        adapter_visible_function_table.label = @"zpu-cpu-visible-functions";

        MTLIntersectionFunctionTableDescriptor *adapter_intersection_descriptor =
            [MTLIntersectionFunctionTableDescriptor new];
        adapter_intersection_descriptor.functionCount = 2;
        id<MTLIntersectionFunctionTable> adapter_intersection_function_table =
            [adapter_mtl4_compiled_pipeline newIntersectionFunctionTableWithDescriptor:adapter_intersection_descriptor];
        id<MTLBuffer> adapter_table_buffers[] = {adapter_vertex_buffer, nil};
        NSUInteger adapter_table_offsets[] = {0, 16};
        id<MTLFunctionHandle> adapter_intersection_handles[] = {adapter_table_handle, nil};
        [adapter_intersection_function_table setBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_intersection_function_table setBuffers:adapter_table_buffers
                                                offsets:adapter_table_offsets
                                              withRange:NSMakeRange(0, 2)];
        [adapter_intersection_function_table setFunction:adapter_table_handle atIndex:0];
        [adapter_intersection_function_table setFunctions:adapter_intersection_handles withRange:NSMakeRange(0, 2)];
        [adapter_intersection_function_table
            setOpaqueTriangleIntersectionFunctionWithSignature:MTLIntersectionFunctionSignatureTriangleData
                                                       atIndex:0];
        [adapter_intersection_function_table
            setOpaqueCurveIntersectionFunctionWithSignature:MTLIntersectionFunctionSignatureWorldSpaceData
                                                     withRange:NSMakeRange(0, 2)];
        [adapter_intersection_function_table setVisibleFunctionTable:adapter_visible_function_table atBufferIndex:0];
        adapter_intersection_function_table.label = @"zpu-cpu-intersection-functions";
        BOOL adapter_function_handle_ids_ok = YES;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            adapter_function_handle_ids_ok = adapter_mtl4_render_function_handle.gpuResourceID._impl != 0 &&
                adapter_mtl4_binary_render_fragment_handle.gpuResourceID._impl != 0 &&
                adapter_mtl4_binary_handle.gpuResourceID._impl != 0 &&
                adapter_device_function_handle.gpuResourceID._impl != 0;
        }
        if (adapter_visible_function_table == nil ||
            ![adapter_visible_function_table conformsToProtocol:@protocol(MTLVisibleFunctionTable)] ||
            adapter_visible_function_table.device != adapter_device ||
            adapter_visible_function_table.allocatedSize < 4 * sizeof(uint64_t) ||
            adapter_visible_function_table.gpuResourceID._impl == 0 ||
            adapter_intersection_function_table == nil ||
            ![adapter_intersection_function_table conformsToProtocol:@protocol(MTLIntersectionFunctionTable)] ||
            adapter_intersection_function_table.device != adapter_device ||
            adapter_intersection_function_table.allocatedSize < 2 * sizeof(uint64_t) ||
            adapter_intersection_function_table.gpuResourceID._impl == 0 ||
            !adapter_function_handle_ids_ok ||
            adapter_mtl4_render_function_handle == nil ||
            adapter_mtl4_render_binary_handle == nil ||
            adapter_device_function_handle == nil ||
            adapter_device_function_handle.functionType != MTLFunctionTypeFragment ||
            adapter_mtl4_render_function_handle.functionType != MTLFunctionTypeFragment ||
            ![adapter_mtl4_render_function_handle.name isEqualToString:@"zpu_test_fragment"] ||
            ![adapter_mtl4_render_binary_handle.name isEqualToString:@"zpu_test_fragment"]) {
            fprintf(stderr, "metal-pixel: CPU function table layer failed\n");
            return 102;
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

        /* Metal 4 acceleration commands share the CPU-owned storage and
         * descriptor-size model of the legacy acceleration encoder. Native
         * Metal is not used for this operation; only the earlier render and
         * compute paths use it as a byte oracle. */
        MTL4PrimitiveAccelerationStructureDescriptor *metal4_as_descriptor =
            [MTL4PrimitiveAccelerationStructureDescriptor new];
        metal4_as_descriptor.geometryDescriptors = @[];
        MTLAccelerationStructureSizes metal4_as_sizes =
            [adapter_device accelerationStructureSizesWithDescriptor:metal4_as_descriptor];
        const NSUInteger metal4_as_size = metal4_as_sizes.accelerationStructureSize;
        id<MTLAccelerationStructure> metal4_as =
            [adapter_device newAccelerationStructureWithSize:metal4_as_size];
        id<MTLAccelerationStructure> metal4_as_copy =
            [adapter_device newAccelerationStructureWithSize:metal4_as_size];
        const NSUInteger metal4_compacted_size = metal4_as_size / 2 == 0 ? 1 : metal4_as_size / 2;
        id<MTLAccelerationStructure> metal4_as_compact =
            [adapter_device newAccelerationStructureWithSize:metal4_compacted_size];
        id<MTLBuffer> metal4_as_scratch = [adapter_device newBufferWithLength:
            metal4_as_sizes.buildScratchBufferSize == 0 ? 1 : metal4_as_sizes.buildScratchBufferSize
                                                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> metal4_as_status =
            [adapter_device newBufferWithLength:sizeof(uint64_t) options:MTLResourceStorageModeShared];
        id<MTL4CommandBuffer> metal4_as_command_buffer = [adapter_device newCommandBuffer];
        [metal4_as_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_as_encoder = [metal4_as_command_buffer computeCommandEncoder];
        [metal4_as_encoder buildAccelerationStructure:metal4_as descriptor:metal4_as_descriptor
                                         scratchBuffer:MTL4BufferRangeMake(metal4_as_scratch.gpuAddress,
                                                                            metal4_as_scratch.length)];
        [metal4_as_encoder refitAccelerationStructure:metal4_as descriptor:metal4_as_descriptor
                                           destination:nil
                                         scratchBuffer:MTL4BufferRangeMake(metal4_as_scratch.gpuAddress,
                                                                            metal4_as_scratch.length)];
        [metal4_as_encoder writeCompactedAccelerationStructureSize:metal4_as
                                                          toBuffer:MTL4BufferRangeMake(metal4_as_status.gpuAddress,
                                                                                        metal4_as_status.length)];
        [metal4_as_encoder copyAccelerationStructure:metal4_as toAccelerationStructure:metal4_as_copy];
        [metal4_as_encoder copyAndCompactAccelerationStructure:metal4_as
                                       toAccelerationStructure:metal4_as_compact];
        const MTLStages metal4_as_stages = metal4_as_encoder.stages;
        [metal4_as_encoder endEncoding];
        [metal4_as_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_as_command_buffers[] = {metal4_as_command_buffer};
        MTL4CommitOptions *metal4_as_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *metal4_as_error = nil;
        [metal4_as_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            metal4_as_error = feedback.error;
        }];
        [metal4_queue commit:metal4_as_command_buffers count:1 options:metal4_as_options];
        uint64_t metal4_as_compacted_value = 0;
        if (metal4_as_status != nil) memcpy(&metal4_as_compacted_value, metal4_as_status.contents,
                                            sizeof(metal4_as_compacted_value));
        if (metal4_as_size == 0 || metal4_as == nil || metal4_as_copy == nil || metal4_as_compact == nil ||
            metal4_as_scratch == nil || metal4_as_status == nil || metal4_as_command_buffer == nil ||
            metal4_as_encoder == nil || metal4_as_error != nil ||
            (metal4_as_stages & MTLStageAccelerationStructure) == 0 ||
            metal4_as_compacted_value != metal4_compacted_size) {
            fail_with_error("Metal 4 CPU acceleration commands failed", metal4_as_error);
            return 66;
        }

        /* GPU addresses are only meaningful for resources owned by the
         * device that records the command. A native buffer is used here only
         * to supply a foreign address; it is never submitted to native Metal
         * and must be rejected by the CPU adapter. */
        id<MTLBuffer> native_foreign_address_buffer =
            [device newBufferWithLength:sizeof(uint32_t) options:MTLResourceStorageModeShared];
        id<MTL4CommandBuffer> metal4_foreign_address_command_buffer = [adapter_device newCommandBuffer];
        [metal4_foreign_address_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_foreign_address_encoder =
            [metal4_foreign_address_command_buffer computeCommandEncoder];
        [metal4_foreign_address_encoder dispatchThreadgroupsWithIndirectBuffer:native_foreign_address_buffer.gpuAddress
                                                        threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        [metal4_foreign_address_encoder endEncoding];
        [metal4_foreign_address_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_foreign_address_command_buffers[] = {
            metal4_foreign_address_command_buffer,
        };
        MTL4CommitOptions *metal4_foreign_address_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *metal4_foreign_address_error = nil;
        [metal4_foreign_address_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            metal4_foreign_address_error = feedback.error;
        }];
        [metal4_queue commit:metal4_foreign_address_command_buffers
                        count:1
                       options:metal4_foreign_address_options];
        if (native_foreign_address_buffer == nil || metal4_foreign_address_command_buffer == nil ||
            metal4_foreign_address_encoder == nil || metal4_foreign_address_error == nil) {
            fail_with_error("Metal 4 CPU adapter accepted a foreign GPU address", metal4_error);
            return 61;
        }

        /* An otherwise empty argument table is still scoped to its creating
         * device. This catches a foreign-table handoff before any resource
         * ID happens to make the ownership violation visible. */
        MTL4ArgumentTableDescriptor *foreign_metal4_table_descriptor = [MTL4ArgumentTableDescriptor new];
        id<MTL4ArgumentTable> foreign_metal4_table =
            [foreign_adapter_device newArgumentTableWithDescriptor:foreign_metal4_table_descriptor error:&metal4_error];
        id<MTL4CommandBuffer> foreign_metal4_table_command_buffer = [adapter_device newCommandBuffer];
        [foreign_metal4_table_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> foreign_metal4_table_encoder =
            [foreign_metal4_table_command_buffer computeCommandEncoder];
        [foreign_metal4_table_encoder setComputePipelineState:adapter_compute_pipeline];
        [foreign_metal4_table_encoder setArgumentTable:foreign_metal4_table];
        [foreign_metal4_table_encoder dispatchThreads:MTLSizeMake(width, height, 1)
                                  threadsPerThreadgroup:MTLSizeMake(8, 8, 1)];
        [foreign_metal4_table_encoder endEncoding];
        [foreign_metal4_table_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> foreign_metal4_table_command_buffers[] = {
            foreign_metal4_table_command_buffer,
        };
        MTL4CommitOptions *foreign_metal4_table_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *foreign_metal4_table_error = nil;
        [foreign_metal4_table_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            foreign_metal4_table_error = feedback.error;
        }];
        [metal4_queue commit:foreign_metal4_table_command_buffers
                        count:1
                       options:foreign_metal4_table_options];
        if (foreign_metal4_table == nil || foreign_metal4_table_command_buffer == nil ||
            foreign_metal4_table_encoder == nil || foreign_metal4_table_error == nil) {
            fail_with_error("Metal 4 CPU adapter accepted a foreign argument table", metal4_error);
            return 63;
        }

        /* MTL4 copy commands must apply the same device ownership rule as
         * argument tables and GPU-address dispatch. */
        id<MTL4CommandBuffer> foreign_metal4_copy_command_buffer = [adapter_device newCommandBuffer];
        [foreign_metal4_copy_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> foreign_metal4_copy_encoder =
            [foreign_metal4_copy_command_buffer computeCommandEncoder];
        [foreign_metal4_copy_encoder copyFromBuffer:foreign_adapter_buffer sourceOffset:0
                                           toBuffer:adapter_copy_buffer destinationOffset:0 size:sizeof(uint32_t)];
        [foreign_metal4_copy_encoder endEncoding];
        [foreign_metal4_copy_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> foreign_metal4_copy_command_buffers[] = {
            foreign_metal4_copy_command_buffer,
        };
        MTL4CommitOptions *foreign_metal4_copy_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *foreign_metal4_copy_error = nil;
        [foreign_metal4_copy_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            foreign_metal4_copy_error = feedback.error;
        }];
        [metal4_queue commit:foreign_metal4_copy_command_buffers
                        count:1
                       options:foreign_metal4_copy_options];
        if (foreign_metal4_copy_command_buffer == nil || foreign_metal4_copy_encoder == nil ||
            foreign_metal4_copy_error == nil) {
            fail_with_error("Metal 4 CPU adapter accepted a foreign copy resource", metal4_error);
            return 64;
        }

        /* The ML encoder must be a CPU-owned object even though arbitrary ML
         * graph execution is not implemented. Its dispatch path must report
         * an error through Metal 4 feedback instead of returning nil or
         * reaching Apple's native Metal runtime. */
        id<MTL4CommandBuffer> metal4_ml_command_buffer = [adapter_device newCommandBuffer];
        [metal4_ml_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4MachineLearningCommandEncoder> metal4_ml_encoder =
            [metal4_ml_command_buffer machineLearningCommandEncoder];
        [metal4_ml_encoder setArgumentTable:metal4_table];
        [metal4_ml_encoder dispatchNetworkWithIntermediatesHeap:adapter_three_d_heap];
        [metal4_ml_encoder endEncoding];
        [metal4_ml_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_ml_command_buffers[] = {metal4_ml_command_buffer};
        MTL4CommitOptions *metal4_ml_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *metal4_ml_error = nil;
        [metal4_ml_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            metal4_ml_error = feedback.error;
        }];
        [metal4_queue commit:metal4_ml_command_buffers count:1 options:metal4_ml_options];
        if (metal4_ml_command_buffer == nil || metal4_ml_encoder == nil ||
            ![metal4_ml_encoder conformsToProtocol:@protocol(MTL4MachineLearningCommandEncoder)] ||
            metal4_ml_error == nil) {
            fail_with_error("Metal 4 CPU ML encoder did not fail closed", metal4_error);
            return 62;
        }

        /* Placement-sparse buffers use CPU-owned physical pages. The native
         * Metal sparse implementation is not used for this path; its only
         * role in this test suite is to define the page-size and mapping
         * contract that the adapter mirrors. A mapped page must round-trip
         * through ordinary ZPU copies, copied mappings must alias the same
         * physical page, and an unmapped read must be zero. */
        const NSUInteger sparse_page_bytes_16 =
            [adapter_device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize16];
        const NSUInteger sparse_page_bytes =
            [adapter_device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize64];
        const NSUInteger sparse_page_bytes_256 =
            [adapter_device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize256];
        NSMutableData *sparse_input_data = [NSMutableData dataWithLength:sparse_page_bytes];
        for (NSUInteger index = 0; index < sparse_page_bytes; ++index) {
            ((uint8_t *)sparse_input_data.mutableBytes)[index] = (uint8_t)((index * 29u + 11u) & 0xffu);
        }
        const MTLTextureType sparse_texture_types[] = {
            MTLTextureType1D, MTLTextureType1DArray, MTLTextureType2D,
            MTLTextureType2DArray, MTLTextureType3D,
        };
        const MTLPixelFormat sparse_pixel_formats[] = {
            MTLPixelFormatRGBA8Unorm, MTLPixelFormatR32Float,
            MTLPixelFormatRGBA16Float, MTLPixelFormatStencil8,
            MTLPixelFormatDepth32Float,
        };
        const MTLSparsePageSize sparse_page_sizes[] = {
            MTLSparsePageSize16, MTLSparsePageSize64, MTLSparsePageSize256,
        };
        BOOL sparse_tile_exact = YES;
        for (NSUInteger texture_type_index = 0; texture_type_index < sizeof(sparse_texture_types) / sizeof(sparse_texture_types[0]); ++texture_type_index) {
            for (NSUInteger format_index = 0; format_index < sizeof(sparse_pixel_formats) / sizeof(sparse_pixel_formats[0]); ++format_index) {
                for (NSUInteger page_index = 0; page_index < sizeof(sparse_page_sizes) / sizeof(sparse_page_sizes[0]); ++page_index) {
                    MTLSize native_tile = [device sparseTileSizeWithTextureType:sparse_texture_types[texture_type_index]
                                                                       pixelFormat:sparse_pixel_formats[format_index]
                                                                       sampleCount:1 sparsePageSize:sparse_page_sizes[page_index]];
                    MTLSize adapter_tile = [adapter_device sparseTileSizeWithTextureType:sparse_texture_types[texture_type_index]
                                                                                  pixelFormat:sparse_pixel_formats[format_index]
                                                                                  sampleCount:1 sparsePageSize:sparse_page_sizes[page_index]];
                    sparse_tile_exact = sparse_tile_exact && native_tile.width == adapter_tile.width &&
                        native_tile.height == adapter_tile.height && native_tile.depth == adapter_tile.depth;
                }
            }
        }
        id<MTLHeap> sparse_heap = nil;
        id<MTLBuffer> sparse_source = nil;
        id<MTLBuffer> sparse_destination = nil;
        id<MTLBuffer> sparse_roundtrip = nil;
        id<MTLBuffer> sparse_output = nil;
        id<MTLBuffer> sparse_alias_output = nil;
        id<MTLBuffer> sparse_zero_output = nil;
        if (sparse_page_bytes_16 != 16u * 1024u || sparse_page_bytes != 64u * 1024u ||
            sparse_page_bytes_256 != 256u * 1024u ||
            [device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize16] != sparse_page_bytes_16 ||
            [device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize64] != sparse_page_bytes ||
            [device sparseTileSizeInBytesForSparsePageSize:MTLSparsePageSize256] != sparse_page_bytes_256 ||
            !sparse_tile_exact) {
            fprintf(stderr, "metal-pixel: CPU sparse page sizes are incorrect\n");
            return 85;
        }
        MTLHeapDescriptor *sparse_heap_descriptor = [MTLHeapDescriptor new];
        sparse_heap_descriptor.type = MTLHeapTypePlacement;
        sparse_heap_descriptor.size = sparse_page_bytes * 2;
        sparse_heap_descriptor.storageMode = MTLStorageModePrivate;
        sparse_heap_descriptor.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
        sparse_heap = [adapter_device newHeapWithDescriptor:sparse_heap_descriptor];
        sparse_source = [adapter_device newBufferWithLength:sparse_page_bytes
                                                    options:MTLResourceStorageModePrivate
                                   placementSparsePageSize:MTLSparsePageSize64];
        sparse_destination = [adapter_device newBufferWithLength:sparse_page_bytes
                                                         options:MTLResourceStorageModePrivate
                                        placementSparsePageSize:MTLSparsePageSize64];
        sparse_roundtrip = [adapter_device newBufferWithLength:sparse_page_bytes
                                                        options:MTLResourceStorageModePrivate
                                       placementSparsePageSize:MTLSparsePageSize64];
        sparse_output = [adapter_device newBufferWithLength:sparse_page_bytes
                                                     options:MTLResourceStorageModeShared];
        sparse_alias_output = [adapter_device newBufferWithLength:sparse_page_bytes
                                                           options:MTLResourceStorageModeShared];
        sparse_zero_output = [adapter_device newBufferWithLength:sparse_page_bytes
                                                          options:MTLResourceStorageModeShared];
        if (sparse_output != nil) memset(sparse_output.contents, 0, sparse_output.length);
        if (sparse_alias_output != nil) memset(sparse_alias_output.contents, 0xa5,
                                               sparse_alias_output.length);
        if (sparse_zero_output != nil) memset(sparse_zero_output.contents, 0xa5,
                                              sparse_zero_output.length);
        id<MTLBuffer> sparse_input =
            [adapter_device newBufferWithBytes:sparse_input_data.bytes
                                         length:sparse_input_data.length
                                        options:MTLResourceStorageModeShared];
        id<MTL4CommandQueue> metal4_sparse_queue = [adapter_device newMTL4CommandQueue];
        MTL4UpdateSparseBufferMappingOperation metal4_sparse_map_operation = {
            .mode = MTLSparseTextureMappingModeMap,
            .bufferRange = NSMakeRange(0, 1),
            .heapOffset = 0,
        };
        [metal4_sparse_queue updateBufferMappings:sparse_source
                                             heap:sparse_heap
                                        operations:&metal4_sparse_map_operation
                                             count:1];
        id<MTLCommandQueue> sparse_legacy_queue = [adapter_device newCommandQueue];
        id<MTLCommandBuffer> sparse_upload_command_buffer = [sparse_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> sparse_upload_encoder = [sparse_upload_command_buffer blitCommandEncoder];
        [sparse_upload_encoder copyFromBuffer:sparse_input sourceOffset:0
                                     toBuffer:sparse_source destinationOffset:0 size:sparse_page_bytes];
        [sparse_upload_encoder endEncoding];
        [sparse_upload_command_buffer commit];
        [sparse_upload_command_buffer waitUntilCompleted];
        MTL4CopySparseBufferMappingOperation metal4_sparse_copy_operation = {
            .sourceRange = NSMakeRange(0, 1),
            .destinationOffset = 0,
        };
        [metal4_sparse_queue copyBufferMappingsFromBuffer:sparse_source
                                                  toBuffer:sparse_source
                                                operations:&metal4_sparse_copy_operation
                                                     count:1];
        [metal4_sparse_queue copyBufferMappingsFromBuffer:sparse_source
                                                  toBuffer:sparse_destination
                                                operations:&metal4_sparse_copy_operation
                                                     count:1];
        id<MTLCommandBuffer> sparse_download_command_buffer = [sparse_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> sparse_download_encoder = [sparse_download_command_buffer blitCommandEncoder];
        [sparse_download_encoder copyFromBuffer:sparse_destination sourceOffset:0
                                       toBuffer:sparse_output destinationOffset:0 size:sparse_page_bytes];
        [sparse_download_encoder endEncoding];
        [sparse_download_command_buffer commit];
        [sparse_download_command_buffer waitUntilCompleted];
        MTL4UpdateSparseBufferMappingOperation metal4_sparse_unmap_operation = {
            .mode = MTLSparseTextureMappingModeUnmap,
            .bufferRange = NSMakeRange(0, 1),
            .heapOffset = 0,
        };
        [metal4_sparse_queue updateBufferMappings:sparse_source
                                             heap:nil
                                        operations:&metal4_sparse_unmap_operation
                                             count:1];
        [metal4_sparse_queue updateBufferMappings:sparse_destination
                                             heap:nil
                                        operations:&metal4_sparse_unmap_operation
                                             count:1];
        id<MTLCommandBuffer> sparse_zero_command_buffer = [sparse_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> sparse_zero_encoder = [sparse_zero_command_buffer blitCommandEncoder];
        [sparse_zero_encoder copyFromBuffer:sparse_source sourceOffset:0
                                    toBuffer:sparse_zero_output destinationOffset:0 size:sparse_page_bytes];
        [sparse_zero_encoder endEncoding];
        [sparse_zero_command_buffer commit];
        [sparse_zero_command_buffer waitUntilCompleted];
        [metal4_sparse_queue updateBufferMappings:sparse_roundtrip
                                             heap:sparse_heap
                                        operations:&metal4_sparse_map_operation
                                             count:1];
        id<MTLCommandBuffer> sparse_roundtrip_command_buffer = [sparse_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> sparse_roundtrip_encoder = [sparse_roundtrip_command_buffer blitCommandEncoder];
        [sparse_roundtrip_encoder copyFromBuffer:sparse_roundtrip sourceOffset:0
                                         toBuffer:sparse_alias_output destinationOffset:0 size:sparse_page_bytes];
        [sparse_roundtrip_encoder endEncoding];
        [sparse_roundtrip_command_buffer commit];
        [sparse_roundtrip_command_buffer waitUntilCompleted];
        BOOL sparse_zero_exact = sparse_zero_output != nil;
        if (sparse_zero_exact) {
            const uint8_t *bytes = sparse_zero_output.contents;
            for (NSUInteger index = 0; index < sparse_page_bytes; ++index) {
                if (bytes[index] != 0) {
                    sparse_zero_exact = NO;
                    break;
                }
            }
        }
        if (sparse_heap == nil || sparse_source == nil || sparse_destination == nil ||
            sparse_roundtrip == nil || sparse_input == nil || sparse_output == nil ||
            sparse_alias_output == nil || sparse_zero_output == nil || sparse_source.contents != nil ||
            sparse_destination.contents != nil || sparse_roundtrip.contents != nil ||
            sparse_upload_encoder == nil || sparse_download_encoder == nil ||
            sparse_zero_encoder == nil || sparse_roundtrip_encoder == nil ||
            sparse_upload_command_buffer.status != MTLCommandBufferStatusCompleted ||
            sparse_zero_command_buffer.status != MTLCommandBufferStatusCompleted ||
            sparse_download_command_buffer.status != MTLCommandBufferStatusCompleted ||
            sparse_roundtrip_command_buffer.status != MTLCommandBufferStatusCompleted ||
            !sparse_zero_exact ||
            memcmp(sparse_output.contents, sparse_input_data.bytes, sparse_page_bytes) != 0 ||
            memcmp(sparse_alias_output.contents, sparse_input_data.bytes, sparse_page_bytes) != 0) {
            fprintf(stderr, "metal-pixel: CPU placement-sparse buffer mapping exactness failed\n");
            return 86;
        }
        [metal4_sparse_queue updateBufferMappings:sparse_roundtrip
                                             heap:nil
                                        operations:&metal4_sparse_unmap_operation
                                             count:1];

        /* Placement-sparse textures use the same CPU-owned physical-page
         * store as sparse buffers. Native Metal is queried only for the
         * resource-property oracle; the adapter never routes this work to
         * Apple's command encoder. */
        const NSUInteger sparse_texture_width = sparse_page_bytes == 0 ? 0 : 256;
        const NSUInteger sparse_texture_height = 256;
        const NSUInteger sparse_texture_row_bytes = sparse_texture_width * 4;
        const NSUInteger sparse_texture_bytes = sparse_texture_row_bytes * sparse_texture_height;
        const NSUInteger sparse_texture_tile_bytes = 128 * 128 * 4;
        NSMutableData *sparse_texture_input_data = [NSMutableData dataWithLength:sparse_texture_tile_bytes];
        for (NSUInteger index = 0; index < sparse_texture_tile_bytes; ++index) {
            ((uint8_t *)sparse_texture_input_data.mutableBytes)[index] = (uint8_t)((index * 17u + 3u) & 0xffu);
        }
        MTLTextureDescriptor *native_sparse_texture_descriptor =
            [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                width:sparse_texture_width
                                                               height:sparse_texture_height
                                                            mipmapped:NO];
        native_sparse_texture_descriptor.storageMode = MTLStorageModePrivate;
        native_sparse_texture_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        native_sparse_texture_descriptor.placementSparsePageSize = MTLSparsePageSize64;
        MTLTextureDescriptor *adapter_sparse_texture_descriptor = [native_sparse_texture_descriptor copy];
        id<MTLTexture> native_sparse_texture = [device newTextureWithDescriptor:native_sparse_texture_descriptor];
        MTLHeapDescriptor *adapter_sparse_texture_heap_descriptor = [MTLHeapDescriptor new];
        adapter_sparse_texture_heap_descriptor.type = MTLHeapTypePlacement;
        adapter_sparse_texture_heap_descriptor.size = sparse_page_bytes * 2;
        adapter_sparse_texture_heap_descriptor.storageMode = MTLStorageModePrivate;
        adapter_sparse_texture_heap_descriptor.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
        id<MTLHeap> adapter_sparse_texture_heap = [adapter_device newHeapWithDescriptor:adapter_sparse_texture_heap_descriptor];
        id<MTLTexture> adapter_sparse_texture = [adapter_sparse_texture_heap newTextureWithDescriptor:adapter_sparse_texture_descriptor];
        id<MTLTexture> adapter_sparse_texture_copy = [adapter_sparse_texture_heap newTextureWithDescriptor:adapter_sparse_texture_descriptor];
        MTLTextureDescriptor *adapter_sparse_texture_tail_descriptor = [adapter_sparse_texture_descriptor copy];
        adapter_sparse_texture_tail_descriptor.mipmapLevelCount = 4;
        MTLTextureDescriptor *native_sparse_texture_tail_descriptor =
            [native_sparse_texture_descriptor copy];
        native_sparse_texture_tail_descriptor.mipmapLevelCount = 4;
        id<MTLTexture> native_sparse_texture_tail =
            [device newTextureWithDescriptor:native_sparse_texture_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_tail =
            [adapter_sparse_texture_heap newTextureWithDescriptor:adapter_sparse_texture_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_tail_copy =
            [adapter_sparse_texture_heap newTextureWithDescriptor:adapter_sparse_texture_tail_descriptor];
        MTLTextureDescriptor *native_sparse_texture_wide_tail_descriptor =
            [native_sparse_texture_descriptor copy];
        native_sparse_texture_wide_tail_descriptor.width = 1024;
        native_sparse_texture_wide_tail_descriptor.height = 64;
        native_sparse_texture_wide_tail_descriptor.mipmapLevelCount = 11;
        id<MTLTexture> native_sparse_texture_wide_tail =
            [device newTextureWithDescriptor:native_sparse_texture_wide_tail_descriptor];
        MTLTextureDescriptor *adapter_sparse_texture_wide_tail_descriptor =
            [native_sparse_texture_wide_tail_descriptor copy];
        id<MTLTexture> adapter_sparse_texture_wide_tail =
            [adapter_device newTextureWithDescriptor:adapter_sparse_texture_wide_tail_descriptor];
        MTLTextureDescriptor *native_sparse_texture_tall_tail_descriptor =
            [native_sparse_texture_descriptor copy];
        native_sparse_texture_tall_tail_descriptor.width = 64;
        native_sparse_texture_tall_tail_descriptor.height = 1024;
        native_sparse_texture_tall_tail_descriptor.mipmapLevelCount = 11;
        id<MTLTexture> native_sparse_texture_tall_tail =
            [device newTextureWithDescriptor:native_sparse_texture_tall_tail_descriptor];
        MTLHeapDescriptor *adapter_sparse_texture_wide_heap_descriptor = [MTLHeapDescriptor new];
        adapter_sparse_texture_wide_heap_descriptor.type = MTLHeapTypePlacement;
        adapter_sparse_texture_wide_heap_descriptor.size = sparse_page_bytes * 7;
        adapter_sparse_texture_wide_heap_descriptor.storageMode = MTLStorageModePrivate;
        adapter_sparse_texture_wide_heap_descriptor.maxCompatiblePlacementSparsePageSize = MTLSparsePageSize64;
        id<MTLHeap> adapter_sparse_texture_wide_heap =
            [adapter_device newHeapWithDescriptor:adapter_sparse_texture_wide_heap_descriptor];
        id<MTLTexture> adapter_sparse_texture_wide_mapped =
            [adapter_sparse_texture_wide_heap newTextureWithDescriptor:adapter_sparse_texture_wide_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_tall_tail =
            [adapter_sparse_texture_wide_heap newTextureWithDescriptor:native_sparse_texture_tall_tail_descriptor];
        MTLTextureDescriptor *native_sparse_texture_3d_descriptor = [MTLTextureDescriptor new];
        native_sparse_texture_3d_descriptor.textureType = MTLTextureType3D;
        native_sparse_texture_3d_descriptor.pixelFormat = MTLPixelFormatRGBA8Unorm;
        native_sparse_texture_3d_descriptor.width = 128;
        native_sparse_texture_3d_descriptor.height = 128;
        native_sparse_texture_3d_descriptor.depth = 2;
        native_sparse_texture_3d_descriptor.mipmapLevelCount = 1;
        native_sparse_texture_3d_descriptor.sampleCount = 1;
        native_sparse_texture_3d_descriptor.storageMode = MTLStorageModePrivate;
        native_sparse_texture_3d_descriptor.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
        native_sparse_texture_3d_descriptor.placementSparsePageSize = MTLSparsePageSize64;
        id<MTLTexture> native_sparse_texture_3d =
            [device newTextureWithDescriptor:native_sparse_texture_3d_descriptor];
        id<MTLTexture> adapter_sparse_texture_3d =
            [adapter_sparse_texture_heap newTextureWithDescriptor:native_sparse_texture_3d_descriptor];
        MTLTextureDescriptor *native_sparse_texture_3d_tail_descriptor = [native_sparse_texture_3d_descriptor copy];
        native_sparse_texture_3d_tail_descriptor.depth = 4;
        native_sparse_texture_3d_tail_descriptor.mipmapLevelCount = 4;
        id<MTLTexture> native_sparse_texture_3d_tail =
            [device newTextureWithDescriptor:native_sparse_texture_3d_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_3d_tail =
            [adapter_device newTextureWithDescriptor:native_sparse_texture_3d_tail_descriptor];
        MTLTextureDescriptor *native_sparse_texture_array_tail_descriptor =
            [native_sparse_texture_tail_descriptor copy];
        native_sparse_texture_array_tail_descriptor.textureType = MTLTextureType2DArray;
        native_sparse_texture_array_tail_descriptor.arrayLength = 2;
        id<MTLTexture> native_sparse_texture_array_tail =
            [device newTextureWithDescriptor:native_sparse_texture_array_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_array_tail =
            [adapter_sparse_texture_heap newTextureWithDescriptor:native_sparse_texture_array_tail_descriptor];
        id<MTLTexture> adapter_sparse_texture_tail_move =
            [adapter_sparse_texture_heap newTextureWithDescriptor:adapter_sparse_texture_tail_descriptor];
        id<MTLBuffer> adapter_sparse_texture_input =
            [adapter_device newBufferWithBytes:sparse_texture_input_data.bytes
                                         length:sparse_texture_input_data.length
                                        options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_sparse_texture_output =
            [adapter_device newBufferWithLength:sparse_texture_bytes options:MTLResourceStorageModeShared];
        id<MTLCommandQueue> adapter_sparse_texture_legacy_queue = [adapter_device newCommandQueue];
        const NSUInteger sparse_texture_wide_tail_level = adapter_sparse_texture_wide_mapped == nil ? 0 :
            adapter_sparse_texture_wide_mapped.firstMipmapInTail;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_wide_tail_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake2D(0, 0, 1, 1),
            .heapOffset = 0,
            .textureLevel = sparse_texture_wide_tail_level,
            .textureSlice = 0,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_wide_mapped
                                              heap:adapter_sparse_texture_wide_heap
                                         operations:&adapter_sparse_texture_wide_tail_map count:1];
        NSMutableData *sparse_texture_wide_input = [NSMutableData dataWithLength:1024 * 64 * 4];
        for (NSUInteger index = 0; index < sparse_texture_wide_input.length; ++index) {
            ((uint8_t *)sparse_texture_wide_input.mutableBytes)[index] = (uint8_t)((index * 37u + 13u) & 0xffu);
        }
        [adapter_sparse_texture_wide_mapped replaceRegion:MTLRegionMake2D(0, 0, 1024, 64)
                                               mipmapLevel:sparse_texture_wide_tail_level
                                                  withBytes:sparse_texture_wide_input.bytes bytesPerRow:1024 * 4];
        NSMutableData *sparse_texture_wide_output = [NSMutableData dataWithLength:sparse_texture_wide_input.length];
        [adapter_sparse_texture_wide_mapped getBytes:sparse_texture_wide_output.mutableBytes
                                          bytesPerRow:1024 * 4
                                           fromRegion:MTLRegionMake2D(0, 0, 1024, 64)
                                          mipmapLevel:sparse_texture_wide_tail_level];
        BOOL sparse_texture_wide_tail_exact =
            native_sparse_texture_wide_tail != nil && adapter_sparse_texture_wide_tail != nil &&
            adapter_sparse_texture_wide_mapped != nil && sparse_texture_wide_tail_level == 0 &&
            memcmp(sparse_texture_wide_output.bytes, sparse_texture_wide_input.bytes,
                   sparse_texture_wide_input.length) == 0;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_wide_tail_unmap =
            adapter_sparse_texture_wide_tail_map;
        adapter_sparse_texture_wide_tail_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_wide_mapped heap:nil
                                              operations:&adapter_sparse_texture_wide_tail_unmap count:1];
        const NSUInteger sparse_texture_tall_tail_level = adapter_sparse_texture_tall_tail == nil ? 0 :
            adapter_sparse_texture_tall_tail.firstMipmapInTail;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_tall_tail_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake2D(0, 0, 1, 1),
            .heapOffset = 0,
            .textureLevel = sparse_texture_tall_tail_level,
            .textureSlice = 0,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tall_tail
                                              heap:adapter_sparse_texture_wide_heap
                                         operations:&adapter_sparse_texture_tall_tail_map count:1];
        NSMutableData *sparse_texture_tall_input = [NSMutableData dataWithLength:64 * 1024 * 4];
        for (NSUInteger index = 0; index < sparse_texture_tall_input.length; ++index) {
            ((uint8_t *)sparse_texture_tall_input.mutableBytes)[index] = (uint8_t)((index * 47u + 29u) & 0xffu);
        }
        [adapter_sparse_texture_tall_tail replaceRegion:MTLRegionMake2D(0, 0, 64, 1024)
                                               mipmapLevel:sparse_texture_tall_tail_level
                                                  withBytes:sparse_texture_tall_input.bytes bytesPerRow:64 * 4];
        NSMutableData *sparse_texture_tall_output = [NSMutableData dataWithLength:sparse_texture_tall_input.length];
        [adapter_sparse_texture_tall_tail getBytes:sparse_texture_tall_output.mutableBytes
                                          bytesPerRow:64 * 4
                                           fromRegion:MTLRegionMake2D(0, 0, 64, 1024)
                                          mipmapLevel:sparse_texture_tall_tail_level];
        BOOL sparse_texture_tall_tail_exact =
            native_sparse_texture_tall_tail != nil && adapter_sparse_texture_tall_tail != nil &&
            sparse_texture_tall_tail_level == 0 &&
            adapter_sparse_texture_tall_tail.firstMipmapInTail == native_sparse_texture_tall_tail.firstMipmapInTail &&
            adapter_sparse_texture_tall_tail.tailSizeInBytes == native_sparse_texture_tall_tail.tailSizeInBytes &&
            adapter_sparse_texture_tall_tail.tailSizeInBytes == sparse_page_bytes * 7 &&
            memcmp(sparse_texture_tall_output.bytes, sparse_texture_tall_input.bytes,
                   sparse_texture_tall_input.length) == 0;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_tall_tail_unmap =
            adapter_sparse_texture_tall_tail_map;
        adapter_sparse_texture_tall_tail_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tall_tail heap:nil
                                         operations:&adapter_sparse_texture_tall_tail_unmap count:1];
        memset(sparse_texture_tall_output.mutableBytes, 0xa5, sparse_texture_tall_output.length);
        [adapter_sparse_texture_tall_tail getBytes:sparse_texture_tall_output.mutableBytes
                                          bytesPerRow:64 * 4
                                           fromRegion:MTLRegionMake2D(0, 0, 64, 1024)
                                          mipmapLevel:sparse_texture_tall_tail_level];
        if (sparse_texture_tall_tail_exact) {
            for (NSUInteger index = 0; index < sparse_texture_tall_output.length; ++index) {
                if (((const uint8_t *)sparse_texture_tall_output.bytes)[index] != 0) {
                    sparse_texture_tall_tail_exact = NO;
                    break;
                }
            }
        }
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_3d_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake3D(0, 0, 1, 1, 1, 1),
            .heapOffset = 0,
            .textureLevel = 0,
            .textureSlice = 0,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_3d
                                              heap:adapter_sparse_texture_heap
                                         operations:&adapter_sparse_texture_3d_map count:1];
        NSMutableData *sparse_texture_3d_input = [NSMutableData dataWithLength:128 * 128 * 4];
        for (NSUInteger index = 0; index < sparse_texture_3d_input.length; ++index) {
            ((uint8_t *)sparse_texture_3d_input.mutableBytes)[index] = (uint8_t)((index * 41u + 5u) & 0xffu);
        }
        [adapter_sparse_texture_3d replaceRegion:MTLRegionMake3D(0, 0, 1, 128, 128, 1)
                                      mipmapLevel:0 slice:0 withBytes:sparse_texture_3d_input.bytes
                                     bytesPerRow:128 * 4 bytesPerImage:128 * 128 * 4];
        NSMutableData *sparse_texture_3d_output = [NSMutableData dataWithLength:sparse_texture_3d_input.length];
        [adapter_sparse_texture_3d getBytes:sparse_texture_3d_output.mutableBytes
                               bytesPerRow:128 * 4 bytesPerImage:128 * 128 * 4
                                fromRegion:MTLRegionMake3D(0, 0, 1, 128, 128, 1)
                               mipmapLevel:0 slice:0];
        NSMutableData *sparse_texture_3d_zero = [NSMutableData dataWithLength:sparse_texture_3d_input.length];
        memset(sparse_texture_3d_zero.mutableBytes, 0xa5, sparse_texture_3d_zero.length);
        [adapter_sparse_texture_3d getBytes:sparse_texture_3d_zero.mutableBytes
                               bytesPerRow:128 * 4 bytesPerImage:128 * 128 * 4
                                fromRegion:MTLRegionMake3D(0, 0, 0, 128, 128, 1)
                               mipmapLevel:0 slice:0];
        BOOL sparse_texture_3d_exact = native_sparse_texture_3d != nil && adapter_sparse_texture_3d != nil &&
            native_sparse_texture_3d.isSparse && adapter_sparse_texture_3d.isSparse &&
            native_sparse_texture_3d.sparseTextureTier == adapter_sparse_texture_3d.sparseTextureTier &&
            native_sparse_texture_3d_tail != nil && adapter_sparse_texture_3d_tail != nil &&
            native_sparse_texture_3d_tail.firstMipmapInTail == adapter_sparse_texture_3d_tail.firstMipmapInTail &&
            native_sparse_texture_3d_tail.tailSizeInBytes == adapter_sparse_texture_3d_tail.tailSizeInBytes &&
            memcmp(sparse_texture_3d_output.bytes, sparse_texture_3d_input.bytes,
                   sparse_texture_3d_input.length) == 0;
        if (sparse_texture_3d_exact) {
            for (NSUInteger index = 0; index < sparse_texture_3d_zero.length; ++index) {
                if (((const uint8_t *)sparse_texture_3d_zero.bytes)[index] != 0) {
                    sparse_texture_3d_exact = NO;
                    break;
                }
            }
        }
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_3d_unmap = adapter_sparse_texture_3d_map;
        adapter_sparse_texture_3d_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_3d heap:nil
                                         operations:&adapter_sparse_texture_3d_unmap count:1];
        BOOL sparse_texture_3d_tail_mapping_exact = native_sparse_texture_3d_tail != nil &&
            adapter_sparse_texture_3d_tail != nil &&
            adapter_sparse_texture_3d_tail.firstMipmapInTail == 1 &&
            adapter_sparse_texture_3d_tail.tailSizeInBytes == sparse_page_bytes * 3;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_3d_tail_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake3D(0, 0, 0, 1, 1, 1),
            .heapOffset = 0,
            .textureLevel = 1,
            .textureSlice = 0,
        };
        if (sparse_texture_3d_tail_mapping_exact) {
            [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_3d_tail
                                                  heap:adapter_sparse_texture_wide_heap
                                             operations:&adapter_sparse_texture_3d_tail_map count:1];
            NSUInteger levelWidth = 64;
            NSUInteger levelHeight = 64;
            NSUInteger levelDepth = 2;
            for (NSUInteger level = 1; level < 4 && sparse_texture_3d_tail_mapping_exact; ++level) {
                const NSUInteger levelBytes = levelWidth * levelHeight * levelDepth * 4;
                NSMutableData *input = [NSMutableData dataWithLength:levelBytes];
                for (NSUInteger index = 0; index < input.length; ++index) {
                    ((uint8_t *)input.mutableBytes)[index] = (uint8_t)((index * 53u + level * 19u) & 0xffu);
                }
                [adapter_sparse_texture_3d_tail replaceRegion:MTLRegionMake3D(0, 0, 0,
                                                                                 levelWidth, levelHeight, levelDepth)
                                                   mipmapLevel:level slice:0 withBytes:input.bytes
                                                  bytesPerRow:levelWidth * 4
                                                bytesPerImage:levelWidth * levelHeight * 4];
                NSMutableData *output = [NSMutableData dataWithLength:levelBytes];
                [adapter_sparse_texture_3d_tail getBytes:output.mutableBytes
                                             bytesPerRow:levelWidth * 4
                                            bytesPerImage:levelWidth * levelHeight * 4
                                              fromRegion:MTLRegionMake3D(0, 0, 0,
                                                                           levelWidth, levelHeight, levelDepth)
                                             mipmapLevel:level slice:0];
                if (memcmp(input.bytes, output.bytes, levelBytes) != 0) {
                    sparse_texture_3d_tail_mapping_exact = NO;
                }
                levelWidth = levelWidth > 1 ? levelWidth / 2 : 1;
                levelHeight = levelHeight > 1 ? levelHeight / 2 : 1;
                levelDepth = levelDepth > 1 ? levelDepth / 2 : 1;
            }
            MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_3d_tail_unmap =
                adapter_sparse_texture_3d_tail_map;
            adapter_sparse_texture_3d_tail_unmap.mode = MTLSparseTextureMappingModeUnmap;
            [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_3d_tail heap:nil
                                             operations:&adapter_sparse_texture_3d_tail_unmap count:1];
        }
        sparse_texture_3d_exact = sparse_texture_3d_exact && sparse_texture_3d_tail_mapping_exact;
        const NSUInteger sparse_texture_array_tail_level = adapter_sparse_texture_array_tail == nil ? 0 :
            adapter_sparse_texture_array_tail.firstMipmapInTail;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_array_tail_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake2D(0, 0, 1, 1),
            .heapOffset = 0,
            .textureLevel = sparse_texture_array_tail_level,
            .textureSlice = 1,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_array_tail
                                              heap:adapter_sparse_texture_heap
                                         operations:&adapter_sparse_texture_array_tail_map count:1];
        const NSUInteger sparse_texture_array_tail_width = sparse_texture_width >> sparse_texture_array_tail_level;
        const NSUInteger sparse_texture_array_tail_height = sparse_texture_height >> sparse_texture_array_tail_level;
        NSMutableData *sparse_texture_array_tail_input = [NSMutableData dataWithLength:
            sparse_texture_array_tail_width * sparse_texture_array_tail_height * 4];
        for (NSUInteger index = 0; index < sparse_texture_array_tail_input.length; ++index) {
            ((uint8_t *)sparse_texture_array_tail_input.mutableBytes)[index] =
                (uint8_t)((index * 43u + 17u) & 0xffu);
        }
        [adapter_sparse_texture_array_tail replaceRegion:MTLRegionMake2D(0, 0,
                                                                           sparse_texture_array_tail_width,
                                                                           sparse_texture_array_tail_height)
                                              mipmapLevel:sparse_texture_array_tail_level slice:1
                                               withBytes:sparse_texture_array_tail_input.bytes
                                              bytesPerRow:sparse_texture_array_tail_width * 4
                                            bytesPerImage:sparse_texture_array_tail_input.length];
        NSMutableData *sparse_texture_array_tail_output = [NSMutableData dataWithLength:
            sparse_texture_array_tail_input.length];
        [adapter_sparse_texture_array_tail getBytes:sparse_texture_array_tail_output.mutableBytes
                                         bytesPerRow:sparse_texture_array_tail_width * 4
                                        bytesPerImage:sparse_texture_array_tail_input.length
                                          fromRegion:MTLRegionMake2D(0, 0,
                                                                       sparse_texture_array_tail_width,
                                                                       sparse_texture_array_tail_height)
                                         mipmapLevel:sparse_texture_array_tail_level slice:1];
        BOOL sparse_texture_array_tail_exact = native_sparse_texture_array_tail != nil &&
            adapter_sparse_texture_array_tail != nil &&
            adapter_sparse_texture_array_tail.firstMipmapInTail == native_sparse_texture_array_tail.firstMipmapInTail &&
            adapter_sparse_texture_array_tail.tailSizeInBytes == native_sparse_texture_array_tail.tailSizeInBytes &&
            memcmp(sparse_texture_array_tail_output.bytes, sparse_texture_array_tail_input.bytes,
                   sparse_texture_array_tail_input.length) == 0;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_array_tail_unmap =
            adapter_sparse_texture_array_tail_map;
        adapter_sparse_texture_array_tail_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_array_tail heap:nil
                                         operations:&adapter_sparse_texture_array_tail_unmap count:1];
        const NSUInteger sparse_texture_tail_level = adapter_sparse_texture_tail == nil ? 0 :
            adapter_sparse_texture_tail.firstMipmapInTail;
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_tail_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake2D(0, 0, 1, 1),
            .heapOffset = 0,
            .textureLevel = sparse_texture_tail_level,
            .textureSlice = 0,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tail
                                              heap:adapter_sparse_texture_heap
                                         operations:&adapter_sparse_texture_tail_map count:1];
        NSMutableArray<NSMutableData *> *sparse_texture_tail_inputs = [NSMutableArray array];
        NSUInteger sparse_texture_tail_width = sparse_texture_width >> sparse_texture_tail_level;
        NSUInteger sparse_texture_tail_height = sparse_texture_height >> sparse_texture_tail_level;
        for (NSUInteger level = sparse_texture_tail_level; level < 4; ++level) {
            const NSUInteger rowBytes = sparse_texture_tail_width * 4;
            NSMutableData *levelData = [NSMutableData dataWithLength:rowBytes * sparse_texture_tail_height];
            for (NSUInteger index = 0; index < levelData.length; ++index) {
                ((uint8_t *)levelData.mutableBytes)[index] =
                    (uint8_t)((index * 23u + level * 19u + 7u) & 0xffu);
            }
            [sparse_texture_tail_inputs addObject:levelData];
            [adapter_sparse_texture_tail replaceRegion:MTLRegionMake2D(0, 0,
                                                                         sparse_texture_tail_width,
                                                                         sparse_texture_tail_height)
                                            mipmapLevel:level withBytes:levelData.bytes
                                           bytesPerRow:rowBytes];
            sparse_texture_tail_width = sparse_texture_tail_width > 1 ? sparse_texture_tail_width / 2 : 1;
            sparse_texture_tail_height = sparse_texture_tail_height > 1 ? sparse_texture_tail_height / 2 : 1;
        }
        BOOL sparse_texture_tail_exact = native_sparse_texture_tail != nil &&
            adapter_sparse_texture_tail != nil && adapter_sparse_texture_tail_copy != nil &&
            adapter_sparse_texture_tail.firstMipmapInTail == native_sparse_texture_tail.firstMipmapInTail &&
            adapter_sparse_texture_tail.tailSizeInBytes == native_sparse_texture_tail.tailSizeInBytes &&
            adapter_sparse_texture_tail.tailSizeInBytes == sparse_page_bytes * 2 &&
            native_sparse_texture_wide_tail != nil && adapter_sparse_texture_wide_tail != nil &&
            adapter_sparse_texture_wide_tail.firstMipmapInTail == native_sparse_texture_wide_tail.firstMipmapInTail &&
            adapter_sparse_texture_wide_tail.tailSizeInBytes == native_sparse_texture_wide_tail.tailSizeInBytes &&
            adapter_sparse_texture_wide_tail.tailSizeInBytes == sparse_page_bytes * 7 &&
            sparse_texture_wide_tail_exact && sparse_texture_tall_tail_exact &&
            sparse_texture_3d_exact && sparse_texture_array_tail_exact;
        for (NSUInteger level = sparse_texture_tail_level;
             level < 4 && sparse_texture_tail_exact; ++level) {
            NSMutableData *levelOutput = [NSMutableData dataWithLength:
                [sparse_texture_tail_inputs[level - sparse_texture_tail_level] length]];
            NSUInteger levelWidth = sparse_texture_width >> level;
            NSUInteger levelHeight = sparse_texture_height >> level;
            [adapter_sparse_texture_tail getBytes:levelOutput.mutableBytes
                                      bytesPerRow:levelWidth * 4
                                       fromRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                      mipmapLevel:level];
            sparse_texture_tail_exact = memcmp(levelOutput.bytes,
                                                sparse_texture_tail_inputs[level - sparse_texture_tail_level].bytes,
                                                levelOutput.length) == 0;
        }
        MTL4CopySparseTextureMappingOperation adapter_sparse_texture_tail_copy_operation = {
            .sourceRegion = MTLRegionMake2D(0, 0, 1, 1),
            .sourceLevel = sparse_texture_tail_level,
            .sourceSlice = 0,
            .destinationOrigin = MTLOriginMake(0, 0, 0),
            .destinationLevel = sparse_texture_tail_level,
            .destinationSlice = 0,
        };
        [metal4_sparse_queue copyTextureMappingsFromTexture:adapter_sparse_texture_tail
                                                   toTexture:adapter_sparse_texture_tail_copy
                                                 operations:&adapter_sparse_texture_tail_copy_operation count:1];
        for (NSUInteger level = sparse_texture_tail_level;
             level < 4 && sparse_texture_tail_exact; ++level) {
            NSMutableData *levelOutput = [NSMutableData dataWithLength:
                [sparse_texture_tail_inputs[level - sparse_texture_tail_level] length]];
            NSUInteger levelWidth = sparse_texture_width >> level;
            NSUInteger levelHeight = sparse_texture_height >> level;
            [adapter_sparse_texture_tail_copy getBytes:levelOutput.mutableBytes
                                           bytesPerRow:levelWidth * 4
                                            fromRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                           mipmapLevel:level];
            sparse_texture_tail_exact = memcmp(levelOutput.bytes,
                                                sparse_texture_tail_inputs[level - sparse_texture_tail_level].bytes,
                                                levelOutput.length) == 0;
        }
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_tail_unmap =
            adapter_sparse_texture_tail_map;
        adapter_sparse_texture_tail_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tail heap:nil
                                         operations:&adapter_sparse_texture_tail_unmap count:1];
        for (NSUInteger level = sparse_texture_tail_level;
             level < 4 && sparse_texture_tail_exact; ++level) {
            const NSUInteger levelWidth = sparse_texture_width >> level;
            const NSUInteger levelHeight = sparse_texture_height >> level;
            NSMutableData *levelOutput = [NSMutableData dataWithLength:levelWidth * levelHeight * 4];
            memset(levelOutput.mutableBytes, 0xa5, levelOutput.length);
            [adapter_sparse_texture_tail getBytes:levelOutput.mutableBytes
                                      bytesPerRow:levelWidth * 4
                                       fromRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                      mipmapLevel:level];
            for (NSUInteger index = 0; index < levelOutput.length; ++index) {
                if (((const uint8_t *)levelOutput.bytes)[index] != 0) {
                    sparse_texture_tail_exact = NO;
                    break;
                }
            }
        }
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tail_copy heap:nil
                                         operations:&adapter_sparse_texture_tail_unmap count:1];
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tail
                                              heap:adapter_sparse_texture_heap
                                         operations:&adapter_sparse_texture_tail_map count:1];
        for (NSUInteger level = sparse_texture_tail_level; level < 4; ++level) {
            const NSUInteger levelWidth = sparse_texture_width >> level;
            const NSUInteger levelHeight = sparse_texture_height >> level;
            NSMutableData *levelData = sparse_texture_tail_inputs[level - sparse_texture_tail_level];
            [adapter_sparse_texture_tail replaceRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                            mipmapLevel:level withBytes:levelData.bytes
                                           bytesPerRow:levelWidth * 4];
        }
        id<MTLCommandBuffer> sparse_texture_tail_move_command =
            [adapter_sparse_texture_legacy_queue commandBuffer];
        id<MTLResourceStateCommandEncoder> sparse_texture_tail_move_encoder =
            [sparse_texture_tail_move_command resourceStateCommandEncoder];
        [sparse_texture_tail_move_encoder moveTextureMappingsFromTexture:adapter_sparse_texture_tail
                                                             sourceSlice:0 sourceLevel:sparse_texture_tail_level
                                                            sourceOrigin:MTLOriginMake(0, 0, 0)
                                                              sourceSize:MTLSizeMake(1, 1, 1)
                                                               toTexture:adapter_sparse_texture_tail_move
                                                        destinationSlice:0
                                                         destinationLevel:sparse_texture_tail_level
                                                        destinationOrigin:MTLOriginMake(0, 0, 0)];
        [sparse_texture_tail_move_encoder endEncoding];
        [sparse_texture_tail_move_command commit];
        [sparse_texture_tail_move_command waitUntilCompleted];
        for (NSUInteger level = sparse_texture_tail_level;
             level < 4 && sparse_texture_tail_exact; ++level) {
            const NSUInteger levelWidth = sparse_texture_width >> level;
            const NSUInteger levelHeight = sparse_texture_height >> level;
            NSMutableData *sourceOutput = [NSMutableData dataWithLength:levelWidth * levelHeight * 4];
            NSMutableData *destinationOutput = [NSMutableData dataWithLength:sourceOutput.length];
            memset(sourceOutput.mutableBytes, 0xa5, sourceOutput.length);
            [adapter_sparse_texture_tail getBytes:sourceOutput.mutableBytes
                                      bytesPerRow:levelWidth * 4
                                       fromRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                      mipmapLevel:level];
            [adapter_sparse_texture_tail_move getBytes:destinationOutput.mutableBytes
                                           bytesPerRow:levelWidth * 4
                                            fromRegion:MTLRegionMake2D(0, 0, levelWidth, levelHeight)
                                           mipmapLevel:level];
            BOOL sourceZero = YES;
            for (NSUInteger index = 0; index < sourceOutput.length; ++index) {
                if (((const uint8_t *)sourceOutput.bytes)[index] != 0) {
                    sourceZero = NO;
                    break;
                }
            }
            sparse_texture_tail_exact = sourceZero &&
                memcmp(destinationOutput.bytes,
                       sparse_texture_tail_inputs[level - sparse_texture_tail_level].bytes,
                       destinationOutput.length) == 0;
        }
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_tail_move heap:nil
                                         operations:&adapter_sparse_texture_tail_unmap count:1];
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_map = {
            .mode = MTLSparseTextureMappingModeMap,
            .textureRegion = MTLRegionMake2D(0, 0, 1, 1),
            .heapOffset = 0,
            .textureLevel = 0,
            .textureSlice = 0,
        };
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture
                                              heap:adapter_sparse_texture_heap
                                         operations:&adapter_sparse_texture_map count:1];
        id<MTLCommandBuffer> adapter_sparse_texture_upload_command = [adapter_sparse_texture_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_sparse_texture_upload_encoder =
            [adapter_sparse_texture_upload_command blitCommandEncoder];
        [adapter_sparse_texture_upload_encoder copyFromBuffer:adapter_sparse_texture_input sourceOffset:0
                                               sourceBytesPerRow:128 * 4 sourceBytesPerImage:128 * 128 * 4
                                                     sourceSize:MTLSizeMake(128, 128, 1)
                                                    toTexture:adapter_sparse_texture destinationSlice:0 destinationLevel:0
                                             destinationOrigin:MTLOriginMake(0, 0, 0)];
        [adapter_sparse_texture_upload_encoder endEncoding];
        [adapter_sparse_texture_upload_command commit];
        [adapter_sparse_texture_upload_command waitUntilCompleted];
        id<MTLCommandBuffer> adapter_sparse_texture_download_command = [adapter_sparse_texture_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_sparse_texture_download_encoder =
            [adapter_sparse_texture_download_command blitCommandEncoder];
        [adapter_sparse_texture_download_encoder copyFromTexture:adapter_sparse_texture sourceSlice:0 sourceLevel:0
                                                     sourceOrigin:MTLOriginMake(0, 0, 0)
                                                       sourceSize:MTLSizeMake(sparse_texture_width, sparse_texture_height, 1)
                                                          toBuffer:adapter_sparse_texture_output destinationOffset:0
                                              destinationBytesPerRow:sparse_texture_row_bytes
                                            destinationBytesPerImage:sparse_texture_bytes];
        [adapter_sparse_texture_download_encoder endEncoding];
        [adapter_sparse_texture_download_command commit];
        [adapter_sparse_texture_download_command waitUntilCompleted];
        BOOL sparse_texture_exact =
            native_sparse_texture != nil && native_sparse_texture.isSparse &&
            native_sparse_texture.sparseTextureTier == MTLTextureSparseTier1 &&
            native_sparse_texture.firstMipmapInTail == adapter_sparse_texture.firstMipmapInTail &&
            native_sparse_texture.allocatedSize == adapter_sparse_texture.allocatedSize &&
            adapter_sparse_texture_heap != nil &&
            adapter_sparse_texture != nil && adapter_sparse_texture_input != nil &&
            adapter_sparse_texture_output != nil && adapter_sparse_texture_legacy_queue != nil &&
            sparse_texture_tail_exact &&
            adapter_sparse_texture_upload_command.status == MTLCommandBufferStatusCompleted &&
            adapter_sparse_texture_download_command.status == MTLCommandBufferStatusCompleted;
        if (sparse_texture_exact) {
            const uint8_t *adapter_bytes = adapter_sparse_texture_output.contents;
            const uint8_t *input_bytes = sparse_texture_input_data.bytes;
            for (NSUInteger row = 0; row < sparse_texture_height && sparse_texture_exact; ++row) {
                const BOOL mappedRow = row < 128;
                sparse_texture_exact = !mappedRow || memcmp(adapter_bytes + row * sparse_texture_row_bytes,
                                                            input_bytes + row * 128 * 4, 128 * 4) == 0;
                for (NSUInteger index = 0; index < 128 * 4 && sparse_texture_exact; ++index) {
                    if (!mappedRow && adapter_bytes[row * sparse_texture_row_bytes + index] != 0) {
                        sparse_texture_exact = NO;
                    }
                }
                for (NSUInteger index = 128 * 4; index < sparse_texture_row_bytes && sparse_texture_exact; ++index) {
                    if (adapter_bytes[row * sparse_texture_row_bytes + index] != 0) sparse_texture_exact = NO;
                }
            }
        }
        if (!sparse_texture_exact || adapter_sparse_texture.sparseTextureTier != MTLTextureSparseTier1 ||
            !adapter_sparse_texture.isSparse) {
            fprintf(stderr, "metal-pixel: CPU placement-sparse texture mapping exactness failed\n");
            return 87;
        }
        MTL4CopySparseTextureMappingOperation adapter_sparse_texture_copy_operation = {
            .sourceRegion = MTLRegionMake2D(0, 0, 1, 1),
            .sourceLevel = 0,
            .sourceSlice = 0,
            /* A nonzero tile origin catches accidental zero-point handling
             * in the X/Y sparse grid independently of viewport coordinates. */
            .destinationOrigin = MTLOriginMake(1, 1, 0),
            .destinationLevel = 0,
            .destinationSlice = 0,
        };
        [metal4_sparse_queue copyTextureMappingsFromTexture:adapter_sparse_texture
                                                   toTexture:adapter_sparse_texture_copy
                                                   operations:&adapter_sparse_texture_copy_operation count:1];
        memset(adapter_sparse_texture_output.contents, 0xa5, sparse_texture_bytes);
        id<MTLCommandBuffer> adapter_sparse_texture_copy_command = [adapter_sparse_texture_legacy_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_sparse_texture_copy_encoder =
            [adapter_sparse_texture_copy_command blitCommandEncoder];
        [adapter_sparse_texture_copy_encoder copyFromTexture:adapter_sparse_texture_copy sourceSlice:0 sourceLevel:0
                                                  sourceOrigin:MTLOriginMake(0, 0, 0)
                                                    sourceSize:MTLSizeMake(sparse_texture_width, sparse_texture_height, 1)
                                                       toBuffer:adapter_sparse_texture_output destinationOffset:0
                                            destinationBytesPerRow:sparse_texture_row_bytes
                                          destinationBytesPerImage:sparse_texture_bytes];
        [adapter_sparse_texture_copy_encoder endEncoding];
        [adapter_sparse_texture_copy_command commit];
        [adapter_sparse_texture_copy_command waitUntilCompleted];
        if (adapter_sparse_texture_copy == nil || adapter_sparse_texture_copy_encoder == nil ||
            adapter_sparse_texture_copy_command.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: CPU sparse texture mapping copy failed\n");
            return 88;
        }
        const uint8_t *copied_sparse_texture_bytes = adapter_sparse_texture_output.contents;
        for (NSUInteger row = 0; row < sparse_texture_height; ++row) {
            const BOOL mappedRow = row >= 128;
            for (NSUInteger index = 0; index < 128 * 4; ++index) {
                const NSUInteger sourceIndex = (mappedRow ? row - 128 : 0) * 128 * 4 + index;
                const NSUInteger destinationIndex = row * sparse_texture_row_bytes + 128 * 4 + index;
                if (mappedRow && memcmp(copied_sparse_texture_bytes + destinationIndex,
                                        sparse_texture_input_data.bytes + sourceIndex, 1) != 0) {
                    fprintf(stderr, "metal-pixel: CPU sparse texture mapping copy lost a mapped Y tile\n");
                    return 89;
                }
                if (copied_sparse_texture_bytes[row * sparse_texture_row_bytes + index] != 0) {
                    fprintf(stderr, "metal-pixel: CPU sparse texture mapping copy touched an unmapped row\n");
                    return 89;
                }
            }
            for (NSUInteger index = 0; index < sparse_texture_row_bytes; ++index) {
                const BOOL mappedPixel = mappedRow && index >= 128 * 4;
                if (!mappedPixel && copied_sparse_texture_bytes[row * sparse_texture_row_bytes + index] != 0) {
                    fprintf(stderr, "metal-pixel: CPU sparse texture mapping copy touched an unmapped pixel\n");
                    return 89;
                }
            }
        }
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_unmap = adapter_sparse_texture_map;
        adapter_sparse_texture_unmap.mode = MTLSparseTextureMappingModeUnmap;
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture heap:nil
                                         operations:&adapter_sparse_texture_unmap count:1];
        MTL4UpdateSparseTextureMappingOperation adapter_sparse_texture_copy_unmap = adapter_sparse_texture_unmap;
        adapter_sparse_texture_copy_unmap.textureRegion = MTLRegionMake2D(1, 1, 1, 1);
        [metal4_sparse_queue updateTextureMappings:adapter_sparse_texture_copy heap:nil
                                         operations:&adapter_sparse_texture_copy_unmap count:1];
        uint8_t adapter_sparse_texture_zero[sparse_texture_tile_bytes];
        memset(adapter_sparse_texture_zero, 0xa5, sizeof(adapter_sparse_texture_zero));
        [adapter_sparse_texture getBytes:adapter_sparse_texture_zero bytesPerRow:128 * 4
                             fromRegion:MTLRegionMake2D(0, 0, 128, 128) mipmapLevel:0];
        for (NSUInteger index = 0; index < sizeof(adapter_sparse_texture_zero); ++index) {
            if (adapter_sparse_texture_zero[index] != 0) {
                fprintf(stderr, "metal-pixel: CPU unbacked sparse texture read was not zero\n");
                return 88;
            }
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

        id<MTLTexture> metal4_f16_upload_texture =
            [adapter_device newTextureWithDescriptor:f16_three_d_descriptor];
        id<MTLBuffer> metal4_f16_to_buffer =
            [adapter_device newBufferWithLength:f16_download_buffer_length options:MTLResourceStorageModeShared];
        if (metal4_f16_upload_texture != nil) {
            [metal4_f16_upload_texture replaceRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                                       f16_three_d_height, f16_three_d_depth)
                                           mipmapLevel:0 slice:0 withBytes:f16_three_d_clear
                                           bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes];
        }
        if (metal4_f16_to_buffer != nil) {
            memset(metal4_f16_to_buffer.contents, 0xab, metal4_f16_to_buffer.length);
        }
        id<MTL4CommandBuffer> metal4_f16_command_buffer = [adapter_device newCommandBuffer];
        [metal4_f16_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_f16_encoder =
            [metal4_f16_command_buffer computeCommandEncoder];
        [metal4_f16_encoder copyFromTexture:adapter_f16_three_d
                                  sourceSlice:0 sourceLevel:0 sourceOrigin:f16_source_origin
                                  sourceSize:f16_copy_size toBuffer:metal4_f16_to_buffer
                             destinationOffset:f16_download_offset
                        destinationBytesPerRow:f16_copy_row_stride
                      destinationBytesPerImage:f16_copy_image_stride];
        [metal4_f16_encoder copyFromBuffer:adapter_f16_upload_buffer sourceOffset:f16_upload_offset
                           sourceBytesPerRow:f16_copy_row_stride sourceBytesPerImage:f16_copy_image_stride
                                  sourceSize:f16_copy_size toTexture:metal4_f16_upload_texture
                            destinationSlice:0 destinationLevel:0 destinationOrigin:f16_destination_origin];
        [metal4_f16_encoder endEncoding];
        [metal4_f16_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_f16_command_buffers[] = {metal4_f16_command_buffer};
        [metal4_queue commit:metal4_f16_command_buffers count:1];
        uint8_t metal4_f16_upload_texture_bytes[f16_three_d_bytes];
        memset(metal4_f16_upload_texture_bytes, 0xa5, sizeof(metal4_f16_upload_texture_bytes));
        [metal4_f16_upload_texture getBytes:metal4_f16_upload_texture_bytes
                                bytesPerRow:f16_three_d_row_bytes bytesPerImage:f16_three_d_plane_bytes
                                 fromRegion:MTLRegionMake3D(0, 0, 0, f16_three_d_width,
                                                             f16_three_d_height, f16_three_d_depth)
                                mipmapLevel:0 slice:0];
        if (metal4_f16_upload_texture == nil || metal4_f16_to_buffer == nil ||
            metal4_f16_command_buffer == nil || metal4_f16_encoder == nil ||
            memcmp(metal4_f16_upload_texture_bytes, native_f16_three_d_bytes,
                   sizeof(metal4_f16_upload_texture_bytes)) != 0 ||
            memcmp(metal4_f16_to_buffer.contents, native_f16_download_buffer.contents,
                   f16_download_buffer_length) != 0) {
            fail_with_error("Metal 4 CPU RGBA16Float 3D copy failed", metal4_error);
            return 113;
        }

        if (@available(macOS 26.0, iOS 26.0, *)) {
            const NSInteger metal4_tensor_dimension_values[] = {3, 2};
            const NSInteger metal4_tensor_packed_stride_values[] = {1, 3};
            const NSInteger metal4_tensor_buffer_stride_values[] = {1, 4};
            MTLTensorExtents *metal4_tensor_dimensions =
                [[MTLTensorExtents alloc] initWithRank:2 values:metal4_tensor_dimension_values];
            MTLTensorExtents *metal4_tensor_packed_strides =
                [[MTLTensorExtents alloc] initWithRank:2 values:metal4_tensor_packed_stride_values];
            MTLTensorExtents *metal4_tensor_buffer_strides =
                [[MTLTensorExtents alloc] initWithRank:2 values:metal4_tensor_buffer_stride_values];
            MTLTensorDescriptor *metal4_tensor_descriptor = [MTLTensorDescriptor new];
            metal4_tensor_descriptor.dimensions = metal4_tensor_dimensions;
            metal4_tensor_descriptor.strides = metal4_tensor_buffer_strides;
            metal4_tensor_descriptor.dataType = MTLTensorDataTypeUInt8;
            metal4_tensor_descriptor.usage = MTLTensorUsageCompute;
            metal4_tensor_descriptor.resourceOptions = MTLResourceStorageModeShared;
            metal4_tensor_descriptor.storageMode = MTLStorageModeShared;
            id<MTLBuffer> metal4_tensor_source_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLBuffer> metal4_tensor_destination_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            id<MTLTensor> metal4_source_tensor =
                [metal4_tensor_source_buffer newTensorWithDescriptor:metal4_tensor_descriptor
                                                                offset:1 error:&metal4_error];
            id<MTLTensor> metal4_destination_tensor =
                [metal4_tensor_destination_buffer newTensorWithDescriptor:metal4_tensor_descriptor
                                                                     offset:2 error:&metal4_error];
            const NSInteger metal4_tensor_zero_values[] = {0, 0};
            MTLTensorExtents *metal4_tensor_zero =
                [[MTLTensorExtents alloc] initWithRank:2 values:metal4_tensor_zero_values];
            const uint8_t metal4_tensor_values[] = {50, 51, 52, 60, 61, 62};
            uint8_t metal4_tensor_copy_values[sizeof(metal4_tensor_values)] = {0};
            id<MTL4CommandBuffer> metal4_tensor_command_buffer = [adapter_device newCommandBuffer];
            [metal4_tensor_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
            id<MTL4ComputeCommandEncoder> metal4_tensor_encoder =
                [metal4_tensor_command_buffer computeCommandEncoder];
            [metal4_source_tensor replaceSliceOrigin:metal4_tensor_zero
                                      sliceDimensions:metal4_tensor_dimensions
                                            withBytes:metal4_tensor_values
                                              strides:metal4_tensor_packed_strides];
            [metal4_tensor_encoder copyFromTensor:metal4_source_tensor
                                      sourceOrigin:metal4_tensor_zero
                                  sourceDimensions:metal4_tensor_dimensions
                                          toTensor:metal4_destination_tensor
                                 destinationOrigin:metal4_tensor_zero
                             destinationDimensions:metal4_tensor_dimensions];
            [metal4_tensor_encoder endEncoding];
            [metal4_tensor_command_buffer endCommandBuffer];
            id<MTL4CommandBuffer> metal4_tensor_command_buffers[] = {metal4_tensor_command_buffer};
            [metal4_queue commit:metal4_tensor_command_buffers count:1];
            [metal4_destination_tensor getBytes:metal4_tensor_copy_values
                                        strides:metal4_tensor_packed_strides
                               fromSliceOrigin:metal4_tensor_zero
                                sliceDimensions:metal4_tensor_dimensions];
            if (metal4_source_tensor == nil || metal4_destination_tensor == nil ||
                metal4_tensor_command_buffer == nil || metal4_tensor_encoder == nil ||
                [metal4_tensor_encoder stages] != MTLStageBlit ||
                memcmp(metal4_tensor_copy_values, metal4_tensor_values,
                       sizeof(metal4_tensor_values)) != 0) {
                fail_with_error("Metal 4 CPU tensor copy failed", metal4_error);
                return 112;
            }
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
        uint8_t metal4_indirect_threads_storage[sizeof(metal4_indirect_threads) + 16] = {0};
        memcpy(metal4_indirect_threads_storage + 16, metal4_indirect_threads, sizeof(metal4_indirect_threads));
        id<MTLBuffer> metal4_indirect_threads_buffer =
            [adapter_device newBufferWithBytes:metal4_indirect_threads_storage
                                         length:sizeof(metal4_indirect_threads_storage)
                                        options:MTLResourceStorageModeShared];
        id<MTLTexture> metal4_indirect_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        [metal4_table setTexture:metal4_indirect_texture.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> metal4_indirect_command_buffer = [adapter_device newCommandBuffer];
        [metal4_indirect_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4ComputeCommandEncoder> metal4_indirect_encoder = [metal4_indirect_command_buffer computeCommandEncoder];
        [metal4_indirect_encoder setComputePipelineState:adapter_compute_pipeline];
        [metal4_indirect_encoder setArgumentTable:metal4_table];
        [metal4_indirect_encoder dispatchThreadsWithIndirectBuffer:metal4_indirect_threads_buffer.gpuAddress + 16];
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

        /* Metal 4 counter resolution accepts optional fences, but a fence
         * from another CPU adapter device must not cross the ownership
         * boundary merely because it has the right Objective-C protocol. */
        id<MTLFence> foreign_counter_wait_fence = [foreign_adapter_device newFence];
        id<MTLFence> foreign_counter_update_fence = [foreign_adapter_device newFence];
        id<MTL4CommandBuffer> foreign_counter_fence_command_buffer = [adapter_device newCommandBuffer];
        [foreign_counter_fence_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        [foreign_counter_fence_command_buffer endCommandBuffer];
        [foreign_counter_fence_command_buffer resolveCounterHeap:adapter_counter_heap
                                                         withRange:NSMakeRange(0, 1)
                                                        intoBuffer:MTL4BufferRangeMake(adapter_counter_buffer.gpuAddress,
                                                                                        sizeof(MTL4TimestampHeapEntry))
                                                         waitFence:foreign_counter_wait_fence
                                                       updateFence:foreign_counter_update_fence];
        id<MTL4CommandBuffer> foreign_counter_fence_command_buffers[] = {
            foreign_counter_fence_command_buffer,
        };
        MTL4CommitOptions *foreign_counter_fence_options = ZPUMetalCreateCPUCommitOptions();
        __block NSError *foreign_counter_fence_error = nil;
        [foreign_counter_fence_options addFeedbackHandler:^(id<MTL4CommitFeedback> feedback) {
            foreign_counter_fence_error = feedback.error;
        }];
        [metal4_queue commit:foreign_counter_fence_command_buffers
                        count:1
                       options:foreign_counter_fence_options];
        if (foreign_counter_wait_fence == nil || foreign_counter_update_fence == nil ||
            foreign_counter_fence_command_buffer == nil || foreign_counter_fence_error == nil) {
            fail_with_error("Metal 4 CPU counter resolution accepted a foreign fence", metal4_error);
            return 66;
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
        [metal4_copy_encoder optimizeContentsForCPUAccess:metal4_texture_copy];
        [metal4_copy_encoder optimizeContentsForGPUAccess:metal4_buffer_texture slice:0 level:0];
        MTLIndirectCommandBufferDescriptor *metal4_copy_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        metal4_copy_icb_descriptor.commandTypes = MTLIndirectCommandTypeDraw;
        id<MTLIndirectCommandBuffer> metal4_copy_icb_source =
            [adapter_device newIndirectCommandBufferWithDescriptor:metal4_copy_icb_descriptor
                                                     maxCommandCount:2 options:MTLResourceStorageModeShared];
        id<MTLIndirectCommandBuffer> metal4_copy_icb_destination =
            [adapter_device newIndirectCommandBufferWithDescriptor:metal4_copy_icb_descriptor
                                                     maxCommandCount:2 options:MTLResourceStorageModeShared];
        [metal4_copy_encoder resetCommandsInBuffer:metal4_copy_icb_source withRange:NSMakeRange(0, 2)];
        [metal4_copy_encoder copyIndirectCommandBuffer:metal4_copy_icb_source sourceRange:NSMakeRange(0, 2)
                                           destination:metal4_copy_icb_destination destinationIndex:0];
        [metal4_copy_encoder optimizeIndirectCommandBuffer:metal4_copy_icb_destination withRange:NSMakeRange(0, 2)];
        [metal4_copy_encoder endEncoding];
        [metal4_copy_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> metal4_copy_command_buffers[] = {metal4_copy_command_buffer};
        [metal4_queue commit:metal4_copy_command_buffers count:1];
        if (metal4_buffer_copy == nil || metal4_texture_copy == nil || metal4_texture_back == nil ||
            metal4_buffer_texture == nil || metal4_buffer_back == nil || metal4_filled_buffer == nil ||
            metal4_copy_icb_source == nil || metal4_copy_icb_destination == nil ||
            metal4_copy_command_buffer == nil ||
            metal4_copy_encoder == nil ||
            [metal4_copy_encoder stages] != MTLStageBlit ||
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

        if ([adapter_device newComputePipelineStateWithFunction:native_copy_function
                                                           error:&adapter_compute_error] != nil) {
            fprintf(stderr, "metal-pixel: adapter accepted a native Metal compute function\n");
            return 130;
        }

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
        [adapter_compute_icb_command setImageblockWidth:2 height:2];
        [adapter_compute_icb_command setThreadgroupMemoryLength:16 atIndex:0];
        [adapter_compute_icb_command setStageInRegion:MTLRegionMake2D(1, 1, 2, 2)];
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

        /* With buffer inheritance disabled, a command that omits its kernel
         * buffer must not accidentally consume the compute encoder's prior
         * binding. Native Metal rejects this dispatch; keep the CPU adapter
         * equally fail-closed while retaining ZPU ownership of the resources. */
        MTLIndirectCommandBufferDescriptor *noninherited_compute_descriptor = [compute_icb_descriptor copy];
        noninherited_compute_descriptor.inheritBuffers = NO;
        id<MTLIndirectCommandBuffer> noninherited_compute_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:noninherited_compute_descriptor
                                                     maxCommandCount:1 options:MTLResourceStorageModeShared];
        id<MTLIndirectComputeCommand> noninherited_compute_command =
            [noninherited_compute_icb indirectComputeCommandAtIndex:0];
        [noninherited_compute_command setComputePipelineState:adapter_icb_compute_pipeline];
        [noninherited_compute_command concurrentDispatchThreads:MTLSizeMake(width, height, 1)
                                               threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        id<MTLTexture> noninherited_compute_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> noninherited_compute_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> noninherited_compute_encoder =
            [noninherited_compute_command_buffer computeCommandEncoder];
        [noninherited_compute_encoder setBuffer:adapter_copy_buffer offset:0 atIndex:0];
        [noninherited_compute_encoder setTexture:noninherited_compute_texture atIndex:1];
        [noninherited_compute_encoder executeCommandsInBuffer:noninherited_compute_icb withRange:NSMakeRange(0, 1)];
        [noninherited_compute_encoder endEncoding];
        [noninherited_compute_command_buffer commit];
        [noninherited_compute_command_buffer waitUntilCompleted];
        if (noninherited_compute_icb == nil || noninherited_compute_command == nil ||
            noninherited_compute_texture == nil || noninherited_compute_encoder == nil ||
            noninherited_compute_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: non-inherited indirect compute buffer binding did not fail closed\n");
            return 136;
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

        /* As with render ICBs, the fixed CPU compute ABI has one representable
         * kernel-buffer slot. Do not accept a larger descriptor and later
         * replay its index-one binding as index zero. */
        MTLIndirectCommandBufferDescriptor *invalid_compute_binding_descriptor = [compute_icb_descriptor copy];
        invalid_compute_binding_descriptor.maxKernelBufferBindCount = 2;
        id<MTLIndirectCommandBuffer> invalid_compute_binding_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:invalid_compute_binding_descriptor
                                                    maxCommandCount:1 options:MTLResourceStorageModeShared];
        id<MTLIndirectComputeCommand> invalid_compute_binding_command =
            [invalid_compute_binding_icb indirectComputeCommandAtIndex:0];
        [invalid_compute_binding_command setComputePipelineState:adapter_icb_compute_pipeline];
        [invalid_compute_binding_command setKernelBuffer:adapter_copy_buffer offset:0 atIndex:1];
        [invalid_compute_binding_command concurrentDispatchThreads:MTLSizeMake(width, height, 1)
                                               threadsPerThreadgroup:MTLSizeMake(2, 2, 1)];
        id<MTLTexture> invalid_compute_binding_texture =
            [adapter_device newTextureWithDescriptor:compute_texture_descriptor];
        id<MTLCommandBuffer> invalid_compute_binding_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> invalid_compute_binding_encoder =
            [invalid_compute_binding_command_buffer computeCommandEncoder];
        [invalid_compute_binding_encoder setTexture:invalid_compute_binding_texture atIndex:1];
        [invalid_compute_binding_encoder executeCommandsInBuffer:invalid_compute_binding_icb withRange:NSMakeRange(0, 1)];
        [invalid_compute_binding_encoder endEncoding];
        [invalid_compute_binding_command_buffer commit];
        [invalid_compute_binding_command_buffer waitUntilCompleted];
        if (invalid_compute_binding_icb == nil || invalid_compute_binding_command == nil ||
            invalid_compute_binding_texture == nil || invalid_compute_binding_encoder == nil ||
            invalid_compute_binding_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: indirect kernel binding index did not fail closed\n");
            return 130;
        }

        if (@available(macOS 14.0, *)) {
            MTLIndirectCommandBufferDescriptor *invalid_memory_icb_descriptor = [compute_icb_descriptor copy];
            invalid_memory_icb_descriptor.maxKernelThreadgroupMemoryBindCount = 0;
            id<MTLIndirectCommandBuffer> invalid_memory_icb =
                [adapter_device newIndirectCommandBufferWithDescriptor:invalid_memory_icb_descriptor
                                                         maxCommandCount:1 options:MTLResourceStorageModeShared];
            id<MTLIndirectComputeCommand> invalid_memory_command =
                [invalid_memory_icb indirectComputeCommandAtIndex:0];
            [invalid_memory_command setThreadgroupMemoryLength:16 atIndex:0];
            id<MTLCommandBuffer> invalid_memory_command_buffer = [adapter_queue commandBuffer];
            id<MTLComputeCommandEncoder> invalid_memory_encoder =
                [invalid_memory_command_buffer computeCommandEncoder];
            [invalid_memory_encoder setTexture:adapter_compute_icb_texture atIndex:1];
            [invalid_memory_encoder executeCommandsInBuffer:invalid_memory_icb withRange:NSMakeRange(0, 1)];
            [invalid_memory_encoder endEncoding];
            [invalid_memory_command_buffer commit];
            [invalid_memory_command_buffer waitUntilCompleted];
            if (invalid_memory_icb == nil || invalid_memory_command == nil ||
                invalid_memory_command_buffer.status != MTLCommandBufferStatusError) {
                fprintf(stderr, "metal-pixel: indirect compute threadgroup-memory limit did not fail closed\n");
                return 60;
            }
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
        [adapter_argument_encoder setRenderPipelineState:adapter_pipeline atIndex:6];
        [adapter_argument_encoder setIndirectCommandBuffer:adapter_compute_icb atIndex:3];
        id<MTLArgumentEncoder> nested_argument_encoder =
            [adapter_argument_encoder newArgumentEncoderForBufferAtIndex:0];
        uint64_t encoded_argument_resource = 0;
        uint64_t encoded_argument_offset = 0;
        uint64_t encoded_argument_icb_resource = 0;
        uint64_t encoded_argument_compute_pipeline_resource = 0;
        uint64_t encoded_argument_render_pipeline_resource = 0;
        if (adapter_argument_buffer != nil) {
            memcpy(&encoded_argument_resource, adapter_argument_buffer.contents, sizeof(encoded_argument_resource));
            memcpy(&encoded_argument_offset, (uint8_t *)adapter_argument_buffer.contents + sizeof(encoded_argument_resource), sizeof(encoded_argument_offset));
            memcpy(&encoded_argument_compute_pipeline_resource, (uint8_t *)adapter_argument_buffer.contents + 2 * 16,
                   sizeof(encoded_argument_compute_pipeline_resource));
            memcpy(&encoded_argument_icb_resource, (uint8_t *)adapter_argument_buffer.contents + 3 * 16,
                   sizeof(encoded_argument_icb_resource));
            memcpy(&encoded_argument_render_pipeline_resource, (uint8_t *)adapter_argument_buffer.contents + 6 * 16,
                   sizeof(encoded_argument_render_pipeline_resource));
        }
        if (adapter_argument_encoder == nil || adapter_argument_buffer == nil || nested_argument_encoder == nil ||
            [adapter_argument_encoder encodedLength] < 16 || [adapter_argument_encoder alignment] != 16 ||
            bound_constant_data == NULL || memcmp(bound_constant_data, &argument_constant, sizeof(argument_constant)) != 0 ||
            encoded_argument_resource != adapter_copy_buffer.gpuAddress || encoded_argument_offset != 0 ||
            encoded_argument_compute_pipeline_resource != adapter_icb_compute_pipeline.gpuResourceID._impl ||
            encoded_argument_icb_resource != adapter_compute_icb.gpuResourceID._impl ||
            encoded_argument_render_pipeline_resource != adapter_pipeline.gpuResourceID._impl) {
            fprintf(stderr, "metal-pixel: CPU argument encoder allocation failed\n");
            return 49;
        }

        /* A count-based NSArray-style range must not wrap its final binding
         * index. The second entry below would alias slot zero if
         * location + index were evaluated without overflow checking. */
        id<MTLBuffer> argument_range_overflow_buffer =
            [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
        id<MTLBuffer> argument_range_overflow_bindings[2] = {nil, argument_range_overflow_buffer};
        NSUInteger argument_range_overflow_offsets[2] = {0, 0};
        [adapter_argument_encoder setBuffers:argument_range_overflow_bindings
                                      offsets:argument_range_overflow_offsets
                                    withRange:NSMakeRange(NSUIntegerMax, 2)];
        uint64_t range_overflow_resource = 0;
        if (adapter_argument_buffer != nil) {
            memcpy(&range_overflow_resource, adapter_argument_buffer.contents, sizeof(range_overflow_resource));
        }
        if (argument_range_overflow_buffer == nil || range_overflow_resource != adapter_copy_buffer.gpuAddress) {
            fprintf(stderr, "metal-pixel: CPU argument encoder range overflow wrapped a binding\n");
            return 51;
        }

        /* A bound constantDataAtIndex: pointer aliases the selected argument
         * buffer. Rebinding must preserve those bytes and must not accept an
         * unaligned or truncated destination. */
        const uint32_t rebound_argument_constant = 0xcafebabe;
        memcpy(bound_constant_data, &rebound_argument_constant, sizeof(rebound_argument_constant));
        [adapter_argument_encoder setArgumentBuffer:adapter_argument_buffer offset:32];
        void *rebound_constant_data = [adapter_argument_encoder constantDataAtIndex:5];
        uint32_t rebound_argument_readback = 0;
        if (rebound_constant_data != NULL) {
            memcpy(&rebound_argument_readback, rebound_constant_data, sizeof(rebound_argument_readback));
        }
        [adapter_argument_encoder setArgumentBuffer:adapter_argument_buffer offset:8];
        void *unaligned_constant_data = [adapter_argument_encoder constantDataAtIndex:5];
        [adapter_argument_encoder setArgumentBuffer:adapter_argument_buffer offset:0];
        void *restored_constant_data = [adapter_argument_encoder constantDataAtIndex:5];
        uint32_t restored_argument_readback = 0;
        if (restored_constant_data != NULL) {
            memcpy(&restored_argument_readback, restored_constant_data, sizeof(restored_argument_readback));
        }
        if (rebound_constant_data == NULL || rebound_argument_readback != rebound_argument_constant ||
            unaligned_constant_data != rebound_constant_data || restored_argument_readback != rebound_argument_constant) {
            fprintf(stderr, "metal-pixel: CPU argument encoder rebind/range semantics failed\n");
            return 50;
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
        uint8_t adapter_metal4_origin_vertex_bytes[sizeof(origin_vertices) + 16] = {0};
        memcpy(adapter_metal4_origin_vertex_bytes + 16, origin_vertices, sizeof(origin_vertices));
        id<MTLBuffer> adapter_metal4_origin_vertex_buffer =
            [adapter_device newBufferWithBytes:adapter_metal4_origin_vertex_bytes
                                         length:sizeof(adapter_metal4_origin_vertex_bytes)
                                        options:MTLResourceStorageModeShared];
        MTL4RenderPassDescriptor *adapter_metal4_origin_pass = [MTL4RenderPassDescriptor new];
        adapter_metal4_origin_pass.colorAttachments[0].texture = adapter_metal4_origin_texture;
        adapter_metal4_origin_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_origin_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_origin_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        MTL4ArgumentTableDescriptor *adapter_metal4_origin_table_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_origin_table_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_origin_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_origin_table_descriptor error:&metal4_error];
        [adapter_metal4_origin_table setAddress:adapter_metal4_origin_vertex_buffer.gpuAddress + 16 atIndex:0];
        id<MTL4CommandBuffer> adapter_metal4_origin_command_buffer = [adapter_device newCommandBuffer];
        [adapter_metal4_origin_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_origin_encoder =
            [adapter_metal4_origin_command_buffer renderCommandEncoderWithDescriptor:adapter_metal4_origin_pass];
        [adapter_metal4_origin_encoder setRenderPipelineState:adapter_pipeline];
        MTLLogicalToPhysicalColorAttachmentMap *identity_color_map =
            [MTLLogicalToPhysicalColorAttachmentMap new];
        for (NSUInteger color_index = 0; color_index < 8; ++color_index) {
            [identity_color_map setPhysicalIndex:color_index forLogicalIndex:color_index];
        }
        [adapter_metal4_origin_encoder setColorAttachmentMap:identity_color_map];
        [adapter_metal4_origin_encoder setColorStoreAction:MTLStoreActionStore atIndex:0];
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
        if (adapter_metal4_origin_texture == nil || adapter_metal4_origin_vertex_buffer == nil ||
            adapter_metal4_origin_table == nil ||
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

        /* ZPU has one top-left viewport and scissor state. Never silently
         * discard additional entries, since doing so could change either
         * axis of the rendered pixel grid. */
        MTLViewport invalid_viewports[2] = {origin_viewport, origin_viewport};
        MTLScissorRect invalid_scissors[2] = {origin_scissor, origin_scissor};
        MTLRenderPassDescriptor *invalid_grid_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        invalid_grid_pass.colorAttachments[0].texture = adapter_metal4_origin_texture;
        invalid_grid_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        invalid_grid_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> invalid_grid_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> invalid_grid_encoder =
            [invalid_grid_command_buffer renderCommandEncoderWithDescriptor:invalid_grid_pass];
        [invalid_grid_encoder setViewports:invalid_viewports count:2];
        [invalid_grid_encoder setScissorRects:invalid_scissors count:2];
        [invalid_grid_encoder endEncoding];
        [invalid_grid_command_buffer commit];
        [invalid_grid_command_buffer waitUntilCompleted];
        if (invalid_grid_command_buffer == nil || invalid_grid_encoder == nil ||
            invalid_grid_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: CPU Metal accepted unrepresentable multi-viewport grid state\n");
            return 70;
        }

        /* A color attachment remap changes the logical-to-physical pixel
         * destination. The CPU rasterizer has one fixed attachment mapping,
         * so identity is accepted and every non-identity map must fail
         * closed instead of silently producing pixels in another attachment.
         */
        MTLLogicalToPhysicalColorAttachmentMap *invalid_color_map =
            [MTLLogicalToPhysicalColorAttachmentMap new];
        [invalid_color_map setPhysicalIndex:1 forLogicalIndex:0];
        MTLRenderPassDescriptor *invalid_color_map_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        invalid_color_map_pass.colorAttachments[0].texture = adapter_metal4_origin_texture;
        invalid_color_map_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        invalid_color_map_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> invalid_color_map_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> invalid_color_map_encoder =
            [invalid_color_map_command_buffer renderCommandEncoderWithDescriptor:invalid_color_map_pass];
        [invalid_color_map_encoder setColorAttachmentMap:invalid_color_map];
        [invalid_color_map_encoder endEncoding];
        [invalid_color_map_command_buffer commit];
        [invalid_color_map_command_buffer waitUntilCompleted];
        if (invalid_color_map_command_buffer == nil || invalid_color_map_encoder == nil ||
            invalid_color_map_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: CPU Metal accepted a non-identity color attachment map\n");
            return 71;
        }

        /* A single-sample CPU target cannot represent a multisample resolve
         * store action. Do not coerce it to ordinary Store, which would make
         * the public pass descriptor and resulting bytes disagree. */
        MTLRenderPassDescriptor *unsupported_store_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        unsupported_store_pass.colorAttachments[0].texture = adapter_metal4_origin_texture;
        unsupported_store_pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        unsupported_store_pass.colorAttachments[0].storeAction = MTLStoreActionMultisampleResolve;
        id<MTLCommandBuffer> unsupported_store_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> unsupported_store_encoder =
            [unsupported_store_command_buffer renderCommandEncoderWithDescriptor:unsupported_store_pass];
        BOOL unsupported_store_rejected = unsupported_store_encoder == nil;
        if (unsupported_store_encoder != nil) {
            [unsupported_store_encoder endEncoding];
            [unsupported_store_command_buffer commit];
            [unsupported_store_command_buffer waitUntilCompleted];
            unsupported_store_rejected = unsupported_store_command_buffer.status == MTLCommandBufferStatusError;
        }
        if (!unsupported_store_rejected) {
            fprintf(stderr, "metal-pixel: CPU Metal coerced an unsupported multisample store action\n");
            return 133;
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

        /* Metal 4 sampler bindings are resource IDs rather than Objective-C
         * sampler objects at the encoder call site. Resolve them through the
         * CPU-owned table and compare the resulting sampled pixels with the
         * native Metal oracle. The quad deliberately uses an asymmetric
         * viewport-independent UV pattern so nearest filtering and the
         * attachment's top-left row origin are both observable. */
        id<MTLTexture> adapter_metal4_sampler_texture =
            [adapter_device newTextureWithDescriptor:sample_output_descriptor];
        MTL4RenderPassDescriptor *adapter_metal4_sampler_pass = [MTL4RenderPassDescriptor new];
        adapter_metal4_sampler_pass.colorAttachments[0].texture = adapter_metal4_sampler_texture;
        adapter_metal4_sampler_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_metal4_sampler_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_metal4_sampler_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        MTL4ArgumentTableDescriptor *adapter_metal4_sampler_vertex_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_sampler_vertex_descriptor.maxBufferBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_sampler_vertex_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_sampler_vertex_descriptor error:&metal4_error];
        [adapter_metal4_sampler_vertex_table setAddress:adapter_sample_vertex_buffer.gpuAddress atIndex:0];
        MTL4ArgumentTableDescriptor *adapter_metal4_sampler_fragment_descriptor = [MTL4ArgumentTableDescriptor new];
        adapter_metal4_sampler_fragment_descriptor.maxTextureBindCount = 1;
        adapter_metal4_sampler_fragment_descriptor.maxSamplerStateBindCount = 1;
        id<MTL4ArgumentTable> adapter_metal4_sampler_fragment_table =
            [adapter_device newArgumentTableWithDescriptor:adapter_metal4_sampler_fragment_descriptor error:&metal4_error];
        [adapter_metal4_sampler_fragment_table setTexture:adapter_sample_source.gpuResourceID atIndex:0];
        [adapter_metal4_sampler_fragment_table setSamplerState:adapter_sample_sampler.gpuResourceID atIndex:0];
        id<MTL4CommandBuffer> adapter_metal4_sampler_command_buffer = [adapter_device newCommandBuffer];
        [adapter_metal4_sampler_command_buffer beginCommandBufferWithAllocator:metal4_allocator];
        id<MTL4RenderCommandEncoder> adapter_metal4_sampler_encoder =
            [adapter_metal4_sampler_command_buffer renderCommandEncoderWithDescriptor:adapter_metal4_sampler_pass];
        [adapter_metal4_sampler_encoder setRenderPipelineState:adapter_sample_pipeline];
        [adapter_metal4_sampler_encoder setArgumentTable:adapter_metal4_sampler_vertex_table
                                                 atStages:MTLRenderStageVertex];
        [adapter_metal4_sampler_encoder setArgumentTable:adapter_metal4_sampler_fragment_table
                                                 atStages:MTLRenderStageFragment];
        [adapter_metal4_sampler_encoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];
        [adapter_metal4_sampler_encoder endEncoding];
        [adapter_metal4_sampler_command_buffer endCommandBuffer];
        id<MTL4CommandBuffer> adapter_metal4_sampler_command_buffers[] = {adapter_metal4_sampler_command_buffer};
        [metal4_queue commit:adapter_metal4_sampler_command_buffers count:1];
        uint8_t adapter_metal4_sampler_pixels[byte_count];
        [adapter_metal4_sampler_texture getBytes:adapter_metal4_sampler_pixels
                                      bytesPerRow:(NSUInteger)width * 4
                                       fromRegion:MTLRegionMake2D(0, 0, width, height)
                                      mipmapLevel:0];
        if (adapter_metal4_sampler_texture == nil || adapter_metal4_sampler_vertex_table == nil ||
            adapter_metal4_sampler_fragment_table == nil || adapter_metal4_sampler_command_buffer == nil ||
            adapter_metal4_sampler_encoder == nil ||
            memcmp(native_sample_bytes, adapter_metal4_sampler_pixels, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && native_sample_bytes[mismatch] == adapter_metal4_sampler_pixels[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: Metal 4 sampler table mismatch (mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    mismatch,
                    mismatch < byte_count ? native_sample_bytes[mismatch] : 0,
                    mismatch < byte_count ? adapter_metal4_sampler_pixels[mismatch] : 0);
            return 101;
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
        MTLCommandBufferDescriptor *adapter_unretained_descriptor = [MTLCommandBufferDescriptor new];
        adapter_unretained_descriptor.retainedReferences = NO;
        adapter_unretained_descriptor.errorOptions = MTLCommandBufferErrorOptionEncoderExecutionStatus;
        id<MTLCommandBuffer> adapter_unretained_command_buffer =
            [adapter_queue commandBufferWithUnretainedReferences];
        id<MTLCommandBuffer> adapter_descriptor_command_buffer =
            [adapter_queue commandBufferWithDescriptor:adapter_unretained_descriptor];
        if (adapter_unretained_command_buffer == nil || adapter_unretained_command_buffer.retainedReferences ||
            adapter_descriptor_command_buffer == nil || adapter_descriptor_command_buffer.retainedReferences ||
            adapter_descriptor_command_buffer.errorOptions != MTLCommandBufferErrorOptionEncoderExecutionStatus) {
            fprintf(stderr, "metal-pixel: CPU command-buffer retention/options metadata failed\n");
            return 22;
        }
        id<MTLCommandBuffer> malformed_binding_range_command_buffer = [adapter_queue commandBuffer];
        id<MTLComputeCommandEncoder> malformed_binding_range_encoder =
            [malformed_binding_range_command_buffer computeCommandEncoder];
        id<MTLBuffer> malformed_binding_buffers[] = {adapter_copy_buffer};
        const NSUInteger malformed_binding_offsets[] = {0};
        [malformed_binding_range_encoder setBuffers:malformed_binding_buffers
                                            offsets:malformed_binding_offsets
                                          withRange:NSMakeRange(NSUIntegerMax, 2)];
        [malformed_binding_range_encoder endEncoding];
        [malformed_binding_range_command_buffer commit];
        [malformed_binding_range_command_buffer waitUntilCompleted];
        if (malformed_binding_range_encoder == nil ||
            malformed_binding_range_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: overflowing CPU binding range did not fail closed\n");
            return 23;
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

        MTLRenderPipelineDescriptor *adapter_blend_descriptor = [blend_descriptor copy];
        adapter_blend_descriptor.vertexFunction = adapter_vertex_function;
        adapter_blend_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_blend_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_blend_descriptor error:&adapter_pipeline_error];
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
        [adapter_heap setLabel:@"zpu cpu heap"];
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
        if (adapter_heap == nil || ![adapter_heap.label isEqualToString:@"zpu cpu heap"] ||
            adapter_heap_mismatched_buffer != nil ||
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
        if (metal_icb.size != 1 || adapter_icb.size != metal_icb.size ||
            metal_icb.gpuResourceID._impl == 0 || adapter_icb.gpuResourceID._impl == 0 ||
            adapter_icb.resourceOptions != (MTLResourceStorageModePrivate | MTLResourceHazardTrackingModeUntracked) ||
            adapter_icb.storageMode != MTLStorageModePrivate ||
            adapter_icb.hazardTrackingMode != MTLHazardTrackingModeUntracked) {
            fprintf(stderr, "metal-pixel: indirect command buffer size/resource metadata failed\n");
            return 56;
        }
        for (size_t index = 0; index < byte_count; index++) {
            if (metal_icb_pixels[index] != adapter_icb_pixels[index]) {
                fprintf(stderr, "metal-pixel: indirect command buffer mismatch at byte %zu: Metal=%u ZPU=%u\n",
                        index, metal_icb_pixels[index], adapter_icb_pixels[index]);
                return 40;
            }
        }

        /* ICB dynamic vertex strides are part of the command, not the
         * encoder. Preserve the stride through CPU replay and compare the
         * stage-in result with Apple's native ICB byte-for-byte. */
        if (@available(macOS 14.0, iOS 17.0, *)) {
            const NSUInteger dynamic_icb_stride = 48;
            uint8_t dynamic_icb_vertices[6 * dynamic_icb_stride];
            memset(dynamic_icb_vertices, 0xcd, sizeof(dynamic_icb_vertices));
            for (NSUInteger index = 0; index < 6; ++index) {
                memcpy(dynamic_icb_vertices + index * dynamic_icb_stride,
                       &vertices[index], sizeof(vertices[index]));
            }
            MTLVertexDescriptor *dynamic_icb_vertex_descriptor = [MTLVertexDescriptor vertexDescriptor];
            dynamic_icb_vertex_descriptor.attributes[0].format = MTLVertexFormatFloat4;
            dynamic_icb_vertex_descriptor.attributes[0].offset = 0;
            dynamic_icb_vertex_descriptor.attributes[0].bufferIndex = 0;
            dynamic_icb_vertex_descriptor.attributes[1].format = MTLVertexFormatFloat4;
            dynamic_icb_vertex_descriptor.attributes[1].offset = sizeof(float) * 4;
            dynamic_icb_vertex_descriptor.attributes[1].bufferIndex = 0;
            dynamic_icb_vertex_descriptor.layouts[0].stride = MTLBufferLayoutStrideDynamic;
            dynamic_icb_vertex_descriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;
            dynamic_icb_vertex_descriptor.layouts[0].stepRate = 1;
            MTLRenderPipelineDescriptor *native_dynamic_icb_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
            native_dynamic_icb_pipeline_descriptor.vertexFunction = stage_in_vertex_function;
            native_dynamic_icb_pipeline_descriptor.fragmentFunction = fragment_function;
            native_dynamic_icb_pipeline_descriptor.vertexDescriptor = dynamic_icb_vertex_descriptor;
            native_dynamic_icb_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            native_dynamic_icb_pipeline_descriptor.supportIndirectCommandBuffers = YES;
            MTLRenderPipelineDescriptor *adapter_dynamic_icb_pipeline_descriptor = [MTLRenderPipelineDescriptor new];
            adapter_dynamic_icb_pipeline_descriptor.vertexFunction = adapter_stage_in_vertex_function;
            adapter_dynamic_icb_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
            adapter_dynamic_icb_pipeline_descriptor.vertexDescriptor = [dynamic_icb_vertex_descriptor copy];
            adapter_dynamic_icb_pipeline_descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
            adapter_dynamic_icb_pipeline_descriptor.supportIndirectCommandBuffers = YES;
            id<MTLRenderPipelineState> native_dynamic_icb_pipeline =
                [device newRenderPipelineStateWithDescriptor:native_dynamic_icb_pipeline_descriptor error:&error];
            id<MTLRenderPipelineState> adapter_dynamic_icb_pipeline =
                [adapter_device newRenderPipelineStateWithDescriptor:adapter_dynamic_icb_pipeline_descriptor
                                                                 error:&adapter_pipeline_error];
            MTLIndirectCommandBufferDescriptor *dynamic_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
            dynamic_icb_descriptor.commandTypes = MTLIndirectCommandTypeDraw;
            dynamic_icb_descriptor.inheritPipelineState = YES;
            dynamic_icb_descriptor.inheritBuffers = NO;
            dynamic_icb_descriptor.maxVertexBufferBindCount = 1;
            dynamic_icb_descriptor.supportDynamicAttributeStride = YES;
            id<MTLIndirectCommandBuffer> native_dynamic_icb =
                [device newIndirectCommandBufferWithDescriptor:dynamic_icb_descriptor
                                                maxCommandCount:1 options:0];
            id<MTLIndirectCommandBuffer> adapter_dynamic_icb =
                [adapter_device newIndirectCommandBufferWithDescriptor:dynamic_icb_descriptor
                                                        maxCommandCount:1 options:MTLResourceStorageModeShared];
            id<MTLIndirectRenderCommand> native_dynamic_icb_command =
                [native_dynamic_icb indirectRenderCommandAtIndex:0];
            id<MTLIndirectRenderCommand> adapter_dynamic_icb_command =
                [adapter_dynamic_icb indirectRenderCommandAtIndex:0];
            id<MTLBuffer> native_dynamic_icb_buffer =
                [device newBufferWithBytes:dynamic_icb_vertices length:sizeof(dynamic_icb_vertices)
                                   options:MTLResourceStorageModeShared];
            id<MTLBuffer> adapter_dynamic_icb_buffer =
                [adapter_device newBufferWithBytes:dynamic_icb_vertices length:sizeof(dynamic_icb_vertices)
                                            options:MTLResourceStorageModeShared];
            [native_dynamic_icb_command setVertexBuffer:native_dynamic_icb_buffer offset:0
                                        attributeStride:dynamic_icb_stride atIndex:0];
            [adapter_dynamic_icb_command setVertexBuffer:adapter_dynamic_icb_buffer offset:0
                                          attributeStride:dynamic_icb_stride atIndex:0];
            [native_dynamic_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                          vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
            [adapter_dynamic_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                            vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
            id<MTLTexture> native_dynamic_icb_texture = [device newTextureWithDescriptor:texture_descriptor];
            id<MTLTexture> adapter_dynamic_icb_texture =
                [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
            MTLRenderPassDescriptor *native_dynamic_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            native_dynamic_icb_pass.colorAttachments[0].texture = native_dynamic_icb_texture;
            native_dynamic_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            native_dynamic_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            native_dynamic_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            MTLRenderPassDescriptor *adapter_dynamic_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
            adapter_dynamic_icb_pass.colorAttachments[0].texture = adapter_dynamic_icb_texture;
            adapter_dynamic_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
            adapter_dynamic_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
            adapter_dynamic_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            id<MTLCommandBuffer> native_dynamic_icb_command_buffer = [queue commandBuffer];
            id<MTLCommandBuffer> adapter_dynamic_icb_command_buffer = [adapter_queue commandBuffer];
            id<MTLRenderCommandEncoder> native_dynamic_icb_encoder =
                [native_dynamic_icb_command_buffer renderCommandEncoderWithDescriptor:native_dynamic_icb_pass];
            id<MTLRenderCommandEncoder> adapter_dynamic_icb_encoder =
                [adapter_dynamic_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_dynamic_icb_pass];
            [native_dynamic_icb_encoder setRenderPipelineState:native_dynamic_icb_pipeline];
            [adapter_dynamic_icb_encoder setRenderPipelineState:adapter_dynamic_icb_pipeline];
            [native_dynamic_icb_encoder useResource:native_dynamic_icb_buffer
                                             usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
            [native_dynamic_icb_encoder useResource:native_dynamic_icb
                                             usage:MTLResourceUsageRead stages:MTLRenderStageVertex];
            [adapter_dynamic_icb_encoder executeCommandsInBuffer:adapter_dynamic_icb withRange:NSMakeRange(0, 1)];
            [native_dynamic_icb_encoder executeCommandsInBuffer:native_dynamic_icb withRange:NSMakeRange(0, 1)];
            [native_dynamic_icb_encoder endEncoding];
            [adapter_dynamic_icb_encoder endEncoding];
            [native_dynamic_icb_command_buffer commit];
            [adapter_dynamic_icb_command_buffer commit];
            [native_dynamic_icb_command_buffer waitUntilCompleted];
            [adapter_dynamic_icb_command_buffer waitUntilCompleted];
            uint8_t native_dynamic_icb_pixels[byte_count];
            uint8_t adapter_dynamic_icb_pixels[byte_count];
            [native_dynamic_icb_texture getBytes:native_dynamic_icb_pixels bytesPerRow:width * 4
                                       fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            [adapter_dynamic_icb_texture getBytes:adapter_dynamic_icb_pixels bytesPerRow:width * 4
                                         fromRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0];
            if (native_dynamic_icb_pipeline == nil || adapter_dynamic_icb_pipeline == nil ||
                native_dynamic_icb == nil || adapter_dynamic_icb == nil ||
                native_dynamic_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
                adapter_dynamic_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
                memcmp(native_dynamic_icb_pixels, adapter_dynamic_icb_pixels, byte_count) != 0) {
                fprintf(stderr, "metal-pixel: dynamic indirect vertex-stride bytes mismatch\n");
                fail_with_error("native dynamic indirect command error", native_dynamic_icb_command_buffer.error);
                fail_with_error("adapter dynamic indirect command error", adapter_dynamic_icb_command_buffer.error);
                return 144;
            }
        }

        /* The command buffer owns resources referenced by an encoded ICB
         * until completion. Verify that render replay retains the CPU-owned
         * ICB after the caller drops its last reference, while avoiding an
         * artificial command-to-ICB retain cycle. */
        __weak id<MTLIndirectCommandBuffer> weak_lifetime_icb = nil;
        id<MTLCommandBuffer> lifetime_command_buffer = [adapter_queue commandBuffer];
        id<MTLTexture> lifetime_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *lifetime_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        lifetime_pass.colorAttachments[0].texture = lifetime_texture;
        lifetime_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        lifetime_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> lifetime_encoder =
            [lifetime_command_buffer renderCommandEncoderWithDescriptor:lifetime_pass];
        id<MTLIndirectCommandBuffer> lifetime_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> lifetime_command = [lifetime_icb indirectRenderCommandAtIndex:0];
        [lifetime_command drawPrimitives:MTLPrimitiveTypeTriangle
                            vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        weak_lifetime_icb = lifetime_icb;
        [lifetime_encoder setRenderPipelineState:adapter_pipeline];
        [lifetime_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [lifetime_encoder executeCommandsInBuffer:lifetime_icb withRange:NSMakeRange(0, 1)];
        [lifetime_encoder endEncoding];
        lifetime_command = nil;
        lifetime_icb = nil;
        if (weak_lifetime_icb == nil) {
            fprintf(stderr, "metal-pixel: render ICB was not retained by command buffer\n");
            return 132;
        }
        [lifetime_command_buffer commit];
        [lifetime_command_buffer waitUntilCompleted];
        if (lifetime_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: retained render ICB command did not complete\n");
            fail_with_error("retained render ICB command error", lifetime_command_buffer.error);
            return 133;
        }

        const uint32_t lifetime_range_words[] = {0, 1};
        __weak id<MTLBuffer> weak_lifetime_range_buffer = nil;
        id<MTLBuffer> lifetime_range_buffer =
            [adapter_device newBufferWithBytes:lifetime_range_words
                                        length:sizeof(lifetime_range_words)
                                       options:MTLResourceStorageModeShared];
        weak_lifetime_range_buffer = lifetime_range_buffer;
        id<MTLTexture> indirect_range_lifetime_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *indirect_range_lifetime_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        indirect_range_lifetime_pass.colorAttachments[0].texture = indirect_range_lifetime_texture;
        indirect_range_lifetime_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        indirect_range_lifetime_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> indirect_range_lifetime_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> indirect_range_lifetime_encoder =
            [indirect_range_lifetime_command_buffer renderCommandEncoderWithDescriptor:indirect_range_lifetime_pass];
        [indirect_range_lifetime_encoder setRenderPipelineState:adapter_pipeline];
        [indirect_range_lifetime_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [indirect_range_lifetime_encoder executeCommandsInBuffer:adapter_icb
                                                   indirectBuffer:lifetime_range_buffer
                                              indirectBufferOffset:0];
        [indirect_range_lifetime_encoder endEncoding];
        lifetime_range_buffer = nil;
        if (weak_lifetime_range_buffer == nil) {
            fprintf(stderr, "metal-pixel: render ICB range buffer was not retained by command buffer\n");
            return 135;
        }
        [indirect_range_lifetime_command_buffer commit];
        [indirect_range_lifetime_command_buffer waitUntilCompleted];
        if (indirect_range_lifetime_command_buffer.status != MTLCommandBufferStatusCompleted) {
            fprintf(stderr, "metal-pixel: retained render ICB range command did not complete\n");
            fail_with_error("retained render ICB range command error", indirect_range_lifetime_command_buffer.error);
            return 136;
        }

        /* The CPU renderer currently has one representable vertex binding.
         * An ICB descriptor may advertise more slots, but accepting an index
         * other than zero would replay that resource at the wrong slot. The
         * adapter must poison the command instead of silently rebinding it. */
        MTLIndirectCommandBufferDescriptor *invalid_render_binding_descriptor = [icb_descriptor copy];
        invalid_render_binding_descriptor.maxVertexBufferBindCount = 2;
        id<MTLIndirectCommandBuffer> invalid_render_binding_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:invalid_render_binding_descriptor
                                                    maxCommandCount:1 options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> invalid_render_binding_command =
            [invalid_render_binding_icb indirectRenderCommandAtIndex:0];
        [invalid_render_binding_command setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:1];
        [invalid_render_binding_command drawPrimitives:MTLPrimitiveTypeTriangle
                                          vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> invalid_render_binding_texture =
            [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *invalid_render_binding_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        invalid_render_binding_pass.colorAttachments[0].texture = invalid_render_binding_texture;
        invalid_render_binding_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        invalid_render_binding_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> invalid_render_binding_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> invalid_render_binding_encoder =
            [invalid_render_binding_command_buffer renderCommandEncoderWithDescriptor:invalid_render_binding_pass];
        [invalid_render_binding_encoder setRenderPipelineState:adapter_pipeline];
        [invalid_render_binding_encoder executeCommandsInBuffer:invalid_render_binding_icb withRange:NSMakeRange(0, 1)];
        [invalid_render_binding_encoder endEncoding];
        [invalid_render_binding_command_buffer commit];
        [invalid_render_binding_command_buffer waitUntilCompleted];
        if (invalid_render_binding_icb == nil || invalid_render_binding_command == nil ||
            invalid_render_binding_texture == nil || invalid_render_binding_encoder == nil ||
            invalid_render_binding_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: indirect vertex binding index did not fail closed\n");
            return 129;
        }

        /* Indexed ICB commands carry their index resource inside the CPU
         * command record. Compare that deferred path against Apple's native
         * command buffer so index type, offset, and lookup semantics remain
         * pixel-identical as well. */
        MTLIndirectCommandBufferDescriptor *indexed_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        indexed_icb_descriptor.commandTypes = MTLIndirectCommandTypeDrawIndexed;
        indexed_icb_descriptor.inheritPipelineState = YES;
        indexed_icb_descriptor.inheritBuffers = YES;
        indexed_icb_descriptor.maxVertexBufferBindCount = 1;
        id<MTLIndirectCommandBuffer> metal_indexed_icb =
            [device newIndirectCommandBufferWithDescriptor:indexed_icb_descriptor
                                           maxCommandCount:1
                                                   options:0];
        id<MTLIndirectRenderCommand> metal_indexed_icb_command =
            [metal_indexed_icb indirectRenderCommandAtIndex:0];
        [metal_indexed_icb_command drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                              indexCount:6
                                               indexType:MTLIndexTypeUInt16
                                           indexBuffer:native_indexed_commit_indices
                                     indexBufferOffset:0
                                          instanceCount:1
                                           baseVertex:0
                                         baseInstance:0];
        id<MTLTexture> metal_indexed_icb_texture = [device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *metal_indexed_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_indexed_icb_pass.colorAttachments[0].texture = metal_indexed_icb_texture;
        metal_indexed_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_indexed_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_indexed_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> metal_indexed_icb_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_indexed_icb_encoder =
            [metal_indexed_icb_command_buffer renderCommandEncoderWithDescriptor:metal_indexed_icb_pass];
        [metal_indexed_icb_encoder setRenderPipelineState:pipeline];
        [metal_indexed_icb_encoder setVertexBuffer:native_indexed_commit_vertices offset:0 atIndex:0];
        [metal_indexed_icb_encoder useResource:native_indexed_commit_vertices
                                         usage:MTLResourceUsageRead
                                         stages:MTLRenderStageVertex];
        [metal_indexed_icb_encoder useResource:native_indexed_commit_indices
                                         usage:MTLResourceUsageRead
                                         stages:MTLRenderStageVertex];
        [metal_indexed_icb_encoder useResource:metal_indexed_icb
                                         usage:MTLResourceUsageRead
                                         stages:MTLRenderStageVertex];
        [metal_indexed_icb_encoder executeCommandsInBuffer:metal_indexed_icb withRange:NSMakeRange(0, 1)];
        [metal_indexed_icb_encoder endEncoding];
        [metal_indexed_icb_command_buffer commit];
        [metal_indexed_icb_command_buffer waitUntilCompleted];
        uint8_t metal_indexed_icb_pixels[byte_count];
        [metal_indexed_icb_texture getBytes:metal_indexed_icb_pixels
                                  bytesPerRow:(NSUInteger)width * 4
                                  fromRegion:MTLRegionMake2D(0, 0, width, height)
                                 mipmapLevel:0];

        id<MTLIndirectCommandBuffer> adapter_indexed_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:indexed_icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_indexed_icb_command =
            [adapter_indexed_icb indirectRenderCommandAtIndex:0];
        [adapter_indexed_icb_command drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                                                indexCount:6
                                                 indexType:MTLIndexTypeUInt16
                                             indexBuffer:adapter_indexed_commit_indices
                                       indexBufferOffset:0
                                            instanceCount:1
                                             baseVertex:0
                                           baseInstance:0];
        id<MTLTexture> adapter_indexed_icb_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_indexed_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_indexed_icb_pass.colorAttachments[0].texture = adapter_indexed_icb_texture;
        adapter_indexed_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_indexed_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_indexed_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_indexed_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_indexed_icb_encoder =
            [adapter_indexed_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_indexed_icb_pass];
        [adapter_indexed_icb_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_indexed_icb_encoder setVertexBuffer:adapter_indexed_commit_vertices offset:0 atIndex:0];
        [adapter_indexed_icb_encoder executeCommandsInBuffer:adapter_indexed_icb withRange:NSMakeRange(0, 1)];
        [adapter_indexed_icb_encoder endEncoding];
        [adapter_indexed_icb_command_buffer commit];
        [adapter_indexed_icb_command_buffer waitUntilCompleted];
        uint8_t adapter_indexed_icb_pixels[byte_count];
        [adapter_indexed_icb_texture getBytes:adapter_indexed_icb_pixels
                                    bytesPerRow:(NSUInteger)width * 4
                                    fromRegion:MTLRegionMake2D(0, 0, width, height)
                                   mipmapLevel:0];
        if (metal_indexed_icb == nil || metal_indexed_icb_command == nil ||
            metal_indexed_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_indexed_icb == nil || adapter_indexed_icb_command == nil ||
            adapter_indexed_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_indexed_icb_pixels, adapter_indexed_icb_pixels, byte_count) != 0) {
            size_t mismatch = 0;
            while (mismatch < byte_count && metal_indexed_icb_pixels[mismatch] == adapter_indexed_icb_pixels[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: indexed indirect command buffer mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)metal_indexed_icb_command_buffer.status,
                    (unsigned long)adapter_indexed_icb_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? metal_indexed_icb_pixels[mismatch] : 0,
                    mismatch < byte_count ? adapter_indexed_icb_pixels[mismatch] : 0);
            fail_with_error("native indexed indirect command buffer error", metal_indexed_icb_command_buffer.error);
            fail_with_error("adapter indexed indirect command buffer error", adapter_indexed_icb_command_buffer.error);
            return 128;
        }

        /* Metal 4 adds fixed-function state and fragment-buffer bindings to
         * indirect render commands. Record those fields in each CPU-owned
         * command and compare replay against Apple's native ICB. */
        MTLIndirectCommandBufferDescriptor *state_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        state_icb_descriptor.commandTypes = MTLIndirectCommandTypeDraw;
        state_icb_descriptor.inheritPipelineState = NO;
        state_icb_descriptor.inheritBuffers = NO;
        if (@available(macOS 26.0, iOS 26.0, *)) {
            state_icb_descriptor.inheritDepthStencilState = NO;
            state_icb_descriptor.inheritDepthBias = NO;
            state_icb_descriptor.inheritDepthClipMode = NO;
            state_icb_descriptor.inheritCullMode = NO;
            state_icb_descriptor.inheritFrontFacingWinding = NO;
            state_icb_descriptor.inheritTriangleFillMode = NO;
        }
        if (@available(macOS 13.0, iOS 16.0, *)) {
            if (adapter_pipeline.gpuResourceID._impl == 0 || adapter_icb_compute_pipeline.gpuResourceID._impl == 0) {
                fprintf(stderr, "metal-pixel: pipeline resource identity was not exposed\n");
                return 52;
            }
        }
        state_icb_descriptor.maxVertexBufferBindCount = 1;
        state_icb_descriptor.maxFragmentBufferBindCount = 1;
        id<MTLIndirectCommandBuffer> metal_state_icb =
            [device newIndirectCommandBufferWithDescriptor:state_icb_descriptor
                                           maxCommandCount:1
                                                   options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> metal_state_icb_command =
            [metal_state_icb indirectRenderCommandAtIndex:0];
        [metal_state_icb_command setRenderPipelineState:native_uniform_pipeline];
        [metal_state_icb_command setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [metal_state_icb_command setFragmentBuffer:native_uniform_buffer offset:8 atIndex:0];
        BOOL native_indirect_state_supported = YES;
        @try {
            [metal_state_icb_command setDepthStencilState:nil];
            [metal_state_icb_command setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
            [metal_state_icb_command setDepthClipMode:MTLDepthClipModeClip];
            [metal_state_icb_command setCullMode:MTLCullModeNone];
            [metal_state_icb_command setFrontFacingWinding:MTLWindingClockwise];
            [metal_state_icb_command setTriangleFillMode:MTLTriangleFillModeLines];
        } @catch (NSException *exception) {
            (void)exception;
            native_indirect_state_supported = NO;
        }
        [metal_state_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                     vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> metal_state_icb_texture = [device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *metal_state_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_state_icb_pass.colorAttachments[0].texture = metal_state_icb_texture;
        metal_state_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_state_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_state_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> metal_state_icb_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_state_icb_encoder =
            [metal_state_icb_command_buffer renderCommandEncoderWithDescriptor:metal_state_icb_pass];
        [metal_state_icb_encoder executeCommandsInBuffer:metal_state_icb withRange:NSMakeRange(0, 1)];
        [metal_state_icb_encoder endEncoding];
        [metal_state_icb_command_buffer commit];
        [metal_state_icb_command_buffer waitUntilCompleted];
        uint8_t metal_state_icb_pixels[byte_count];
        [metal_state_icb_texture getBytes:metal_state_icb_pixels
                              bytesPerRow:(NSUInteger)width * 4
                               fromRegion:MTLRegionMake2D(0, 0, width, height)
                              mipmapLevel:0];

        id<MTLIndirectCommandBuffer> adapter_state_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:state_icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_state_icb_command =
            [adapter_state_icb indirectRenderCommandAtIndex:0];
        [adapter_state_icb_command setRenderPipelineState:adapter_uniform_pipeline];
        [adapter_state_icb_command setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_state_icb_command setFragmentBuffer:adapter_uniform_buffer offset:8 atIndex:0];
        [adapter_state_icb_command setDepthStencilState:nil];
        [adapter_state_icb_command setDepthBias:0.0f slopeScale:0.0f clamp:0.0f];
        [adapter_state_icb_command setDepthClipMode:MTLDepthClipModeClip];
        [adapter_state_icb_command setCullMode:MTLCullModeNone];
        [adapter_state_icb_command setFrontFacingWinding:MTLWindingClockwise];
        [adapter_state_icb_command setTriangleFillMode:MTLTriangleFillModeLines];
        [adapter_state_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                       vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> adapter_state_icb_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_state_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_state_icb_pass.colorAttachments[0].texture = adapter_state_icb_texture;
        adapter_state_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_state_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_state_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
        id<MTLCommandBuffer> adapter_state_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_state_icb_encoder =
            [adapter_state_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_state_icb_pass];
        [adapter_state_icb_encoder executeCommandsInBuffer:adapter_state_icb withRange:NSMakeRange(0, 1)];
        [adapter_state_icb_encoder endEncoding];
        [adapter_state_icb_command_buffer commit];
        [adapter_state_icb_command_buffer waitUntilCompleted];
        uint8_t adapter_state_icb_pixels[byte_count];
        [adapter_state_icb_texture getBytes:adapter_state_icb_pixels
                                bytesPerRow:(NSUInteger)width * 4
                                 fromRegion:MTLRegionMake2D(0, 0, width, height)
                                mipmapLevel:0];
        if (native_indirect_state_supported &&
            (metal_state_icb == nil || metal_state_icb_command == nil ||
            metal_state_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_state_icb == nil || adapter_state_icb_command == nil ||
            adapter_state_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_state_icb_pixels, adapter_state_icb_pixels, byte_count) != 0)) {
            size_t mismatch = 0;
            while (mismatch < byte_count && metal_state_icb_pixels[mismatch] == adapter_state_icb_pixels[mismatch]) mismatch += 1;
            fprintf(stderr, "metal-pixel: indirect render state mismatch (native=%lu adapter=%lu mismatch=%zu nativeByte=%u adapterByte=%u)\n",
                    (unsigned long)metal_state_icb_command_buffer.status,
                    (unsigned long)adapter_state_icb_command_buffer.status,
                    mismatch,
                    mismatch < byte_count ? metal_state_icb_pixels[mismatch] : 0,
                    mismatch < byte_count ? adapter_state_icb_pixels[mismatch] : 0);
            fail_with_error("native indirect render state error", metal_state_icb_command_buffer.error);
            fail_with_error("adapter indirect render state error", adapter_state_icb_command_buffer.error);
            return 126;
        }
        if (!native_indirect_state_supported &&
            (adapter_state_icb == nil || adapter_state_icb_command == nil ||
             adapter_state_icb_command_buffer.status != MTLCommandBufferStatusCompleted)) {
            fail_with_error("adapter indirect render state fallback error", adapter_state_icb_command_buffer.error);
            return 127;
        }

        /* Mesh commands retain the CPU-owned ICB lifecycle even though mesh
         * shader execution itself remains fail-closed. Native Metal is used
         * here only to verify that the command-family descriptor is valid on
         * this Apple host; no native mesh command is submitted. */
        MTLIndirectCommandBufferDescriptor *mesh_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        mesh_icb_descriptor.commandTypes = MTLIndirectCommandTypeDrawMeshThreadgroups |
            MTLIndirectCommandTypeDrawMeshThreads;
        mesh_icb_descriptor.inheritPipelineState = YES;
        mesh_icb_descriptor.inheritBuffers = YES;
        mesh_icb_descriptor.maxObjectBufferBindCount = 1;
        mesh_icb_descriptor.maxMeshBufferBindCount = 1;
        mesh_icb_descriptor.maxObjectThreadgroupMemoryBindCount = 1;
        id<MTLIndirectCommandBuffer> native_mesh_icb =
            [device newIndirectCommandBufferWithDescriptor:mesh_icb_descriptor
                                            maxCommandCount:2 options:0];
        id<MTLIndirectRenderCommand> native_mesh_threads_command =
            [native_mesh_icb indirectRenderCommandAtIndex:0];
        id<MTLIndirectRenderCommand> native_mesh_threadgroups_command =
            [native_mesh_icb indirectRenderCommandAtIndex:1];
        if (native_mesh_threads_command != nil && native_mesh_threadgroups_command != nil) {
            [native_mesh_threads_command setObjectThreadgroupMemoryLength:16 atIndex:0];
            [native_mesh_threads_command setObjectBuffer:vertex_buffer offset:0 atIndex:0];
            [native_mesh_threads_command setMeshBuffer:vertex_buffer offset:0 atIndex:0];
            [native_mesh_threads_command drawMeshThreads:MTLSizeMake(8, 4, 1)
                           threadsPerObjectThreadgroup:MTLSizeMake(8, 1, 1)
                             threadsPerMeshThreadgroup:MTLSizeMake(8, 1, 1)];
            [native_mesh_threadgroups_command setObjectThreadgroupMemoryLength:16 atIndex:0];
            [native_mesh_threadgroups_command setObjectBuffer:vertex_buffer offset:0 atIndex:0];
            [native_mesh_threadgroups_command setMeshBuffer:vertex_buffer offset:0 atIndex:0];
            [native_mesh_threadgroups_command drawMeshThreadgroups:MTLSizeMake(1, 1, 1)
                                      threadsPerObjectThreadgroup:MTLSizeMake(8, 1, 1)
                                        threadsPerMeshThreadgroup:MTLSizeMake(8, 1, 1)];
        }
        id<MTLIndirectCommandBuffer> adapter_mesh_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:mesh_icb_descriptor
                                                    maxCommandCount:2
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_mesh_threads_command =
            [adapter_mesh_icb indirectRenderCommandAtIndex:0];
        id<MTLIndirectRenderCommand> adapter_mesh_threadgroups_command =
            [adapter_mesh_icb indirectRenderCommandAtIndex:1];
        [adapter_mesh_threads_command setObjectThreadgroupMemoryLength:16 atIndex:0];
        [adapter_mesh_threads_command setObjectBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mesh_threads_command setMeshBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mesh_threads_command drawMeshThreads:MTLSizeMake(8, 4, 1)
                       threadsPerObjectThreadgroup:MTLSizeMake(8, 1, 1)
                         threadsPerMeshThreadgroup:MTLSizeMake(8, 1, 1)];
        [adapter_mesh_threadgroups_command setObjectThreadgroupMemoryLength:16 atIndex:0];
        [adapter_mesh_threadgroups_command setObjectBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mesh_threadgroups_command setMeshBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_mesh_threadgroups_command drawMeshThreadgroups:MTLSizeMake(1, 1, 1)
                                  threadsPerObjectThreadgroup:MTLSizeMake(8, 1, 1)
                                    threadsPerMeshThreadgroup:MTLSizeMake(8, 1, 1)];
        id<MTLIndirectCommandBuffer> adapter_mesh_copy_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:mesh_icb_descriptor
                                                    maxCommandCount:2
                                                            options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_mesh_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_mesh_copy_encoder =
            [adapter_mesh_copy_command_buffer blitCommandEncoder];
        [adapter_mesh_copy_encoder copyIndirectCommandBuffer:adapter_mesh_icb
                                                  sourceRange:NSMakeRange(0, 2)
                                                 destination:adapter_mesh_copy_icb
                                            destinationIndex:0];
        [adapter_mesh_copy_encoder endEncoding];
        [adapter_mesh_copy_command_buffer commit];
        [adapter_mesh_copy_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_mesh_execute_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_mesh_execute_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_mesh_execute_pass.colorAttachments[0].texture = adapter_texture;
        adapter_mesh_execute_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_mesh_execute_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> adapter_mesh_execute_encoder =
            [adapter_mesh_execute_command_buffer renderCommandEncoderWithDescriptor:adapter_mesh_execute_pass];
        [adapter_mesh_execute_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_mesh_execute_encoder executeCommandsInBuffer:adapter_mesh_copy_icb withRange:NSMakeRange(0, 2)];
        [adapter_mesh_execute_encoder endEncoding];
        [adapter_mesh_execute_command_buffer commit];
        [adapter_mesh_execute_command_buffer waitUntilCompleted];
        BOOL adapter_mesh_icb_exact = native_mesh_icb != nil &&
            native_mesh_threads_command != nil && native_mesh_threadgroups_command != nil &&
            adapter_mesh_icb != nil && adapter_mesh_threads_command != nil &&
            adapter_mesh_threadgroups_command != nil && adapter_mesh_copy_icb != nil &&
            adapter_mesh_copy_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_mesh_execute_command_buffer.status == MTLCommandBufferStatusError;
        [adapter_mesh_copy_icb resetWithRange:NSMakeRange(0, 2)];
        if (!adapter_mesh_icb_exact) {
            fprintf(stderr, "metal-pixel: CPU indirect mesh command lifecycle failed\n");
            return 130;
        }

        /* Patch commands have no CPU tessellation executor yet, but their
         * indirect recording contract is still representable. Preserve all
         * CPU-owned buffers and scalar arguments through ICB copy/reset, then
         * fail closed only when replay would require tessellation. */
        const MTLIndirectCommandType patch_command_types =
            (MTLIndirectCommandType)((1u << 2) | (1u << 3));
        MTLIndirectCommandBufferDescriptor *patch_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        patch_icb_descriptor.commandTypes = patch_command_types;
        id<MTLIndirectCommandBuffer> adapter_patch_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:patch_icb_descriptor
                                                    maxCommandCount:2
                                                            options:MTLResourceStorageModeShared];
        id<MTLBuffer> adapter_patch_factor_buffer =
            [adapter_device newBufferWithLength:256 options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_patch_command =
            [adapter_patch_icb indirectRenderCommandAtIndex:0];
        id<MTLIndirectRenderCommand> adapter_indexed_patch_command =
            [adapter_patch_icb indirectRenderCommandAtIndex:1];
        [adapter_patch_command drawPatches:4
                                patchStart:3
                                patchCount:5
                          patchIndexBuffer:nil
                    patchIndexBufferOffset:0
                               instanceCount:2
                                baseInstance:1
                     tessellationFactorBuffer:adapter_patch_factor_buffer
                 tessellationFactorBufferOffset:16
          tessellationFactorBufferInstanceStride:32];
        [adapter_indexed_patch_command drawIndexedPatches:4
                                               patchStart:2
                                               patchCount:6
                                         patchIndexBuffer:adapter_vertex_buffer
                                   patchIndexBufferOffset:4
                                  controlPointIndexBuffer:adapter_vertex_buffer
                            controlPointIndexBufferOffset:8
                                              instanceCount:2
                                               baseInstance:1
                                    tessellationFactorBuffer:adapter_patch_factor_buffer
                                tessellationFactorBufferOffset:32
                         tessellationFactorBufferInstanceStride:32];
        id<MTLIndirectCommandBuffer> adapter_patch_copy_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:patch_icb_descriptor
                                                    maxCommandCount:2
                                                            options:MTLResourceStorageModeShared];
        id<MTLCommandBuffer> adapter_patch_copy_command_buffer = [adapter_queue commandBuffer];
        id<MTLBlitCommandEncoder> adapter_patch_copy_encoder =
            [adapter_patch_copy_command_buffer blitCommandEncoder];
        [adapter_patch_copy_encoder copyIndirectCommandBuffer:adapter_patch_icb
                                                  sourceRange:NSMakeRange(0, 2)
                                                 destination:adapter_patch_copy_icb
                                            destinationIndex:0];
        [adapter_patch_copy_encoder endEncoding];
        [adapter_patch_copy_command_buffer commit];
        [adapter_patch_copy_command_buffer waitUntilCompleted];
        id<MTLCommandBuffer> adapter_patch_execute_command_buffer = [adapter_queue commandBuffer];
        MTLRenderPassDescriptor *adapter_patch_execute_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_patch_execute_pass.colorAttachments[0].texture = adapter_texture;
        adapter_patch_execute_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_patch_execute_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLRenderCommandEncoder> adapter_patch_execute_encoder =
            [adapter_patch_execute_command_buffer renderCommandEncoderWithDescriptor:adapter_patch_execute_pass];
        [adapter_patch_execute_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_patch_execute_encoder executeCommandsInBuffer:adapter_patch_copy_icb withRange:NSMakeRange(0, 2)];
        [adapter_patch_execute_encoder endEncoding];
        [adapter_patch_execute_command_buffer commit];
        [adapter_patch_execute_command_buffer waitUntilCompleted];
        BOOL adapter_patch_icb_exact =
            adapter_patch_icb != nil && adapter_patch_factor_buffer != nil &&
            adapter_patch_command != nil && adapter_indexed_patch_command != nil &&
            adapter_patch_copy_icb != nil &&
            adapter_patch_copy_command_buffer.status == MTLCommandBufferStatusCompleted &&
            adapter_patch_execute_command_buffer.status == MTLCommandBufferStatusError;
        [adapter_patch_copy_icb resetWithRange:NSMakeRange(0, 2)];
        if (!adapter_patch_icb_exact) {
            fprintf(stderr, "metal-pixel: CPU indirect patch command lifecycle failed\n");
            return 131;
        }

        /* ICB object/mesh bindings have no CPU/ZPU shader-stage executor.
         * They must invalidate the recorded command instead of being silently
         * discarded before replay. */
        MTLIndirectCommandBufferDescriptor *adapter_unsupported_icb_descriptor = [MTLIndirectCommandBufferDescriptor new];
        adapter_unsupported_icb_descriptor.commandTypes = MTLIndirectCommandTypeDraw;
        adapter_unsupported_icb_descriptor.inheritPipelineState = YES;
        adapter_unsupported_icb_descriptor.inheritBuffers = YES;
        adapter_unsupported_icb_descriptor.maxVertexBufferBindCount = 1;
        id<MTLIndirectCommandBuffer> adapter_unsupported_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:adapter_unsupported_icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_unsupported_icb_command =
            [adapter_unsupported_icb indirectRenderCommandAtIndex:0];
        [adapter_unsupported_icb_command setObjectThreadgroupMemoryLength:16 atIndex:0];
        [adapter_unsupported_icb_command setObjectBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_unsupported_icb_command setMeshBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_unsupported_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                             vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        id<MTLTexture> adapter_unsupported_icb_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_unsupported_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_unsupported_icb_pass.colorAttachments[0].texture = adapter_unsupported_icb_texture;
        adapter_unsupported_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_unsupported_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        id<MTLCommandBuffer> adapter_unsupported_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_unsupported_icb_encoder =
            [adapter_unsupported_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_unsupported_icb_pass];
        [adapter_unsupported_icb_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_unsupported_icb_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_unsupported_icb_encoder executeCommandsInBuffer:adapter_unsupported_icb withRange:NSMakeRange(0, 1)];
        [adapter_unsupported_icb_encoder endEncoding];
        [adapter_unsupported_icb_command_buffer commit];
        [adapter_unsupported_icb_command_buffer waitUntilCompleted];
        if (adapter_unsupported_icb == nil || adapter_unsupported_icb_command == nil ||
            adapter_unsupported_icb_encoder == nil ||
            adapter_unsupported_icb_command_buffer.status != MTLCommandBufferStatusError) {
            fprintf(stderr, "metal-pixel: unsupported ICB shader stage did not fail closed\n");
            return 129;
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

        /* Resetting an ICB slot must remove its previously encoded draw and
         * leave execution as a legal no-op. Compare the native reset path
         * with the CPU-owned command representation so reset cannot leak
         * stale pipeline, buffer, or fixed-function state into a later pass. */
        id<MTLIndirectCommandBuffer> metal_reset_icb =
            [device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                           maxCommandCount:1
                                                   options:0];
        id<MTLIndirectRenderCommand> metal_reset_icb_command =
            [metal_reset_icb indirectRenderCommandAtIndex:0];
        [metal_reset_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                    vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        [metal_reset_icb resetWithRange:NSMakeRange(0, 1)];
        id<MTLTexture> metal_reset_icb_texture = [device newTextureWithDescriptor:texture_descriptor];
        MTLRenderPassDescriptor *metal_reset_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        metal_reset_icb_pass.colorAttachments[0].texture = metal_reset_icb_texture;
        metal_reset_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        metal_reset_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        metal_reset_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> metal_reset_icb_command_buffer = [queue commandBuffer];
        id<MTLRenderCommandEncoder> metal_reset_icb_encoder =
            [metal_reset_icb_command_buffer renderCommandEncoderWithDescriptor:metal_reset_icb_pass];
        [metal_reset_icb_encoder setRenderPipelineState:pipeline];
        [metal_reset_icb_encoder setVertexBuffer:vertex_buffer offset:0 atIndex:0];
        [metal_reset_icb_encoder executeCommandsInBuffer:metal_reset_icb withRange:NSMakeRange(0, 1)];
        [metal_reset_icb_encoder endEncoding];
        [metal_reset_icb_command_buffer commit];
        [metal_reset_icb_command_buffer waitUntilCompleted];
        uint8_t metal_reset_icb_pixels[byte_count];
        [metal_reset_icb_texture getBytes:metal_reset_icb_pixels
                               bytesPerRow:(NSUInteger)width * 4
                                fromRegion:MTLRegionMake2D(0, 0, width, height)
                               mipmapLevel:0];

        id<MTLIndirectCommandBuffer> adapter_reset_icb =
            [adapter_device newIndirectCommandBufferWithDescriptor:icb_descriptor
                                                    maxCommandCount:1
                                                            options:MTLResourceStorageModeShared];
        id<MTLIndirectRenderCommand> adapter_reset_icb_command =
            [adapter_reset_icb indirectRenderCommandAtIndex:0];
        [adapter_reset_icb_command drawPrimitives:MTLPrimitiveTypeTriangle
                                      vertexStart:0 vertexCount:6 instanceCount:1 baseInstance:0];
        [adapter_reset_icb resetWithRange:NSMakeRange(0, 1)];
        id<MTLTexture> adapter_reset_icb_texture = [adapter_device newTextureWithDescriptor:adapter_texture_descriptor];
        MTLRenderPassDescriptor *adapter_reset_icb_pass = [MTLRenderPassDescriptor renderPassDescriptor];
        adapter_reset_icb_pass.colorAttachments[0].texture = adapter_reset_icb_texture;
        adapter_reset_icb_pass.colorAttachments[0].loadAction = MTLLoadActionClear;
        adapter_reset_icb_pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        adapter_reset_icb_pass.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0);
        id<MTLCommandBuffer> adapter_reset_icb_command_buffer = [adapter_queue commandBuffer];
        id<MTLRenderCommandEncoder> adapter_reset_icb_encoder =
            [adapter_reset_icb_command_buffer renderCommandEncoderWithDescriptor:adapter_reset_icb_pass];
        [adapter_reset_icb_encoder setRenderPipelineState:adapter_pipeline];
        [adapter_reset_icb_encoder setVertexBuffer:adapter_vertex_buffer offset:0 atIndex:0];
        [adapter_reset_icb_encoder executeCommandsInBuffer:adapter_reset_icb withRange:NSMakeRange(0, 1)];
        [adapter_reset_icb_encoder endEncoding];
        [adapter_reset_icb_command_buffer commit];
        [adapter_reset_icb_command_buffer waitUntilCompleted];
        uint8_t adapter_reset_icb_pixels[byte_count];
        [adapter_reset_icb_texture getBytes:adapter_reset_icb_pixels
                                 bytesPerRow:(NSUInteger)width * 4
                                  fromRegion:MTLRegionMake2D(0, 0, width, height)
                                 mipmapLevel:0];
        if (metal_reset_icb == nil || metal_reset_icb_command == nil ||
            metal_reset_icb_texture == nil || metal_reset_icb_encoder == nil ||
            metal_reset_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            adapter_reset_icb == nil || adapter_reset_icb_command == nil ||
            adapter_reset_icb_texture == nil || adapter_reset_icb_encoder == nil ||
            adapter_reset_icb_command_buffer.status != MTLCommandBufferStatusCompleted ||
            memcmp(metal_reset_icb_pixels, adapter_reset_icb_pixels, byte_count) != 0) {
            fprintf(stderr, "metal-pixel: reset indirect command buffer mismatch\n");
            return 128;
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
        depth_state_descriptor.label = @"zpu cpu depth state";
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
        MTLRenderPipelineDescriptor *adapter_depth_pipeline_descriptor = [depth_pipeline_descriptor copy];
        adapter_depth_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_depth_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_depth_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_depth_pipeline_descriptor error:&adapter_depth_pipeline_error];
        id<MTLDepthStencilState> adapter_depth_state =
            [adapter_device newDepthStencilStateWithDescriptor:depth_state_descriptor];
        if (adapter_depth_color == nil || adapter_depth_texture == nil ||
            adapter_depth_vertex_buffer == nil || adapter_depth_command_buffer == nil ||
            adapter_depth_encoder == nil || adapter_depth_pipeline == nil || adapter_depth_state == nil ||
            ![adapter_depth_state.label isEqualToString:@"zpu cpu depth state"]) {
            fail_with_error("depth adapter pipeline allocation failed", adapter_depth_pipeline_error);
            fprintf(stderr, "metal-pixel: depth adapter allocation failed\n");
            return 28;
        }
        if (@available(macOS 26.0, iOS 26.0, *)) {
            MTLArgumentDescriptor *depth_argument_descriptor = [MTLArgumentDescriptor argumentDescriptor];
            depth_argument_descriptor.dataType = MTLDataTypePointer;
            depth_argument_descriptor.index = 0;
            id<MTLArgumentEncoder> depth_argument_encoder =
                [adapter_device newArgumentEncoderWithArguments:@[depth_argument_descriptor]];
            id<MTLBuffer> depth_argument_buffer =
                [adapter_device newBufferWithLength:16 options:MTLResourceStorageModeShared];
            [depth_argument_encoder setArgumentBuffer:depth_argument_buffer offset:0];
            [depth_argument_encoder setDepthStencilState:adapter_depth_state atIndex:0];
            uint64_t encoded_depth_resource = 0;
            if (depth_argument_buffer != nil) {
                memcpy(&encoded_depth_resource, depth_argument_buffer.contents, sizeof(encoded_depth_resource));
            }
            if (depth_argument_encoder == nil || depth_argument_buffer == nil ||
                adapter_depth_state.gpuResourceID._impl == 0 ||
                encoded_depth_resource != adapter_depth_state.gpuResourceID._impl) {
                fprintf(stderr, "metal-pixel: depth state argument encoding failed\n");
                return 51;
            }
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
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_depth_pipeline_descriptor error:&adapter_depth_pipeline_error];
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
        MTLRenderPipelineDescriptor *adapter_depth_only_pipeline_descriptor = [depth_only_pipeline_descriptor copy];
        adapter_depth_only_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_depth_only_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_depth_only_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_depth_only_pipeline_descriptor
                                                            error:&adapter_depth_only_pipeline_error];
        if (adapter_depth_only_texture == nil || adapter_depth_only_command_buffer == nil ||
            adapter_depth_only_encoder == nil || adapter_depth_only_pipeline == nil) {
            fail_with_error("depth-only adapter pipeline allocation failed", adapter_depth_only_pipeline_error);
            return 79;
        }
        [adapter_depth_only_encoder setRenderPipelineState:adapter_depth_only_pipeline];
        [adapter_depth_only_encoder setDepthStencilState:adapter_depth_state];
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
        MTLRenderPipelineDescriptor *adapter_stencil_pipeline_descriptor = [stencil_pipeline_descriptor copy];
        adapter_stencil_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_stencil_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_stencil_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_stencil_pipeline_descriptor error:&adapter_pipeline_error];
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
        MTLRenderPipelineDescriptor *adapter_stencil_only_pipeline_descriptor = [stencil_only_pipeline_descriptor copy];
        adapter_stencil_only_pipeline_descriptor.vertexFunction = adapter_vertex_function;
        adapter_stencil_only_pipeline_descriptor.fragmentFunction = adapter_fragment_function;
        id<MTLRenderPipelineState> adapter_stencil_only_pipeline =
            [adapter_device newRenderPipelineStateWithDescriptor:adapter_stencil_only_pipeline_descriptor
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
        printf("metal-pixel: exact Metal/ZPU bytes for RGBA8/BGRA8 core, CPU compute, tensors, identity rasterization-rate maps, CPU Metal I/O, CPU log state, uniform fragment bytes/buffers, deferred vertex/index/indirect render arguments, Metal 4 sampler tables and border colors, mip/coordinate/reduction sampler modes, visibility results, acceleration-structure resources, cube/cube-array textures, point/line/line-strip/triangle-strip coverage, legacy/Metal 4 counters, compiler-created Metal 4 compute/render, render/dispatch/copy, view pools, argument encoders, depth/stencil, heaps, indexed ICBs, and parallel adapter (%ux%u, %zu bytes)\n",
               width, height, (size_t)byte_count);
        return 0;
    }
}

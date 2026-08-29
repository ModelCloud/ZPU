// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

/*
 * Explicit Apple-facing adapter for the bounded ZPU Metal runtime.
 *
 * The classes declare the corresponding Apple protocols so callers can use
 * normal Objective-C conformance and selector checks. Every object remains
 * CPU-owned: supported selectors execute through the portable ZPU runtime,
 * while unsupported framework families fail closed with nil/errors rather
 * than dispatching to Apple's native Metal implementation.
 */

#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

#include <string.h>
#include <time.h>

#include "zpu/metal.h"
#include "zpu/metal_apple.h"

@class ZPUDevice;
@class ZPUCommandQueue;
@class ZPUCommandBuffer;
@class ZPUHeap;
@class ZPUTextureViewPool;
@class ZPUIndirectCommandBuffer;
@class ZPUIndirectComputeCommand;
@class ZPUComputeEncoder;
@class ZPUArgumentEncoder;
@class ZPUMTL4CounterHeap;
@class ZPUCounter;
@class ZPUCounterSet;
@class ZPUCounterSampleBuffer;
@class ZPURenderEncoder;
@class ZPUResourceStateEncoder;
@class ZPULibrary;
@class ZPUMTL4CommandAllocator;
@class ZPUMTL4CommandQueue;
@class ZPUMTL4CommandBuffer;
@class ZPUMTL4ArgumentTable;
@class ZPUMTL4ComputeEncoder;
@class ZPUMTL4RenderEncoder;

@interface ZPUBuffer : NSObject <MTLBuffer> {
@public
    zpu_metal_buffer *_zpuBuffer;
    id _owner;
    ZPUHeap *_heap;
    MTLResourceOptions _resourceOptions;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    uint64_t _resourceID;
    void (^_deallocator)(void *pointer, NSUInteger length);
    void *_deallocatorPointer;
    NSUInteger _deallocatorLength;
    NSString *_label;
    BOOL _aliasable;
}
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer;
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer heap:(ZPUHeap *)heap;
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer deallocator:(void (^)(void *pointer, NSUInteger length))deallocator pointer:(void *)pointer length:(NSUInteger)length;
- (void)applyResourceOptions:(MTLResourceOptions)options;
@end

@interface ZPUTexture : NSObject <MTLTexture> {
@public
    zpu_metal_texture *_zpuTexture;
    id _owner;
    ZPUTexture *_backing;
    ZPUBuffer *_backingBuffer;
    ZPUHeap *_heap;
    NSUInteger _bufferOffset;
    NSUInteger _bufferBytesPerRow;
    MTLTextureType _textureType;
    MTLPixelFormat _pixelFormat;
    MTLTextureUsage _usage;
    MTLResourceOptions _resourceOptions;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    BOOL _allowGPUOptimizedContents;
    MTLTextureCompressionType _compressionType;
    MTLTextureSwizzleChannels _swizzle;
    uint64_t _resourceID;
    NSString *_label;
    BOOL _aliasable;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backing:(ZPUTexture *)backing;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backingBuffer:(ZPUBuffer *)backingBuffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat heap:(ZPUHeap *)heap;
- (void)applyDescriptor:(MTLTextureDescriptor *)descriptor;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUTextureViewPool : NSObject <MTLTextureViewPool> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSMutableArray *_views;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLResourceViewPoolDescriptor *)descriptor;
@end
#pragma clang diagnostic pop

@interface ZPUHeap : NSObject <MTLHeap> {
@public
    zpu_metal_heap *_zpuHeap;
    ZPUDevice *_owner;
    MTLHeapType _type;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner heap:(zpu_metal_heap *)heap descriptor:(MTLHeapDescriptor *)descriptor;
@end

@interface ZPUIndirectRenderCommand : NSObject <MTLIndirectRenderCommand> {
@public
    ZPUIndirectCommandBuffer *_owner;
    id _pipelineState;
    ZPUBuffer *_vertexBuffer;
    NSUInteger _vertexOffset;
    MTLPrimitiveType _primitiveType;
    NSUInteger _vertexStart;
    NSUInteger _vertexCount;
    NSUInteger _instanceCount;
    NSUInteger _baseInstance;
    BOOL _hasDraw;
    ZPUBuffer *_indexBuffer;
    NSUInteger _indexCount;
    MTLIndexType _indexType;
    NSUInteger _indexOffset;
    NSInteger _baseVertex;
    BOOL _hasIndexedDraw;
    BOOL _unsupportedCommand;
}
- (instancetype)initWithOwner:(ZPUIndirectCommandBuffer *)owner;
- (void)reset;
- (void)executeWithEncoder:(ZPURenderEncoder *)encoder;
@end

@interface ZPUIndirectComputeCommand : NSObject <MTLIndirectComputeCommand> {
@public
    ZPUIndirectCommandBuffer *_owner;
    id _pipelineState;
    ZPUBuffer *_kernelBuffer;
    NSUInteger _kernelBufferOffset;
    BOOL _hasDispatchThreads;
    MTLSize _threadsPerGrid;
    MTLSize _threadsPerThreadgroup;
    BOOL _hasDispatchThreadgroups;
    MTLSize _threadgroupsPerGrid;
    MTLSize _threadgroupsPerThreadgroup;
}
- (instancetype)initWithOwner:(ZPUIndirectCommandBuffer *)owner;
- (void)reset;
- (void)executeWithEncoder:(ZPUComputeEncoder *)encoder;
@end

@interface ZPUIndirectCommandBuffer : NSObject <MTLIndirectCommandBuffer> {
@public
    ZPUDevice *_owner;
    NSUInteger _maxCommandCount;
    MTLIndirectCommandType _commandTypes;
    MTLResourceOptions _resourceOptions;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    NSMutableArray *_commands;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLIndirectCommandBufferDescriptor *)descriptor maxCommandCount:(NSUInteger)maxCount options:(MTLResourceOptions)options;
- (void)resetWithRange:(NSRange)range;
- (BOOL)copyCommandsFrom:(ZPUIndirectCommandBuffer *)source sourceRange:(NSRange)sourceRange destinationIndex:(NSUInteger)destinationIndex;
@end

@interface ZPUFence : NSObject <MTLFence> {
@public
    zpu_metal_fence *_zpuFence;
    ZPUDevice *_owner;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner fence:(zpu_metal_fence *)fence;
@end

@interface ZPUSharedEventNotification : NSObject {
@public
    uint64_t _value;
    MTLSharedEventListener *_listener;
    MTLSharedEventNotificationBlock _block;
}
- (instancetype)initWithValue:(uint64_t)value listener:(MTLSharedEventListener *)listener block:(MTLSharedEventNotificationBlock)block;
@end

@interface ZPUSharedEvent : NSObject <MTLSharedEvent> {
@public
    zpu_metal_shared_event *_zpuEvent;
    ZPUDevice *_owner;
    NSMutableArray *_notifications;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner event:(zpu_metal_shared_event *)event;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CounterHeap : NSObject <MTL4CounterHeap> {
@public
    ZPUDevice *_owner;
    MTL4CounterHeapType _type;
    NSUInteger _count;
    NSString *_label;
    NSMutableData *_entries;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CounterHeapDescriptor *)descriptor;
- (BOOL)writeTimestampAtIndex:(NSUInteger)index;
@end
#pragma clang diagnostic pop

@interface ZPURenderPipelineState : NSObject <MTLRenderPipelineState> {
@public
    ZPUDevice *_owner;
    MTLPixelFormat _colorPixelFormat;
    MTLPixelFormat _depthPixelFormat;
    BOOL _blendingEnabled;
    MTLBlendFactor _sourceRGBBlendFactor;
    MTLBlendFactor _destinationRGBBlendFactor;
    MTLBlendOperation _rgbBlendOperation;
    MTLBlendFactor _sourceAlphaBlendFactor;
    MTLBlendFactor _destinationAlphaBlendFactor;
    MTLBlendOperation _alphaBlendOperation;
    MTLColorWriteMask _writeMask;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRenderPipelineDescriptor *)descriptor;
@end

@interface ZPUDepthStencilState : NSObject <MTLDepthStencilState> {
@public
    ZPUDevice *_owner;
    MTLCompareFunction _depthCompareFunction;
    BOOL _depthWriteEnabled;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLDepthStencilDescriptor *)descriptor;
@end

@interface ZPUSamplerState : NSObject <MTLSamplerState> {
@public
    ZPUDevice *_owner;
    MTLSamplerMinMagFilter _minFilter;
    MTLSamplerMipFilter _mipFilter;
    uint64_t _resourceID;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLSamplerDescriptor *)descriptor;
@end

@interface ZPUCounter : NSObject <MTLCounter> {
@public
    NSString *_name;
}
- (instancetype)initWithName:(NSString *)name;
@end

@interface ZPUCounterSet : NSObject <MTLCounterSet> {
@public
    NSString *_name;
    NSArray *_counters;
}
- (instancetype)initWithName:(NSString *)name counters:(NSArray *)counters;
@end

@interface ZPUCounterSampleBuffer : NSObject <MTLCounterSampleBuffer> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSUInteger _sampleCount;
    id<MTLCounterSet> _counterSet;
    NSMutableData *_entries;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLCounterSampleBufferDescriptor *)descriptor;
- (BOOL)sampleAtIndex:(NSUInteger)index;
@end

@interface ZPUDevice : NSObject <MTLDevice> {
@public
    zpu_metal_device *_zpuDevice;
    NSArray *_counterSets;
}
- (instancetype)initWithDevice:(zpu_metal_device *)device;
@end

/* Metal 4 has a distinct command-submission graph from the legacy Metal
 * command queue. These objects intentionally bridge only the portions that
 * have a direct CPU/ZPU meaning. They never contain an Apple MTL object. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CommandAllocator : NSObject <MTL4CommandAllocator> {
@public
    ZPUDevice *_owner;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CommandAllocatorDescriptor *)descriptor;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CommitFeedback : NSObject <MTL4CommitFeedback> {
@public
    NSError *_error;
    CFTimeInterval _GPUStartTime;
    CFTimeInterval _GPUEndTime;
}
- (instancetype)initWithError:(NSError *)error startTime:(CFTimeInterval)startTime endTime:(CFTimeInterval)endTime;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CommitOptions : MTL4CommitOptions {
@public
    NSMutableArray *_feedbackHandlers;
}
- (NSArray *)feedbackHandlers;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CommandBuffer : NSObject <MTL4CommandBuffer> {
@public
    ZPUDevice *_owner;
    ZPUCommandQueue *_legacyQueue;
    ZPUCommandBuffer *_legacyBuffer;
    ZPUMTL4CommandAllocator *_allocator;
    id _activeEncoder;
    NSString *_label;
    BOOL _recording;
    BOOL _ended;
    BOOL _submitted;
    BOOL _failed;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner;
- (void)markError;
- (BOOL)commitCPU;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CommandQueue : NSObject <MTL4CommandQueue> {
@public
    ZPUDevice *_owner;
    ZPUCommandQueue *_legacyQueue;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CommandQueueDescriptor *)descriptor;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4ArgumentTable : NSObject <MTL4ArgumentTable> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSUInteger _maxBufferBindCount;
    NSUInteger _maxTextureBindCount;
    NSUInteger _maxSamplerStateBindCount;
    BOOL _supportAttributeStrides;
    NSMutableData *_bufferAddresses;
    NSMutableData *_bufferStrides;
    NSMutableData *_bufferResources;
    NSMutableData *_textureResources;
    NSMutableData *_samplerResources;
    BOOL _invalid;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4ArgumentTableDescriptor *)descriptor;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4ComputeEncoder : NSObject <MTL4ComputeCommandEncoder> {
@public
    ZPUMTL4CommandBuffer *_owner;
    ZPUComputeEncoder *_legacy;
    ZPUMTL4ArgumentTable *_argumentTable;
    NSString *_label;
    MTLStages _stages;
    BOOL _ended;
}
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner legacy:(ZPUComputeEncoder *)legacy;
@end

#pragma clang diagnostic pop

@interface ZPUCPUFunction : NSObject <MTLFunction> {
@public
    ZPUDevice *_owner;
    NSString *_name;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name;
@end

/* A library is a CPU-side name table for registered ZPU kernels. It never
 * contains an Apple MTLLibrary or compiled MSL. */
@interface ZPULibrary : NSObject <MTLLibrary> {
@public
    ZPUDevice *_owner;
    NSArray *_functionNames;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner source:(NSString *)source;
@end

@interface ZPUCommandQueue : NSObject <MTLCommandQueue> {
@public
    zpu_metal_command_queue *_zpuQueue;
    ZPUDevice *_owner;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner queue:(zpu_metal_command_queue *)queue;
@end

@interface ZPUCommandBuffer : NSObject <MTLCommandBuffer> {
@public
    zpu_metal_command_buffer *_zpuCommandBuffer;
    ZPUCommandQueue *_owner;
    NSMutableArray *_retainedResources;
    NSMutableArray *_scheduledHandlers;
    NSMutableArray *_completedHandlers;
    NSError *_error;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUCommandQueue *)owner commandBuffer:(zpu_metal_command_buffer *)commandBuffer;
- (void)retainResource:(id)resource;
- (void)markError;
@end

@interface ZPUComputePipelineState : NSObject <MTLComputePipelineState> {
@public
    ZPUDevice *_owner;
    zpu_metal_compute_kernel _kernel;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner function:(id<MTLFunction>)function error:(NSError **)error;
@end

@interface ZPUComputeEncoder : NSObject <MTLComputeCommandEncoder> {
@public
    zpu_metal_compute_encoder *_zpuEncoder;
    ZPUCommandBuffer *_owner;
    MTLDispatchType _dispatchType;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_compute_encoder *)encoder;
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state;
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(10.11), ios(8.3));
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index;
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(10.11), ios(8.3));
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index;
- (void)setTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range;
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index;
- (void)setSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range;
- (void)setSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index;
- (void)setSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers lodMinClamps:(const float [__nonnull])lodMinClamps lodMaxClamps:(const float [__nonnull])lodMaxClamps withRange:(NSRange)range;
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index;
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height API_AVAILABLE(ios(11.0), macos(11.0), macCatalyst(14.0), tvos(14.5));
- (void)setStageInRegion:(MTLRegion)region API_AVAILABLE(macos(10.12), ios(10.0));
- (void)setStageInRegionWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(10.14), ios(12.0));
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup API_AVAILABLE(macos(10.13), ios(11.0), tvos(14.5));
- (void)dispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup;
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup API_AVAILABLE(macos(10.11), ios(9.0));
- (void)updateFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0));
- (void)waitForFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0));
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage API_AVAILABLE(macos(10.13), ios(11.0));
- (void)useResources:(const id<MTLResource> __nonnull [__nonnull])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage API_AVAILABLE(macos(10.13), ios(11.0));
- (void)useHeap:(id<MTLHeap>)heap API_AVAILABLE(macos(10.13), ios(11.0));
- (void)useHeaps:(const id<MTLHeap> __nonnull [__nonnull])heaps count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(11.0));
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope API_AVAILABLE(macos(10.14), ios(12.0));
- (void)memoryBarrierWithResources:(const id<MTLResource> __nonnull [__nonnull])resources count:(NSUInteger)count API_AVAILABLE(macos(10.14), ios(12.0));
@end

@interface ZPUArgumentEncoder : NSObject <MTLArgumentEncoder> {
@public
    ZPUDevice *_owner;
    NSUInteger _encodedLength;
    NSUInteger _alignment;
    ZPUBuffer *_argumentBuffer;
    NSUInteger _argumentOffset;
    NSString *_label;
    NSMutableArray *_retainedResources;
    NSMutableDictionary *_bindings;
    NSMutableDictionary *_bindingOffsets;
    NSMutableDictionary *_constants;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner arguments:(NSArray<MTLArgumentDescriptor *> *)arguments;
@end

@interface ZPURenderEncoder : NSObject <MTLRenderCommandEncoder> {
@public
    zpu_metal_render_encoder *_zpuEncoder;
    ZPUCommandBuffer *_owner;
    ZPUBuffer *_vertexBuffer;
    ZPURenderPipelineState *_pipelineState;
    ZPUDepthStencilState *_depthStencilState;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_render_encoder *)encoder;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4RenderEncoder : NSObject <MTL4RenderCommandEncoder> {
@public
    ZPUMTL4CommandBuffer *_owner;
    ZPURenderEncoder *_legacy;
    ZPUMTL4ArgumentTable *_argumentTable;
    NSString *_label;
    NSUInteger _tileWidth;
    NSUInteger _tileHeight;
    BOOL _ended;
}
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner legacy:(ZPURenderEncoder *)legacy
                      tileWidth:(NSUInteger)tileWidth tileHeight:(NSUInteger)tileHeight;
@end
#pragma clang diagnostic pop

@interface ZPUBlitEncoder : NSObject <MTLBlitCommandEncoder> {
@public
    zpu_metal_blit_encoder *_zpuEncoder;
    ZPUCommandBuffer *_owner;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_blit_encoder *)encoder;
@end

@interface ZPUResourceStateEncoder : NSObject <MTLResourceStateCommandEncoder> {
@public
    zpu_metal_resource_state_encoder *_zpuEncoder;
    ZPUCommandBuffer *_owner;
    NSString *_label;
    BOOL _ended;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_resource_state_encoder *)encoder;
@end

@interface ZPUParallelRenderEncoder : NSObject <MTLParallelRenderCommandEncoder> {
@public
    ZPUCommandBuffer *_owner;
    ZPUTexture *_texture;
    zpu_metal_render_pass_descriptor _pass;
    NSUInteger _childCount;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner texture:(ZPUTexture *)texture pass:(zpu_metal_render_pass_descriptor)pass;
@end

static BOOL zpu_u32(NSUInteger value, uint32_t *result) {
    if (value > UINT32_MAX) return NO;
    *result = (uint32_t)value;
    return YES;
}

static BOOL zpu_region_fits(MTLRegion region) {
    return region.origin.x <= UINT32_MAX && region.origin.y <= UINT32_MAX &&
        region.origin.z <= UINT32_MAX && region.size.width <= UINT32_MAX &&
        region.size.height <= UINT32_MAX && region.size.depth <= UINT32_MAX;
}

static zpu_metal_region zpu_region(MTLRegion region) {
    return (zpu_metal_region){
        { (uint32_t)region.origin.x, (uint32_t)region.origin.y, (uint32_t)region.origin.z },
        { (uint32_t)region.size.width, (uint32_t)region.size.height, (uint32_t)region.size.depth },
    };
}

static zpu_metal_pixel_format zpu_pixel_format(MTLPixelFormat format) {
    if (format == MTLPixelFormatBGRA8Unorm) return ZPU_METAL_BGRA8_UNORM;
    if (format == MTLPixelFormatDepth32Float) return ZPU_METAL_DEPTH32_FLOAT;
    return ZPU_METAL_RGBA8_UNORM;
}

static zpu_metal_load_action zpu_load_action(MTLLoadAction action) {
    switch (action) {
        case MTLLoadActionDontCare: return ZPU_METAL_LOAD_DONT_CARE;
        case MTLLoadActionClear: return ZPU_METAL_LOAD_CLEAR;
        case MTLLoadActionLoad:
        default: return ZPU_METAL_LOAD_LOAD;
    }
}

static zpu_metal_store_action zpu_store_action(MTLStoreAction action) {
    return action == MTLStoreActionDontCare ? ZPU_METAL_STORE_DONT_CARE : ZPU_METAL_STORE_STORE;
}

static void zpu_set_error(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"ZPUMetal" code:ZPU_METAL_INVALID_ARGUMENT
                                userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL zpu_render_pipeline_format_supported(MTLPixelFormat format) {
    return format == MTLPixelFormatInvalid || format == MTLPixelFormatRGBA8Unorm ||
        format == MTLPixelFormatBGRA8Unorm;
}

static BOOL zpu_depth_format_supported(MTLPixelFormat format) {
    return format == MTLPixelFormatInvalid || format == MTLPixelFormatDepth32Float;
}

static MTLResourceOptions zpu_pack_resource_options(MTLStorageMode storageMode,
                                                     MTLCPUCacheMode cpuCacheMode,
                                                     MTLHazardTrackingMode hazardTrackingMode) {
    return ((MTLResourceOptions)cpuCacheMode << MTLResourceCPUCacheModeShift) |
        ((MTLResourceOptions)storageMode << MTLResourceStorageModeShift) |
        ((MTLResourceOptions)hazardTrackingMode << MTLResourceHazardTrackingModeShift);
}

static MTLHazardTrackingMode zpu_effective_hazard_tracking_mode(MTLHazardTrackingMode mode,
                                                                 MTLHazardTrackingMode fallback) {
    return mode == MTLHazardTrackingModeDefault ? fallback : mode;
}

static BOOL zpu_heap_buffer_options_match(MTLStorageMode heapStorageMode,
                                           MTLCPUCacheMode heapCPUCacheMode,
                                           MTLHazardTrackingMode heapHazardTrackingMode,
                                           MTLResourceOptions options) {
    const MTLStorageMode storageMode =
        (MTLStorageMode)((options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift);
    const MTLCPUCacheMode cpuCacheMode =
        (MTLCPUCacheMode)((options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift);
    const MTLHazardTrackingMode hazardTrackingMode =
        (MTLHazardTrackingMode)((options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift);
    if (storageMode != heapStorageMode || cpuCacheMode != heapCPUCacheMode) return NO;
    return hazardTrackingMode != MTLHazardTrackingModeTracked ||
        heapHazardTrackingMode == MTLHazardTrackingModeTracked;
}

/* Metal 4 exposes opaque resource IDs and GPU addresses rather than
 * Objective-C resource objects. The CPU adapter gives each ZPU resource a
 * process-local opaque ID so an argument table can still resolve bindings
 * without manufacturing a native Metal resource. Values are intentionally
 * not exposed as real GPU addresses. */
static NSMapTable *zpu_resource_registry;
static uint64_t zpu_next_resource_id = 1;

static void zpu_init_resource_registry(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        zpu_resource_registry = [NSMapTable mapTableWithKeyOptions:NSMapTableStrongMemory
                                                         valueOptions:NSMapTableWeakMemory];
    });
}

static uint64_t zpu_register_resource(id resource) {
    zpu_init_resource_registry();
    @synchronized (zpu_resource_registry) {
        const uint64_t result = zpu_next_resource_id++;
        [zpu_resource_registry setObject:resource forKey:@(result)];
        return result;
    }
}

static id zpu_resource_for_id(uint64_t resourceID) {
    if (resourceID == 0) return nil;
    zpu_init_resource_registry();
    @synchronized (zpu_resource_registry) {
        return [zpu_resource_registry objectForKey:@(resourceID)];
    }
}

static BOOL zpu_metal4_region(MTLOrigin origin, MTLSize size, zpu_metal_region *result) {
    const MTLRegion region = {origin, size};
    if (!zpu_region_fits(region)) return NO;
    *result = zpu_region(region);
    return YES;
}

API_AVAILABLE(macos(26.0), ios(26.0))
static BOOL zpu_metal4_render_pass_descriptor(MTL4RenderPassDescriptor *descriptor,
                                                ZPUTexture **color_texture,
                                                ZPUTexture **depth_texture,
                                                zpu_metal_render_pass_descriptor *pass) {
    if (descriptor == nil || color_texture == NULL || depth_texture == NULL || pass == NULL) return NO;
    ZPUTexture *color = (ZPUTexture *)descriptor.colorAttachments[0].texture;
    if (![color isKindOfClass:[ZPUTexture class]] || !color->_zpuTexture ||
        !zpu_render_pipeline_format_supported(color->_pixelFormat)) return NO;
    if (descriptor.renderTargetArrayLength > 1 || descriptor.defaultRasterSampleCount > 1 ||
        (descriptor.renderTargetWidth != 0 && descriptor.renderTargetWidth != color.width) ||
        (descriptor.renderTargetHeight != 0 && descriptor.renderTargetHeight != color.height) ||
        descriptor.stencilAttachment.texture != nil) return NO;
    for (NSUInteger index = 1; index < 8; ++index) {
        if (descriptor.colorAttachments[index].texture != nil) return NO;
    }
    *pass = (zpu_metal_render_pass_descriptor){
        .color = {
            .load_action = zpu_load_action(descriptor.colorAttachments[0].loadAction),
            .store_action = zpu_store_action(descriptor.colorAttachments[0].storeAction),
            .clear_color = {
                (float)descriptor.colorAttachments[0].clearColor.red,
                (float)descriptor.colorAttachments[0].clearColor.green,
                (float)descriptor.colorAttachments[0].clearColor.blue,
                (float)descriptor.colorAttachments[0].clearColor.alpha,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
    if (depth != nil) {
        if (![depth isKindOfClass:[ZPUTexture class]] || depth->_pixelFormat != MTLPixelFormatDepth32Float ||
            depth.width != color.width || depth.height != color.height) return NO;
        pass->depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass->depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass->depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    *color_texture = color;
    *depth_texture = depth;
    return YES;
}

static ZPUBuffer *zpu_metal4_buffer_for_address(MTLGPUAddress address) {
    id resource = zpu_resource_for_id((uint64_t)address);
    return [resource isKindOfClass:[ZPUBuffer class]] ? (ZPUBuffer *)resource : nil;
}

@implementation ZPUBuffer
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer {
    return [self initWithOwner:owner buffer:buffer heap:nil];
}
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer heap:(ZPUHeap *)heap {
    if ((self = [super init])) {
        _owner = owner;
        _zpuBuffer = buffer;
        _heap = heap;
        _resourceOptions = MTLResourceStorageModeShared;
        _storageMode = MTLStorageModeShared;
        _cpuCacheMode = MTLCPUCacheModeDefaultCache;
        _hazardTrackingMode = MTLHazardTrackingModeTracked;
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (instancetype)initWithOwner:(id)owner buffer:(zpu_metal_buffer *)buffer deallocator:(void (^)(void *pointer, NSUInteger length))deallocator pointer:(void *)pointer length:(NSUInteger)length {
    if ((self = [self initWithOwner:owner buffer:buffer heap:nil])) {
        _deallocator = [deallocator copy];
        _deallocatorPointer = pointer;
        _deallocatorLength = length;
    }
    return self;
}
- (void)dealloc {
    if (_zpuBuffer != NULL) zpu_metal_buffer_destroy(_zpuBuffer);
    if (_deallocator != nil) _deallocator(_deallocatorPointer, _deallocatorLength);
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (NSUInteger)length { return zpu_metal_buffer_length(_zpuBuffer); }
- (void *)contents { return zpu_metal_buffer_contents(_zpuBuffer); }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (void)applyResourceOptions:(MTLResourceOptions)options {
    _resourceOptions = options;
    _storageMode = (MTLStorageMode)((options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift);
    _cpuCacheMode = (MTLCPUCacheMode)((options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift);
    _hazardTrackingMode = (MTLHazardTrackingMode)((options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift);
}
- (MTLResourceOptions)resourceOptions { return _resourceOptions; }
- (MTLStorageMode)storageMode { return _storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode {
    const MTLHazardTrackingMode fallback = _heap == nil ? MTLHazardTrackingModeTracked : [_heap hazardTrackingMode];
    return zpu_effective_hazard_tracking_mode(_hazardTrackingMode, fallback);
}
- (NSUInteger)allocatedSize { return [self length]; }
- (id<MTLHeap>)heap { return (id<MTLHeap>)_heap; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return _aliasable; }
- (void)makeAliasable { _aliasable = YES; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (void)didModifyRange:(NSRange)range { (void)range; }
- (void)addDebugMarker:(NSString *)marker range:(NSRange)range API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)marker;
    (void)range;
}
- (void)removeAllDebugMarkers API_AVAILABLE(macos(10.12), ios(10.0)) {}
- (id<MTLBuffer>)remoteStorageBuffer API_AVAILABLE(macos(10.15)) { return nil; }
- (id<MTLBuffer>)newRemoteBufferViewForDevice:(id<MTLDevice>)device API_AVAILABLE(macos(10.15)) {
    (void)device;
    return nil;
}
- (MTLGPUAddress)gpuAddress API_AVAILABLE(macos(13.0), ios(16.0)) { return _resourceID; }
- (MTLBufferSparseTier)sparseBufferTier API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLBufferSparseTierNone; }
- (id<MTLTensor>)newTensorWithDescriptor:(MTLTensorDescriptor *)descriptor offset:(NSUInteger)offset error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)descriptor;
    (void)offset;
    zpu_set_error(error, @"ZPU CPU Metal has no tensor implementation");
    return nil;
}
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    if (descriptor == nil || descriptor.textureType != MTLTextureType2D || descriptor.depth != 1 ||
        descriptor.arrayLength != 1 || descriptor.mipmapLevelCount != 1 || descriptor.sampleCount != 1 ||
        (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm)) return nil;
    if (descriptor.width > UINT32_MAX || descriptor.height > UINT32_MAX) return nil;
    zpu_metal_texture_descriptor zpu_descriptor = {
        (uint32_t)descriptor.width, (uint32_t)descriptor.height, zpu_pixel_format(descriptor.pixelFormat),
    };
    zpu_metal_texture *texture = zpu_metal_buffer_new_texture(_zpuBuffer, &zpu_descriptor, offset, bytesPerRow);
    if (texture == NULL) return nil;
    ZPUTexture *result = [[ZPUTexture alloc] initWithOwner:_owner texture:texture
                                                      type:descriptor.textureType
                                               pixelFormat:descriptor.pixelFormat
                                             backingBuffer:self offset:offset bytesPerRow:bytesPerRow];
    [result applyDescriptor:descriptor];
    return (id<MTLTexture>)result;
}
@end

@implementation ZPUTexture
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat {
    return [self initWithOwner:owner texture:texture type:type pixelFormat:pixelFormat backing:nil];
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backing:(ZPUTexture *)backing {
    self = [self initWithOwner:owner texture:texture type:type pixelFormat:pixelFormat backingBuffer:nil offset:0 bytesPerRow:0];
    if (self != nil) _backing = backing;
    return self;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backingBuffer:(ZPUBuffer *)backingBuffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    if ((self = [super init])) {
        _owner = owner;
        _zpuTexture = texture;
        _backing = nil;
        _backingBuffer = backingBuffer;
        _heap = nil;
        _bufferOffset = offset;
        _bufferBytesPerRow = bytesPerRow;
        _textureType = type;
        _pixelFormat = pixelFormat;
        _usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageRenderTarget;
        _resourceOptions = MTLResourceStorageModeShared;
        _storageMode = MTLStorageModeShared;
        _cpuCacheMode = MTLCPUCacheModeDefaultCache;
        _hazardTrackingMode = MTLHazardTrackingModeTracked;
        _allowGPUOptimizedContents = YES;
        _compressionType = MTLTextureCompressionTypeLossless;
        _swizzle = MTLTextureSwizzleChannelsDefault;
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat heap:(ZPUHeap *)heap {
    if ((self = [self initWithOwner:owner texture:texture type:type pixelFormat:pixelFormat backingBuffer:nil offset:0 bytesPerRow:0])) {
        _heap = heap;
    }
    return self;
}
- (void)dealloc {
    if (_zpuTexture != NULL && _backing == nil) zpu_metal_texture_destroy(_zpuTexture);
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLTextureType)textureType { return _textureType; }
- (MTLPixelFormat)pixelFormat { return _pixelFormat; }
- (NSUInteger)width { return zpu_metal_texture_width(_zpuTexture); }
- (NSUInteger)height { return zpu_metal_texture_height(_zpuTexture); }
- (NSUInteger)depth { return 1; }
- (NSUInteger)mipmapLevelCount { return 1; }
- (NSUInteger)sampleCount { return 1; }
- (NSUInteger)arrayLength { return 1; }
- (void)applyDescriptor:(MTLTextureDescriptor *)descriptor {
    if (descriptor == nil) return;
    _usage = descriptor.usage;
    _resourceOptions = descriptor.resourceOptions;
    _storageMode = descriptor.storageMode;
    _cpuCacheMode = descriptor.cpuCacheMode;
    _hazardTrackingMode = descriptor.hazardTrackingMode;
    _allowGPUOptimizedContents = descriptor.allowGPUOptimizedContents;
    _compressionType = descriptor.compressionType;
    _swizzle = descriptor.swizzle;
}
- (MTLTextureUsage)usage { return _backing != nil ? [_backing usage] : _usage; }
- (BOOL)isShareable { return NO; }
- (BOOL)isFramebufferOnly { return NO; }
- (BOOL)allowGPUOptimizedContents { return _backing != nil ? [_backing allowGPUOptimizedContents] : _allowGPUOptimizedContents; }
- (MTLTextureCompressionType)compressionType { return _backing != nil ? [_backing compressionType] : _compressionType; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){_resourceID}; }
- (MTLTextureSparseTier)sparseTextureTier API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLTextureSparseTierNone; }
- (id<MTLTexture>)remoteStorageTexture API_AVAILABLE(macos(10.15)) { return nil; }
- (id<MTLTexture>)newRemoteTextureViewForDevice:(id<MTLDevice>)device API_AVAILABLE(macos(10.15)) {
    (void)device;
    return nil;
}
- (id<MTLResource>)rootResource {
    if (_backing != nil) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        id<MTLResource> root = [_backing rootResource];
#pragma clang diagnostic pop
        return root;
    }
    if (_backingBuffer != nil) return (id<MTLResource>)_backingBuffer;
    return (id<MTLResource>)self;
}
- (id<MTLTexture>)parentTexture { return (id<MTLTexture>)_backing; }
- (id<MTLBuffer>)buffer { return _backing != nil ? [_backing buffer] : (id<MTLBuffer>)_backingBuffer; }
- (NSUInteger)bufferOffset { return _backing != nil ? [_backing bufferOffset] : _bufferOffset; }
- (NSUInteger)bufferBytesPerRow { return _backing != nil ? [_backing bufferBytesPerRow] : _bufferBytesPerRow; }
- (MTLResourceOptions)resourceOptions { return _backing != nil ? [_backing resourceOptions] : _resourceOptions; }
- (MTLStorageMode)storageMode { return _backing != nil ? [_backing storageMode] : _storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _backing != nil ? [_backing cpuCacheMode] : _cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode {
    if (_backing != nil) return [_backing hazardTrackingMode];
    const MTLHazardTrackingMode fallback = _heap == nil ? MTLHazardTrackingModeTracked : [_heap hazardTrackingMode];
    return zpu_effective_hazard_tracking_mode(_hazardTrackingMode, fallback);
}
- (NSUInteger)allocatedSize {
    if (_backing != nil) return [_backing allocatedSize];
    return _backingBuffer == nil ? [self width] * [self height] * 4 : _bufferBytesPerRow * [self height];
}
- (id<MTLHeap>)heap { return (id<MTLHeap>)_heap; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)parentRelativeLevel { return 0; }
- (NSUInteger)parentRelativeSlice { return 0; }
- (IOSurfaceRef)iosurface API_AVAILABLE(macos(10.11), ios(11.0)) { return nil; }
- (NSUInteger)iosurfacePlane API_AVAILABLE(macos(10.11), ios(11.0)) { return 0; }
- (NSUInteger)firstMipmapInTail API_AVAILABLE(macos(11.0), ios(13.0)) { return 0; }
- (NSUInteger)tailSizeInBytes API_AVAILABLE(macos(11.0), ios(13.0)) { return 0; }
- (BOOL)isSparse API_AVAILABLE(macos(11.0), ios(13.0)) { return NO; }
- (BOOL)isAliasable { return _aliasable; }
- (void)makeAliasable { _aliasable = YES; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (void)getBytes:(void *)destination bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    if (level != 0 || destination == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_get_bytes(_zpuTexture, destination, NSUIntegerMax, bytesPerRow, zpu_region(region));
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)source bytesPerRow:(NSUInteger)bytesPerRow {
    if (level != 0 || source == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_replace_region(_zpuTexture, zpu_region(region), source, NSUIntegerMax, bytesPerRow);
}
- (void)getBytes:(void *)destination bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    (void)bytesPerImage;
    if (slice != 0) return;
    [self getBytes:destination bytesPerRow:bytesPerRow fromRegion:region mipmapLevel:level];
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)source bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage {
    (void)bytesPerImage;
    if (slice != 0) return;
    [self replaceRegion:region mipmapLevel:level withBytes:source bytesPerRow:bytesPerRow];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat {
    if (pixelFormat != _pixelFormat) return nil;
    return (id<MTLTexture>)[[ZPUTexture alloc] initWithOwner:_owner texture:_zpuTexture
                                                         type:_textureType pixelFormat:pixelFormat backing:self];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)textureType levels:(NSRange)levelRange slices:(NSRange)sliceRange {
    if (textureType != _textureType || levelRange.location != 0 || levelRange.length != 1 ||
        sliceRange.location != 0 || sliceRange.length != 1) return nil;
    return [self newTextureViewWithPixelFormat:pixelFormat];
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)textureType levels:(NSRange)levelRange slices:(NSRange)sliceRange swizzle:(MTLTextureSwizzleChannels)swizzle {
    if (swizzle.red != MTLTextureSwizzleRed || swizzle.green != MTLTextureSwizzleGreen ||
        swizzle.blue != MTLTextureSwizzleBlue || swizzle.alpha != MTLTextureSwizzleAlpha) return nil;
    return [self newTextureViewWithPixelFormat:pixelFormat textureType:textureType levels:levelRange slices:sliceRange];
}
- (id<MTLTexture>)newTextureViewWithDescriptor:(MTLTextureViewDescriptor *)descriptor API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil) return nil;
    return [self newTextureViewWithPixelFormat:descriptor.pixelFormat
                                   textureType:descriptor.textureType
                                        levels:descriptor.levelRange
                                        slices:descriptor.sliceRange
                                       swizzle:descriptor.swizzle];
}
- (MTLTextureSwizzleChannels)swizzle { return _backing != nil ? [_backing swizzle] : _swizzle; }
- (MTLSharedTextureHandle *)newSharedTextureHandle { return nil; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
@implementation ZPUTextureViewPool
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLResourceViewPoolDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _views = [NSMutableArray arrayWithCapacity:descriptor.resourceViewCount];
        for (NSUInteger index = 0; index < descriptor.resourceViewCount; ++index) [_views addObject:[NSNull null]];
    }
    return self;
}
- (MTLResourceID)resourceIDForViewAtIndex:(NSUInteger)index {
    if (index >= _views.count) return (MTLResourceID){0};
    id view = _views[index];
    return [view isKindOfClass:[ZPUTexture class]] ? (MTLResourceID){((ZPUTexture *)view)->_resourceID} : (MTLResourceID){0};
}
- (MTLResourceID)baseResourceID { return [self resourceIDForViewAtIndex:0]; }
- (NSUInteger)resourceViewCount { return _views.count; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (MTLResourceID)copyResourceViewsFromPool:(id<MTLResourceViewPool>)sourcePool sourceRange:(NSRange)sourceRange destinationIndex:(NSUInteger)destinationIndex {
    ZPUTextureViewPool *source = (ZPUTextureViewPool *)sourcePool;
    if (![source isKindOfClass:[ZPUTextureViewPool class]] || source->_owner != _owner ||
        sourceRange.location > source->_views.count || sourceRange.length > source->_views.count - sourceRange.location ||
        destinationIndex > _views.count || sourceRange.length > _views.count - destinationIndex) return (MTLResourceID){0};
    for (NSUInteger index = 0; index < sourceRange.length; ++index) {
        _views[destinationIndex + index] = source->_views[sourceRange.location + index];
    }
    return [self resourceIDForViewAtIndex:destinationIndex];
}
- (MTLResourceID)setTextureView:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    ZPUTexture *source = (ZPUTexture *)texture;
    if (![source isKindOfClass:[ZPUTexture class]] || source->_owner != _owner || index >= _views.count) return (MTLResourceID){0};
    id view = [source newTextureViewWithPixelFormat:source.pixelFormat];
    if (![view isKindOfClass:[ZPUTexture class]]) return (MTLResourceID){0};
    _views[index] = view;
    return [self resourceIDForViewAtIndex:index];
}
- (MTLResourceID)setTextureView:(id<MTLTexture>)texture descriptor:(MTLTextureViewDescriptor *)descriptor atIndex:(NSUInteger)index {
    ZPUTexture *source = (ZPUTexture *)texture;
    if (![source isKindOfClass:[ZPUTexture class]] || source->_owner != _owner || descriptor == nil || index >= _views.count) return (MTLResourceID){0};
    id view = [source newTextureViewWithDescriptor:descriptor];
    if (![view isKindOfClass:[ZPUTexture class]]) return (MTLResourceID){0};
    _views[index] = view;
    return [self resourceIDForViewAtIndex:index];
}
- (MTLResourceID)setTextureViewFromBuffer:(id<MTLBuffer>)buffer descriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow atIndex:(NSUInteger)index {
    ZPUBuffer *source = (ZPUBuffer *)buffer;
    if (![source isKindOfClass:[ZPUBuffer class]] || source->_owner != _owner || descriptor == nil || index >= _views.count) return (MTLResourceID){0};
    id view = [source newTextureWithDescriptor:descriptor offset:offset bytesPerRow:bytesPerRow];
    if (![view isKindOfClass:[ZPUTexture class]]) return (MTLResourceID){0};
    _views[index] = view;
    return [self resourceIDForViewAtIndex:index];
}
@end
#pragma clang diagnostic pop

@implementation ZPUHeap
- (instancetype)initWithOwner:(ZPUDevice *)owner heap:(zpu_metal_heap *)heap descriptor:(MTLHeapDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _zpuHeap = heap;
        _type = descriptor.type;
        _storageMode = descriptor.storageMode;
        _cpuCacheMode = descriptor.cpuCacheMode;
        _hazardTrackingMode = descriptor.hazardTrackingMode;
    }
    return self;
}
- (void)dealloc {
    if (_zpuHeap != NULL) zpu_metal_heap_destroy(_zpuHeap);
}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLStorageMode)storageMode { return _storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode {
    return zpu_effective_hazard_tracking_mode(_hazardTrackingMode, MTLHazardTrackingModeUntracked);
}
- (MTLResourceOptions)resourceOptions {
    return zpu_pack_resource_options(_storageMode, _cpuCacheMode, [self hazardTrackingMode]);
}
- (NSUInteger)size { return zpu_metal_heap_size(_zpuHeap); }
- (NSUInteger)usedSize { return zpu_metal_heap_used_size(_zpuHeap); }
- (NSUInteger)currentAllocatedSize { return [self usedSize]; }
- (NSUInteger)allocatedSize API_AVAILABLE(macos(15.0), ios(18.0)) { return [self usedSize]; }
- (NSUInteger)maxAvailableSizeWithAlignment:(NSUInteger)alignment {
    return zpu_metal_heap_max_available_size(_zpuHeap, alignment == 0 ? 1 : alignment);
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    if (!zpu_heap_buffer_options_match(_storageMode, _cpuCacheMode, [self hazardTrackingMode], options)) return nil;
    zpu_metal_buffer *buffer = zpu_metal_heap_new_buffer(_zpuHeap, length, NULL);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:_owner buffer:buffer heap:self];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    if (descriptor == nil || descriptor.textureType != MTLTextureType2D || descriptor.depth != 1 ||
        descriptor.arrayLength != 1 || descriptor.mipmapLevelCount != 1 || descriptor.sampleCount != 1 ||
        descriptor.width > UINT32_MAX || descriptor.height > UINT32_MAX ||
        (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm &&
         descriptor.pixelFormat != MTLPixelFormatDepth32Float)) return nil;
    if ((descriptor.storageMode != _storageMode && descriptor.storageMode != MTLStorageModeMemoryless) ||
        descriptor.cpuCacheMode != _cpuCacheMode ||
        (descriptor.hazardTrackingMode == MTLHazardTrackingModeTracked && [self hazardTrackingMode] != MTLHazardTrackingModeTracked)) return nil;
    zpu_metal_texture_descriptor zpu_descriptor = {
        (uint32_t)descriptor.width, (uint32_t)descriptor.height, zpu_pixel_format(descriptor.pixelFormat),
    };
    zpu_metal_texture *texture = zpu_metal_heap_new_texture(_zpuHeap, &zpu_descriptor);
    if (texture == NULL) return nil;
    ZPUTexture *result = [[ZPUTexture alloc] initWithOwner:_owner texture:texture
                                                      type:descriptor.textureType
                                               pixelFormat:descriptor.pixelFormat heap:self];
    [result applyDescriptor:descriptor];
    return (id<MTLTexture>)result;
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (MTLHeapType)type { return _type; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset API_AVAILABLE(macos(10.15), ios(13.0)) {
    (void)length;
    (void)options;
    (void)offset;
    return nil;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset API_AVAILABLE(macos(10.15), ios(13.0)) {
    (void)descriptor;
    (void)offset;
    return nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithSize:(NSUInteger)size API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)size;
    return nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    return nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithSize:(NSUInteger)size offset:(NSUInteger)offset API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)size;
    (void)offset;
    return nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor offset:(NSUInteger)offset API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    (void)offset;
    return nil;
}
@end

@implementation ZPUFence
- (instancetype)initWithOwner:(ZPUDevice *)owner fence:(zpu_metal_fence *)fence {
    if ((self = [super init])) { _owner = owner; _zpuFence = fence; }
    return self;
}
- (void)dealloc {
    if (_zpuFence != NULL) zpu_metal_fence_destroy(_zpuFence);
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
@end

@implementation ZPUSharedEventNotification
- (instancetype)initWithValue:(uint64_t)value listener:(MTLSharedEventListener *)listener block:(MTLSharedEventNotificationBlock)block {
    if ((self = [super init])) {
        _value = value;
        _listener = listener;
        _block = [block copy];
    }
    return self;
}
@end

@implementation ZPUSharedEvent
- (instancetype)initWithOwner:(ZPUDevice *)owner event:(zpu_metal_shared_event *)event {
    if ((self = [super init])) {
        _owner = owner;
        _zpuEvent = event;
        _notifications = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc {
    if (_zpuEvent != NULL) zpu_metal_shared_event_destroy(_zpuEvent);
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (uint64_t)signaledValue { return zpu_metal_shared_event_signaled_value(_zpuEvent); }
- (void)setSignaledValue:(uint64_t)value {
    if (zpu_metal_shared_event_set_signaled_value(_zpuEvent, value) != ZPU_METAL_OK) return;
    NSMutableArray *fired = [NSMutableArray array];
    for (ZPUSharedEventNotification *notification in _notifications) {
        if (self.signaledValue >= notification->_value) {
            dispatch_async(notification->_listener.dispatchQueue, ^{
                notification->_block((id<MTLSharedEvent>)self, self.signaledValue);
            });
            [fired addObject:notification];
        }
    }
    [_notifications removeObjectsInArray:fired];
}
- (void)notifyListener:(MTLSharedEventListener *)listener atValue:(uint64_t)value block:(MTLSharedEventNotificationBlock)block {
    if (listener == nil || block == nil) return;
    ZPUSharedEventNotification *notification =
        [[ZPUSharedEventNotification alloc] initWithValue:value listener:listener block:block];
    if (self.signaledValue >= value) {
        dispatch_async(listener.dispatchQueue, ^{
            block((id<MTLSharedEvent>)self, self.signaledValue);
        });
    } else {
        [_notifications addObject:notification];
    }
}
- (BOOL)waitUntilSignaledValue:(uint64_t)value timeoutMS:(uint64_t)milliseconds {
    return zpu_metal_shared_event_wait_until_signaled_value(_zpuEvent, value, milliseconds) == ZPU_METAL_OK;
}
- (MTLSharedEventHandle *)newSharedEventHandle { return nil; }
@end

static uint64_t zpu_cpu_timestamp(void) {
    return clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}

@implementation ZPUCounter
- (instancetype)initWithName:(NSString *)name {
    if ((self = [super init])) _name = [name copy];
    return self;
}
- (NSString *)name { return _name; }
@end

@implementation ZPUCounterSet
- (instancetype)initWithName:(NSString *)name counters:(NSArray *)counters {
    if ((self = [super init])) {
        _name = [name copy];
        _counters = [counters copy];
    }
    return self;
}
- (NSString *)name { return _name; }
- (NSArray *)counters { return _counters; }
@end

@implementation ZPUCounterSampleBuffer
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLCounterSampleBufferDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _sampleCount = descriptor.sampleCount;
        _counterSet = descriptor.counterSet;
        if (_sampleCount == 0 || descriptor.storageMode != MTLStorageModeShared ||
            ![_counterSet isKindOfClass:[ZPUCounterSet class]] ||
            ![[_counterSet name] isEqualToString:MTLCommonCounterSetTimestamp]) {
            return nil;
        }
        if (_sampleCount > SIZE_MAX / sizeof(MTLCounterResultTimestamp)) return nil;
        _entries = [NSMutableData dataWithLength:_sampleCount * sizeof(MTLCounterResultTimestamp)];
        MTLCounterResultTimestamp *entries = (MTLCounterResultTimestamp *)_entries.mutableBytes;
        for (NSUInteger index = 0; index < _sampleCount; ++index) entries[index].timestamp = MTLCounterErrorValue;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (NSUInteger)sampleCount { return _sampleCount; }
- (BOOL)sampleAtIndex:(NSUInteger)index {
    if (index >= _sampleCount) return NO;
    @synchronized (self) {
        ((MTLCounterResultTimestamp *)_entries.mutableBytes)[index].timestamp = zpu_cpu_timestamp();
    }
    return YES;
}
- (NSData *)resolveCounterRange:(NSRange)range {
    if (range.location > _sampleCount || range.length > _sampleCount - range.location) return nil;
    @synchronized (self) {
        return [_entries subdataWithRange:NSMakeRange(
            range.location * sizeof(MTLCounterResultTimestamp),
            range.length * sizeof(MTLCounterResultTimestamp))];
    }
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@implementation ZPUMTL4CounterHeap
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CounterHeapDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _type = descriptor.type;
        _count = descriptor.count;
        if (_type != MTL4CounterHeapTypeTimestamp || _count == 0 ||
            _count > SIZE_MAX / sizeof(MTL4TimestampHeapEntry)) {
            return nil;
        }
        _entries = [NSMutableData dataWithLength:_count * sizeof(MTL4TimestampHeapEntry)];
    }
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (NSUInteger)count { return _count; }
- (MTL4CounterHeapType)type { return _type; }
- (BOOL)writeTimestampAtIndex:(NSUInteger)index {
    if (_type != MTL4CounterHeapTypeTimestamp || index >= _count) return NO;
    const uint64_t timestamp = zpu_cpu_timestamp();
    @synchronized (self) {
        ((MTL4TimestampHeapEntry *)_entries.mutableBytes)[index].timestamp = timestamp;
    }
    return YES;
}
- (NSData *)resolveCounterRange:(NSRange)range {
    if (range.location > _count || range.length > _count - range.location) return nil;
    @synchronized (self) {
        return [_entries subdataWithRange:NSMakeRange(
            range.location * sizeof(MTL4TimestampHeapEntry),
            range.length * sizeof(MTL4TimestampHeapEntry))];
    }
}
- (void)invalidateCounterRange:(NSRange)range {
    if (range.location > _count || range.length > _count - range.location) return;
    @synchronized (self) {
        memset((uint8_t *)_entries.mutableBytes + range.location * sizeof(MTL4TimestampHeapEntry), 0,
               range.length * sizeof(MTL4TimestampHeapEntry));
    }
}
@end
#pragma clang diagnostic pop

@implementation ZPURenderPipelineState
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRenderPipelineDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        MTLRenderPipelineColorAttachmentDescriptor *attachment = descriptor.colorAttachments[0];
        _colorPixelFormat = attachment.pixelFormat;
        _depthPixelFormat = descriptor.depthAttachmentPixelFormat;
        _blendingEnabled = attachment.blendingEnabled;
        _sourceRGBBlendFactor = attachment.sourceRGBBlendFactor;
        _destinationRGBBlendFactor = attachment.destinationRGBBlendFactor;
        _rgbBlendOperation = attachment.rgbBlendOperation;
        _sourceAlphaBlendFactor = attachment.sourceAlphaBlendFactor;
        _destinationAlphaBlendFactor = attachment.destinationAlphaBlendFactor;
        _alphaBlendOperation = attachment.alphaBlendOperation;
        _writeMask = attachment.writeMask;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSUInteger)allocatedSize API_AVAILABLE(macos(15.0), ios(18.0)) { return 0; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1; }
- (NSUInteger)maxTotalThreadsPerObjectThreadgroup { return 1; }
- (NSUInteger)maxTotalThreadsPerMeshThreadgroup API_AVAILABLE(macos(13.0), ios(16.0)) { return 0; }
- (NSUInteger)objectThreadExecutionWidth API_AVAILABLE(macos(13.0), ios(16.0)) { return 0; }
- (NSUInteger)meshThreadExecutionWidth API_AVAILABLE(macos(13.0), ios(16.0)) { return 0; }
- (NSUInteger)maxTotalThreadgroupsPerMeshGrid API_AVAILABLE(macos(13.0), ios(16.0)) { return 0; }
- (BOOL)threadgroupSizeMatchesTileSize { return NO; }
- (NSUInteger)imageblockSampleLength API_AVAILABLE(macos(11.0), ios(11.0), macCatalyst(14.0), tvos(14.5)) { return 0; }
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)imageblockDimensions API_AVAILABLE(macos(11.0), ios(11.0), macCatalyst(14.0), tvos(14.5)) {
    (void)imageblockDimensions;
    return 0;
}
- (BOOL)supportIndirectCommandBuffers API_AVAILABLE(macos(10.14), ios(12.0)) { return YES; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){0}; }
- (MTLShaderValidation)shaderValidation API_AVAILABLE(macos(15.0), ios(18.0)) { return (MTLShaderValidation)0; }
- (MTLSize)requiredThreadsPerTileThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (MTLSize)requiredThreadsPerObjectThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (MTLSize)requiredThreadsPerMeshThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (id<MTLFunctionHandle>)functionHandleWithFunction:(id<MTLFunction>)function stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    (void)function;
    (void)stage;
    return nil;
}
- (id<MTLVisibleFunctionTable>)newVisibleFunctionTableWithDescriptor:(MTLVisibleFunctionTableDescriptor *)descriptor stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    (void)descriptor;
    (void)stage;
    return nil;
}
- (id<MTLIntersectionFunctionTable>)newIntersectionFunctionTableWithDescriptor:(MTLIntersectionFunctionTableDescriptor *)descriptor stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    (void)descriptor;
    (void)stage;
    return nil;
}
- (MTLRenderPipelineReflection *)reflection API_AVAILABLE(macos(26.0), ios(26.0)) { return nil; }
- (id<MTLFunctionHandle>)functionHandleWithName:(NSString *)name stage:(MTLRenderStages)stage API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)name;
    (void)stage;
    return nil;
}
- (id<MTLFunctionHandle>)functionHandleWithBinaryFunction:(id<MTL4BinaryFunction>)function stage:(MTLRenderStages)stage API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)function;
    (void)stage;
    return nil;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithBinaryFunctions:(MTL4RenderPipelineBinaryFunctionsDescriptor *)binaryFunctionsDescriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)binaryFunctionsDescriptor;
    zpu_set_error(error, @"ZPU CPU Metal does not link Metal 4 binary functions");
    return nil;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithAdditionalBinaryFunctions:(MTLRenderPipelineFunctionsDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal does not link binary functions");
    return nil;
}
- (MTL4PipelineDescriptor *)newRenderPipelineDescriptorForSpecialization API_AVAILABLE(macos(26.0), ios(26.0)) { return nil; }
@end

@implementation ZPUDepthStencilState
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLDepthStencilDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _depthCompareFunction = descriptor.depthCompareFunction;
        _depthWriteEnabled = descriptor.depthWriteEnabled;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(26.0), ios(26.0)) { return (MTLResourceID){0}; }
@end

@implementation ZPUSamplerState
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLSamplerDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _minFilter = descriptor.minFilter;
        _mipFilter = descriptor.mipFilter;
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){_resourceID}; }
@end

@implementation ZPUDevice
- (instancetype)initWithDevice:(zpu_metal_device *)device {
    if ((self = [super init])) {
        _zpuDevice = device;
        ZPUCounter *timestampCounter = [[ZPUCounter alloc] initWithName:MTLCommonCounterTimestamp];
        ZPUCounterSet *timestampSet = [[ZPUCounterSet alloc] initWithName:MTLCommonCounterSetTimestamp
                                                                    counters:@[timestampCounter]];
        _counterSets = @[timestampSet];
    }
    return self;
}
- (void)dealloc {
    if (_zpuDevice != NULL) zpu_metal_device_destroy(_zpuDevice);
}
- (NSString *)name { return @"ZPU CPU Metal"; }
- (uint64_t)registryID { return 0x5a50555f4d544c44ULL; }
- (NSUInteger)maxBufferLength { return NSUIntegerMax; }
- (uint64_t)recommendedMaxWorkingSetSize { return UINT64_MAX; }
- (BOOL)isHeadless { return YES; }
- (BOOL)isLowPower { return YES; }
- (BOOL)isRemovable { return NO; }
- (BOOL)hasUnifiedMemory { return YES; }
- (MTLSize)maxThreadsPerThreadgroup API_AVAILABLE(macos(10.11), ios(9.0)) { return MTLSizeMake(1024, 1024, 64); }
- (MTLArchitecture *)architecture API_AVAILABLE(macos(14.0), ios(17.0)) { return nil; }
#if !defined(TARGET_OS_IPHONE) || !TARGET_OS_IPHONE
- (uint64_t)maxTransferRate { return 0; }
- (MTLDeviceLocation)location { return MTLDeviceLocationBuiltIn; }
- (NSUInteger)locationNumber { return 0; }
#endif
- (BOOL)isDepth24Stencil8PixelFormatSupported { return NO; }
- (MTLReadWriteTextureTier)readWriteTextureSupport { return MTLReadWriteTextureTier1; }
- (BOOL)areRasterOrderGroupsSupported { return NO; }
- (BOOL)supports32BitFloatFiltering { return NO; }
- (BOOL)supports32BitMSAA { return NO; }
- (BOOL)supportsQueryTextureLOD { return NO; }
- (BOOL)supportsBCTextureCompression { return NO; }
- (BOOL)supportsPullModelInterpolation { return NO; }
- (BOOL)areBarycentricCoordsSupported { return NO; }
- (BOOL)supportsShaderBarycentricCoordinates { return NO; }
- (NSUInteger)currentAllocatedSize { return 0; }
- (NSUInteger)maxThreadgroupMemoryLength { return 0; }
- (NSUInteger)maxArgumentBufferSamplerCount { return 1024; }
- (BOOL)areProgrammableSamplePositionsSupported { return NO; }
- (void)getDefaultSamplePositions:(MTLSamplePosition *)positions count:(NSUInteger)count {
    if (positions == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) positions[index] = (MTLSamplePosition){0.5f, 0.5f};
}
- (BOOL)supportsRasterizationRateMapWithLayerCount:(NSUInteger)layerCount { (void)layerCount; return NO; }
- (BOOL)supportsVertexAmplificationCount:(NSUInteger)count { return count <= 1; }
- (BOOL)supportsDynamicLibraries { return NO; }
- (BOOL)supportsRenderDynamicLibraries { return NO; }
- (BOOL)supportsRaytracing { return NO; }
- (BOOL)supportsCounterSampling:(MTLCounterSamplingPoint)point {
    return point == MTLCounterSamplingPointAtDrawBoundary ||
           point == MTLCounterSamplingPointAtDispatchBoundary ||
           point == MTLCounterSamplingPointAtBlitBoundary;
}
- (NSUInteger)sparseTileSizeInBytes { return 0; }
- (NSUInteger)sparseTileSizeInBytesForSparsePageSize:(MTLSparsePageSize)pageSize API_AVAILABLE(macos(13.0), ios(16.0)) { (void)pageSize; return 0; }
- (NSArray *)counterSets { return _counterSets; }
- (void)sampleTimestamps:(MTLTimestamp *)cpuTimestamp gpuTimestamp:(MTLTimestamp *)gpuTimestamp {
    const MTLTimestamp timestamp = (MTLTimestamp)zpu_cpu_timestamp();
    if (cpuTimestamp != NULL) *cpuTimestamp = timestamp;
    if (gpuTimestamp != NULL) *gpuTimestamp = timestamp;
}
- (MTLArgumentBuffersTier)argumentBuffersSupport { return MTLArgumentBuffersTier1; }
- (BOOL)supportsFamily:(MTLGPUFamily)family { return family == MTLGPUFamilyApple7 || family == MTLGPUFamilyMac2; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (BOOL)supportsFeatureSet:(MTLFeatureSet)featureSet {
#if defined(TARGET_OS_IPHONE) && TARGET_OS_IPHONE
    return featureSet == 14; /* MTLFeatureSet_iOS_GPUFamily3_v4 */
#else
    return featureSet == 10005; /* MTLFeatureSet_macOS_GPUFamily2_v1 */
#endif
}
#pragma clang diagnostic pop
- (BOOL)supportsTextureSampleCount:(NSUInteger)sampleCount { return sampleCount == 1; }
- (NSUInteger)minimumLinearTextureAlignmentForPixelFormat:(MTLPixelFormat)format { return format == MTLPixelFormatInvalid ? 0 : 4; }
- (NSUInteger)minimumTextureBufferAlignmentForPixelFormat:(MTLPixelFormat)format { return format == MTLPixelFormatInvalid ? 0 : 4; }
- (id<MTLCommandQueue>)newCommandQueue {
    zpu_metal_command_queue *queue = zpu_metal_device_new_command_queue(_zpuDevice);
    if (queue == NULL) return nil;
    return (id<MTLCommandQueue>)[[ZPUCommandQueue alloc] initWithOwner:self queue:queue];
}
- (id<MTLCommandQueue>)newCommandQueueWithMaxCommandBufferCount:(NSUInteger)maxCommandBufferCount {
    return maxCommandBufferCount == 0 ? nil : [self newCommandQueue];
}
- (id<MTLCommandQueue>)newCommandQueueWithDescriptor:(MTLCommandQueueDescriptor *)descriptor API_AVAILABLE(macos(15.0), ios(18.0)) {
    return descriptor == nil ? nil : [self newCommandQueue];
}
- (MTLSizeAndAlign)heapTextureSizeAndAlignWithDescriptor:(MTLTextureDescriptor *)descriptor API_AVAILABLE(macos(10.13), ios(10.0)) {
    if (descriptor == nil || descriptor.width > SIZE_MAX / 4 || descriptor.height > SIZE_MAX / (descriptor.width == 0 ? 1 : descriptor.width * 4)) return (MTLSizeAndAlign){0, 0};
    if (descriptor.textureType != MTLTextureType2D || descriptor.depth != 1 || descriptor.arrayLength != 1 ||
        descriptor.mipmapLevelCount != 1 || descriptor.sampleCount != 1 ||
        (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm &&
         descriptor.pixelFormat != MTLPixelFormatDepth32Float)) return (MTLSizeAndAlign){0, 0};
    const NSUInteger rowBytes = descriptor.width * 4;
    return (MTLSizeAndAlign){rowBytes * descriptor.height, 4};
}
- (MTLSizeAndAlign)heapBufferSizeAndAlignWithLength:(NSUInteger)length options:(MTLResourceOptions)options API_AVAILABLE(macos(10.13), ios(10.0)) {
    (void)options;
    return (MTLSizeAndAlign){length, 4};
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options {
    zpu_metal_buffer *buffer = zpu_metal_device_new_buffer(_zpuDevice, length, NULL);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:self buffer:buffer];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLBuffer>)newBufferWithBytes:(const void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options {
    if (pointer == NULL && length != 0) return nil;
    zpu_metal_buffer *buffer = zpu_metal_device_new_buffer(_zpuDevice, length, pointer);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:self buffer:buffer];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLBuffer>)newBufferWithBytesNoCopy:(void *)pointer length:(NSUInteger)length options:(MTLResourceOptions)options deallocator:(void (^)(void *pointer, NSUInteger length))deallocator {
    if (pointer == NULL && length != 0) return nil;
    zpu_metal_buffer *buffer = zpu_metal_device_new_buffer(_zpuDevice, length, pointer);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:self buffer:buffer
                                             deallocator:deallocator pointer:pointer length:length];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    if (descriptor == nil || descriptor.textureType != MTLTextureType2D || descriptor.depth != 1 || descriptor.arrayLength != 1 || descriptor.mipmapLevelCount != 1 || descriptor.sampleCount != 1) return nil;
    if (descriptor.width > UINT32_MAX || descriptor.height > UINT32_MAX) return nil;
    if (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm && descriptor.pixelFormat != MTLPixelFormatDepth32Float) return nil;
    zpu_metal_texture_descriptor zpu_descriptor = {
        (uint32_t)descriptor.width, (uint32_t)descriptor.height, zpu_pixel_format(descriptor.pixelFormat),
    };
    zpu_metal_texture *texture = zpu_metal_device_new_texture(_zpuDevice, &zpu_descriptor);
    if (texture == NULL) return nil;
    ZPUTexture *result = [[ZPUTexture alloc] initWithOwner:self texture:texture
                                                      type:descriptor.textureType
                                               pixelFormat:descriptor.pixelFormat];
    [result applyDescriptor:descriptor];
    return (id<MTLTexture>)result;
}
- (id<MTLFence>)newFence {
    zpu_metal_fence *fence = zpu_metal_device_new_fence(_zpuDevice);
    return fence == NULL ? nil : (id<MTLFence>)[[ZPUFence alloc] initWithOwner:self fence:fence];
}
- (id<MTLSharedEvent>)newSharedEvent {
    zpu_metal_shared_event *event = zpu_metal_device_new_shared_event(_zpuDevice);
    return event == NULL ? nil : (id<MTLSharedEvent>)[[ZPUSharedEvent alloc] initWithOwner:self event:event];
}
- (id<MTLHeap>)newHeapWithDescriptor:(MTLHeapDescriptor *)descriptor {
    if (descriptor == nil || descriptor.size == 0) return nil;
    zpu_metal_heap *heap = zpu_metal_device_new_heap(_zpuDevice, descriptor.size);
    return heap == NULL ? nil : (id<MTLHeap>)[[ZPUHeap alloc] initWithOwner:self heap:heap descriptor:descriptor];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil || descriptor.vertexFunction == nil || descriptor.fragmentFunction == nil ||
        descriptor.rasterSampleCount != 1 || !zpu_render_pipeline_format_supported(descriptor.colorAttachments[0].pixelFormat) ||
        !zpu_depth_format_supported(descriptor.depthAttachmentPixelFormat)) {
        zpu_set_error(error, @"ZPU Metal supports only the fixed Vertex ABI with RGBA8/BGRA8 and depth32-float attachments");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLRenderPipelineState>)[[ZPURenderPipelineState alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options reflection:(MTLRenderPipelineReflection **)reflection error:(NSError **)error {
    (void)options;
    if (reflection != NULL) *reflection = nil;
    return [self newRenderPipelineStateWithDescriptor:descriptor error:error];
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor completionHandler:(MTLNewRenderPipelineStateCompletionHandler)completionHandler {
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:descriptor error:&error];
    completionHandler(state, error);
}
- (void)newRenderPipelineStateWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)completionHandler {
    (void)options;
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLRenderPipelineState> state = [self newRenderPipelineStateWithDescriptor:descriptor error:&error];
    completionHandler(state, nil, error);
}
- (id<MTLDepthStencilState>)newDepthStencilStateWithDescriptor:(MTLDepthStencilDescriptor *)descriptor {
    return descriptor == nil ? nil : (id<MTLDepthStencilState>)[[ZPUDepthStencilState alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTLSamplerState>)newSamplerStateWithDescriptor:(MTLSamplerDescriptor *)descriptor {
    return descriptor == nil ? nil : (id<MTLSamplerState>)[[ZPUSamplerState alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTLLibrary>)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options error:(NSError **)error {
    (void)options;
    if (source == nil) {
        zpu_set_error(error, @"ZPU CPU Metal requires source text");
        return nil;
    }
    ZPULibrary *library = [[ZPULibrary alloc] initWithOwner:self source:source];
    if (library->_functionNames.count == 0) {
        zpu_set_error(error, @"ZPU CPU Metal source contains no registered CPU kernel");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLLibrary>)library;
}
- (void)newLibraryWithSource:(NSString *)source options:(MTLCompileOptions *)options completionHandler:(MTLNewLibraryCompletionHandler)completionHandler {
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLLibrary> library = [self newLibraryWithSource:source options:options error:&error];
    completionHandler(library, error);
}
- (id<MTLEvent>)newEvent API_AVAILABLE(macos(10.14), ios(12.0)) {
    return (id<MTLEvent>)[self newSharedEvent];
}
- (id<MTLSharedEvent>)newSharedEventWithHandle:(MTLSharedEventHandle *)sharedEventHandle API_AVAILABLE(macos(10.14), ios(12.0)) {
    (void)sharedEventHandle;
    return nil;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)iosurface plane:(NSUInteger)plane API_AVAILABLE(macos(10.11), ios(11.0)) {
    (void)descriptor;
    (void)iosurface;
    (void)plane;
    return nil;
}
- (id<MTLTexture>)newSharedTextureWithDescriptor:(MTLTextureDescriptor *)descriptor API_AVAILABLE(macos(10.14), ios(13.0)) {
    (void)descriptor;
    return nil;
}
- (id<MTLTexture>)newSharedTextureWithHandle:(MTLSharedTextureHandle *)sharedHandle API_AVAILABLE(macos(10.14), ios(13.0)) {
    (void)sharedHandle;
    return nil;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithArguments:(NSArray<MTLArgumentDescriptor *> *)arguments API_AVAILABLE(macos(10.13), ios(11.0)) {
    return arguments == nil ? nil : (id<MTLArgumentEncoder>)[[ZPUArgumentEncoder alloc] initWithOwner:self arguments:arguments];
}
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferBinding:(id<MTLBufferBinding>)bufferBinding API_AVAILABLE(macos(13.0), ios(16.0)) {
    return bufferBinding == nil ? nil : (id<MTLArgumentEncoder>)[[ZPUArgumentEncoder alloc] initWithOwner:self arguments:@[]];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)computeFunction error:(NSError **)error {
    return (id<MTLComputePipelineState>)[[ZPUComputePipelineState alloc] initWithOwner:self function:computeFunction error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithFunction:(id<MTLFunction>)computeFunction options:(MTLPipelineOption)options reflection:(MTLAutoreleasedComputePipelineReflection * __nullable)reflection error:(NSError **)error {
    (void)options;
    if (reflection != NULL) *reflection = nil;
    return [self newComputePipelineStateWithFunction:computeFunction error:error];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor options:(MTLPipelineOption)options reflection:(MTLAutoreleasedComputePipelineReflection * __nullable)reflection error:(NSError **)error API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    if (reflection != NULL) *reflection = nil;
    return descriptor == nil ? nil : [self newComputePipelineStateWithFunction:descriptor.computeFunction error:error];
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)computeFunction completionHandler:(MTLNewComputePipelineStateCompletionHandler)completionHandler {
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLComputePipelineState> state = [self newComputePipelineStateWithFunction:computeFunction error:&error];
    completionHandler(state, error);
}
- (void)newComputePipelineStateWithFunction:(id<MTLFunction>)computeFunction options:(MTLPipelineOption)options completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)completionHandler {
    (void)options;
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLComputePipelineState> state = [self newComputePipelineStateWithFunction:computeFunction error:&error];
    completionHandler(state, nil, error);
}
- (void)newComputePipelineStateWithDescriptor:(MTLComputePipelineDescriptor *)descriptor options:(MTLPipelineOption)options completionHandler:(MTLNewComputePipelineStateWithReflectionCompletionHandler)completionHandler API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLComputePipelineState> state = [self newComputePipelineStateWithDescriptor:descriptor options:0 reflection:nil error:&error];
    completionHandler(state, nil, error);
}
- (id<MTLIndirectCommandBuffer>)newIndirectCommandBufferWithDescriptor:(MTLIndirectCommandBufferDescriptor *)descriptor maxCommandCount:(NSUInteger)maxCount options:(MTLResourceOptions)options API_AVAILABLE(macos(10.14), ios(12.0)) {
    const MTLIndirectCommandType renderTypes = MTLIndirectCommandTypeDraw | MTLIndirectCommandTypeDrawIndexed;
    const MTLIndirectCommandType computeTypes = MTLIndirectCommandTypeConcurrentDispatch |
        MTLIndirectCommandTypeConcurrentDispatchThreads;
    const MTLIndirectCommandType supported = renderTypes | computeTypes;
    const MTLIndirectCommandType requested = descriptor == nil ? 0 : descriptor.commandTypes;
    if (descriptor == nil || maxCount == 0 || (requested & ~supported) != 0 || requested == 0 ||
        ((requested & renderTypes) != 0 && (requested & computeTypes) != 0)) return nil;
    return (id<MTLIndirectCommandBuffer>)[[ZPUIndirectCommandBuffer alloc]
        initWithOwner:self descriptor:descriptor maxCommandCount:maxCount options:options];
}
- (id<MTLLibrary>)newDefaultLibrary {
    return (id<MTLLibrary>)[[ZPULibrary alloc] initWithOwner:self
                                                        source:@"zpu_cpu_fill_gradient_rgba8 zpu_cpu_copy_rgba8_buffer_to_texture"];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)bundle;
    zpu_set_error(error, @"ZPU CPU Metal has no default shader library");
    return nil;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)filepath error:(NSError **)error {
    (void)filepath;
    zpu_set_error(error, @"ZPU CPU Metal does not load compiled metallib files");
    return nil;
}
#pragma clang diagnostic pop
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(10.13), ios(11.0)) {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal does not load compiled metallib files");
    return nil;
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    (void)data;
    zpu_set_error(error, @"ZPU CPU Metal does not load compiled metallib data");
    return nil;
}
- (id<MTLLibrary>)newLibraryWithStitchedDescriptor:(MTLStitchedLibraryDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(12.0), ios(15.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal does not stitch arbitrary shader libraries");
    return nil;
}
- (void)newLibraryWithStitchedDescriptor:(MTLStitchedLibraryDescriptor *)descriptor completionHandler:(MTLNewLibraryCompletionHandler)completionHandler API_AVAILABLE(macos(12.0), ios(15.0)) {
    (void)descriptor;
    if (completionHandler == nil) return;
    NSError *error = nil;
    zpu_set_error(&error, @"ZPU CPU Metal does not stitch arbitrary shader libraries");
    completionHandler(nil, error);
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)descriptor;
    (void)options;
    if (reflection != NULL) *reflection = nil;
    zpu_set_error(error, @"ZPU CPU Metal has no tile-shader implementation");
    return nil;
}
- (void)newRenderPipelineStateWithTileDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)completionHandler API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)descriptor;
    (void)options;
    if (completionHandler == nil) return;
    NSError *error = nil;
    zpu_set_error(&error, @"ZPU CPU Metal has no tile-shader implementation");
    completionHandler(nil, nil, error);
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options reflection:(MTLAutoreleasedRenderPipelineReflection *)reflection error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    (void)options;
    if (reflection != NULL) *reflection = nil;
    zpu_set_error(error, @"ZPU CPU Metal has no mesh-shader implementation");
    return nil;
}
- (void)newRenderPipelineStateWithMeshDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor options:(MTLPipelineOption)options completionHandler:(MTLNewRenderPipelineStateWithReflectionCompletionHandler)completionHandler API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    (void)options;
    if (completionHandler == nil) return;
    NSError *error = nil;
    zpu_set_error(&error, @"ZPU CPU Metal has no mesh-shader implementation");
    completionHandler(nil, nil, error);
}
- (id<MTLRasterizationRateMap>)newRasterizationRateMapWithDescriptor:(MTLRasterizationRateMapDescriptor *)descriptor API_AVAILABLE(macos(10.15), ios(13.0), macCatalyst(13.4), tvos(16.0)) {
    (void)descriptor;
    return nil;
}
- (uint64_t)peerGroupID API_AVAILABLE(macos(10.15)) { return 0; }
- (uint32_t)peerIndex API_AVAILABLE(macos(10.15)) { return 0; }
- (uint32_t)peerCount API_AVAILABLE(macos(10.15)) { return 1; }
- (id<MTLDynamicLibrary>)newDynamicLibrary:(id<MTLLibrary>)library error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)library;
    zpu_set_error(error, @"ZPU CPU Metal has no dynamic shader libraries");
    return nil;
}
- (id<MTLDynamicLibrary>)newDynamicLibraryWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal has no dynamic shader libraries");
    return nil;
}
- (id<MTLBinaryArchive>)newBinaryArchiveWithDescriptor:(MTLBinaryArchiveDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no binary shader archive");
    return nil;
}
- (BOOL)supportsPlacementSparse API_AVAILABLE(macos(26.4), ios(26.4)) { return NO; }
- (BOOL)supportsFunctionPointers API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) { return NO; }
- (BOOL)supportsFunctionPointersFromRender API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { return NO; }
- (BOOL)supportsRaytracingFromRender API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { return NO; }
- (BOOL)supportsPrimitiveMotionBlur API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) { return NO; }
- (BOOL)shouldMaximizeConcurrentCompilation API_AVAILABLE(macos(13.3)) { return NO; }
- (void)setShouldMaximizeConcurrentCompilation:(BOOL)value API_AVAILABLE(macos(13.3)) { (void)value; }
- (NSUInteger)maximumConcurrentCompilationTaskCount API_AVAILABLE(macos(13.3), ios(26.0)) { return 1; }
- (id<MTLResidencySet>)newResidencySetWithDescriptor:(MTLResidencySetDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no residency-set implementation");
    return nil;
}
- (MTLAccelerationStructureSizes)accelerationStructureSizesWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    return (MTLAccelerationStructureSizes){0, 0, 0};
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithSize:(NSUInteger)size API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)size;
    return nil;
}
- (id<MTLAccelerationStructure>)newAccelerationStructureWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    return nil;
}
- (MTLSizeAndAlign)heapAccelerationStructureSizeAndAlignWithSize:(NSUInteger)size API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)size;
    return (MTLSizeAndAlign){0, 0};
}
- (MTLSizeAndAlign)heapAccelerationStructureSizeAndAlignWithDescriptor:(MTLAccelerationStructureDescriptor *)descriptor API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    return (MTLSizeAndAlign){0, 0};
}
- (MTLSizeAndAlign)tensorSizeAndAlignWithDescriptor:(MTLTensorDescriptor *)descriptor API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)descriptor;
    return (MTLSizeAndAlign){0, 0};
}
- (id<MTLTensor>)newTensorWithDescriptor:(MTLTensorDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no tensor implementation");
    return nil;
}
- (id<MTLFunctionHandle>)functionHandleWithFunction:(id<MTLFunction>)function API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)function;
    return nil;
}
- (id<MTLIOFileHandle>)newIOHandleWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal I/O implementation");
    return nil;
}
- (id<MTLIOFileHandle>)newIOHandleWithURL:(NSURL *)url compressionMethod:(MTLIOCompressionMethod)compressionMethod error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)url;
    (void)compressionMethod;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal I/O implementation");
    return nil;
}
- (id<MTLIOCommandQueue>)newIOCommandQueueWithDescriptor:(MTLIOCommandQueueDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal I/O implementation");
    return nil;
}
- (id<MTLIOFileHandle>)newIOFileHandleWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal I/O implementation");
    return nil;
}
- (id<MTLIOFileHandle>)newIOFileHandleWithURL:(NSURL *)url compressionMethod:(MTLIOCompressionMethod)compressionMethod error:(NSError **)error API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)url;
    (void)compressionMethod;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal I/O implementation");
    return nil;
}
- (id<MTLLogState>)newLogStateWithDescriptor:(MTLLogStateDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no GPU log-state implementation");
    return nil;
}
- (id<MTLCounterSampleBuffer>)newCounterSampleBufferWithDescriptor:(MTLCounterSampleBufferDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(10.15), ios(14.0)) {
    if (descriptor == nil || descriptor.sampleCount == 0 || descriptor.storageMode != MTLStorageModeShared ||
        ![descriptor.counterSet isKindOfClass:[ZPUCounterSet class]] ||
        ![descriptor.counterSet.name isEqualToString:MTLCommonCounterSetTimestamp]) {
        zpu_set_error(error, @"ZPU CPU Metal supports only shared timestamp counter sample buffers");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLCounterSampleBuffer>)[[ZPUCounterSampleBuffer alloc] initWithOwner:self descriptor:descriptor];
}
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)textureType pixelFormat:(MTLPixelFormat)pixelFormat sampleCount:(NSUInteger)sampleCount API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0), tvos(16.0)) {
    (void)textureType;
    (void)pixelFormat;
    (void)sampleCount;
    return MTLSizeMake(0, 0, 0);
}
- (MTLSize)sparseTileSizeWithTextureType:(MTLTextureType)textureType pixelFormat:(MTLPixelFormat)pixelFormat sampleCount:(NSUInteger)sampleCount sparsePageSize:(MTLSparsePageSize)sparsePageSize API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)textureType;
    (void)pixelFormat;
    (void)sampleCount;
    (void)sparsePageSize;
    return MTLSizeMake(0, 0, 0);
}
- (void)convertSparsePixelRegions:(const MTLRegion[_Nonnull])pixelRegions toTileRegions:(MTLRegion[_Nonnull])tileRegions withTileSize:(MTLSize)tileSize alignmentMode:(MTLSparseTextureRegionAlignmentMode)mode numRegions:(NSUInteger)numRegions API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0), tvos(16.0)) {
    (void)pixelRegions;
    (void)tileRegions;
    (void)tileSize;
    (void)mode;
    (void)numRegions;
}
- (void)convertSparseTileRegions:(const MTLRegion[_Nonnull])tileRegions toPixelRegions:(MTLRegion[_Nonnull])pixelRegions withTileSize:(MTLSize)tileSize numRegions:(NSUInteger)numRegions API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0), tvos(16.0)) {
    (void)tileRegions;
    (void)pixelRegions;
    (void)tileSize;
    (void)numRegions;
}
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options placementSparsePageSize:(MTLSparsePageSize)placementSparsePageSize API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)length;
    (void)options;
    (void)placementSparsePageSize;
    return nil;
}
- (id<MTL4CommandAllocator>)newCommandAllocator API_AVAILABLE(macos(26.0), ios(26.0)) {
    return (id<MTL4CommandAllocator>)[[ZPUMTL4CommandAllocator alloc] initWithOwner:self descriptor:nil];
}
- (id<MTL4CommandAllocator>)newCommandAllocatorWithDescriptor:(MTL4CommandAllocatorDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal requires a Metal 4 command allocator descriptor");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4CommandAllocator>)[[ZPUMTL4CommandAllocator alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTL4CommandQueue>)newMTL4CommandQueue API_AVAILABLE(macos(26.0), ios(26.0)) {
    return (id<MTL4CommandQueue>)[[ZPUMTL4CommandQueue alloc] initWithOwner:self descriptor:nil];
}
- (id<MTL4CommandQueue>)newMTL4CommandQueueWithDescriptor:(MTL4CommandQueueDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal requires a Metal 4 command queue descriptor");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4CommandQueue>)[[ZPUMTL4CommandQueue alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTL4CommandBuffer>)newCommandBuffer API_AVAILABLE(macos(26.0), ios(26.0)) {
    return (id<MTL4CommandBuffer>)[[ZPUMTL4CommandBuffer alloc] initWithOwner:self];
}
- (id<MTL4ArgumentTable>)newArgumentTableWithDescriptor:(MTL4ArgumentTableDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil || descriptor.maxBufferBindCount > 31 ||
        descriptor.maxTextureBindCount > 128 || descriptor.maxSamplerStateBindCount > 16) {
        zpu_set_error(error, @"ZPU CPU Metal Metal 4 argument table binding counts exceed the API limits");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4ArgumentTable>)[[ZPUMTL4ArgumentTable alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTLTextureViewPool>)newTextureViewPoolWithDescriptor:(MTLResourceViewPoolDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil || descriptor.resourceViewCount == 0) {
        zpu_set_error(error, @"ZPU CPU Metal requires a non-empty texture view pool descriptor");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLTextureViewPool>)[[ZPUTextureViewPool alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTL4Compiler>)newCompilerWithDescriptor:(MTL4CompilerDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal 4 compiler");
    return nil;
}
- (id<MTL4Archive>)newArchiveWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal has no Metal 4 archive");
    return nil;
}
- (id<MTL4PipelineDataSetSerializer>)newPipelineDataSetSerializerWithDescriptor:(MTL4PipelineDataSetSerializerDescriptor *)descriptor API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)descriptor;
    return nil;
}
- (id<MTL4CounterHeap>)newCounterHeapWithDescriptor:(MTL4CounterHeapDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil || descriptor.type != MTL4CounterHeapTypeTimestamp || descriptor.count == 0 ||
        descriptor.count > SIZE_MAX / sizeof(MTL4TimestampHeapEntry)) {
        zpu_set_error(error, @"ZPU CPU Metal supports only non-empty Metal 4 timestamp counter heaps");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4CounterHeap>)[[ZPUMTL4CounterHeap alloc] initWithOwner:self descriptor:descriptor];
}
- (NSUInteger)sizeOfCounterHeapEntry:(MTL4CounterHeapType)type API_AVAILABLE(macos(26.0), ios(26.0)) {
    return type == MTL4CounterHeapTypeTimestamp ? sizeof(MTL4TimestampHeapEntry) : 0;
}
- (uint64_t)queryTimestampFrequency API_AVAILABLE(macos(26.0), ios(26.0)) { return 1000000000ULL; }
- (id<MTLFunctionHandle>)functionHandleWithBinaryFunction:(id<MTL4BinaryFunction>)function API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)function;
    return nil;
}
@end

@implementation ZPUCPUFunction
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name {
    if ((self = [super init])) {
        _owner = owner;
        _name = [name copy];
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)name { return _name; }
- (MTLFunctionType)functionType {
    if ([_name rangeOfString:@"vertex" options:NSCaseInsensitiveSearch].location != NSNotFound) return MTLFunctionTypeVertex;
    if ([_name rangeOfString:@"fragment" options:NSCaseInsensitiveSearch].location != NSNotFound) return MTLFunctionTypeFragment;
    return MTLFunctionTypeKernel;
}
- (NSString *)label { return _name; }
- (void)setLabel:(NSString *)label { _name = [label copy]; }
- (MTLPatchType)patchType API_AVAILABLE(macos(10.12), ios(10.0)) { return MTLPatchTypeNone; }
- (NSInteger)patchControlPointCount API_AVAILABLE(macos(10.12), ios(10.0)) { return -1; }
- (NSArray *)vertexAttributes { return @[]; }
- (NSArray *)stageInputAttributes API_AVAILABLE(macos(10.12), ios(10.0)) { return @[]; }
- (NSDictionary *)functionConstantsDictionary API_AVAILABLE(macos(10.12), ios(10.0)) { return @{}; }
- (MTLFunctionOptions)options API_AVAILABLE(macos(11.0), ios(14.0)) { return MTLFunctionOptionNone; }
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(10.13), ios(11.0)) {
    (void)bufferIndex;
    return (id<MTLArgumentEncoder>)[(id)_owner newArgumentEncoderWithArguments:@[]];
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (id<MTLArgumentEncoder>)newArgumentEncoderWithBufferIndex:(NSUInteger)bufferIndex
                                                  reflection:(MTLAutoreleasedArgument * __nullable)reflection API_AVAILABLE(macos(10.13), ios(11.0)) {
    if (reflection != NULL) *reflection = nil;
    return [self newArgumentEncoderWithBufferIndex:bufferIndex];
}
#pragma clang diagnostic pop
@end

@implementation ZPULibrary
- (instancetype)initWithOwner:(ZPUDevice *)owner source:(NSString *)source {
    if ((self = [super init])) {
        _owner = owner;
        NSMutableArray *names = [NSMutableArray array];
        for (NSString *name in @[
            @"zpu_cpu_fill_gradient_rgba8",
            @"zpu_cpu_copy_rgba8_buffer_to_texture",
        ]) {
            if ([source rangeOfString:name].location != NSNotFound) [names addObject:name];
        }
        _functionNames = [names copy];
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)functionName {
    if (![_functionNames containsObject:functionName]) return nil;
    return (id<MTLFunction>)[[ZPUCPUFunction alloc] initWithOwner:_owner name:functionName];
}
- (id<MTLFunction>)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)constantValues error:(NSError **)error API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)constantValues;
    id<MTLFunction> function = [self newFunctionWithName:name];
    if (function == nil) zpu_set_error(error, @"ZPU CPU Metal function is not registered");
    else if (error != NULL) *error = nil;
    return function;
}
- (void)newFunctionWithName:(NSString *)name constantValues:(MTLFunctionConstantValues *)constantValues
           completionHandler:(void (^)(id<MTLFunction> __nullable function, NSError * __nullable error))completionHandler API_AVAILABLE(macos(10.12), ios(10.0)) {
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLFunction> function = [self newFunctionWithName:name constantValues:constantValues error:&error];
    completionHandler(function, error);
}
- (NSArray<NSString *> *)functionNames { return _functionNames; }
- (MTLLibraryType)type API_AVAILABLE(macos(11.0), ios(14.0)) { return MTLLibraryTypeExecutable; }
- (NSString *)installName API_AVAILABLE(macos(11.0), ios(14.0)) { return nil; }
- (MTLFunctionReflection *)reflectionForFunctionWithName:(NSString *)functionName API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)functionName;
    return nil;
}
- (id<MTLFunction>)newFunctionWithDescriptor:(MTLFunctionDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal does not specialize arbitrary function descriptors");
    return nil;
}
- (void)newFunctionWithDescriptor:(MTLFunctionDescriptor *)descriptor
                 completionHandler:(void (^)(id<MTLFunction> __nullable function, NSError * __nullable error))completionHandler API_AVAILABLE(macos(11.0), ios(14.0)) {
    if (completionHandler == nil) return;
    NSError *error = nil;
    id<MTLFunction> function = [self newFunctionWithDescriptor:descriptor error:&error];
    completionHandler(function, error);
}
- (id<MTLFunction>)newIntersectionFunctionWithDescriptor:(MTLIntersectionFunctionDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal has no intersection-function implementation");
    return nil;
}
- (void)newIntersectionFunctionWithDescriptor:(MTLIntersectionFunctionDescriptor *)descriptor completionHandler:(void (^)(id<MTLFunction> __nullable function, NSError * __nullable error))completionHandler API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    if (completionHandler == nil) return;
    NSError *error = nil;
    zpu_set_error(&error, @"ZPU CPU Metal has no intersection-function implementation");
    completionHandler(nil, error);
}
@end

@implementation ZPUCommandQueue
- (instancetype)initWithOwner:(ZPUDevice *)owner queue:(zpu_metal_command_queue *)queue {
    if ((self = [super init])) { _owner = owner; _zpuQueue = queue; }
    return self;
}
- (void)dealloc {
    if (_zpuQueue != NULL) zpu_metal_command_queue_destroy(_zpuQueue);
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)insertDebugCaptureBoundary {}
- (void)addResidencySet:(id)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) { (void)residencySet; }
- (void)addResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) { (void)residencySets; (void)count; }
- (void)removeResidencySet:(id)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) { (void)residencySet; }
- (void)removeResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) { (void)residencySets; (void)count; }
- (id<MTLCommandBuffer>)commandBuffer {
    zpu_metal_command_buffer *commandBuffer = zpu_metal_command_queue_command_buffer(_zpuQueue);
    if (commandBuffer == NULL) return nil;
    return (id<MTLCommandBuffer>)[[ZPUCommandBuffer alloc] initWithOwner:self commandBuffer:commandBuffer];
}
- (id<MTLCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (id<MTLCommandBuffer>)commandBufferWithDescriptor:(MTLCommandBufferDescriptor *)descriptor { (void)descriptor; return [self commandBuffer]; }
@end

@implementation ZPUCommandBuffer
- (instancetype)initWithOwner:(ZPUCommandQueue *)owner commandBuffer:(zpu_metal_command_buffer *)commandBuffer {
    if ((self = [super init])) {
        _owner = owner;
        _zpuCommandBuffer = commandBuffer;
        _retainedResources = [NSMutableArray array];
        _scheduledHandlers = [NSMutableArray array];
        _completedHandlers = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc {
    if (_zpuCommandBuffer != NULL) zpu_metal_command_buffer_destroy(_zpuCommandBuffer);
}
- (void)retainResource:(id)resource { if (resource != nil) [_retainedResources addObject:resource]; }
- (void)markError { zpu_metal_command_buffer_mark_error(_zpuCommandBuffer); }
- (id<MTLDevice>)device { return [_owner device]; }
- (id<MTLCommandQueue>)commandQueue { return (id<MTLCommandQueue>)_owner; }
- (BOOL)retainedReferences { return YES; }
- (MTLCommandBufferErrorOption)errorOptions { return MTLCommandBufferErrorOptionNone; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (CFTimeInterval)kernelStartTime { return 0; }
- (CFTimeInterval)kernelEndTime { return 0; }
- (CFTimeInterval)GPUStartTime { return 0; }
- (CFTimeInterval)GPUEndTime { return 0; }
- (id<MTLLogContainer>)logs { return nil; }
- (MTLCommandBufferStatus)status {
    switch (zpu_metal_command_buffer_get_status(_zpuCommandBuffer)) {
        case ZPU_METAL_COMMAND_BUFFER_COMMITTED: return MTLCommandBufferStatusCommitted;
        case ZPU_METAL_COMMAND_BUFFER_COMPLETED: return MTLCommandBufferStatusCompleted;
        case ZPU_METAL_COMMAND_BUFFER_ERROR: return MTLCommandBufferStatusError;
        default: return MTLCommandBufferStatusNotEnqueued;
    }
}
- (NSError *)error { return _error; }
- (void)enqueue { [self commit]; }
- (void)commit {
    NSArray *scheduled = [_scheduledHandlers copy];
    [_scheduledHandlers removeAllObjects];
    for (MTLCommandBufferHandler block in scheduled) block((id<MTLCommandBuffer>)self);
    if (zpu_metal_command_buffer_commit(_zpuCommandBuffer) != ZPU_METAL_OK) {
        _error = [NSError errorWithDomain:@"ZPUMetal" code:ZPU_METAL_INVALID_COMMAND
                                userInfo:@{NSLocalizedDescriptionKey: @"ZPU Metal command buffer execution failed"}];
    }
    NSArray *completed = [_completedHandlers copy];
    [_completedHandlers removeAllObjects];
    for (MTLCommandBufferHandler block in completed) block((id<MTLCommandBuffer>)self);
}
- (void)waitUntilCompleted {
    (void)zpu_metal_command_buffer_wait_until_completed(_zpuCommandBuffer);
}
- (void)waitUntilScheduled {}
- (void)presentDrawable:(id<MTLDrawable>)drawable { (void)drawable; }
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime { (void)drawable; (void)presentationTime; }
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration API_AVAILABLE(macos(10.15.4), ios(10.3), macCatalyst(13.4)) { (void)drawable; (void)duration; }
- (void)addScheduledHandler:(MTLCommandBufferHandler)block {
    if (block == nil) return;
    if ([self status] != MTLCommandBufferStatusNotEnqueued) {
        block((id<MTLCommandBuffer>)self);
        return;
    }
    [_scheduledHandlers addObject:[block copy]];
}
- (void)addCompletedHandler:(MTLCommandBufferHandler)block {
    if (block == nil) return;
    if ([self status] == MTLCommandBufferStatusCompleted || [self status] == MTLCommandBufferStatusError) {
        block((id<MTLCommandBuffer>)self);
        return;
    }
    [_completedHandlers addObject:[block copy]];
}
- (id<MTLRenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    if (descriptor == nil || descriptor.colorAttachments[0].texture == nil) return nil;
    ZPUTexture *texture = (ZPUTexture *)descriptor.colorAttachments[0].texture;
    if (![texture isKindOfClass:[ZPUTexture class]]) return nil;
    zpu_metal_render_pass_descriptor pass = {
        .color = {
            .load_action = zpu_load_action(descriptor.colorAttachments[0].loadAction),
            .store_action = zpu_store_action(descriptor.colorAttachments[0].storeAction),
            .clear_color = {
                (float)descriptor.colorAttachments[0].clearColor.red,
                (float)descriptor.colorAttachments[0].clearColor.green,
                (float)descriptor.colorAttachments[0].clearColor.blue,
                (float)descriptor.colorAttachments[0].clearColor.alpha,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        if (![depth isKindOfClass:[ZPUTexture class]] || depth->_pixelFormat != MTLPixelFormatDepth32Float) return nil;
        pass.depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass.depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass.depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(_zpuCommandBuffer, texture->_zpuTexture, &pass);
    if (encoder == NULL) return nil;
    [self retainResource:texture];
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        [self retainResource:depth];
        if (zpu_metal_render_encoder_set_depth_texture(encoder, depth->_zpuTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            return nil;
        }
    }
    return (id<MTLRenderCommandEncoder>)[[ZPURenderEncoder alloc] initWithOwner:self encoder:encoder];
}
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    if (descriptor == nil || descriptor.colorAttachments[0].texture == nil) return nil;
    ZPUTexture *texture = (ZPUTexture *)descriptor.colorAttachments[0].texture;
    if (![texture isKindOfClass:[ZPUTexture class]]) return nil;
    zpu_metal_render_pass_descriptor pass = {
        .color = {
            .load_action = zpu_load_action(descriptor.colorAttachments[0].loadAction),
            .store_action = zpu_store_action(descriptor.colorAttachments[0].storeAction),
            .clear_color = {
                (float)descriptor.colorAttachments[0].clearColor.red,
                (float)descriptor.colorAttachments[0].clearColor.green,
                (float)descriptor.colorAttachments[0].clearColor.blue,
                (float)descriptor.colorAttachments[0].clearColor.alpha,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        if (![depth isKindOfClass:[ZPUTexture class]] || depth->_pixelFormat != MTLPixelFormatDepth32Float) return nil;
        pass.depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass.depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass.depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    [self retainResource:texture];
    if (descriptor.depthAttachment.texture != nil) [self retainResource:descriptor.depthAttachment.texture];
    return (id<MTLParallelRenderCommandEncoder>)[[ZPUParallelRenderEncoder alloc] initWithOwner:self texture:texture pass:pass];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoder {
    zpu_metal_blit_encoder *encoder = zpu_metal_command_buffer_blit_encoder(_zpuCommandBuffer);
    return encoder == NULL ? nil : (id<MTLBlitCommandEncoder>)[[ZPUBlitEncoder alloc] initWithOwner:self encoder:encoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoder {
    zpu_metal_compute_encoder *encoder = zpu_metal_command_buffer_compute_encoder(_zpuCommandBuffer);
    return encoder == NULL ? nil : (id<MTLComputeCommandEncoder>)[[ZPUComputeEncoder alloc] initWithOwner:self encoder:encoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDescriptor:(MTLComputePassDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)descriptor;
    return [self computeCommandEncoder];
}
- (id<MTLBlitCommandEncoder>)blitCommandEncoderWithDescriptor:(MTLBlitPassDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0)) {
    (void)descriptor;
    return [self blitCommandEncoder];
}
- (id<MTLComputeCommandEncoder>)computeCommandEncoderWithDispatchType:(MTLDispatchType)dispatchType API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (dispatchType != MTLDispatchTypeSerial && dispatchType != MTLDispatchTypeConcurrent) return nil;
    ZPUComputeEncoder *encoder = (ZPUComputeEncoder *)[self computeCommandEncoder];
    if (encoder == nil) return nil;
    encoder->_dispatchType = dispatchType;
    return (id<MTLComputeCommandEncoder>)encoder;
}
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoder API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0), tvos(16.0)) {
    zpu_metal_resource_state_encoder *encoder =
        zpu_metal_command_buffer_resource_state_encoder(_zpuCommandBuffer);
    return encoder == NULL ? nil : (id<MTLResourceStateCommandEncoder>)[[ZPUResourceStateEncoder alloc]
        initWithOwner:self encoder:encoder];
}
- (id<MTLResourceStateCommandEncoder>)resourceStateCommandEncoderWithDescriptor:(MTLResourceStatePassDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    if (descriptor == nil) return nil;
    return [self resourceStateCommandEncoder];
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoder API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    return nil;
}
- (id<MTLAccelerationStructureCommandEncoder>)accelerationStructureCommandEncoderWithDescriptor:(MTLAccelerationStructurePassDescriptor *)descriptor API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)descriptor;
    return nil;
}
- (void)encodeSignalEvent:(id<MTLEvent>)event value:(uint64_t)value API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] ||
        zpu_metal_command_buffer_encode_signal_event(_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        [self markError];
        return;
    }
    [self retainResource:zpuEvent];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] ||
        zpu_metal_command_buffer_encode_wait_for_event(_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        [self markError];
        return;
    }
    [self retainResource:zpuEvent];
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)useResidencySet:(id<MTLResidencySet>)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)residencySet;
}
- (void)useResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)residencySets;
    (void)count;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
@implementation ZPUMTL4CommandAllocator
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CommandAllocatorDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (uint64_t)allocatedSize { return 0; }
- (void)reset {}
@end

@implementation ZPUMTL4CommitFeedback
- (instancetype)initWithError:(NSError *)error startTime:(CFTimeInterval)startTime endTime:(CFTimeInterval)endTime {
    if ((self = [super init])) {
        _error = error;
        _GPUStartTime = startTime;
        _GPUEndTime = endTime;
    }
    return self;
}
- (NSError *)error { return _error; }
- (CFTimeInterval)GPUStartTime { return _GPUStartTime; }
- (CFTimeInterval)GPUEndTime { return _GPUEndTime; }
@end

@implementation ZPUMTL4CommitOptions
- (instancetype)init {
    if ((self = [super init])) _feedbackHandlers = [NSMutableArray array];
    return self;
}
- (void)addFeedbackHandler:(MTL4CommitFeedbackHandler)block {
    if (block != nil) [_feedbackHandlers addObject:[block copy]];
}
- (NSArray *)feedbackHandlers { return [_feedbackHandlers copy]; }
@end

@implementation ZPUMTL4ArgumentTable
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4ArgumentTableDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _maxBufferBindCount = descriptor.maxBufferBindCount;
        _maxTextureBindCount = descriptor.maxTextureBindCount;
        _maxSamplerStateBindCount = descriptor.maxSamplerStateBindCount;
        _supportAttributeStrides = descriptor.supportAttributeStrides;
        _bufferAddresses = [NSMutableData dataWithLength:_maxBufferBindCount * sizeof(uint64_t)];
        _bufferStrides = [NSMutableData dataWithLength:_maxBufferBindCount * sizeof(uint64_t)];
        _bufferResources = [NSMutableData dataWithLength:_maxBufferBindCount * sizeof(uint64_t)];
        _textureResources = [NSMutableData dataWithLength:_maxTextureBindCount * sizeof(uint64_t)];
        _samplerResources = [NSMutableData dataWithLength:_maxSamplerStateBindCount * sizeof(uint64_t)];
    }
    return self;
}
- (void)setAddress:(MTLGPUAddress)gpuAddress atIndex:(NSUInteger)bindingIndex {
    if (bindingIndex >= _maxBufferBindCount) { _invalid = YES; return; }
    ((uint64_t *)_bufferAddresses.mutableBytes)[bindingIndex] = gpuAddress;
    ((uint64_t *)_bufferResources.mutableBytes)[bindingIndex] = gpuAddress;
}
- (void)setAddress:(MTLGPUAddress)gpuAddress attributeStride:(NSUInteger)stride atIndex:(NSUInteger)bindingIndex {
    if (!_supportAttributeStrides || bindingIndex >= _maxBufferBindCount) { _invalid = YES; return; }
    [self setAddress:gpuAddress atIndex:bindingIndex];
    ((uint64_t *)_bufferStrides.mutableBytes)[bindingIndex] = stride;
}
- (void)setResource:(MTLResourceID)resourceID atBufferIndex:(NSUInteger)bindingIndex {
    if (bindingIndex >= _maxBufferBindCount) { _invalid = YES; return; }
    ((uint64_t *)_bufferResources.mutableBytes)[bindingIndex] = resourceID._impl;
}
- (void)setTexture:(MTLResourceID)resourceID atIndex:(NSUInteger)bindingIndex {
    if (bindingIndex >= _maxTextureBindCount) { _invalid = YES; return; }
    ((uint64_t *)_textureResources.mutableBytes)[bindingIndex] = resourceID._impl;
}
- (void)setSamplerState:(MTLResourceID)resourceID atIndex:(NSUInteger)bindingIndex {
    if (bindingIndex >= _maxSamplerStateBindCount) { _invalid = YES; return; }
    ((uint64_t *)_samplerResources.mutableBytes)[bindingIndex] = resourceID._impl;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
@end

@implementation ZPUMTL4CommandBuffer
- (instancetype)initWithOwner:(ZPUDevice *)owner {
    if ((self = [super init])) {
        _owner = owner;
        id queue = [owner newCommandQueue];
        if ([queue isKindOfClass:[ZPUCommandQueue class]]) _legacyQueue = (ZPUCommandQueue *)queue;
        else _failed = YES;
    }
    return self;
}
- (void)markError {
    _failed = YES;
    if (_legacyBuffer != nil) [_legacyBuffer markError];
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)beginWithAllocator:(id<MTL4CommandAllocator>)allocator options:(MTL4CommandBufferOptions *)options {
    (void)options;
    ZPUMTL4CommandAllocator *zpuAllocator = (ZPUMTL4CommandAllocator *)allocator;
    if (_failed || _recording || _ended || _submitted ||
        ![zpuAllocator isKindOfClass:[ZPUMTL4CommandAllocator class]] ||
        zpuAllocator->_owner != _owner || _legacyQueue == nil) {
        [self markError];
        return;
    }
    _legacyBuffer = (ZPUCommandBuffer *)[_legacyQueue commandBuffer];
    if (_legacyBuffer == nil) {
        [self markError];
        return;
    }
    _allocator = zpuAllocator;
    _recording = YES;
}
- (void)beginCommandBufferWithAllocator:(id<MTL4CommandAllocator>)allocator {
    [self beginWithAllocator:allocator options:nil];
}
- (void)beginCommandBufferWithAllocator:(id<MTL4CommandAllocator>)allocator options:(MTL4CommandBufferOptions *)options {
    [self beginWithAllocator:allocator options:options];
}
- (void)endCommandBuffer {
    if (!_recording || _ended || _submitted) { [self markError]; return; }
    if (_activeEncoder != nil) [_activeEncoder endEncoding];
    _activeEncoder = nil;
    _recording = NO;
    _ended = YES;
}
- (BOOL)commitCPU {
    if (!_ended || _submitted || _legacyBuffer == nil || _failed) {
        [self markError];
        return NO;
    }
    [_legacyBuffer commit];
    _submitted = YES;
    if ([_legacyBuffer status] == MTLCommandBufferStatusError) {
        _failed = YES;
        return NO;
    }
    return YES;
}
- (id<MTL4RenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)descriptor {
    return [self renderCommandEncoderWithDescriptor:descriptor options:MTL4RenderEncoderOptionNone];
}
- (id<MTL4RenderCommandEncoder>)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)descriptor options:(MTL4RenderEncoderOptions)options {
    if (!_recording || _ended || _submitted || _failed || _activeEncoder != nil ||
        (options & ~(MTL4RenderEncoderOptionSuspending | MTL4RenderEncoderOptionResuming)) != 0) return nil;
    /* The CPU implementation has no tile-memory optimization to stitch, but
     * a suspending/resuming pair has the same observable ordering when it is
     * recorded as ordinary ordered ZPU passes. */
    ZPUTexture *color = nil;
    ZPUTexture *depth = nil;
    zpu_metal_render_pass_descriptor pass;
    if (!zpu_metal4_render_pass_descriptor(descriptor, &color, &depth, &pass)) return nil;
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(
        _legacyBuffer->_zpuCommandBuffer, color->_zpuTexture, &pass);
    if (encoder == NULL) {
        [self markError];
        return nil;
    }
    [_legacyBuffer retainResource:color];
    if (depth != nil) {
        [_legacyBuffer retainResource:depth];
        if (zpu_metal_render_encoder_set_depth_texture(encoder, depth->_zpuTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            [self markError];
            return nil;
        }
    }
    ZPURenderEncoder *legacy = [[ZPURenderEncoder alloc] initWithOwner:_legacyBuffer encoder:encoder];
    ZPUMTL4RenderEncoder *result = [[ZPUMTL4RenderEncoder alloc] initWithOwner:self legacy:legacy
                                                                        tileWidth:descriptor.tileWidth
                                                                       tileHeight:descriptor.tileHeight];
    _activeEncoder = result;
    return (id<MTL4RenderCommandEncoder>)result;
}
- (id<MTL4ComputeCommandEncoder>)computeCommandEncoder {
    if (!_recording || _ended || _submitted || _failed || _activeEncoder != nil || _legacyBuffer == nil) return nil;
    ZPUComputeEncoder *legacy = (ZPUComputeEncoder *)[_legacyBuffer computeCommandEncoder];
    if (legacy == nil) { [self markError]; return nil; }
    ZPUMTL4ComputeEncoder *encoder = [[ZPUMTL4ComputeEncoder alloc] initWithOwner:self legacy:legacy];
    _activeEncoder = encoder;
    return (id<MTL4ComputeCommandEncoder>)encoder;
}
- (id<MTL4MachineLearningCommandEncoder>)machineLearningCommandEncoder { return nil; }
- (void)useResidencySet:(id<MTLResidencySet>)residencySet { (void)residencySet; }
- (void)useResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count {
    (void)residencySets;
    (void)count;
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)writeTimestampIntoHeap:(id<MTL4CounterHeap>)counterHeap atIndex:(NSUInteger)index {
    ZPUMTL4CounterHeap *heap = (ZPUMTL4CounterHeap *)counterHeap;
    if (![heap isKindOfClass:[ZPUMTL4CounterHeap class]] || heap->_owner != _owner || _legacyBuffer == nil ||
        ![heap writeTimestampAtIndex:index]) {
        [self markError];
        return;
    }
    if (_legacyBuffer != nil) [_legacyBuffer retainResource:heap];
}
- (void)resolveCounterHeap:(id<MTL4CounterHeap>)counterHeap withRange:(NSRange)range intoBuffer:(MTL4BufferRange)bufferRange waitFence:(id<MTLFence>)fenceToWait updateFence:(id<MTLFence>)fenceToUpdate {
    ZPUMTL4CounterHeap *heap = (ZPUMTL4CounterHeap *)counterHeap;
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(bufferRange.bufferAddress);
    if (![heap isKindOfClass:[ZPUMTL4CounterHeap class]] || heap->_owner != _owner || _legacyBuffer == nil ||
        ![buffer isKindOfClass:[ZPUBuffer class]] || buffer->_owner != _owner ||
        (fenceToWait != nil && ![(id)fenceToWait isKindOfClass:[ZPUFence class]]) ||
        (fenceToUpdate != nil && ![(id)fenceToUpdate isKindOfClass:[ZPUFence class]])) {
        [self markError];
        return;
    }
    NSData *resolved = [heap resolveCounterRange:range];
    if (resolved == nil || resolved.length > buffer.length ||
        bufferRange.bufferAddress != buffer->_resourceID ||
        (bufferRange.length != UINT64_MAX &&
         (bufferRange.length < resolved.length || bufferRange.length > (uint64_t)buffer.length))) {
        [self markError];
        return;
    }
    if (resolved.length != 0) memcpy((uint8_t *)buffer.contents, resolved.bytes, resolved.length);
    [_legacyBuffer retainResource:heap];
    [_legacyBuffer retainResource:buffer];
    if (fenceToUpdate != nil) [_legacyBuffer retainResource:fenceToUpdate];
}
@end

@implementation ZPUMTL4CommandQueue
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CommandQueueDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        id queue = [owner newCommandQueue];
        if ([queue isKindOfClass:[ZPUCommandQueue class]]) _legacyQueue = (ZPUCommandQueue *)queue;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)commit:(const id<MTL4CommandBuffer> __nonnull [__nonnull])commandBuffers count:(NSUInteger)count {
    if (commandBuffers == NULL && count != 0) return;
    for (NSUInteger index = 0; index < count; ++index) {
        ZPUMTL4CommandBuffer *buffer = (ZPUMTL4CommandBuffer *)commandBuffers[index];
        if (![buffer isKindOfClass:[ZPUMTL4CommandBuffer class]] || buffer->_owner != _owner) {
            if ([buffer respondsToSelector:@selector(markError)]) [buffer markError];
            continue;
        }
        (void)[buffer commitCPU];
    }
}
- (void)commit:(const id<MTL4CommandBuffer> __nonnull [__nonnull])commandBuffers count:(NSUInteger)count options:(MTL4CommitOptions *)options {
    const CFTimeInterval startTime = CFAbsoluteTimeGetCurrent();
    BOOL success = commandBuffers != NULL || count == 0;
    for (NSUInteger index = 0; success && index < count; ++index) {
        ZPUMTL4CommandBuffer *buffer = (ZPUMTL4CommandBuffer *)commandBuffers[index];
        if (![buffer isKindOfClass:[ZPUMTL4CommandBuffer class]] || buffer->_owner != _owner ||
            ![buffer commitCPU]) {
            if ([buffer respondsToSelector:@selector(markError)]) [buffer markError];
            success = NO;
        }
    }
    if ([options isKindOfClass:[ZPUMTL4CommitOptions class]]) {
        NSError *error = success ? nil : [NSError errorWithDomain:@"ZPUMetal"
                                                              code:ZPU_METAL_INVALID_COMMAND
                                                          userInfo:@{NSLocalizedDescriptionKey: @"ZPU Metal 4 CPU command queue commit failed"}];
        ZPUMTL4CommitFeedback *feedback = [[ZPUMTL4CommitFeedback alloc]
            initWithError:error startTime:startTime endTime:CFAbsoluteTimeGetCurrent()];
        for (MTL4CommitFeedbackHandler block in [(ZPUMTL4CommitOptions *)options feedbackHandlers]) {
            block((id<MTL4CommitFeedback>)feedback);
        }
    }
}
- (void)signalEvent:(id<MTLEvent>)event value:(uint64_t)value {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || _legacyQueue == nil) return;
    ZPUCommandBuffer *buffer = (ZPUCommandBuffer *)[_legacyQueue commandBuffer];
    if (buffer == nil || zpu_metal_command_buffer_encode_signal_event(buffer->_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) return;
    [buffer commit];
}
- (void)waitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || _legacyQueue == nil) return;
    ZPUCommandBuffer *buffer = (ZPUCommandBuffer *)[_legacyQueue commandBuffer];
    if (buffer == nil || zpu_metal_command_buffer_encode_wait_for_event(buffer->_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) return;
    [buffer commit];
}
- (void)signalDrawable:(id<MTLDrawable>)drawable { (void)drawable; }
- (void)waitForDrawable:(id<MTLDrawable>)drawable { (void)drawable; }
- (void)addResidencySet:(id<MTLResidencySet>)residencySet { (void)residencySet; }
- (void)addResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count { (void)residencySets; (void)count; }
- (void)removeResidencySet:(id<MTLResidencySet>)residencySet { (void)residencySet; }
- (void)removeResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count { (void)residencySets; (void)count; }
- (void)updateTextureMappings:(id<MTLTexture>)texture heap:(id<MTLHeap>)heap operations:(const MTL4UpdateSparseTextureMappingOperation [_Nonnull])operations count:(NSUInteger)count { (void)texture; (void)heap; (void)operations; (void)count; }
- (void)copyTextureMappingsFromTexture:(id<MTLTexture>)sourceTexture toTexture:(id<MTLTexture>)destinationTexture operations:(const MTL4CopySparseTextureMappingOperation [_Nonnull])operations count:(NSUInteger)count { (void)sourceTexture; (void)destinationTexture; (void)operations; (void)count; }
- (void)updateBufferMappings:(id<MTLBuffer>)buffer heap:(id<MTLHeap>)heap operations:(const MTL4UpdateSparseBufferMappingOperation [_Nonnull])operations count:(NSUInteger)count { (void)buffer; (void)heap; (void)operations; (void)count; }
- (void)copyBufferMappingsFromBuffer:(id<MTLBuffer>)sourceBuffer toBuffer:(id<MTLBuffer>)destinationBuffer operations:(const MTL4CopySparseBufferMappingOperation [_Nonnull])operations count:(NSUInteger)count { (void)sourceBuffer; (void)destinationBuffer; (void)operations; (void)count; }
@end

@implementation ZPUMTL4RenderEncoder
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner legacy:(ZPURenderEncoder *)legacy
                      tileWidth:(NSUInteger)tileWidth tileHeight:(NSUInteger)tileHeight {
    if ((self = [super init])) {
        _owner = owner;
        _legacy = legacy;
        _tileWidth = tileWidth;
        _tileHeight = tileHeight;
    }
    return self;
}
- (id<MTL4CommandBuffer>)commandBuffer { return (id<MTL4CommandBuffer>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (NSUInteger)tileWidth { return _tileWidth; }
- (NSUInteger)tileHeight { return _tileHeight; }
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions {
    (void)afterQueueStages;
    (void)beforeStages;
    (void)visibilityOptions;
}
- (void)barrierAfterStages:(MTLStages)afterStages beforeQueueStages:(MTLStages)beforeQueueStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions {
    (void)afterStages;
    (void)beforeQueueStages;
    (void)visibilityOptions;
}
- (void)barrierAfterEncoderStages:(MTLStages)afterEncoderStages beforeEncoderStages:(MTLStages)beforeEncoderStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions {
    (void)afterEncoderStages;
    (void)beforeEncoderStages;
    (void)visibilityOptions;
}
- (void)updateFence:(id<MTLFence>)fence afterEncoderStages:(MTLStages)afterEncoderStages {
    (void)afterEncoderStages;
    [(id)_legacy updateFence:fence afterStages:MTLRenderStageVertex | MTLRenderStageFragment];
}
- (void)waitForFence:(id<MTLFence>)fence beforeEncoderStages:(MTLStages)beforeEncoderStages {
    (void)beforeEncoderStages;
    [(id)_legacy waitForFence:fence beforeStages:MTLRenderStageVertex | MTLRenderStageFragment];
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)setColorAttachmentMap:(MTLLogicalToPhysicalColorAttachmentMap *)mapping {
    if (mapping != nil) [_owner markError];
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    [(id)_legacy setRenderPipelineState:pipelineState];
}
- (void)setViewport:(MTLViewport)viewport { [(id)_legacy setViewport:viewport]; }
- (void)setViewports:(const MTLViewport [__nonnull])viewports count:(NSUInteger)count {
    if (viewports == NULL || count == 0) { [_owner markError]; return; }
    [(id)_legacy setViewports:viewports count:count];
}
- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping *)viewMappings {
    [(id)_legacy setVertexAmplificationCount:count viewMappings:viewMappings];
}
- (void)setCullMode:(MTLCullMode)cullMode { [(id)_legacy setCullMode:cullMode]; }
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode { [(id)_legacy setDepthClipMode:depthClipMode]; }
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp {
    [(id)_legacy setDepthBias:depthBias slopeScale:slopeScale clamp:clamp];
}
- (void)setDepthTestMinBound:(float)minBound maxBound:(float)maxBound {
    if (minBound != 0.0f || maxBound != 1.0f) [_owner markError];
}
- (void)setScissorRect:(MTLScissorRect)rect { [(id)_legacy setScissorRect:rect]; }
- (void)setScissorRects:(const MTLScissorRect [__nonnull])rects count:(NSUInteger)count {
    if (rects == NULL || count == 0) { [_owner markError]; return; }
    [(id)_legacy setScissorRects:rects count:count];
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode { [(id)_legacy setTriangleFillMode:fillMode]; }
- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha {
    [(id)_legacy setBlendColorRed:red green:green blue:blue alpha:alpha];
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState {
    [(id)_legacy setDepthStencilState:depthStencilState];
}
- (void)setStencilReferenceValue:(uint32_t)referenceValue { [(id)_legacy setStencilReferenceValue:referenceValue]; }
- (void)setStencilFrontReferenceValue:(uint32_t)frontReferenceValue backReferenceValue:(uint32_t)backReferenceValue {
    [(id)_legacy setStencilFrontReferenceValue:frontReferenceValue backReferenceValue:backReferenceValue];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
    [(id)_legacy setVisibilityResultMode:mode offset:offset];
}
- (void)setColorStoreAction:(MTLStoreAction)storeAction atIndex:(NSUInteger)colorAttachmentIndex {
    if (colorAttachmentIndex != 0 || storeAction == MTLStoreActionUnknown) [_owner markError];
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction {
    if (storeAction == MTLStoreActionUnknown) [_owner markError];
}
- (void)setStencilStoreAction:(MTLStoreAction)storeAction {
    if (storeAction == MTLStoreActionUnknown) [_owner markError];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount {
    [(id)_legacy drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount {
    [(id)_legacy drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance {
    [(id)_legacy drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount baseInstance:baseInstance];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength instanceCount:(NSUInteger)instanceCount {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0 instanceCount:instanceCount];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0 instanceCount:instanceCount
                           baseVertex:baseVertex baseInstance:baseInstance];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType indirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indirectBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    [(id)_legacy drawPrimitives:primitiveType indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength indirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *indices = zpu_metal4_buffer_for_address(indexBuffer);
    ZPUBuffer *indirect = zpu_metal4_buffer_for_address(indirectBuffer);
    if (indices == nil || indirect == nil || indexBufferLength > indices.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexType:indexType
                           indexBuffer:(id<MTLBuffer>)indices indexBufferOffset:0
                           indirectBuffer:(id<MTLBuffer>)indirect indirectBufferOffset:0];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange {
    [(id)_legacy executeCommandsInBuffer:indirectCommandBuffer withRange:executionRange];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer indirectBuffer:(MTLGPUAddress)indirectRangeBuffer {
    ZPUBuffer *range = zpu_metal4_buffer_for_address(indirectRangeBuffer);
    if (range == nil) { [_owner markError]; return; }
    [(id)_legacy executeCommandsInBuffer:indirectCommandBuffer indirectBuffer:(id<MTLBuffer>)range indirectBufferOffset:0];
}
- (void)setObjectThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    (void)length;
    (void)index;
    [_owner markError];
}
- (void)drawMeshThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup {
    (void)threadgroupsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)drawMeshThreads:(MTLSize)threadsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup {
    (void)threadsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)drawMeshThreadgroupsWithIndirectBuffer:(MTLGPUAddress)indirectBuffer threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup {
    (void)indirectBuffer;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)dispatchThreadsPerTile:(MTLSize)threadsPerTile {
    (void)threadsPerTile;
    [_owner markError];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    (void)length;
    (void)offset;
    (void)index;
    [_owner markError];
}
- (void)setArgumentTable:(id<MTL4ArgumentTable>)argumentTable atStages:(MTLRenderStages)stages {
    if (argumentTable != nil && ![(id)argumentTable isKindOfClass:[ZPUMTL4ArgumentTable class]]) {
        [_owner markError];
        return;
    }
    _argumentTable = (ZPUMTL4ArgumentTable *)argumentTable;
    if (_argumentTable == nil) return;
    if (_argumentTable->_invalid || (stages & ~(MTLRenderStageVertex | MTLRenderStageFragment)) != 0) {
        [_owner markError];
        return;
    }
    const uint64_t *bufferIDs = (const uint64_t *)_argumentTable->_bufferResources.bytes;
    const uint64_t *bufferStrides = (const uint64_t *)_argumentTable->_bufferStrides.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxBufferBindCount; ++index) {
        ZPUBuffer *buffer = zpu_metal4_buffer_for_address((MTLGPUAddress)bufferIDs[index]);
        if (buffer == nil) continue;
        if ((stages & MTLRenderStageVertex) != 0) {
            [(id)_legacy setVertexBuffer:(id<MTLBuffer>)buffer offset:0 attributeStride:(NSUInteger)bufferStrides[index] atIndex:index];
        }
        if ((stages & MTLRenderStageFragment) != 0) {
            [(id)_legacy setFragmentBuffer:(id<MTLBuffer>)buffer offset:0 atIndex:index];
        }
    }
    const uint64_t *textureIDs = (const uint64_t *)_argumentTable->_textureResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxTextureBindCount; ++index) {
        id resource = zpu_resource_for_id(textureIDs[index]);
        if (![resource isKindOfClass:[ZPUTexture class]]) {
            if (textureIDs[index] != 0) [_owner markError];
            continue;
        }
        if ((stages & MTLRenderStageVertex) != 0) [(id)_legacy setVertexTexture:resource atIndex:index];
        if ((stages & MTLRenderStageFragment) != 0) [(id)_legacy setFragmentTexture:resource atIndex:index];
    }
}
- (void)setFrontFacingWinding:(MTLWinding)frontFacingWinding { [(id)_legacy setFrontFacingWinding:frontFacingWinding]; }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)granularity afterStage:(MTLRenderStages)stage intoHeap:(id<MTL4CounterHeap>)counterHeap atIndex:(NSUInteger)index {
    (void)granularity;
    (void)stage;
    ZPUMTL4CounterHeap *heap = (ZPUMTL4CounterHeap *)counterHeap;
    if (![heap isKindOfClass:[ZPUMTL4CounterHeap class]] || heap->_owner != _owner->_owner ||
        ![heap writeTimestampAtIndex:index]) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:heap];
}
- (void)endEncoding {
    if (_ended) return;
    _ended = YES;
    [(id)_legacy endEncoding];
    if (_owner->_activeEncoder == self) _owner->_activeEncoder = nil;
}
@end

@implementation ZPUMTL4ComputeEncoder
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner legacy:(ZPUComputeEncoder *)legacy {
    if ((self = [super init])) {
        _owner = owner;
        _legacy = legacy;
        _stages = 0;
    }
    return self;
}
- (id<MTL4CommandBuffer>)commandBuffer { return (id<MTL4CommandBuffer>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (MTLStages)stages { return _stages; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    [_legacy setComputePipelineState:state];
    _stages |= MTLStageDispatch;
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index { [_legacy setThreadgroupMemoryLength:length atIndex:index]; }
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height { [_legacy setImageblockWidth:width height:height]; }
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    [_legacy dispatchThreads:threadsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
    _stages |= MTLStageDispatch;
}
- (void)dispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    [_legacy dispatchThreadgroups:threadgroupsPerGrid threadsPerThreadgroup:threadsPerThreadgroup];
    _stages |= MTLStageDispatch;
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(MTLGPUAddress)indirectBuffer threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indirectBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    [(id)_legacy dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:0
                                  threadsPerThreadgroup:threadsPerThreadgroup];
    [_owner->_legacyBuffer retainResource:buffer];
    _stages |= MTLStageDispatch;
}
- (void)dispatchThreadsWithIndirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indirectBuffer);
    if (buffer == nil || zpu_metal_compute_encoder_dispatch_threads_indirect(
            _legacy->_zpuEncoder, buffer->_zpuBuffer) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:buffer];
    _stages |= MTLStageDispatch;
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange {
    [(id)_legacy executeCommandsInBuffer:indirectCommandBuffer withRange:executionRange];
    _stages |= MTLStageDispatch;
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer indirectBuffer:(MTLGPUAddress)indirectRangeBuffer {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(indirectRangeBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    [(id)_legacy executeCommandsInBuffer:indirectCommandBuffer indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:0];
    _stages |= MTLStageDispatch;
}
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions { (void)afterQueueStages; (void)beforeStages; (void)visibilityOptions; }
- (void)barrierAfterStages:(MTLStages)afterStages beforeQueueStages:(MTLStages)beforeQueueStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions { (void)afterStages; (void)beforeQueueStages; (void)visibilityOptions; }
- (void)barrierAfterEncoderStages:(MTLStages)afterEncoderStages beforeEncoderStages:(MTLStages)beforeEncoderStages visibilityOptions:(MTL4VisibilityOptions)visibilityOptions { (void)afterEncoderStages; (void)beforeEncoderStages; (void)visibilityOptions; }
- (void)updateFence:(id<MTLFence>)fence afterEncoderStages:(MTLStages)afterEncoderStages { (void)afterEncoderStages; [_legacy updateFence:fence]; }
- (void)waitForFence:(id<MTLFence>)fence beforeEncoderStages:(MTLStages)beforeEncoderStages { (void)beforeEncoderStages; [_legacy waitForFence:fence]; }
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding {
    if (_ended) return;
    _ended = YES;
    [_legacy endEncoding];
    if (_owner->_activeEncoder == self) _owner->_activeEncoder = nil;
}
- (void)setArgumentTable:(id<MTL4ArgumentTable>)argumentTable {
    if (argumentTable != nil && ![(id)argumentTable isKindOfClass:[ZPUMTL4ArgumentTable class]]) {
        [_owner markError];
        return;
    }
    _argumentTable = (ZPUMTL4ArgumentTable *)argumentTable;
    if (_argumentTable == nil) return;
    if (_argumentTable->_invalid) { [_owner markError]; return; }
    const uint64_t *bufferIDs = (const uint64_t *)_argumentTable->_bufferResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxBufferBindCount; ++index) {
        id resource = zpu_resource_for_id(bufferIDs[index]);
        if (resource == nil) continue;
        if (![resource isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
        const uint64_t *strides = (const uint64_t *)_argumentTable->_bufferStrides.bytes;
        [_legacy setBuffer:(id<MTLBuffer>)resource offset:0 atIndex:index];
        if (strides[index] != 0) {
            [_legacy setBuffer:(id<MTLBuffer>)resource offset:0 attributeStride:(NSUInteger)strides[index] atIndex:index];
        }
    }
    const uint64_t *textureIDs = (const uint64_t *)_argumentTable->_textureResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxTextureBindCount; ++index) {
        id resource = zpu_resource_for_id(textureIDs[index]);
        if (resource == nil) continue;
        if (![resource isKindOfClass:[ZPUTexture class]]) { [_owner markError]; return; }
        [_legacy setTexture:(id<MTLTexture>)resource atIndex:index];
    }
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture toTexture:(id<MTLTexture>)destinationTexture {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]]) { [_owner markError]; return; }
    [self copyFromTexture:source sourceSlice:0 sourceLevel:0 toTexture:destination destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:1];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]] ||
        sourceSlice != 0 || sourceLevel != 0 || destinationSlice != 0 || destinationLevel != 0 ||
        sliceCount != 1 || levelCount != 1) { [_owner markError]; return; }
    [self copyFromTexture:source sourceSlice:0 sourceLevel:0
             sourceOrigin:(MTLOrigin){0, 0, 0}
               sourceSize:MTLSizeMake(source.width, source.height, 1)
                toTexture:destination destinationSlice:0 destinationLevel:0 destinationOrigin:(MTLOrigin){0, 0, 0}];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    zpu_metal_region sourceRegion;
    zpu_metal_region destinationRegion;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]] ||
        sourceSlice != 0 || sourceLevel != 0 || destinationSlice != 0 || destinationLevel != 0 ||
        !zpu_metal4_region(sourceOrigin, sourceSize, &sourceRegion) ||
        !zpu_metal4_region(destinationOrigin, sourceSize, &destinationRegion) ||
        zpu_metal_compute_encoder_copy_texture_to_texture(_legacy->_zpuEncoder, source->_zpuTexture, sourceRegion,
            destination->_zpuTexture, destinationRegion) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage {
    (void)destinationBytesPerImage;
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    zpu_metal_region sourceRegion;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUBuffer class]] ||
        sourceSlice != 0 || sourceLevel != 0 || !zpu_metal4_region(sourceOrigin, sourceSize, &sourceRegion) ||
        zpu_metal_compute_encoder_copy_texture_to_buffer(_legacy->_zpuEncoder, source->_zpuTexture, sourceRegion,
            destination->_zpuBuffer, destinationOffset, destinationBytesPerRow) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage options:(MTLBlitOption)options {
    if (options != MTLBlitOptionNone) { [_owner markError]; return; }
    [self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:sourceSize toBuffer:destinationBuffer destinationOffset:destinationOffset destinationBytesPerRow:destinationBytesPerRow destinationBytesPerImage:destinationBytesPerImage];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size {
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    if (![source isKindOfClass:[ZPUBuffer class]] || ![destination isKindOfClass:[ZPUBuffer class]] ||
        zpu_metal_compute_encoder_copy_buffer(_legacy->_zpuEncoder, source->_zpuBuffer, sourceOffset,
            destination->_zpuBuffer, destinationOffset, size) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    (void)sourceBytesPerImage;
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    zpu_metal_region destinationRegion;
    if (![source isKindOfClass:[ZPUBuffer class]] || ![destination isKindOfClass:[ZPUTexture class]] ||
        destinationSlice != 0 || destinationLevel != 0 || !zpu_metal4_region(destinationOrigin, sourceSize, &destinationRegion) ||
        zpu_metal_compute_encoder_copy_buffer_to_texture(_legacy->_zpuEncoder, source->_zpuBuffer, sourceOffset,
            sourceBytesPerRow, destination->_zpuTexture, destinationRegion) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options {
    if (options != MTLBlitOptionNone) { [_owner markError]; return; }
    [self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel destinationOrigin:destinationOrigin];
}
- (void)copyFromTensor:(id<MTLTensor>)sourceTensor sourceOrigin:(MTLTensorExtents *)sourceOrigin sourceDimensions:(MTLTensorExtents *)sourceDimensions toTensor:(id<MTLTensor>)destinationTensor destinationOrigin:(MTLTensorExtents *)destinationOrigin destinationDimensions:(MTLTensorExtents *)destinationDimensions { (void)sourceTensor; (void)sourceOrigin; (void)sourceDimensions; (void)destinationTensor; (void)destinationOrigin; (void)destinationDimensions; [_owner markError]; }
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture { (void)texture; [_owner markError]; }
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
        zpu_metal_compute_encoder_fill_buffer(_legacy->_zpuEncoder, zpuBuffer->_zpuBuffer, range.location, range.length, value) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:zpuBuffer];
    _stages |= MTLStageBlit;
}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture { (void)texture; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level { (void)texture; (void)slice; (void)level; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture { (void)texture; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level { (void)texture; (void)slice; (void)level; }
- (void)resetCommandsInBuffer:(id<MTLIndirectCommandBuffer>)buffer withRange:(NSRange)range { (void)buffer; (void)range; [_owner markError]; }
- (void)copyIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)source sourceRange:(NSRange)sourceRange destination:(id<MTLIndirectCommandBuffer>)destination destinationIndex:(NSUInteger)destinationIndex { (void)source; (void)sourceRange; (void)destination; (void)destinationIndex; [_owner markError]; }
- (void)optimizeIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)range { (void)indirectCommandBuffer; (void)range; }
- (void)buildAccelerationStructure:(id<MTLAccelerationStructure>)accelerationStructure descriptor:(MTL4AccelerationStructureDescriptor *)descriptor scratchBuffer:(MTL4BufferRange)scratchBuffer { (void)accelerationStructure; (void)descriptor; (void)scratchBuffer; [_owner markError]; }
- (void)refitAccelerationStructure:(id<MTLAccelerationStructure>)sourceAccelerationStructure descriptor:(MTL4AccelerationStructureDescriptor *)descriptor destination:(id<MTLAccelerationStructure>)destinationAccelerationStructure scratchBuffer:(MTL4BufferRange)scratchBuffer { (void)sourceAccelerationStructure; (void)descriptor; (void)destinationAccelerationStructure; (void)scratchBuffer; [_owner markError]; }
- (void)refitAccelerationStructure:(id<MTLAccelerationStructure>)sourceAccelerationStructure descriptor:(MTL4AccelerationStructureDescriptor *)descriptor destination:(id<MTLAccelerationStructure>)destinationAccelerationStructure scratchBuffer:(MTL4BufferRange)scratchBuffer options:(MTLAccelerationStructureRefitOptions)options { (void)sourceAccelerationStructure; (void)descriptor; (void)destinationAccelerationStructure; (void)scratchBuffer; (void)options; [_owner markError]; }
- (void)copyAccelerationStructure:(id<MTLAccelerationStructure>)sourceAccelerationStructure toAccelerationStructure:(id<MTLAccelerationStructure>)destinationAccelerationStructure { (void)sourceAccelerationStructure; (void)destinationAccelerationStructure; [_owner markError]; }
- (void)writeCompactedAccelerationStructureSize:(id<MTLAccelerationStructure>)accelerationStructure toBuffer:(MTL4BufferRange)buffer { (void)accelerationStructure; (void)buffer; [_owner markError]; }
- (void)copyAndCompactAccelerationStructure:(id<MTLAccelerationStructure>)sourceAccelerationStructure toAccelerationStructure:(id<MTLAccelerationStructure>)destinationAccelerationStructure { (void)sourceAccelerationStructure; (void)destinationAccelerationStructure; [_owner markError]; }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)granularity intoHeap:(id<MTL4CounterHeap>)counterHeap atIndex:(NSUInteger)index {
    (void)granularity;
    ZPUMTL4CounterHeap *heap = (ZPUMTL4CounterHeap *)counterHeap;
    if (![heap isKindOfClass:[ZPUMTL4CounterHeap class]] || heap->_owner != _owner->_owner ||
        ![heap writeTimestampAtIndex:index]) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:heap];
}
@end

#pragma clang diagnostic pop

@implementation ZPUComputePipelineState
- (instancetype)initWithOwner:(ZPUDevice *)owner function:(id<MTLFunction>)function error:(NSError **)error {
    if ((self = [super init])) {
        _owner = owner;
        _kernel = 0;
        NSString *name = [function respondsToSelector:@selector(name)] ? [function name] : nil;
        BOOL is_kernel = ![function respondsToSelector:@selector(functionType)] ||
            [function functionType] == MTLFunctionTypeKernel;
        if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_rgba8"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_copy_rgba8_buffer_to_texture"]) {
            _kernel = ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE;
        } else {
            zpu_set_error(error, @"ZPU CPU Metal has no registered CPU implementation for this compute function");
            return nil;
        }
    }
    if (error != NULL) *error = nil;
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSUInteger)allocatedSize API_AVAILABLE(macos(15.0), ios(18.0)) { return 0; }
- (NSString *)label { return @"ZPU CPU compute pipeline"; }
- (void)setLabel:(NSString *)label { (void)label; }
- (NSUInteger)maxTotalThreadsPerThreadgroup { return 1024; }
- (NSUInteger)threadExecutionWidth { return 1; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (BOOL)supportIndirectCommandBuffers API_AVAILABLE(macos(10.14), ios(12.0)) { return YES; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){0}; }
- (MTLShaderValidation)shaderValidation API_AVAILABLE(macos(15.0), ios(18.0)) { return (MTLShaderValidation)0; }
- (MTLSize)requiredThreadsPerThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (MTLComputePipelineReflection *)reflection API_AVAILABLE(macos(26.0), ios(26.0)) { return nil; }
- (id<MTLFunctionHandle>)functionHandleWithName:(NSString *)name API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)name;
    return nil;
}
- (id<MTLFunctionHandle>)functionHandleWithBinaryFunction:(id<MTL4BinaryFunction>)function API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)function;
    return nil;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithBinaryFunctions:(NSArray<id<MTL4BinaryFunction>> *)additionalBinaryFunctions error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)additionalBinaryFunctions;
    zpu_set_error(error, @"ZPU CPU Metal does not link Metal 4 binary functions");
    return nil;
}
- (NSUInteger)imageblockMemoryLengthForDimensions:(MTLSize)imageblockDimensions API_AVAILABLE(macos(11.0), ios(11.0)) {
    (void)imageblockDimensions;
    return 0;
}
- (id<MTLFunctionHandle>)functionHandleWithFunction:(id<MTLFunction>)function API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)function;
    return nil;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithAdditionalBinaryFunctions:(NSArray<id<MTLFunction>> *)functions error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)functions;
    zpu_set_error(error, @"ZPU CPU Metal does not link binary functions");
    return nil;
}
- (id<MTLVisibleFunctionTable>)newVisibleFunctionTableWithDescriptor:(MTLVisibleFunctionTableDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    return nil;
}
- (id<MTLIntersectionFunctionTable>)newIntersectionFunctionTableWithDescriptor:(MTLIntersectionFunctionTableDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)descriptor;
    return nil;
}
@end

@implementation ZPUComputeEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_compute_encoder *)encoder {
    if ((self = [super init])) { _owner = owner; _zpuEncoder = encoder; _dispatchType = MTLDispatchTypeSerial; }
    return self;
}
- (void)dealloc {
    if (_zpuEncoder != NULL) {
        (void)zpu_metal_compute_encoder_end_encoding(_zpuEncoder);
        zpu_metal_compute_encoder_destroy(_zpuEncoder);
    }
}
- (id<MTLDevice>)device { return [_owner device]; }
- (MTLDispatchType)dispatchType API_AVAILABLE(macos(10.14), ios(12.0)) { return _dispatchType; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    ZPUComputePipelineState *pipeline = (ZPUComputePipelineState *)state;
    if (![pipeline isKindOfClass:[ZPUComputePipelineState class]] ||
        zpu_metal_compute_encoder_set_kernel(_zpuEncoder, pipeline->_kernel) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:pipeline];
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(10.11), ios(8.3)) {
    if (index > UINT32_MAX || (length != 0 && bytes == NULL) ||
        zpu_metal_compute_encoder_set_bytes(_zpuEncoder, bytes, length, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
    }
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (index > UINT32_MAX || (buffer != nil && ![zpuBuffer isKindOfClass:[ZPUBuffer class]])) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_set_buffer(_zpuEncoder,
            buffer == nil ? NULL : zpuBuffer->_zpuBuffer, offset, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)setBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (buffers == NULL || offsets == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setBuffer:buffers[index] offset:offsets[index] atIndex:range.location + index];
    }
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setBuffer:buffer offset:offset atIndex:index];
}
- (void)setBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets attributeStrides:(const NSUInteger [__nonnull])strides withRange:(NSRange)range API_AVAILABLE(macos(14.0), ios(17.0)) {
    if (buffers == NULL || offsets == NULL || strides == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setBuffer:buffers[index] offset:offsets[index] attributeStride:strides[index] atIndex:range.location + index];
    }
}
- (void)setBufferOffset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setBufferOffset:offset atIndex:index];
}
- (void)setBytes:(const void *)bytes length:(NSUInteger)length attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setBytes:bytes length:length atIndex:index];
}
- (void)setBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(10.11), ios(8.3)) {
    if (index > UINT32_MAX ||
        zpu_metal_compute_encoder_set_buffer_offset(_zpuEncoder, offset, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
    }
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (index > UINT32_MAX || (texture != nil && ![zpuTexture isKindOfClass:[ZPUTexture class]])) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_set_texture(_zpuEncoder,
            texture == nil ? NULL : zpuTexture->_zpuTexture, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuTexture];
}
- (void)setTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setTexture:textures[index] atIndex:range.location + index];
    }
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (sampler != nil && ![(id)sampler isKindOfClass:[ZPUSamplerState class]]) {
        [_owner markError];
        return;
    }
    (void)index;
    if (sampler != nil) [_owner retainResource:sampler];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range {
    if (samplers == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setSamplerState:samplers[index] atIndex:range.location + index];
    }
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index {
    (void)lodMinClamp;
    (void)lodMaxClamp;
    [self setSamplerState:sampler atIndex:index];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers lodMinClamps:(const float [__nonnull])lodMinClamps lodMaxClamps:(const float [__nonnull])lodMaxClamps withRange:(NSRange)range {
    if (samplers == NULL || lodMinClamps == NULL || lodMaxClamps == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setSamplerState:samplers[index]
                 lodMinClamp:lodMinClamps[index]
                 lodMaxClamp:lodMaxClamps[index]
                      atIndex:range.location + index];
    }
}
- (void)setVisibleFunctionTable:(id<MTLVisibleFunctionTable>)visibleFunctionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)visibleFunctionTable;
    (void)bufferIndex;
}
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])visibleFunctionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)visibleFunctionTables;
    (void)range;
}
- (void)setIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)intersectionFunctionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)intersectionFunctionTable;
    (void)bufferIndex;
}
- (void)setIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])intersectionFunctionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)intersectionFunctionTables;
    (void)range;
}
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)accelerationStructure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)accelerationStructure;
    (void)bufferIndex;
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    (void)length;
    (void)index;
}
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height API_AVAILABLE(ios(11.0), macos(11.0), macCatalyst(14.0), tvos(14.5)) {
    (void)width;
    (void)height;
}
- (void)setStageInRegion:(MTLRegion)region API_AVAILABLE(macos(10.12), ios(10.0)) {
    if (!zpu_region_fits(region)) [_owner markError];
}
- (void)setStageInRegionWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)indirectBuffer;
    if (![zpuBuffer isKindOfClass:[ZPUBuffer class]] || indirectBufferOffset > zpuBuffer.length) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage API_AVAILABLE(macos(10.13), ios(11.0)) {
    (void)usage;
    if ([resource isKindOfClass:[ZPUBuffer class]] || [resource isKindOfClass:[ZPUTexture class]]) {
        [_owner retainResource:resource];
    } else if (resource != nil) {
        [_owner markError];
    }
}
- (void)useResources:(const id<MTLResource> __nonnull [__nonnull])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage API_AVAILABLE(macos(10.13), ios(11.0)) {
    if (resources == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < count; ++index) [self useResource:resources[index] usage:usage];
}
- (void)useHeap:(id<MTLHeap>)heap API_AVAILABLE(macos(10.13), ios(11.0)) {
    if ([heap isKindOfClass:[ZPUHeap class]]) [_owner retainResource:heap];
    else if (heap != nil) [_owner markError];
}
- (void)useHeaps:(const id<MTLHeap> __nonnull [__nonnull])heaps count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(11.0)) {
    if (heaps == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < count; ++index) [self useHeap:heaps[index]];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope API_AVAILABLE(macos(10.14), ios(12.0)) {
    (void)scope;
}
- (void)memoryBarrierWithResources:(const id<MTLResource> __nonnull [__nonnull])resources count:(NSUInteger)count API_AVAILABLE(macos(10.14), ios(12.0)) {
    [self useResources:resources count:count usage:MTLResourceUsageRead | MTLResourceUsageWrite];
}
- (void)sampleCountersInBuffer:(id<MTLCounterSampleBuffer>)sampleBuffer atSampleIndex:(NSUInteger)sampleIndex withBarrier:(BOOL)barrier API_AVAILABLE(macos(10.15), ios(14.0)) {
    (void)barrier;
    ZPUCounterSampleBuffer *sample = (ZPUCounterSampleBuffer *)sampleBuffer;
    if (![sample isKindOfClass:[ZPUCounterSampleBuffer class]] || sample->_owner != [_owner device] ||
        ![sample sampleAtIndex:sampleIndex]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:sample];
}
- (void)dispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup API_AVAILABLE(macos(10.13), ios(11.0), tvos(14.5)) {
    if (!zpu_u32(threadsPerGrid.width, &(uint32_t){0}) || !zpu_u32(threadsPerGrid.height, &(uint32_t){0}) ||
        !zpu_u32(threadsPerGrid.depth, &(uint32_t){0}) || !zpu_u32(threadsPerThreadgroup.width, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.height, &(uint32_t){0}) || !zpu_u32(threadsPerThreadgroup.depth, &(uint32_t){0})) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_dispatch_threads(_zpuEncoder,
            (zpu_metal_size){(uint32_t)threadsPerGrid.width, (uint32_t)threadsPerGrid.height, (uint32_t)threadsPerGrid.depth},
            (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width, (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
        [_owner markError];
    }
}
- (void)dispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    if (!zpu_u32(threadgroupsPerGrid.width, &(uint32_t){0}) || !zpu_u32(threadgroupsPerGrid.height, &(uint32_t){0}) ||
        !zpu_u32(threadgroupsPerGrid.depth, &(uint32_t){0}) || !zpu_u32(threadsPerThreadgroup.width, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.height, &(uint32_t){0}) || !zpu_u32(threadsPerThreadgroup.depth, &(uint32_t){0})) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_dispatch_threadgroups(_zpuEncoder,
            (zpu_metal_size){(uint32_t)threadgroupsPerGrid.width, (uint32_t)threadgroupsPerGrid.height, (uint32_t)threadgroupsPerGrid.depth},
            (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width, (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
        [_owner markError];
    }
}
- (void)dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup API_AVAILABLE(macos(10.11), ios(9.0)) {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)indirectBuffer;
    if (indirectBuffer == nil || ![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
        !zpu_u32(indirectBufferOffset, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.width, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.height, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.depth, &(uint32_t){0})) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_dispatch_threadgroups_indirect(_zpuEncoder, zpuBuffer->_zpuBuffer,
            indirectBufferOffset, (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width,
            (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)updateFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0)) {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] ||
        zpu_metal_compute_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)waitForFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0)) {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] ||
        zpu_metal_compute_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    ZPUIndirectCommandBuffer *buffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![buffer isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        executionRange.location > buffer->_maxCommandCount ||
        executionRange.length > buffer->_maxCommandCount - executionRange.location) {
        [_owner markError];
        return;
    }
    [_owner retainResource:buffer];
    for (NSUInteger index = executionRange.location; index < executionRange.location + executionRange.length; ++index) {
        id command = buffer->_commands[index];
        if ([command isKindOfClass:[ZPUIndirectComputeCommand class]]) {
            [(ZPUIndirectComputeCommand *)command executeWithEncoder:self];
        }
    }
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer indirectBuffer:(id<MTLBuffer>)indirectRangeBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    ZPUBuffer *rangeBuffer = (ZPUBuffer *)indirectRangeBuffer;
    if (![rangeBuffer isKindOfClass:[ZPUBuffer class]] ||
        indirectBufferOffset > rangeBuffer.length ||
        rangeBuffer.length - indirectBufferOffset < sizeof(MTLIndirectCommandBufferExecutionRange)) {
        [_owner markError];
        return;
    }
    const uint8_t *bytes = (const uint8_t *)rangeBuffer.contents + indirectBufferOffset;
    const MTLIndirectCommandBufferExecutionRange range = {
        (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24),
        (uint32_t)bytes[4] | ((uint32_t)bytes[5] << 8) | ((uint32_t)bytes[6] << 16) | ((uint32_t)bytes[7] << 24),
    };
    [_owner retainResource:rangeBuffer];
    [self executeCommandsInBuffer:indirectCommandBuffer
                         withRange:NSMakeRange(range.location, range.length)];
}
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)afterQueueStages;
    (void)beforeStages;
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding {
    if (_zpuEncoder != NULL) (void)zpu_metal_compute_encoder_end_encoding(_zpuEncoder);
}
@end

@implementation ZPUArgumentEncoder
- (instancetype)initWithOwner:(ZPUDevice *)owner arguments:(NSArray<MTLArgumentDescriptor *> *)arguments {
    if ((self = [super init])) {
        _owner = owner;
        _alignment = 16;
        _encodedLength = 0;
        _retainedResources = [NSMutableArray array];
        _bindings = [NSMutableDictionary dictionary];
        _bindingOffsets = [NSMutableDictionary dictionary];
        _constants = [NSMutableDictionary dictionary];
        for (MTLArgumentDescriptor *descriptor in arguments) {
            if (![descriptor isKindOfClass:[MTLArgumentDescriptor class]]) continue;
            NSUInteger elements = descriptor.arrayLength == 0 ? 1 : descriptor.arrayLength;
            if (descriptor.index > NSUIntegerMax - elements) {
                _encodedLength = 0;
                break;
            }
            NSUInteger slots = descriptor.index + elements;
            if (slots > NSUIntegerMax / 16) {
                _encodedLength = 0;
                break;
            }
            NSUInteger length = slots * 16;
            if (length > _encodedLength) _encodedLength = length;
        }
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (NSUInteger)encodedLength { return _encodedLength; }
- (NSUInteger)alignment { return _alignment; }
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer offset:(NSUInteger)offset {
    ZPUBuffer *buffer = (ZPUBuffer *)argumentBuffer;
    if (argumentBuffer != nil && ![buffer isKindOfClass:[ZPUBuffer class]]) return;
    if (buffer != nil && offset > buffer.length) return;
    _argumentBuffer = buffer;
    _argumentOffset = offset;
    if (buffer != nil) [_retainedResources addObject:buffer];
    if (buffer != nil) {
        [_constants enumerateKeysAndObjectsUsingBlock:^(NSNumber *key, NSMutableData *data, BOOL *stop) {
            (void)stop;
            NSUInteger index = key.unsignedIntegerValue;
            if (index > (NSUIntegerMax - offset) / 16) return;
            NSUInteger destinationOffset = offset + index * 16;
            if (destinationOffset <= buffer.length && buffer.length - destinationOffset >= data.length) {
                memcpy((uint8_t *)buffer.contents + destinationOffset, data.bytes, data.length);
            }
        }];
        [self writeBindingsToArgumentBuffer];
    }
}
- (void)setArgumentBuffer:(id<MTLBuffer>)argumentBuffer startOffset:(NSUInteger)startOffset arrayElement:(NSUInteger)arrayElement {
    if (_encodedLength != 0 && arrayElement > NSUIntegerMax / _encodedLength) return;
    NSUInteger elementOffset = _encodedLength * arrayElement;
    if (startOffset > NSUIntegerMax - elementOffset) return;
    [self setArgumentBuffer:argumentBuffer offset:startOffset + elementOffset];
}
- (void)writeBindingsToArgumentBuffer {
    if (_argumentBuffer == nil) return;
    for (NSNumber *key in _bindings) {
        const NSUInteger index = key.unsignedIntegerValue;
        if (index > (NSUIntegerMax - _argumentOffset) / 16) continue;
        const NSUInteger destinationOffset = _argumentOffset + index * 16;
        if (destinationOffset > _argumentBuffer.length || _argumentBuffer.length - destinationOffset < 16) continue;
        id object = _bindings[key];
        uint64_t resourceID = 0;
        uint64_t auxiliary = 0;
        if ([object isKindOfClass:[ZPUBuffer class]]) {
            ZPUBuffer *buffer = (ZPUBuffer *)object;
            resourceID = buffer->_resourceID;
            auxiliary = [_bindingOffsets[key] unsignedLongLongValue];
        } else if ([object isKindOfClass:[ZPUTexture class]]) {
            resourceID = ((ZPUTexture *)object)->_resourceID;
        } else if ([object isKindOfClass:[ZPUSamplerState class]]) {
            resourceID = ((ZPUSamplerState *)object)->_resourceID;
        }
        memcpy((uint8_t *)_argumentBuffer.contents + destinationOffset, &resourceID, sizeof(resourceID));
        memcpy((uint8_t *)_argumentBuffer.contents + destinationOffset + sizeof(resourceID), &auxiliary, sizeof(auxiliary));
    }
}
- (void)remember:(id)object atIndex:(NSUInteger)index offset:(NSUInteger)offset {
    _bindings[@(index)] = object == nil ? [NSNull null] : object;
    _bindingOffsets[@(index)] = @(offset);
    if (object != nil) [_retainedResources addObject:object];
    [self writeBindingsToArgumentBuffer];
}
- (void)remember:(id)object atIndex:(NSUInteger)index {
    [self remember:object atIndex:index offset:0];
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (buffer != nil && ![(id)buffer isKindOfClass:[ZPUBuffer class]]) return;
    if (buffer != nil && offset > [(ZPUBuffer *)buffer length]) return;
    [self remember:buffer atIndex:index offset:offset];
}
- (void)setBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (buffers == NULL || offsets == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setBuffer:buffers[index] offset:offsets[index] atIndex:range.location + index];
    }
}
- (void)setTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    if (texture != nil && ![(id)texture isKindOfClass:[ZPUTexture class]]) return;
    [self remember:texture atIndex:index];
}
- (void)setTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setTexture:textures[index] atIndex:range.location + index];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (sampler != nil && ![(id)sampler isKindOfClass:[ZPUSamplerState class]]) return;
    [self remember:sampler atIndex:index];
}
- (void)setSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range {
    if (samplers == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setSamplerState:samplers[index] atIndex:range.location + index];
}
- (void *)constantDataAtIndex:(NSUInteger)index {
    NSNumber *key = @(index);
    NSMutableData *data = _constants[key];
    if (data == nil) {
        data = [NSMutableData dataWithLength:16];
        _constants[key] = data;
    }
    if (_argumentBuffer != nil && index <= (NSUIntegerMax - _argumentOffset) / 16) {
        NSUInteger offset = _argumentOffset + index * 16;
        if (offset <= _argumentBuffer.length && _argumentBuffer.length - offset >= 16) {
            return (uint8_t *)_argumentBuffer.contents + offset;
        }
    }
    return data.mutableBytes;
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipeline atIndex:(NSUInteger)index API_AVAILABLE(macos(10.14), macCatalyst(13.0), ios(13.0)) {
    if (pipeline != nil && ![(id)pipeline isKindOfClass:[ZPURenderPipelineState class]]) return;
    [self remember:pipeline atIndex:index];
}
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> __nullable [__nonnull])pipelines withRange:(NSRange)range API_AVAILABLE(macos(10.14), macCatalyst(13.0), ios(13.0)) {
    if (pipelines == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setRenderPipelineState:pipelines[index] atIndex:range.location + index];
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    if (pipeline != nil && ![(id)pipeline isKindOfClass:[ZPUComputePipelineState class]]) return;
    [self remember:pipeline atIndex:index];
}
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> __nullable [__nonnull])pipelines withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    if (pipelines == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setComputePipelineState:pipelines[index] atIndex:range.location + index];
}
- (void)setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer atIndex:(NSUInteger)index API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (indirectCommandBuffer != nil && ![(id)indirectCommandBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]]) return;
    [self remember:indirectCommandBuffer atIndex:index];
}
- (void)setIndirectCommandBuffers:(const id<MTLIndirectCommandBuffer> __nullable [__nonnull])buffers withRange:(NSRange)range API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (buffers == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setIndirectCommandBuffer:buffers[index] atIndex:range.location + index];
}
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)accelerationStructure atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)accelerationStructure;
    (void)index;
}
- (void)setVisibleFunctionTable:(id<MTLVisibleFunctionTable>)visibleFunctionTable atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)visibleFunctionTable;
    (void)index;
}
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])visibleFunctionTables withRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)visibleFunctionTables;
    (void)range;
}
- (void)setIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)intersectionFunctionTable atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)intersectionFunctionTable;
    (void)index;
}
- (void)setIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])intersectionFunctionTables withRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)intersectionFunctionTables;
    (void)range;
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState atIndex:(NSUInteger)index API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)depthStencilState;
    (void)index;
}
- (void)setDepthStencilStates:(const id<MTLDepthStencilState> __nullable [__nonnull])depthStencilStates withRange:(NSRange)range API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)depthStencilStates;
    (void)range;
}
- (id<MTLArgumentEncoder>)newArgumentEncoderForBufferAtIndex:(NSUInteger)index API_AVAILABLE(macos(10.13), ios(11.0)) {
    (void)index;
    return (id<MTLArgumentEncoder>)[[ZPUArgumentEncoder alloc] initWithOwner:_owner arguments:@[]];
}
@end

@implementation ZPUParallelRenderEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner texture:(ZPUTexture *)texture pass:(zpu_metal_render_pass_descriptor)pass {
    if ((self = [super init])) {
        _owner = owner;
        _texture = texture;
        _pass = pass;
    }
    return self;
}
- (id<MTLDevice>)device { return [_owner device]; }
- (id<MTLRenderCommandEncoder>)renderCommandEncoder {
    zpu_metal_render_pass_descriptor pass = _pass;
    if (_childCount != 0) {
        pass.color.load_action = ZPU_METAL_LOAD_LOAD;
        if (pass.depth.load_action != ZPU_METAL_LOAD_DONT_CARE) pass.depth.load_action = ZPU_METAL_LOAD_LOAD;
    }
    zpu_metal_command_buffer *commandBuffer = _owner->_zpuCommandBuffer;
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(commandBuffer, _texture->_zpuTexture, &pass);
    if (encoder == NULL) return nil;
    if (pass.depth.load_action != ZPU_METAL_LOAD_DONT_CARE) {
        ZPUTexture *depth = nil;
        for (id resource in _owner->_retainedResources) {
            if ([resource isKindOfClass:[ZPUTexture class]] && ((ZPUTexture *)resource)->_pixelFormat == MTLPixelFormatDepth32Float) {
                depth = (ZPUTexture *)resource;
                break;
            }
        }
        if (depth == nil || zpu_metal_render_encoder_set_depth_texture(encoder, depth->_zpuTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            return nil;
        }
    }
    _childCount += 1;
    return (id<MTLRenderCommandEncoder>)[[ZPURenderEncoder alloc] initWithOwner:_owner encoder:encoder];
}
- (void)setColorStoreAction:(MTLStoreAction)storeAction atIndex:(NSUInteger)colorAttachmentIndex {
    if (colorAttachmentIndex == 0) _pass.color.store_action = zpu_store_action(storeAction);
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction { _pass.depth.store_action = zpu_store_action(storeAction); }
- (void)setStencilStoreAction:(MTLStoreAction)storeAction { (void)storeAction; }
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)colorAttachmentIndex { (void)options; (void)colorAttachmentIndex; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)afterQueueStages;
    (void)beforeStages;
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding { }
@end

@implementation ZPUBlitEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_blit_encoder *)encoder {
    if ((self = [super init])) { _owner = owner; _zpuEncoder = encoder; }
    return self;
}
- (id<MTLDevice>)device { return [_owner device]; }
- (void)dealloc {
    if (_zpuEncoder != NULL) {
        (void)zpu_metal_blit_encoder_end_encoding(_zpuEncoder);
        zpu_metal_blit_encoder_destroy(_zpuEncoder);
    }
}
- (void)synchronizeResource:(id<MTLResource>)resource {
    ZPUBuffer *buffer = (ZPUBuffer *)resource;
    if (![buffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:buffer];
    (void)zpu_metal_blit_encoder_synchronize_resource(_zpuEncoder, buffer->_zpuBuffer);
}
- (void)synchronizeTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.11), macCatalyst(13.0)) API_UNAVAILABLE(ios) {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (![zpuTexture isKindOfClass:[ZPUTexture class]] || slice != 0 || level != 0) return;
    [_owner retainResource:zpuTexture];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size {
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    if (![source isKindOfClass:[ZPUBuffer class]] || ![destination isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:source];
    [_owner retainResource:destination];
    (void)zpu_metal_blit_encoder_copy_buffer(_zpuEncoder, source->_zpuBuffer, sourceOffset, destination->_zpuBuffer, destinationOffset, size);
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    (void)sourceBytesPerImage;
    (void)destinationSlice;
    if (destinationLevel != 0 || sourceSize.depth != 1) return;
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    MTLRegion region = MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, destinationOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (![source isKindOfClass:[ZPUBuffer class]] || ![destination isKindOfClass:[ZPUTexture class]] || !zpu_region_fits(region)) return;
    [_owner retainResource:source];
    [_owner retainResource:destination];
    (void)zpu_metal_blit_encoder_copy_buffer_to_texture(_zpuEncoder, source->_zpuBuffer, sourceOffset, sourceBytesPerRow, destination->_zpuTexture, zpu_region(region));
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    [self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel destinationOrigin:destinationOrigin];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage {
    (void)sourceSlice;
    (void)destinationBytesPerImage;
    if (sourceLevel != 0 || sourceSize.depth != 1) return;
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    MTLRegion region = MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUBuffer class]] || !zpu_region_fits(region)) return;
    [_owner retainResource:source];
    [_owner retainResource:destination];
    (void)zpu_metal_blit_encoder_copy_texture_to_buffer(_zpuEncoder, source->_zpuTexture, zpu_region(region), destination->_zpuBuffer, destinationOffset, destinationBytesPerRow);
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage options:(MTLBlitOption)options API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    [self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:sourceSize toBuffer:destinationBuffer destinationOffset:destinationOffset destinationBytesPerRow:destinationBytesPerRow destinationBytesPerImage:destinationBytesPerImage];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    (void)sourceSlice;
    (void)destinationSlice;
    if (sourceLevel != 0 || destinationLevel != 0 || sourceSize.depth != 1) return;
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]]) return;
    [_owner retainResource:source];
    [_owner retainResource:destination];
    MTLRegion sourceRegion = MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    MTLRegion destinationRegion = MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, destinationOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (!zpu_region_fits(sourceRegion) || !zpu_region_fits(destinationRegion)) return;
    (void)zpu_metal_blit_encoder_copy_texture_to_texture(_zpuEncoder, source->_zpuTexture, zpu_region(sourceRegion), destination->_zpuTexture, zpu_region(destinationRegion));
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount API_AVAILABLE(macos(10.15), ios(13.0)) {
    if (sourceSlice != 0 || destinationSlice != 0 || sourceLevel != 0 || destinationLevel != 0 || sliceCount != 1 || levelCount != 1) {
        [_owner markError];
        return;
    }
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]] ||
        [source width] != [destination width] || [source height] != [destination height]) {
        [_owner markError];
        return;
    }
    [self copyFromTexture:sourceTexture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                sourceSize:MTLSizeMake([source width], [source height], 1) toTexture:destinationTexture
        destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture toTexture:(id<MTLTexture>)destinationTexture API_AVAILABLE(macos(10.15), ios(13.0)) {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]]) {
        [_owner markError];
        return;
    }
    [self copyFromTexture:sourceTexture sourceSlice:0 sourceLevel:0 toTexture:destinationTexture destinationSlice:0 destinationLevel:0 sliceCount:1 levelCount:1];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (![zpuBuffer isKindOfClass:[ZPUBuffer class]] || range.location > SIZE_MAX - range.length) return;
    [_owner retainResource:zpuBuffer];
    (void)zpu_metal_blit_encoder_fill_buffer(_zpuEncoder, zpuBuffer->_zpuBuffer, range.location, range.length, value);
}
- (void)updateFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]]) return;
    [_owner retainResource:zpuFence];
    (void)zpu_metal_blit_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)waitForFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]]) return;
    [_owner retainResource:zpuFence];
    (void)zpu_metal_blit_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture { (void)texture; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture { (void)texture; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture { (void)texture; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (![texture isKindOfClass:[ZPUTexture class]] || slice != 0 || level != 0) [_owner markError];
    else [_owner retainResource:texture];
}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (![texture isKindOfClass:[ZPUTexture class]] || slice != 0 || level != 0) [_owner markError];
    else [_owner retainResource:texture];
}
- (void)resetCommandsInBuffer:(id<MTLIndirectCommandBuffer>)buffer withRange:(NSRange)range API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)buffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
    [zpuBuffer resetWithRange:range];
}
- (void)copyIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)source sourceRange:(NSRange)sourceRange destination:(id<MTLIndirectCommandBuffer>)destination destinationIndex:(NSUInteger)destinationIndex API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *sourceBuffer = (ZPUIndirectCommandBuffer *)source;
    ZPUIndirectCommandBuffer *destinationBuffer = (ZPUIndirectCommandBuffer *)destination;
    if (![sourceBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        ![destinationBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        ![destinationBuffer copyCommandsFrom:sourceBuffer sourceRange:sourceRange destinationIndex:destinationIndex]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:sourceBuffer];
    [_owner retainResource:destinationBuffer];
}
- (void)optimizeIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)range API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        range.location > zpuBuffer->_maxCommandCount || range.length > zpuBuffer->_maxCommandCount - range.location) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)sampleCountersInBuffer:(id<MTLCounterSampleBuffer>)sampleBuffer atSampleIndex:(NSUInteger)sampleIndex withBarrier:(BOOL)barrier API_AVAILABLE(macos(10.15), ios(14.0)) {
    (void)barrier;
    ZPUCounterSampleBuffer *sample = (ZPUCounterSampleBuffer *)sampleBuffer;
    if (![sample isKindOfClass:[ZPUCounterSampleBuffer class]] || sample->_owner != [_owner device] ||
        ![sample sampleAtIndex:sampleIndex]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:sample];
}
- (void)resolveCounters:(id<MTLCounterSampleBuffer>)sampleBuffer inRange:(NSRange)range destinationBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset API_AVAILABLE(macos(10.15), ios(14.0)) {
    ZPUCounterSampleBuffer *sample = (ZPUCounterSampleBuffer *)sampleBuffer;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    NSData *resolved = [sample isKindOfClass:[ZPUCounterSampleBuffer class]] ? [sample resolveCounterRange:range] : nil;
    if (![sample isKindOfClass:[ZPUCounterSampleBuffer class]] || sample->_owner != [_owner device] ||
        ![destination isKindOfClass:[ZPUBuffer class]] || destination->_owner != [_owner device] ||
        resolved == nil || destinationOffset > destination.length ||
        resolved.length > destination.length - destinationOffset) {
        [_owner markError];
        return;
    }
    if (resolved.length != 0) memcpy((uint8_t *)destination.contents + destinationOffset, resolved.bytes, resolved.length);
    [_owner retainResource:sample];
    [_owner retainResource:destination];
}
- (void)getTextureAccessCounters:(id<MTLTexture>)texture region:(MTLRegion)region mipLevel:(NSUInteger)mipLevel slice:(NSUInteger)slice resetCounters:(BOOL)resetCounters countersBuffer:(id<MTLBuffer>)countersBuffer countersBufferOffset:(NSUInteger)countersBufferOffset API_AVAILABLE(macos(11.0), macCatalyst(14.0)) {
    (void)texture;
    (void)region;
    (void)mipLevel;
    (void)slice;
    (void)resetCounters;
    (void)countersBuffer;
    (void)countersBufferOffset;
    [_owner markError];
}
- (void)resetTextureAccessCounters:(id<MTLTexture>)texture region:(MTLRegion)region mipLevel:(NSUInteger)mipLevel slice:(NSUInteger)slice API_AVAILABLE(macos(11.0), macCatalyst(14.0)) {
    (void)texture;
    (void)region;
    (void)mipLevel;
    (void)slice;
    [_owner markError];
}
- (void)copyFromTensor:(id<MTLTensor>)sourceTensor sourceOrigin:(MTLTensorExtents *)sourceOrigin sourceDimensions:(MTLTensorExtents *)sourceDimensions toTensor:(id<MTLTensor>)destinationTensor destinationOrigin:(MTLTensorExtents *)destinationOrigin destinationDimensions:(MTLTensorExtents *)destinationDimensions API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)sourceTensor;
    (void)sourceOrigin;
    (void)sourceDimensions;
    (void)destinationTensor;
    (void)destinationOrigin;
    (void)destinationDimensions;
    [_owner markError];
}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)afterQueueStages;
    (void)beforeStages;
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding {
    if (_zpuEncoder != NULL) (void)zpu_metal_blit_encoder_end_encoding(_zpuEncoder);
}
@end

@implementation ZPUResourceStateEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_resource_state_encoder *)encoder {
    if ((self = [super init])) {
        _owner = owner;
        _zpuEncoder = encoder;
    }
    return self;
}
- (id<MTLDevice>)device { return [_owner device]; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)dealloc {
    if (_zpuEncoder != NULL) {
        (void)zpu_metal_resource_state_encoder_end_encoding(_zpuEncoder);
        zpu_metal_resource_state_encoder_destroy(_zpuEncoder);
    }
}
- (void)updateTextureMappings:(id<MTLTexture>)texture
                         mode:(const MTLSparseTextureMappingMode)mode
                      regions:(const MTLRegion[])regions
                    mipLevels:(const NSUInteger[])mipLevels
                       slices:(const NSUInteger[])slices
                   numRegions:(NSUInteger)numRegions {
    (void)texture;
    (void)mode;
    (void)regions;
    (void)mipLevels;
    (void)slices;
    (void)numRegions;
    /* Sparse storage is intentionally unsupported; never fabricate a
     * mapping while keeping the failure visible on the command buffer. */
    [_owner markError];
}
- (void)updateTextureMapping:(id<MTLTexture>)texture
                        mode:(const MTLSparseTextureMappingMode)mode
                       region:(const MTLRegion)region
                     mipLevel:(const NSUInteger)mipLevel
                        slice:(const NSUInteger)slice {
    (void)texture;
    (void)mode;
    (void)region;
    (void)mipLevel;
    (void)slice;
    [_owner markError];
}
- (void)updateTextureMapping:(id<MTLTexture>)texture
                        mode:(const MTLSparseTextureMappingMode)mode
              indirectBuffer:(id<MTLBuffer>)indirectBuffer
        indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    (void)texture;
    (void)mode;
    (void)indirectBuffer;
    (void)indirectBufferOffset;
    [_owner markError];
}
- (void)moveTextureMappingsFromTexture:(id<MTLTexture>)sourceTexture
                          sourceSlice:(NSUInteger)sourceSlice
                          sourceLevel:(NSUInteger)sourceLevel
                         sourceOrigin:(MTLOrigin)sourceOrigin
                           sourceSize:(MTLSize)sourceSize
                            toTexture:(id<MTLTexture>)destinationTexture
                     destinationSlice:(NSUInteger)destinationSlice
                     destinationLevel:(NSUInteger)destinationLevel
                  destinationOrigin:(MTLOrigin)destinationOrigin {
    (void)sourceTexture;
    (void)sourceSlice;
    (void)sourceLevel;
    (void)sourceOrigin;
    (void)sourceSize;
    (void)destinationTexture;
    (void)destinationSlice;
    (void)destinationLevel;
    (void)destinationOrigin;
    [_owner markError];
}
- (void)updateFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device] ||
        zpu_metal_resource_state_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)waitForFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device] ||
        zpu_metal_resource_state_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)afterQueueStages;
    (void)beforeStages;
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding {
    if (_zpuEncoder != NULL && !_ended) {
        (void)zpu_metal_resource_state_encoder_end_encoding(_zpuEncoder);
        _ended = YES;
    }
}
@end

@implementation ZPURenderEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_render_encoder *)encoder {
    if ((self = [super init])) { _owner = owner; _zpuEncoder = encoder; }
    return self;
}
- (id<MTLDevice>)device { return [_owner device]; }
- (void)dealloc {
    if (_zpuEncoder != NULL) {
        (void)zpu_metal_render_encoder_end_encoding(_zpuEncoder);
        zpu_metal_render_encoder_destroy(_zpuEncoder);
    }
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (buffer != nil && ![zpuBuffer isKindOfClass:[ZPUBuffer class]]) return;
    if (index > UINT32_MAX) return;
    _vertexBuffer = zpuBuffer;
    [_owner retainResource:zpuBuffer];
    if (zpu_metal_render_encoder_set_vertex_buffer(
            _zpuEncoder, zpuBuffer == nil ? NULL : zpuBuffer->_zpuBuffer, offset,
            (uint32_t)index) != ZPU_METAL_OK) [_owner markError];
}
- (void)setVertexBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    [self setVertexBuffer:(id<MTLBuffer>)_vertexBuffer offset:offset atIndex:index];
}
- (void)setVertexBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (range.length == 0 || buffers == NULL || offsets == NULL || range.location > UINT32_MAX ||
        range.length > UINT32_MAX - range.location) return;
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setVertexBuffer:buffers[index] offset:offsets[index] atIndex:range.location + index];
    }
}
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (index > UINT32_MAX || zpu_metal_render_encoder_set_vertex_bytes(
            _zpuEncoder, bytes, length, (uint32_t)index) != ZPU_METAL_OK) [_owner markError];
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setVertexBuffer:buffer offset:offset atIndex:index];
}
- (void)setVertexBuffers:(id<MTLBuffer> const __nullable [__nonnull])buffers
                  offsets:(NSUInteger const [__nonnull])offsets
         attributeStrides:(NSUInteger const [__nonnull])strides
                withRange:(NSRange)range API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)strides;
    [self setVertexBuffers:buffers offsets:offsets withRange:range];
}
- (void)setVertexBufferOffset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setVertexBufferOffset:offset atIndex:index];
}
- (void)setVertexBytes:(const void *)bytes length:(NSUInteger)length attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setVertexBytes:bytes length:length atIndex:index];
}
- (void)setVertexTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (texture != nil && ![zpuTexture isKindOfClass:[ZPUTexture class]]) { [_owner markError]; return; }
    (void)index;
    if (zpuTexture != nil) [_owner retainResource:zpuTexture];
}
- (void)setVertexTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setVertexTexture:textures[index] atIndex:range.location + index];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (sampler != nil && ![(id)sampler isKindOfClass:[ZPUSamplerState class]]) { [_owner markError]; return; }
    (void)index;
    if (sampler != nil) [_owner retainResource:sampler];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range {
    if (samplers == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setVertexSamplerState:samplers[index] atIndex:range.location + index];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index {
    (void)lodMinClamp;
    (void)lodMaxClamp;
    [self setVertexSamplerState:sampler atIndex:index];
}
- (void)setVertexSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range {
    if (samplers == NULL || lodMinClamps == NULL || lodMaxClamps == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setVertexSamplerState:samplers[index]
                       lodMinClamp:lodMinClamps[index]
                       lodMaxClamp:lodMaxClamps[index]
                            atIndex:range.location + index];
    }
}
- (void)setFragmentBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index {
    if (index > UINT32_MAX || (bytes == NULL && length != 0)) { [_owner markError]; return; }
    if (length != 0) [_owner retainResource:[NSData dataWithBytes:bytes length:length]];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (buffer != nil && (![zpuBuffer isKindOfClass:[ZPUBuffer class]] || offset > zpuBuffer.length)) { [_owner markError]; return; }
    (void)index;
    if (zpuBuffer != nil) [_owner retainResource:zpuBuffer];
}
- (void)setFragmentBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index { (void)offset; (void)index; }
- (void)setFragmentBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (buffers == NULL || offsets == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setFragmentBuffer:buffers[index] offset:offsets[index] atIndex:range.location + index];
}
- (void)setFragmentTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    [self setVertexTexture:texture atIndex:index];
}
- (void)setFragmentTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    [self setVertexTextures:textures withRange:range];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    [self setVertexSamplerState:sampler atIndex:index];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range {
    [self setVertexSamplerStates:samplers withRange:range];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index {
    [self setVertexSamplerState:sampler lodMinClamp:lodMinClamp lodMaxClamp:lodMaxClamp atIndex:index];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range {
    [self setVertexSamplerStates:samplers lodMinClamps:lodMinClamps lodMaxClamps:lodMaxClamps withRange:range];
}
- (void)setObjectBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentBytes:bytes length:length atIndex:index];
}
- (void)setObjectBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentBuffer:buffer offset:offset atIndex:index];
}
- (void)setObjectBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentBufferOffset:offset atIndex:index]; }
- (void)setObjectBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentBuffers:buffers offsets:offsets withRange:range];
}
- (void)setObjectTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentTexture:texture atIndex:index]; }
- (void)setObjectTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentTextures:textures withRange:range]; }
- (void)setObjectSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentSamplerState:sampler atIndex:index]; }
- (void)setObjectSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentSamplerStates:samplers withRange:range]; }
- (void)setObjectSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentSamplerState:sampler lodMinClamp:lodMinClamp lodMaxClamp:lodMaxClamp atIndex:index];
}
- (void)setObjectSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentSamplerStates:samplers lodMinClamps:lodMinClamps lodMaxClamps:lodMaxClamps withRange:range];
}
- (void)setObjectThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)length; (void)index; }
- (void)setMeshBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentBytes:bytes length:length atIndex:index]; }
- (void)setMeshBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentBuffer:buffer offset:offset atIndex:index]; }
- (void)setMeshBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentBufferOffset:offset atIndex:index]; }
- (void)setMeshBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentBuffers:buffers offsets:offsets withRange:range]; }
- (void)setMeshTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentTexture:texture atIndex:index]; }
- (void)setMeshTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentTextures:textures withRange:range]; }
- (void)setMeshSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentSamplerState:sampler atIndex:index]; }
- (void)setMeshSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { [self setFragmentSamplerStates:samplers withRange:range]; }
- (void)setMeshSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentSamplerState:sampler lodMinClamp:lodMinClamp lodMaxClamp:lodMaxClamp atIndex:index];
}
- (void)setMeshSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    [self setFragmentSamplerStates:samplers lodMinClamps:lodMinClamps lodMaxClamps:lodMaxClamps withRange:range];
}
- (void)setTileBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentBytes:bytes length:length atIndex:index]; }
- (void)setTileBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentBuffer:buffer offset:offset atIndex:index]; }
- (void)setTileBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentBufferOffset:offset atIndex:index]; }
- (void)setTileBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentBuffers:buffers offsets:offsets withRange:range]; }
- (void)setTileTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentTexture:texture atIndex:index]; }
- (void)setTileTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentTextures:textures withRange:range]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentSamplerState:sampler atIndex:index]; }
- (void)setTileSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { [self setFragmentSamplerStates:samplers withRange:range]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    [self setFragmentSamplerState:sampler lodMinClamp:lodMinClamp lodMaxClamp:lodMaxClamp atIndex:index];
}
- (void)setTileSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(ios(11.0), tvos(14.5), macos(11.0), macCatalyst(14.0)) {
    [self setFragmentSamplerStates:samplers lodMinClamps:lodMinClamps lodMaxClamps:lodMaxClamps withRange:range];
}
- (void)setVertexVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTable; (void)bufferIndex; }
- (void)setVertexVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; (void)range; }
- (void)setFragmentVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTable; (void)bufferIndex; }
- (void)setFragmentVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; (void)range; }
- (void)setTileVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTable; (void)bufferIndex; }
- (void)setTileVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; (void)range; }
- (void)setVertexIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)table; (void)bufferIndex; }
- (void)setVertexIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; (void)range; }
- (void)setFragmentIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)table; (void)bufferIndex; }
- (void)setFragmentIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; (void)range; }
- (void)setTileIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)table; (void)bufferIndex; }
- (void)setTileIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; (void)range; }
- (void)setVertexAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)structure; (void)bufferIndex; }
- (void)setFragmentAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)structure; (void)bufferIndex; }
- (void)setTileAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)structure; (void)bufferIndex; }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage {
    (void)usage;
    if ([resource isKindOfClass:[ZPUBuffer class]] || [resource isKindOfClass:[ZPUTexture class]]) {
        [_owner retainResource:resource];
    }
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages API_AVAILABLE(macos(10.15), ios(13.0)) {
    (void)stages;
    [self useResource:resource usage:usage];
}
- (void)useResources:(const id<MTLResource> __nonnull[__nonnull])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage {
    if (resources == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self useResource:resources[index] usage:usage];
}
- (void)useResources:(const id<MTLResource> __nonnull[__nonnull])resources count:(NSUInteger)count usage:(MTLResourceUsage)usage stages:(MTLRenderStages)stages API_AVAILABLE(macos(10.15), ios(13.0)) {
    if (resources == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self useResource:resources[index] usage:usage stages:stages];
}
- (void)useHeap:(id<MTLHeap>)heap {
    if ([heap isKindOfClass:[ZPUHeap class]]) [_owner retainResource:heap];
}
- (void)useHeaps:(const id<MTLHeap> __nonnull[__nonnull])heaps count:(NSUInteger)count {
    if (heaps == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self useHeap:heaps[index]];
}
- (void)useHeap:(id<MTLHeap>)heap stages:(MTLRenderStages)stages API_AVAILABLE(macos(10.15), ios(13.0)) {
    (void)stages;
    [self useHeap:heap];
}
- (void)useHeaps:(const id<MTLHeap> __nonnull[__nonnull])heaps count:(NSUInteger)count stages:(MTLRenderStages)stages API_AVAILABLE(macos(10.15), ios(13.0)) {
    (void)stages;
    [self useHeaps:heaps count:count];
}
- (void)memoryBarrierWithScope:(MTLBarrierScope)scope afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before API_AVAILABLE(macos(10.14), macCatalyst(13.0), ios(16.0)) {
    (void)scope;
    (void)after;
    (void)before;
}
- (void)memoryBarrierWithResources:(const id<MTLResource> __nonnull[__nonnull])resources count:(NSUInteger)count afterStages:(MTLRenderStages)after beforeStages:(MTLRenderStages)before API_AVAILABLE(macos(10.14), macCatalyst(13.0), ios(16.0)) {
    (void)after;
    (void)before;
    [self useResources:resources count:count usage:MTLResourceUsageRead | MTLResourceUsageWrite];
}
#pragma clang diagnostic pop
- (void)setViewport:(MTLViewport)viewport {
    (void)zpu_metal_render_encoder_set_viewport(_zpuEncoder, (zpu_metal_viewport){
        (float)viewport.originX, (float)viewport.originY, (float)viewport.width,
        (float)viewport.height, (float)viewport.znear, (float)viewport.zfar,
    });
}
- (void)setViewports:(const MTLViewport [__nonnull])viewports count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(12.0), tvos(14.5)) {
    if (viewports == NULL || count == 0) { [_owner markError]; return; }
    [self setViewport:viewports[0]];
}
- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping * __nullable)viewMappings API_AVAILABLE(macos(10.15.4), ios(13.0), macCatalyst(13.4), tvos(16.0)) {
    (void)viewMappings;
    if (count > 1) [_owner markError];
}
- (void)setScissorRect:(MTLScissorRect)scissorRect {
    uint32_t x, y, width, height;
    if (!zpu_u32(scissorRect.x, &x) || !zpu_u32(scissorRect.y, &y) || !zpu_u32(scissorRect.width, &width) || !zpu_u32(scissorRect.height, &height)) return;
    (void)zpu_metal_render_encoder_set_scissor_rect(_zpuEncoder, (zpu_metal_scissor_rect){x, y, width, height});
}
- (void)setScissorRects:(const MTLScissorRect [__nonnull])scissorRects count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(12.0), tvos(14.5)) {
    if (scissorRects == NULL || count == 0) { [_owner markError]; return; }
    [self setScissorRect:scissorRects[0]];
}
- (void)setCullMode:(MTLCullMode)cullMode { (void)zpu_metal_render_encoder_set_cull_mode(_zpuEncoder, (zpu_metal_cull_mode)cullMode); }
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode API_AVAILABLE(macos(10.11), ios(11.0)) { (void)depthClipMode; }
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp { (void)depthBias; (void)slopeScale; (void)clamp; }
- (void)setDepthTestMinBound:(float)minBound maxBound:(float)maxBound API_AVAILABLE(macos(26.0), ios(26.0)) { (void)minBound; (void)maxBound; }
- (void)setFrontFacingWinding:(MTLWinding)frontFacingWinding { (void)zpu_metal_render_encoder_set_front_facing(_zpuEncoder, (zpu_metal_winding)frontFacingWinding); }
- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode { (void)zpu_metal_render_encoder_set_triangle_fill_mode(_zpuEncoder, (zpu_metal_triangle_fill_mode)fillMode); }
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState {
    ZPUDepthStencilState *state = (ZPUDepthStencilState *)depthStencilState;
    if (![state isKindOfClass:[ZPUDepthStencilState class]]) return;
    _depthStencilState = state;
    [_owner retainResource:state];
    if (zpu_metal_render_encoder_set_depth_compare_function(
            _zpuEncoder, (zpu_metal_compare_function)state->_depthCompareFunction,
            state->_depthWriteEnabled) != ZPU_METAL_OK) [_owner markError];
}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {
    (void)stages;
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]]) return;
    [_owner retainResource:zpuFence];
    (void)zpu_metal_render_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {
    (void)stages;
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]]) return;
    [_owner retainResource:zpuFence];
    (void)zpu_metal_render_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    ZPURenderPipelineState *state = (ZPURenderPipelineState *)pipelineState;
    if (![state isKindOfClass:[ZPURenderPipelineState class]]) return;
    _pipelineState = state;
    [_owner retainResource:state];
    if (zpu_metal_render_encoder_set_pipeline_formats(
            _zpuEncoder, (uint16_t)state->_colorPixelFormat,
            (uint16_t)state->_depthPixelFormat) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_blend_state(
        _zpuEncoder, state->_blendingEnabled,
        (zpu_metal_blend_factor)state->_sourceRGBBlendFactor,
        (zpu_metal_blend_factor)state->_destinationRGBBlendFactor,
        (zpu_metal_blend_operation)state->_rgbBlendOperation,
        (zpu_metal_blend_factor)state->_sourceAlphaBlendFactor,
        (zpu_metal_blend_factor)state->_destinationAlphaBlendFactor,
        (zpu_metal_blend_operation)state->_alphaBlendOperation,
        (zpu_metal_color_write_mask)state->_writeMask) != ZPU_METAL_OK) [_owner markError];
}
- (void)setBlendColor:(MTLClearColor)blendColor {
    if (zpu_metal_render_encoder_set_blend_color(_zpuEncoder, (zpu_metal_color){
        (float)blendColor.red, (float)blendColor.green, (float)blendColor.blue, (float)blendColor.alpha,
    }) != ZPU_METAL_OK) [_owner markError];
}
- (void)setBlendColorRed:(float)red green:(float)green blue:(float)blue alpha:(float)alpha {
    [self setBlendColor:MTLClearColorMake(red, green, blue, alpha)];
}
- (void)setStencilReferenceValue:(uint32_t)referenceValue { (void)referenceValue; }
- (void)setStencilFrontReferenceValue:(uint32_t)frontReferenceValue backReferenceValue:(uint32_t)backReferenceValue API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)frontReferenceValue;
    (void)backReferenceValue;
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset { (void)mode; (void)offset; }
- (void)textureBarrier API_DEPRECATED_WITH_REPLACEMENT("Use memoryBarrierWithScope:MTLBarrierScopeRenderTargets", macos(10.11, 10.14)) API_UNAVAILABLE(ios) {}
- (NSUInteger)tileWidth API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { return 0; }
- (NSUInteger)tileHeight API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { return 0; }
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount {
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:1];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount {
    (void)zpu_metal_render_encoder_draw_primitives(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, vertexStart, vertexCount, instanceCount);
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance {
    (void)baseInstance;
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    ZPUBuffer *zpuIndirectBuffer = (ZPUBuffer *)indirectBuffer;
    if (![zpuIndirectBuffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:zpuIndirectBuffer];
    (void)zpu_metal_render_encoder_draw_primitives_indirect(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, zpuIndirectBuffer->_zpuBuffer, indirectBufferOffset);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:zpuIndexBuffer];
    (void)zpu_metal_render_encoder_draw_indexed_primitives(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount, (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32), zpuIndexBuffer->_zpuBuffer, indexBufferOffset, 1);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:zpuIndexBuffer];
    (void)zpu_metal_render_encoder_draw_indexed_primitives(
        _zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount,
        (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32),
        zpuIndexBuffer->_zpuBuffer, indexBufferOffset, instanceCount);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    (void)baseInstance;
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:zpuIndexBuffer];
    (void)zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(
        _zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount,
        (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32),
        zpuIndexBuffer->_zpuBuffer, indexBufferOffset, instanceCount, (int64_t)baseVertex);
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    ZPUBuffer *zpuIndirectBuffer = (ZPUBuffer *)indirectBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]] || ![zpuIndirectBuffer isKindOfClass:[ZPUBuffer class]]) return;
    [_owner retainResource:zpuIndexBuffer];
    [_owner retainResource:zpuIndirectBuffer];
    (void)zpu_metal_render_encoder_draw_indexed_primitives_indirect(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32), zpuIndexBuffer->_zpuBuffer, indexBufferOffset, zpuIndirectBuffer->_zpuBuffer, indirectBufferOffset);
}
- (void)setTessellationFactorBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset instanceStride:(NSUInteger)instanceStride API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)buffer;
    (void)offset;
    (void)instanceStride;
    [_owner markError];
}
- (void)setTessellationFactorScale:(float)scale API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)scale;
    [_owner markError];
}
- (void)drawPatches:(NSUInteger)numberOfPatchControlPoints patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)numberOfPatchControlPoints;
    (void)patchStart;
    (void)patchCount;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)instanceCount;
    (void)baseInstance;
    [_owner markError];
}
- (void)drawPatches:(NSUInteger)numberOfPatchControlPoints patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(10.12), ios(12.0), tvos(14.5)) {
    (void)numberOfPatchControlPoints;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)indirectBuffer;
    (void)indirectBufferOffset;
    [_owner markError];
}
- (void)drawIndexedPatches:(NSUInteger)numberOfPatchControlPoints patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset controlPointIndexBuffer:(id<MTLBuffer>)controlPointIndexBuffer controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)numberOfPatchControlPoints;
    (void)patchStart;
    (void)patchCount;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)controlPointIndexBuffer;
    (void)controlPointIndexBufferOffset;
    (void)instanceCount;
    (void)baseInstance;
    [_owner markError];
}
- (void)drawIndexedPatches:(NSUInteger)numberOfPatchControlPoints patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset controlPointIndexBuffer:(id<MTLBuffer>)controlPointIndexBuffer controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(10.12), ios(12.0), tvos(14.5)) {
    (void)numberOfPatchControlPoints;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)controlPointIndexBuffer;
    (void)controlPointIndexBufferOffset;
    (void)indirectBuffer;
    (void)indirectBufferOffset;
    [_owner markError];
}
- (void)drawMeshThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup API_AVAILABLE(macos(13.0), ios(16.0), tvos(18.1), visionos(2.1)) {
    (void)threadgroupsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)drawMeshThreads:(MTLSize)threadsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup API_AVAILABLE(macos(13.0), ios(16.0), tvos(18.1), visionos(2.1)) {
    (void)threadsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)drawMeshThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)indirectBuffer;
    (void)indirectBufferOffset;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    [_owner markError];
}
- (void)dispatchThreadsPerTile:(MTLSize)threadsPerTile API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)threadsPerTile;
    [_owner markError];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)length;
    (void)offset;
    (void)index;
    [_owner markError];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange {
    ZPUIndirectCommandBuffer *buffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![buffer isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        executionRange.location > buffer->_maxCommandCount ||
        executionRange.length > buffer->_maxCommandCount - executionRange.location) {
        [_owner markError];
        return;
    }
    for (NSUInteger index = executionRange.location; index < executionRange.location + executionRange.length; ++index) {
        id command = buffer->_commands[index];
        if ([command isKindOfClass:[ZPUIndirectRenderCommand class]]) {
            [(ZPUIndirectRenderCommand *)command executeWithEncoder:self];
        }
    }
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer indirectBuffer:(id<MTLBuffer>)indirectRangeBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    ZPUBuffer *rangeBuffer = (ZPUBuffer *)indirectRangeBuffer;
    if (![rangeBuffer isKindOfClass:[ZPUBuffer class]] ||
        indirectBufferOffset > rangeBuffer.length ||
        rangeBuffer.length - indirectBufferOffset < sizeof(MTLIndirectCommandBufferExecutionRange)) {
        [_owner markError];
        return;
    }
    const uint8_t *bytes = (const uint8_t *)rangeBuffer.contents + indirectBufferOffset;
    const MTLIndirectCommandBufferExecutionRange range = {
        (uint32_t)bytes[0] | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24),
        (uint32_t)bytes[4] | ((uint32_t)bytes[5] << 8) | ((uint32_t)bytes[6] << 16) | ((uint32_t)bytes[7] << 24),
    };
    [self executeCommandsInBuffer:indirectCommandBuffer
                         withRange:NSMakeRange(range.location, range.length)];
}
- (void)sampleCountersInBuffer:(id<MTLCounterSampleBuffer>)sampleBuffer atSampleIndex:(NSUInteger)sampleIndex withBarrier:(BOOL)barrier API_AVAILABLE(macos(10.15), ios(14.0)) {
    (void)barrier;
    ZPUCounterSampleBuffer *sample = (ZPUCounterSampleBuffer *)sampleBuffer;
    if (![sample isKindOfClass:[ZPUCounterSampleBuffer class]] || sample->_owner != [_owner device] ||
        ![sample sampleAtIndex:sampleIndex]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:sample];
}
- (void)setColorAttachmentMap:(MTLLogicalToPhysicalColorAttachmentMap *)mapping API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)mapping;
}
- (void)setColorStoreAction:(MTLStoreAction)storeAction atIndex:(NSUInteger)colorAttachmentIndex {
    (void)storeAction;
    (void)colorAttachmentIndex;
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)colorAttachmentIndex {
    (void)options;
    (void)colorAttachmentIndex;
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction { (void)storeAction; }
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (void)setStencilStoreAction:(MTLStoreAction)storeAction { (void)storeAction; }
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options { (void)options; }
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (void)barrierAfterQueueStages:(MTLStages)afterQueueStages beforeStages:(MTLStages)beforeStages API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)afterQueueStages;
    (void)beforeStages;
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)endEncoding {
    if (_zpuEncoder != NULL) (void)zpu_metal_render_encoder_end_encoding(_zpuEncoder);
}
@end

@implementation ZPUIndirectCommandBuffer
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLIndirectCommandBufferDescriptor *)descriptor maxCommandCount:(NSUInteger)maxCount options:(MTLResourceOptions)options {
    if ((self = [super init])) {
        _owner = owner;
        _maxCommandCount = maxCount;
        _commandTypes = descriptor.commandTypes;
        _resourceOptions = options;
        _storageMode = (MTLStorageMode)((options & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift);
        _cpuCacheMode = (MTLCPUCacheMode)((options & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift);
        _hazardTrackingMode = (MTLHazardTrackingMode)((options & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift);
        _commands = [NSMutableArray arrayWithCapacity:maxCount];
        for (NSUInteger index = 0; index < maxCount; ++index) [_commands addObject:[NSNull null]];
    }
    return self;
}
- (NSString *)label { return nil; }
- (void)setLabel:(NSString *)label { (void)label; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSUInteger)size { return _maxCommandCount * 64; }
- (MTLResourceOptions)resourceOptions { return _resourceOptions; }
- (MTLStorageMode)storageMode { return _storageMode; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCacheMode; }
- (MTLHazardTrackingMode)hazardTrackingMode {
    return zpu_effective_hazard_tracking_mode(_hazardTrackingMode, MTLHazardTrackingModeTracked);
}
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){0}; }
- (NSUInteger)allocatedSize { return [self size]; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (BOOL)isAliasable { return NO; }
- (void)makeAliasable {}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (id<MTLResource>)rootResource { return (id<MTLResource>)self; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (void)resetWithRange:(NSRange)range {
    if (range.location > _maxCommandCount || range.length > _maxCommandCount - range.location) return;
    for (NSUInteger index = range.location; index < range.location + range.length; ++index) {
        id command = _commands[index];
        if ([command isKindOfClass:[ZPUIndirectRenderCommand class]]) [(ZPUIndirectRenderCommand *)command reset];
        if ([command isKindOfClass:[ZPUIndirectComputeCommand class]]) [(ZPUIndirectComputeCommand *)command reset];
    }
}
- (BOOL)copyCommandsFrom:(ZPUIndirectCommandBuffer *)source sourceRange:(NSRange)sourceRange destinationIndex:(NSUInteger)destinationIndex {
    if (source == nil || sourceRange.location > source->_maxCommandCount ||
        sourceRange.length > source->_maxCommandCount - sourceRange.location ||
        destinationIndex > _maxCommandCount || sourceRange.length > _maxCommandCount - destinationIndex) return NO;
    NSArray *commands = [source->_commands subarrayWithRange:sourceRange];
    const MTLIndirectCommandType renderTypes = MTLIndirectCommandTypeDraw | MTLIndirectCommandTypeDrawIndexed;
    const MTLIndirectCommandType computeTypes = MTLIndirectCommandTypeConcurrentDispatch |
        MTLIndirectCommandTypeConcurrentDispatchThreads;
    for (NSUInteger index = 0; index < commands.count; ++index) {
        id command = commands[index];
        if ([command isKindOfClass:[NSNull class]]) {
            _commands[destinationIndex + index] = [NSNull null];
        } else if ([command isKindOfClass:[ZPUIndirectRenderCommand class]]) {
            ZPUIndirectRenderCommand *renderCommand = (ZPUIndirectRenderCommand *)command;
            if ((_commandTypes & renderTypes) == 0 ||
                (renderCommand->_hasDraw && (_commandTypes & MTLIndirectCommandTypeDraw) == 0) ||
                (renderCommand->_hasIndexedDraw && (_commandTypes & MTLIndirectCommandTypeDrawIndexed) == 0)) return NO;
            ZPUIndirectRenderCommand *copy = [[ZPUIndirectRenderCommand alloc] initWithOwner:self];
            copy->_pipelineState = renderCommand->_pipelineState;
            copy->_vertexBuffer = renderCommand->_vertexBuffer;
            copy->_vertexOffset = renderCommand->_vertexOffset;
            copy->_primitiveType = renderCommand->_primitiveType;
            copy->_vertexStart = renderCommand->_vertexStart;
            copy->_vertexCount = renderCommand->_vertexCount;
            copy->_instanceCount = renderCommand->_instanceCount;
            copy->_baseInstance = renderCommand->_baseInstance;
            copy->_hasDraw = renderCommand->_hasDraw;
            copy->_indexBuffer = renderCommand->_indexBuffer;
            copy->_indexCount = renderCommand->_indexCount;
            copy->_indexType = renderCommand->_indexType;
            copy->_indexOffset = renderCommand->_indexOffset;
            copy->_baseVertex = renderCommand->_baseVertex;
            copy->_hasIndexedDraw = renderCommand->_hasIndexedDraw;
            copy->_unsupportedCommand = renderCommand->_unsupportedCommand;
            _commands[destinationIndex + index] = copy;
        } else if ([command isKindOfClass:[ZPUIndirectComputeCommand class]]) {
            ZPUIndirectComputeCommand *computeCommand = (ZPUIndirectComputeCommand *)command;
            if ((_commandTypes & computeTypes) == 0 ||
                (computeCommand->_hasDispatchThreads && (_commandTypes & MTLIndirectCommandTypeConcurrentDispatchThreads) == 0) ||
                (computeCommand->_hasDispatchThreadgroups && (_commandTypes & MTLIndirectCommandTypeConcurrentDispatch) == 0)) return NO;
            ZPUIndirectComputeCommand *copy = [[ZPUIndirectComputeCommand alloc] initWithOwner:self];
            copy->_pipelineState = computeCommand->_pipelineState;
            copy->_kernelBuffer = computeCommand->_kernelBuffer;
            copy->_kernelBufferOffset = computeCommand->_kernelBufferOffset;
            copy->_hasDispatchThreads = computeCommand->_hasDispatchThreads;
            copy->_threadsPerGrid = computeCommand->_threadsPerGrid;
            copy->_threadsPerThreadgroup = computeCommand->_threadsPerThreadgroup;
            copy->_hasDispatchThreadgroups = computeCommand->_hasDispatchThreadgroups;
            copy->_threadgroupsPerGrid = computeCommand->_threadgroupsPerGrid;
            copy->_threadgroupsPerThreadgroup = computeCommand->_threadgroupsPerThreadgroup;
            _commands[destinationIndex + index] = copy;
        } else {
            return NO;
        }
    }
    return YES;
}
- (id<MTLIndirectRenderCommand>)indirectRenderCommandAtIndex:(NSUInteger)commandIndex {
    if (commandIndex >= _maxCommandCount || (_commandTypes & (MTLIndirectCommandTypeDraw | MTLIndirectCommandTypeDrawIndexed)) == 0) return nil;
    id command = _commands[commandIndex];
    if ([command isKindOfClass:[NSNull class]]) {
        command = [[ZPUIndirectRenderCommand alloc] initWithOwner:self];
        _commands[commandIndex] = command;
    }
    return (id<MTLIndirectRenderCommand>)command;
}
- (id<MTLIndirectComputeCommand>)indirectComputeCommandAtIndex:(NSUInteger)commandIndex API_AVAILABLE(macos(11.0), ios(13.0)) {
    const MTLIndirectCommandType computeTypes = MTLIndirectCommandTypeConcurrentDispatch |
        MTLIndirectCommandTypeConcurrentDispatchThreads;
    if (commandIndex >= _maxCommandCount || (_commandTypes & computeTypes) == 0) return nil;
    id command = _commands[commandIndex];
    if ([command isKindOfClass:[NSNull class]]) {
        command = [[ZPUIndirectComputeCommand alloc] initWithOwner:self];
        _commands[commandIndex] = command;
    }
    return (id<MTLIndirectComputeCommand>)command;
}
@end

@implementation ZPUIndirectRenderCommand
- (instancetype)initWithOwner:(ZPUIndirectCommandBuffer *)owner {
    if ((self = [super init])) _owner = owner;
    return self;
}
- (void)reset {
    _pipelineState = nil;
    _vertexBuffer = nil;
    _indexBuffer = nil;
    _vertexOffset = 0;
    _vertexStart = 0;
    _vertexCount = 0;
    _instanceCount = 0;
    _baseInstance = 0;
    _indexCount = 0;
    _indexOffset = 0;
    _baseVertex = 0;
    _hasDraw = NO;
    _hasIndexedDraw = NO;
    _unsupportedCommand = NO;
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    if (pipelineState != nil) _pipelineState = pipelineState;
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index != 0 || ![(id)buffer isKindOfClass:[ZPUBuffer class]]) return;
    _vertexBuffer = (ZPUBuffer *)buffer;
    _vertexOffset = offset;
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    (void)buffer;
    (void)offset;
    (void)index;
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setVertexBuffer:buffer offset:offset atIndex:index];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance {
    _primitiveType = primitiveType;
    _vertexStart = vertexStart;
    _vertexCount = vertexCount;
    _instanceCount = instanceCount;
    _baseInstance = baseInstance;
    _hasDraw = YES;
    _hasIndexedDraw = NO;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    if (![(id)indexBuffer isKindOfClass:[ZPUBuffer class]]) return;
    _primitiveType = primitiveType;
    _indexCount = indexCount;
    _indexType = indexType;
    _indexBuffer = (ZPUBuffer *)indexBuffer;
    _indexOffset = indexBufferOffset;
    _instanceCount = instanceCount;
    _baseVertex = baseVertex;
    _baseInstance = baseInstance;
    _hasIndexedDraw = YES;
    _hasDraw = NO;
}
- (void)setObjectThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)length; (void)index; }
- (void)setObjectBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)buffer; (void)offset; (void)index; }
- (void)setMeshBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)buffer; (void)offset; (void)index; }
- (void)drawPatches:(NSUInteger)numberOfPatchControlPoints patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance tessellationFactorBuffer:(id<MTLBuffer>)buffer tessellationFactorBufferOffset:(NSUInteger)offset tessellationFactorBufferInstanceStride:(NSUInteger)instanceStride API_AVAILABLE(tvos(14.5)) {
    (void)numberOfPatchControlPoints;
    (void)patchStart;
    (void)patchCount;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)instanceCount;
    (void)baseInstance;
    (void)buffer;
    (void)offset;
    (void)instanceStride;
    _unsupportedCommand = YES;
}
- (void)drawIndexedPatches:(NSUInteger)numberOfPatchControlPoints patchStart:(NSUInteger)patchStart patchCount:(NSUInteger)patchCount patchIndexBuffer:(id<MTLBuffer>)patchIndexBuffer patchIndexBufferOffset:(NSUInteger)patchIndexBufferOffset controlPointIndexBuffer:(id<MTLBuffer>)controlPointIndexBuffer controlPointIndexBufferOffset:(NSUInteger)controlPointIndexBufferOffset instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance tessellationFactorBuffer:(id<MTLBuffer>)buffer tessellationFactorBufferOffset:(NSUInteger)offset tessellationFactorBufferInstanceStride:(NSUInteger)instanceStride API_AVAILABLE(tvos(14.5)) {
    (void)numberOfPatchControlPoints;
    (void)patchStart;
    (void)patchCount;
    (void)patchIndexBuffer;
    (void)patchIndexBufferOffset;
    (void)controlPointIndexBuffer;
    (void)controlPointIndexBufferOffset;
    (void)instanceCount;
    (void)baseInstance;
    (void)buffer;
    (void)offset;
    (void)instanceStride;
    _unsupportedCommand = YES;
}
- (void)drawMeshThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {
    (void)threadgroupsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    _unsupportedCommand = YES;
}
- (void)drawMeshThreads:(MTLSize)threadsPerGrid threadsPerObjectThreadgroup:(MTLSize)threadsPerObjectThreadgroup threadsPerMeshThreadgroup:(MTLSize)threadsPerMeshThreadgroup API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {
    (void)threadsPerGrid;
    (void)threadsPerObjectThreadgroup;
    (void)threadsPerMeshThreadgroup;
    _unsupportedCommand = YES;
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)depthStencilState;
    _unsupportedCommand = YES;
}
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)depthBias;
    (void)slopeScale;
    (void)clamp;
    _unsupportedCommand = YES;
}
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)depthClipMode;
    _unsupportedCommand = YES;
}
- (void)setCullMode:(MTLCullMode)cullMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)cullMode;
    _unsupportedCommand = YES;
}
- (void)setFrontFacingWinding:(MTLWinding)frontFacingWinding API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)frontFacingWinding;
    _unsupportedCommand = YES;
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    (void)fillMode;
    _unsupportedCommand = YES;
}
- (void)setBarrier API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {}
- (void)clearBarrier API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {}
- (void)executeWithEncoder:(ZPURenderEncoder *)encoder {
    if (_unsupportedCommand) {
        [encoder->_owner markError];
        return;
    }
    if (_pipelineState != nil) [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)_pipelineState];
    if (_vertexBuffer != nil) [encoder setVertexBuffer:(id<MTLBuffer>)_vertexBuffer offset:_vertexOffset atIndex:0];
    if (_hasDraw) {
        [encoder drawPrimitives:_primitiveType vertexStart:_vertexStart vertexCount:_vertexCount
                    instanceCount:_instanceCount baseInstance:_baseInstance];
    } else if (_hasIndexedDraw) {
        [encoder drawIndexedPrimitives:_primitiveType indexCount:_indexCount indexType:_indexType
                           indexBuffer:(id<MTLBuffer>)_indexBuffer indexBufferOffset:_indexOffset
                        instanceCount:_instanceCount baseVertex:_baseVertex baseInstance:_baseInstance];
    }
}
@end

@implementation ZPUIndirectComputeCommand
- (instancetype)initWithOwner:(ZPUIndirectCommandBuffer *)owner {
    if ((self = [super init])) _owner = owner;
    return self;
}
- (void)reset {
    _pipelineState = nil;
    _kernelBuffer = nil;
    _kernelBufferOffset = 0;
    _hasDispatchThreads = NO;
    _threadsPerGrid = MTLSizeMake(0, 0, 0);
    _threadsPerThreadgroup = MTLSizeMake(0, 0, 0);
    _hasDispatchThreadgroups = NO;
    _threadgroupsPerGrid = MTLSizeMake(0, 0, 0);
    _threadgroupsPerThreadgroup = MTLSizeMake(0, 0, 0);
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipelineState API_AVAILABLE(macos(11.0), ios(13.0)) {
    if ([pipelineState isKindOfClass:[ZPUComputePipelineState class]]) _pipelineState = pipelineState;
}
- (void)setKernelBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index != 0 || ![(id)buffer isKindOfClass:[ZPUBuffer class]]) return;
    _kernelBuffer = (ZPUBuffer *)buffer;
    _kernelBufferOffset = offset;
}
- (void)setKernelBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)stride;
    [self setKernelBuffer:buffer offset:offset atIndex:index];
}
- (void)concurrentDispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    _threadgroupsPerGrid = threadgroupsPerGrid;
    _threadgroupsPerThreadgroup = threadsPerThreadgroup;
    _hasDispatchThreadgroups = YES;
    _hasDispatchThreads = NO;
}
- (void)concurrentDispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    _threadsPerGrid = threadsPerGrid;
    _threadsPerThreadgroup = threadsPerThreadgroup;
    _hasDispatchThreads = YES;
    _hasDispatchThreadgroups = NO;
}
- (void)setBarrier {}
- (void)clearBarrier {}
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height API_AVAILABLE(ios(14.0), macos(11.0)) {
    (void)width;
    (void)height;
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    (void)length;
    (void)index;
}
- (void)setStageInRegion:(MTLRegion)region {
    (void)region;
}
- (void)executeWithEncoder:(ZPUComputeEncoder *)encoder {
    if (_pipelineState != nil) [encoder setComputePipelineState:(id<MTLComputePipelineState>)_pipelineState];
    if (_kernelBuffer != nil) {
        [encoder setBuffer:(id<MTLBuffer>)_kernelBuffer offset:_kernelBufferOffset atIndex:0];
    }
    if (_hasDispatchThreads) {
        [encoder dispatchThreads:_threadsPerGrid threadsPerThreadgroup:_threadsPerThreadgroup];
    } else if (_hasDispatchThreadgroups) {
        [encoder dispatchThreadgroups:_threadgroupsPerGrid threadsPerThreadgroup:_threadgroupsPerThreadgroup];
    }
}
- (void)resetWithRange:(NSRange)range {
    (void)range;
}
@end

id<MTLDevice> ZPUMetalCreateSystemDefaultDevice(void) {
    zpu_metal_device *device = zpu_metal_device_create();
    return device == NULL ? nil : (id<MTLDevice>)[[ZPUDevice alloc] initWithDevice:device];
}

id<MTLFunction> ZPUMetalCreateCPUFunction(id<MTLDevice> device, NSString *name) {
    if (![device isKindOfClass:[ZPUDevice class]] || name == nil) return nil;
    return (id<MTLFunction>)[[ZPUCPUFunction alloc] initWithOwner:(ZPUDevice *)device name:name];
}

MTL4CommitOptions *ZPUMetalCreateCPUCommitOptions(void) API_AVAILABLE(macos(26.0), ios(26.0)) {
    return (MTL4CommitOptions *)[[ZPUMTL4CommitOptions alloc] init];
}

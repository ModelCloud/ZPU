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
#include <math.h>
#include <time.h>

#include "zpu/metal.h"
#include "zpu/metal_apple.h"

@class ZPUDevice;
@class ZPUCommandQueue;
@class ZPUCommandBuffer;
@class ZPUHeap;
@class ZPUDepthStencilState;
@class ZPUSamplerState;
@class ZPUResidencySet;
@class ZPUSharedEvent;
@class ZPUTexture;
@class ZPUTextureViewPool;
@class ZPUIndirectCommandBuffer;
@class ZPUIndirectComputeCommand;
@class ZPUComputeEncoder;
@class ZPUArgumentEncoder;
@class ZPUMTL4CounterHeap;
@class ZPUCounter;
@class ZPUCounterSet;
@class ZPUCounterSampleBuffer;
@class ZPULogState;
@class ZPURenderEncoder;
@class ZPUResourceStateEncoder;
@class ZPULibrary;
@class ZPUBinaryArchive;
@class ZPUMTL4BinaryFunction;
@class ZPUMTL4PipelineDataSetSerializer;
@class ZPUMTL4CompilerTask;
@class ZPUMTL4Compiler;
@class ZPUMTL4Archive;
@class ZPUMTL4CommandAllocator;
@class ZPUMTL4CommandQueue;
@class ZPUMTL4CommandBuffer;
@class ZPUMTL4ArgumentTable;
@class ZPUMTL4ComputeEncoder;
@class ZPUMTL4RenderEncoder;
@class ZPUMTL4MachineLearningEncoder;
@class ZPUIOCommandQueue;

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
    NSUInteger _heapOffset;
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

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUTensor : NSObject <MTLTensor> {
@public
    ZPUDevice *_owner;
    ZPUBuffer *_storageBuffer;
    ZPUBuffer *_backingBuffer;
    NSUInteger _bufferOffset;
    NSUInteger _allocatedSize;
    NSUInteger _elementSize;
    MTLTensorExtents *_dimensions;
    MTLTensorExtents *_strides;
    MTLTensorDataType _dataType;
    MTLTensorUsage _usage;
    MTLResourceOptions _resourceOptions;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    uint64_t _resourceID;
    NSString *_label;
    BOOL _aliasable;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner storageBuffer:(ZPUBuffer *)storageBuffer
                 backingBuffer:(ZPUBuffer *)backingBuffer bufferOffset:(NSUInteger)bufferOffset
                    dimensions:(MTLTensorExtents *)dimensions strides:(MTLTensorExtents *)strides
                       dataType:(MTLTensorDataType)dataType usage:(MTLTensorUsage)usage
                resourceOptions:(MTLResourceOptions)resourceOptions allocatedSize:(NSUInteger)allocatedSize;
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
    NSUInteger _heapOffset;
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
    NSArray *_mipmapTextures;
    NSArray *_sliceMipmapTextures;
    NSUInteger _depth;
    NSUInteger _baseMipmapLevel;
    NSUInteger _baseSlice;
    BOOL _shareable;
    NSString *_label;
    BOOL _aliasable;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backing:(ZPUTexture *)backing;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat backingBuffer:(ZPUBuffer *)backingBuffer offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat heap:(ZPUHeap *)heap;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat mipmapTextures:(NSArray *)mipmapTextures;
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat mipmapSlices:(NSArray *)mipmapSlices;
- (zpu_metal_texture *)zpuTextureAtLevel:(NSUInteger)level;
- (zpu_metal_texture *)zpuTextureAtLevel:(NSUInteger)level slice:(NSUInteger)slice;
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
    NSString *_label;
    MTLHeapType _type;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner heap:(zpu_metal_heap *)heap descriptor:(MTLHeapDescriptor *)descriptor;
- (id<MTLTexture>)zpuNewTextureWithDescriptor:(MTLTextureDescriptor *)descriptor firstOffset:(NSUInteger)offset explicitOffset:(BOOL)explicitOffset;
@end

API_AVAILABLE(macos(15.0), ios(18.0))
@interface ZPUResidencySet : NSObject <MTLResidencySet> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSMutableArray *_allocations;
    uint64_t _committedAllocatedSize;
    BOOL _resident;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLResidencySetDescriptor *)descriptor;
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
    ZPUBuffer *_fragmentBuffer;
    NSUInteger _fragmentOffset;
    ZPUDepthStencilState *_depthStencilState;
    float _depthBias;
    float _slopeScale;
    float _depthBiasClamp;
    MTLDepthClipMode _depthClipMode;
    MTLCullMode _cullMode;
    MTLWinding _frontFacingWinding;
    MTLTriangleFillMode _triangleFillMode;
    BOOL _hasFragmentBuffer;
    BOOL _hasDepthStencilState;
    BOOL _hasDepthBias;
    BOOL _hasDepthClipMode;
    BOOL _hasCullMode;
    BOOL _hasFrontFacingWinding;
    BOOL _hasTriangleFillMode;
    BOOL _hasVertexBuffer;
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
    BOOL _unsupportedCommand;
}
- (instancetype)initWithOwner:(ZPUIndirectCommandBuffer *)owner;
- (void)reset;
- (void)executeWithEncoder:(ZPUComputeEncoder *)encoder;
@end

@interface ZPUIndirectCommandBuffer : NSObject <MTLIndirectCommandBuffer> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSUInteger _maxCommandCount;
    MTLIndirectCommandType _commandTypes;
    MTLResourceOptions _resourceOptions;
    MTLStorageMode _storageMode;
    MTLCPUCacheMode _cpuCacheMode;
    MTLHazardTrackingMode _hazardTrackingMode;
    BOOL _inheritPipelineState;
    BOOL _inheritBuffers;
    NSUInteger _maxVertexBufferBindCount;
    NSUInteger _maxFragmentBufferBindCount;
    NSUInteger _maxKernelBufferBindCount;
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
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner event:(zpu_metal_shared_event *)event;
@end

@interface ZPUSharedEventHandle : MTLSharedEventHandle {
@public
    ZPUSharedEvent *_event;
    NSString *_label;
}
- (instancetype)initWithEvent:(ZPUSharedEvent *)event;
@end

@interface ZPUSharedTextureHandle : MTLSharedTextureHandle {
@public
    ZPUTexture *_texture;
    NSString *_label;
}
- (instancetype)initWithTexture:(ZPUTexture *)texture;
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

/* Reflection is limited to the fixed CPU profiles. These objects describe
 * binding metadata only; they do not expose an MSL compiler or native Metal
 * reflection state. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
@interface ZPUArgument : MTLArgument {
@public
    NSString *_name;
    MTLArgumentType _type;
    MTLBindingAccess _access;
    NSUInteger _index;
    BOOL _active;
    NSUInteger _bufferAlignment;
    NSUInteger _bufferDataSize;
    MTLDataType _bufferDataType;
    MTLTextureType _textureType;
    MTLDataType _textureDataType;
    BOOL _depthTexture;
    NSUInteger _arrayLength;
}
- (instancetype)initWithName:(NSString *)name type:(MTLArgumentType)type
                       access:(MTLBindingAccess)access index:(NSUInteger)index;
- (void)setBufferDataSize:(NSUInteger)size dataType:(MTLDataType)dataType;
- (void)setTextureType:(MTLTextureType)textureType dataType:(MTLDataType)dataType arrayLength:(NSUInteger)arrayLength;
@end

API_AVAILABLE(macos(13.0), ios(16.0))
@interface ZPUBinding : NSObject <MTLBinding, MTLBufferBinding, MTLTextureBinding> {
@public
    NSString *_name;
    MTLBindingType _type;
    MTLBindingAccess _access;
    NSUInteger _index;
    NSUInteger _bufferAlignment;
    NSUInteger _bufferDataSize;
    MTLDataType _bufferDataType;
    MTLTextureType _textureType;
    MTLDataType _textureDataType;
    BOOL _depthTexture;
    NSUInteger _arrayLength;
}
- (instancetype)initWithName:(NSString *)name type:(MTLBindingType)type
                       access:(MTLBindingAccess)access index:(NSUInteger)index;
- (void)setBufferDataSize:(NSUInteger)size dataType:(MTLDataType)dataType;
- (void)setTextureType:(MTLTextureType)textureType dataType:(MTLDataType)dataType arrayLength:(NSUInteger)arrayLength;
@end

API_AVAILABLE(macos(10.11), ios(8.0))
@interface ZPUComputePipelineReflection : MTLComputePipelineReflection {
@public
    NSArray *_arguments;
    NSArray *_bindings;
}
- (instancetype)initWithArguments:(NSArray *)arguments bindings:(NSArray *)bindings;
@end

API_AVAILABLE(macos(10.11), ios(8.0))
@interface ZPURenderPipelineReflection : MTLRenderPipelineReflection {
@public
    NSArray *_vertexArguments;
    NSArray *_fragmentArguments;
    NSArray *_vertexBindings;
    NSArray *_fragmentBindings;
}
- (instancetype)initWithVertexArguments:(NSArray *)vertexArguments
                        fragmentArguments:(NSArray *)fragmentArguments
                           vertexBindings:(NSArray *)vertexBindings
                         fragmentBindings:(NSArray *)fragmentBindings;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUFunctionReflection : MTLFunctionReflection {
@public
    NSArray *_bindings;
    NSString *_userAnnotation;
}
- (instancetype)initWithBindings:(NSArray *)bindings userAnnotation:(NSString *)userAnnotation;
@end

@interface ZPURenderPipelineState : NSObject <MTLRenderPipelineState> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    MTLPixelFormat _colorPixelFormat;
    MTLPixelFormat _colorPixelFormats[ZPU_METAL_MAX_COLOR_ATTACHMENTS];
    NSUInteger _colorAttachmentCount;
    BOOL _multiTargetOutput;
    BOOL _rasterizationEnabled;
    BOOL _supportsIndirectCommandBuffers;
    BOOL _fragmentUniform;
    MTLPixelFormat _depthPixelFormat;
    MTLPixelFormat _stencilPixelFormat;
    BOOL _sampleTexture;
    BOOL _blendingEnabled;
    MTLBlendFactor _sourceRGBBlendFactor;
    MTLBlendFactor _destinationRGBBlendFactor;
    MTLBlendOperation _rgbBlendOperation;
    MTLBlendFactor _sourceAlphaBlendFactor;
    MTLBlendFactor _destinationAlphaBlendFactor;
    MTLBlendOperation _alphaBlendOperation;
    MTLColorWriteMask _writeMask;
    NSString *_vertexFunctionName;
    NSString *_fragmentFunctionName;
    MTLRenderPipelineReflection *_reflection;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRenderPipelineDescriptor *)descriptor;
@end

@interface ZPUDepthStencilState : NSObject <MTLDepthStencilState> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    MTLCompareFunction _depthCompareFunction;
    BOOL _depthWriteEnabled;
    MTLCompareFunction _frontStencilCompareFunction;
    MTLStencilOperation _frontStencilFailureOperation;
    MTLStencilOperation _frontDepthFailureOperation;
    MTLStencilOperation _frontDepthStencilPassOperation;
    uint32_t _frontStencilReadMask;
    uint32_t _frontStencilWriteMask;
    MTLCompareFunction _backStencilCompareFunction;
    MTLStencilOperation _backStencilFailureOperation;
    MTLStencilOperation _backDepthFailureOperation;
    MTLStencilOperation _backDepthStencilPassOperation;
    uint32_t _backStencilReadMask;
    uint32_t _backStencilWriteMask;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLDepthStencilDescriptor *)descriptor;
@end

@interface ZPUSamplerState : NSObject <MTLSamplerState> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    MTLSamplerMinMagFilter _minFilter;
    MTLSamplerMinMagFilter _magFilter;
    MTLSamplerMipFilter _mipFilter;
    MTLSamplerAddressMode _sAddressMode;
    MTLSamplerAddressMode _tAddressMode;
    uint64_t _resourceID;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLSamplerDescriptor *)descriptor;
@end

/* The CPU rasterizer is intentionally 1:1. Keep rasterization-rate maps
 * exact by accepting only identity maps; a variable-rate map cannot be
 * represented by the fixed pixel grid without changing observable pixels. */
@interface ZPURasterizationRateMap : NSObject <MTLRasterizationRateMap> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    MTLSize _screenSize;
    MTLSize _physicalGranularity;
    NSUInteger _layerCount;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRasterizationRateMapDescriptor *)descriptor;
@end

/* Metal I/O is represented by CPU-owned file data and ordered operations.
 * Committing an I/O buffer executes its operations synchronously against ZPU
 * buffers/textures; no native MTL resource or command encoder is involved. */
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(13.0), ios(16.0))
@interface ZPUIOFileHandle : NSObject <MTLIOFileHandle> {
@public
    ZPUDevice *_owner;
    NSData *_data;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner url:(NSURL *)url error:(NSError **)error;
@end

typedef BOOL (^ZPUIOOperationBlock)(NSError **error);

API_AVAILABLE(macos(13.0), ios(16.0))
@interface ZPUIOCommandBuffer : NSObject <MTLIOCommandBuffer> {
@public
    ZPUIOCommandQueue *_owner;
    NSMutableArray *_operations;
    NSMutableArray *_statusTargets;
    NSMutableArray *_completedHandlers;
    MTLIOStatus _status;
    NSError *_error;
    NSString *_label;
    BOOL _committed;
    BOOL _cancelRequested;
}
- (instancetype)initWithOwner:(ZPUIOCommandQueue *)owner;
- (void)addOperation:(ZPUIOOperationBlock)operation;
- (void)addFailure:(NSString *)message;
@end

API_AVAILABLE(macos(13.0), ios(16.0))
@interface ZPUIOCommandQueue : NSObject <MTLIOCommandQueue> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    NSUInteger _maxCommandBufferCount;
    MTLIOPriority _priority;
    MTLIOCommandQueueType _type;
    NSUInteger _maxCommandsInFlight;
    id<MTLIOScratchBufferAllocator> _scratchBufferAllocator;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLIOCommandQueueDescriptor *)descriptor;
@end
#pragma clang diagnostic pop

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

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"
API_AVAILABLE(macos(15.0), ios(18.0))
@interface ZPULogState : NSObject <MTLLogState> {
@public
    MTLLogLevel _level;
    NSInteger _bufferSize;
    NSMutableArray *_handlers;
}
- (instancetype)initWithDescriptor:(MTLLogStateDescriptor *)descriptor error:(NSError **)error;
@end
#pragma clang diagnostic pop

@interface ZPUDevice : NSObject <MTLDevice> {
@public
    zpu_metal_device *_zpuDevice;
    NSArray *_counterSets;
    NSHashTable *_heaps;
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
    NSMutableSet *_residencySets;
    BOOL _failed;
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

/* Metal 4 exposes machine-learning encoding as a separate command-encoder
 * family. ZPU does not have a CPU implementation for arbitrary ML pipeline
 * graphs yet, so the object is still CPU-owned but every operation that would
 * execute a graph fails closed on the owning command buffer. Returning an
 * object here is important: selector discovery and encoder lifetime must not
 * depend on Apple's native Metal runtime. */
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4MachineLearningEncoder : NSObject <MTL4MachineLearningCommandEncoder> {
@public
    ZPUMTL4CommandBuffer *_owner;
    id<MTL4MachineLearningPipelineState> _pipelineState;
    ZPUMTL4ArgumentTable *_argumentTable;
    NSString *_label;
    BOOL _ended;
}
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner;
@end

#pragma clang diagnostic pop

@interface ZPUCPUFunction : NSObject <MTLFunction> {
@public
    ZPUDevice *_owner;
    NSString *_name;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name;
@end

@interface ZPUFunctionHandle : NSObject <MTLFunctionHandle> {
@public
    ZPUDevice *_owner;
    NSString *_name;
    MTLFunctionType _functionType;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name
                  functionType:(MTLFunctionType)functionType;
@end

/* Function tables are CPU-side resource metadata. They retain only ZPU-owned
 * handles/resources and never expose a native Metal allocation. */
@interface ZPUVisibleFunctionTable : NSObject <MTLVisibleFunctionTable> {
@public
    ZPUDevice *_owner;
    NSUInteger _functionCount;
    MTLRenderStages _stage;
    NSMutableArray *_functions;
    NSString *_label;
    uint64_t _resourceID;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner functionCount:(NSUInteger)functionCount stage:(MTLRenderStages)stage;
@end

@interface ZPUIntersectionFunctionTable : NSObject <MTLIntersectionFunctionTable> {
@public
    ZPUDevice *_owner;
    NSUInteger _functionCount;
    NSMutableArray *_buffers;
    NSMutableData *_bufferOffsets;
    NSMutableArray *_functions;
    NSMutableData *_opaqueSignatures;
    NSMutableArray *_visibleTables;
    NSString *_label;
    uint64_t _resourceID;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner functionCount:(NSUInteger)functionCount;
@end

/* A library is a CPU-side name table for registered ZPU kernels and fixed
 * CPU render profiles. It never contains an Apple MTLLibrary or compiled MSL. */
@interface ZPULibrary : NSObject <MTLLibrary> {
@public
    ZPUDevice *_owner;
    NSArray *_functionNames;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner source:(NSString *)source;
@end

/* A binary archive is a deterministic CPU metadata cache. It stores names of
 * registered ZPU functions, never Apple's compiled shader binaries. */
@interface ZPUBinaryArchive : NSObject <MTLBinaryArchive> {
@public
    ZPUDevice *_owner;
    NSMutableSet *_functionNames;
    NSURL *_sourceURL;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLBinaryArchiveDescriptor *)descriptor error:(NSError **)error;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

/* Metal 4 compiler objects are CPU-side metadata adapters. They can describe
 * and instantiate registered ZPU compute kernels, but never invoke Apple's
 * MSL compiler or produce a native GPU binary. */
API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4PipelineDataSetSerializer : NSObject <MTL4PipelineDataSetSerializer> {
@public
    ZPUDevice *_owner;
    MTL4PipelineDataSetSerializerConfiguration _configuration;
    NSMutableSet *_functionNames;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4PipelineDataSetSerializerDescriptor *)descriptor;
- (void)recordFunctionName:(NSString *)name;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4BinaryFunction : NSObject <MTL4BinaryFunction> {
@public
    ZPUDevice *_owner;
    NSString *_name;
    MTLFunctionType _functionType;
    MTL4BinaryFunctionOptions _options;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name
                  functionType:(MTLFunctionType)functionType options:(MTL4BinaryFunctionOptions)options;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4CompilerTask : NSObject <MTL4CompilerTask> {
@public
    id<MTL4Compiler> _compiler;
}
- (instancetype)initWithCompiler:(id<MTL4Compiler>)compiler;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4Compiler : NSObject <MTL4Compiler> {
@public
    ZPUDevice *_owner;
    NSString *_label;
    id<MTL4PipelineDataSetSerializer> _pipelineDataSetSerializer;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CompilerDescriptor *)descriptor;
@end

API_AVAILABLE(macos(26.0), ios(26.0))
@interface ZPUMTL4Archive : NSObject <MTL4Archive> {
@public
    ZPUDevice *_owner;
    NSMutableSet *_functionNames;
    NSURL *_sourceURL;
    NSString *_label;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner url:(NSURL *)url error:(NSError **)error;
@end

#pragma clang diagnostic pop

@interface ZPUCommandQueue : NSObject <MTLCommandQueue> {
@public
    zpu_metal_command_queue *_zpuQueue;
    ZPUDevice *_owner;
    NSString *_label;
    NSMutableSet *_residencySets;
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
    BOOL _scheduled;
}
- (instancetype)initWithOwner:(ZPUCommandQueue *)owner commandBuffer:(zpu_metal_command_buffer *)commandBuffer;
- (void)retainResource:(id)resource;
- (void)markError;
@end

@interface ZPUComputePipelineState : NSObject <MTLComputePipelineState> {
@public
    ZPUDevice *_owner;
    zpu_metal_compute_kernel _kernel;
    NSUInteger _maxTotalThreadsPerThreadgroup;
    MTLSize _requiredThreadsPerThreadgroup;
    BOOL _supportsIndirectCommandBuffers;
    MTLComputePipelineReflection *_reflection;
}
- (instancetype)initWithOwner:(ZPUDevice *)owner function:(id<MTLFunction>)function error:(NSError **)error;
@end

@interface ZPUComputeEncoder : NSObject <MTLComputeCommandEncoder> {
@public
    zpu_metal_compute_encoder *_zpuEncoder;
    ZPUCommandBuffer *_owner;
    NSString *_label;
    MTLDispatchType _dispatchType;
    zpu_metal_compute_kernel _kernel;
    ZPUTexture *_boundTexture;
    NSUInteger _boundTextureIndex;
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
    NSString *_label;
    ZPUBuffer *_vertexBuffer;
    ZPUTexture *_fragmentTexture;
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
    NSString *_label;
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
    NSString *_label;
    ZPUTexture *_texture;
    zpu_metal_texture *_renderTexture;
    zpu_metal_texture *_depthTexture;
    zpu_metal_texture *_stencilTexture;
    zpu_metal_load_action _stencilLoadAction;
    zpu_metal_store_action _stencilStoreAction;
    uint8_t _stencilClearValue;
    zpu_metal_render_pass_descriptor _pass;
    MTLRenderPassDescriptor *_descriptor;
    NSUInteger _childCount;
}
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner texture:(ZPUTexture *)texture renderTexture:(zpu_metal_texture *)renderTexture depthTexture:(zpu_metal_texture *)depthTexture stencilTexture:(zpu_metal_texture *)stencilTexture stencilLoadAction:(zpu_metal_load_action)stencilLoadAction stencilStoreAction:(zpu_metal_store_action)stencilStoreAction stencilClearValue:(uint8_t)stencilClearValue pass:(zpu_metal_render_pass_descriptor)pass descriptor:(MTLRenderPassDescriptor *)descriptor;
@end

static BOOL zpu_u32(NSUInteger value, uint32_t *result) {
    if (value > UINT32_MAX) return NO;
    *result = (uint32_t)value;
    return YES;
}

static BOOL zpu_metal_size_fits_cpu_threadgroup(MTLSize size, NSUInteger maxTotalThreads) {
    if (size.width == 0 || size.height == 0 || size.depth == 0 ||
        size.width > UINT32_MAX || size.height > UINT32_MAX || size.depth > UINT32_MAX ||
        maxTotalThreads == 0) return NO;
    const uint64_t area = (uint64_t)size.width * (uint64_t)size.height;
    const uint64_t maximum = (uint64_t)maxTotalThreads;
    return area <= maximum && area <= UINT64_MAX / (uint64_t)size.depth &&
        area * (uint64_t)size.depth <= maximum;
}

static BOOL zpu_metal_indirect_primitive_supported(MTLPrimitiveType primitiveType) {
    switch (primitiveType) {
        case MTLPrimitiveTypePoint:
        case MTLPrimitiveTypeLine:
        case MTLPrimitiveTypeLineStrip:
        case MTLPrimitiveTypeTriangle:
        case MTLPrimitiveTypeTriangleStrip:
            return YES;
        default:
            return NO;
    }
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
    if (format == MTLPixelFormatR32Float) return ZPU_METAL_R32_FLOAT;
    if (format == MTLPixelFormatRGBA16Float) return ZPU_METAL_RGBA16_FLOAT;
    if (format == MTLPixelFormatDepth32Float) return ZPU_METAL_DEPTH32_FLOAT;
    if (format == MTLPixelFormatStencil8) return ZPU_METAL_STENCIL8;
    return ZPU_METAL_RGBA8_UNORM;
}

static NSUInteger zpu_texture_bytes_per_pixel(MTLPixelFormat format) {
    if (format == MTLPixelFormatStencil8) return 1;
    if (format == MTLPixelFormatRGBA16Float) return 8;
    return 4;
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

static BOOL zpu_store_action_supported(MTLStoreAction action) {
    return action == MTLStoreActionDontCare || action == MTLStoreActionStore;
}

static void zpu_set_error(NSError **error, NSString *description) {
    if (error != NULL) {
        *error = [NSError errorWithDomain:@"ZPUMetal" code:ZPU_METAL_INVALID_ARGUMENT
                                userInfo:@{NSLocalizedDescriptionKey: description}];
    }
}

static BOOL zpu_render_pipeline_format_supported(MTLPixelFormat format) {
    return format == MTLPixelFormatInvalid || format == MTLPixelFormatRGBA8Unorm ||
        format == MTLPixelFormatBGRA8Unorm || format == MTLPixelFormatR32Float ||
        format == MTLPixelFormatRGBA16Float;
}

static BOOL zpu_depth_format_supported(MTLPixelFormat format) {
    return format == MTLPixelFormatInvalid || format == MTLPixelFormatDepth32Float;
}

static BOOL zpu_stencil_format_supported(MTLPixelFormat format) {
    return format == MTLPixelFormatInvalid || format == MTLPixelFormatStencil8;
}

static BOOL zpu_render_texture_type_supported(MTLTextureType type);

/* Metal permits a render pass with only depth/stencil attachments.  The
 * portable runtime keeps one color surface in its command ABI, so a missing
 * color attachment is represented by a private, discarded RGBA8 surface.
 * This surface is never exposed to the caller and is only a CPU raster
 * target; depth/stencil bytes remain the public resources being tested. */
static ZPUTexture *zpu_hidden_color_target(ZPUDevice *owner, ZPUTexture *attachment,
                                           NSUInteger level, NSUInteger slice) {
    if (owner == nil || attachment == nil ||
        (attachment->_pixelFormat != MTLPixelFormatDepth32Float && attachment->_pixelFormat != MTLPixelFormatStencil8) ||
        !zpu_render_texture_type_supported(attachment->_textureType)) return nil;
    zpu_metal_texture *attachmentTexture = [attachment zpuTextureAtLevel:level slice:slice];
    if (attachmentTexture == NULL) return nil;
    const NSUInteger width = zpu_metal_texture_width(attachmentTexture);
    const NSUInteger height = zpu_metal_texture_height(attachmentTexture);
    if (width == 0 || height == 0) return nil;
    MTLTextureDescriptor *descriptor =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                            width:width height:height mipmapped:NO];
    descriptor.storageMode = MTLStorageModeShared;
    descriptor.usage = MTLTextureUsageRenderTarget;
    return (ZPUTexture *)[owner newTextureWithDescriptor:descriptor];
}

static BOOL zpu_configure_additional_color_attachments(ZPUCommandBuffer *owner,
                                                        zpu_metal_render_encoder *encoder,
                                                        MTLRenderPassDescriptor *descriptor) {
    if (owner == nil || encoder == NULL || descriptor == nil) return NO;
    for (uint32_t index = 1; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        MTLRenderPassColorAttachmentDescriptor *attachment = descriptor.colorAttachments[index];
        ZPUTexture *texture = (ZPUTexture *)attachment.texture;
        if (texture == nil) continue;
        if (![texture isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(texture->_textureType) ||
            !zpu_render_pipeline_format_supported(texture->_pixelFormat) ||
            !zpu_store_action_supported(attachment.storeAction)) return NO;
        zpu_metal_texture *zpuTexture = [texture zpuTextureAtLevel:attachment.level slice:attachment.slice];
        if (zpuTexture == NULL) return NO;
        const zpu_metal_render_pass_color_attachment_descriptor pass = {
            .load_action = zpu_load_action(attachment.loadAction),
            .store_action = zpu_store_action(attachment.storeAction),
            .clear_color = {
                (float)attachment.clearColor.red,
                (float)attachment.clearColor.green,
                (float)attachment.clearColor.blue,
                (float)attachment.clearColor.alpha,
            },
        };
        if (zpu_metal_render_encoder_set_color_attachment(encoder, zpuTexture, &pass, index) != ZPU_METAL_OK) return NO;
        [owner retainResource:texture];
    }
    return YES;
}

API_AVAILABLE(macos(26.0), ios(26.0))
static BOOL zpu_configure_additional_metal4_color_attachments(ZPUCommandBuffer *owner,
                                                               zpu_metal_render_encoder *encoder,
                                                               MTL4RenderPassDescriptor *descriptor) {
    if (owner == nil || encoder == NULL || descriptor == nil) return NO;
    for (uint32_t index = 1; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        id attachment = descriptor.colorAttachments[index];
        ZPUTexture *texture = (ZPUTexture *)[attachment texture];
        if (texture == nil) continue;
        if (![texture isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(texture->_textureType) ||
            !zpu_render_pipeline_format_supported(texture->_pixelFormat) ||
            !zpu_store_action_supported([attachment storeAction])) return NO;
        zpu_metal_texture *zpuTexture = [texture zpuTextureAtLevel:[attachment level] slice:[attachment slice]];
        if (zpuTexture == NULL) return NO;
        const zpu_metal_render_pass_color_attachment_descriptor pass = {
            .load_action = zpu_load_action([attachment loadAction]),
            .store_action = zpu_store_action([attachment storeAction]),
            .clear_color = {
                (float)[attachment clearColor].red,
                (float)[attachment clearColor].green,
                (float)[attachment clearColor].blue,
                (float)[attachment clearColor].alpha,
            },
        };
        if (zpu_metal_render_encoder_set_color_attachment(encoder, zpuTexture, &pass, index) != ZPU_METAL_OK) return NO;
        [owner retainResource:texture];
    }
    return YES;
}

static BOOL zpu_configure_visibility_result(ZPUCommandBuffer *owner,
                                             zpu_metal_render_encoder *encoder,
                                             id<MTLBuffer> buffer,
                                             uint8_t resultType) {
    if (owner == nil || encoder == NULL) return NO;
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (zpuBuffer != nil && (![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
                              zpuBuffer->_owner != owner->_owner->_owner)) return NO;
    if (zpu_metal_render_encoder_set_visibility_result_buffer(
            encoder, zpuBuffer == nil ? NULL : zpuBuffer->_zpuBuffer) != ZPU_METAL_OK ||
        zpu_metal_render_encoder_set_visibility_result_type(encoder, (uint8_t)resultType) != ZPU_METAL_OK) return NO;
    if (zpuBuffer != nil) [owner retainResource:zpuBuffer];
    return YES;
}

static uint8_t zpu_visibility_result_type(MTLRenderPassDescriptor *descriptor) {
    if (descriptor != nil) {
        if (@available(macOS 26.0, iOS 26.0, *)) {
            return (uint8_t)descriptor.visibilityResultType;
        }
    }
    return ZPU_METAL_VISIBILITY_RESET;
}

static BOOL zpu_texture_type_is_1d(MTLTextureType type) {
    return type == MTLTextureType1D || type == MTLTextureType1DArray;
}

static BOOL zpu_texture_type_is_3d(MTLTextureType type) {
    return type == MTLTextureType3D;
}

static BOOL zpu_texture_type_is_array(MTLTextureType type) {
    return type == MTLTextureType1DArray || type == MTLTextureType2DArray;
}

static BOOL zpu_texture_type_is_supported(MTLTextureType type) {
    return type == MTLTextureType1D || type == MTLTextureType1DArray ||
        type == MTLTextureType2D || type == MTLTextureType2DArray || type == MTLTextureType3D;
}

static BOOL zpu_render_texture_type_supported(MTLTextureType type) {
    return type == MTLTextureType2D || type == MTLTextureType2DArray;
}

static NSUInteger zpu_texture_depth_at_level(ZPUTexture *texture, NSUInteger level) {
    if (texture == nil || !zpu_texture_type_is_3d(texture->_textureType) || level >= texture->_mipmapTextures.count) return 0;
    NSUInteger depth = texture->_depth;
    for (NSUInteger index = 0; index < level; ++index) depth = depth > 1 ? depth / 2 : 1;
    return depth;
}

static BOOL zpu_texture_descriptor_size(MTLTextureDescriptor *descriptor, NSUInteger *size) {
    if (descriptor == nil || size == NULL ||
        !zpu_texture_type_is_supported(descriptor.textureType) ||
        descriptor.arrayLength == 0 ||
        (zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth == 0 : descriptor.depth != 1) ||
        (!zpu_texture_type_is_array(descriptor.textureType) && descriptor.arrayLength != 1) ||
        (zpu_texture_type_is_1d(descriptor.textureType) && descriptor.height != 1) ||
        descriptor.mipmapLevelCount == 0 || descriptor.sampleCount != 1 ||
        descriptor.width > UINT32_MAX || descriptor.height > UINT32_MAX ||
        (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm &&
         descriptor.pixelFormat != MTLPixelFormatR32Float && descriptor.pixelFormat != MTLPixelFormatRGBA16Float &&
         descriptor.pixelFormat != MTLPixelFormatDepth32Float && descriptor.pixelFormat != MTLPixelFormatStencil8)) return NO;
    NSUInteger total = 0;
    const NSUInteger sliceCount = zpu_texture_type_is_3d(descriptor.textureType) ? 1 : descriptor.arrayLength;
    for (NSUInteger slice = 0; slice < sliceCount; ++slice) {
        (void)slice;
        NSUInteger width = descriptor.width;
        NSUInteger height = zpu_texture_type_is_1d(descriptor.textureType) ? 1 : descriptor.height;
        NSUInteger depth = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : 1;
        for (NSUInteger level = 0; level < descriptor.mipmapLevelCount; ++level) {
            const NSUInteger bytesPerPixel = zpu_texture_bytes_per_pixel(descriptor.pixelFormat);
            if (width > SIZE_MAX / bytesPerPixel) return NO;
            const NSUInteger rowBytes = width * bytesPerPixel;
            if (height != 0 && rowBytes > SIZE_MAX / height) return NO;
            const NSUInteger levelRows = rowBytes * height;
            if (depth != 0 && levelRows > SIZE_MAX / depth) return NO;
            const NSUInteger levelSize = levelRows * depth;
            if (levelSize > SIZE_MAX - total) return NO;
            total += levelSize;
            width = width > 1 ? width / 2 : 1;
            height = height > 1 ? height / 2 : 1;
            depth = depth > 1 ? depth / 2 : 1;
        }
        if (total == SIZE_MAX) return NO;
    }
    *size = total;
    return YES;
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

static void zpu_add_allocated_size(NSUInteger value, NSUInteger *total) {
    if (value > SIZE_MAX - *total) *total = SIZE_MAX;
    else *total += value;
}

static BOOL zpu_metal4_region(MTLOrigin origin, MTLSize size, zpu_metal_region *result) {
    const MTLRegion region = {origin, size};
    if (!zpu_region_fits(region)) return NO;
    *result = zpu_region(region);
    return YES;
}

API_AVAILABLE(macos(26.0), ios(26.0))
static BOOL zpu_metal4_render_pass_descriptor(ZPUDevice *owner,
                                                MTL4RenderPassDescriptor *descriptor,
                                                ZPUTexture **color_texture,
                                                ZPUTexture **depth_texture,
                                                ZPUTexture **stencil_texture,
                                                zpu_metal_render_pass_descriptor *pass) {
    if (descriptor == nil || color_texture == NULL || depth_texture == NULL || stencil_texture == NULL || pass == NULL) return NO;
    ZPUTexture *color = (ZPUTexture *)descriptor.colorAttachments[0].texture;
    const BOOL hasColor = color != nil;
    if (!hasColor) {
        ZPUTexture *depthCandidate = (ZPUTexture *)descriptor.depthAttachment.texture;
        ZPUTexture *stencilCandidate = (ZPUTexture *)descriptor.stencilAttachment.texture;
        color = zpu_hidden_color_target(owner,
                                        depthCandidate != nil ? depthCandidate : stencilCandidate,
                                        depthCandidate != nil ? descriptor.depthAttachment.level : descriptor.stencilAttachment.level,
                                        depthCandidate != nil ? descriptor.depthAttachment.slice : descriptor.stencilAttachment.slice);
        if (color == nil) return NO;
    }
    if (![color isKindOfClass:[ZPUTexture class]] ||
        !zpu_render_texture_type_supported(color->_textureType) ||
        !zpu_render_pipeline_format_supported(hasColor ? color->_pixelFormat : MTLPixelFormatRGBA8Unorm)) return NO;
    zpu_metal_texture *colorTexture = [color zpuTextureAtLevel:hasColor ? descriptor.colorAttachments[0].level : 0
                                                          slice:hasColor ? descriptor.colorAttachments[0].slice : 0];
    if (colorTexture == NULL) return NO;
    if (descriptor.renderTargetArrayLength > 1 || descriptor.defaultRasterSampleCount > 1 ||
        (descriptor.renderTargetWidth != 0 && descriptor.renderTargetWidth != zpu_metal_texture_width(colorTexture)) ||
        (descriptor.renderTargetHeight != 0 && descriptor.renderTargetHeight != zpu_metal_texture_height(colorTexture))) return NO;
    if (hasColor && !zpu_store_action_supported(descriptor.colorAttachments[0].storeAction)) return NO;
    *pass = (zpu_metal_render_pass_descriptor){
        .color = {
            .load_action = hasColor ? zpu_load_action(descriptor.colorAttachments[0].loadAction) : ZPU_METAL_LOAD_DONT_CARE,
            .store_action = hasColor ? zpu_store_action(descriptor.colorAttachments[0].storeAction) : ZPU_METAL_STORE_DONT_CARE,
            .clear_color = {
                hasColor ? (float)descriptor.colorAttachments[0].clearColor.red : 0.0f,
                hasColor ? (float)descriptor.colorAttachments[0].clearColor.green : 0.0f,
                hasColor ? (float)descriptor.colorAttachments[0].clearColor.blue : 0.0f,
                hasColor ? (float)descriptor.colorAttachments[0].clearColor.alpha : 0.0f,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
    if (depth != nil) {
        if (![depth isKindOfClass:[ZPUTexture class]] || depth->_pixelFormat != MTLPixelFormatDepth32Float ||
            !zpu_store_action_supported(descriptor.depthAttachment.storeAction)) return NO;
        zpu_metal_texture *depthTexture = [depth zpuTextureAtLevel:descriptor.depthAttachment.level
                                                              slice:descriptor.depthAttachment.slice];
        if (depthTexture == NULL || zpu_metal_texture_width(depthTexture) != zpu_metal_texture_width(colorTexture) ||
            zpu_metal_texture_height(depthTexture) != zpu_metal_texture_height(colorTexture)) return NO;
        pass->depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass->depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass->depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    ZPUTexture *stencil = (ZPUTexture *)descriptor.stencilAttachment.texture;
    if (stencil != nil) {
        if (![stencil isKindOfClass:[ZPUTexture class]] || stencil->_pixelFormat != MTLPixelFormatStencil8 ||
            !zpu_store_action_supported(descriptor.stencilAttachment.storeAction)) return NO;
        zpu_metal_texture *stencilTexture = [stencil zpuTextureAtLevel:descriptor.stencilAttachment.level
                                                                   slice:descriptor.stencilAttachment.slice];
        if (stencilTexture == NULL || zpu_metal_texture_width(stencilTexture) != zpu_metal_texture_width(colorTexture) ||
            zpu_metal_texture_height(stencilTexture) != zpu_metal_texture_height(colorTexture)) return NO;
    }
    *color_texture = color;
    *depth_texture = depth;
    *stencil_texture = stencil;
    return YES;
}

static ZPUBuffer *zpu_metal4_buffer_for_address(ZPUDevice *owner, MTLGPUAddress address) {
    id resource = zpu_resource_for_id((uint64_t)address);
    if (![resource isKindOfClass:[ZPUBuffer class]]) return nil;
    ZPUBuffer *buffer = (ZPUBuffer *)resource;
    return buffer->_owner == owner ? buffer : nil;
}

static BOOL zpu_buffer_belongs_to_device(ZPUDevice *owner, ZPUBuffer *buffer) {
    return [buffer isKindOfClass:[ZPUBuffer class]] && buffer->_owner == owner;
}

static BOOL zpu_texture_belongs_to_device(ZPUDevice *owner, ZPUTexture *texture) {
    return [texture isKindOfClass:[ZPUTexture class]] && texture->_owner == owner;
}

static BOOL zpu_color_attachment_map_is_identity(MTLLogicalToPhysicalColorAttachmentMap *mapping)
    API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (mapping == nil) return YES;
    for (NSUInteger index = 0; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        if ([mapping getPhysicalIndexForLogicalIndex:index] != index) return NO;
    }
    return YES;
}

/* Sparse allocation is deliberately not advertised by the CPU adapter, but
 * Metal's pixel/tile conversion helpers are pure integer geometry. Keep them
 * useful for callers that use the helpers to prepare a mapping for another
 * device, without manufacturing a sparse resource or hardware page size. */
static BOOL zpu_sparse_axis_to_tiles(NSUInteger origin, NSUInteger size, NSUInteger tile,
                                     MTLSparseTextureRegionAlignmentMode mode,
                                     NSUInteger *tileOrigin, NSUInteger *tileSize) {
    if (tile == 0 || tileOrigin == NULL || tileSize == NULL ||
        (mode != MTLSparseTextureRegionAlignmentModeOutward &&
         mode != MTLSparseTextureRegionAlignmentModeInward) ||
        size > NSUIntegerMax - origin) return NO;
    const NSUInteger end = origin + size;
    const NSUInteger floorOrigin = origin / tile;
    const NSUInteger ceilOrigin = floorOrigin + (origin % tile != 0 ? 1 : 0);
    const NSUInteger floorEnd = end / tile;
    const NSUInteger ceilEnd = floorEnd + (end % tile != 0 ? 1 : 0);
    const NSUInteger start = mode == MTLSparseTextureRegionAlignmentModeOutward ? floorOrigin : ceilOrigin;
    const NSUInteger finish = mode == MTLSparseTextureRegionAlignmentModeOutward ? ceilEnd : floorEnd;
    *tileOrigin = start;
    *tileSize = finish > start ? finish - start : 0;
    return YES;
}

static BOOL zpu_sparse_axis_to_pixels(NSUInteger origin, NSUInteger size, NSUInteger tile,
                                      NSUInteger *pixelOrigin, NSUInteger *pixelSize) {
    if (tile == 0 || pixelOrigin == NULL || pixelSize == NULL ||
        origin > NSUIntegerMax / tile || size > NSUIntegerMax / tile) return NO;
    *pixelOrigin = origin * tile;
    *pixelSize = size * tile;
    return YES;
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

typedef struct {
    NSUInteger rank;
    NSUInteger dimensions[MTL_TENSOR_MAX_RANK];
    NSUInteger strides[MTL_TENSOR_MAX_RANK];
    NSUInteger elementSize;
    NSUInteger size;
} ZPUTensorLayout;

static NSUInteger zpu_tensor_element_size(MTLTensorDataType dataType) {
    switch (dataType) {
        case MTLTensorDataTypeFloat32:
        case MTLTensorDataTypeInt32:
        case MTLTensorDataTypeUInt32:
            return 4;
        case MTLTensorDataTypeFloat16:
        case MTLTensorDataTypeBFloat16:
        case MTLTensorDataTypeInt16:
        case MTLTensorDataTypeUInt16:
            return 2;
        case MTLTensorDataTypeInt8:
        case MTLTensorDataTypeUInt8:
            return 1;
        default:
            return 0;
    }
}

static BOOL zpu_tensor_read_extents(MTLTensorExtents *extents, NSUInteger rank, NSUInteger *values,
                                    BOOL allowZero) {
    if (extents == nil || values == NULL || extents.rank != rank || rank > MTL_TENSOR_MAX_RANK) return NO;
    for (NSUInteger index = 0; index < rank; ++index) {
        const NSInteger value = [extents extentAtDimensionIndex:index];
        if (value < 0 || (!allowZero && value == 0)) return NO;
        values[index] = (NSUInteger)value;
    }
    return YES;
}

static MTLTensorExtents *zpu_tensor_make_extents(NSUInteger rank, const NSUInteger *values) {
    NSInteger signedValues[MTL_TENSOR_MAX_RANK];
    if (rank > MTL_TENSOR_MAX_RANK || (rank != 0 && values == NULL)) return nil;
    for (NSUInteger index = 0; index < rank; ++index) {
        if (values[index] > (NSUInteger)NSIntegerMax) return nil;
        signedValues[index] = (NSInteger)values[index];
    }
    return [[MTLTensorExtents alloc] initWithRank:rank values:rank == 0 ? NULL : signedValues];
}

static BOOL zpu_tensor_layout_for_descriptor(MTLTensorDescriptor *descriptor, ZPUTensorLayout *layout) {
    if (descriptor == nil || layout == NULL || descriptor.dimensions == nil ||
        descriptor.dimensions.rank > MTL_TENSOR_MAX_RANK ||
        (descriptor.usage & ~((MTLTensorUsageCompute | MTLTensorUsageRender | MTLTensorUsageMachineLearning))) != 0 ||
        descriptor.usage == 0) return NO;
    const NSUInteger rank = descriptor.dimensions.rank;
    const NSUInteger elementSize = zpu_tensor_element_size(descriptor.dataType);
    if (elementSize == 0 || !zpu_tensor_read_extents(descriptor.dimensions, rank, layout->dimensions, NO)) return NO;
    layout->rank = rank;
    layout->elementSize = elementSize;
    if (descriptor.strides != nil) {
        if (!zpu_tensor_read_extents(descriptor.strides, rank, layout->strides, NO) ||
            (rank != 0 && layout->strides[0] != 1)) return NO;
        for (NSUInteger index = 1; index < rank; ++index) {
            if (layout->strides[index - 1] > SIZE_MAX / layout->dimensions[index - 1] ||
                layout->strides[index] < layout->strides[index - 1] * layout->dimensions[index - 1]) return NO;
        }
    } else {
        NSUInteger stride = 1;
        for (NSUInteger index = 0; index < rank; ++index) {
            layout->strides[index] = stride;
            if (index + 1 < rank) {
                if (stride > SIZE_MAX / layout->dimensions[index]) return NO;
                stride *= layout->dimensions[index];
            }
        }
    }
    NSUInteger lastElement = rank == 0 ? 0 : 1;
    if (rank != 0) {
        lastElement = 0;
        for (NSUInteger index = 0; index < rank; ++index) {
            if (layout->dimensions[index] == 0 || layout->dimensions[index] - 1 > SIZE_MAX / layout->strides[index] ||
                lastElement > SIZE_MAX - (layout->dimensions[index] - 1) * layout->strides[index]) return NO;
            lastElement += (layout->dimensions[index] - 1) * layout->strides[index];
        }
    }
    if (lastElement == SIZE_MAX || lastElement + 1 > SIZE_MAX / elementSize) return NO;
    layout->size = (lastElement + 1) * elementSize;
    return YES;
}

static BOOL zpu_tensor_slice_parameters(ZPUTensor *tensor, MTLTensorExtents *sliceOrigin,
                                        MTLTensorExtents *sliceDimensions, MTLTensorExtents *sourceStrides,
                                        NSUInteger *origin, NSUInteger *dimensions, NSUInteger *strides,
                                        NSUInteger *elementCount) {
    if (tensor == nil || sliceOrigin == nil || sliceDimensions == nil || origin == NULL ||
        dimensions == NULL || strides == NULL || elementCount == NULL ||
        !zpu_tensor_read_extents(sliceOrigin, tensor->_dimensions.rank, origin, YES) ||
        !zpu_tensor_read_extents(sliceDimensions, tensor->_dimensions.rank, dimensions, YES)) return NO;
    const NSUInteger rank = tensor->_dimensions.rank;
    NSUInteger tensorDimensions[MTL_TENSOR_MAX_RANK];
    if (!zpu_tensor_read_extents(tensor->_dimensions, rank, tensorDimensions, NO)) return NO;
    for (NSUInteger index = 0; index < rank; ++index) {
        if (origin[index] > tensorDimensions[index] || dimensions[index] > tensorDimensions[index] - origin[index]) return NO;
    }
    if (sourceStrides != nil) {
        if (!zpu_tensor_read_extents(sourceStrides, rank, strides, NO) || (rank != 0 && strides[0] == 0)) return NO;
        for (NSUInteger index = 1; index < rank; ++index) {
            if (strides[index - 1] > SIZE_MAX / dimensions[index - 1] ||
                strides[index] < strides[index - 1] * dimensions[index - 1]) return NO;
        }
    } else {
        NSUInteger stride = 1;
        for (NSUInteger index = 0; index < rank; ++index) {
            strides[index] = stride;
            if (index + 1 < rank) {
                if (stride > SIZE_MAX / dimensions[index]) return NO;
                stride *= dimensions[index];
            }
        }
    }
    NSUInteger count = rank == 0 ? 1 : 1;
    for (NSUInteger index = 0; index < rank; ++index) {
        if (dimensions[index] != 0 && count > SIZE_MAX / dimensions[index]) return NO;
        count *= dimensions[index];
    }
    *elementCount = count;
    return YES;
}

static ZPUTensor *zpu_create_tensor(ZPUDevice *owner, ZPUBuffer *storageBuffer,
                                    ZPUBuffer *backingBuffer, NSUInteger bufferOffset,
                                    MTLTensorDescriptor *descriptor, NSError **error);

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
        _heapOffset = zpu_metal_buffer_heap_offset(buffer);
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
- (NSUInteger)heapOffset { return _heapOffset; }
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
    return (id<MTLTensor>)zpu_create_tensor((ZPUDevice *)_owner, self, self, offset, descriptor, error);
}
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset bytesPerRow:(NSUInteger)bytesPerRow {
    if (descriptor == nil || (descriptor.textureType != MTLTextureType1D && descriptor.textureType != MTLTextureType2D) ||
        (descriptor.textureType == MTLTextureType1D && descriptor.height != 1) || descriptor.depth != 1 ||
        descriptor.arrayLength != 1 || descriptor.mipmapLevelCount != 1 || descriptor.sampleCount != 1 ||
        (descriptor.pixelFormat != MTLPixelFormatRGBA8Unorm && descriptor.pixelFormat != MTLPixelFormatBGRA8Unorm &&
         descriptor.pixelFormat != MTLPixelFormatR32Float && descriptor.pixelFormat != MTLPixelFormatRGBA16Float &&
         descriptor.pixelFormat != MTLPixelFormatStencil8)) return nil;
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

static ZPUTensor *zpu_create_tensor(ZPUDevice *owner, ZPUBuffer *storageBuffer,
                                    ZPUBuffer *backingBuffer, NSUInteger bufferOffset,
                                    MTLTensorDescriptor *descriptor, NSError **error) {
    ZPUTensorLayout layout;
    if (owner == nil || storageBuffer == nil || storageBuffer->_owner != owner ||
        (backingBuffer != nil && backingBuffer != storageBuffer && backingBuffer->_owner != owner) ||
        !zpu_tensor_layout_for_descriptor(descriptor, &layout) ||
        bufferOffset > storageBuffer.length || layout.size > storageBuffer.length - bufferOffset ||
        (backingBuffer != nil && descriptor.storageMode != backingBuffer.storageMode)) {
        zpu_set_error(error, @"ZPU CPU Metal tensor descriptor or backing range is invalid");
        return nil;
    }
    MTLTensorExtents *dimensions = zpu_tensor_make_extents(layout.rank, layout.dimensions);
    MTLTensorExtents *strides = zpu_tensor_make_extents(layout.rank, layout.strides);
    if (dimensions == nil || strides == nil) {
        zpu_set_error(error, @"ZPU CPU Metal could not represent tensor extents");
        return nil;
    }
    if (error != NULL) *error = nil;
    return [[ZPUTensor alloc] initWithOwner:owner storageBuffer:storageBuffer
                              backingBuffer:backingBuffer bufferOffset:bufferOffset
                                 dimensions:dimensions strides:strides
                                    dataType:descriptor.dataType usage:descriptor.usage
                             resourceOptions:descriptor.resourceOptions allocatedSize:layout.size];
}

static BOOL zpu_tensor_transfer_bytes(ZPUTensor *tensor, MTLTensorExtents *sliceOrigin,
                                      MTLTensorExtents *sliceDimensions, MTLTensorExtents *strides,
                                      const void *bytes, BOOL write) {
    NSUInteger origin[MTL_TENSOR_MAX_RANK];
    NSUInteger dimensions[MTL_TENSOR_MAX_RANK];
    NSUInteger sourceStrides[MTL_TENSOR_MAX_RANK];
    NSUInteger elementCount = 0;
    if (bytes == NULL || !zpu_tensor_slice_parameters(tensor, sliceOrigin, sliceDimensions, strides,
                                                       origin, dimensions, sourceStrides, &elementCount)) return NO;
    if (elementCount == 0) return YES;
    NSUInteger tensorStrides[MTL_TENSOR_MAX_RANK];
    const NSUInteger rank = tensor->_dimensions.rank;
    if (!zpu_tensor_read_extents(tensor->_strides, rank, tensorStrides, NO) ||
        tensor->_storageBuffer == nil || tensor->_storageBuffer.contents == NULL) return NO;
    NSUInteger coordinates[MTL_TENSOR_MAX_RANK] = {0};
    uint8_t *storage = (uint8_t *)tensor->_storageBuffer.contents;
    for (NSUInteger element = 0; element < elementCount; ++element) {
        NSUInteger destinationElement = 0;
        NSUInteger sourceElement = 0;
        for (NSUInteger dimension = 0; dimension < rank; ++dimension) {
            if (origin[dimension] > SIZE_MAX / tensorStrides[dimension] ||
                destinationElement > SIZE_MAX - origin[dimension] * tensorStrides[dimension] ||
                coordinates[dimension] > SIZE_MAX / tensorStrides[dimension] ||
                destinationElement > SIZE_MAX - coordinates[dimension] * tensorStrides[dimension] ||
                coordinates[dimension] > SIZE_MAX / sourceStrides[dimension] ||
                sourceElement > SIZE_MAX - coordinates[dimension] * sourceStrides[dimension]) return NO;
            destinationElement += origin[dimension] * tensorStrides[dimension];
            destinationElement += coordinates[dimension] * tensorStrides[dimension];
            sourceElement += coordinates[dimension] * sourceStrides[dimension];
        }
        if (destinationElement > SIZE_MAX / tensor->_elementSize ||
            sourceElement > SIZE_MAX / tensor->_elementSize ||
            tensor->_bufferOffset > SIZE_MAX - destinationElement * tensor->_elementSize) return NO;
        const NSUInteger destinationByte = tensor->_bufferOffset + destinationElement * tensor->_elementSize;
        const NSUInteger sourceByte = sourceElement * tensor->_elementSize;
        if (write) {
            memmove(storage + destinationByte, (const uint8_t *)bytes + sourceByte, tensor->_elementSize);
        } else {
            memmove((uint8_t *)bytes + sourceByte, storage + destinationByte, tensor->_elementSize);
        }
        for (NSUInteger dimension = 0; dimension < rank; ++dimension) {
            coordinates[dimension] += 1;
            if (coordinates[dimension] < dimensions[dimension]) break;
            coordinates[dimension] = 0;
        }
    }
    return YES;
}

typedef int (*ZPUTensorBufferCopyFunction)(void *encoder, zpu_metal_buffer *source, size_t sourceOffset,
                                           zpu_metal_buffer *destination, size_t destinationOffset, size_t length);

static int zpu_tensor_blit_copy(void *encoder, zpu_metal_buffer *source, size_t sourceOffset,
                                zpu_metal_buffer *destination, size_t destinationOffset, size_t length) {
    return zpu_metal_blit_encoder_copy_buffer((zpu_metal_blit_encoder *)encoder, source, sourceOffset,
                                              destination, destinationOffset, length);
}

static int zpu_tensor_compute_copy(void *encoder, zpu_metal_buffer *source, size_t sourceOffset,
                                   zpu_metal_buffer *destination, size_t destinationOffset, size_t length) {
    return zpu_metal_compute_encoder_copy_buffer((zpu_metal_compute_encoder *)encoder, source, sourceOffset,
                                                 destination, destinationOffset, length);
}

static BOOL zpu_tensor_encode_copy_slice(ZPUTensor *source, MTLTensorExtents *sourceOrigin,
                                         MTLTensorExtents *sourceDimensions, ZPUTensor *destination,
                                         MTLTensorExtents *destinationOrigin, MTLTensorExtents *destinationDimensions,
                                         void *encoder, BOOL computeEncoder) {
    if (source == nil || destination == nil || source->_dataType != destination->_dataType ||
        source->_elementSize == 0 || destination->_elementSize != source->_elementSize ||
        sourceDimensions == nil || sourceOrigin == nil || destinationOrigin == nil || destinationDimensions == nil ||
        sourceDimensions.rank != source->_dimensions.rank || destinationOrigin.rank != destination->_dimensions.rank ||
        destinationDimensions.rank != destination->_dimensions.rank) return NO;
    const NSUInteger rank = sourceDimensions.rank;
    NSUInteger dimensions[MTL_TENSOR_MAX_RANK];
    if (!zpu_tensor_read_extents(sourceDimensions, rank, dimensions, YES)) return NO;
    NSUInteger destinationDimensionsValues[MTL_TENSOR_MAX_RANK];
    if (!zpu_tensor_read_extents(destinationDimensions, rank, destinationDimensionsValues, YES) ||
        memcmp(dimensions, destinationDimensionsValues, rank * sizeof(NSUInteger)) != 0) return NO;
    NSUInteger sourceOriginValues[MTL_TENSOR_MAX_RANK];
    NSUInteger sourceSliceDimensions[MTL_TENSOR_MAX_RANK];
    NSUInteger sourceStrides[MTL_TENSOR_MAX_RANK];
    NSUInteger sourceCount = 0;
    if (!zpu_tensor_slice_parameters(source, sourceOrigin, sourceDimensions, source->_strides,
                                      sourceOriginValues, sourceSliceDimensions, sourceStrides, &sourceCount)) return NO;
    NSUInteger destinationOriginValues[MTL_TENSOR_MAX_RANK];
    NSUInteger destinationSliceDimensions[MTL_TENSOR_MAX_RANK];
    NSUInteger destinationStrides[MTL_TENSOR_MAX_RANK];
    NSUInteger destinationCount = 0;
    if (!zpu_tensor_slice_parameters(destination, destinationOrigin, sourceDimensions, destination->_strides,
                                      destinationOriginValues, destinationSliceDimensions, destinationStrides, &destinationCount) ||
        sourceCount != destinationCount || memcmp(sourceSliceDimensions, destinationSliceDimensions,
                                                   rank * sizeof(NSUInteger)) != 0) return NO;
    if (sourceCount == 0 || encoder == NULL || source->_storageBuffer == nil || destination->_storageBuffer == nil) return sourceCount == 0;
    ZPUTensorBufferCopyFunction copy = computeEncoder ? zpu_tensor_compute_copy : zpu_tensor_blit_copy;
    NSUInteger sourceTensorStrides[MTL_TENSOR_MAX_RANK];
    NSUInteger destinationTensorStrides[MTL_TENSOR_MAX_RANK];
    if (!zpu_tensor_read_extents(source->_strides, rank, sourceTensorStrides, NO) ||
        !zpu_tensor_read_extents(destination->_strides, rank, destinationTensorStrides, NO)) return NO;
    NSUInteger coordinates[MTL_TENSOR_MAX_RANK] = {0};
    for (NSUInteger element = 0; element < sourceCount; ++element) {
        NSUInteger sourceElement = 0;
        NSUInteger destinationElement = 0;
        for (NSUInteger dimension = 0; dimension < rank; ++dimension) {
            if (sourceOriginValues[dimension] > SIZE_MAX / sourceTensorStrides[dimension] ||
                sourceElement > SIZE_MAX - sourceOriginValues[dimension] * sourceTensorStrides[dimension] ||
                coordinates[dimension] > SIZE_MAX / sourceStrides[dimension] ||
                sourceElement > SIZE_MAX - coordinates[dimension] * sourceStrides[dimension] ||
                destinationOriginValues[dimension] > SIZE_MAX / destinationTensorStrides[dimension] ||
                destinationElement > SIZE_MAX - destinationOriginValues[dimension] * destinationTensorStrides[dimension] ||
                coordinates[dimension] > SIZE_MAX / destinationStrides[dimension] ||
                destinationElement > SIZE_MAX - coordinates[dimension] * destinationStrides[dimension]) return NO;
            sourceElement += sourceOriginValues[dimension] * sourceTensorStrides[dimension];
            sourceElement += coordinates[dimension] * sourceStrides[dimension];
            destinationElement += destinationOriginValues[dimension] * destinationTensorStrides[dimension];
            destinationElement += coordinates[dimension] * destinationStrides[dimension];
        }
        if (sourceElement > SIZE_MAX / source->_elementSize || destinationElement > SIZE_MAX / destination->_elementSize ||
            source->_bufferOffset > SIZE_MAX - sourceElement * source->_elementSize ||
            destination->_bufferOffset > SIZE_MAX - destinationElement * destination->_elementSize ||
            copy(encoder, source->_storageBuffer->_zpuBuffer,
                 source->_bufferOffset + sourceElement * source->_elementSize,
                 destination->_storageBuffer->_zpuBuffer,
                 destination->_bufferOffset + destinationElement * destination->_elementSize,
                 source->_elementSize) != ZPU_METAL_OK) return NO;
        for (NSUInteger dimension = 0; dimension < rank; ++dimension) {
            coordinates[dimension] += 1;
            if (coordinates[dimension] < dimensions[dimension]) break;
            coordinates[dimension] = 0;
        }
    }
    return YES;
}

@implementation ZPUTensor
- (instancetype)initWithOwner:(ZPUDevice *)owner storageBuffer:(ZPUBuffer *)storageBuffer
                 backingBuffer:(ZPUBuffer *)backingBuffer bufferOffset:(NSUInteger)bufferOffset
                    dimensions:(MTLTensorExtents *)dimensions strides:(MTLTensorExtents *)strides
                       dataType:(MTLTensorDataType)dataType usage:(MTLTensorUsage)usage
                resourceOptions:(MTLResourceOptions)resourceOptions allocatedSize:(NSUInteger)allocatedSize {
    if ((self = [super init])) {
        _owner = owner;
        _storageBuffer = storageBuffer;
        _backingBuffer = backingBuffer;
        _bufferOffset = bufferOffset;
        _allocatedSize = allocatedSize;
        _elementSize = zpu_tensor_element_size(dataType);
        _dimensions = [dimensions copy];
        _strides = [strides copy];
        _dataType = dataType;
        _usage = usage;
        _resourceOptions = resourceOptions;
        _storageMode = (MTLStorageMode)((resourceOptions & MTLResourceStorageModeMask) >> MTLResourceStorageModeShift);
        _cpuCacheMode = (MTLCPUCacheMode)((resourceOptions & MTLResourceCPUCacheModeMask) >> MTLResourceCPUCacheModeShift);
        _hazardTrackingMode = (MTLHazardTrackingMode)((resourceOptions & MTLResourceHazardTrackingModeMask) >> MTLResourceHazardTrackingModeShift);
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLCPUCacheMode)cpuCacheMode { return _cpuCacheMode; }
- (MTLStorageMode)storageMode { return _storageMode; }
- (MTLHazardTrackingMode)hazardTrackingMode {
    return zpu_effective_hazard_tracking_mode(_hazardTrackingMode, MTLHazardTrackingModeTracked);
}
- (MTLResourceOptions)resourceOptions { return _resourceOptions; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize { return _allocatedSize; }
- (BOOL)isAliasable { return _aliasable; }
- (void)makeAliasable { _aliasable = YES; }
- (id<MTLResource>)rootResource { return (id<MTLResource>)self; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){_resourceID}; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (id<MTLBuffer>)buffer { return (id<MTLBuffer>)_backingBuffer; }
- (NSUInteger)bufferOffset { return _backingBuffer == nil ? 0 : _bufferOffset; }
- (MTLTensorExtents *)strides { return _backingBuffer == nil ? nil : _strides; }
- (MTLTensorExtents *)dimensions { return _dimensions; }
- (MTLTensorDataType)dataType { return _dataType; }
- (MTLTensorUsage)usage { return _usage; }
- (void)replaceSliceOrigin:(MTLTensorExtents *)sliceOrigin
           sliceDimensions:(MTLTensorExtents *)sliceDimensions
                 withBytes:(const void *)bytes
                   strides:(MTLTensorExtents *)strides {
    (void)zpu_tensor_transfer_bytes(self, sliceOrigin, sliceDimensions, strides, bytes, YES);
}
- (void)getBytes:(void *)bytes strides:(MTLTensorExtents *)strides
 fromSliceOrigin:(MTLTensorExtents *)sliceOrigin sliceDimensions:(MTLTensorExtents *)sliceDimensions {
    (void)zpu_tensor_transfer_bytes(self, sliceOrigin, sliceDimensions, strides, bytes, NO);
}
@end

#pragma clang diagnostic pop

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
        _heapOffset = zpu_metal_texture_heap_offset(texture);
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
        _mipmapTextures = @[[NSValue valueWithPointer:texture]];
        _sliceMipmapTextures = @[_mipmapTextures];
        _depth = 1;
        _baseMipmapLevel = 0;
        _baseSlice = 0;
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat mipmapSlices:(NSArray *)mipmapSlices {
    NSArray *firstSlice = mipmapSlices.firstObject;
    if ((self = [self initWithOwner:owner texture:texture type:type pixelFormat:pixelFormat
                      backingBuffer:nil offset:0 bytesPerRow:0])) {
        if (mipmapSlices.count != 0 && firstSlice.count != 0) {
            _sliceMipmapTextures = [mipmapSlices copy];
            _mipmapTextures = [firstSlice copy];
        }
    }
    return self;
}
- (instancetype)initWithOwner:(id)owner texture:(zpu_metal_texture *)texture type:(MTLTextureType)type pixelFormat:(MTLPixelFormat)pixelFormat mipmapTextures:(NSArray *)mipmapTextures {
    if ((self = [self initWithOwner:owner texture:texture type:type pixelFormat:pixelFormat
                       backingBuffer:nil offset:0 bytesPerRow:0])) {
        if (mipmapTextures.count != 0) _mipmapTextures = [mipmapTextures copy];
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
    if (_backing == nil) {
        for (NSArray *slice in _sliceMipmapTextures) {
            for (id value in slice) {
                if ([value isKindOfClass:[NSValue class]]) {
                    zpu_metal_texture *texture = (zpu_metal_texture *)[value pointerValue];
                    if (texture != NULL) zpu_metal_texture_destroy(texture);
                }
            }
        }
    }
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLTextureType)textureType { return _textureType; }
- (MTLPixelFormat)pixelFormat { return _pixelFormat; }
- (NSUInteger)width { return zpu_metal_texture_width(_zpuTexture); }
- (NSUInteger)height { return zpu_metal_texture_height(_zpuTexture); }
- (NSUInteger)depth { return _depth; }
- (NSUInteger)mipmapLevelCount { return _mipmapTextures.count; }
- (NSUInteger)sampleCount { return 1; }
- (NSUInteger)arrayLength { return zpu_texture_type_is_3d(_textureType) ? 1 : _sliceMipmapTextures.count; }
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
- (BOOL)isShareable { return _shareable; }
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
    if (_backingBuffer != nil) return _bufferBytesPerRow * [self height];
    NSUInteger total = 0;
    for (NSArray *slice in _sliceMipmapTextures) {
        for (id value in slice) {
            if (![value isKindOfClass:[NSValue class]]) continue;
            zpu_metal_texture *texture = (zpu_metal_texture *)[value pointerValue];
            const NSUInteger width = zpu_metal_texture_width(texture);
            const NSUInteger height = zpu_metal_texture_height(texture);
            const NSUInteger bytesPerPixel = zpu_texture_bytes_per_pixel(_pixelFormat);
            if (height != 0 && width > (SIZE_MAX - total) / (height * bytesPerPixel)) return SIZE_MAX;
            total += width * height * bytesPerPixel;
        }
    }
    return total;
}
- (id<MTLHeap>)heap { return (id<MTLHeap>)_heap; }
- (NSUInteger)heapOffset { return _backing != nil ? [_backing heapOffset] : _heapOffset; }
- (NSUInteger)parentRelativeLevel { return _baseMipmapLevel; }
- (NSUInteger)parentRelativeSlice { return _baseSlice; }
- (IOSurfaceRef)iosurface API_AVAILABLE(macos(10.11), ios(11.0)) { return nil; }
- (NSUInteger)iosurfacePlane API_AVAILABLE(macos(10.11), ios(11.0)) { return 0; }
- (NSUInteger)firstMipmapInTail API_AVAILABLE(macos(11.0), ios(13.0)) { return 0; }
- (NSUInteger)tailSizeInBytes API_AVAILABLE(macos(11.0), ios(13.0)) { return 0; }
- (BOOL)isSparse API_AVAILABLE(macos(11.0), ios(13.0)) { return NO; }
- (BOOL)isAliasable { return _aliasable; }
- (void)makeAliasable { _aliasable = YES; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (void)getBytes:(void *)destination bytesPerRow:(NSUInteger)bytesPerRow fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level {
    if (zpu_texture_type_is_3d(_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(self, level);
        if (destination == NULL || levelDepth == 0 || region.origin.z > levelDepth ||
            region.size.depth > levelDepth - region.origin.z || !zpu_region_fits(region) ||
            [self zpuTextureAtLevel:level slice:0] == NULL) return;
        const NSUInteger rowBytes = region.size.width * zpu_texture_bytes_per_pixel(_pixelFormat);
        const NSUInteger rowStride = bytesPerRow == 0 ? rowBytes : bytesPerRow;
        if (rowStride < rowBytes || (region.size.height != 0 && rowStride > SIZE_MAX / region.size.height)) return;
        const NSUInteger imageStride = rowStride * region.size.height;
        if (region.size.depth > 1 && imageStride > SIZE_MAX / (region.size.depth - 1)) return;
        for (NSUInteger plane = 0; plane < region.size.depth; ++plane) {
            zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:region.origin.z + plane];
            if (texture == NULL || zpu_metal_texture_get_bytes(texture,
                    (uint8_t *)destination + plane * imageStride, NSUIntegerMax, rowStride,
                    zpu_region(MTLRegionMake3D(region.origin.x, region.origin.y, 0,
                                                region.size.width, region.size.height, 1))) != ZPU_METAL_OK) return;
        }
        return;
    }
    zpu_metal_texture *texture = [self zpuTextureAtLevel:level];
    if (texture == NULL || destination == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_get_bytes(texture, destination, NSUIntegerMax, bytesPerRow, zpu_region(region));
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level withBytes:(const void *)source bytesPerRow:(NSUInteger)bytesPerRow {
    if (zpu_texture_type_is_3d(_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(self, level);
        if (source == NULL || levelDepth == 0 || region.origin.z > levelDepth ||
            region.size.depth > levelDepth - region.origin.z || !zpu_region_fits(region) ||
            [self zpuTextureAtLevel:level slice:0] == NULL) return;
        const NSUInteger rowBytes = region.size.width * zpu_texture_bytes_per_pixel(_pixelFormat);
        const NSUInteger rowStride = bytesPerRow == 0 ? rowBytes : bytesPerRow;
        if (rowStride < rowBytes || (region.size.height != 0 && rowStride > SIZE_MAX / region.size.height)) return;
        const NSUInteger imageStride = rowStride * region.size.height;
        if (region.size.depth > 1 && imageStride > SIZE_MAX / (region.size.depth - 1)) return;
        for (NSUInteger plane = 0; plane < region.size.depth; ++plane) {
            zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:region.origin.z + plane];
            if (texture == NULL || zpu_metal_texture_replace_region(texture,
                    zpu_region(MTLRegionMake3D(region.origin.x, region.origin.y, 0,
                                                region.size.width, region.size.height, 1)),
                    (const uint8_t *)source + plane * imageStride, NSUIntegerMax, rowStride) != ZPU_METAL_OK) return;
        }
        return;
    }
    zpu_metal_texture *texture = [self zpuTextureAtLevel:level];
    if (texture == NULL || source == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_replace_region(texture, zpu_region(region), source, NSUIntegerMax, bytesPerRow);
}
- (void)getBytes:(void *)destination bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage fromRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice {
    if (zpu_texture_type_is_3d(_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(self, level);
        if (slice != 0 || destination == NULL || levelDepth == 0 || region.origin.z > levelDepth ||
            region.size.depth > levelDepth - region.origin.z || !zpu_region_fits(region) ||
            [self zpuTextureAtLevel:level slice:0] == NULL) return;
        const NSUInteger rowBytes = region.size.width * zpu_texture_bytes_per_pixel(_pixelFormat);
        const NSUInteger rowStride = bytesPerRow == 0 ? rowBytes : bytesPerRow;
        if (rowStride < rowBytes || (region.size.height != 0 && rowStride > SIZE_MAX / region.size.height)) return;
        const NSUInteger imageStride = bytesPerImage == 0 ? rowStride * region.size.height : bytesPerImage;
        if (region.size.depth > 1 && imageStride < rowStride * region.size.height) return;
        if (region.size.depth > 1 && imageStride > SIZE_MAX / (region.size.depth - 1)) return;
        for (NSUInteger plane = 0; plane < region.size.depth; ++plane) {
            zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:region.origin.z + plane];
            if (texture == NULL || zpu_metal_texture_get_bytes(texture,
                    (uint8_t *)destination + plane * imageStride, NSUIntegerMax, rowStride,
                    zpu_region(MTLRegionMake3D(region.origin.x, region.origin.y, 0,
                                                region.size.width, region.size.height, 1))) != ZPU_METAL_OK) return;
        }
        return;
    }
    zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:slice];
    if (texture == NULL || destination == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_get_bytes(texture, destination, NSUIntegerMax, bytesPerRow, zpu_region(region));
}
- (void)replaceRegion:(MTLRegion)region mipmapLevel:(NSUInteger)level slice:(NSUInteger)slice withBytes:(const void *)source bytesPerRow:(NSUInteger)bytesPerRow bytesPerImage:(NSUInteger)bytesPerImage {
    if (zpu_texture_type_is_3d(_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(self, level);
        if (slice != 0 || source == NULL || levelDepth == 0 || region.origin.z > levelDepth ||
            region.size.depth > levelDepth - region.origin.z || !zpu_region_fits(region) ||
            [self zpuTextureAtLevel:level slice:0] == NULL) return;
        const NSUInteger rowBytes = region.size.width * zpu_texture_bytes_per_pixel(_pixelFormat);
        const NSUInteger rowStride = bytesPerRow == 0 ? rowBytes : bytesPerRow;
        if (rowStride < rowBytes || (region.size.height != 0 && rowStride > SIZE_MAX / region.size.height)) return;
        const NSUInteger imageStride = bytesPerImage == 0 ? rowStride * region.size.height : bytesPerImage;
        if (region.size.depth > 1 && imageStride < rowStride * region.size.height) return;
        if (region.size.depth > 1 && imageStride > SIZE_MAX / (region.size.depth - 1)) return;
        for (NSUInteger plane = 0; plane < region.size.depth; ++plane) {
            zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:region.origin.z + plane];
            if (texture == NULL || zpu_metal_texture_replace_region(texture,
                    zpu_region(MTLRegionMake3D(region.origin.x, region.origin.y, 0,
                                                region.size.width, region.size.height, 1)),
                    (const uint8_t *)source + plane * imageStride, NSUIntegerMax, rowStride) != ZPU_METAL_OK) return;
        }
        return;
    }
    zpu_metal_texture *texture = [self zpuTextureAtLevel:level slice:slice];
    if (texture == NULL || source == NULL || !zpu_region_fits(region)) return;
    (void)zpu_metal_texture_replace_region(texture, zpu_region(region), source, NSUIntegerMax, bytesPerRow);
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat {
    if (pixelFormat != _pixelFormat) return nil;
    ZPUTexture *view = [[ZPUTexture alloc] initWithOwner:_owner texture:_zpuTexture
                                                    type:_textureType pixelFormat:pixelFormat backing:self];
    view->_mipmapTextures = [_mipmapTextures copy];
    view->_sliceMipmapTextures = [_sliceMipmapTextures copy];
    view->_depth = _depth;
    view->_baseMipmapLevel = _baseMipmapLevel;
    view->_baseSlice = _baseSlice;
    view->_swizzle = [self swizzle];
    return (id<MTLTexture>)view;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)textureType levels:(NSRange)levelRange slices:(NSRange)sliceRange {
    if (textureType != _textureType || sliceRange.location > _sliceMipmapTextures.count || sliceRange.length == 0 ||
        sliceRange.length > _sliceMipmapTextures.count - sliceRange.location ||
        levelRange.location > _mipmapTextures.count || levelRange.length == 0 ||
        levelRange.length > _mipmapTextures.count - levelRange.location) return nil;
    if (pixelFormat != _pixelFormat) return nil;
    if (zpu_texture_type_is_3d(_textureType) && (sliceRange.location != 0 || sliceRange.length != 1)) return nil;
    NSMutableArray *sliceMipmapTextures = [NSMutableArray arrayWithCapacity:sliceRange.length];
    const NSRange sourceSliceRange = zpu_texture_type_is_3d(_textureType) ?
        NSMakeRange(0, _sliceMipmapTextures.count) : sliceRange;
    for (NSArray *slice in [_sliceMipmapTextures subarrayWithRange:sourceSliceRange]) {
        [sliceMipmapTextures addObject:[slice subarrayWithRange:levelRange]];
    }
    NSArray *mipmaps = sliceMipmapTextures.firstObject;
    zpu_metal_texture *texture = (zpu_metal_texture *)[mipmaps[0] pointerValue];
    ZPUTexture *view = [[ZPUTexture alloc] initWithOwner:_owner texture:texture
                                                    type:_textureType pixelFormat:pixelFormat backing:self];
    view->_mipmapTextures = [mipmaps copy];
    view->_sliceMipmapTextures = [sliceMipmapTextures copy];
    view->_depth = zpu_texture_type_is_3d(_textureType) ?
        zpu_texture_depth_at_level(self, levelRange.location) : 1;
    view->_baseMipmapLevel = _baseMipmapLevel + levelRange.location;
    view->_baseSlice = _baseSlice + sliceRange.location;
    view->_swizzle = [self swizzle];
    return (id<MTLTexture>)view;
}
- (id<MTLTexture>)newTextureViewWithPixelFormat:(MTLPixelFormat)pixelFormat textureType:(MTLTextureType)textureType levels:(NSRange)levelRange slices:(NSRange)sliceRange swizzle:(MTLTextureSwizzleChannels)swizzle {
    ZPUTexture *view = (ZPUTexture *)[self newTextureViewWithPixelFormat:pixelFormat
                                                               textureType:textureType
                                                                    levels:levelRange
                                                                    slices:sliceRange];
    if (view == nil) return nil;
    view->_swizzle = swizzle;
    return (id<MTLTexture>)view;
}
- (id<MTLTexture>)newTextureViewWithDescriptor:(MTLTextureViewDescriptor *)descriptor API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil) return nil;
    return [self newTextureViewWithPixelFormat:descriptor.pixelFormat
                                   textureType:descriptor.textureType
                                        levels:descriptor.levelRange
                                        slices:descriptor.sliceRange
                                       swizzle:descriptor.swizzle];
}
- (MTLTextureSwizzleChannels)swizzle { return _swizzle; }
- (MTLSharedTextureHandle *)newSharedTextureHandle { return [[ZPUSharedTextureHandle alloc] initWithTexture:self]; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token API_AVAILABLE(ios(17.4), watchos(10.4), tvos(17.4), macos(14.4)) {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (zpu_metal_texture *)zpuTextureAtLevel:(NSUInteger)level {
    return [self zpuTextureAtLevel:level slice:0];
}
- (zpu_metal_texture *)zpuTextureAtLevel:(NSUInteger)level slice:(NSUInteger)slice {
    if (slice >= _sliceMipmapTextures.count) return NULL;
    NSArray *mipmaps = _sliceMipmapTextures[slice];
    if (level >= mipmaps.count) return NULL;
    id value = mipmaps[level];
    if (![value isKindOfClass:[NSValue class]]) return NULL;
    return (zpu_metal_texture *)[value pointerValue];
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
        [_owner->_heaps addObject:self];
    }
    return self;
}
- (void)dealloc {
    if (_zpuHeap != NULL) zpu_metal_heap_destroy(_zpuHeap);
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
- (id<MTLTexture>)zpuNewTextureWithDescriptor:(MTLTextureDescriptor *)descriptor firstOffset:(NSUInteger)offset explicitOffset:(BOOL)explicitOffset {
    NSUInteger descriptorSize = 0;
    if (!zpu_texture_descriptor_size(descriptor, &descriptorSize)) return nil;
    (void)descriptorSize;
    if ((descriptor.storageMode != _storageMode && descriptor.storageMode != MTLStorageModeMemoryless) ||
        descriptor.cpuCacheMode != _cpuCacheMode ||
        (descriptor.hazardTrackingMode == MTLHazardTrackingModeTracked && [self hazardTrackingMode] != MTLHazardTrackingModeTracked)) return nil;
    const NSUInteger sliceCount = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : descriptor.arrayLength;
    NSMutableArray *sliceMipmapTextures = [NSMutableArray arrayWithCapacity:sliceCount];
    for (NSUInteger slice = 0; slice < sliceCount; ++slice) {
        NSMutableArray *mipmaps = [NSMutableArray arrayWithCapacity:descriptor.mipmapLevelCount];
        NSUInteger levelWidth = descriptor.width;
        NSUInteger levelHeight = zpu_texture_type_is_1d(descriptor.textureType) ? 1 : descriptor.height;
        NSUInteger levelDepth = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : 1;
        for (NSUInteger level = 0; level < descriptor.mipmapLevelCount; ++level) {
            if (zpu_texture_type_is_3d(descriptor.textureType) && slice >= levelDepth) {
                [mipmaps addObject:[NSNull null]];
            } else {
                zpu_metal_texture_descriptor zpu_descriptor = {
                    (uint32_t)levelWidth, (uint32_t)levelHeight, zpu_pixel_format(descriptor.pixelFormat),
                };
                zpu_metal_texture *texture = (explicitOffset && slice == 0 && level == 0) ?
                    zpu_metal_heap_new_texture_at_offset(_zpuHeap, &zpu_descriptor, offset) :
                    zpu_metal_heap_new_texture(_zpuHeap, &zpu_descriptor);
                if (texture == NULL) {
                    for (NSArray *createdSlice in sliceMipmapTextures) {
                        for (id value in createdSlice) {
                            if ([value isKindOfClass:[NSValue class]]) zpu_metal_texture_destroy((zpu_metal_texture *)[value pointerValue]);
                        }
                    }
                    for (id value in mipmaps) {
                        if ([value isKindOfClass:[NSValue class]]) zpu_metal_texture_destroy((zpu_metal_texture *)[value pointerValue]);
                    }
                    return nil;
                }
                [mipmaps addObject:[NSValue valueWithPointer:texture]];
            }
            levelWidth = levelWidth > 1 ? levelWidth / 2 : 1;
            levelHeight = levelHeight > 1 ? levelHeight / 2 : 1;
            levelDepth = levelDepth > 1 ? levelDepth / 2 : 1;
        }
        [sliceMipmapTextures addObject:mipmaps];
    }
    NSArray *firstSlice = sliceMipmapTextures.firstObject;
    zpu_metal_texture *texture = (zpu_metal_texture *)[firstSlice[0] pointerValue];
    ZPUTexture *result = [[ZPUTexture alloc] initWithOwner:_owner texture:texture
                                                      type:descriptor.textureType
                                               pixelFormat:descriptor.pixelFormat heap:self];
    result->_sliceMipmapTextures = [sliceMipmapTextures copy];
    result->_mipmapTextures = [firstSlice copy];
    result->_depth = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : 1;
    [result applyDescriptor:descriptor];
    return (id<MTLTexture>)result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    return [self zpuNewTextureWithDescriptor:descriptor firstOffset:0 explicitOffset:NO];
}
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (MTLHeapType)type { return _type; }
- (id<MTLBuffer>)newBufferWithLength:(NSUInteger)length options:(MTLResourceOptions)options offset:(NSUInteger)offset API_AVAILABLE(macos(10.15), ios(13.0)) {
    if (!zpu_heap_buffer_options_match(_storageMode, _cpuCacheMode, [self hazardTrackingMode], options)) return nil;
    zpu_metal_buffer *buffer = zpu_metal_heap_new_buffer_at_offset(_zpuHeap, length, NULL, offset);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:_owner buffer:buffer heap:self];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor offset:(NSUInteger)offset API_AVAILABLE(macos(10.15), ios(13.0)) {
    return [self zpuNewTextureWithDescriptor:descriptor firstOffset:offset explicitOffset:YES];
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

API_AVAILABLE(macos(15.0), ios(18.0))
static BOOL zpu_residency_allocation_belongs_to_device(ZPUDevice *owner, id<MTLAllocation> allocation) {
    if (allocation == nil || ![allocation respondsToSelector:@selector(allocatedSize)] ||
        ![allocation respondsToSelector:@selector(device)]) return NO;
    return [(id)allocation device] == owner;
}

@implementation ZPUResidencySet
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLResidencySetDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _allocations = [NSMutableArray arrayWithCapacity:descriptor.initialCapacity];
        _committedAllocatedSize = 0;
        _resident = NO;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (uint64_t)allocatedSize { return _committedAllocatedSize; }
- (void)requestResidency {
    [self commit];
    _resident = YES;
}
- (void)endResidency { _resident = NO; }
- (void)addAllocation:(id<MTLAllocation>)allocation {
    if (!zpu_residency_allocation_belongs_to_device(_owner, allocation) || [_allocations containsObject:allocation]) return;
    [_allocations addObject:allocation];
}
- (void)addAllocations:(const id<MTLAllocation>[])allocations count:(NSUInteger)count {
    if (allocations == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self addAllocation:allocations[index]];
}
- (void)removeAllocation:(id<MTLAllocation>)allocation {
    if (allocation != nil) [_allocations removeObject:allocation];
}
- (void)removeAllocations:(const id<MTLAllocation>[])allocations count:(NSUInteger)count {
    if (allocations == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self removeAllocation:allocations[index]];
}
- (void)removeAllAllocations { [_allocations removeAllObjects]; }
- (BOOL)containsAllocation:(id<MTLAllocation>)allocation { return allocation != nil && [_allocations containsObject:allocation]; }
- (NSArray<id<MTLAllocation>> *)allAllocations { return [_allocations copy]; }
- (NSUInteger)allocationCount { return _allocations.count; }
- (void)commit {
    uint64_t total = 0;
    for (id<MTLAllocation> allocation in _allocations) {
        const uint64_t size = (uint64_t)[allocation allocatedSize];
        total = UINT64_MAX - total < size ? UINT64_MAX : total + size;
    }
    _committedAllocatedSize = total;
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

@implementation ZPUSharedEventHandle
- (instancetype)initWithEvent:(ZPUSharedEvent *)event {
    if ((self = [super init])) {
        _event = event;
        _label = [event.label copy];
    }
    return self;
}
- (NSString *)label { return _label; }
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) _label = [[coder decodeObjectOfClass:[NSString class] forKey:@"label"] copy];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_label forKey:@"label"]; }
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
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
- (MTLSharedEventHandle *)newSharedEventHandle { return [[ZPUSharedEventHandle alloc] initWithEvent:self]; }
@end

@implementation ZPUSharedTextureHandle
- (instancetype)initWithTexture:(ZPUTexture *)texture {
    if ((self = [super init])) {
        _texture = texture;
        _label = [texture.label copy];
    }
    return self;
}
- (id<MTLDevice>)device { return [_texture device]; }
- (NSString *)label { return _label; }
+ (BOOL)supportsSecureCoding { return YES; }
- (instancetype)initWithCoder:(NSCoder *)coder {
    if ((self = [super init])) _label = [[coder decodeObjectOfClass:[NSString class] forKey:@"label"] copy];
    return self;
}
- (void)encodeWithCoder:(NSCoder *)coder { [coder encodeObject:_label forKey:@"label"]; }
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
@implementation ZPULogState
- (instancetype)initWithDescriptor:(MTLLogStateDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil || descriptor.bufferSize < 1024 ||
        descriptor.level < MTLLogLevelUndefined || descriptor.level > MTLLogLevelFault) {
        zpu_set_error(error, @"ZPU CPU Metal log state requires a valid level and at least 1 KiB of storage");
        return nil;
    }
    if ((self = [super init])) {
        _level = descriptor.level;
        _bufferSize = descriptor.bufferSize;
        _handlers = [NSMutableArray array];
    }
    if (error != NULL) *error = nil;
    return self;
}
- (void)addLogHandler:(void (^)(NSString * _Nullable subSystem, NSString * _Nullable category,
                                MTLLogLevel logLevel, NSString *message))block {
    if (block == nil) return;
    @synchronized (self) {
        [_handlers addObject:[block copy]];
    }
}
@end
#pragma clang diagnostic pop

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

@implementation ZPUArgument
- (instancetype)initWithName:(NSString *)name type:(MTLArgumentType)type
                       access:(MTLBindingAccess)access index:(NSUInteger)index {
    if ((self = [super init])) {
        _name = [name copy];
        _type = type;
        _access = access;
        _index = index;
        _active = YES;
        _bufferAlignment = 1;
        _textureType = MTLTextureType2D;
        _textureDataType = MTLDataTypeFloat;
        _arrayLength = 1;
    }
    return self;
}
- (NSString *)name { return _name; }
- (MTLArgumentType)type { return _type; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)index { return _index; }
- (BOOL)isActive { return _active; }
- (NSUInteger)bufferAlignment { return _bufferAlignment; }
- (NSUInteger)bufferDataSize { return _bufferDataSize; }
- (MTLDataType)bufferDataType { return _bufferDataType; }
- (MTLStructType *)bufferStructType { return nil; }
- (MTLPointerType *)bufferPointerType API_AVAILABLE(macos(10.13), ios(11.0)) { return nil; }
- (NSUInteger)threadgroupMemoryAlignment { return 0; }
- (NSUInteger)threadgroupMemoryDataSize { return 0; }
- (MTLTextureType)textureType { return _textureType; }
- (MTLDataType)textureDataType { return _textureDataType; }
- (BOOL)isDepthTexture API_AVAILABLE(macos(10.12), ios(10.0)) { return _depthTexture; }
- (NSUInteger)arrayLength API_AVAILABLE(macos(10.13), ios(10.0)) { return _arrayLength; }
- (void)setBufferDataSize:(NSUInteger)size dataType:(MTLDataType)dataType {
    _bufferDataSize = size;
    _bufferDataType = dataType;
}
- (void)setTextureType:(MTLTextureType)textureType dataType:(MTLDataType)dataType arrayLength:(NSUInteger)arrayLength {
    _textureType = textureType;
    _textureDataType = dataType;
    _arrayLength = arrayLength;
}
@end

@implementation ZPUBinding
- (instancetype)initWithName:(NSString *)name type:(MTLBindingType)type
                       access:(MTLBindingAccess)access index:(NSUInteger)index {
    if ((self = [super init])) {
        _name = [name copy];
        _type = type;
        _access = access;
        _index = index;
        _bufferAlignment = 1;
        _textureType = MTLTextureType2D;
        _textureDataType = MTLDataTypeFloat;
        _arrayLength = 1;
    }
    return self;
}
- (NSString *)name { return _name; }
- (MTLBindingType)type { return _type; }
- (MTLBindingAccess)access { return _access; }
- (NSUInteger)index { return _index; }
- (BOOL)isUsed { return YES; }
- (BOOL)isArgument { return YES; }
- (NSUInteger)bufferAlignment { return _bufferAlignment; }
- (NSUInteger)bufferDataSize { return _bufferDataSize; }
- (MTLDataType)bufferDataType { return _bufferDataType; }
- (MTLStructType *)bufferStructType { return nil; }
- (MTLPointerType *)bufferPointerType { return nil; }
- (MTLTextureType)textureType { return _textureType; }
- (MTLDataType)textureDataType { return _textureDataType; }
- (BOOL)isDepthTexture { return _depthTexture; }
- (NSUInteger)arrayLength { return _arrayLength; }
- (void)setBufferDataSize:(NSUInteger)size dataType:(MTLDataType)dataType {
    _bufferDataSize = size;
    _bufferDataType = dataType;
}
- (void)setTextureType:(MTLTextureType)textureType dataType:(MTLDataType)dataType arrayLength:(NSUInteger)arrayLength {
    _textureType = textureType;
    _textureDataType = dataType;
    _arrayLength = arrayLength;
}
@end

@implementation ZPUComputePipelineReflection
- (instancetype)initWithArguments:(NSArray *)arguments bindings:(NSArray *)bindings {
    if ((self = [super init])) {
        _arguments = [arguments copy];
        _bindings = [bindings copy];
    }
    return self;
}
- (NSArray<id<MTLBinding>> *)bindings API_AVAILABLE(macos(13.0), ios(16.0)) { return _bindings; }
- (NSArray<MTLArgument *> *)arguments { return _arguments; }
@end

@implementation ZPURenderPipelineReflection
- (instancetype)initWithVertexArguments:(NSArray *)vertexArguments
                        fragmentArguments:(NSArray *)fragmentArguments
                           vertexBindings:(NSArray *)vertexBindings
                         fragmentBindings:(NSArray *)fragmentBindings {
    if ((self = [super init])) {
        _vertexArguments = [vertexArguments copy];
        _fragmentArguments = [fragmentArguments copy];
        _vertexBindings = [vertexBindings copy];
        _fragmentBindings = [fragmentBindings copy];
    }
    return self;
}
- (NSArray<id<MTLBinding>> *)vertexBindings API_AVAILABLE(macos(13.0), ios(16.0)) { return _vertexBindings; }
- (NSArray<id<MTLBinding>> *)fragmentBindings API_AVAILABLE(macos(13.0), ios(16.0)) { return _fragmentBindings; }
- (NSArray<id<MTLBinding>> *)tileBindings API_AVAILABLE(macos(13.0), ios(16.0)) { return @[]; }
- (NSArray<id<MTLBinding>> *)objectBindings API_AVAILABLE(macos(13.0), ios(16.0)) { return @[]; }
- (NSArray<id<MTLBinding>> *)meshBindings API_AVAILABLE(macos(13.0), ios(16.0)) { return @[]; }
- (NSArray<MTLArgument *> *)vertexArguments { return _vertexArguments; }
- (NSArray<MTLArgument *> *)fragmentArguments { return _fragmentArguments; }
- (NSArray<MTLArgument *> *)tileArguments { return @[]; }
@end

@implementation ZPUFunctionReflection
- (instancetype)initWithBindings:(NSArray *)bindings userAnnotation:(NSString *)userAnnotation {
    if ((self = [super init])) {
        _bindings = [bindings copy];
        _userAnnotation = [userAnnotation copy];
    }
    return self;
}
- (NSArray<id<MTLBinding>> *)bindings { return _bindings; }
- (NSString *)userAnnotation { return _userAnnotation; }
@end

static ZPUArgument *zpu_reflection_argument(NSString *name, MTLArgumentType type,
                                              MTLBindingAccess access, NSUInteger index) {
    return [[ZPUArgument alloc] initWithName:name type:type access:access index:index];
}

API_AVAILABLE(macos(13.0), ios(16.0))
static ZPUBinding *zpu_reflection_binding(NSString *name, MTLBindingType type,
                                           MTLBindingAccess access, NSUInteger index) {
    return [[ZPUBinding alloc] initWithName:name type:type access:access index:index];
}

API_AVAILABLE(macos(26.0), ios(26.0))
static MTLComputePipelineReflection *zpu_compute_pipeline_reflection(zpu_metal_compute_kernel kernel) {
    NSMutableArray *arguments = [NSMutableArray array];
    NSMutableArray *bindings = [NSMutableArray array];
    if (kernel == ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE) {
        ZPUArgument *source = zpu_reflection_argument(@"source", MTLArgumentTypeBuffer,
                                                       MTLBindingAccessReadOnly, 0);
        [source setBufferDataSize:sizeof(uint32_t) dataType:MTLDataTypeUChar4];
        ZPUBinding *sourceBinding = zpu_reflection_binding(@"source", MTLBindingTypeBuffer,
                                                            MTLBindingAccessReadOnly, 0);
        [sourceBinding setBufferDataSize:sizeof(uint32_t) dataType:MTLDataTypeUChar4];
        [arguments addObject:source];
        [bindings addObject:sourceBinding];

        ZPUArgument *output = zpu_reflection_argument(@"output", MTLArgumentTypeTexture,
                                                       MTLBindingAccessWriteOnly, 1);
        [output setTextureType:MTLTextureType2D dataType:MTLDataTypeFloat arrayLength:1];
        ZPUBinding *outputBinding = zpu_reflection_binding(@"output", MTLBindingTypeTexture,
                                                            MTLBindingAccessWriteOnly, 1);
        [outputBinding setTextureType:MTLTextureType2D dataType:MTLDataTypeFloat arrayLength:1];
        [arguments addObject:output];
        [bindings addObject:outputBinding];
    } else if (kernel != 0) {
        const BOOL arrayTexture = kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
        const BOOL volumeTexture = kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D;
        const MTLTextureType textureType = volumeTexture ? MTLTextureType3D :
            (arrayTexture ? MTLTextureType2DArray : MTLTextureType2D);
        ZPUArgument *output = zpu_reflection_argument(@"output", MTLArgumentTypeTexture,
                                                       MTLBindingAccessWriteOnly, 0);
        [output setTextureType:textureType dataType:MTLDataTypeFloat
                   arrayLength:arrayTexture ? 0 : 1];
        ZPUBinding *outputBinding = zpu_reflection_binding(@"output", MTLBindingTypeTexture,
                                                            MTLBindingAccessWriteOnly, 0);
        [outputBinding setTextureType:textureType dataType:MTLDataTypeFloat
                           arrayLength:arrayTexture ? 0 : 1];
        [arguments addObject:output];
        [bindings addObject:outputBinding];
    }
    return (MTLComputePipelineReflection *)[[ZPUComputePipelineReflection alloc]
        initWithArguments:arguments bindings:bindings];
}

API_AVAILABLE(macos(26.0), ios(26.0))
static MTLRenderPipelineReflection *zpu_render_pipeline_reflection(NSString *vertexName,
                                                                     NSString *fragmentName) {
    NSMutableArray *vertexArguments = [NSMutableArray array];
    NSMutableArray *fragmentArguments = [NSMutableArray array];
    NSMutableArray *vertexBindings = [NSMutableArray array];
    NSMutableArray *fragmentBindings = [NSMutableArray array];
    ZPUArgument *vertices = zpu_reflection_argument(@"vertices", MTLArgumentTypeBuffer,
                                                     MTLBindingAccessReadOnly, 0);
    [vertices setBufferDataSize:sizeof(zpu_metal_vertex) dataType:MTLDataTypeStruct];
    ZPUBinding *verticesBinding = zpu_reflection_binding(@"vertices", MTLBindingTypeBuffer,
                                                          MTLBindingAccessReadOnly, 0);
    [verticesBinding setBufferDataSize:sizeof(zpu_metal_vertex) dataType:MTLDataTypeStruct];
    if (vertexName.length != 0) {
        [vertexArguments addObject:vertices];
        [vertexBindings addObject:verticesBinding];
    }
    if ([fragmentName isEqualToString:@"zpu_cpu_uniform_color_fragment"]) {
        ZPUArgument *uniform = zpu_reflection_argument(@"uniformColor", MTLArgumentTypeBuffer,
                                                        MTLBindingAccessReadOnly, 0);
        [uniform setBufferDataSize:sizeof(float) * 4 dataType:MTLDataTypeFloat4];
        ZPUBinding *uniformBinding = zpu_reflection_binding(@"uniformColor", MTLBindingTypeBuffer,
                                                             MTLBindingAccessReadOnly, 0);
        [uniformBinding setBufferDataSize:sizeof(float) * 4 dataType:MTLDataTypeFloat4];
        [fragmentArguments addObject:uniform];
        [fragmentBindings addObject:uniformBinding];
    } else if ([fragmentName isEqualToString:@"zpu_test_sample_fragment"]) {
        ZPUArgument *source = zpu_reflection_argument(@"source", MTLArgumentTypeTexture,
                                                       MTLBindingAccessReadOnly, 0);
        [source setTextureType:MTLTextureType2D dataType:MTLDataTypeFloat arrayLength:1];
        ZPUBinding *sourceBinding = zpu_reflection_binding(@"source", MTLBindingTypeTexture,
                                                            MTLBindingAccessReadOnly, 0);
        [sourceBinding setTextureType:MTLTextureType2D dataType:MTLDataTypeFloat arrayLength:1];
        [fragmentArguments addObject:source];
        [fragmentBindings addObject:sourceBinding];
        ZPUArgument *sampler = zpu_reflection_argument(@"sourceSampler", MTLArgumentTypeSampler,
                                                        MTLBindingAccessReadOnly, 0);
        ZPUBinding *samplerBinding = zpu_reflection_binding(@"sourceSampler", MTLBindingTypeSampler,
                                                             MTLBindingAccessReadOnly, 0);
        [fragmentArguments addObject:sampler];
        [fragmentBindings addObject:samplerBinding];
    }
    return (MTLRenderPipelineReflection *)[[ZPURenderPipelineReflection alloc]
        initWithVertexArguments:vertexArguments fragmentArguments:fragmentArguments
                 vertexBindings:vertexBindings fragmentBindings:fragmentBindings];
}

API_AVAILABLE(macos(26.0), ios(26.0))
static MTLFunctionReflection *zpu_function_reflection(NSString *name) {
    if ([name isEqualToString:@"zpu_test_no_raster_vertex"]) {
        return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
            initWithBindings:@[] userAnnotation:nil];
    }
    if ([name isEqualToString:@"zpu_test_vertex"]) {
        ZPUBinding *binding = zpu_reflection_binding(@"vertices", MTLBindingTypeBuffer,
                                                      MTLBindingAccessReadOnly, 0);
        [binding setBufferDataSize:sizeof(zpu_metal_vertex) dataType:MTLDataTypeStruct];
        return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
            initWithBindings:@[binding] userAnnotation:nil];
    }
    if ([name isEqualToString:@"zpu_cpu_uniform_color_fragment"]) {
        ZPUBinding *binding = zpu_reflection_binding(@"uniformColor", MTLBindingTypeBuffer,
                                                      MTLBindingAccessReadOnly, 0);
        [binding setBufferDataSize:sizeof(float) * 4 dataType:MTLDataTypeFloat4];
        return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
            initWithBindings:@[binding] userAnnotation:nil];
    }
    if ([name isEqualToString:@"zpu_test_sample_fragment"]) {
        ZPUBinding *source = zpu_reflection_binding(@"source", MTLBindingTypeTexture,
                                                     MTLBindingAccessReadOnly, 0);
        [source setTextureType:MTLTextureType2D dataType:MTLDataTypeFloat arrayLength:1];
        ZPUBinding *sampler = zpu_reflection_binding(@"sourceSampler", MTLBindingTypeSampler,
                                                      MTLBindingAccessReadOnly, 0);
        return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
            initWithBindings:@[source, sampler] userAnnotation:nil];
    }
    if ([name hasPrefix:@"zpu_test_"] && [name rangeOfString:@"fragment" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
            initWithBindings:@[] userAnnotation:nil];
    }
    if ([name hasPrefix:@"zpu_cpu_"]) {
        zpu_metal_compute_kernel kernel = 0;
        if ([name isEqualToString:@"zpu_cpu_fill_gradient_rgba8"]) kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8;
        else if ([name isEqualToString:@"zpu_cpu_copy_rgba8_buffer_to_texture"]) kernel = ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE;
        else if ([name isEqualToString:@"zpu_cpu_fill_gradient_rgba8_array"]) kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
        else if ([name isEqualToString:@"zpu_cpu_fill_gradient_rgba8_3d"]) kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D;
        else if ([name isEqualToString:@"zpu_cpu_fill_gradient_r32_float"]) kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT;
        else if ([name isEqualToString:@"zpu_cpu_fill_gradient_rgba16_float"]) kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT;
        if (kernel != 0) {
            MTLComputePipelineReflection *reflection = zpu_compute_pipeline_reflection(kernel);
            return (MTLFunctionReflection *)[[ZPUFunctionReflection alloc]
                initWithBindings:reflection.bindings userAnnotation:nil];
        }
    }
    return nil;
}

#pragma clang diagnostic pop

@implementation ZPURenderPipelineState
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRenderPipelineDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        MTLRenderPipelineColorAttachmentDescriptor *attachment = descriptor.colorAttachments[0];
        _vertexFunctionName = [descriptor.vertexFunction.name copy];
        _fragmentFunctionName = [descriptor.fragmentFunction.name copy];
        _colorPixelFormat = attachment.pixelFormat;
        _colorAttachmentCount = 0;
        for (NSUInteger index = 0; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
            _colorPixelFormats[index] = descriptor.colorAttachments[index].pixelFormat;
            if (_colorPixelFormats[index] != MTLPixelFormatInvalid) _colorAttachmentCount = index + 1;
        }
        _multiTargetOutput = [descriptor.fragmentFunction.name rangeOfString:@"mrt" options:NSCaseInsensitiveSearch].location != NSNotFound;
        _sampleTexture = [descriptor.fragmentFunction.name rangeOfString:@"sample" options:NSCaseInsensitiveSearch].location != NSNotFound;
        _fragmentUniform = [descriptor.fragmentFunction.name isEqualToString:@"zpu_cpu_uniform_color_fragment"];
        _rasterizationEnabled = descriptor.rasterizationEnabled;
        _supportsIndirectCommandBuffers = descriptor.supportIndirectCommandBuffers;
        _depthPixelFormat = descriptor.depthAttachmentPixelFormat;
        _stencilPixelFormat = descriptor.stencilAttachmentPixelFormat;
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
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
- (BOOL)supportIndirectCommandBuffers API_AVAILABLE(macos(10.14), ios(12.0)) { return _supportsIndirectCommandBuffers; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){0}; }
- (MTLShaderValidation)shaderValidation API_AVAILABLE(macos(15.0), ios(18.0)) { return (MTLShaderValidation)0; }
- (MTLSize)requiredThreadsPerTileThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (MTLSize)requiredThreadsPerObjectThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (MTLSize)requiredThreadsPerMeshThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return MTLSizeMake(0, 0, 0); }
- (id<MTLFunctionHandle>)functionHandleWithFunction:(id<MTLFunction>)function stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    ZPUCPUFunction *cpuFunction = (ZPUCPUFunction *)function;
    if (![cpuFunction isKindOfClass:[ZPUCPUFunction class]] || cpuFunction->_owner != _owner) return nil;
    NSString *expectedName = stage == MTLRenderStageVertex ? _vertexFunctionName :
        (stage == MTLRenderStageFragment ? _fragmentFunctionName : nil);
    MTLFunctionType expectedType = stage == MTLRenderStageVertex ? MTLFunctionTypeVertex :
        (stage == MTLRenderStageFragment ? MTLFunctionTypeFragment : MTLFunctionTypeKernel);
    if (expectedName == nil || ![expectedName isEqualToString:cpuFunction.name] ||
        cpuFunction.functionType != expectedType) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:_owner
                                                                        name:expectedName
                                                                 functionType:expectedType];
}
- (id<MTLVisibleFunctionTable>)newVisibleFunctionTableWithDescriptor:(MTLVisibleFunctionTableDescriptor *)descriptor stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    if (descriptor == nil) return nil;
    return (id<MTLVisibleFunctionTable>)[[ZPUVisibleFunctionTable alloc]
        initWithOwner:_owner functionCount:descriptor.functionCount stage:stage];
}
- (id<MTLIntersectionFunctionTable>)newIntersectionFunctionTableWithDescriptor:(MTLIntersectionFunctionTableDescriptor *)descriptor stage:(MTLRenderStages)stage API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) {
    (void)stage;
    if (descriptor == nil) return nil;
    return (id<MTLIntersectionFunctionTable>)[[ZPUIntersectionFunctionTable alloc]
        initWithOwner:_owner functionCount:descriptor.functionCount];
}
- (MTLRenderPipelineReflection *)reflection API_AVAILABLE(macos(26.0), ios(26.0)) { return _reflection; }
- (id<MTLFunctionHandle>)functionHandleWithName:(NSString *)name stage:(MTLRenderStages)stage API_AVAILABLE(macos(26.0), ios(26.0)) {
    NSString *expectedName = stage == MTLRenderStageVertex ? _vertexFunctionName :
        (stage == MTLRenderStageFragment ? _fragmentFunctionName : nil);
    MTLFunctionType expectedType = stage == MTLRenderStageVertex ? MTLFunctionTypeVertex :
        (stage == MTLRenderStageFragment ? MTLFunctionTypeFragment : MTLFunctionTypeKernel);
    if (expectedName == nil || ![expectedName isEqualToString:name]) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:_owner
                                                                        name:expectedName
                                                                 functionType:expectedType];
}
- (id<MTLFunctionHandle>)functionHandleWithBinaryFunction:(id<MTL4BinaryFunction>)function stage:(MTLRenderStages)stage API_AVAILABLE(macos(26.0), ios(26.0)) {
    ZPUMTL4BinaryFunction *binary = (ZPUMTL4BinaryFunction *)function;
    if (![binary isKindOfClass:[ZPUMTL4BinaryFunction class]] || binary->_owner != _owner) return nil;
    NSString *expectedName = stage == MTLRenderStageVertex ? _vertexFunctionName :
        (stage == MTLRenderStageFragment ? _fragmentFunctionName : nil);
    MTLFunctionType expectedType = stage == MTLRenderStageVertex ? MTLFunctionTypeVertex :
        (stage == MTLRenderStageFragment ? MTLFunctionTypeFragment : MTLFunctionTypeKernel);
    if (expectedName == nil || ![expectedName isEqualToString:binary->_name] ||
        binary->_functionType != expectedType) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:_owner
                                                                        name:expectedName
                                                                 functionType:expectedType];
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
        _label = [descriptor.label copy];
        _depthCompareFunction = descriptor.depthCompareFunction;
        _depthWriteEnabled = descriptor.depthWriteEnabled;
        MTLStencilDescriptor *front = descriptor.frontFaceStencil;
        MTLStencilDescriptor *back = descriptor.backFaceStencil;
        _frontStencilCompareFunction = front.stencilCompareFunction;
        _frontStencilFailureOperation = front.stencilFailureOperation;
        _frontDepthFailureOperation = front.depthFailureOperation;
        _frontDepthStencilPassOperation = front.depthStencilPassOperation;
        _frontStencilReadMask = front.readMask;
        _frontStencilWriteMask = front.writeMask;
        _backStencilCompareFunction = back.stencilCompareFunction;
        _backStencilFailureOperation = back.stencilFailureOperation;
        _backDepthFailureOperation = back.depthFailureOperation;
        _backDepthStencilPassOperation = back.depthStencilPassOperation;
        _backStencilReadMask = back.readMask;
        _backStencilWriteMask = back.writeMask;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(26.0), ios(26.0)) { return (MTLResourceID){0}; }
@end

@implementation ZPUSamplerState
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLSamplerDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _minFilter = descriptor.minFilter;
        _magFilter = descriptor.magFilter;
        _mipFilter = descriptor.mipFilter;
        _sAddressMode = descriptor.sAddressMode;
        _tAddressMode = descriptor.tAddressMode;
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){_resourceID}; }
@end

static BOOL zpu_rasterization_rate_layer_is_identity(MTLRasterizationRateLayerDescriptor *layer) {
    if (layer == nil) return NO;
    const MTLSize count = layer.sampleCount;
    if (count.width == 0 || count.height == 0) return NO;
    const float *horizontal = layer.horizontalSampleStorage;
    const float *vertical = layer.verticalSampleStorage;
    if (horizontal == NULL || vertical == NULL) return NO;
    for (NSUInteger index = 0; index < count.width; ++index) {
        if (!isfinite(horizontal[index]) || horizontal[index] != 1.0f) return NO;
    }
    for (NSUInteger index = 0; index < count.height; ++index) {
        if (!isfinite(vertical[index]) || vertical[index] != 1.0f) return NO;
    }
    return YES;
}

@implementation ZPURasterizationRateMap
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLRasterizationRateMapDescriptor *)descriptor {
    if (owner == nil || descriptor == nil || descriptor.screenSize.width == 0 || descriptor.screenSize.height == 0) return nil;
    for (NSUInteger index = 0; index < descriptor.layerCount; ++index) {
        if (!zpu_rasterization_rate_layer_is_identity([descriptor layerAtIndex:index])) return nil;
    }
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _screenSize = MTLSizeMake(descriptor.screenSize.width, descriptor.screenSize.height, 0);
        /* Apple GPU rate maps report a 32x32 physical granularity even for
         * an identity 1:1 map. Preserve that observable descriptor property
         * while the CPU rasterizer still writes every pixel individually. */
        _physicalGranularity = MTLSizeMake(32, 32, 0);
        _layerCount = descriptor.layerCount;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (MTLSize)screenSize { return _screenSize; }
- (MTLSize)physicalGranularity { return _physicalGranularity; }
- (NSUInteger)layerCount { return _layerCount; }
- (MTLSizeAndAlign)parameterBufferSizeAndAlign { return (MTLSizeAndAlign){0, 1}; }
- (void)copyParameterDataToBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (!zpu_buffer_belongs_to_device(_owner, zpuBuffer) || offset > zpuBuffer.length) return;
}
- (MTLSize)physicalSizeForLayer:(NSUInteger)layerIndex {
    return layerIndex < _layerCount ? _screenSize : MTLSizeMake(0, 0, 0);
}
- (MTLCoordinate2D)mapScreenToPhysicalCoordinates:(MTLCoordinate2D)screenCoordinates forLayer:(NSUInteger)layerIndex {
    return layerIndex < _layerCount ? screenCoordinates : (MTLCoordinate2D){0, 0};
}
- (MTLCoordinate2D)mapPhysicalToScreenCoordinates:(MTLCoordinate2D)physicalCoordinates forLayer:(NSUInteger)layerIndex {
    return layerIndex < _layerCount ? physicalCoordinates : (MTLCoordinate2D){0, 0};
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

static BOOL zpu_io_data_range(NSData *data, NSUInteger offset, NSUInteger length) {
    return data != nil && offset <= data.length && length <= data.length - offset;
}

static BOOL zpu_io_texture_load(ZPUTexture *texture, NSUInteger slice, NSUInteger level,
                                MTLSize size, NSUInteger sourceBytesPerRow,
                                NSUInteger sourceBytesPerImage, MTLOrigin destinationOrigin,
                                NSData *data, NSUInteger sourceHandleOffset, NSError **error) {
    if (!zpu_texture_type_is_supported(texture->_textureType) ||
        texture->_pixelFormat == MTLPixelFormatInvalid || size.width == 0 || size.height == 0 || size.depth == 0 ||
        destinationOrigin.x > UINT32_MAX || destinationOrigin.y > UINT32_MAX || destinationOrigin.z > UINT32_MAX ||
        size.width > UINT32_MAX || size.height > UINT32_MAX || size.depth > UINT32_MAX) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture load has an invalid texture region");
        return NO;
    }
    const BOOL is3D = zpu_texture_type_is_3d(texture->_textureType);
    if (is3D) {
        if (slice != 0 || destinationOrigin.z > zpu_texture_depth_at_level(texture, level) ||
            size.depth > zpu_texture_depth_at_level(texture, level) - destinationOrigin.z) {
            zpu_set_error(error, @"ZPU CPU Metal I/O 3D texture load has an invalid slice or depth");
            return NO;
        }
    } else if (destinationOrigin.z != 0 || size.depth != 1) {
        zpu_set_error(error, @"ZPU CPU Metal I/O array texture load must address one slice");
        return NO;
    }
    zpu_metal_texture *firstTexture = [texture zpuTextureAtLevel:level slice:is3D ? 0 : slice];
    if (firstTexture == NULL) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture level or slice is invalid");
        return NO;
    }
    const NSUInteger textureWidth = zpu_metal_texture_width(firstTexture);
    const NSUInteger textureHeight = zpu_metal_texture_height(firstTexture);
    if (destinationOrigin.x > textureWidth || size.width > textureWidth - destinationOrigin.x ||
        destinationOrigin.y > textureHeight || size.height > textureHeight - destinationOrigin.y) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture load is outside the destination texture");
        return NO;
    }
    const NSUInteger bytesPerPixel = zpu_texture_bytes_per_pixel(texture->_pixelFormat);
    if (bytesPerPixel == 0 || size.width > SIZE_MAX / bytesPerPixel) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture load row size overflows");
        return NO;
    }
    const NSUInteger rowBytes = size.width * bytesPerPixel;
    const NSUInteger rowStride = sourceBytesPerRow == 0 ? rowBytes : sourceBytesPerRow;
    if (rowStride < rowBytes || size.height > SIZE_MAX / rowStride) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture load has an invalid source row stride");
        return NO;
    }
    const NSUInteger rowsBytes = rowStride * size.height;
    const NSUInteger imageStride = sourceBytesPerImage == 0 ? rowsBytes : sourceBytesPerImage;
    if (imageStride < rowsBytes || size.depth - 1 > SIZE_MAX / imageStride) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture load has an invalid source image stride");
        return NO;
    }
    const NSUInteger lastPlaneOffset = (size.depth - 1) * imageStride;
    const NSUInteger lastRowOffset = (size.height - 1) * rowStride;
    if (lastPlaneOffset > SIZE_MAX - lastRowOffset ||
        lastPlaneOffset + lastRowOffset > SIZE_MAX - rowBytes ||
        !zpu_io_data_range(data, sourceHandleOffset, lastPlaneOffset + lastRowOffset + rowBytes)) {
        zpu_set_error(error, @"ZPU CPU Metal I/O texture source range is outside the file");
        return NO;
    }
    const uint8_t *source = (const uint8_t *)data.bytes + sourceHandleOffset;
    for (NSUInteger plane = 0; plane < size.depth; ++plane) {
        const NSUInteger planeOffset = plane * imageStride;
        zpu_metal_texture *destination = [texture zpuTextureAtLevel:level
                                                                 slice:is3D ? destinationOrigin.z + plane : slice];
        if (destination == NULL || zpu_metal_texture_replace_region(
                destination,
                (zpu_metal_region){
                    .origin = {(uint32_t)destinationOrigin.x, (uint32_t)destinationOrigin.y, 0},
                    .size = {(uint32_t)size.width, (uint32_t)size.height, 1},
                },
                source + planeOffset, data.length - sourceHandleOffset - planeOffset,
                rowStride) != ZPU_METAL_OK) {
            zpu_set_error(error, @"ZPU CPU Metal I/O texture write failed");
            return NO;
        }
    }
    return YES;
}

@implementation ZPUIOFileHandle
- (instancetype)initWithOwner:(ZPUDevice *)owner url:(NSURL *)url error:(NSError **)error {
    if (owner == nil || url == nil || !url.isFileURL) {
        zpu_set_error(error, @"ZPU CPU Metal I/O handle requires a file URL");
        return nil;
    }
    NSError *readError = nil;
    NSData *data = [NSData dataWithContentsOfURL:url options:0 error:&readError];
    if (data == nil) {
        if (error != NULL) *error = readError != nil ? readError : [NSError errorWithDomain:@"ZPUMetal"
            code:ZPU_METAL_INVALID_ARGUMENT userInfo:@{NSLocalizedDescriptionKey: @"ZPU CPU Metal I/O file could not be read"}];
        return nil;
    }
    if ((self = [super init])) {
        _owner = owner;
        _data = data;
    }
    if (error != NULL) *error = nil;
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
@end

@implementation ZPUIOCommandBuffer
- (instancetype)initWithOwner:(ZPUIOCommandQueue *)owner {
    if ((self = [super init])) {
        _owner = owner;
        _operations = [NSMutableArray array];
        _statusTargets = [NSMutableArray array];
        _completedHandlers = [NSMutableArray array];
        _status = MTLIOStatusPending;
    }
    return self;
}
- (void)addOperation:(ZPUIOOperationBlock)operation {
    if (!_committed && !_cancelRequested && operation != nil) [_operations addObject:[operation copy]];
}
- (void)addFailure:(NSString *)message {
    [self addOperation:^BOOL(NSError **error) {
        zpu_set_error(error, message);
        return NO;
    }];
}
- (void)notifyCompleted {
    NSArray *handlers = [_completedHandlers copy];
    [_completedHandlers removeAllObjects];
    for (MTLIOCommandBufferHandler block in handlers) block((id<MTLIOCommandBuffer>)self);
}
- (void)addCompletedHandler:(MTLIOCommandBufferHandler)block {
    if (block == nil) return;
    if (_status != MTLIOStatusPending) {
        block((id<MTLIOCommandBuffer>)self);
        return;
    }
    [_completedHandlers addObject:[block copy]];
}
- (void)loadBytes:(void *)pointer size:(NSUInteger)size sourceHandle:(id<MTLIOFileHandle>)sourceHandle sourceHandleOffset:(NSUInteger)sourceHandleOffset {
    ZPUIOFileHandle *handle = (ZPUIOFileHandle *)sourceHandle;
    if (![handle isKindOfClass:[ZPUIOFileHandle class]] || handle->_owner != _owner->_owner ||
        (pointer == NULL && size != 0)) {
        [self addFailure:@"ZPU CPU Metal I/O loadBytes requires a same-device raw file handle and destination pointer"];
        return;
    }
    NSData *data = handle->_data;
    [self addOperation:^BOOL(NSError **error) {
        if (!zpu_io_data_range(data, sourceHandleOffset, size)) {
            zpu_set_error(error, @"ZPU CPU Metal I/O byte source range is outside the file");
            return NO;
        }
        if (size != 0) memcpy(pointer, (const uint8_t *)data.bytes + sourceHandleOffset, size);
        return YES;
    }];
}
- (void)loadBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset size:(NSUInteger)size sourceHandle:(id<MTLIOFileHandle>)sourceHandle sourceHandleOffset:(NSUInteger)sourceHandleOffset {
    ZPUIOFileHandle *handle = (ZPUIOFileHandle *)sourceHandle;
    ZPUBuffer *destination = (ZPUBuffer *)buffer;
    if (![handle isKindOfClass:[ZPUIOFileHandle class]] || handle->_owner != _owner->_owner ||
        !zpu_buffer_belongs_to_device(_owner->_owner, destination) || offset > destination.length ||
        size > destination.length - offset) {
        [self addFailure:@"ZPU CPU Metal I/O loadBuffer requires same-device file and buffer ranges"];
        return;
    }
    NSData *data = handle->_data;
    [self addOperation:^BOOL(NSError **error) {
        if (!zpu_io_data_range(data, sourceHandleOffset, size) ||
            zpu_metal_buffer_write(destination->_zpuBuffer, offset,
                                   (const uint8_t *)data.bytes + sourceHandleOffset, size) != ZPU_METAL_OK) {
            zpu_set_error(error, @"ZPU CPU Metal I/O buffer write failed");
            return NO;
        }
        return YES;
    }];
}
- (void)loadTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level size:(MTLSize)size sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage destinationOrigin:(MTLOrigin)destinationOrigin sourceHandle:(id<MTLIOFileHandle>)sourceHandle sourceHandleOffset:(NSUInteger)sourceHandleOffset {
    ZPUIOFileHandle *handle = (ZPUIOFileHandle *)sourceHandle;
    ZPUTexture *destination = (ZPUTexture *)texture;
    if (![handle isKindOfClass:[ZPUIOFileHandle class]] || handle->_owner != _owner->_owner ||
        !zpu_texture_belongs_to_device(_owner->_owner, destination)) {
        [self addFailure:@"ZPU CPU Metal I/O loadTexture requires same-device file and texture resources"];
        return;
    }
    NSData *data = handle->_data;
    [self addOperation:^BOOL(NSError **error) {
        return zpu_io_texture_load(destination, slice, level, size, sourceBytesPerRow,
                                   sourceBytesPerImage, destinationOrigin, data, sourceHandleOffset, error);
    }];
}
- (void)copyStatusToBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset {
    ZPUBuffer *destination = (ZPUBuffer *)buffer;
    if (!zpu_buffer_belongs_to_device(_owner->_owner, destination) || offset > destination.length ||
        sizeof(uint32_t) > destination.length - offset) {
        [self addFailure:@"ZPU CPU Metal I/O copyStatusToBuffer requires a same-device buffer range"];
        return;
    }
    [_statusTargets addObject:@[destination, @(offset)]];
}
- (void)commit {
    if (_committed) return;
    _committed = YES;
    if (_cancelRequested) {
        _status = MTLIOStatusCancelled;
        [self notifyCompleted];
        return;
    }
    for (ZPUIOOperationBlock operation in [_operations copy]) {
        NSError *operationError = nil;
        if (!operation(&operationError)) {
            _error = operationError != nil ? operationError : [NSError errorWithDomain:@"ZPUMetal"
                code:ZPU_METAL_INVALID_COMMAND userInfo:@{NSLocalizedDescriptionKey: @"ZPU CPU Metal I/O operation failed"}];
            _status = MTLIOStatusError;
            break;
        }
    }
    if (_status == MTLIOStatusPending) _status = MTLIOStatusComplete;
    const uint32_t statusValue = (uint32_t)_status;
    for (NSArray *target in _statusTargets) {
        ZPUBuffer *buffer = target[0];
        const NSUInteger offset = [target[1] unsignedIntegerValue];
        if (zpu_metal_buffer_write(buffer->_zpuBuffer, offset, &statusValue, sizeof(statusValue)) != ZPU_METAL_OK &&
            _status == MTLIOStatusComplete) {
            _status = MTLIOStatusError;
            _error = [NSError errorWithDomain:@"ZPUMetal" code:ZPU_METAL_INVALID_COMMAND
                userInfo:@{NSLocalizedDescriptionKey: @"ZPU CPU Metal I/O status write failed"}];
        }
    }
    [self notifyCompleted];
}
- (void)waitUntilCompleted { [self commit]; }
- (void)tryCancel {
    if (_committed) return;
    _cancelRequested = YES;
    [self commit];
}
- (void)addBarrier {}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)enqueue { [self commit]; }
- (void)waitForEvent:(id<MTLSharedEvent>)event value:(uint64_t)value {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != _owner->_owner) {
        [self addFailure:@"ZPU CPU Metal I/O waitForEvent requires a same-device shared event"];
        return;
    }
    [self addOperation:^BOOL(NSError **error) {
        if (![zpuEvent waitUntilSignaledValue:value timeoutMS:UINT64_MAX]) {
            zpu_set_error(error, @"ZPU CPU Metal I/O shared-event wait failed");
            return NO;
        }
        return YES;
    }];
}
- (void)signalEvent:(id<MTLSharedEvent>)event value:(uint64_t)value {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != _owner->_owner) {
        [self addFailure:@"ZPU CPU Metal I/O signalEvent requires a same-device shared event"];
        return;
    }
    [self addOperation:^BOOL(NSError **error) {
        if (value < zpuEvent.signaledValue) {
            zpu_set_error(error, @"ZPU CPU Metal I/O shared-event value cannot decrease");
            return NO;
        }
        zpuEvent.signaledValue = value;
        return YES;
    }];
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (MTLIOStatus)status { return _status; }
- (NSError *)error { return _error; }
@end

@implementation ZPUIOCommandQueue
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLIOCommandQueueDescriptor *)descriptor {
    if (owner == nil || descriptor == nil) return nil;
    if ((self = [super init])) {
        _owner = owner;
        _maxCommandBufferCount = descriptor.maxCommandBufferCount;
        _priority = descriptor.priority;
        _type = descriptor.type;
        _maxCommandsInFlight = descriptor.maxCommandsInFlight;
        _scratchBufferAllocator = descriptor.scratchBufferAllocator;
    }
    return self;
}
- (void)enqueueBarrier {}
- (id<MTLIOCommandBuffer>)commandBuffer {
    return (id<MTLIOCommandBuffer>)[[ZPUIOCommandBuffer alloc] initWithOwner:self];
}
- (id<MTLIOCommandBuffer>)commandBufferWithUnretainedReferences { return [self commandBuffer]; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
@end

#pragma clang diagnostic pop

@implementation ZPUDevice
- (instancetype)initWithDevice:(zpu_metal_device *)device {
    if ((self = [super init])) {
        _zpuDevice = device;
        ZPUCounter *timestampCounter = [[ZPUCounter alloc] initWithName:MTLCommonCounterTimestamp];
        ZPUCounterSet *timestampSet = [[ZPUCounterSet alloc] initWithName:MTLCommonCounterSetTimestamp
                                                                    counters:@[timestampCounter]];
        _counterSets = @[timestampSet];
        _heaps = [NSHashTable weakObjectsHashTable];
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
- (NSUInteger)currentAllocatedSize {
    NSUInteger total = 0;
    zpu_init_resource_registry();
    @synchronized (zpu_resource_registry) {
        for (id resource in zpu_resource_registry.objectEnumerator) {
            if ([resource isKindOfClass:[ZPUBuffer class]]) {
                ZPUBuffer *buffer = (ZPUBuffer *)resource;
                if (buffer->_owner == self && buffer->_heap == nil) zpu_add_allocated_size(buffer.length, &total);
            } else if ([resource isKindOfClass:[ZPUTexture class]]) {
                ZPUTexture *texture = (ZPUTexture *)resource;
                if (texture->_owner == self && texture->_backing == nil && texture->_backingBuffer == nil && texture->_heap == nil) {
                    zpu_add_allocated_size(texture.allocatedSize, &total);
                }
            }
        }
    }
    @synchronized (_heaps) {
        for (ZPUHeap *heap in _heaps) zpu_add_allocated_size(heap.usedSize, &total);
    }
    return total;
}
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
    NSUInteger size = 0;
    return zpu_texture_descriptor_size(descriptor, &size) ? (MTLSizeAndAlign){size, 4} : (MTLSizeAndAlign){0, 0};
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
    zpu_metal_buffer *buffer = zpu_metal_device_new_buffer_no_copy(_zpuDevice, length, pointer);
    if (buffer == NULL) return nil;
    ZPUBuffer *result = [[ZPUBuffer alloc] initWithOwner:self buffer:buffer
                                             deallocator:deallocator pointer:pointer length:length];
    [result applyResourceOptions:options];
    return (id<MTLBuffer>)result;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor {
    NSUInteger descriptorSize = 0;
    if (!zpu_texture_descriptor_size(descriptor, &descriptorSize)) return nil;
    (void)descriptorSize;
    const NSUInteger sliceCount = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : descriptor.arrayLength;
    NSMutableArray *sliceMipmapTextures = [NSMutableArray arrayWithCapacity:sliceCount];
    for (NSUInteger slice = 0; slice < sliceCount; ++slice) {
        NSMutableArray *mipmaps = [NSMutableArray arrayWithCapacity:descriptor.mipmapLevelCount];
        NSUInteger levelWidth = descriptor.width;
        NSUInteger levelHeight = zpu_texture_type_is_1d(descriptor.textureType) ? 1 : descriptor.height;
        NSUInteger levelDepth = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : 1;
        for (NSUInteger level = 0; level < descriptor.mipmapLevelCount; ++level) {
            if (zpu_texture_type_is_3d(descriptor.textureType) && slice >= levelDepth) {
                [mipmaps addObject:[NSNull null]];
            } else {
                zpu_metal_texture_descriptor zpu_descriptor = {
                    (uint32_t)levelWidth, (uint32_t)levelHeight, zpu_pixel_format(descriptor.pixelFormat),
                };
                zpu_metal_texture *texture = zpu_metal_device_new_texture(_zpuDevice, &zpu_descriptor);
                if (texture == NULL) {
                    for (NSArray *createdSlice in sliceMipmapTextures) {
                        for (id value in createdSlice) {
                            if ([value isKindOfClass:[NSValue class]]) zpu_metal_texture_destroy((zpu_metal_texture *)[value pointerValue]);
                        }
                    }
                    for (id value in mipmaps) {
                        if ([value isKindOfClass:[NSValue class]]) zpu_metal_texture_destroy((zpu_metal_texture *)[value pointerValue]);
                    }
                    return nil;
                }
                [mipmaps addObject:[NSValue valueWithPointer:texture]];
            }
            levelWidth = levelWidth > 1 ? levelWidth / 2 : 1;
            levelHeight = levelHeight > 1 ? levelHeight / 2 : 1;
            levelDepth = levelDepth > 1 ? levelDepth / 2 : 1;
        }
        [sliceMipmapTextures addObject:mipmaps];
    }
    NSArray *firstSlice = sliceMipmapTextures.firstObject;
    ZPUTexture *result = [[ZPUTexture alloc] initWithOwner:self
                                                   texture:(zpu_metal_texture *)[firstSlice[0] pointerValue]
                                                      type:descriptor.textureType
                                               pixelFormat:descriptor.pixelFormat
                                             mipmapSlices:sliceMipmapTextures];
    result->_depth = zpu_texture_type_is_3d(descriptor.textureType) ? descriptor.depth : 1;
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
        descriptor.rasterSampleCount != 1 ||
        !zpu_depth_format_supported(descriptor.depthAttachmentPixelFormat) ||
        !zpu_stencil_format_supported(descriptor.stencilAttachmentPixelFormat)) {
        zpu_set_error(error, @"ZPU Metal supports only the fixed Vertex ABI with RGBA8/BGRA8, depth32-float, and stencil8 attachments");
        return nil;
    }
    ZPUCPUFunction *vertexFunction = (ZPUCPUFunction *)descriptor.vertexFunction;
    ZPUCPUFunction *fragmentFunction = (ZPUCPUFunction *)descriptor.fragmentFunction;
    if (![vertexFunction isKindOfClass:[ZPUCPUFunction class]] || vertexFunction->_owner != self ||
        vertexFunction.functionType != MTLFunctionTypeVertex ||
        ![fragmentFunction isKindOfClass:[ZPUCPUFunction class]] || fragmentFunction->_owner != self ||
        fragmentFunction.functionType != MTLFunctionTypeFragment) {
        zpu_set_error(error, @"ZPU CPU Metal render pipelines require ZPU-owned CPU vertex and fragment functions");
        return nil;
    }
    for (NSUInteger index = 0; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        if (!zpu_render_pipeline_format_supported(descriptor.colorAttachments[index].pixelFormat)) {
            zpu_set_error(error, @"ZPU Metal supports only RGBA8/BGRA8/R32Float/RGBA16Float color attachments");
            return nil;
        }
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
    ZPUSharedEventHandle *handle = (ZPUSharedEventHandle *)sharedEventHandle;
    if (![handle isKindOfClass:[ZPUSharedEventHandle class]] || handle->_event == nil ||
        handle->_event->_owner != self) return nil;
    return (id<MTLSharedEvent>)handle->_event;
}
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor iosurface:(IOSurfaceRef)iosurface plane:(NSUInteger)plane API_AVAILABLE(macos(10.11), ios(11.0)) {
    (void)descriptor;
    (void)iosurface;
    (void)plane;
    return nil;
}
- (id<MTLTexture>)newSharedTextureWithDescriptor:(MTLTextureDescriptor *)descriptor API_AVAILABLE(macos(10.14), ios(13.0)) {
    ZPUTexture *texture = (ZPUTexture *)[self newTextureWithDescriptor:descriptor];
    if (texture == nil) return nil;
    texture->_shareable = YES;
    return (id<MTLTexture>)texture;
}
- (id<MTLTexture>)newSharedTextureWithHandle:(MTLSharedTextureHandle *)sharedHandle API_AVAILABLE(macos(10.14), ios(13.0)) {
    ZPUSharedTextureHandle *handle = (ZPUSharedTextureHandle *)sharedHandle;
    if (![handle isKindOfClass:[ZPUSharedTextureHandle class]] || handle->_texture == nil ||
        handle->_texture->_owner != self) return nil;
    return (id<MTLTexture>)handle->_texture;
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
                                                        source:@"zpu_cpu_fill_gradient_rgba8 zpu_cpu_copy_rgba8_buffer_to_texture zpu_cpu_fill_gradient_rgba8_array zpu_cpu_fill_gradient_rgba8_3d zpu_cpu_fill_gradient_r32_float zpu_cpu_fill_gradient_rgba16_float"];
}
- (id<MTLLibrary>)newDefaultLibraryWithBundle:(NSBundle *)bundle error:(NSError **)error API_AVAILABLE(macos(10.12), ios(10.0)) {
    (void)bundle;
    id<MTLLibrary> library = [self newDefaultLibrary];
    if (error != NULL) *error = library == nil ? [NSError errorWithDomain:@"ZPUMetal" code:ZPU_METAL_INVALID_ARGUMENT
        userInfo:@{NSLocalizedDescriptionKey: @"ZPU CPU Metal default library creation failed"}] : nil;
    return library;
}
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
- (id<MTLLibrary>)newLibraryWithFile:(NSString *)filepath error:(NSError **)error {
    if (filepath == nil) {
        zpu_set_error(error, @"ZPU CPU Metal library file path is required");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfFile:filepath];
    NSString *source = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (source == nil) {
        zpu_set_error(error, @"ZPU CPU Metal library file must contain UTF-8 CPU function metadata");
        return nil;
    }
    return [self newLibraryWithSource:source options:nil error:error];
}
#pragma clang diagnostic pop
- (id<MTLLibrary>)newLibraryWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(10.13), ios(11.0)) {
    if (url == nil || !url.isFileURL) {
        zpu_set_error(error, @"ZPU CPU Metal library URL must be a file URL");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *source = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (source == nil) {
        zpu_set_error(error, @"ZPU CPU Metal library URL must contain UTF-8 CPU function metadata");
        return nil;
    }
    return [self newLibraryWithSource:source options:nil error:error];
}
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    if (data == nil) {
        zpu_set_error(error, @"ZPU CPU Metal library data is required");
        return nil;
    }
    size_t size = dispatch_data_get_size(data);
    if (size > NSUIntegerMax) {
        zpu_set_error(error, @"ZPU CPU Metal library data is too large");
        return nil;
    }
    NSMutableData *bytes = [NSMutableData dataWithLength:(NSUInteger)size];
    __block BOOL valid = YES;
    dispatch_data_apply(data, ^bool(dispatch_data_t region, size_t offset, const void *buffer, size_t regionSize) {
        (void)region;
        if (offset > size || regionSize > size - offset) {
            valid = NO;
            return false;
        }
        if (regionSize != 0) memcpy((uint8_t *)bytes.mutableBytes + offset, buffer, regionSize);
        return true;
    });
    NSString *source = valid ? [[NSString alloc] initWithData:bytes encoding:NSUTF8StringEncoding] : nil;
    if (source == nil) {
        zpu_set_error(error, @"ZPU CPU Metal library data must contain UTF-8 CPU function metadata");
        return nil;
    }
    return [self newLibraryWithSource:source options:nil error:error];
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
    return (id<MTLRasterizationRateMap>)[[ZPURasterizationRateMap alloc] initWithOwner:self descriptor:descriptor];
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
    return (id<MTLBinaryArchive>)[[ZPUBinaryArchive alloc] initWithOwner:self descriptor:descriptor error:error];
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
    if (descriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal requires a residency-set descriptor");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLResidencySet>)[[ZPUResidencySet alloc] initWithOwner:self descriptor:descriptor];
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
    ZPUTensorLayout layout;
    return zpu_tensor_layout_for_descriptor(descriptor, &layout) ?
        (MTLSizeAndAlign){layout.size, 4} : (MTLSizeAndAlign){0, 0};
}
- (id<MTLTensor>)newTensorWithDescriptor:(MTLTensorDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    ZPUTensorLayout layout;
    if (!zpu_tensor_layout_for_descriptor(descriptor, &layout)) {
        zpu_set_error(error, @"ZPU CPU Metal tensor descriptor is unsupported or invalid");
        return nil;
    }
    zpu_metal_buffer *buffer = zpu_metal_device_new_buffer(_zpuDevice, layout.size, NULL);
    if (buffer == NULL) {
        zpu_set_error(error, @"ZPU CPU Metal could not allocate tensor storage");
        return nil;
    }
    ZPUBuffer *storageBuffer = [[ZPUBuffer alloc] initWithOwner:self buffer:buffer];
    [storageBuffer applyResourceOptions:descriptor.resourceOptions];
    return (id<MTLTensor>)zpu_create_tensor(self, storageBuffer, nil, 0, descriptor, error);
}
- (id<MTLFunctionHandle>)functionHandleWithFunction:(id<MTLFunction>)function API_AVAILABLE(macos(26.0), ios(26.0)) {
    ZPUCPUFunction *cpuFunction = (ZPUCPUFunction *)function;
    if (![cpuFunction isKindOfClass:[ZPUCPUFunction class]] || cpuFunction->_owner != self ||
        cpuFunction->_name.length == 0) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:self
                                                                        name:cpuFunction->_name
                                                                 functionType:cpuFunction.functionType];
}
- (id<MTLIOFileHandle>)newIOHandleWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    return (id<MTLIOFileHandle>)[[ZPUIOFileHandle alloc] initWithOwner:self url:url error:error];
}
- (id<MTLIOFileHandle>)newIOHandleWithURL:(NSURL *)url compressionMethod:(MTLIOCompressionMethod)compressionMethod error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)url;
    (void)compressionMethod;
    zpu_set_error(error, @"ZPU CPU Metal I/O supports raw file handles only; compressed handles are unsupported");
    return nil;
}
- (id<MTLIOCommandQueue>)newIOCommandQueueWithDescriptor:(MTLIOCommandQueueDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(13.0), ios(16.0)) {
    if (descriptor == nil || descriptor.priority < MTLIOPriorityHigh || descriptor.priority > MTLIOPriorityLow ||
        descriptor.type < MTLIOCommandQueueTypeConcurrent || descriptor.type > MTLIOCommandQueueTypeSerial) {
        zpu_set_error(error, @"ZPU CPU Metal I/O command queue descriptor is invalid");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTLIOCommandQueue>)[[ZPUIOCommandQueue alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTLIOFileHandle>)newIOFileHandleWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(14.0), ios(17.0)) {
    return (id<MTLIOFileHandle>)[[ZPUIOFileHandle alloc] initWithOwner:self url:url error:error];
}
- (id<MTLIOFileHandle>)newIOFileHandleWithURL:(NSURL *)url compressionMethod:(MTLIOCompressionMethod)compressionMethod error:(NSError **)error API_AVAILABLE(macos(14.0), ios(17.0)) {
    (void)url;
    (void)compressionMethod;
    zpu_set_error(error, @"ZPU CPU Metal I/O supports raw file handles only; compressed handles are unsupported");
    return nil;
}
- (id<MTLLogState>)newLogStateWithDescriptor:(MTLLogStateDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(15.0), ios(18.0)) {
    return (id<MTLLogState>)[[ZPULogState alloc] initWithDescriptor:descriptor error:error];
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
    if (pixelRegions == NULL || tileRegions == NULL) return;
    for (NSUInteger index = 0; index < numRegions; ++index) {
        MTLRegion result = {MTLOriginMake(0, 0, 0), MTLSizeMake(0, 0, 0)};
        const BOOL valid =
            zpu_sparse_axis_to_tiles(pixelRegions[index].origin.x, pixelRegions[index].size.width,
                                     tileSize.width, mode, &result.origin.x, &result.size.width) &&
            zpu_sparse_axis_to_tiles(pixelRegions[index].origin.y, pixelRegions[index].size.height,
                                     tileSize.height, mode, &result.origin.y, &result.size.height) &&
            zpu_sparse_axis_to_tiles(pixelRegions[index].origin.z, pixelRegions[index].size.depth,
                                     tileSize.depth, mode, &result.origin.z, &result.size.depth);
        tileRegions[index] = valid ? result : (MTLRegion){MTLOriginMake(0, 0, 0), MTLSizeMake(0, 0, 0)};
    }
}
- (void)convertSparseTileRegions:(const MTLRegion[_Nonnull])tileRegions toPixelRegions:(MTLRegion[_Nonnull])pixelRegions withTileSize:(MTLSize)tileSize numRegions:(NSUInteger)numRegions API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0), tvos(16.0)) {
    if (tileRegions == NULL || pixelRegions == NULL) return;
    for (NSUInteger index = 0; index < numRegions; ++index) {
        MTLRegion result = {MTLOriginMake(0, 0, 0), MTLSizeMake(0, 0, 0)};
        const BOOL valid =
            zpu_sparse_axis_to_pixels(tileRegions[index].origin.x, tileRegions[index].size.width,
                                      tileSize.width, &result.origin.x, &result.size.width) &&
            zpu_sparse_axis_to_pixels(tileRegions[index].origin.y, tileRegions[index].size.height,
                                      tileSize.height, &result.origin.y, &result.size.height) &&
            zpu_sparse_axis_to_pixels(tileRegions[index].origin.z, tileRegions[index].size.depth,
                                      tileSize.depth, &result.origin.z, &result.size.depth);
        pixelRegions[index] = valid ? result : (MTLRegion){MTLOriginMake(0, 0, 0), MTLSizeMake(0, 0, 0)};
    }
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
    if (descriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal requires a Metal 4 compiler descriptor");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4Compiler>)[[ZPUMTL4Compiler alloc] initWithOwner:self descriptor:descriptor];
}
- (id<MTL4Archive>)newArchiveWithURL:(NSURL *)url error:(NSError **)error API_AVAILABLE(macos(26.0), ios(26.0)) {
    return (id<MTL4Archive>)[[ZPUMTL4Archive alloc] initWithOwner:self url:url error:error];
}
- (id<MTL4PipelineDataSetSerializer>)newPipelineDataSetSerializerWithDescriptor:(MTL4PipelineDataSetSerializerDescriptor *)descriptor API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (descriptor == nil ||
        (descriptor.configuration & ~((NSUInteger)MTL4PipelineDataSetSerializerConfigurationCaptureDescriptors |
                                      (NSUInteger)MTL4PipelineDataSetSerializerConfigurationCaptureBinaries)) != 0) {
        return nil;
    }
    return (id<MTL4PipelineDataSetSerializer>)[[ZPUMTL4PipelineDataSetSerializer alloc]
        initWithOwner:self descriptor:descriptor];
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
    ZPUMTL4BinaryFunction *binary = (ZPUMTL4BinaryFunction *)function;
    if (![binary isKindOfClass:[ZPUMTL4BinaryFunction class]] || binary->_owner != self ||
        (binary->_options & MTL4BinaryFunctionOptionPipelineIndependent) == 0 ||
        binary->_name.length == 0) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:self
                                                                        name:binary->_name
                                                                 functionType:binary->_functionType];
}
@end

@implementation ZPUFunctionHandle
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name
                  functionType:(MTLFunctionType)functionType {
    if ((self = [super init])) {
        _owner = owner;
        _name = [name copy];
        _functionType = functionType;
    }
    return self;
}
- (MTLFunctionType)functionType { return _functionType; }
- (NSString *)name { return _name; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(26.0), ios(26.0)) { return (MTLResourceID){0}; }
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
    /* The registered CPU profiles expose ordinary buffer/texture/sampler
     * arguments, not an MSL argument-buffer parameter. Metal returns nil for
     * this selector in that case; an empty encoder would incorrectly make a
     * non-argument-buffer resource look encodable. */
    return nil;
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
            @"zpu_test_vertex",
            @"zpu_test_no_raster_vertex",
            @"zpu_test_fragment",
            @"zpu_test_uniform_fragment",
            @"zpu_test_depth_bounds_oracle",
            @"zpu_test_mrt_fragment",
            @"zpu_test_sample_fragment",
            @"zpu_cpu_uniform_color_fragment",
            @"zpu_cpu_fill_gradient_rgba8",
            @"zpu_cpu_copy_rgba8_buffer_to_texture",
            @"zpu_cpu_fill_gradient_rgba8_array",
            @"zpu_cpu_fill_gradient_rgba8_3d",
            @"zpu_cpu_fill_gradient_r32_float",
            @"zpu_cpu_fill_gradient_rgba16_float",
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
    if (![_functionNames containsObject:functionName]) return nil;
    return zpu_function_reflection(functionName);
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

static NSString *zpu_binary_archive_function_name(ZPUDevice *owner, id<MTLFunction> function) {
    if (![function isKindOfClass:[ZPUCPUFunction class]]) return nil;
    ZPUCPUFunction *cpuFunction = (ZPUCPUFunction *)function;
    if (cpuFunction->_owner != owner || cpuFunction->_name.length == 0) return nil;
    return cpuFunction->_name;
}

static void zpu_binary_archive_add_error(NSError **error, NSString *message) {
    zpu_set_error(error, message);
}

@implementation ZPUBinaryArchive
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTLBinaryArchiveDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal requires a binary archive descriptor");
        return nil;
    }
    if ((self = [super init])) {
        _owner = owner;
        _functionNames = [NSMutableSet set];
        _sourceURL = [descriptor.url copy];
        if (_sourceURL != nil) {
            NSData *data = [NSData dataWithContentsOfURL:_sourceURL];
            NSString *serialized = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            NSArray<NSString *> *lines = [serialized componentsSeparatedByString:@"\n"];
            if (serialized == nil || lines.count == 0 || ![lines[0] isEqualToString:@"ZPU CPU Metal Binary Archive v1"]) {
                zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archive is not a ZPU archive");
                return nil;
            }
            ZPULibrary *registered = [[ZPULibrary alloc] initWithOwner:owner source:serialized];
            for (NSUInteger index = 1; index < lines.count; ++index) {
                NSString *name = lines[index];
                if (name.length != 0 && [registered newFunctionWithName:name] != nil) [_functionNames addObject:name];
            }
        }
    }
    if (error != NULL) *error = nil;
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (BOOL)addComputePipelineFunctionsWithDescriptor:(MTLComputePipelineDescriptor *)descriptor error:(NSError **)error {
    NSString *name = descriptor == nil ? nil : zpu_binary_archive_function_name(_owner, descriptor.computeFunction);
    if (name == nil || descriptor.computeFunction.functionType != MTLFunctionTypeKernel) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives accept only CPU compute functions");
        return NO;
    }
    [_functionNames addObject:name];
    if (error != NULL) *error = nil;
    return YES;
}
- (BOOL)addRenderPipelineFunctionsWithDescriptor:(MTLRenderPipelineDescriptor *)descriptor error:(NSError **)error {
    NSString *vertex = descriptor == nil ? nil : zpu_binary_archive_function_name(_owner, descriptor.vertexFunction);
    NSString *fragment = descriptor == nil ? nil : zpu_binary_archive_function_name(_owner, descriptor.fragmentFunction);
    if (vertex == nil || fragment == nil || descriptor.vertexFunction.functionType != MTLFunctionTypeVertex ||
        descriptor.fragmentFunction.functionType != MTLFunctionTypeFragment) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives accept only CPU render functions");
        return NO;
    }
    [_functionNames addObject:vertex];
    [_functionNames addObject:fragment];
    if (error != NULL) *error = nil;
    return YES;
}
- (BOOL)addTileRenderPipelineFunctionsWithDescriptor:(MTLTileRenderPipelineDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)descriptor;
    zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives have no tile-shader implementation");
    return NO;
}
- (BOOL)addMeshRenderPipelineFunctionsWithDescriptor:(MTLMeshRenderPipelineDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)descriptor;
    zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives have no mesh-shader implementation");
    return NO;
}
- (BOOL)addLibraryWithDescriptor:(MTLStitchedLibraryDescriptor *)descriptor error:(NSError **)error API_AVAILABLE(macos(15.0), ios(18.0)) {
    (void)descriptor;
    zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives do not stitch arbitrary libraries");
    return NO;
}
- (BOOL)serializeToURL:(NSURL *)url error:(NSError **)error {
    if (url == nil) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archive serialization requires a file URL");
        return NO;
    }
    NSMutableString *serialized = [NSMutableString stringWithString:@"ZPU CPU Metal Binary Archive v1\n"];
    NSArray<NSString *> *sortedNames = [[_functionNames allObjects] sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *name in sortedNames) [serialized appendFormat:@"%@\n", name];
    NSData *data = [serialized dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    BOOL result = [data writeToURL:url options:NSDataWritingAtomic error:&writeError];
    if (!result) {
        if (error != NULL) *error = writeError;
        return NO;
    }
    if (error != NULL) *error = nil;
    return YES;
}
- (BOOL)addFunctionWithDescriptor:(MTLFunctionDescriptor *)descriptor library:(id<MTLLibrary>)library error:(NSError **)error API_AVAILABLE(macos(12.0), ios(15.0)) {
    ZPULibrary *zpuLibrary = (ZPULibrary *)library;
    if (![zpuLibrary isKindOfClass:[ZPULibrary class]] || zpuLibrary->_owner != _owner || descriptor == nil || descriptor.name == nil) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives accept only registered ZPU library functions");
        return NO;
    }
    id<MTLFunction> function = [zpuLibrary newFunctionWithName:descriptor.name];
    NSString *name = zpu_binary_archive_function_name(_owner, function);
    if (name == nil || function.functionType != MTLFunctionTypeKernel) {
        zpu_binary_archive_add_error(error, @"ZPU CPU Metal binary archives accept only registered CPU functions");
        return NO;
    }
    [_functionNames addObject:name];
    if (error != NULL) *error = nil;
    return YES;
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunguarded-availability-new"

@implementation ZPUMTL4PipelineDataSetSerializer
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4PipelineDataSetSerializerDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _configuration = descriptor.configuration;
        _functionNames = [NSMutableSet set];
    }
    return self;
}
- (void)recordFunctionName:(NSString *)name {
    if (name.length != 0) {
        @synchronized (self) { [_functionNames addObject:name]; }
    }
}
- (BOOL)serializeAsArchiveAndFlushToURL:(NSURL *)url error:(NSError **)error {
    if ((_configuration & MTL4PipelineDataSetSerializerConfigurationCaptureBinaries) == 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 serializer was not configured to capture binaries");
        return NO;
    }
    if (url == nil || !url.isFileURL) {
        zpu_set_error(error, @"ZPU CPU Metal 4 serializer requires a file URL");
        return NO;
    }
    NSMutableString *serialized = [NSMutableString stringWithString:@"ZPU CPU Metal Binary Archive v1\n"];
    NSArray<NSString *> *sortedNames;
    @synchronized (self) { sortedNames = [[_functionNames allObjects] sortedArrayUsingSelector:@selector(compare:)]; }
    for (NSString *name in sortedNames) [serialized appendFormat:@"%@\n", name];
    NSData *data = [serialized dataUsingEncoding:NSUTF8StringEncoding];
    NSError *writeError = nil;
    BOOL result = [data writeToURL:url options:NSDataWritingAtomic error:&writeError];
    if (!result) {
        if (error != NULL) *error = writeError;
        return NO;
    }
    if (error != NULL) *error = nil;
    @synchronized (self) { [_functionNames removeAllObjects]; }
    return YES;
}
- (NSData *)serializeAsPipelinesScriptWithError:(NSError **)error {
    if ((_configuration & MTL4PipelineDataSetSerializerConfigurationCaptureDescriptors) == 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 serializer was not configured to capture descriptors");
        return nil;
    }
    NSMutableString *serialized = [NSMutableString stringWithString:@"ZPU CPU Metal Pipeline Script v1\n"];
    NSArray<NSString *> *sortedNames;
    @synchronized (self) { sortedNames = [[_functionNames allObjects] sortedArrayUsingSelector:@selector(compare:)]; }
    for (NSString *name in sortedNames) [serialized appendFormat:@"compute %@\n", name];
    if (error != NULL) *error = nil;
    return [serialized dataUsingEncoding:NSUTF8StringEncoding];
}
@end

@implementation ZPUMTL4BinaryFunction
- (instancetype)initWithOwner:(ZPUDevice *)owner name:(NSString *)name
                  functionType:(MTLFunctionType)functionType options:(MTL4BinaryFunctionOptions)options {
    if ((self = [super init])) {
        _owner = owner;
        _name = [name copy];
        _functionType = functionType;
        _options = options;
    }
    return self;
}
- (NSString *)name { return _name; }
- (MTLFunctionType)functionType { return _functionType; }
@end

@implementation ZPUMTL4CompilerTask
- (instancetype)initWithCompiler:(id<MTL4Compiler>)compiler {
    if ((self = [super init])) _compiler = compiler;
    return self;
}
- (id<MTL4Compiler>)compiler { return _compiler; }
- (MTL4CompilerTaskStatus)status { return MTL4CompilerTaskStatusFinished; }
- (void)waitUntilCompleted {}
@end

static id<MTLFunction> zpu_mtl4_resolve_library_function(
    ZPUDevice *owner, MTL4FunctionDescriptor *descriptor, NSError **error) {
    if (![descriptor isKindOfClass:[MTL4LibraryFunctionDescriptor class]]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 accepts only library function descriptors");
        return nil;
    }
    MTL4LibraryFunctionDescriptor *library_descriptor = (MTL4LibraryFunctionDescriptor *)descriptor;
    ZPULibrary *library = (ZPULibrary *)library_descriptor.library;
    if (![library isKindOfClass:[ZPULibrary class]] || library->_owner != owner ||
        library_descriptor.name.length == 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 requires a ZPU-owned registered library function");
        return nil;
    }
    id<MTLFunction> function = [library newFunctionWithName:library_descriptor.name];
    if (function == nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 function is not registered");
        return nil;
    }
    if (error != NULL) *error = nil;
    return function;
}

static id<MTL4BinaryFunction> zpu_mtl4_binary_function_for_descriptor(
    ZPUDevice *owner, MTL4BinaryFunctionDescriptor *descriptor, NSError **error) {
    if (descriptor == nil || descriptor.name.length == 0 || descriptor.functionDescriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 requires a named binary function descriptor");
        return nil;
    }
    const NSUInteger supported_options = MTL4BinaryFunctionOptionPipelineIndependent;
    if ((descriptor.options & ~supported_options) != 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 does not support these binary function options");
        return nil;
    }
    id<MTLFunction> function = zpu_mtl4_resolve_library_function(owner, descriptor.functionDescriptor, error);
    if (function == nil || ![descriptor.name isEqualToString:function.name]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 binary function name does not match its library function");
        return nil;
    }
    return (id<MTL4BinaryFunction>)[[ZPUMTL4BinaryFunction alloc]
        initWithOwner:owner name:function.name functionType:function.functionType options:descriptor.options];
}

static id<MTLRenderPipelineState> zpu_mtl4_render_pipeline_for_descriptor(
    ZPUDevice *owner, MTL4RenderPipelineDescriptor *descriptor, NSError **error) {
    if (descriptor == nil || descriptor.vertexFunctionDescriptor == nil ||
        descriptor.fragmentFunctionDescriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 requires registered vertex and fragment functions");
        return nil;
    }
    if (descriptor.rasterSampleCount != 0 && descriptor.rasterSampleCount != 1) {
        zpu_set_error(error, @"ZPU CPU Metal 4 supports only one-sample CPU render targets");
        return nil;
    }
    MTL4StaticLinkingDescriptor *vertex_linking = descriptor.vertexStaticLinkingDescriptor;
    MTL4StaticLinkingDescriptor *fragment_linking = descriptor.fragmentStaticLinkingDescriptor;
    MTLVertexDescriptor *vertex_descriptor = descriptor.vertexDescriptor;
    MTLVertexAttributeDescriptor *position_attribute = vertex_descriptor.attributes[0];
    MTLVertexAttributeDescriptor *color_attribute = vertex_descriptor.attributes[1];
    MTLVertexBufferLayoutDescriptor *vertex_layout = vertex_descriptor.layouts[0];
    const BOOL empty_vertex_descriptor = vertex_descriptor == nil ||
        (position_attribute.format == MTLVertexFormatInvalid && color_attribute.format == MTLVertexFormatInvalid &&
         vertex_layout.stride == 0 &&
         (vertex_layout.stepFunction == MTLVertexStepFunctionConstant ||
          vertex_layout.stepFunction == MTLVertexStepFunctionPerVertex));
    const BOOL fixed_vertex_descriptor = vertex_descriptor != nil &&
        position_attribute.format == MTLVertexFormatFloat4 && position_attribute.offset == 0 &&
        position_attribute.bufferIndex == 0 && color_attribute.format == MTLVertexFormatFloat4 &&
        color_attribute.offset == sizeof(float) * 4 && color_attribute.bufferIndex == 0 &&
        vertex_layout.stride == sizeof(zpu_metal_vertex) &&
        vertex_layout.stepFunction == MTLVertexStepFunctionPerVertex && vertex_layout.stepRate == 1;
    if (descriptor.alphaToCoverageState != MTL4AlphaToCoverageStateDisabled ||
        descriptor.alphaToOneState != MTL4AlphaToOneStateDisabled ||
        descriptor.maxVertexAmplificationCount > 1 ||
        descriptor.colorAttachmentMappingState != MTL4LogicalToPhysicalColorAttachmentMappingStateIdentity ||
        (!empty_vertex_descriptor && !fixed_vertex_descriptor) ||
        vertex_linking.functionDescriptors.count != 0 || vertex_linking.privateFunctionDescriptors.count != 0 ||
        vertex_linking.groups.count != 0 || fragment_linking.functionDescriptors.count != 0 ||
        fragment_linking.privateFunctionDescriptors.count != 0 || fragment_linking.groups.count != 0 ||
        descriptor.supportVertexBinaryLinking || descriptor.supportFragmentBinaryLinking) {
        zpu_set_error(error, @"ZPU CPU Metal 4 render pipeline uses unsupported specialization or vertex layout state");
        return nil;
    }
    id<MTLFunction> vertex = zpu_mtl4_resolve_library_function(owner, descriptor.vertexFunctionDescriptor, error);
    id<MTLFunction> fragment = zpu_mtl4_resolve_library_function(owner, descriptor.fragmentFunctionDescriptor, error);
    if (vertex == nil || fragment == nil ||
        vertex.functionType != MTLFunctionTypeVertex || fragment.functionType != MTLFunctionTypeFragment) {
        zpu_set_error(error, @"ZPU CPU Metal 4 render pipeline requires CPU vertex and fragment profiles");
        return nil;
    }
    MTLRenderPipelineDescriptor *legacy = [MTLRenderPipelineDescriptor new];
    legacy.vertexFunction = vertex;
    legacy.fragmentFunction = fragment;
    legacy.rasterSampleCount = descriptor.rasterSampleCount == 0 ? 1 : descriptor.rasterSampleCount;
    legacy.alphaToCoverageEnabled = NO;
    legacy.alphaToOneEnabled = NO;
    legacy.rasterizationEnabled = descriptor.rasterizationEnabled;
    legacy.maxVertexAmplificationCount = descriptor.maxVertexAmplificationCount == 0 ? 1 : descriptor.maxVertexAmplificationCount;
    legacy.inputPrimitiveTopology = descriptor.inputPrimitiveTopology;
    legacy.supportIndirectCommandBuffers =
        descriptor.supportIndirectCommandBuffers == MTL4IndirectCommandBufferSupportStateEnabled;
    for (NSUInteger index = 0; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        MTL4RenderPipelineColorAttachmentDescriptor *source = descriptor.colorAttachments[index];
        MTLRenderPipelineColorAttachmentDescriptor *destination = legacy.colorAttachments[index];
        destination.pixelFormat = source.pixelFormat;
        if (source.blendingState == MTL4BlendStateUnspecialized) {
            zpu_set_error(error, @"ZPU CPU Metal 4 does not specialize unspecialized blending state");
            return nil;
        }
        destination.blendingEnabled = source.blendingState == MTL4BlendStateEnabled;
        destination.sourceRGBBlendFactor = source.sourceRGBBlendFactor;
        destination.destinationRGBBlendFactor = source.destinationRGBBlendFactor;
        destination.rgbBlendOperation = source.rgbBlendOperation;
        destination.sourceAlphaBlendFactor = source.sourceAlphaBlendFactor;
        destination.destinationAlphaBlendFactor = source.destinationAlphaBlendFactor;
        destination.alphaBlendOperation = source.alphaBlendOperation;
        destination.writeMask = source.writeMask;
    }
    id<MTLRenderPipelineState> pipeline = [owner newRenderPipelineStateWithDescriptor:legacy error:error];
    if (pipeline != nil && [pipeline isKindOfClass:[ZPURenderPipelineState class]]) {
        ((ZPURenderPipelineState *)pipeline)->_reflection =
            zpu_render_pipeline_reflection(vertex.name, fragment.name);
    }
    return pipeline;
}

static BOOL zpu_mtl4_apply_compute_descriptor(
    ZPUComputePipelineState *pipeline, MTL4ComputePipelineDescriptor *descriptor, NSError **error) {
    if (pipeline == nil || descriptor == nil ||
        (descriptor.supportIndirectCommandBuffers != MTL4IndirectCommandBufferSupportStateDisabled &&
         descriptor.supportIndirectCommandBuffers != MTL4IndirectCommandBufferSupportStateEnabled)) {
        zpu_set_error(error, @"ZPU CPU Metal 4 compute pipeline has invalid descriptor state");
        return NO;
    }
    MTL4StaticLinkingDescriptor *linking = descriptor.staticLinkingDescriptor;
    if (descriptor.supportBinaryLinking || linking.functionDescriptors.count != 0 ||
        linking.privateFunctionDescriptors.count != 0 || linking.groups.count != 0 ||
        descriptor.maxTotalThreadsPerThreadgroup > pipeline->_maxTotalThreadsPerThreadgroup) {
        zpu_set_error(error, @"ZPU CPU Metal 4 compute pipeline uses unsupported linking or thread limits");
        return NO;
    }
    if (descriptor.maxTotalThreadsPerThreadgroup != 0) {
        pipeline->_maxTotalThreadsPerThreadgroup = descriptor.maxTotalThreadsPerThreadgroup;
    }
    pipeline->_requiredThreadsPerThreadgroup = descriptor.requiredThreadsPerThreadgroup;
    pipeline->_supportsIndirectCommandBuffers =
        descriptor.supportIndirectCommandBuffers == MTL4IndirectCommandBufferSupportStateEnabled;
    return YES;
}

static id<MTL4CompilerTask> zpu_mtl4_finished_task(id<MTL4Compiler> compiler) {
    return (id<MTL4CompilerTask>)[[ZPUMTL4CompilerTask alloc] initWithCompiler:compiler];
}

@implementation ZPUMTL4Compiler
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CompilerDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _pipelineDataSetSerializer = descriptor.pipelineDataSetSerializer;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (id<MTL4PipelineDataSetSerializer>)pipelineDataSetSerializer { return _pipelineDataSetSerializer; }
- (id<MTLLibrary>)newLibraryWithDescriptor:(MTL4LibraryDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil || descriptor.source == nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 library creation requires source text");
        return nil;
    }
    ZPULibrary *library = [[ZPULibrary alloc] initWithOwner:_owner source:descriptor.source];
    if (library->_functionNames.count == 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 source contains no registered CPU kernel");
        return nil;
    }
    if (descriptor.name.length != 0) library->_label = [descriptor.name copy];
    if (error != NULL) *error = nil;
    return (id<MTLLibrary>)library;
}
- (id<MTLDynamicLibrary>)newDynamicLibrary:(id<MTLLibrary>)library error:(NSError **)error {
    (void)library;
    zpu_set_error(error, @"ZPU CPU Metal 4 has no dynamic library implementation");
    return nil;
}
- (id<MTLDynamicLibrary>)newDynamicLibraryWithURL:(NSURL *)url error:(NSError **)error {
    (void)url;
    zpu_set_error(error, @"ZPU CPU Metal 4 has no dynamic library implementation");
    return nil;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor
                                                  compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                                                error:(NSError **)error {
    (void)compilerTaskOptions;
    if (descriptor == nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 requires a compute pipeline descriptor");
        return nil;
    }
    id<MTLFunction> function = zpu_mtl4_resolve_library_function(_owner, descriptor.computeFunctionDescriptor, error);
    if (function == nil) return nil;
    id<MTLComputePipelineState> pipeline = (id<MTLComputePipelineState>)[[ZPUComputePipelineState alloc]
        initWithOwner:_owner function:function error:error];
    if (pipeline != nil && !zpu_mtl4_apply_compute_descriptor(
            (ZPUComputePipelineState *)pipeline, descriptor, error)) return nil;
    if (pipeline != nil) {
        ((ZPUComputePipelineState *)pipeline)->_reflection =
            zpu_compute_pipeline_reflection(((ZPUComputePipelineState *)pipeline)->_kernel);
    }
    if (pipeline != nil && [_pipelineDataSetSerializer respondsToSelector:@selector(recordFunctionName:)]) {
        [(ZPUMTL4PipelineDataSetSerializer *)_pipelineDataSetSerializer recordFunctionName:function.name];
    }
    return pipeline;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor
                                           dynamicLinkingDescriptor:(MTL4PipelineStageDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                                compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                                              error:(NSError **)error {
    (void)compilerTaskOptions;
    if (dynamicLinkingDescriptor != nil) {
        zpu_set_error(error, @"ZPU CPU Metal 4 does not link dynamic binary functions");
        return nil;
    }
    return [self newComputePipelineStateWithDescriptor:descriptor compilerTaskOptions:nil error:error];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                                   compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                                                 error:(NSError **)error {
    (void)compilerTaskOptions;
    if (![descriptor isKindOfClass:[MTL4RenderPipelineDescriptor class]]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 compiler supports only ordinary render descriptors");
        return nil;
    }
    id<MTLRenderPipelineState> pipeline =
        zpu_mtl4_render_pipeline_for_descriptor(_owner, (MTL4RenderPipelineDescriptor *)descriptor, error);
    if (pipeline != nil && [_pipelineDataSetSerializer respondsToSelector:@selector(recordFunctionName:)]) {
        MTL4RenderPipelineDescriptor *render = (MTL4RenderPipelineDescriptor *)descriptor;
        MTL4LibraryFunctionDescriptor *vertex = (MTL4LibraryFunctionDescriptor *)render.vertexFunctionDescriptor;
        MTL4LibraryFunctionDescriptor *fragment = (MTL4LibraryFunctionDescriptor *)render.fragmentFunctionDescriptor;
        [(ZPUMTL4PipelineDataSetSerializer *)_pipelineDataSetSerializer recordFunctionName:vertex.name];
        [(ZPUMTL4PipelineDataSetSerializer *)_pipelineDataSetSerializer recordFunctionName:fragment.name];
    }
    return pipeline;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                            dynamicLinkingDescriptor:(MTL4RenderPipelineDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                                 compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                                               error:(NSError **)error {
    (void)descriptor;
    (void)dynamicLinkingDescriptor;
    (void)compilerTaskOptions;
    zpu_set_error(error, @"ZPU CPU Metal 4 does not link dynamic render functions");
    return nil;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateBySpecializationWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                                                                pipeline:(id<MTLRenderPipelineState>)pipeline
                                                                                   error:(NSError **)error {
    (void)descriptor;
    (void)pipeline;
    zpu_set_error(error, @"ZPU CPU Metal 4 does not specialize render pipelines");
    return nil;
}
- (id<MTL4BinaryFunction>)newBinaryFunctionWithDescriptor:(MTL4BinaryFunctionDescriptor *)descriptor
                                        compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                                      error:(NSError **)error {
    (void)compilerTaskOptions;
    id<MTL4BinaryFunction> function = zpu_mtl4_binary_function_for_descriptor(_owner, descriptor, error);
    if (function != nil && [_pipelineDataSetSerializer respondsToSelector:@selector(recordFunctionName:)]) {
        [(ZPUMTL4PipelineDataSetSerializer *)_pipelineDataSetSerializer recordFunctionName:function.name];
    }
    return function;
}
- (id<MTL4CompilerTask>)newLibraryWithDescriptor:(MTL4LibraryDescriptor *)descriptor
                               completionHandler:(MTLNewLibraryCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLLibrary> library = [self newLibraryWithDescriptor:descriptor error:&error];
    if (completionHandler != nil) completionHandler(library, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newDynamicLibrary:(id<MTLLibrary>)library
                        completionHandler:(MTLNewDynamicLibraryCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLDynamicLibrary> result = [self newDynamicLibrary:library error:&error];
    if (completionHandler != nil) completionHandler(result, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newDynamicLibraryWithURL:(NSURL *)url
                               completionHandler:(MTLNewDynamicLibraryCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLDynamicLibrary> result = [self newDynamicLibraryWithURL:url error:&error];
    if (completionHandler != nil) completionHandler(result, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor
                                          compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                            completionHandler:(MTLNewComputePipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [self newComputePipelineStateWithDescriptor:descriptor
                                                                     compilerTaskOptions:compilerTaskOptions
                                                                                   error:&error];
    if (completionHandler != nil) completionHandler(pipeline, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor
                                     dynamicLinkingDescriptor:(MTL4PipelineStageDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                          compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                            completionHandler:(MTLNewComputePipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [self newComputePipelineStateWithDescriptor:descriptor
                                                                    dynamicLinkingDescriptor:dynamicLinkingDescriptor
                                                                         compilerTaskOptions:compilerTaskOptions
                                                                                       error:&error];
    if (completionHandler != nil) completionHandler(pipeline, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                         compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                           completionHandler:(MTLNewRenderPipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [self newRenderPipelineStateWithDescriptor:descriptor
                                                                     compilerTaskOptions:compilerTaskOptions
                                                                                   error:&error];
    if (completionHandler != nil) completionHandler(pipeline, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                    dynamicLinkingDescriptor:(MTL4RenderPipelineDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                         compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                           completionHandler:(MTLNewRenderPipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLRenderPipelineState> pipeline = [self newRenderPipelineStateWithDescriptor:descriptor
                                                                    dynamicLinkingDescriptor:dynamicLinkingDescriptor
                                                                         compilerTaskOptions:compilerTaskOptions
                                                                                       error:&error];
    if (completionHandler != nil) completionHandler(pipeline, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newRenderPipelineStateBySpecializationWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                                                    pipeline:(id<MTLRenderPipelineState>)pipeline
                                                           completionHandler:(MTLNewRenderPipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTLRenderPipelineState> result = [self newRenderPipelineStateBySpecializationWithDescriptor:descriptor
                                                                                             pipeline:pipeline
                                                                                                error:&error];
    if (completionHandler != nil) completionHandler(result, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4CompilerTask>)newBinaryFunctionWithDescriptor:(MTL4BinaryFunctionDescriptor *)descriptor
                                    compilerTaskOptions:(MTL4CompilerTaskOptions *)compilerTaskOptions
                                      completionHandler:(MTL4NewBinaryFunctionCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTL4BinaryFunction> function = [self newBinaryFunctionWithDescriptor:descriptor
                                                          compilerTaskOptions:compilerTaskOptions
                                                                        error:&error];
    if (completionHandler != nil) completionHandler(function, error);
    return zpu_mtl4_finished_task(self);
}
- (id<MTL4MachineLearningPipelineState>)newMachineLearningPipelineStateWithDescriptor:(MTL4MachineLearningPipelineDescriptor *)descriptor
                                                                                  error:(NSError **)error {
    (void)descriptor;
    zpu_set_error(error, @"ZPU CPU Metal 4 has no machine-learning pipeline implementation");
    return nil;
}
- (id<MTL4CompilerTask>)newMachineLearningPipelineStateWithDescriptor:(MTL4MachineLearningPipelineDescriptor *)descriptor
                                                      completionHandler:(MTL4NewMachineLearningPipelineStateCompletionHandler)completionHandler {
    NSError *error = nil;
    id<MTL4MachineLearningPipelineState> pipeline = [self newMachineLearningPipelineStateWithDescriptor:descriptor error:&error];
    if (completionHandler != nil) completionHandler(pipeline, error);
    return zpu_mtl4_finished_task(self);
}
@end

@implementation ZPUMTL4Archive
- (instancetype)initWithOwner:(ZPUDevice *)owner url:(NSURL *)url error:(NSError **)error {
    if (url == nil || !url.isFileURL) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archives require a file URL");
        return nil;
    }
    NSData *data = [NSData dataWithContentsOfURL:url];
    NSString *serialized = data == nil ? nil : [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    NSArray<NSString *> *lines = [serialized componentsSeparatedByString:@"\n"];
    if (serialized == nil || lines.count == 0 || ![lines[0] isEqualToString:@"ZPU CPU Metal Binary Archive v1"]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive is not a ZPU archive");
        return nil;
    }
    if ((self = [super init])) {
        _owner = owner;
        _sourceURL = [url copy];
        _functionNames = [NSMutableSet set];
        ZPULibrary *registered = [[ZPULibrary alloc] initWithOwner:owner source:serialized];
        for (NSUInteger index = 1; index < lines.count; ++index) {
            NSString *name = lines[index];
            if (name.length != 0 && [registered newFunctionWithName:name] != nil) [_functionNames addObject:name];
        }
    }
    if (error != NULL) *error = nil;
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil || ![descriptor.computeFunctionDescriptor isKindOfClass:[MTL4LibraryFunctionDescriptor class]]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive requires a library compute function descriptor");
        return nil;
    }
    MTL4LibraryFunctionDescriptor *function_descriptor = (MTL4LibraryFunctionDescriptor *)descriptor.computeFunctionDescriptor;
    if (![_functionNames containsObject:function_descriptor.name]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive does not contain this compute function");
        return nil;
    }
    id<MTLFunction> function = zpu_mtl4_resolve_library_function(_owner, descriptor.computeFunctionDescriptor, error);
    if (function == nil) return nil;
    id<MTLComputePipelineState> pipeline = (id<MTLComputePipelineState>)[[ZPUComputePipelineState alloc]
        initWithOwner:_owner function:function error:error];
    if (pipeline != nil && !zpu_mtl4_apply_compute_descriptor(
            (ZPUComputePipelineState *)pipeline, descriptor, error)) return nil;
    if (pipeline != nil) {
        ((ZPUComputePipelineState *)pipeline)->_reflection =
            zpu_compute_pipeline_reflection(((ZPUComputePipelineState *)pipeline)->_kernel);
    }
    return pipeline;
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)descriptor
                                           dynamicLinkingDescriptor:(MTL4PipelineStageDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                                               error:(NSError **)error {
    (void)descriptor;
    (void)dynamicLinkingDescriptor;
    zpu_set_error(error, @"ZPU CPU Metal 4 archives do not link dynamic binary functions");
    return nil;
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor error:(NSError **)error {
    if (![descriptor isKindOfClass:[MTL4RenderPipelineDescriptor class]]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive supports only ordinary render descriptors");
        return nil;
    }
    MTL4RenderPipelineDescriptor *render = (MTL4RenderPipelineDescriptor *)descriptor;
    MTL4LibraryFunctionDescriptor *vertex = (MTL4LibraryFunctionDescriptor *)render.vertexFunctionDescriptor;
    MTL4LibraryFunctionDescriptor *fragment = (MTL4LibraryFunctionDescriptor *)render.fragmentFunctionDescriptor;
    if (![vertex isKindOfClass:[MTL4LibraryFunctionDescriptor class]] ||
        ![fragment isKindOfClass:[MTL4LibraryFunctionDescriptor class]] ||
        ![_functionNames containsObject:vertex.name] || ![_functionNames containsObject:fragment.name]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive does not contain this render pipeline");
        return nil;
    }
    return zpu_mtl4_render_pipeline_for_descriptor(_owner, render, error);
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor
                                            dynamicLinkingDescriptor:(MTL4RenderPipelineDynamicLinkingDescriptor *)dynamicLinkingDescriptor
                                                               error:(NSError **)error {
    (void)descriptor;
    (void)dynamicLinkingDescriptor;
    zpu_set_error(error, @"ZPU CPU Metal 4 archives do not link dynamic render functions");
    return nil;
}
- (id<MTL4BinaryFunction>)newBinaryFunctionWithDescriptor:(MTL4BinaryFunctionDescriptor *)descriptor error:(NSError **)error {
    if (descriptor == nil || descriptor.name.length == 0 || ![_functionNames containsObject:descriptor.name]) {
        zpu_set_error(error, @"ZPU CPU Metal 4 archive does not contain this binary function");
        return nil;
    }
    if ((descriptor.options & ~((NSUInteger)MTL4BinaryFunctionOptionPipelineIndependent)) != 0) {
        zpu_set_error(error, @"ZPU CPU Metal 4 does not support these binary function options");
        return nil;
    }
    if (error != NULL) *error = nil;
    return (id<MTL4BinaryFunction>)[[ZPUMTL4BinaryFunction alloc]
        initWithOwner:_owner name:descriptor.name functionType:MTLFunctionTypeKernel options:descriptor.options];
}
@end

#pragma clang diagnostic pop

@implementation ZPUCommandQueue
- (instancetype)initWithOwner:(ZPUDevice *)owner queue:(zpu_metal_command_queue *)queue {
    if ((self = [super init])) {
        _owner = owner;
        _zpuQueue = queue;
        _residencySets = [NSMutableSet set];
    }
    return self;
}
- (void)dealloc {
    if (_zpuQueue != NULL) zpu_metal_command_queue_destroy(_zpuQueue);
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)insertDebugCaptureBoundary {}
- (void)addResidencySet:(id)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != _owner) return;
    [_residencySets addObject:zpuSet];
    [zpuSet commit];
}
- (void)addResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) {
    if (residencySets == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self addResidencySet:residencySets[index]];
}
- (void)removeResidencySet:(id)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != _owner) return;
    [_residencySets removeObject:zpuSet];
}
- (void)removeResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) {
    if (residencySets == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self removeResidencySet:residencySets[index]];
}
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
        default: return _scheduled ? MTLCommandBufferStatusScheduled : MTLCommandBufferStatusNotEnqueued;
    }
}
- (NSError *)error { return _error; }
- (void)enqueue { [self commit]; }
- (void)commit {
    if (_scheduled) return;
    _scheduled = YES;
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
- (void)presentDrawable:(id<MTLDrawable>)drawable { (void)drawable; [self markError]; }
- (void)presentDrawable:(id<MTLDrawable>)drawable atTime:(CFTimeInterval)presentationTime { (void)drawable; (void)presentationTime; [self markError]; }
- (void)presentDrawable:(id<MTLDrawable>)drawable afterMinimumDuration:(CFTimeInterval)duration API_AVAILABLE(macos(10.15.4), ios(10.3), macCatalyst(13.4)) { (void)drawable; (void)duration; [self markError]; }
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
    if (descriptor == nil) return nil;
    MTLRenderPassColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
    ZPUTexture *texture = (ZPUTexture *)colorAttachment.texture;
    ZPUTexture *depthAttachmentTexture = (ZPUTexture *)descriptor.depthAttachment.texture;
    ZPUTexture *stencilAttachmentTexture = (ZPUTexture *)descriptor.stencilAttachment.texture;
    if (texture == nil) {
        texture = zpu_hidden_color_target(self.device,
                                          depthAttachmentTexture != nil ? depthAttachmentTexture : stencilAttachmentTexture,
                                          depthAttachmentTexture != nil ? descriptor.depthAttachment.level : descriptor.stencilAttachment.level,
                                          depthAttachmentTexture != nil ? descriptor.depthAttachment.slice : descriptor.stencilAttachment.slice);
        if (texture == nil) return nil;
    }
    if (colorAttachment.texture != nil && !zpu_store_action_supported(colorAttachment.storeAction)) return nil;
    if (![texture isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(texture->_textureType)) return nil;
    zpu_metal_texture *colorTexture = [texture zpuTextureAtLevel:colorAttachment.texture != nil ? colorAttachment.level : 0
                                                            slice:colorAttachment.texture != nil ? colorAttachment.slice : 0];
    if (colorTexture == NULL) return nil;
    zpu_metal_texture *depthTexture = NULL;
    zpu_metal_texture *stencilTexture = NULL;
    zpu_metal_render_pass_descriptor pass = {
        .color = {
            .load_action = colorAttachment.texture == nil ? ZPU_METAL_LOAD_DONT_CARE : zpu_load_action(colorAttachment.loadAction),
            .store_action = colorAttachment.texture == nil ? ZPU_METAL_STORE_DONT_CARE : zpu_store_action(colorAttachment.storeAction),
            .clear_color = {
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.red,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.green,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.blue,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.alpha,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        if (![depth isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(depth->_textureType) ||
            depth->_pixelFormat != MTLPixelFormatDepth32Float ||
            !zpu_store_action_supported(descriptor.depthAttachment.storeAction)) return nil;
        depthTexture = [depth zpuTextureAtLevel:descriptor.depthAttachment.level
                                           slice:descriptor.depthAttachment.slice];
        if (depthTexture == NULL) return nil;
        pass.depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass.depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass.depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    if (descriptor.stencilAttachment.texture != nil) {
        ZPUTexture *stencil = (ZPUTexture *)descriptor.stencilAttachment.texture;
        if (![stencil isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(stencil->_textureType) ||
            stencil->_pixelFormat != MTLPixelFormatStencil8 ||
            !zpu_store_action_supported(descriptor.stencilAttachment.storeAction)) return nil;
        stencilTexture = [stencil zpuTextureAtLevel:descriptor.stencilAttachment.level
                                               slice:descriptor.stencilAttachment.slice];
        if (stencilTexture == NULL || zpu_metal_texture_width(stencilTexture) != zpu_metal_texture_width(colorTexture) ||
            zpu_metal_texture_height(stencilTexture) != zpu_metal_texture_height(colorTexture)) return nil;
    }
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(_zpuCommandBuffer, colorTexture, &pass);
    if (encoder == NULL) return nil;
    [self retainResource:texture];
    if (!zpu_configure_additional_color_attachments(self, encoder, descriptor)) {
        zpu_metal_render_encoder_destroy(encoder);
        return nil;
    }
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        [self retainResource:depth];
        if (zpu_metal_render_encoder_set_depth_texture(encoder, depthTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            return nil;
        }
    }
    if (descriptor.stencilAttachment.texture != nil) {
        ZPUTexture *stencil = (ZPUTexture *)descriptor.stencilAttachment.texture;
        [self retainResource:stencil];
        if (zpu_metal_render_encoder_set_stencil_texture(encoder, stencilTexture,
                zpu_load_action(descriptor.stencilAttachment.loadAction),
                zpu_store_action(descriptor.stencilAttachment.storeAction),
                (uint8_t)descriptor.stencilAttachment.clearStencil) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            return nil;
        }
    }
    if (!zpu_configure_visibility_result(self, encoder, descriptor.visibilityResultBuffer,
                                         zpu_visibility_result_type(descriptor))) {
        zpu_metal_render_encoder_destroy(encoder);
        return nil;
    }
    return (id<MTLRenderCommandEncoder>)[[ZPURenderEncoder alloc] initWithOwner:self encoder:encoder];
}
- (id<MTLParallelRenderCommandEncoder>)parallelRenderCommandEncoderWithDescriptor:(MTLRenderPassDescriptor *)descriptor {
    if (descriptor == nil) return nil;
    MTLRenderPassColorAttachmentDescriptor *colorAttachment = descriptor.colorAttachments[0];
    ZPUTexture *texture = (ZPUTexture *)colorAttachment.texture;
    ZPUTexture *depthAttachmentTexture = (ZPUTexture *)descriptor.depthAttachment.texture;
    ZPUTexture *stencilAttachmentTexture = (ZPUTexture *)descriptor.stencilAttachment.texture;
    if (texture == nil) {
        texture = zpu_hidden_color_target(self.device,
                                          depthAttachmentTexture != nil ? depthAttachmentTexture : stencilAttachmentTexture,
                                          depthAttachmentTexture != nil ? descriptor.depthAttachment.level : descriptor.stencilAttachment.level,
                                          depthAttachmentTexture != nil ? descriptor.depthAttachment.slice : descriptor.stencilAttachment.slice);
        if (texture == nil) return nil;
    }
    if (colorAttachment.texture != nil && !zpu_store_action_supported(colorAttachment.storeAction)) return nil;
    if (![texture isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(texture->_textureType)) return nil;
    zpu_metal_texture *colorTexture = [texture zpuTextureAtLevel:colorAttachment.texture != nil ? colorAttachment.level : 0
                                                            slice:colorAttachment.texture != nil ? colorAttachment.slice : 0];
    if (colorTexture == NULL) return nil;
    zpu_metal_texture *depthTexture = NULL;
    zpu_metal_texture *stencilTexture = NULL;
    zpu_metal_render_pass_descriptor pass = {
        .color = {
            .load_action = colorAttachment.texture == nil ? ZPU_METAL_LOAD_DONT_CARE : zpu_load_action(colorAttachment.loadAction),
            .store_action = colorAttachment.texture == nil ? ZPU_METAL_STORE_DONT_CARE : zpu_store_action(colorAttachment.storeAction),
            .clear_color = {
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.red,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.green,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.blue,
                colorAttachment.texture == nil ? 0.0f : (float)colorAttachment.clearColor.alpha,
            },
        },
        .depth = { ZPU_METAL_LOAD_DONT_CARE, ZPU_METAL_STORE_DONT_CARE, 1.0f },
    };
    if (descriptor.depthAttachment.texture != nil) {
        ZPUTexture *depth = (ZPUTexture *)descriptor.depthAttachment.texture;
        if (![depth isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(depth->_textureType) ||
            depth->_pixelFormat != MTLPixelFormatDepth32Float ||
            !zpu_store_action_supported(descriptor.depthAttachment.storeAction)) return nil;
        depthTexture = [depth zpuTextureAtLevel:descriptor.depthAttachment.level
                                           slice:descriptor.depthAttachment.slice];
        if (depthTexture == NULL) return nil;
        pass.depth.load_action = zpu_load_action(descriptor.depthAttachment.loadAction);
        pass.depth.store_action = zpu_store_action(descriptor.depthAttachment.storeAction);
        pass.depth.clear_depth = (float)descriptor.depthAttachment.clearDepth;
    }
    if (descriptor.stencilAttachment.texture != nil) {
        ZPUTexture *stencil = (ZPUTexture *)descriptor.stencilAttachment.texture;
        if (![stencil isKindOfClass:[ZPUTexture class]] || !zpu_render_texture_type_supported(stencil->_textureType) ||
            stencil->_pixelFormat != MTLPixelFormatStencil8 ||
            !zpu_store_action_supported(descriptor.stencilAttachment.storeAction)) return nil;
        stencilTexture = [stencil zpuTextureAtLevel:descriptor.stencilAttachment.level
                                               slice:descriptor.stencilAttachment.slice];
        if (stencilTexture == NULL || zpu_metal_texture_width(stencilTexture) != zpu_metal_texture_width(colorTexture) ||
            zpu_metal_texture_height(stencilTexture) != zpu_metal_texture_height(colorTexture)) return nil;
    }
    [self retainResource:texture];
    if (descriptor.depthAttachment.texture != nil) [self retainResource:descriptor.depthAttachment.texture];
    if (descriptor.stencilAttachment.texture != nil) [self retainResource:descriptor.stencilAttachment.texture];
    return (id<MTLParallelRenderCommandEncoder>)[[ZPUParallelRenderEncoder alloc]
        initWithOwner:self texture:texture renderTexture:colorTexture depthTexture:depthTexture stencilTexture:stencilTexture
        stencilLoadAction:descriptor.stencilAttachment.texture != nil ? zpu_load_action(descriptor.stencilAttachment.loadAction) : ZPU_METAL_LOAD_DONT_CARE
        stencilStoreAction:descriptor.stencilAttachment.texture != nil ? zpu_store_action(descriptor.stencilAttachment.storeAction) : ZPU_METAL_STORE_DONT_CARE
        stencilClearValue:(uint8_t)descriptor.stencilAttachment.clearStencil pass:pass descriptor:descriptor];
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
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != [_owner device] ||
        zpu_metal_command_buffer_encode_signal_event(_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        [self markError];
        return;
    }
    [self retainResource:zpuEvent];
}
- (void)encodeWaitForEvent:(id<MTLEvent>)event value:(uint64_t)value API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != [_owner device] ||
        zpu_metal_command_buffer_encode_wait_for_event(_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        [self markError];
        return;
    }
    [self retainResource:zpuEvent];
}
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)useResidencySet:(id<MTLResidencySet>)residencySet API_AVAILABLE(macos(15.0), ios(18.0)) {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != [_owner device]) {
        [self markError];
        return;
    }
    [zpuSet commit];
    [self retainResource:zpuSet];
}
- (void)useResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count API_AVAILABLE(macos(15.0), ios(18.0)) {
    if (residencySets == NULL) {
        if (count != 0) [self markError];
        return;
    }
    for (NSUInteger index = 0; index < count; ++index) [self useResidencySet:residencySets[index]];
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
    ZPUTexture *stencil = nil;
    zpu_metal_render_pass_descriptor pass;
    if (!zpu_metal4_render_pass_descriptor(_owner, descriptor, &color, &depth, &stencil, &pass)) return nil;
    zpu_metal_texture *colorTexture = [color zpuTextureAtLevel:descriptor.colorAttachments[0].texture != nil ? descriptor.colorAttachments[0].level : 0
                                                           slice:descriptor.colorAttachments[0].texture != nil ? descriptor.colorAttachments[0].slice : 0];
    zpu_metal_texture *depthTexture = depth == nil ? NULL : [depth zpuTextureAtLevel:descriptor.depthAttachment.level
                                                                                slice:descriptor.depthAttachment.slice];
    zpu_metal_texture *stencilTexture = stencil == nil ? NULL : [stencil zpuTextureAtLevel:descriptor.stencilAttachment.level
                                                                                         slice:descriptor.stencilAttachment.slice];
    if (colorTexture == NULL || (depth != nil && depthTexture == NULL) || (stencil != nil && stencilTexture == NULL)) return nil;
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(
        _legacyBuffer->_zpuCommandBuffer, colorTexture, &pass);
    if (encoder == NULL) {
        [self markError];
        return nil;
    }
    if (!zpu_configure_additional_metal4_color_attachments(_legacyBuffer, encoder, descriptor)) {
        zpu_metal_render_encoder_destroy(encoder);
        [self markError];
        return nil;
    }
    [_legacyBuffer retainResource:color];
    if (depth != nil) {
        [_legacyBuffer retainResource:depth];
        if (zpu_metal_render_encoder_set_depth_texture(encoder, depthTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            [self markError];
            return nil;
        }
    }
    if (stencil != nil) {
        [_legacyBuffer retainResource:stencil];
        if (zpu_metal_render_encoder_set_stencil_texture(encoder, stencilTexture,
                zpu_load_action(descriptor.stencilAttachment.loadAction),
                zpu_store_action(descriptor.stencilAttachment.storeAction),
                (uint8_t)descriptor.stencilAttachment.clearStencil) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            [self markError];
            return nil;
        }
    }
    if (!zpu_configure_visibility_result(_legacyBuffer, encoder, descriptor.visibilityResultBuffer,
                                         descriptor.visibilityResultType)) {
        zpu_metal_render_encoder_destroy(encoder);
        [self markError];
        return nil;
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
- (id<MTL4MachineLearningCommandEncoder>)machineLearningCommandEncoder {
    if (!_recording || _ended || _submitted || _failed || _activeEncoder != nil || _legacyBuffer == nil) return nil;
    ZPUMTL4MachineLearningEncoder *encoder = [[ZPUMTL4MachineLearningEncoder alloc] initWithOwner:self];
    _activeEncoder = encoder;
    return (id<MTL4MachineLearningCommandEncoder>)encoder;
}
- (void)useResidencySet:(id<MTLResidencySet>)residencySet {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != _owner || _legacyBuffer == nil) {
        [self markError];
        return;
    }
    [zpuSet commit];
    [_legacyBuffer retainResource:zpuSet];
}
- (void)useResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count {
    if (residencySets == NULL) {
        if (count != 0) [self markError];
        return;
    }
    for (NSUInteger index = 0; index < count; ++index) [self useResidencySet:residencySets[index]];
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
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner, bufferRange.bufferAddress);
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

@implementation ZPUMTL4MachineLearningEncoder
- (instancetype)initWithOwner:(ZPUMTL4CommandBuffer *)owner {
    if ((self = [super init])) _owner = owner;
    return self;
}
- (id<MTL4CommandBuffer>)commandBuffer { return _ended ? nil : (id<MTL4CommandBuffer>)_owner; }
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
    (void)fence;
    (void)afterEncoderStages;
    [_owner markError];
}
- (void)waitForFence:(id<MTLFence>)fence beforeEncoderStages:(MTLStages)beforeEncoderStages {
    (void)fence;
    (void)beforeEncoderStages;
    [_owner markError];
}
- (void)insertDebugSignpost:(NSString *)string { (void)string; }
- (void)pushDebugGroup:(NSString *)string { (void)string; }
- (void)popDebugGroup {}
- (void)setPipelineState:(id<MTL4MachineLearningPipelineState>)pipelineState {
    (void)pipelineState;
    _pipelineState = nil;
    [_owner markError];
}
- (void)setArgumentTable:(id<MTL4ArgumentTable>)argumentTable {
    if (argumentTable != nil &&
        (![argumentTable isKindOfClass:[ZPUMTL4ArgumentTable class]] ||
         ((ZPUMTL4ArgumentTable *)argumentTable)->_owner != _owner->_owner)) {
        [_owner markError];
        return;
    }
    _argumentTable = (ZPUMTL4ArgumentTable *)argumentTable;
}
- (void)dispatchNetworkWithIntermediatesHeap:(id<MTLHeap>)heap {
    (void)heap;
    /* There is no portable ZPU ML graph executor yet. Keep this operation
     * CPU-only and report the unsupported execution at submission time. */
    [_owner markError];
}
- (void)endEncoding {
    if (_ended) return;
    _ended = YES;
    if (_owner->_activeEncoder == self) _owner->_activeEncoder = nil;
}
@end

@implementation ZPUMTL4CommandQueue
- (instancetype)initWithOwner:(ZPUDevice *)owner descriptor:(MTL4CommandQueueDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _label = [descriptor.label copy];
        _residencySets = [NSMutableSet set];
        id queue = [owner newCommandQueue];
        if ([queue isKindOfClass:[ZPUCommandQueue class]]) _legacyQueue = (ZPUCommandQueue *)queue;
        else _failed = YES;
    }
    return self;
}
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (NSString *)label { return _label; }
- (void)commit:(const id<MTL4CommandBuffer> __nonnull [__nonnull])commandBuffers count:(NSUInteger)count {
    if (commandBuffers == NULL && count != 0) {
        _failed = YES;
        return;
    }
    if (_failed) {
        for (NSUInteger index = 0; index < count; ++index) {
            id buffer = commandBuffers[index];
            if ([buffer respondsToSelector:@selector(markError)]) [buffer markError];
        }
        return;
    }
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
    BOOL success = !_failed && (commandBuffers != NULL || count == 0);
    if (success) {
        for (NSUInteger index = 0; index < count; ++index) {
            ZPUMTL4CommandBuffer *buffer = (ZPUMTL4CommandBuffer *)commandBuffers[index];
            if (![buffer isKindOfClass:[ZPUMTL4CommandBuffer class]] || buffer->_owner != _owner ||
                ![buffer commitCPU]) {
                if ([buffer respondsToSelector:@selector(markError)]) [buffer markError];
                success = NO;
            }
        }
    } else if (commandBuffers != NULL) {
        for (NSUInteger index = 0; index < count; ++index) {
            id buffer = commandBuffers[index];
            if ([buffer respondsToSelector:@selector(markError)]) [buffer markError];
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
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != _owner || _legacyQueue == nil) {
        _failed = YES;
        return;
    }
    ZPUCommandBuffer *buffer = (ZPUCommandBuffer *)[_legacyQueue commandBuffer];
    if (buffer == nil || zpu_metal_command_buffer_encode_signal_event(buffer->_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        _failed = YES;
        if (buffer != nil) [buffer markError];
        return;
    }
    [buffer commit];
}
- (void)waitForEvent:(id<MTLEvent>)event value:(uint64_t)value {
    ZPUSharedEvent *zpuEvent = (ZPUSharedEvent *)event;
    if (![zpuEvent isKindOfClass:[ZPUSharedEvent class]] || zpuEvent->_owner != _owner || _legacyQueue == nil) {
        _failed = YES;
        return;
    }
    ZPUCommandBuffer *buffer = (ZPUCommandBuffer *)[_legacyQueue commandBuffer];
    if (buffer == nil || zpu_metal_command_buffer_encode_wait_for_event(buffer->_zpuCommandBuffer, zpuEvent->_zpuEvent, value) != ZPU_METAL_OK) {
        _failed = YES;
        if (buffer != nil) [buffer markError];
        return;
    }
    [buffer commit];
}
- (void)signalDrawable:(id<MTLDrawable>)drawable { (void)drawable; _failed = YES; }
- (void)waitForDrawable:(id<MTLDrawable>)drawable { (void)drawable; _failed = YES; }
- (void)addResidencySet:(id<MTLResidencySet>)residencySet {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != _owner) {
        _failed = YES;
        return;
    }
    [_residencySets addObject:zpuSet];
    [zpuSet commit];
}
- (void)addResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count {
    if (residencySets == NULL) return;
    for (NSUInteger index = 0; index < count; ++index) [self addResidencySet:residencySets[index]];
}
- (void)removeResidencySet:(id<MTLResidencySet>)residencySet {
    ZPUResidencySet *zpuSet = (ZPUResidencySet *)residencySet;
    if (![zpuSet isKindOfClass:[ZPUResidencySet class]] || zpuSet->_owner != _owner) {
        _failed = YES;
        return;
    }
    [_residencySets removeObject:zpuSet];
}
- (void)removeResidencySets:(const id<MTLResidencySet> __nonnull [__nonnull])residencySets count:(NSUInteger)count {
    if (residencySets == NULL) {
        if (count != 0) _failed = YES;
        return;
    }
    for (NSUInteger index = 0; index < count; ++index) [self removeResidencySet:residencySets[index]];
}
- (void)updateTextureMappings:(id<MTLTexture>)texture heap:(id<MTLHeap>)heap operations:(const MTL4UpdateSparseTextureMappingOperation [_Nonnull])operations count:(NSUInteger)count {
    (void)texture;
    (void)heap;
    (void)operations;
    if (count != 0) _failed = YES;
}
- (void)copyTextureMappingsFromTexture:(id<MTLTexture>)sourceTexture toTexture:(id<MTLTexture>)destinationTexture operations:(const MTL4CopySparseTextureMappingOperation [_Nonnull])operations count:(NSUInteger)count {
    (void)sourceTexture;
    (void)destinationTexture;
    (void)operations;
    if (count != 0) _failed = YES;
}
- (void)updateBufferMappings:(id<MTLBuffer>)buffer heap:(id<MTLHeap>)heap operations:(const MTL4UpdateSparseBufferMappingOperation [_Nonnull])operations count:(NSUInteger)count {
    (void)buffer;
    (void)heap;
    (void)operations;
    if (count != 0) _failed = YES;
}
- (void)copyBufferMappingsFromBuffer:(id<MTLBuffer>)sourceBuffer toBuffer:(id<MTLBuffer>)destinationBuffer operations:(const MTL4CopySparseBufferMappingOperation [_Nonnull])operations count:(NSUInteger)count {
    (void)sourceBuffer;
    (void)destinationBuffer;
    (void)operations;
    if (count != 0) _failed = YES;
}
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
    if (!zpu_color_attachment_map_is_identity(mapping)) [_owner markError];
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    [(id)_legacy setRenderPipelineState:pipelineState];
}
- (void)setViewport:(MTLViewport)viewport { [(id)_legacy setViewport:viewport]; }
- (void)setViewports:(const MTLViewport [__nonnull])viewports count:(NSUInteger)count {
    if (viewports == NULL || count != 1) { [_owner markError]; return; }
    [(id)_legacy setViewports:viewports count:count];
}
- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping *)viewMappings {
    if (count != 1 || (viewMappings != NULL &&
        (viewMappings[0].viewportArrayIndexOffset != 0 || viewMappings[0].renderTargetArrayIndexOffset != 0))) {
        [_owner markError];
        return;
    }
    [(id)_legacy setVertexAmplificationCount:count viewMappings:viewMappings];
}
- (void)setCullMode:(MTLCullMode)cullMode { [(id)_legacy setCullMode:cullMode]; }
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode { [(id)_legacy setDepthClipMode:depthClipMode]; }
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp {
    [(id)_legacy setDepthBias:depthBias slopeScale:slopeScale clamp:clamp];
}
- (void)setDepthTestMinBound:(float)minBound maxBound:(float)maxBound {
    [(id)_legacy setDepthTestMinBound:minBound maxBound:maxBound];
}
- (void)setScissorRect:(MTLScissorRect)rect { [(id)_legacy setScissorRect:rect]; }
- (void)setScissorRects:(const MTLScissorRect [__nonnull])rects count:(NSUInteger)count {
    if (rects == NULL || count != 1) { [_owner markError]; return; }
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
    [(id)_legacy setColorStoreAction:storeAction atIndex:colorAttachmentIndex];
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction {
    [(id)_legacy setDepthStoreAction:storeAction];
}
- (void)setStencilStoreAction:(MTLStoreAction)storeAction {
    [(id)_legacy setStencilStoreAction:storeAction];
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
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength instanceCount:(NSUInteger)instanceCount {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0 instanceCount:instanceCount];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indexBuffer);
    if (buffer == nil || indexBufferLength > buffer.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexCount:indexCount indexType:indexType
                           indexBuffer:(id<MTLBuffer>)buffer indexBufferOffset:0 instanceCount:instanceCount
                           baseVertex:baseVertex baseInstance:baseInstance];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType indirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indirectBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    [(id)_legacy drawPrimitives:primitiveType indirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:0];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexType:(MTLIndexType)indexType indexBuffer:(MTLGPUAddress)indexBuffer indexBufferLength:(NSUInteger)indexBufferLength indirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *indices = zpu_metal4_buffer_for_address(_owner->_owner, indexBuffer);
    ZPUBuffer *indirect = zpu_metal4_buffer_for_address(_owner->_owner, indirectBuffer);
    if (indices == nil || indirect == nil || indexBufferLength > indices.length) { [_owner markError]; return; }
    [(id)_legacy drawIndexedPrimitives:primitiveType indexType:indexType
                           indexBuffer:(id<MTLBuffer>)indices indexBufferOffset:0
                           indirectBuffer:(id<MTLBuffer>)indirect indirectBufferOffset:0];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange {
    [(id)_legacy executeCommandsInBuffer:indirectCommandBuffer withRange:executionRange];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer indirectBuffer:(MTLGPUAddress)indirectRangeBuffer {
    ZPUBuffer *range = zpu_metal4_buffer_for_address(_owner->_owner, indirectRangeBuffer);
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
    if (argumentTable != nil &&
        (![argumentTable isKindOfClass:[ZPUMTL4ArgumentTable class]] ||
         ((ZPUMTL4ArgumentTable *)argumentTable)->_owner != _owner->_owner)) {
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
        ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, (MTLGPUAddress)bufferIDs[index]);
        if (bufferIDs[index] != 0 && buffer == nil) {
            [_owner markError];
            return;
        }
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
        if (textureIDs[index] != 0 &&
            (![resource isKindOfClass:[ZPUTexture class]] || ((ZPUTexture *)resource)->_owner != _owner->_owner)) {
            [_owner markError];
            return;
        }
        if (resource == nil) continue;
        if ((stages & MTLRenderStageVertex) != 0) [(id)_legacy setVertexTexture:resource atIndex:index];
        if ((stages & MTLRenderStageFragment) != 0) [(id)_legacy setFragmentTexture:resource atIndex:index];
    }
    const uint64_t *samplerIDs = (const uint64_t *)_argumentTable->_samplerResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxSamplerStateBindCount; ++index) {
        id resource = zpu_resource_for_id(samplerIDs[index]);
        if (samplerIDs[index] != 0 &&
            (![resource isKindOfClass:[ZPUSamplerState class]] || ((ZPUSamplerState *)resource)->_owner != _owner->_owner)) {
            [_owner markError];
            return;
        }
        if (resource == nil) continue;
        if ((stages & MTLRenderStageVertex) != 0) [(id)_legacy setVertexSamplerState:resource atIndex:index];
        if ((stages & MTLRenderStageFragment) != 0) [(id)_legacy setFragmentSamplerState:resource atIndex:index];
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
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indirectBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    [(id)_legacy dispatchThreadgroupsWithIndirectBuffer:(id<MTLBuffer>)buffer indirectBufferOffset:0
                                  threadsPerThreadgroup:threadsPerThreadgroup];
    [_owner->_legacyBuffer retainResource:buffer];
    _stages |= MTLStageDispatch;
}
- (void)dispatchThreadsWithIndirectBuffer:(MTLGPUAddress)indirectBuffer {
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indirectBuffer);
    if (buffer == nil) { [_owner markError]; return; }
    const BOOL arrayKernel = _legacy->_kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
    if (arrayKernel) {
        if (_legacy->_boundTexture == nil || _legacy->_boundTexture->_textureType != MTLTextureType2DArray) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < _legacy->_boundTexture.arrayLength; ++slice) {
            zpu_metal_texture *sliceTexture = [_legacy->_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_legacy->_zpuEncoder, sliceTexture,
                    (uint32_t)_legacy->_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_set_array_slice(_legacy->_zpuEncoder, (uint32_t)slice,
                    (uint32_t)_legacy->_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threads_indirect(_legacy->_zpuEncoder,
                    buffer->_zpuBuffer) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    } else if (_legacy->_kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D) {
        if (_legacy->_boundTexture == nil || _legacy->_boundTexture->_textureType != MTLTextureType3D) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < _legacy->_boundTexture.depth; ++slice) {
            zpu_metal_texture *sliceTexture = [_legacy->_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_legacy->_zpuEncoder, sliceTexture,
                    (uint32_t)_legacy->_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_set_array_slice(_legacy->_zpuEncoder, (uint32_t)slice,
                    (uint32_t)_legacy->_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threads_indirect(_legacy->_zpuEncoder,
                    buffer->_zpuBuffer) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    } else if (_legacy->_boundTexture != nil && (_legacy->_boundTexture->_textureType == MTLTextureType2DArray ||
                                                 _legacy->_boundTexture->_textureType == MTLTextureType3D)) {
        [_owner markError];
        return;
    } else if (zpu_metal_compute_encoder_dispatch_threads_indirect(
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
    ZPUBuffer *buffer = zpu_metal4_buffer_for_address(_owner->_owner, indirectRangeBuffer);
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
    if (argumentTable != nil &&
        (![argumentTable isKindOfClass:[ZPUMTL4ArgumentTable class]] ||
         ((ZPUMTL4ArgumentTable *)argumentTable)->_owner != _owner->_owner)) {
        [_owner markError];
        return;
    }
    _argumentTable = (ZPUMTL4ArgumentTable *)argumentTable;
    if (_argumentTable == nil) return;
    if (_argumentTable->_invalid) { [_owner markError]; return; }
    const uint64_t *bufferIDs = (const uint64_t *)_argumentTable->_bufferResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxBufferBindCount; ++index) {
        id resource = zpu_resource_for_id(bufferIDs[index]);
        if (bufferIDs[index] != 0 &&
            (![resource isKindOfClass:[ZPUBuffer class]] || ((ZPUBuffer *)resource)->_owner != _owner->_owner)) {
            [_owner markError];
            return;
        }
        if (resource == nil) continue;
        const uint64_t *strides = (const uint64_t *)_argumentTable->_bufferStrides.bytes;
        [_legacy setBuffer:(id<MTLBuffer>)resource offset:0 atIndex:index];
        if (strides[index] != 0) {
            [_legacy setBuffer:(id<MTLBuffer>)resource offset:0 attributeStride:(NSUInteger)strides[index] atIndex:index];
        }
    }
    const uint64_t *textureIDs = (const uint64_t *)_argumentTable->_textureResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxTextureBindCount; ++index) {
        id resource = zpu_resource_for_id(textureIDs[index]);
        if (textureIDs[index] != 0 &&
            (![resource isKindOfClass:[ZPUTexture class]] || ((ZPUTexture *)resource)->_owner != _owner->_owner)) {
            [_owner markError];
            return;
        }
        if (resource == nil) continue;
        [_legacy setTexture:(id<MTLTexture>)resource atIndex:index];
    }
    const uint64_t *samplerIDs = (const uint64_t *)_argumentTable->_samplerResources.bytes;
    for (NSUInteger index = 0; index < _argumentTable->_maxSamplerStateBindCount; ++index) {
        id resource = zpu_resource_for_id(samplerIDs[index]);
        if (samplerIDs[index] != 0 &&
            (![resource isKindOfClass:[ZPUSamplerState class]] || ((ZPUSamplerState *)resource)->_owner != _owner->_owner)) {
            [_owner markError];
            return;
        }
        if (resource == nil) continue;
        [_legacy setSamplerState:(id<MTLSamplerState>)resource atIndex:index];
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
    if (!zpu_texture_belongs_to_device([_owner device], source) || !zpu_texture_belongs_to_device([_owner device], destination) ||
        sliceCount == 0 || levelCount == 0 ||
        sourceSlice > source.arrayLength || sliceCount > source.arrayLength - sourceSlice ||
        destinationSlice > destination.arrayLength || sliceCount > destination.arrayLength - destinationSlice ||
        sourceLevel > source.mipmapLevelCount || levelCount > source.mipmapLevelCount - sourceLevel ||
        destinationLevel > destination.mipmapLevelCount || levelCount > destination.mipmapLevelCount - destinationLevel) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(source->_textureType) || zpu_texture_type_is_3d(destination->_textureType)) {
        if (!zpu_texture_type_is_3d(source->_textureType) || !zpu_texture_type_is_3d(destination->_textureType) ||
            sourceSlice != 0 || destinationSlice != 0 || sliceCount != 1) {
            [_owner markError];
            return;
        }
        for (NSUInteger level = 0; level < levelCount; ++level) {
            const NSUInteger sourceDepth = zpu_texture_depth_at_level(source, sourceLevel + level);
            const NSUInteger destinationDepth = zpu_texture_depth_at_level(destination, destinationLevel + level);
            if (sourceDepth != destinationDepth) { [_owner markError]; return; }
            for (NSUInteger plane = 0; plane < sourceDepth; ++plane) {
                zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel + level slice:plane];
                zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel + level slice:plane];
                if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
                    zpu_metal_texture_width(sourceTextureAtLevel) != zpu_metal_texture_width(destinationTextureAtLevel) ||
                    zpu_metal_texture_height(sourceTextureAtLevel) != zpu_metal_texture_height(destinationTextureAtLevel) ||
                    zpu_metal_compute_encoder_copy_texture_to_texture(_legacy->_zpuEncoder, sourceTextureAtLevel,
                        (zpu_metal_region){.origin = {0, 0, 0}, .size = {zpu_metal_texture_width(sourceTextureAtLevel), zpu_metal_texture_height(sourceTextureAtLevel), 1}},
                        destinationTextureAtLevel,
                        (zpu_metal_region){.origin = {0, 0, 0}, .size = {zpu_metal_texture_width(destinationTextureAtLevel), zpu_metal_texture_height(destinationTextureAtLevel), 1}}) != ZPU_METAL_OK) {
                    [_owner markError];
                    return;
                }
            }
        }
        [_owner->_legacyBuffer retainResource:source];
        [_owner->_legacyBuffer retainResource:destination];
        _stages |= MTLStageBlit;
        return;
    }
    for (NSUInteger slice = 0; slice < sliceCount; ++slice) {
        for (NSUInteger level = 0; level < levelCount; ++level) {
            zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel + level slice:sourceSlice + slice];
            zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel + level slice:destinationSlice + slice];
            if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL) {
                [_owner markError];
                return;
            }
            const zpu_metal_region sourceRegion = {
                .origin = {0, 0, 0},
                .size = {zpu_metal_texture_width(sourceTextureAtLevel), zpu_metal_texture_height(sourceTextureAtLevel), 1},
            };
            const zpu_metal_region destinationRegion = {
                .origin = {0, 0, 0},
                .size = {zpu_metal_texture_width(destinationTextureAtLevel), zpu_metal_texture_height(destinationTextureAtLevel), 1},
            };
            if (zpu_metal_texture_width(sourceTextureAtLevel) != zpu_metal_texture_width(destinationTextureAtLevel) ||
                zpu_metal_texture_height(sourceTextureAtLevel) != zpu_metal_texture_height(destinationTextureAtLevel) ||
                zpu_metal_compute_encoder_copy_texture_to_texture(
                    _legacy->_zpuEncoder, sourceTextureAtLevel,
                    sourceRegion,
                    destinationTextureAtLevel,
                    destinationRegion) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    zpu_metal_region sourceRegion;
    zpu_metal_region destinationRegion;
    if (!zpu_texture_belongs_to_device([_owner device], source) ||
        !zpu_texture_belongs_to_device([_owner device], destination) ||
        !zpu_metal4_region(sourceOrigin, sourceSize, &sourceRegion) ||
        !zpu_metal4_region(destinationOrigin, sourceSize, &destinationRegion)) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(source->_textureType) || zpu_texture_type_is_3d(destination->_textureType)) {
        const NSUInteger sourceDepth = zpu_texture_depth_at_level(source, sourceLevel);
        const NSUInteger destinationDepth = zpu_texture_depth_at_level(destination, destinationLevel);
        if (!zpu_texture_type_is_3d(source->_textureType) || !zpu_texture_type_is_3d(destination->_textureType) ||
            sourceSlice != 0 || destinationSlice != 0 || sourceDepth == 0 || destinationDepth == 0 ||
            sourceOrigin.z > sourceDepth || destinationOrigin.z > destinationDepth ||
            sourceSize.depth > sourceDepth - sourceOrigin.z || sourceSize.depth > destinationDepth - destinationOrigin.z) {
            [_owner markError];
            return;
        }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceOrigin.z + plane];
            zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel slice:destinationOrigin.z + plane];
            const zpu_metal_region planeSourceRegion = {
                .origin = {sourceOrigin.x, sourceOrigin.y, 0},
                .size = {sourceSize.width, sourceSize.height, 1},
            };
            const zpu_metal_region planeDestinationRegion = {
                .origin = {destinationOrigin.x, destinationOrigin.y, 0},
                .size = {sourceSize.width, sourceSize.height, 1},
            };
            if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
                zpu_metal_compute_encoder_copy_texture_to_texture(_legacy->_zpuEncoder, sourceTextureAtLevel,
                    planeSourceRegion, destinationTextureAtLevel, planeDestinationRegion) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
        [_owner->_legacyBuffer retainResource:source];
        [_owner->_legacyBuffer retainResource:destination];
        _stages |= MTLStageBlit;
        return;
    }
    zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceSlice];
    zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel slice:destinationSlice];
    if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
        zpu_metal_compute_encoder_copy_texture_to_texture(_legacy->_zpuEncoder, sourceTextureAtLevel, sourceRegion,
            destinationTextureAtLevel, destinationRegion) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage {
    (void)destinationBytesPerImage;
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    zpu_metal_region sourceRegion;
    if (!zpu_texture_belongs_to_device([_owner device], source) ||
        !zpu_buffer_belongs_to_device([_owner device], destination) ||
        !zpu_metal4_region(sourceOrigin, sourceSize, &sourceRegion)) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(source->_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(source, sourceLevel);
        const NSUInteger rowBytes = sourceSize.width * 4;
        const NSUInteger rowStride = destinationBytesPerRow == 0 ? rowBytes : destinationBytesPerRow;
        if (sourceSlice != 0 || levelDepth == 0 || sourceOrigin.z > levelDepth ||
            sourceSize.depth > levelDepth - sourceOrigin.z || rowStride < rowBytes ||
            (sourceSize.height != 0 && rowStride > SIZE_MAX / sourceSize.height)) {
            [_owner markError];
            return;
        }
        const NSUInteger imageStride = destinationBytesPerImage == 0 ? rowStride * sourceSize.height : destinationBytesPerImage;
        if (sourceSize.depth > 1 && imageStride > SIZE_MAX / (sourceSize.depth - 1)) {
            [_owner markError];
            return;
        }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceOrigin.z + plane];
            const zpu_metal_region planeSourceRegion = {
                .origin = {sourceOrigin.x, sourceOrigin.y, 0},
                .size = {sourceSize.width, sourceSize.height, 1},
            };
            if (sourceTextureAtLevel == NULL || destinationOffset > SIZE_MAX - plane * imageStride ||
                zpu_metal_compute_encoder_copy_texture_to_buffer(_legacy->_zpuEncoder, sourceTextureAtLevel,
                    planeSourceRegion, destination->_zpuBuffer, destinationOffset + plane * imageStride,
                    destinationBytesPerRow) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
        [_owner->_legacyBuffer retainResource:source];
        [_owner->_legacyBuffer retainResource:destination];
        _stages |= MTLStageBlit;
        return;
    }
    zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceSlice];
    if (sourceTextureAtLevel == NULL ||
        zpu_metal_compute_encoder_copy_texture_to_buffer(_legacy->_zpuEncoder, sourceTextureAtLevel, sourceRegion,
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
    if (!zpu_buffer_belongs_to_device([_owner device], source) ||
        !zpu_buffer_belongs_to_device([_owner device], destination) ||
        zpu_metal_compute_encoder_copy_buffer(_legacy->_zpuEncoder, source->_zpuBuffer, sourceOffset,
            destination->_zpuBuffer, destinationOffset, size) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    zpu_metal_region destinationRegion;
    if (!zpu_buffer_belongs_to_device([_owner device], source) ||
        !zpu_texture_belongs_to_device([_owner device], destination) ||
        !zpu_metal4_region(destinationOrigin, sourceSize, &destinationRegion)) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(destination->_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(destination, destinationLevel);
        const NSUInteger rowBytes = sourceSize.width * 4;
        const NSUInteger rowStride = sourceBytesPerRow == 0 ? rowBytes : sourceBytesPerRow;
        if (destinationSlice != 0 || levelDepth == 0 || destinationOrigin.z > levelDepth ||
            sourceSize.depth > levelDepth - destinationOrigin.z || rowStride < rowBytes ||
            (sourceSize.height != 0 && rowStride > SIZE_MAX / sourceSize.height)) {
            [_owner markError];
            return;
        }
        const NSUInteger imageStride = sourceBytesPerImage == 0 ? rowStride * sourceSize.height : sourceBytesPerImage;
        if (sourceSize.depth > 1 && imageStride > SIZE_MAX / (sourceSize.depth - 1)) {
            [_owner markError];
            return;
        }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *destinationTextureAtLevel =
                [destination zpuTextureAtLevel:destinationLevel slice:destinationOrigin.z + plane];
            const zpu_metal_region planeDestinationRegion = {
                .origin = {destinationOrigin.x, destinationOrigin.y, 0},
                .size = {sourceSize.width, sourceSize.height, 1},
            };
            if (destinationTextureAtLevel == NULL || sourceOffset > SIZE_MAX - plane * imageStride ||
                zpu_metal_compute_encoder_copy_buffer_to_texture(_legacy->_zpuEncoder, source->_zpuBuffer,
                    sourceOffset + plane * imageStride, sourceBytesPerRow, destinationTextureAtLevel,
                    planeDestinationRegion) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
        [_owner->_legacyBuffer retainResource:source];
        [_owner->_legacyBuffer retainResource:destination];
        _stages |= MTLStageBlit;
        return;
    }
    (void)sourceBytesPerImage;
    zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel slice:destinationSlice];
    if (destinationTextureAtLevel == NULL ||
        zpu_metal_compute_encoder_copy_buffer_to_texture(_legacy->_zpuEncoder, source->_zpuBuffer, sourceOffset,
            sourceBytesPerRow, destinationTextureAtLevel, destinationRegion) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options {
    if (options != MTLBlitOptionNone) { [_owner markError]; return; }
    [self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel destinationOrigin:destinationOrigin];
}
- (void)copyFromTensor:(id<MTLTensor>)sourceTensor sourceOrigin:(MTLTensorExtents *)sourceOrigin sourceDimensions:(MTLTensorExtents *)sourceDimensions toTensor:(id<MTLTensor>)destinationTensor destinationOrigin:(MTLTensorExtents *)destinationOrigin destinationDimensions:(MTLTensorExtents *)destinationDimensions {
    ZPUTensor *source = (ZPUTensor *)sourceTensor;
    ZPUTensor *destination = (ZPUTensor *)destinationTensor;
    if (![source isKindOfClass:[ZPUTensor class]] || ![destination isKindOfClass:[ZPUTensor class]] ||
        source->_owner != [_owner device] || destination->_owner != [_owner device] ||
        !zpu_tensor_encode_copy_slice(source, sourceOrigin, sourceDimensions, destination, destinationOrigin,
                                       destinationDimensions, _legacy->_zpuEncoder, YES)) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:source];
    [_owner->_legacyBuffer retainResource:destination];
    _stages |= MTLStageBlit;
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (!zpu_texture_belongs_to_device([_owner device], zpuTexture) ||
        (zpuTexture->_pixelFormat != MTLPixelFormatRGBA8Unorm && zpuTexture->_pixelFormat != MTLPixelFormatBGRA8Unorm) ||
        zpuTexture.mipmapLevelCount < 2) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(zpuTexture->_textureType)) {
        for (NSUInteger level = 0; level + 1 < zpuTexture.mipmapLevelCount; ++level) {
            const NSUInteger sourceDepth = zpu_texture_depth_at_level(zpuTexture, level);
            const NSUInteger destinationDepth = zpu_texture_depth_at_level(zpuTexture, level + 1);
            if (sourceDepth == 0 || destinationDepth != (sourceDepth > 1 ? sourceDepth / 2 : 1)) {
                [_owner markError];
                return;
            }
            const NSUInteger zDenominator = destinationDepth * 2;
            for (NSUInteger plane = 0; plane < destinationDepth; ++plane) {
                const NSUInteger zPositionNumerator = (plane * 2 + 1) * sourceDepth - destinationDepth;
                const NSUInteger sourcePlane = zPositionNumerator / zDenominator;
                const NSUInteger zRemainder = zPositionNumerator % zDenominator;
                const BOOL hasSource1 = zRemainder != 0 && sourcePlane + 1 < sourceDepth;
                zpu_metal_texture *sourceTexture0 = [zpuTexture zpuTextureAtLevel:level slice:sourcePlane];
                zpu_metal_texture *sourceTexture1 = hasSource1 ?
                    [zpuTexture zpuTextureAtLevel:level slice:sourcePlane + 1] : NULL;
                zpu_metal_texture *destinationTexture = [zpuTexture zpuTextureAtLevel:level + 1 slice:plane];
                if (sourceTexture0 == NULL || (hasSource1 && sourceTexture1 == NULL) || destinationTexture == NULL ||
                    zpu_metal_compute_encoder_generate_mipmap_3d_weighted(_legacy->_zpuEncoder, sourceTexture0,
                        sourceTexture1, destinationTexture, hasSource1 ? (uint32_t)zRemainder : 0,
                        hasSource1 ? (uint32_t)zDenominator : 1) != ZPU_METAL_OK) {
                    [_owner markError];
                    return;
                }
            }
        }
        [_owner->_legacyBuffer retainResource:zpuTexture];
        _stages |= MTLStageBlit;
        return;
    }
    for (NSUInteger slice = 0; slice < zpuTexture.arrayLength; ++slice) {
        for (NSUInteger level = 0; level + 1 < zpuTexture.mipmapLevelCount; ++level) {
            if (zpu_metal_compute_encoder_generate_mipmap(
                    _legacy->_zpuEncoder, [zpuTexture zpuTextureAtLevel:level slice:slice],
                    [zpuTexture zpuTextureAtLevel:level + 1 slice:slice]) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    }
    [_owner->_legacyBuffer retainResource:zpuTexture];
}
- (void)fillBuffer:(id<MTLBuffer>)buffer range:(NSRange)range value:(uint8_t)value {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (!zpu_buffer_belongs_to_device([_owner device], zpuBuffer) ||
        zpu_metal_compute_encoder_fill_buffer(_legacy->_zpuEncoder, zpuBuffer->_zpuBuffer, range.location, range.length, value) != ZPU_METAL_OK) { [_owner markError]; return; }
    [_owner->_legacyBuffer retainResource:zpuBuffer];
    _stages |= MTLStageBlit;
}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (!zpu_texture_belongs_to_device(_owner->_owner, zpuTexture)) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:zpuTexture];
    _stages |= MTLStageBlit;
}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (!zpu_texture_belongs_to_device(_owner->_owner, zpuTexture) ||
        [zpuTexture zpuTextureAtLevel:level slice:zpu_texture_type_is_3d(zpuTexture->_textureType) ? 0 : slice] == NULL) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:zpuTexture];
    _stages |= MTLStageBlit;
}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture {
    [self optimizeContentsForGPUAccess:texture];
}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level {
    [self optimizeContentsForGPUAccess:texture slice:slice level:level];
}
- (void)resetCommandsInBuffer:(id<MTLIndirectCommandBuffer>)buffer withRange:(NSRange)range {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)buffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || zpuBuffer->_owner != _owner->_owner ||
        range.location > zpuBuffer->_maxCommandCount || range.length > zpuBuffer->_maxCommandCount - range.location) {
        [_owner markError];
        return;
    }
    [zpuBuffer resetWithRange:range];
    [_owner->_legacyBuffer retainResource:zpuBuffer];
    _stages |= MTLStageBlit;
}
- (void)copyIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)source sourceRange:(NSRange)sourceRange destination:(id<MTLIndirectCommandBuffer>)destination destinationIndex:(NSUInteger)destinationIndex {
    ZPUIndirectCommandBuffer *zpuSource = (ZPUIndirectCommandBuffer *)source;
    ZPUIndirectCommandBuffer *zpuDestination = (ZPUIndirectCommandBuffer *)destination;
    if (![zpuSource isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        ![zpuDestination isKindOfClass:[ZPUIndirectCommandBuffer class]] ||
        zpuSource->_owner != _owner->_owner || zpuDestination->_owner != _owner->_owner ||
        ![zpuDestination copyCommandsFrom:zpuSource sourceRange:sourceRange destinationIndex:destinationIndex]) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:zpuSource];
    [_owner->_legacyBuffer retainResource:zpuDestination];
    _stages |= MTLStageBlit;
}
- (void)optimizeIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)range {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || zpuBuffer->_owner != _owner->_owner ||
        range.location > zpuBuffer->_maxCommandCount || range.length > zpuBuffer->_maxCommandCount - range.location) {
        [_owner markError];
        return;
    }
    [_owner->_legacyBuffer retainResource:zpuBuffer];
    _stages |= MTLStageBlit;
}
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

static NSString *zpu_compute_kernel_name(zpu_metal_compute_kernel kernel) {
    switch (kernel) {
        case ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8: return @"zpu_cpu_fill_gradient_rgba8";
        case ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE: return @"zpu_cpu_copy_rgba8_buffer_to_texture";
        case ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY: return @"zpu_cpu_fill_gradient_rgba8_array";
        case ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D: return @"zpu_cpu_fill_gradient_rgba8_3d";
        case ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT: return @"zpu_cpu_fill_gradient_r32_float";
        case ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT: return @"zpu_cpu_fill_gradient_rgba16_float";
        default: return nil;
    }
}

@implementation ZPUComputePipelineState
- (instancetype)initWithOwner:(ZPUDevice *)owner function:(id<MTLFunction>)function error:(NSError **)error {
    if ((self = [super init])) {
        _owner = owner;
        _kernel = 0;
        _maxTotalThreadsPerThreadgroup = 1024;
        _requiredThreadsPerThreadgroup = MTLSizeMake(0, 0, 0);
        _supportsIndirectCommandBuffers = YES;
        ZPUCPUFunction *cpuFunction = (ZPUCPUFunction *)function;
        if (![cpuFunction isKindOfClass:[ZPUCPUFunction class]] || cpuFunction->_owner != owner ||
            cpuFunction.functionType != MTLFunctionTypeKernel) {
            zpu_set_error(error, @"ZPU CPU Metal compute pipelines require a ZPU-owned CPU kernel function");
            return nil;
        }
        NSString *name = cpuFunction->_name;
        BOOL is_kernel = YES;
        if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_rgba8"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_copy_rgba8_buffer_to_texture"]) {
            _kernel = ZPU_METAL_COMPUTE_COPY_RGBA8_BUFFER_TO_TEXTURE;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_rgba8_array"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_rgba8_3d"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_r32_float"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_R32_FLOAT;
        } else if (is_kernel && [name isEqualToString:@"zpu_cpu_fill_gradient_rgba16_float"]) {
            _kernel = ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA16_FLOAT;
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
- (NSUInteger)maxTotalThreadsPerThreadgroup { return _maxTotalThreadsPerThreadgroup; }
- (NSUInteger)threadExecutionWidth { return 1; }
- (NSUInteger)staticThreadgroupMemoryLength { return 0; }
- (BOOL)supportIndirectCommandBuffers API_AVAILABLE(macos(10.14), ios(12.0)) { return _supportsIndirectCommandBuffers; }
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) { return (MTLResourceID){0}; }
- (MTLShaderValidation)shaderValidation API_AVAILABLE(macos(15.0), ios(18.0)) { return (MTLShaderValidation)0; }
- (MTLSize)requiredThreadsPerThreadgroup API_AVAILABLE(macos(26.0), ios(26.0)) { return _requiredThreadsPerThreadgroup; }
- (MTLComputePipelineReflection *)reflection API_AVAILABLE(macos(26.0), ios(26.0)) { return _reflection; }
- (id<MTLFunctionHandle>)functionHandleWithName:(NSString *)name API_AVAILABLE(macos(26.0), ios(26.0)) {
    NSString *kernelName = zpu_compute_kernel_name(_kernel);
    if (kernelName == nil || ![kernelName isEqualToString:name]) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:_owner
                                                                        name:kernelName
                                                                 functionType:MTLFunctionTypeKernel];
}
- (id<MTLFunctionHandle>)functionHandleWithBinaryFunction:(id<MTL4BinaryFunction>)function API_AVAILABLE(macos(26.0), ios(26.0)) {
    ZPUMTL4BinaryFunction *binary = (ZPUMTL4BinaryFunction *)function;
    if (![binary isKindOfClass:[ZPUMTL4BinaryFunction class]] || binary->_owner != _owner ||
        binary->_functionType != MTLFunctionTypeKernel) return nil;
    return [self functionHandleWithName:binary->_name];
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
    ZPUCPUFunction *cpuFunction = (ZPUCPUFunction *)function;
    if (![cpuFunction isKindOfClass:[ZPUCPUFunction class]] || cpuFunction->_owner != _owner ||
        cpuFunction.functionType != MTLFunctionTypeKernel) return nil;
    NSString *kernelName = zpu_compute_kernel_name(_kernel);
    if (kernelName == nil || ![kernelName isEqualToString:cpuFunction->_name]) return nil;
    return (id<MTLFunctionHandle>)[[ZPUFunctionHandle alloc] initWithOwner:_owner
                                                                        name:kernelName
                                                                 functionType:MTLFunctionTypeKernel];
}
- (id<MTLComputePipelineState>)newComputePipelineStateWithAdditionalBinaryFunctions:(NSArray<id<MTLFunction>> *)functions error:(NSError **)error API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)functions;
    zpu_set_error(error, @"ZPU CPU Metal does not link binary functions");
    return nil;
}
- (id<MTLVisibleFunctionTable>)newVisibleFunctionTableWithDescriptor:(MTLVisibleFunctionTableDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    if (descriptor == nil) return nil;
    return (id<MTLVisibleFunctionTable>)[[ZPUVisibleFunctionTable alloc]
        initWithOwner:_owner functionCount:descriptor.functionCount stage:0];
}
- (id<MTLIntersectionFunctionTable>)newIntersectionFunctionTableWithDescriptor:(MTLIntersectionFunctionTableDescriptor *)descriptor API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    if (descriptor == nil) return nil;
    return (id<MTLIntersectionFunctionTable>)[[ZPUIntersectionFunctionTable alloc]
        initWithOwner:_owner functionCount:descriptor.functionCount];
}
@end

static BOOL zpu_function_table_range_valid(NSUInteger count, NSRange range) {
    return range.location <= count && range.length <= count - range.location;
}

static BOOL zpu_function_table_handle_belongs_to_device(ZPUDevice *owner,
                                                          id<MTLFunctionHandle> function) {
    if (function == nil) return YES;
    ZPUFunctionHandle *handle = (ZPUFunctionHandle *)function;
    return [handle isKindOfClass:[ZPUFunctionHandle class]] && handle->_owner == owner;
}

static BOOL zpu_function_table_buffer_belongs_to_device(ZPUDevice *owner,
                                                          id<MTLBuffer> buffer) {
    if (buffer == nil) return YES;
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    return [zpuBuffer isKindOfClass:[ZPUBuffer class]] && zpuBuffer->_owner == owner;
}

@implementation ZPUVisibleFunctionTable
- (instancetype)initWithOwner:(ZPUDevice *)owner functionCount:(NSUInteger)functionCount
                         stage:(MTLRenderStages)stage {
    if (owner == nil || functionCount > SIZE_MAX / sizeof(uint64_t)) return nil;
    if ((self = [super init])) {
        _owner = owner;
        _functionCount = functionCount;
        _stage = stage;
        _functions = [NSMutableArray arrayWithCapacity:functionCount];
        for (NSUInteger index = 0; index < functionCount; ++index) [_functions addObject:[NSNull null]];
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return MTLResourceStorageModeShared; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize {
    return _functionCount > SIZE_MAX / sizeof(uint64_t) ? SIZE_MAX : _functionCount * sizeof(uint64_t);
}
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) {
    return (MTLResourceID){_resourceID};
}
- (void)setFunction:(id<MTLFunctionHandle>)function atIndex:(NSUInteger)index {
    if (index >= _functionCount || !zpu_function_table_handle_belongs_to_device(_owner, function)) return;
    _functions[index] = function == nil ? (id)[NSNull null] : (id)function;
}
- (void)setFunctions:(const id<MTLFunctionHandle> __nullable [__nonnull])functions withRange:(NSRange)range {
    if (functions == NULL || !zpu_function_table_range_valid(_functionCount, range)) return;
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        id<MTLFunctionHandle> function = functions[offset];
        if (!zpu_function_table_handle_belongs_to_device(_owner, function)) return;
    }
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        id<MTLFunctionHandle> function = functions[offset];
        _functions[range.location + offset] = function == nil ? (id)[NSNull null] : (id)function;
    }
}
@end

@implementation ZPUIntersectionFunctionTable
- (instancetype)initWithOwner:(ZPUDevice *)owner functionCount:(NSUInteger)functionCount {
    if (owner == nil || functionCount > SIZE_MAX / sizeof(NSUInteger) ||
        functionCount > SIZE_MAX / sizeof(MTLIntersectionFunctionSignature)) return nil;
    if ((self = [super init])) {
        _owner = owner;
        _functionCount = functionCount;
        _buffers = [NSMutableArray arrayWithCapacity:functionCount];
        _functions = [NSMutableArray arrayWithCapacity:functionCount];
        _visibleTables = [NSMutableArray arrayWithCapacity:functionCount];
        _bufferOffsets = [NSMutableData dataWithLength:functionCount * sizeof(NSUInteger)];
        _opaqueSignatures = [NSMutableData dataWithLength:functionCount * sizeof(MTLIntersectionFunctionSignature)];
        for (NSUInteger index = 0; index < functionCount; ++index) {
            [_buffers addObject:[NSNull null]];
            [_functions addObject:[NSNull null]];
            [_visibleTables addObject:[NSNull null]];
        }
        _resourceID = zpu_register_resource(self);
    }
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (id<MTLDevice>)device { return (id<MTLDevice>)_owner; }
- (MTLCPUCacheMode)cpuCacheMode { return MTLCPUCacheModeDefaultCache; }
- (MTLStorageMode)storageMode { return MTLStorageModeShared; }
- (MTLHazardTrackingMode)hazardTrackingMode { return MTLHazardTrackingModeTracked; }
- (MTLResourceOptions)resourceOptions { return MTLResourceStorageModeShared; }
- (MTLPurgeableState)setPurgeableState:(MTLPurgeableState)state { return state; }
- (id<MTLHeap>)heap { return nil; }
- (NSUInteger)heapOffset { return 0; }
- (NSUInteger)allocatedSize {
    return _functionCount > SIZE_MAX / sizeof(uint64_t) ? SIZE_MAX : _functionCount * sizeof(uint64_t);
}
- (void)makeAliasable {}
- (BOOL)isAliasable { return NO; }
- (kern_return_t)setOwnerWithIdentity:(task_id_token_t)task_id_token {
    (void)task_id_token;
    return KERN_SUCCESS;
}
- (MTLResourceID)gpuResourceID API_AVAILABLE(macos(13.0), ios(16.0)) {
    return (MTLResourceID){_resourceID};
}
- (void)setBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index >= _functionCount || !zpu_function_table_buffer_belongs_to_device(_owner, buffer)) return;
    _buffers[index] = buffer == nil ? (id)[NSNull null] : (id)buffer;
    ((NSUInteger *)_bufferOffsets.mutableBytes)[index] = offset;
}
- (void)setBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers
           offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (buffers == NULL || offsets == NULL || !zpu_function_table_range_valid(_functionCount, range)) return;
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        if (!zpu_function_table_buffer_belongs_to_device(_owner, buffers[offset])) return;
    }
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        const NSUInteger index = range.location + offset;
        _buffers[index] = buffers[offset] == nil ? (id)[NSNull null] : (id)buffers[offset];
        ((NSUInteger *)_bufferOffsets.mutableBytes)[index] = offsets[offset];
    }
}
- (void)setFunction:(id<MTLFunctionHandle>)function atIndex:(NSUInteger)index {
    if (index >= _functionCount || !zpu_function_table_handle_belongs_to_device(_owner, function)) return;
    _functions[index] = function == nil ? (id)[NSNull null] : (id)function;
}
- (void)setFunctions:(const id<MTLFunctionHandle> __nullable [__nonnull])functions withRange:(NSRange)range {
    if (functions == NULL || !zpu_function_table_range_valid(_functionCount, range)) return;
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        if (!zpu_function_table_handle_belongs_to_device(_owner, functions[offset])) return;
    }
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        id<MTLFunctionHandle> function = functions[offset];
        _functions[range.location + offset] = function == nil ? (id)[NSNull null] : (id)function;
    }
}
- (void)setOpaqueTriangleIntersectionFunctionWithSignature:(MTLIntersectionFunctionSignature)signature
                                                   atIndex:(NSUInteger)index {
    if (index >= _functionCount) return;
    ((MTLIntersectionFunctionSignature *)_opaqueSignatures.mutableBytes)[index] = signature;
}
- (void)setOpaqueTriangleIntersectionFunctionWithSignature:(MTLIntersectionFunctionSignature)signature
                                                  withRange:(NSRange)range {
    if (!zpu_function_table_range_valid(_functionCount, range)) return;
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        ((MTLIntersectionFunctionSignature *)_opaqueSignatures.mutableBytes)[range.location + offset] = signature;
    }
}
- (void)setOpaqueCurveIntersectionFunctionWithSignature:(MTLIntersectionFunctionSignature)signature
                                                 atIndex:(NSUInteger)index {
    if (index >= _functionCount) return;
    ((MTLIntersectionFunctionSignature *)_opaqueSignatures.mutableBytes)[index] = signature;
}
- (void)setOpaqueCurveIntersectionFunctionWithSignature:(MTLIntersectionFunctionSignature)signature
                                                withRange:(NSRange)range {
    if (!zpu_function_table_range_valid(_functionCount, range)) return;
    for (NSUInteger offset = 0; offset < range.length; ++offset) {
        ((MTLIntersectionFunctionSignature *)_opaqueSignatures.mutableBytes)[range.location + offset] = signature;
    }
}
- (void)setVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex {
    if (bufferIndex >= _functionCount) return;
    if (functionTable == nil) {
        _visibleTables[bufferIndex] = [NSNull null];
        return;
    }
    ZPUVisibleFunctionTable *table = (ZPUVisibleFunctionTable *)functionTable;
    if (![table isKindOfClass:[ZPUVisibleFunctionTable class]] || table->_owner != _owner) return;
    _visibleTables[bufferIndex] = functionTable;
}
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables
                 withBufferRange:(NSRange)bufferRange {
    if (functionTables == NULL || !zpu_function_table_range_valid(_functionCount, bufferRange)) return;
    for (NSUInteger offset = 0; offset < bufferRange.length; ++offset) {
        id<MTLVisibleFunctionTable> functionTable = functionTables[offset];
        if (functionTable != nil) {
            ZPUVisibleFunctionTable *table = (ZPUVisibleFunctionTable *)functionTable;
            if (![table isKindOfClass:[ZPUVisibleFunctionTable class]] || table->_owner != _owner) return;
        }
    }
    for (NSUInteger offset = 0; offset < bufferRange.length; ++offset) {
        id<MTLVisibleFunctionTable> functionTable = functionTables[offset];
        _visibleTables[bufferRange.location + offset] = functionTable == nil ? (id)[NSNull null] : (id)functionTable;
    }
}
@end

@implementation ZPUComputeEncoder
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner encoder:(zpu_metal_compute_encoder *)encoder {
    if ((self = [super init])) {
        _owner = owner;
        _zpuEncoder = encoder;
        _dispatchType = MTLDispatchTypeSerial;
        _kernel = 0;
        _boundTexture = nil;
        _boundTextureIndex = 0;
    }
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
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
- (void)setComputePipelineState:(id<MTLComputePipelineState>)state {
    ZPUComputePipelineState *pipeline = (ZPUComputePipelineState *)state;
    if (![pipeline isKindOfClass:[ZPUComputePipelineState class]] ||
        pipeline->_owner != [_owner device] ||
        zpu_metal_compute_encoder_set_kernel(_zpuEncoder, pipeline->_kernel) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    _kernel = pipeline->_kernel;
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
    if (index > UINT32_MAX || (buffer != nil && !zpu_buffer_belongs_to_device([_owner device], zpuBuffer))) {
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
    if (index > UINT32_MAX || (texture != nil && !zpu_texture_belongs_to_device([_owner device], zpuTexture))) {
        [_owner markError];
        return;
    }
    if (zpu_metal_compute_encoder_set_texture(_zpuEncoder,
            texture == nil ? NULL : zpuTexture->_zpuTexture, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    _boundTexture = zpuTexture;
    _boundTextureIndex = index;
    if (zpuTexture != nil) [_owner retainResource:zpuTexture];
}
- (void)setTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setTexture:textures[index] atIndex:range.location + index];
    }
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    ZPUSamplerState *zpuSampler = (ZPUSamplerState *)sampler;
    if (sampler != nil && (![zpuSampler isKindOfClass:[ZPUSamplerState class]] || zpuSampler->_owner != [_owner device])) {
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
    (void)bufferIndex;
    if (visibleFunctionTable != nil) [_owner markError];
}
- (void)setVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])visibleFunctionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)visibleFunctionTables;
    if (range.length != 0) [_owner markError];
}
- (void)setIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)intersectionFunctionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)bufferIndex;
    if (intersectionFunctionTable != nil) [_owner markError];
}
- (void)setIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])intersectionFunctionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)intersectionFunctionTables;
    if (range.length != 0) [_owner markError];
}
- (void)setAccelerationStructure:(id<MTLAccelerationStructure>)accelerationStructure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(11.0), ios(14.0), tvos(16.0)) {
    (void)bufferIndex;
    if (accelerationStructure != nil) [_owner markError];
}
- (void)setThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index {
    (void)index;
    if (length != 0) [_owner markError];
}
- (void)setImageblockWidth:(NSUInteger)width height:(NSUInteger)height API_AVAILABLE(ios(11.0), macos(11.0), macCatalyst(14.0), tvos(14.5)) {
    if (width != 0 || height != 0) [_owner markError];
}
- (void)setStageInRegion:(MTLRegion)region API_AVAILABLE(macos(10.12), ios(10.0)) {
    if (!zpu_region_fits(region)) [_owner markError];
}
- (void)setStageInRegionWithIndirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)indirectBuffer;
    if (!zpu_buffer_belongs_to_device([_owner device], zpuBuffer) || indirectBufferOffset > zpuBuffer.length) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)useResource:(id<MTLResource>)resource usage:(MTLResourceUsage)usage API_AVAILABLE(macos(10.13), ios(11.0)) {
    (void)usage;
    ZPUBuffer *buffer = (ZPUBuffer *)resource;
    ZPUTexture *texture = (ZPUTexture *)resource;
    if (zpu_buffer_belongs_to_device([_owner device], buffer) || zpu_texture_belongs_to_device([_owner device], texture)) {
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
    ZPUHeap *zpuHeap = (ZPUHeap *)heap;
    if ([zpuHeap isKindOfClass:[ZPUHeap class]] && zpuHeap->_owner == [_owner device]) [_owner retainResource:heap];
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
    const BOOL arrayKernel = _kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
    const BOOL volumeKernel = _kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D;
    if (arrayKernel) {
        if (_boundTexture == nil || _boundTexture->_textureType != MTLTextureType2DArray) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < threadsPerGrid.depth && slice < _boundTexture.arrayLength; ++slice) {
            zpu_metal_texture *sliceTexture = [_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_zpuEncoder, sliceTexture, (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threads(_zpuEncoder,
                    (zpu_metal_size){(uint32_t)threadsPerGrid.width, (uint32_t)threadsPerGrid.height, 1},
                    (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width, (uint32_t)threadsPerThreadgroup.height,
                                     (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
        return;
    }
    if (volumeKernel) {
        if (_boundTexture == nil || _boundTexture->_textureType != MTLTextureType3D) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < threadsPerGrid.depth && slice < _boundTexture.depth; ++slice) {
            zpu_metal_texture *sliceTexture = [_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_zpuEncoder, sliceTexture, (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_set_array_slice(_zpuEncoder, (uint32_t)slice,
                    (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threads(_zpuEncoder,
                    (zpu_metal_size){(uint32_t)threadsPerGrid.width, (uint32_t)threadsPerGrid.height, (uint32_t)threadsPerGrid.depth},
                    (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width, (uint32_t)threadsPerThreadgroup.height,
                                     (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
        return;
    }
    if (_boundTexture != nil && (_boundTexture->_textureType == MTLTextureType2DArray ||
                                 _boundTexture->_textureType == MTLTextureType3D)) {
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
    if (_kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY &&
        _boundTexture != nil && _boundTexture->_textureType == MTLTextureType2DArray) {
        const uint64_t gridWidth = (uint64_t)threadgroupsPerGrid.width * threadsPerThreadgroup.width;
        const uint64_t gridHeight = (uint64_t)threadgroupsPerGrid.height * threadsPerThreadgroup.height;
        if (gridWidth > UINT32_MAX || gridHeight > UINT32_MAX) {
            [_owner markError];
            return;
        }
        [self dispatchThreads:MTLSizeMake((NSUInteger)gridWidth, (NSUInteger)gridHeight, threadgroupsPerGrid.depth)
             threadsPerThreadgroup:threadsPerThreadgroup];
        return;
    }
    if (_kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D &&
        _boundTexture != nil && _boundTexture->_textureType == MTLTextureType3D) {
        const uint64_t gridWidth = (uint64_t)threadgroupsPerGrid.width * threadsPerThreadgroup.width;
        const uint64_t gridHeight = (uint64_t)threadgroupsPerGrid.height * threadsPerThreadgroup.height;
        if (gridWidth > UINT32_MAX || gridHeight > UINT32_MAX) {
            [_owner markError];
            return;
        }
        [self dispatchThreads:MTLSizeMake((NSUInteger)gridWidth, (NSUInteger)gridHeight, threadgroupsPerGrid.depth)
             threadsPerThreadgroup:threadsPerThreadgroup];
        return;
    }
    if (_kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY || _kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D ||
        (_boundTexture != nil && (_boundTexture->_textureType == MTLTextureType2DArray ||
                                  _boundTexture->_textureType == MTLTextureType3D))) {
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
        zpuBuffer->_owner != [_owner device] ||
        !zpu_u32(indirectBufferOffset, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.width, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.height, &(uint32_t){0}) ||
        !zpu_u32(threadsPerThreadgroup.depth, &(uint32_t){0})) {
        [_owner markError];
        return;
    }
    const BOOL arrayKernel = _kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_ARRAY;
    const BOOL volumeKernel = _kernel == ZPU_METAL_COMPUTE_FILL_GRADIENT_RGBA8_3D;
    if (arrayKernel) {
        if (_boundTexture == nil || _boundTexture->_textureType != MTLTextureType2DArray) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < _boundTexture.arrayLength; ++slice) {
            zpu_metal_texture *sliceTexture = [_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_zpuEncoder, sliceTexture,
                    (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_set_array_slice(_zpuEncoder, (uint32_t)slice,
                    (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threadgroups_indirect(_zpuEncoder,
                    zpuBuffer->_zpuBuffer, indirectBufferOffset,
                    (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width,
                    (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    } else if (volumeKernel) {
        if (_boundTexture == nil || _boundTexture->_textureType != MTLTextureType3D) {
            [_owner markError];
            return;
        }
        for (NSUInteger slice = 0; slice < _boundTexture.depth; ++slice) {
            zpu_metal_texture *sliceTexture = [_boundTexture zpuTextureAtLevel:0 slice:slice];
            if (sliceTexture == NULL ||
                zpu_metal_compute_encoder_set_texture(_zpuEncoder, sliceTexture,
                    (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_set_array_slice(_zpuEncoder, (uint32_t)slice,
                    (uint32_t)_boundTextureIndex) != ZPU_METAL_OK ||
                zpu_metal_compute_encoder_dispatch_threadgroups_indirect(_zpuEncoder, zpuBuffer->_zpuBuffer,
                    indirectBufferOffset,
                    (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width,
                    (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    } else if (_boundTexture != nil && _boundTexture->_textureType == MTLTextureType2DArray) {
        [_owner markError];
        return;
    } else if (zpu_metal_compute_encoder_dispatch_threadgroups_indirect(_zpuEncoder, zpuBuffer->_zpuBuffer,
            indirectBufferOffset, (zpu_metal_size){(uint32_t)threadsPerThreadgroup.width,
            (uint32_t)threadsPerThreadgroup.height, (uint32_t)threadsPerThreadgroup.depth}) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
}
- (void)updateFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0)) {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device] ||
        zpu_metal_compute_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)waitForFence:(id<MTLFence>)fence API_AVAILABLE(macos(10.13), ios(10.0)) {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device] ||
        zpu_metal_compute_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuFence];
}
- (void)executeCommandsInBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)executionRange API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    ZPUIndirectCommandBuffer *buffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![buffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || buffer->_owner != [_owner device] ||
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
    if (argumentBuffer != nil && !zpu_buffer_belongs_to_device(_owner, buffer)) return;
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
    if (buffer != nil && !zpu_buffer_belongs_to_device(_owner, (ZPUBuffer *)buffer)) return;
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
    if (texture != nil && !zpu_texture_belongs_to_device(_owner, (ZPUTexture *)texture)) return;
    [self remember:texture atIndex:index];
}
- (void)setTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setTexture:textures[index] atIndex:range.location + index];
}
- (void)setSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    if (sampler != nil && ![(ZPUSamplerState *)sampler isKindOfClass:[ZPUSamplerState class]]) return;
    if (sampler != nil && ((ZPUSamplerState *)sampler)->_owner != _owner) return;
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
    if (pipeline != nil && (![(id)pipeline isKindOfClass:[ZPURenderPipelineState class]] || ((ZPURenderPipelineState *)pipeline)->_owner != _owner)) return;
    [self remember:pipeline atIndex:index];
}
- (void)setRenderPipelineStates:(const id<MTLRenderPipelineState> __nullable [__nonnull])pipelines withRange:(NSRange)range API_AVAILABLE(macos(10.14), macCatalyst(13.0), ios(13.0)) {
    if (pipelines == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setRenderPipelineState:pipelines[index] atIndex:range.location + index];
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipeline atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    if (pipeline != nil && (![(id)pipeline isKindOfClass:[ZPUComputePipelineState class]] || ((ZPUComputePipelineState *)pipeline)->_owner != _owner)) return;
    [self remember:pipeline atIndex:index];
}
- (void)setComputePipelineStates:(const id<MTLComputePipelineState> __nullable [__nonnull])pipelines withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(13.0)) {
    if (pipelines == NULL) return;
    for (NSUInteger index = 0; index < range.length; ++index) [self setComputePipelineState:pipelines[index] atIndex:range.location + index];
}
- (void)setIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer atIndex:(NSUInteger)index API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (indirectCommandBuffer != nil && (![(id)indirectCommandBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || ((ZPUIndirectCommandBuffer *)indirectCommandBuffer)->_owner != _owner)) return;
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
- (instancetype)initWithOwner:(ZPUCommandBuffer *)owner texture:(ZPUTexture *)texture renderTexture:(zpu_metal_texture *)renderTexture depthTexture:(zpu_metal_texture *)depthTexture stencilTexture:(zpu_metal_texture *)stencilTexture stencilLoadAction:(zpu_metal_load_action)stencilLoadAction stencilStoreAction:(zpu_metal_store_action)stencilStoreAction stencilClearValue:(uint8_t)stencilClearValue pass:(zpu_metal_render_pass_descriptor)pass descriptor:(MTLRenderPassDescriptor *)descriptor {
    if ((self = [super init])) {
        _owner = owner;
        _texture = texture;
        _renderTexture = renderTexture;
        _depthTexture = depthTexture;
        _stencilTexture = stencilTexture;
        _stencilLoadAction = stencilLoadAction;
        _stencilStoreAction = stencilStoreAction;
        _stencilClearValue = stencilClearValue;
        _pass = pass;
        _descriptor = [descriptor copy];
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
    zpu_metal_render_encoder *encoder = zpu_metal_command_buffer_render_encoder(commandBuffer, _renderTexture, &pass);
    if (encoder == NULL) return nil;
    if (!zpu_configure_additional_color_attachments(_owner, encoder, _descriptor)) {
        zpu_metal_render_encoder_destroy(encoder);
        return nil;
    }
    if (pass.depth.load_action != ZPU_METAL_LOAD_DONT_CARE) {
        if (_depthTexture == NULL || zpu_metal_render_encoder_set_depth_texture(encoder, _depthTexture) != ZPU_METAL_OK) {
            zpu_metal_render_encoder_destroy(encoder);
            return nil;
        }
    }
    if (_stencilTexture != NULL &&
        zpu_metal_render_encoder_set_stencil_texture(encoder, _stencilTexture, _stencilLoadAction,
            _stencilStoreAction, _stencilClearValue) != ZPU_METAL_OK) {
        zpu_metal_render_encoder_destroy(encoder);
        return nil;
    }
    if (!zpu_configure_visibility_result(_owner, encoder, _descriptor.visibilityResultBuffer,
                                         zpu_visibility_result_type(_descriptor))) {
        zpu_metal_render_encoder_destroy(encoder);
        return nil;
    }
    _childCount += 1;
    return (id<MTLRenderCommandEncoder>)[[ZPURenderEncoder alloc] initWithOwner:_owner encoder:encoder];
}
- (void)setColorStoreAction:(MTLStoreAction)storeAction atIndex:(NSUInteger)colorAttachmentIndex {
    if (!zpu_store_action_supported(storeAction) || colorAttachmentIndex >= ZPU_METAL_MAX_COLOR_ATTACHMENTS) {
        [_owner markError];
        return;
    }
    if (colorAttachmentIndex == 0) _pass.color.store_action = zpu_store_action(storeAction);
    else if (colorAttachmentIndex < ZPU_METAL_MAX_COLOR_ATTACHMENTS) _descriptor.colorAttachments[colorAttachmentIndex].storeAction = storeAction;
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction {
    if (!zpu_store_action_supported(storeAction)) [_owner markError];
    else _pass.depth.store_action = zpu_store_action(storeAction);
}
- (void)setStencilStoreAction:(MTLStoreAction)storeAction {
    if (!zpu_store_action_supported(storeAction)) [_owner markError];
    else _stencilStoreAction = zpu_store_action(storeAction);
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)colorAttachmentIndex {
    (void)colorAttachmentIndex;
    if (options != 0) [_owner markError];
}
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options {
    if (options != 0) [_owner markError];
}
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options {
    if (options != 0) [_owner markError];
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
    if (!zpu_buffer_belongs_to_device([_owner device], buffer)) { [_owner markError]; return; }
    [_owner retainResource:buffer];
    if (zpu_metal_blit_encoder_synchronize_resource(_zpuEncoder, buffer->_zpuBuffer) != ZPU_METAL_OK) [_owner markError];
}
- (void)synchronizeTexture:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.11), macCatalyst(13.0)) API_UNAVAILABLE(ios) {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (!zpu_texture_belongs_to_device([_owner device], zpuTexture) || [zpuTexture zpuTextureAtLevel:level slice:slice] == NULL) { [_owner markError]; return; }
    [_owner retainResource:zpuTexture];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset size:(NSUInteger)size {
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    if (!zpu_buffer_belongs_to_device([_owner device], source) || !zpu_buffer_belongs_to_device([_owner device], destination)) { [_owner markError]; return; }
    [_owner retainResource:source];
    [_owner retainResource:destination];
    if (zpu_metal_blit_encoder_copy_buffer(_zpuEncoder, source->_zpuBuffer, sourceOffset, destination->_zpuBuffer, destinationOffset, size) != ZPU_METAL_OK) [_owner markError];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    ZPUBuffer *source = (ZPUBuffer *)sourceBuffer;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    MTLRegion region = MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, destinationOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (!zpu_buffer_belongs_to_device([_owner device], source) || !zpu_texture_belongs_to_device([_owner device], destination) || !zpu_region_fits(region)) { [_owner markError]; return; }
    if (zpu_texture_type_is_3d(destination->_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(destination, destinationLevel);
        if (destinationSlice != 0 || levelDepth == 0 || destinationOrigin.z > levelDepth ||
            sourceSize.depth > levelDepth - destinationOrigin.z) { [_owner markError]; return; }
        const NSUInteger rowBytes = sourceSize.width * 4;
        const NSUInteger rowStride = sourceBytesPerRow == 0 ? rowBytes : sourceBytesPerRow;
        if (rowStride < rowBytes || (sourceSize.height != 0 && rowStride > SIZE_MAX / sourceSize.height)) { [_owner markError]; return; }
        const NSUInteger imageStride = sourceBytesPerImage == 0 ? rowStride * sourceSize.height : sourceBytesPerImage;
        if (sourceSize.depth > 1 && imageStride > SIZE_MAX / (sourceSize.depth - 1)) { [_owner markError]; return; }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *destinationTextureAtLevel =
                [destination zpuTextureAtLevel:destinationLevel slice:destinationOrigin.z + plane];
            if (destinationTextureAtLevel == NULL || sourceOffset > SIZE_MAX - plane * imageStride ||
                zpu_metal_blit_encoder_copy_buffer_to_texture(_zpuEncoder, source->_zpuBuffer,
                    sourceOffset + plane * imageStride, sourceBytesPerRow, destinationTextureAtLevel,
                    zpu_region(MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, 0,
                                                sourceSize.width, sourceSize.height, 1))) != ZPU_METAL_OK) { [_owner markError]; return; }
        }
        [_owner retainResource:source];
        [_owner retainResource:destination];
        return;
    }
    (void)sourceBytesPerImage;
    if (sourceSize.depth != 1) { [_owner markError]; return; }
    zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel slice:destinationSlice];
    if (destinationTextureAtLevel == NULL) { [_owner markError]; return; }
    [_owner retainResource:source];
    [_owner retainResource:destination];
    if (zpu_metal_blit_encoder_copy_buffer_to_texture(_zpuEncoder, source->_zpuBuffer, sourceOffset, sourceBytesPerRow, destinationTextureAtLevel, zpu_region(region)) != ZPU_METAL_OK) [_owner markError];
}
- (void)copyFromBuffer:(id<MTLBuffer>)sourceBuffer sourceOffset:(NSUInteger)sourceOffset sourceBytesPerRow:(NSUInteger)sourceBytesPerRow sourceBytesPerImage:(NSUInteger)sourceBytesPerImage sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin options:(MTLBlitOption)options API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    [self copyFromBuffer:sourceBuffer sourceOffset:sourceOffset sourceBytesPerRow:sourceBytesPerRow sourceBytesPerImage:sourceBytesPerImage sourceSize:sourceSize toTexture:destinationTexture destinationSlice:destinationSlice destinationLevel:destinationLevel destinationOrigin:destinationOrigin];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUBuffer *destination = (ZPUBuffer *)destinationBuffer;
    MTLRegion region = MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (!zpu_texture_belongs_to_device([_owner device], source) || !zpu_buffer_belongs_to_device([_owner device], destination) || !zpu_region_fits(region)) { [_owner markError]; return; }
    if (zpu_texture_type_is_3d(source->_textureType)) {
        const NSUInteger levelDepth = zpu_texture_depth_at_level(source, sourceLevel);
        if (sourceSlice != 0 || levelDepth == 0 || sourceOrigin.z > levelDepth ||
            sourceSize.depth > levelDepth - sourceOrigin.z) { [_owner markError]; return; }
        const NSUInteger rowBytes = sourceSize.width * 4;
        const NSUInteger rowStride = destinationBytesPerRow == 0 ? rowBytes : destinationBytesPerRow;
        if (rowStride < rowBytes || (sourceSize.height != 0 && rowStride > SIZE_MAX / sourceSize.height)) { [_owner markError]; return; }
        const NSUInteger imageStride = destinationBytesPerImage == 0 ? rowStride * sourceSize.height : destinationBytesPerImage;
        if (sourceSize.depth > 1 && imageStride > SIZE_MAX / (sourceSize.depth - 1)) { [_owner markError]; return; }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *sourceTextureAtLevel =
                [source zpuTextureAtLevel:sourceLevel slice:sourceOrigin.z + plane];
            if (sourceTextureAtLevel == NULL || destinationOffset > SIZE_MAX - plane * imageStride ||
                zpu_metal_blit_encoder_copy_texture_to_buffer(_zpuEncoder, sourceTextureAtLevel,
                    zpu_region(MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, 0,
                                                sourceSize.width, sourceSize.height, 1)),
                    destination->_zpuBuffer, destinationOffset + plane * imageStride, destinationBytesPerRow) != ZPU_METAL_OK) { [_owner markError]; return; }
        }
        [_owner retainResource:source];
        [_owner retainResource:destination];
        return;
    }
    (void)destinationBytesPerImage;
    if (sourceSize.depth != 1) { [_owner markError]; return; }
    zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceSlice];
    if (sourceTextureAtLevel == NULL) { [_owner markError]; return; }
    [_owner retainResource:source];
    [_owner retainResource:destination];
    if (zpu_metal_blit_encoder_copy_texture_to_buffer(_zpuEncoder, sourceTextureAtLevel, zpu_region(region), destination->_zpuBuffer, destinationOffset, destinationBytesPerRow) != ZPU_METAL_OK) [_owner markError];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toBuffer:(id<MTLBuffer>)destinationBuffer destinationOffset:(NSUInteger)destinationOffset destinationBytesPerRow:(NSUInteger)destinationBytesPerRow destinationBytesPerImage:(NSUInteger)destinationBytesPerImage options:(MTLBlitOption)options API_AVAILABLE(macos(10.11), ios(9.0)) {
    (void)options;
    [self copyFromTexture:sourceTexture sourceSlice:sourceSlice sourceLevel:sourceLevel sourceOrigin:sourceOrigin sourceSize:sourceSize toBuffer:destinationBuffer destinationOffset:destinationOffset destinationBytesPerRow:destinationBytesPerRow destinationBytesPerImage:destinationBytesPerImage];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel sourceOrigin:(MTLOrigin)sourceOrigin sourceSize:(MTLSize)sourceSize toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel destinationOrigin:(MTLOrigin)destinationOrigin {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (!zpu_texture_belongs_to_device([_owner device], source) || !zpu_texture_belongs_to_device([_owner device], destination)) { [_owner markError]; return; }
    if (zpu_texture_type_is_3d(source->_textureType) || zpu_texture_type_is_3d(destination->_textureType)) {
        if (!zpu_texture_type_is_3d(source->_textureType) || !zpu_texture_type_is_3d(destination->_textureType) ||
            sourceSlice != 0 || destinationSlice != 0 ||
            sourceOrigin.z > zpu_texture_depth_at_level(source, sourceLevel) ||
            destinationOrigin.z > zpu_texture_depth_at_level(destination, destinationLevel) ||
            sourceSize.depth > zpu_texture_depth_at_level(source, sourceLevel) - sourceOrigin.z ||
            sourceSize.depth > zpu_texture_depth_at_level(destination, destinationLevel) - destinationOrigin.z ||
            !zpu_region_fits(MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, sourceOrigin.z,
                                              sourceSize.width, sourceSize.height, sourceSize.depth)) ||
            !zpu_region_fits(MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, destinationOrigin.z,
                                              sourceSize.width, sourceSize.height, sourceSize.depth))) { [_owner markError]; return; }
        for (NSUInteger plane = 0; plane < sourceSize.depth; ++plane) {
            zpu_metal_texture *sourceTextureAtLevel =
                [source zpuTextureAtLevel:sourceLevel slice:sourceOrigin.z + plane];
            zpu_metal_texture *destinationTextureAtLevel =
                [destination zpuTextureAtLevel:destinationLevel slice:destinationOrigin.z + plane];
            if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
                zpu_metal_blit_encoder_copy_texture_to_texture(_zpuEncoder, sourceTextureAtLevel,
                    zpu_region(MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, 0,
                                                sourceSize.width, sourceSize.height, 1)),
                    destinationTextureAtLevel, zpu_region(MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, 0,
                                                                          sourceSize.width, sourceSize.height, 1))) != ZPU_METAL_OK) { [_owner markError]; return; }
        }
        [_owner retainResource:source];
        [_owner retainResource:destination];
        return;
    }
    if (sourceSize.depth != 1) { [_owner markError]; return; }
    zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel slice:sourceSlice];
    zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel slice:destinationSlice];
    if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL) { [_owner markError]; return; }
    [_owner retainResource:source];
    [_owner retainResource:destination];
    MTLRegion sourceRegion = MTLRegionMake3D(sourceOrigin.x, sourceOrigin.y, sourceOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    MTLRegion destinationRegion = MTLRegionMake3D(destinationOrigin.x, destinationOrigin.y, destinationOrigin.z, sourceSize.width, sourceSize.height, sourceSize.depth);
    if (!zpu_region_fits(sourceRegion) || !zpu_region_fits(destinationRegion)) { [_owner markError]; return; }
    if (zpu_metal_blit_encoder_copy_texture_to_texture(_zpuEncoder, sourceTextureAtLevel, zpu_region(sourceRegion), destinationTextureAtLevel, zpu_region(destinationRegion)) != ZPU_METAL_OK) [_owner markError];
}
- (void)copyFromTexture:(id<MTLTexture>)sourceTexture sourceSlice:(NSUInteger)sourceSlice sourceLevel:(NSUInteger)sourceLevel toTexture:(id<MTLTexture>)destinationTexture destinationSlice:(NSUInteger)destinationSlice destinationLevel:(NSUInteger)destinationLevel sliceCount:(NSUInteger)sliceCount levelCount:(NSUInteger)levelCount API_AVAILABLE(macos(10.15), ios(13.0)) {
    ZPUTexture *source = (ZPUTexture *)sourceTexture;
    ZPUTexture *destination = (ZPUTexture *)destinationTexture;
    if (![source isKindOfClass:[ZPUTexture class]] || ![destination isKindOfClass:[ZPUTexture class]] ||
        sliceCount == 0 || levelCount == 0 ||
        sourceSlice > source.arrayLength || sliceCount > source.arrayLength - sourceSlice ||
        destinationSlice > destination.arrayLength || sliceCount > destination.arrayLength - destinationSlice ||
        sourceLevel > source.mipmapLevelCount || levelCount > source.mipmapLevelCount - sourceLevel ||
        destinationLevel > destination.mipmapLevelCount || levelCount > destination.mipmapLevelCount - destinationLevel) {
        [_owner markError];
        return;
    }
    if (zpu_texture_type_is_3d(source->_textureType) || zpu_texture_type_is_3d(destination->_textureType)) {
        if (!zpu_texture_type_is_3d(source->_textureType) || !zpu_texture_type_is_3d(destination->_textureType) ||
            sourceSlice != 0 || destinationSlice != 0 || sliceCount != 1) {
            [_owner markError];
            return;
        }
        for (NSUInteger level = 0; level < levelCount; ++level) {
            const NSUInteger sourceDepth = zpu_texture_depth_at_level(source, sourceLevel + level);
            const NSUInteger destinationDepth = zpu_texture_depth_at_level(destination, destinationLevel + level);
            if (sourceDepth != destinationDepth) { [_owner markError]; return; }
            for (NSUInteger plane = 0; plane < sourceDepth; ++plane) {
                zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel + level slice:plane];
                zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel + level slice:plane];
                if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
                    zpu_metal_texture_width(sourceTextureAtLevel) != zpu_metal_texture_width(destinationTextureAtLevel) ||
                    zpu_metal_texture_height(sourceTextureAtLevel) != zpu_metal_texture_height(destinationTextureAtLevel) ||
                    zpu_metal_blit_encoder_copy_texture_to_texture(_zpuEncoder, sourceTextureAtLevel,
                        (zpu_metal_region){.origin = {0, 0, 0}, .size = {zpu_metal_texture_width(sourceTextureAtLevel), zpu_metal_texture_height(sourceTextureAtLevel), 1}},
                        destinationTextureAtLevel,
                        (zpu_metal_region){.origin = {0, 0, 0}, .size = {zpu_metal_texture_width(destinationTextureAtLevel), zpu_metal_texture_height(destinationTextureAtLevel), 1}}) != ZPU_METAL_OK) {
                    [_owner markError];
                    return;
                }
            }
        }
        [_owner retainResource:source];
        [_owner retainResource:destination];
        return;
    }
    for (NSUInteger slice = 0; slice < sliceCount; ++slice) {
        for (NSUInteger level = 0; level < levelCount; ++level) {
            zpu_metal_texture *sourceTextureAtLevel = [source zpuTextureAtLevel:sourceLevel + level slice:sourceSlice + slice];
            zpu_metal_texture *destinationTextureAtLevel = [destination zpuTextureAtLevel:destinationLevel + level slice:destinationSlice + slice];
            if (sourceTextureAtLevel == NULL || destinationTextureAtLevel == NULL ||
                zpu_metal_texture_width(sourceTextureAtLevel) != zpu_metal_texture_width(destinationTextureAtLevel) ||
                zpu_metal_texture_height(sourceTextureAtLevel) != zpu_metal_texture_height(destinationTextureAtLevel)) {
                [_owner markError];
                return;
            }
            MTLRegion sourceRegion = MTLRegionMake3D(0, 0, 0, zpu_metal_texture_width(sourceTextureAtLevel), zpu_metal_texture_height(sourceTextureAtLevel), 1);
            MTLRegion destinationRegion = MTLRegionMake3D(0, 0, 0, zpu_metal_texture_width(destinationTextureAtLevel), zpu_metal_texture_height(destinationTextureAtLevel), 1);
            if (!zpu_region_fits(sourceRegion) || !zpu_region_fits(destinationRegion) ||
                zpu_metal_blit_encoder_copy_texture_to_texture(_zpuEncoder, sourceTextureAtLevel, zpu_region(sourceRegion),
                    destinationTextureAtLevel, zpu_region(destinationRegion)) != ZPU_METAL_OK) {
                [_owner markError];
                return;
            }
        }
    }
    [_owner retainResource:source];
    [_owner retainResource:destination];
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
    if (!zpu_buffer_belongs_to_device([_owner device], zpuBuffer) || range.location > SIZE_MAX - range.length) { [_owner markError]; return; }
    [_owner retainResource:zpuBuffer];
    if (zpu_metal_blit_encoder_fill_buffer(_zpuEncoder, zpuBuffer->_zpuBuffer, range.location, range.length, value) != ZPU_METAL_OK) [_owner markError];
}
- (void)updateFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device]) { [_owner markError]; return; }
    [_owner retainResource:zpuFence];
    if (zpu_metal_blit_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) [_owner markError];
}
- (void)waitForFence:(id<MTLFence>)fence {
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device]) { [_owner markError]; return; }
    [_owner retainResource:zpuFence];
    if (zpu_metal_blit_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence) != ZPU_METAL_OK) [_owner markError];
}
- (void)generateMipmapsForTexture:(id<MTLTexture>)texture {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (!zpu_texture_belongs_to_device([_owner device], zpuTexture) ||
        !zpu_render_pipeline_format_supported(zpuTexture->_pixelFormat) ||
        zpuTexture.mipmapLevelCount < 2) { [_owner markError]; return; }
    if (zpu_texture_type_is_3d(zpuTexture->_textureType)) {
        for (NSUInteger level = 0; level + 1 < zpuTexture.mipmapLevelCount; ++level) {
            const NSUInteger sourceDepth = zpu_texture_depth_at_level(zpuTexture, level);
            const NSUInteger destinationDepth = zpu_texture_depth_at_level(zpuTexture, level + 1);
            if (sourceDepth == 0 || destinationDepth != (sourceDepth > 1 ? sourceDepth / 2 : 1)) { [_owner markError]; return; }
            const NSUInteger zDenominator = destinationDepth * 2;
            for (NSUInteger plane = 0; plane < destinationDepth; ++plane) {
                const NSUInteger zPositionNumerator = (plane * 2 + 1) * sourceDepth - destinationDepth;
                const NSUInteger sourcePlane = zPositionNumerator / zDenominator;
                const NSUInteger zRemainder = zPositionNumerator % zDenominator;
                const BOOL hasSource1 = zRemainder != 0 && sourcePlane + 1 < sourceDepth;
                zpu_metal_texture *sourceTexture0 = [zpuTexture zpuTextureAtLevel:level slice:sourcePlane];
                zpu_metal_texture *sourceTexture1 = hasSource1 ?
                    [zpuTexture zpuTextureAtLevel:level slice:sourcePlane + 1] : NULL;
                zpu_metal_texture *destinationTexture = [zpuTexture zpuTextureAtLevel:level + 1 slice:plane];
                if (sourceTexture0 == NULL || (hasSource1 && sourceTexture1 == NULL) || destinationTexture == NULL ||
                    zpu_metal_blit_encoder_generate_mipmap_3d_weighted(_zpuEncoder, sourceTexture0,
                        sourceTexture1, destinationTexture, hasSource1 ? (uint32_t)zRemainder : 0,
                        hasSource1 ? (uint32_t)zDenominator : 1) != ZPU_METAL_OK) { [_owner markError]; return; }
            }
        }
        [_owner retainResource:zpuTexture];
        return;
    }
    for (NSUInteger slice = 0; slice < zpuTexture.arrayLength; ++slice) {
        for (NSUInteger level = 0; level + 1 < zpuTexture.mipmapLevelCount; ++level) {
            if (zpu_metal_blit_encoder_generate_mipmap(
                    _zpuEncoder, [zpuTexture zpuTextureAtLevel:level slice:slice],
                    [zpuTexture zpuTextureAtLevel:level + 1 slice:slice]) != ZPU_METAL_OK) { [_owner markError]; return; }
        }
    }
    [_owner retainResource:zpuTexture];
}
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture { if (!zpu_texture_belongs_to_device([_owner device], (ZPUTexture *)texture)) [_owner markError]; else [_owner retainResource:texture]; }
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture { if (!zpu_texture_belongs_to_device([_owner device], (ZPUTexture *)texture)) [_owner markError]; else [_owner retainResource:texture]; }
- (void)optimizeContentsForGPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (!zpu_texture_belongs_to_device([_owner device], (ZPUTexture *)texture) || slice != 0 || level != 0) [_owner markError];
    else [_owner retainResource:texture];
}
- (void)optimizeContentsForCPUAccess:(id<MTLTexture>)texture slice:(NSUInteger)slice level:(NSUInteger)level API_AVAILABLE(macos(10.14), ios(12.0)) {
    if (!zpu_texture_belongs_to_device([_owner device], (ZPUTexture *)texture) || slice != 0 || level != 0) [_owner markError];
    else [_owner retainResource:texture];
}
- (void)resetCommandsInBuffer:(id<MTLIndirectCommandBuffer>)buffer withRange:(NSRange)range API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)buffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || zpuBuffer->_owner != [_owner device]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:zpuBuffer];
    [zpuBuffer resetWithRange:range];
}
- (void)copyIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)source sourceRange:(NSRange)sourceRange destination:(id<MTLIndirectCommandBuffer>)destination destinationIndex:(NSUInteger)destinationIndex API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *sourceBuffer = (ZPUIndirectCommandBuffer *)source;
    ZPUIndirectCommandBuffer *destinationBuffer = (ZPUIndirectCommandBuffer *)destination;
    if (![sourceBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || sourceBuffer->_owner != [_owner device] ||
        ![destinationBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || destinationBuffer->_owner != [_owner device] ||
        ![destinationBuffer copyCommandsFrom:sourceBuffer sourceRange:sourceRange destinationIndex:destinationIndex]) {
        [_owner markError];
        return;
    }
    [_owner retainResource:sourceBuffer];
    [_owner retainResource:destinationBuffer];
}
- (void)optimizeIndirectCommandBuffer:(id<MTLIndirectCommandBuffer>)indirectCommandBuffer withRange:(NSRange)range API_AVAILABLE(macos(10.14), ios(12.0)) {
    ZPUIndirectCommandBuffer *zpuBuffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![zpuBuffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || zpuBuffer->_owner != [_owner device] ||
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
    ZPUTensor *source = (ZPUTensor *)sourceTensor;
    ZPUTensor *destination = (ZPUTensor *)destinationTensor;
    if (![source isKindOfClass:[ZPUTensor class]] || ![destination isKindOfClass:[ZPUTensor class]] ||
        source->_owner != [_owner device] || destination->_owner != [_owner device] ||
        !zpu_tensor_encode_copy_slice(source, sourceOrigin, sourceDimensions, destination, destinationOrigin,
                                       destinationDimensions, _zpuEncoder, NO)) {
        [_owner markError];
        return;
    }
    [_owner retainResource:source];
    [_owner retainResource:destination];
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
    if ((buffer != nil && !zpu_buffer_belongs_to_device([_owner device], zpuBuffer)) || index > UINT32_MAX) {
        [_owner markError];
        return;
    }
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
    if (texture != nil && !zpu_texture_belongs_to_device([_owner device], zpuTexture)) { [_owner markError]; return; }
    if (texture != nil) { [_owner markError]; return; }
    (void)index;
}
- (void)setVertexTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setVertexTexture:textures[index] atIndex:range.location + index];
}
- (void)setVertexSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    ZPUSamplerState *zpuSampler = (ZPUSamplerState *)sampler;
    if (sampler != nil && (![zpuSampler isKindOfClass:[ZPUSamplerState class]] || zpuSampler->_owner != [_owner device])) { [_owner markError]; return; }
    if (sampler != nil) { [_owner markError]; return; }
    (void)index;
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
    if (zpu_metal_render_encoder_set_fragment_bytes(_zpuEncoder, bytes, length, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    if (length != 0) [_owner retainResource:[NSData dataWithBytes:bytes length:length]];
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (buffer != nil && (!zpu_buffer_belongs_to_device([_owner device], zpuBuffer) || offset > zpuBuffer.length)) { [_owner markError]; return; }
    if (index > UINT32_MAX || zpu_metal_render_encoder_set_fragment_buffer(
            _zpuEncoder, zpuBuffer == nil ? NULL : zpuBuffer->_zpuBuffer, offset, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    if (zpuBuffer != nil) [_owner retainResource:zpuBuffer];
}
- (void)setFragmentBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index {
    if (index > UINT32_MAX || zpu_metal_render_encoder_set_fragment_buffer_offset(_zpuEncoder, offset, (uint32_t)index) != ZPU_METAL_OK) [_owner markError];
}
- (void)setFragmentBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range {
    if (buffers == NULL || offsets == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setFragmentBuffer:buffers[index] offset:offsets[index] atIndex:range.location + index];
}
- (void)setFragmentTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index {
    ZPUTexture *zpuTexture = (ZPUTexture *)texture;
    if (index > UINT32_MAX || (texture != nil && !zpu_texture_belongs_to_device([_owner device], zpuTexture))) { [_owner markError]; return; }
    if (zpu_metal_render_encoder_set_fragment_texture(
            _zpuEncoder, texture == nil ? NULL : zpuTexture->_zpuTexture, (uint32_t)index) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    _fragmentTexture = zpuTexture;
    if (zpuTexture != nil) [_owner retainResource:zpuTexture];
    const MTLTextureSwizzleChannels swizzle = zpuTexture == nil ? MTLTextureSwizzleChannelsDefault : zpuTexture.swizzle;
    if (zpu_metal_render_encoder_set_fragment_texture_swizzle(
            _zpuEncoder, (zpu_metal_texture_swizzle)swizzle.red,
            (zpu_metal_texture_swizzle)swizzle.green,
            (zpu_metal_texture_swizzle)swizzle.blue,
            (zpu_metal_texture_swizzle)swizzle.alpha) != ZPU_METAL_OK) [_owner markError];
}
- (void)setFragmentTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range {
    if (textures == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setFragmentTexture:textures[index] atIndex:range.location + index];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index {
    ZPUSamplerState *zpuSampler = (ZPUSamplerState *)sampler;
    if (index > UINT32_MAX || (sampler != nil && (![zpuSampler isKindOfClass:[ZPUSamplerState class]] || zpuSampler->_owner != [_owner device]))) {
        [_owner markError];
        return;
    }
    const zpu_metal_sampler_filter filter = sampler == nil ? ZPU_METAL_SAMPLER_NEAREST :
        (zpu_metal_sampler_filter)zpuSampler->_magFilter;
    const zpu_metal_sampler_address_mode address_s = sampler == nil ? ZPU_METAL_SAMPLER_CLAMP_TO_EDGE :
        (zpu_metal_sampler_address_mode)zpuSampler->_sAddressMode;
    const zpu_metal_sampler_address_mode address_t = sampler == nil ? ZPU_METAL_SAMPLER_CLAMP_TO_EDGE :
        (zpu_metal_sampler_address_mode)zpuSampler->_tAddressMode;
    if (zpu_metal_render_encoder_set_fragment_sampler(_zpuEncoder, filter, address_s, address_t) != ZPU_METAL_OK) {
        [_owner markError];
        return;
    }
    if (sampler != nil) [_owner retainResource:sampler];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range {
    if (samplers == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) [self setFragmentSamplerState:samplers[index] atIndex:range.location + index];
}
- (void)setFragmentSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index {
    (void)lodMinClamp;
    (void)lodMaxClamp;
    [self setFragmentSamplerState:sampler atIndex:index];
}
- (void)setFragmentSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range {
    if (samplers == NULL || lodMinClamps == NULL || lodMaxClamps == NULL) { [_owner markError]; return; }
    for (NSUInteger index = 0; index < range.length; ++index) {
        [self setFragmentSamplerState:samplers[index] atIndex:range.location + index];
    }
}
- (void)setObjectBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)bytes;
    (void)length;
    (void)index;
    [_owner markError];
}
- (void)setObjectBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)buffer;
    (void)offset;
    (void)index;
    [_owner markError];
}
- (void)setObjectBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)offset; (void)index; [_owner markError]; }
- (void)setObjectBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)buffers;
    (void)offsets;
    (void)range;
    [_owner markError];
}
- (void)setObjectTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)texture; (void)index; [_owner markError]; }
- (void)setObjectTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { (void)textures; (void)range; [_owner markError]; }
- (void)setObjectSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)sampler; (void)index; [_owner markError]; }
- (void)setObjectSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { (void)samplers; (void)range; [_owner markError]; }
- (void)setObjectSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)sampler;
    (void)lodMinClamp;
    (void)lodMaxClamp;
    (void)index;
    [_owner markError];
}
- (void)setObjectSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                    lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)samplers;
    (void)lodMinClamps;
    (void)lodMaxClamps;
    (void)range;
    [_owner markError];
}
- (void)setObjectThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)length; (void)index; [_owner markError]; }
- (void)setMeshBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)bytes; (void)length; (void)index; [_owner markError]; }
- (void)setMeshBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)buffer; (void)offset; (void)index; [_owner markError]; }
- (void)setMeshBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)offset; (void)index; [_owner markError]; }
- (void)setMeshBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { (void)buffers; (void)offsets; (void)range; [_owner markError]; }
- (void)setMeshTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)texture; (void)index; [_owner markError]; }
- (void)setMeshTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { (void)textures; (void)range; [_owner markError]; }
- (void)setMeshSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) { (void)sampler; (void)index; [_owner markError]; }
- (void)setMeshSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) { (void)samplers; (void)range; [_owner markError]; }
- (void)setMeshSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)sampler;
    (void)lodMinClamp;
    (void)lodMaxClamp;
    (void)index;
    [_owner markError];
}
- (void)setMeshSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                    lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(macos(13.0), ios(16.0)) {
    (void)samplers;
    (void)lodMinClamps;
    (void)lodMaxClamps;
    (void)range;
    [_owner markError];
}
- (void)setTileBytes:(const void *)bytes length:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)bytes; (void)length; (void)index; [_owner markError]; }
- (void)setTileBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)buffer; (void)offset; (void)index; [_owner markError]; }
- (void)setTileBufferOffset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)offset; (void)index; [_owner markError]; }
- (void)setTileBuffers:(const id<MTLBuffer> __nullable [__nonnull])buffers offsets:(const NSUInteger [__nonnull])offsets withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)buffers; (void)offsets; (void)range; [_owner markError]; }
- (void)setTileTexture:(id<MTLTexture>)texture atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)texture; (void)index; [_owner markError]; }
- (void)setTileTextures:(const id<MTLTexture> __nullable [__nonnull])textures withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)textures; (void)range; [_owner markError]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)sampler atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)sampler; (void)index; [_owner markError]; }
- (void)setTileSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers withRange:(NSRange)range API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { (void)samplers; (void)range; [_owner markError]; }
- (void)setTileSamplerState:(id<MTLSamplerState>)sampler lodMinClamp:(float)lodMinClamp lodMaxClamp:(float)lodMaxClamp atIndex:(NSUInteger)index API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) {
    (void)sampler;
    (void)lodMinClamp;
    (void)lodMaxClamp;
    (void)index;
    [_owner markError];
}
- (void)setTileSamplerStates:(const id<MTLSamplerState> __nullable [__nonnull])samplers
                lodMinClamps:(const float [__nonnull])lodMinClamps
                    lodMaxClamps:(const float [__nonnull])lodMaxClamps
                    withRange:(NSRange)range API_AVAILABLE(ios(11.0), tvos(14.5), macos(11.0), macCatalyst(14.0)) {
    (void)samplers;
    (void)lodMinClamps;
    (void)lodMaxClamps;
    (void)range;
    [_owner markError];
}
- (void)setVertexVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (functionTable != nil) [_owner markError]; }
- (void)setVertexVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; if (range.length != 0) [_owner markError]; }
- (void)setFragmentVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (functionTable != nil) [_owner markError]; }
- (void)setFragmentVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; if (range.length != 0) [_owner markError]; }
- (void)setTileVisibleFunctionTable:(id<MTLVisibleFunctionTable>)functionTable atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (functionTable != nil) [_owner markError]; }
- (void)setTileVisibleFunctionTables:(const id<MTLVisibleFunctionTable> __nullable [__nonnull])functionTables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)functionTables; if (range.length != 0) [_owner markError]; }
- (void)setVertexIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (table != nil) [_owner markError]; }
- (void)setVertexIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; if (range.length != 0) [_owner markError]; }
- (void)setFragmentIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (table != nil) [_owner markError]; }
- (void)setFragmentIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; if (range.length != 0) [_owner markError]; }
- (void)setTileIntersectionFunctionTable:(id<MTLIntersectionFunctionTable>)table atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (table != nil) [_owner markError]; }
- (void)setTileIntersectionFunctionTables:(const id<MTLIntersectionFunctionTable> __nullable [__nonnull])tables withBufferRange:(NSRange)range API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)tables; if (range.length != 0) [_owner markError]; }
- (void)setVertexAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (structure != nil) [_owner markError]; }
- (void)setFragmentAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (structure != nil) [_owner markError]; }
- (void)setTileAccelerationStructure:(id<MTLAccelerationStructure>)structure atBufferIndex:(NSUInteger)bufferIndex API_AVAILABLE(macos(12.0), ios(15.0), tvos(16.0)) { (void)bufferIndex; if (structure != nil) [_owner markError]; }
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
    if (zpu_metal_render_encoder_set_viewport(_zpuEncoder, (zpu_metal_viewport){
        (float)viewport.originX, (float)viewport.originY, (float)viewport.width,
        (float)viewport.height, (float)viewport.znear, (float)viewport.zfar,
    }) != ZPU_METAL_OK) [_owner markError];
}
- (void)setViewports:(const MTLViewport [__nonnull])viewports count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(12.0), tvos(14.5)) {
    if (viewports == NULL || count != 1) { [_owner markError]; return; }
    [self setViewport:viewports[0]];
}
- (void)setVertexAmplificationCount:(NSUInteger)count viewMappings:(const MTLVertexAmplificationViewMapping * __nullable)viewMappings API_AVAILABLE(macos(10.15.4), ios(13.0), macCatalyst(13.4), tvos(16.0)) {
    if (count != 1 || (viewMappings != NULL &&
        (viewMappings[0].viewportArrayIndexOffset != 0 || viewMappings[0].renderTargetArrayIndexOffset != 0))) {
        [_owner markError];
    }
}
- (void)setScissorRect:(MTLScissorRect)scissorRect {
    uint32_t x, y, width, height;
    if (!zpu_u32(scissorRect.x, &x) || !zpu_u32(scissorRect.y, &y) || !zpu_u32(scissorRect.width, &width) || !zpu_u32(scissorRect.height, &height)) {
        [_owner markError];
        return;
    }
    if (zpu_metal_render_encoder_set_scissor_rect(_zpuEncoder, (zpu_metal_scissor_rect){x, y, width, height}) != ZPU_METAL_OK) [_owner markError];
}
- (void)setScissorRects:(const MTLScissorRect [__nonnull])scissorRects count:(NSUInteger)count API_AVAILABLE(macos(10.13), ios(12.0), tvos(14.5)) {
    if (scissorRects == NULL || count != 1) { [_owner markError]; return; }
    [self setScissorRect:scissorRects[0]];
}
- (void)setCullMode:(MTLCullMode)cullMode {
    if (zpu_metal_render_encoder_set_cull_mode(_zpuEncoder, (zpu_metal_cull_mode)cullMode) != ZPU_METAL_OK) [_owner markError];
}
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode API_AVAILABLE(macos(10.11), ios(11.0)) {
    if (zpu_metal_render_encoder_set_depth_clip_mode(_zpuEncoder, (zpu_metal_depth_clip_mode)depthClipMode) != ZPU_METAL_OK) [_owner markError];
}
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp {
    if (zpu_metal_render_encoder_set_depth_bias(_zpuEncoder, depthBias, slopeScale, clamp) != ZPU_METAL_OK) [_owner markError];
}
- (void)setDepthTestMinBound:(float)minBound maxBound:(float)maxBound API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (zpu_metal_render_encoder_set_depth_test_bounds(_zpuEncoder, minBound, maxBound) != ZPU_METAL_OK) [_owner markError];
}
- (void)setFrontFacingWinding:(MTLWinding)frontFacingWinding {
    if (zpu_metal_render_encoder_set_front_facing(_zpuEncoder, (zpu_metal_winding)frontFacingWinding) != ZPU_METAL_OK) [_owner markError];
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode {
    if (zpu_metal_render_encoder_set_triangle_fill_mode(_zpuEncoder, (zpu_metal_triangle_fill_mode)fillMode) != ZPU_METAL_OK) [_owner markError];
}
- (void)setDepthStencilState:(id<MTLDepthStencilState>)depthStencilState {
    ZPUDepthStencilState *state = (ZPUDepthStencilState *)depthStencilState;
    if (![state isKindOfClass:[ZPUDepthStencilState class]] || state->_owner != [_owner device]) {
        [_owner markError];
        return;
    }
    _depthStencilState = state;
    [_owner retainResource:state];
    if (zpu_metal_render_encoder_set_depth_compare_function(
            _zpuEncoder, (zpu_metal_compare_function)state->_depthCompareFunction,
            state->_depthWriteEnabled) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_stencil_state(
            _zpuEncoder, 1, (zpu_metal_compare_function)state->_frontStencilCompareFunction,
            (zpu_metal_stencil_operation)state->_frontStencilFailureOperation,
            (zpu_metal_stencil_operation)state->_frontDepthFailureOperation,
            (zpu_metal_stencil_operation)state->_frontDepthStencilPassOperation,
            (uint8_t)state->_frontStencilReadMask, (uint8_t)state->_frontStencilWriteMask) != ZPU_METAL_OK ||
        zpu_metal_render_encoder_set_stencil_state(
            _zpuEncoder, 0, (zpu_metal_compare_function)state->_backStencilCompareFunction,
            (zpu_metal_stencil_operation)state->_backStencilFailureOperation,
            (zpu_metal_stencil_operation)state->_backDepthFailureOperation,
            (zpu_metal_stencil_operation)state->_backDepthStencilPassOperation,
            (uint8_t)state->_backStencilReadMask, (uint8_t)state->_backStencilWriteMask) != ZPU_METAL_OK) [_owner markError];
}
- (void)updateFence:(id<MTLFence>)fence afterStages:(MTLRenderStages)stages {
    (void)stages;
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device]) { [_owner markError]; return; }
    [_owner retainResource:zpuFence];
    (void)zpu_metal_render_encoder_update_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)waitForFence:(id<MTLFence>)fence beforeStages:(MTLRenderStages)stages {
    (void)stages;
    ZPUFence *zpuFence = (ZPUFence *)fence;
    if (![zpuFence isKindOfClass:[ZPUFence class]] || zpuFence->_owner != [_owner device]) { [_owner markError]; return; }
    [_owner retainResource:zpuFence];
    (void)zpu_metal_render_encoder_wait_for_fence(_zpuEncoder, zpuFence->_zpuFence);
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    ZPURenderPipelineState *state = (ZPURenderPipelineState *)pipelineState;
    if (![state isKindOfClass:[ZPURenderPipelineState class]] || state->_owner != [_owner device]) {
        [_owner markError];
        return;
    }
    _pipelineState = state;
    [_owner retainResource:state];
    uint16_t colorFormats[ZPU_METAL_MAX_COLOR_ATTACHMENTS];
    for (NSUInteger index = 0; index < ZPU_METAL_MAX_COLOR_ATTACHMENTS; ++index) {
        colorFormats[index] = (uint16_t)state->_colorPixelFormats[index];
    }
    if (zpu_metal_render_encoder_set_pipeline_color_formats(
            _zpuEncoder, colorFormats, state->_colorAttachmentCount,
            (uint16_t)state->_depthPixelFormat, (uint16_t)state->_stencilPixelFormat) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_multi_target_output(_zpuEncoder, state->_multiTargetOutput) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_sample_texture(_zpuEncoder, state->_sampleTexture) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_fragment_uniform_enabled(_zpuEncoder, state->_fragmentUniform) != ZPU_METAL_OK) [_owner markError];
    if (zpu_metal_render_encoder_set_rasterization_enabled(_zpuEncoder, state->_rasterizationEnabled) != ZPU_METAL_OK) [_owner markError];
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
- (void)setStencilReferenceValue:(uint32_t)referenceValue {
    if (zpu_metal_render_encoder_set_stencil_reference(_zpuEncoder, (uint8_t)referenceValue, (uint8_t)referenceValue) != ZPU_METAL_OK) [_owner markError];
}
- (void)setStencilFrontReferenceValue:(uint32_t)frontReferenceValue backReferenceValue:(uint32_t)backReferenceValue API_AVAILABLE(macos(10.11), ios(9.0)) {
    if (zpu_metal_render_encoder_set_stencil_reference(_zpuEncoder, (uint8_t)frontReferenceValue, (uint8_t)backReferenceValue) != ZPU_METAL_OK) [_owner markError];
}
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)mode offset:(NSUInteger)offset {
    if (zpu_metal_render_encoder_set_visibility_result_mode(_zpuEncoder, (uint8_t)mode, offset) != ZPU_METAL_OK) [_owner markError];
}
- (void)textureBarrier API_DEPRECATED_WITH_REPLACEMENT("Use memoryBarrierWithScope:MTLBarrierScopeRenderTargets", macos(10.11, 10.14)) API_UNAVAILABLE(ios) {}
- (NSUInteger)tileWidth API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { return 0; }
- (NSUInteger)tileHeight API_AVAILABLE(macos(11.0), macCatalyst(14.0), ios(11.0), tvos(14.5)) { return 0; }
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount {
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:1];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount {
    if (zpu_metal_render_encoder_draw_primitives(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, vertexStart, vertexCount, instanceCount) != ZPU_METAL_OK) [_owner markError];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance {
    (void)baseInstance;
    [self drawPrimitives:primitiveType vertexStart:vertexStart vertexCount:vertexCount instanceCount:instanceCount];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    ZPUBuffer *zpuIndirectBuffer = (ZPUBuffer *)indirectBuffer;
    if (![zpuIndirectBuffer isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
    [_owner retainResource:zpuIndirectBuffer];
    if (zpu_metal_render_encoder_draw_primitives_indirect(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, zpuIndirectBuffer->_zpuBuffer, indirectBufferOffset) != ZPU_METAL_OK) [_owner markError];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
    [_owner retainResource:zpuIndexBuffer];
    if (zpu_metal_render_encoder_draw_indexed_primitives(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount, (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32), zpuIndexBuffer->_zpuBuffer, indexBufferOffset, 1) != ZPU_METAL_OK) [_owner markError];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
    [_owner retainResource:zpuIndexBuffer];
    if (zpu_metal_render_encoder_draw_indexed_primitives(
        _zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount,
        (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32),
        zpuIndexBuffer->_zpuBuffer, indexBufferOffset, instanceCount) != ZPU_METAL_OK) [_owner markError];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    (void)baseInstance;
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
    [_owner retainResource:zpuIndexBuffer];
    if (zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(
        _zpuEncoder, (zpu_metal_primitive_type)primitiveType, indexCount,
        (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32),
        zpuIndexBuffer->_zpuBuffer, indexBufferOffset, instanceCount, (int64_t)baseVertex) != ZPU_METAL_OK) [_owner markError];
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset indirectBuffer:(id<MTLBuffer>)indirectBuffer indirectBufferOffset:(NSUInteger)indirectBufferOffset {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    ZPUBuffer *zpuIndirectBuffer = (ZPUBuffer *)indirectBuffer;
    if (![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]] || ![zpuIndirectBuffer isKindOfClass:[ZPUBuffer class]]) { [_owner markError]; return; }
    [_owner retainResource:zpuIndexBuffer];
    [_owner retainResource:zpuIndirectBuffer];
    if (zpu_metal_render_encoder_draw_indexed_primitives_indirect(_zpuEncoder, (zpu_metal_primitive_type)primitiveType, (zpu_metal_index_type)(indexType == MTLIndexTypeUInt16 ? ZPU_METAL_INDEX_UINT16 : ZPU_METAL_INDEX_UINT32), zpuIndexBuffer->_zpuBuffer, indexBufferOffset, zpuIndirectBuffer->_zpuBuffer, indirectBufferOffset) != ZPU_METAL_OK) [_owner markError];
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
    if (![buffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || buffer->_owner != [_owner device] ||
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
    ZPUIndirectCommandBuffer *buffer = (ZPUIndirectCommandBuffer *)indirectCommandBuffer;
    if (![buffer isKindOfClass:[ZPUIndirectCommandBuffer class]] || buffer->_owner != [_owner device] ||
        !zpu_buffer_belongs_to_device([_owner device], rangeBuffer) ||
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
    if (!zpu_color_attachment_map_is_identity(mapping)) [_owner markError];
}
- (void)setColorStoreAction:(MTLStoreAction)storeAction atIndex:(NSUInteger)colorAttachmentIndex {
    if (colorAttachmentIndex > UINT32_MAX ||
        zpu_metal_render_encoder_set_color_store_action(
            _zpuEncoder, (zpu_metal_store_action)storeAction, (uint32_t)colorAttachmentIndex) != ZPU_METAL_OK) {
        [_owner markError];
    }
}
- (void)setColorStoreActionOptions:(MTLStoreActionOptions)options atIndex:(NSUInteger)colorAttachmentIndex {
    (void)colorAttachmentIndex;
    if (options != 0) [_owner markError];
}
- (void)setDepthStoreAction:(MTLStoreAction)storeAction {
    if (zpu_metal_render_encoder_set_depth_store_action(
            _zpuEncoder, (zpu_metal_store_action)storeAction) != ZPU_METAL_OK) [_owner markError];
}
- (void)setDepthStoreActionOptions:(MTLStoreActionOptions)options {
    if (options != 0) [_owner markError];
}
- (void)setStencilStoreAction:(MTLStoreAction)storeAction {
    if (zpu_metal_render_encoder_set_stencil_store_action(
            _zpuEncoder, (zpu_metal_store_action)storeAction) != ZPU_METAL_OK) [_owner markError];
}
- (void)setStencilStoreActionOptions:(MTLStoreActionOptions)options {
    if (options != 0) [_owner markError];
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
        _inheritPipelineState = descriptor.inheritPipelineState;
        _inheritBuffers = descriptor.inheritBuffers;
        _maxVertexBufferBindCount = descriptor.maxVertexBufferBindCount;
        _maxFragmentBufferBindCount = descriptor.maxFragmentBufferBindCount;
        _maxKernelBufferBindCount = descriptor.maxKernelBufferBindCount;
        _commands = [NSMutableArray arrayWithCapacity:maxCount];
        for (NSUInteger index = 0; index < maxCount; ++index) [_commands addObject:[NSNull null]];
    }
    return self;
}
- (NSString *)label { return _label; }
- (void)setLabel:(NSString *)label { _label = [label copy]; }
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
    if (source == nil || source->_owner != _owner || sourceRange.location > source->_maxCommandCount ||
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
            copy->_fragmentBuffer = renderCommand->_fragmentBuffer;
            copy->_fragmentOffset = renderCommand->_fragmentOffset;
            copy->_depthStencilState = renderCommand->_depthStencilState;
            copy->_depthBias = renderCommand->_depthBias;
            copy->_slopeScale = renderCommand->_slopeScale;
            copy->_depthBiasClamp = renderCommand->_depthBiasClamp;
            copy->_depthClipMode = renderCommand->_depthClipMode;
            copy->_cullMode = renderCommand->_cullMode;
            copy->_frontFacingWinding = renderCommand->_frontFacingWinding;
            copy->_triangleFillMode = renderCommand->_triangleFillMode;
            copy->_hasFragmentBuffer = renderCommand->_hasFragmentBuffer;
            copy->_hasDepthStencilState = renderCommand->_hasDepthStencilState;
            copy->_hasDepthBias = renderCommand->_hasDepthBias;
            copy->_hasDepthClipMode = renderCommand->_hasDepthClipMode;
            copy->_hasCullMode = renderCommand->_hasCullMode;
            copy->_hasFrontFacingWinding = renderCommand->_hasFrontFacingWinding;
            copy->_hasTriangleFillMode = renderCommand->_hasTriangleFillMode;
            copy->_hasVertexBuffer = renderCommand->_hasVertexBuffer;
            copy->_unsupportedCommand = renderCommand->_unsupportedCommand;
            if ((renderCommand->_hasVertexBuffer && _maxVertexBufferBindCount == 0) ||
                (renderCommand->_hasFragmentBuffer && _maxFragmentBufferBindCount == 0)) return NO;
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
            copy->_unsupportedCommand = computeCommand->_unsupportedCommand;
            if (computeCommand->_kernelBuffer != nil && _maxKernelBufferBindCount == 0) return NO;
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
    _fragmentBuffer = nil;
    _fragmentOffset = 0;
    _depthStencilState = nil;
    _depthBias = 0;
    _slopeScale = 0;
    _depthBiasClamp = 0;
    _depthClipMode = MTLDepthClipModeClip;
    _cullMode = MTLCullModeNone;
    _frontFacingWinding = MTLWindingClockwise;
    _triangleFillMode = MTLTriangleFillModeFill;
    _hasFragmentBuffer = NO;
    _hasDepthStencilState = NO;
    _hasDepthBias = NO;
    _hasDepthClipMode = NO;
    _hasCullMode = NO;
    _hasFrontFacingWinding = NO;
    _hasTriangleFillMode = NO;
    _hasVertexBuffer = NO;
    _unsupportedCommand = NO;
}
- (void)setRenderPipelineState:(id<MTLRenderPipelineState>)pipelineState {
    if (pipelineState == nil) return;
    ZPURenderPipelineState *state = (ZPURenderPipelineState *)pipelineState;
    if (![state isKindOfClass:[ZPURenderPipelineState class]] || state->_owner != _owner->_owner) {
        _unsupportedCommand = YES;
        return;
    }
    _pipelineState = state;
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (index >= _owner->_maxVertexBufferBindCount ||
        (buffer != nil && (![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
                            zpuBuffer->_owner != _owner->_owner || offset > zpuBuffer.length))) {
        _unsupportedCommand = YES;
        return;
    }
    _vertexBuffer = zpuBuffer;
    _vertexOffset = buffer == nil ? 0 : offset;
    _hasVertexBuffer = YES;
}
- (void)setFragmentBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (index >= _owner->_maxFragmentBufferBindCount || (buffer != nil && (![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
                                         zpuBuffer->_owner != _owner->_owner || offset > zpuBuffer.length))) {
        _unsupportedCommand = YES;
        return;
    }
    _fragmentBuffer = zpuBuffer;
    _fragmentOffset = offset;
    _hasFragmentBuffer = YES;
}
- (void)setVertexBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    if (stride != 0) {
        _unsupportedCommand = YES;
        return;
    }
    [self setVertexBuffer:buffer offset:offset atIndex:index];
}
- (void)drawPrimitives:(MTLPrimitiveType)primitiveType vertexStart:(NSUInteger)vertexStart vertexCount:(NSUInteger)vertexCount instanceCount:(NSUInteger)instanceCount baseInstance:(NSUInteger)baseInstance {
    if ((_owner->_commandTypes & MTLIndirectCommandTypeDraw) == 0 ||
        !zpu_metal_indirect_primitive_supported(primitiveType)) {
        _unsupportedCommand = YES;
        return;
    }
    _primitiveType = primitiveType;
    _vertexStart = vertexStart;
    _vertexCount = vertexCount;
    _instanceCount = instanceCount;
    _baseInstance = baseInstance;
    _hasDraw = YES;
    _hasIndexedDraw = NO;
}
- (void)drawIndexedPrimitives:(MTLPrimitiveType)primitiveType indexCount:(NSUInteger)indexCount indexType:(MTLIndexType)indexType indexBuffer:(id<MTLBuffer>)indexBuffer indexBufferOffset:(NSUInteger)indexBufferOffset instanceCount:(NSUInteger)instanceCount baseVertex:(NSInteger)baseVertex baseInstance:(NSUInteger)baseInstance {
    ZPUBuffer *zpuIndexBuffer = (ZPUBuffer *)indexBuffer;
    const NSUInteger indexSize = indexType == MTLIndexTypeUInt16 ? sizeof(uint16_t) : sizeof(uint32_t);
    if ((_owner->_commandTypes & MTLIndirectCommandTypeDrawIndexed) == 0 ||
        !zpu_metal_indirect_primitive_supported(primitiveType) ||
        (indexType != MTLIndexTypeUInt16 && indexType != MTLIndexTypeUInt32) ||
        ![zpuIndexBuffer isKindOfClass:[ZPUBuffer class]] ||
        zpuIndexBuffer->_owner != _owner->_owner ||
        indexBufferOffset % indexSize != 0 || indexBufferOffset > zpuIndexBuffer.length ||
        indexCount > (zpuIndexBuffer.length - indexBufferOffset) / indexSize) {
        _unsupportedCommand = YES;
        return;
    }
    _primitiveType = primitiveType;
    _indexCount = indexCount;
    _indexType = indexType;
    _indexBuffer = zpuIndexBuffer;
    _indexOffset = indexBufferOffset;
    _instanceCount = instanceCount;
    _baseVertex = baseVertex;
    _baseInstance = baseInstance;
    _hasIndexedDraw = YES;
    _hasDraw = NO;
}
- (void)setObjectThreadgroupMemoryLength:(NSUInteger)length atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)length; (void)index; _unsupportedCommand = YES; }
- (void)setObjectBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)buffer; (void)offset; (void)index; _unsupportedCommand = YES; }
- (void)setMeshBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) { (void)buffer; (void)offset; (void)index; _unsupportedCommand = YES; }
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
    ZPUDepthStencilState *state = (ZPUDepthStencilState *)depthStencilState;
    if (depthStencilState != nil && (![state isKindOfClass:[ZPUDepthStencilState class]] || state->_owner != _owner->_owner)) {
        _unsupportedCommand = YES;
        return;
    }
    _depthStencilState = state;
    _hasDepthStencilState = YES;
}
- (void)setDepthBias:(float)depthBias slopeScale:(float)slopeScale clamp:(float)clamp API_AVAILABLE(macos(26.0), ios(26.0)) {
    _depthBias = depthBias;
    _slopeScale = slopeScale;
    _depthBiasClamp = clamp;
    _hasDepthBias = YES;
}
- (void)setDepthClipMode:(MTLDepthClipMode)depthClipMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (depthClipMode != MTLDepthClipModeClip && depthClipMode != MTLDepthClipModeClamp) {
        _unsupportedCommand = YES;
        return;
    }
    _depthClipMode = depthClipMode;
    _hasDepthClipMode = YES;
}
- (void)setCullMode:(MTLCullMode)cullMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (cullMode > MTLCullModeBack) {
        _unsupportedCommand = YES;
        return;
    }
    _cullMode = cullMode;
    _hasCullMode = YES;
}
- (void)setFrontFacingWinding:(MTLWinding)frontFacingWinding API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (frontFacingWinding != MTLWindingClockwise && frontFacingWinding != MTLWindingCounterClockwise) {
        _unsupportedCommand = YES;
        return;
    }
    _frontFacingWinding = frontFacingWinding;
    _hasFrontFacingWinding = YES;
}
- (void)setTriangleFillMode:(MTLTriangleFillMode)fillMode API_AVAILABLE(macos(26.0), ios(26.0)) {
    if (fillMode != MTLTriangleFillModeFill && fillMode != MTLTriangleFillModeLines) {
        _unsupportedCommand = YES;
        return;
    }
    _triangleFillMode = fillMode;
    _hasTriangleFillMode = YES;
}
- (void)setBarrier API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {}
- (void)clearBarrier API_AVAILABLE(macos(14.0), ios(17.0), tvos(18.1), visionos(2.1)) {}
- (void)executeWithEncoder:(ZPURenderEncoder *)encoder {
    if (_unsupportedCommand) {
        [encoder->_owner markError];
        return;
    }
    /* A reset or never-recorded ICB slot is a legal no-op, even when the
     * descriptor does not inherit pipeline state. */
    if (!_hasDraw && !_hasIndexedDraw) return;
    if (!_owner->_inheritPipelineState && _pipelineState == nil) {
        [encoder->_owner markError];
        return;
    }
    if (_pipelineState != nil) [encoder setRenderPipelineState:(id<MTLRenderPipelineState>)_pipelineState];
    if (_hasVertexBuffer) {
        [encoder setVertexBuffer:(id<MTLBuffer>)_vertexBuffer offset:_vertexOffset atIndex:0];
    } else if (!_owner->_inheritBuffers) {
        [encoder setVertexBuffer:nil offset:0 atIndex:0];
    }
    if (_hasFragmentBuffer) {
        [encoder setFragmentBuffer:(id<MTLBuffer>)_fragmentBuffer offset:_fragmentOffset atIndex:0];
    } else if (!_owner->_inheritBuffers) {
        [encoder setFragmentBuffer:nil offset:0 atIndex:0];
    }
    if (_hasDepthStencilState) [encoder setDepthStencilState:(id<MTLDepthStencilState>)_depthStencilState];
    if (_hasDepthBias) [encoder setDepthBias:_depthBias slopeScale:_slopeScale clamp:_depthBiasClamp];
    if (_hasDepthClipMode) [encoder setDepthClipMode:_depthClipMode];
    if (_hasCullMode) [encoder setCullMode:_cullMode];
    if (_hasFrontFacingWinding) [encoder setFrontFacingWinding:_frontFacingWinding];
    if (_hasTriangleFillMode) [encoder setTriangleFillMode:_triangleFillMode];
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
    _unsupportedCommand = NO;
}
- (void)setComputePipelineState:(id<MTLComputePipelineState>)pipelineState API_AVAILABLE(macos(11.0), ios(13.0)) {
    ZPUComputePipelineState *pipeline = (ZPUComputePipelineState *)pipelineState;
    if (pipelineState == nil) {
        _pipelineState = nil;
        return;
    }
    if (![pipeline isKindOfClass:[ZPUComputePipelineState class]] || pipeline->_owner != _owner->_owner) {
        _unsupportedCommand = YES;
        return;
    }
    _pipelineState = pipeline;
}
- (void)setKernelBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset atIndex:(NSUInteger)index {
    ZPUBuffer *zpuBuffer = (ZPUBuffer *)buffer;
    if (index >= _owner->_maxKernelBufferBindCount || (buffer != nil && (![zpuBuffer isKindOfClass:[ZPUBuffer class]] ||
                                         zpuBuffer->_owner != _owner->_owner || offset > zpuBuffer.length))) {
        _unsupportedCommand = YES;
        return;
    }
    _kernelBuffer = zpuBuffer;
    _kernelBufferOffset = buffer == nil ? 0 : offset;
}
- (void)setKernelBuffer:(id<MTLBuffer>)buffer offset:(NSUInteger)offset attributeStride:(NSUInteger)stride atIndex:(NSUInteger)index API_AVAILABLE(macos(14.0), ios(17.0)) {
    if (stride != 0) {
        _unsupportedCommand = YES;
        return;
    }
    [self setKernelBuffer:buffer offset:offset atIndex:index];
}
- (void)concurrentDispatchThreadgroups:(MTLSize)threadgroupsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    if ((_owner->_commandTypes & MTLIndirectCommandTypeConcurrentDispatch) == 0 ||
        threadgroupsPerGrid.width > UINT32_MAX || threadgroupsPerGrid.height > UINT32_MAX ||
        threadgroupsPerGrid.depth > UINT32_MAX ||
        !zpu_metal_size_fits_cpu_threadgroup(threadsPerThreadgroup, 1024)) {
        _unsupportedCommand = YES;
        return;
    }
    _threadgroupsPerGrid = threadgroupsPerGrid;
    _threadgroupsPerThreadgroup = threadsPerThreadgroup;
    _hasDispatchThreadgroups = YES;
    _hasDispatchThreads = NO;
}
- (void)concurrentDispatchThreads:(MTLSize)threadsPerGrid threadsPerThreadgroup:(MTLSize)threadsPerThreadgroup {
    if ((_owner->_commandTypes & MTLIndirectCommandTypeConcurrentDispatchThreads) == 0 ||
        threadsPerGrid.width > UINT32_MAX || threadsPerGrid.height > UINT32_MAX ||
        threadsPerGrid.depth > UINT32_MAX ||
        !zpu_metal_size_fits_cpu_threadgroup(threadsPerThreadgroup, 1024)) {
        _unsupportedCommand = YES;
        return;
    }
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
    if (_unsupportedCommand) {
        [encoder->_owner markError];
        return;
    }
    /* A reset or never-recorded ICB slot is a legal no-op. */
    if (_pipelineState == nil || (!_hasDispatchThreads && !_hasDispatchThreadgroups)) return;
    ZPUComputePipelineState *pipeline = (ZPUComputePipelineState *)_pipelineState;
    MTLSize threadgroup = _hasDispatchThreads ? _threadsPerThreadgroup : _threadgroupsPerThreadgroup;
    if (!zpu_metal_size_fits_cpu_threadgroup(threadgroup, pipeline->_maxTotalThreadsPerThreadgroup)) {
        [encoder->_owner markError];
        return;
    }
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

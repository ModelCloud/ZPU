// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Core object/resource implementation for the opt-in ZPU Metal-shaped ABI.
//!
//! This is a deterministic CPU command runtime.  It deliberately uses an
//! explicit C handle graph instead of attempting to replace Apple's
//! Objective-C Metal framework.  The runtime nevertheless preserves the
//! useful Metal ordering rule: encoders record work, and work becomes visible
//! only when the command buffer is committed.

const std = @import("std");
const abi = @import("abi.zig");
const raster3d = @import("raster3d.zig");

const allocator = std.heap.c_allocator;

const device_magic: u64 = 0x5a50555f4d544c44; // ZPU_MTLD
const queue_magic: u64 = 0x5a50555f51554555; // ZPU_QUEU
const command_buffer_magic: u64 = 0x5a50555f434d4442; // ZPU_CMDB
const render_encoder_magic: u64 = 0x5a50555f52454e43; // ZPU_RENC
const blit_encoder_magic: u64 = 0x5a50555f424c4954; // ZPU_BLIT
const compute_encoder_magic: u64 = 0x5a50555f434f4d50; // ZPU_COMP
const resource_state_encoder_magic: u64 = 0x5a50555f52535445; // ZPU_RSTE
const buffer_magic: u64 = 0x5a50555f42554646; // ZPU_BUFF
const texture_magic: u64 = 0x5a50555f54455854; // ZPU_TEXT
const heap_magic: u64 = 0x5a50555f48454150; // ZPU_HEAP
const fence_magic: u64 = 0x5a50555f46454e43; // ZPU_FENC
const shared_event_magic: u64 = 0x5a50555f53455654; // ZPU_SEVT

const cpu_acceleration_structure_magic: u32 = 0x5a505541;
const cpu_acceleration_structure_version: u32 = 2;
const cpu_acceleration_structure_header_bytes: usize = 32;
const cpu_acceleration_structure_triangle_bytes: usize = 9 * @sizeOf(f32);
const cpu_acceleration_structure_aabb_bytes: usize = 6 * @sizeOf(f32);
const cpu_acceleration_structure_flag_triangle_masks: u32 = 2;
const cpu_acceleration_structure_flag_aabbs: u32 = 4;
const max_viewport_count = 16;

pub const TextureFormat = enum {
    a8_unorm,
    r8_unorm,
    r8_unorm_srgb,
    r8_snorm,
    r8_uint,
    r8_sint,
    r16_unorm,
    r16_snorm,
    r16_uint,
    r16_sint,
    r16_float,
    rg8_unorm,
    rg8_unorm_srgb,
    rg8_snorm,
    rg8_uint,
    rg8_sint,
    rg16_unorm,
    rg16_snorm,
    rg16_uint,
    rg16_sint,
    rg16_float,
    r32_uint,
    r32_sint,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba8_snorm,
    rgba8_uint,
    rgba8_sint,
    bgra8_unorm,
    bgra8_unorm_srgb,
    b5g6r5_unorm,
    a1bgr5_unorm,
    abgr4_unorm,
    bgr5a1_unorm,
    rgb10a2_unorm,
    rgb10a2_uint,
    rg11b10_float,
    rgb9e5_float,
    bgr10a2_unorm,
    r32_float,
    rgba16_unorm,
    rgba16_snorm,
    rgba16_uint,
    rgba16_sint,
    rgba16_float,
    rg32_uint,
    rg32_sint,
    rg32_float,
    rgba32_uint,
    rgba32_sint,
    rgba32_float,
    depth16_unorm,
    depth32_float,
    stencil8,
    depth24_unorm_stencil8,
    depth32_float_stencil8,
    x32_stencil8,
    x24_stencil8,

    fn bytesPerPixel(self: TextureFormat) usize {
        return switch (self) {
            .a8_unorm => 1,
            .r8_unorm, .r8_unorm_srgb, .r8_snorm => 1,
            .r8_uint, .r8_sint => 1,
            .r16_unorm, .r16_snorm => 2,
            .r16_uint, .r16_sint => 2,
            .r16_float => 2,
            .rg8_unorm, .rg8_unorm_srgb, .rg8_snorm => 2,
            .rg8_uint, .rg8_sint => 2,
            .rg16_unorm, .rg16_snorm => 4,
            .rg16_uint, .rg16_sint => 4,
            .rg16_float => 4,
            .r32_uint, .r32_sint => 4,
            .rgba8_unorm_srgb, .rgba8_snorm, .rgba8_uint, .rgba8_sint => 4,
            .b5g6r5_unorm, .a1bgr5_unorm, .abgr4_unorm, .bgr5a1_unorm => 2,
            .rgb10a2_unorm, .rgb10a2_uint, .rg11b10_float, .rgb9e5_float, .bgr10a2_unorm => 4,
            .stencil8 => 1,
            .depth16_unorm => 2,
            .depth24_unorm_stencil8, .x24_stencil8 => 4,
            .depth32_float_stencil8, .x32_stencil8 => 8,
            .rgba16_unorm, .rgba16_snorm, .rgba16_uint, .rgba16_sint, .rgba16_float => 8,
            .rg32_uint, .rg32_sint, .rg32_float => 8,
            .rgba32_uint, .rgba32_sint, .rgba32_float => 16,
            else => 4,
        };
    }

    fn isColor(self: TextureFormat) bool {
        return self == .a8_unorm or self == .r8_unorm or self == .r8_unorm_srgb or self == .r8_snorm or self == .r8_uint or self == .r8_sint or self == .r16_unorm or self == .r16_snorm or self == .r16_uint or self == .r16_sint or self == .r16_float or
            self == .rg8_unorm or self == .rg8_unorm_srgb or self == .rg8_snorm or self == .rg8_uint or self == .rg8_sint or self == .rg16_unorm or self == .rg16_snorm or self == .rg16_uint or self == .rg16_sint or self == .rg16_float or
            self == .rgba8_unorm or self == .rgba8_unorm_srgb or self == .rgba8_snorm or self == .rgba8_uint or self == .rgba8_sint or
            self == .bgra8_unorm or self == .bgra8_unorm_srgb or
            self == .b5g6r5_unorm or self == .a1bgr5_unorm or self == .abgr4_unorm or self == .bgr5a1_unorm or
            self == .rgb10a2_unorm or self == .rgb10a2_uint or self == .bgr10a2_unorm or self == .rg11b10_float or self == .rgb9e5_float or
            self == .r32_uint or self == .r32_sint or self == .r32_float or self == .rgba16_unorm or self == .rgba16_snorm or self == .rgba16_uint or self == .rgba16_sint or self == .rgba16_float or
            self == .rg32_uint or self == .rg32_sint or self == .rg32_float or
            self == .rgba32_uint or self == .rgba32_sint or self == .rgba32_float;
    }

    fn isIntegerColor(self: TextureFormat) bool {
        return self == .r8_uint or self == .r8_sint or self == .r16_uint or self == .r16_sint or
            self == .rg8_uint or self == .rg8_sint or self == .rg16_uint or self == .rg16_sint or
            self == .rgba8_uint or self == .rgba8_sint or self == .rgb10a2_uint or
            self == .r32_uint or self == .r32_sint or self == .rg32_uint or self == .rg32_sint or
            self == .rgba16_uint or self == .rgba16_sint or self == .rgba32_uint or self == .rgba32_sint;
    }
};

fn textureFormatFromRaw(format_raw: u16) ?TextureFormat {
    return switch (format_raw) {
        @intFromEnum(abi.PixelFormat.a8_unorm) => .a8_unorm,
        @intFromEnum(abi.PixelFormat.r8_unorm) => .r8_unorm,
        @intFromEnum(abi.PixelFormat.r8_unorm_srgb) => .r8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.r8_snorm) => .r8_snorm,
        @intFromEnum(abi.PixelFormat.r8_uint) => .r8_uint,
        @intFromEnum(abi.PixelFormat.r8_sint) => .r8_sint,
        @intFromEnum(abi.PixelFormat.r16_unorm) => .r16_unorm,
        @intFromEnum(abi.PixelFormat.r16_snorm) => .r16_snorm,
        @intFromEnum(abi.PixelFormat.r16_uint) => .r16_uint,
        @intFromEnum(abi.PixelFormat.r16_sint) => .r16_sint,
        @intFromEnum(abi.PixelFormat.r16_float) => .r16_float,
        @intFromEnum(abi.PixelFormat.rg8_unorm) => .rg8_unorm,
        @intFromEnum(abi.PixelFormat.rg8_unorm_srgb) => .rg8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.rg8_snorm) => .rg8_snorm,
        @intFromEnum(abi.PixelFormat.rg8_uint) => .rg8_uint,
        @intFromEnum(abi.PixelFormat.rg8_sint) => .rg8_sint,
        @intFromEnum(abi.PixelFormat.rg16_unorm) => .rg16_unorm,
        @intFromEnum(abi.PixelFormat.rg16_snorm) => .rg16_snorm,
        @intFromEnum(abi.PixelFormat.rg16_uint) => .rg16_uint,
        @intFromEnum(abi.PixelFormat.rg16_sint) => .rg16_sint,
        @intFromEnum(abi.PixelFormat.rg16_float) => .rg16_float,
        @intFromEnum(abi.PixelFormat.r32_uint) => .r32_uint,
        @intFromEnum(abi.PixelFormat.r32_sint) => .r32_sint,
        @intFromEnum(abi.PixelFormat.rgba8_unorm) => .rgba8_unorm,
        @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb) => .rgba8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.rgba8_snorm) => .rgba8_snorm,
        @intFromEnum(abi.PixelFormat.rgba8_uint) => .rgba8_uint,
        @intFromEnum(abi.PixelFormat.rgba8_sint) => .rgba8_sint,
        @intFromEnum(abi.PixelFormat.bgra8_unorm) => .bgra8_unorm,
        @intFromEnum(abi.PixelFormat.bgra8_unorm_srgb) => .bgra8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.b5g6r5_unorm) => .b5g6r5_unorm,
        @intFromEnum(abi.PixelFormat.a1bgr5_unorm) => .a1bgr5_unorm,
        @intFromEnum(abi.PixelFormat.abgr4_unorm) => .abgr4_unorm,
        @intFromEnum(abi.PixelFormat.bgr5a1_unorm) => .bgr5a1_unorm,
        @intFromEnum(abi.PixelFormat.rgb10a2_unorm) => .rgb10a2_unorm,
        @intFromEnum(abi.PixelFormat.rgb10a2_uint) => .rgb10a2_uint,
        @intFromEnum(abi.PixelFormat.rg11b10_float) => .rg11b10_float,
        @intFromEnum(abi.PixelFormat.rgb9e5_float) => .rgb9e5_float,
        @intFromEnum(abi.PixelFormat.bgr10a2_unorm) => .bgr10a2_unorm,
        @intFromEnum(abi.PixelFormat.r32_float) => .r32_float,
        @intFromEnum(abi.PixelFormat.rgba16_unorm) => .rgba16_unorm,
        @intFromEnum(abi.PixelFormat.rgba16_snorm) => .rgba16_snorm,
        @intFromEnum(abi.PixelFormat.rgba16_uint) => .rgba16_uint,
        @intFromEnum(abi.PixelFormat.rgba16_sint) => .rgba16_sint,
        @intFromEnum(abi.PixelFormat.rgba16_float) => .rgba16_float,
        @intFromEnum(abi.PixelFormat.rg32_uint) => .rg32_uint,
        @intFromEnum(abi.PixelFormat.rg32_sint) => .rg32_sint,
        @intFromEnum(abi.PixelFormat.rg32_float) => .rg32_float,
        @intFromEnum(abi.PixelFormat.rgba32_uint) => .rgba32_uint,
        @intFromEnum(abi.PixelFormat.rgba32_sint) => .rgba32_sint,
        @intFromEnum(abi.PixelFormat.rgba32_float) => .rgba32_float,
        @intFromEnum(abi.PixelFormat.depth16_unorm) => .depth16_unorm,
        @intFromEnum(abi.PixelFormat.depth32_float) => .depth32_float,
        @intFromEnum(abi.PixelFormat.stencil8) => .stencil8,
        @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8) => .depth24_unorm_stencil8,
        @intFromEnum(abi.PixelFormat.depth32_float_stencil8) => .depth32_float_stencil8,
        @intFromEnum(abi.PixelFormat.x32_stencil8) => .x32_stencil8,
        @intFromEnum(abi.PixelFormat.x24_stencil8) => .x24_stencil8,
        else => null,
    };
}

fn isDepthTextureFormat(format: TextureFormat) bool {
    return format == .depth16_unorm or format == .depth32_float or
        format == .depth24_unorm_stencil8 or format == .depth32_float_stencil8;
}

fn isStencilTextureFormat(format: TextureFormat) bool {
    return format == .stencil8 or format == .depth24_unorm_stencil8 or
        format == .depth32_float_stencil8 or format == .x32_stencil8 or format == .x24_stencil8;
}

fn textureFormatsViewCompatible(source: TextureFormat, view: TextureFormat) bool {
    if (source == view) return true;
    // Metal views reinterpret shared texel bytes. Apple accepts all color and
    // integer formats with the same bytes-per-texel. The two documented
    // combined-depth parents also expose a stencil-only view with the same
    // packed storage; other depth/stencil reinterpretations remain invalid.
    if ((source == .depth32_float_stencil8 and view == .x32_stencil8) or
        (source == .x32_stencil8 and view == .depth32_float_stencil8) or
        (source == .depth24_unorm_stencil8 and view == .x24_stencil8) or
        (source == .x24_stencil8 and view == .depth24_unorm_stencil8)) return true;
    if (isDepthTextureFormat(source) or isStencilTextureFormat(source) or
        isDepthTextureFormat(view) or isStencilTextureFormat(view)) return false;
    return source.bytesPerPixel() == view.bytesPerPixel();
}

pub const Error = error{
    InvalidArgument,
    InvalidResource,
    InvalidCommand,
    UnsupportedFormat,
    UnsupportedOperation,
    OutOfMemory,
};

pub const CommandStatus = enum(u8) {
    created,
    committed,
    completed,
    failed,
};

const EncoderKind = enum { none, render, blit, compute, resource_state };

pub const Device = struct {
    magic: u64 = device_magic,
};

pub const CommandQueue = struct {
    magic: u64 = queue_magic,
    device: *Device,
};

pub const Fence = struct {
    magic: u64 = fence_magic,
    device: *Device,
    signaled: bool = false,
};

pub const SharedEvent = struct {
    magic: u64 = shared_event_magic,
    device: *Device,
    signaled_value: u64 = 0,
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,
};

const HeapAllocation = struct {
    offset: usize,
    size: usize,
};

pub const Heap = struct {
    magic: u64 = heap_magic,
    device: *Device,
    size: usize,
    backing: []u8,
    used: usize = 0,
    allocations: std.ArrayList(HeapAllocation) = .empty,
};

const SparsePage = struct {
    bytes: []u8,
    refs: usize = 1,

    fn create(page_bytes: usize) Error!*SparsePage {
        const bytes = allocator.alloc(u8, page_bytes) catch return error.OutOfMemory;
        @memset(bytes, 0);
        const result = allocator.create(SparsePage) catch {
            allocator.free(bytes);
            return error.OutOfMemory;
        };
        result.* = .{ .bytes = bytes };
        return result;
    }

    fn retain(self: *SparsePage) void {
        self.refs += 1;
    }

    fn release(self: *SparsePage) void {
        std.debug.assert(self.refs != 0);
        self.refs -= 1;
        if (self.refs == 0) {
            allocator.free(self.bytes);
            allocator.destroy(self);
        }
    }
};

const SparseMapping = struct {
    page_index: usize,
    page: *SparsePage,
};

const SparseTextureMapping = struct {
    tile_x: usize,
    tile_y: usize,
    page: *SparsePage,
};

pub const Buffer = struct {
    magic: u64 = buffer_magic,
    device: *Device,
    bytes: []u8,
    owns_bytes: bool = true,
    heap: ?*Heap = null,
    heap_allocation_offset: usize = 0,
    heap_allocation_size: usize = 0,
    sparse_page_bytes: usize = 0,
    sparse_mappings: std.ArrayList(SparseMapping) = .empty,

    pub fn deinit(self: *Buffer) void {
        for (self.sparse_mappings.items) |mapping| mapping.page.release();
        self.sparse_mappings.deinit(allocator);
        if (self.owns_bytes) allocator.free(self.bytes);
        releaseHeapAllocation(self.heap, self.heap_allocation_offset, self.heap_allocation_size);
        self.magic = 0;
    }
};

pub const Texture = struct {
    magic: u64 = texture_magic,
    device: *Device,
    width: u32,
    height: u32,
    stride: usize,
    format: TextureFormat,
    bytes: []u8,
    owns_bytes: bool = true,
    heap: ?*Heap = null,
    heap_allocation_offset: usize = 0,
    heap_allocation_size: usize = 0,
    sparse_page_bytes: usize = 0,
    sparse_tile_width: usize = 0,
    sparse_tile_height: usize = 0,
    sparse_mappings: std.ArrayList(SparseTextureMapping) = .empty,

    pub fn deinit(self: *Texture) void {
        for (self.sparse_mappings.items) |mapping| mapping.page.release();
        self.sparse_mappings.deinit(allocator);
        if (self.owns_bytes) allocator.free(self.bytes);
        releaseHeapAllocation(self.heap, self.heap_allocation_offset, self.heap_allocation_size);
        self.magic = 0;
    }

    fn asTarget(self: *Texture) raster3d.Target {
        std.debug.assert(self.format.isColor());
        return .{
            .pixels = self.bytes,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .format = switch (self.format) {
                .a8_unorm => .a8_unorm,
                .r8_unorm => .r8_unorm,
                .r8_unorm_srgb => .r8_unorm_srgb,
                .r8_snorm => .r8_snorm,
                .r8_uint => .r8_uint,
                .r8_sint => .r8_sint,
                .r16_unorm => .r16_unorm,
                .r16_snorm => .r16_snorm,
                .r16_uint => .r16_uint,
                .r16_sint => .r16_sint,
                .r16_float => .r16_float,
                .rg8_unorm => .rg8_unorm,
                .rg8_unorm_srgb => .rg8_unorm_srgb,
                .rg8_snorm => .rg8_snorm,
                .rg8_uint => .rg8_uint,
                .rg8_sint => .rg8_sint,
                .rg16_unorm => .rg16_unorm,
                .rg16_snorm => .rg16_snorm,
                .rg16_uint => .rg16_uint,
                .rg16_sint => .rg16_sint,
                .rg16_float => .rg16_float,
                .r32_uint => .r32_uint,
                .r32_sint => .r32_sint,
                .rgba8_unorm => .rgba8_unorm,
                .rgba8_unorm_srgb => .rgba8_unorm_srgb,
                .rgba8_snorm => .rgba8_snorm,
                .rgba8_uint => .rgba8_uint,
                .rgba8_sint => .rgba8_sint,
                .bgra8_unorm => .bgra8_unorm,
                .bgra8_unorm_srgb => .bgra8_unorm_srgb,
                .b5g6r5_unorm => .b5g6r5_unorm,
                .a1bgr5_unorm => .a1bgr5_unorm,
                .abgr4_unorm => .abgr4_unorm,
                .bgr5a1_unorm => .bgr5a1_unorm,
                .rgb10a2_unorm => .rgb10a2_unorm,
                .rgb10a2_uint => .rgb10a2_uint,
                .rg11b10_float => .rg11b10_float,
                .rgb9e5_float => .rgb9e5_float,
                .bgr10a2_unorm => .bgr10a2_unorm,
                .r32_float => .r32_float,
                .rgba16_unorm => .rgba16_unorm,
                .rgba16_snorm => .rgba16_snorm,
                .rgba16_uint => .rgba16_uint,
                .rgba16_sint => .rgba16_sint,
                .rgba16_float => .rgba16_float,
                .rg32_uint => .rg32_uint,
                .rg32_sint => .rg32_sint,
                .rg32_float => .rg32_float,
                .rgba32_uint => .rgba32_uint,
                .rgba32_sint => .rgba32_sint,
                .rgba32_float => .rgba32_float,
                .depth16_unorm, .depth32_float, .stencil8, .depth24_unorm_stencil8, .depth32_float_stencil8, .x32_stencil8, .x24_stencil8 => unreachable,
            },
        };
    }
};

const DrawCommand = struct {
    vertex_start: usize,
    vertex_count: usize,
    vertex_stride: usize = @sizeOf(abi.Vertex),
    primitive: abi.PrimitiveType,
    options: raster3d.DrawOptions,
    vertex_buffer: ?*Buffer = null,
    vertex_buffer_offset: usize = 0,
    vertex_source_count: usize = 0,
    index_buffer: ?*Buffer = null,
    index_buffer_offset: usize = 0,
    index_type: abi.IndexType = .uint16,
    base_vertex: i64 = 0,
    indirect_buffer: ?*Buffer = null,
    indirect_buffer_offset: usize = 0,
    fragment_uniform_enabled: bool = false,
    fragment_uniform_buffer: ?*Buffer = null,
    fragment_uniform_buffer_offset: usize = 0,
    sample_texture: ?*Texture = null,
    sample_mipmap_start: usize = 0,
    sample_mipmap_count: usize = 0,
    visibility_buffer: ?*Buffer = null,
    visibility_mode: abi.VisibilityResultMode = .disabled,
    visibility_offset: usize = 0,
    visibility_result_type: abi.VisibilityResultType = .reset,
    // Direct layered draws use the expanded instance index as the selected
    // render-target-array slice. Indirect draws add their base instance after
    // deferred argument resolution; non-layered draws retain zero.
    array_index: usize = 0,
    base_instance: usize = 0,
    amplification_count: u8 = 1,
    amplification_viewport_offsets: [2]u32 = .{ 0, 0 },
    amplification_render_target_offsets: [2]u32 = .{ 0, 0 },
    viewport_array: [max_viewport_count]raster3d.PreciseViewport = undefined,
    viewport_array_count: u8 = 1,
    scissor_array: [max_viewport_count]abi.ScissorRect = undefined,
    scissor_array_count: u8 = 1,
};

const TileCommand = struct {
    target: *Texture,
    kernel: u8,
    tile_size: abi.Size,
    threads_per_tile: abi.Size,
    color_attachment_map: [8]u8,
    options: raster3d.DrawOptions,
    visibility_buffer: ?*Buffer = null,
    visibility_mode: abi.VisibilityResultMode = .disabled,
    visibility_offset: usize = 0,
    visibility_result_type: abi.VisibilityResultType = .reset,
};

const MeshCommand = struct {
    target: *Texture,
    kernel: u8,
    threads_per_grid: abi.Size,
    threads_per_object_threadgroup: abi.Size,
    threads_per_mesh_threadgroup: abi.Size,
    color_attachment_map: [8]u8,
    options: raster3d.DrawOptions,
    visibility_buffer: ?*Buffer = null,
    visibility_mode: abi.VisibilityResultMode = .disabled,
    visibility_offset: usize = 0,
    visibility_result_type: abi.VisibilityResultType = .reset,
    indirect_buffer: ?*Buffer = null,
    indirect_buffer_offset: usize = 0,
};

const PatchCommand = struct {
    target: *Texture,
    kernel: u8,
    control_point_count: u32,
    patch_start: usize,
    patch_count: usize,
    patch_index_buffer: ?*Buffer,
    patch_index_buffer_offset: usize,
    control_point_index_type: abi.TessellationControlPointIndexType,
    control_point_index_buffer: ?*Buffer,
    control_point_index_buffer_offset: usize,
    instance_count: usize,
    base_instance: usize,
    factor_buffer: *Buffer,
    factor_buffer_offset: usize,
    factor_instance_stride: usize,
    factor_scale: f32,
    partition_mode: u8,
    max_tessellation_factor: usize,
    indirect_buffer: ?*Buffer,
    indirect_buffer_offset: usize,
    vertex_buffer: ?*Buffer,
    vertex_buffer_offset: usize,
    vertex_stride: usize,
    inline_vertex_start: usize,
    inline_vertex_count: usize,
    options: raster3d.DrawOptions,
    fragment_uniform_enabled: bool,
    fragment_uniform_buffer: ?*Buffer,
    fragment_uniform_buffer_offset: usize,
    visibility_buffer: ?*Buffer,
    visibility_mode: abi.VisibilityResultMode,
    visibility_offset: usize,
    visibility_result_type: abi.VisibilityResultType,
};

// The registered patch profile deliberately has a bounded CPU tessellator.
// Integer, power-of-two, and uniform fractional triangle factors up to 16 cover the portable profile while keeping
// the generated mesh on the command-buffer stack. Arbitrary tessellation
// shaders and non-uniform edge/inside factors remain fail-closed at command
// commit; fractional line-grid rasterization is also rejected. A factor scale
// is supported when it produces
// one positive partition factor for all four values in the registered profile.
const cpu_patch_max_tessellation_factor: usize = 16;
const cpu_patch_max_mesh_vertices: usize = cpu_patch_max_tessellation_factor * cpu_patch_max_tessellation_factor * 3;
const cpu_tessellation_partition_pow2: u8 = 0;
const cpu_tessellation_partition_integer: u8 = 1;
const cpu_tessellation_partition_fractional_odd: u8 = 2;
const cpu_tessellation_partition_fractional_even: u8 = 3;

fn interpolatePatchVertex(control: [3]abi.Vertex, weights: [3]usize, factor: usize) abi.Vertex {
    const denominator: f32 = @floatFromInt(factor);
    const weight0: f32 = @as(f32, @floatFromInt(weights[0])) / denominator;
    const weight1: f32 = @as(f32, @floatFromInt(weights[1])) / denominator;
    const weight2: f32 = @as(f32, @floatFromInt(weights[2])) / denominator;
    var result: abi.Vertex = undefined;
    for (0..4) |component| {
        result.position[component] = control[0].position[component] * weight0 +
            control[1].position[component] * weight1 + control[2].position[component] * weight2;
    }
    result.color.red = control[0].color.red * weight0 + control[1].color.red * weight1 + control[2].color.red * weight2;
    result.color.green = control[0].color.green * weight0 + control[1].color.green * weight1 + control[2].color.green * weight2;
    result.color.blue = control[0].color.blue * weight0 + control[1].color.blue * weight1 + control[2].color.blue * weight2;
    result.color.alpha = control[0].color.alpha * weight0 + control[1].color.alpha * weight1 + control[2].color.alpha * weight2;
    return result;
}

fn appendPatchGridVertex(
    output: *[cpu_patch_max_mesh_vertices]abi.Vertex,
    count: *usize,
    control: [3]abi.Vertex,
    weights: [3]usize,
    factor: usize,
) void {
    output.*[count.*] = interpolatePatchVertex(control, weights, factor);
    count.* += 1;
}

fn tessellateUniformPatch(
    control: [3]abi.Vertex,
    factor: usize,
    output: *[cpu_patch_max_mesh_vertices]abi.Vertex,
) usize {
    var count: usize = 0;
    for (0..factor) |i| {
        for (0..factor - i) |j| {
            const lower_left = [3]usize{ i, j, factor - i - j };
            const lower_right = [3]usize{ i + 1, j, factor - i - j - 1 };
            const upper_left = [3]usize{ i, j + 1, factor - i - j - 1 };
            appendPatchGridVertex(output, &count, control, lower_left, factor);
            appendPatchGridVertex(output, &count, control, lower_right, factor);
            appendPatchGridVertex(output, &count, control, upper_left, factor);
            if (i + j + 2 <= factor) {
                const upper_right = [3]usize{ i + 1, j + 1, factor - i - j - 2 };
                appendPatchGridVertex(output, &count, control, lower_right, factor);
                appendPatchGridVertex(output, &count, control, upper_right, factor);
                appendPatchGridVertex(output, &count, control, upper_left, factor);
            }
        }
    }
    return count;
}

fn partitionTessellationFactor(value: f32, mode: u8, max_factor: usize) ?usize {
    if (!std.math.isFinite(value) or value < 1.0 or max_factor == 0) return null;
    return switch (mode) {
        cpu_tessellation_partition_integer => if (@floor(value) == value and
            value <= @as(f32, @floatFromInt(max_factor))) @intFromFloat(value) else null,
        cpu_tessellation_partition_pow2 => blk: {
            var factor: usize = 1;
            while (@as(f32, @floatFromInt(factor)) < value) {
                if (factor > max_factor / 2) break :blk null;
                factor *= 2;
            }
            break :blk if (factor <= max_factor) factor else null;
        },
        cpu_tessellation_partition_fractional_odd => blk: {
            var factor: usize = @intFromFloat(@ceil(value));
            if (factor % 2 == 0) factor += 1;
            break :blk if (factor <= max_factor) factor else null;
        },
        cpu_tessellation_partition_fractional_even => blk: {
            var factor: usize = @intFromFloat(@ceil(value));
            if (factor % 2 != 0) factor += 1;
            break :blk if (factor >= 2 and factor <= max_factor) factor else null;
        },
        else => null,
    };
}

test "CPU tessellation partition rules match Metal factor classes" {
    try std.testing.expectEqual(@as(?usize, 4), partitionTessellationFactor(3.0, cpu_tessellation_partition_pow2, 16));
    try std.testing.expectEqual(@as(?usize, 3), partitionTessellationFactor(2.5, cpu_tessellation_partition_fractional_odd, 16));
    try std.testing.expectEqual(@as(?usize, 4), partitionTessellationFactor(2.5, cpu_tessellation_partition_fractional_even, 16));
    try std.testing.expectEqual(@as(?usize, null), partitionTessellationFactor(2.5, cpu_tessellation_partition_fractional_odd, 2));
    try std.testing.expectEqual(@as(?usize, null), partitionTessellationFactor(1.5, cpu_tessellation_partition_fractional_even, 1));
}

const VisibilitySlot = struct {
    buffer: *Buffer,
    offset: usize,
};

const ColorAttachmentCommand = struct {
    texture: *Texture,
    pass: abi.RenderPassColorAttachmentDescriptor,
    array_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    array_target_count: u8 = 1,
    sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4,
    sample_array_targets: [8][4]?*Texture = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8,
    sample_array_resolve_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    resolve_target: ?*Texture = null,
    resolve_enabled: bool = false,
};

const BeginRenderCommand = struct {
    target: *Texture,
    pass: abi.RenderPassDescriptor,
    color_attachments: [8]?ColorAttachmentCommand = [_]?ColorAttachmentCommand{null} ** 8,
    array_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    array_target_count: u8 = 1,
    sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4,
    sample_array_targets: [8][4]?*Texture = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8,
    sample_array_resolve_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    sample_count: u8 = 1,
    custom_sample_positions: bool = false,
    sample_positions: [4]abi.SamplePosition = .{
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 0.5, .y = 0.5 },
        .{ .x = 0.5, .y = 0.5 },
    },
    resolve_target: ?*Texture = null,
    resolve_enabled: bool = false,
    depth_array_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    stencil_array_targets: [8]?*Texture = [_]?*Texture{null} ** 8,
    depth_sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4,
    stencil_sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4,
    depth_sample_array_targets: [8][4]?*Texture = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8,
    stencil_sample_array_targets: [8][4]?*Texture = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8,
    depth: ?[]f32 = null,
    depth_texture: ?*Texture = null,
    stencil: ?[]u8 = null,
    stencil_texture: ?*Texture = null,
    stencil_load_action: abi.LoadAction = .dont_care,
    stencil_store_action: abi.StoreAction = .dont_care,
    stencil_clear: u8 = 0,
};

const identity_color_attachment_map: [8]u8 = .{ 0, 1, 2, 3, 4, 5, 6, 7 };

fn validColorAttachmentMap(mapping: [8]u8) bool {
    var seen: u8 = 0;
    for (mapping) |physical_index| {
        if (physical_index >= 8) return false;
        const bit = @as(u8, 1) << @intCast(physical_index);
        if ((seen & bit) != 0) return false;
        seen |= bit;
    }
    return true;
}

fn validateColorAttachmentOutputs(active: [8]?*Texture, mapping: [8]u8, logical_output_count: usize) Error!void {
    if (logical_output_count == 0 or logical_output_count > mapping.len or !validColorAttachmentMap(mapping))
        return error.InvalidArgument;
    for (mapping[0..logical_output_count]) |physical_index| {
        if (active[physical_index] == null) return error.InvalidResource;
    }
}

const CopyBufferCommand = struct {
    source: *Buffer,
    source_offset: usize,
    destination: *Buffer,
    destination_offset: usize,
    length: usize,
};

const BufferTextureCommand = struct {
    buffer: *Buffer,
    buffer_offset: usize,
    bytes_per_row: usize,
    texture: *Texture,
    region: abi.Region,
};

const TextureBufferCommand = struct {
    texture: *Texture,
    region: abi.Region,
    buffer: *Buffer,
    buffer_offset: usize,
    bytes_per_row: usize,
};

const TextureTextureCommand = struct {
    source: *Texture,
    source_region: abi.Region,
    destination: *Texture,
    destination_region: abi.Region,
};

const MipmapCommand = struct {
    source: *Texture,
    destination: *Texture,
};

const MipmapChainCommand = struct {
    levels: []const *Texture,
};

const Mipmap3DCommand = struct {
    source0: *Texture,
    source1: ?*Texture,
    destination: *Texture,
    source1_weight_numerator: u32,
    source1_weight_denominator: u32,
};

const Mipmap3DArrayCommand = struct {
    source_planes: []const *Texture,
    destination: *Texture,
};

const FillBufferCommand = struct {
    buffer: *Buffer,
    offset: usize,
    length: usize,
    value: u8,
};

const SparseBufferMappingCommand = struct {
    buffer: *Buffer,
    mode: u8,
    offset: usize,
    length: usize,
};

const SparseBufferCopyMappingCommand = struct {
    source: *Buffer,
    destination: *Buffer,
    source_offset: usize,
    destination_offset: usize,
    length: usize,
};

const SparseTextureMappingCommand = struct {
    texture: *Texture,
    mode: u8,
    region: abi.Region,
};

const SparseTextureCopyMappingCommand = struct {
    source: *Texture,
    destination: *Texture,
    source_region: abi.Region,
    destination_origin: abi.Origin,
};

const SparseTextureMappingIndirectCommand = struct {
    texture: *Texture,
    mode: u8,
    buffer: *Buffer,
    buffer_offset: usize,
};

const SparseTextureMoveMappingCommand = struct {
    source: *Texture,
    destination: *Texture,
    source_region: abi.Region,
    destination_origin: abi.Origin,
};

/// Adapter-private CPU callbacks let the Objective-C compatibility layer
/// preserve command ordering for Metal-shaped operations whose complete
/// resource model lives outside the portable ABI. The callback is still
/// executed by the ZPU CPU command stream; it is never an escape hatch to a
/// native GPU command encoder.
const ExternalCallbackCommand = struct {
    callback: *const fn (?*anyopaque) callconv(.c) c_int,
    context: ?*anyopaque,
};

const SharedEventCommand = struct {
    event: *SharedEvent,
    value: u64,
};

const ComputeCommand = struct {
    kernel: u8,
    source_texture: ?*Texture = null,
    texture: ?*Texture,
    texture_index: u32,
    buffer: ?*Buffer,
    buffer_offset: usize,
    acceleration_structure: ?*Buffer = null,
    acceleration_structure_index: u32 = 0,
    intersection_function_profile: u8 = 0,
    threads_per_grid: abi.Size,
    threads_per_threadgroup: abi.Size = .{ .width = 0, .height = 0, .depth = 0 },
    indirect_buffer: ?*Buffer = null,
    indirect_buffer_offset: usize = 0,
    indirect_threads: bool = false,
    array_slice: ?u32 = null,
};

const ComputeBufferAddCommand = struct {
    kernel: u8,
    elements_per_thread: usize = 1,
    element_stride: usize = 1,
    left: *Buffer,
    left_offset: usize,
    right: *Buffer,
    right_offset: usize,
    output: *Buffer,
    output_offset: usize,
    threads_per_grid: abi.Size,
    threads_per_threadgroup: abi.Size = .{ .width = 0, .height = 0, .depth = 0 },
    indirect_buffer: ?*Buffer = null,
    indirect_buffer_offset: usize = 0,
    indirect_threads: bool = false,
};

const Command = union(enum) {
    begin_render: BeginRenderCommand,
    draw: DrawCommand,
    tile: TileCommand,
    mesh: MeshCommand,
    patch: PatchCommand,
    copy_buffer: CopyBufferCommand,
    copy_buffer_to_texture: BufferTextureCommand,
    copy_texture_to_buffer: TextureBufferCommand,
    copy_texture_to_texture: TextureTextureCommand,
    generate_mipmap: MipmapCommand,
    generate_srgb_mipmap_chain: MipmapChainCommand,
    generate_mipmap_3d: Mipmap3DCommand,
    generate_mipmap_3d_array: Mipmap3DArrayCommand,
    fill_buffer: FillBufferCommand,
    compute: ComputeCommand,
    compute_buffer_add: ComputeBufferAddCommand,
    synchronize_buffer: *Buffer,
    sparse_buffer_mapping: SparseBufferMappingCommand,
    sparse_buffer_copy_mapping: SparseBufferCopyMappingCommand,
    sparse_texture_mapping: SparseTextureMappingCommand,
    sparse_texture_mapping_indirect: SparseTextureMappingIndirectCommand,
    sparse_texture_move_mapping: SparseTextureMoveMappingCommand,
    sparse_texture_copy_mapping: SparseTextureCopyMappingCommand,
    external_callback: ExternalCallbackCommand,
    update_fence: *Fence,
    wait_fence: *Fence,
    signal_event: SharedEventCommand,
    wait_event: SharedEventCommand,
};

pub const CommandBuffer = struct {
    magic: u64 = command_buffer_magic,
    queue: *CommandQueue,
    status: CommandStatus = .created,
    active_encoder: EncoderKind = .none,
    commands: std.ArrayList(Command) = .empty,
    vertices: std.ArrayList(abi.Vertex) = .empty,
    sample_mipmaps: std.ArrayList(*Texture) = .empty,
    owned_mipmap_source_lists: std.ArrayList([]*Texture) = .empty,
    owned_mipmap_chain_lists: std.ArrayList([]*Texture) = .empty,
    owned_compute_buffers: std.ArrayList(*Buffer) = .empty,

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(allocator);
        self.vertices.deinit(allocator);
        self.sample_mipmaps.deinit(allocator);
        for (self.owned_mipmap_source_lists.items) |sources| allocator.free(sources);
        self.owned_mipmap_source_lists.deinit(allocator);
        for (self.owned_mipmap_chain_lists.items) |levels| allocator.free(levels);
        self.owned_mipmap_chain_lists.deinit(allocator);
        for (self.owned_compute_buffers.items) |buffer| destroyBuffer(buffer);
        self.owned_compute_buffers.deinit(allocator);
        self.magic = 0;
    }

    fn begin(self: *CommandBuffer, kind: EncoderKind) Error!void {
        if (self.magic != command_buffer_magic or self.status != .created or self.active_encoder != .none) return error.InvalidCommand;
        self.active_encoder = kind;
    }

    fn end(self: *CommandBuffer, kind: EncoderKind) Error!void {
        if (self.magic != command_buffer_magic or self.active_encoder != kind) return error.InvalidCommand;
        self.active_encoder = .none;
    }

    fn append(self: *CommandBuffer, command: Command) Error!usize {
        if (self.magic != command_buffer_magic or self.status != .created) return error.InvalidCommand;
        self.commands.append(allocator, command) catch return error.OutOfMemory;
        return self.commands.items.len - 1;
    }

    fn appendMipmap3DArray(self: *CommandBuffer, sources: []const *Texture, destination: *Texture) Error!void {
        if (sources.len == 0) return error.InvalidArgument;
        const owned = allocator.alloc(*Texture, sources.len) catch return error.OutOfMemory;
        @memcpy(owned, sources);
        self.owned_mipmap_source_lists.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
        _ = self.append(.{ .generate_mipmap_3d_array = .{
            .source_planes = owned,
            .destination = destination,
        } }) catch |err| {
            self.owned_mipmap_source_lists.items.len -= 1;
            allocator.free(owned);
            return err;
        };
    }

    fn appendSrgbMipmapChain(self: *CommandBuffer, levels: []const *Texture) Error!void {
        if (levels.len < 2) return error.InvalidArgument;
        const owned = allocator.alloc(*Texture, levels.len) catch return error.OutOfMemory;
        @memcpy(owned, levels);
        self.owned_mipmap_chain_lists.append(allocator, owned) catch {
            allocator.free(owned);
            return error.OutOfMemory;
        };
        _ = self.append(.{ .generate_srgb_mipmap_chain = .{ .levels = owned } }) catch |err| {
            self.owned_mipmap_chain_lists.items.len -= 1;
            allocator.free(owned);
            return err;
        };
    }

    fn appendVertices(self: *CommandBuffer, values: []const abi.Vertex) Error!usize {
        const start = self.vertices.items.len;
        self.vertices.appendSlice(allocator, values) catch return error.OutOfMemory;
        return start;
    }

    fn resolveDrawVertices(self: *CommandBuffer, draw: DrawCommand, owned_source: *?[]abi.Vertex, owned_indexed: *?[]abi.Vertex) Error![]const abi.Vertex {
        const source = if (draw.vertex_buffer) |buffer|
            try bufferVertices(buffer, draw.vertex_buffer_offset, draw.vertex_stride, owned_source)
        else if (draw.vertex_source_count != 0 or draw.index_buffer != null) blk: {
            if (draw.vertex_start > self.vertices.items.len or
                draw.vertex_source_count > self.vertices.items.len - draw.vertex_start)
                return error.InvalidCommand;
            break :blk self.vertices.items[draw.vertex_start .. draw.vertex_start + draw.vertex_source_count];
        } else self.vertices.items;
        if (draw.index_buffer) |index_buffer| {
            if (!validBuffer(index_buffer) or index_buffer.device != self.queue.device) return error.InvalidResource;
            const index_size: usize = if (draw.index_type == .uint16) 2 else 4;
            const index_bytes = std.math.mul(usize, draw.vertex_count, index_size) catch return error.InvalidArgument;
            if (!rangeValid(index_buffer.bytes.len, draw.index_buffer_offset, index_bytes)) return error.InvalidArgument;
            const result = allocator.alloc(abi.Vertex, draw.vertex_count) catch return error.OutOfMemory;
            owned_indexed.* = result;
            for (0..draw.vertex_count) |index| {
                const offset = draw.index_buffer_offset + index * index_size;
                const value: usize = if (draw.index_type == .uint16)
                    @as(usize, index_buffer.bytes[offset]) | (@as(usize, index_buffer.bytes[offset + 1]) << 8)
                else
                    @as(usize, index_buffer.bytes[offset]) |
                        (@as(usize, index_buffer.bytes[offset + 1]) << 8) |
                        (@as(usize, index_buffer.bytes[offset + 2]) << 16) |
                        (@as(usize, index_buffer.bytes[offset + 3]) << 24);
                const signed_value = @as(i128, @intCast(value)) + @as(i128, draw.base_vertex);
                if (signed_value < 0 or signed_value >= @as(i128, @intCast(source.len))) return error.InvalidArgument;
                result[index] = source[@intCast(signed_value)];
            }
            return result;
        }
        if (draw.vertex_start > source.len or draw.vertex_count > source.len - draw.vertex_start) return error.InvalidCommand;
        return source[draw.vertex_start .. draw.vertex_start + draw.vertex_count];
    }

    fn resolvePatchVertices(self: *CommandBuffer, patch: PatchCommand, owned: *?[]abi.Vertex) Error![]const abi.Vertex {
        if (patch.vertex_buffer) |buffer| {
            return bufferVertices(buffer, patch.vertex_buffer_offset, patch.vertex_stride, owned);
        }
        if (patch.inline_vertex_start > self.vertices.items.len or
            patch.inline_vertex_count > self.vertices.items.len - patch.inline_vertex_start)
            return error.InvalidCommand;
        return self.vertices.items[patch.inline_vertex_start .. patch.inline_vertex_start + patch.inline_vertex_count];
    }

    fn resolveIndirectDraw(self: *CommandBuffer, draw: *DrawCommand) Error!usize {
        const indirect_buffer = draw.indirect_buffer orelse return 1;
        if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.queue.device) return error.InvalidResource;
        const indexed = draw.index_buffer != null;
        const argument_size: usize = if (indexed) 20 else 16;
        if (!rangeValid(indirect_buffer.bytes.len, draw.indirect_buffer_offset, argument_size)) return error.InvalidArgument;
        const offset = draw.indirect_buffer_offset;
        const instance_count = readU32Little(indirect_buffer.bytes, offset + 4);
        const base_instance_offset: usize = if (indexed) 16 else 12;
        draw.base_instance = readU32Little(indirect_buffer.bytes, offset + base_instance_offset);
        draw.vertex_count = readU32Little(indirect_buffer.bytes, offset);
        draw.vertex_start = readU32Little(indirect_buffer.bytes, offset + 8);
        if (indexed) {
            const index_size: usize = if (draw.index_type == .uint16) 2 else 4;
            const index_start_bytes = std.math.mul(usize, @as(usize, readU32Little(indirect_buffer.bytes, offset + 8)), index_size) catch return error.InvalidArgument;
            draw.index_buffer_offset = std.math.add(usize, draw.index_buffer_offset, index_start_bytes) catch return error.InvalidArgument;
            draw.base_vertex = @as(i64, @intCast(@as(i32, @bitCast(readU32Little(indirect_buffer.bytes, offset + 12)))));
            draw.vertex_start = 0;
        }
        return instance_count;
    }

    pub fn commit(self: *CommandBuffer) Error!void {
        if (self.magic != command_buffer_magic or self.status != .created or self.active_encoder != .none) return error.InvalidCommand;
        self.status = .committed;
        var active_target: ?*Texture = null;
        var active_color_attachments: [8]?*Texture = [_]?*Texture{null} ** 8;
        var active_array_color_attachments: [8][8]?*Texture = undefined;
        for (&active_array_color_attachments) |*layers| @memset(layers, null);
        var active_array_target_count: usize = 1;
        var active_sample_color_attachments: [32]?*Texture = [_]?*Texture{null} ** 32;
        var active_sample_array_color_attachments: [8][8][4]?*Texture = undefined;
        for (&active_sample_array_color_attachments) |*attachments| {
            for (attachments) |*layers| @memset(layers, null);
        }
        var active_sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4;
        var active_sample_count: usize = 1;
        var active_custom_sample_positions = false;
        var active_sample_positions: [4]abi.SamplePosition = .{
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
        };
        var active_resolve_targets: [8]?*Texture = [_]?*Texture{null} ** 8;
        var active_sample_array_resolve_targets: [8][8]?*Texture = undefined;
        for (&active_sample_array_resolve_targets) |*attachments| @memset(attachments, null);
        var active_depth_sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4;
        var active_stencil_sample_targets: [4]?*Texture = [_]?*Texture{null} ** 4;
        var active_depth_sample_array_targets: [8][4]?*Texture = undefined;
        var active_stencil_sample_array_targets: [8][4]?*Texture = undefined;
        for (&active_depth_sample_array_targets) |*layer_targets| @memset(layer_targets, null);
        for (&active_stencil_sample_array_targets) |*layer_targets| @memset(layer_targets, null);
        var active_depth_array_targets: [8]?*Texture = [_]?*Texture{null} ** 8;
        var active_stencil_array_targets: [8]?*Texture = [_]?*Texture{null} ** 8;
        var active_depth: ?[]f32 = null;
        var active_depth_texture: ?*Texture = null;
        var active_depth_values: ?[]f32 = null;
        var active_depth_array_values: [8]?[]f32 = [_]?[]f32{null} ** 8;
        var active_depth_sample_array_values: [8]?[]f32 = [_]?[]f32{null} ** 8;
        var active_depth_store_action: abi.StoreAction = .dont_care;
        var active_stencil: ?[]u8 = null;
        var active_stencil_texture: ?*Texture = null;
        var active_stencil_values: ?[]u8 = null;
        var active_stencil_array_values: [8]?[]u8 = [_]?[]u8{null} ** 8;
        var active_stencil_sample_array_values: [8]?[]u8 = [_]?[]u8{null} ** 8;
        var active_stencil_store_action: abi.StoreAction = .dont_care;
        var reset_visibility_slots: std.ArrayList(VisibilitySlot) = .empty;
        defer reset_visibility_slots.deinit(allocator);
        defer if (active_depth_values) |values| {
            if (active_depth_store_action == .store) {
                if (active_sample_count == 1) {
                    storeDepthTexture(active_depth_texture.?, values);
                } else {
                    storeDepthSampleTextures(active_depth_sample_targets, active_sample_count, values);
                }
            }
            allocator.free(values);
        };
        defer for (0..active_depth_array_values.len) |layer| {
            if (active_depth_array_values[layer]) |values| {
                if (active_depth_store_action == .store) {
                    storeDepthTexture(active_depth_array_targets[layer].?, values);
                }
                allocator.free(values);
            }
        };
        defer {
            if (active_depth_store_action == .store) {
                storeDepthSampleArrayTextures(
                    active_depth_sample_array_targets,
                    active_array_target_count,
                    active_sample_count,
                    active_depth_sample_array_values,
                );
            }
            for (active_depth_sample_array_values) |values| {
                if (values) |owned| allocator.free(owned);
            }
        }
        defer if (active_stencil_values) |values| {
            if (active_stencil_store_action == .store) {
                if (active_sample_count == 1) {
                    storeStencilTexture(active_stencil_texture.?, values);
                } else {
                    storeStencilSampleTextures(active_stencil_sample_targets, active_sample_count, values);
                }
            }
            allocator.free(values);
        };
        defer for (0..active_stencil_array_values.len) |layer| {
            if (active_stencil_array_values[layer]) |values| {
                if (active_stencil_store_action == .store) {
                    storeStencilTexture(active_stencil_array_targets[layer].?, values);
                }
                allocator.free(values);
            }
        };
        defer {
            if (active_stencil_store_action == .store) {
                storeStencilSampleArrayTextures(
                    active_stencil_sample_array_targets,
                    active_array_target_count,
                    active_sample_count,
                    active_stencil_sample_array_values,
                );
            }
            for (active_stencil_sample_array_values) |values| {
                if (values) |owned| allocator.free(owned);
            }
        }

        for (self.commands.items) |command| switch (command) {
            .begin_render => |begin_render| {
                if (!validTexture(begin_render.target)) return self.fail(error.InvalidResource);
                if (begin_render.sample_count != 1 and begin_render.sample_count != 2 and begin_render.sample_count != 4)
                    return self.fail(error.InvalidArgument);
                if (begin_render.array_target_count == 0 or begin_render.array_target_count > 8)
                    return self.fail(error.InvalidArgument);
                if (begin_render.sample_count == 1) {
                    for (begin_render.array_targets[0..begin_render.array_target_count], 0..) |target, layer| {
                        const texture = target orelse return self.fail(error.InvalidResource);
                        if (!validTexture(texture) or texture.device != self.queue.device or !texture.format.isColor() or
                            texture.width != begin_render.target.width or texture.height != begin_render.target.height or
                            texture.format != begin_render.target.format or (layer == 0 and texture != begin_render.target))
                            return self.fail(error.InvalidResource);
                    }
                }
                if (begin_render.array_target_count > 1 and
                    (begin_render.depth != null or begin_render.stencil != null or
                        begin_render.depth_texture != null or begin_render.stencil_texture != null or
                        begin_render.depth_sample_targets[0] != null or begin_render.stencil_sample_targets[0] != null))
                    return self.fail(error.UnsupportedOperation);
                if (begin_render.sample_count > 1 and (begin_render.depth != null or begin_render.stencil != null))
                    return self.fail(error.UnsupportedOperation);
                if (begin_render.sample_count > 1) {
                    const layered_samples = begin_render.sample_array_targets[0][0] != null;
                    const layered_depth_samples = begin_render.depth_sample_array_targets[0][0] != null;
                    const layered_stencil_samples = begin_render.stencil_sample_array_targets[0][0] != null;
                    if (begin_render.depth_array_targets[0] != null or begin_render.stencil_array_targets[0] != null)
                        return self.fail(error.UnsupportedOperation);
                    if (layered_samples) {
                        for (begin_render.sample_array_targets[0..begin_render.array_target_count], 0..) |layer_targets, layer| {
                            for (layer_targets[0..begin_render.sample_count], 0..) |sample, sample_index| {
                                const texture = sample orelse return self.fail(error.InvalidResource);
                                if (!validTexture(texture) or texture.device != self.queue.device or !texture.format.isColor() or
                                    texture.width != begin_render.target.width or texture.height != begin_render.target.height or
                                    texture.format != begin_render.target.format or
                                    (layer == 0 and sample_index == 0 and texture != begin_render.target))
                                    return self.fail(error.InvalidResource);
                            }
                        }
                        if (begin_render.resolve_enabled) {
                            for (begin_render.sample_array_resolve_targets[0..begin_render.array_target_count]) |resolve| {
                                const texture = resolve orelse return self.fail(error.InvalidResource);
                                if (!validTexture(texture) or texture.device != self.queue.device or
                                    !texture.format.isColor() or texture.width != begin_render.target.width or
                                    texture.height != begin_render.target.height or texture.format != begin_render.target.format)
                                    return self.fail(error.InvalidResource);
                            }
                        }
                    } else {
                        if (layered_depth_samples or layered_stencil_samples)
                            return self.fail(error.InvalidArgument);
                        for (begin_render.sample_targets[0..begin_render.sample_count]) |sample| {
                            const texture = sample orelse return self.fail(error.InvalidResource);
                            if (!validTexture(texture) or texture.device != self.queue.device or !texture.format.isColor() or
                                texture.width != begin_render.target.width or texture.height != begin_render.target.height or
                                texture.format != begin_render.target.format) return self.fail(error.InvalidResource);
                        }
                    }
                    for (begin_render.color_attachments[1..], 1..) |attachment, index| {
                        if (attachment) |value| {
                            if (layered_samples) {
                                if (value.array_target_count != begin_render.array_target_count)
                                    return self.fail(error.InvalidArgument);
                                for (value.sample_array_targets[0..begin_render.array_target_count], 0..) |layer_targets, layer| {
                                    for (layer_targets[0..begin_render.sample_count], 0..) |sample, sample_index| {
                                        const texture = sample orelse return self.fail(error.InvalidResource);
                                        if (!validTexture(texture) or texture.device != self.queue.device or
                                            !texture.format.isColor() or texture.width != begin_render.target.width or
                                            texture.height != begin_render.target.height or texture.format != value.texture.format or
                                            (layer == 0 and sample_index == 0 and texture != value.texture))
                                            return self.fail(error.InvalidResource);
                                    }
                                }
                            } else {
                                for (value.sample_targets[0..begin_render.sample_count], 0..) |sample, sample_index| {
                                    const texture = sample orelse return self.fail(error.InvalidResource);
                                    if (!validTexture(texture) or texture.device != self.queue.device or
                                        !texture.format.isColor() or texture.width != begin_render.target.width or
                                        texture.height != begin_render.target.height or
                                        (sample_index == 0 and texture != value.texture))
                                        return self.fail(error.InvalidResource);
                                }
                            }
                            if (value.resolve_enabled) {
                                if (layered_samples) {
                                    for (value.sample_array_resolve_targets[0..begin_render.array_target_count], 0..) |resolve, layer| {
                                        const resolve_texture = resolve orelse return self.fail(error.InvalidResource);
                                        if (!validTexture(resolve_texture) or resolve_texture.device != self.queue.device or
                                            !resolve_texture.format.isColor() or resolve_texture.width != begin_render.target.width or
                                            resolve_texture.height != begin_render.target.height or
                                            resolve_texture.format != value.texture.format)
                                            return self.fail(error.InvalidResource);
                                        for (value.sample_array_targets[layer][0..begin_render.sample_count]) |sample| {
                                            if (sample.? == resolve_texture) return self.fail(error.InvalidArgument);
                                        }
                                    }
                                } else {
                                    const resolve = value.resolve_target orelse return self.fail(error.InvalidResource);
                                    if (!validTexture(resolve) or resolve.device != self.queue.device or
                                        !resolve.format.isColor() or resolve.width != begin_render.target.width or
                                        resolve.height != begin_render.target.height or resolve.format != value.texture.format)
                                        return self.fail(error.InvalidResource);
                                    for (value.sample_targets[0..begin_render.sample_count]) |sample| {
                                        if (sample.? == resolve) return self.fail(error.InvalidArgument);
                                    }
                                }
                            }
                        } else if (index != 0 and begin_render.color_attachments[index] != null) {
                            return self.fail(error.InvalidResource);
                        }
                    }
                    if (layered_depth_samples) {
                        for (begin_render.depth_sample_array_targets[0..begin_render.array_target_count]) |layer_targets| {
                            for (layer_targets[0..begin_render.sample_count]) |depth| {
                                const texture = depth orelse return self.fail(error.InvalidResource);
                                if (!validTexture(texture) or texture.device != self.queue.device or
                                    !isDepthTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                    texture.height != begin_render.target.height)
                                    return self.fail(error.InvalidResource);
                            }
                        }
                        if (begin_render.depth_sample_targets[0] != null or begin_render.depth_array_targets[0] != null)
                            return self.fail(error.InvalidArgument);
                    } else for (begin_render.depth_sample_targets[0..begin_render.sample_count]) |depth| {
                        if (depth) |texture| {
                            if (!validTexture(texture) or texture.device != self.queue.device or
                                !isDepthTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                texture.height != begin_render.target.height) return self.fail(error.InvalidResource);
                        }
                    }
                    if (layered_stencil_samples) {
                        for (begin_render.stencil_sample_array_targets[0..begin_render.array_target_count]) |layer_targets| {
                            for (layer_targets[0..begin_render.sample_count]) |stencil| {
                                const texture = stencil orelse return self.fail(error.InvalidResource);
                                if (!validTexture(texture) or texture.device != self.queue.device or
                                    !isStencilTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                    texture.height != begin_render.target.height)
                                    return self.fail(error.InvalidResource);
                            }
                        }
                        if (begin_render.stencil_sample_targets[0] != null or begin_render.stencil_array_targets[0] != null)
                            return self.fail(error.InvalidArgument);
                    } else for (begin_render.stencil_sample_targets[0..begin_render.sample_count]) |stencil| {
                        if (stencil) |texture| {
                            if (!validTexture(texture) or texture.device != self.queue.device or
                                !isStencilTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                texture.height != begin_render.target.height) return self.fail(error.InvalidResource);
                        }
                    }
                    if (begin_render.depth_texture != null and begin_render.depth_sample_targets[0] == null and !layered_depth_samples)
                        return self.fail(error.InvalidResource);
                    if (begin_render.stencil_texture != null and begin_render.stencil_sample_targets[0] == null and !layered_stencil_samples)
                        return self.fail(error.InvalidResource);
                } else if (begin_render.resolve_target != null) return self.fail(error.InvalidArgument);
                if (begin_render.sample_count == 1 and begin_render.array_target_count > 1) {
                    var has_depth_array = false;
                    var has_stencil_array = false;
                    for (begin_render.depth_array_targets[0..begin_render.array_target_count]) |target| {
                        if (target != null) has_depth_array = true;
                    }
                    for (begin_render.stencil_array_targets[0..begin_render.array_target_count]) |target| {
                        if (target != null) has_stencil_array = true;
                    }
                    for (begin_render.depth_array_targets[0..begin_render.array_target_count]) |target| {
                        if (has_depth_array) {
                            const texture = target orelse return self.fail(error.InvalidResource);
                            if (!validTexture(texture) or texture.device != self.queue.device or
                                !isDepthTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                texture.height != begin_render.target.height)
                                return self.fail(error.InvalidResource);
                        }
                    }
                    for (begin_render.stencil_array_targets[0..begin_render.array_target_count]) |target| {
                        if (has_stencil_array) {
                            const texture = target orelse return self.fail(error.InvalidResource);
                            if (!validTexture(texture) or texture.device != self.queue.device or
                                !isStencilTextureFormat(texture.format) or texture.width != begin_render.target.width or
                                texture.height != begin_render.target.height)
                                return self.fail(error.InvalidResource);
                        }
                    }
                    for (begin_render.color_attachments[1..], 1..) |attachment, index| {
                        if (attachment) |value| {
                            if (value.array_target_count != begin_render.array_target_count)
                                return self.fail(error.InvalidArgument);
                            for (value.array_targets[0..begin_render.array_target_count], 0..) |target, layer| {
                                const texture = target orelse return self.fail(error.InvalidResource);
                                if (!validTexture(texture) or texture.device != self.queue.device or
                                    !texture.format.isColor() or texture.width != begin_render.target.width or
                                    texture.height != begin_render.target.height or texture.format != value.texture.format or
                                    (layer == 0 and texture != value.texture))
                                    return self.fail(error.InvalidResource);
                            }
                            if (value.resolve_enabled) return self.fail(error.UnsupportedOperation);
                        } else if (index != 0 and begin_render.color_attachments[index] != null) {
                            return self.fail(error.InvalidResource);
                        }
                    }
                }
                resolveMultisampleColorAttachments(
                    active_sample_targets,
                    active_sample_color_attachments,
                    active_sample_count,
                    active_resolve_targets,
                ) catch |err| return self.fail(err);
                resolveMultisampleColorAttachmentArrays(
                    active_sample_array_color_attachments,
                    active_array_target_count,
                    active_sample_count,
                    active_sample_array_resolve_targets,
                ) catch |err| return self.fail(err);
                sparseFlushOptionalTexture(active_target);
                for (active_color_attachments) |attachment| sparseFlushOptionalTexture(attachment);
                for (active_array_color_attachments) |attachment_layers| {
                    for (attachment_layers[0..active_array_target_count]) |attachment| sparseFlushOptionalTexture(attachment);
                }
                for (active_sample_targets[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                for (active_sample_color_attachments) |sample| sparseFlushOptionalTexture(sample);
                for (active_sample_array_color_attachments) |attachment_layers| {
                    for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                        for (layer_samples[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                    }
                }
                for (active_depth_sample_array_targets[0..active_array_target_count]) |layer_samples| {
                    for (layer_samples[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                }
                for (active_stencil_sample_array_targets[0..active_array_target_count]) |layer_samples| {
                    for (layer_samples[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                }
                if (active_depth_values) |values| {
                    if (active_depth_store_action == .store) {
                        if (active_sample_count == 1) {
                            storeDepthTexture(active_depth_texture.?, values);
                        } else {
                            storeDepthSampleTextures(active_depth_sample_targets, active_sample_count, values);
                        }
                    }
                    allocator.free(values);
                    active_depth_values = null;
                }
                for (0..active_depth_array_values.len) |layer| {
                    if (active_depth_array_values[layer]) |values| {
                        if (active_depth_store_action == .store) {
                            storeDepthTexture(active_depth_array_targets[layer].?, values);
                        }
                        allocator.free(values);
                        active_depth_array_values[layer] = null;
                    }
                }
                if (active_depth_store_action == .store) {
                    storeDepthSampleArrayTextures(
                        active_depth_sample_array_targets,
                        active_array_target_count,
                        active_sample_count,
                        active_depth_sample_array_values,
                    );
                }
                for (0..active_depth_sample_array_values.len) |layer| {
                    if (active_depth_sample_array_values[layer]) |values| {
                        allocator.free(values);
                        active_depth_sample_array_values[layer] = null;
                    }
                }
                if (active_stencil_values) |values| {
                    if (active_stencil_store_action == .store) {
                        if (active_sample_count == 1) {
                            storeStencilTexture(active_stencil_texture.?, values);
                        } else {
                            storeStencilSampleTextures(active_stencil_sample_targets, active_sample_count, values);
                        }
                    }
                    allocator.free(values);
                    active_stencil_values = null;
                }
                for (0..active_stencil_array_values.len) |layer| {
                    if (active_stencil_array_values[layer]) |values| {
                        if (active_stencil_store_action == .store) {
                            storeStencilTexture(active_stencil_array_targets[layer].?, values);
                        }
                        allocator.free(values);
                        active_stencil_array_values[layer] = null;
                    }
                }
                if (active_stencil_store_action == .store) {
                    storeStencilSampleArrayTextures(
                        active_stencil_sample_array_targets,
                        active_array_target_count,
                        active_sample_count,
                        active_stencil_sample_array_values,
                    );
                }
                for (0..active_stencil_sample_array_values.len) |layer| {
                    if (active_stencil_sample_array_values[layer]) |values| {
                        allocator.free(values);
                        active_stencil_sample_array_values[layer] = null;
                    }
                }
                reset_visibility_slots.clearRetainingCapacity();
                active_color_attachments = [_]?*Texture{null} ** 8;
                for (&active_array_color_attachments) |*layers| @memset(layers, null);
                active_sample_color_attachments = [_]?*Texture{null} ** 32;
                for (&active_sample_array_color_attachments) |*attachments| {
                    for (attachments) |*layers| @memset(layers, null);
                }
                active_target = begin_render.target;
                active_color_attachments[0] = begin_render.target;
                active_array_target_count = begin_render.array_target_count;
                for (begin_render.array_targets[0..active_array_target_count], 0..) |target, layer| {
                    active_array_color_attachments[0][layer] = target;
                }
                active_sample_targets = [_]?*Texture{null} ** 4;
                active_sample_count = begin_render.sample_count;
                active_custom_sample_positions = begin_render.custom_sample_positions;
                active_sample_positions = begin_render.sample_positions;
                active_resolve_targets = [_]?*Texture{null} ** 8;
                const layered_samples = active_sample_count > 1 and begin_render.sample_array_targets[0][0] != null;
                active_resolve_targets[0] = if (!layered_samples and begin_render.resolve_enabled) begin_render.resolve_target else null;
                for (&active_sample_array_resolve_targets) |*attachments| @memset(attachments, null);
                active_depth_sample_targets = begin_render.depth_sample_targets;
                active_stencil_sample_targets = begin_render.stencil_sample_targets;
                active_depth_array_targets = begin_render.depth_array_targets;
                active_stencil_array_targets = begin_render.stencil_array_targets;
                active_depth_array_values = [_]?[]f32{null} ** 8;
                active_stencil_array_values = [_]?[]u8{null} ** 8;
                for (&active_depth_sample_array_targets) |*layer_targets| @memset(layer_targets, null);
                for (&active_stencil_sample_array_targets) |*layer_targets| @memset(layer_targets, null);
                active_depth_sample_array_values = [_]?[]f32{null} ** 8;
                active_stencil_sample_array_values = [_]?[]u8{null} ** 8;
                for (begin_render.depth_sample_array_targets[0..active_array_target_count], 0..) |layer_targets, layer| {
                    active_depth_sample_array_targets[layer] = layer_targets;
                }
                for (begin_render.stencil_sample_array_targets[0..active_array_target_count], 0..) |layer_targets, layer| {
                    active_stencil_sample_array_targets[layer] = layer_targets;
                }
                if (active_sample_count == 1) {
                    active_sample_targets[0] = begin_render.target;
                    sparseSyncTexture(begin_render.target);
                } else {
                    if (begin_render.sample_array_targets[0][0] != null) {
                        for (begin_render.sample_array_targets[0..active_array_target_count], 0..) |layer_samples, layer| {
                            for (layer_samples[0..active_sample_count], 0..) |sample, sample_index| {
                                active_sample_array_color_attachments[0][layer][sample_index] = sample;
                                active_array_color_attachments[0][layer] = layer_samples[0];
                                if (layer == 0) {
                                    active_sample_targets[sample_index] = sample;
                                    active_sample_color_attachments[sample_index] = sample;
                                }
                                sparseSyncTexture(sample.?);
                            }
                        }
                        for (begin_render.sample_array_resolve_targets[0..active_array_target_count], 0..) |resolve, layer| {
                            active_sample_array_resolve_targets[0][layer] = resolve;
                        }
                    } else {
                        for (begin_render.sample_targets[0..active_sample_count], 0..) |sample, index| {
                            active_sample_targets[index] = sample;
                            active_sample_color_attachments[index] = sample;
                            sparseSyncTexture(sample.?);
                        }
                    }
                }
                for (begin_render.color_attachments, 0..) |attachment, index| {
                    if (attachment) |value| {
                        if (!validTexture(value.texture) or value.texture.device != self.queue.device or
                            !value.texture.format.isColor() or value.texture.width != begin_render.target.width or
                            value.texture.height != begin_render.target.height) return self.fail(error.InvalidResource);
                        active_color_attachments[index] = value.texture;
                        if (active_sample_count == 1) {
                            const array_targets = if (index == 0)
                                begin_render.array_targets[0..active_array_target_count]
                            else
                                value.array_targets[0..active_array_target_count];
                            for (array_targets, 0..) |target, layer| {
                                const array_target = if (active_array_target_count == 1 and target == null)
                                    value.texture
                                else
                                    target orelse return self.fail(error.InvalidResource);
                                active_array_color_attachments[index][layer] = array_target;
                                sparseSyncTexture(array_target);
                            }
                        } else if (index != 0) {
                            if (begin_render.sample_array_targets[0][0] != null) {
                                for (value.sample_array_targets[0..active_array_target_count], 0..) |layer_samples, layer| {
                                    for (layer_samples[0..active_sample_count], 0..) |sample, sample_index| {
                                        const sample_texture = sample orelse return self.fail(error.InvalidResource);
                                        active_sample_array_color_attachments[index][layer][sample_index] = sample_texture;
                                        if (sample_index == 0) active_array_color_attachments[index][layer] = sample_texture;
                                        if (layer == 0) active_sample_color_attachments[index * 4 + sample_index] = sample_texture;
                                        sparseSyncTexture(sample_texture);
                                    }
                                }
                                for (value.sample_array_resolve_targets[0..active_array_target_count], 0..) |resolve, layer| {
                                    active_sample_array_resolve_targets[index][layer] = resolve;
                                }
                            } else {
                                for (value.sample_targets[0..active_sample_count], 0..) |sample, sample_index| {
                                    const sample_texture = sample orelse return self.fail(error.InvalidResource);
                                    active_sample_color_attachments[index * 4 + sample_index] = sample_texture;
                                    sparseSyncTexture(sample_texture);
                                }
                            }
                            active_resolve_targets[index] = if (!layered_samples and value.resolve_enabled) value.resolve_target else null;
                        }
                        if (value.pass.load_action == .clear) {
                            if (active_sample_count == 1) {
                                for (active_array_color_attachments[index][0..active_array_target_count]) |array_attachment| {
                                    var attachment_target = (array_attachment orelse return self.fail(error.InvalidResource)).asTarget();
                                    raster3d.clearTarget(&attachment_target, toTargetColor(value.pass.clear_color));
                                }
                            } else if (layered_samples) {
                                for (active_sample_array_color_attachments[index][0..active_array_target_count]) |layer_samples| {
                                    for (layer_samples[0..active_sample_count]) |sample| {
                                        var attachment_target = (sample orelse return self.fail(error.InvalidResource)).asTarget();
                                        raster3d.clearTarget(&attachment_target, toTargetColor(value.pass.clear_color));
                                    }
                                }
                            } else {
                                for (0..active_sample_count) |sample_index| {
                                    const sample = if (index == 0)
                                        active_sample_targets[sample_index].?
                                    else
                                        active_sample_color_attachments[index * 4 + sample_index].?;
                                    var attachment_target = sample.asTarget();
                                    raster3d.clearTarget(&attachment_target, toTargetColor(value.pass.clear_color));
                                }
                            }
                        }
                    }
                }
                active_depth_texture = begin_render.depth_texture;
                active_depth_store_action = begin_render.pass.depth.store_action;
                active_depth = begin_render.depth;
                if (active_array_target_count > 1 and begin_render.depth_array_targets[0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    for (begin_render.depth_array_targets[0..active_array_target_count], 0..) |depth_texture, layer| {
                        const texture = depth_texture orelse return self.fail(error.InvalidResource);
                        const values = allocator.alloc(f32, pixel_count) catch return self.fail(error.OutOfMemory);
                        active_depth_array_values[layer] = values;
                        for (values, 0..) |*value, index| value.* = depthTextureValue(texture, index);
                    }
                    active_depth = null;
                    active_depth_texture = null;
                } else if (active_sample_count > 1 and begin_render.depth_sample_array_targets[0][0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    const value_count = std.math.mul(usize, pixel_count, active_sample_count) catch return self.fail(error.InvalidArgument);
                    for (begin_render.depth_sample_array_targets[0..active_array_target_count], 0..) |layer_targets, layer| {
                        const values = allocator.alloc(f32, value_count) catch return self.fail(error.OutOfMemory);
                        active_depth_sample_array_values[layer] = values;
                        for (layer_targets[0..active_sample_count], 0..) |depth_texture, sample_index| {
                            const texture = depth_texture orelse return self.fail(error.InvalidResource);
                            const sample_values = values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            for (sample_values, 0..) |*value, index| value.* = depthTextureValue(texture, index);
                        }
                    }
                    active_depth = null;
                    active_depth_texture = null;
                } else if (active_sample_count > 1 and begin_render.depth_sample_targets[0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    const value_count = std.math.mul(usize, pixel_count, active_sample_count) catch return self.fail(error.InvalidArgument);
                    const values = allocator.alloc(f32, value_count) catch return self.fail(error.OutOfMemory);
                    active_depth_values = values;
                    for (begin_render.depth_sample_targets[0..active_sample_count], 0..) |depth_texture, sample_index| {
                        const texture = depth_texture orelse return self.fail(error.InvalidResource);
                        const sample_values = values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                        for (sample_values, 0..) |*value, index| value.* = depthTextureValue(texture, index);
                    }
                    active_depth = null;
                } else if (begin_render.depth_texture) |depth_texture| {
                    if (!validTexture(depth_texture) or depth_texture.device != self.queue.device or
                        !isDepthTextureFormat(depth_texture.format) or depth_texture.width != begin_render.target.width or
                        depth_texture.height != begin_render.target.height) return self.fail(error.InvalidResource);
                    const pixel_count = std.math.mul(usize, depth_texture.width, depth_texture.height) catch return self.fail(error.InvalidArgument);
                    const values = allocator.alloc(f32, pixel_count) catch return self.fail(error.OutOfMemory);
                    active_depth_values = values;
                    for (values, 0..) |*value, index| {
                        value.* = depthTextureValue(depth_texture, index);
                    }
                    active_depth = values;
                }
                active_stencil = begin_render.stencil;
                active_stencil_texture = begin_render.stencil_texture;
                active_stencil_store_action = begin_render.stencil_store_action;
                if (active_array_target_count > 1 and begin_render.stencil_array_targets[0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    for (begin_render.stencil_array_targets[0..active_array_target_count], 0..) |stencil_texture, layer| {
                        const texture = stencil_texture orelse return self.fail(error.InvalidResource);
                        const values = allocator.alloc(u8, pixel_count) catch return self.fail(error.OutOfMemory);
                        active_stencil_array_values[layer] = values;
                        for (values, 0..) |*value, index| value.* = stencilTextureValue(texture, index);
                    }
                    active_stencil = null;
                    active_stencil_texture = null;
                } else if (active_sample_count > 1 and begin_render.stencil_sample_array_targets[0][0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    const value_count = std.math.mul(usize, pixel_count, active_sample_count) catch return self.fail(error.InvalidArgument);
                    for (begin_render.stencil_sample_array_targets[0..active_array_target_count], 0..) |layer_targets, layer| {
                        const values = allocator.alloc(u8, value_count) catch return self.fail(error.OutOfMemory);
                        active_stencil_sample_array_values[layer] = values;
                        for (layer_targets[0..active_sample_count], 0..) |stencil_texture, sample_index| {
                            const texture = stencil_texture orelse return self.fail(error.InvalidResource);
                            const sample_values = values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            for (sample_values, 0..) |*value, index| value.* = stencilTextureValue(texture, index);
                        }
                    }
                    active_stencil = null;
                    active_stencil_texture = null;
                } else if (active_sample_count > 1 and begin_render.stencil_sample_targets[0] != null) {
                    const pixel_count = std.math.mul(usize, begin_render.target.width, begin_render.target.height) catch return self.fail(error.InvalidArgument);
                    const value_count = std.math.mul(usize, pixel_count, active_sample_count) catch return self.fail(error.InvalidArgument);
                    const values = allocator.alloc(u8, value_count) catch return self.fail(error.OutOfMemory);
                    active_stencil_values = values;
                    for (begin_render.stencil_sample_targets[0..active_sample_count], 0..) |stencil_texture, sample_index| {
                        const texture = stencil_texture orelse return self.fail(error.InvalidResource);
                        const sample_values = values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                        for (sample_values, 0..) |*value, index| value.* = stencilTextureValue(texture, index);
                    }
                    active_stencil = null;
                } else if (begin_render.stencil_texture) |stencil_texture| {
                    if (!validTexture(stencil_texture) or stencil_texture.device != self.queue.device or
                        !isStencilTextureFormat(stencil_texture.format) or stencil_texture.width != begin_render.target.width or
                        stencil_texture.height != begin_render.target.height) return self.fail(error.InvalidResource);
                    const pixel_count = std.math.mul(usize, stencil_texture.width, stencil_texture.height) catch return self.fail(error.InvalidArgument);
                    const values = allocator.alloc(u8, pixel_count) catch return self.fail(error.OutOfMemory);
                    active_stencil_values = values;
                    for (values, 0..) |*value, index| value.* = stencilTextureValue(stencil_texture, index);
                    active_stencil = values;
                }
                const target = begin_render.target.asTarget();
                if (begin_render.pass.depth.load_action != .dont_care) {
                    const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                    if (begin_render.pass.depth.load_action == .clear) {
                        if (active_array_target_count > 1 and begin_render.depth_sample_array_targets[0][0] != null) {
                            for (active_depth_sample_array_values[0..active_array_target_count]) |values| {
                                @memset(values orelse return self.fail(error.InvalidResource), begin_render.pass.depth.clear_depth);
                            }
                        } else if (active_array_target_count > 1 and begin_render.depth_array_targets[0] != null) {
                            for (active_depth_array_values[0..active_array_target_count]) |values| {
                                @memset(values orelse return self.fail(error.InvalidResource), begin_render.pass.depth.clear_depth);
                            }
                        } else if (active_sample_count == 1) {
                            const depth = active_depth orelse return self.fail(error.InvalidResource);
                            if (depth.len < pixel_count) return self.fail(error.InvalidResource);
                            @memset(depth[0..pixel_count], begin_render.pass.depth.clear_depth);
                        } else {
                            const values = active_depth_values orelse return self.fail(error.InvalidResource);
                            @memset(values, begin_render.pass.depth.clear_depth);
                        }
                    }
                }
                if (begin_render.stencil_load_action != .dont_care) {
                    const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                    if (begin_render.stencil_load_action == .clear) {
                        if (active_array_target_count > 1 and begin_render.stencil_sample_array_targets[0][0] != null) {
                            for (active_stencil_sample_array_values[0..active_array_target_count]) |values| {
                                @memset(values orelse return self.fail(error.InvalidResource), begin_render.stencil_clear);
                            }
                        } else if (active_array_target_count > 1 and begin_render.stencil_array_targets[0] != null) {
                            for (active_stencil_array_values[0..active_array_target_count]) |values| {
                                @memset(values orelse return self.fail(error.InvalidResource), begin_render.stencil_clear);
                            }
                        } else if (active_sample_count == 1) {
                            const stencil = active_stencil orelse return self.fail(error.InvalidResource);
                            if (stencil.len < pixel_count) return self.fail(error.InvalidResource);
                            @memset(stencil[0..pixel_count], begin_render.stencil_clear);
                        } else {
                            const values = active_stencil_values orelse return self.fail(error.InvalidResource);
                            @memset(values, begin_render.stencil_clear);
                        }
                    }
                }
            },
            .draw => |draw| {
                var resolved_draw = draw;
                const instance_count = self.resolveIndirectDraw(&resolved_draw) catch |err| return self.fail(err);
                if (instance_count == 0 or resolved_draw.vertex_count == 0) continue;
                if (resolved_draw.amplification_count == 0 or resolved_draw.amplification_count > 2)
                    return self.fail(error.InvalidArgument);
                for (resolved_draw.amplification_viewport_offsets[0..resolved_draw.amplification_count]) |offset| {
                    const viewport_index = @as(usize, offset);
                    if (viewport_index >= resolved_draw.viewport_array_count or
                        viewport_index >= resolved_draw.scissor_array_count)
                        return self.fail(error.InvalidArgument);
                }
                const base_array_index = if (active_array_target_count > 1)
                    std.math.add(usize, resolved_draw.array_index, resolved_draw.base_instance) catch return self.fail(error.InvalidArgument)
                else
                    0;
                var first_array_index = base_array_index;
                if (active_array_target_count > 1) {
                    first_array_index = std.math.add(
                        usize,
                        base_array_index,
                        resolved_draw.amplification_render_target_offsets[0],
                    ) catch return self.fail(error.InvalidArgument);
                    for (resolved_draw.amplification_render_target_offsets[0..resolved_draw.amplification_count]) |offset| {
                        const amplified_base = std.math.add(usize, base_array_index, offset) catch
                            return self.fail(error.InvalidArgument);
                        if (amplified_base >= active_array_target_count or
                            (resolved_draw.indirect_buffer != null and
                                instance_count > active_array_target_count - amplified_base))
                            return self.fail(error.InvalidArgument);
                    }
                } else {
                    for (resolved_draw.amplification_render_target_offsets[0..resolved_draw.amplification_count]) |offset| {
                        if (offset != 0) return self.fail(error.InvalidArgument);
                    }
                }
                const array_index = first_array_index;
                const target_handle = active_array_color_attachments[0][array_index] orelse
                    (active_target orelse return self.fail(error.InvalidCommand));
                if (!validTexture(target_handle)) return self.fail(error.InvalidResource);
                if (active_array_target_count > 1) {
                    for (active_array_color_attachments[0][0..active_array_target_count]) |target| {
                        sparseSyncTexture(target orelse return self.fail(error.InvalidResource));
                    }
                    for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                        if (attachment != null) {
                            for (active_array_color_attachments[physical_index + 1][0..active_array_target_count]) |target| {
                                sparseSyncTexture(target orelse return self.fail(error.InvalidResource));
                            }
                        }
                    }
                } else {
                    sparseSyncTexture(target_handle);
                    for (active_color_attachments) |attachment| sparseSyncOptionalTexture(attachment);
                }
                for (active_sample_targets[0..active_sample_count]) |sample| sparseSyncOptionalTexture(sample);
                for (active_sample_color_attachments) |sample| sparseSyncOptionalTexture(sample);
                for (active_sample_array_color_attachments) |attachment_layers| {
                    for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                        for (layer_samples[0..active_sample_count]) |sample| sparseSyncOptionalTexture(sample);
                    }
                }
                defer {
                    if (active_array_target_count > 1) {
                        for (active_array_color_attachments[0][0..active_array_target_count]) |target| sparseFlushOptionalTexture(target);
                        for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                            if (attachment != null) {
                                for (active_array_color_attachments[physical_index + 1][0..active_array_target_count]) |target| {
                                    sparseFlushOptionalTexture(target);
                                }
                            }
                        }
                    } else {
                        sparseFlushTexture(target_handle);
                        for (active_color_attachments) |attachment| sparseFlushOptionalTexture(attachment);
                    }
                    for (active_sample_targets[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                    for (active_sample_color_attachments) |sample| sparseFlushOptionalTexture(sample);
                    for (active_sample_array_color_attachments) |attachment_layers| {
                        for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                            for (layer_samples[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                        }
                    }
                }
                sparseSyncOptionalBuffer(draw.vertex_buffer);
                sparseSyncOptionalBuffer(draw.index_buffer);
                sparseSyncOptionalBuffer(draw.indirect_buffer);
                sparseSyncOptionalBuffer(draw.fragment_uniform_buffer);
                sparseSyncOptionalBuffer(draw.visibility_buffer);
                defer {
                    sparseFlushOptionalBuffer(draw.vertex_buffer);
                    sparseFlushOptionalBuffer(draw.index_buffer);
                    sparseFlushOptionalBuffer(draw.fragment_uniform_buffer);
                    sparseFlushOptionalBuffer(draw.visibility_buffer);
                    sparseFlushOptionalBuffer(draw.indirect_buffer);
                }
                var owned_source_vertices: ?[]abi.Vertex = null;
                var owned_indexed_vertices: ?[]abi.Vertex = null;
                const draw_vertices = self.resolveDrawVertices(
                    resolved_draw,
                    &owned_source_vertices,
                    &owned_indexed_vertices,
                ) catch |err| return self.fail(err);
                defer {
                    if (owned_source_vertices) |vertices| allocator.free(vertices);
                    if (owned_indexed_vertices) |vertices| allocator.free(vertices);
                }
                var draw_options = resolved_draw.options;
                if (resolved_draw.fragment_uniform_enabled) {
                    if (resolved_draw.fragment_uniform_buffer) |buffer| {
                        if (!validBuffer(buffer) or buffer.device != self.queue.device or
                            !rangeValid(buffer.bytes.len, resolved_draw.fragment_uniform_buffer_offset, @sizeOf(abi.Color)))
                            return self.fail(error.InvalidArgument);
                        const raw = buffer.bytes[resolved_draw.fragment_uniform_buffer_offset .. resolved_draw.fragment_uniform_buffer_offset + @sizeOf(abi.Color)];
                        var color: [4]f32 = undefined;
                        for (0..4) |channel| {
                            color[channel] = @bitCast(std.mem.readInt(u32, raw[channel * @sizeOf(f32) ..][0..@sizeOf(f32)], .little));
                            if (!std.math.isFinite(color[channel])) return self.fail(error.InvalidArgument);
                        }
                        draw_options.fragment_color = color;
                    } else if (draw_options.fragment_color == null) {
                        return self.fail(error.InvalidResource);
                    }
                }
                var target = target_handle.asTarget();
                var extra_targets_storage: [7]raster3d.Target = undefined;
                var extra_targets: [7]?*raster3d.Target = [_]?*raster3d.Target{null} ** 7;
                var sample_extra_targets_storage: [7]raster3d.Target = undefined;
                var sample_extra_targets: [7]?*raster3d.Target = [_]?*raster3d.Target{null} ** 7;
                var sample_target_storage: raster3d.Target = undefined;
                var sample_target: ?*const raster3d.Target = null;
                var sample_mipmap_targets: []raster3d.Target = &.{};
                defer if (sample_mipmap_targets.len != 0) allocator.free(sample_mipmap_targets);
                if (draw.sample_texture) |value| {
                    if (!validTexture(value) or value.device != self.queue.device or !value.format.isColor()) return self.fail(error.InvalidResource);
                    sample_target_storage = value.asTarget();
                    sample_target = &sample_target_storage;
                }
                if (draw.sample_mipmap_count != 0) {
                    if (draw.sample_mipmap_start > self.sample_mipmaps.items.len or
                        draw.sample_mipmap_count > self.sample_mipmaps.items.len - draw.sample_mipmap_start)
                        return self.fail(error.InvalidCommand);
                    sample_mipmap_targets = allocator.alloc(raster3d.Target, draw.sample_mipmap_count) catch return self.fail(error.OutOfMemory);
                    for (self.sample_mipmaps.items[draw.sample_mipmap_start .. draw.sample_mipmap_start + draw.sample_mipmap_count], 0..) |value, index| {
                        if (!validTexture(value) or value.device != self.queue.device or !value.format.isColor()) return self.fail(error.InvalidResource);
                        sample_mipmap_targets[index] = value.asTarget();
                    }
                }
                var extra_count: usize = 0;
                for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                    if (attachment) |attachment_value| {
                        const value = if (active_array_target_count > 1)
                            active_array_color_attachments[physical_index + 1][array_index] orelse
                                return self.fail(error.InvalidResource)
                        else
                            attachment_value;
                        extra_targets_storage[physical_index] = value.asTarget();
                        extra_targets[physical_index] = &extra_targets_storage[physical_index];
                        extra_count = @max(extra_count, physical_index + 1);
                    }
                }
                const logical_output_count: usize = if (draw_options.write_extra_targets)
                    @min(extra_count + 1, 8)
                else
                    1;
                validateColorAttachmentOutputs(active_color_attachments, draw_options.color_attachment_map, logical_output_count) catch |err| return self.fail(err);
                var stats: raster3d.Stats = .{};
                if (active_sample_count == 1) {
                    for (0..resolved_draw.amplification_count) |amplification| {
                        const viewport_index = @as(usize, resolved_draw.amplification_viewport_offsets[amplification]);
                        var amplification_options = draw_options;
                        amplification_options.viewport = resolved_draw.viewport_array[viewport_index];
                        amplification_options.scissor = resolved_draw.scissor_array[viewport_index];
                        const amplified_array_index = if (active_array_target_count > 1)
                            std.math.add(usize, base_array_index, resolved_draw.amplification_render_target_offsets[amplification]) catch
                                return self.fail(error.InvalidArgument)
                        else
                            0;
                        for (0..instance_count) |instance| {
                            const instance_array_index = if (active_array_target_count > 1 and resolved_draw.indirect_buffer != null)
                                std.math.add(usize, amplified_array_index, instance) catch return self.fail(error.InvalidArgument)
                            else
                                amplified_array_index;
                            if (active_array_target_count > 1 and resolved_draw.indirect_buffer != null) {
                                const instance_target = active_array_color_attachments[0][instance_array_index] orelse
                                    return self.fail(error.InvalidResource);
                                target = instance_target.asTarget();
                                for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                                    if (attachment != null) {
                                        const instance_extra = active_array_color_attachments[physical_index + 1][instance_array_index] orelse
                                            return self.fail(error.InvalidResource);
                                        extra_targets_storage[physical_index] = instance_extra.asTarget();
                                    }
                                }
                            }
                            const depth_values = if (active_array_target_count > 1)
                                active_depth_array_values[instance_array_index]
                            else
                                active_depth;
                            const stencil_values = if (active_array_target_count > 1)
                                active_stencil_array_values[instance_array_index]
                            else
                                active_stencil;
                            if (active_array_target_count > 1 and resolved_draw.indirect_buffer == null) {
                                const instance_target = active_array_color_attachments[0][instance_array_index] orelse
                                    return self.fail(error.InvalidResource);
                                target = instance_target.asTarget();
                                for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                                    if (attachment != null) {
                                        const instance_extra = active_array_color_attachments[physical_index + 1][instance_array_index] orelse
                                            return self.fail(error.InvalidResource);
                                        extra_targets_storage[physical_index] = instance_extra.asTarget();
                                    }
                                }
                            }
                            stats = addRasterStats(stats, raster3d.drawWithTargetMipmaps(
                                @constCast(&target),
                                extra_targets[0..extra_count],
                                sample_target,
                                sample_mipmap_targets,
                                depth_values,
                                stencil_values,
                                draw_vertices,
                                resolved_draw.primitive,
                                amplification_options,
                            ));
                        }
                    }
                } else {
                    const pixel_count = std.math.mul(usize, target_handle.width, target_handle.height) catch return self.fail(error.InvalidArgument);
                    const layered_samples = active_sample_array_color_attachments[0][0][0] != null;
                    for (0..resolved_draw.amplification_count) |amplification| {
                        const viewport_index = @as(usize, resolved_draw.amplification_viewport_offsets[amplification]);
                        var amplification_options = draw_options;
                        amplification_options.viewport = resolved_draw.viewport_array[viewport_index];
                        amplification_options.scissor = resolved_draw.scissor_array[viewport_index];
                        const amplified_array_index = if (active_array_target_count > 1)
                            std.math.add(usize, base_array_index, resolved_draw.amplification_render_target_offsets[amplification]) catch
                                return self.fail(error.InvalidArgument)
                        else
                            0;
                        for (0..instance_count) |instance| {
                            const instance_array_index = if (active_array_target_count > 1)
                                (if (resolved_draw.indirect_buffer != null)
                                    std.math.add(usize, amplified_array_index, instance) catch return self.fail(error.InvalidArgument)
                                else
                                    amplified_array_index)
                            else
                                0;
                            if (instance_array_index >= active_array_target_count)
                                return self.fail(error.InvalidArgument);
                            for (0..active_sample_count) |sample_index| {
                                const sample = if (layered_samples)
                                    active_sample_array_color_attachments[0][instance_array_index][sample_index]
                                else
                                    active_sample_targets[sample_index];
                                var sample_target_value = (sample orelse return self.fail(error.InvalidResource)).asTarget();
                                sample_extra_targets = [_]?*raster3d.Target{null} ** 7;
                                var sample_extra_count: usize = 0;
                                for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                                    if (attachment) |_| {
                                        const sample_texture = if (layered_samples)
                                            active_sample_array_color_attachments[physical_index + 1][instance_array_index][sample_index]
                                        else
                                            active_sample_color_attachments[(physical_index + 1) * 4 + sample_index];
                                        const resolved_sample_texture = sample_texture orelse return self.fail(error.InvalidResource);
                                        sample_extra_targets_storage[physical_index] = resolved_sample_texture.asTarget();
                                        sample_extra_targets[physical_index] = &sample_extra_targets_storage[physical_index];
                                        sample_extra_count = @max(sample_extra_count, physical_index + 1);
                                    }
                                }
                                amplification_options.sample_position = if (active_custom_sample_positions)
                                    .{ active_sample_positions[sample_index].x, active_sample_positions[sample_index].y }
                                else
                                    raster3d.defaultSamplePosition(active_sample_count, sample_index);
                                const depth_values: ?[]f32 = if (layered_samples) blk: {
                                    if (active_depth_sample_array_values[instance_array_index]) |values|
                                        break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                                    break :blk null;
                                } else if (active_depth_values) |values|
                                    values[sample_index * pixel_count .. (sample_index + 1) * pixel_count]
                                else
                                    null;
                                const stencil_values: ?[]u8 = if (layered_samples) blk: {
                                    if (active_stencil_sample_array_values[instance_array_index]) |values|
                                        break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                                    break :blk null;
                                } else if (active_stencil_values) |values|
                                    values[sample_index * pixel_count .. (sample_index + 1) * pixel_count]
                                else
                                    null;
                                stats = addRasterStats(stats, raster3d.drawWithTargetMipmaps(
                                    &sample_target_value,
                                    sample_extra_targets[0..sample_extra_count],
                                    sample_target,
                                    sample_mipmap_targets,
                                    depth_values,
                                    stencil_values,
                                    draw_vertices,
                                    resolved_draw.primitive,
                                    amplification_options,
                                ));
                            }
                        }
                    }
                }
                if (resolved_draw.visibility_mode != .disabled) {
                    const visibility_buffer = resolved_draw.visibility_buffer orelse return self.fail(error.InvalidResource);
                    if (!validBuffer(visibility_buffer) or visibility_buffer.device != self.queue.device or
                        !rangeValid(visibility_buffer.bytes.len, resolved_draw.visibility_offset, @sizeOf(u64)))
                    {
                        return self.fail(error.InvalidArgument);
                    }
                    if (resolved_draw.visibility_result_type == .reset and
                        !visibilitySlotSeen(reset_visibility_slots.items, visibility_buffer, resolved_draw.visibility_offset))
                    {
                        writeU64Little(visibility_buffer.bytes, resolved_draw.visibility_offset, 0);
                        reset_visibility_slots.append(allocator, .{ .buffer = visibility_buffer, .offset = resolved_draw.visibility_offset }) catch return self.fail(error.OutOfMemory);
                    }
                    const previous = readU64Little(visibility_buffer.bytes, resolved_draw.visibility_offset);
                    const result = switch (resolved_draw.visibility_mode) {
                        .disabled => unreachable,
                        .boolean => @max(previous, if (stats.fragments_covered != 0) @as(u64, 1) else 0),
                        .counting => previous +| stats.fragments_covered,
                    };
                    writeU64Little(visibility_buffer.bytes, resolved_draw.visibility_offset, result);
                }
            },
            .tile => |tile| {
                sparseSyncOptionalBuffer(tile.visibility_buffer);
                defer sparseFlushOptionalBuffer(tile.visibility_buffer);
                const target_handle = active_target orelse return self.fail(error.InvalidCommand);
                if (!validTexture(target_handle) or target_handle != tile.target) return self.fail(error.InvalidResource);
                validateColorAttachmentOutputs(active_color_attachments, tile.color_attachment_map, 1) catch |err| return self.fail(err);
                const output_index = @as(usize, tile.color_attachment_map[0]);
                const output_texture = if (active_array_target_count > 1)
                    active_array_color_attachments[output_index][0] orelse return self.fail(error.InvalidResource)
                else
                    active_color_attachments[output_index] orelse return self.fail(error.InvalidResource);
                if (active_array_target_count > 1) {
                    for (active_array_color_attachments[output_index][0..active_array_target_count]) |output| {
                        sparseSyncTexture(output orelse return self.fail(error.InvalidResource));
                    }
                } else {
                    sparseSyncTexture(output_texture);
                }
                const layered_samples = active_sample_count > 1 and
                    active_sample_array_color_attachments[output_index][0][0] != null;
                if (active_sample_count > 1) {
                    if (layered_samples) {
                        for (active_sample_array_color_attachments[output_index][0..active_array_target_count]) |layer_samples| {
                            for (layer_samples[0..active_sample_count]) |sample| {
                                sparseSyncTexture(sample orelse return self.fail(error.InvalidResource));
                            }
                        }
                    } else {
                        for (0..active_sample_count) |sample_index| {
                            const sample = if (output_index == 0)
                                active_sample_targets[sample_index]
                            else
                                active_sample_color_attachments[output_index * 4 + sample_index];
                            sparseSyncTexture(sample orelse return self.fail(error.InvalidResource));
                        }
                    }
                }
                defer {
                    if (active_array_target_count > 1) {
                        for (active_array_color_attachments[output_index][0..active_array_target_count]) |output| {
                            sparseFlushOptionalTexture(output);
                        }
                    } else {
                        sparseFlushTexture(output_texture);
                    }
                    if (active_sample_count > 1) {
                        if (layered_samples) {
                            for (active_sample_array_color_attachments[output_index][0..active_array_target_count]) |layer_samples| {
                                for (layer_samples[0..active_sample_count]) |sample| {
                                    sparseFlushOptionalTexture(sample);
                                }
                            }
                        } else {
                            for (0..active_sample_count) |sample_index| {
                                const sample = if (output_index == 0)
                                    active_sample_targets[sample_index]
                                else
                                    active_sample_color_attachments[output_index * 4 + sample_index];
                                sparseFlushOptionalTexture(sample);
                            }
                        }
                    }
                }
                if (tile.kernel != 1 or
                    (output_texture.format != .rgba8_unorm and output_texture.format != .bgra8_unorm) or
                    tile.tile_size.width == 0 or tile.tile_size.height == 0 or tile.tile_size.depth != 1 or
                    tile.threads_per_tile.width == 0 or tile.threads_per_tile.height == 0 or
                    tile.threads_per_tile.depth != 1 or
                    tile.threads_per_tile.width > tile.tile_size.width or
                    tile.threads_per_tile.height > tile.tile_size.height) return self.fail(error.InvalidArgument);
                const tile_count_x = (@as(usize, target_handle.width) + tile.tile_size.width - 1) / tile.tile_size.width;
                const tile_count_y = (@as(usize, target_handle.height) + tile.tile_size.height - 1) / tile.tile_size.height;
                const layer_count = if (active_array_target_count > 1) active_array_target_count else 1;
                var tile_options = tile.options;
                // The bounded profile has one logical output. Its selected
                // physical attachment is already the target passed here;
                // normalize only the helper's local output map while
                // retaining fixed-function state.
                tile_options.write_extra_targets = false;
                tile_options.color_attachment_map[0] = 0;
                const x0 = @min(@as(usize, tile_options.scissor.x), @as(usize, target_handle.width));
                const y0 = @min(@as(usize, tile_options.scissor.y), @as(usize, target_handle.height));
                const x1 = @min(x0 +| @as(usize, tile_options.scissor.width), @as(usize, target_handle.width));
                const y1 = @min(y0 +| @as(usize, tile_options.scissor.height), @as(usize, target_handle.height));
                var stats: raster3d.Stats = .{};
                for (0..layer_count) |layer| {
                    const sample_iterations = if (active_sample_count > 1) active_sample_count else 1;
                    for (0..sample_iterations) |sample_index| {
                        const layer_texture = if (active_sample_count > 1)
                            (if (layered_samples)
                                active_sample_array_color_attachments[output_index][layer][sample_index]
                            else if (output_index == 0)
                                active_sample_targets[sample_index]
                            else
                                active_sample_color_attachments[output_index * 4 + sample_index]) orelse
                                return self.fail(error.InvalidResource)
                        else if (active_array_target_count > 1)
                            active_array_color_attachments[output_index][layer] orelse return self.fail(error.InvalidResource)
                        else
                            output_texture;
                        var target = layer_texture.asTarget();
                        const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                        const depth_values: ?[]f32 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_depth_sample_array_values[layer]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_depth_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_depth_array_values[layer]
                        else
                            active_depth;
                        const stencil_values: ?[]u8 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_stencil_sample_array_values[layer]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_stencil_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_stencil_array_values[layer]
                        else
                            active_stencil;
                        if (active_sample_count > 1) {
                            tile_options.sample_position = if (active_custom_sample_positions)
                                .{ active_sample_positions[sample_index].x, active_sample_positions[sample_index].y }
                            else
                                raster3d.defaultSamplePosition(active_sample_count, sample_index);
                        }
                        for (0..tile_count_y) |tile_y| {
                            for (0..tile_count_x) |tile_x| {
                                const tile_origin_x = tile_x * tile.tile_size.width;
                                const tile_origin_y = tile_y * tile.tile_size.height;
                                for (0..tile.threads_per_tile.height) |local_y| {
                                    const y = tile_origin_y + local_y;
                                    if (y >= target.height or y < y0 or y >= y1) continue;
                                    for (0..tile.threads_per_tile.width) |local_x| {
                                        const x = tile_origin_x + local_x;
                                        if (x >= target.width or x < x0 or x >= x1) continue;
                                        stats = addRasterStats(stats, raster3d.writePoint(&target, depth_values, stencil_values, x, y, 0.5, .{
                                            (@as(f32, @floatFromInt(x)) + 1.0) / 8.0,
                                            (@as(f32, @floatFromInt(y)) + 1.0) / 8.0,
                                            0.25,
                                            1.0,
                                        }, tile_options));
                                    }
                                }
                            }
                        }
                    }
                }
                if (tile.visibility_mode != .disabled) {
                    const visibility_buffer = tile.visibility_buffer orelse return self.fail(error.InvalidResource);
                    if (!validBuffer(visibility_buffer) or visibility_buffer.device != self.queue.device or
                        !rangeValid(visibility_buffer.bytes.len, tile.visibility_offset, @sizeOf(u64)))
                        return self.fail(error.InvalidArgument);
                    if (tile.visibility_result_type == .reset and
                        !visibilitySlotSeen(reset_visibility_slots.items, visibility_buffer, tile.visibility_offset))
                    {
                        writeU64Little(visibility_buffer.bytes, tile.visibility_offset, 0);
                        reset_visibility_slots.append(allocator, .{ .buffer = visibility_buffer, .offset = tile.visibility_offset }) catch return self.fail(error.OutOfMemory);
                    }
                    const previous = readU64Little(visibility_buffer.bytes, tile.visibility_offset);
                    const result = switch (tile.visibility_mode) {
                        .disabled => unreachable,
                        .boolean => @max(previous, if (stats.fragments_covered != 0) @as(u64, 1) else 0),
                        .counting => previous +| stats.fragments_covered,
                    };
                    writeU64Little(visibility_buffer.bytes, tile.visibility_offset, result);
                }
            },
            .mesh => |mesh| {
                sparseSyncOptionalBuffer(mesh.indirect_buffer);
                sparseSyncOptionalBuffer(mesh.visibility_buffer);
                defer sparseFlushOptionalBuffer(mesh.indirect_buffer);
                defer sparseFlushOptionalBuffer(mesh.visibility_buffer);
                var resolved_mesh = mesh;
                if (mesh.indirect_buffer) |indirect_buffer| {
                    if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.queue.device or
                        !rangeValid(indirect_buffer.bytes.len, mesh.indirect_buffer_offset, 3 * @sizeOf(u32)))
                        return self.fail(error.InvalidArgument);
                    const threadgroups_width = readU32Little(indirect_buffer.bytes, mesh.indirect_buffer_offset);
                    const threadgroups_height = readU32Little(indirect_buffer.bytes, mesh.indirect_buffer_offset + 4);
                    const threadgroups_depth = readU32Little(indirect_buffer.bytes, mesh.indirect_buffer_offset + 8);
                    resolved_mesh.threads_per_grid = .{
                        .width = std.math.mul(u32, threadgroups_width, mesh.threads_per_mesh_threadgroup.width) catch
                            return self.fail(error.InvalidArgument),
                        .height = std.math.mul(u32, threadgroups_height, mesh.threads_per_mesh_threadgroup.height) catch
                            return self.fail(error.InvalidArgument),
                        .depth = std.math.mul(u32, threadgroups_depth, mesh.threads_per_mesh_threadgroup.depth) catch
                            return self.fail(error.InvalidArgument),
                    };
                }
                const target_handle = active_target orelse return self.fail(error.InvalidCommand);
                if (!validTexture(target_handle) or target_handle != resolved_mesh.target) return self.fail(error.InvalidResource);
                validateColorAttachmentOutputs(active_color_attachments, resolved_mesh.color_attachment_map, 1) catch |err| return self.fail(err);
                const output_index = @as(usize, resolved_mesh.color_attachment_map[0]);
                const output_texture = if (active_array_target_count > 1)
                    active_array_color_attachments[output_index][0] orelse return self.fail(error.InvalidResource)
                else
                    active_color_attachments[output_index] orelse return self.fail(error.InvalidResource);
                if (active_array_target_count > 1) {
                    for (active_array_color_attachments[output_index][0..active_array_target_count]) |output| {
                        sparseSyncTexture(output orelse return self.fail(error.InvalidResource));
                    }
                } else {
                    sparseSyncTexture(output_texture);
                }
                const layered_samples = active_sample_count > 1 and
                    active_sample_array_color_attachments[output_index][0][0] != null;
                if (active_sample_count > 1) {
                    if (layered_samples) {
                        for (active_sample_array_color_attachments[output_index][0..active_array_target_count]) |layer_samples| {
                            for (layer_samples[0..active_sample_count]) |sample| {
                                sparseSyncTexture(sample orelse return self.fail(error.InvalidResource));
                            }
                        }
                    } else {
                        for (0..active_sample_count) |sample_index| {
                            const sample = if (output_index == 0)
                                active_sample_targets[sample_index]
                            else
                                active_sample_color_attachments[output_index * 4 + sample_index];
                            sparseSyncTexture(sample orelse return self.fail(error.InvalidResource));
                        }
                    }
                }
                defer {
                    if (active_array_target_count > 1) {
                        for (active_array_color_attachments[output_index][0..active_array_target_count]) |output| {
                            sparseFlushOptionalTexture(output);
                        }
                    } else {
                        sparseFlushTexture(output_texture);
                    }
                    if (active_sample_count > 1) {
                        if (layered_samples) {
                            for (active_sample_array_color_attachments[output_index][0..active_array_target_count]) |layer_samples| {
                                for (layer_samples[0..active_sample_count]) |sample| {
                                    sparseFlushOptionalTexture(sample);
                                }
                            }
                        } else {
                            for (0..active_sample_count) |sample_index| {
                                const sample = if (output_index == 0)
                                    active_sample_targets[sample_index]
                                else
                                    active_sample_color_attachments[output_index * 4 + sample_index];
                                sparseFlushOptionalTexture(sample);
                            }
                        }
                    }
                }
                const mesh_threads = resolved_mesh.threads_per_mesh_threadgroup;
                const object_threads = resolved_mesh.threads_per_object_threadgroup;
                const mesh_thread_count = @as(u64, mesh_threads.width) * @as(u64, mesh_threads.height) * @as(u64, mesh_threads.depth);
                const object_thread_count = @as(u64, object_threads.width) * @as(u64, object_threads.height) * @as(u64, object_threads.depth);
                const layer_count = if (active_array_target_count > 1) active_array_target_count else 1;
                if (resolved_mesh.kernel != 1 or
                    (output_texture.format != .rgba8_unorm and output_texture.format != .bgra8_unorm) or
                    resolved_mesh.threads_per_grid.width == 0 or resolved_mesh.threads_per_grid.height == 0 or
                    resolved_mesh.threads_per_grid.depth != layer_count or
                    object_threads.width != 1 or object_threads.height != 1 or object_threads.depth != 1 or
                    mesh_threads.width == 0 or mesh_threads.height == 0 or mesh_threads.depth != 1 or
                    mesh_thread_count > 1024 or object_thread_count != 1) return self.fail(error.InvalidArgument);
                // Metal scissor coordinates are attachment-global and
                // top-left-origin; the complete options snapshot prevents
                // later encoder mutations from rebasing this command.
                var mesh_options = resolved_mesh.options;
                // The bounded profile has one logical output. Its selected
                // physical attachment is already the target passed here;
                // normalize only the helper's local output map while
                // retaining depth/stencil/blend/write-mask state.
                mesh_options.write_extra_targets = false;
                mesh_options.color_attachment_map[0] = 0;
                var stats: raster3d.Stats = .{};
                for (0..layer_count) |layer| {
                    const sample_iterations = if (active_sample_count > 1) active_sample_count else 1;
                    for (0..sample_iterations) |sample_index| {
                        const layer_texture = if (active_sample_count > 1)
                            (if (layered_samples)
                                active_sample_array_color_attachments[output_index][layer][sample_index]
                            else if (output_index == 0)
                                active_sample_targets[sample_index]
                            else
                                active_sample_color_attachments[output_index * 4 + sample_index]) orelse
                                return self.fail(error.InvalidResource)
                        else if (active_array_target_count > 1)
                            active_array_color_attachments[output_index][layer] orelse return self.fail(error.InvalidResource)
                        else
                            output_texture;
                        var target = layer_texture.asTarget();
                        const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                        const depth_values: ?[]f32 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_depth_sample_array_values[layer]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_depth_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_depth_array_values[layer]
                        else
                            active_depth;
                        const stencil_values: ?[]u8 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_stencil_sample_array_values[layer]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_stencil_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_stencil_array_values[layer]
                        else
                            active_stencil;
                        if (active_sample_count > 1) {
                            mesh_options.sample_position = if (active_custom_sample_positions)
                                .{ active_sample_positions[sample_index].x, active_sample_positions[sample_index].y }
                            else
                                raster3d.defaultSamplePosition(active_sample_count, sample_index);
                        }
                        const width = @min(@as(usize, target.width), @as(usize, resolved_mesh.threads_per_grid.width));
                        const height = @min(@as(usize, target.height), @as(usize, resolved_mesh.threads_per_grid.height));
                        const x0 = @min(@as(usize, resolved_mesh.options.scissor.x), width);
                        const y0 = @min(@as(usize, resolved_mesh.options.scissor.y), height);
                        const x1 = @min(x0 +| @as(usize, resolved_mesh.options.scissor.width), width);
                        const y1 = @min(y0 +| @as(usize, resolved_mesh.options.scissor.height), height);
                        for (y0..y1) |y| {
                            for (x0..x1) |x| {
                                stats = addRasterStats(stats, raster3d.writePoint(&target, depth_values, stencil_values, x, y, 0.5, .{
                                    (@as(f32, @floatFromInt(x)) + 1.0) / 8.0,
                                    (@as(f32, @floatFromInt(y)) + 1.0) / 8.0,
                                    0.25,
                                    1.0,
                                }, mesh_options));
                            }
                        }
                    }
                }
                if (resolved_mesh.visibility_mode != .disabled) {
                    const visibility_buffer = resolved_mesh.visibility_buffer orelse return self.fail(error.InvalidResource);
                    if (!validBuffer(visibility_buffer) or visibility_buffer.device != self.queue.device or
                        !rangeValid(visibility_buffer.bytes.len, resolved_mesh.visibility_offset, @sizeOf(u64)))
                        return self.fail(error.InvalidArgument);
                    if (resolved_mesh.visibility_result_type == .reset and
                        !visibilitySlotSeen(reset_visibility_slots.items, visibility_buffer, resolved_mesh.visibility_offset))
                    {
                        writeU64Little(visibility_buffer.bytes, resolved_mesh.visibility_offset, 0);
                        reset_visibility_slots.append(allocator, .{ .buffer = visibility_buffer, .offset = resolved_mesh.visibility_offset }) catch return self.fail(error.OutOfMemory);
                    }
                    const previous = readU64Little(visibility_buffer.bytes, resolved_mesh.visibility_offset);
                    const result = switch (resolved_mesh.visibility_mode) {
                        .disabled => unreachable,
                        .boolean => @max(previous, if (stats.fragments_covered != 0) @as(u64, 1) else 0),
                        .counting => previous +| stats.fragments_covered,
                    };
                    writeU64Little(visibility_buffer.bytes, resolved_mesh.visibility_offset, result);
                }
            },
            .patch => |patch| {
                sparseSyncOptionalBuffer(patch.vertex_buffer);
                sparseSyncOptionalBuffer(patch.patch_index_buffer);
                sparseSyncOptionalBuffer(patch.indirect_buffer);
                sparseSyncOptionalBuffer(patch.factor_buffer);
                sparseSyncOptionalBuffer(patch.control_point_index_buffer);
                sparseSyncOptionalBuffer(patch.fragment_uniform_buffer);
                sparseSyncOptionalBuffer(patch.visibility_buffer);
                defer {
                    sparseFlushOptionalBuffer(patch.vertex_buffer);
                    sparseFlushOptionalBuffer(patch.patch_index_buffer);
                    sparseFlushOptionalBuffer(patch.indirect_buffer);
                    sparseFlushOptionalBuffer(patch.factor_buffer);
                    sparseFlushOptionalBuffer(patch.control_point_index_buffer);
                    sparseFlushOptionalBuffer(patch.fragment_uniform_buffer);
                    sparseFlushOptionalBuffer(patch.visibility_buffer);
                }
                var resolved_patch = patch;
                if (patch.indirect_buffer) |indirect_buffer| {
                    if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.queue.device or
                        !rangeValid(indirect_buffer.bytes.len, patch.indirect_buffer_offset, 4 * @sizeOf(u32)))
                        return self.fail(error.InvalidArgument);
                    const offset = patch.indirect_buffer_offset;
                    resolved_patch.patch_count = readU32Little(indirect_buffer.bytes, offset);
                    resolved_patch.instance_count = readU32Little(indirect_buffer.bytes, offset + 4);
                    resolved_patch.patch_start = readU32Little(indirect_buffer.bytes, offset + 8);
                    resolved_patch.base_instance = readU32Little(indirect_buffer.bytes, offset + 12);
                }
                const target_handle = active_target orelse return self.fail(error.InvalidCommand);
                if (!validTexture(target_handle) or target_handle != resolved_patch.target or
                    resolved_patch.kernel != 1 or resolved_patch.control_point_count != 3 or
                    (target_handle.format != .rgba8_unorm and target_handle.format != .bgra8_unorm) or
                    resolved_patch.max_tessellation_factor == 0 or
                    resolved_patch.max_tessellation_factor > cpu_patch_max_tessellation_factor)
                    return self.fail(error.InvalidArgument);
                if (resolved_patch.instance_count == 0 or resolved_patch.patch_count == 0) continue;

                const last_instance = std.math.add(usize, resolved_patch.base_instance, resolved_patch.instance_count - 1) catch
                    return self.fail(error.InvalidArgument);
                if (active_array_target_count > 1 and last_instance >= active_array_target_count)
                    return self.fail(error.InvalidArgument);
                if (active_array_target_count > 1) {
                    for (active_array_color_attachments[0][0..active_array_target_count]) |target| {
                        sparseSyncTexture(target orelse return self.fail(error.InvalidResource));
                    }
                    for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                        if (attachment != null) {
                            for (active_array_color_attachments[physical_index + 1][0..active_array_target_count]) |target| {
                                sparseSyncTexture(target orelse return self.fail(error.InvalidResource));
                            }
                        }
                    }
                } else {
                    sparseSyncTexture(target_handle);
                    for (active_color_attachments) |attachment| sparseSyncOptionalTexture(attachment);
                }
                const layered_samples = active_sample_count > 1 and
                    active_sample_array_color_attachments[0][0][0] != null;
                if (active_sample_count > 1) {
                    for (active_sample_targets[0..active_sample_count]) |sample| {
                        sparseSyncTexture(sample orelse {
                            return self.fail(error.InvalidResource);
                        });
                    }
                    for (active_sample_color_attachments) |sample| sparseSyncOptionalTexture(sample);
                    for (active_sample_array_color_attachments) |attachment_layers| {
                        for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                            if (layer_samples[0] != null) {
                                for (layer_samples[0..active_sample_count]) |sample| {
                                    sparseSyncTexture(sample orelse return self.fail(error.InvalidResource));
                                }
                            }
                        }
                    }
                }
                defer {
                    if (active_array_target_count > 1) {
                        for (active_array_color_attachments[0][0..active_array_target_count]) |target| {
                            sparseFlushOptionalTexture(target);
                        }
                        for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                            if (attachment != null) {
                                for (active_array_color_attachments[physical_index + 1][0..active_array_target_count]) |target| {
                                    sparseFlushOptionalTexture(target);
                                }
                            }
                        }
                    } else {
                        sparseFlushTexture(target_handle);
                        for (active_color_attachments) |attachment| sparseFlushOptionalTexture(attachment);
                    }
                    if (active_sample_count > 1) {
                        for (active_sample_targets[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
                        for (active_sample_color_attachments) |sample| sparseFlushOptionalTexture(sample);
                        for (active_sample_array_color_attachments) |attachment_layers| {
                            for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                                for (layer_samples[0..active_sample_count]) |sample| {
                                    sparseFlushOptionalTexture(sample);
                                }
                            }
                        }
                    }
                }

                const patch_end = std.math.add(usize, resolved_patch.patch_start, resolved_patch.patch_count) catch
                    return self.fail(error.InvalidArgument);
                if (resolved_patch.patch_index_buffer) |buffer| {
                    const bytes = std.math.mul(usize, resolved_patch.patch_count, @sizeOf(u32)) catch
                        return self.fail(error.InvalidArgument);
                    if (!validBuffer(buffer) or buffer.device != self.queue.device or
                        !rangeValid(buffer.bytes.len, resolved_patch.patch_index_buffer_offset, bytes))
                        return self.fail(error.InvalidArgument);
                }

                const factor_entry_size = @sizeOf(u16) * 4;
                const factor_instance_offset = std.math.mul(usize, last_instance, resolved_patch.factor_instance_stride) catch
                    return self.fail(error.InvalidArgument);
                const factor_patch_offset = std.math.mul(usize, patch_end - 1, factor_entry_size) catch
                    return self.fail(error.InvalidArgument);
                const factor_last = std.math.add(usize, factor_instance_offset, factor_patch_offset) catch
                    return self.fail(error.InvalidArgument);
                const factor_bytes = std.math.add(usize, factor_last, factor_entry_size) catch
                    return self.fail(error.InvalidArgument);
                if (!validBuffer(resolved_patch.factor_buffer) or resolved_patch.factor_buffer.device != self.queue.device or
                    !rangeValid(resolved_patch.factor_buffer.bytes.len, resolved_patch.factor_buffer_offset, factor_bytes))
                    return self.fail(error.InvalidArgument);

                if (resolved_patch.control_point_index_buffer) |buffer| {
                    if (!validBuffer(buffer) or buffer.device != self.queue.device) return self.fail(error.InvalidResource);
                }
                var owned_source_vertices: ?[]abi.Vertex = null;
                const source_vertices = self.resolvePatchVertices(resolved_patch, &owned_source_vertices) catch |err| return self.fail(err);
                defer if (owned_source_vertices) |vertices| allocator.free(vertices);

                var draw_options = resolved_patch.options;
                if (resolved_patch.fragment_uniform_enabled) {
                    if (resolved_patch.fragment_uniform_buffer) |buffer| {
                        if (!validBuffer(buffer) or buffer.device != self.queue.device or
                            !rangeValid(buffer.bytes.len, resolved_patch.fragment_uniform_buffer_offset, @sizeOf(abi.Color)))
                            return self.fail(error.InvalidArgument);
                        const raw = buffer.bytes[resolved_patch.fragment_uniform_buffer_offset .. resolved_patch.fragment_uniform_buffer_offset + @sizeOf(abi.Color)];
                        var color: [4]f32 = undefined;
                        for (0..4) |channel| {
                            color[channel] = @bitCast(std.mem.readInt(u32, raw[channel * @sizeOf(f32) ..][0..@sizeOf(f32)], .little));
                            if (!std.math.isFinite(color[channel])) return self.fail(error.InvalidArgument);
                        }
                        draw_options.fragment_color = color;
                    } else if (draw_options.fragment_color == null) {
                        return self.fail(error.InvalidResource);
                    }
                }

                var extra_targets_storage: [7]raster3d.Target = undefined;
                var extra_targets: [7]?*raster3d.Target = [_]?*raster3d.Target{null} ** 7;
                var extra_count: usize = 0;
                for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                    if (attachment != null) extra_count = @max(extra_count, physical_index + 1);
                }
                const logical_output_count: usize = if (draw_options.write_extra_targets)
                    @min(extra_count + 1, 8)
                else
                    1;
                validateColorAttachmentOutputs(active_color_attachments, draw_options.color_attachment_map, logical_output_count) catch |err| return self.fail(err);
                var stats: raster3d.Stats = .{};
                for (0..resolved_patch.instance_count) |instance| {
                    const instance_id = std.math.add(usize, resolved_patch.base_instance, instance) catch
                        return self.fail(error.InvalidArgument);
                    const array_index = if (active_array_target_count > 1) instance_id else 0;
                    const sample_iterations = if (active_sample_count > 1) active_sample_count else 1;
                    for (0..sample_iterations) |sample_index| {
                        const instance_target = if (active_sample_count > 1)
                            (if (layered_samples)
                                active_sample_array_color_attachments[0][array_index][sample_index]
                            else
                                active_sample_targets[sample_index]) orelse {
                                return self.fail(error.InvalidResource);
                            }
                        else if (active_array_target_count > 1)
                            active_array_color_attachments[0][array_index] orelse {
                                return self.fail(error.InvalidResource);
                            }
                        else
                            target_handle;
                        var target = instance_target.asTarget();
                        extra_targets = [_]?*raster3d.Target{null} ** 7;
                        var sample_extra_count: usize = 0;
                        for (active_color_attachments[1..], 0..) |attachment, physical_index| {
                            if (attachment != null) {
                                const instance_extra = if (active_sample_count > 1)
                                    (if (layered_samples)
                                        active_sample_array_color_attachments[physical_index + 1][array_index][sample_index]
                                    else
                                        active_sample_color_attachments[(physical_index + 1) * 4 + sample_index]) orelse
                                        return self.fail(error.InvalidResource)
                                else if (active_array_target_count > 1)
                                    active_array_color_attachments[physical_index + 1][array_index] orelse
                                        return self.fail(error.InvalidResource)
                                else
                                    attachment.?;
                                extra_targets_storage[physical_index] = instance_extra.asTarget();
                                extra_targets[physical_index] = &extra_targets_storage[physical_index];
                                sample_extra_count = @max(sample_extra_count, physical_index + 1);
                            }
                        }
                        const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                        const depth_values: ?[]f32 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_depth_sample_array_values[array_index]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_depth_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_depth_array_values[array_index]
                        else
                            active_depth;
                        const stencil_values: ?[]u8 = if (active_sample_count > 1) blk: {
                            if (layered_samples) {
                                if (active_stencil_sample_array_values[array_index]) |values|
                                    break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            } else if (active_stencil_values) |values| {
                                break :blk values[sample_index * pixel_count .. (sample_index + 1) * pixel_count];
                            }
                            break :blk null;
                        } else if (active_array_target_count > 1)
                            active_stencil_array_values[array_index]
                        else
                            active_stencil;
                        if (active_sample_count > 1) {
                            draw_options.sample_position = if (active_custom_sample_positions)
                                .{ active_sample_positions[sample_index].x, active_sample_positions[sample_index].y }
                            else
                                raster3d.defaultSamplePosition(active_sample_count, sample_index);
                        }
                        for (0..resolved_patch.patch_count) |local_patch| {
                            const draw_patch_index = std.math.add(usize, resolved_patch.patch_start, local_patch) catch
                                return self.fail(error.InvalidArgument);
                            const factor_offset = std.math.add(usize, std.math.add(usize, resolved_patch.factor_buffer_offset, std.math.mul(usize, instance_id, resolved_patch.factor_instance_stride) catch return self.fail(error.InvalidArgument)) catch
                                return self.fail(error.InvalidArgument), std.math.mul(usize, draw_patch_index, factor_entry_size) catch return self.fail(error.InvalidArgument)) catch
                                return self.fail(error.InvalidArgument);
                            const factor_bytes_slice = resolved_patch.factor_buffer.bytes;
                            const edge0 = readF16Little(factor_bytes_slice, factor_offset);
                            const edge1 = readF16Little(factor_bytes_slice, factor_offset + 2);
                            const edge2 = readF16Little(factor_bytes_slice, factor_offset + 4);
                            const inside = readF16Little(factor_bytes_slice, factor_offset + 6);
                            if (!std.math.isFinite(edge0) or !std.math.isFinite(edge1) or !std.math.isFinite(edge2) or
                                !std.math.isFinite(inside)) return self.fail(error.InvalidArgument);
                            const scaled_edge0 = edge0 * resolved_patch.factor_scale;
                            const scaled_edge1 = edge1 * resolved_patch.factor_scale;
                            const scaled_edge2 = edge2 * resolved_patch.factor_scale;
                            const scaled_inside = inside * resolved_patch.factor_scale;
                            if (edge0 <= 0 or edge1 <= 0 or edge2 <= 0 or inside <= 0 or
                                !std.math.isFinite(scaled_edge0) or !std.math.isFinite(scaled_edge1) or
                                !std.math.isFinite(scaled_edge2) or !std.math.isFinite(scaled_inside)) continue;
                            if (scaled_edge0 != scaled_edge1 or scaled_edge0 != scaled_edge2 or
                                scaled_edge0 != scaled_inside)
                                return self.fail(error.UnsupportedOperation);
                            const tessellation_factor = partitionTessellationFactor(
                                scaled_edge0,
                                resolved_patch.partition_mode,
                                resolved_patch.max_tessellation_factor,
                            ) orelse return self.fail(error.UnsupportedOperation);
                            if ((resolved_patch.partition_mode == cpu_tessellation_partition_fractional_odd or
                                resolved_patch.partition_mode == cpu_tessellation_partition_fractional_even) and
                                draw_options.fill_mode == .lines)
                                return self.fail(error.UnsupportedOperation);

                            const patch_index = if (resolved_patch.patch_index_buffer) |buffer|
                                readU32Little(buffer.bytes, resolved_patch.patch_index_buffer_offset + local_patch * @sizeOf(u32))
                            else
                                @as(u32, @intCast(draw_patch_index));
                            const patch_index_usize: usize = patch_index;
                            var patch_vertices: [3]abi.Vertex = undefined;
                            for (0..3) |control_point| {
                                var source_index: usize = undefined;
                                if (resolved_patch.control_point_index_buffer) |buffer| {
                                    const index_size: usize = switch (resolved_patch.control_point_index_type) {
                                        .uint16 => @sizeOf(u16),
                                        .uint32 => @sizeOf(u32),
                                        .none => return self.fail(error.InvalidArgument),
                                    };
                                    const index_offset = std.math.add(usize, resolved_patch.control_point_index_buffer_offset, std.math.mul(usize, std.math.add(usize, std.math.mul(usize, patch_index_usize, resolved_patch.control_point_count) catch return self.fail(error.InvalidArgument), control_point) catch return self.fail(error.InvalidArgument), index_size) catch return self.fail(error.InvalidArgument)) catch
                                        return self.fail(error.InvalidArgument);
                                    source_index = if (index_size == @sizeOf(u16))
                                        readU16Little(buffer.bytes, index_offset)
                                    else
                                        readU32Little(buffer.bytes, index_offset);
                                } else {
                                    source_index = std.math.add(usize, std.math.mul(usize, patch_index_usize, resolved_patch.control_point_count) catch return self.fail(error.InvalidArgument), control_point) catch return self.fail(error.InvalidArgument);
                                }
                                if (source_index >= source_vertices.len) return self.fail(error.InvalidArgument);
                                patch_vertices[control_point] = source_vertices[source_index];
                            }
                            var tessellated_vertices: [cpu_patch_max_mesh_vertices]abi.Vertex = undefined;
                            const draw_vertices: []const abi.Vertex = if (tessellation_factor == 1 or draw_options.fill_mode == .fill)
                                &patch_vertices
                            else
                                tessellated_vertices[0..tessellateUniformPatch(patch_vertices, tessellation_factor, &tessellated_vertices)];
                            stats = addRasterStats(stats, raster3d.drawWithTargetMipmaps(
                                @constCast(&target),
                                extra_targets[0..sample_extra_count],
                                null,
                                &.{},
                                depth_values,
                                stencil_values,
                                draw_vertices,
                                .triangle,
                                draw_options,
                            ));
                        }
                    }
                }
                if (resolved_patch.visibility_mode != .disabled) {
                    const visibility_buffer = resolved_patch.visibility_buffer orelse return self.fail(error.InvalidResource);
                    if (!validBuffer(visibility_buffer) or visibility_buffer.device != self.queue.device or
                        !rangeValid(visibility_buffer.bytes.len, resolved_patch.visibility_offset, @sizeOf(u64)))
                        return self.fail(error.InvalidArgument);
                    if (resolved_patch.visibility_result_type == .reset and
                        !visibilitySlotSeen(reset_visibility_slots.items, visibility_buffer, resolved_patch.visibility_offset))
                    {
                        writeU64Little(visibility_buffer.bytes, resolved_patch.visibility_offset, 0);
                        reset_visibility_slots.append(allocator, .{ .buffer = visibility_buffer, .offset = resolved_patch.visibility_offset }) catch return self.fail(error.OutOfMemory);
                    }
                    const previous = readU64Little(visibility_buffer.bytes, resolved_patch.visibility_offset);
                    const result = switch (resolved_patch.visibility_mode) {
                        .disabled => unreachable,
                        .boolean => @max(previous, if (stats.fragments_covered != 0) @as(u64, 1) else 0),
                        .counting => previous +| stats.fragments_covered,
                    };
                    writeU64Little(visibility_buffer.bytes, resolved_patch.visibility_offset, result);
                }
            },
            .copy_buffer => |copy| {
                if (!validBuffer(copy.source) or !validBuffer(copy.destination)) return self.fail(error.InvalidResource);
                if (copy.source.device != copy.destination.device) return self.fail(error.InvalidResource);
                if (!rangeValid(copy.source.bytes.len, copy.source_offset, copy.length) or !rangeValid(copy.destination.bytes.len, copy.destination_offset, copy.length)) return self.fail(error.InvalidArgument);
                sparseSyncBuffer(copy.source);
                sparseSyncBuffer(copy.destination);
                defer {
                    sparseFlushBuffer(copy.source);
                    sparseFlushBuffer(copy.destination);
                }
                if (copy.length != 0) @memcpy(copy.destination.bytes[copy.destination_offset .. copy.destination_offset + copy.length], copy.source.bytes[copy.source_offset .. copy.source_offset + copy.length]);
            },
            .copy_buffer_to_texture => |copy| {
                if (!validBuffer(copy.buffer) or !validTexture(copy.texture)) return self.fail(error.InvalidResource);
                if (copy.buffer.device != copy.texture.device) return self.fail(error.InvalidResource);
                sparseSyncBuffer(copy.buffer);
                sparseSyncTexture(copy.texture);
                defer sparseFlushBuffer(copy.buffer);
                defer sparseFlushTexture(copy.texture);
                copyBufferToTexture(copy) catch |err| return self.fail(err);
            },
            .copy_texture_to_buffer => |copy| {
                if (!validTexture(copy.texture) or !validBuffer(copy.buffer)) return self.fail(error.InvalidResource);
                if (copy.texture.device != copy.buffer.device) return self.fail(error.InvalidResource);
                sparseSyncTexture(copy.texture);
                sparseSyncBuffer(copy.buffer);
                defer sparseFlushTexture(copy.texture);
                defer sparseFlushBuffer(copy.buffer);
                copyTextureToBuffer(copy) catch |err| return self.fail(err);
            },
            .copy_texture_to_texture => |copy| {
                if (!validTexture(copy.source) or !validTexture(copy.destination)) return self.fail(error.InvalidResource);
                if (copy.source.device != copy.destination.device or copy.source.format != copy.destination.format) return self.fail(error.InvalidResource);
                sparseSyncTexture(copy.source);
                sparseSyncTexture(copy.destination);
                defer sparseFlushTexture(copy.source);
                defer sparseFlushTexture(copy.destination);
                copyTextureToTexture(copy) catch |err| return self.fail(err);
            },
            .generate_mipmap => |mipmap| {
                if (!validTexture(mipmap.source) or !validTexture(mipmap.destination)) return self.fail(error.InvalidResource);
                if (mipmap.source.device != mipmap.destination.device) return self.fail(error.InvalidResource);
                sparseSyncTexture(mipmap.source);
                sparseSyncTexture(mipmap.destination);
                defer sparseFlushTexture(mipmap.source);
                defer sparseFlushTexture(mipmap.destination);
                generateMipmap(mipmap) catch |err| return self.fail(err);
            },
            .generate_srgb_mipmap_chain => |mipmap| {
                if (mipmap.levels.len < 2) return self.fail(error.InvalidArgument);
                for (mipmap.levels) |level| {
                    if (!validTexture(level) or level.device != self.queue.device) return self.fail(error.InvalidResource);
                    sparseSyncTexture(level);
                }
                defer for (mipmap.levels) |level| sparseFlushTexture(level);
                generateSrgb8MipmapChain(mipmap.levels) catch |err| return self.fail(err);
            },
            .generate_mipmap_3d => |mipmap| {
                if (!validTexture(mipmap.source0) or !validTexture(mipmap.destination) or
                    (mipmap.source1 != null and !validTexture(mipmap.source1.?))) return self.fail(error.InvalidResource);
                if (mipmap.source0.device != mipmap.destination.device or
                    (mipmap.source1 != null and mipmap.source1.?.device != mipmap.destination.device)) return self.fail(error.InvalidResource);
                sparseSyncTexture(mipmap.source0);
                sparseSyncOptionalTexture(mipmap.source1);
                sparseSyncTexture(mipmap.destination);
                defer sparseFlushTexture(mipmap.source0);
                defer sparseFlushOptionalTexture(mipmap.source1);
                defer sparseFlushTexture(mipmap.destination);
                generateMipmap3D(mipmap) catch |err| return self.fail(err);
            },
            .generate_mipmap_3d_array => |mipmap| {
                if (!validTexture(mipmap.destination) or mipmap.source_planes.len == 0) return self.fail(error.InvalidResource);
                for (mipmap.source_planes) |source| {
                    if (!validTexture(source) or source.device != self.queue.device) return self.fail(error.InvalidResource);
                }
                if (mipmap.destination.device != self.queue.device) return self.fail(error.InvalidResource);
                for (mipmap.source_planes) |source| sparseSyncTexture(source);
                sparseSyncTexture(mipmap.destination);
                defer for (mipmap.source_planes) |source| sparseFlushTexture(source);
                defer sparseFlushTexture(mipmap.destination);
                generateSrgb8Mipmap3DArray(mipmap) catch |err| return self.fail(err);
            },
            .fill_buffer => |fill| {
                if (!validBuffer(fill.buffer)) return self.fail(error.InvalidResource);
                if (!rangeValid(fill.buffer.bytes.len, fill.offset, fill.length)) return self.fail(error.InvalidArgument);
                sparseSyncBuffer(fill.buffer);
                defer sparseFlushBuffer(fill.buffer);
                @memset(fill.buffer.bytes[fill.offset .. fill.offset + fill.length], fill.value);
            },
            .compute_buffer_add => |compute| {
                sparseSyncBuffer(compute.left);
                sparseSyncBuffer(compute.right);
                sparseSyncBuffer(compute.output);
                sparseSyncOptionalBuffer(compute.indirect_buffer);
                defer sparseFlushBuffer(compute.left);
                defer sparseFlushBuffer(compute.right);
                defer sparseFlushBuffer(compute.output);
                defer sparseFlushOptionalBuffer(compute.indirect_buffer);
                var resolved = compute;
                if (compute.indirect_buffer) |indirect_buffer| {
                    if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.queue.device or
                        !rangeValid(indirect_buffer.bytes.len, compute.indirect_buffer_offset, if (compute.indirect_threads) 2 * @sizeOf(abi.Size) else @sizeOf(abi.Size)))
                        return self.fail(error.InvalidArgument);
                    if (compute.indirect_threads) {
                        resolved.threads_per_grid = .{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 4),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 8),
                        };
                        resolved.threads_per_threadgroup = .{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 12),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 16),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 20),
                        };
                    } else {
                        const groups = abi.Size{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 4),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 8),
                        };
                        const grid_width = std.math.mul(u64, groups.width, compute.threads_per_threadgroup.width) catch
                            return self.fail(error.InvalidArgument);
                        const grid_height = std.math.mul(u64, groups.height, compute.threads_per_threadgroup.height) catch
                            return self.fail(error.InvalidArgument);
                        const grid_depth = std.math.mul(u64, groups.depth, compute.threads_per_threadgroup.depth) catch
                            return self.fail(error.InvalidArgument);
                        if (grid_width > std.math.maxInt(u32) or grid_height > std.math.maxInt(u32) or
                            grid_depth > std.math.maxInt(u32)) return self.fail(error.InvalidArgument);
                        resolved.threads_per_grid = .{
                            .width = @intCast(grid_width),
                            .height = @intCast(grid_height),
                            .depth = @intCast(grid_depth),
                        };
                    }
                }
                executeBufferAdd(resolved) catch |err| return self.fail(err);
            },
            .compute => |compute| {
                sparseSyncOptionalBuffer(compute.buffer);
                sparseSyncOptionalBuffer(compute.acceleration_structure);
                sparseSyncOptionalBuffer(compute.indirect_buffer);
                if (compute.source_texture) |source| {
                    if (!validTexture(source) or source.device != self.queue.device) return self.fail(error.InvalidResource);
                    sparseSyncTexture(source);
                }
                if (compute.texture) |texture| sparseSyncTexture(texture);
                defer {
                    sparseFlushOptionalBuffer(compute.buffer);
                    sparseFlushOptionalBuffer(compute.acceleration_structure);
                    sparseFlushOptionalBuffer(compute.indirect_buffer);
                    if (compute.source_texture) |source| sparseFlushTexture(source);
                    if (compute.texture) |texture| sparseFlushTexture(texture);
                }
                var resolved = compute;
                if (compute.indirect_buffer) |indirect_buffer| {
                    if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.queue.device or
                        !rangeValid(indirect_buffer.bytes.len, compute.indirect_buffer_offset, if (compute.indirect_threads) 2 * @sizeOf(abi.Size) else @sizeOf(abi.Size)))
                    {
                        return self.fail(error.InvalidArgument);
                    }
                    if (compute.indirect_threads) {
                        resolved.threads_per_grid = .{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 4),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 8),
                        };
                        resolved.threads_per_threadgroup = .{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 12),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 16),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 20),
                        };
                        if ((compute.kernel != 3 and compute.kernel != 4 and compute.kernel != 29 and resolved.threads_per_grid.depth != 1) or
                            resolved.threads_per_threadgroup.width == 0 or
                            resolved.threads_per_threadgroup.height == 0 or
                            resolved.threads_per_threadgroup.depth == 0) return self.fail(error.InvalidArgument);
                    } else {
                        const groups = abi.Size{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 4),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 8),
                        };
                        if ((compute.kernel != 3 and compute.kernel != 4 and compute.kernel != 29 and groups.depth != 1) or compute.threads_per_threadgroup.depth == 0 or
                            compute.threads_per_threadgroup.width == 0 or compute.threads_per_threadgroup.height == 0)
                        {
                            return self.fail(error.InvalidArgument);
                        }
                        const grid_width = std.math.mul(u64, groups.width, compute.threads_per_threadgroup.width) catch return self.fail(error.InvalidArgument);
                        const grid_height = std.math.mul(u64, groups.height, compute.threads_per_threadgroup.height) catch return self.fail(error.InvalidArgument);
                        if (grid_width > std.math.maxInt(u32) or grid_height > std.math.maxInt(u32)) return self.fail(error.InvalidArgument);
                        resolved.threads_per_grid = .{
                            .width = @intCast(grid_width),
                            .height = @intCast(grid_height),
                            .depth = if (compute.kernel == 3 or compute.kernel == 4) groups.depth else 1,
                        };
                    }
                }
                if (resolved.array_slice) |slice| {
                    if ((resolved.kernel == 3 or resolved.kernel == 4) and resolved.threads_per_grid.depth <= slice) continue;
                }
                executeCompute(resolved) catch |err| return self.fail(err);
            },
            .synchronize_buffer => |buffer| {
                if (!validBuffer(buffer)) return self.fail(error.InvalidResource);
                sparseSyncBuffer(buffer);
            },
            .sparse_buffer_mapping => |mapping| {
                if (!validBuffer(mapping.buffer) or mapping.buffer.device != self.queue.device) return self.fail(error.InvalidResource);
                sparseUpdateBufferMapping(mapping.buffer, mapping.mode, mapping.offset, mapping.length) catch |err| return self.fail(err);
            },
            .sparse_buffer_copy_mapping => |mapping| {
                if (!validBuffer(mapping.source) or !validBuffer(mapping.destination) or
                    mapping.source.device != self.queue.device or mapping.destination.device != self.queue.device)
                    return self.fail(error.InvalidResource);
                sparseCopyBufferMappings(mapping.source, mapping.destination, mapping.source_offset, mapping.destination_offset, mapping.length) catch |err| return self.fail(err);
            },
            .sparse_texture_mapping => |mapping| {
                if (!validTexture(mapping.texture) or mapping.texture.device != self.queue.device) return self.fail(error.InvalidResource);
                sparseUpdateTextureMapping(mapping.texture, mapping.mode, mapping.region) catch |err| return self.fail(err);
            },
            .sparse_texture_mapping_indirect => |mapping| {
                if (!validTexture(mapping.texture) or !validBuffer(mapping.buffer) or
                    mapping.texture.device != self.queue.device or mapping.buffer.device != self.queue.device)
                    return self.fail(error.InvalidResource);
                sparseUpdateTextureMappingIndirect(mapping.texture, mapping.mode, mapping.buffer, mapping.buffer_offset) catch |err| return self.fail(err);
            },
            .sparse_texture_move_mapping => |mapping| {
                if (!validTexture(mapping.source) or !validTexture(mapping.destination) or
                    mapping.source.device != self.queue.device or mapping.destination.device != self.queue.device)
                    return self.fail(error.InvalidResource);
                sparseMoveTextureMappings(mapping.source, mapping.destination, mapping.source_region, mapping.destination_origin) catch |err| return self.fail(err);
            },
            .sparse_texture_copy_mapping => |mapping| {
                if (!validTexture(mapping.source) or !validTexture(mapping.destination) or
                    mapping.source.device != self.queue.device or mapping.destination.device != self.queue.device)
                    return self.fail(error.InvalidResource);
                sparseCopyTextureMappings(mapping.source, mapping.destination, mapping.source_region, mapping.destination_origin) catch |err| return self.fail(err);
            },
            .external_callback => |callback| {
                if (callback.callback(callback.context) != 0) return self.fail(error.InvalidCommand);
            },
            .update_fence => |fence| {
                if (!validFence(fence) or fence.device != self.queue.device) return self.fail(error.InvalidResource);
                fence.signaled = true;
            },
            .wait_fence => |fence| {
                if (!validFence(fence) or fence.device != self.queue.device) return self.fail(error.InvalidResource);
                if (!fence.signaled) return self.fail(error.InvalidCommand);
            },
            .signal_event => |signal| {
                if (!validSharedEvent(signal.event) or signal.event.device != self.queue.device) return self.fail(error.InvalidResource);
                _ = std.c.pthread_mutex_lock(&signal.event.mutex);
                if (signal.value < signal.event.signaled_value) {
                    _ = std.c.pthread_mutex_unlock(&signal.event.mutex);
                    return self.fail(error.InvalidCommand);
                }
                signal.event.signaled_value = signal.value;
                _ = std.c.pthread_cond_broadcast(&signal.event.condition);
                _ = std.c.pthread_mutex_unlock(&signal.event.mutex);
            },
            .wait_event => |wait| {
                if (!validSharedEvent(wait.event) or wait.event.device != self.queue.device) return self.fail(error.InvalidResource);
                _ = std.c.pthread_mutex_lock(&wait.event.mutex);
                const signaled = wait.event.signaled_value >= wait.value;
                _ = std.c.pthread_mutex_unlock(&wait.event.mutex);
                if (!signaled) return self.fail(error.InvalidCommand);
            },
        };
        resolveMultisampleColorAttachments(
            active_sample_targets,
            active_sample_color_attachments,
            active_sample_count,
            active_resolve_targets,
        ) catch |err| return self.fail(err);
        resolveMultisampleColorAttachmentArrays(
            active_sample_array_color_attachments,
            active_array_target_count,
            active_sample_count,
            active_sample_array_resolve_targets,
        ) catch |err| return self.fail(err);
        sparseFlushOptionalTexture(active_target);
        for (active_color_attachments) |attachment| sparseFlushOptionalTexture(attachment);
        for (active_array_color_attachments) |attachment_layers| {
            for (attachment_layers[0..active_array_target_count]) |attachment| sparseFlushOptionalTexture(attachment);
        }
        for (active_sample_targets[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
        for (active_sample_color_attachments) |sample| sparseFlushOptionalTexture(sample);
        for (active_sample_array_color_attachments) |attachment_layers| {
            for (attachment_layers[0..active_array_target_count]) |layer_samples| {
                for (layer_samples[0..active_sample_count]) |sample| sparseFlushOptionalTexture(sample);
            }
        }
        self.status = .completed;
    }

    pub fn markError(self: *CommandBuffer) void {
        if (self.magic == command_buffer_magic and self.status == .created) {
            self.active_encoder = .none;
            self.status = .failed;
        }
    }

    fn fail(self: *CommandBuffer, err: Error) Error!void {
        self.status = .failed;
        return err;
    }
};

pub const RenderEncoder = struct {
    magic: u64 = render_encoder_magic,
    command_buffer: *CommandBuffer,
    begin_index: usize,
    pipeline_sample_count: u8 = 1,
    vertex_amplification_count: u8 = 1,
    vertex_amplification_viewport_offsets: [2]u32 = .{ 0, 0 },
    vertex_amplification_render_target_offsets: [2]u32 = .{ 0, 0 },
    vertex_buffer: ?*Buffer = null,
    vertex_offset: usize = 0,
    vertex_stride: usize = @sizeOf(abi.Vertex),
    inline_vertices: std.ArrayList(abi.Vertex) = .empty,
    viewport: raster3d.PreciseViewport,
    viewport_array: [max_viewport_count]raster3d.PreciseViewport = undefined,
    viewport_array_count: u8 = 1,
    scissor: abi.ScissorRect,
    scissor_array: [max_viewport_count]abi.ScissorRect = undefined,
    scissor_array_count: u8 = 1,
    cull_mode: abi.CullMode = .none,
    winding: abi.Winding = .clockwise,
    fill_mode: abi.TriangleFillMode = .fill,
    depth_clip_mode: abi.DepthClipMode = .clip,
    depth_bias: f32 = 0,
    slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_test_min_bound: f32 = 0,
    depth_test_max_bound: f32 = 1,
    fragment_texture: ?*Texture = null,
    fragment_mipmaps: std.ArrayList(*Texture) = .empty,
    sample_texture: bool = false,
    sample_min_filter: abi.SamplerFilter = .nearest,
    sample_mag_filter: abi.SamplerFilter = .nearest,
    sample_mip_filter: abi.SamplerMipFilter = .not_mipmapped,
    sample_lod_min_clamp: f32 = 0,
    sample_lod_max_clamp: f32 = std.math.floatMax(f32),
    sample_lod_bias: f32 = 0,
    sample_max_anisotropy: u32 = 1,
    sample_normalized_coordinates: bool = true,
    sample_reduction_mode: abi.SamplerReductionMode = .weighted_average,
    sample_address_s: abi.SamplerAddressMode = .clamp_to_edge,
    sample_address_t: abi.SamplerAddressMode = .clamp_to_edge,
    sample_border_color: abi.SamplerBorderColor = .transparent_black,
    sample_swizzle: abi.TextureSwizzleChannels = .{
        .red = .red,
        .green = .green,
        .blue = .blue,
        .alpha = .alpha,
    },
    rasterization_enabled: bool = true,
    // Metal starts a render encoder with no depth/stencil state bound. Model
    // that state explicitly through an always-pass, no-write depth test until
    // setDepthCompareFunction installs a real depth state.
    depth_compare: abi.CompareFunction = .always,
    depth_write_enabled: bool = false,
    blending_enabled: bool = false,
    source_rgb_factor: abi.BlendFactor = .one,
    destination_rgb_factor: abi.BlendFactor = .zero,
    rgb_operation: abi.BlendOperation = .add,
    source_alpha_factor: abi.BlendFactor = .one,
    destination_alpha_factor: abi.BlendFactor = .zero,
    alpha_operation: abi.BlendOperation = .add,
    color_write_mask: u8 = @intFromEnum(abi.ColorWriteMask.all),
    write_extra_targets: bool = false,
    color_attachment_map: [8]u8 = identity_color_attachment_map,
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_front: raster3d.StencilFace = .{},
    stencil_back: raster3d.StencilFace = .{},
    fragment_color: ?[4]f32 = null,
    fragment_uniform_enabled: bool = false,
    fragment_position_gradient_enabled: bool = false,
    fragment_uniform_buffer: ?*Buffer = null,
    fragment_uniform_buffer_offset: usize = 0,
    visibility_buffer: ?*Buffer = null,
    visibility_mode: abi.VisibilityResultMode = .disabled,
    visibility_offset: usize = 0,
    visibility_result_type: abi.VisibilityResultType = .reset,
    tessellation_factor_buffer: ?*Buffer = null,
    tessellation_factor_buffer_offset: usize = 0,
    tessellation_factor_buffer_instance_stride: usize = @sizeOf(u16) * 4,
    tessellation_factor_scale: f32 = 1,
    tessellation_partition_mode: u8 = cpu_tessellation_partition_integer,
    patch_max_tessellation_factor: usize = 1,

    pub fn deinit(self: *RenderEncoder) void {
        self.inline_vertices.deinit(allocator);
        self.fragment_mipmaps.deinit(allocator);
        self.magic = 0;
    }

    fn open(self: *const RenderEncoder) bool {
        return self.magic == render_encoder_magic and self.command_buffer.active_encoder == .render;
    }

    fn options(self: *const RenderEncoder) raster3d.DrawOptions {
        return .{
            .viewport = self.viewport,
            .scissor = self.scissor,
            .cull_mode = self.cull_mode,
            .winding = self.winding,
            .fill_mode = self.fill_mode,
            .depth_clip_mode = self.depth_clip_mode,
            .depth_bias = self.depth_bias,
            .slope_scale = self.slope_scale,
            .depth_bias_clamp = self.depth_bias_clamp,
            .depth_test_min_bound = self.depth_test_min_bound,
            .depth_test_max_bound = self.depth_test_max_bound,
            .sample_min_filter = self.sample_min_filter,
            .sample_mag_filter = self.sample_mag_filter,
            .sample_mip_filter = self.sample_mip_filter,
            .sample_lod_min_clamp = self.sample_lod_min_clamp,
            .sample_lod_max_clamp = self.sample_lod_max_clamp,
            .sample_lod_bias = self.sample_lod_bias,
            .sample_max_anisotropy = self.sample_max_anisotropy,
            .sample_normalized_coordinates = self.sample_normalized_coordinates,
            .sample_reduction_mode = self.sample_reduction_mode,
            .sample_address_s = self.sample_address_s,
            .sample_address_t = self.sample_address_t,
            .sample_border_color = self.sample_border_color,
            .sample_swizzle = self.sample_swizzle,
            .rasterization_enabled = self.rasterization_enabled,
            .depth_compare = self.depth_compare,
            .depth_write_enabled = self.depth_write_enabled,
            .blending_enabled = self.blending_enabled,
            .source_rgb_factor = self.source_rgb_factor,
            .destination_rgb_factor = self.destination_rgb_factor,
            .rgb_operation = self.rgb_operation,
            .source_alpha_factor = self.source_alpha_factor,
            .destination_alpha_factor = self.destination_alpha_factor,
            .alpha_operation = self.alpha_operation,
            .color_write_mask = self.color_write_mask,
            .write_extra_targets = self.write_extra_targets,
            .color_attachment_map = self.color_attachment_map,
            .blend_color = self.blend_color,
            .stencil_front = self.stencil_front,
            .stencil_back = self.stencil_back,
            .fragment_position_gradient_enabled = self.fragment_position_gradient_enabled,
            .fragment_color = if (self.fragment_uniform_enabled) self.fragment_color else null,
        };
    }

    pub fn setPipelineFormats(self: *RenderEncoder, color_format: u16, depth_format: u16) Error!void {
        return self.setPipelineFormatsWithStencil(color_format, depth_format, 0);
    }

    pub fn setRasterSampleCount(self: *RenderEncoder, sample_count: u8) Error!void {
        if (!self.open() or (sample_count != 1 and sample_count != 2 and sample_count != 4)) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| if (begin_render.sample_count != sample_count) return error.InvalidArgument,
            else => return error.InvalidCommand,
        }
        self.pipeline_sample_count = sample_count;
    }

    pub fn setSamplePositions(self: *RenderEncoder, positions: ?[*]const abi.SamplePosition, count: usize) Error!void {
        // Apple's custom-position API accepts only the supported multisample
        // counts. A single sample uses the fixed 0.5/0.5 center and cannot
        // be configured through this selector on the native M4 path.
        if (!self.open() or !validMetalSamplePositionCount(count) or
            (count != 0 and positions == null)) return error.InvalidArgument;
        const values = positions orelse undefined;
        var sample_positions: [4]abi.SamplePosition = .{
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
            .{ .x = 0.5, .y = 0.5 },
        };
        if (count != 0) {
            for (values[0..count], 0..) |position, index| {
                if (!validMetalSamplePosition(position.x) or !validMetalSamplePosition(position.y))
                    return error.InvalidArgument;
                // Apple programmable sample positions use the top-left pixel
                // grid with 1/16-pixel coordinates. Keep the public descriptor
                // values untouched, but quantize the CPU raster state to the
                // same hardware grid before coverage is evaluated.
                sample_positions[index] = .{
                    .x = quantizeMetalSamplePosition(position.x),
                    .y = quantizeMetalSamplePosition(position.y),
                };
            }
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (count != 0 and count != begin_render.sample_count) return error.InvalidArgument;
                begin_render.custom_sample_positions = count != 0;
                begin_render.sample_positions = sample_positions;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setVertexAmplificationCount(
        self: *RenderEncoder,
        count: usize,
        mappings: ?[*]const abi.VertexAmplificationViewMapping,
    ) Error!void {
        // Apple Metal currently exposes a maximum of two amplified views.
        // The CPU profile records up to the Metal viewport/scissor entry limit
        // and resolves the selected entry at commit time, preserving the
        // attachment-global top-left pixel coordinates.
        if (!self.open() or count == 0 or count > 2)
            return error.InvalidArgument;
        var offsets: [2]u32 = .{ 0, 0 };
        var viewport_offsets: [2]u32 = .{ 0, 0 };
        if (mappings) |values| {
            for (values[0..count], 0..) |mapping, index| {
                viewport_offsets[index] = mapping.viewport_array_index_offset;
                offsets[index] = mapping.render_target_array_index_offset;
            }
        }
        self.vertex_amplification_count = @intCast(count);
        self.vertex_amplification_viewport_offsets = viewport_offsets;
        self.vertex_amplification_render_target_offsets = offsets;
    }

    pub fn setMultisampleTargets(self: *RenderEncoder, textures: ?[*]const ?*Texture, count: usize, resolve: ?*Texture) Error!void {
        if (!self.open() or (count != 1 and count != 2 and count != 4) or textures == null) return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !first.format.isColor()) return error.InvalidResource;
        for (values[0..count]) |value| {
            const texture = value orelse return error.InvalidResource;
            if (!validTexture(texture) or texture.device != first.device or !texture.format.isColor() or
                texture.width != first.width or texture.height != first.height or texture.format != first.format) return error.InvalidArgument;
        }
        if (resolve) |target| {
            if (!validTexture(target) or target.device != first.device or !target.format.isColor() or
                target.width != first.width or target.height != first.height or target.format != first.format) return error.InvalidArgument;
            for (values[0..count]) |sample| if (sample.? == target) return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (first != begin_render.target or resolve == first) return error.InvalidArgument;
                begin_render.sample_targets = [_]?*Texture{null} ** 4;
                for (values[0..count], 0..) |value, index| begin_render.sample_targets[index] = value;
                begin_render.sample_count = @intCast(count);
                begin_render.resolve_target = resolve;
                begin_render.resolve_enabled = resolve != null;
            },
            else => return error.InvalidCommand,
        }
        self.pipeline_sample_count = @intCast(count);
    }

    /// Select the ZPU-owned slices used by a direct layered render pass.
    /// Metal's render-target-array index is represented by the direct draw's
    /// instance index; the CPU runtime never creates a native array target.
    pub fn setRenderTargetArray(self: *RenderEncoder, textures: ?[*]const *Texture, count: usize) Error!void {
        if (!self.open() or textures == null or count == 0 or count > 8) return error.InvalidArgument;
        const values = textures.?;
        const first = values[0];
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !first.format.isColor())
            return error.InvalidResource;
        for (values[0..count]) |texture| {
            if (!validTexture(texture) or texture.device != first.device or !texture.format.isColor() or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != 1 or first != begin_render.target) return error.InvalidArgument;
                begin_render.array_targets = [_]?*Texture{null} ** 8;
                for (values[0..count], 0..) |texture, index| begin_render.array_targets[index] = texture;
                begin_render.array_target_count = @intCast(count);
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setColorAttachmentArrayTargets(
        self: *RenderEncoder,
        textures: ?[*]const *Texture,
        count: usize,
        attachment: abi.RenderPassColorAttachmentDescriptor,
        index: u32,
    ) Error!void {
        if (!self.open() or textures == null or index == 0 or index >= 8 or count == 0 or count > 8)
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0];
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !first.format.isColor())
            return error.InvalidResource;
        for (values[0..count]) |texture| {
            if (!validTexture(texture) or texture.device != first.device or !texture.format.isColor() or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != 1 or begin_render.array_target_count != count or
                    first.width != begin_render.target.width or first.height != begin_render.target.height)
                    return error.InvalidArgument;
                var color_attachment = ColorAttachmentCommand{
                    .texture = first,
                    .pass = attachment,
                    .array_target_count = @intCast(count),
                };
                for (values[0..count], 0..) |texture, layer| color_attachment.array_targets[layer] = texture;
                begin_render.color_attachments[index] = color_attachment;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleColorAttachmentTargets(
        self: *RenderEncoder,
        textures: ?[*]const ?*Texture,
        count: usize,
        resolve: ?*Texture,
        attachment: abi.RenderPassColorAttachmentDescriptor,
        index: u32,
    ) Error!void {
        if (!self.open() or index == 0 or index >= 8 or (count != 2 and count != 4) or textures == null)
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !first.format.isColor())
            return error.InvalidResource;
        for (values[0..count]) |value| {
            const texture = value orelse return error.InvalidResource;
            if (!validTexture(texture) or texture.device != first.device or !texture.format.isColor() or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        if (resolve) |target| {
            if (!validTexture(target) or target.device != first.device or !target.format.isColor() or
                target.width != first.width or target.height != first.height or target.format != first.format)
                return error.InvalidArgument;
            for (values[0..count]) |sample| if (sample.? == target) return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != count or first.width != begin_render.target.width or
                    first.height != begin_render.target.height) return error.InvalidArgument;
                var color_attachment = ColorAttachmentCommand{
                    .texture = first,
                    .pass = attachment,
                    .resolve_target = resolve,
                    .resolve_enabled = resolve != null,
                };
                for (values[0..count], 0..) |value, sample_index| {
                    color_attachment.sample_targets[sample_index] = value;
                }
                begin_render.color_attachments[index] = color_attachment;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleColorAttachmentArrayTargets(
        self: *RenderEncoder,
        textures: ?[*]const ?*Texture,
        array_count: usize,
        sample_count: usize,
        resolve_textures: ?[*]const ?*Texture,
        attachment: abi.RenderPassColorAttachmentDescriptor,
        index: u32,
    ) Error!void {
        if (!self.open() or index >= 8 or (sample_count != 2 and sample_count != 4) or
            array_count == 0 or array_count > 8 or textures == null)
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !first.format.isColor())
            return error.InvalidResource;
        for (0..array_count) |layer| {
            for (0..sample_count) |sample_index| {
                const texture = values[layer * sample_count + sample_index] orelse return error.InvalidResource;
                if (!validTexture(texture) or texture.device != first.device or !texture.format.isColor() or
                    texture.width != first.width or texture.height != first.height or texture.format != first.format)
                    return error.InvalidArgument;
            }
        }
        if (resolve_textures) |resolves| {
            for (0..array_count) |layer| {
                const resolve = resolves[layer] orelse return error.InvalidResource;
                if (!validTexture(resolve) or resolve.device != first.device or !resolve.format.isColor() or
                    resolve.width != first.width or resolve.height != first.height or resolve.format != first.format)
                    return error.InvalidArgument;
                for (0..sample_count) |sample_index| {
                    if (values[layer * sample_count + sample_index].? == resolve)
                        return error.InvalidArgument;
                }
            }
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (index == 0) {
                    if (first != begin_render.target or first.width != begin_render.target.width or
                        first.height != begin_render.target.height)
                        return error.InvalidArgument;
                    begin_render.sample_count = @intCast(sample_count);
                    begin_render.array_target_count = @intCast(array_count);
                    for (0..array_count) |layer| {
                        for (0..sample_count) |sample_index| {
                            begin_render.sample_array_targets[layer][sample_index] =
                                values[layer * sample_count + sample_index];
                        }
                        begin_render.sample_array_resolve_targets[layer] =
                            if (resolve_textures) |resolves| resolves[layer] else null;
                    }
                    begin_render.resolve_enabled = resolve_textures != null;
                    begin_render.resolve_target = if (resolve_textures) |resolves| resolves[0] else null;
                } else {
                    if (begin_render.sample_count != sample_count or begin_render.array_target_count != array_count or
                        first.width != begin_render.target.width or first.height != begin_render.target.height)
                        return error.InvalidArgument;
                    var color_attachment = ColorAttachmentCommand{
                        .texture = first,
                        .pass = attachment,
                        .array_target_count = @intCast(array_count),
                        .resolve_enabled = resolve_textures != null,
                    };
                    for (0..array_count) |layer| {
                        for (0..sample_count) |sample_index| {
                            color_attachment.sample_array_targets[layer][sample_index] =
                                values[layer * sample_count + sample_index];
                        }
                        color_attachment.sample_array_resolve_targets[layer] =
                            if (resolve_textures) |resolves| resolves[layer] else null;
                    }
                    color_attachment.resolve_target = if (resolve_textures) |resolves| resolves[0] else null;
                    begin_render.color_attachments[index] = color_attachment;
                }
            },
            else => return error.InvalidCommand,
        }
        self.pipeline_sample_count = @intCast(sample_count);
    }

    pub fn setColorAttachment(self: *RenderEncoder, texture: *Texture, attachment: abi.RenderPassColorAttachmentDescriptor, index: u32) Error!void {
        if (!self.open() or index == 0 or index >= 8 or !validTexture(texture) or
            texture.device != self.command_buffer.queue.device or !texture.format.isColor() or
            @intFromEnum(attachment.load_action) > @intFromEnum(abi.LoadAction.clear) or
            @intFromEnum(attachment.store_action) > @intFromEnum(abi.StoreAction.store)) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (texture.width != begin_render.target.width or texture.height != begin_render.target.height) return error.InvalidArgument;
                begin_render.color_attachments[index] = .{ .texture = texture, .pass = attachment };
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setColorAttachmentMap(self: *RenderEncoder, mapping: ?[*]const u8, count: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (mapping == null) {
            if (count != 0) return error.InvalidArgument;
            self.color_attachment_map = identity_color_attachment_map;
            return;
        }
        if (count != identity_color_attachment_map.len) return error.InvalidArgument;
        var values: [8]u8 = undefined;
        @memcpy(&values, mapping.?[0..values.len]);
        if (!validColorAttachmentMap(values)) return error.InvalidArgument;
        self.color_attachment_map = values;
    }

    pub fn setColorStoreAction(self: *RenderEncoder, store_action: u8, index: u32) Error!void {
        if (!self.open() or index >= 8 or store_action > 3) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                const requests_resolve = store_action == 2 or store_action == 3;
                if (requests_resolve) {
                    if (begin_render.sample_count == 1) return error.InvalidArgument;
                    if (index == 0) {
                        if (begin_render.resolve_target == null) return error.InvalidArgument;
                    } else if (begin_render.color_attachments[index] == null or
                        begin_render.color_attachments[index].?.resolve_target == null) return error.InvalidArgument;
                }
                const action: abi.StoreAction = if (store_action == 0) .dont_care else .store;
                if (index == 0) begin_render.pass.color.store_action = action;
                if (begin_render.color_attachments[index]) |*attachment| {
                    attachment.pass.store_action = action;
                    if (index != 0) attachment.resolve_enabled = requests_resolve;
                }
                if (index == 0) begin_render.resolve_enabled = requests_resolve;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setDepthStoreAction(self: *RenderEncoder, store_action: u8) Error!void {
        if (!self.open() or store_action > @intFromEnum(abi.StoreAction.store)) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| begin_render.pass.depth.store_action = @enumFromInt(store_action),
            else => return error.InvalidCommand,
        }
    }

    pub fn setStencilStoreAction(self: *RenderEncoder, store_action: u8) Error!void {
        if (!self.open() or store_action > @intFromEnum(abi.StoreAction.store)) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| begin_render.stencil_store_action = @enumFromInt(store_action),
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultiTargetOutput(self: *RenderEncoder, enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.write_extra_targets = enabled;
    }

    pub fn setSampleTexture(self: *RenderEncoder, enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (enabled and self.fragment_position_gradient_enabled) return error.UnsupportedOperation;
        self.sample_texture = enabled;
    }

    pub fn setFragmentTexture(self: *RenderEncoder, texture: ?*Texture, index: u32) Error!void {
        if (!self.open() or index != 0) return error.UnsupportedOperation;
        if (texture) |value| {
            if (!validTexture(value) or value.device != self.command_buffer.queue.device or !value.format.isColor()) return error.InvalidResource;
        }
        self.fragment_texture = texture;
        self.fragment_mipmaps.clearRetainingCapacity();
        if (texture) |value| self.fragment_mipmaps.append(allocator, value) catch return error.OutOfMemory;
        self.sample_swizzle = .{ .red = .red, .green = .green, .blue = .blue, .alpha = .alpha };
    }

    pub fn setFragmentTextureLevels(self: *RenderEncoder, textures: ?[*]const ?*Texture, count: usize, index: u32) Error!void {
        if (!self.open() or index != 0) return error.UnsupportedOperation;
        if (count == 0) {
            self.fragment_texture = null;
            self.fragment_mipmaps.clearRetainingCapacity();
            self.sample_swizzle = .{ .red = .red, .green = .green, .blue = .blue, .alpha = .alpha };
            return;
        }
        const values = textures orelse return error.InvalidArgument;
        for (values[0..count]) |value| {
            const texture = value orelse return error.InvalidResource;
            if (!validTexture(texture) or texture.device != self.command_buffer.queue.device or !texture.format.isColor()) return error.InvalidResource;
        }
        self.fragment_mipmaps.clearRetainingCapacity();
        for (values[0..count]) |value| self.fragment_mipmaps.append(allocator, value.?) catch return error.OutOfMemory;
        self.fragment_texture = self.fragment_mipmaps.items[0];
        self.sample_swizzle = .{ .red = .red, .green = .green, .blue = .blue, .alpha = .alpha };
    }

    fn appendSampleMipmaps(self: *RenderEncoder) Error!struct { start: usize, count: usize } {
        if (!self.sample_texture) return .{ .start = 0, .count = 0 };
        const texture = self.fragment_texture orelse return error.InvalidResource;
        const start = self.command_buffer.sample_mipmaps.items.len;
        if (self.fragment_mipmaps.items.len == 0) {
            self.command_buffer.sample_mipmaps.append(allocator, texture) catch return error.OutOfMemory;
            return .{ .start = start, .count = 1 };
        }
        self.command_buffer.sample_mipmaps.appendSlice(allocator, self.fragment_mipmaps.items) catch return error.OutOfMemory;
        return .{ .start = start, .count = self.fragment_mipmaps.items.len };
    }

    pub fn setFragmentSampler(self: *RenderEncoder, min_filter: u8, mag_filter: u8, address_s: u8, address_t: u8, border_color: u8, mip_filter: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.sample_min_filter = samplerFilterFromInt(min_filter) orelse return error.InvalidArgument;
        self.sample_mag_filter = samplerFilterFromInt(mag_filter) orelse return error.InvalidArgument;
        self.sample_mip_filter = samplerMipFilterFromInt(mip_filter) orelse return error.InvalidArgument;
        self.sample_address_s = samplerAddressModeFromInt(address_s) orelse return error.InvalidArgument;
        self.sample_address_t = samplerAddressModeFromInt(address_t) orelse return error.InvalidArgument;
        self.sample_border_color = samplerBorderColorFromInt(border_color) orelse return error.InvalidArgument;
    }

    pub fn setFragmentSamplerLodClamps(self: *RenderEncoder, lod_min_clamp: f32, lod_max_clamp: f32) Error!void {
        if (!self.open() or !std.math.isFinite(lod_min_clamp) or !std.math.isFinite(lod_max_clamp) or
            lod_min_clamp < 0 or lod_max_clamp < lod_min_clamp) return error.InvalidArgument;
        self.sample_lod_min_clamp = lod_min_clamp;
        self.sample_lod_max_clamp = lod_max_clamp;
    }

    pub fn setFragmentSamplerLodBias(self: *RenderEncoder, lod_bias: f32) Error!void {
        if (!self.open() or !std.math.isFinite(lod_bias) or lod_bias < -16 or lod_bias >= 16) return error.InvalidArgument;
        self.sample_lod_bias = lod_bias;
    }

    pub fn setFragmentSamplerMaxAnisotropy(self: *RenderEncoder, max_anisotropy: u32) Error!void {
        if (!self.open() or max_anisotropy == 0 or max_anisotropy > 16) return error.InvalidArgument;
        self.sample_max_anisotropy = max_anisotropy;
    }

    pub fn setFragmentSamplerNormalizedCoordinates(self: *RenderEncoder, normalized_coordinates: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.sample_normalized_coordinates = normalized_coordinates;
    }

    pub fn setFragmentSamplerReductionMode(self: *RenderEncoder, reduction_mode: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.sample_reduction_mode = samplerReductionModeFromInt(reduction_mode) orelse return error.InvalidArgument;
    }

    pub fn setFragmentTextureSwizzle(self: *RenderEncoder, red: u8, green: u8, blue: u8, alpha: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.sample_swizzle = .{
            .red = textureSwizzleFromInt(red) orelse return error.InvalidArgument,
            .green = textureSwizzleFromInt(green) orelse return error.InvalidArgument,
            .blue = textureSwizzleFromInt(blue) orelse return error.InvalidArgument,
            .alpha = textureSwizzleFromInt(alpha) orelse return error.InvalidArgument,
        };
    }

    pub fn setFragmentUniformEnabled(self: *RenderEncoder, enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.fragment_uniform_enabled = enabled;
    }

    pub fn setFragmentPositionGradientEnabled(self: *RenderEncoder, enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (enabled and self.sample_texture) return error.UnsupportedOperation;
        self.fragment_position_gradient_enabled = enabled;
    }

    pub fn setFragmentBytes(self: *RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) Error!void {
        if (!self.open() or (length != 0 and bytes == null)) return error.InvalidArgument;
        if (!self.fragment_uniform_enabled) return;
        if (index != 0 or length != @sizeOf(abi.Color)) return error.UnsupportedOperation;
        var color: [4]f32 = undefined;
        const raw = bytes.?[0..length];
        for (0..4) |channel| {
            color[channel] = @bitCast(std.mem.readInt(u32, raw[channel * @sizeOf(f32) ..][0..@sizeOf(f32)], .little));
            if (!std.math.isFinite(color[channel])) return error.InvalidArgument;
        }
        self.fragment_uniform_buffer = null;
        self.fragment_uniform_buffer_offset = 0;
        self.fragment_color = color;
    }

    pub fn setFragmentBuffer(self: *RenderEncoder, buffer: ?*Buffer, offset: usize, index: u32) Error!void {
        if (!self.open() or (buffer != null and (!validBuffer(buffer.?) or
            buffer.?.device != self.command_buffer.queue.device or offset > buffer.?.bytes.len))) return error.InvalidArgument;
        if (!self.fragment_uniform_enabled) return;
        if (index != 0) return error.UnsupportedOperation;
        self.fragment_uniform_buffer = buffer;
        self.fragment_uniform_buffer_offset = offset;
        self.fragment_color = null;
    }

    pub fn setFragmentBufferOffset(self: *RenderEncoder, offset: usize, index: u32) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!self.fragment_uniform_enabled) return;
        if (index != 0) return error.UnsupportedOperation;
        const buffer = self.fragment_uniform_buffer orelse return error.InvalidCommand;
        if (offset > buffer.bytes.len) return error.InvalidArgument;
        self.fragment_uniform_buffer_offset = offset;
        self.fragment_color = null;
    }

    pub fn setRasterizationEnabled(self: *RenderEncoder, enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.rasterization_enabled = enabled;
    }

    pub fn setPipelineColorFormats(self: *RenderEncoder, color_formats: []const u16, depth_format: u16, stencil_format: u16) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const expected_depth = switch (depth_format) {
            0 => null,
            @intFromEnum(abi.PixelFormat.depth16_unorm) => abi.PixelFormat.depth16_unorm,
            @intFromEnum(abi.PixelFormat.depth32_float) => abi.PixelFormat.depth32_float,
            @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8) => abi.PixelFormat.depth24_unorm_stencil8,
            @intFromEnum(abi.PixelFormat.depth32_float_stencil8) => abi.PixelFormat.depth32_float_stencil8,
            else => return error.UnsupportedFormat,
        };
        const expected_stencil = switch (stencil_format) {
            0 => null,
            @intFromEnum(abi.PixelFormat.stencil8) => abi.PixelFormat.stencil8,
            @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8) => abi.PixelFormat.depth24_unorm_stencil8,
            @intFromEnum(abi.PixelFormat.depth32_float_stencil8) => abi.PixelFormat.depth32_float_stencil8,
            @intFromEnum(abi.PixelFormat.x32_stencil8) => abi.PixelFormat.x32_stencil8,
            @intFromEnum(abi.PixelFormat.x24_stencil8) => abi.PixelFormat.x24_stencil8,
            else => return error.UnsupportedFormat,
        };
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| {
                if (color_formats.len > 8) return error.InvalidArgument;
                for (begin_render.color_attachments, 0..) |attachment, index| {
                    var logical_index: ?usize = null;
                    for (self.color_attachment_map, 0..) |physical_index, candidate| {
                        if (physical_index == index) {
                            logical_index = candidate;
                            break;
                        }
                    }
                    const expected_color = if (logical_index) |logical| if (logical < color_formats.len) color_formats[logical] else 0 else 0;
                    const expected = switch (expected_color) {
                        0 => null,
                        @intFromEnum(abi.PixelFormat.a8_unorm) => abi.PixelFormat.a8_unorm,
                        @intFromEnum(abi.PixelFormat.r8_unorm) => abi.PixelFormat.r8_unorm,
                        @intFromEnum(abi.PixelFormat.r8_unorm_srgb) => abi.PixelFormat.r8_unorm_srgb,
                        @intFromEnum(abi.PixelFormat.r8_snorm) => abi.PixelFormat.r8_snorm,
                        @intFromEnum(abi.PixelFormat.r8_uint) => abi.PixelFormat.r8_uint,
                        @intFromEnum(abi.PixelFormat.r8_sint) => abi.PixelFormat.r8_sint,
                        @intFromEnum(abi.PixelFormat.r16_unorm) => abi.PixelFormat.r16_unorm,
                        @intFromEnum(abi.PixelFormat.r16_snorm) => abi.PixelFormat.r16_snorm,
                        @intFromEnum(abi.PixelFormat.r16_uint) => abi.PixelFormat.r16_uint,
                        @intFromEnum(abi.PixelFormat.r16_sint) => abi.PixelFormat.r16_sint,
                        @intFromEnum(abi.PixelFormat.r16_float) => abi.PixelFormat.r16_float,
                        @intFromEnum(abi.PixelFormat.rg8_unorm) => abi.PixelFormat.rg8_unorm,
                        @intFromEnum(abi.PixelFormat.rg8_unorm_srgb) => abi.PixelFormat.rg8_unorm_srgb,
                        @intFromEnum(abi.PixelFormat.rg8_snorm) => abi.PixelFormat.rg8_snorm,
                        @intFromEnum(abi.PixelFormat.rg8_uint) => abi.PixelFormat.rg8_uint,
                        @intFromEnum(abi.PixelFormat.rg8_sint) => abi.PixelFormat.rg8_sint,
                        @intFromEnum(abi.PixelFormat.rg16_unorm) => abi.PixelFormat.rg16_unorm,
                        @intFromEnum(abi.PixelFormat.rg16_snorm) => abi.PixelFormat.rg16_snorm,
                        @intFromEnum(abi.PixelFormat.rg16_uint) => abi.PixelFormat.rg16_uint,
                        @intFromEnum(abi.PixelFormat.rg16_sint) => abi.PixelFormat.rg16_sint,
                        @intFromEnum(abi.PixelFormat.rg16_float) => abi.PixelFormat.rg16_float,
                        @intFromEnum(abi.PixelFormat.rgba16_unorm) => abi.PixelFormat.rgba16_unorm,
                        @intFromEnum(abi.PixelFormat.rgba16_snorm) => abi.PixelFormat.rgba16_snorm,
                        @intFromEnum(abi.PixelFormat.rgba16_uint) => abi.PixelFormat.rgba16_uint,
                        @intFromEnum(abi.PixelFormat.rgba16_sint) => abi.PixelFormat.rgba16_sint,
                        @intFromEnum(abi.PixelFormat.rgba8_unorm) => abi.PixelFormat.rgba8_unorm,
                        @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb) => abi.PixelFormat.rgba8_unorm_srgb,
                        @intFromEnum(abi.PixelFormat.rgba8_snorm) => abi.PixelFormat.rgba8_snorm,
                        @intFromEnum(abi.PixelFormat.rgba8_uint) => abi.PixelFormat.rgba8_uint,
                        @intFromEnum(abi.PixelFormat.rgba8_sint) => abi.PixelFormat.rgba8_sint,
                        @intFromEnum(abi.PixelFormat.bgra8_unorm) => abi.PixelFormat.bgra8_unorm,
                        @intFromEnum(abi.PixelFormat.bgra8_unorm_srgb) => abi.PixelFormat.bgra8_unorm_srgb,
                        @intFromEnum(abi.PixelFormat.b5g6r5_unorm) => abi.PixelFormat.b5g6r5_unorm,
                        @intFromEnum(abi.PixelFormat.a1bgr5_unorm) => abi.PixelFormat.a1bgr5_unorm,
                        @intFromEnum(abi.PixelFormat.abgr4_unorm) => abi.PixelFormat.abgr4_unorm,
                        @intFromEnum(abi.PixelFormat.bgr5a1_unorm) => abi.PixelFormat.bgr5a1_unorm,
                        @intFromEnum(abi.PixelFormat.rgb10a2_unorm) => abi.PixelFormat.rgb10a2_unorm,
                        @intFromEnum(abi.PixelFormat.rgb10a2_uint) => abi.PixelFormat.rgb10a2_uint,
                        @intFromEnum(abi.PixelFormat.rg11b10_float) => abi.PixelFormat.rg11b10_float,
                        @intFromEnum(abi.PixelFormat.rgb9e5_float) => abi.PixelFormat.rgb9e5_float,
                        @intFromEnum(abi.PixelFormat.bgr10a2_unorm) => abi.PixelFormat.bgr10a2_unorm,
                        @intFromEnum(abi.PixelFormat.r32_uint) => abi.PixelFormat.r32_uint,
                        @intFromEnum(abi.PixelFormat.r32_sint) => abi.PixelFormat.r32_sint,
                        @intFromEnum(abi.PixelFormat.r32_float) => abi.PixelFormat.r32_float,
                        @intFromEnum(abi.PixelFormat.rgba16_float) => abi.PixelFormat.rgba16_float,
                        @intFromEnum(abi.PixelFormat.rg32_uint) => abi.PixelFormat.rg32_uint,
                        @intFromEnum(abi.PixelFormat.rg32_sint) => abi.PixelFormat.rg32_sint,
                        @intFromEnum(abi.PixelFormat.rg32_float) => abi.PixelFormat.rg32_float,
                        @intFromEnum(abi.PixelFormat.rgba32_uint) => abi.PixelFormat.rgba32_uint,
                        @intFromEnum(abi.PixelFormat.rgba32_sint) => abi.PixelFormat.rgba32_sint,
                        @intFromEnum(abi.PixelFormat.rgba32_float) => abi.PixelFormat.rgba32_float,
                        else => return error.UnsupportedFormat,
                    };
                    const actual = if (attachment) |value| texturePixelFormat(value.texture) else null;
                    // Attachment zero may be the private discarded target
                    // used by a depth/stencil-only pass.
                    if (index == 0 and expected == null and attachment != null) continue;
                    if ((expected == null) != (actual == null)) {
                        const unmapped_physical_attachment = actual != null and
                            !std.mem.eql(u8, &self.color_attachment_map, &identity_color_attachment_map) and
                            (logical_index == null or logical_index.? >= color_formats.len);
                        if (!unmapped_physical_attachment) return error.InvalidArgument;
                    }
                    if (expected) |format| if (actual == null or format != actual.?) return error.InvalidArgument;
                }
                if (expected_depth != null and begin_render.depth == null and begin_render.depth_texture == null and
                    begin_render.depth_sample_targets[0] == null and begin_render.depth_array_targets[0] == null and
                    begin_render.depth_sample_array_targets[0][0] == null) return error.InvalidArgument;
                if (begin_render.depth_texture) |depth_texture| {
                    if (expected_depth == null or texturePixelFormat(depth_texture) != expected_depth.?) return error.InvalidArgument;
                }
                if (expected_stencil != null and begin_render.stencil == null and begin_render.stencil_texture == null and
                    begin_render.stencil_sample_targets[0] == null and begin_render.stencil_array_targets[0] == null and
                    begin_render.stencil_sample_array_targets[0][0] == null) return error.InvalidArgument;
                if (begin_render.stencil_texture) |stencil_texture| {
                    if (expected_stencil == null or texturePixelFormat(stencil_texture) != expected_stencil.?) return error.InvalidArgument;
                }
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setPipelineFormatsWithStencil(self: *RenderEncoder, color_format: u16, depth_format: u16, stencil_format: u16) Error!void {
        const color_formats = [_]u16{color_format};
        return self.setPipelineColorFormats(&color_formats, depth_format, stencil_format);
    }

    pub fn setDepthCompareFunction(self: *RenderEncoder, compare_function: u8, depth_write_enabled: bool) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.depth_compare = switch (compare_function) {
            @intFromEnum(abi.CompareFunction.never) => .never,
            @intFromEnum(abi.CompareFunction.less) => .less,
            @intFromEnum(abi.CompareFunction.equal) => .equal,
            @intFromEnum(abi.CompareFunction.less_equal) => .less_equal,
            @intFromEnum(abi.CompareFunction.greater) => .greater,
            @intFromEnum(abi.CompareFunction.not_equal) => .not_equal,
            @intFromEnum(abi.CompareFunction.greater_equal) => .greater_equal,
            @intFromEnum(abi.CompareFunction.always) => .always,
            else => return error.InvalidArgument,
        };
        self.depth_write_enabled = depth_write_enabled;
    }

    pub fn setBlendState(self: *RenderEncoder, blending_enabled: bool, source_rgb_factor: u8, destination_rgb_factor: u8, rgb_operation: u8, source_alpha_factor: u8, destination_alpha_factor: u8, alpha_operation: u8, color_write_mask: u8) Error!void {
        if (!self.open() or color_write_mask & ~@as(u8, @intFromEnum(abi.ColorWriteMask.all)) != 0) return error.InvalidArgument;
        self.source_rgb_factor = blendFactorFromInt(source_rgb_factor) orelse return error.InvalidArgument;
        self.destination_rgb_factor = blendFactorFromInt(destination_rgb_factor) orelse return error.InvalidArgument;
        self.rgb_operation = blendOperationFromInt(rgb_operation) orelse return error.InvalidArgument;
        self.source_alpha_factor = blendFactorFromInt(source_alpha_factor) orelse return error.InvalidArgument;
        self.destination_alpha_factor = blendFactorFromInt(destination_alpha_factor) orelse return error.InvalidArgument;
        self.alpha_operation = blendOperationFromInt(alpha_operation) orelse return error.InvalidArgument;
        self.blending_enabled = blending_enabled;
        self.color_write_mask = color_write_mask;
    }

    pub fn setBlendColor(self: *RenderEncoder, color: abi.Color) Error!void {
        if (!self.open() or !std.math.isFinite(color.red) or !std.math.isFinite(color.green) or !std.math.isFinite(color.blue) or !std.math.isFinite(color.alpha)) return error.InvalidArgument;
        self.blend_color = .{ color.red, color.green, color.blue, color.alpha };
    }

    pub fn setDepthBuffer(self: *RenderEncoder, depth: ?[*]f32, depth_count: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (depth_count != 0 and depth == null) return error.InvalidArgument;
        const values: ?[]f32 = if (depth) |ptr| ptr[0..depth_count] else null;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                begin_render.depth = values;
                begin_render.depth_texture = null;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setDepthTexture(self: *RenderEncoder, texture: *Texture) Error!void {
        if (!self.open() or !validTexture(texture) or texture.device != self.command_buffer.queue.device or
            !isDepthTextureFormat(texture.format)) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| if (begin_render.sample_count > 1) return error.InvalidArgument,
            else => return error.InvalidCommand,
        }
        if (texture.width != self.colorWidth() or texture.height != self.colorHeight()) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                begin_render.depth_texture = null;
                if (texture.format == .depth32_float) {
                    if (@intFromPtr(texture.bytes.ptr) % @alignOf(f32) != 0) return error.InvalidResource;
                    begin_render.depth = @as([*]f32, @ptrCast(@alignCast(texture.bytes.ptr)))[0 .. @as(usize, texture.width) * texture.height];
                } else {
                    begin_render.depth = null;
                    begin_render.depth_texture = texture;
                }
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setDepthTextureArray(self: *RenderEncoder, textures: ?[*]const *Texture, count: usize) Error!void {
        if (!self.open() or textures == null or count < 2 or count > 8) return error.InvalidArgument;
        const values = textures.?;
        const first = values[0];
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !isDepthTextureFormat(first.format))
            return error.InvalidResource;
        for (values[0..count]) |texture| {
            if (!validTexture(texture) or texture.device != first.device or !isDepthTextureFormat(texture.format) or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != 1 or begin_render.array_target_count != count or
                    first.width != begin_render.target.width or first.height != begin_render.target.height)
                    return error.InvalidArgument;
                begin_render.depth_array_targets = [_]?*Texture{null} ** 8;
                for (values[0..count], 0..) |value, index| begin_render.depth_array_targets[index] = value;
                begin_render.depth = null;
                begin_render.depth_texture = null;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleDepthTargets(self: *RenderEncoder, textures: ?[*]const ?*Texture, count: usize) Error!void {
        if (!self.open() or (count != 2 and count != 4) or textures == null) return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !isDepthTextureFormat(first.format))
            return error.InvalidResource;
        for (values[0..count]) |value| {
            const texture = value orelse return error.InvalidResource;
            if (!validTexture(texture) or texture.device != first.device or !isDepthTextureFormat(texture.format) or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != count or first.width != begin_render.target.width or
                    first.height != begin_render.target.height) return error.InvalidArgument;
                begin_render.depth_sample_targets = [_]?*Texture{null} ** 4;
                for (values[0..count], 0..) |value, index| begin_render.depth_sample_targets[index] = value;
                begin_render.depth = null;
                begin_render.depth_texture = null;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleDepthAttachmentArrayTargets(
        self: *RenderEncoder,
        textures: ?[*]const ?*Texture,
        array_count: usize,
        sample_count: usize,
    ) Error!void {
        if (!self.open() or textures == null or array_count == 0 or array_count > 8 or
            (sample_count != 2 and sample_count != 4)) return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !isDepthTextureFormat(first.format))
            return error.InvalidResource;
        for (0..array_count) |layer| {
            for (0..sample_count) |sample_index| {
                const texture = values[layer * sample_count + sample_index] orelse return error.InvalidResource;
                if (!validTexture(texture) or texture.device != first.device or !isDepthTextureFormat(texture.format) or
                    texture.width != first.width or texture.height != first.height or texture.format != first.format)
                    return error.InvalidArgument;
            }
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != sample_count or begin_render.array_target_count != array_count or
                    first.width != begin_render.target.width or first.height != begin_render.target.height)
                    return error.InvalidArgument;
                begin_render.depth_sample_array_targets = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8;
                for (0..array_count) |layer| {
                    for (0..sample_count) |sample_index| {
                        begin_render.depth_sample_array_targets[layer][sample_index] =
                            values[layer * sample_count + sample_index];
                    }
                }
                begin_render.depth_sample_targets = [_]?*Texture{null} ** 4;
                begin_render.depth = null;
                begin_render.depth_texture = null;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setStencilTexture(self: *RenderEncoder, texture: *Texture, load_action: u8, store_action: u8, clear_value: u8) Error!void {
        if (!self.open() or !validTexture(texture) or texture.device != self.command_buffer.queue.device or
            !isStencilTextureFormat(texture.format)) return error.InvalidArgument;
        if (load_action > @intFromEnum(abi.LoadAction.clear) or store_action > @intFromEnum(abi.StoreAction.store) or
            texture.width != self.colorWidth() or texture.height != self.colorHeight()) return error.InvalidArgument;
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| if (begin_render.sample_count > 1) return error.InvalidArgument,
            else => return error.InvalidCommand,
        }
        const stencil: []u8 = texture.bytes[0 .. @as(usize, texture.width) * texture.height];
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                begin_render.stencil = stencil;
                begin_render.stencil_texture = null;
                if (texture.format != .stencil8) {
                    begin_render.stencil = null;
                    begin_render.stencil_texture = texture;
                }
                begin_render.stencil_load_action = @enumFromInt(load_action);
                begin_render.stencil_store_action = @enumFromInt(store_action);
                begin_render.stencil_clear = clear_value;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setStencilTextureArray(
        self: *RenderEncoder,
        textures: ?[*]const *Texture,
        count: usize,
        load_action: u8,
        store_action: u8,
        clear_value: u8,
    ) Error!void {
        if (!self.open() or textures == null or count < 2 or count > 8 or
            load_action > @intFromEnum(abi.LoadAction.clear) or store_action > @intFromEnum(abi.StoreAction.store))
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0];
        if (!validTexture(first) or first.device != self.command_buffer.queue.device or !isStencilTextureFormat(first.format))
            return error.InvalidResource;
        for (values[0..count]) |texture| {
            if (!validTexture(texture) or texture.device != first.device or !isStencilTextureFormat(texture.format) or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != 1 or begin_render.array_target_count != count or
                    first.width != begin_render.target.width or first.height != begin_render.target.height)
                    return error.InvalidArgument;
                begin_render.stencil_array_targets = [_]?*Texture{null} ** 8;
                for (values[0..count], 0..) |value, index| begin_render.stencil_array_targets[index] = value;
                begin_render.stencil = null;
                begin_render.stencil_texture = null;
                begin_render.stencil_load_action = @enumFromInt(load_action);
                begin_render.stencil_store_action = @enumFromInt(store_action);
                begin_render.stencil_clear = clear_value;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleStencilTargets(self: *RenderEncoder, textures: ?[*]const ?*Texture, count: usize, load_action: u8, store_action: u8, clear_value: u8) Error!void {
        if (!self.open() or (count != 2 and count != 4) or textures == null or
            load_action > @intFromEnum(abi.LoadAction.clear) or store_action > @intFromEnum(abi.StoreAction.store))
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or !isStencilTextureFormat(first.format) or
            first.device != self.command_buffer.queue.device)
            return error.InvalidResource;
        for (values[0..count]) |value| {
            const texture = value orelse return error.InvalidResource;
            if (!validTexture(texture) or texture.device != first.device or !isStencilTextureFormat(texture.format) or
                texture.width != first.width or texture.height != first.height or texture.format != first.format)
                return error.InvalidArgument;
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != count or first.width != begin_render.target.width or
                    first.height != begin_render.target.height) return error.InvalidArgument;
                begin_render.stencil_sample_targets = [_]?*Texture{null} ** 4;
                for (values[0..count], 0..) |value, index| begin_render.stencil_sample_targets[index] = value;
                begin_render.stencil = null;
                begin_render.stencil_texture = null;
                begin_render.stencil_load_action = @enumFromInt(load_action);
                begin_render.stencil_store_action = @enumFromInt(store_action);
                begin_render.stencil_clear = clear_value;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setMultisampleStencilAttachmentArrayTargets(
        self: *RenderEncoder,
        textures: ?[*]const ?*Texture,
        array_count: usize,
        sample_count: usize,
        load_action: u8,
        store_action: u8,
        clear_value: u8,
    ) Error!void {
        if (!self.open() or textures == null or array_count == 0 or array_count > 8 or
            (sample_count != 2 and sample_count != 4) or
            load_action > @intFromEnum(abi.LoadAction.clear) or store_action > @intFromEnum(abi.StoreAction.store))
            return error.InvalidArgument;
        const values = textures.?;
        const first = values[0] orelse return error.InvalidResource;
        if (!validTexture(first) or !isStencilTextureFormat(first.format) or
            first.device != self.command_buffer.queue.device)
            return error.InvalidResource;
        for (0..array_count) |layer| {
            for (0..sample_count) |sample_index| {
                const texture = values[layer * sample_count + sample_index] orelse return error.InvalidResource;
                if (!validTexture(texture) or texture.device != first.device or !isStencilTextureFormat(texture.format) or
                    texture.width != first.width or texture.height != first.height or texture.format != first.format)
                    return error.InvalidArgument;
            }
        }
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                if (begin_render.sample_count != sample_count or begin_render.array_target_count != array_count or
                    first.width != begin_render.target.width or first.height != begin_render.target.height)
                    return error.InvalidArgument;
                begin_render.stencil_sample_array_targets = [_][4]?*Texture{[_]?*Texture{null} ** 4} ** 8;
                for (0..array_count) |layer| {
                    for (0..sample_count) |sample_index| {
                        begin_render.stencil_sample_array_targets[layer][sample_index] =
                            values[layer * sample_count + sample_index];
                    }
                }
                begin_render.stencil_sample_targets = [_]?*Texture{null} ** 4;
                begin_render.stencil = null;
                begin_render.stencil_texture = null;
                begin_render.stencil_load_action = @enumFromInt(load_action);
                begin_render.stencil_store_action = @enumFromInt(store_action);
                begin_render.stencil_clear = clear_value;
            },
            else => return error.InvalidCommand,
        }
    }

    pub fn setStencilState(self: *RenderEncoder, front_face: bool, compare: u8, stencil_failure: u8, depth_failure: u8, depth_pass: u8, read_mask: u8, write_mask: u8) Error!void {
        if (!self.open() or compare > @intFromEnum(abi.CompareFunction.always) or
            stencil_failure > @intFromEnum(abi.StencilOperation.decrement_wrap) or
            depth_failure > @intFromEnum(abi.StencilOperation.decrement_wrap) or
            depth_pass > @intFromEnum(abi.StencilOperation.decrement_wrap)) return error.InvalidArgument;
        const state = raster3d.StencilFace{
            .compare = @enumFromInt(compare),
            .stencil_failure = @enumFromInt(stencil_failure),
            .depth_failure = @enumFromInt(depth_failure),
            .depth_pass = @enumFromInt(depth_pass),
            .read_mask = read_mask,
            .write_mask = write_mask,
            .reference = if (front_face) self.stencil_front.reference else self.stencil_back.reference,
        };
        if (front_face) self.stencil_front = state else self.stencil_back = state;
    }

    pub fn setStencilReference(self: *RenderEncoder, front_reference: u8, back_reference: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.stencil_front.reference = front_reference;
        self.stencil_back.reference = back_reference;
    }

    pub fn setVisibilityResultBuffer(self: *RenderEncoder, buffer: ?*Buffer) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (buffer) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device) return error.InvalidResource;
        }
        self.visibility_buffer = buffer;
    }

    pub fn setVisibilityResultMode(self: *RenderEncoder, mode: u8, offset: usize) Error!void {
        if (!self.open() or offset % @sizeOf(u64) != 0) return error.InvalidArgument;
        const parsed: abi.VisibilityResultMode = switch (mode) {
            @intFromEnum(abi.VisibilityResultMode.disabled) => .disabled,
            @intFromEnum(abi.VisibilityResultMode.boolean) => .boolean,
            @intFromEnum(abi.VisibilityResultMode.counting) => .counting,
            else => return error.InvalidArgument,
        };
        if (parsed != .disabled) {
            const buffer = self.visibility_buffer orelse return error.InvalidResource;
            if (!rangeValid(buffer.bytes.len, offset, @sizeOf(u64))) return error.InvalidArgument;
        }
        self.visibility_mode = parsed;
        self.visibility_offset = offset;
    }

    pub fn setVisibilityResultType(self: *RenderEncoder, result_type: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.visibility_result_type = switch (result_type) {
            @intFromEnum(abi.VisibilityResultType.reset) => .reset,
            @intFromEnum(abi.VisibilityResultType.accumulate) => .accumulate,
            else => return error.InvalidArgument,
        };
    }

    pub fn setTessellationFactorBuffer(self: *RenderEncoder, buffer: ?*Buffer, offset: usize, instance_stride: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (buffer == null) {
            self.tessellation_factor_buffer = null;
            self.tessellation_factor_buffer_offset = 0;
            self.tessellation_factor_buffer_instance_stride = @sizeOf(u16) * 4;
            return;
        }
        const factor_buffer = buffer.?;
        if (!validBuffer(factor_buffer) or factor_buffer.device != self.command_buffer.queue.device or
            offset % @alignOf(u32) != 0 or !rangeValid(factor_buffer.bytes.len, offset, @sizeOf(u16) * 4))
            return error.InvalidArgument;
        if (instance_stride != 0 and (instance_stride < @sizeOf(u16) * 4 or instance_stride % @alignOf(u16) != 0))
            return error.InvalidArgument;
        self.tessellation_factor_buffer = factor_buffer;
        self.tessellation_factor_buffer_offset = offset;
        self.tessellation_factor_buffer_instance_stride = if (instance_stride == 0) @sizeOf(u16) * 4 else instance_stride;
    }

    pub fn setTessellationFactorScale(self: *RenderEncoder, scale: f32) Error!void {
        if (!self.open() or !std.math.isFinite(scale) or scale <= 0) return error.InvalidArgument;
        self.tessellation_factor_scale = scale;
    }

    pub fn setTessellationPartitionMode(self: *RenderEncoder, mode: u8) Error!void {
        if (!self.open() or (mode != cpu_tessellation_partition_pow2 and
            mode != cpu_tessellation_partition_integer and
            mode != cpu_tessellation_partition_fractional_odd and
            mode != cpu_tessellation_partition_fractional_even)) return error.InvalidArgument;
        self.tessellation_partition_mode = mode;
    }

    pub fn setPatchMaxTessellationFactor(self: *RenderEncoder, max_factor: usize) Error!void {
        if (!self.open() or max_factor == 0 or max_factor > cpu_patch_max_tessellation_factor)
            return error.InvalidArgument;
        self.patch_max_tessellation_factor = max_factor;
    }

    pub fn updateFence(self: *RenderEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .update_fence = fence });
    }

    pub fn waitForFence(self: *RenderEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .wait_fence = fence });
    }

    fn colorWidth(self: *const RenderEncoder) u32 {
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| return begin_render.target.width,
            else => return 0,
        }
    }

    fn colorHeight(self: *const RenderEncoder) u32 {
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| return begin_render.target.height,
            else => return 0,
        }
    }

    fn renderTargetArrayCount(self: *const RenderEncoder) usize {
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| return begin_render.array_target_count,
            else => return 0,
        }
    }

    pub fn setVertexBuffer(self: *RenderEncoder, buffer: ?*Buffer, offset: usize, index: u32) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (index != 0) return error.UnsupportedOperation;
        if (buffer) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device or offset > value.bytes.len) return error.InvalidArgument;
        }
        // Metal bindings are last-write-wins. A nil buffer must also clear
        // an older setBytes snapshot instead of silently reusing it.
        self.inline_vertices.clearRetainingCapacity();
        self.vertex_buffer = buffer;
        self.vertex_offset = offset;
    }

    pub fn setVertexBufferStride(self: *RenderEncoder, stride: usize) Error!void {
        if (!self.open() or stride < @sizeOf(abi.Vertex)) return error.InvalidArgument;
        self.vertex_stride = stride;
    }

    pub fn setVertexBytes(self: *RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (index != 0) return error.UnsupportedOperation;
        if (length != 0 and bytes == null) return error.InvalidArgument;
        self.inline_vertices.clearRetainingCapacity();
        if (length != 0) {
            const raw = bytes.?[0..length];
            try appendVertexBytes(&self.inline_vertices, raw, self.vertex_stride);
        }
        self.vertex_buffer = null;
        self.vertex_offset = 0;
    }

    pub fn setViewport(self: *RenderEncoder, viewport: abi.Viewport) Error!void {
        return self.setViewportPrecise(.{
            .origin_x = @floatCast(viewport.origin_x),
            .origin_y = @floatCast(viewport.origin_y),
            .width = @floatCast(viewport.width),
            .height = @floatCast(viewport.height),
            .znear = @floatCast(viewport.znear),
            .zfar = @floatCast(viewport.zfar),
        });
    }

    pub fn setViewportPrecise(self: *RenderEncoder, viewport: raster3d.PreciseViewport) Error!void {
        if (!self.open() or !finitePreciseViewport(viewport)) return error.InvalidArgument;
        self.viewport = viewport;
        self.viewport_array[0] = viewport;
        self.viewport_array_count = 1;
    }

    pub fn setViewports(self: *RenderEncoder, viewports: ?[*]const abi.Viewport, count: usize) Error!void {
        if (!self.open() or viewports == null or count == 0 or count > max_viewport_count) return error.InvalidArgument;
        var precise: [max_viewport_count]raster3d.PreciseViewport = undefined;
        for (viewports.?[0..count], 0..) |viewport, index| {
            precise[index] = .{
                .origin_x = @floatCast(viewport.origin_x),
                .origin_y = @floatCast(viewport.origin_y),
                .width = @floatCast(viewport.width),
                .height = @floatCast(viewport.height),
                .znear = @floatCast(viewport.znear),
                .zfar = @floatCast(viewport.zfar),
            };
            if (!finitePreciseViewport(precise[index])) return error.InvalidArgument;
        }
        self.viewport_array = precise;
        self.viewport_array_count = @intCast(count);
        self.viewport = precise[0];
    }

    pub fn setViewportsPrecise(
        self: *RenderEncoder,
        viewports: ?[*]const raster3d.PreciseViewport,
        count: usize,
    ) Error!void {
        if (!self.open() or viewports == null or count == 0 or count > max_viewport_count) return error.InvalidArgument;
        var precise: [max_viewport_count]raster3d.PreciseViewport = undefined;
        for (viewports.?[0..count], 0..) |viewport, index| {
            if (!finitePreciseViewport(viewport)) return error.InvalidArgument;
            precise[index] = viewport;
        }
        self.viewport_array = precise;
        self.viewport_array_count = @intCast(count);
        self.viewport = precise[0];
    }

    pub fn setScissorRect(self: *RenderEncoder, scissor: abi.ScissorRect) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.scissor = scissor;
        self.scissor_array[0] = scissor;
        self.scissor_array_count = 1;
    }

    pub fn setScissorRects(self: *RenderEncoder, scissors: ?[*]const abi.ScissorRect, count: usize) Error!void {
        if (!self.open() or scissors == null or count == 0 or count > max_viewport_count) return error.InvalidArgument;
        var values: [max_viewport_count]abi.ScissorRect = undefined;
        for (scissors.?[0..count], 0..) |scissor, index| values[index] = scissor;
        self.scissor_array = values;
        self.scissor_array_count = @intCast(count);
        self.scissor = values[0];
    }

    pub fn setCullMode(self: *RenderEncoder, cull_mode: abi.CullMode) Error!void {
        if (!self.open() or !validCullMode(cull_mode)) return error.InvalidCommand;
        self.cull_mode = cull_mode;
    }

    pub fn setFrontFacing(self: *RenderEncoder, winding: abi.Winding) Error!void {
        if (!self.open() or !validWinding(winding)) return error.InvalidCommand;
        self.winding = winding;
    }

    pub fn setTriangleFillMode(self: *RenderEncoder, fill_mode: abi.TriangleFillMode) Error!void {
        if (!self.open() or !validFillMode(fill_mode)) return error.InvalidCommand;
        self.fill_mode = fill_mode;
    }

    pub fn setDepthClipMode(self: *RenderEncoder, depth_clip_mode: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.depth_clip_mode = switch (depth_clip_mode) {
            @intFromEnum(abi.DepthClipMode.clip) => .clip,
            @intFromEnum(abi.DepthClipMode.clamp) => .clamp,
            else => return error.InvalidArgument,
        };
    }

    pub fn setDepthBias(self: *RenderEncoder, depth_bias: f32, slope_scale: f32, clamp: f32) Error!void {
        if (!self.open() or !std.math.isFinite(depth_bias) or !std.math.isFinite(slope_scale) or !std.math.isFinite(clamp)) return error.InvalidArgument;
        self.depth_bias = depth_bias;
        self.slope_scale = slope_scale;
        self.depth_bias_clamp = clamp;
    }

    pub fn setDepthTestBounds(self: *RenderEncoder, min_bound: f32, max_bound: f32) Error!void {
        if (!self.open() or !std.math.isFinite(min_bound) or !std.math.isFinite(max_bound) or
            min_bound < 0 or max_bound > 1 or min_bound > max_bound) return error.InvalidArgument;
        self.depth_test_min_bound = min_bound;
        self.depth_test_max_bound = max_bound;
    }

    fn sourceVertices(self: *const RenderEncoder, owned: *?[]abi.Vertex) Error![]const abi.Vertex {
        if (self.vertex_buffer == null and self.inline_vertices.items.len != 0) return self.inline_vertices.items;
        const buffer = self.vertex_buffer orelse return error.InvalidArgument;
        return bufferVertices(buffer, self.vertex_offset, self.vertex_stride, owned);
    }

    pub fn drawPrimitives(self: *RenderEncoder, primitive: abi.PrimitiveType, vertex_start: usize, vertex_count: usize, instance_count: usize) Error!void {
        return self.drawPrimitivesWithBaseInstance(primitive, vertex_start, vertex_count, instance_count, 0);
    }

    pub fn drawPrimitivesWithBaseInstance(self: *RenderEncoder, primitive: abi.PrimitiveType, vertex_start: usize, vertex_count: usize, instance_count: usize, base_instance: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive)) return error.InvalidCommand;
        if (self.sample_texture and self.fragment_texture == null) return error.InvalidResource;
        if (instance_count == 0 or vertex_count == 0) return;
        const array_target_count = self.renderTargetArrayCount();
        if (array_target_count == 0) return error.InvalidArgument;
        if (array_target_count > 1) {
            const last_instance = std.math.add(usize, base_instance, instance_count - 1) catch return error.InvalidArgument;
            if (last_instance >= array_target_count) return error.InvalidArgument;
        }
        if (array_target_count > 1 and instance_count > array_target_count)
            return error.InvalidArgument;
        var owned_source: ?[]abi.Vertex = null;
        const source = try self.sourceVertices(&owned_source);
        defer if (owned_source) |vertices| allocator.free(vertices);
        if (vertex_start > source.len or vertex_count > source.len - vertex_start) return error.InvalidArgument;
        const selected = source[vertex_start .. vertex_start + vertex_count];
        const sample_mipmaps = try self.appendSampleMipmaps();
        var instance: usize = 0;
        while (instance < instance_count) : (instance += 1) {
            const bound_buffer = self.vertex_buffer;
            const start = if (bound_buffer == null) try self.command_buffer.appendVertices(selected) else vertex_start;
            _ = try self.command_buffer.append(.{ .draw = .{
                .vertex_start = start,
                .vertex_count = selected.len,
                .vertex_stride = self.vertex_stride,
                .primitive = primitive,
                .options = self.options(),
                .vertex_buffer = bound_buffer,
                .vertex_buffer_offset = self.vertex_offset,
                .fragment_uniform_enabled = self.fragment_uniform_enabled,
                .fragment_uniform_buffer = self.fragment_uniform_buffer,
                .fragment_uniform_buffer_offset = self.fragment_uniform_buffer_offset,
                .sample_texture = if (self.sample_texture) self.fragment_texture else null,
                .sample_mipmap_start = sample_mipmaps.start,
                .sample_mipmap_count = sample_mipmaps.count,
                .visibility_buffer = self.visibility_buffer,
                .visibility_mode = self.visibility_mode,
                .visibility_offset = self.visibility_offset,
                .visibility_result_type = self.visibility_result_type,
                .array_index = if (array_target_count > 1)
                    std.math.add(usize, base_instance, instance) catch return error.InvalidArgument
                else
                    0,
                .amplification_count = self.vertex_amplification_count,
                .amplification_viewport_offsets = self.vertex_amplification_viewport_offsets,
                .amplification_render_target_offsets = self.vertex_amplification_render_target_offsets,
                .viewport_array = self.viewport_array,
                .viewport_array_count = self.viewport_array_count,
                .scissor_array = self.scissor_array,
                .scissor_array_count = self.scissor_array_count,
            } });
        }
    }

    pub fn drawPrimitivesIndirect(self: *RenderEncoder, primitive: abi.PrimitiveType, indirect_buffer: *Buffer, indirect_buffer_offset: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (indirect_buffer_offset % @alignOf(u32) != 0 or !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 16)) return error.InvalidArgument;
        var owned_source: ?[]abi.Vertex = null;
        const source = try self.sourceVertices(&owned_source);
        defer if (owned_source) |vertices| allocator.free(vertices);
        const bound_buffer = self.vertex_buffer;
        const vertex_start = if (bound_buffer == null) try self.command_buffer.appendVertices(source) else 0;
        const sample_mipmaps = try self.appendSampleMipmaps();
        _ = try self.command_buffer.append(.{ .draw = .{
            .vertex_start = vertex_start,
            .vertex_count = 0,
            .vertex_stride = self.vertex_stride,
            .primitive = primitive,
            .options = self.options(),
            .vertex_buffer = bound_buffer,
            .vertex_buffer_offset = self.vertex_offset,
            .vertex_source_count = if (bound_buffer == null) source.len else 0,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .fragment_uniform_enabled = self.fragment_uniform_enabled,
            .fragment_uniform_buffer = self.fragment_uniform_buffer,
            .fragment_uniform_buffer_offset = self.fragment_uniform_buffer_offset,
            .sample_texture = if (self.sample_texture) self.fragment_texture else null,
            .sample_mipmap_start = sample_mipmaps.start,
            .sample_mipmap_count = sample_mipmaps.count,
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
            .amplification_count = self.vertex_amplification_count,
            .amplification_viewport_offsets = self.vertex_amplification_viewport_offsets,
            .amplification_render_target_offsets = self.vertex_amplification_render_target_offsets,
            .viewport_array = self.viewport_array,
            .viewport_array_count = self.viewport_array_count,
            .scissor_array = self.scissor_array,
            .scissor_array_count = self.scissor_array_count,
        } });
    }

    pub fn drawIndexedPrimitives(self: *RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, instance_count: usize) Error!void {
        return self.drawIndexedPrimitivesWithBaseVertexAndInstance(primitive, index_count, index_type, index_buffer, index_buffer_offset, instance_count, 0, 0);
    }

    pub fn drawIndexedPrimitivesWithBaseVertex(self: *RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, instance_count: usize, base_vertex: i64) Error!void {
        return self.drawIndexedPrimitivesWithBaseVertexAndInstance(primitive, index_count, index_type, index_buffer, index_buffer_offset, instance_count, base_vertex, 0);
    }

    pub fn drawIndexedPrimitivesWithBaseVertexAndInstance(self: *RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, instance_count: usize, base_vertex: i64, base_instance: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validIndexType(index_type)) return error.InvalidCommand;
        if (self.sample_texture and self.fragment_texture == null) return error.InvalidResource;
        if (!validBuffer(index_buffer) or index_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (instance_count == 0 or index_count == 0) return;
        const array_target_count = self.renderTargetArrayCount();
        if (array_target_count == 0) return error.InvalidArgument;
        if (array_target_count > 1) {
            const last_instance = std.math.add(usize, base_instance, instance_count - 1) catch return error.InvalidArgument;
            if (last_instance >= array_target_count) return error.InvalidArgument;
        }
        if (array_target_count > 1 and instance_count > array_target_count)
            return error.InvalidArgument;
        var owned_source: ?[]abi.Vertex = null;
        const source = try self.sourceVertices(&owned_source);
        defer if (owned_source) |vertices| allocator.free(vertices);
        const index_size: usize = if (index_type == .uint16) 2 else 4;
        const index_bytes = std.math.mul(usize, index_count, index_size) catch return error.InvalidArgument;
        if (!rangeValid(index_buffer.bytes.len, index_buffer_offset, index_bytes)) return error.InvalidArgument;
        const bound_buffer = self.vertex_buffer;
        const vertex_start = if (bound_buffer == null) try self.command_buffer.appendVertices(source) else 0;
        const sample_mipmaps = try self.appendSampleMipmaps();
        var instance: usize = 0;
        while (instance < instance_count) : (instance += 1) {
            _ = try self.command_buffer.append(.{ .draw = .{
                .vertex_start = vertex_start,
                .vertex_count = index_count,
                .vertex_stride = self.vertex_stride,
                .primitive = primitive,
                .options = self.options(),
                .vertex_buffer = bound_buffer,
                .vertex_buffer_offset = self.vertex_offset,
                .vertex_source_count = if (bound_buffer == null) source.len else 0,
                .index_buffer = index_buffer,
                .index_buffer_offset = index_buffer_offset,
                .index_type = index_type,
                .base_vertex = base_vertex,
                .fragment_uniform_enabled = self.fragment_uniform_enabled,
                .fragment_uniform_buffer = self.fragment_uniform_buffer,
                .fragment_uniform_buffer_offset = self.fragment_uniform_buffer_offset,
                .sample_texture = if (self.sample_texture) self.fragment_texture else null,
                .sample_mipmap_start = sample_mipmaps.start,
                .sample_mipmap_count = sample_mipmaps.count,
                .visibility_buffer = self.visibility_buffer,
                .visibility_mode = self.visibility_mode,
                .visibility_offset = self.visibility_offset,
                .visibility_result_type = self.visibility_result_type,
                .array_index = if (array_target_count > 1)
                    std.math.add(usize, base_instance, instance) catch return error.InvalidArgument
                else
                    0,
                .amplification_count = self.vertex_amplification_count,
                .amplification_viewport_offsets = self.vertex_amplification_viewport_offsets,
                .amplification_render_target_offsets = self.vertex_amplification_render_target_offsets,
                .viewport_array = self.viewport_array,
                .viewport_array_count = self.viewport_array_count,
                .scissor_array = self.scissor_array,
                .scissor_array_count = self.scissor_array_count,
            } });
        }
    }

    pub fn drawIndexedPrimitivesIndirect(self: *RenderEncoder, primitive: abi.PrimitiveType, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, indirect_buffer: *Buffer, indirect_buffer_offset: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validIndexType(index_type) or !validBuffer(index_buffer) or !validBuffer(indirect_buffer)) return error.InvalidArgument;
        if (index_buffer.device != self.command_buffer.queue.device or indirect_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (indirect_buffer_offset % @alignOf(u32) != 0 or !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 20)) return error.InvalidArgument;
        var owned_source: ?[]abi.Vertex = null;
        const source = try self.sourceVertices(&owned_source);
        defer if (owned_source) |vertices| allocator.free(vertices);
        const bound_buffer = self.vertex_buffer;
        const vertex_start = if (bound_buffer == null) try self.command_buffer.appendVertices(source) else 0;
        const sample_mipmaps = try self.appendSampleMipmaps();
        _ = try self.command_buffer.append(.{ .draw = .{
            .vertex_start = vertex_start,
            .vertex_count = 0,
            .vertex_stride = self.vertex_stride,
            .primitive = primitive,
            .options = self.options(),
            .vertex_buffer = bound_buffer,
            .vertex_buffer_offset = self.vertex_offset,
            .vertex_source_count = if (bound_buffer == null) source.len else 0,
            .index_buffer = index_buffer,
            .index_buffer_offset = index_buffer_offset,
            .index_type = index_type,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .fragment_uniform_enabled = self.fragment_uniform_enabled,
            .fragment_uniform_buffer = self.fragment_uniform_buffer,
            .fragment_uniform_buffer_offset = self.fragment_uniform_buffer_offset,
            .sample_texture = if (self.sample_texture) self.fragment_texture else null,
            .sample_mipmap_start = sample_mipmaps.start,
            .sample_mipmap_count = sample_mipmaps.count,
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
            .amplification_count = self.vertex_amplification_count,
            .amplification_viewport_offsets = self.vertex_amplification_viewport_offsets,
            .amplification_render_target_offsets = self.vertex_amplification_render_target_offsets,
            .viewport_array = self.viewport_array,
            .viewport_array_count = self.viewport_array_count,
            .scissor_array = self.scissor_array,
            .scissor_array_count = self.scissor_array_count,
        } });
    }

    pub fn dispatchThreadsPerTile(self: *RenderEncoder, kernel: u8, tile_size: abi.Size, threads_per_tile: abi.Size) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const target = switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| begin_render.target,
            else => return error.InvalidCommand,
        };
        if (kernel != 1 or
            (target.format != .rgba8_unorm and target.format != .bgra8_unorm) or
            tile_size.width == 0 or tile_size.height == 0 or tile_size.depth != 1 or
            threads_per_tile.width == 0 or threads_per_tile.height == 0 or threads_per_tile.depth != 1 or
            threads_per_tile.width > tile_size.width or threads_per_tile.height > tile_size.height) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .tile = .{
            .target = target,
            .kernel = kernel,
            .tile_size = tile_size,
            .threads_per_tile = threads_per_tile,
            .color_attachment_map = self.color_attachment_map,
            .options = self.options(),
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
        } });
    }

    fn validMeshThreadgroup(size: abi.Size) bool {
        if (size.width == 0 or size.height == 0 or size.depth != 1) return false;
        return @as(u64, size.width) * @as(u64, size.height) <= 1024;
    }

    pub fn drawMeshThreadgroups(
        self: *RenderEncoder,
        kernel: u8,
        threadgroups_per_grid: abi.Size,
        threads_per_object_threadgroup: abi.Size,
        threads_per_mesh_threadgroup: abi.Size,
    ) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const array_target_count = self.renderTargetArrayCount();
        if (array_target_count == 0) return error.InvalidArgument;
        const target = switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| begin_render.target,
            else => return error.InvalidCommand,
        };
        if (kernel != 1 or
            (target.format != .rgba8_unorm and target.format != .bgra8_unorm) or
            threadgroups_per_grid.width == 0 or threadgroups_per_grid.height == 0 or
            threadgroups_per_grid.depth != array_target_count or
            threads_per_object_threadgroup.width != 1 or threads_per_object_threadgroup.height != 1 or
            threads_per_object_threadgroup.depth != 1 or !validMeshThreadgroup(threads_per_mesh_threadgroup))
            return error.InvalidArgument;
        const grid_width = std.math.mul(u32, threadgroups_per_grid.width, threads_per_mesh_threadgroup.width) catch return error.InvalidArgument;
        const grid_height = std.math.mul(u32, threadgroups_per_grid.height, threads_per_mesh_threadgroup.height) catch return error.InvalidArgument;
        const grid_depth = std.math.mul(u32, threadgroups_per_grid.depth, threads_per_mesh_threadgroup.depth) catch return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .mesh = .{
            .target = target,
            .kernel = kernel,
            .threads_per_grid = .{ .width = grid_width, .height = grid_height, .depth = grid_depth },
            .threads_per_object_threadgroup = threads_per_object_threadgroup,
            .threads_per_mesh_threadgroup = threads_per_mesh_threadgroup,
            .color_attachment_map = self.color_attachment_map,
            .options = self.options(),
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
        } });
    }

    pub fn drawMeshThreads(
        self: *RenderEncoder,
        kernel: u8,
        threads_per_grid: abi.Size,
        threads_per_object_threadgroup: abi.Size,
        threads_per_mesh_threadgroup: abi.Size,
    ) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const array_target_count = self.renderTargetArrayCount();
        if (array_target_count == 0) return error.InvalidArgument;
        if (threads_per_grid.width == 0 or threads_per_grid.height == 0 or
            threads_per_grid.depth != array_target_count or
            threads_per_object_threadgroup.width != 1 or threads_per_object_threadgroup.height != 1 or
            threads_per_object_threadgroup.depth != 1 or !validMeshThreadgroup(threads_per_mesh_threadgroup))
            return error.InvalidArgument;
        const rounded_width = (threads_per_grid.width / threads_per_mesh_threadgroup.width) * threads_per_mesh_threadgroup.width;
        const rounded_height = (threads_per_grid.height / threads_per_mesh_threadgroup.height) * threads_per_mesh_threadgroup.height;
        if (rounded_width == 0 or rounded_height == 0) return;
        return self.drawMeshThreadgroups(kernel, .{
            .width = rounded_width / threads_per_mesh_threadgroup.width,
            .height = rounded_height / threads_per_mesh_threadgroup.height,
            .depth = threads_per_grid.depth,
        }, threads_per_object_threadgroup, threads_per_mesh_threadgroup);
    }

    pub fn drawMeshThreadgroupsIndirect(
        self: *RenderEncoder,
        kernel: u8,
        indirect_buffer: *Buffer,
        indirect_buffer_offset: usize,
        threads_per_object_threadgroup: abi.Size,
        threads_per_mesh_threadgroup: abi.Size,
    ) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const target = switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| begin_render.target,
            else => return error.InvalidCommand,
        };
        if (kernel != 1 or
            (target.format != .rgba8_unorm and target.format != .bgra8_unorm) or
            !validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
            indirect_buffer_offset % @alignOf(u32) != 0 or
            !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 3 * @sizeOf(u32)) or
            threads_per_object_threadgroup.width != 1 or threads_per_object_threadgroup.height != 1 or
            threads_per_object_threadgroup.depth != 1 or !validMeshThreadgroup(threads_per_mesh_threadgroup))
            return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .mesh = .{
            .target = target,
            .kernel = kernel,
            .threads_per_grid = .{ .width = 0, .height = 0, .depth = 0 },
            .threads_per_object_threadgroup = threads_per_object_threadgroup,
            .threads_per_mesh_threadgroup = threads_per_mesh_threadgroup,
            .color_attachment_map = self.color_attachment_map,
            .options = self.options(),
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
        } });
    }

    fn patchControlPointIndexTypeValid(index_type: abi.TessellationControlPointIndexType, index_buffer: ?*Buffer) bool {
        return if (index_buffer == null) index_type == .none else index_type != .none;
    }

    fn appendPatchCommand(
        self: *RenderEncoder,
        kernel: u8,
        control_point_count: u32,
        patch_start: usize,
        patch_count: usize,
        patch_index_buffer: ?*Buffer,
        patch_index_buffer_offset: usize,
        instance_count: usize,
        base_instance: usize,
        control_point_index_type: abi.TessellationControlPointIndexType,
        control_point_index_buffer: ?*Buffer,
        control_point_index_buffer_offset: usize,
        indirect_buffer: ?*Buffer,
        indirect_buffer_offset: usize,
    ) Error!void {
        const control_point_index_alignment: usize = switch (control_point_index_type) {
            .uint16 => @alignOf(u16),
            .uint32, .none => @alignOf(u32),
        };
        if (!self.open() or kernel != 1 or control_point_count != 3 or
            !patchControlPointIndexTypeValid(control_point_index_type, control_point_index_buffer) or
            (patch_index_buffer != null and (!validBuffer(patch_index_buffer.?) or
                patch_index_buffer.?.device != self.command_buffer.queue.device or
                patch_index_buffer_offset % @alignOf(u32) != 0)) or
            (control_point_index_buffer != null and (!validBuffer(control_point_index_buffer.?) or
                control_point_index_buffer.?.device != self.command_buffer.queue.device or
                control_point_index_buffer_offset % control_point_index_alignment != 0)) or
            (indirect_buffer != null and (!validBuffer(indirect_buffer.?) or
                indirect_buffer.?.device != self.command_buffer.queue.device or
                indirect_buffer_offset % @alignOf(u32) != 0 or
                !rangeValid(indirect_buffer.?.bytes.len, indirect_buffer_offset, 4 * @sizeOf(u32)))) or
            self.tessellation_factor_buffer == null or
            !std.math.isFinite(self.tessellation_factor_scale) or
            self.tessellation_factor_scale <= 0)
            return error.InvalidArgument;
        const target = switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| begin_render.target,
            else => return error.InvalidCommand,
        };
        if (target.format != .rgba8_unorm and target.format != .bgra8_unorm) return error.UnsupportedFormat;
        if (patch_index_buffer) |buffer| {
            const bytes = std.math.mul(usize, patch_count, @sizeOf(u32)) catch return error.InvalidArgument;
            if (!rangeValid(buffer.bytes.len, patch_index_buffer_offset, bytes)) return error.InvalidArgument;
        } else if (patch_start > std.math.maxInt(usize) - patch_count) return error.InvalidArgument;
        if (control_point_index_buffer) |buffer| {
            const index_size: usize = switch (control_point_index_type) {
                .uint16 => @sizeOf(u16),
                .uint32 => @sizeOf(u32),
                .none => return error.InvalidArgument,
            };
            if (patch_index_buffer == null) {
                const patch_end = std.math.add(usize, patch_start, patch_count) catch return error.InvalidArgument;
                const bytes = std.math.mul(usize, std.math.mul(usize, patch_end, control_point_count) catch return error.InvalidArgument, index_size) catch return error.InvalidArgument;
                if (!rangeValid(buffer.bytes.len, control_point_index_buffer_offset, bytes)) return error.InvalidArgument;
            } else if (control_point_index_buffer_offset > buffer.bytes.len) {
                // A patch-index buffer can map drawPatchIndex to arbitrary,
                // non-contiguous patch IDs. Validate the selected control
                // point records at commit, after reading those IDs.
                return error.InvalidArgument;
            }
        }
        const factor_buffer = self.tessellation_factor_buffer.?;
        const factor_end = std.math.add(usize, patch_start, patch_count) catch return error.InvalidArgument;
        const factor_last_instance = if (instance_count == 0) base_instance else std.math.add(usize, base_instance, instance_count - 1) catch return error.InvalidArgument;
        const factor_instance_offset = std.math.mul(usize, factor_last_instance, self.tessellation_factor_buffer_instance_stride) catch return error.InvalidArgument;
        const factor_patch_offset = if (patch_count == 0) 0 else std.math.mul(usize, factor_end - 1, @sizeOf(u16) * 4) catch return error.InvalidArgument;
        const factor_last = std.math.add(usize, factor_instance_offset, factor_patch_offset) catch return error.InvalidArgument;
        const factor_bytes = std.math.add(usize, factor_last, @sizeOf(u16) * 4) catch return error.InvalidArgument;
        if (!rangeValid(factor_buffer.bytes.len, self.tessellation_factor_buffer_offset, factor_bytes)) return error.InvalidArgument;
        var inline_vertex_start: usize = 0;
        var inline_vertex_count: usize = 0;
        if (self.vertex_buffer == null) {
            if (self.inline_vertices.items.len == 0) return error.InvalidResource;
            inline_vertex_start = try self.command_buffer.appendVertices(self.inline_vertices.items);
            inline_vertex_count = self.inline_vertices.items.len;
        }
        _ = try self.command_buffer.append(.{ .patch = .{
            .target = target,
            .kernel = kernel,
            .control_point_count = control_point_count,
            .patch_start = patch_start,
            .patch_count = patch_count,
            .patch_index_buffer = patch_index_buffer,
            .patch_index_buffer_offset = patch_index_buffer_offset,
            .control_point_index_type = control_point_index_type,
            .control_point_index_buffer = control_point_index_buffer,
            .control_point_index_buffer_offset = control_point_index_buffer_offset,
            .instance_count = if (indirect_buffer == null) instance_count else 0,
            .base_instance = base_instance,
            .factor_buffer = factor_buffer,
            .factor_buffer_offset = self.tessellation_factor_buffer_offset,
            .factor_instance_stride = self.tessellation_factor_buffer_instance_stride,
            .factor_scale = self.tessellation_factor_scale,
            .partition_mode = self.tessellation_partition_mode,
            .max_tessellation_factor = self.patch_max_tessellation_factor,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .vertex_buffer = self.vertex_buffer,
            .vertex_buffer_offset = self.vertex_offset,
            .vertex_stride = self.vertex_stride,
            .inline_vertex_start = inline_vertex_start,
            .inline_vertex_count = inline_vertex_count,
            .options = self.options(),
            .fragment_uniform_enabled = self.fragment_uniform_enabled,
            .fragment_uniform_buffer = self.fragment_uniform_buffer,
            .fragment_uniform_buffer_offset = self.fragment_uniform_buffer_offset,
            .visibility_buffer = self.visibility_buffer,
            .visibility_mode = self.visibility_mode,
            .visibility_offset = self.visibility_offset,
            .visibility_result_type = self.visibility_result_type,
        } });
    }

    pub fn drawPatches(
        self: *RenderEncoder,
        kernel: u8,
        control_point_count: u32,
        patch_start: usize,
        patch_count: usize,
        patch_index_buffer: ?*Buffer,
        patch_index_buffer_offset: usize,
        instance_count: usize,
        base_instance: usize,
        control_point_index_type: abi.TessellationControlPointIndexType,
        control_point_index_buffer: ?*Buffer,
        control_point_index_buffer_offset: usize,
    ) Error!void {
        return self.appendPatchCommand(kernel, control_point_count, patch_start, patch_count, patch_index_buffer, patch_index_buffer_offset, instance_count, base_instance, control_point_index_type, control_point_index_buffer, control_point_index_buffer_offset, null, 0);
    }

    pub fn drawPatchesIndirect(
        self: *RenderEncoder,
        kernel: u8,
        control_point_count: u32,
        patch_index_buffer: ?*Buffer,
        patch_index_buffer_offset: usize,
        indirect_buffer: *Buffer,
        indirect_buffer_offset: usize,
        control_point_index_type: abi.TessellationControlPointIndexType,
        control_point_index_buffer: ?*Buffer,
        control_point_index_buffer_offset: usize,
    ) Error!void {
        return self.appendPatchCommand(kernel, control_point_count, 0, 0, patch_index_buffer, patch_index_buffer_offset, 0, 0, control_point_index_type, control_point_index_buffer, control_point_index_buffer_offset, indirect_buffer, indirect_buffer_offset);
    }

    pub fn endEncoding(self: *RenderEncoder) Error!void {
        if (!self.open()) return error.InvalidCommand;
        try self.command_buffer.end(.render);
    }
};

pub const BlitEncoder = struct {
    magic: u64 = blit_encoder_magic,
    command_buffer: *CommandBuffer,

    pub fn deinit(self: *BlitEncoder) void {
        self.magic = 0;
    }

    fn open(self: *const BlitEncoder) bool {
        return self.magic == blit_encoder_magic and self.command_buffer.active_encoder == .blit;
    }

    pub fn copyBuffer(self: *BlitEncoder, source: *Buffer, source_offset: usize, destination: *Buffer, destination_offset: usize, length: usize) Error!void {
        if (!self.open() or !validBuffer(source) or !validBuffer(destination)) return error.InvalidArgument;
        if (source.device != destination.device or !rangeValid(source.bytes.len, source_offset, length) or !rangeValid(destination.bytes.len, destination_offset, length)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_buffer = .{ .source = source, .source_offset = source_offset, .destination = destination, .destination_offset = destination_offset, .length = length } });
    }

    pub fn copyBufferToTexture(self: *BlitEncoder, source: *Buffer, source_offset: usize, source_bytes_per_row: usize, destination: *Texture, destination_region: abi.Region) Error!void {
        if (!self.open() or !validBuffer(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_buffer_to_texture = .{ .buffer = source, .buffer_offset = source_offset, .bytes_per_row = source_bytes_per_row, .texture = destination, .region = destination_region } });
    }

    pub fn copyTextureToBuffer(self: *BlitEncoder, source: *Texture, source_region: abi.Region, destination: *Buffer, destination_offset: usize, destination_bytes_per_row: usize) Error!void {
        if (!self.open() or !validTexture(source) or !validBuffer(destination)) return error.InvalidArgument;
        if (source.device != destination.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_texture_to_buffer = .{ .texture = source, .region = source_region, .buffer = destination, .buffer_offset = destination_offset, .bytes_per_row = destination_bytes_per_row } });
    }

    pub fn copyTextureToTexture(self: *BlitEncoder, source: *Texture, source_region: abi.Region, destination: *Texture, destination_region: abi.Region) Error!void {
        if (!self.open() or !validTexture(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_texture_to_texture = .{ .source = source, .source_region = source_region, .destination = destination, .destination_region = destination_region } });
    }

    pub fn generateMipmap(self: *BlitEncoder, source: *Texture, destination: *Texture) Error!void {
        if (!self.open() or !validTexture(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        if (source.format.isIntegerColor()) return error.UnsupportedFormat;
        _ = try self.command_buffer.append(.{ .generate_mipmap = .{ .source = source, .destination = destination } });
    }

    pub fn generateSrgbMipmapChain(self: *BlitEncoder, levels: []const *Texture) Error!void {
        if (!self.open() or levels.len < 2) return error.InvalidArgument;
        const format = levels[0].format;
        if (!isSrgb8Format(format)) return error.UnsupportedFormat;
        for (levels) |level| {
            if (!validTexture(level) or level.device != self.command_buffer.queue.device or level.format != format) return error.InvalidArgument;
        }
        try self.command_buffer.appendSrgbMipmapChain(levels);
    }

    pub fn generateMipmap3D(self: *BlitEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture) Error!void {
        const denominator: u32 = if (source1 != null) 2 else 1;
        try self.generateMipmap3DWeighted(source0, source1, destination, if (source1 != null) 1 else 0, denominator);
    }

    pub fn generateMipmap3DWeighted(self: *BlitEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) Error!void {
        if (!self.open() or !validTexture(source0) or !validTexture(destination)) return error.InvalidArgument;
        if (source0.device != destination.device or source0.format != destination.format) return error.InvalidArgument;
        if (source0.format.isIntegerColor()) return error.UnsupportedFormat;
        if (source1) |value| {
            if (!validTexture(value) or value.device != destination.device or value.format != destination.format) return error.InvalidArgument;
        }
        if (source1_weight_denominator == 0 or source1_weight_numerator > source1_weight_denominator or
            (source1 == null and source1_weight_numerator != 0)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .generate_mipmap_3d = .{
            .source0 = source0,
            .source1 = source1,
            .destination = destination,
            .source1_weight_numerator = source1_weight_numerator,
            .source1_weight_denominator = source1_weight_denominator,
        } });
    }

    pub fn generateMipmap3DArray(self: *BlitEncoder, sources: []const *Texture, destination: *Texture) Error!void {
        if (!self.open() or !validTexture(destination) or sources.len == 0) return error.InvalidArgument;
        if (destination.format.isIntegerColor()) return error.UnsupportedFormat;
        for (sources) |source| {
            if (!validTexture(source) or source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        }
        try self.command_buffer.appendMipmap3DArray(sources, destination);
    }

    pub fn fillBuffer(self: *BlitEncoder, buffer: *Buffer, offset: usize, length: usize, value: u8) Error!void {
        if (!self.open() or !validBuffer(buffer)) return error.InvalidArgument;
        if (!rangeValid(buffer.bytes.len, offset, length)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .fill_buffer = .{ .buffer = buffer, .offset = offset, .length = length, .value = value } });
    }

    pub fn synchronizeResource(self: *BlitEncoder, buffer: *Buffer) Error!void {
        if (!self.open() or !validBuffer(buffer)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .synchronize_buffer = buffer });
    }

    pub fn updateFence(self: *BlitEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .update_fence = fence });
    }

    pub fn waitForFence(self: *BlitEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .wait_fence = fence });
    }

    pub fn endEncoding(self: *BlitEncoder) Error!void {
        if (!self.open()) return error.InvalidCommand;
        try self.command_buffer.end(.blit);
    }
};

pub const ResourceStateEncoder = struct {
    magic: u64 = resource_state_encoder_magic,
    command_buffer: *CommandBuffer,

    pub fn deinit(self: *ResourceStateEncoder) void {
        self.magic = 0;
    }

    fn open(self: *const ResourceStateEncoder) bool {
        return self.magic == resource_state_encoder_magic and self.command_buffer.active_encoder == .resource_state;
    }

    /// ZPU owns unified CPU memory, so resource state transitions do not need
    /// cache operations. They remain an encoder boundary so command ordering,
    /// fence visibility, and Metal's deferred commit behavior are preserved.
    pub fn updateFence(self: *ResourceStateEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .update_fence = fence });
    }

    pub fn waitForFence(self: *ResourceStateEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .wait_fence = fence });
    }

    /// Record the legacy Metal batch mapping form against the same CPU-owned
    /// page store as updateTextureMapping. Regions use sparse-tile coordinates
    /// in this bounded profile; level 0 and slice 0 are the only representable
    /// subresources, so invalid entries fail before any command is appended.
    pub fn updateTextureMappings(self: *ResourceStateEncoder, texture: *Texture, mode: u8, regions: []const abi.Region, mip_levels: []const usize, slices: []const usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!validTexture(texture) or texture.device != self.command_buffer.queue.device or
            texture.sparse_page_bytes == 0 or (mode != 0 and mode != 1) or
            regions.len != mip_levels.len or regions.len != slices.len) return error.InvalidArgument;
        for (regions, 0..) |region, index| {
            if (mip_levels[index] != 0 or slices[index] != 0 or !sparseTextureRangeValid(texture, region))
                return error.InvalidArgument;
        }
        for (regions) |region| {
            _ = try self.command_buffer.append(.{ .sparse_texture_mapping = .{
                .texture = texture,
                .mode = mode,
                .region = region,
            } });
        }
    }

    /// Record the indirect MTLMapIndirectArguments form. The count and
    /// records are read at commit time, matching Metal's deferred command
    /// buffer behavior; the portable profile still requires level 0 and
    /// slice 0 for every record.
    pub fn updateTextureMappingIndirect(self: *ResourceStateEncoder, texture: *Texture, mode: u8, buffer: *Buffer, buffer_offset: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!validTexture(texture) or !validBuffer(buffer) or texture.device != self.command_buffer.queue.device or
            buffer.device != self.command_buffer.queue.device or buffer.sparse_page_bytes != 0 or
            texture.sparse_page_bytes == 0 or (mode != 0 and mode != 1) or
            buffer_offset % @alignOf(u32) != 0 or
            !rangeValid(buffer.bytes.len, buffer_offset, @sizeOf(u32))) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_texture_mapping_indirect = .{
            .texture = texture,
            .mode = mode,
            .buffer = buffer,
            .buffer_offset = buffer_offset,
        } });
    }

    /// Move mapped pages, leaving the source unmapped. A destination tile that
    /// is already mapped is preserved, as required by Metal's move operation.
    pub fn moveTextureMappings(self: *ResourceStateEncoder, source: *Texture, destination: *Texture, source_region: abi.Region, destination_origin: abi.Origin) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const destination_region = abi.Region{ .origin = destination_origin, .size = source_region.size };
        if (!validTexture(source) or !validTexture(destination) or source.device != self.command_buffer.queue.device or
            destination.device != self.command_buffer.queue.device or source.sparse_page_bytes == 0 or
            source.sparse_page_bytes != destination.sparse_page_bytes or source.format != destination.format or
            source.sparse_tile_width != destination.sparse_tile_width or source.sparse_tile_height != destination.sparse_tile_height or
            !sparseTextureRangeValid(source, source_region) or !sparseTextureRangeValid(destination, destination_region))
            return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_texture_move_mapping = .{
            .source = source,
            .destination = destination,
            .source_region = source_region,
            .destination_origin = destination_origin,
        } });
    }

    /// Map or unmap page-aligned ranges of a sparse buffer. Mapping commands
    /// are deferred with the rest of the command buffer, while the backing
    /// pages remain CPU/ZPU-owned and preserve aliases across copies.
    pub fn updateBufferMapping(self: *ResourceStateEncoder, buffer: *Buffer, mode: u8, offset: usize, length: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!validBuffer(buffer) or buffer.device != self.command_buffer.queue.device or
            buffer.sparse_page_bytes == 0 or !sparseRangeValid(buffer, offset, length) or
            (mode != 0 and mode != 1)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_buffer_mapping = .{
            .buffer = buffer,
            .mode = mode,
            .offset = offset,
            .length = length,
        } });
    }

    pub fn copyBufferMappings(self: *ResourceStateEncoder, source: *Buffer, destination: *Buffer, source_offset: usize, destination_offset: usize, length: usize) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!validBuffer(source) or !validBuffer(destination) or source.device != self.command_buffer.queue.device or
            destination.device != self.command_buffer.queue.device or source.sparse_page_bytes == 0 or
            source.sparse_page_bytes != destination.sparse_page_bytes or
            !sparseRangeValid(source, source_offset, length) or !sparseRangeValid(destination, destination_offset, length))
            return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_buffer_copy_mapping = .{
            .source = source,
            .destination = destination,
            .source_offset = source_offset,
            .destination_offset = destination_offset,
            .length = length,
        } });
    }

    pub fn updateTextureMapping(self: *ResourceStateEncoder, texture: *Texture, mode: u8, region: abi.Region) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (!validTexture(texture) or texture.device != self.command_buffer.queue.device or
            texture.sparse_page_bytes == 0 or !sparseTextureRangeValid(texture, region) or
            (mode != 0 and mode != 1)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_texture_mapping = .{
            .texture = texture,
            .mode = mode,
            .region = region,
        } });
    }

    pub fn copyTextureMappings(self: *ResourceStateEncoder, source: *Texture, destination: *Texture, source_region: abi.Region, destination_origin: abi.Origin) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const destination_region = abi.Region{ .origin = destination_origin, .size = source_region.size };
        if (!validTexture(source) or !validTexture(destination) or source.device != self.command_buffer.queue.device or
            destination.device != self.command_buffer.queue.device or source.sparse_page_bytes == 0 or
            source.sparse_page_bytes != destination.sparse_page_bytes or source.sparse_tile_width != destination.sparse_tile_width or
            source.sparse_tile_height != destination.sparse_tile_height or !sparseTextureRangeValid(source, source_region) or
            !sparseTextureRangeValid(destination, destination_region)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .sparse_texture_copy_mapping = .{
            .source = source,
            .destination = destination,
            .source_region = source_region,
            .destination_origin = destination_origin,
        } });
    }

    pub fn endEncoding(self: *ResourceStateEncoder) Error!void {
        if (!self.open()) return error.InvalidCommand;
        try self.command_buffer.end(.resource_state);
    }
};

fn isNarrowHalfKernel(kernel: u8) bool {
    return kernel >= 46 and kernel <= 49 or kernel >= 54 and kernel <= 65;
}

fn isNarrowBfloatKernel(kernel: u8) bool {
    return kernel >= 50 and kernel <= 53 or kernel >= 66 and kernel <= 77;
}

fn isNarrowKernel(kernel: u8) bool {
    return isNarrowHalfKernel(kernel) or isNarrowBfloatKernel(kernel);
}

fn isIntegerKernel(kernel: u8) bool {
    return kernel >= 78 and kernel <= 95;
}

fn integerKernelElementBytes(kernel: u8) usize {
    return switch (kernel) {
        78...83 => @sizeOf(u32),
        84...89 => @sizeOf(u16),
        90...95 => @sizeOf(u8),
        else => 0,
    };
}

fn narrowVectorWidth(kernel: u8) ?usize {
    return switch (kernel) {
        54...57, 66...69 => 2,
        58...61, 70...73 => 3,
        62...65, 74...77 => 4,
        else => null,
    };
}

pub const ComputeEncoder = struct {
    // Metal exposes 31 buffer bindings per compute stage on the Apple targets
    // covered by this adapter. Registered CPU kernels only consume the slots
    // described by their profile, but valid extra slots remain part of the
    // encoder state and must not poison a command before dispatch.
    const max_buffer_bindings: usize = 31;
    magic: u64 = compute_encoder_magic,
    command_buffer: *CommandBuffer,
    kernel: u8 = 0,
    textures: [2]?*Texture = .{ null, null },
    array_slices: [2]?u32 = .{ null, null },
    buffers: [max_buffer_bindings]?*Buffer = [_]?*Buffer{null} ** max_buffer_bindings,
    buffer_offsets: [max_buffer_bindings]usize = [_]usize{0} ** max_buffer_bindings,
    buffer: ?*Buffer = null,
    buffer_offset: usize = 0,
    acceleration_structure: ?*Buffer = null,
    acceleration_structure_index: u32 = 0,
    intersection_function_profile: u8 = 0,

    pub fn deinit(self: *ComputeEncoder) void {
        self.magic = 0;
    }

    fn open(self: *const ComputeEncoder) bool {
        return self.magic == compute_encoder_magic and self.command_buffer.active_encoder == .compute;
    }

    fn textureIndexForKernel(self: *const ComputeEncoder) usize {
        return if (self.kernel == 2 or self.kernel == 31) 1 else 0;
    }

    fn textureForKernel(self: *const ComputeEncoder) ?*Texture {
        return self.textures[self.textureIndexForKernel()];
    }

    fn sourceTextureForKernel(self: *const ComputeEncoder) ?*Texture {
        return if (self.kernel == 31) self.textures[0] else null;
    }

    pub fn setKernel(self: *ComputeEncoder, kernel: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (kernel < 1 or kernel > 95) return error.UnsupportedOperation;
        self.kernel = kernel;
    }

    fn isBufferAddKernel(self: *const ComputeEncoder) bool {
        return self.kernel == 8 or self.kernel == 9 or self.kernel == 30 or self.kernel == 41 or
            self.kernel == 32 or self.kernel == 33 or self.kernel == 34 or
            self.kernel == 35 or self.kernel == 36 or self.kernel == 37 or
            self.kernel == 38 or self.kernel == 39 or self.kernel == 40 or
            self.kernel == 42 or self.kernel == 43 or self.kernel == 44 or
            isNarrowKernel(self.kernel) or isIntegerKernel(self.kernel);
    }

    fn appendBufferAdd(
        self: *ComputeEncoder,
        threads_per_grid: abi.Size,
        threads_per_threadgroup: abi.Size,
        indirect_buffer: ?*Buffer,
        indirect_buffer_offset: usize,
        indirect_threads: bool,
    ) Error!void {
        if (!self.isBufferAddKernel() or threads_per_grid.height != 1 or threads_per_grid.depth != 1 or
            threads_per_threadgroup.width == 0 or threads_per_threadgroup.height != 1 or
            threads_per_threadgroup.depth != 1) return error.InvalidArgument;
        const left = self.buffers[0] orelse return error.InvalidCommand;
        const right = self.buffers[1] orelse return error.InvalidCommand;
        const output = self.buffers[2] orelse return error.InvalidCommand;
        if (!validBuffer(left) or !validBuffer(right) or !validBuffer(output) or
            left.device != self.command_buffer.queue.device or right.device != left.device or
            output.device != left.device) return error.InvalidResource;
        _ = try self.command_buffer.append(.{ .compute_buffer_add = .{
            .kernel = self.kernel,
            .elements_per_thread = if (narrowVectorWidth(self.kernel)) |width| width else if (self.kernel == 32 or self.kernel == 33 or self.kernel == 34 or self.kernel == 42) 4 else (if (self.kernel == 35 or self.kernel == 36 or self.kernel == 37 or self.kernel == 43) 2 else (if (self.kernel == 38 or self.kernel == 39 or self.kernel == 40 or self.kernel == 44) 3 else 1)),
            .element_stride = if (narrowVectorWidth(self.kernel)) |width| if (width == 3) 4 else width else if (self.kernel == 32 or self.kernel == 33 or self.kernel == 34 or self.kernel == 42) 4 else (if (self.kernel == 35 or self.kernel == 36 or self.kernel == 37 or self.kernel == 43) 2 else (if (self.kernel == 38 or self.kernel == 39 or self.kernel == 40 or self.kernel == 44) 4 else 1)),
            .left = left,
            .left_offset = self.buffer_offsets[0],
            .right = right,
            .right_offset = self.buffer_offsets[1],
            .output = output,
            .output_offset = self.buffer_offsets[2],
            .threads_per_grid = threads_per_grid,
            .threads_per_threadgroup = threads_per_threadgroup,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .indirect_threads = indirect_threads,
        } });
    }

    fn appendSourceNoop(
        self: *ComputeEncoder,
        threads_per_grid: abi.Size,
        threads_per_threadgroup: abi.Size,
        indirect_buffer: ?*Buffer,
        indirect_buffer_offset: usize,
        indirect_threads: bool,
    ) Error!void {
        if (self.kernel != 29 or threads_per_threadgroup.width == 0 or
            threads_per_threadgroup.height == 0 or threads_per_threadgroup.depth == 0)
            return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .texture = null,
            .texture_index = 0,
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .acceleration_structure = self.acceleration_structure,
            .acceleration_structure_index = self.acceleration_structure_index,
            .intersection_function_profile = self.intersection_function_profile,
            .threads_per_grid = threads_per_grid,
            .threads_per_threadgroup = threads_per_threadgroup,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .indirect_threads = indirect_threads,
        } });
    }

    pub fn setBuffer(self: *ComputeEncoder, buffer: ?*Buffer, offset: usize, index: u32) Error!void {
        if (!self.open() or index >= max_buffer_bindings) return error.UnsupportedOperation;
        if (buffer) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device or offset > value.bytes.len) return error.InvalidArgument;
        }
        const slot: usize = @intCast(index);
        self.buffers[slot] = buffer;
        self.buffer_offsets[slot] = offset;
        if (slot == 0) {
            self.buffer = buffer;
            self.buffer_offset = offset;
        }
    }

    pub fn setBufferOffset(self: *ComputeEncoder, offset: usize, index: u32) Error!void {
        if (!self.open() or index >= max_buffer_bindings) return error.UnsupportedOperation;
        const slot: usize = @intCast(index);
        const buffer = self.buffers[slot] orelse return error.InvalidCommand;
        try self.setBuffer(buffer, offset, index);
    }

    pub fn setAccelerationStructure(self: *ComputeEncoder, structure: ?*Buffer, index: u32) Error!void {
        if (!self.open()) return error.UnsupportedOperation;
        if (structure) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device) return error.InvalidResource;
        }
        self.acceleration_structure = structure;
        self.acceleration_structure_index = index;
    }

    pub fn setIntersectionFunctionProfile(self: *ComputeEncoder, profile: u32) Error!void {
        if (!self.open() or profile > 3) return error.UnsupportedOperation;
        self.intersection_function_profile = @intCast(profile);
    }

    pub fn setBytes(self: *ComputeEncoder, bytes: ?[*]const u8, length: usize, index: u32) Error!void {
        if (!self.open() or index >= max_buffer_bindings or (length != 0 and bytes == null)) return error.InvalidArgument;
        const buffer = try createBuffer(self.command_buffer.queue.device, length, bytes);
        errdefer destroyBuffer(buffer);
        self.command_buffer.owned_compute_buffers.append(allocator, buffer) catch return error.OutOfMemory;
        const slot: usize = @intCast(index);
        self.buffers[slot] = buffer;
        self.buffer_offsets[slot] = 0;
        if (slot == 0) {
            self.buffer = buffer;
            self.buffer_offset = 0;
        }
    }

    pub fn setTexture(self: *ComputeEncoder, texture: ?*Texture, index: u32) Error!void {
        if (!self.open() or (index != 0 and index != 1)) return error.UnsupportedOperation;
        if (texture) |value| {
            if (!validTexture(value) or value.device != self.command_buffer.queue.device or !value.format.isColor()) return error.InvalidResource;
        }
        self.textures[index] = texture;
        self.array_slices[index] = null;
    }

    pub fn setArraySlice(self: *ComputeEncoder, slice: u32, index: u32) Error!void {
        if (!self.open() or index > 1 or self.textures[index] == null) return error.InvalidArgument;
        self.array_slices[index] = slice;
    }

    // Metal 4 exposes copy/fill operations on the compute encoder. They are
    // recorded into the same ordered command stream as dispatches so the CPU
    // adapter preserves deferred execution and resource lifetime semantics.
    pub fn copyBuffer(self: *ComputeEncoder, source: *Buffer, source_offset: usize, destination: *Buffer, destination_offset: usize, length: usize) Error!void {
        if (!self.open() or !validBuffer(source) or !validBuffer(destination)) return error.InvalidArgument;
        if (source.device != destination.device or !rangeValid(source.bytes.len, source_offset, length) or
            !rangeValid(destination.bytes.len, destination_offset, length)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_buffer = .{ .source = source, .source_offset = source_offset, .destination = destination, .destination_offset = destination_offset, .length = length } });
    }

    pub fn copyBufferToTexture(self: *ComputeEncoder, source: *Buffer, source_offset: usize, source_bytes_per_row: usize, destination: *Texture, destination_region: abi.Region) Error!void {
        if (!self.open() or !validBuffer(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_buffer_to_texture = .{ .buffer = source, .buffer_offset = source_offset, .bytes_per_row = source_bytes_per_row, .texture = destination, .region = destination_region } });
    }

    pub fn copyTextureToBuffer(self: *ComputeEncoder, source: *Texture, source_region: abi.Region, destination: *Buffer, destination_offset: usize, destination_bytes_per_row: usize) Error!void {
        if (!self.open() or !validTexture(source) or !validBuffer(destination)) return error.InvalidArgument;
        if (source.device != destination.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_texture_to_buffer = .{ .texture = source, .region = source_region, .buffer = destination, .buffer_offset = destination_offset, .bytes_per_row = destination_bytes_per_row } });
    }

    pub fn copyTextureToTexture(self: *ComputeEncoder, source: *Texture, source_region: abi.Region, destination: *Texture, destination_region: abi.Region) Error!void {
        if (!self.open() or !validTexture(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .copy_texture_to_texture = .{ .source = source, .source_region = source_region, .destination = destination, .destination_region = destination_region } });
    }

    pub fn generateMipmap(self: *ComputeEncoder, source: *Texture, destination: *Texture) Error!void {
        if (!self.open() or !validTexture(source) or !validTexture(destination)) return error.InvalidArgument;
        if (source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        if (source.format.isIntegerColor()) return error.UnsupportedFormat;
        _ = try self.command_buffer.append(.{ .generate_mipmap = .{ .source = source, .destination = destination } });
    }

    pub fn generateSrgbMipmapChain(self: *ComputeEncoder, levels: []const *Texture) Error!void {
        if (!self.open() or levels.len < 2) return error.InvalidArgument;
        const format = levels[0].format;
        if (!isSrgb8Format(format)) return error.UnsupportedFormat;
        for (levels) |level| {
            if (!validTexture(level) or level.device != self.command_buffer.queue.device or level.format != format) return error.InvalidArgument;
        }
        try self.command_buffer.appendSrgbMipmapChain(levels);
    }

    pub fn generateMipmap3D(self: *ComputeEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture) Error!void {
        const denominator: u32 = if (source1 != null) 2 else 1;
        try self.generateMipmap3DWeighted(source0, source1, destination, if (source1 != null) 1 else 0, denominator);
    }

    pub fn generateMipmap3DWeighted(self: *ComputeEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) Error!void {
        if (!self.open() or !validTexture(source0) or !validTexture(destination)) return error.InvalidArgument;
        if (source0.device != destination.device or source0.format != destination.format) return error.InvalidArgument;
        if (source0.format.isIntegerColor()) return error.UnsupportedFormat;
        if (source1) |value| {
            if (!validTexture(value) or value.device != destination.device or value.format != destination.format) return error.InvalidArgument;
        }
        if (source1_weight_denominator == 0 or source1_weight_numerator > source1_weight_denominator or
            (source1 == null and source1_weight_numerator != 0)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .generate_mipmap_3d = .{
            .source0 = source0,
            .source1 = source1,
            .destination = destination,
            .source1_weight_numerator = source1_weight_numerator,
            .source1_weight_denominator = source1_weight_denominator,
        } });
    }

    pub fn generateMipmap3DArray(self: *ComputeEncoder, sources: []const *Texture, destination: *Texture) Error!void {
        if (!self.open() or !validTexture(destination) or sources.len == 0) return error.InvalidArgument;
        if (destination.format.isIntegerColor()) return error.UnsupportedFormat;
        for (sources) |source| {
            if (!validTexture(source) or source.device != destination.device or source.format != destination.format) return error.InvalidArgument;
        }
        try self.command_buffer.appendMipmap3DArray(sources, destination);
    }

    pub fn fillBuffer(self: *ComputeEncoder, buffer: *Buffer, offset: usize, length: usize, value: u8) Error!void {
        if (!self.open() or !validBuffer(buffer) or !rangeValid(buffer.bytes.len, offset, length)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .fill_buffer = .{ .buffer = buffer, .offset = offset, .length = length, .value = value } });
    }

    pub fn dispatchThreads(self: *ComputeEncoder, threads_per_grid: abi.Size, threads_per_threadgroup: abi.Size) Error!void {
        if (!self.open() or self.kernel == 0) return error.InvalidCommand;
        if (self.kernel == 29) return self.appendSourceNoop(threads_per_grid, threads_per_threadgroup, null, 0, false);
        if (self.isBufferAddKernel()) {
            return self.appendBufferAdd(threads_per_grid, threads_per_threadgroup, null, 0, false);
        }
        if (self.textureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 31 and self.sourceTextureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 2 and self.buffer == null) return error.InvalidCommand;
        if ((self.kernel == 7 or self.kernel == 45) and
            (self.acceleration_structure == null or self.acceleration_structure_index != 0)) return error.InvalidCommand;
        if ((self.kernel != 3 and self.kernel != 4 and threads_per_grid.depth != 1) or
            threads_per_threadgroup.width == 0 or
            threads_per_threadgroup.height == 0 or threads_per_threadgroup.depth == 0) return error.InvalidArgument;
        if (self.kernel != 4 and threads_per_threadgroup.depth != 1) return error.UnsupportedOperation;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .source_texture = self.sourceTextureForKernel(),
            .texture = self.textureForKernel().?,
            .texture_index = @intCast(self.textureIndexForKernel()),
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .acceleration_structure = self.acceleration_structure,
            .acceleration_structure_index = self.acceleration_structure_index,
            .intersection_function_profile = self.intersection_function_profile,
            .threads_per_grid = threads_per_grid,
            .threads_per_threadgroup = threads_per_threadgroup,
            .array_slice = self.array_slices[self.textureIndexForKernel()],
        } });
    }

    pub fn dispatchThreadgroups(self: *ComputeEncoder, threadgroups_per_grid: abi.Size, threads_per_threadgroup: abi.Size) Error!void {
        if (!self.open() or self.kernel == 0) return error.InvalidCommand;
        if (self.kernel == 29) {
            const grid_width = @as(u64, threadgroups_per_grid.width) * @as(u64, threads_per_threadgroup.width);
            const grid_height = @as(u64, threadgroups_per_grid.height) * @as(u64, threads_per_threadgroup.height);
            const grid_depth = @as(u64, threadgroups_per_grid.depth) * @as(u64, threads_per_threadgroup.depth);
            if (grid_width > std.math.maxInt(u32) or grid_height > std.math.maxInt(u32) or
                grid_depth > std.math.maxInt(u32)) return error.InvalidArgument;
            return self.appendSourceNoop(.{
                .width = @intCast(grid_width),
                .height = @intCast(grid_height),
                .depth = @intCast(grid_depth),
            }, threads_per_threadgroup, null, 0, false);
        }
        if (self.isBufferAddKernel()) {
            const grid_width = @as(u64, threadgroups_per_grid.width) * @as(u64, threads_per_threadgroup.width);
            if (grid_width > std.math.maxInt(u32)) return error.InvalidArgument;
            return self.dispatchThreads(.{
                .width = @intCast(grid_width),
                .height = threadgroups_per_grid.height,
                .depth = threadgroups_per_grid.depth,
            }, threads_per_threadgroup);
        }
        if (self.textureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 31 and self.sourceTextureForKernel() == null) return error.InvalidCommand;
        if ((self.kernel != 3 and self.kernel != 4 and threadgroups_per_grid.depth != 1) or
            (self.kernel != 4 and threads_per_threadgroup.depth != 1) or
            threads_per_threadgroup.width == 0 or threads_per_threadgroup.height == 0) return error.InvalidArgument;
        const grid_width = @as(u64, threadgroups_per_grid.width) * @as(u64, threads_per_threadgroup.width);
        const grid_height = @as(u64, threadgroups_per_grid.height) * @as(u64, threads_per_threadgroup.height);
        if (grid_width > std.math.maxInt(u32) or grid_height > std.math.maxInt(u32)) return error.InvalidArgument;
        return self.dispatchThreads(.{
            .width = @intCast(grid_width),
            .height = @intCast(grid_height),
            .depth = if (self.kernel == 3 or self.kernel == 4) threadgroups_per_grid.depth else 1,
        }, threads_per_threadgroup);
    }

    pub fn dispatchThreadgroupsIndirect(self: *ComputeEncoder, indirect_buffer: *Buffer, indirect_buffer_offset: usize, threads_per_threadgroup: abi.Size) Error!void {
        if (!self.open() or self.kernel == 0) return error.InvalidCommand;
        if (self.kernel == 29) {
            if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
                indirect_buffer_offset % @alignOf(u32) != 0 or
                !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, @sizeOf(abi.Size))) return error.InvalidArgument;
            return self.appendSourceNoop(.{ .width = 0, .height = 0, .depth = 1 }, threads_per_threadgroup, indirect_buffer, indirect_buffer_offset, false);
        }
        if (self.isBufferAddKernel()) {
            if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
                indirect_buffer_offset % @alignOf(u32) != 0 or
                !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, @sizeOf(abi.Size))) return error.InvalidArgument;
            return self.appendBufferAdd(.{ .width = 0, .height = 1, .depth = 1 }, threads_per_threadgroup, indirect_buffer, indirect_buffer_offset, false);
        }
        if (self.textureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 31 and self.sourceTextureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 2 and self.buffer == null) return error.InvalidCommand;
        if ((self.kernel == 7 or self.kernel == 45) and
            (self.acceleration_structure == null or self.acceleration_structure_index != 0)) return error.InvalidCommand;
        if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
            indirect_buffer_offset % @alignOf(u32) != 0 or
            !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, @sizeOf(abi.Size))) return error.InvalidArgument;
        if (threads_per_threadgroup.depth == 0 or threads_per_threadgroup.width == 0 or threads_per_threadgroup.height == 0) return error.InvalidArgument;
        if (self.kernel != 4 and threads_per_threadgroup.depth != 1) return error.UnsupportedOperation;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .source_texture = self.sourceTextureForKernel(),
            .texture = self.textureForKernel().?,
            .texture_index = @intCast(self.textureIndexForKernel()),
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .acceleration_structure = self.acceleration_structure,
            .acceleration_structure_index = self.acceleration_structure_index,
            .intersection_function_profile = self.intersection_function_profile,
            .threads_per_grid = .{ .width = 0, .height = 0, .depth = 1 },
            .threads_per_threadgroup = threads_per_threadgroup,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .array_slice = self.array_slices[self.textureIndexForKernel()],
        } });
    }

    pub fn dispatchThreadsIndirect(self: *ComputeEncoder, indirect_buffer: *Buffer) Error!void {
        return self.dispatchThreadsIndirectAtOffset(indirect_buffer, 0);
    }

    pub fn dispatchThreadsIndirectAtOffset(self: *ComputeEncoder, indirect_buffer: *Buffer, indirect_buffer_offset: usize) Error!void {
        if (!self.open() or self.kernel == 0) return error.InvalidCommand;
        if (self.kernel == 29) {
            if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
                indirect_buffer_offset % @alignOf(u32) != 0 or
                !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 2 * @sizeOf(abi.Size))) return error.InvalidArgument;
            return self.appendSourceNoop(.{ .width = 0, .height = 0, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 }, indirect_buffer, indirect_buffer_offset, true);
        }
        if (self.isBufferAddKernel()) {
            if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
                indirect_buffer_offset % @alignOf(u32) != 0 or
                !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 2 * @sizeOf(abi.Size))) return error.InvalidArgument;
            return self.appendBufferAdd(.{ .width = 0, .height = 0, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 }, indirect_buffer, indirect_buffer_offset, true);
        }
        if (self.textureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 31 and self.sourceTextureForKernel() == null) return error.InvalidCommand;
        if (self.kernel == 2 and self.buffer == null) return error.InvalidCommand;
        if ((self.kernel == 7 or self.kernel == 45) and
            (self.acceleration_structure == null or self.acceleration_structure_index != 0)) return error.InvalidCommand;
        if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
            indirect_buffer_offset % @alignOf(u32) != 0 or
            !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 2 * @sizeOf(abi.Size))) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .source_texture = self.sourceTextureForKernel(),
            .texture = self.textureForKernel().?,
            .texture_index = @intCast(self.textureIndexForKernel()),
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .acceleration_structure = self.acceleration_structure,
            .acceleration_structure_index = self.acceleration_structure_index,
            .intersection_function_profile = self.intersection_function_profile,
            .threads_per_grid = .{ .width = 0, .height = 0, .depth = 1 },
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .indirect_threads = true,
            .array_slice = self.array_slices[self.textureIndexForKernel()],
        } });
    }

    pub fn endEncoding(self: *ComputeEncoder) Error!void {
        if (!self.open()) return error.InvalidCommand;
        try self.command_buffer.end(.compute);
    }

    pub fn updateFence(self: *ComputeEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .update_fence = fence });
    }

    pub fn waitForFence(self: *ComputeEncoder, fence: *Fence) Error!void {
        if (!self.open() or !validFence(fence) or fence.device != self.command_buffer.queue.device) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .wait_fence = fence });
    }
};

fn unorm8ChannelCount(format: TextureFormat) usize {
    return switch (format) {
        .a8_unorm => 1,
        .r8_unorm => 1,
        .rg8_unorm => 2,
        .rgba8_unorm, .bgra8_unorm => 4,
        else => unreachable,
    };
}

fn srgb8ChannelCount(format: TextureFormat) usize {
    return switch (format) {
        .r8_unorm_srgb => 1,
        .rg8_unorm_srgb => 2,
        .rgba8_unorm_srgb, .bgra8_unorm_srgb => 4,
        else => unreachable,
    };
}

fn isSrgb8Format(format: TextureFormat) bool {
    return switch (format) {
        .r8_unorm_srgb, .rg8_unorm_srgb, .rgba8_unorm_srgb, .bgra8_unorm_srgb => true,
        else => false,
    };
}

fn srgb8ToLinear(value: u8) f64 {
    const normalized = @as(f64, @floatFromInt(value)) / 255.0;
    const decoded = if (normalized <= 0.04045)
        normalized / 12.92
    else
        std.math.pow(f64, (normalized + 0.055) / 1.055, 2.4);
    return @round(decoded * 4095.0) / 4095.0;
}

fn srgb8AlphaToF32(value: u8) f32 {
    return @as(f32, @floatFromInt(value)) / 255.0;
}

fn linearToSrgb8(value: f64) u8 {
    // Apple texture filtering keeps the linear intermediate at 12-bit
    // precision before converting it back to an 8-bit sRGB texel. Narrow to
    // f32 before the fixed-point rounding to match the GPU's conversion
    // boundary for halfway values.
    const clamped: f32 = @floatCast(std.math.clamp(value, 0, 1));
    const linear = @floor(@as(f64, clamped) * 4095.0 + 0.5) / 4095.0;
    const encoded = if (linear <= 0.0031308)
        linear * 12.92
    else
        1.055 * std.math.pow(f64, linear, 1.0 / 2.4) - 0.055;
    return @intFromFloat(encoded * 255.0 + 0.5);
}

fn unorm8Value(value: f64) u8 {
    const scaled = std.math.clamp(value, 0, 1) * 255.0;
    const lower = @floor(scaled);
    const fraction = scaled - lower;
    const lower_integer: u64 = @intFromFloat(lower);
    const rounded = if (fraction > 0.5 or (fraction == 0.5 and lower_integer % 2 == 1)) lower + 1 else lower;
    return @intFromFloat(rounded);
}

fn readSrgb8MipmapColor(texture: *const Texture, x: usize, y: usize) [4]f64 {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .r8_unorm_srgb => .{ srgb8ToLinear(texture.bytes[offset]), 0, 0, 1 },
        .rg8_unorm_srgb => .{ srgb8ToLinear(texture.bytes[offset]), srgb8ToLinear(texture.bytes[offset + 1]), 0, 1 },
        .rgba8_unorm_srgb => .{
            srgb8ToLinear(texture.bytes[offset]),     srgb8ToLinear(texture.bytes[offset + 1]),
            srgb8ToLinear(texture.bytes[offset + 2]), @floatCast(srgb8AlphaToF32(texture.bytes[offset + 3])),
        },
        .bgra8_unorm_srgb => .{
            srgb8ToLinear(texture.bytes[offset + 2]), srgb8ToLinear(texture.bytes[offset + 1]),
            srgb8ToLinear(texture.bytes[offset]),     @floatCast(srgb8AlphaToF32(texture.bytes[offset + 3])),
        },
        else => unreachable,
    };
}

fn writeSrgb8MipmapColor(texture: *Texture, x: usize, y: usize, color: [4]f64) void {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    switch (texture.format) {
        .r8_unorm_srgb => texture.bytes[offset] = linearToSrgb8(color[0]),
        .rg8_unorm_srgb => {
            texture.bytes[offset] = linearToSrgb8(color[0]);
            texture.bytes[offset + 1] = linearToSrgb8(color[1]);
        },
        .rgba8_unorm_srgb => {
            texture.bytes[offset] = linearToSrgb8(color[0]);
            texture.bytes[offset + 1] = linearToSrgb8(color[1]);
            texture.bytes[offset + 2] = linearToSrgb8(color[2]);
            texture.bytes[offset + 3] = unorm8Value(color[3]);
        },
        .bgra8_unorm_srgb => {
            texture.bytes[offset] = linearToSrgb8(color[2]);
            texture.bytes[offset + 1] = linearToSrgb8(color[1]);
            texture.bytes[offset + 2] = linearToSrgb8(color[0]);
            texture.bytes[offset + 3] = unorm8Value(color[3]);
        },
        else => unreachable,
    }
}

fn unorm16ChannelCount(format: TextureFormat) usize {
    return switch (format) {
        .r16_unorm => 1,
        .rg16_unorm => 2,
        .rgba16_unorm => 4,
        else => unreachable,
    };
}

fn snorm8ChannelCount(format: TextureFormat) usize {
    return switch (format) {
        .r8_snorm => 1,
        .rg8_snorm => 2,
        .rgba8_snorm => 4,
        else => unreachable,
    };
}

fn snorm16ChannelCount(format: TextureFormat) usize {
    return switch (format) {
        .r16_snorm => 1,
        .rg16_snorm => 2,
        .rgba16_snorm => 4,
        else => unreachable,
    };
}

fn readMipmapS8(bytes: []const u8, offset: usize) f64 {
    const value: i8 = @bitCast(bytes[offset]);
    return if (value == std.math.minInt(i8)) -1 else @as(f64, @floatFromInt(value)) / 127.0;
}

fn readMipmapS16(bytes: []const u8, offset: usize) f64 {
    const value = std.mem.readInt(i16, bytes[offset..][0..2], .little);
    return if (value == std.math.minInt(i16)) -1 else @as(f64, @floatFromInt(value)) / 32767.0;
}

fn snorm8Value(value: f64) i8 {
    const clamped = std.math.clamp(value, -1, 1);
    const scaled = clamped * 127.0;
    const magnitude = if (scaled < 0) -scaled else scaled;
    const lower = @floor(magnitude);
    const rounded = if (magnitude - lower > 0.5) lower + 1 else lower;
    const quantized: i16 = if (scaled < 0) -@as(i16, @intFromFloat(rounded)) else @intFromFloat(rounded);
    return @intCast(std.math.clamp(quantized, -128, 127));
}

fn snorm16Value(value: f64) i16 {
    const clamped = std.math.clamp(value, -1, 1);
    const scaled = clamped * 32767.0;
    const magnitude = if (scaled < 0) -scaled else scaled;
    const lower = @floor(magnitude);
    const rounded = if (magnitude - lower > 0.5) lower + 1 else lower;
    const quantized: i32 = if (scaled < 0) -@as(i32, @intFromFloat(rounded)) else @intFromFloat(rounded);
    return @intCast(std.math.clamp(quantized, -32768, 32767));
}

fn readSnormMipmapColor(texture: *const Texture, x: usize, y: usize) [4]f64 {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .r8_snorm => .{ readMipmapS8(texture.bytes, offset), 0, 0, 1 },
        .rg8_snorm => .{ readMipmapS8(texture.bytes, offset), readMipmapS8(texture.bytes, offset + 1), 0, 1 },
        .rgba8_snorm => .{
            readMipmapS8(texture.bytes, offset),     readMipmapS8(texture.bytes, offset + 1),
            readMipmapS8(texture.bytes, offset + 2), readMipmapS8(texture.bytes, offset + 3),
        },
        .r16_snorm => .{ readMipmapS16(texture.bytes, offset), 0, 0, 1 },
        .rg16_snorm => .{ readMipmapS16(texture.bytes, offset), readMipmapS16(texture.bytes, offset + 2), 0, 1 },
        .rgba16_snorm => .{
            readMipmapS16(texture.bytes, offset),     readMipmapS16(texture.bytes, offset + 2),
            readMipmapS16(texture.bytes, offset + 4), readMipmapS16(texture.bytes, offset + 6),
        },
        else => unreachable,
    };
}

fn writeSnormMipmapColor(texture: *Texture, x: usize, y: usize, color: [4]f64) void {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    switch (texture.format) {
        .r8_snorm => texture.bytes[offset] = @bitCast(snorm8Value(color[0])),
        .rg8_snorm => {
            texture.bytes[offset] = @bitCast(snorm8Value(color[0]));
            texture.bytes[offset + 1] = @bitCast(snorm8Value(color[1]));
        },
        .rgba8_snorm => {
            texture.bytes[offset] = @bitCast(snorm8Value(color[0]));
            texture.bytes[offset + 1] = @bitCast(snorm8Value(color[1]));
            texture.bytes[offset + 2] = @bitCast(snorm8Value(color[2]));
            texture.bytes[offset + 3] = @bitCast(snorm8Value(color[3]));
        },
        .r16_snorm => std.mem.writeInt(i16, texture.bytes[offset..][0..2], snorm16Value(color[0]), .little),
        .rg16_snorm => {
            std.mem.writeInt(i16, texture.bytes[offset..][0..2], snorm16Value(color[0]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 2 ..][0..2], snorm16Value(color[1]), .little);
        },
        .rgba16_snorm => {
            std.mem.writeInt(i16, texture.bytes[offset..][0..2], snorm16Value(color[0]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 2 ..][0..2], snorm16Value(color[1]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 4 ..][0..2], snorm16Value(color[2]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 6 ..][0..2], snorm16Value(color[3]), .little);
        },
        else => unreachable,
    }
}

fn readSnormMipmapCode(texture: *const Texture, x: usize, y: usize, component: usize) i128 {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .r8_snorm => @as(i128, @intCast(if (@as(i8, @bitCast(texture.bytes[offset])) == std.math.minInt(i8)) -127 else @as(i8, @bitCast(texture.bytes[offset])))),
        .rg8_snorm, .rgba8_snorm => @as(i128, @intCast(if (@as(i8, @bitCast(texture.bytes[offset + component])) == std.math.minInt(i8)) -127 else @as(i8, @bitCast(texture.bytes[offset + component])))),
        .r16_snorm => @as(i128, @intCast(if (std.mem.readInt(i16, texture.bytes[offset..][0..2], .little) == std.math.minInt(i16)) -32767 else std.mem.readInt(i16, texture.bytes[offset..][0..2], .little))),
        .rg16_snorm, .rgba16_snorm => @as(i128, @intCast(if (std.mem.readInt(i16, texture.bytes[offset + component * 2 ..][0..2], .little) == std.math.minInt(i16)) -32767 else std.mem.readInt(i16, texture.bytes[offset + component * 2 ..][0..2], .little))),
        else => unreachable,
    };
}

fn averagedSnormCode(sum: i128, denominator: u64, maximum: i128) i128 {
    const denominator_i128: i128 = @intCast(denominator);
    const magnitude = if (sum < 0) -sum else sum;
    const remainder = @rem(magnitude, denominator_i128);
    const rounded = @divTrunc(magnitude, denominator_i128) + @as(i128, @intFromBool(remainder * 2 > denominator_i128));
    const signed = if (sum < 0) -rounded else rounded;
    return std.math.clamp(signed, -maximum, maximum);
}

fn writeSnormMipmapCode(texture: *Texture, x: usize, y: usize, codes: [4]i128) void {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    switch (texture.format) {
        .r8_snorm => texture.bytes[offset] = @bitCast(@as(i8, @intCast(codes[0]))),
        .rg8_snorm => {
            texture.bytes[offset] = @bitCast(@as(i8, @intCast(codes[0])));
            texture.bytes[offset + 1] = @bitCast(@as(i8, @intCast(codes[1])));
        },
        .rgba8_snorm => {
            texture.bytes[offset] = @bitCast(@as(i8, @intCast(codes[0])));
            texture.bytes[offset + 1] = @bitCast(@as(i8, @intCast(codes[1])));
            texture.bytes[offset + 2] = @bitCast(@as(i8, @intCast(codes[2])));
            texture.bytes[offset + 3] = @bitCast(@as(i8, @intCast(codes[3])));
        },
        .r16_snorm => std.mem.writeInt(i16, texture.bytes[offset..][0..2], @intCast(codes[0]), .little),
        .rg16_snorm => {
            std.mem.writeInt(i16, texture.bytes[offset..][0..2], @intCast(codes[0]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 2 ..][0..2], @intCast(codes[1]), .little);
        },
        .rgba16_snorm => {
            std.mem.writeInt(i16, texture.bytes[offset..][0..2], @intCast(codes[0]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 2 ..][0..2], @intCast(codes[1]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 4 ..][0..2], @intCast(codes[2]), .little);
            std.mem.writeInt(i16, texture.bytes[offset + 6 ..][0..2], @intCast(codes[3]), .little);
        },
        else => unreachable,
    }
}

const CpuRayVec3 = struct {
    x: f32,
    y: f32,
    z: f32,
};

fn cpuRaySub(left: CpuRayVec3, right: CpuRayVec3) CpuRayVec3 {
    return .{ .x = left.x - right.x, .y = left.y - right.y, .z = left.z - right.z };
}

fn cpuRayCross(left: CpuRayVec3, right: CpuRayVec3) CpuRayVec3 {
    return .{
        .x = left.y * right.z - left.z * right.y,
        .y = left.z * right.x - left.x * right.z,
        .z = left.x * right.y - left.y * right.x,
    };
}

fn cpuRayDot(left: CpuRayVec3, right: CpuRayVec3) f32 {
    return left.x * right.x + left.y * right.y + left.z * right.z;
}

fn readF32Little(bytes: []const u8, offset: usize) f32 {
    return @bitCast(readU32Little(bytes, offset));
}

fn cpuAccelerationVersionSupported(version: u32) bool {
    return version == 1 or version == cpu_acceleration_structure_version;
}

fn cpuRayTriangleHit(origin: CpuRayVec3, direction: CpuRayVec3, v0: CpuRayVec3, v1: CpuRayVec3, v2: CpuRayVec3) ?f32 {
    const edge1 = cpuRaySub(v1, v0);
    const edge2 = cpuRaySub(v2, v0);
    const pvec = cpuRayCross(direction, edge2);
    const determinant = cpuRayDot(edge1, pvec);
    if (!std.math.isFinite(determinant) or @abs(determinant) < 0.0000001) return null;
    const inverse_determinant = 1.0 / determinant;
    const tvec = cpuRaySub(origin, v0);
    const u = cpuRayDot(tvec, pvec) * inverse_determinant;
    if (u < 0.0 or u > 1.0) return null;
    const qvec = cpuRayCross(tvec, edge1);
    const v = cpuRayDot(direction, qvec) * inverse_determinant;
    if (v < 0.0 or u + v > 1.0) return null;
    const distance = cpuRayDot(edge2, qvec) * inverse_determinant;
    if (!std.math.isFinite(distance) or distance < 0.0) return null;
    return distance;
}

fn cpuRayAabbHit(origin: CpuRayVec3, direction: CpuRayVec3, minimum: CpuRayVec3, maximum: CpuRayVec3) ?f32 {
    var near: f32 = 0.0;
    var far: f32 = std.math.inf(f32);
    const origins = [_]f32{ origin.x, origin.y, origin.z };
    const directions = [_]f32{ direction.x, direction.y, direction.z };
    const minima = [_]f32{ minimum.x, minimum.y, minimum.z };
    const maxima = [_]f32{ maximum.x, maximum.y, maximum.z };
    for (0..3) |axis| {
        if (!std.math.isFinite(minima[axis]) or !std.math.isFinite(maxima[axis]) or minima[axis] > maxima[axis]) return null;
        if (@abs(directions[axis]) < 0.0000001) {
            if (origins[axis] < minima[axis] or origins[axis] > maxima[axis]) return null;
            continue;
        }
        const inverse_direction = 1.0 / directions[axis];
        var first = (minima[axis] - origins[axis]) * inverse_direction;
        var second = (maxima[axis] - origins[axis]) * inverse_direction;
        if (first > second) std.mem.swap(f32, &first, &second);
        near = @max(near, first);
        far = @min(far, second);
        if (near > far) return null;
    }
    return if (far >= 0.0 and std.math.isFinite(far)) near else null;
}

fn executeTraceTriangles(command: ComputeCommand) Error!void {
    const texture = command.texture orelse return error.InvalidResource;
    if (texture.format != .rgba8_unorm) return error.UnsupportedFormat;
    const acceleration_structure = command.acceleration_structure orelse return error.InvalidCommand;
    if (command.intersection_function_profile > 2) return error.UnsupportedOperation;
    if (!validBuffer(acceleration_structure) or acceleration_structure.device != texture.device) return error.InvalidResource;
    if (!rangeValid(acceleration_structure.bytes.len, 0, cpu_acceleration_structure_header_bytes)) return error.InvalidArgument;
    if (readU32Little(acceleration_structure.bytes, 0) != cpu_acceleration_structure_magic or
        !cpuAccelerationVersionSupported(readU32Little(acceleration_structure.bytes, 4))) return error.InvalidResource;
    const triangle_count: usize = @intCast(readU32Little(acceleration_structure.bytes, 8));
    const flags = readU32Little(acceleration_structure.bytes, 12);
    const triangle_offset: usize = @intCast(readU32Little(acceleration_structure.bytes, 16));
    const triangle_bytes = std.math.mul(usize, triangle_count, cpu_acceleration_structure_triangle_bytes) catch return error.InvalidArgument;
    if (triangle_offset < cpu_acceleration_structure_header_bytes or
        !rangeValid(acceleration_structure.bytes.len, triangle_offset, triangle_bytes)) return error.InvalidArgument;
    const mask_offset: usize = @intCast(readU32Little(acceleration_structure.bytes, 20));
    if ((flags & cpu_acceleration_structure_flag_triangle_masks) != 0) {
        const mask_bytes = std.math.mul(usize, triangle_count, @sizeOf(u32)) catch return error.InvalidArgument;
        if (mask_offset < triangle_offset or mask_offset - triangle_offset < triangle_bytes or
            !rangeValid(acceleration_structure.bytes.len, mask_offset, mask_bytes)) return error.InvalidArgument;
    }
    const width = @min(command.threads_per_grid.width, texture.width);
    const height = @min(command.threads_per_grid.height, texture.height);
    var target = texture.asTarget();
    for (0..height) |y| for (0..width) |x| {
        // Metal's texture grid is top-left: row zero is the upper edge and
        // clip/world +Y therefore maps toward decreasing pixel rows.
        const origin = CpuRayVec3{
            .x = 2.0 * ((@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(texture.width))) - 1.0,
            .y = 1.0 - 2.0 * ((@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(texture.height))),
            .z = 1.0,
        };
        const direction = CpuRayVec3{ .x = 0.0, .y = 0.0, .z = -1.0 };
        var nearest: ?f32 = null;
        var triangle_index: usize = 0;
        while (triangle_index < triangle_count) : (triangle_index += 1) {
            if ((flags & cpu_acceleration_structure_flag_triangle_masks) != 0 and
                (readU32Little(acceleration_structure.bytes, mask_offset + triangle_index * @sizeOf(u32)) & std.math.maxInt(u32)) == 0)
            {
                continue;
            }
            const base = triangle_offset + triangle_index * cpu_acceleration_structure_triangle_bytes;
            const v0 = CpuRayVec3{
                .x = readF32Little(acceleration_structure.bytes, base),
                .y = readF32Little(acceleration_structure.bytes, base + 4),
                .z = readF32Little(acceleration_structure.bytes, base + 8),
            };
            const v1 = CpuRayVec3{
                .x = readF32Little(acceleration_structure.bytes, base + 12),
                .y = readF32Little(acceleration_structure.bytes, base + 16),
                .z = readF32Little(acceleration_structure.bytes, base + 20),
            };
            const v2 = CpuRayVec3{
                .x = readF32Little(acceleration_structure.bytes, base + 24),
                .y = readF32Little(acceleration_structure.bytes, base + 28),
                .z = readF32Little(acceleration_structure.bytes, base + 32),
            };
            // Profile 1 is the CPU implementation of the registered reject-
            // all intersection function. Keep traversal deterministic and
            // skip the candidate exactly where Metal would reject it.
            if (command.intersection_function_profile == 1) continue;
            if (cpuRayTriangleHit(origin, direction, v0, v1, v2)) |distance| {
                if (nearest == null or distance < nearest.?) nearest = distance;
            }
        }
        target.storeColor(x, y, if (nearest != null) .{ 1.0, 0.0, 0.0, 1.0 } else .{ 0.0, 0.0, 0.0, 1.0 });
    };
}

fn executeTraceAabbs(command: ComputeCommand) Error!void {
    const texture = command.texture orelse return error.InvalidResource;
    if (texture.format != .rgba8_unorm) return error.UnsupportedFormat;
    const acceleration_structure = command.acceleration_structure orelse return error.InvalidCommand;
    if (command.intersection_function_profile != 0 and command.intersection_function_profile != 3)
        return error.UnsupportedOperation;
    if (!validBuffer(acceleration_structure) or acceleration_structure.device != texture.device) return error.InvalidResource;
    if (!rangeValid(acceleration_structure.bytes.len, 0, cpu_acceleration_structure_header_bytes)) return error.InvalidArgument;
    if (readU32Little(acceleration_structure.bytes, 0) != cpu_acceleration_structure_magic or
        readU32Little(acceleration_structure.bytes, 4) != cpu_acceleration_structure_version) return error.InvalidResource;
    const triangle_count: usize = @intCast(readU32Little(acceleration_structure.bytes, 8));
    const flags = readU32Little(acceleration_structure.bytes, 12);
    if ((flags & cpu_acceleration_structure_flag_aabbs) == 0) return error.InvalidResource;
    const triangle_offset: usize = @intCast(readU32Little(acceleration_structure.bytes, 16));
    const triangle_bytes = std.math.mul(usize, triangle_count, cpu_acceleration_structure_triangle_bytes) catch return error.InvalidArgument;
    const triangle_end = std.math.add(usize, triangle_offset, triangle_bytes) catch return error.InvalidArgument;
    if (triangle_offset < cpu_acceleration_structure_header_bytes or
        !rangeValid(acceleration_structure.bytes.len, triangle_offset, triangle_bytes)) return error.InvalidArgument;
    const aabb_offset: usize = @intCast(readU32Little(acceleration_structure.bytes, 24));
    const aabb_count: usize = @intCast(readU32Little(acceleration_structure.bytes, 28));
    const aabb_bytes = std.math.mul(usize, aabb_count, cpu_acceleration_structure_aabb_bytes) catch return error.InvalidArgument;
    if (aabb_offset < triangle_end or
        !rangeValid(acceleration_structure.bytes.len, aabb_offset, aabb_bytes)) return error.InvalidArgument;
    const mask_offset: usize = @intCast(readU32Little(acceleration_structure.bytes, 20));
    if ((flags & cpu_acceleration_structure_flag_triangle_masks) != 0) {
        const mask_bytes = std.math.mul(usize, aabb_count, @sizeOf(u32)) catch return error.InvalidArgument;
        if (mask_offset < aabb_offset or mask_offset - aabb_offset < aabb_bytes or
            !rangeValid(acceleration_structure.bytes.len, mask_offset, mask_bytes)) return error.InvalidArgument;
    }
    var validation_index: usize = 0;
    while (validation_index < aabb_count) : (validation_index += 1) {
        const base = aabb_offset + validation_index * cpu_acceleration_structure_aabb_bytes;
        const minimum = CpuRayVec3{
            .x = readF32Little(acceleration_structure.bytes, base),
            .y = readF32Little(acceleration_structure.bytes, base + 4),
            .z = readF32Little(acceleration_structure.bytes, base + 8),
        };
        const maximum = CpuRayVec3{
            .x = readF32Little(acceleration_structure.bytes, base + 12),
            .y = readF32Little(acceleration_structure.bytes, base + 16),
            .z = readF32Little(acceleration_structure.bytes, base + 20),
        };
        if (!std.math.isFinite(minimum.x) or !std.math.isFinite(minimum.y) or !std.math.isFinite(minimum.z) or
            !std.math.isFinite(maximum.x) or !std.math.isFinite(maximum.y) or !std.math.isFinite(maximum.z) or
            minimum.x > maximum.x or minimum.y > maximum.y or minimum.z > maximum.z)
            return error.InvalidArgument;
    }
    const width = @min(command.threads_per_grid.width, texture.width);
    const height = @min(command.threads_per_grid.height, texture.height);
    var target = texture.asTarget();
    for (0..height) |y| for (0..width) |x| {
        // Metal's row zero is the upper edge. Keep the same half-pixel
        // origin as the triangle profile for exact X/Y grid agreement.
        const origin = CpuRayVec3{
            .x = 2.0 * ((@as(f32, @floatFromInt(x)) + 0.5) / @as(f32, @floatFromInt(texture.width))) - 1.0,
            .y = 1.0 - 2.0 * ((@as(f32, @floatFromInt(y)) + 0.5) / @as(f32, @floatFromInt(texture.height))),
            .z = 1.0,
        };
        const direction = CpuRayVec3{ .x = 0.0, .y = 0.0, .z = -1.0 };
        var hit = false;
        var aabb_index: usize = 0;
        while (aabb_index < aabb_count) : (aabb_index += 1) {
            if ((flags & cpu_acceleration_structure_flag_triangle_masks) != 0 and
                (readU32Little(acceleration_structure.bytes, mask_offset + aabb_index * @sizeOf(u32)) & std.math.maxInt(u32)) == 0)
            {
                continue;
            }
            const base = aabb_offset + aabb_index * cpu_acceleration_structure_aabb_bytes;
            const minimum = CpuRayVec3{
                .x = readF32Little(acceleration_structure.bytes, base),
                .y = readF32Little(acceleration_structure.bytes, base + 4),
                .z = readF32Little(acceleration_structure.bytes, base + 8),
            };
            const maximum = CpuRayVec3{
                .x = readF32Little(acceleration_structure.bytes, base + 12),
                .y = readF32Little(acceleration_structure.bytes, base + 16),
                .z = readF32Little(acceleration_structure.bytes, base + 20),
            };
            if (cpuRayAabbHit(origin, direction, minimum, maximum) != null) {
                hit = true;
                break;
            }
        }
        target.storeColor(x, y, if (hit) .{ 1.0, 0.0, 0.0, 1.0 } else .{ 0.0, 0.0, 0.0, 1.0 });
    };
}

fn executeBufferAdd(command: ComputeBufferAddCommand) Error!void {
    const narrow = isNarrowKernel(command.kernel);
    const integer = isIntegerKernel(command.kernel);
    const narrow_vector_width = narrowVectorWidth(command.kernel);
    if ((command.kernel != 8 and command.kernel != 9 and command.kernel != 30 and command.kernel != 41 and
        command.kernel != 32 and command.kernel != 33 and command.kernel != 34 and
        command.kernel != 35 and command.kernel != 36 and command.kernel != 37 and
        command.kernel != 38 and command.kernel != 39 and command.kernel != 40 and
        command.kernel != 42 and command.kernel != 43 and command.kernel != 44 and
        !narrow and !integer) or
        (integer and (command.elements_per_thread != 1 or command.element_stride != 1)) or
        (command.elements_per_thread != 1 and command.elements_per_thread != 2 and
            command.elements_per_thread != 3 and command.elements_per_thread != 4) or
        (command.element_stride != 1 and command.element_stride != 2 and
            command.element_stride != 4) or
        (narrow and narrow_vector_width == null and
            (command.elements_per_thread != 1 or command.element_stride != 1)) or
        (narrow_vector_width != null and
            (command.elements_per_thread != narrow_vector_width.? or
             command.element_stride != (if (narrow_vector_width.? == 3) 4 else narrow_vector_width.?))) or
        !validBuffer(command.left) or !validBuffer(command.right) or
        !validBuffer(command.output) or command.left.device != command.right.device or
        command.output.device != command.left.device or command.threads_per_grid.height != 1 or
        command.threads_per_grid.depth != 1 or command.threads_per_threadgroup.width == 0 or
        command.threads_per_threadgroup.height != 1 or command.threads_per_threadgroup.depth != 1)
        return error.InvalidArgument;
    const storage_count = std.math.mul(usize, command.threads_per_grid.width, command.element_stride) catch return error.InvalidArgument;
    const element_bytes: usize = if (integer) integerKernelElementBytes(command.kernel) else if (narrow) @sizeOf(u16) else @sizeOf(f32);
    const byte_count = std.math.mul(usize, storage_count, element_bytes) catch return error.InvalidArgument;
    if (!rangeValid(command.left.bytes.len, command.left_offset, byte_count) or
        !rangeValid(command.right.bytes.len, command.right_offset, byte_count) or
        !rangeValid(command.output.bytes.len, command.output_offset, byte_count)) return error.InvalidArgument;
    for (0..command.threads_per_grid.width) |index| {
        for (0..command.elements_per_thread) |lane| {
            const scalar_index = index * command.element_stride + lane;
            const left_offset = command.left_offset + scalar_index * element_bytes;
            const right_offset = command.right_offset + scalar_index * element_bytes;
            const output_offset = command.output_offset + scalar_index * element_bytes;
            if (integer) {
                const left = switch (element_bytes) {
                    1 => @as(u32, command.left.bytes[left_offset]),
                    2 => @as(u32, readU16Little(command.left.bytes, left_offset)),
                    4 => readU32Little(command.left.bytes, left_offset),
                    else => unreachable,
                };
                const right = switch (element_bytes) {
                    1 => @as(u32, command.right.bytes[right_offset]),
                    2 => @as(u32, readU16Little(command.right.bytes, right_offset)),
                    4 => readU32Little(command.right.bytes, right_offset),
                    else => unreachable,
                };
                const result = switch (command.kernel) {
                    78, 81, 84, 87, 90, 93 => left +% right,
                    79, 82, 85, 88, 91, 94 => left -% right,
                    80, 83, 86, 89, 92, 95 => left *% right,
                    else => unreachable,
                };
                switch (element_bytes) {
                    1 => command.output.bytes[output_offset] = @truncate(result),
                    2 => writeU16Little(command.output.bytes, output_offset, @truncate(result)),
                    4 => writeU32Little(command.output.bytes, output_offset, result),
                    else => unreachable,
                }
                continue;
            } else if (narrow) {
                if (isNarrowHalfKernel(command.kernel)) {
                    const left: f16 = @bitCast(readU16Little(command.left.bytes, left_offset));
                    const right: f16 = @bitCast(readU16Little(command.right.bytes, right_offset));
                    const result: f16 = switch (command.kernel) {
                        46, 54, 58, 62 => left + right,
                        47, 55, 59, 63 => left * right,
                        48, 56, 60, 64 => left - right,
                        49, 57, 61, 65 => left / right,
                        else => unreachable,
                    };
                    writeU16Little(command.output.bytes, output_offset, @bitCast(result));
                } else {
                    const left = bfloat16FromBits(readU16Little(command.left.bytes, left_offset));
                    const right = bfloat16FromBits(readU16Little(command.right.bytes, right_offset));
                    const result = switch (command.kernel) {
                        50, 66, 70, 74 => left + right,
                        51, 67, 71, 75 => left * right,
                        52, 68, 72, 76 => left - right,
                        53, 69, 73, 77 => left / right,
                        else => unreachable,
                    };
                    writeU16Little(command.output.bytes, output_offset, bfloat16ToBits(result));
                }
                continue;
            }
            const left = readF32Little(command.left.bytes, left_offset);
            const right = readF32Little(command.right.bytes, right_offset);
            const result = switch (command.kernel) {
                8, 32, 35, 38 => left + right,
                9, 33, 36, 39 => left * right,
                30, 34, 37, 40 => left - right,
                41, 42, 43, 44 => left / right,
                else => unreachable,
            };
            std.mem.writeInt(u32, command.output.bytes[output_offset..][0..@sizeOf(f32)], @bitCast(result), .little);
        }
    }
}

fn executeCompute(command: ComputeCommand) Error!void {
    // An empty source kernel has no resource requirement. It still travels
    // through the deferred CPU command stream so dispatch ordering and
    // indirect argument validation match the other compute profiles.
    if (command.kernel == 29) return;
    const texture = command.texture orelse return error.InvalidResource;
    if (!validTexture(texture) or !texture.format.isColor()) return error.InvalidResource;
    if (command.kernel == 31) {
        const source = command.source_texture orelse return error.InvalidResource;
        if (!validTexture(source) or source.device != texture.device or
            source.format != texture.format or
            (source.format != .rgba8_unorm and source.format != .bgra8_unorm) or
            source.width != texture.width or source.height != texture.height or
            command.threads_per_grid.depth != 1 or
            command.threads_per_threadgroup.width == 0 or
            command.threads_per_threadgroup.height == 0 or
            command.threads_per_threadgroup.depth != 1) return error.InvalidArgument;
        const width = @min(command.threads_per_grid.width, texture.width);
        const height = @min(command.threads_per_grid.height, texture.height);
        for (0..height) |y| for (0..width) |x| {
            const source_offset = y * source.stride + x * source.format.bytesPerPixel();
            const destination_offset = y * texture.stride + x * texture.format.bytesPerPixel();
            @memcpy(texture.bytes[destination_offset..][0..4], source.bytes[source_offset..][0..4]);
        };
        return;
    }
    if (command.kernel != 3 and command.kernel != 4 and command.threads_per_grid.depth != 1) return error.InvalidArgument;
    const width = @min(command.threads_per_grid.width, texture.width);
    const height = @min(command.threads_per_grid.height, texture.height);
    switch (command.kernel) {
        1, 3, 4 => {
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| {
                const blue = if (command.kernel == 4 and command.array_slice != null)
                    (@as(f32, @floatFromInt(command.array_slice.?)) + 1.0) / 8.0
                else
                    0.25;
                target.storeColor(x, y, .{
                    (@as(f32, @floatFromInt(x)) + 1.0) / 8.0,
                    (@as(f32, @floatFromInt(y)) + 1.0) / 8.0,
                    blue,
                    1.0,
                });
            };
        },
        2 => {
            const source = command.buffer orelse return error.InvalidCommand;
            const row_bytes = std.math.mul(usize, texture.width, 4) catch return error.InvalidArgument;
            const required = if (width == 0 or height == 0) 0 else std.math.add(
                usize,
                std.math.mul(usize, @as(usize, height - 1), row_bytes) catch return error.InvalidArgument,
                std.math.mul(usize, @as(usize, width), 4) catch return error.InvalidArgument,
            ) catch return error.InvalidArgument;
            if (!rangeValid(source.bytes.len, command.buffer_offset, required)) return error.InvalidArgument;
            const byte_to_float: f32 = 1.0 / 255.0;
            var target = texture.asTarget();
            for (0..height) |y| {
                const source_row = command.buffer_offset + y * row_bytes;
                for (0..width) |x| {
                    const source_offset = source_row + x * 4;
                    target.storeColorWithNativeSrgb(x, y, .{
                        @as(f32, @floatFromInt(source.bytes[source_offset + 0])) * byte_to_float,
                        @as(f32, @floatFromInt(source.bytes[source_offset + 1])) * byte_to_float,
                        @as(f32, @floatFromInt(source.bytes[source_offset + 2])) * byte_to_float,
                        @as(f32, @floatFromInt(source.bytes[source_offset + 3])) * byte_to_float,
                    });
                }
            }
        },
        5 => {
            if (texture.format != .r32_float) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeColor(x, y, .{
                (@as(f32, @floatFromInt(x)) + 1.0) / 8.0, 0, 0, 1,
            });
        },
        6 => {
            if (texture.format != .rgba16_float) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeColor(x, y, .{
                (@as(f32, @floatFromInt(x)) + 1.0) / 8.0,
                (@as(f32, @floatFromInt(y)) + 1.0) / 8.0,
                0.25,
                1,
            });
        },
        10 => {
            if (texture.format != .rgba32_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1),
                @floatFromInt(y + 1),
                @floatFromInt(x + y + 1),
                4294967295.0,
            });
        },
        11 => {
            if (texture.format != .rgba32_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1),
                -@as(f32, @floatFromInt(y + 1)),
                @floatFromInt(x + y),
                2147483647.0,
            });
        },
        12 => {
            if (texture.format != .r32_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        13 => {
            if (texture.format != .r32_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        14 => {
            if (texture.format != .rg32_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), 0, 0,
            });
        },
        15 => {
            if (texture.format != .rg32_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), -@as(f32, @floatFromInt(y + 1)), 0, 0,
            });
        },
        16 => {
            if (texture.format != .r8_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        17 => {
            if (texture.format != .r8_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        18 => {
            if (texture.format != .rg8_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), 0, 0,
            });
        },
        19 => {
            if (texture.format != .rg8_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), -@as(f32, @floatFromInt(y + 1)), 0, 0,
            });
        },
        20 => {
            if (texture.format != .rgba8_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(x + y + 1), 255,
            });
        },
        21 => {
            if (texture.format != .rgba8_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), -@as(f32, @floatFromInt(y + 1)), @floatFromInt(x + y), 127,
            });
        },
        22 => {
            if (texture.format != .r16_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        23 => {
            if (texture.format != .r16_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), 0, 0, 0,
            });
        },
        24 => {
            if (texture.format != .rg16_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), 0, 0,
            });
        },
        25 => {
            if (texture.format != .rg16_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), -@as(f32, @floatFromInt(y + 1)), 0, 0,
            });
        },
        26 => {
            if (texture.format != .rgba16_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(x + y + 1), 65535,
            });
        },
        27 => {
            if (texture.format != .rgba16_sint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), -@as(f32, @floatFromInt(y + 1)), @floatFromInt(x + y), 32767,
            });
        },
        28 => {
            if (texture.format != .rgb10a2_uint) return error.UnsupportedFormat;
            var target = texture.asTarget();
            for (0..height) |y| for (0..width) |x| target.storeRawColor(x, y, .{
                @floatFromInt(x + 1), @floatFromInt(y + 1), @floatFromInt(x + y + 1), 3,
            });
        },
        7 => return executeTraceTriangles(command),
        45 => return executeTraceAabbs(command),
        else => return error.UnsupportedOperation,
    }
}

pub fn createDevice() Error!*Device {
    const result = allocator.create(Device) catch return error.OutOfMemory;
    result.* = .{};
    return result;
}

pub fn destroyDevice(device: *Device) void {
    if (device.magic != device_magic) return;
    device.magic = 0;
    allocator.destroy(device);
}

pub fn createQueue(device: *Device) Error!*CommandQueue {
    if (!validDevice(device)) return error.InvalidResource;
    const result = allocator.create(CommandQueue) catch return error.OutOfMemory;
    result.* = .{ .device = device };
    return result;
}

pub fn destroyQueue(queue: *CommandQueue) void {
    if (!validQueue(queue)) return;
    queue.magic = 0;
    allocator.destroy(queue);
}

pub fn createHeap(device: *Device, size: usize) Error!*Heap {
    if (!validDevice(device) or size == 0) return error.InvalidArgument;
    const backing = allocator.alignedAlloc(u8, std.mem.Alignment.of(f32), size) catch return error.OutOfMemory;
    errdefer allocator.free(backing);
    @memset(backing, 0);
    const result = allocator.create(Heap) catch return error.OutOfMemory;
    result.* = .{ .device = device, .size = size, .backing = backing };
    return result;
}

pub fn destroyHeap(heap: *Heap) void {
    if (!validHeap(heap)) return;
    heap.allocations.deinit(allocator);
    allocator.free(heap.backing);
    heap.magic = 0;
    allocator.destroy(heap);
}

fn reserveHeapAllocation(heap: *Heap, size: usize, alignment: usize) Error!usize {
    if (!validHeap(heap) or alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidArgument;
    var candidate: usize = 0;
    while (true) {
        const mask = alignment - 1;
        candidate = (std.math.add(usize, candidate, mask) catch return error.InvalidArgument) & ~mask;
        const end = std.math.add(usize, candidate, size) catch return error.InvalidArgument;
        var next_offset: ?usize = null;
        for (heap.allocations.items) |allocation| {
            if (allocation.offset < candidate) continue;
            if (next_offset == null or allocation.offset < next_offset.?) next_offset = allocation.offset;
        }
        if (next_offset == null or end <= next_offset.?) {
            return reserveHeapAllocationAtOffset(heap, size, alignment, candidate);
        }
        const occupied = next_offset.?;
        const occupied_end = for (heap.allocations.items) |allocation| {
            if (allocation.offset == occupied) {
                break std.math.add(usize, allocation.offset, allocation.size) catch return error.InvalidArgument;
            }
        } else return error.InvalidArgument;
        candidate = occupied_end;
    }
}

fn reserveHeapAllocationAtOffset(heap: *Heap, size: usize, alignment: usize, offset: usize) Error!usize {
    if (!validHeap(heap) or alignment == 0 or (alignment & (alignment - 1)) != 0 or
        (offset & (alignment - 1)) != 0) return error.InvalidArgument;
    const end = std.math.add(usize, offset, size) catch return error.InvalidArgument;
    if (end > heap.size) return error.OutOfMemory;
    for (heap.allocations.items) |allocation| {
        const allocation_end = std.math.add(usize, allocation.offset, allocation.size) catch return error.InvalidArgument;
        if (size != 0 and allocation.offset < end and offset < allocation_end) return error.InvalidArgument;
    }
    if (size == 0) return offset;
    if (heap.used > std.math.maxInt(usize) - size) return error.InvalidArgument;
    heap.used += size;
    heap.allocations.append(allocator, .{ .offset = offset, .size = size }) catch return error.OutOfMemory;
    var index = heap.allocations.items.len - 1;
    while (index > 0 and heap.allocations.items[index].offset < heap.allocations.items[index - 1].offset) : (index -= 1) {
        std.mem.swap(HeapAllocation, &heap.allocations.items[index], &heap.allocations.items[index - 1]);
    }
    return offset;
}

fn releaseHeapAllocation(heap: ?*Heap, offset: usize, allocation_size: usize) void {
    if (heap) |value| {
        if (!validHeap(value) or allocation_size == 0) return;
        for (value.allocations.items, 0..) |allocation, index| {
            if (allocation.offset == offset and allocation.size == allocation_size) {
                _ = value.allocations.orderedRemove(index);
                value.used -= allocation_size;
                return;
            }
        }
    }
}

pub fn heapMaxAvailableSize(heap: *const Heap, alignment: usize) usize {
    if (!validHeap(@constCast(heap)) or alignment == 0 or (alignment & (alignment - 1)) != 0) return 0;
    var cursor: usize = 0;
    var maximum: usize = 0;
    for (heap.allocations.items) |allocation| {
        const start = alignHeapOffset(cursor, alignment) catch return 0;
        if (start <= allocation.offset) maximum = @max(maximum, allocation.offset - start);
        cursor = std.math.add(usize, allocation.offset, allocation.size) catch return 0;
    }
    const start = alignHeapOffset(cursor, alignment) catch return 0;
    if (start <= heap.size) maximum = @max(maximum, heap.size - start);
    return maximum;
}

fn alignHeapOffset(offset: usize, alignment: usize) Error!usize {
    if (alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidArgument;
    const mask = alignment - 1;
    return (std.math.add(usize, offset, mask) catch return error.InvalidArgument) & ~mask;
}

pub fn createBufferInHeap(heap: *Heap, length: usize, initial_bytes: ?[*]const u8) Error!*Buffer {
    if (!validHeap(heap)) return error.InvalidResource;
    const allocation_offset = try reserveHeapAllocation(heap, length, @alignOf(u32));
    errdefer releaseHeapAllocation(heap, allocation_offset, length);
    const bytes = heap.backing[allocation_offset .. allocation_offset + length];
    @memset(bytes, 0);
    if (initial_bytes) |ptr| if (length != 0) @memcpy(bytes, ptr[0..length]);
    const result = allocator.create(Buffer) catch return error.OutOfMemory;
    result.* = .{
        .device = heap.device,
        .bytes = bytes,
        .owns_bytes = false,
        .heap = heap,
        .heap_allocation_offset = allocation_offset,
        .heap_allocation_size = length,
    };
    return result;
}

pub fn createBufferInHeapAtOffset(heap: *Heap, length: usize, initial_bytes: ?[*]const u8, offset: usize) Error!*Buffer {
    if (!validHeap(heap)) return error.InvalidResource;
    const allocation_offset = try reserveHeapAllocationAtOffset(heap, length, @alignOf(u32), offset);
    errdefer releaseHeapAllocation(heap, allocation_offset, length);
    const bytes = heap.backing[allocation_offset .. allocation_offset + length];
    @memset(bytes, 0);
    if (initial_bytes) |ptr| if (length != 0) @memcpy(bytes, ptr[0..length]);
    const result = allocator.create(Buffer) catch return error.OutOfMemory;
    result.* = .{
        .device = heap.device,
        .bytes = bytes,
        .owns_bytes = false,
        .heap = heap,
        .heap_allocation_offset = allocation_offset,
        .heap_allocation_size = length,
    };
    return result;
}

pub fn makeBufferAliasable(buffer: *Buffer) void {
    if (!validBuffer(buffer) or buffer.heap == null or buffer.heap_allocation_size == 0) return;
    releaseHeapAllocation(buffer.heap, buffer.heap_allocation_offset, buffer.heap_allocation_size);
    buffer.heap_allocation_size = 0;
}

pub fn createBuffer(device: *Device, length: usize, initial_bytes: ?[*]const u8) Error!*Buffer {
    if (!validDevice(device)) return error.InvalidResource;
    const bytes = allocator.alloc(u8, length) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    if (initial_bytes) |ptr| if (length != 0) @memcpy(bytes, ptr[0..length]);
    const result = allocator.create(Buffer) catch return error.OutOfMemory;
    result.* = .{ .device = device, .bytes = bytes };
    return result;
}

pub fn createBufferNoCopy(device: *Device, length: usize, bytes: ?[*]u8) Error!*Buffer {
    if (!validDevice(device) or (length != 0 and bytes == null)) return error.InvalidArgument;
    if (length == 0) return createBuffer(device, 0, null);
    const result = allocator.create(Buffer) catch return error.OutOfMemory;
    result.* = .{ .device = device, .bytes = bytes.?[0..length], .owns_bytes = false };
    return result;
}

/// Create a placement-sparse CPU buffer. The dense byte slice is an internal
/// staging view only; public contents are unavailable until a mapped range is
/// copied through an encoder. Mapping state lives in ZPU-owned pages.
pub fn createSparseBuffer(device: *Device, length: usize, page_bytes: usize) Error!*Buffer {
    if (!validDevice(device) or length == 0 or !validSparsePageBytes(page_bytes)) return error.InvalidArgument;
    const result = try createBuffer(device, length, null);
    errdefer destroyBuffer(result);
    result.sparse_page_bytes = page_bytes;
    return result;
}

pub fn destroyBuffer(buffer: *Buffer) void {
    if (!validBuffer(buffer)) return;
    buffer.deinit();
    allocator.destroy(buffer);
}

pub fn createTexture(device: *Device, width: u32, height: u32, format_raw: u16) Error!*Texture {
    if (!validDevice(device) or width == 0 or height == 0) return error.InvalidArgument;
    const format = textureFormatFromRaw(format_raw) orelse return error.UnsupportedFormat;
    const stride = std.math.mul(usize, width, format.bytesPerPixel()) catch return error.InvalidArgument;
    const length = std.math.mul(usize, stride, height) catch return error.InvalidArgument;
    const bytes = allocator.alignedAlloc(u8, std.mem.Alignment.of(f32), length) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{ .device = device, .width = width, .height = height, .stride = stride, .format = format, .bytes = bytes, .owns_bytes = true };
    return result;
}

/// Create a bounded 2D level-0 placement-sparse texture. Tile geometry is
/// derived from the Apple page-size contract for the supported CPU formats;
/// mipmapped, array, and 3D sparse layouts remain outside this portable ABI.
pub fn createSparseTexture(device: *Device, width: u32, height: u32, format_raw: u16, page_bytes: usize) Error!*Texture {
    const result = try createTexture(device, width, height, format_raw);
    errdefer destroyTexture(result);
    const tile = sparseTextureTileDimensions(result.format, page_bytes) orelse return error.UnsupportedOperation;
    result.sparse_page_bytes = page_bytes;
    result.sparse_tile_width = tile.width;
    result.sparse_tile_height = tile.height;
    return result;
}

pub fn createTextureInHeap(heap: *Heap, width: u32, height: u32, format_raw: u16) Error!*Texture {
    if (!validHeap(heap)) return error.InvalidResource;
    if (width == 0 or height == 0) return error.InvalidArgument;
    const format = textureFormatFromRaw(format_raw) orelse return error.UnsupportedFormat;
    const stride = std.math.mul(usize, width, format.bytesPerPixel()) catch return error.InvalidArgument;
    const length = std.math.mul(usize, stride, height) catch return error.InvalidArgument;
    const allocation_offset = try reserveHeapAllocation(heap, length, @alignOf(f32));
    errdefer releaseHeapAllocation(heap, allocation_offset, length);
    const bytes = heap.backing[allocation_offset .. allocation_offset + length];
    @memset(bytes, 0);
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{
        .device = heap.device,
        .width = width,
        .height = height,
        .stride = stride,
        .format = format,
        .bytes = bytes,
        .owns_bytes = false,
        .heap = heap,
        .heap_allocation_offset = allocation_offset,
        .heap_allocation_size = length,
    };
    return result;
}

pub fn createTextureInHeapAtOffset(heap: *Heap, width: u32, height: u32, format_raw: u16, offset: usize) Error!*Texture {
    if (!validHeap(heap)) return error.InvalidResource;
    if (width == 0 or height == 0) return error.InvalidArgument;
    const format = textureFormatFromRaw(format_raw) orelse return error.UnsupportedFormat;
    const stride = std.math.mul(usize, width, format.bytesPerPixel()) catch return error.InvalidArgument;
    const length = std.math.mul(usize, stride, height) catch return error.InvalidArgument;
    const allocation_offset = try reserveHeapAllocationAtOffset(heap, length, @alignOf(f32), offset);
    errdefer releaseHeapAllocation(heap, allocation_offset, length);
    const bytes = heap.backing[allocation_offset .. allocation_offset + length];
    @memset(bytes, 0);
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{
        .device = heap.device,
        .width = width,
        .height = height,
        .stride = stride,
        .format = format,
        .bytes = bytes,
        .owns_bytes = false,
        .heap = heap,
        .heap_allocation_offset = allocation_offset,
        .heap_allocation_size = length,
    };
    return result;
}

pub fn makeTextureAliasable(texture: *Texture) void {
    if (!validTexture(texture) or texture.heap == null or texture.heap_allocation_size == 0) return;
    releaseHeapAllocation(texture.heap, texture.heap_allocation_offset, texture.heap_allocation_size);
    texture.heap_allocation_size = 0;
}

pub fn createTextureFromBuffer(buffer: *Buffer, width: u32, height: u32, format_raw: u16, offset: usize, bytes_per_row: usize) Error!*Texture {
    if (!validBuffer(buffer)) return error.InvalidResource;
    if (width == 0 or height == 0) return error.InvalidArgument;
    if (buffer.sparse_page_bytes != 0) return error.UnsupportedOperation;
    const format: TextureFormat = switch (format_raw) {
        @intFromEnum(abi.PixelFormat.a8_unorm) => .a8_unorm,
        @intFromEnum(abi.PixelFormat.r8_unorm) => .r8_unorm,
        @intFromEnum(abi.PixelFormat.r8_unorm_srgb) => .r8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.r8_snorm) => .r8_snorm,
        @intFromEnum(abi.PixelFormat.r8_uint) => .r8_uint,
        @intFromEnum(abi.PixelFormat.r8_sint) => .r8_sint,
        @intFromEnum(abi.PixelFormat.r16_unorm) => .r16_unorm,
        @intFromEnum(abi.PixelFormat.r16_snorm) => .r16_snorm,
        @intFromEnum(abi.PixelFormat.r16_uint) => .r16_uint,
        @intFromEnum(abi.PixelFormat.r16_sint) => .r16_sint,
        @intFromEnum(abi.PixelFormat.r16_float) => .r16_float,
        @intFromEnum(abi.PixelFormat.rg8_unorm) => .rg8_unorm,
        @intFromEnum(abi.PixelFormat.rg8_unorm_srgb) => .rg8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.rg8_snorm) => .rg8_snorm,
        @intFromEnum(abi.PixelFormat.rg8_uint) => .rg8_uint,
        @intFromEnum(abi.PixelFormat.rg8_sint) => .rg8_sint,
        @intFromEnum(abi.PixelFormat.rg16_unorm) => .rg16_unorm,
        @intFromEnum(abi.PixelFormat.rg16_snorm) => .rg16_snorm,
        @intFromEnum(abi.PixelFormat.rg16_uint) => .rg16_uint,
        @intFromEnum(abi.PixelFormat.rg16_sint) => .rg16_sint,
        @intFromEnum(abi.PixelFormat.rg16_float) => .rg16_float,
        @intFromEnum(abi.PixelFormat.r32_uint) => .r32_uint,
        @intFromEnum(abi.PixelFormat.r32_sint) => .r32_sint,
        @intFromEnum(abi.PixelFormat.rgba8_unorm) => .rgba8_unorm,
        @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb) => .rgba8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.rgba8_snorm) => .rgba8_snorm,
        @intFromEnum(abi.PixelFormat.rgba8_uint) => .rgba8_uint,
        @intFromEnum(abi.PixelFormat.rgba8_sint) => .rgba8_sint,
        @intFromEnum(abi.PixelFormat.bgra8_unorm) => .bgra8_unorm,
        @intFromEnum(abi.PixelFormat.bgra8_unorm_srgb) => .bgra8_unorm_srgb,
        @intFromEnum(abi.PixelFormat.b5g6r5_unorm) => .b5g6r5_unorm,
        @intFromEnum(abi.PixelFormat.a1bgr5_unorm) => .a1bgr5_unorm,
        @intFromEnum(abi.PixelFormat.abgr4_unorm) => .abgr4_unorm,
        @intFromEnum(abi.PixelFormat.bgr5a1_unorm) => .bgr5a1_unorm,
        @intFromEnum(abi.PixelFormat.rgb10a2_unorm) => .rgb10a2_unorm,
        @intFromEnum(abi.PixelFormat.rgb10a2_uint) => .rgb10a2_uint,
        @intFromEnum(abi.PixelFormat.rg11b10_float) => .rg11b10_float,
        @intFromEnum(abi.PixelFormat.rgb9e5_float) => .rgb9e5_float,
        @intFromEnum(abi.PixelFormat.bgr10a2_unorm) => .bgr10a2_unorm,
        @intFromEnum(abi.PixelFormat.r32_float) => .r32_float,
        @intFromEnum(abi.PixelFormat.rgba16_unorm) => .rgba16_unorm,
        @intFromEnum(abi.PixelFormat.rgba16_snorm) => .rgba16_snorm,
        @intFromEnum(abi.PixelFormat.rgba16_uint) => .rgba16_uint,
        @intFromEnum(abi.PixelFormat.rgba16_sint) => .rgba16_sint,
        @intFromEnum(abi.PixelFormat.rgba16_float) => .rgba16_float,
        @intFromEnum(abi.PixelFormat.rg32_uint) => .rg32_uint,
        @intFromEnum(abi.PixelFormat.rg32_sint) => .rg32_sint,
        @intFromEnum(abi.PixelFormat.rg32_float) => .rg32_float,
        @intFromEnum(abi.PixelFormat.rgba32_uint) => .rgba32_uint,
        @intFromEnum(abi.PixelFormat.rgba32_sint) => .rgba32_sint,
        @intFromEnum(abi.PixelFormat.rgba32_float) => .rgba32_float,
        @intFromEnum(abi.PixelFormat.depth16_unorm) => .depth16_unorm,
        @intFromEnum(abi.PixelFormat.depth32_float) => .depth32_float,
        @intFromEnum(abi.PixelFormat.stencil8) => .stencil8,
        @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8) => .depth24_unorm_stencil8,
        @intFromEnum(abi.PixelFormat.depth32_float_stencil8) => .depth32_float_stencil8,
        @intFromEnum(abi.PixelFormat.x32_stencil8) => .x32_stencil8,
        @intFromEnum(abi.PixelFormat.x24_stencil8) => .x24_stencil8,
        else => return error.UnsupportedFormat,
    };
    if (offset % @alignOf(u32) != 0) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, width, format.bytesPerPixel()) catch return error.InvalidArgument;
    if (bytes_per_row < row_bytes or bytes_per_row % @alignOf(u32) != 0) return error.InvalidArgument;
    const required = if (height == 0) 0 else std.math.add(usize, std.math.mul(usize, height - 1, bytes_per_row) catch return error.InvalidArgument, row_bytes) catch return error.InvalidArgument;
    if (!rangeValid(buffer.bytes.len, offset, required)) return error.InvalidArgument;
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{
        .device = buffer.device,
        .width = width,
        .height = height,
        .stride = bytes_per_row,
        .format = format,
        .bytes = buffer.bytes[offset .. offset + required],
        .owns_bytes = false,
    };
    return result;
}

pub fn destroyTexture(texture: *Texture) void {
    if (!validTexture(texture)) return;
    texture.deinit();
    allocator.destroy(texture);
}

pub fn createTextureView(texture: *const Texture, format_raw: u16) Error!*Texture {
    if (texture.magic != texture_magic or !validDevice(texture.device)) return error.InvalidResource;
    if (texture.sparse_page_bytes != 0) return error.UnsupportedOperation;
    const format = textureFormatFromRaw(format_raw) orelse return error.UnsupportedFormat;
    if (!textureFormatsViewCompatible(texture.format, format)) return error.UnsupportedFormat;
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{
        .device = texture.device,
        .width = texture.width,
        .height = texture.height,
        .stride = texture.stride,
        .format = format,
        .bytes = texture.bytes,
        .owns_bytes = false,
    };
    return result;
}

pub fn createFence(device: *Device) Error!*Fence {
    if (!validDevice(device)) return error.InvalidResource;
    const result = allocator.create(Fence) catch return error.OutOfMemory;
    result.* = .{ .device = device };
    return result;
}

pub fn destroyFence(fence: *Fence) void {
    if (!validFence(fence)) return;
    fence.magic = 0;
    allocator.destroy(fence);
}

pub fn createSharedEvent(device: *Device) Error!*SharedEvent {
    if (!validDevice(device)) return error.InvalidResource;
    const result = allocator.create(SharedEvent) catch return error.OutOfMemory;
    result.* = .{ .device = device };
    return result;
}

pub fn destroySharedEvent(event: *SharedEvent) void {
    if (!validSharedEvent(event)) return;
    _ = std.c.pthread_mutex_lock(&event.mutex);
    event.magic = 0;
    _ = std.c.pthread_cond_broadcast(&event.condition);
    _ = std.c.pthread_mutex_unlock(&event.mutex);
    _ = std.c.pthread_cond_destroy(&event.condition);
    _ = std.c.pthread_mutex_destroy(&event.mutex);
    allocator.destroy(event);
}

pub fn setSharedEventValue(event: *SharedEvent, value: u64) Error!void {
    if (!validSharedEvent(event)) return error.InvalidResource;
    _ = std.c.pthread_mutex_lock(&event.mutex);
    defer _ = std.c.pthread_mutex_unlock(&event.mutex);
    if (value < event.signaled_value) return error.InvalidArgument;
    event.signaled_value = value;
    _ = std.c.pthread_cond_broadcast(&event.condition);
}

pub fn waitSharedEventValue(event: *const SharedEvent, value: u64, timeout_ms: u64) Error!void {
    if (event.magic != shared_event_magic or !validDevice(event.device)) return error.InvalidResource;
    const mutable_event: *SharedEvent = @constCast(event);
    _ = std.c.pthread_mutex_lock(&mutable_event.mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutable_event.mutex);
    if (mutable_event.signaled_value >= value) return;
    if (timeout_ms == 0) return error.InvalidCommand;
    if (timeout_ms == std.math.maxInt(u64)) {
        while (mutable_event.signaled_value < value) {
            _ = std.c.pthread_cond_wait(&mutable_event.condition, &mutable_event.mutex);
        }
        return;
    }
    var deadline: std.c.timespec = undefined;
    if (std.c.clock_gettime(.REALTIME, &deadline) != 0) return error.InvalidCommand;
    const timeout_seconds: u64 = timeout_ms / 1000;
    const timeout_nanos: u64 = (timeout_ms % 1000) * 1_000_000;
    const seconds = @as(u64, @intCast(deadline.sec)) + timeout_seconds;
    if (seconds > @as(u64, @intCast(std.math.maxInt(@TypeOf(deadline.sec))))) {
        return error.InvalidCommand;
    }
    deadline.sec = @intCast(seconds);
    const nanoseconds = @as(u64, @intCast(deadline.nsec)) + timeout_nanos;
    if (nanoseconds >= 1_000_000_000) {
        deadline.sec += 1;
        deadline.nsec = @intCast(nanoseconds - 1_000_000_000);
    } else {
        deadline.nsec = @intCast(nanoseconds);
    }
    while (mutable_event.signaled_value < value) {
        if (std.c.pthread_cond_timedwait(&mutable_event.condition, &mutable_event.mutex, &deadline) != .SUCCESS) {
            return error.InvalidCommand;
        }
    }
}

pub fn createCommandBuffer(queue: *CommandQueue) Error!*CommandBuffer {
    if (!validQueue(queue)) return error.InvalidResource;
    const result = allocator.create(CommandBuffer) catch return error.OutOfMemory;
    result.* = .{ .queue = queue };
    return result;
}

pub fn destroyCommandBuffer(command_buffer: *CommandBuffer) void {
    if (!validCommandBuffer(command_buffer)) return;
    command_buffer.deinit();
    allocator.destroy(command_buffer);
}

pub fn encodeSignalEvent(command_buffer: *CommandBuffer, event: *SharedEvent, value: u64) Error!void {
    if (!validCommandBuffer(command_buffer) or command_buffer.active_encoder != .none or
        !validSharedEvent(event) or event.device != command_buffer.queue.device) return error.InvalidArgument;
    _ = try command_buffer.append(.{ .signal_event = .{ .event = event, .value = value } });
}

pub fn encodeWaitForEvent(command_buffer: *CommandBuffer, event: *SharedEvent, value: u64) Error!void {
    if (!validCommandBuffer(command_buffer) or command_buffer.active_encoder != .none or
        !validSharedEvent(event) or event.device != command_buffer.queue.device) return error.InvalidArgument;
    _ = try command_buffer.append(.{ .wait_event = .{ .event = event, .value = value } });
}

pub fn beginRender(command_buffer: *CommandBuffer, texture: *Texture, pass: abi.RenderPassDescriptor) Error!*RenderEncoder {
    if (!validCommandBuffer(command_buffer) or !validTexture(texture) or texture.device != command_buffer.queue.device or !texture.format.isColor()) return error.InvalidResource;
    if (!validPass(pass)) return error.InvalidArgument;
    try command_buffer.begin(.render);
    errdefer command_buffer.active_encoder = .none;
    const begin_index = try command_buffer.append(.{ .begin_render = .{ .target = texture, .pass = pass } });
    switch (command_buffer.commands.items[begin_index]) {
        .begin_render => |*begin_render| {
            begin_render.color_attachments[0] = .{ .texture = texture, .pass = pass.color };
            begin_render.array_targets[0] = texture;
        },
        else => return error.InvalidCommand,
    }
    const result = allocator.create(RenderEncoder) catch return error.OutOfMemory;
    const initial_viewport = raster3d.PreciseViewport{
        .origin_x = 0,
        .origin_y = 0,
        .width = @floatFromInt(texture.width),
        .height = @floatFromInt(texture.height),
        .znear = 0,
        .zfar = 1,
    };
    const initial_scissor = abi.ScissorRect{ .x = 0, .y = 0, .width = texture.width, .height = texture.height };
    result.* = .{
        .command_buffer = command_buffer,
        .begin_index = begin_index,
        .viewport = initial_viewport,
        .viewport_array = .{initial_viewport} ** max_viewport_count,
        .scissor = initial_scissor,
        .scissor_array = .{initial_scissor} ** max_viewport_count,
    };
    return result;
}

pub fn destroyRenderEncoder(encoder: *RenderEncoder) void {
    if (encoder.magic != render_encoder_magic) return;
    if (encoder.command_buffer.active_encoder == .render) encoder.command_buffer.active_encoder = .none;
    encoder.deinit();
    allocator.destroy(encoder);
}

pub fn beginBlit(command_buffer: *CommandBuffer) Error!*BlitEncoder {
    if (!validCommandBuffer(command_buffer)) return error.InvalidResource;
    try command_buffer.begin(.blit);
    const result = allocator.create(BlitEncoder) catch {
        command_buffer.active_encoder = .none;
        return error.OutOfMemory;
    };
    result.* = .{ .command_buffer = command_buffer };
    return result;
}

pub fn destroyBlitEncoder(encoder: *BlitEncoder) void {
    if (encoder.magic != blit_encoder_magic) return;
    if (encoder.command_buffer.active_encoder == .blit) encoder.command_buffer.active_encoder = .none;
    encoder.deinit();
    allocator.destroy(encoder);
}

pub fn beginResourceState(command_buffer: *CommandBuffer) Error!*ResourceStateEncoder {
    if (!validCommandBuffer(command_buffer)) return error.InvalidResource;
    try command_buffer.begin(.resource_state);
    const result = allocator.create(ResourceStateEncoder) catch {
        command_buffer.active_encoder = .none;
        return error.OutOfMemory;
    };
    result.* = .{ .command_buffer = command_buffer };
    return result;
}

pub fn destroyResourceStateEncoder(encoder: *ResourceStateEncoder) void {
    if (encoder.magic != resource_state_encoder_magic) return;
    if (encoder.command_buffer.active_encoder == .resource_state) encoder.command_buffer.active_encoder = .none;
    encoder.deinit();
    allocator.destroy(encoder);
}

pub fn beginCompute(command_buffer: *CommandBuffer) Error!*ComputeEncoder {
    if (!validCommandBuffer(command_buffer)) return error.InvalidResource;
    try command_buffer.begin(.compute);
    const result = allocator.create(ComputeEncoder) catch {
        command_buffer.active_encoder = .none;
        return error.OutOfMemory;
    };
    result.* = .{ .command_buffer = command_buffer };
    return result;
}

pub fn destroyComputeEncoder(encoder: *ComputeEncoder) void {
    if (encoder.magic != compute_encoder_magic) return;
    if (encoder.command_buffer.active_encoder == .compute) encoder.command_buffer.active_encoder = .none;
    encoder.deinit();
    allocator.destroy(encoder);
}

pub fn bufferWrite(buffer: *Buffer, offset: usize, bytes: ?[*]const u8, length: usize) Error!void {
    if (!validBuffer(buffer) or (length != 0 and bytes == null) or !rangeValid(buffer.bytes.len, offset, length)) return error.InvalidArgument;
    sparseSyncBuffer(buffer);
    if (length != 0) @memcpy(buffer.bytes[offset .. offset + length], bytes.?[0..length]);
    sparseFlushBuffer(buffer);
}

pub fn textureGetBytes(texture: *Texture, destination: ?[*]u8, destination_length: usize, bytes_per_row: usize, region: abi.Region) Error!void {
    if (!validTexture(texture) or (region.origin.z != 0) or (region.size.depth != 1)) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, region.size.width, texture.format.bytesPerPixel()) catch return error.InvalidArgument;
    const stride = if (bytes_per_row == 0) row_bytes else bytes_per_row;
    try validateRegion(texture.width, texture.height, region, stride, destination_length, texture.format.bytesPerPixel());
    if (row_bytes != 0 and destination == null) return error.InvalidArgument;
    if (row_bytes == 0) return;
    sparseSyncTexture(texture);
    for (0..region.size.height) |row| {
        const source_offset = (@as(usize, region.origin.y) + row) * texture.stride + @as(usize, region.origin.x) * texture.format.bytesPerPixel();
        const destination_offset = row * stride;
        @memcpy(destination.?[destination_offset .. destination_offset + row_bytes], texture.bytes[source_offset .. source_offset + row_bytes]);
    }
}

pub fn textureReplaceRegion(texture: *Texture, region: abi.Region, source: ?[*]const u8, source_length: usize, bytes_per_row: usize) Error!void {
    if (!validTexture(texture) or (region.origin.z != 0) or (region.size.depth != 1)) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, region.size.width, texture.format.bytesPerPixel()) catch return error.InvalidArgument;
    const stride = if (bytes_per_row == 0) row_bytes else bytes_per_row;
    try validateRegion(texture.width, texture.height, region, stride, source_length, texture.format.bytesPerPixel());
    if (row_bytes != 0 and source == null) return error.InvalidArgument;
    if (row_bytes == 0) return;
    sparseSyncTexture(texture);
    for (0..region.size.height) |row| {
        const source_offset = row * stride;
        const destination_offset = (@as(usize, region.origin.y) + row) * texture.stride + @as(usize, region.origin.x) * texture.format.bytesPerPixel();
        @memcpy(texture.bytes[destination_offset .. destination_offset + row_bytes], source.?[source_offset .. source_offset + row_bytes]);
    }
    sparseFlushTexture(texture);
}

fn vertexCount(raw_len: usize, stride: usize) ?usize {
    if (stride < @sizeOf(abi.Vertex) or raw_len < @sizeOf(abi.Vertex)) return null;
    return 1 + (raw_len - @sizeOf(abi.Vertex)) / stride;
}

fn appendVertexBytes(list: *std.ArrayList(abi.Vertex), raw: []const u8, stride: usize) Error!void {
    const count = vertexCount(raw.len, stride) orelse {
        if (raw.len == 0) return;
        return error.InvalidArgument;
    };
    for (0..count) |index| {
        var value: abi.Vertex = undefined;
        const destination = std.mem.asBytes(&value);
        @memcpy(destination, raw[index * stride ..][0..@sizeOf(abi.Vertex)]);
        list.append(allocator, value) catch return error.OutOfMemory;
    }
}

fn bufferVertices(buffer: *Buffer, offset: usize, stride: usize, owned: *?[]abi.Vertex) Error![]const abi.Vertex {
    if (!validBuffer(buffer) or offset > buffer.bytes.len) return error.InvalidResource;
    const raw = buffer.bytes[offset..];
    const count = vertexCount(raw.len, stride) orelse {
        if (raw.len == 0) return &.{};
        return error.InvalidArgument;
    };
    if (stride == @sizeOf(abi.Vertex) and @intFromPtr(raw.ptr) % @alignOf(abi.Vertex) == 0) {
        const pointer: [*]const abi.Vertex = @ptrCast(@alignCast(raw.ptr));
        return pointer[0..count];
    }
    const result = allocator.alloc(abi.Vertex, count) catch return error.OutOfMemory;
    for (0..count) |index| {
        @memcpy(std.mem.asBytes(&result[index]), raw[index * stride ..][0..@sizeOf(abi.Vertex)]);
    }
    owned.* = result;
    return result;
}

fn addRasterStats(a: raster3d.Stats, b: raster3d.Stats) raster3d.Stats {
    return .{
        .primitives_submitted = a.primitives_submitted + b.primitives_submitted,
        .primitives_rasterized = a.primitives_rasterized + b.primitives_rasterized,
        .fragments_tested = a.fragments_tested + b.fragments_tested,
        .fragments_covered = a.fragments_covered + b.fragments_covered,
        .depth_tests_passed = a.depth_tests_passed + b.depth_tests_passed,
        .color_writes = a.color_writes + b.color_writes,
    };
}

fn copyBufferToTexture(command: BufferTextureCommand) Error!void {
    const row_bytes = std.math.mul(usize, command.region.size.width, command.texture.format.bytesPerPixel()) catch return error.InvalidArgument;
    const stride = if (command.bytes_per_row == 0) row_bytes else command.bytes_per_row;
    try validateRegion(command.texture.width, command.texture.height, command.region, stride, command.buffer.bytes.len -| command.buffer_offset, command.texture.format.bytesPerPixel());
    if (command.buffer_offset > command.buffer.bytes.len) return error.InvalidArgument;
    for (0..command.region.size.height) |row| {
        const source_offset = command.buffer_offset + row * stride;
        const destination_offset = (@as(usize, command.region.origin.y) + row) * command.texture.stride + @as(usize, command.region.origin.x) * command.texture.format.bytesPerPixel();
        @memcpy(command.texture.bytes[destination_offset .. destination_offset + row_bytes], command.buffer.bytes[source_offset .. source_offset + row_bytes]);
    }
}

fn copyTextureToBuffer(command: TextureBufferCommand) Error!void {
    const row_bytes = std.math.mul(usize, command.region.size.width, command.texture.format.bytesPerPixel()) catch return error.InvalidArgument;
    const stride = if (command.bytes_per_row == 0) row_bytes else command.bytes_per_row;
    try validateRegion(command.texture.width, command.texture.height, command.region, stride, command.buffer.bytes.len -| command.buffer_offset, command.texture.format.bytesPerPixel());
    if (command.buffer_offset > command.buffer.bytes.len) return error.InvalidArgument;
    for (0..command.region.size.height) |row| {
        const source_offset = (@as(usize, command.region.origin.y) + row) * command.texture.stride + @as(usize, command.region.origin.x) * command.texture.format.bytesPerPixel();
        const destination_offset = command.buffer_offset + row * stride;
        @memcpy(command.buffer.bytes[destination_offset .. destination_offset + row_bytes], command.texture.bytes[source_offset .. source_offset + row_bytes]);
    }
}

fn copyTextureToTexture(command: TextureTextureCommand) Error!void {
    if (command.source_region.size.width != command.destination_region.size.width or
        command.source_region.size.height != command.destination_region.size.height or
        command.source_region.size.depth != 1 or command.destination_region.size.depth != 1) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, command.source_region.size.width, command.source.format.bytesPerPixel()) catch return error.InvalidArgument;
    try validateRegion(command.source.width, command.source.height, command.source_region, row_bytes, std.math.maxInt(usize), command.source.format.bytesPerPixel());
    try validateRegion(command.destination.width, command.destination.height, command.destination_region, row_bytes, std.math.maxInt(usize), command.destination.format.bytesPerPixel());
    for (0..command.source_region.size.height) |row| {
        const source_offset = (@as(usize, command.source_region.origin.y) + row) * command.source.stride + @as(usize, command.source_region.origin.x) * command.source.format.bytesPerPixel();
        const destination_offset = (@as(usize, command.destination_region.origin.y) + row) * command.destination.stride + @as(usize, command.destination_region.origin.x) * command.destination.format.bytesPerPixel();
        @memcpy(command.destination.bytes[destination_offset .. destination_offset + row_bytes], command.source.bytes[source_offset .. source_offset + row_bytes]);
    }
}

const MipmapAxis = struct {
    low: usize,
    high: usize,
    low_weight: u64,
    high_weight: u64,
    denominator: u64,
};

fn mipmapAxis(source_size: u32, destination_size: u32, destination_index: usize) MipmapAxis {
    const source_size_u64 = @as(u64, source_size);
    const destination_size_u64 = @as(u64, destination_size);
    const denominator = destination_size_u64 * 2;
    const numerator = (@as(u64, destination_index) * 2 + 1) * source_size_u64 - destination_size_u64;
    const low_u64 = numerator / denominator;
    const remainder = numerator % denominator;
    const high_u64 = if (remainder != 0 and low_u64 + 1 < source_size_u64) low_u64 + 1 else low_u64;
    const low: usize = @intCast(low_u64);
    const high: usize = @intCast(high_u64);
    return .{
        .low = low,
        .high = high,
        .low_weight = if (low == high) denominator else denominator - remainder,
        .high_weight = if (low == high) 0 else remainder,
        .denominator = denominator,
    };
}

const MipmapRange = struct {
    low: usize,
    high: usize,
};

fn mipmapRange(source_size: u32, destination_size: u32, destination_index: usize) MipmapRange {
    const source_size_u64 = @as(u64, source_size);
    const destination_size_u64 = @as(u64, destination_size);
    const index_u64 = @as(u64, destination_index);
    const low_u64 = index_u64 * source_size_u64 / destination_size_u64;
    const high_unclamped = (index_u64 + 1) * source_size_u64 + destination_size_u64 - 1;
    const high_u64 = @min(high_unclamped / destination_size_u64, source_size_u64);
    return .{
        .low = @intCast(low_u64),
        .high = @intCast(@max(high_u64, low_u64 + 1)),
    };
}

fn readMipmapF32(bytes: []const u8, offset: usize) f64 {
    return @floatCast(@as(f32, @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little))));
}

fn writeMipmapF32(bytes: []u8, offset: usize, value: f64) void {
    const narrowed: f32 = @floatCast(value);
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(narrowed), .little);
}

fn readMipmapF16(bytes: []const u8, offset: usize) f64 {
    return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, bytes[offset..][0..2], .little))));
}

fn writeMipmapF16(bytes: []u8, offset: usize, value: f64) void {
    const narrowed: f16 = @floatCast(value);
    std.mem.writeInt(u16, bytes[offset..][0..2], @bitCast(narrowed), .little);
}

fn readFloatMipmapColor(texture: *const Texture, x: usize, y: usize) [4]f64 {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .r16_float => .{ readMipmapF16(texture.bytes, offset), 0, 0, 1 },
        .rg16_float => .{ readMipmapF16(texture.bytes, offset), readMipmapF16(texture.bytes, offset + 2), 0, 1 },
        .r32_float => .{ readMipmapF32(texture.bytes, offset), 0, 0, 1 },
        .rgba16_float => .{
            readMipmapF16(texture.bytes, offset),
            readMipmapF16(texture.bytes, offset + 2),
            readMipmapF16(texture.bytes, offset + 4),
            readMipmapF16(texture.bytes, offset + 6),
        },
        .rgba32_float => .{
            readMipmapF32(texture.bytes, offset),
            readMipmapF32(texture.bytes, offset + 4),
            readMipmapF32(texture.bytes, offset + 8),
            readMipmapF32(texture.bytes, offset + 12),
        },
        else => unreachable,
    };
}

fn writeFloatMipmapColor(texture: *Texture, x: usize, y: usize, color: [4]f64) void {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    switch (texture.format) {
        .r16_float => writeMipmapF16(texture.bytes, offset, color[0]),
        .rg16_float => {
            writeMipmapF16(texture.bytes, offset, color[0]);
            writeMipmapF16(texture.bytes, offset + 2, color[1]);
        },
        .r32_float => writeMipmapF32(texture.bytes, offset, color[0]),
        .rgba16_float => {
            writeMipmapF16(texture.bytes, offset, color[0]);
            writeMipmapF16(texture.bytes, offset + 2, color[1]);
            writeMipmapF16(texture.bytes, offset + 4, color[2]);
            writeMipmapF16(texture.bytes, offset + 6, color[3]);
        },
        .rgba32_float => {
            writeMipmapF32(texture.bytes, offset, color[0]);
            writeMipmapF32(texture.bytes, offset + 4, color[1]);
            writeMipmapF32(texture.bytes, offset + 8, color[2]);
            writeMipmapF32(texture.bytes, offset + 12, color[3]);
        },
        else => unreachable,
    }
}

fn packedMipmapValue(value: f64, maximum: u32) u32 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * @as(f64, @floatFromInt(maximum)) + 0.5);
}

// Apple's blit mipmap path truncates packed-float mantissas when it stores the
// filtered value.  Render-target conversion uses the separate raster3d
// encoder, which keeps its native rounding behavior.
fn truncatePackedFloat(value: f64) u32 {
    if (!(value > 0)) return 0;
    return @intFromFloat(@floor(value));
}

fn readUnsignedPackedFloat(bits: u32, mantissa_bits: u32) f64 {
    const mantissa_mask = (@as(u32, 1) << @intCast(mantissa_bits)) - 1;
    const mantissa = bits & mantissa_mask;
    const exponent = (bits >> @intCast(mantissa_bits)) & 0x1f;
    if (exponent == 0) return @as(f64, @floatFromInt(mantissa)) *
        std.math.pow(f64, 2.0, -14.0 - @as(f64, @floatFromInt(mantissa_bits)));
    if (exponent == 0x1f) return if (mantissa == 0) std.math.inf(f64) else std.math.nan(f64);
    return (1.0 + @as(f64, @floatFromInt(mantissa)) /
        std.math.pow(f64, 2.0, @as(f64, @floatFromInt(mantissa_bits)))) *
        std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 15.0);
}

fn writeUnsignedPackedFloat(value: f64, mantissa_bits: u32) u32 {
    if (!(value > 0)) return 0;
    if (!std.math.isFinite(value)) return @as(u32, 0x1f) << @intCast(mantissa_bits);
    const mantissa_scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(mantissa_bits)));
    const minimum_normal = std.math.pow(f64, 2.0, -14.0);
    if (value < minimum_normal) return truncatePackedFloat(value *
        std.math.pow(f64, 2.0, 14.0 + @as(f64, @floatFromInt(mantissa_bits))));
    const exponent: i32 = @intFromFloat(@floor(std.math.log2(value)));
    const mantissa = truncatePackedFloat((value / std.math.pow(f64, 2.0, @floatFromInt(exponent)) - 1.0) * mantissa_scale);
    if (exponent > 15) return @as(u32, 0x1f) << @intCast(mantissa_bits);
    return (@as(u32, @intCast(exponent + 15)) << @intCast(mantissa_bits)) | mantissa;
}

fn readRgb9e5Mipmap(bits: u32) [4]f64 {
    const exponent = (bits >> 27) & 0x1f;
    const scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
    return .{
        @as(f64, @floatFromInt(bits & 0x1ff)) * scale,
        @as(f64, @floatFromInt((bits >> 9) & 0x1ff)) * scale,
        @as(f64, @floatFromInt((bits >> 18) & 0x1ff)) * scale,
        1,
    };
}

fn writeRgb9e5Mipmap(color: [4]f64) u32 {
    var maximum: f64 = 0;
    for (color[0..3]) |component| maximum = @max(maximum, std.math.clamp(component, 0, std.math.inf(f64)));
    if (!(maximum > 0)) return 0;
    var exponent: i32 = @as(i32, @intFromFloat(@floor(std.math.log2(maximum)))) + 16;
    exponent = std.math.clamp(exponent, 0, 31);
    var scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
    var red = truncatePackedFloat(std.math.clamp(color[0], 0, std.math.inf(f64)) / scale);
    var green = truncatePackedFloat(std.math.clamp(color[1], 0, std.math.inf(f64)) / scale);
    var blue = truncatePackedFloat(std.math.clamp(color[2], 0, std.math.inf(f64)) / scale);
    if (@max(@max(red, green), blue) > 0x1ff and exponent < 31) {
        exponent += 1;
        scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
        red = truncatePackedFloat(std.math.clamp(color[0], 0, std.math.inf(f64)) / scale);
        green = truncatePackedFloat(std.math.clamp(color[1], 0, std.math.inf(f64)) / scale);
        blue = truncatePackedFloat(std.math.clamp(color[2], 0, std.math.inf(f64)) / scale);
    }
    return @as(u32, @intCast(@min(red, 0x1ff))) |
        (@as(u32, @intCast(@min(green, 0x1ff))) << 9) |
        (@as(u32, @intCast(@min(blue, 0x1ff))) << 18) |
        (@as(u32, @intCast(exponent)) << 27);
}

fn readPackedMipmapColor(texture: *const Texture, x: usize, y: usize) [4]f64 {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .b5g6r5_unorm => blk: {
            const bits = std.mem.readInt(u16, texture.bytes[offset..][0..2], .little);
            break :blk .{
                @as(f64, @floatFromInt((bits >> 11) & 0x1f)) / 31.0,
                @as(f64, @floatFromInt((bits >> 5) & 0x3f)) / 63.0,
                @as(f64, @floatFromInt(bits & 0x1f)) / 31.0,
                1,
            };
        },
        .a1bgr5_unorm => blk: {
            const bits = std.mem.readInt(u16, texture.bytes[offset..][0..2], .little);
            break :blk .{
                @as(f64, @floatFromInt((bits >> 11) & 0x1f)) / 31.0,
                @as(f64, @floatFromInt((bits >> 6) & 0x1f)) / 31.0,
                @as(f64, @floatFromInt((bits >> 1) & 0x1f)) / 31.0,
                if ((bits & 1) != 0) 1 else 0,
            };
        },
        .abgr4_unorm => blk: {
            const bits = std.mem.readInt(u16, texture.bytes[offset..][0..2], .little);
            break :blk .{
                @as(f64, @floatFromInt((bits >> 12) & 0xf)) / 15.0,
                @as(f64, @floatFromInt((bits >> 8) & 0xf)) / 15.0,
                @as(f64, @floatFromInt((bits >> 4) & 0xf)) / 15.0,
                @as(f64, @floatFromInt(bits & 0xf)) / 15.0,
            };
        },
        .bgr5a1_unorm => blk: {
            const bits = std.mem.readInt(u16, texture.bytes[offset..][0..2], .little);
            break :blk .{
                @as(f64, @floatFromInt((bits >> 10) & 0x1f)) / 31.0,
                @as(f64, @floatFromInt((bits >> 5) & 0x1f)) / 31.0,
                @as(f64, @floatFromInt(bits & 0x1f)) / 31.0,
                if ((bits >> 15) != 0) 1 else 0,
            };
        },
        .rgb10a2_unorm, .bgr10a2_unorm => blk: {
            const bits = std.mem.readInt(u32, texture.bytes[offset..][0..4], .little);
            const red_bits = if (texture.format == .rgb10a2_unorm) bits & 0x3ff else (bits >> 20) & 0x3ff;
            const blue_bits = if (texture.format == .rgb10a2_unorm) (bits >> 20) & 0x3ff else bits & 0x3ff;
            break :blk .{
                @as(f64, @floatFromInt(red_bits)) / 1023.0,
                @as(f64, @floatFromInt((bits >> 10) & 0x3ff)) / 1023.0,
                @as(f64, @floatFromInt(blue_bits)) / 1023.0,
                @as(f64, @floatFromInt((bits >> 30) & 3)) / 3.0,
            };
        },
        .rg11b10_float => blk: {
            const bits = std.mem.readInt(u32, texture.bytes[offset..][0..4], .little);
            break :blk .{
                readUnsignedPackedFloat(bits & 0x7ff, 6),
                readUnsignedPackedFloat((bits >> 11) & 0x7ff, 6),
                readUnsignedPackedFloat((bits >> 22) & 0x3ff, 5),
                1,
            };
        },
        .rgb9e5_float => readRgb9e5Mipmap(std.mem.readInt(u32, texture.bytes[offset..][0..4], .little)),
        else => unreachable,
    };
}

fn writePackedMipmapColor(texture: *Texture, x: usize, y: usize, color: [4]f64) void {
    const offset = y * texture.stride + x * texture.format.bytesPerPixel();
    switch (texture.format) {
        .b5g6r5_unorm => {
            const bits: u16 = @intCast((packedMipmapValue(color[0], 31) << 11) |
                (packedMipmapValue(color[1], 63) << 5) | packedMipmapValue(color[2], 31));
            std.mem.writeInt(u16, texture.bytes[offset..][0..2], bits, .little);
        },
        .a1bgr5_unorm => {
            const bits: u16 = @intCast((packedMipmapValue(color[0], 31) << 11) |
                (packedMipmapValue(color[1], 31) << 6) | (packedMipmapValue(color[2], 31) << 1) |
                packedMipmapValue(color[3], 1));
            std.mem.writeInt(u16, texture.bytes[offset..][0..2], bits, .little);
        },
        .abgr4_unorm => {
            const bits: u16 = @intCast((packedMipmapValue(color[0], 15) << 12) |
                (packedMipmapValue(color[1], 15) << 8) | (packedMipmapValue(color[2], 15) << 4) |
                packedMipmapValue(color[3], 15));
            std.mem.writeInt(u16, texture.bytes[offset..][0..2], bits, .little);
        },
        .bgr5a1_unorm => {
            const bits: u16 = @intCast((packedMipmapValue(color[0], 31) << 10) |
                (packedMipmapValue(color[1], 31) << 5) | packedMipmapValue(color[2], 31) |
                (packedMipmapValue(color[3], 1) << 15));
            std.mem.writeInt(u16, texture.bytes[offset..][0..2], bits, .little);
        },
        .rgb10a2_unorm, .bgr10a2_unorm => {
            const red_bits = packedMipmapValue(color[0], 1023) << (if (texture.format == .rgb10a2_unorm) 0 else 20);
            const blue_bits = packedMipmapValue(color[2], 1023) << (if (texture.format == .rgb10a2_unorm) 20 else 0);
            const bits = red_bits | (packedMipmapValue(color[1], 1023) << 10) | blue_bits |
                (packedMipmapValue(color[3], 3) << 30);
            std.mem.writeInt(u32, texture.bytes[offset..][0..4], bits, .little);
        },
        .rg11b10_float => {
            const bits = writeUnsignedPackedFloat(color[0], 6) |
                (writeUnsignedPackedFloat(color[1], 6) << 11) |
                (writeUnsignedPackedFloat(color[2], 5) << 22);
            std.mem.writeInt(u32, texture.bytes[offset..][0..4], bits, .little);
        },
        .rgb9e5_float => std.mem.writeInt(u32, texture.bytes[offset..][0..4], writeRgb9e5Mipmap(color), .little),
        else => unreachable,
    }
}

fn generateFloatMipmap(command: MipmapCommand) Error!void {
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source.format) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            const denominator = @as(f64, @floatFromInt(source_x.denominator * source_y.denominator));
            var sums = [_]f64{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const weight = @as(f64, @floatFromInt(x_sample.weight * y_sample.weight));
                    const color = readFloatMipmapColor(command.source, x_sample.index, y_sample.index);
                    for (0..4) |component| sums[component] += color[component] * weight;
                }
            }
            writeFloatMipmapColor(command.destination, x, y, .{
                sums[0] / denominator, sums[1] / denominator,
                sums[2] / denominator, sums[3] / denominator,
            });
        }
    }
}

fn generateA8Mipmap(command: MipmapCommand) Error!void {
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != .a8_unorm) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            var sum: f32 = 0;
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                var row_sum: f32 = 0;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const source_offset = y_sample.index * command.source.stride + x_sample.index;
                    const weight: f32 = @floatFromInt(x_sample.weight);
                    row_sum += @as(f32, @floatFromInt(command.source.bytes[source_offset])) / 255.0 * weight;
                }
                row_sum /= @as(f32, @floatFromInt(source_x.denominator));
                sum += row_sum * @as(f32, @floatFromInt(y_sample.weight));
            }
            const normalized = sum / @as(f32, @floatFromInt(source_y.denominator));
            const quantized: f64 = @as(f64, normalized) * 255.0 + 0.5;
            command.destination.bytes[y * command.destination.stride + x] = @intFromFloat(quantized);
        }
    }
}

fn generateA8Mipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != .a8_unorm) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.source0.format != .a8_unorm or command.destination.width != destination_width or
        command.destination.height != destination_height or command.destination.format != .a8_unorm) return error.InvalidArgument;
    const source0_z_weight = command.source1_weight_denominator - command.source1_weight_numerator;
    const source1_z_weight = command.source1_weight_numerator;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const x_denominator: f32 = @floatFromInt(source_x.denominator);
            const y_denominator: f32 = @floatFromInt(source_y.denominator);
            const z_denominator: f32 = @floatFromInt(command.source1_weight_denominator);
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            var sum: f32 = 0;
            const sources = [_]struct { texture: ?*Texture, weight: u64 }{
                .{ .texture = command.source0, .weight = source0_z_weight },
                .{ .texture = source1, .weight = source1_z_weight },
            };
            for (sources) |source_sample| {
                const texture = source_sample.texture orelse continue;
                if (source_sample.weight == 0) continue;
                var xy_sum: f32 = 0;
                for (y_samples) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    var row_sum: f32 = 0;
                    for (x_samples) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const source_offset = y_sample.index * texture.stride + x_sample.index;
                        row_sum += @as(f32, @floatFromInt(texture.bytes[source_offset])) / 255.0 *
                            @as(f32, @floatFromInt(x_sample.weight));
                    }
                    row_sum /= x_denominator;
                    xy_sum += row_sum * @as(f32, @floatFromInt(y_sample.weight));
                }
                xy_sum /= y_denominator;
                sum += xy_sum * @as(f32, @floatFromInt(source_sample.weight));
            }
            const normalized = sum / z_denominator;
            const quantized: f64 = @as(f64, normalized) * 255.0 + 0.5;
            command.destination.bytes[y * command.destination.stride + x] = @intFromFloat(quantized);
        }
    }
}

fn generatePackedUnormMipmap(command: MipmapCommand) Error!void {
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source.format) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            const denominator: f32 = @floatFromInt(source_x.denominator * source_y.denominator);
            var sums = [_]f32{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const weight: f32 = @floatFromInt(x_sample.weight * y_sample.weight);
                    const color = readPackedMipmapColor(command.source, x_sample.index, y_sample.index);
                    for (0..4) |component| sums[component] += @as(f32, @floatCast(color[component])) * weight;
                }
            }
            writePackedMipmapColor(command.destination, x, y, .{
                @as(f64, sums[0] / denominator), @as(f64, sums[1] / denominator),
                @as(f64, sums[2] / denominator), @as(f64, sums[3] / denominator),
            });
        }
    }
}

fn generateUnorm8Mipmap(command: MipmapCommand) Error!void {
    if (command.source.format == .a8_unorm) return generateA8Mipmap(command);
    const channels = unorm8ChannelCount(command.source.format);
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source.format) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            const weight_denominator = source_x.denominator * source_y.denominator;
            var sums = [_]u64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_weights) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_weights) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const source_offset = y_sample.index * command.source.stride + x_sample.index * channels;
                    const weight = x_sample.weight * y_sample.weight;
                    for (0..channels) |component| sums[component] += @as(u64, command.source.bytes[source_offset + component]) * weight;
                }
            }
            const destination_offset = y * command.destination.stride + x * channels;
            for (0..channels) |component| {
                const value = if (command.source.format == .a8_unorm)
                    sums[component] / weight_denominator
                else
                    (sums[component] + weight_denominator / 2) / weight_denominator;
                command.destination.bytes[destination_offset + component] = @intCast(value);
            }
        }
    }
}

fn generateSrgb8Mipmap(command: MipmapCommand) Error!void {
    const channels = srgb8ChannelCount(command.source.format);
    if (command.destination.width == 0 or command.destination.height == 0 or
        command.destination.width > command.source.width or (command.source.width > 1 and command.destination.width == command.source.width) or
        command.destination.height > command.source.height or (command.source.height > 1 and command.destination.height == command.source.height) or
        command.destination.format != command.source.format) return error.InvalidArgument;
    // When the source footprint is an integral number of destination texels,
    // Apple's sRGB mip generator uses the complete footprint. Preserve that
    // path for direct multi-level reductions (for example 8x8 -> 2x2); the
    // center-weighted path below is needed only when an odd dimension leaves
    // a fractional footprint (for example 5x3 -> 2x1).
    if (command.source.width % command.destination.width == 0 and
        command.source.height % command.destination.height == 0)
    {
        for (0..command.destination.height) |y| {
            const source_y = mipmapRange(command.source.height, command.destination.height, y);
            for (0..command.destination.width) |x| {
                const source_x = mipmapRange(command.source.width, command.destination.width, x);
                const footprint = (source_x.high - source_x.low) * (source_y.high - source_y.low);
                const denominator = @as(f64, @floatFromInt(footprint));
                var sums = [_]f64{ 0, 0, 0, 0 };
                var alpha_sum: f32 = 0;
                for (source_y.low..source_y.high) |source_y_index| {
                    for (source_x.low..source_x.high) |source_x_index| {
                        const color = readSrgb8MipmapColor(command.source, source_x_index, source_y_index);
                        for (0..channels) |component| sums[component] += color[component];
                        if (channels == 4) alpha_sum += @floatCast(color[3]);
                    }
                }
                writeSrgb8MipmapColor(command.destination, x, y, .{
                    sums[0] / denominator, sums[1] / denominator,
                    sums[2] / denominator, if (channels == 4) @as(f64, @floatCast(alpha_sum / @as(f32, @floatFromInt(footprint)))) else 1,
                });
            }
        }
        return;
    }
    for (0..command.destination.height) |y| {
        const source_y = mipmapAxis(command.source.height, command.destination.height, y);
        for (0..command.destination.width) |x| {
            const source_x = mipmapAxis(command.source.width, command.destination.width, x);
            const denominator = @as(f64, @floatFromInt(source_x.denominator * source_y.denominator));
            var sums = [_]f64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_weights) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_weights) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const color = readSrgb8MipmapColor(command.source, x_sample.index, y_sample.index);
                    const weight = @as(f64, @floatFromInt(x_sample.weight * y_sample.weight));
                    for (0..channels) |component| sums[component] += color[component] * weight;
                }
            }
            writeSrgb8MipmapColor(command.destination, x, y, .{
                sums[0] / denominator, sums[1] / denominator,
                sums[2] / denominator, if (channels == 4) sums[3] / denominator else 1,
            });
        }
    }
}

fn generateSrgb8MipmapChain(levels: []const *Texture) Error!void {
    if (levels.len < 2) return error.InvalidArgument;
    const base = levels[0];
    const channels = srgb8ChannelCount(base.format);
    if (base.width == 0 or base.height == 0) return error.InvalidArgument;
    for (levels) |level| {
        if (level.format != base.format or level.width == 0 or level.height == 0) return error.InvalidArgument;
    }

    const base_pixel_count = std.math.mul(usize, base.width, base.height) catch return error.InvalidArgument;
    var current = allocator.alloc([4]f64, base_pixel_count) catch return error.OutOfMemory;
    defer allocator.free(current);
    for (0..base.height) |y| {
        for (0..base.width) |x| {
            current[y * base.width + x] = readSrgb8MipmapColor(base, x, y);
        }
    }

    var source_width = base.width;
    var source_height = base.height;
    for (levels[1..]) |destination| {
        const destination_width = if (source_width > 1) source_width / 2 else 1;
        const destination_height = if (source_height > 1) source_height / 2 else 1;
        if (destination.width != destination_width or destination.height != destination_height) return error.InvalidArgument;
        const destination_pixel_count = std.math.mul(usize, destination_width, destination_height) catch return error.InvalidArgument;
        var next = allocator.alloc([4]f64, destination_pixel_count) catch return error.OutOfMemory;
        errdefer allocator.free(next);
        for (0..destination_height) |y| {
            const source_y = mipmapAxis(source_height, destination_height, y);
            for (0..destination_width) |x| {
                const source_x = mipmapAxis(source_width, destination_width, x);
                const denominator = @as(f64, @floatFromInt(source_x.denominator * source_y.denominator));
                var sums = [_]f64{ 0, 0, 0, 0 };
                const x_weights = [_]struct { index: usize, weight: u64 }{
                    .{ .index = source_x.low, .weight = source_x.low_weight },
                    .{ .index = source_x.high, .weight = source_x.high_weight },
                };
                const y_weights = [_]struct { index: usize, weight: u64 }{
                    .{ .index = source_y.low, .weight = source_y.low_weight },
                    .{ .index = source_y.high, .weight = source_y.high_weight },
                };
                for (y_weights) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    for (x_weights) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const color = current[y_sample.index * source_width + x_sample.index];
                        const weight = @as(f64, @floatFromInt(x_sample.weight * y_sample.weight));
                        for (0..channels) |component| sums[component] += color[component] * weight;
                    }
                }
                next[y * destination_width + x] = .{
                    sums[0] / denominator, sums[1] / denominator,
                    sums[2] / denominator, if (channels == 4) sums[3] / denominator else 1,
                };
                writeSrgb8MipmapColor(destination, x, y, next[y * destination_width + x]);
            }
        }
        allocator.free(current);
        current = next;
        source_width = destination_width;
        source_height = destination_height;
    }
}

fn generateUnorm16Mipmap(command: MipmapCommand) Error!void {
    const channels = unorm16ChannelCount(command.source.format);
    const bytes_per_pixel = channels * @sizeOf(u16);
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source.format) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            const weight_denominator = source_x.denominator * source_y.denominator;
            var sums = [_]u64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_weights) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_weights) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const source_offset = y_sample.index * command.source.stride + x_sample.index * bytes_per_pixel;
                    const weight = x_sample.weight * y_sample.weight;
                    for (0..channels) |component| {
                        sums[component] += @as(u64, std.mem.readInt(u16, command.source.bytes[source_offset + component * 2 ..][0..2], .little)) * weight;
                    }
                }
            }
            const destination_offset = y * command.destination.stride + x * bytes_per_pixel;
            for (0..channels) |component| {
                std.mem.writeInt(u16, command.destination.bytes[destination_offset + component * 2 ..][0..2], @intCast((sums[component] + weight_denominator / 2) / weight_denominator), .little);
            }
        }
    }
}

fn generateSnormMipmap(command: MipmapCommand) Error!void {
    const channels = switch (command.source.format) {
        .r8_snorm, .rg8_snorm, .rgba8_snorm => snorm8ChannelCount(command.source.format),
        .r16_snorm, .rg16_snorm, .rgba16_snorm => snorm16ChannelCount(command.source.format),
        else => unreachable,
    };
    const maximum: i128 = switch (command.source.format) {
        .r8_snorm, .rg8_snorm, .rgba8_snorm => 127,
        .r16_snorm, .rg16_snorm, .rgba16_snorm => 32767,
        else => unreachable,
    };
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source.format) return error.InvalidArgument;
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source.width, destination_width, x);
            var sums = [_]i128{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const weight: i128 = @intCast(x_sample.weight * y_sample.weight);
                    for (0..channels) |component| {
                        sums[component] += readSnormMipmapCode(command.source, x_sample.index, y_sample.index, component) * weight;
                    }
                }
            }
            const denominator = source_x.denominator * source_y.denominator;
            writeSnormMipmapCode(command.destination, x, y, .{
                averagedSnormCode(sums[0], denominator, maximum),
                averagedSnormCode(sums[1], denominator, maximum),
                averagedSnormCode(sums[2], denominator, maximum),
                averagedSnormCode(sums[3], denominator, maximum),
            });
        }
    }
}

fn generateMipmap(command: MipmapCommand) Error!void {
    if (command.source == command.destination or !command.source.format.isColor() or command.source.format.isIntegerColor()) return error.UnsupportedFormat;
    if (command.source.format == .r8_unorm_srgb or command.source.format == .rg8_unorm_srgb or
        command.source.format == .rgba8_unorm_srgb or command.source.format == .bgra8_unorm_srgb) return generateSrgb8Mipmap(command);
    if (command.source.format == .r8_snorm or command.source.format == .rg8_snorm or command.source.format == .rgba8_snorm or
        command.source.format == .r16_snorm or command.source.format == .rg16_snorm or command.source.format == .rgba16_snorm) return generateSnormMipmap(command);
    if (command.source.format == .b5g6r5_unorm or command.source.format == .a1bgr5_unorm or
        command.source.format == .abgr4_unorm or command.source.format == .bgr5a1_unorm or
        command.source.format == .rgb10a2_unorm or command.source.format == .bgr10a2_unorm or
        command.source.format == .rg11b10_float or command.source.format == .rgb9e5_float) return generatePackedUnormMipmap(command);
    if (command.source.format == .r16_unorm or command.source.format == .rg16_unorm or command.source.format == .rgba16_unorm) return generateUnorm16Mipmap(command);
    if (command.source.format == .r16_float or command.source.format == .rg16_float or command.source.format == .r32_float or command.source.format == .rgba16_float or command.source.format == .rgba32_float) {
        return generateFloatMipmap(command);
    }
    return generateUnorm8Mipmap(command);
}

fn generateFloatMipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(u64, command.source1_weight_denominator - command.source1_weight_numerator);
    const source1_z_weight = @as(u64, command.source1_weight_numerator);
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const xy_denominator = @as(f64, @floatFromInt(source_x.denominator * source_y.denominator));
            const z_denominator = @as(f64, @floatFromInt(command.source1_weight_denominator));
            var sums = [_]f64{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const xy_weight = @as(f64, @floatFromInt(x_sample.weight * y_sample.weight));
                    const color0 = readFloatMipmapColor(command.source0, x_sample.index, y_sample.index);
                    for (0..4) |component| {
                        sums[component] += color0[component] * xy_weight * @as(f64, @floatFromInt(source0_z_weight));
                    }
                    if (source1) |value| {
                        if (source1_z_weight != 0) {
                            const color1 = readFloatMipmapColor(value, x_sample.index, y_sample.index);
                            for (0..4) |component| {
                                sums[component] += color1[component] * xy_weight * @as(f64, @floatFromInt(source1_z_weight));
                            }
                        }
                    }
                }
            }
            const denominator = xy_denominator * z_denominator;
            writeFloatMipmapColor(command.destination, x, y, .{
                sums[0] / denominator, sums[1] / denominator,
                sums[2] / denominator, sums[3] / denominator,
            });
        }
    }
}

fn generateUnorm8Mipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source0.format == .a8_unorm) return generateA8Mipmap3D(command);
    const channels = unorm8ChannelCount(command.source0.format);
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(u64, command.source1_weight_denominator - command.source1_weight_numerator);
    const source1_z_weight = @as(u64, command.source1_weight_numerator);
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const weight_denominator = source_x.denominator * source_y.denominator * command.source1_weight_denominator;
            var sums = [_]u64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            const sources = [_]struct { texture: *Texture, weight: u64 }{
                .{ .texture = command.source0, .weight = source0_z_weight },
            };
            for (sources) |source_sample| {
                if (source_sample.weight == 0) continue;
                for (y_weights) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    for (x_weights) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const source_offset = y_sample.index * source_sample.texture.stride + x_sample.index * channels;
                        const weight = source_sample.weight * x_sample.weight * y_sample.weight;
                        for (0..channels) |component| sums[component] += @as(u64, source_sample.texture.bytes[source_offset + component]) * weight;
                    }
                }
            }
            if (source1) |value| {
                if (source1_z_weight != 0) {
                    for (y_weights) |y_sample| {
                        if (y_sample.weight == 0) continue;
                        for (x_weights) |x_sample| {
                            if (x_sample.weight == 0) continue;
                            const source_offset = y_sample.index * value.stride + x_sample.index * channels;
                            const weight = source1_z_weight * x_sample.weight * y_sample.weight;
                            for (0..channels) |component| sums[component] += @as(u64, value.bytes[source_offset + component]) * weight;
                        }
                    }
                }
            }
            const destination_offset = y * command.destination.stride + x * channels;
            for (0..channels) |component| command.destination.bytes[destination_offset + component] = @intCast((sums[component] + weight_denominator / 2) / weight_denominator);
        }
    }
}

fn generateSrgb8Mipmap3D(command: Mipmap3DCommand) Error!void {
    const channels = srgb8ChannelCount(command.source0.format);
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(u64, command.source1_weight_denominator - command.source1_weight_numerator);
    const source1_z_weight = @as(u64, command.source1_weight_numerator);
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const denominator = @as(f64, @floatFromInt(source_x.denominator * source_y.denominator * command.source1_weight_denominator));
            var sums = [_]f64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            if (source0_z_weight != 0) for (y_weights) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_weights) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const color = readSrgb8MipmapColor(command.source0, x_sample.index, y_sample.index);
                    const weight = @as(f64, @floatFromInt(source0_z_weight * x_sample.weight * y_sample.weight));
                    for (0..channels) |component| sums[component] += color[component] * weight;
                }
            };
            if (source1) |value| {
                if (source1_z_weight != 0) for (y_weights) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    for (x_weights) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const color = readSrgb8MipmapColor(value, x_sample.index, y_sample.index);
                        const weight = @as(f64, @floatFromInt(source1_z_weight * x_sample.weight * y_sample.weight));
                        for (0..channels) |component| sums[component] += color[component] * weight;
                    }
                };
            }
            writeSrgb8MipmapColor(command.destination, x, y, .{
                sums[0] / denominator, sums[1] / denominator,
                sums[2] / denominator, sums[3] / denominator,
            });
        }
    }
}

fn generateSrgb8Mipmap3DArray(command: Mipmap3DArrayCommand) Error!void {
    if (command.source_planes.len == 0 or command.destination.width == 0 or command.destination.height == 0 or
        command.destination.format != command.source_planes[0].format) return error.InvalidArgument;
    const source = command.source_planes[0];
    if (command.destination.width > source.width or command.destination.height > source.height or
        (source.width > 1 and command.destination.width == source.width) or
        (source.height > 1 and command.destination.height == source.height)) return error.InvalidArgument;
    for (command.source_planes) |source_plane| {
        if (source_plane.format != source.format or source_plane.width != source.width or
            source_plane.height != source.height) return error.InvalidArgument;
    }
    const channels = srgb8ChannelCount(source.format);
    for (0..command.destination.height) |y| {
        const source_y = mipmapRange(source.height, command.destination.height, y);
        for (0..command.destination.width) |x| {
            const source_x = mipmapRange(source.width, command.destination.width, x);
            const footprint = command.source_planes.len * (source_x.high - source_x.low) * (source_y.high - source_y.low);
            const denominator = @as(f64, @floatFromInt(footprint));
            var sums = [_]f64{ 0, 0, 0, 0 };
            var alpha_sum: f32 = 0;
            for (command.source_planes) |source_plane| {
                for (source_x.low..source_x.high) |source_x_index| {
                    for (source_y.low..source_y.high) |source_y_index| {
                        const color = readSrgb8MipmapColor(source_plane, source_x_index, source_y_index);
                        for (0..channels) |component| sums[component] += color[component];
                        if (channels == 4) alpha_sum += @floatCast(color[3]);
                    }
                }
            }
            writeSrgb8MipmapColor(command.destination, x, y, .{
                sums[0] / denominator, sums[1] / denominator,
                sums[2] / denominator, if (channels == 4) @as(f64, @floatCast(alpha_sum / @as(f32, @floatFromInt(footprint)))) else 1,
            });
        }
    }
}

fn generateUnorm16Mipmap3D(command: Mipmap3DCommand) Error!void {
    const channels = unorm16ChannelCount(command.source0.format);
    const bytes_per_pixel = channels * @sizeOf(u16);
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(u64, command.source1_weight_denominator - command.source1_weight_numerator);
    const source1_z_weight = @as(u64, command.source1_weight_numerator);
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const weight_denominator = source_x.denominator * source_y.denominator * command.source1_weight_denominator;
            var sums = [_]u64{ 0, 0, 0, 0 };
            const x_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_weights = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            const sources = [_]struct { texture: *Texture, weight: u64 }{
                .{ .texture = command.source0, .weight = source0_z_weight },
            };
            for (sources) |source_sample| {
                if (source_sample.weight == 0) continue;
                for (y_weights) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    for (x_weights) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const source_offset = y_sample.index * source_sample.texture.stride + x_sample.index * bytes_per_pixel;
                        const weight = source_sample.weight * x_sample.weight * y_sample.weight;
                        for (0..channels) |component| {
                            sums[component] += @as(u64, std.mem.readInt(u16, source_sample.texture.bytes[source_offset + component * 2 ..][0..2], .little)) * weight;
                        }
                    }
                }
            }
            if (source1) |value| {
                if (source1_z_weight != 0) {
                    for (y_weights) |y_sample| {
                        if (y_sample.weight == 0) continue;
                        for (x_weights) |x_sample| {
                            if (x_sample.weight == 0) continue;
                            const source_offset = y_sample.index * value.stride + x_sample.index * bytes_per_pixel;
                            const weight = source1_z_weight * x_sample.weight * y_sample.weight;
                            for (0..channels) |component| {
                                sums[component] += @as(u64, std.mem.readInt(u16, value.bytes[source_offset + component * 2 ..][0..2], .little)) * weight;
                            }
                        }
                    }
                }
            }
            const destination_offset = y * command.destination.stride + x * bytes_per_pixel;
            for (0..channels) |component| {
                std.mem.writeInt(u16, command.destination.bytes[destination_offset + component * 2 ..][0..2], @intCast((sums[component] + weight_denominator / 2) / weight_denominator), .little);
            }
        }
    }
}

fn generateSnormMipmap3D(command: Mipmap3DCommand) Error!void {
    const channels = switch (command.source0.format) {
        .r8_snorm, .rg8_snorm, .rgba8_snorm => snorm8ChannelCount(command.source0.format),
        .r16_snorm, .rg16_snorm, .rgba16_snorm => snorm16ChannelCount(command.source0.format),
        else => unreachable,
    };
    const maximum: i128 = switch (command.source0.format) {
        .r8_snorm, .rg8_snorm, .rgba8_snorm => 127,
        .r16_snorm, .rg16_snorm, .rgba16_snorm => 32767,
        else => unreachable,
    };
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(u64, command.source1_weight_denominator - command.source1_weight_numerator);
    const source1_z_weight = @as(u64, command.source1_weight_numerator);
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            const xy_denominator = source_x.denominator * source_y.denominator;
            const denominator = xy_denominator * command.source1_weight_denominator;
            var sums = [_]i128{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            if (source0_z_weight != 0) for (y_samples) |y_sample| {
                if (y_sample.weight == 0) continue;
                for (x_samples) |x_sample| {
                    if (x_sample.weight == 0) continue;
                    const weight: i128 = @intCast(source0_z_weight * x_sample.weight * y_sample.weight);
                    for (0..channels) |component| {
                        sums[component] += readSnormMipmapCode(command.source0, x_sample.index, y_sample.index, component) * weight;
                    }
                }
            };
            if (source1) |value| {
                if (source1_z_weight != 0) for (y_samples) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    for (x_samples) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const weight: i128 = @intCast(source1_z_weight * x_sample.weight * y_sample.weight);
                        for (0..channels) |component| {
                            sums[component] += readSnormMipmapCode(value, x_sample.index, y_sample.index, component) * weight;
                        }
                    }
                };
            }
            writeSnormMipmapCode(command.destination, x, y, .{
                averagedSnormCode(sums[0], denominator, maximum),
                averagedSnormCode(sums[1], denominator, maximum),
                averagedSnormCode(sums[2], denominator, maximum),
                averagedSnormCode(sums[3], denominator, maximum),
            });
        }
    }
}

fn generatePackedUnormMipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height or
        command.destination.format != command.source0.format) return error.InvalidArgument;
    const source0_z_weight = @as(f32, @floatFromInt(command.source1_weight_denominator - command.source1_weight_numerator));
    const source1_z_weight = @as(f32, @floatFromInt(command.source1_weight_numerator));
    const x_denominator: f32 = @floatFromInt(mipmapAxis(command.source0.width, destination_width, 0).denominator);
    const y_denominator: f32 = @floatFromInt(mipmapAxis(command.source0.height, destination_height, 0).denominator);
    const z_denominator = @as(f32, @floatFromInt(command.source1_weight_denominator));
    for (0..destination_height) |y| {
        const source_y = mipmapAxis(command.source0.height, destination_height, y);
        for (0..destination_width) |x| {
            const source_x = mipmapAxis(command.source0.width, destination_width, x);
            var sums = [_]f32{ 0, 0, 0, 0 };
            const x_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_x.low, .weight = source_x.low_weight },
                .{ .index = source_x.high, .weight = source_x.high_weight },
            };
            const y_samples = [_]struct { index: usize, weight: u64 }{
                .{ .index = source_y.low, .weight = source_y.low_weight },
                .{ .index = source_y.high, .weight = source_y.high_weight },
            };
            const sources = [_]struct { texture: *Texture, weight: f32 }{
                .{ .texture = command.source0, .weight = source0_z_weight },
            };
            for (sources) |source_sample| {
                if (source_sample.weight == 0) continue;
                var xy_sums = [_]f32{ 0, 0, 0, 0 };
                for (y_samples) |y_sample| {
                    if (y_sample.weight == 0) continue;
                    var row_sums = [_]f32{ 0, 0, 0, 0 };
                    for (x_samples) |x_sample| {
                        if (x_sample.weight == 0) continue;
                        const color = readPackedMipmapColor(source_sample.texture, x_sample.index, y_sample.index);
                        for (0..4) |component| {
                            row_sums[component] += @as(f32, @floatCast(color[component])) *
                                @as(f32, @floatFromInt(x_sample.weight));
                        }
                    }
                    for (0..4) |component| xy_sums[component] += row_sums[component] / x_denominator *
                        @as(f32, @floatFromInt(y_sample.weight));
                }
                for (0..4) |component| sums[component] += xy_sums[component] / y_denominator * source_sample.weight;
            }
            if (source1) |value| {
                if (source1_z_weight != 0) {
                    var xy_sums = [_]f32{ 0, 0, 0, 0 };
                    for (y_samples) |y_sample| {
                        if (y_sample.weight == 0) continue;
                        var row_sums = [_]f32{ 0, 0, 0, 0 };
                        for (x_samples) |x_sample| {
                            if (x_sample.weight == 0) continue;
                            const color = readPackedMipmapColor(value, x_sample.index, y_sample.index);
                            for (0..4) |component| row_sums[component] += @as(f32, @floatCast(color[component])) *
                                @as(f32, @floatFromInt(x_sample.weight));
                        }
                        for (0..4) |component| xy_sums[component] += row_sums[component] / x_denominator *
                            @as(f32, @floatFromInt(y_sample.weight));
                    }
                    for (0..4) |component| sums[component] += xy_sums[component] / y_denominator * source1_z_weight;
                }
            }
            writePackedMipmapColor(command.destination, x, y, .{
                @as(f64, sums[0] / z_denominator), @as(f64, sums[1] / z_denominator),
                @as(f64, sums[2] / z_denominator), @as(f64, sums[3] / z_denominator),
            });
        }
    }
}

fn generateMipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source0 == command.destination or !command.source0.format.isColor() or command.source0.format.isIntegerColor()) return error.UnsupportedFormat;
    if (command.source0.format == .r8_unorm_srgb or command.source0.format == .rg8_unorm_srgb or
        command.source0.format == .rgba8_unorm_srgb or command.source0.format == .bgra8_unorm_srgb) return generateSrgb8Mipmap3D(command);
    if (command.source0.format == .r8_snorm or command.source0.format == .rg8_snorm or command.source0.format == .rgba8_snorm or
        command.source0.format == .r16_snorm or command.source0.format == .rg16_snorm or command.source0.format == .rgba16_snorm) return generateSnormMipmap3D(command);
    if (command.source0.format == .b5g6r5_unorm or command.source0.format == .a1bgr5_unorm or
        command.source0.format == .abgr4_unorm or command.source0.format == .bgr5a1_unorm or
        command.source0.format == .rgb10a2_unorm or command.source0.format == .bgr10a2_unorm or
        command.source0.format == .rg11b10_float or command.source0.format == .rgb9e5_float) return generatePackedUnormMipmap3D(command);
    if (command.source0.format == .r16_unorm or command.source0.format == .rg16_unorm or command.source0.format == .rgba16_unorm) return generateUnorm16Mipmap3D(command);
    if (command.source0.format == .r16_float or command.source0.format == .rg16_float or command.source0.format == .r32_float or command.source0.format == .rgba16_float or command.source0.format == .rgba32_float) {
        return generateFloatMipmap3D(command);
    }
    return generateUnorm8Mipmap3D(command);
}

fn validateRegion(width: u32, height: u32, region: abi.Region, stride: usize, storage_length: usize, bytes_per_pixel: usize) Error!void {
    if (region.origin.z != 0 or region.size.depth != 1) return error.InvalidArgument;
    if (region.origin.x > width or region.origin.y > height or region.size.width > width - region.origin.x or region.size.height > height - region.origin.y) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, region.size.width, bytes_per_pixel) catch return error.InvalidArgument;
    if (stride < row_bytes) return error.InvalidArgument;
    const needed = if (region.size.height == 0) 0 else std.math.add(usize, std.math.mul(usize, region.size.height - 1, stride) catch return error.InvalidArgument, row_bytes) catch return error.InvalidArgument;
    if (storage_length < needed) return error.InvalidArgument;
}

fn readU16Little(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readF16Little(bytes: []const u8, offset: usize) f32 {
    return @floatCast(@as(f16, @bitCast(readU16Little(bytes, offset))));
}

fn writeU16Little(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn bfloat16FromBits(value: u16) f32 {
    return @bitCast(@as(u32, value) << 16);
}

fn bfloat16ToBits(value: f32) u16 {
    const bits: u32 = @bitCast(value);
    const rounded = bits +% (0x7fff + ((bits >> 16) & 1));
    return @intCast(rounded >> 16);
}

fn readU32Little(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn writeU32Little(bytes: []u8, offset: usize, value: u32) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
    bytes[offset + 2] = @truncate(value >> 16);
    bytes[offset + 3] = @truncate(value >> 24);
}

fn readU24Little(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16);
}

fn depthTextureValue(texture: *const Texture, index: usize) f32 {
    const offset = index * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .depth16_unorm => @as(f32, @floatFromInt(readU16Little(texture.bytes, offset))) / 65535.0,
        .depth24_unorm_stencil8 => @as(f32, @floatFromInt(readU24Little(texture.bytes, offset))) / 16777215.0,
        .depth32_float, .depth32_float_stencil8 => @bitCast(readU32Little(texture.bytes, offset)),
        else => unreachable,
    };
}

fn stencilTextureValue(texture: *const Texture, index: usize) u8 {
    const offset = index * texture.format.bytesPerPixel();
    return switch (texture.format) {
        .stencil8 => texture.bytes[offset],
        .depth24_unorm_stencil8, .x24_stencil8 => texture.bytes[offset + 3],
        .depth32_float_stencil8, .x32_stencil8 => texture.bytes[offset + 4],
        else => unreachable,
    };
}

fn storeDepthTexture(texture: *Texture, values: []const f32) void {
    for (values, 0..) |value, index| {
        const offset = index * texture.format.bytesPerPixel();
        switch (texture.format) {
            .depth16_unorm => {
                const quantized: u16 = @intFromFloat(std.math.clamp(value, 0, 1) * 65535.0 + 0.5);
                writeU16Little(texture.bytes, offset, quantized);
            },
            .depth24_unorm_stencil8 => {
                const quantized: u32 = @intFromFloat(std.math.clamp(value, 0, 1) * 16777215.0 + 0.5);
                texture.bytes[offset] = @truncate(quantized);
                texture.bytes[offset + 1] = @truncate(quantized >> 8);
                texture.bytes[offset + 2] = @truncate(quantized >> 16);
            },
            .depth32_float, .depth32_float_stencil8 => writeU32Little(texture.bytes, offset, @bitCast(value)),
            else => unreachable,
        }
    }
}

fn storeDepthSampleTextures(targets: [4]?*Texture, sample_count: usize, values: []const f32) void {
    if (sample_count == 0) return;
    const pixel_count = values.len / sample_count;
    for (targets[0..sample_count], 0..) |target, sample_index| {
        if (target) |texture| {
            storeDepthTexture(texture, values[sample_index * pixel_count .. (sample_index + 1) * pixel_count]);
        }
    }
}

fn storeDepthSampleArrayTextures(
    targets: [8][4]?*Texture,
    array_count: usize,
    sample_count: usize,
    values: [8]?[]f32,
) void {
    for (0..array_count) |layer| {
        if (values[layer]) |layer_values| {
            storeDepthSampleTextures(targets[layer], sample_count, layer_values);
        }
    }
}

fn storeStencilTexture(texture: *Texture, values: []const u8) void {
    for (values, 0..) |value, index| {
        const offset = index * texture.format.bytesPerPixel();
        switch (texture.format) {
            .stencil8 => texture.bytes[offset] = value,
            .depth24_unorm_stencil8, .x24_stencil8 => texture.bytes[offset + 3] = value,
            .depth32_float_stencil8, .x32_stencil8 => texture.bytes[offset + 4] = value,
            else => unreachable,
        }
    }
}

fn storeStencilSampleTextures(targets: [4]?*Texture, sample_count: usize, values: []const u8) void {
    if (sample_count == 0) return;
    const pixel_count = values.len / sample_count;
    for (targets[0..sample_count], 0..) |target, sample_index| {
        if (target) |texture| {
            storeStencilTexture(texture, values[sample_index * pixel_count .. (sample_index + 1) * pixel_count]);
        }
    }
}

fn storeStencilSampleArrayTextures(
    targets: [8][4]?*Texture,
    array_count: usize,
    sample_count: usize,
    values: [8]?[]u8,
) void {
    for (0..array_count) |layer| {
        if (values[layer]) |layer_values| {
            storeStencilSampleTextures(targets[layer], sample_count, layer_values);
        }
    }
}

fn readU64Little(bytes: []const u8, offset: usize) u64 {
    return @as(u64, bytes[offset]) |
        (@as(u64, bytes[offset + 1]) << 8) |
        (@as(u64, bytes[offset + 2]) << 16) |
        (@as(u64, bytes[offset + 3]) << 24) |
        (@as(u64, bytes[offset + 4]) << 32) |
        (@as(u64, bytes[offset + 5]) << 40) |
        (@as(u64, bytes[offset + 6]) << 48) |
        (@as(u64, bytes[offset + 7]) << 56);
}

fn writeU64Little(bytes: []u8, offset: usize, value: u64) void {
    bytes[offset] = @intCast(value);
    bytes[offset + 1] = @intCast(value >> 8);
    bytes[offset + 2] = @intCast(value >> 16);
    bytes[offset + 3] = @intCast(value >> 24);
    bytes[offset + 4] = @intCast(value >> 32);
    bytes[offset + 5] = @intCast(value >> 40);
    bytes[offset + 6] = @intCast(value >> 48);
    bytes[offset + 7] = @intCast(value >> 56);
}

fn visibilitySlotSeen(slots: []const VisibilitySlot, buffer: *Buffer, offset: usize) bool {
    for (slots) |slot| if (slot.buffer == buffer and slot.offset == offset) return true;
    return false;
}

fn texturePixelFormat(texture: *const Texture) ?abi.PixelFormat {
    return switch (texture.format) {
        .a8_unorm => .a8_unorm,
        .r8_unorm => .r8_unorm,
        .r8_unorm_srgb => .r8_unorm_srgb,
        .r8_snorm => .r8_snorm,
        .r8_uint => .r8_uint,
        .r8_sint => .r8_sint,
        .r16_unorm => .r16_unorm,
        .r16_snorm => .r16_snorm,
        .r16_uint => .r16_uint,
        .r16_sint => .r16_sint,
        .r16_float => .r16_float,
        .rg8_unorm => .rg8_unorm,
        .rg8_unorm_srgb => .rg8_unorm_srgb,
        .rg8_snorm => .rg8_snorm,
        .rg8_uint => .rg8_uint,
        .rg8_sint => .rg8_sint,
        .rg16_unorm => .rg16_unorm,
        .rg16_snorm => .rg16_snorm,
        .rg16_uint => .rg16_uint,
        .rg16_sint => .rg16_sint,
        .rg16_float => .rg16_float,
        .r32_uint => .r32_uint,
        .r32_sint => .r32_sint,
        .rgba8_unorm => .rgba8_unorm,
        .rgba8_unorm_srgb => .rgba8_unorm_srgb,
        .rgba8_snorm => .rgba8_snorm,
        .rgba8_uint => .rgba8_uint,
        .rgba8_sint => .rgba8_sint,
        .bgra8_unorm => .bgra8_unorm,
        .bgra8_unorm_srgb => .bgra8_unorm_srgb,
        .b5g6r5_unorm => .b5g6r5_unorm,
        .a1bgr5_unorm => .a1bgr5_unorm,
        .abgr4_unorm => .abgr4_unorm,
        .bgr5a1_unorm => .bgr5a1_unorm,
        .rgb10a2_unorm => .rgb10a2_unorm,
        .rgb10a2_uint => .rgb10a2_uint,
        .rg11b10_float => .rg11b10_float,
        .rgb9e5_float => .rgb9e5_float,
        .bgr10a2_unorm => .bgr10a2_unorm,
        .r32_float => .r32_float,
        .rgba16_unorm => .rgba16_unorm,
        .rgba16_snorm => .rgba16_snorm,
        .rgba16_uint => .rgba16_uint,
        .rgba16_sint => .rgba16_sint,
        .rgba16_float => .rgba16_float,
        .rg32_uint => .rg32_uint,
        .rg32_sint => .rg32_sint,
        .rg32_float => .rg32_float,
        .rgba32_uint => .rgba32_uint,
        .rgba32_sint => .rgba32_sint,
        .rgba32_float => .rgba32_float,
        .depth16_unorm => .depth16_unorm,
        .depth32_float => .depth32_float,
        .stencil8 => .stencil8,
        .depth24_unorm_stencil8 => .depth24_unorm_stencil8,
        .depth32_float_stencil8 => .depth32_float_stencil8,
        .x32_stencil8 => .x32_stencil8,
        .x24_stencil8 => .x24_stencil8,
    };
}

fn rangeValid(length: usize, offset: usize, count: usize) bool {
    return offset <= length and count <= length - offset;
}

fn validDevice(device: *Device) bool {
    return device.magic == device_magic;
}

fn validQueue(queue: *CommandQueue) bool {
    return queue.magic == queue_magic and validDevice(queue.device);
}

fn validCommandBuffer(command_buffer: *CommandBuffer) bool {
    return command_buffer.magic == command_buffer_magic and validQueue(command_buffer.queue);
}

fn validBuffer(buffer: *Buffer) bool {
    return buffer.magic == buffer_magic and validDevice(buffer.device);
}

fn validSparsePageBytes(page_bytes: usize) bool {
    return page_bytes == 16 * 1024 or page_bytes == 64 * 1024 or page_bytes == 256 * 1024;
}

fn sparsePageCount(buffer: *const Buffer) ?usize {
    if (buffer.sparse_page_bytes == 0 or !validSparsePageBytes(buffer.sparse_page_bytes) or
        buffer.bytes.len > std.math.maxInt(usize) - (buffer.sparse_page_bytes - 1)) return null;
    return (buffer.bytes.len + buffer.sparse_page_bytes - 1) / buffer.sparse_page_bytes;
}

fn sparseRangeValid(buffer: *const Buffer, offset: usize, length: usize) bool {
    const page_count = sparsePageCount(buffer) orelse return false;
    if (offset % buffer.sparse_page_bytes != 0 or length % buffer.sparse_page_bytes != 0 or
        offset > buffer.bytes.len or length > buffer.bytes.len - offset) return false;
    const first_page = offset / buffer.sparse_page_bytes;
    const page_length = length / buffer.sparse_page_bytes;
    return first_page <= page_count and page_length <= page_count - first_page;
}

fn sparseMappingIndex(buffer: *const Buffer, page_index: usize) ?usize {
    for (buffer.sparse_mappings.items, 0..) |mapping, index| {
        if (mapping.page_index == page_index) return index;
    }
    return null;
}

fn sparseSyncBuffer(buffer: *Buffer) void {
    if (buffer.sparse_page_bytes == 0) return;
    @memset(buffer.bytes, 0);
    for (buffer.sparse_mappings.items) |mapping| {
        const offset = mapping.page_index * buffer.sparse_page_bytes;
        if (offset >= buffer.bytes.len) continue;
        const length = @min(buffer.sparse_page_bytes, buffer.bytes.len - offset);
        @memcpy(buffer.bytes[offset .. offset + length], mapping.page.bytes[0..length]);
    }
}

fn sparseFlushBuffer(buffer: *Buffer) void {
    if (buffer.sparse_page_bytes == 0) return;
    for (buffer.sparse_mappings.items) |mapping| {
        const offset = mapping.page_index * buffer.sparse_page_bytes;
        if (offset >= buffer.bytes.len) continue;
        const length = @min(buffer.sparse_page_bytes, buffer.bytes.len - offset);
        @memcpy(mapping.page.bytes[0..length], buffer.bytes[offset .. offset + length]);
        if (length < mapping.page.bytes.len) @memset(mapping.page.bytes[length..], 0);
    }
}

fn sparseSyncOptionalBuffer(buffer: ?*Buffer) void {
    if (buffer) |value| if (validBuffer(value)) sparseSyncBuffer(value);
}

fn sparseFlushOptionalBuffer(buffer: ?*Buffer) void {
    if (buffer) |value| if (validBuffer(value)) sparseFlushBuffer(value);
}

fn sparseSyncOptionalTexture(texture: ?*Texture) void {
    if (texture) |value| if (validTexture(value)) sparseSyncTexture(value);
}

fn sparseFlushOptionalTexture(texture: ?*Texture) void {
    if (texture) |value| if (validTexture(value)) sparseFlushTexture(value);
}

fn sparseUpdateBufferMapping(buffer: *Buffer, mode: u8, offset: usize, length: usize) Error!void {
    if (!validBuffer(buffer) or buffer.sparse_page_bytes == 0 or !sparseRangeValid(buffer, offset, length)) return error.InvalidArgument;
    if (mode != 0 and mode != 1) return error.InvalidArgument;
    sparseFlushBuffer(buffer);
    const first_page = offset / buffer.sparse_page_bytes;
    const page_length = length / buffer.sparse_page_bytes;
    for (0..page_length) |index| {
        const page_index = first_page + index;
        const existing = sparseMappingIndex(buffer, page_index);
        if (mode == 0) {
            if (existing == null) {
                const page = try SparsePage.create(buffer.sparse_page_bytes);
                buffer.sparse_mappings.append(allocator, .{ .page_index = page_index, .page = page }) catch |err| {
                    page.release();
                    return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArgument;
                };
            }
        } else if (existing) |mapping_index| {
            const removed = buffer.sparse_mappings.orderedRemove(mapping_index);
            removed.page.release();
        }
    }
    sparseSyncBuffer(buffer);
}

fn sparseCopyBufferMappings(source: *Buffer, destination: *Buffer, source_offset: usize, destination_offset: usize, length: usize) Error!void {
    if (!validBuffer(source) or !validBuffer(destination) or source.device != destination.device or
        source.sparse_page_bytes == 0 or source.sparse_page_bytes != destination.sparse_page_bytes or
        !sparseRangeValid(source, source_offset, length) or !sparseRangeValid(destination, destination_offset, length)) return error.InvalidArgument;
    sparseFlushBuffer(source);
    sparseFlushBuffer(destination);
    const page_length = length / source.sparse_page_bytes;
    const source_first = source_offset / source.sparse_page_bytes;
    const destination_first = destination_offset / destination.sparse_page_bytes;
    const pages = allocator.alloc(?*SparsePage, page_length) catch return error.OutOfMemory;
    defer {
        for (pages) |page| if (page) |value| value.release();
        allocator.free(pages);
    }
    for (0..page_length) |index| {
        pages[index] = if (sparseMappingIndex(source, source_first + index)) |mapping_index| blk: {
            const page = source.sparse_mappings.items[mapping_index].page;
            page.retain();
            break :blk page;
        } else null;
    }
    for (0..page_length) |index| {
        const destination_page = destination_first + index;
        if (sparseMappingIndex(destination, destination_page)) |mapping_index| {
            const removed = destination.sparse_mappings.orderedRemove(mapping_index);
            removed.page.release();
        }
        if (pages[index]) |page| {
            destination.sparse_mappings.append(allocator, .{ .page_index = destination_page, .page = page }) catch |err| {
                page.release();
                pages[index] = null;
                return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidArgument;
            };
            pages[index] = null;
        }
    }
    sparseSyncBuffer(destination);
}

fn sparseTextureTileDimensions(format: TextureFormat, page_bytes: usize) ?struct { width: usize, height: usize } {
    return switch (format) {
        .rgba8_unorm, .bgra8_unorm, .r32_float => switch (page_bytes) {
            16 * 1024 => .{ .width = 64, .height = 64 },
            64 * 1024 => .{ .width = 128, .height = 128 },
            256 * 1024 => .{ .width = 256, .height = 256 },
            else => null,
        },
        .rgba16_float => switch (page_bytes) {
            16 * 1024 => .{ .width = 64, .height = 32 },
            64 * 1024 => .{ .width = 128, .height = 64 },
            256 * 1024 => .{ .width = 256, .height = 128 },
            else => null,
        },
        else => null,
    };
}

fn sparseTextureMappingIndex(texture: *const Texture, tile_x: usize, tile_y: usize) ?usize {
    for (texture.sparse_mappings.items, 0..) |mapping, index| {
        if (mapping.tile_x == tile_x and mapping.tile_y == tile_y) return index;
    }
    return null;
}

fn sparseTextureRangeValid(texture: *const Texture, region: abi.Region) bool {
    if (texture.sparse_page_bytes == 0 or texture.sparse_tile_width == 0 or
        texture.sparse_tile_height == 0 or region.origin.z != 0 or region.size.depth != 1)
        return false;
    if (texture.width > std.math.maxInt(usize) - (texture.sparse_tile_width - 1) or
        texture.height > std.math.maxInt(usize) - (texture.sparse_tile_height - 1)) return false;
    const tile_count_x = (texture.width + texture.sparse_tile_width - 1) / texture.sparse_tile_width;
    const tile_count_y = (texture.height + texture.sparse_tile_height - 1) / texture.sparse_tile_height;
    return region.origin.x <= tile_count_x and region.size.width <= tile_count_x - region.origin.x and
        region.origin.y <= tile_count_y and region.size.height <= tile_count_y - region.origin.y;
}

fn sparseSyncTexture(texture: *Texture) void {
    if (texture.sparse_page_bytes == 0) return;
    @memset(texture.bytes, 0);
    const bytes_per_pixel = texture.format.bytesPerPixel();
    for (texture.sparse_mappings.items) |mapping| {
        const pixel_x = mapping.tile_x * texture.sparse_tile_width;
        const pixel_y = mapping.tile_y * texture.sparse_tile_height;
        if (pixel_x >= texture.width or pixel_y >= texture.height) continue;
        const width = @min(texture.sparse_tile_width, texture.width - pixel_x);
        const height = @min(texture.sparse_tile_height, texture.height - pixel_y);
        const row_bytes = width * bytes_per_pixel;
        const source_stride = texture.sparse_tile_width * bytes_per_pixel;
        for (0..height) |row| {
            const destination_offset = (pixel_y + row) * texture.stride + pixel_x * bytes_per_pixel;
            @memcpy(texture.bytes[destination_offset .. destination_offset + row_bytes], mapping.page.bytes[row * source_stride .. row * source_stride + row_bytes]);
        }
    }
}

fn sparseFlushTexture(texture: *Texture) void {
    if (texture.sparse_page_bytes == 0) return;
    const bytes_per_pixel = texture.format.bytesPerPixel();
    for (texture.sparse_mappings.items) |mapping| {
        const pixel_x = mapping.tile_x * texture.sparse_tile_width;
        const pixel_y = mapping.tile_y * texture.sparse_tile_height;
        if (pixel_x >= texture.width or pixel_y >= texture.height) continue;
        const width = @min(texture.sparse_tile_width, texture.width - pixel_x);
        const height = @min(texture.sparse_tile_height, texture.height - pixel_y);
        const row_bytes = width * bytes_per_pixel;
        const source_stride = texture.sparse_tile_width * bytes_per_pixel;
        @memset(mapping.page.bytes, 0);
        for (0..height) |row| {
            const source_offset = (pixel_y + row) * texture.stride + pixel_x * bytes_per_pixel;
            @memcpy(mapping.page.bytes[row * source_stride .. row * source_stride + row_bytes], texture.bytes[source_offset .. source_offset + row_bytes]);
        }
    }
}

fn sparseUpdateTextureMapping(texture: *Texture, mode: u8, region: abi.Region) Error!void {
    if (!validTexture(texture) or !sparseTextureRangeValid(texture, region) or (mode != 0 and mode != 1)) return error.InvalidArgument;
    sparseFlushTexture(texture);
    for (0..region.size.height) |row| {
        for (0..region.size.width) |column| {
            const tile_x = @as(usize, region.origin.x) + column;
            const tile_y = @as(usize, region.origin.y) + row;
            const mapping_index = sparseTextureMappingIndex(texture, tile_x, tile_y);
            if (mode == 0) {
                if (mapping_index == null) {
                    const page = try SparsePage.create(texture.sparse_page_bytes);
                    texture.sparse_mappings.append(allocator, .{ .tile_x = tile_x, .tile_y = tile_y, .page = page }) catch {
                        page.release();
                        return error.OutOfMemory;
                    };
                }
            } else if (mapping_index) |index| {
                const removed = texture.sparse_mappings.orderedRemove(index);
                removed.page.release();
            }
        }
    }
    sparseSyncTexture(texture);
}

fn sparseCopyTextureMappings(source: *Texture, destination: *Texture, source_region: abi.Region, destination_origin: abi.Origin) Error!void {
    const destination_region = abi.Region{ .origin = destination_origin, .size = source_region.size };
    if (!validTexture(source) or !validTexture(destination) or source.device != destination.device or
        source.format != destination.format or
        source.sparse_page_bytes == 0 or source.sparse_page_bytes != destination.sparse_page_bytes or
        source.sparse_tile_width != destination.sparse_tile_width or source.sparse_tile_height != destination.sparse_tile_height or
        !sparseTextureRangeValid(source, source_region) or !sparseTextureRangeValid(destination, destination_region)) return error.InvalidArgument;
    sparseFlushTexture(source);
    sparseFlushTexture(destination);
    const page_count = std.math.mul(usize, @as(usize, source_region.size.width), source_region.size.height) catch return error.InvalidArgument;
    const pages = allocator.alloc(?*SparsePage, page_count) catch return error.OutOfMemory;
    defer {
        for (pages) |page| if (page) |value| value.release();
        allocator.free(pages);
    }
    var page_index: usize = 0;
    for (0..source_region.size.height) |row| {
        for (0..source_region.size.width) |column| {
            const tile_x = @as(usize, source_region.origin.x) + column;
            const tile_y = @as(usize, source_region.origin.y) + row;
            pages[page_index] = if (sparseTextureMappingIndex(source, tile_x, tile_y)) |mapping_index| blk: {
                const page = source.sparse_mappings.items[mapping_index].page;
                page.retain();
                break :blk page;
            } else null;
            page_index += 1;
        }
    }
    page_index = 0;
    for (0..destination_region.size.height) |row| {
        for (0..destination_region.size.width) |column| {
            const tile_x = @as(usize, destination_region.origin.x) + column;
            const tile_y = @as(usize, destination_region.origin.y) + row;
            if (sparseTextureMappingIndex(destination, tile_x, tile_y)) |mapping_index| {
                const removed = destination.sparse_mappings.orderedRemove(mapping_index);
                removed.page.release();
            }
            if (pages[page_index]) |page| {
                destination.sparse_mappings.append(allocator, .{ .tile_x = tile_x, .tile_y = tile_y, .page = page }) catch {
                    page.release();
                    pages[page_index] = null;
                    return error.OutOfMemory;
                };
                pages[page_index] = null;
            }
            page_index += 1;
        }
    }
    sparseSyncTexture(destination);
}

fn sparseUpdateTextureMappingIndirect(texture: *Texture, mode: u8, buffer: *Buffer, buffer_offset: usize) Error!void {
    if (!validTexture(texture) or !validBuffer(buffer) or texture.device != buffer.device or
        buffer.sparse_page_bytes != 0 or texture.sparse_page_bytes == 0 or
        (mode != 0 and mode != 1) or buffer_offset % @alignOf(u32) != 0 or
        !rangeValid(buffer.bytes.len, buffer_offset, @sizeOf(u32)))
        return error.InvalidArgument;
    sparseSyncBuffer(buffer);
    const mapping_count = readU32Little(buffer.bytes, buffer_offset);
    const arguments_offset = std.math.add(usize, buffer_offset, @sizeOf(u32)) catch return error.InvalidArgument;
    const arguments_bytes = std.math.mul(usize, @as(usize, mapping_count), @sizeOf(abi.SparseTextureMappingArguments)) catch
        return error.InvalidArgument;
    if (!rangeValid(buffer.bytes.len, arguments_offset, arguments_bytes)) return error.InvalidArgument;
    for (0..mapping_count) |index| {
        const offset = arguments_offset + index * @sizeOf(abi.SparseTextureMappingArguments);
        const region = abi.Region{
            .origin = .{
                .x = readU32Little(buffer.bytes, offset),
                .y = readU32Little(buffer.bytes, offset + 4),
                .z = readU32Little(buffer.bytes, offset + 8),
            },
            .size = .{
                .width = readU32Little(buffer.bytes, offset + 12),
                .height = readU32Little(buffer.bytes, offset + 16),
                .depth = readU32Little(buffer.bytes, offset + 20),
            },
        };
        if (readU32Little(buffer.bytes, offset + 24) != 0 or
            readU32Little(buffer.bytes, offset + 28) != 0 or
            !sparseTextureRangeValid(texture, region)) return error.InvalidArgument;
    }
    for (0..mapping_count) |index| {
        const offset = arguments_offset + index * @sizeOf(abi.SparseTextureMappingArguments);
        const region = abi.Region{
            .origin = .{
                .x = readU32Little(buffer.bytes, offset),
                .y = readU32Little(buffer.bytes, offset + 4),
                .z = readU32Little(buffer.bytes, offset + 8),
            },
            .size = .{
                .width = readU32Little(buffer.bytes, offset + 12),
                .height = readU32Little(buffer.bytes, offset + 16),
                .depth = readU32Little(buffer.bytes, offset + 20),
            },
        };
        try sparseUpdateTextureMapping(texture, mode, region);
    }
}

fn sparseMoveTextureMappings(source: *Texture, destination: *Texture, source_region: abi.Region, destination_origin: abi.Origin) Error!void {
    const destination_region = abi.Region{ .origin = destination_origin, .size = source_region.size };
    if (!validTexture(source) or !validTexture(destination) or source.device != destination.device or
        source.format != destination.format or source.sparse_page_bytes == 0 or
        source.sparse_page_bytes != destination.sparse_page_bytes or
        source.sparse_tile_width != destination.sparse_tile_width or
        source.sparse_tile_height != destination.sparse_tile_height or
        !sparseTextureRangeValid(source, source_region) or
        !sparseTextureRangeValid(destination, destination_region)) return error.InvalidArgument;
    sparseFlushTexture(source);
    sparseFlushTexture(destination);
    const page_count = std.math.mul(usize, @as(usize, source_region.size.width), source_region.size.height) catch return error.InvalidArgument;
    const pages = allocator.alloc(?*SparsePage, page_count) catch return error.OutOfMemory;
    defer {
        for (pages) |page| if (page) |value| value.release();
        allocator.free(pages);
    }
    const destination_mapped = allocator.alloc(bool, page_count) catch {
        allocator.free(pages);
        return error.OutOfMemory;
    };
    defer allocator.free(destination_mapped);
    var page_index: usize = 0;
    var move_count: usize = 0;
    for (0..source_region.size.height) |row| {
        for (0..source_region.size.width) |column| {
            const source_x = @as(usize, source_region.origin.x) + column;
            const source_y = @as(usize, source_region.origin.y) + row;
            const destination_x = @as(usize, destination_origin.x) + column;
            const destination_y = @as(usize, destination_origin.y) + row;
            pages[page_index] = if (sparseTextureMappingIndex(source, source_x, source_y)) |mapping_index| blk: {
                const page = source.sparse_mappings.items[mapping_index].page;
                page.retain();
                break :blk page;
            } else null;
            destination_mapped[page_index] = sparseTextureMappingIndex(destination, destination_x, destination_y) != null;
            if (pages[page_index] != null and !destination_mapped[page_index]) move_count += 1;
            page_index += 1;
        }
    }
    destination.sparse_mappings.ensureUnusedCapacity(allocator, move_count) catch return error.OutOfMemory;
    page_index = 0;
    for (0..source_region.size.height) |row| {
        for (0..source_region.size.width) |column| {
            if (pages[page_index] != null and !destination_mapped[page_index]) {
                const source_x = @as(usize, source_region.origin.x) + column;
                const source_y = @as(usize, source_region.origin.y) + row;
                if (sparseTextureMappingIndex(source, source_x, source_y)) |mapping_index| {
                    const removed = source.sparse_mappings.orderedRemove(mapping_index);
                    removed.page.release();
                }
            }
            page_index += 1;
        }
    }
    page_index = 0;
    for (0..destination_region.size.height) |row| {
        for (0..destination_region.size.width) |column| {
            if (pages[page_index]) |page| {
                if (!destination_mapped[page_index]) {
                    destination.sparse_mappings.appendAssumeCapacity(.{
                        .tile_x = @as(usize, destination_region.origin.x) + column,
                        .tile_y = @as(usize, destination_region.origin.y) + row,
                        .page = page,
                    });
                    pages[page_index] = null;
                }
            }
            page_index += 1;
        }
    }
    sparseSyncTexture(source);
    sparseSyncTexture(destination);
}

fn validTexture(texture: *Texture) bool {
    return texture.magic == texture_magic and validDevice(texture.device);
}

fn resolveMultisampleTargets(sample_targets: [4]?*Texture, sample_count: usize, resolve_target: *Texture) Error!void {
    if ((sample_count != 2 and sample_count != 4) or !validTexture(resolve_target)) return error.InvalidArgument;
    var samples: [4]raster3d.Target = undefined;
    for (sample_targets[0..sample_count], 0..) |sample, index| {
        const texture = sample orelse return error.InvalidResource;
        if (!validTexture(texture) or texture.device != resolve_target.device or
            texture.width != resolve_target.width or texture.height != resolve_target.height or
            texture.format != resolve_target.format) return error.InvalidResource;
        samples[index] = texture.asTarget();
    }
    var destination = resolve_target.asTarget();
    for (0..destination.height) |y| {
        for (0..destination.width) |x| {
            var color = [4]f32{ 0, 0, 0, 0 };
            for (samples[0..sample_count]) |sample| {
                const value = sample.readColor(x, y);
                for (0..4) |channel| color[channel] += value[channel];
            }
            const divisor: f32 = @floatFromInt(sample_count);
            for (0..4) |channel| color[channel] /= divisor;
            destination.storeResolvedColor(x, y, color);
        }
    }
}

fn resolveMultisampleColorAttachments(
    primary_sample_targets: [4]?*Texture,
    sample_color_attachments: [32]?*Texture,
    sample_count: usize,
    resolve_targets: [8]?*Texture,
) Error!void {
    for (resolve_targets, 0..) |resolve, index| {
        const target = resolve orelse continue;
        var samples: [4]?*Texture = [_]?*Texture{null} ** 4;
        if (index == 0) {
            samples = primary_sample_targets;
        } else {
            for (0..sample_count) |sample_index| {
                samples[sample_index] = sample_color_attachments[index * 4 + sample_index];
            }
        }
        sparseSyncTexture(target);
        resolveMultisampleTargets(samples, sample_count, target) catch |err| return err;
        sparseFlushTexture(target);
    }
}

fn resolveMultisampleColorAttachmentArrays(
    sample_color_attachments: [8][8][4]?*Texture,
    array_count: usize,
    sample_count: usize,
    resolve_targets: [8][8]?*Texture,
) Error!void {
    for (0..8) |attachment_index| {
        for (0..array_count) |layer| {
            const target = resolve_targets[attachment_index][layer] orelse continue;
            var samples: [4]?*Texture = [_]?*Texture{null} ** 4;
            for (0..sample_count) |sample_index| {
                samples[sample_index] = sample_color_attachments[attachment_index][layer][sample_index];
            }
            sparseSyncTexture(target);
            resolveMultisampleTargets(samples, sample_count, target) catch |err| return err;
            sparseFlushTexture(target);
        }
    }
}

fn validFence(fence: *Fence) bool {
    return fence.magic == fence_magic and validDevice(fence.device);
}

fn validSharedEvent(event: *SharedEvent) bool {
    return event.magic == shared_event_magic and validDevice(event.device);
}

fn validHeap(heap: *const Heap) bool {
    return heap.magic == heap_magic and validDevice(heap.device);
}

fn finitePreciseViewport(viewport: raster3d.PreciseViewport) bool {
    return std.math.isFinite(viewport.origin_x) and std.math.isFinite(viewport.origin_y) and
        std.math.isFinite(viewport.width) and std.math.isFinite(viewport.height) and
        std.math.isFinite(viewport.znear) and std.math.isFinite(viewport.zfar) and
        viewport.width >= 0 and viewport.height >= 0;
}

fn quantizeMetalSamplePosition(value: f32) f32 {
    return @round(value * 16.0) / 16.0;
}

fn validMetalSamplePosition(value: f32) bool {
    return std.math.isFinite(value) and value >= 0 and value < 1;
}

fn validMetalSamplePositionCount(count: usize) bool {
    return count == 0 or count == 2 or count == 4;
}

fn validPass(pass: abi.RenderPassDescriptor) bool {
    return @intFromEnum(pass.color.load_action) <= @intFromEnum(abi.LoadAction.clear) and
        @intFromEnum(pass.color.store_action) <= @intFromEnum(abi.StoreAction.store) and
        @intFromEnum(pass.depth.load_action) <= @intFromEnum(abi.LoadAction.clear) and
        @intFromEnum(pass.depth.store_action) <= @intFromEnum(abi.StoreAction.store) and
        std.math.isFinite(pass.depth.clear_depth);
}

test "Apple programmable sample positions use a 1/16 top-left pixel grid" {
    try std.testing.expectEqual(@as(f32, 0.125), quantizeMetalSamplePosition(0.13));
    try std.testing.expectEqual(@as(f32, 0.8125), quantizeMetalSamplePosition(0.79));
    try std.testing.expectEqual(@as(f32, 0.1875), quantizeMetalSamplePosition(0.21));
    try std.testing.expectEqual(@as(f32, 0.6875), quantizeMetalSamplePosition(0.69));
}

test "Apple custom sample positions use supported counts and a half-open pixel cell" {
    try std.testing.expect(validMetalSamplePositionCount(0));
    try std.testing.expect(validMetalSamplePositionCount(2));
    try std.testing.expect(validMetalSamplePositionCount(4));
    try std.testing.expect(!validMetalSamplePositionCount(1));
    try std.testing.expect(!validMetalSamplePositionCount(3));
    try std.testing.expect(!validMetalSamplePositionCount(5));
    try std.testing.expect(!validMetalSamplePosition(std.math.nan(f32)));
    try std.testing.expect(validMetalSamplePosition(0));
    try std.testing.expect(validMetalSamplePosition(0.999));
    try std.testing.expect(!validMetalSamplePosition(1));
    try std.testing.expect(!validMetalSamplePosition(-0.001));
}

fn validPrimitive(primitive: abi.PrimitiveType) bool {
    return @intFromEnum(primitive) <= @intFromEnum(abi.PrimitiveType.triangle_strip);
}

fn validIndexType(index_type: abi.IndexType) bool {
    return @intFromEnum(index_type) <= @intFromEnum(abi.IndexType.uint32);
}

fn validCullMode(cull_mode: abi.CullMode) bool {
    return @intFromEnum(cull_mode) <= @intFromEnum(abi.CullMode.back);
}

fn validWinding(winding: abi.Winding) bool {
    return @intFromEnum(winding) <= @intFromEnum(abi.Winding.counter_clockwise);
}

fn validFillMode(fill_mode: abi.TriangleFillMode) bool {
    return @intFromEnum(fill_mode) <= @intFromEnum(abi.TriangleFillMode.lines);
}

fn blendFactorFromInt(value: u8) ?abi.BlendFactor {
    return switch (value) {
        0 => .zero,
        1 => .one,
        2 => .source_color,
        3 => .one_minus_source_color,
        4 => .source_alpha,
        5 => .one_minus_source_alpha,
        6 => .destination_color,
        7 => .one_minus_destination_color,
        8 => .destination_alpha,
        9 => .one_minus_destination_alpha,
        10 => .source_alpha_saturated,
        11 => .blend_color,
        12 => .one_minus_blend_color,
        13 => .blend_alpha,
        14 => .one_minus_blend_alpha,
        else => null,
    };
}

fn blendOperationFromInt(value: u8) ?abi.BlendOperation {
    return switch (value) {
        0 => .add,
        1 => .subtract,
        2 => .reverse_subtract,
        3 => .min,
        4 => .max,
        else => null,
    };
}

fn samplerFilterFromInt(value: u8) ?abi.SamplerFilter {
    return switch (value) {
        @intFromEnum(abi.SamplerFilter.nearest) => .nearest,
        @intFromEnum(abi.SamplerFilter.linear) => .linear,
        else => null,
    };
}

fn samplerMipFilterFromInt(value: u8) ?abi.SamplerMipFilter {
    return switch (value) {
        @intFromEnum(abi.SamplerMipFilter.not_mipmapped) => .not_mipmapped,
        @intFromEnum(abi.SamplerMipFilter.nearest) => .nearest,
        @intFromEnum(abi.SamplerMipFilter.linear) => .linear,
        else => null,
    };
}

fn samplerReductionModeFromInt(value: u8) ?abi.SamplerReductionMode {
    return switch (value) {
        @intFromEnum(abi.SamplerReductionMode.weighted_average) => .weighted_average,
        @intFromEnum(abi.SamplerReductionMode.minimum) => .minimum,
        @intFromEnum(abi.SamplerReductionMode.maximum) => .maximum,
        else => null,
    };
}

fn samplerAddressModeFromInt(value: u8) ?abi.SamplerAddressMode {
    return switch (value) {
        @intFromEnum(abi.SamplerAddressMode.clamp_to_edge) => .clamp_to_edge,
        @intFromEnum(abi.SamplerAddressMode.mirror_clamp_to_edge) => .mirror_clamp_to_edge,
        @intFromEnum(abi.SamplerAddressMode.mirror_repeat) => .mirror_repeat,
        @intFromEnum(abi.SamplerAddressMode.repeat) => .repeat,
        @intFromEnum(abi.SamplerAddressMode.clamp_to_zero) => .clamp_to_zero,
        @intFromEnum(abi.SamplerAddressMode.clamp_to_border_color) => .clamp_to_border_color,
        else => null,
    };
}

fn samplerBorderColorFromInt(value: u8) ?abi.SamplerBorderColor {
    return switch (value) {
        @intFromEnum(abi.SamplerBorderColor.transparent_black) => .transparent_black,
        @intFromEnum(abi.SamplerBorderColor.opaque_black) => .opaque_black,
        @intFromEnum(abi.SamplerBorderColor.opaque_white) => .opaque_white,
        else => null,
    };
}

fn textureSwizzleFromInt(value: u8) ?abi.TextureSwizzle {
    return switch (value) {
        @intFromEnum(abi.TextureSwizzle.zero) => .zero,
        @intFromEnum(abi.TextureSwizzle.one) => .one,
        @intFromEnum(abi.TextureSwizzle.red) => .red,
        @intFromEnum(abi.TextureSwizzle.green) => .green,
        @intFromEnum(abi.TextureSwizzle.blue) => .blue,
        @intFromEnum(abi.TextureSwizzle.alpha) => .alpha,
        else => null,
    };
}

fn toTargetColor(color: abi.Color) [4]f32 {
    return .{ color.red, color.green, color.blue, color.alpha };
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255.0);
}

test "resource bytes and ordered blit command buffer are deterministic" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source = try createBuffer(device, 16, null);
    defer destroyBuffer(source);
    const destination = try createBuffer(device, 16, null);
    defer destroyBuffer(destination);
    const values = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8 };
    try bufferWrite(source, 2, &values, values.len);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.fillBuffer(destination, 0, 16, 0xee);
    try encoder.copyBuffer(source, 2, destination, 4, values.len);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xee, 0xee, 0xee, 0xee, 1, 2, 3, 4, 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee }, destination.bytes);
}

test "CPU blit mipmap generation is deferred and deterministic" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(source);
    const destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(destination);
    const block_values = [_]u8{ 17, 53, 101, 197 };
    for (0..4) |y| {
        for (0..4) |x| {
            const value = block_values[(y / 2) * 2 + x / 2];
            const offset = y * source.stride + x * 4;
            source.bytes[offset + 0] = value;
            source.bytes[offset + 1] = value + 1;
            source.bytes[offset + 2] = value + 2;
            source.bytes[offset + 3] = 255;
        }
    }
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.generateMipmap(source, destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), destination.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{
        17,  18,  19,  255, 53,  54,  55,  255,
        101, 102, 103, 255, 197, 198, 199, 255,
    }, destination.bytes);
}

test "CPU sRGB mipmaps average in linear color space" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb));
    defer destroyTexture(source);
    const destination = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb));
    defer destroyTexture(destination);
    source.bytes[0..16].* = .{
        0,   0,   0,   0,
        255, 255, 255, 255,
        0,   255, 255, 128,
        255, 0,   255, 64,
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.generateMipmap(source, destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 188, 188, 225, 112 }, destination.bytes);
}

test "CPU sRGB 3D mipmap arrays average the complete footprint" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source0 = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb));
    defer destroyTexture(source0);
    const source1 = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb));
    defer destroyTexture(source1);
    const destination = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb));
    defer destroyTexture(destination);
    @memset(source0.bytes, 0);
    @memset(source1.bytes, 255);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    const sources = [_]*Texture{ source0, source1 };
    try encoder.generateMipmap3DArray(sources[0..], destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 188, 188, 188, 128 }, destination.bytes);
}

test "CPU float mipmap generation preserves format precision" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const r32_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.r32_float));
    defer destroyTexture(r32_source);
    const r32_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.r32_float));
    defer destroyTexture(r32_destination);
    for (0..4) |y| for (0..4) |x| writeMipmapF32(r32_source.bytes, y * r32_source.stride + x * 4, @floatFromInt(x + y * 4));

    const rgba16_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba16_float));
    defer destroyTexture(rgba16_source);
    const rgba16_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba16_float));
    defer destroyTexture(rgba16_destination);
    for (0..4) |y| for (0..4) |x| {
        const offset = y * rgba16_source.stride + x * 8;
        writeMipmapF16(rgba16_source.bytes, offset, @floatFromInt(x + 1));
        writeMipmapF16(rgba16_source.bytes, offset + 2, @floatFromInt(y + 1));
        writeMipmapF16(rgba16_source.bytes, offset + 4, 0.25);
        writeMipmapF16(rgba16_source.bytes, offset + 6, 1.0);
    };

    const r16_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.r16_float));
    defer destroyTexture(r16_source);
    const r16_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.r16_float));
    defer destroyTexture(r16_destination);
    for (0..4) |y| for (0..4) |x| writeMipmapF16(r16_source.bytes, y * r16_source.stride + x * 2, @floatFromInt(x + y * 4));

    const rg16_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rg16_float));
    defer destroyTexture(rg16_source);
    const rg16_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rg16_float));
    defer destroyTexture(rg16_destination);
    for (0..4) |y| for (0..4) |x| {
        const offset = y * rg16_source.stride + x * 4;
        writeMipmapF16(rg16_source.bytes, offset, @floatFromInt(x + y * 4));
        writeMipmapF16(rg16_source.bytes, offset + 2, @floatFromInt(100 + x + y * 4));
    };

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.generateMipmap(r32_source, r32_destination);
    try encoder.generateMipmap(rgba16_source, rgba16_destination);
    try encoder.generateMipmap(r16_source, r16_destination);
    try encoder.generateMipmap(rg16_source, rg16_destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, r32_destination.bytes[0..4], .little));
    try command_buffer.commit();

    try std.testing.expectApproxEqAbs(@as(f64, 2.5), readMipmapF32(r32_destination.bytes, 0), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), readMipmapF32(r32_destination.bytes, 4), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), readMipmapF32(r32_destination.bytes, r32_destination.stride), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), readMipmapF32(r32_destination.bytes, r32_destination.stride + 4), 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), readMipmapF16(rgba16_destination.bytes, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), readMipmapF16(rgba16_destination.bytes, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), readMipmapF16(rgba16_destination.bytes, 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), readMipmapF16(rgba16_destination.bytes, 6), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), readMipmapF16(r16_destination.bytes, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), readMipmapF16(r16_destination.bytes, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), readMipmapF16(r16_destination.bytes, r16_destination.stride), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), readMipmapF16(r16_destination.bytes, r16_destination.stride + 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), readMipmapF16(rg16_destination.bytes, 0), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 102.5), readMipmapF16(rg16_destination.bytes, 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.5), readMipmapF16(rg16_destination.bytes, 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 104.5), readMipmapF16(rg16_destination.bytes, 6), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), readMipmapF16(rg16_destination.bytes, rg16_destination.stride), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 110.5), readMipmapF16(rg16_destination.bytes, rg16_destination.stride + 2), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 12.5), readMipmapF16(rg16_destination.bytes, rg16_destination.stride + 4), 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 112.5), readMipmapF16(rg16_destination.bytes, rg16_destination.stride + 6), 0.001);
}

test "CPU packed unorm and wide float mipmaps preserve format precision" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const unorm_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(unorm_source);
    const unorm_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(unorm_destination);
    for (0..4) |y| for (0..4) |x| {
        const base = (x + y * 4) * 1000;
        const offset = y * unorm_source.stride + x * 8;
        for (0..4) |component| std.mem.writeInt(u16, unorm_source.bytes[offset + component * 2 ..][0..2], @intCast(base + component * 100), .little);
    };

    const r16_unorm_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.r16_unorm));
    defer destroyTexture(r16_unorm_source);
    const r16_unorm_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.r16_unorm));
    defer destroyTexture(r16_unorm_destination);
    const rg16_unorm_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rg16_unorm));
    defer destroyTexture(rg16_unorm_source);
    const rg16_unorm_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rg16_unorm));
    defer destroyTexture(rg16_unorm_destination);
    for (0..4) |y| for (0..4) |x| {
        const base = (x + y * 4) * 1000;
        std.mem.writeInt(u16, r16_unorm_source.bytes[y * r16_unorm_source.stride + x * 2 ..][0..2], @intCast(base), .little);
        const offset = y * rg16_unorm_source.stride + x * 4;
        std.mem.writeInt(u16, rg16_unorm_source.bytes[offset..][0..2], @intCast(base), .little);
        std.mem.writeInt(u16, rg16_unorm_source.bytes[offset + 2 ..][0..2], @intCast(base + 500), .little);
    };

    const wide_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba32_float));
    defer destroyTexture(wide_source);
    const wide_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba32_float));
    defer destroyTexture(wide_destination);
    for (0..4) |y| for (0..4) |x| {
        const base: f64 = @floatFromInt(x + y * 4);
        const offset = y * wide_source.stride + x * 16;
        for (0..4) |component| writeMipmapF32(wide_source.bytes, offset + component * 4, base + @as(f64, @floatFromInt(component)) * 0.125);
    };

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.generateMipmap(unorm_source, unorm_destination);
    try encoder.generateMipmap(r16_unorm_source, r16_unorm_destination);
    try encoder.generateMipmap(rg16_unorm_source, rg16_unorm_destination);
    try encoder.generateMipmap(wide_source, wide_destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try command_buffer.commit();

    const unorm_bases = [_]u16{ 2500, 4500, 10500, 12500 };
    for (0..4) |pixel| {
        const row = pixel / 2;
        const column = pixel % 2;
        const offset = row * unorm_destination.stride + column * 8;
        for (0..4) |component| {
            const actual = std.mem.readInt(u16, unorm_destination.bytes[offset + component * 2 ..][0..2], .little);
            try std.testing.expectEqual(unorm_bases[pixel] + @as(u16, @intCast(component * 100)), actual);
        }
    }
    for (0..4) |pixel| {
        const row = pixel / 2;
        const column = pixel % 2;
        const r16_offset = row * r16_unorm_destination.stride + column * 2;
        try std.testing.expectEqual(unorm_bases[pixel], std.mem.readInt(u16, r16_unorm_destination.bytes[r16_offset..][0..2], .little));
        const rg16_offset = row * rg16_unorm_destination.stride + column * 4;
        try std.testing.expectEqual(unorm_bases[pixel], std.mem.readInt(u16, rg16_unorm_destination.bytes[rg16_offset..][0..2], .little));
        try std.testing.expectEqual(unorm_bases[pixel] + 500, std.mem.readInt(u16, rg16_unorm_destination.bytes[rg16_offset + 2 ..][0..2], .little));
    }
    const wide_bases = [_]f64{ 2.5, 4.5, 10.5, 12.5 };
    for (0..4) |pixel| {
        const row = pixel / 2;
        const column = pixel % 2;
        const offset = row * wide_destination.stride + column * 16;
        for (0..4) |component| {
            try std.testing.expectApproxEqAbs(wide_bases[pixel] + @as(f64, @floatFromInt(component)) * 0.125, readMipmapF32(wide_destination.bytes, offset + component * 4), 0.00001);
        }
    }
}

test "CPU narrow unorm mipmaps preserve packed channel widths" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const r8_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.r8_unorm));
    defer destroyTexture(r8_source);
    const r8_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.r8_unorm));
    defer destroyTexture(r8_destination);
    for (0..4) |y| {
        for (0..4) |x| {
            r8_source.bytes[y * r8_source.stride + x] = @intCast(x + y * 4);
        }
    }

    const rg8_source = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rg8_unorm));
    defer destroyTexture(rg8_source);
    const rg8_destination = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rg8_unorm));
    defer destroyTexture(rg8_destination);
    for (0..4) |y| {
        for (0..4) |x| {
            const offset = y * rg8_source.stride + x * 2;
            rg8_source.bytes[offset] = @intCast(x + y * 4);
            rg8_source.bytes[offset + 1] = @intCast(100 + x + y * 4);
        }
    }

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginBlit(command_buffer);
    try encoder.generateMipmap(r8_source, r8_destination);
    try encoder.generateMipmap(rg8_source, rg8_destination);
    try encoder.endEncoding();
    destroyBlitEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), r8_destination.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 5, 11, 13 }, r8_destination.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 3, 103, 5, 105, 11, 111, 13, 113 }, rg8_destination.bytes);
}

test "CPU compute is deferred, bounded, and pixel deterministic" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const extra_buffer = try createBuffer(device, 64, null);
    defer destroyBuffer(extra_buffer);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(1);
    try encoder.setBuffer(extra_buffer, 8, 1);
    try encoder.setBufferOffset(16, 1);
    try encoder.setTexture(texture, 0);
    try encoder.dispatchThreads(.{ .width = 4, .height = 3, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), texture.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, texture.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 128, 96, 64, 255 }, texture.bytes[2 * texture.stride + 3 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, texture.bytes[3 * texture.stride ..][0..4]);
    try std.testing.expectError(error.InvalidCommand, beginCompute(command_buffer));
}

test "CPU buffer add compute is deferred and slot-accurate" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const left_values = [_]f32{ 99.0, 1.25, -2.5, 3.0, 4.5, 8.0, -16.0 };
    const right_values = [_]f32{ 77.0, 2.5, 0.5, -1.0, 1.5, -3.0, 4.0 };
    var output_values = [_]f32{ 123.0, 456.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const left = try createBuffer(device, @sizeOf(@TypeOf(left_values)), @ptrCast(&left_values));
    defer destroyBuffer(left);
    const right = try createBuffer(device, @sizeOf(@TypeOf(right_values)), @ptrCast(&right_values));
    defer destroyBuffer(right);
    const output = try createBuffer(device, @sizeOf(@TypeOf(output_values)), @ptrCast(&output_values));
    defer destroyBuffer(output);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(8);
    try encoder.setBuffer(left, @sizeOf(f32), 0);
    try encoder.setBuffer(right, @sizeOf(f32), 1);
    try encoder.setBuffer(output, 2 * @sizeOf(f32), 2);
    try encoder.dispatchThreads(.{ .width = 6, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(f32, 0.0), readF32Little(output.bytes, 2 * @sizeOf(f32)));
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    const expected = [_]f32{ 3.75, -2.0, 2.0, 6.0, 5.0, -12.0 };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, readF32Little(output.bytes, (index + 2) * @sizeOf(f32)));
    }
    try std.testing.expectEqual(@as(f32, 123.0), readF32Little(output.bytes, 0));
    try std.testing.expectEqual(@as(f32, 456.0), readF32Little(output.bytes, @sizeOf(f32)));

    @memset(output.bytes[2 * @sizeOf(f32) ..], 0);
    const indirect_groups = abi.Size{ .width = 3, .height = 1, .depth = 1 };
    const indirect = try createBuffer(device, @sizeOf(@TypeOf(indirect_groups)), @ptrCast(&indirect_groups));
    defer destroyBuffer(indirect);
    var indirect_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(indirect_command_buffer);
    var indirect_encoder = try beginCompute(indirect_command_buffer);
    try indirect_encoder.setKernel(8);
    try indirect_encoder.setBuffer(left, @sizeOf(f32), 0);
    try indirect_encoder.setBuffer(right, @sizeOf(f32), 1);
    try indirect_encoder.setBuffer(output, 2 * @sizeOf(f32), 2);
    try indirect_encoder.dispatchThreadgroupsIndirect(indirect, 0, .{ .width = 2, .height = 1, .depth = 1 });
    try indirect_encoder.endEncoding();
    destroyComputeEncoder(indirect_encoder);
    try std.testing.expectEqual(@as(f32, 0.0), readF32Little(output.bytes, 2 * @sizeOf(f32)));
    try indirect_command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, indirect_command_buffer.status);
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, readF32Little(output.bytes, (index + 2) * @sizeOf(f32)));
    }
}

test "CPU buffer multiply compute is deferred and slot-accurate" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const left_values = [_]f32{ 99.0, -3.5, -2.0, -0.5, 0.0, 1.25, 2.0 };
    const right_values = [_]f32{ 77.0, 2.0, -0.5, 4.0, 9.0, 2.0, -1.0 };
    var output_values = [_]f32{ 123.0, 456.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0 };
    const left = try createBuffer(device, @sizeOf(@TypeOf(left_values)), @ptrCast(&left_values));
    defer destroyBuffer(left);
    const right = try createBuffer(device, @sizeOf(@TypeOf(right_values)), @ptrCast(&right_values));
    defer destroyBuffer(right);
    const output = try createBuffer(device, @sizeOf(@TypeOf(output_values)), @ptrCast(&output_values));
    defer destroyBuffer(output);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(9);
    try encoder.setBuffer(left, @sizeOf(f32), 0);
    try encoder.setBuffer(right, @sizeOf(f32), 1);
    try encoder.setBuffer(output, 2 * @sizeOf(f32), 2);
    try encoder.dispatchThreads(.{ .width = 6, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(f32, 0.0), readF32Little(output.bytes, 2 * @sizeOf(f32)));
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    const expected = [_]f32{ -7.0, 1.0, -2.0, 0.0, 2.5, -2.0 };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqual(value, readF32Little(output.bytes, (index + 2) * @sizeOf(f32)));
    }
    try std.testing.expectEqual(@as(f32, 123.0), readF32Little(output.bytes, 0));
    try std.testing.expectEqual(@as(f32, 456.0), readF32Little(output.bytes, @sizeOf(f32)));
}

test "CPU texture copy compute preserves the top-left pixel grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);

    const source = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(source);
    const destination = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(destination);
    @memset(destination.bytes, 0xa5);
    for (0..source.height) |y| for (0..source.width) |x| {
        const offset = y * source.stride + x * 4;
        source.bytes[offset + 0] = @intCast(10 + x);
        source.bytes[offset + 1] = @intCast(40 + y);
        source.bytes[offset + 2] = @intCast(80 + x + y * source.width);
        source.bytes[offset + 3] = 255;
    };

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(31);
    try encoder.setTexture(source, 0);
    try encoder.setTexture(destination, 1);
    try encoder.dispatchThreads(.{ .width = 7, .height = 4, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0xa5), destination.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);

    for (0..source.height) |y| for (0..source.width) |x| {
        const source_offset = y * source.stride + x * 4;
        const destination_offset = y * destination.stride + x * 4;
        try std.testing.expectEqualSlices(u8, source.bytes[source_offset..][0..4], destination.bytes[destination_offset..][0..4]);
    };
}

test "CPU triangle trace uses the Metal top-left pixel grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 7, 5, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const acceleration_structure = try createBuffer(device, 512, null);
    defer destroyBuffer(acceleration_structure);

    writeU32Little(acceleration_structure.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(acceleration_structure.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(acceleration_structure.bytes, 8, 1);
    writeU32Little(acceleration_structure.bytes, 12, 1);
    writeU32Little(acceleration_structure.bytes, 16, cpu_acceleration_structure_header_bytes);
    const vertices = [_]f32{
        -0.80, -0.65, 0.0,
        0.80,  -0.65, 0.0,
        -0.05, 0.65,  0.0,
    };
    for (vertices, 0..) |value, index| {
        std.mem.writeInt(u32, acceleration_structure.bytes[cpu_acceleration_structure_header_bytes + index * 4 ..][0..4], @bitCast(value), .little);
    }

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(7);
    try encoder.setTexture(texture, 0);
    try encoder.setAccelerationStructure(acceleration_structure, 0);
    try encoder.dispatchThreads(.{ .width = 7, .height = 5, .depth = 1 }, .{ .width = 7, .height = 5, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), texture.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);

    // Row zero is the upper edge. This triangle misses it, intersects the
    // upper interior row, and also intersects a lower interior row.
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, texture.bytes[(0 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, texture.bytes[(1 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, texture.bytes[(3 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, texture.bytes[(4 * texture.stride + 3 * 4)..][0..4]);
}

test "CPU triangle intersection profile rejects candidates" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 7, 5, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const acceleration_structure = try createBuffer(device, 512, null);
    defer destroyBuffer(acceleration_structure);
    writeU32Little(acceleration_structure.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(acceleration_structure.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(acceleration_structure.bytes, 8, 1);
    writeU32Little(acceleration_structure.bytes, 12, 1);
    writeU32Little(acceleration_structure.bytes, 16, cpu_acceleration_structure_header_bytes);
    const vertices = [_]f32{
        -0.80, -0.65, 0.0,
        0.80,  -0.65, 0.0,
        -0.05, 0.65,  0.0,
    };
    for (vertices, 0..) |value, index| {
        std.mem.writeInt(u32, acceleration_structure.bytes[cpu_acceleration_structure_header_bytes + index * 4 ..][0..4], @bitCast(value), .little);
    }
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(7);
    try encoder.setTexture(texture, 0);
    try encoder.setAccelerationStructure(acceleration_structure, 0);
    try encoder.setIntersectionFunctionProfile(1);
    try encoder.dispatchThreads(.{ .width = 7, .height = 5, .depth = 1 }, .{ .width = 7, .height = 5, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    for (0..texture.height) |y| for (0..texture.width) |x| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, texture.bytes[(y * texture.stride + x * 4)..][0..4]);
    };
}

test "CPU AABB trace preserves the Metal 4 top-left pixel grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 7, 5, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const acceleration_structure = try createBuffer(device, 64, null);
    defer destroyBuffer(acceleration_structure);

    writeU32Little(acceleration_structure.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(acceleration_structure.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(acceleration_structure.bytes, 8, 0);
    writeU32Little(acceleration_structure.bytes, 12, cpu_acceleration_structure_flag_aabbs);
    writeU32Little(acceleration_structure.bytes, 16, cpu_acceleration_structure_header_bytes);
    writeU32Little(acceleration_structure.bytes, 24, cpu_acceleration_structure_header_bytes);
    writeU32Little(acceleration_structure.bytes, 28, 1);
    const bounds = [_]f32{ -0.8, -0.7, -0.1, 0.8, 0.7, 0.1 };
    for (bounds, 0..) |value, index| {
        std.mem.writeInt(u32, acceleration_structure.bytes[cpu_acceleration_structure_header_bytes + index * 4 ..][0..4], @bitCast(value), .little);
    }

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(45);
    try encoder.setTexture(texture, 0);
    try encoder.setAccelerationStructure(acceleration_structure, 0);
    try encoder.dispatchThreads(.{ .width = 7, .height = 5, .depth = 1 }, .{ .width = 7, .height = 5, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);

    const miss = [_]u8{ 0, 0, 0, 255 };
    const hit = [_]u8{ 255, 0, 0, 255 };
    try std.testing.expectEqualSlices(u8, &miss, texture.bytes[(0 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &hit, texture.bytes[(1 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &hit, texture.bytes[(2 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &hit, texture.bytes[(3 * texture.stride + 3 * 4)..][0..4]);
    try std.testing.expectEqualSlices(u8, &miss, texture.bytes[(4 * texture.stride + 3 * 4)..][0..4]);
}

test "CPU AABB trace applies primitive visibility masks" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const acceleration_structure = try createBuffer(device, 64, null);
    defer destroyBuffer(acceleration_structure);

    writeU32Little(acceleration_structure.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(acceleration_structure.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(acceleration_structure.bytes, 8, 0);
    writeU32Little(acceleration_structure.bytes, 12, cpu_acceleration_structure_flag_aabbs | cpu_acceleration_structure_flag_triangle_masks);
    writeU32Little(acceleration_structure.bytes, 16, cpu_acceleration_structure_header_bytes);
    writeU32Little(acceleration_structure.bytes, 20, 56);
    writeU32Little(acceleration_structure.bytes, 24, cpu_acceleration_structure_header_bytes);
    writeU32Little(acceleration_structure.bytes, 28, 1);
    const bounds = [_]f32{ -1.0, -1.0, -1.0, 1.0, 1.0, 1.0 };
    for (bounds, 0..) |value, index| {
        std.mem.writeInt(u32, acceleration_structure.bytes[cpu_acceleration_structure_header_bytes + index * 4 ..][0..4], @bitCast(value), .little);
    }

    writeU32Little(acceleration_structure.bytes, 56, 0);
    var masked_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(masked_commands);
    var masked_encoder = try beginCompute(masked_commands);
    try masked_encoder.setKernel(45);
    try masked_encoder.setTexture(texture, 0);
    try masked_encoder.setAccelerationStructure(acceleration_structure, 0);
    try masked_encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 });
    try masked_encoder.endEncoding();
    destroyComputeEncoder(masked_encoder);
    try masked_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, masked_commands.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, texture.bytes[0..4]);

    writeU32Little(acceleration_structure.bytes, 56, std.math.maxInt(u32));
    @memset(texture.bytes, 0);
    var visible_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(visible_commands);
    var visible_encoder = try beginCompute(visible_commands);
    try visible_encoder.setKernel(45);
    try visible_encoder.setTexture(texture, 0);
    try visible_encoder.setAccelerationStructure(acceleration_structure, 0);
    try visible_encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 });
    try visible_encoder.endEncoding();
    destroyComputeEncoder(visible_encoder);
    try visible_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, visible_commands.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, texture.bytes[0..4]);
}

test "CPU AABB trace rejects truncated and non-finite payloads" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);

    const truncated = try createBuffer(device, cpu_acceleration_structure_header_bytes, null);
    defer destroyBuffer(truncated);
    writeU32Little(truncated.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(truncated.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(truncated.bytes, 12, cpu_acceleration_structure_flag_aabbs);
    writeU32Little(truncated.bytes, 16, cpu_acceleration_structure_header_bytes);
    writeU32Little(truncated.bytes, 24, cpu_acceleration_structure_header_bytes);
    writeU32Little(truncated.bytes, 28, 1);
    var truncated_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(truncated_commands);
    var truncated_encoder = try beginCompute(truncated_commands);
    try truncated_encoder.setKernel(45);
    try truncated_encoder.setTexture(texture, 0);
    try truncated_encoder.setAccelerationStructure(truncated, 0);
    try truncated_encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 });
    try truncated_encoder.endEncoding();
    destroyComputeEncoder(truncated_encoder);
    try std.testing.expectError(error.InvalidArgument, truncated_commands.commit());
    try std.testing.expectEqual(CommandStatus.failed, truncated_commands.status);

    const invalid = try createBuffer(device, 64, null);
    defer destroyBuffer(invalid);
    writeU32Little(invalid.bytes, 0, cpu_acceleration_structure_magic);
    writeU32Little(invalid.bytes, 4, cpu_acceleration_structure_version);
    writeU32Little(invalid.bytes, 12, cpu_acceleration_structure_flag_aabbs);
    writeU32Little(invalid.bytes, 16, cpu_acceleration_structure_header_bytes);
    writeU32Little(invalid.bytes, 24, cpu_acceleration_structure_header_bytes);
    writeU32Little(invalid.bytes, 28, 1);
    const invalid_bounds = [_]f32{ 1.0, -1.0, -1.0, 0.0, 1.0, 1.0 };
    for (invalid_bounds, 0..) |value, index| {
        std.mem.writeInt(u32, invalid.bytes[cpu_acceleration_structure_header_bytes + index * 4 ..][0..4], @bitCast(value), .little);
    }
    var invalid_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(invalid_commands);
    var invalid_encoder = try beginCompute(invalid_commands);
    try invalid_encoder.setKernel(45);
    try invalid_encoder.setTexture(texture, 0);
    try invalid_encoder.setAccelerationStructure(invalid, 0);
    try invalid_encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 });
    try invalid_encoder.endEncoding();
    destroyComputeEncoder(invalid_encoder);
    try std.testing.expectError(error.InvalidArgument, invalid_commands.commit());
    try std.testing.expectEqual(CommandStatus.failed, invalid_commands.status);
}

test "CPU compute acceleration bindings can be explicitly unbound" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const acceleration_storage = try createBuffer(device, 64, null);
    defer destroyBuffer(acceleration_storage);

    const command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(7);
    try encoder.setTexture(texture, 0);
    try encoder.setAccelerationStructure(acceleration_storage, 0);
    try encoder.setAccelerationStructure(null, 0);
    try std.testing.expectError(
        error.InvalidCommand,
        encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 }),
    );
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
}

test "CPU compute textures retain independent Metal binding slots" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source_bytes = [_]u8{ 255, 0, 0, 255 };
    const source = try createBuffer(device, source_bytes.len, &source_bytes);
    defer destroyBuffer(source);
    const destination = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(destination);
    const unrelated = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(unrelated);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(2);
    try encoder.setBuffer(source, 0, 0);
    try encoder.setTexture(destination, 1);
    try encoder.setTexture(unrelated, 0);
    try encoder.setTexture(null, 0);
    try encoder.dispatchThreads(.{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), destination.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &source_bytes, destination.bytes[0..4]);
}

test "CPU tile dispatch preserves Metal's upper-left pixel origin" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    @memset(texture.bytes, 0xa5);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .load, .store_action = .store } });
    try encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0xa5), texture.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, texture.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 159, 96, 64, 255 }, texture.bytes[2 * texture.stride + 4 * 4 ..][0..4]);
}

test "CPU tile dispatch clips in the attachment-global top-left grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.depth32_float));
    defer destroyTexture(depth);
    const stencil = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.stencil8));
    defer destroyTexture(stencil);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setStencilTexture(stencil, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 0);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less), true);
    try encoder.setStencilState(
        true,
        @intFromEnum(abi.CompareFunction.always),
        @intFromEnum(abi.StencilOperation.keep),
        @intFromEnum(abi.StencilOperation.keep),
        @intFromEnum(abi.StencilOperation.replace),
        0xff,
        0xff,
    );
    try encoder.setStencilReference(7, 7);
    // Tile invocation coordinates are attachment-global as well; viewport
    // origin does not move the tile thread grid.
    try encoder.setViewport(.{ .origin_x = 2, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.dispatchThreadsPerTile(
        1,
        .{ .width = 2, .height = 2, .depth = 1 },
        .{ .width = 2, .height = 2, .depth = 1 },
    );
    // Verify the tile command keeps the original scissor snapshot.
    try encoder.setScissorRect(.{ .x = 0, .y = 0, .width = 5, .height = 3 });
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();

    var expected = [_]u8{0} ** (5 * 3 * 4);
    for (0..3) |y| {
        for (0..5) |x| {
            const pixel = (y * 5 + x) * 4;
            expected[pixel + 3] = 255;
            if (x >= 1 and x < 4 and y >= 1 and y < 3) {
                expected[pixel + 0] = @intCast(((x + 1) * 255 + 4) / 8);
                expected[pixel + 1] = @intCast(((y + 1) * 255 + 4) / 8);
                expected[pixel + 2] = 64;
            }
        }
    }
    const depth_value: f32 = 0.5;
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &expected, color.bytes);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&depth_value), depth.bytes[6 * 4 .. 7 * 4]);
    try std.testing.expectEqual(@as(u8, 7), stencil.bytes[7]);
    try std.testing.expectEqual(@as(u8, 0), stencil.bytes[0]);
}

test "CPU layered tile dispatch broadcasts each slice on the upper-left grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    var layers: [3]*Texture = undefined;
    var references: [3]*Texture = undefined;
    for (&layers, &references) |*layer, *reference| {
        layer.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        reference.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        @memset(layer.*.bytes, 0xa5);
        @memset(reference.*.bytes, 0xa5);
    }
    defer for (layers, &references) |layer, *reference| {
        destroyTexture(layer);
        destroyTexture(reference.*);
    };

    var layered_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(layered_commands);
    var layered_encoder = try beginRender(layered_commands, layers[0], .{ .color = .{ .load_action = .load, .store_action = .store } });
    try layered_encoder.setRenderTargetArray(&layers, layers.len);
    try layered_encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try layered_encoder.endEncoding();
    destroyRenderEncoder(layered_encoder);

    var reference_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(reference_commands);
    for (references) |reference| {
        var reference_encoder = try beginRender(reference_commands, reference, .{ .color = .{ .load_action = .load, .store_action = .store } });
        try reference_encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
        try reference_encoder.endEncoding();
        destroyRenderEncoder(reference_encoder);
    }

    for (layers, &references) |layer, *reference| {
        try std.testing.expectEqual(@as(u8, 0xa5), layer.bytes[0]);
        try std.testing.expectEqual(@as(u8, 0xa5), reference.*.bytes[0]);
    }
    try layered_commands.commit();
    try reference_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, layered_commands.status);
    try std.testing.expectEqual(CommandStatus.completed, reference_commands.status);
    for (layers, &references) |layer, *reference| {
        try std.testing.expectEqualSlices(u8, reference.*.bytes, layer.bytes);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, layer.bytes[0..4]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 159, 96, 64, 255 }, layer.bytes[2 * layer.stride + 4 * 4 ..][0..4]);
    }
}

test "CPU layered tile dispatch honors logical to physical attachment mapping" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    var logical_layers: [3]*Texture = undefined;
    var physical_layers: [3]*Texture = undefined;
    var references: [3]*Texture = undefined;
    for (&logical_layers, &physical_layers, &references) |*logical, *physical, *reference| {
        logical.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        physical.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        reference.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        @memset(logical.*.bytes, 0xa5);
        @memset(physical.*.bytes, 0xa5);
        @memset(reference.*.bytes, 0xa5);
    }
    defer for (logical_layers, &physical_layers, &references) |logical, *physical, *reference| {
        destroyTexture(logical);
        destroyTexture(physical.*);
        destroyTexture(reference.*);
    };

    var mapped_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(mapped_commands);
    var mapped_encoder = try beginRender(mapped_commands, logical_layers[0], .{
        .color = .{ .load_action = .load, .store_action = .store },
    });
    try mapped_encoder.setRenderTargetArray(&logical_layers, logical_layers.len);
    try mapped_encoder.setColorAttachmentArrayTargets(
        &physical_layers,
        physical_layers.len,
        .{ .load_action = .load, .store_action = .store },
        1,
    );
    try mapped_encoder.setColorAttachmentMap(&[_]u8{ 1, 0, 2, 3, 4, 5, 6, 7 }, 8);
    try mapped_encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try mapped_encoder.endEncoding();
    destroyRenderEncoder(mapped_encoder);

    var reference_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(reference_commands);
    for (references) |reference| {
        var reference_encoder = try beginRender(reference_commands, reference, .{
            .color = .{ .load_action = .load, .store_action = .store },
        });
        try reference_encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
        try reference_encoder.endEncoding();
        destroyRenderEncoder(reference_encoder);
    }

    try std.testing.expectEqual(@as(u8, 0xa5), physical_layers[0].bytes[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), logical_layers[0].bytes[0]);
    try mapped_commands.commit();
    try reference_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, mapped_commands.status);
    try std.testing.expectEqual(CommandStatus.completed, reference_commands.status);
    for (physical_layers, &references) |physical, *reference| {
        try std.testing.expectEqualSlices(u8, reference.*.bytes, physical.bytes);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 32, 32, 255 }, physical.bytes[0..4]);
        try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 96, 159, 255 }, physical.bytes[2 * physical.stride + 4 * 4 ..][0..4]);
    }
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa5, 0xa5, 0xa5, 0xa5 }, logical_layers[0].bytes[0..4]);
    try std.testing.expectEqualSlices(u8, logical_layers[0].bytes, logical_layers[1].bytes);
    try std.testing.expectEqualSlices(u8, logical_layers[1].bytes, logical_layers[2].bytes);
}

test "CPU mesh indirect grid is deferred and uses Metal threadgroup dimensions" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(texture);
    const initial_arguments = [_]u32{ 1, 1, 1 };
    const indirect = try createBuffer(device, @sizeOf(@TypeOf(initial_arguments)), @ptrCast(&initial_arguments));
    defer destroyBuffer(indirect);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.drawMeshThreadgroupsIndirect(
        1,
        indirect,
        0,
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 2, .height = 2, .depth = 1 },
    );
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);

    const updated_arguments = [_]u32{ 3, 2, 1 };
    try bufferWrite(indirect, 0, @ptrCast(&updated_arguments), @sizeOf(@TypeOf(updated_arguments)));
    try std.testing.expectEqual(@as(u8, 0), texture.bytes[0]);
    try command_buffer.commit();

    var expected = [_]u8{0} ** (5 * 3 * 4);
    for (0..3) |y| {
        for (0..5) |x| {
            const pixel = (y * 5 + x) * 4;
            expected[pixel + 0] = 64;
            expected[pixel + 1] = @intCast(((y + 1) * 255 + 4) / 8);
            expected[pixel + 2] = @intCast(((x + 1) * 255 + 4) / 8);
            expected[pixel + 3] = 255;
        }
    }
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &expected, texture.bytes);
}

test "CPU layered mesh indirect grid selects render-target slices" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    var layers: [3]*Texture = undefined;
    for (&layers) |*layer| {
        layer.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    }
    defer for (layers) |layer| destroyTexture(layer);
    const initial_arguments = [_]u32{ 1, 1, 1 };
    const indirect = try createBuffer(device, @sizeOf(@TypeOf(initial_arguments)), @ptrCast(&initial_arguments));
    defer destroyBuffer(indirect);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, layers[0], .{
        .color = .{ .load_action = .clear, .store_action = .store },
    });
    try encoder.setRenderTargetArray(&layers, layers.len);
    try encoder.setViewport(.{ .origin_x = 2, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.drawMeshThreadgroupsIndirect(
        1,
        indirect,
        0,
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
    );
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);

    const updated_arguments = [_]u32{ 5, 3, 3 };
    try bufferWrite(indirect, 0, @ptrCast(&updated_arguments), @sizeOf(@TypeOf(updated_arguments)));
    try std.testing.expectEqual(@as(u8, 0), layers[0].bytes[0]);
    try command_buffer.commit();

    var expected = [_]u8{0} ** (5 * 3 * 4);
    for (0..3) |y| {
        for (0..5) |x| {
            const pixel = (y * 5 + x) * 4;
            expected[pixel + 3] = 255;
            if (x >= 1 and x < 4 and y >= 1 and y < 3) {
                expected[pixel + 0] = 64;
                expected[pixel + 1] = @intCast(((y + 1) * 255 + 4) / 8);
                expected[pixel + 2] = @intCast(((x + 1) * 255 + 4) / 8);
            }
        }
    }
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    for (layers) |layer| {
        try std.testing.expectEqualSlices(u8, &expected, layer.bytes);
    }
}

test "CPU mesh scissor keeps the Apple top-left grid origin" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    // Mesh grid coordinates remain attachment-global; a viewport origin must
    // not rebase the CPU profile's invocation-to-pixel mapping.
    try encoder.setViewport(.{ .origin_x = 2, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.drawMeshThreads(
        1,
        .{ .width = 5, .height = 3, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
    );
    // The deferred command must retain the original attachment-global
    // scissor even when the encoder is changed before commit.
    try encoder.setScissorRect(.{ .x = 0, .y = 0, .width = 5, .height = 3 });
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();

    var expected = [_]u8{0} ** (5 * 3 * 4);
    for (0..3) |y| {
        for (0..5) |x| {
            const pixel = (y * 5 + x) * 4;
            expected[pixel + 3] = 255;
            if (x >= 1 and x < 4 and y >= 1 and y < 3) {
                expected[pixel + 0] = @intCast(((x + 1) * 255 + 4) / 8);
                expected[pixel + 1] = @intCast(((y + 1) * 255 + 4) / 8);
                expected[pixel + 2] = 64;
            }
        }
    }
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &expected, texture.bytes);
}

test "CPU layered mesh grid depth selects render-target slices" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    var layers: [3]*Texture = undefined;
    for (&layers) |*layer| {
        layer.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (layers) |layer| destroyTexture(layer);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, layers[0], .{
        .color = .{
            .load_action = .clear,
            .store_action = .store,
            .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 },
        },
    });
    try encoder.setRenderTargetArray(&layers, layers.len);
    // Mesh-grid Z selects the target slice in the bounded CPU profile. X/Y
    // remain attachment-global and use Apple's top-left origin.
    try encoder.setViewport(.{ .origin_x = 2, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.drawMeshThreads(
        1,
        .{ .width = 5, .height = 3, .depth = layers.len },
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
    );
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();

    var expected = [_]u8{0} ** (5 * 3 * 4);
    for (0..3) |y| {
        for (0..5) |x| {
            const pixel = (y * 5 + x) * 4;
            expected[pixel + 3] = 255;
            if (x >= 1 and x < 4 and y >= 1 and y < 3) {
                expected[pixel + 0] = @intCast(((x + 1) * 255 + 4) / 8);
                expected[pixel + 1] = @intCast(((y + 1) * 255 + 4) / 8);
                expected[pixel + 2] = 64;
            }
        }
    }
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    for (layers) |layer| {
        try std.testing.expectEqualSlices(u8, &expected, layer.bytes);
    }
}

test "CPU mesh dispatch applies depth and stencil tests" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.depth32_float));
    defer destroyTexture(depth);
    const stencil = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.stencil8));
    defer destroyTexture(stencil);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setStencilTexture(stencil, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 0);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less), true);
    try encoder.setStencilState(
        true,
        @intFromEnum(abi.CompareFunction.always),
        @intFromEnum(abi.StencilOperation.keep),
        @intFromEnum(abi.StencilOperation.keep),
        @intFromEnum(abi.StencilOperation.replace),
        0xff,
        0xff,
    );
    try encoder.setStencilReference(7, 7);
    try encoder.drawMeshThreads(
        1,
        .{ .width = 2, .height = 2, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
    );

    // Reject the second pass by depth and use depth-failure stencil op to
    // prove that mesh pixels share the ordinary fixed-function path.
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.never), true);
    try encoder.setStencilState(
        true,
        @intFromEnum(abi.CompareFunction.always),
        @intFromEnum(abi.StencilOperation.keep),
        @intFromEnum(abi.StencilOperation.increment_clamp),
        @intFromEnum(abi.StencilOperation.keep),
        0xff,
        0xff,
    );
    try encoder.drawMeshThreads(
        1,
        .{ .width = 2, .height = 2, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
        .{ .width = 1, .height = 1, .depth = 1 },
    );
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();

    const depth_value: f32 = 0.5;
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, std.mem.asBytes(&depth_value), depth.bytes[0..@sizeOf(f32)]);
    try std.testing.expectEqual(@as(u8, 8), stencil.bytes[0]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, color.bytes[0..4]);
}

test "CPU triangle patches use factor-one lowering and preserve raster pixels" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const patch_texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(patch_texture);
    const primitive_texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(primitive_texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const factors = [_]u16{ 0x3c00, 0x3c00, 0x3c00, 0x3c00 };
    const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
    defer destroyBuffer(factor_buffer);

    var patch_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(patch_commands);
    var patch_encoder = try beginRender(patch_commands, patch_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try patch_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try patch_encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf(@TypeOf(factors)));
    try patch_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try patch_encoder.endEncoding();
    destroyRenderEncoder(patch_encoder);

    var primitive_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(primitive_commands);
    var primitive_encoder = try beginRender(primitive_commands, primitive_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try primitive_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try primitive_encoder.drawPrimitives(.triangle, 0, 3, 1);
    try primitive_encoder.endEncoding();
    destroyRenderEncoder(primitive_encoder);

    try std.testing.expectEqual(@as(u8, 0), patch_texture.bytes[0]);
    try patch_commands.commit();
    try primitive_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, patch_commands.status);
    try std.testing.expectEqualSlices(u8, patch_texture.bytes, primitive_texture.bytes);
    try std.testing.expect(std.mem.indexOfScalar(u8, patch_texture.bytes, 255) != null);
}

test "CPU uniform integer triangle patches preserve raster pixels" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.86, -0.72, 0.5, 1 }, .color = .{ .red = 0.91, .green = 0.17, .blue = 0.63, .alpha = 0.81 } },
        .{ .position = .{ 0.78, -0.43, 0.5, 1 }, .color = .{ .red = 0.23, .green = 0.87, .blue = 0.31, .alpha = 0.59 } },
        .{ .position = .{ -0.21, 0.84, 0.5, 1 }, .color = .{ .red = 0.19, .green = 0.41, .blue = 0.97, .alpha = 0.73 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const cases = [_]struct { factor: usize, half: u16 }{
        .{ .factor = 2, .half = 0x4000 },
        .{ .factor = 4, .half = 0x4400 },
    };
    for (cases) |case| {
        const patch_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        defer destroyTexture(patch_texture);
        const primitive_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        defer destroyTexture(primitive_texture);
        const factors = [_]u16{ case.half, case.half, case.half, case.half };
        const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
        defer destroyBuffer(factor_buffer);

        var patch_commands = try createCommandBuffer(queue);
        defer destroyCommandBuffer(patch_commands);
        var patch_encoder = try beginRender(patch_commands, patch_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
        try patch_encoder.setVertexBuffer(vertex_buffer, 0, 0);
        try patch_encoder.setPatchMaxTessellationFactor(case.factor);
        try patch_encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf(@TypeOf(factors)));
        try patch_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
        try patch_encoder.endEncoding();
        destroyRenderEncoder(patch_encoder);

        var primitive_commands = try createCommandBuffer(queue);
        defer destroyCommandBuffer(primitive_commands);
        var primitive_encoder = try beginRender(primitive_commands, primitive_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
        try primitive_encoder.setVertexBuffer(vertex_buffer, 0, 0);
        try primitive_encoder.drawPrimitives(.triangle, 0, 3, 1);
        try primitive_encoder.endEncoding();
        destroyRenderEncoder(primitive_encoder);

        try patch_commands.commit();
        try primitive_commands.commit();
        try std.testing.expectEqual(CommandStatus.completed, patch_commands.status);
        try std.testing.expectEqualSlices(u8, patch_texture.bytes, primitive_texture.bytes);
    }
}

test "CPU triangle patches apply an enabled integer factor scale" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.86, -0.72, 0.5, 1 }, .color = .{ .red = 0.91, .green = 0.17, .blue = 0.63, .alpha = 0.81 } },
        .{ .position = .{ 0.78, -0.43, 0.5, 1 }, .color = .{ .red = 0.23, .green = 0.87, .blue = 0.31, .alpha = 0.59 } },
        .{ .position = .{ -0.21, 0.84, 0.5, 1 }, .color = .{ .red = 0.19, .green = 0.41, .blue = 0.97, .alpha = 0.73 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const factors = [_]u16{ 0x3c00, 0x3c00, 0x3c00, 0x3c00 };
    const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
    defer destroyBuffer(factor_buffer);
    const factor_two = [_]u16{ 0x4000, 0x4000, 0x4000, 0x4000 };
    const factor_two_buffer = try createBuffer(device, @sizeOf(@TypeOf(factor_two)), @ptrCast(&factor_two));
    defer destroyBuffer(factor_two_buffer);
    const scaled_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(scaled_texture);
    const reference_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(reference_texture);

    var scaled_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(scaled_commands);
    var scaled_encoder = try beginRender(scaled_commands, scaled_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try scaled_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try scaled_encoder.setPatchMaxTessellationFactor(2);
    try scaled_encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf(@TypeOf(factors)));
    try scaled_encoder.setTessellationFactorScale(2);
    try scaled_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try scaled_encoder.endEncoding();
    destroyRenderEncoder(scaled_encoder);

    var reference_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(reference_commands);
    var reference_encoder = try beginRender(reference_commands, reference_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try reference_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try reference_encoder.setPatchMaxTessellationFactor(2);
    try reference_encoder.setTessellationFactorBuffer(factor_two_buffer, 0, @sizeOf(@TypeOf(factor_two)));
    try reference_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try reference_encoder.endEncoding();
    destroyRenderEncoder(reference_encoder);

    // The reference uses a factor-two buffer while the scaled path uses a
    // factor-one buffer with scale two; both must produce the same CPU mesh.
    try scaled_commands.commit();
    try reference_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, scaled_commands.status);
    try std.testing.expectEqualSlices(u8, scaled_texture.bytes, reference_texture.bytes);
}

test "CPU pow2 triangle patches round up to the next power of two" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.86, -0.72, 0.5, 1 }, .color = .{ .red = 0.91, .green = 0.17, .blue = 0.63, .alpha = 0.81 } },
        .{ .position = .{ 0.78, -0.43, 0.5, 1 }, .color = .{ .red = 0.23, .green = 0.87, .blue = 0.31, .alpha = 0.59 } },
        .{ .position = .{ -0.21, 0.84, 0.5, 1 }, .color = .{ .red = 0.19, .green = 0.41, .blue = 0.97, .alpha = 0.73 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const pow2_factors = [_]u16{ 0x4200, 0x4200, 0x4200, 0x4200 };
    const pow2_factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(pow2_factors)), @ptrCast(&pow2_factors));
    defer destroyBuffer(pow2_factor_buffer);
    const integer_factors = [_]u16{ 0x4400, 0x4400, 0x4400, 0x4400 };
    const integer_factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(integer_factors)), @ptrCast(&integer_factors));
    defer destroyBuffer(integer_factor_buffer);
    const pow2_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(pow2_texture);
    const integer_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(integer_texture);

    var pow2_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(pow2_commands);
    var pow2_encoder = try beginRender(pow2_commands, pow2_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try pow2_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try pow2_encoder.setPatchMaxTessellationFactor(4);
    try pow2_encoder.setTessellationPartitionMode(cpu_tessellation_partition_pow2);
    try pow2_encoder.setTessellationFactorBuffer(pow2_factor_buffer, 0, @sizeOf(@TypeOf(pow2_factors)));
    try pow2_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try pow2_encoder.endEncoding();
    destroyRenderEncoder(pow2_encoder);

    var integer_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(integer_commands);
    var integer_encoder = try beginRender(integer_commands, integer_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try integer_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try integer_encoder.setPatchMaxTessellationFactor(4);
    try integer_encoder.setTessellationFactorBuffer(integer_factor_buffer, 0, @sizeOf(@TypeOf(integer_factors)));
    try integer_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try integer_encoder.endEncoding();
    destroyRenderEncoder(integer_encoder);

    try pow2_commands.commit();
    try integer_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, pow2_commands.status);
    try std.testing.expectEqualSlices(u8, pow2_texture.bytes, integer_texture.bytes);
}

test "CPU line-filled integer triangle patches rasterize their generated grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.86, -0.72, 0.5, 1 }, .color = .{ .red = 0.91, .green = 0.17, .blue = 0.63, .alpha = 0.81 } },
        .{ .position = .{ 0.78, -0.43, 0.5, 1 }, .color = .{ .red = 0.23, .green = 0.87, .blue = 0.31, .alpha = 0.59 } },
        .{ .position = .{ -0.21, 0.84, 0.5, 1 }, .color = .{ .red = 0.19, .green = 0.41, .blue = 0.97, .alpha = 0.73 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const factors = [_]u16{ 0x4000, 0x4000, 0x4000, 0x4000 };
    const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
    defer destroyBuffer(factor_buffer);

    const line_texture = try createTexture(device, 9, 7, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(line_texture);
    var line_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(line_commands);
    var line_encoder = try beginRender(line_commands, line_texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try line_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try line_encoder.setPatchMaxTessellationFactor(2);
    try line_encoder.setTriangleFillMode(.lines);
    try line_encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf(@TypeOf(factors)));
    try line_encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
    try line_encoder.endEncoding();
    destroyRenderEncoder(line_encoder);
    try line_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, line_commands.status);

    var has_line_pixel = false;
    for (0..line_texture.bytes.len / 4) |pixel| {
        const offset = pixel * 4;
        if (line_texture.bytes[offset] != 0 or line_texture.bytes[offset + 1] != 0 or line_texture.bytes[offset + 2] != 0) {
            has_line_pixel = true;
            break;
        }
    }
    try std.testing.expect(has_line_pixel);
}

test "CPU triangle patches fail closed for unsupported tessellation factors" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const cases = [_]struct { factors: [4]u16, max_factor: usize }{
        .{ .factors = .{ 0x4100, 0x4100, 0x4100, 0x4100 }, .max_factor = 4 }, // fractional 2.5
        .{ .factors = .{ 0x4000, 0x4000, 0x4000, 0x4400 }, .max_factor = 4 }, // non-uniform 2/4
        .{ .factors = .{ 0x4000, 0x4000, 0x4000, 0x4000 }, .max_factor = 1 }, // above pipeline limit
        .{ .factors = .{ 0x4c40, 0x4c40, 0x4c40, 0x4c40 }, .max_factor = 16 }, // above CPU cap
    };
    for (cases) |case| {
        const texture = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        defer destroyTexture(texture);
        const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(case.factors)), @ptrCast(&case.factors));
        defer destroyBuffer(factor_buffer);
        var command_buffer = try createCommandBuffer(queue);
        defer destroyCommandBuffer(command_buffer);
        var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
        try encoder.setVertexBuffer(vertex_buffer, 0, 0);
        try encoder.setPatchMaxTessellationFactor(case.max_factor);
        try encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf(@TypeOf(case.factors)));
        try encoder.drawPatches(1, 3, 0, 1, null, 0, 1, 0, .none, null, 0);
        try encoder.endEncoding();
        destroyRenderEncoder(encoder);
        try std.testing.expectError(error.UnsupportedOperation, command_buffer.commit());
        try std.testing.expectEqual(CommandStatus.failed, command_buffer.status);
    }
}

test "CPU compute writes narrow unorm targets at their native stride" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const r8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r8_unorm));
    defer destroyTexture(r8);
    const rg8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rg8_unorm));
    defer destroyTexture(rg8);

    var r8_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(r8_command_buffer);
    var r8_encoder = try beginCompute(r8_command_buffer);
    try r8_encoder.setKernel(1);
    try r8_encoder.setTexture(r8, 0);
    try r8_encoder.dispatchThreads(.{ .width = 2, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    try r8_encoder.endEncoding();
    destroyComputeEncoder(r8_encoder);
    try r8_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 64 }, r8.bytes);

    var rg8_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(rg8_command_buffer);
    var rg8_encoder = try beginCompute(rg8_command_buffer);
    try rg8_encoder.setKernel(1);
    try rg8_encoder.setTexture(rg8, 0);
    try rg8_encoder.dispatchThreads(.{ .width = 2, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    try rg8_encoder.endEncoding();
    destroyComputeEncoder(rg8_encoder);
    try rg8_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 32 }, rg8.bytes);
}

test "CPU compute gradient preserves wide target encodings" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const r16 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r16_unorm));
    defer destroyTexture(r16);
    const r16_float = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r16_float));
    defer destroyTexture(r16_float);
    const rg16 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rg16_unorm));
    defer destroyTexture(rg16);
    const rg16_float = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rg16_float));
    defer destroyTexture(rg16_float);
    const rgba16 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(rgba16);
    const rgba32 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rgba32_float));
    defer destroyTexture(rgba32);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(1);
    const textures = [_]*Texture{ r16, r16_float, rg16, rg16_float, rgba16, rgba32 };
    for (textures) |texture| {
        try encoder.setTexture(texture, 0);
        try encoder.dispatchThreads(.{ .width = 2, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    }
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), r16.bytes[0]);
    try command_buffer.commit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0x20, 0, 0x40 }, r16.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0x30, 0, 0x34 }, r16_float.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0x20, 0, 0x20, 0, 0x40, 0, 0x20,
    }, rg16.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0x30, 0, 0x30, 0, 0x34, 0, 0x30,
    }, rg16_float.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0x20, 0, 0x20, 0, 0x40, 0xff, 0xff,
        0, 0x40, 0, 0x20, 0, 0x40, 0xff, 0xff,
    }, rgba16.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0, 0, 0,    0x3e, 0, 0, 0, 0x3e, 0, 0, 0x80, 0x3e, 0, 0, 0x80, 0x3f,
        0, 0, 0x80, 0x3e, 0, 0, 0, 0x3e, 0, 0, 0x80, 0x3e, 0, 0, 0x80, 0x3f,
    }, rgba32.bytes);
}

test "CPU compute integer gradients preserve RGBA32 lanes and top-left rows" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const uint_texture = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba32_uint));
    defer destroyTexture(uint_texture);
    const sint_texture = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba32_sint));
    defer destroyTexture(sint_texture);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(10);
    try encoder.setTexture(uint_texture, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setKernel(11);
    try encoder.setTexture(sint_texture, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();

    for (0..2) |y| for (0..3) |x| {
        const offset = y * uint_texture.stride + x * 16;
        try std.testing.expectEqual(@as(u32, @intCast(x + 1)), readU32Little(uint_texture.bytes, offset));
        try std.testing.expectEqual(@as(u32, @intCast(y + 1)), readU32Little(uint_texture.bytes, offset + 4));
        try std.testing.expectEqual(@as(u32, @intCast(x + y + 1)), readU32Little(uint_texture.bytes, offset + 8));
        try std.testing.expectEqual(std.math.maxInt(u32), readU32Little(uint_texture.bytes, offset + 12));
        try std.testing.expectEqual(@as(i32, @intCast(x + 1)), std.mem.readInt(i32, sint_texture.bytes[offset..][0..4], .little));
        try std.testing.expectEqual(-@as(i32, @intCast(y + 1)), std.mem.readInt(i32, sint_texture.bytes[offset + 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(i32, @intCast(x + y)), std.mem.readInt(i32, sint_texture.bytes[offset + 8 ..][0..4], .little));
        try std.testing.expectEqual(std.math.maxInt(i32), std.mem.readInt(i32, sint_texture.bytes[offset + 12 ..][0..4], .little));
    };
}

test "CPU compute integer gradients preserve R32 and RG32 lanes" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const r32_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r32_uint));
    defer destroyTexture(r32_uint);
    const r32_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r32_sint));
    defer destroyTexture(r32_sint);
    const rg32_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg32_uint));
    defer destroyTexture(rg32_uint);
    const rg32_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg32_sint));
    defer destroyTexture(rg32_sint);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(12);
    try encoder.setTexture(r32_uint, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setKernel(13);
    try encoder.setTexture(r32_sint, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setKernel(14);
    try encoder.setTexture(rg32_uint, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setKernel(15);
    try encoder.setTexture(rg32_sint, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();

    for (0..2) |y| for (0..3) |x| {
        const r32_offset = y * r32_uint.stride + x * 4;
        const rg32_offset = y * rg32_uint.stride + x * 8;
        try std.testing.expectEqual(@as(u32, @intCast(x + 1)), readU32Little(r32_uint.bytes, r32_offset));
        try std.testing.expectEqual(@as(i32, @intCast(x + 1)), std.mem.readInt(i32, r32_sint.bytes[r32_offset..][0..4], .little));
        try std.testing.expectEqual(@as(u32, @intCast(x + 1)), readU32Little(rg32_uint.bytes, rg32_offset));
        try std.testing.expectEqual(@as(u32, @intCast(y + 1)), readU32Little(rg32_uint.bytes, rg32_offset + 4));
        try std.testing.expectEqual(@as(i32, @intCast(x + 1)), std.mem.readInt(i32, rg32_sint.bytes[rg32_offset..][0..4], .little));
        try std.testing.expectEqual(-@as(i32, @intCast(y + 1)), std.mem.readInt(i32, rg32_sint.bytes[rg32_offset + 4 ..][0..4], .little));
    };
}

test "CPU compute integer gradients preserve R8/RG8/RGBA8 and 16-bit lanes" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const r8_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r8_uint));
    defer destroyTexture(r8_uint);
    const r8_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r8_sint));
    defer destroyTexture(r8_sint);
    const rg8_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg8_uint));
    defer destroyTexture(rg8_uint);
    const rg8_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg8_sint));
    defer destroyTexture(rg8_sint);
    const rgba8_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba8_uint));
    defer destroyTexture(rgba8_uint);
    const rgba8_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba8_sint));
    defer destroyTexture(rgba8_sint);
    const r16_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r16_uint));
    defer destroyTexture(r16_uint);
    const r16_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r16_sint));
    defer destroyTexture(r16_sint);
    const rg16_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg16_uint));
    defer destroyTexture(rg16_uint);
    const rg16_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg16_sint));
    defer destroyTexture(rg16_sint);
    const rgba16_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba16_uint));
    defer destroyTexture(rgba16_uint);
    const rgba16_sint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba16_sint));
    defer destroyTexture(rgba16_sint);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    const grid = abi.Size{ .width = 3, .height = 2, .depth = 1 };
    const group = abi.Size{ .width = 2, .height = 2, .depth = 1 };
    try encoder.setKernel(16);
    try encoder.setTexture(r8_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(17);
    try encoder.setTexture(r8_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(18);
    try encoder.setTexture(rg8_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(19);
    try encoder.setTexture(rg8_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(20);
    try encoder.setTexture(rgba8_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(21);
    try encoder.setTexture(rgba8_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(22);
    try encoder.setTexture(r16_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(23);
    try encoder.setTexture(r16_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(24);
    try encoder.setTexture(rg16_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(25);
    try encoder.setTexture(rg16_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(26);
    try encoder.setTexture(rgba16_uint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.setKernel(27);
    try encoder.setTexture(rgba16_sint, 0);
    try encoder.dispatchThreads(grid, group);
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();

    for (0..2) |y| for (0..3) |x| {
        const r8_offset = y * r8_uint.stride + x;
        const rg8_offset = y * rg8_uint.stride + x * 2;
        const rgba8_offset = y * rgba8_uint.stride + x * 4;
        const r16_offset = y * r16_uint.stride + x * 2;
        const rg16_offset = y * rg16_uint.stride + x * 4;
        const rgba16_offset = y * rgba16_uint.stride + x * 8;
        try std.testing.expectEqual(@as(u8, @intCast(x + 1)), r8_uint.bytes[r8_offset]);
        try std.testing.expectEqual(@as(i8, @intCast(x + 1)), std.mem.readInt(i8, r8_sint.bytes[r8_offset..][0..1], .little));
        try std.testing.expectEqual(@as(u8, @intCast(x + 1)), rg8_uint.bytes[rg8_offset]);
        try std.testing.expectEqual(@as(u8, @intCast(y + 1)), rg8_uint.bytes[rg8_offset + 1]);
        try std.testing.expectEqual(@as(i8, @intCast(x + 1)), std.mem.readInt(i8, rg8_sint.bytes[rg8_offset..][0..1], .little));
        try std.testing.expectEqual(-@as(i8, @intCast(y + 1)), std.mem.readInt(i8, rg8_sint.bytes[rg8_offset + 1 ..][0..1], .little));
        try std.testing.expectEqual(@as(u8, @intCast(x + 1)), rgba8_uint.bytes[rgba8_offset]);
        try std.testing.expectEqual(@as(u8, @intCast(y + 1)), rgba8_uint.bytes[rgba8_offset + 1]);
        try std.testing.expectEqual(@as(u8, @intCast(x + y + 1)), rgba8_uint.bytes[rgba8_offset + 2]);
        try std.testing.expectEqual(@as(u8, 255), rgba8_uint.bytes[rgba8_offset + 3]);
        try std.testing.expectEqual(@as(i8, @intCast(x + 1)), std.mem.readInt(i8, rgba8_sint.bytes[rgba8_offset..][0..1], .little));
        try std.testing.expectEqual(-@as(i8, @intCast(y + 1)), std.mem.readInt(i8, rgba8_sint.bytes[rgba8_offset + 1 ..][0..1], .little));
        try std.testing.expectEqual(@as(i8, @intCast(x + y)), std.mem.readInt(i8, rgba8_sint.bytes[rgba8_offset + 2 ..][0..1], .little));
        try std.testing.expectEqual(@as(i8, 127), std.mem.readInt(i8, rgba8_sint.bytes[rgba8_offset + 3 ..][0..1], .little));
        try std.testing.expectEqual(@as(u16, @intCast(x + 1)), readU16Little(r16_uint.bytes, r16_offset));
        try std.testing.expectEqual(@as(i16, @intCast(x + 1)), std.mem.readInt(i16, r16_sint.bytes[r16_offset..][0..2], .little));
        try std.testing.expectEqual(@as(u16, @intCast(x + 1)), readU16Little(rg16_uint.bytes, rg16_offset));
        try std.testing.expectEqual(@as(u16, @intCast(y + 1)), readU16Little(rg16_uint.bytes, rg16_offset + 2));
        try std.testing.expectEqual(@as(i16, @intCast(x + 1)), std.mem.readInt(i16, rg16_sint.bytes[rg16_offset..][0..2], .little));
        try std.testing.expectEqual(-@as(i16, @intCast(y + 1)), std.mem.readInt(i16, rg16_sint.bytes[rg16_offset + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(u16, @intCast(x + 1)), readU16Little(rgba16_uint.bytes, rgba16_offset));
        try std.testing.expectEqual(@as(u16, @intCast(y + 1)), readU16Little(rgba16_uint.bytes, rgba16_offset + 2));
        try std.testing.expectEqual(@as(u16, @intCast(x + y + 1)), readU16Little(rgba16_uint.bytes, rgba16_offset + 4));
        try std.testing.expectEqual(@as(u16, 65535), readU16Little(rgba16_uint.bytes, rgba16_offset + 6));
        try std.testing.expectEqual(@as(i16, @intCast(x + 1)), std.mem.readInt(i16, rgba16_sint.bytes[rgba16_offset..][0..2], .little));
        try std.testing.expectEqual(-@as(i16, @intCast(y + 1)), std.mem.readInt(i16, rgba16_sint.bytes[rgba16_offset + 2 ..][0..2], .little));
        try std.testing.expectEqual(@as(i16, @intCast(x + y)), std.mem.readInt(i16, rgba16_sint.bytes[rgba16_offset + 4 ..][0..2], .little));
        try std.testing.expectEqual(@as(i16, 32767), std.mem.readInt(i16, rgba16_sint.bytes[rgba16_offset + 6 ..][0..2], .little));
    };
}

test "CPU compute packed RGB10A2 uint gradient preserves bit fields" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgb10a2_uint));
    defer destroyTexture(texture);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(28);
    try encoder.setTexture(texture, 0);
    try encoder.dispatchThreads(.{ .width = 3, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try command_buffer.commit();

    for (0..2) |y| for (0..3) |x| {
        const offset = y * texture.stride + x * 4;
        const expected = @as(u32, @intCast(x + 1)) |
            (@as(u32, @intCast(y + 1)) << 10) |
            (@as(u32, @intCast(x + y + 1)) << 20) | (3 << 30);
        try std.testing.expectEqual(expected, readU32Little(texture.bytes, offset));
    };
}

test "CPU compute buffer copy preserves logical channels across formats" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source_bytes = [_]u8{ 32, 64, 96, 128, 64, 96, 128, 160 };
    const source = try createBuffer(device, source_bytes.len, @ptrCast(&source_bytes));
    defer destroyBuffer(source);
    const r8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r8_unorm));
    defer destroyTexture(r8);
    const rg8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rg8_unorm));
    defer destroyTexture(rg8);
    const rgba8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(rgba8);
    const bgra8 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(bgra8);
    const r16 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r16_unorm));
    defer destroyTexture(r16);
    const r16_float = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r16_float));
    defer destroyTexture(r16_float);
    const rgba16 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(rgba16);
    const r32 = try createTexture(device, 2, 1, @intFromEnum(abi.PixelFormat.r32_float));
    defer destroyTexture(r32);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(2);
    try encoder.setBuffer(source, 0, 0);
    const textures = [_]*Texture{ r8, rg8, rgba8, bgra8, r16, r16_float, rgba16, r32 };
    for (textures) |texture| {
        try encoder.setTexture(texture, 1);
        try encoder.dispatchThreads(.{ .width = 2, .height = 1, .depth = 1 }, .{ .width = 2, .height = 1, .depth = 1 });
    }
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), rgba8.bytes[0]);
    try command_buffer.commit();

    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 64 }, r8.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 64, 64, 96 }, rg8.bytes);
    try std.testing.expectEqualSlices(u8, &source_bytes, rgba8.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 96, 64, 32, 128, 128, 96, 64, 160 }, bgra8.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x20, 0x20, 0x40, 0x40 }, r16.bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{
        0x20, 0x20, 0x40, 0x40, 0x60, 0x60, 0x80, 0x80,
        0x40, 0x40, 0x60, 0x60, 0x80, 0x80, 0xa0, 0xa0,
    }, rgba16.bytes);
    var expected_r16_float_bytes = [_]u8{0} ** 4;
    var expected_r16_float = try raster3d.Target.init(&expected_r16_float_bytes, 2, 1, 4, .r16_float);
    expected_r16_float.storeColor(0, 0, .{ @as(f32, 32) / 255.0, 0, 0, 1 });
    expected_r16_float.storeColor(1, 0, .{ @as(f32, 64) / 255.0, 0, 0, 1 });
    try std.testing.expectEqualSlices(u8, &expected_r16_float_bytes, r16_float.bytes);
    const r32_first: f32 = @bitCast(std.mem.readInt(u32, r32.bytes[0..4], .little));
    const r32_second: f32 = @bitCast(std.mem.readInt(u32, r32.bytes[4..8], .little));
    try std.testing.expectApproxEqAbs(@as(f32, 32) / 255.0, r32_first, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f32, 64) / 255.0, r32_second, 0.000001);
}

test "CPU compute encoder preserves deferred Metal 4 copy and fill ordering" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const source_bytes = [_]u8{
        1,  2,  3,  4,  5,  6,  7,  8,  9,  10, 11, 12, 13, 14, 15, 16,
        17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32,
    };
    const source = try createBuffer(device, source_bytes.len, @ptrCast(&source_bytes));
    defer destroyBuffer(source);
    const copied = try createBuffer(device, source_bytes.len, null);
    defer destroyBuffer(copied);
    const texture = try createTexture(device, 4, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const round_trip = try createBuffer(device, source_bytes.len, null);
    defer destroyBuffer(round_trip);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.copyBuffer(source, 0, copied, 0, source_bytes.len);
    try encoder.copyBufferToTexture(source, 0, 16, texture, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 4, .height = 2, .depth = 1 } });
    try encoder.copyTextureToBuffer(texture, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 4, .height = 2, .depth = 1 } }, round_trip, 0, 16);
    try encoder.fillBuffer(copied, 0, 4, 0xa7);
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    try std.testing.expectEqual(@as(u8, 0), copied.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xa7, 0xa7, 0xa7, 0xa7 }, copied.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, source_bytes[4..], copied.bytes[4..]);
    try std.testing.expectEqualSlices(u8, &source_bytes, round_trip.bytes);
}

test "CPU compute encoder resolves Metal 4 indirect thread arguments at commit and offset" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const initial_arguments = [_]u32{ 4, 3, 1, 2, 2, 1 };
    const indirect = try createBuffer(device, 16 + @sizeOf(@TypeOf(initial_arguments)), null);
    defer destroyBuffer(indirect);
    try bufferWrite(indirect, 0, @ptrCast(&initial_arguments), @sizeOf(@TypeOf(initial_arguments)));
    try bufferWrite(indirect, 16, @ptrCast(&initial_arguments), @sizeOf(@TypeOf(initial_arguments)));
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(1);
    try encoder.setTexture(texture, 0);
    try encoder.dispatchThreadsIndirect(indirect);
    try encoder.dispatchThreadsIndirectAtOffset(indirect, 16);
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    const updated_arguments = [_]u32{ 2, 3, 1, 1, 1, 1 };
    try bufferWrite(indirect, 0, @ptrCast(&updated_arguments), @sizeOf(@TypeOf(updated_arguments)));
    try bufferWrite(indirect, 16, @ptrCast(&updated_arguments), @sizeOf(@TypeOf(updated_arguments)));
    try std.testing.expectEqual(@as(u8, 0), texture.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, texture.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 96, 64, 255 }, texture.bytes[2 * texture.stride + 1 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, texture.bytes[3 * texture.stride ..][0..4]);
}

test "no-copy buffers alias caller storage" {
    const device = try createDevice();
    defer destroyDevice(device);
    var bytes = [_]u8{ 1, 2, 3, 4 };
    const buffer = try createBufferNoCopy(device, bytes.len, @ptrCast(&bytes));
    defer destroyBuffer(buffer);
    try std.testing.expectEqual(@intFromPtr(&bytes), @intFromPtr(buffer.bytes.ptr));
    buffer.bytes[0] = 9;
    try std.testing.expectEqual(@as(u8, 9), bytes[0]);
}

test "CPU heap resources alias backing storage and reuse released ranges" {
    const device = try createDevice();
    defer destroyDevice(device);
    const heap = try createHeap(device, 64);
    defer destroyHeap(heap);
    const first = try createBufferInHeap(heap, 16, null);
    const texture = try createTextureInHeap(heap, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    try std.testing.expectEqual(@as(usize, 0), first.heap_allocation_offset);
    try std.testing.expectEqual(@as(usize, 16), texture.heap_allocation_offset);
    try std.testing.expectEqual(@intFromPtr(heap.backing.ptr), @intFromPtr(first.bytes.ptr));
    try std.testing.expectEqual(@intFromPtr(heap.backing.ptr + 16), @intFromPtr(texture.bytes.ptr));
    try std.testing.expectEqual(@as(usize, 32), heap.used);
    try std.testing.expectEqual(@as(usize, 32), heapMaxAvailableSize(heap, 4));

    @memset(texture.bytes, 0xa5);
    destroyBuffer(first);
    try std.testing.expectEqual(@as(usize, 16), heap.used);
    try std.testing.expectError(error.InvalidArgument, createBufferInHeapAtOffset(heap, 8, null, texture.heap_allocation_offset));

    {
        const replacement = try createBufferInHeapAtOffset(heap, 16, null, 0);
        defer destroyBuffer(replacement);
        try std.testing.expectEqual(@intFromPtr(heap.backing.ptr), @intFromPtr(replacement.bytes.ptr));
        @memset(replacement.bytes, 0x3c);
        try std.testing.expectEqualSlices(u8, &[_]u8{0xa5} ** 16, texture.bytes);
        try std.testing.expectEqual(@as(usize, 32), heap.used);
    }
    try std.testing.expectEqual(@as(usize, 16), heap.used);
}

test "texture creation rejects zero-sized resources" {
    const device = try createDevice();
    defer destroyDevice(device);
    try std.testing.expectError(error.InvalidArgument, createTexture(device, 0, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm)));
    try std.testing.expectError(error.InvalidArgument, createTexture(device, 1, 0, @intFromEnum(abi.PixelFormat.rgba8_unorm)));

    const buffer = try createBuffer(device, 16, null);
    defer destroyBuffer(buffer);
    try std.testing.expectError(error.InvalidArgument, createTextureFromBuffer(buffer, 0, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm), 0, 4));
    try std.testing.expectError(error.InvalidArgument, createTextureFromBuffer(buffer, 1, 0, @intFromEnum(abi.PixelFormat.rgba8_unorm), 0, 4));
}

test "buffer-backed textures alias rows without copying" {
    const device = try createDevice();
    defer destroyDevice(device);
    const buffer = try createBuffer(device, 32, null);
    defer destroyBuffer(buffer);
    const texture = try createTextureFromBuffer(buffer, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm), 4, 12);
    defer destroyTexture(texture);
    const values = [_]u8{
        1, 2,  3,  4,  5,  6,  7,  8,  0xee, 0xee, 0xee, 0xee,
        9, 10, 11, 12, 13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd,
    };
    try bufferWrite(buffer, 0, &values, values.len);
    var result: [16]u8 = undefined;
    try textureGetBytes(texture, &result, result.len, 8, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 2, .height = 2, .depth = 1 } });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 5, 6, 7, 8, 0xee, 0xee, 0xee, 0xee, 13, 14, 15, 16, 0xdd, 0xdd, 0xdd, 0xdd }, &result);
    try textureReplaceRegion(texture, .{ .origin = .{ .x = 1, .y = 1, .z = 0 }, .size = .{ .width = 1, .height = 1, .depth = 1 } }, &[_]u8{ 31, 32, 33, 34 }, 4, 4);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 31, 32, 33, 34 }, buffer.bytes[4 + 12 + 4 ..][0..4]);
}

test "raw texture formats preserve their native texel widths" {
    const device = try createDevice();
    defer destroyDevice(device);
    const r16 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r16_unorm));
    defer destroyTexture(r16);
    const r32 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r32_float));
    defer destroyTexture(r32);
    const rg16 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg16_unorm));
    defer destroyTexture(rg16);
    const r32_uint = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r32_uint));
    defer destroyTexture(r32_uint);
    const rgba16_unorm = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(rgba16_unorm);
    const rgba16 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba16_float));
    defer destroyTexture(rgba16);
    const rgba32 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rgba32_float));
    defer destroyTexture(rgba32);
    const rg32 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg32_float));
    defer destroyTexture(rg32);
    try std.testing.expectEqual(@as(usize, 12), r16.bytes.len);
    try std.testing.expectEqual(@as(usize, 24), r32.bytes.len);
    try std.testing.expectEqual(@as(usize, 24), rg16.bytes.len);
    try std.testing.expectEqual(@as(usize, 24), r32_uint.bytes.len);
    try std.testing.expectEqual(@as(usize, 48), rgba16_unorm.bytes.len);
    try std.testing.expectEqual(@as(usize, 48), rgba16.bytes.len);
    try std.testing.expectEqual(@as(usize, 96), rgba32.bytes.len);
    try std.testing.expectEqual(@as(usize, 48), rg32.bytes.len);
    const r16_values = [_]u8{ 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b, 0x0c };
    const r32_values = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23 };
    const rg16_values = [_]u8{ 0x10, 0x11, 0x12, 0x13, 0x20, 0x21, 0x22, 0x23, 0x30, 0x31, 0x32, 0x33, 0x40, 0x41, 0x42, 0x43, 0x50, 0x51, 0x52, 0x53, 0x60, 0x61, 0x62, 0x63 };
    const r32_uint_values = [_]u8{ 0xf0, 0xf1, 0xf2, 0xf3, 0xe0, 0xe1, 0xe2, 0xe3, 0xd0, 0xd1, 0xd2, 0xd3, 0xc0, 0xc1, 0xc2, 0xc3, 0xb0, 0xb1, 0xb2, 0xb3, 0xa0, 0xa1, 0xa2, 0xa3 };
    const rgba16_values = [_]u8{ 0xa0, 0xa1, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7, 0xb0, 0xb1, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xc0, 0xc1, 0xc2, 0xc3, 0xc4, 0xc5, 0xc6, 0xc7, 0xd0, 0xd1, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xe0, 0xe1, 0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7 };
    var rgba32_values: [96]u8 = undefined;
    for (&rgba32_values, 0..) |*byte, index| byte.* = @intCast(index);
    var rg32_values: [48]u8 = undefined;
    for (&rg32_values, 0..) |*byte, index| byte.* = @intCast(255 - index);
    try textureReplaceRegion(r16, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &r16_values, r16_values.len, 6);
    try textureReplaceRegion(r32, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &r32_values, r32_values.len, 12);
    try textureReplaceRegion(rg16, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rg16_values, rg16_values.len, 12);
    try textureReplaceRegion(r32_uint, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &r32_uint_values, r32_uint_values.len, 12);
    try textureReplaceRegion(rgba16_unorm, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rgba16_values, rgba16_values.len, 24);
    try textureReplaceRegion(rgba16, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rgba16_values, rgba16_values.len, 24);
    try textureReplaceRegion(rgba32, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rgba32_values, rgba32_values.len, 48);
    try textureReplaceRegion(rg32, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rg32_values, rg32_values.len, 24);
    try std.testing.expectEqualSlices(u8, &r16_values, r16.bytes);
    try std.testing.expectEqualSlices(u8, &r32_values, r32.bytes);
    try std.testing.expectEqualSlices(u8, &rg16_values, rg16.bytes);
    try std.testing.expectEqualSlices(u8, &r32_uint_values, r32_uint.bytes);
    try std.testing.expectEqualSlices(u8, &rgba16_values, rgba16_unorm.bytes);
    try std.testing.expectEqualSlices(u8, &rgba16_values, rgba16.bytes);
    try std.testing.expectEqualSlices(u8, &rgba32_values, rgba32.bytes);
    try std.testing.expectEqualSlices(u8, &rg32_values, rg32.bytes);
}

test "depth and stencil resource formats preserve raw bytes" {
    const device = try createDevice();
    defer destroyDevice(device);
    const formats = [_]struct { raw: u16, bytes_per_pixel: usize, expected: TextureFormat }{
        .{ .raw = @intFromEnum(abi.PixelFormat.depth16_unorm), .bytes_per_pixel = 2, .expected = .depth16_unorm },
        .{ .raw = @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8), .bytes_per_pixel = 4, .expected = .depth24_unorm_stencil8 },
        .{ .raw = @intFromEnum(abi.PixelFormat.depth32_float_stencil8), .bytes_per_pixel = 8, .expected = .depth32_float_stencil8 },
        .{ .raw = @intFromEnum(abi.PixelFormat.x32_stencil8), .bytes_per_pixel = 8, .expected = .x32_stencil8 },
        .{ .raw = @intFromEnum(abi.PixelFormat.x24_stencil8), .bytes_per_pixel = 4, .expected = .x24_stencil8 },
    };
    var source: [3 * 2 * 8]u8 = undefined;
    var copied: [3 * 2 * 8]u8 = undefined;
    for (formats, 0..) |format, format_index| {
        const texture = try createTexture(device, 3, 2, format.raw);
        defer destroyTexture(texture);
        const byte_count = 3 * 2 * format.bytes_per_pixel;
        for (source[0..byte_count], 0..) |*byte, index| byte.* = @intCast((index * 31 + format_index * 47 + 3) & 0xff);
        @memset(copied[0..byte_count], 0);
        try std.testing.expectEqual(format.expected, texture.format);
        try std.testing.expectEqual(@as(usize, byte_count), texture.bytes.len);
        try textureReplaceRegion(texture, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, source[0..byte_count].ptr, byte_count, 3 * format.bytes_per_pixel);
        try textureGetBytes(texture, copied[0..byte_count].ptr, byte_count, 3 * format.bytes_per_pixel, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } });
        try std.testing.expectEqualSlices(u8, source[0..byte_count], copied[0..byte_count]);
    }

    const buffer = try createBuffer(device, 64, null);
    defer destroyBuffer(buffer);
    for (formats, 0..) |format, format_index| {
        const row_bytes = 3 * format.bytes_per_pixel;
        const bytes_per_row = std.mem.alignForward(usize, 3 * format.bytes_per_pixel, 4);
        const texture = try createTextureFromBuffer(buffer, 3, 2, format.raw, 4, bytes_per_row);
        defer destroyTexture(texture);
        const byte_count = 3 * 2 * format.bytes_per_pixel;
        const source_length = bytes_per_row + row_bytes;
        for (source[0..source_length], 0..) |*byte, index| byte.* = @intCast((index * 19 + format_index * 61 + 11) & 0xff);
        @memset(copied[0..byte_count], 0);
        try textureReplaceRegion(texture, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, source[0..source_length].ptr, source_length, bytes_per_row);
        try textureGetBytes(texture, copied[0..byte_count].ptr, byte_count, row_bytes, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } });
        for (0..2) |row| {
            try std.testing.expectEqualSlices(u8, source[row * bytes_per_row ..][0..row_bytes], copied[row * row_bytes ..][0..row_bytes]);
        }
    }
}

test "narrow unorm texture formats preserve bytes through checked transfers" {
    const device = try createDevice();
    defer destroyDevice(device);
    const r8 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.r8_unorm));
    defer destroyTexture(r8);
    const rg8 = try createTexture(device, 3, 2, @intFromEnum(abi.PixelFormat.rg8_unorm));
    defer destroyTexture(rg8);
    try std.testing.expectEqual(@as(usize, 6), r8.bytes.len);
    try std.testing.expectEqual(@as(usize, 12), rg8.bytes.len);
    const r8_values = [_]u8{ 1, 2, 3, 9, 8, 7 };
    const rg8_values = [_]u8{ 10, 11, 20, 21, 30, 31, 40, 41, 50, 51, 60, 61 };
    try textureReplaceRegion(r8, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &r8_values, r8_values.len, 3);
    try textureReplaceRegion(rg8, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, &rg8_values, rg8_values.len, 6);
    try std.testing.expectEqualSlices(u8, &r8_values, r8.bytes);
    try std.testing.expectEqualSlices(u8, &rg8_values, rg8.bytes);
    var copied: [12]u8 = undefined;
    try textureGetBytes(rg8, &copied, copied.len, 6, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } });
    try std.testing.expectEqualSlices(u8, &rg8_values, &copied);
}

test "signed normalized and sRGB texture formats preserve native widths" {
    const device = try createDevice();
    defer destroyDevice(device);
    const formats = [_]struct { format: u16, bytes_per_pixel: usize }{
        .{ .format = @intFromEnum(abi.PixelFormat.r8_snorm), .bytes_per_pixel = 1 },
        .{ .format = @intFromEnum(abi.PixelFormat.r16_snorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.rg8_snorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.rg16_snorm), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgba8_snorm), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgba16_snorm), .bytes_per_pixel = 8 },
        .{ .format = @intFromEnum(abi.PixelFormat.r8_unorm_srgb), .bytes_per_pixel = 1 },
        .{ .format = @intFromEnum(abi.PixelFormat.rg8_unorm_srgb), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.bgra8_unorm_srgb), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.a8_unorm), .bytes_per_pixel = 1 },
        .{ .format = @intFromEnum(abi.PixelFormat.b5g6r5_unorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.a1bgr5_unorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.abgr4_unorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.bgr5a1_unorm), .bytes_per_pixel = 2 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgb10a2_unorm), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgb10a2_uint), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.rg11b10_float), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.rgb9e5_float), .bytes_per_pixel = 4 },
        .{ .format = @intFromEnum(abi.PixelFormat.bgr10a2_unorm), .bytes_per_pixel = 4 },
    };
    var values: [48]u8 = undefined;
    for (formats, 0..) |format, format_index| {
        const byte_count = 3 * 2 * format.bytes_per_pixel;
        for (values[0..byte_count], 0..) |*byte, index| byte.* = @intCast((index * 31 + format_index * 7 + 3) & 0xff);
        const texture = try createTexture(device, 3, 2, format.format);
        try textureReplaceRegion(texture, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 3, .height = 2, .depth = 1 } }, values[0..byte_count].ptr, byte_count, 3 * format.bytes_per_pixel);
        try std.testing.expectEqual(@as(usize, byte_count), texture.bytes.len);
        try std.testing.expectEqualSlices(u8, values[0..byte_count], texture.bytes);
        destroyTexture(texture);
    }
}

test "compatible texture views reinterpret shared storage" {
    const device = try createDevice();
    defer destroyDevice(device);
    const source = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(source);
    const initial = [_]u8{
        0x00, 0x00, 0x80, 0x3f, 0x11, 0x22, 0x33, 0x44,
        0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc,
    };
    try textureReplaceRegion(source, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 2, .height = 2, .depth = 1 } }, &initial, initial.len, 8);
    const view = try createTextureView(source, @intFromEnum(abi.PixelFormat.r32_float));
    defer destroyTexture(view);
    try std.testing.expectEqual(TextureFormat.r32_float, view.format);
    try std.testing.expectEqual(@intFromPtr(source.bytes.ptr), @intFromPtr(view.bytes.ptr));
    var copied: [16]u8 = undefined;
    try textureGetBytes(view, &copied, copied.len, 8, .{ .origin = .{ .x = 0, .y = 0, .z = 0 }, .size = .{ .width = 2, .height = 2, .depth = 1 } });
    try std.testing.expectEqualSlices(u8, &initial, &copied);

    const replacement = [_]u8{ 0xde, 0xad, 0xbe, 0xef };
    try textureReplaceRegion(view, .{ .origin = .{ .x = 1, .y = 0, .z = 0 }, .size = .{ .width = 1, .height = 1, .depth = 1 } }, &replacement, replacement.len, 4);
    try std.testing.expectEqualSlices(u8, &replacement, source.bytes[4..8]);

    const same_size_views = [_]struct { raw: u16, format: TextureFormat }{
        .{ .raw = @intFromEnum(abi.PixelFormat.rgba8_unorm_srgb), .format = .rgba8_unorm_srgb },
        .{ .raw = @intFromEnum(abi.PixelFormat.rgba8_snorm), .format = .rgba8_snorm },
        .{ .raw = @intFromEnum(abi.PixelFormat.rgb10a2_unorm), .format = .rgb10a2_unorm },
        .{ .raw = @intFromEnum(abi.PixelFormat.rg11b10_float), .format = .rg11b10_float },
    };
    for (same_size_views) |case| {
        const compatible = try createTextureView(source, case.raw);
        defer destroyTexture(compatible);
        try std.testing.expectEqual(case.format, compatible.format);
        try std.testing.expectEqual(@intFromPtr(source.bytes.ptr), @intFromPtr(compatible.bytes.ptr));
    }
    try std.testing.expectError(error.UnsupportedFormat, createTextureView(source, @intFromEnum(abi.PixelFormat.r16_float)));
    try std.testing.expectError(error.UnsupportedFormat, createTextureView(source, @intFromEnum(abi.PixelFormat.depth32_float)));

    const wide_source = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba16_unorm));
    defer destroyTexture(wide_source);
    const wide_views = [_]struct { raw: u16, format: TextureFormat }{
        .{ .raw = @intFromEnum(abi.PixelFormat.rgba16_float), .format = .rgba16_float },
        .{ .raw = @intFromEnum(abi.PixelFormat.rgba16_uint), .format = .rgba16_uint },
        .{ .raw = @intFromEnum(abi.PixelFormat.rg32_float), .format = .rg32_float },
    };
    for (wide_views) |case| {
        const compatible = try createTextureView(wide_source, case.raw);
        defer destroyTexture(compatible);
        try std.testing.expectEqual(case.format, compatible.format);
        try std.testing.expectEqual(@intFromPtr(wide_source.bytes.ptr), @intFromPtr(compatible.bytes.ptr));
    }

    const depth_stencil = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.depth32_float_stencil8));
    defer destroyTexture(depth_stencil);
    const x32_view = try createTextureView(depth_stencil, @intFromEnum(abi.PixelFormat.x32_stencil8));
    defer destroyTexture(x32_view);
    try std.testing.expectEqual(TextureFormat.x32_stencil8, x32_view.format);
    try std.testing.expectEqual(@intFromPtr(depth_stencil.bytes.ptr), @intFromPtr(x32_view.bytes.ptr));
    const depth_from_x32 = try createTextureView(x32_view, @intFromEnum(abi.PixelFormat.depth32_float_stencil8));
    defer destroyTexture(depth_from_x32);
    try std.testing.expectEqual(TextureFormat.depth32_float_stencil8, depth_from_x32.format);
    try std.testing.expectEqual(@intFromPtr(depth_stencil.bytes.ptr), @intFromPtr(depth_from_x32.bytes.ptr));

    const legacy_depth_stencil = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8));
    defer destroyTexture(legacy_depth_stencil);
    const x24_view = try createTextureView(legacy_depth_stencil, @intFromEnum(abi.PixelFormat.x24_stencil8));
    defer destroyTexture(x24_view);
    try std.testing.expectEqual(TextureFormat.x24_stencil8, x24_view.format);
    try std.testing.expectEqual(@intFromPtr(legacy_depth_stencil.bytes.ptr), @intFromPtr(x24_view.bytes.ptr));
    const legacy_depth_from_x24 = try createTextureView(x24_view, @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8));
    defer destroyTexture(legacy_depth_from_x24);
    try std.testing.expectEqual(TextureFormat.depth24_unorm_stencil8, legacy_depth_from_x24.format);
    try std.testing.expectEqual(@intFromPtr(legacy_depth_stencil.bytes.ptr), @intFromPtr(legacy_depth_from_x24.bytes.ptr));
}

test "indexed render encoding produces the same pixels as direct vertices" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const indices = [_]u16{ 0, 1, 2 };
    const index_buffer = try createBuffer(device, @sizeOf(@TypeOf(indices)), @ptrCast(&indices));
    defer destroyBuffer(index_buffer);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try encoder.drawIndexedPrimitives(.triangle, 3, .uint16, index_buffer, 0, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expect(std.mem.indexOfScalar(u8, texture.bytes, 255) != null);
}

test "render state validation rejects invalid CPU Metal state" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{} });
    try std.testing.expectError(error.InvalidArgument, encoder.setViewport(.{
        .origin_x = 0,
        .origin_y = 0,
        .width = -1,
        .height = 1,
        .znear = 0,
        .zfar = 1,
    }));
    try std.testing.expectError(error.InvalidArgument, encoder.setDepthTestBounds(0.75, 0.25));
    try encoder.setFragmentSamplerMaxAnisotropy(16);
    try std.testing.expectError(error.InvalidArgument, encoder.setFragmentSamplerMaxAnisotropy(0));
    try std.testing.expectError(error.InvalidArgument, encoder.setFragmentSamplerMaxAnisotropy(17));
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
}

test "CPU position fragment uses attachment-global top-left coordinates" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 5, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.setViewport(.{
        .origin_x = 1,
        .origin_y = 1,
        .width = 3,
        .height = 2,
        .znear = 0,
        .zfar = 1,
    });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.setFragmentPositionGradientEnabled(true);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 64, 64, 255 }, texture.bytes[(1 * 5 + 1) * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, texture.bytes[0..4]);
}

test "CPU uniform fragment bytes override interpolated color" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 } },
    };
    const uniform = abi.Color{ .red = 0.2, .green = 0.6, .blue = 0.9, .alpha = 0.4 };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.setFragmentUniformEnabled(true);
    try encoder.setFragmentBytes(@ptrCast(&uniform), @sizeOf(abi.Color), 0);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 51, 153, 230, 102 }, texture.bytes[0..4]);
}

test "CPU uniform fragment buffer reads at commit with offset" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 1, .blue = 1, .alpha = 1 } },
    };
    const initial = abi.Color{ .red = 0.9, .green = 0.1, .blue = 0.2, .alpha = 1 };
    const updated = abi.Color{ .red = 0.2, .green = 0.6, .blue = 0.88, .alpha = 0.4 };
    const uniform_buffer = try createBuffer(device, 24, null);
    defer destroyBuffer(uniform_buffer);
    try bufferWrite(uniform_buffer, 8, @ptrCast(&initial), @sizeOf(abi.Color));
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.setFragmentUniformEnabled(true);
    try encoder.setFragmentBuffer(uniform_buffer, 0, 0);
    try encoder.setFragmentBufferOffset(8, 0);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try bufferWrite(uniform_buffer, 8, @ptrCast(&updated), @sizeOf(abi.Color));
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 51, 153, 224, 102 }, texture.bytes[0..4]);
}

test "CPU vertex buffer bindings read at commit" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const initial = [_]abi.Vertex{
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const updated = [_]abi.Vertex{
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(initial)), @ptrCast(&initial));
    defer destroyBuffer(vertex_buffer);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try encoder.drawPrimitives(.triangle, 0, initial.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try bufferWrite(vertex_buffer, 0, @ptrCast(&updated), @sizeOf(@TypeOf(updated)));
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, texture.bytes[40..44]);
}

test "CPU indexed draws read the index buffer at commit" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const initial_indices = [_]u16{ 0, 1, 2, 0, 2, 3 };
    const updated_indices = [_]u16{ 6, 7, 8, 6, 8, 9 };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const index_buffer = try createBuffer(device, @sizeOf(@TypeOf(initial_indices)), @ptrCast(&initial_indices));
    defer destroyBuffer(index_buffer);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try encoder.drawIndexedPrimitives(.triangle, initial_indices.len, .uint16, index_buffer, 0, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try bufferWrite(index_buffer, 0, @ptrCast(&updated_indices), @sizeOf(@TypeOf(updated_indices)));
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, texture.bytes[40..44]);
}

test "CPU indirect render arguments read at commit" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, -0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ 0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .{ .position = .{ -0.5, 0.5, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const initial_direct_arguments = [_]u32{ 6, 1, 0, 0 };
    const updated_direct_arguments = [_]u32{ 6, 1, 6, 0 };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const direct_arguments = try createBuffer(device, @sizeOf(@TypeOf(initial_direct_arguments)), @ptrCast(&initial_direct_arguments));
    defer destroyBuffer(direct_arguments);
    const direct_texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(direct_texture);
    var direct_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(direct_command_buffer);
    var direct_encoder = try beginRender(direct_command_buffer, direct_texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try direct_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try direct_encoder.drawPrimitivesIndirect(.triangle, direct_arguments, 0);
    try direct_encoder.endEncoding();
    destroyRenderEncoder(direct_encoder);
    try bufferWrite(direct_arguments, 0, @ptrCast(&updated_direct_arguments), @sizeOf(@TypeOf(updated_direct_arguments)));
    try direct_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, direct_texture.bytes[40..44]);

    const indices = [_]u16{ 0, 1, 2, 0, 2, 3, 6, 7, 8, 6, 8, 11 };
    const initial_indexed_arguments = [_]u32{ 6, 1, 0, 0, 0 };
    const updated_indexed_arguments = [_]u32{ 6, 1, 6, 0, 0 };
    const index_buffer = try createBuffer(device, @sizeOf(@TypeOf(indices)), @ptrCast(&indices));
    defer destroyBuffer(index_buffer);
    const indexed_arguments = try createBuffer(device, @sizeOf(@TypeOf(initial_indexed_arguments)), @ptrCast(&initial_indexed_arguments));
    defer destroyBuffer(indexed_arguments);
    const indexed_texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(indexed_texture);
    var indexed_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(indexed_command_buffer);
    var indexed_encoder = try beginRender(indexed_command_buffer, indexed_texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try indexed_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try indexed_encoder.drawIndexedPrimitivesIndirect(.triangle, .uint16, index_buffer, 0, indexed_arguments, 0);
    try indexed_encoder.endEncoding();
    destroyRenderEncoder(indexed_encoder);
    try bufferWrite(indexed_arguments, 0, @ptrCast(&updated_indexed_arguments), @sizeOf(@TypeOf(updated_indexed_arguments)));
    try indexed_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, indexed_texture.bytes[40..44]);

    const base_vertex_indices = [_]u32{ 0, 1, 2, 0, 2, 5 };
    const base_vertex_arguments = [_]u32{ 6, 1, 0, 6, 0 };
    const base_vertex_index_buffer = try createBuffer(device, @sizeOf(@TypeOf(base_vertex_indices)), @ptrCast(&base_vertex_indices));
    defer destroyBuffer(base_vertex_index_buffer);
    const base_vertex_argument_buffer = try createBuffer(device, @sizeOf(@TypeOf(base_vertex_arguments)), @ptrCast(&base_vertex_arguments));
    defer destroyBuffer(base_vertex_argument_buffer);
    const base_vertex_texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(base_vertex_texture);
    var base_vertex_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(base_vertex_command_buffer);
    var base_vertex_encoder = try beginRender(base_vertex_command_buffer, base_vertex_texture, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    try base_vertex_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try base_vertex_encoder.drawIndexedPrimitivesIndirect(.triangle, .uint32, base_vertex_index_buffer, 0, base_vertex_argument_buffer, 0);
    try base_vertex_encoder.endEncoding();
    destroyRenderEncoder(base_vertex_encoder);
    try base_vertex_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, direct_texture.bytes, base_vertex_texture.bytes);
}

test "depth texture attachment rejects farther fragments" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.depth32_float));
    defer destroyTexture(depth);
    const far = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const near = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less_equal), true);
    try encoder.setVertexBytes(@ptrCast(&far), @sizeOf(@TypeOf(far)), 0);
    try encoder.drawPrimitives(.triangle, 0, far.len, 1);
    try encoder.setVertexBytes(@ptrCast(&near), @sizeOf(@TypeOf(near)), 0);
    try encoder.drawPrimitives(.triangle, 0, near.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, color.bytes[0..4]);
}

test "CPU render encoder maps direct instances and base instance to array color layers" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    var layers: [4]*Texture = undefined;
    for (&layers) |*layer| {
        layer.* = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (layers) |layer| destroyTexture(layer);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, layers[0], .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    });
    try encoder.setRenderTargetArray(&layers, layers.len);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitivesWithBaseInstance(.triangle, 0, vertices.len, layers.len - 1, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, layers[0].bytes[0..4]);
    for (layers[1..]) |layer| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, layer.bytes[0..4]);
    }
}

test "CPU render encoder maps indirect and indexed base instances to array color layers" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const arguments = [_]u32{ vertices.len, 2, 0, 1 };
    const argument_buffer = try createBuffer(device, @sizeOf(@TypeOf(arguments)), @ptrCast(&arguments));
    defer destroyBuffer(argument_buffer);
    var layers: [3]*Texture = undefined;
    for (&layers) |*layer| {
        layer.* = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (layers) |layer| destroyTexture(layer);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, layers[0], .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    });
    try encoder.setRenderTargetArray(&layers, layers.len);
    try encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try encoder.drawPrimitivesIndirect(.triangle, argument_buffer, 0);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, layers[0].bytes[0..4]);
    for (layers[1..]) |layer| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, layer.bytes[0..4]);
    }

    const indices = [_]u16{ 0, 1, 2, 3, 4, 5 };
    const index_buffer = try createBuffer(device, @sizeOf(@TypeOf(indices)), @ptrCast(&indices));
    defer destroyBuffer(index_buffer);
    const indexed_arguments = [_]u32{ indices.len, 2, 0, 0, 1 };
    const indexed_argument_buffer = try createBuffer(device, @sizeOf(@TypeOf(indexed_arguments)), @ptrCast(&indexed_arguments));
    defer destroyBuffer(indexed_argument_buffer);
    var indexed_layers: [3]*Texture = undefined;
    for (&indexed_layers) |*layer| {
        layer.* = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (indexed_layers) |layer| destroyTexture(layer);
    var indexed_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(indexed_command_buffer);
    var indexed_encoder = try beginRender(indexed_command_buffer, indexed_layers[0], .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    });
    try indexed_encoder.setRenderTargetArray(&indexed_layers, indexed_layers.len);
    try indexed_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try indexed_encoder.drawIndexedPrimitivesIndirect(.triangle, .uint16, index_buffer, 0, indexed_argument_buffer, 0);
    try indexed_encoder.endEncoding();
    destroyRenderEncoder(indexed_encoder);
    try indexed_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, indexed_layers[0].bytes[0..4]);
    for (indexed_layers[1..]) |layer| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, layer.bytes[0..4]);
    }

    var direct_indexed_layers: [4]*Texture = undefined;
    for (&direct_indexed_layers) |*layer| {
        layer.* = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (direct_indexed_layers) |layer| destroyTexture(layer);
    var direct_indexed_command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(direct_indexed_command_buffer);
    var direct_indexed_encoder = try beginRender(direct_indexed_command_buffer, direct_indexed_layers[0], .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    });
    try direct_indexed_encoder.setRenderTargetArray(&direct_indexed_layers, direct_indexed_layers.len);
    try direct_indexed_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try direct_indexed_encoder.drawIndexedPrimitivesWithBaseVertexAndInstance(.triangle, indices.len, .uint16, index_buffer, 0, direct_indexed_layers.len - 1, 0, 1);
    try direct_indexed_encoder.endEncoding();
    destroyRenderEncoder(direct_indexed_encoder);
    try direct_indexed_command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, direct_indexed_layers[0].bytes[0..4]);
    for (direct_indexed_layers[1..]) |layer| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, layer.bytes[0..4]);
    }
}

test "CPU render encoder expands vertex amplification on the top-left grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.80, -0.70, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.75, -0.35, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -0.20, 0.82, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const mappings = [_]abi.VertexAmplificationViewMapping{
        .{ .viewport_array_index_offset = 0, .render_target_array_index_offset = 0 },
        .{ .viewport_array_index_offset = 1, .render_target_array_index_offset = 1 },
    };
    var layers: [2]*Texture = undefined;
    var references: [2]*Texture = undefined;
    for (&layers, &references) |*layer, *reference| {
        layer.* = try createTexture(device, 7, 5, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        reference.* = try createTexture(device, 7, 5, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    }
    defer for (layers, &references) |layer, *reference| {
        destroyTexture(layer);
        destroyTexture(reference.*);
    };
    const pass = abi.RenderPassDescriptor{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0.13, .green = 0.21, .blue = 0.31, .alpha = 1 } },
    };
    const viewports = [_]raster3d.PreciseViewport{
        .{ .origin_x = 1.25, .origin_y = 0.75, .width = 5, .height = 4, .znear = 0, .zfar = 1 },
        .{ .origin_x = 0.25, .origin_y = 1.75, .width = 5, .height = 3, .znear = 0, .zfar = 1 },
    };
    const scissors = [_]abi.ScissorRect{
        .{ .x = 1, .y = 0, .width = 6, .height = 5 },
        .{ .x = 0, .y = 1, .width = 7, .height = 4 },
    };

    var amplified_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(amplified_commands);
    var amplified_encoder = try beginRender(amplified_commands, layers[0], pass);
    try amplified_encoder.setRenderTargetArray(&layers, layers.len);
    try amplified_encoder.setViewportsPrecise(&viewports, viewports.len);
    try amplified_encoder.setScissorRects(&scissors, scissors.len);
    try amplified_encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try amplified_encoder.setVertexAmplificationCount(2, &mappings);
    try amplified_encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try amplified_encoder.endEncoding();
    destroyRenderEncoder(amplified_encoder);

    var reference_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(reference_commands);
    for (references, 0..) |reference, index| {
        var reference_encoder = try beginRender(reference_commands, reference, pass);
        try reference_encoder.setViewportPrecise(viewports[index]);
        try reference_encoder.setScissorRect(scissors[index]);
        try reference_encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
        try reference_encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
        try reference_encoder.endEncoding();
        destroyRenderEncoder(reference_encoder);
    }
    try amplified_commands.commit();
    try reference_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, amplified_commands.status);
    try std.testing.expectEqual(CommandStatus.completed, reference_commands.status);
    for (layers, &references) |layer, *reference| {
        try std.testing.expectEqualSlices(u8, reference.*.bytes, layer.bytes);
    }
}

test "CPU render encoder fails closed for an unrecorded amplified viewport" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 1, 1, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{ .color = .{ .load_action = .clear, .store_action = .store } });
    const mappings = [_]abi.VertexAmplificationViewMapping{
        .{ .viewport_array_index_offset = 1, .render_target_array_index_offset = 0 },
        .{ .viewport_array_index_offset = 0, .render_target_array_index_offset = 0 },
    };
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.setVertexAmplificationCount(2, &mappings);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try std.testing.expectError(error.InvalidArgument, command_buffer.commit());
}

test "CPU layered triangle patches map base instances on the top-left grid" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const vertex_buffer = try createBuffer(device, @sizeOf(@TypeOf(vertices)), @ptrCast(&vertices));
    defer destroyBuffer(vertex_buffer);
    const factors = [_]u16{
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
    };
    const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
    defer destroyBuffer(factor_buffer);

    var patch_layers: [3]*Texture = undefined;
    var reference_layers: [3]*Texture = undefined;
    for (&patch_layers, &reference_layers) |*patch_layer, *reference_layer| {
        patch_layer.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
        reference_layer.* = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    }
    defer for (patch_layers, &reference_layers) |patch_layer, *reference_layer| {
        destroyTexture(patch_layer);
        destroyTexture(reference_layer.*);
    };

    const pass = abi.RenderPassDescriptor{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    const viewport = abi.Viewport{ .origin_x = 1, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 };
    const scissor = abi.ScissorRect{ .x = 1, .y = 1, .width = 3, .height = 2 };

    var patch_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(patch_commands);
    var patch_encoder = try beginRender(patch_commands, patch_layers[0], pass);
    try patch_encoder.setRenderTargetArray(&patch_layers, patch_layers.len);
    try patch_encoder.setViewport(viewport);
    try patch_encoder.setScissorRect(scissor);
    try patch_encoder.setVertexBuffer(vertex_buffer, 0, 0);
    try patch_encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf([4]u16));
    try patch_encoder.drawPatches(1, 3, 0, 1, null, 0, 2, 1, .none, null, 0);
    try patch_encoder.endEncoding();
    destroyRenderEncoder(patch_encoder);

    var reference_commands = try createCommandBuffer(queue);
    defer destroyCommandBuffer(reference_commands);
    for (reference_layers, 0..) |reference_layer, layer| {
        var reference_encoder = try beginRender(reference_commands, reference_layer, pass);
        try reference_encoder.setViewport(viewport);
        try reference_encoder.setScissorRect(scissor);
        if (layer != 0) {
            try reference_encoder.setVertexBuffer(vertex_buffer, 0, 0);
            try reference_encoder.drawPrimitives(.triangle, 0, 3, 1);
        }
        try reference_encoder.endEncoding();
        destroyRenderEncoder(reference_encoder);
    }

    try patch_commands.commit();
    try reference_commands.commit();
    try std.testing.expectEqual(CommandStatus.completed, patch_commands.status);
    try std.testing.expectEqual(CommandStatus.completed, reference_commands.status);
    for (patch_layers, reference_layers) |patch_layer, reference_layer| {
        try std.testing.expectEqualSlices(u8, patch_layer.bytes, reference_layer.bytes);
    }
}

test "CPU layered triangle patches preserve per-layer depth and stencil" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const far_vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const near_vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
    };
    const factors = [_]u16{
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
        0x3c00, 0x3c00, 0x3c00, 0x3c00,
    };
    const factor_buffer = try createBuffer(device, @sizeOf(@TypeOf(factors)), @ptrCast(&factors));
    defer destroyBuffer(factor_buffer);
    var colors: [3]*Texture = undefined;
    var depths: [3]*Texture = undefined;
    var stencils: [3]*Texture = undefined;
    for (0..colors.len) |index| {
        colors[index] = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        depths[index] = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.depth32_float));
        stencils[index] = try createTexture(device, 5, 3, @intFromEnum(abi.PixelFormat.stencil8));
    }
    defer for (0..colors.len) |index| {
        destroyTexture(colors[index]);
        destroyTexture(depths[index]);
        destroyTexture(stencils[index]);
    };
    const pass = abi.RenderPassDescriptor{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, colors[0], pass);
    try encoder.setRenderTargetArray(&colors, colors.len);
    try encoder.setDepthTextureArray(&depths, depths.len);
    try encoder.setStencilTextureArray(&stencils, stencils.len, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 0);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less), true);
    try encoder.setStencilState(true, @intFromEnum(abi.CompareFunction.always), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.replace), 0xff, 0xff);
    try encoder.setStencilReference(7, 7);
    try encoder.setViewport(.{ .origin_x = 1, .origin_y = 1, .width = 3, .height = 2, .znear = 0, .zfar = 1 });
    try encoder.setScissorRect(.{ .x = 1, .y = 1, .width = 3, .height = 2 });
    try encoder.setTessellationFactorBuffer(factor_buffer, 0, @sizeOf([4]u16));
    try encoder.setVertexBytes(@ptrCast(&far_vertices), @sizeOf(@TypeOf(far_vertices)), 0);
    try encoder.drawPatches(1, 3, 0, 1, null, 0, 2, 1, .none, null, 0);
    try encoder.setVertexBytes(@ptrCast(&near_vertices), @sizeOf(@TypeOf(near_vertices)), 0);
    try encoder.drawPatches(1, 3, 0, 1, null, 0, 2, 1, .none, null, 0);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    const in_bounds_pixel = (1 * 5 + 2) * 4;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, colors[0].bytes[in_bounds_pixel .. in_bounds_pixel + 4]);
    for (colors[1..]) |color| {
        try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, color.bytes[in_bounds_pixel .. in_bounds_pixel + 4]);
    }
    const clear_depth_value: f32 = 1.0;
    const clear_depth = std.mem.asBytes(&clear_depth_value);
    const near_depth_value: f32 = 0.25;
    const near_depth = std.mem.asBytes(&near_depth_value);
    const in_bounds_depth = in_bounds_pixel;
    try std.testing.expectEqualSlices(u8, clear_depth, depths[0].bytes[in_bounds_depth .. in_bounds_depth + 4]);
    for (depths[1..]) |depth| try std.testing.expectEqualSlices(u8, near_depth, depth.bytes[in_bounds_depth .. in_bounds_depth + 4]);
    const in_bounds_stencil = 1 * 5 + 2;
    try std.testing.expectEqual(@as(u8, 0), stencils[0].bytes[in_bounds_stencil]);
    for (stencils[1..]) |stencil| try std.testing.expectEqual(@as(u8, 7), stencil.bytes[in_bounds_stencil]);
}

test "CPU layered depth and stencil attachments stay per-layer" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const far_vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const near_vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
    };
    var colors: [3]*Texture = undefined;
    var depths: [3]*Texture = undefined;
    var stencils: [3]*Texture = undefined;
    for (0..colors.len) |index| {
        colors[index] = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        depths[index] = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.depth32_float));
        stencils[index] = try createTexture(device, 2, 2, @intFromEnum(abi.PixelFormat.stencil8));
    }
    defer for (0..colors.len) |index| {
        destroyTexture(colors[index]);
        destroyTexture(depths[index]);
        destroyTexture(stencils[index]);
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, colors[0], .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setRenderTargetArray(&colors, colors.len);
    try encoder.setDepthTextureArray(&depths, depths.len);
    try encoder.setStencilTextureArray(&stencils, stencils.len, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 7);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less), true);
    try encoder.setStencilState(true, @intFromEnum(abi.CompareFunction.always), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.replace), 0xff, 0xff);
    try encoder.setStencilReference(7, 7);
    try encoder.setVertexBytes(@ptrCast(&far_vertices), @sizeOf(@TypeOf(far_vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, far_vertices.len, colors.len);
    try encoder.setVertexBytes(@ptrCast(&near_vertices), @sizeOf(@TypeOf(near_vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, near_vertices.len, colors.len);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    for (colors) |color| try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, color.bytes[0..4]);
    for (stencils) |stencil| try std.testing.expectEqual(@as(u8, 7), stencil.bytes[0]);
}

test "CPU render encoder leaves depth disabled until a state is bound" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.depth32_float));
    defer destroyTexture(depth);
    const near = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
    };
    const far = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setVertexBytes(@ptrCast(&near), @sizeOf(@TypeOf(near)), 0);
    try encoder.drawPrimitives(.triangle, 0, near.len, 1);
    try encoder.setVertexBytes(@ptrCast(&far), @sizeOf(@TypeOf(far)), 0);
    try encoder.drawPrimitives(.triangle, 0, far.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
}

test "depth16 texture attachment stores normalized CPU depth" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.depth16_unorm));
    defer destroyTexture(depth);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less_equal), true);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
    for (0..4 * 4) |index| {
        try std.testing.expectEqual(@as(u8, 0), depth.bytes[index * 2]);
        try std.testing.expectEqual(@as(u8, 0x40), depth.bytes[index * 2 + 1]);
    }
}

test "combined depth stencil textures pack CPU attachment results" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const combined_formats = [_]struct { raw: u16, bytes_per_pixel: usize, depth_bytes: [3]u8, stencil_offset: usize }{
        .{ .raw = @intFromEnum(abi.PixelFormat.depth24_unorm_stencil8), .bytes_per_pixel = 4, .depth_bytes = .{ 0, 0, 0x40 }, .stencil_offset = 3 },
        .{ .raw = @intFromEnum(abi.PixelFormat.depth32_float_stencil8), .bytes_per_pixel = 8, .depth_bytes = .{ 0, 0, 0x80 }, .stencil_offset = 4 },
    };
    for (combined_formats) |format| {
        const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        defer destroyTexture(color);
        const depth_stencil = try createTexture(device, 4, 4, format.raw);
        defer destroyTexture(depth_stencil);
        var command_buffer = try createCommandBuffer(queue);
        defer destroyCommandBuffer(command_buffer);
        var encoder = try beginRender(command_buffer, color, .{
            .color = .{ .load_action = .clear, .store_action = .store },
            .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
        });
        try encoder.setDepthTexture(depth_stencil);
        try encoder.setStencilTexture(depth_stencil, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 3);
        try encoder.setPipelineFormatsWithStencil(@intFromEnum(abi.PixelFormat.rgba8_unorm), format.raw, format.raw);
        try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less_equal), true);
        try encoder.setStencilState(true, @intFromEnum(abi.CompareFunction.equal), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
        try encoder.setStencilState(false, @intFromEnum(abi.CompareFunction.equal), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
        try encoder.setStencilReference(3, 3);
        try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
        try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
        try encoder.endEncoding();
        destroyRenderEncoder(encoder);
        try command_buffer.commit();
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
        for (0..4 * 4) |index| {
            const offset = index * format.bytes_per_pixel;
            try std.testing.expectEqualSlices(u8, &format.depth_bytes, depth_stencil.bytes[offset..][0..3]);
            try std.testing.expectEqual(@as(u8, 4), depth_stencil.bytes[offset + format.stencil_offset]);
        }
    }
}

test "x stencil textures pack CPU stencil attachment results" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    const x_formats = [_]struct { raw: u16, bytes_per_pixel: usize, stencil_offset: usize }{
        .{ .raw = @intFromEnum(abi.PixelFormat.x24_stencil8), .bytes_per_pixel = 4, .stencil_offset = 3 },
        .{ .raw = @intFromEnum(abi.PixelFormat.x32_stencil8), .bytes_per_pixel = 8, .stencil_offset = 4 },
    };
    for (x_formats) |format| {
        const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
        defer destroyTexture(color);
        const stencil = try createTexture(device, 4, 4, format.raw);
        defer destroyTexture(stencil);
        @memset(stencil.bytes, 0xa5);
        var command_buffer = try createCommandBuffer(queue);
        defer destroyCommandBuffer(command_buffer);
        var encoder = try beginRender(command_buffer, color, .{
            .color = .{ .load_action = .clear, .store_action = .store },
        });
        try encoder.setStencilTexture(stencil, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 3);
        try encoder.setPipelineFormatsWithStencil(@intFromEnum(abi.PixelFormat.rgba8_unorm), 0, format.raw);
        try encoder.setStencilState(true, @intFromEnum(abi.CompareFunction.equal), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
        try encoder.setStencilState(false, @intFromEnum(abi.CompareFunction.equal), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
        try encoder.setStencilReference(3, 3);
        try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
        try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
        try encoder.endEncoding();
        destroyRenderEncoder(encoder);
        try command_buffer.commit();
        try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
        for (0..4 * 4) |index| {
            const offset = index * format.bytes_per_pixel;
            for (0..format.bytes_per_pixel) |byte| {
                if (byte == format.stencil_offset) continue;
                try std.testing.expectEqual(@as(u8, 0xa5), stencil.bytes[offset + byte]);
            }
            try std.testing.expectEqual(@as(u8, 4), stencil.bytes[offset + format.stencil_offset]);
        }
    }
}

test "depth bounds discard fragments outside the CPU depth range" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const depth = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.depth32_float));
    defer destroyTexture(depth);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.75, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.25, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 },
    });
    try encoder.setDepthTexture(depth);
    try encoder.setDepthCompareFunction(@intFromEnum(abi.CompareFunction.less_equal), true);
    try encoder.setDepthTestBounds(0.5, 1.0);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
}

test "stencil attachment applies compare and pass/failure operations" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const stencil = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.stencil8));
    defer destroyTexture(stencil);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    try encoder.setStencilTexture(stencil, @intFromEnum(abi.LoadAction.clear), @intFromEnum(abi.StoreAction.store), 3);
    for ([_]bool{ true, false }) |front_face| {
        try encoder.setStencilState(front_face, @intFromEnum(abi.CompareFunction.equal), @intFromEnum(abi.StencilOperation.zero), @intFromEnum(abi.StencilOperation.keep), @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
    }
    try encoder.setStencilReference(3, 3);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    for (stencil.bytes) |value| try std.testing.expectEqual(@as(u8, 0), value);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
}

test "multiple color attachments share one CPU fragment output" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const secondary = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(secondary);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    try encoder.setColorAttachment(secondary, .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } }, 1);
    try encoder.setPipelineColorFormats(&[_]u16{
        @intFromEnum(abi.PixelFormat.rgba8_unorm),
        @intFromEnum(abi.PixelFormat.bgra8_unorm),
    }, 0, 0);
    try encoder.setMultiTargetOutput(true);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255 }, color.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, secondary.bytes[0..4]);
}

test "CPU color attachment mapping routes logical output to its physical target" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const secondary = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.bgra8_unorm));
    defer destroyTexture(secondary);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    defer destroyRenderEncoder(encoder);
    try encoder.setColorAttachment(secondary, .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } }, 1);
    try std.testing.expectError(error.InvalidArgument, encoder.setColorAttachmentMap(&[_]u8{ 1, 1, 2, 3, 4, 5, 6, 7 }, 8));
    try encoder.setColorAttachmentMap(&[_]u8{ 1, 0, 2, 3, 4, 5, 6, 7 }, 8);
    try encoder.setPipelineColorFormats(&[_]u16{
        @intFromEnum(abi.PixelFormat.bgra8_unorm),
    }, 0, 0);
    try encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try encoder.endEncoding();
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, color.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 255, 255 }, secondary.bytes[0..4]);
}

test "CPU tile and mesh maps are captured per deferred command" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const tile_target = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(tile_target);
    const mesh_target = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(mesh_target);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    defer destroyRenderEncoder(encoder);
    const clear = abi.RenderPassColorAttachmentDescriptor{
        .load_action = .clear,
        .store_action = .store,
        .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 },
    };
    try encoder.setColorAttachment(tile_target, clear, 2);
    try encoder.setColorAttachment(mesh_target, clear, 3);
    try encoder.setColorAttachmentMap(&[_]u8{ 2, 0, 1, 3, 4, 5, 6, 7 }, 8);
    try encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setColorAttachmentMap(&[_]u8{ 3, 0, 1, 2, 4, 5, 6, 7 }, 8);
    try encoder.drawMeshThreadgroups(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 255 }, color.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, tile_target.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, mesh_target.bytes[0..4]);
}

test "visibility results count CPU-covered fragments and accumulate" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const visibility = try createBuffer(device, 16, null);
    defer destroyBuffer(visibility);
    @memset(visibility.bytes, 0xa5);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ -1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var first = try createCommandBuffer(queue);
    defer destroyCommandBuffer(first);
    var first_encoder = try beginRender(first, color, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try first_encoder.setVisibilityResultBuffer(visibility);
    try first_encoder.setVisibilityResultType(@intFromEnum(abi.VisibilityResultType.reset));
    try first_encoder.setVisibilityResultMode(@intFromEnum(abi.VisibilityResultMode.boolean), 0);
    try first_encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try first_encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try first_encoder.setVisibilityResultMode(@intFromEnum(abi.VisibilityResultMode.counting), 8);
    try first_encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try first_encoder.endEncoding();
    destroyRenderEncoder(first_encoder);
    try first.commit();
    try std.testing.expectEqual(@as(u64, 1), readU64Little(visibility.bytes, 0));
    try std.testing.expectEqual(@as(u64, 16), readU64Little(visibility.bytes, 8));

    var second = try createCommandBuffer(queue);
    defer destroyCommandBuffer(second);
    var second_encoder = try beginRender(second, color, .{ .color = .{ .load_action = .load, .store_action = .store } });
    try second_encoder.setVisibilityResultBuffer(visibility);
    try second_encoder.setVisibilityResultType(@intFromEnum(abi.VisibilityResultType.accumulate));
    try second_encoder.setVisibilityResultMode(@intFromEnum(abi.VisibilityResultMode.counting), 8);
    try second_encoder.setVertexBytes(@ptrCast(&vertices), @sizeOf(@TypeOf(vertices)), 0);
    try second_encoder.drawPrimitives(.triangle, 0, vertices.len, 1);
    try second_encoder.endEncoding();
    destroyRenderEncoder(second_encoder);
    try second.commit();
    try std.testing.expectEqual(@as(u64, 32), readU64Little(visibility.bytes, 8));
}

test "tile and mesh visibility results count CPU-covered fragments" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const color = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(color);
    const visibility = try createBuffer(device, 16, null);
    defer destroyBuffer(visibility);
    @memset(visibility.bytes, 0xa5);

    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginRender(command_buffer, color, .{
        .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
    });
    try encoder.setVisibilityResultBuffer(visibility);
    try encoder.setVisibilityResultType(@intFromEnum(abi.VisibilityResultType.reset));
    try encoder.setVisibilityResultMode(@intFromEnum(abi.VisibilityResultMode.counting), 0);
    try encoder.dispatchThreadsPerTile(1, .{ .width = 2, .height = 2, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.setVisibilityResultMode(@intFromEnum(abi.VisibilityResultMode.boolean), 8);
    try encoder.drawMeshThreadgroups(1, .{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 1, .height = 1, .depth = 1 }, .{ .width = 2, .height = 2, .depth = 1 });
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();

    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqual(@as(u64, 16), readU64Little(visibility.bytes, 0));
    try std.testing.expectEqual(@as(u64, 1), readU64Little(visibility.bytes, 8));
}

test "CPU sparse buffer mappings preserve deferred ordering, zeroing, and aliases" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const page_bytes = 64 * 1024;
    const source_values = try allocator.alloc(u8, page_bytes);
    defer allocator.free(source_values);
    for (source_values, 0..) |*value, index| value.* = @truncate(index * 13 + 7);
    const source = try createBuffer(device, page_bytes, source_values.ptr);
    defer destroyBuffer(source);
    const sparse_source = try createSparseBuffer(device, page_bytes * 2, page_bytes);
    defer destroyBuffer(sparse_source);
    const sparse_destination = try createSparseBuffer(device, page_bytes * 2, page_bytes);
    defer destroyBuffer(sparse_destination);
    const readback = try createBuffer(device, page_bytes, null);
    defer destroyBuffer(readback);

    try std.testing.expectEqual(@as(usize, page_bytes), sparse_source.sparse_page_bytes);
    try std.testing.expectEqual(@as(?[*]u8, null), zpu_metal_buffer_contents(sparse_source));

    var first = try createCommandBuffer(queue);
    defer destroyCommandBuffer(first);
    var resource_state = try beginResourceState(first);
    try std.testing.expectError(error.InvalidArgument, resource_state.updateBufferMapping(source, 0, 0, page_bytes));
    try std.testing.expectError(error.InvalidArgument, resource_state.updateBufferMapping(sparse_source, 2, 0, page_bytes));
    try resource_state.updateBufferMapping(sparse_source, 0, 0, page_bytes);
    try resource_state.updateBufferMapping(sparse_destination, 0, 0, page_bytes);
    try resource_state.endEncoding();
    destroyResourceStateEncoder(resource_state);
    var upload = try beginBlit(first);
    try upload.copyBuffer(source, 0, sparse_source, 0, page_bytes);
    try upload.endEncoding();
    destroyBlitEncoder(upload);
    try first.commit();

    var second = try createCommandBuffer(queue);
    defer destroyCommandBuffer(second);
    var remap = try beginResourceState(second);
    try remap.copyBufferMappings(sparse_source, sparse_destination, 0, page_bytes, page_bytes);
    try remap.endEncoding();
    destroyResourceStateEncoder(remap);
    var download = try beginBlit(second);
    try download.copyBuffer(sparse_destination, page_bytes, readback, 0, page_bytes);
    try download.endEncoding();
    destroyBlitEncoder(download);
    try second.commit();
    try std.testing.expectEqualSlices(u8, source_values, readback.bytes);

    for (source_values, 0..) |*value, index| value.* = @truncate(index * 19 + 3);
    try bufferWrite(source, 0, source_values.ptr, page_bytes);
    var third = try createCommandBuffer(queue);
    defer destroyCommandBuffer(third);
    var alias_upload = try beginBlit(third);
    try alias_upload.copyBuffer(source, 0, sparse_source, 0, page_bytes);
    try alias_upload.copyBuffer(sparse_destination, page_bytes, readback, 0, page_bytes);
    try alias_upload.endEncoding();
    destroyBlitEncoder(alias_upload);
    try third.commit();
    try std.testing.expectEqualSlices(u8, source_values, readback.bytes);

    var fourth = try createCommandBuffer(queue);
    defer destroyCommandBuffer(fourth);
    var unmap = try beginResourceState(fourth);
    try unmap.updateBufferMapping(sparse_destination, 1, page_bytes, page_bytes);
    try unmap.endEncoding();
    destroyResourceStateEncoder(unmap);
    var zero_download = try beginBlit(fourth);
    try zero_download.copyBuffer(sparse_destination, page_bytes, readback, 0, page_bytes);
    try zero_download.endEncoding();
    destroyBlitEncoder(zero_download);
    try fourth.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{0} ** page_bytes, readback.bytes);
}

test "fence update and wait preserve command ordering" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const fence = try createFence(device);
    defer destroyFence(fence);

    var first = try createCommandBuffer(queue);
    defer destroyCommandBuffer(first);
    var first_encoder = try beginBlit(first);
    try first_encoder.updateFence(fence);
    try first_encoder.endEncoding();
    destroyBlitEncoder(first_encoder);
    try first.commit();
    try std.testing.expect(fence.signaled);

    var second = try createCommandBuffer(queue);
    defer destroyCommandBuffer(second);
    var second_encoder = try beginBlit(second);
    try second_encoder.waitForFence(fence);
    try second_encoder.endEncoding();
    destroyBlitEncoder(second_encoder);
    try second.commit();
    try std.testing.expectEqual(CommandStatus.completed, second.status);
}

test "shared event values are monotonic and timeout-safe" {
    const device = try createDevice();
    defer destroyDevice(device);
    const event = try createSharedEvent(device);
    defer destroySharedEvent(event);
    try std.testing.expectEqual(@as(u64, 0), event.signaled_value);
    try std.testing.expectError(error.InvalidCommand, waitSharedEventValue(event, 1, 0));
    try setSharedEventValue(event, 7);
    try waitSharedEventValue(event, 7, 0);
    try waitSharedEventValue(event, 5, 1);
    try std.testing.expectError(error.InvalidArgument, setSharedEventValue(event, 6));
}

fn errorCode(err: Error) c_int {
    return switch (err) {
        error.InvalidArgument => -1,
        error.InvalidResource => -1,
        error.InvalidCommand => -4,
        error.UnsupportedFormat => -2,
        error.UnsupportedOperation => -6,
        error.OutOfMemory => -5,
    };
}

pub export fn zpu_metal_device_create() callconv(.c) ?*Device {
    return createDevice() catch null;
}

pub export fn zpu_metal_device_destroy(device: ?*Device) callconv(.c) void {
    if (device) |value| destroyDevice(value);
}

pub export fn zpu_metal_device_new_command_queue(device: ?*Device) callconv(.c) ?*CommandQueue {
    return createQueue(device orelse return null) catch null;
}

pub export fn zpu_metal_command_queue_destroy(queue: ?*CommandQueue) callconv(.c) void {
    if (queue) |value| destroyQueue(value);
}

pub export fn zpu_metal_device_new_buffer(device: ?*Device, length: usize, initial_bytes: ?[*]const u8) callconv(.c) ?*Buffer {
    return createBuffer(device orelse return null, length, initial_bytes) catch null;
}

pub export fn zpu_metal_device_new_sparse_buffer(device: ?*Device, length: usize, page_bytes: usize) callconv(.c) ?*Buffer {
    return createSparseBuffer(device orelse return null, length, page_bytes) catch null;
}

pub export fn zpu_metal_device_new_buffer_no_copy(device: ?*Device, length: usize, bytes: ?[*]u8) callconv(.c) ?*Buffer {
    return createBufferNoCopy(device orelse return null, length, bytes) catch null;
}

pub export fn zpu_metal_buffer_destroy(buffer: ?*Buffer) callconv(.c) void {
    if (buffer) |value| destroyBuffer(value);
}

pub export fn zpu_metal_buffer_make_aliasable(buffer: ?*Buffer) callconv(.c) void {
    if (buffer) |value| makeBufferAliasable(value);
}

pub export fn zpu_metal_device_new_heap(device: ?*Device, size: usize) callconv(.c) ?*Heap {
    return createHeap(device orelse return null, size) catch null;
}

pub export fn zpu_metal_heap_destroy(heap: ?*Heap) callconv(.c) void {
    if (heap) |value| destroyHeap(value);
}

pub export fn zpu_metal_heap_size(heap: ?*const Heap) callconv(.c) usize {
    const value = heap orelse return 0;
    return if (validHeap(value)) value.size else 0;
}

pub export fn zpu_metal_heap_used_size(heap: ?*const Heap) callconv(.c) usize {
    const value = heap orelse return 0;
    return if (validHeap(value)) value.used else 0;
}

pub export fn zpu_metal_heap_max_available_size(heap: ?*const Heap, alignment: usize) callconv(.c) usize {
    return heapMaxAvailableSize(heap orelse return 0, alignment);
}

pub export fn zpu_metal_heap_new_buffer(heap: ?*Heap, length: usize, initial_bytes: ?[*]const u8) callconv(.c) ?*Buffer {
    return createBufferInHeap(heap orelse return null, length, initial_bytes) catch null;
}

pub export fn zpu_metal_heap_new_buffer_at_offset(heap: ?*Heap, length: usize, initial_bytes: ?[*]const u8, offset: usize) callconv(.c) ?*Buffer {
    return createBufferInHeapAtOffset(heap orelse return null, length, initial_bytes, offset) catch null;
}

pub export fn zpu_metal_buffer_new_texture(buffer: ?*Buffer, descriptor: ?*const abi.TextureDescriptor, offset: usize, bytes_per_row: usize) callconv(.c) ?*Texture {
    const value = buffer orelse return null;
    const desc = descriptor orelse return null;
    return createTextureFromBuffer(value, desc.width, desc.height, desc.format, offset, bytes_per_row) catch null;
}

pub export fn zpu_metal_buffer_length(buffer: ?*const Buffer) callconv(.c) usize {
    const value = buffer orelse return 0;
    if (value.magic != buffer_magic) return 0;
    return value.bytes.len;
}

pub export fn zpu_metal_buffer_contents(buffer: ?*Buffer) callconv(.c) ?[*]u8 {
    const value = buffer orelse return null;
    if (!validBuffer(value) or value.sparse_page_bytes != 0 or value.bytes.len == 0) return null;
    return value.bytes.ptr;
}

pub export fn zpu_metal_buffer_is_sparse(buffer: ?*const Buffer) callconv(.c) c_int {
    const value = buffer orelse return 0;
    return if (validBuffer(@constCast(value)) and value.sparse_page_bytes != 0) 1 else 0;
}

pub export fn zpu_metal_buffer_sparse_page_size(buffer: ?*const Buffer) callconv(.c) usize {
    const value = buffer orelse return 0;
    return if (validBuffer(@constCast(value))) value.sparse_page_bytes else 0;
}

pub export fn zpu_metal_buffer_heap_offset(buffer: ?*const Buffer) callconv(.c) usize {
    const value = buffer orelse return 0;
    return if (value.magic == buffer_magic) value.heap_allocation_offset else 0;
}

pub export fn zpu_metal_buffer_write(buffer: ?*Buffer, offset: usize, bytes: ?[*]const u8, length: usize) callconv(.c) c_int {
    bufferWrite(buffer orelse return -1, offset, bytes, length) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_device_new_texture(device: ?*Device, descriptor: ?*const abi.TextureDescriptor) callconv(.c) ?*Texture {
    const desc = descriptor orelse return null;
    return createTexture(device orelse return null, desc.width, desc.height, desc.format) catch null;
}

pub export fn zpu_metal_device_new_sparse_texture(device: ?*Device, descriptor: ?*const abi.TextureDescriptor, page_bytes: usize) callconv(.c) ?*Texture {
    const desc = descriptor orelse return null;
    return createSparseTexture(device orelse return null, desc.width, desc.height, desc.format, page_bytes) catch null;
}

pub export fn zpu_metal_heap_new_texture(heap: ?*Heap, descriptor: ?*const abi.TextureDescriptor) callconv(.c) ?*Texture {
    const value = heap orelse return null;
    const desc = descriptor orelse return null;
    return createTextureInHeap(value, desc.width, desc.height, desc.format) catch null;
}

pub export fn zpu_metal_heap_new_texture_at_offset(heap: ?*Heap, descriptor: ?*const abi.TextureDescriptor, offset: usize) callconv(.c) ?*Texture {
    const value = heap orelse return null;
    const desc = descriptor orelse return null;
    return createTextureInHeapAtOffset(value, desc.width, desc.height, desc.format, offset) catch null;
}

pub export fn zpu_metal_texture_destroy(texture: ?*Texture) callconv(.c) void {
    if (texture) |value| destroyTexture(value);
}

pub export fn zpu_metal_texture_make_aliasable(texture: ?*Texture) callconv(.c) void {
    if (texture) |value| makeTextureAliasable(value);
}

pub export fn zpu_metal_texture_view(texture: ?*const Texture, format_raw: u16) callconv(.c) ?*Texture {
    return createTextureView(texture orelse return null, format_raw) catch null;
}

pub export fn zpu_metal_texture_width(texture: ?*const Texture) callconv(.c) u32 {
    const value = texture orelse return 0;
    if (value.magic != texture_magic) return 0;
    return value.width;
}

pub export fn zpu_metal_texture_height(texture: ?*const Texture) callconv(.c) u32 {
    const value = texture orelse return 0;
    if (value.magic != texture_magic) return 0;
    return value.height;
}

pub export fn zpu_metal_texture_is_sparse(texture: ?*const Texture) callconv(.c) c_int {
    const value = texture orelse return 0;
    return if (validTexture(@constCast(value)) and value.sparse_page_bytes != 0) 1 else 0;
}

pub export fn zpu_metal_texture_sparse_page_size(texture: ?*const Texture) callconv(.c) usize {
    const value = texture orelse return 0;
    return if (validTexture(@constCast(value))) value.sparse_page_bytes else 0;
}

pub export fn zpu_metal_texture_sparse_tile_width(texture: ?*const Texture) callconv(.c) usize {
    const value = texture orelse return 0;
    return if (validTexture(@constCast(value))) value.sparse_tile_width else 0;
}

pub export fn zpu_metal_texture_sparse_tile_height(texture: ?*const Texture) callconv(.c) usize {
    const value = texture orelse return 0;
    return if (validTexture(@constCast(value))) value.sparse_tile_height else 0;
}

pub export fn zpu_metal_texture_heap_offset(texture: ?*const Texture) callconv(.c) usize {
    const value = texture orelse return 0;
    return if (value.magic == texture_magic) value.heap_allocation_offset else 0;
}

pub export fn zpu_metal_texture_get_bytes(texture: ?*Texture, destination: ?[*]u8, destination_length: usize, bytes_per_row: usize, region: abi.Region) callconv(.c) c_int {
    textureGetBytes(texture orelse return -1, destination, destination_length, bytes_per_row, region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_texture_replace_region(texture: ?*Texture, region: abi.Region, source: ?[*]const u8, source_length: usize, bytes_per_row: usize) callconv(.c) c_int {
    textureReplaceRegion(texture orelse return -1, region, source, source_length, bytes_per_row) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_device_new_fence(device: ?*Device) callconv(.c) ?*Fence {
    return createFence(device orelse return null) catch null;
}

pub export fn zpu_metal_fence_destroy(fence: ?*Fence) callconv(.c) void {
    if (fence) |value| destroyFence(value);
}

pub export fn zpu_metal_fence_device(fence: ?*const Fence) callconv(.c) ?*Device {
    const value = fence orelse return null;
    if (value.magic != fence_magic or !validDevice(value.device)) return null;
    return value.device;
}

pub export fn zpu_metal_device_new_shared_event(device: ?*Device) callconv(.c) ?*SharedEvent {
    return createSharedEvent(device orelse return null) catch null;
}

pub export fn zpu_metal_shared_event_destroy(event: ?*SharedEvent) callconv(.c) void {
    if (event) |value| destroySharedEvent(value);
}

pub export fn zpu_metal_shared_event_signaled_value(event: ?*const SharedEvent) callconv(.c) u64 {
    const value = event orelse return 0;
    if (value.magic != shared_event_magic or !validDevice(value.device)) return 0;
    const mutable_value: *SharedEvent = @constCast(value);
    _ = std.c.pthread_mutex_lock(&mutable_value.mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutable_value.mutex);
    return mutable_value.signaled_value;
}

pub export fn zpu_metal_shared_event_set_signaled_value(event: ?*SharedEvent, value: u64) callconv(.c) c_int {
    setSharedEventValue(event orelse return -1, value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_shared_event_wait_until_signaled_value(event: ?*const SharedEvent, value: u64, timeout_ms: u64) callconv(.c) c_int {
    waitSharedEventValue(event orelse return -1, value, timeout_ms) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_queue_command_buffer(queue: ?*CommandQueue) callconv(.c) ?*CommandBuffer {
    return createCommandBuffer(queue orelse return null) catch null;
}

pub export fn zpu_metal_command_buffer_destroy(command_buffer: ?*CommandBuffer) callconv(.c) void {
    if (command_buffer) |value| destroyCommandBuffer(value);
}

pub export fn zpu_metal_command_buffer_get_status(command_buffer: ?*const CommandBuffer) callconv(.c) u8 {
    const value = command_buffer orelse return @intFromEnum(CommandStatus.failed);
    if (value.magic != command_buffer_magic) return @intFromEnum(CommandStatus.failed);
    return @intFromEnum(value.status);
}

pub export fn zpu_metal_command_buffer_mark_error(command_buffer: ?*CommandBuffer) callconv(.c) void {
    if (command_buffer) |value| value.markError();
}

pub export fn zpu_metal_command_buffer_commit(command_buffer: ?*CommandBuffer) callconv(.c) c_int {
    (command_buffer orelse return -1).commit() catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_wait_until_completed(command_buffer: ?*CommandBuffer) callconv(.c) c_int {
    const value = command_buffer orelse return -1;
    return if (value.status == .completed) 0 else if (value.status == .failed) -4 else -1;
}

pub export fn zpu_metal_command_buffer_encode_signal_event(command_buffer: ?*CommandBuffer, event: ?*SharedEvent, value: u64) callconv(.c) c_int {
    encodeSignalEvent(command_buffer orelse return -1, event orelse return -1, value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_encode_wait_for_event(command_buffer: ?*CommandBuffer, event: ?*SharedEvent, value: u64) callconv(.c) c_int {
    encodeWaitForEvent(command_buffer orelse return -1, event orelse return -1, value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_encode_update_fence(command_buffer: ?*CommandBuffer, fence: ?*Fence) callconv(.c) c_int {
    const value = command_buffer orelse return -1;
    const target = fence orelse return -1;
    if (value.magic != command_buffer_magic or value.status != .created or
        !validFence(target) or target.device != value.queue.device) return errorCode(error.InvalidArgument);
    _ = value.append(.{ .update_fence = target }) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_encode_wait_for_fence(command_buffer: ?*CommandBuffer, fence: ?*Fence) callconv(.c) c_int {
    const value = command_buffer orelse return -1;
    const target = fence orelse return -1;
    if (value.magic != command_buffer_magic or value.status != .created or
        !validFence(target) or target.device != value.queue.device) return errorCode(error.InvalidArgument);
    _ = value.append(.{ .wait_fence = target }) catch |err| return errorCode(err);
    return 0;
}

/// Append an adapter-private CPU callback at the current command-stream
/// position. The caller owns the context lifetime until command completion.
/// This hook is intentionally not part of the portable Metal ABI; it exists
/// only so the Apple compatibility layer can defer its richer CPU metadata
/// operations without importing native Metal storage or execution.
pub export fn zpu_metal_command_buffer_append_callback(
    command_buffer: ?*CommandBuffer,
    callback: ?*const fn (?*anyopaque) callconv(.c) c_int,
    context: ?*anyopaque,
) callconv(.c) c_int {
    const value = command_buffer orelse return -1;
    const callback_value = callback orelse return -1;
    _ = value.append(.{ .external_callback = .{
        .callback = callback_value,
        .context = context,
    } }) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_render_encoder(command_buffer: ?*CommandBuffer, color_texture: ?*Texture, pass: ?*const abi.RenderPassDescriptor) callconv(.c) ?*RenderEncoder {
    const descriptor = pass orelse return null;
    return beginRender(command_buffer orelse return null, color_texture orelse return null, descriptor.*) catch null;
}

pub export fn zpu_metal_render_encoder_destroy(encoder: ?*RenderEncoder) callconv(.c) void {
    if (encoder) |value| destroyRenderEncoder(value);
}

pub export fn zpu_metal_render_encoder_set_vertex_buffer(encoder: ?*RenderEncoder, buffer: ?*Buffer, offset: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setVertexBuffer(buffer, offset, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_vertex_buffer_stride(encoder: ?*RenderEncoder, stride: usize) callconv(.c) c_int {
    (encoder orelse return -1).setVertexBufferStride(stride) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_vertex_bytes(encoder: ?*RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setVertexBytes(bytes, length, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_viewport(encoder: ?*RenderEncoder, viewport: abi.Viewport) callconv(.c) c_int {
    (encoder orelse return -1).setViewport(viewport) catch |err| return errorCode(err);
    return 0;
}

/// Adapter-private precise bridge for Apple MTLViewport's double-valued
/// fields. The stable portable C ABI above intentionally remains float-based.
pub export fn zpu_metal_render_encoder_set_viewport_precise(
    encoder: ?*RenderEncoder,
    viewport: raster3d.PreciseViewport,
) callconv(.c) c_int {
    (encoder orelse return -1).setViewportPrecise(viewport) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_viewports(
    encoder: ?*RenderEncoder,
    viewports: ?[*]const abi.Viewport,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setViewports(viewports, count) catch |err| return errorCode(err);
    return 0;
}

/// Adapter-private precise bridge for an Apple MTLViewport array.
pub export fn zpu_metal_render_encoder_set_viewports_precise(
    encoder: ?*RenderEncoder,
    viewports: ?[*]const raster3d.PreciseViewport,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setViewportsPrecise(viewports, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_scissor_rect(encoder: ?*RenderEncoder, scissor: abi.ScissorRect) callconv(.c) c_int {
    (encoder orelse return -1).setScissorRect(scissor) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_scissor_rects(
    encoder: ?*RenderEncoder,
    scissors: ?[*]const abi.ScissorRect,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setScissorRects(scissors, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_cull_mode(encoder: ?*RenderEncoder, cull_mode: abi.CullMode) callconv(.c) c_int {
    (encoder orelse return -1).setCullMode(cull_mode) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_front_facing(encoder: ?*RenderEncoder, winding: abi.Winding) callconv(.c) c_int {
    (encoder orelse return -1).setFrontFacing(winding) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_triangle_fill_mode(encoder: ?*RenderEncoder, fill_mode: abi.TriangleFillMode) callconv(.c) c_int {
    (encoder orelse return -1).setTriangleFillMode(fill_mode) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_clip_mode(encoder: ?*RenderEncoder, depth_clip_mode: u8) callconv(.c) c_int {
    (encoder orelse return -1).setDepthClipMode(depth_clip_mode) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_bias(encoder: ?*RenderEncoder, depth_bias: f32, slope_scale: f32, clamp: f32) callconv(.c) c_int {
    (encoder orelse return -1).setDepthBias(depth_bias, slope_scale, clamp) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_test_bounds(encoder: ?*RenderEncoder, min_bound: f32, max_bound: f32) callconv(.c) c_int {
    (encoder orelse return -1).setDepthTestBounds(min_bound, max_bound) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_pipeline_formats(encoder: ?*RenderEncoder, color_format: u16, depth_format: u16) callconv(.c) c_int {
    (encoder orelse return -1).setPipelineFormats(color_format, depth_format) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_pipeline_formats_with_stencil(encoder: ?*RenderEncoder, color_format: u16, depth_format: u16, stencil_format: u16) callconv(.c) c_int {
    (encoder orelse return -1).setPipelineFormatsWithStencil(color_format, depth_format, stencil_format) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_raster_sample_count(encoder: ?*RenderEncoder, sample_count: u8) callconv(.c) c_int {
    (encoder orelse return -1).setRasterSampleCount(sample_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_sample_positions(
    encoder: ?*RenderEncoder,
    positions: ?[*]const abi.SamplePosition,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setSamplePositions(positions, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_vertex_amplification_count(
    encoder: ?*RenderEncoder,
    count: usize,
    mappings: ?[*]const abi.VertexAmplificationViewMapping,
) callconv(.c) c_int {
    (encoder orelse return -1).setVertexAmplificationCount(count, mappings) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    sample_count: usize,
    resolve_texture: ?*Texture,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleTargets(sample_textures, sample_count, resolve_texture) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_render_target_array(
    encoder: ?*RenderEncoder,
    textures: ?[*]const *Texture,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setRenderTargetArray(textures, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_color_attachment_array_targets(
    encoder: ?*RenderEncoder,
    textures: ?[*]const *Texture,
    count: usize,
    attachment: ?*const abi.RenderPassColorAttachmentDescriptor,
    index: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setColorAttachmentArrayTargets(
        textures,
        count,
        (attachment orelse return -1).*,
        index,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_color_attachment_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    sample_count: usize,
    resolve_texture: ?*Texture,
    attachment: ?*const abi.RenderPassColorAttachmentDescriptor,
    index: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleColorAttachmentTargets(
        sample_textures,
        sample_count,
        resolve_texture,
        (attachment orelse return -1).*,
        index,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_color_attachment_array_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    array_count: usize,
    sample_count: usize,
    resolve_textures: ?[*]const ?*Texture,
    attachment: ?*const abi.RenderPassColorAttachmentDescriptor,
    index: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleColorAttachmentArrayTargets(
        sample_textures,
        array_count,
        sample_count,
        resolve_textures,
        (attachment orelse return -1).*,
        index,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_color_attachment(encoder: ?*RenderEncoder, texture: ?*Texture, attachment: ?*const abi.RenderPassColorAttachmentDescriptor, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setColorAttachment(texture orelse return -1, (attachment orelse return -1).*, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_color_attachment_map(encoder: ?*RenderEncoder, mapping: ?[*]const u8, count: usize) callconv(.c) c_int {
    (encoder orelse return -1).setColorAttachmentMap(mapping, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_color_store_action(encoder: ?*RenderEncoder, store_action: u8, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setColorStoreAction(store_action, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_store_action(encoder: ?*RenderEncoder, store_action: u8) callconv(.c) c_int {
    (encoder orelse return -1).setDepthStoreAction(store_action) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_store_action(encoder: ?*RenderEncoder, store_action: u8) callconv(.c) c_int {
    (encoder orelse return -1).setStencilStoreAction(store_action) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_pipeline_color_formats(encoder: ?*RenderEncoder, color_formats: ?[*]const u16, color_format_count: usize, depth_format: u16, stencil_format: u16) callconv(.c) c_int {
    if (color_format_count > 8 or (color_format_count != 0 and color_formats == null)) return -1;
    (encoder orelse return -1).setPipelineColorFormats(
        if (color_formats) |formats| formats[0..color_format_count] else &[_]u16{},
        depth_format,
        stencil_format,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multi_target_output(encoder: ?*RenderEncoder, enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setMultiTargetOutput(enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_sample_texture(encoder: ?*RenderEncoder, enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setSampleTexture(enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_texture(encoder: ?*RenderEncoder, texture: ?*Texture, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentTexture(texture, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_texture_levels(
    encoder: ?*RenderEncoder,
    textures: ?[*]const ?*Texture,
    count: usize,
    index: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentTextureLevels(textures, count, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler(encoder: ?*RenderEncoder, filter: u8, address_s: u8, address_t: u8) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSampler(filter, filter, address_s, address_t, @intFromEnum(abi.SamplerBorderColor.transparent_black), @intFromEnum(abi.SamplerMipFilter.not_mipmapped)) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_with_border(
    encoder: ?*RenderEncoder,
    filter: u8,
    address_s: u8,
    address_t: u8,
    border_color: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSampler(filter, filter, address_s, address_t, border_color, @intFromEnum(abi.SamplerMipFilter.not_mipmapped)) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_with_filters(
    encoder: ?*RenderEncoder,
    min_filter: u8,
    mag_filter: u8,
    address_s: u8,
    address_t: u8,
    border_color: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSampler(min_filter, mag_filter, address_s, address_t, border_color, @intFromEnum(abi.SamplerMipFilter.not_mipmapped)) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_with_filters_and_mip_filter(
    encoder: ?*RenderEncoder,
    min_filter: u8,
    mag_filter: u8,
    address_s: u8,
    address_t: u8,
    border_color: u8,
    mip_filter: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSampler(min_filter, mag_filter, address_s, address_t, border_color, mip_filter) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_lod_clamps(
    encoder: ?*RenderEncoder,
    lod_min_clamp: f32,
    lod_max_clamp: f32,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSamplerLodClamps(lod_min_clamp, lod_max_clamp) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_lod_bias(
    encoder: ?*RenderEncoder,
    lod_bias: f32,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSamplerLodBias(lod_bias) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_max_anisotropy(
    encoder: ?*RenderEncoder,
    max_anisotropy: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSamplerMaxAnisotropy(max_anisotropy) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_normalized_coordinates(
    encoder: ?*RenderEncoder,
    normalized_coordinates: bool,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSamplerNormalizedCoordinates(normalized_coordinates) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_sampler_reduction_mode(
    encoder: ?*RenderEncoder,
    reduction_mode: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentSamplerReductionMode(reduction_mode) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_texture_swizzle(encoder: ?*RenderEncoder, red: u8, green: u8, blue: u8, alpha: u8) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentTextureSwizzle(red, green, blue, alpha) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_uniform_enabled(encoder: ?*RenderEncoder, enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentUniformEnabled(enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_position_gradient_enabled(encoder: ?*RenderEncoder, enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentPositionGradientEnabled(enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_bytes(encoder: ?*RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentBytes(bytes, length, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_buffer(encoder: ?*RenderEncoder, buffer: ?*Buffer, offset: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentBuffer(buffer, offset, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_fragment_buffer_offset(encoder: ?*RenderEncoder, offset: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setFragmentBufferOffset(offset, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_rasterization_enabled(encoder: ?*RenderEncoder, enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setRasterizationEnabled(enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_compare_function(encoder: ?*RenderEncoder, compare_function: u8, depth_write_enabled: bool) callconv(.c) c_int {
    (encoder orelse return -1).setDepthCompareFunction(compare_function, depth_write_enabled) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_blend_state(encoder: ?*RenderEncoder, blending_enabled: bool, source_rgb_factor: u8, destination_rgb_factor: u8, rgb_operation: u8, source_alpha_factor: u8, destination_alpha_factor: u8, alpha_operation: u8, color_write_mask: u8) callconv(.c) c_int {
    (encoder orelse return -1).setBlendState(blending_enabled, source_rgb_factor, destination_rgb_factor, rgb_operation, source_alpha_factor, destination_alpha_factor, alpha_operation, color_write_mask) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_blend_color(encoder: ?*RenderEncoder, color: abi.Color) callconv(.c) c_int {
    (encoder orelse return -1).setBlendColor(color) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_texture(encoder: ?*RenderEncoder, texture: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).setDepthTexture(texture orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_texture_array(
    encoder: ?*RenderEncoder,
    textures: ?[*]const *Texture,
    count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setDepthTextureArray(textures, count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_depth_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    sample_count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleDepthTargets(sample_textures, sample_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_depth_attachment_array_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    array_count: usize,
    sample_count: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleDepthAttachmentArrayTargets(
        sample_textures,
        array_count,
        sample_count,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_depth_buffer(encoder: ?*RenderEncoder, depth: ?[*]f32, depth_count: usize) callconv(.c) c_int {
    (encoder orelse return -1).setDepthBuffer(depth, depth_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_texture(encoder: ?*RenderEncoder, texture: ?*Texture, load_action: u8, store_action: u8, clear_value: u8) callconv(.c) c_int {
    (encoder orelse return -1).setStencilTexture(texture orelse return -1, load_action, store_action, clear_value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_texture_array(
    encoder: ?*RenderEncoder,
    textures: ?[*]const *Texture,
    count: usize,
    load_action: u8,
    store_action: u8,
    clear_value: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setStencilTextureArray(textures, count, load_action, store_action, clear_value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_stencil_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    sample_count: usize,
    load_action: u8,
    store_action: u8,
    clear_value: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleStencilTargets(
        sample_textures,
        sample_count,
        load_action,
        store_action,
        clear_value,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_multisample_stencil_attachment_array_targets(
    encoder: ?*RenderEncoder,
    sample_textures: ?[*]const ?*Texture,
    array_count: usize,
    sample_count: usize,
    load_action: u8,
    store_action: u8,
    clear_value: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setMultisampleStencilAttachmentArrayTargets(
        sample_textures,
        array_count,
        sample_count,
        load_action,
        store_action,
        clear_value,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_state(encoder: ?*RenderEncoder, front_face: c_int, compare: u8, stencil_failure: u8, depth_failure: u8, depth_pass: u8, read_mask: u8, write_mask: u8) callconv(.c) c_int {
    (encoder orelse return -1).setStencilState(front_face != 0, compare, stencil_failure, depth_failure, depth_pass, read_mask, write_mask) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_reference(encoder: ?*RenderEncoder, front_reference: u8, back_reference: u8) callconv(.c) c_int {
    (encoder orelse return -1).setStencilReference(front_reference, back_reference) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_visibility_result_buffer(encoder: ?*RenderEncoder, buffer: ?*Buffer) callconv(.c) c_int {
    (encoder orelse return -1).setVisibilityResultBuffer(buffer) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_visibility_result_mode(encoder: ?*RenderEncoder, mode: u8, offset: usize) callconv(.c) c_int {
    (encoder orelse return -1).setVisibilityResultMode(mode, offset) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_visibility_result_type(encoder: ?*RenderEncoder, result_type: u8) callconv(.c) c_int {
    (encoder orelse return -1).setVisibilityResultType(result_type) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_update_fence(encoder: ?*RenderEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).updateFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_wait_for_fence(encoder: ?*RenderEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).waitForFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_primitives(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, vertex_start: usize, vertex_count: usize, instance_count: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawPrimitives(primitive, vertex_start, vertex_count, instance_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_primitives_base_instance(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, vertex_start: usize, vertex_count: usize, instance_count: usize, base_instance: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawPrimitivesWithBaseInstance(primitive, vertex_start, vertex_count, instance_count, base_instance) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_primitives_indirect(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, indirect_buffer: ?*Buffer, indirect_buffer_offset: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawPrimitivesIndirect(primitive, indirect_buffer orelse return -1, indirect_buffer_offset) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_indexed_primitives(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: ?*Buffer, index_buffer_offset: usize, instance_count: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawIndexedPrimitives(primitive, index_count, index_type, index_buffer orelse return -1, index_buffer_offset, instance_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_indexed_primitives_base_vertex(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: ?*Buffer, index_buffer_offset: usize, instance_count: usize, base_vertex: i64) callconv(.c) c_int {
    (encoder orelse return -1).drawIndexedPrimitivesWithBaseVertex(primitive, index_count, index_type, index_buffer orelse return -1, index_buffer_offset, instance_count, base_vertex) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_indexed_primitives_base_vertex_instance(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: ?*Buffer, index_buffer_offset: usize, instance_count: usize, base_vertex: i64, base_instance: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawIndexedPrimitivesWithBaseVertexAndInstance(primitive, index_count, index_type, index_buffer orelse return -1, index_buffer_offset, instance_count, base_vertex, base_instance) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_indexed_primitives_indirect(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, index_type: abi.IndexType, index_buffer: ?*Buffer, index_buffer_offset: usize, indirect_buffer: ?*Buffer, indirect_buffer_offset: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawIndexedPrimitivesIndirect(primitive, index_type, index_buffer orelse return -1, index_buffer_offset, indirect_buffer orelse return -1, indirect_buffer_offset) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_dispatch_threads_per_tile(encoder: ?*RenderEncoder, kernel: u8, tile_size: abi.Size, threads_per_tile: abi.Size) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreadsPerTile(kernel, tile_size, threads_per_tile) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_mesh_threadgroups(
    encoder: ?*RenderEncoder,
    kernel: u8,
    threadgroups_per_grid: abi.Size,
    threads_per_object_threadgroup: abi.Size,
    threads_per_mesh_threadgroup: abi.Size,
) callconv(.c) c_int {
    (encoder orelse return -1).drawMeshThreadgroups(
        kernel,
        threadgroups_per_grid,
        threads_per_object_threadgroup,
        threads_per_mesh_threadgroup,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_mesh_threads(
    encoder: ?*RenderEncoder,
    kernel: u8,
    threads_per_grid: abi.Size,
    threads_per_object_threadgroup: abi.Size,
    threads_per_mesh_threadgroup: abi.Size,
) callconv(.c) c_int {
    (encoder orelse return -1).drawMeshThreads(
        kernel,
        threads_per_grid,
        threads_per_object_threadgroup,
        threads_per_mesh_threadgroup,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_mesh_threadgroups_indirect(
    encoder: ?*RenderEncoder,
    kernel: u8,
    indirect_buffer: ?*Buffer,
    indirect_buffer_offset: usize,
    threads_per_object_threadgroup: abi.Size,
    threads_per_mesh_threadgroup: abi.Size,
) callconv(.c) c_int {
    (encoder orelse return -1).drawMeshThreadgroupsIndirect(
        kernel,
        indirect_buffer orelse return -1,
        indirect_buffer_offset,
        threads_per_object_threadgroup,
        threads_per_mesh_threadgroup,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_tessellation_factor_buffer(
    encoder: ?*RenderEncoder,
    buffer: ?*Buffer,
    offset: usize,
    instance_stride: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).setTessellationFactorBuffer(
        buffer,
        offset,
        instance_stride,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_tessellation_factor_scale(
    encoder: ?*RenderEncoder,
    scale: f32,
) callconv(.c) c_int {
    (encoder orelse return -1).setTessellationFactorScale(scale) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_tessellation_partition_mode(
    encoder: ?*RenderEncoder,
    mode: u8,
) callconv(.c) c_int {
    (encoder orelse return -1).setTessellationPartitionMode(mode) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_patch_max_tessellation_factor(
    encoder: ?*RenderEncoder,
    max_factor: u32,
) callconv(.c) c_int {
    (encoder orelse return -1).setPatchMaxTessellationFactor(max_factor) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_patches(
    encoder: ?*RenderEncoder,
    kernel: u8,
    control_point_count: u32,
    patch_start: usize,
    patch_count: usize,
    patch_index_buffer: ?*Buffer,
    patch_index_buffer_offset: usize,
    instance_count: usize,
    base_instance: usize,
    control_point_index_type: abi.TessellationControlPointIndexType,
    control_point_index_buffer: ?*Buffer,
    control_point_index_buffer_offset: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).drawPatches(
        kernel,
        control_point_count,
        patch_start,
        patch_count,
        patch_index_buffer,
        patch_index_buffer_offset,
        instance_count,
        base_instance,
        control_point_index_type,
        control_point_index_buffer,
        control_point_index_buffer_offset,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_draw_patches_indirect(
    encoder: ?*RenderEncoder,
    kernel: u8,
    control_point_count: u32,
    patch_index_buffer: ?*Buffer,
    patch_index_buffer_offset: usize,
    indirect_buffer: ?*Buffer,
    indirect_buffer_offset: usize,
    control_point_index_type: abi.TessellationControlPointIndexType,
    control_point_index_buffer: ?*Buffer,
    control_point_index_buffer_offset: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).drawPatchesIndirect(
        kernel,
        control_point_count,
        patch_index_buffer,
        patch_index_buffer_offset,
        indirect_buffer orelse return -1,
        indirect_buffer_offset,
        control_point_index_type,
        control_point_index_buffer,
        control_point_index_buffer_offset,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_end_encoding(encoder: ?*RenderEncoder) callconv(.c) c_int {
    (encoder orelse return -1).endEncoding() catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_blit_encoder(command_buffer: ?*CommandBuffer) callconv(.c) ?*BlitEncoder {
    return beginBlit(command_buffer orelse return null) catch null;
}

pub export fn zpu_metal_command_buffer_resource_state_encoder(command_buffer: ?*CommandBuffer) callconv(.c) ?*ResourceStateEncoder {
    return beginResourceState(command_buffer orelse return null) catch null;
}

pub export fn zpu_metal_resource_state_encoder_destroy(encoder: ?*ResourceStateEncoder) callconv(.c) void {
    if (encoder) |value| destroyResourceStateEncoder(value);
}

pub export fn zpu_metal_resource_state_encoder_update_fence(encoder: ?*ResourceStateEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).updateFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_wait_for_fence(encoder: ?*ResourceStateEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).waitForFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_update_buffer_mapping(
    encoder: ?*ResourceStateEncoder,
    buffer: ?*Buffer,
    mode: u8,
    offset: usize,
    length: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).updateBufferMapping(buffer orelse return -1, mode, offset, length) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_copy_buffer_mappings(
    encoder: ?*ResourceStateEncoder,
    source: ?*Buffer,
    destination: ?*Buffer,
    source_offset: usize,
    destination_offset: usize,
    length: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).copyBufferMappings(
        source orelse return -1,
        destination orelse return -1,
        source_offset,
        destination_offset,
        length,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_update_texture_mapping(
    encoder: ?*ResourceStateEncoder,
    texture: ?*Texture,
    mode: u8,
    region: abi.Region,
) callconv(.c) c_int {
    (encoder orelse return -1).updateTextureMapping(texture orelse return -1, mode, region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_update_texture_mappings(
    encoder: ?*ResourceStateEncoder,
    texture: ?*Texture,
    mode: u8,
    regions: ?[*]const abi.Region,
    region_count: usize,
    mip_levels: ?[*]const usize,
    slices: ?[*]const usize,
) callconv(.c) c_int {
    const region_values: []const abi.Region = if (region_count == 0)
        &[_]abi.Region{}
    else
        (regions orelse return -1)[0..region_count];
    const mip_values: []const usize = if (region_count == 0)
        &[_]usize{}
    else
        (mip_levels orelse return -1)[0..region_count];
    const slice_values: []const usize = if (region_count == 0)
        &[_]usize{}
    else
        (slices orelse return -1)[0..region_count];
    (encoder orelse return -1).updateTextureMappings(
        texture orelse return -1,
        mode,
        region_values,
        mip_values,
        slice_values,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_update_texture_mapping_indirect(
    encoder: ?*ResourceStateEncoder,
    texture: ?*Texture,
    mode: u8,
    indirect_buffer: ?*Buffer,
    indirect_buffer_offset: usize,
) callconv(.c) c_int {
    (encoder orelse return -1).updateTextureMappingIndirect(
        texture orelse return -1,
        mode,
        indirect_buffer orelse return -1,
        indirect_buffer_offset,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_move_texture_mappings(
    encoder: ?*ResourceStateEncoder,
    source: ?*Texture,
    destination: ?*Texture,
    source_region: abi.Region,
    destination_origin: abi.Origin,
) callconv(.c) c_int {
    (encoder orelse return -1).moveTextureMappings(
        source orelse return -1,
        destination orelse return -1,
        source_region,
        destination_origin,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_copy_texture_mappings(
    encoder: ?*ResourceStateEncoder,
    source: ?*Texture,
    destination: ?*Texture,
    source_region: abi.Region,
    destination_origin: abi.Origin,
) callconv(.c) c_int {
    (encoder orelse return -1).copyTextureMappings(
        source orelse return -1,
        destination orelse return -1,
        source_region,
        destination_origin,
    ) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_resource_state_encoder_end_encoding(encoder: ?*ResourceStateEncoder) callconv(.c) c_int {
    (encoder orelse return -1).endEncoding() catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_destroy(encoder: ?*BlitEncoder) callconv(.c) void {
    if (encoder) |value| destroyBlitEncoder(value);
}

pub export fn zpu_metal_blit_encoder_copy_buffer(encoder: ?*BlitEncoder, source: ?*Buffer, source_offset: usize, destination: ?*Buffer, destination_offset: usize, length: usize) callconv(.c) c_int {
    (encoder orelse return -1).copyBuffer(source orelse return -1, source_offset, destination orelse return -1, destination_offset, length) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_copy_buffer_to_texture(encoder: ?*BlitEncoder, source: ?*Buffer, source_offset: usize, source_bytes_per_row: usize, destination: ?*Texture, destination_region: abi.Region) callconv(.c) c_int {
    (encoder orelse return -1).copyBufferToTexture(source orelse return -1, source_offset, source_bytes_per_row, destination orelse return -1, destination_region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_copy_texture_to_buffer(encoder: ?*BlitEncoder, source: ?*Texture, source_region: abi.Region, destination: ?*Buffer, destination_offset: usize, destination_bytes_per_row: usize) callconv(.c) c_int {
    (encoder orelse return -1).copyTextureToBuffer(source orelse return -1, source_region, destination orelse return -1, destination_offset, destination_bytes_per_row) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_copy_texture_to_texture(encoder: ?*BlitEncoder, source: ?*Texture, source_region: abi.Region, destination: ?*Texture, destination_region: abi.Region) callconv(.c) c_int {
    (encoder orelse return -1).copyTextureToTexture(source orelse return -1, source_region, destination orelse return -1, destination_region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_mipmap(encoder: ?*BlitEncoder, source: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap(source orelse return -1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_srgb_mipmap_chain(encoder: ?*BlitEncoder, levels: ?[*]const ?*Texture, level_count: usize) callconv(.c) c_int {
    const values = levels orelse return -1;
    if (level_count < 2) return errorCode(error.InvalidArgument);
    var unwrapped = allocator.alloc(*Texture, level_count) catch return errorCode(error.OutOfMemory);
    defer allocator.free(unwrapped);
    for (0..level_count) |index| unwrapped[index] = values[index] orelse return errorCode(error.InvalidArgument);
    (encoder orelse return -1).generateSrgbMipmapChain(unwrapped) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_mipmap_3d(encoder: ?*BlitEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3D(source0 orelse return -1, source1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_mipmap_3d_weighted(encoder: ?*BlitEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3DWeighted(source0 orelse return -1, source1, destination orelse return -1, source1_weight_numerator, source1_weight_denominator) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_mipmap_3d_array(encoder: ?*BlitEncoder, source_planes: ?[*]const ?*Texture, source_count: usize, destination: ?*Texture) callconv(.c) c_int {
    const sources = source_planes orelse return -1;
    if (source_count == 0) return -1;
    const source_slice: []const *Texture = @ptrCast(sources[0..source_count]);
    (encoder orelse return -1).generateMipmap3DArray(source_slice, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_fill_buffer(encoder: ?*BlitEncoder, buffer: ?*Buffer, offset: usize, length: usize, value: u8) callconv(.c) c_int {
    (encoder orelse return -1).fillBuffer(buffer orelse return -1, offset, length, value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_synchronize_resource(encoder: ?*BlitEncoder, buffer: ?*Buffer) callconv(.c) c_int {
    (encoder orelse return -1).synchronizeResource(buffer orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_update_fence(encoder: ?*BlitEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).updateFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_wait_for_fence(encoder: ?*BlitEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).waitForFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_end_encoding(encoder: ?*BlitEncoder) callconv(.c) c_int {
    (encoder orelse return -1).endEncoding() catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_command_buffer_compute_encoder(command_buffer: ?*CommandBuffer) callconv(.c) ?*ComputeEncoder {
    return beginCompute(command_buffer orelse return null) catch null;
}

pub export fn zpu_metal_compute_encoder_set_kernel(encoder: ?*ComputeEncoder, kernel: u8) callconv(.c) c_int {
    (encoder orelse return -1).setKernel(kernel) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_buffer(encoder: ?*ComputeEncoder, buffer: ?*Buffer, offset: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setBuffer(buffer, offset, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_acceleration_structure(encoder: ?*ComputeEncoder, structure: ?*Buffer, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setAccelerationStructure(structure, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_intersection_function_profile(encoder: ?*ComputeEncoder, profile: u32) callconv(.c) c_int {
    (encoder orelse return -1).setIntersectionFunctionProfile(profile) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_buffer_offset(encoder: ?*ComputeEncoder, offset: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setBufferOffset(offset, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_bytes(encoder: ?*ComputeEncoder, bytes: ?[*]const u8, length: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setBytes(bytes, length, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_texture(encoder: ?*ComputeEncoder, texture: ?*Texture, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setTexture(texture, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_set_array_slice(encoder: ?*ComputeEncoder, slice: u32, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setArraySlice(slice, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_copy_buffer(encoder: ?*ComputeEncoder, source: ?*Buffer, source_offset: usize, destination: ?*Buffer, destination_offset: usize, length: usize) callconv(.c) c_int {
    (encoder orelse return -1).copyBuffer(source orelse return -1, source_offset, destination orelse return -1, destination_offset, length) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_copy_buffer_to_texture(encoder: ?*ComputeEncoder, source: ?*Buffer, source_offset: usize, source_bytes_per_row: usize, destination: ?*Texture, destination_region: abi.Region) callconv(.c) c_int {
    (encoder orelse return -1).copyBufferToTexture(source orelse return -1, source_offset, source_bytes_per_row, destination orelse return -1, destination_region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_copy_texture_to_buffer(encoder: ?*ComputeEncoder, source: ?*Texture, source_region: abi.Region, destination: ?*Buffer, destination_offset: usize, destination_bytes_per_row: usize) callconv(.c) c_int {
    (encoder orelse return -1).copyTextureToBuffer(source orelse return -1, source_region, destination orelse return -1, destination_offset, destination_bytes_per_row) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_copy_texture_to_texture(encoder: ?*ComputeEncoder, source: ?*Texture, source_region: abi.Region, destination: ?*Texture, destination_region: abi.Region) callconv(.c) c_int {
    (encoder orelse return -1).copyTextureToTexture(source orelse return -1, source_region, destination orelse return -1, destination_region) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_mipmap(encoder: ?*ComputeEncoder, source: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap(source orelse return -1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_srgb_mipmap_chain(encoder: ?*ComputeEncoder, levels: ?[*]const ?*Texture, level_count: usize) callconv(.c) c_int {
    const values = levels orelse return -1;
    if (level_count < 2) return errorCode(error.InvalidArgument);
    var unwrapped = allocator.alloc(*Texture, level_count) catch return errorCode(error.OutOfMemory);
    defer allocator.free(unwrapped);
    for (0..level_count) |index| unwrapped[index] = values[index] orelse return errorCode(error.InvalidArgument);
    (encoder orelse return -1).generateSrgbMipmapChain(unwrapped) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_mipmap_3d(encoder: ?*ComputeEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3D(source0 orelse return -1, source1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_mipmap_3d_weighted(encoder: ?*ComputeEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3DWeighted(source0 orelse return -1, source1, destination orelse return -1, source1_weight_numerator, source1_weight_denominator) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_mipmap_3d_array(encoder: ?*ComputeEncoder, source_planes: ?[*]const ?*Texture, source_count: usize, destination: ?*Texture) callconv(.c) c_int {
    const sources = source_planes orelse return -1;
    if (source_count == 0) return -1;
    const source_slice: []const *Texture = @ptrCast(sources[0..source_count]);
    (encoder orelse return -1).generateMipmap3DArray(source_slice, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_fill_buffer(encoder: ?*ComputeEncoder, buffer: ?*Buffer, offset: usize, length: usize, value: u8) callconv(.c) c_int {
    (encoder orelse return -1).fillBuffer(buffer orelse return -1, offset, length, value) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_dispatch_threads(encoder: ?*ComputeEncoder, threads_per_grid: abi.Size, threads_per_threadgroup: abi.Size) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreads(threads_per_grid, threads_per_threadgroup) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_dispatch_threadgroups(encoder: ?*ComputeEncoder, threadgroups_per_grid: abi.Size, threads_per_threadgroup: abi.Size) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreadgroups(threadgroups_per_grid, threads_per_threadgroup) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_dispatch_threadgroups_indirect(encoder: ?*ComputeEncoder, indirect_buffer: ?*Buffer, indirect_buffer_offset: usize, threads_per_threadgroup: abi.Size) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreadgroupsIndirect(indirect_buffer orelse return -1, indirect_buffer_offset, threads_per_threadgroup) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_dispatch_threads_indirect(encoder: ?*ComputeEncoder, indirect_buffer: ?*Buffer) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreadsIndirect(indirect_buffer orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_dispatch_threads_indirect_offset(encoder: ?*ComputeEncoder, indirect_buffer: ?*Buffer, indirect_buffer_offset: usize) callconv(.c) c_int {
    (encoder orelse return -1).dispatchThreadsIndirectAtOffset(indirect_buffer orelse return -1, indirect_buffer_offset) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_update_fence(encoder: ?*ComputeEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).updateFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_wait_for_fence(encoder: ?*ComputeEncoder, fence: ?*Fence) callconv(.c) c_int {
    (encoder orelse return -1).waitForFence(fence orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_end_encoding(encoder: ?*ComputeEncoder) callconv(.c) c_int {
    (encoder orelse return -1).endEncoding() catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_destroy(encoder: ?*ComputeEncoder) callconv(.c) void {
    if (encoder) |value| destroyComputeEncoder(value);
}

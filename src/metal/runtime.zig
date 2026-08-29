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
const raster = @import("../raster/raster.zig");
const raster3d = @import("raster3d.zig");
const surface = @import("../surface.zig");

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

pub const TextureFormat = enum {
    rgba8_unorm,
    bgra8_unorm,
    depth32_float,
    stencil8,

    fn bytesPerPixel(self: TextureFormat) usize {
        return if (self == .stencil8) 1 else 4;
    }

    fn isColor(self: TextureFormat) bool {
        return self == .rgba8_unorm or self == .bgra8_unorm;
    }
};

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
};

pub const Heap = struct {
    magic: u64 = heap_magic,
    device: *Device,
    size: usize,
    used: usize = 0,
};

pub const Buffer = struct {
    magic: u64 = buffer_magic,
    device: *Device,
    bytes: []u8,
    heap: ?*Heap = null,
    heap_allocation_offset: usize = 0,
    heap_allocation_size: usize = 0,

    pub fn deinit(self: *Buffer) void {
        allocator.free(self.bytes);
        releaseHeapAllocation(self.heap, self.heap_allocation_size);
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

    pub fn deinit(self: *Texture) void {
        if (self.owns_bytes) allocator.free(self.bytes);
        releaseHeapAllocation(self.heap, self.heap_allocation_size);
        self.magic = 0;
    }

    fn asSurface(self: *Texture) surface.Surface {
        std.debug.assert(self.format.isColor());
        return .{
            .pixels = self.bytes,
            .width = self.width,
            .height = self.height,
            .stride = self.stride,
            .format = switch (self.format) {
                .rgba8_unorm => .rgba8_unorm,
                .bgra8_unorm => .bgra8_unorm,
                .depth32_float => unreachable,
                .stencil8 => unreachable,
            },
        };
    }
};

const DrawCommand = struct {
    vertex_start: usize,
    vertex_count: usize,
    primitive: abi.PrimitiveType,
    options: raster3d.DrawOptions,
};

const BeginRenderCommand = struct {
    target: *Texture,
    pass: abi.RenderPassDescriptor,
    depth: ?[]f32 = null,
    stencil: ?[]u8 = null,
    stencil_load_action: abi.LoadAction = .dont_care,
    stencil_store_action: abi.StoreAction = .dont_care,
    stencil_clear: u8 = 0,
};

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

const Mipmap3DCommand = struct {
    source0: *Texture,
    source1: ?*Texture,
    destination: *Texture,
    source1_weight_numerator: u32,
    source1_weight_denominator: u32,
};

const FillBufferCommand = struct {
    buffer: *Buffer,
    offset: usize,
    length: usize,
    value: u8,
};

const SharedEventCommand = struct {
    event: *SharedEvent,
    value: u64,
};

const ComputeCommand = struct {
    kernel: u8,
    texture: *Texture,
    texture_index: u32,
    buffer: ?*Buffer,
    buffer_offset: usize,
    threads_per_grid: abi.Size,
    threads_per_threadgroup: abi.Size = .{ .width = 0, .height = 0, .depth = 0 },
    indirect_buffer: ?*Buffer = null,
    indirect_buffer_offset: usize = 0,
    indirect_threads: bool = false,
    array_slice: ?u32 = null,
};

const Command = union(enum) {
    begin_render: BeginRenderCommand,
    draw: DrawCommand,
    copy_buffer: CopyBufferCommand,
    copy_buffer_to_texture: BufferTextureCommand,
    copy_texture_to_buffer: TextureBufferCommand,
    copy_texture_to_texture: TextureTextureCommand,
    generate_mipmap: MipmapCommand,
    generate_mipmap_3d: Mipmap3DCommand,
    fill_buffer: FillBufferCommand,
    compute: ComputeCommand,
    synchronize_buffer: *Buffer,
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
    owned_compute_buffers: std.ArrayList(*Buffer) = .empty,

    pub fn deinit(self: *CommandBuffer) void {
        self.commands.deinit(allocator);
        self.vertices.deinit(allocator);
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

    fn appendVertices(self: *CommandBuffer, values: []const abi.Vertex) Error!usize {
        const start = self.vertices.items.len;
        self.vertices.appendSlice(allocator, values) catch return error.OutOfMemory;
        return start;
    }

    pub fn commit(self: *CommandBuffer) Error!void {
        if (self.magic != command_buffer_magic or self.status != .created or self.active_encoder != .none) return error.InvalidCommand;
        self.status = .committed;
        var active_target: ?*Texture = null;
        var active_depth: ?[]f32 = null;
        var active_stencil: ?[]u8 = null;

        for (self.commands.items) |command| switch (command) {
            .begin_render => |begin_render| {
                if (!validTexture(begin_render.target)) return self.fail(error.InvalidResource);
                active_target = begin_render.target;
                active_depth = begin_render.depth;
                active_stencil = begin_render.stencil;
                var target = begin_render.target.asSurface();
                if (begin_render.pass.color.load_action == .clear) {
                    raster.clear(&target, toSurfaceColor(begin_render.pass.color.clear_color));
                }
                if (begin_render.pass.depth.load_action != .dont_care) {
                    const depth = active_depth orelse return self.fail(error.InvalidResource);
                    const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                    if (depth.len < pixel_count) return self.fail(error.InvalidResource);
                    if (begin_render.pass.depth.load_action == .clear) {
                        @memset(depth[0..pixel_count], begin_render.pass.depth.clear_depth);
                    }
                }
                if (begin_render.stencil_load_action != .dont_care) {
                    const stencil = active_stencil orelse return self.fail(error.InvalidResource);
                    const pixel_count = std.math.mul(usize, target.width, target.height) catch return self.fail(error.InvalidArgument);
                    if (stencil.len < pixel_count) return self.fail(error.InvalidResource);
                    if (begin_render.stencil_load_action == .clear) {
                        @memset(stencil[0..pixel_count], begin_render.stencil_clear);
                    }
                }
            },
            .draw => |draw| {
                const target_handle = active_target orelse return self.fail(error.InvalidCommand);
                if (!validTexture(target_handle)) return self.fail(error.InvalidResource);
                if (draw.vertex_start > self.vertices.items.len or draw.vertex_count > self.vertices.items.len - draw.vertex_start) return self.fail(error.InvalidCommand);
                var target = target_handle.asSurface();
                _ = raster3d.draw(
                    &target,
                    active_depth,
                    active_stencil,
                    self.vertices.items[draw.vertex_start .. draw.vertex_start + draw.vertex_count],
                    draw.primitive,
                    draw.options,
                );
            },
            .copy_buffer => |copy| {
                if (!validBuffer(copy.source) or !validBuffer(copy.destination)) return self.fail(error.InvalidResource);
                if (copy.source.device != copy.destination.device) return self.fail(error.InvalidResource);
                if (!rangeValid(copy.source.bytes.len, copy.source_offset, copy.length) or !rangeValid(copy.destination.bytes.len, copy.destination_offset, copy.length)) return self.fail(error.InvalidArgument);
                if (copy.length != 0) @memcpy(copy.destination.bytes[copy.destination_offset .. copy.destination_offset + copy.length], copy.source.bytes[copy.source_offset .. copy.source_offset + copy.length]);
            },
            .copy_buffer_to_texture => |copy| {
                if (!validBuffer(copy.buffer) or !validTexture(copy.texture)) return self.fail(error.InvalidResource);
                if (copy.buffer.device != copy.texture.device) return self.fail(error.InvalidResource);
                copyBufferToTexture(copy) catch |err| return self.fail(err);
            },
            .copy_texture_to_buffer => |copy| {
                if (!validTexture(copy.texture) or !validBuffer(copy.buffer)) return self.fail(error.InvalidResource);
                if (copy.texture.device != copy.buffer.device) return self.fail(error.InvalidResource);
                copyTextureToBuffer(copy) catch |err| return self.fail(err);
            },
            .copy_texture_to_texture => |copy| {
                if (!validTexture(copy.source) or !validTexture(copy.destination)) return self.fail(error.InvalidResource);
                if (copy.source.device != copy.destination.device or copy.source.format != copy.destination.format) return self.fail(error.InvalidResource);
                copyTextureToTexture(copy) catch |err| return self.fail(err);
            },
            .generate_mipmap => |mipmap| {
                if (!validTexture(mipmap.source) or !validTexture(mipmap.destination)) return self.fail(error.InvalidResource);
                if (mipmap.source.device != mipmap.destination.device) return self.fail(error.InvalidResource);
                generateMipmap(mipmap) catch |err| return self.fail(err);
            },
            .generate_mipmap_3d => |mipmap| {
                if (!validTexture(mipmap.source0) or !validTexture(mipmap.destination) or
                    (mipmap.source1 != null and !validTexture(mipmap.source1.?))) return self.fail(error.InvalidResource);
                if (mipmap.source0.device != mipmap.destination.device or
                    (mipmap.source1 != null and mipmap.source1.?.device != mipmap.destination.device)) return self.fail(error.InvalidResource);
                generateMipmap3D(mipmap) catch |err| return self.fail(err);
            },
            .fill_buffer => |fill| {
                if (!validBuffer(fill.buffer)) return self.fail(error.InvalidResource);
                if (!rangeValid(fill.buffer.bytes.len, fill.offset, fill.length)) return self.fail(error.InvalidArgument);
                @memset(fill.buffer.bytes[fill.offset .. fill.offset + fill.length], fill.value);
            },
            .compute => |compute| {
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
                        if ((compute.kernel != 3 and compute.kernel != 4 and resolved.threads_per_grid.depth != 1) or
                            resolved.threads_per_threadgroup.width == 0 or
                            resolved.threads_per_threadgroup.height == 0 or
                            resolved.threads_per_threadgroup.depth == 0) return self.fail(error.InvalidArgument);
                    } else {
                        const groups = abi.Size{
                            .width = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset),
                            .height = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 4),
                            .depth = readU32Little(indirect_buffer.bytes, compute.indirect_buffer_offset + 8),
                        };
                        if ((compute.kernel != 3 and compute.kernel != 4 and groups.depth != 1) or compute.threads_per_threadgroup.depth == 0 or
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
                if (signal.value < signal.event.signaled_value) return self.fail(error.InvalidCommand);
                signal.event.signaled_value = signal.value;
            },
            .wait_event => |wait| {
                if (!validSharedEvent(wait.event) or wait.event.device != self.queue.device) return self.fail(error.InvalidResource);
                if (wait.event.signaled_value < wait.value) return self.fail(error.InvalidCommand);
            },
        };
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
    vertex_buffer: ?*Buffer = null,
    vertex_offset: usize = 0,
    inline_vertices: std.ArrayList(abi.Vertex) = .empty,
    viewport: abi.Viewport,
    scissor: abi.ScissorRect,
    cull_mode: abi.CullMode = .none,
    winding: abi.Winding = .clockwise,
    fill_mode: abi.TriangleFillMode = .fill,
    depth_compare: abi.CompareFunction = .less_equal,
    depth_write_enabled: bool = true,
    blending_enabled: bool = false,
    source_rgb_factor: abi.BlendFactor = .one,
    destination_rgb_factor: abi.BlendFactor = .zero,
    rgb_operation: abi.BlendOperation = .add,
    source_alpha_factor: abi.BlendFactor = .one,
    destination_alpha_factor: abi.BlendFactor = .zero,
    alpha_operation: abi.BlendOperation = .add,
    color_write_mask: u8 = @intFromEnum(abi.ColorWriteMask.all),
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_front: raster3d.StencilFace = .{},
    stencil_back: raster3d.StencilFace = .{},

    pub fn deinit(self: *RenderEncoder) void {
        self.inline_vertices.deinit(allocator);
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
            .blend_color = self.blend_color,
            .stencil_front = self.stencil_front,
            .stencil_back = self.stencil_back,
        };
    }

    pub fn setPipelineFormats(self: *RenderEncoder, color_format: u16, depth_format: u16) Error!void {
        return self.setPipelineFormatsWithStencil(color_format, depth_format, 0);
    }

    pub fn setPipelineFormatsWithStencil(self: *RenderEncoder, color_format: u16, depth_format: u16, stencil_format: u16) Error!void {
        if (!self.open()) return error.InvalidCommand;
        const expected_color = switch (color_format) {
            0 => null,
            @intFromEnum(abi.PixelFormat.rgba8_unorm) => abi.PixelFormat.rgba8_unorm,
            @intFromEnum(abi.PixelFormat.bgra8_unorm) => abi.PixelFormat.bgra8_unorm,
            else => return error.UnsupportedFormat,
        };
        const expected_depth = switch (depth_format) {
            0 => null,
            @intFromEnum(abi.PixelFormat.depth32_float) => abi.PixelFormat.depth32_float,
            else => return error.UnsupportedFormat,
        };
        const expected_stencil = switch (stencil_format) {
            0 => null,
            @intFromEnum(abi.PixelFormat.stencil8) => abi.PixelFormat.stencil8,
            else => return error.UnsupportedFormat,
        };
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |begin_render| {
                const actual_color = texturePixelFormat(begin_render.target) orelse return error.InvalidResource;
                if (expected_color) |format| if (format != actual_color) return error.InvalidArgument;
                if (expected_depth != null and begin_render.depth == null) return error.InvalidArgument;
                if (expected_stencil != null and begin_render.stencil == null) return error.InvalidArgument;
            },
            else => return error.InvalidCommand,
        }
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
            .begin_render => self.command_buffer.commands.items[self.begin_index].begin_render.depth = values,
            else => return error.InvalidCommand,
        }
    }

    pub fn setDepthTexture(self: *RenderEncoder, texture: *Texture) Error!void {
        if (!self.open() or !validTexture(texture) or texture.device != self.command_buffer.queue.device or texture.format != .depth32_float) return error.InvalidArgument;
        if (texture.width != self.colorWidth() or texture.height != self.colorHeight()) return error.InvalidArgument;
        if (@intFromPtr(texture.bytes.ptr) % @alignOf(f32) != 0) return error.InvalidResource;
        const depth: []f32 = @as([*]f32, @ptrCast(@alignCast(texture.bytes.ptr)))[0 .. @as(usize, texture.width) * texture.height];
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| begin_render.depth = depth,
            else => return error.InvalidCommand,
        }
    }

    pub fn setStencilTexture(self: *RenderEncoder, texture: *Texture, load_action: u8, store_action: u8, clear_value: u8) Error!void {
        if (!self.open() or !validTexture(texture) or texture.device != self.command_buffer.queue.device or texture.format != .stencil8) return error.InvalidArgument;
        if (load_action > @intFromEnum(abi.LoadAction.clear) or store_action > @intFromEnum(abi.StoreAction.store) or
            texture.width != self.colorWidth() or texture.height != self.colorHeight()) return error.InvalidArgument;
        const stencil: []u8 = texture.bytes[0 .. @as(usize, texture.width) * texture.height];
        switch (self.command_buffer.commands.items[self.begin_index]) {
            .begin_render => |*begin_render| {
                begin_render.stencil = stencil;
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

    pub fn setVertexBuffer(self: *RenderEncoder, buffer: ?*Buffer, offset: usize, index: u32) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (index != 0) return error.UnsupportedOperation;
        if (buffer) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device or offset > value.bytes.len) return error.InvalidArgument;
        }
        self.vertex_buffer = buffer;
        self.vertex_offset = offset;
    }

    pub fn setVertexBytes(self: *RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (index != 0) return error.UnsupportedOperation;
        if (length != 0 and bytes == null) return error.InvalidArgument;
        if (length % @sizeOf(abi.Vertex) != 0) return error.InvalidArgument;
        self.inline_vertices.clearRetainingCapacity();
        if (length != 0) {
            const raw = bytes.?[0..length];
            try appendVertexBytes(&self.inline_vertices, raw);
        }
        self.vertex_buffer = null;
        self.vertex_offset = 0;
    }

    pub fn setViewport(self: *RenderEncoder, viewport: abi.Viewport) Error!void {
        if (!self.open() or !finiteViewport(viewport)) return error.InvalidArgument;
        self.viewport = viewport;
    }

    pub fn setScissorRect(self: *RenderEncoder, scissor: abi.ScissorRect) Error!void {
        if (!self.open()) return error.InvalidCommand;
        self.scissor = scissor;
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

    fn sourceVertices(self: *const RenderEncoder) Error![]const abi.Vertex {
        if (self.inline_vertices.items.len != 0) return self.inline_vertices.items;
        const buffer = self.vertex_buffer orelse return error.InvalidArgument;
        if (!validBuffer(buffer) or self.vertex_offset > buffer.bytes.len) return error.InvalidArgument;
        const raw = buffer.bytes[self.vertex_offset..];
        if (raw.len % @sizeOf(abi.Vertex) != 0 or @intFromPtr(raw.ptr) % @alignOf(abi.Vertex) != 0) return error.InvalidArgument;
        const pointer: [*]const abi.Vertex = @ptrCast(@alignCast(raw.ptr));
        return pointer[0 .. raw.len / @sizeOf(abi.Vertex)];
    }

    pub fn drawPrimitives(self: *RenderEncoder, primitive: abi.PrimitiveType, vertex_start: usize, vertex_count: usize, instance_count: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive)) return error.InvalidCommand;
        if (instance_count == 0 or vertex_count == 0) return;
        const source = try self.sourceVertices();
        if (vertex_start > source.len or vertex_count > source.len - vertex_start) return error.InvalidArgument;
        const selected = source[vertex_start .. vertex_start + vertex_count];
        var instance: usize = 0;
        while (instance < instance_count) : (instance += 1) {
            const start = try self.command_buffer.appendVertices(selected);
            _ = try self.command_buffer.append(.{ .draw = .{
                .vertex_start = start,
                .vertex_count = selected.len,
                .primitive = primitive,
                .options = self.options(),
            } });
        }
    }

    pub fn drawPrimitivesIndirect(self: *RenderEncoder, primitive: abi.PrimitiveType, indirect_buffer: *Buffer, indirect_buffer_offset: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (indirect_buffer_offset % @alignOf(u32) != 0 or !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 16)) return error.InvalidArgument;
        const vertex_count = readU32Little(indirect_buffer.bytes, indirect_buffer_offset);
        const instance_count = readU32Little(indirect_buffer.bytes, indirect_buffer_offset + 4);
        const vertex_start = readU32Little(indirect_buffer.bytes, indirect_buffer_offset + 8);
        try self.drawPrimitives(primitive, vertex_start, vertex_count, instance_count);
    }

    pub fn drawIndexedPrimitives(self: *RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, instance_count: usize) Error!void {
        return self.drawIndexedPrimitivesWithBaseVertex(primitive, index_count, index_type, index_buffer, index_buffer_offset, instance_count, 0);
    }

    pub fn drawIndexedPrimitivesWithBaseVertex(self: *RenderEncoder, primitive: abi.PrimitiveType, index_count: usize, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, instance_count: usize, base_vertex: i64) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validIndexType(index_type)) return error.InvalidCommand;
        if (!validBuffer(index_buffer) or index_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (instance_count == 0 or index_count == 0) return;
        const source = try self.sourceVertices();
        const index_size: usize = if (index_type == .uint16) 2 else 4;
        const index_bytes = std.math.mul(usize, index_count, index_size) catch return error.InvalidArgument;
        if (!rangeValid(index_buffer.bytes.len, index_buffer_offset, index_bytes)) return error.InvalidArgument;
        const raw = index_buffer.bytes[index_buffer_offset .. index_buffer_offset + index_bytes];
        var instance: usize = 0;
        while (instance < instance_count) : (instance += 1) {
            const start = self.command_buffer.vertices.items.len;
            for (0..index_count) |index| {
                const offset = index * index_size;
                const value: usize = if (index_type == .uint16)
                    @as(usize, raw[offset]) | (@as(usize, raw[offset + 1]) << 8)
                else
                    @as(usize, raw[offset]) |
                        (@as(usize, raw[offset + 1]) << 8) |
                        (@as(usize, raw[offset + 2]) << 16) |
                        (@as(usize, raw[offset + 3]) << 24);
                const signed_value = @as(i128, @intCast(value)) + @as(i128, base_vertex);
                if (signed_value < 0 or signed_value >= @as(i128, @intCast(source.len))) return error.InvalidArgument;
                self.command_buffer.vertices.append(allocator, source[@intCast(signed_value)]) catch return error.OutOfMemory;
            }
            _ = try self.command_buffer.append(.{ .draw = .{
                .vertex_start = start,
                .vertex_count = index_count,
                .primitive = primitive,
                .options = self.options(),
            } });
        }
    }

    pub fn drawIndexedPrimitivesIndirect(self: *RenderEncoder, primitive: abi.PrimitiveType, index_type: abi.IndexType, index_buffer: *Buffer, index_buffer_offset: usize, indirect_buffer: *Buffer, indirect_buffer_offset: usize) Error!void {
        if (!self.open() or !validPrimitive(primitive) or !validIndexType(index_type) or !validBuffer(index_buffer) or !validBuffer(indirect_buffer)) return error.InvalidArgument;
        if (index_buffer.device != self.command_buffer.queue.device or indirect_buffer.device != self.command_buffer.queue.device) return error.InvalidArgument;
        if (indirect_buffer_offset % @alignOf(u32) != 0 or !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, 20)) return error.InvalidArgument;
        const index_count = readU32Little(indirect_buffer.bytes, indirect_buffer_offset);
        const instance_count = readU32Little(indirect_buffer.bytes, indirect_buffer_offset + 4);
        const index_start = readU32Little(indirect_buffer.bytes, indirect_buffer_offset + 8);
        const base_vertex = @as(i64, @intCast(@as(i32, @bitCast(readU32Little(indirect_buffer.bytes, indirect_buffer_offset + 12)))));
        const index_size: usize = if (index_type == .uint16) 2 else 4;
        try self.drawIndexedPrimitivesWithBaseVertex(primitive, index_count, index_type, index_buffer, index_buffer_offset + @as(usize, index_start) * index_size, instance_count, base_vertex);
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
        _ = try self.command_buffer.append(.{ .generate_mipmap = .{ .source = source, .destination = destination } });
    }

    pub fn generateMipmap3D(self: *BlitEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture) Error!void {
        const denominator: u32 = if (source1 != null) 2 else 1;
        try self.generateMipmap3DWeighted(source0, source1, destination, if (source1 != null) 1 else 0, denominator);
    }

    pub fn generateMipmap3DWeighted(self: *BlitEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) Error!void {
        if (!self.open() or !validTexture(source0) or !validTexture(destination)) return error.InvalidArgument;
        if (source0.device != destination.device or source0.format != destination.format) return error.InvalidArgument;
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

    /// Sparse mappings have no CPU/ZPU representation yet. Fail at record
    /// time, matching the adapter's explicit unsupported-feature boundary.
    pub fn updateTextureMappings(self: *ResourceStateEncoder, texture: *Texture, mode: u32, regions: []const abi.Region, mip_levels: []const usize, slices: []const usize) Error!void {
        _ = texture;
        _ = mode;
        _ = regions;
        _ = mip_levels;
        _ = slices;
        if (!self.open()) return error.InvalidCommand;
        return error.UnsupportedOperation;
    }

    pub fn endEncoding(self: *ResourceStateEncoder) Error!void {
        if (!self.open()) return error.InvalidCommand;
        try self.command_buffer.end(.resource_state);
    }
};

pub const ComputeEncoder = struct {
    magic: u64 = compute_encoder_magic,
    command_buffer: *CommandBuffer,
    kernel: u8 = 0,
    texture: ?*Texture = null,
    texture_index: u32 = 0,
    array_slice: ?u32 = null,
    buffer: ?*Buffer = null,
    buffer_offset: usize = 0,

    pub fn deinit(self: *ComputeEncoder) void {
        self.magic = 0;
    }

    fn open(self: *const ComputeEncoder) bool {
        return self.magic == compute_encoder_magic and self.command_buffer.active_encoder == .compute;
    }

    pub fn setKernel(self: *ComputeEncoder, kernel: u8) Error!void {
        if (!self.open()) return error.InvalidCommand;
        if (kernel != 1 and kernel != 2 and kernel != 3 and kernel != 4) return error.UnsupportedOperation;
        self.kernel = kernel;
    }

    pub fn setBuffer(self: *ComputeEncoder, buffer: ?*Buffer, offset: usize, index: u32) Error!void {
        if (!self.open() or index != 0) return error.UnsupportedOperation;
        if (buffer) |value| {
            if (!validBuffer(value) or value.device != self.command_buffer.queue.device or offset > value.bytes.len) return error.InvalidArgument;
        }
        self.buffer = buffer;
        self.buffer_offset = offset;
    }

    pub fn setBufferOffset(self: *ComputeEncoder, offset: usize, index: u32) Error!void {
        if (!self.open() or index != 0) return error.UnsupportedOperation;
        const buffer = self.buffer orelse return error.InvalidCommand;
        try self.setBuffer(buffer, offset, index);
    }

    pub fn setBytes(self: *ComputeEncoder, bytes: ?[*]const u8, length: usize, index: u32) Error!void {
        if (!self.open() or index != 0 or (length != 0 and bytes == null)) return error.InvalidArgument;
        const buffer = try createBuffer(self.command_buffer.queue.device, length, bytes);
        errdefer destroyBuffer(buffer);
        self.command_buffer.owned_compute_buffers.append(allocator, buffer) catch return error.OutOfMemory;
        self.buffer = buffer;
        self.buffer_offset = 0;
    }

    pub fn setTexture(self: *ComputeEncoder, texture: ?*Texture, index: u32) Error!void {
        if (!self.open() or (index != 0 and index != 1)) return error.UnsupportedOperation;
        if (texture) |value| {
            if (!validTexture(value) or value.device != self.command_buffer.queue.device or !value.format.isColor()) return error.InvalidResource;
        }
        self.texture = texture;
        self.texture_index = index;
        self.array_slice = null;
    }

    pub fn setArraySlice(self: *ComputeEncoder, slice: u32, index: u32) Error!void {
        if (!self.open() or self.texture == null or index != self.texture_index) return error.InvalidArgument;
        self.array_slice = slice;
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
        _ = try self.command_buffer.append(.{ .generate_mipmap = .{ .source = source, .destination = destination } });
    }

    pub fn generateMipmap3D(self: *ComputeEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture) Error!void {
        const denominator: u32 = if (source1 != null) 2 else 1;
        try self.generateMipmap3DWeighted(source0, source1, destination, if (source1 != null) 1 else 0, denominator);
    }

    pub fn generateMipmap3DWeighted(self: *ComputeEncoder, source0: *Texture, source1: ?*Texture, destination: *Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) Error!void {
        if (!self.open() or !validTexture(source0) or !validTexture(destination)) return error.InvalidArgument;
        if (source0.device != destination.device or source0.format != destination.format) return error.InvalidArgument;
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

    pub fn fillBuffer(self: *ComputeEncoder, buffer: *Buffer, offset: usize, length: usize, value: u8) Error!void {
        if (!self.open() or !validBuffer(buffer) or !rangeValid(buffer.bytes.len, offset, length)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .fill_buffer = .{ .buffer = buffer, .offset = offset, .length = length, .value = value } });
    }

    pub fn dispatchThreads(self: *ComputeEncoder, threads_per_grid: abi.Size, threads_per_threadgroup: abi.Size) Error!void {
        if (!self.open() or self.kernel == 0 or self.texture == null) return error.InvalidCommand;
        if (((self.kernel == 1 or self.kernel == 3 or self.kernel == 4) and self.texture_index != 0) or (self.kernel == 2 and
            (self.texture_index != 1 or self.buffer == null))) return error.InvalidCommand;
        if ((self.kernel != 3 and self.kernel != 4 and threads_per_grid.depth != 1) or
            threads_per_threadgroup.width == 0 or
            threads_per_threadgroup.height == 0 or threads_per_threadgroup.depth == 0) return error.InvalidArgument;
        if (self.kernel != 4 and threads_per_threadgroup.depth != 1) return error.UnsupportedOperation;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .texture = self.texture.?,
            .texture_index = self.texture_index,
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .threads_per_grid = threads_per_grid,
            .array_slice = self.array_slice,
        } });
    }

    pub fn dispatchThreadgroups(self: *ComputeEncoder, threadgroups_per_grid: abi.Size, threads_per_threadgroup: abi.Size) Error!void {
        if (!self.open() or self.kernel == 0 or self.texture == null) return error.InvalidCommand;
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
        if (!self.open() or self.kernel == 0 or self.texture == null) return error.InvalidCommand;
        if (((self.kernel == 1 or self.kernel == 3 or self.kernel == 4) and self.texture_index != 0) or (self.kernel == 2 and
            (self.texture_index != 1 or self.buffer == null))) return error.InvalidCommand;
        if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
            indirect_buffer_offset % @alignOf(u32) != 0 or
            !rangeValid(indirect_buffer.bytes.len, indirect_buffer_offset, @sizeOf(abi.Size))) return error.InvalidArgument;
        if (threads_per_threadgroup.depth == 0 or threads_per_threadgroup.width == 0 or threads_per_threadgroup.height == 0) return error.InvalidArgument;
        if (self.kernel != 4 and threads_per_threadgroup.depth != 1) return error.UnsupportedOperation;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .texture = self.texture.?,
            .texture_index = self.texture_index,
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .threads_per_grid = .{ .width = 0, .height = 0, .depth = 1 },
            .threads_per_threadgroup = threads_per_threadgroup,
            .indirect_buffer = indirect_buffer,
            .indirect_buffer_offset = indirect_buffer_offset,
            .array_slice = self.array_slice,
        } });
    }

    pub fn dispatchThreadsIndirect(self: *ComputeEncoder, indirect_buffer: *Buffer) Error!void {
        if (!self.open() or self.kernel == 0 or self.texture == null) return error.InvalidCommand;
        if (((self.kernel == 1 or self.kernel == 3 or self.kernel == 4) and self.texture_index != 0) or (self.kernel == 2 and
            (self.texture_index != 1 or self.buffer == null))) return error.InvalidCommand;
        if (!validBuffer(indirect_buffer) or indirect_buffer.device != self.command_buffer.queue.device or
            indirect_buffer.bytes.len < 2 * @sizeOf(abi.Size)) return error.InvalidArgument;
        _ = try self.command_buffer.append(.{ .compute = .{
            .kernel = self.kernel,
            .texture = self.texture.?,
            .texture_index = self.texture_index,
            .buffer = self.buffer,
            .buffer_offset = self.buffer_offset,
            .threads_per_grid = .{ .width = 0, .height = 0, .depth = 1 },
            .indirect_buffer = indirect_buffer,
            .indirect_threads = true,
            .array_slice = self.array_slice,
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

fn unorm8Fraction(numerator: u32, denominator: u32) u8 {
    return @intCast((@as(u64, numerator) * 255 + @as(u64, denominator) / 2) / denominator);
}

fn executeCompute(command: ComputeCommand) Error!void {
    if (!validTexture(command.texture) or !command.texture.format.isColor()) return error.InvalidResource;
    if (command.kernel != 3 and command.kernel != 4 and command.threads_per_grid.depth != 1) return error.InvalidArgument;
    const width = @min(command.threads_per_grid.width, command.texture.width);
    const height = @min(command.threads_per_grid.height, command.texture.height);
    switch (command.kernel) {
        1, 3, 4 => for (0..height) |y| {
            for (0..width) |x| {
                const red = unorm8Fraction(@as(u32, @intCast(x)) + 1, 8);
                const green = unorm8Fraction(@as(u32, @intCast(y)) + 1, 8);
                const blue = if (command.kernel == 4)
                    unorm8Fraction(@as(u32, command.array_slice orelse 0) + 1, 8)
                else
                    64;
                const offset = y * command.texture.stride + x * 4;
                if (command.texture.format == .rgba8_unorm) {
                    command.texture.bytes[offset + 0] = red;
                    command.texture.bytes[offset + 1] = green;
                    command.texture.bytes[offset + 2] = blue;
                } else {
                    // Metal's BGRA texture memory is [B, G, R, A], while the
                    // kernel's logical result is RGBA.
                    command.texture.bytes[offset + 0] = blue;
                    command.texture.bytes[offset + 1] = green;
                    command.texture.bytes[offset + 2] = red;
                }
                command.texture.bytes[offset + 3] = 255;
            }
        },
        2 => {
            const source = command.buffer orelse return error.InvalidCommand;
            const row_bytes = std.math.mul(usize, command.texture.width, 4) catch return error.InvalidArgument;
            const required = if (width == 0 or height == 0) 0 else std.math.add(
                usize,
                std.math.mul(usize, @as(usize, height - 1), row_bytes) catch return error.InvalidArgument,
                std.math.mul(usize, @as(usize, width), 4) catch return error.InvalidArgument,
            ) catch return error.InvalidArgument;
            if (!rangeValid(source.bytes.len, command.buffer_offset, required)) return error.InvalidArgument;
            for (0..height) |y| {
                const source_row = command.buffer_offset + y * row_bytes;
                for (0..width) |x| {
                    const source_offset = source_row + x * 4;
                    const destination_offset = y * command.texture.stride + x * 4;
                    const red = source.bytes[source_offset + 0];
                    const green = source.bytes[source_offset + 1];
                    if (command.texture.format == .rgba8_unorm) {
                        command.texture.bytes[destination_offset + 0] = red;
                        command.texture.bytes[destination_offset + 1] = green;
                        command.texture.bytes[destination_offset + 2] = source.bytes[source_offset + 2];
                    } else {
                        command.texture.bytes[destination_offset + 0] = source.bytes[source_offset + 2];
                        command.texture.bytes[destination_offset + 1] = green;
                        command.texture.bytes[destination_offset + 2] = red;
                    }
                    command.texture.bytes[destination_offset + 3] = source.bytes[source_offset + 3];
                }
            }
        },
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
    const result = allocator.create(Heap) catch return error.OutOfMemory;
    result.* = .{ .device = device, .size = size };
    return result;
}

pub fn destroyHeap(heap: *Heap) void {
    if (!validHeap(heap)) return;
    heap.magic = 0;
    allocator.destroy(heap);
}

fn reserveHeapAllocation(heap: *Heap, size: usize, alignment: usize) Error!usize {
    if (!validHeap(heap) or alignment == 0 or (alignment & (alignment - 1)) != 0) return error.InvalidArgument;
    const mask = alignment - 1;
    const previous = heap.used;
    const start = (std.math.add(usize, previous, mask) catch return error.InvalidArgument) & ~mask;
    return reserveHeapAllocationAtOffset(heap, size, alignment, start);
}

fn reserveHeapAllocationAtOffset(heap: *Heap, size: usize, alignment: usize, offset: usize) Error!usize {
    if (!validHeap(heap) or alignment == 0 or (alignment & (alignment - 1)) != 0 or
        (offset & (alignment - 1)) != 0 or offset != heap.used) return error.InvalidArgument;
    const end = std.math.add(usize, offset, size) catch return error.InvalidArgument;
    if (end > heap.size) return error.OutOfMemory;
    heap.used = end;
    return offset;
}

fn releaseHeapAllocation(heap: ?*Heap, allocation_size: usize) void {
    if (heap) |value| {
        if (validHeap(value) and allocation_size <= value.used) value.used -= allocation_size;
    }
}

pub fn heapMaxAvailableSize(heap: *const Heap, alignment: usize) usize {
    if (!validHeap(@constCast(heap)) or alignment == 0 or (alignment & (alignment - 1)) != 0) return 0;
    const mask = alignment - 1;
    const start = (std.math.add(usize, heap.used, mask) catch return 0) & ~mask;
    return if (start > heap.size) 0 else heap.size - start;
}

pub fn createBufferInHeap(heap: *Heap, length: usize, initial_bytes: ?[*]const u8) Error!*Buffer {
    if (!validHeap(heap)) return error.InvalidResource;
    const result = try createBuffer(heap.device, length, initial_bytes);
    errdefer destroyBuffer(result);
    const previous = heap.used;
    const allocation_offset = try reserveHeapAllocation(heap, length, @alignOf(u32));
    result.heap = heap;
    result.heap_allocation_offset = allocation_offset;
    result.heap_allocation_size = heap.used - previous;
    return result;
}

pub fn createBufferInHeapAtOffset(heap: *Heap, length: usize, initial_bytes: ?[*]const u8, offset: usize) Error!*Buffer {
    if (!validHeap(heap)) return error.InvalidResource;
    const result = try createBuffer(heap.device, length, initial_bytes);
    errdefer destroyBuffer(result);
    const previous = heap.used;
    const allocation_offset = try reserveHeapAllocationAtOffset(heap, length, @alignOf(u32), offset);
    result.heap = heap;
    result.heap_allocation_offset = allocation_offset;
    result.heap_allocation_size = heap.used - previous;
    return result;
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

pub fn destroyBuffer(buffer: *Buffer) void {
    if (!validBuffer(buffer)) return;
    buffer.deinit();
    allocator.destroy(buffer);
}

pub fn createTexture(device: *Device, width: u32, height: u32, format_raw: u16) Error!*Texture {
    if (!validDevice(device)) return error.InvalidResource;
    const format: TextureFormat = switch (format_raw) {
        @intFromEnum(abi.PixelFormat.rgba8_unorm) => .rgba8_unorm,
        @intFromEnum(abi.PixelFormat.bgra8_unorm) => .bgra8_unorm,
        @intFromEnum(abi.PixelFormat.depth32_float) => .depth32_float,
        @intFromEnum(abi.PixelFormat.stencil8) => .stencil8,
        else => return error.UnsupportedFormat,
    };
    const stride = std.math.mul(usize, width, format.bytesPerPixel()) catch return error.InvalidArgument;
    const length = std.math.mul(usize, stride, height) catch return error.InvalidArgument;
    const bytes = allocator.alignedAlloc(u8, std.mem.Alignment.of(f32), length) catch return error.OutOfMemory;
    errdefer allocator.free(bytes);
    @memset(bytes, 0);
    const result = allocator.create(Texture) catch return error.OutOfMemory;
    result.* = .{ .device = device, .width = width, .height = height, .stride = stride, .format = format, .bytes = bytes, .owns_bytes = true };
    return result;
}

pub fn createTextureInHeap(heap: *Heap, width: u32, height: u32, format_raw: u16) Error!*Texture {
    if (!validHeap(heap)) return error.InvalidResource;
    const result = try createTexture(heap.device, width, height, format_raw);
    errdefer destroyTexture(result);
    const previous = heap.used;
    const allocation_offset = try reserveHeapAllocation(heap, result.bytes.len, @alignOf(f32));
    result.heap = heap;
    result.heap_allocation_offset = allocation_offset;
    result.heap_allocation_size = heap.used - previous;
    return result;
}

pub fn createTextureInHeapAtOffset(heap: *Heap, width: u32, height: u32, format_raw: u16, offset: usize) Error!*Texture {
    if (!validHeap(heap)) return error.InvalidResource;
    const result = try createTexture(heap.device, width, height, format_raw);
    errdefer destroyTexture(result);
    const previous = heap.used;
    const allocation_offset = try reserveHeapAllocationAtOffset(heap, result.bytes.len, @alignOf(f32), offset);
    result.heap = heap;
    result.heap_allocation_offset = allocation_offset;
    result.heap_allocation_size = heap.used - previous;
    return result;
}

pub fn createTextureFromBuffer(buffer: *Buffer, width: u32, height: u32, format_raw: u16, offset: usize, bytes_per_row: usize) Error!*Texture {
    if (!validBuffer(buffer)) return error.InvalidResource;
    const format: TextureFormat = switch (format_raw) {
        @intFromEnum(abi.PixelFormat.rgba8_unorm) => .rgba8_unorm,
        @intFromEnum(abi.PixelFormat.bgra8_unorm) => .bgra8_unorm,
        @intFromEnum(abi.PixelFormat.stencil8) => .stencil8,
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
    event.magic = 0;
    allocator.destroy(event);
}

pub fn setSharedEventValue(event: *SharedEvent, value: u64) Error!void {
    if (!validSharedEvent(event) or value < event.signaled_value) return error.InvalidArgument;
    event.signaled_value = value;
}

pub fn waitSharedEventValue(event: *const SharedEvent, value: u64, timeout_ms: u64) Error!void {
    _ = timeout_ms;
    if (event.magic != shared_event_magic or !validDevice(event.device)) return error.InvalidResource;
    if (event.signaled_value < value) return error.InvalidCommand;
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
    const result = allocator.create(RenderEncoder) catch return error.OutOfMemory;
    result.* = .{
        .command_buffer = command_buffer,
        .begin_index = begin_index,
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = @floatFromInt(texture.width), .height = @floatFromInt(texture.height), .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = texture.width, .height = texture.height },
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
    if (length != 0) @memcpy(buffer.bytes[offset .. offset + length], bytes.?[0..length]);
}

pub fn textureGetBytes(texture: *Texture, destination: ?[*]u8, destination_length: usize, bytes_per_row: usize, region: abi.Region) Error!void {
    if (!validTexture(texture) or (region.origin.z != 0) or (region.size.depth != 1)) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, region.size.width, texture.format.bytesPerPixel()) catch return error.InvalidArgument;
    const stride = if (bytes_per_row == 0) row_bytes else bytes_per_row;
    try validateRegion(texture.width, texture.height, region, stride, destination_length, texture.format.bytesPerPixel());
    if (row_bytes != 0 and destination == null) return error.InvalidArgument;
    if (row_bytes == 0) return;
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
    for (0..region.size.height) |row| {
        const source_offset = row * stride;
        const destination_offset = (@as(usize, region.origin.y) + row) * texture.stride + @as(usize, region.origin.x) * texture.format.bytesPerPixel();
        @memcpy(texture.bytes[destination_offset .. destination_offset + row_bytes], source.?[source_offset .. source_offset + row_bytes]);
    }
}

fn appendVertexBytes(list: *std.ArrayList(abi.Vertex), raw: []const u8) Error!void {
    if (raw.len % @sizeOf(abi.Vertex) != 0) return error.InvalidArgument;
    for (0..raw.len / @sizeOf(abi.Vertex)) |index| {
        var value: abi.Vertex = undefined;
        const destination = std.mem.asBytes(&value);
        @memcpy(destination, raw[index * @sizeOf(abi.Vertex) ..][0..@sizeOf(abi.Vertex)]);
        list.append(allocator, value) catch return error.OutOfMemory;
    }
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

fn generateMipmap(command: MipmapCommand) Error!void {
    if (command.source == command.destination or !command.source.format.isColor()) return error.UnsupportedFormat;
    const destination_width: u32 = if (command.source.width > 1) command.source.width / 2 else 1;
    const destination_height: u32 = if (command.source.height > 1) command.source.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height) return error.InvalidArgument;
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
                    const source_offset = y_sample.index * command.source.stride + x_sample.index * 4;
                    const weight = x_sample.weight * y_sample.weight;
                    for (0..4) |component| sums[component] += @as(u64, command.source.bytes[source_offset + component]) * weight;
                }
            }
            const destination_offset = y * command.destination.stride + x * 4;
            for (0..4) |component| command.destination.bytes[destination_offset + component] = @intCast((sums[component] + weight_denominator / 2) / weight_denominator);
        }
    }
}

fn generateMipmap3D(command: Mipmap3DCommand) Error!void {
    if (command.source0 == command.destination or !command.source0.format.isColor()) return error.UnsupportedFormat;
    if (command.source1_weight_denominator == 0 or command.source1_weight_numerator > command.source1_weight_denominator or
        (command.source1 == null and command.source1_weight_numerator != 0)) return error.InvalidArgument;
    const source1 = command.source1;
    if (source1) |value| {
        if (value == command.destination or value.width != command.source0.width or
            value.height != command.source0.height or value.format != command.source0.format) return error.InvalidArgument;
    }
    const destination_width: u32 = if (command.source0.width > 1) command.source0.width / 2 else 1;
    const destination_height: u32 = if (command.source0.height > 1) command.source0.height / 2 else 1;
    if (command.destination.width != destination_width or command.destination.height != destination_height) return error.InvalidArgument;
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
                        const source_offset = y_sample.index * source_sample.texture.stride + x_sample.index * 4;
                        const weight = source_sample.weight * x_sample.weight * y_sample.weight;
                        for (0..4) |component| sums[component] += @as(u64, source_sample.texture.bytes[source_offset + component]) * weight;
                    }
                }
            }
            if (source1) |value| {
                if (source1_z_weight != 0) {
                    for (y_weights) |y_sample| {
                        if (y_sample.weight == 0) continue;
                        for (x_weights) |x_sample| {
                            if (x_sample.weight == 0) continue;
                            const source_offset = y_sample.index * value.stride + x_sample.index * 4;
                            const weight = source1_z_weight * x_sample.weight * y_sample.weight;
                            for (0..4) |component| sums[component] += @as(u64, value.bytes[source_offset + component]) * weight;
                        }
                    }
                }
            }
            const destination_offset = y * command.destination.stride + x * 4;
            for (0..4) |component| command.destination.bytes[destination_offset + component] = @intCast((sums[component] + weight_denominator / 2) / weight_denominator);
        }
    }
}

fn validateRegion(width: u32, height: u32, region: abi.Region, stride: usize, storage_length: usize, bytes_per_pixel: usize) Error!void {
    if (region.origin.z != 0 or region.size.depth != 1) return error.InvalidArgument;
    if (region.origin.x > width or region.origin.y > height or region.size.width > width - region.origin.x or region.size.height > height - region.origin.y) return error.InvalidArgument;
    const row_bytes = std.math.mul(usize, region.size.width, bytes_per_pixel) catch return error.InvalidArgument;
    if (stride < row_bytes) return error.InvalidArgument;
    const needed = if (region.size.height == 0) 0 else std.math.add(usize, std.math.mul(usize, region.size.height - 1, stride) catch return error.InvalidArgument, row_bytes) catch return error.InvalidArgument;
    if (storage_length < needed) return error.InvalidArgument;
}

fn readU32Little(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn texturePixelFormat(texture: *const Texture) ?abi.PixelFormat {
    return switch (texture.format) {
        .rgba8_unorm => .rgba8_unorm,
        .bgra8_unorm => .bgra8_unorm,
        .depth32_float => .depth32_float,
        .stencil8 => .stencil8,
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

fn validTexture(texture: *Texture) bool {
    return texture.magic == texture_magic and validDevice(texture.device);
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

fn finiteViewport(viewport: abi.Viewport) bool {
    return std.math.isFinite(viewport.origin_x) and std.math.isFinite(viewport.origin_y) and
        std.math.isFinite(viewport.width) and std.math.isFinite(viewport.height) and
        std.math.isFinite(viewport.znear) and std.math.isFinite(viewport.zfar) and
        viewport.width >= 0 and viewport.height >= 0;
}

fn validPass(pass: abi.RenderPassDescriptor) bool {
    return @intFromEnum(pass.color.load_action) <= @intFromEnum(abi.LoadAction.clear) and
        @intFromEnum(pass.color.store_action) <= @intFromEnum(abi.StoreAction.store) and
        @intFromEnum(pass.depth.load_action) <= @intFromEnum(abi.LoadAction.clear) and
        @intFromEnum(pass.depth.store_action) <= @intFromEnum(abi.StoreAction.store) and
        std.math.isFinite(pass.depth.clear_depth);
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

fn toSurfaceColor(color: abi.Color) surface.Color {
    return .{
        .r = colorByte(color.red),
        .g = colorByte(color.green),
        .b = colorByte(color.blue),
        .a = colorByte(color.alpha),
    };
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
        17, 18, 19, 255, 53, 54, 55, 255,
        101, 102, 103, 255, 197, 198, 199, 255,
    }, destination.bytes);
}

test "CPU compute is deferred, bounded, and pixel deterministic" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(1);
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

test "CPU compute encoder resolves Metal 4 indirect thread arguments at commit" {
    const device = try createDevice();
    defer destroyDevice(device);
    const queue = try createQueue(device);
    defer destroyQueue(queue);
    const texture = try createTexture(device, 4, 4, @intFromEnum(abi.PixelFormat.rgba8_unorm));
    defer destroyTexture(texture);
    const initial_arguments = [_]u32{ 4, 3, 1, 2, 2, 1 };
    const indirect = try createBuffer(device, @sizeOf(@TypeOf(initial_arguments)), @ptrCast(&initial_arguments));
    defer destroyBuffer(indirect);
    var command_buffer = try createCommandBuffer(queue);
    defer destroyCommandBuffer(command_buffer);
    var encoder = try beginCompute(command_buffer);
    try encoder.setKernel(1);
    try encoder.setTexture(texture, 0);
    try encoder.dispatchThreadsIndirect(indirect);
    try encoder.endEncoding();
    destroyComputeEncoder(encoder);
    const updated_arguments = [_]u32{ 2, 3, 1, 1, 1, 1 };
    try bufferWrite(indirect, 0, @ptrCast(&updated_arguments), @sizeOf(@TypeOf(updated_arguments)));
    try std.testing.expectEqual(@as(u8, 0), texture.bytes[0]);
    try command_buffer.commit();
    try std.testing.expectEqual(CommandStatus.completed, command_buffer.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 32, 32, 64, 255 }, texture.bytes[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 96, 64, 255 }, texture.bytes[2 * texture.stride + 1 * 4 ..][0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, texture.bytes[3 * texture.stride ..][0..4]);
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
    try encoder.setVertexBytes(@ptrCast(&far), @sizeOf(@TypeOf(far)), 0);
    try encoder.drawPrimitives(.triangle, 0, far.len, 1);
    try encoder.setVertexBytes(@ptrCast(&near), @sizeOf(@TypeOf(near)), 0);
    try encoder.drawPrimitives(.triangle, 0, near.len, 1);
    try encoder.endEncoding();
    destroyRenderEncoder(encoder);
    try command_buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, color.bytes[0..4]);
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
        try encoder.setStencilState(front_face,
            @intFromEnum(abi.CompareFunction.equal),
            @intFromEnum(abi.StencilOperation.zero),
            @intFromEnum(abi.StencilOperation.keep),
            @intFromEnum(abi.StencilOperation.increment_clamp), 0xff, 0xff);
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

pub export fn zpu_metal_buffer_destroy(buffer: ?*Buffer) callconv(.c) void {
    if (buffer) |value| destroyBuffer(value);
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
    if (!validBuffer(value) or value.bytes.len == 0) return null;
    return value.bytes.ptr;
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
    return value.signaled_value;
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

pub export fn zpu_metal_render_encoder_set_vertex_bytes(encoder: ?*RenderEncoder, bytes: ?[*]const u8, length: usize, index: u32) callconv(.c) c_int {
    (encoder orelse return -1).setVertexBytes(bytes, length, index) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_viewport(encoder: ?*RenderEncoder, viewport: abi.Viewport) callconv(.c) c_int {
    (encoder orelse return -1).setViewport(viewport) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_scissor_rect(encoder: ?*RenderEncoder, scissor: abi.ScissorRect) callconv(.c) c_int {
    (encoder orelse return -1).setScissorRect(scissor) catch |err| return errorCode(err);
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

pub export fn zpu_metal_render_encoder_set_pipeline_formats(encoder: ?*RenderEncoder, color_format: u16, depth_format: u16) callconv(.c) c_int {
    (encoder orelse return -1).setPipelineFormats(color_format, depth_format) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_pipeline_formats_with_stencil(encoder: ?*RenderEncoder, color_format: u16, depth_format: u16, stencil_format: u16) callconv(.c) c_int {
    (encoder orelse return -1).setPipelineFormatsWithStencil(color_format, depth_format, stencil_format) catch |err| return errorCode(err);
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

pub export fn zpu_metal_render_encoder_set_depth_buffer(encoder: ?*RenderEncoder, depth: ?[*]f32, depth_count: usize) callconv(.c) c_int {
    (encoder orelse return -1).setDepthBuffer(depth, depth_count) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_render_encoder_set_stencil_texture(encoder: ?*RenderEncoder, texture: ?*Texture, load_action: u8, store_action: u8, clear_value: u8) callconv(.c) c_int {
    (encoder orelse return -1).setStencilTexture(texture orelse return -1, load_action, store_action, clear_value) catch |err| return errorCode(err);
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

pub export fn zpu_metal_render_encoder_draw_indexed_primitives_indirect(encoder: ?*RenderEncoder, primitive: abi.PrimitiveType, index_type: abi.IndexType, index_buffer: ?*Buffer, index_buffer_offset: usize, indirect_buffer: ?*Buffer, indirect_buffer_offset: usize) callconv(.c) c_int {
    (encoder orelse return -1).drawIndexedPrimitivesIndirect(primitive, index_type, index_buffer orelse return -1, index_buffer_offset, indirect_buffer orelse return -1, indirect_buffer_offset) catch |err| return errorCode(err);
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

pub export fn zpu_metal_blit_encoder_generate_mipmap_3d(encoder: ?*BlitEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3D(source0 orelse return -1, source1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_blit_encoder_generate_mipmap_3d_weighted(encoder: ?*BlitEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3DWeighted(source0 orelse return -1, source1, destination orelse return -1, source1_weight_numerator, source1_weight_denominator) catch |err| return errorCode(err);
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

pub export fn zpu_metal_compute_encoder_generate_mipmap_3d(encoder: ?*ComputeEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3D(source0 orelse return -1, source1, destination orelse return -1) catch |err| return errorCode(err);
    return 0;
}

pub export fn zpu_metal_compute_encoder_generate_mipmap_3d_weighted(encoder: ?*ComputeEncoder, source0: ?*Texture, source1: ?*Texture, destination: ?*Texture, source1_weight_numerator: u32, source1_weight_denominator: u32) callconv(.c) c_int {
    (encoder orelse return -1).generateMipmap3DWeighted(source0 orelse return -1, source1, destination orelse return -1, source1_weight_numerator, source1_weight_denominator) catch |err| return errorCode(err);
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

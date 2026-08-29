// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Small, deterministic CPU rasterizer for the native Metal-facing ABI.
//!
//! Work is split into two non-overlapping screen bands. The calling thread
//! owns one band and a single worker owns the other, so a 3D submission never
//! creates more than two rendering lanes and no pixel/depth lock is needed.

const std = @import("std");
const abi = @import("abi.zig");
const surface = @import("../surface.zig");
const raster = @import("../raster/raster.zig");

pub const Stats = struct {
    primitives_submitted: u64 = 0,
    primitives_rasterized: u64 = 0,
    fragments_tested: u64 = 0,
    fragments_covered: u64 = 0,
    depth_tests_passed: u64 = 0,
    color_writes: u64 = 0,
};

const ProjectedVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    inverse_w: f32,
    color: [4]f32,
};

pub const DrawOptions = struct {
    viewport: abi.Viewport,
    scissor: abi.ScissorRect,
    cull_mode: abi.CullMode = .none,
    winding: abi.Winding = .clockwise,
    fill_mode: abi.TriangleFillMode = .fill,
    depth_clip_mode: abi.DepthClipMode = .clip,
    depth_bias: f32 = 0,
    slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
    sample_filter: abi.SamplerFilter = .nearest,
    sample_address_s: abi.SamplerAddressMode = .clamp_to_edge,
    sample_address_t: abi.SamplerAddressMode = .clamp_to_edge,
    sample_swizzle: abi.TextureSwizzleChannels = .{
        .red = .red,
        .green = .green,
        .blue = .blue,
        .alpha = .alpha,
    },
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
    write_extra_targets: bool = false,
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_front: StencilFace = .{},
    stencil_back: StencilFace = .{},
};

pub const StencilFace = struct {
    compare: abi.CompareFunction = .always,
    stencil_failure: abi.StencilOperation = .keep,
    depth_failure: abi.StencilOperation = .keep,
    depth_pass: abi.StencilOperation = .keep,
    read_mask: u8 = 0xff,
    write_mask: u8 = 0xff,
    reference: u8 = 0,
};

pub const TargetFormat = enum { rgba8_unorm, bgra8_unorm, r32_float, rgba16_float };

pub const Target = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    format: TargetFormat,

    fn bytesPerPixel(format: TargetFormat) usize {
        return switch (format) {
            .rgba8_unorm, .bgra8_unorm, .r32_float => 4,
            .rgba16_float => 8,
        };
    }

    pub fn init(pixels: []u8, width: u32, height: u32, stride: usize, format: TargetFormat) !Target {
        const row_bytes = try std.math.mul(usize, width, bytesPerPixel(format));
        if (stride < row_bytes) return error.InvalidStride;
        const required = if (height == 0) 0 else try std.math.add(usize, try std.math.mul(usize, height - 1, stride), row_bytes);
        if (pixels.len < required) return error.BufferTooSmall;
        return .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .format = format };
    }

    pub fn row(self: *const Target, y: u32) []u8 {
        const start = @as(usize, y) * self.stride;
        return self.pixels[start .. start + @as(usize, self.width) * bytesPerPixel(self.format)];
    }

    fn readF32(row_bytes: []const u8, offset: usize) f32 {
        return @bitCast(std.mem.readInt(u32, row_bytes[offset..][0..4], .little));
    }

    fn writeF32(row_bytes: []u8, offset: usize, value: f32) void {
        std.mem.writeInt(u32, row_bytes[offset..][0..4], @bitCast(value), .little);
    }

    fn readF16(row_bytes: []const u8, offset: usize) f32 {
        return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, row_bytes[offset..][0..2], .little))));
    }

    fn writeF16(row_bytes: []u8, offset: usize, value: f32) void {
        const half: f16 = @floatCast(value);
        std.mem.writeInt(u16, row_bytes[offset..][0..2], @bitCast(half), .little);
    }

    fn readColor(self: *const Target, x: usize, y: usize) [4]f32 {
        const row_bytes = self.row(@intCast(y));
        const offset = x * bytesPerPixel(self.format);
        return switch (self.format) {
            .rgba8_unorm, .bgra8_unorm => blk: {
                const format: surface.Format = if (self.format == .rgba8_unorm) .rgba8_unorm else .bgra8_unorm;
                const color = surface.Surface.read(row_bytes, offset, format);
                break :blk .{
                    @as(f32, @floatFromInt(color.r)) / 255.0,
                    @as(f32, @floatFromInt(color.g)) / 255.0,
                    @as(f32, @floatFromInt(color.b)) / 255.0,
                    @as(f32, @floatFromInt(color.a)) / 255.0,
                };
            },
            .r32_float => .{ readF32(row_bytes, offset), 0, 0, 1 },
            .rgba16_float => .{
                readF16(row_bytes, offset), readF16(row_bytes, offset + 2),
                readF16(row_bytes, offset + 4), readF16(row_bytes, offset + 6),
            },
        };
    }

    fn writeColor(self: *Target, x: usize, y: usize, color: [4]f32, write_mask: u8) void {
        const row_bytes = self.row(@intCast(y));
        const offset = x * bytesPerPixel(self.format);
        switch (self.format) {
            .rgba8_unorm, .bgra8_unorm => {
                const format: surface.Format = if (self.format == .rgba8_unorm) .rgba8_unorm else .bgra8_unorm;
                var output = surface.Surface.read(row_bytes, offset, format);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) output.r = colorByte(color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) output.g = colorByte(color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) output.b = colorByte(color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) output.a = colorByte(color[3]);
                surface.Surface.write(row_bytes, offset, format, output);
            },
            .r32_float => if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF32(row_bytes, offset, color[0]),
            .rgba16_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeF16(row_bytes, offset + 2, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeF16(row_bytes, offset + 4, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeF16(row_bytes, offset + 6, color[3]);
            },
        }
    }

    fn addressCoordinate(value: f32, mode: abi.SamplerAddressMode) ?f32 {
        if (!std.math.isFinite(value)) return null;
        return switch (mode) {
            .clamp_to_edge => std.math.clamp(value, 0, 1),
            .mirror_clamp_to_edge => if (value < -1) 0 else if (value > 1) 1 else @abs(value),
            .repeat => value - @floor(value),
            .mirror_repeat => blk: {
                const period = value - @floor(value / 2) * 2;
                break :blk if (period <= 1) period else 2 - period;
            },
            .clamp_to_zero, .clamp_to_border_color => if (value < 0 or value > 1) null else value,
        };
    }

    fn sampleIndex(index: i64, limit: u32, mode: abi.SamplerAddressMode) ?usize {
        if (limit == 0) return null;
        const extent: i64 = @intCast(limit);
        return switch (mode) {
            .clamp_to_edge => @intCast(std.math.clamp(index, 0, extent - 1)),
            .mirror_clamp_to_edge => @intCast(std.math.clamp(index, 0, extent - 1)),
            .repeat => blk: {
                var wrapped = @rem(index, extent);
                if (wrapped < 0) wrapped += extent;
                break :blk @intCast(wrapped);
            },
            .mirror_repeat => blk: {
                const period = extent * 2;
                var wrapped = @rem(index, period);
                if (wrapped < 0) wrapped += period;
                break :blk @intCast(if (wrapped < extent) wrapped else period - wrapped - 1);
            },
            .clamp_to_zero, .clamp_to_border_color => if (index < 0 or index >= extent) null else @intCast(index),
        };
    }

    fn sampleTexel(self: *const Target, x: i64, y: i64, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode) [4]f32 {
        const sample_x = sampleIndex(x, self.width, address_s) orelse return .{ 0, 0, 0, 0 };
        const sample_y = sampleIndex(y, self.height, address_t) orelse return .{ 0, 0, 0, 0 };
        return self.readColor(sample_x, sample_y);
    }

    fn sampleNearest(self: *const Target, u: f32, v: f32, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode) [4]f32 {
        const normalized_u = addressCoordinate(u, address_s) orelse return .{ 0, 0, 0, 0 };
        const normalized_v = addressCoordinate(v, address_t) orelse return .{ 0, 0, 0, 0 };
        const x: i64 = @intFromFloat(@min(normalized_u, 0.99999994) * @as(f32, @floatFromInt(self.width)));
        const y: i64 = @intFromFloat(@min(normalized_v, 0.99999994) * @as(f32, @floatFromInt(self.height)));
        return self.sampleTexel(x, y, address_s, address_t);
    }

    fn sampleLinear(self: *const Target, u: f32, v: f32, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode) [4]f32 {
        const normalized_u = addressCoordinate(u, address_s) orelse return .{ 0, 0, 0, 0 };
        const normalized_v = addressCoordinate(v, address_t) orelse return .{ 0, 0, 0, 0 };
        const x = normalized_u * @as(f32, @floatFromInt(self.width)) - 0.5;
        const y = normalized_v * @as(f32, @floatFromInt(self.height)) - 0.5;
        const x0_float = @floor(x);
        const y0_float = @floor(y);
        const x0: i64 = @intFromFloat(x0_float);
        const y0: i64 = @intFromFloat(y0_float);
        const x_weight = x - x0_float;
        const y_weight = y - y0_float;
        const top_left = self.sampleTexel(x0, y0, address_s, address_t);
        const top_right = self.sampleTexel(x0 + 1, y0, address_s, address_t);
        const bottom_left = self.sampleTexel(x0, y0 + 1, address_s, address_t);
        const bottom_right = self.sampleTexel(x0 + 1, y0 + 1, address_s, address_t);
        var result: [4]f32 = undefined;
        for (0..4) |channel| {
            const top = top_left[channel] + (top_right[channel] - top_left[channel]) * x_weight;
            const bottom = bottom_left[channel] + (bottom_right[channel] - bottom_left[channel]) * x_weight;
            result[channel] = top + (bottom - top) * y_weight;
        }
        return result;
    }

    fn swizzleValue(color: [4]f32, channel: abi.TextureSwizzle) f32 {
        return switch (channel) {
            .zero => 0,
            .one => 1,
            .red => color[0],
            .green => color[1],
            .blue => color[2],
            .alpha => color[3],
        };
    }

    fn applySwizzle(color: [4]f32, swizzle: abi.TextureSwizzleChannels) [4]f32 {
        return .{
            swizzleValue(color, swizzle.red),
            swizzleValue(color, swizzle.green),
            swizzleValue(color, swizzle.blue),
            swizzleValue(color, swizzle.alpha),
        };
    }

    fn sample(self: *const Target, u: f32, v: f32, filter: abi.SamplerFilter, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode, swizzle: abi.TextureSwizzleChannels) [4]f32 {
        const color = switch (filter) {
            .nearest => self.sampleNearest(u, v, address_s, address_t),
            .linear => self.sampleLinear(u, v, address_s, address_t),
        };
        return applySwizzle(color, swizzle);
    }
};

const Job = struct {
    target: *Target,
    extra_targets: []const *Target,
    sample_texture: ?*const Target,
    depth: ?[]f32,
    stencil: ?[]u8,
    vertices: []const abi.Vertex,
    primitive: abi.PrimitiveType,
    options: DrawOptions,
    bands: [2]Stats = .{ .{}, .{} },
};

fn project(vertex: abi.Vertex, viewport: abi.Viewport) ?ProjectedVertex {
    const p = vertex.position;
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or !std.math.isFinite(p[2]) or !std.math.isFinite(p[3]) or @abs(p[3]) < 0.000001) return null;
    const inverse_w = 1.0 / p[3];
    const nx = p[0] * inverse_w;
    const ny = p[1] * inverse_w;
    const nz = p[2] * inverse_w;
    if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) return null;
    return .{
        .x = viewport.origin_x + (nx * 0.5 + 0.5) * viewport.width,
        // Metal's render-target row zero is the top row: clip-space +Y maps
        // toward the viewport origin, while the CPU surface is addressed
        // with increasing Y down the image.
        .y = viewport.origin_y + (0.5 - ny * 0.5) * viewport.height,
        .z = viewport.znear + nz * (viewport.zfar - viewport.znear),
        .inverse_w = inverse_w,
        .color = .{ vertex.color.red, vertex.color.green, vertex.color.blue, vertex.color.alpha },
    };
}

fn interpolateLineColor(a: ProjectedVertex, b: ProjectedVertex, t: f32) [4]f32 {
    const weight_a = 1 - t;
    const weight_b = t;
    const denominator = a.inverse_w * weight_a + b.inverse_w * weight_b;
    if (!std.math.isFinite(denominator) or @abs(denominator) < 0.000001) return .{ 0, 0, 0, 1 };
    var color: [4]f32 = undefined;
    for (0..4) |channel| {
        color[channel] = (a.color[channel] * a.inverse_w * weight_a + b.color[channel] * b.inverse_w * weight_b) / denominator;
    }
    return color;
}

fn interpolateTriangleColor(vertices: [3]ProjectedVertex, w0: f32, w1: f32, w2: f32) [4]f32 {
    const denominator = vertices[0].inverse_w * w0 + vertices[1].inverse_w * w1 + vertices[2].inverse_w * w2;
    if (!std.math.isFinite(denominator) or @abs(denominator) < 0.000001) return .{ 0, 0, 0, 1 };
    var color: [4]f32 = undefined;
    for (0..4) |channel| {
        color[channel] = (vertices[0].color[channel] * vertices[0].inverse_w * w0 +
            vertices[1].color[channel] * vertices[1].inverse_w * w1 +
            vertices[2].color[channel] * vertices[2].inverse_w * w2) / denominator;
    }
    return color;
}

fn edge(a: ProjectedVertex, b: ProjectedVertex, x: f32, y: f32) f32 {
    return (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
}

fn topLeftEdge(a: ProjectedVertex, b: ProjectedVertex) bool {
    const dy = b.y - a.y;
    const dx = b.x - a.x;
    return dy < 0 or (dy == 0 and dx > 0);
}

fn outsideTopLeft(value: f32, a: ProjectedVertex, b: ProjectedVertex) bool {
    return value < 0 or (@abs(value) < 0.000001 and !topLeftEdge(a, b));
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255.0 + 0.5);
}

fn compareStencil(compare: abi.CompareFunction, reference: u8, current: u8, mask: u8) bool {
    const lhs = reference & mask;
    const rhs = current & mask;
    return switch (compare) {
        .never => false,
        .less => lhs < rhs,
        .equal => lhs == rhs,
        .less_equal => lhs <= rhs,
        .greater => lhs > rhs,
        .not_equal => lhs != rhs,
        .greater_equal => lhs >= rhs,
        .always => true,
    };
}

fn stencilOperation(operation: abi.StencilOperation, current: u8, reference: u8) u8 {
    return switch (operation) {
        .keep => current,
        .zero => 0,
        .replace => reference,
        .increment_clamp => if (current == 0xff) 0xff else current + 1,
        .decrement_clamp => if (current == 0) 0 else current - 1,
        .invert => ~current,
        .increment_wrap => current +% 1,
        .decrement_wrap => current -% 1,
    };
}

fn applyStencil(stencil: []u8, index: usize, state: StencilFace, operation: abi.StencilOperation) void {
    const current = stencil[index];
    const result = stencilOperation(operation, current, state.reference);
    stencil[index] = (current & ~state.write_mask) | (result & state.write_mask);
}

fn writeColor(target: *Target, x: usize, y: usize, color: [4]f32, options: DrawOptions) void {
    if (x >= target.width or y >= target.height) return;
    const destination_color = target.readColor(x, y);
    const output_color = if (options.blending_enabled) .{
        blendChannel(0, color[0], destination_color[0], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(1, color[1], destination_color[1], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(2, color[2], destination_color[2], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(3, color[3], destination_color[3], color, destination_color, options.blend_color, options.source_alpha_factor, options.destination_alpha_factor, options.alpha_operation),
    } else color;
    target.writeColor(x, y, output_color, options.color_write_mask);
}

fn adjustedDepth(job: *const Job, z: f32, bias: f32) ?f32 {
    var result = z + bias;
    if (job.options.depth_clip_mode == .clamp) {
        result = std.math.clamp(result, 0, 1);
    } else if (result < 0 or result > 1) {
        return null;
    }
    return result;
}

fn depthBias(job: *const Job, slope: f32) f32 {
    var result = job.options.depth_bias + job.options.slope_scale * slope;
    if (job.options.depth_bias_clamp != 0) {
        const limit = @abs(job.options.depth_bias_clamp);
        result = std.math.clamp(result, -limit, limit);
    }
    return result;
}

fn writePixel(job: *Job, x: usize, y: usize, z: f32, depth_adjust: f32, color: [4]f32, stats: *Stats, front_facing: bool) void {
    const width: usize = @intCast(job.target.width);
    if (x >= width or y >= job.target.height) return;
    const adjusted_depth = adjustedDepth(job, z, depth_adjust) orelse return;
    stats.fragments_tested += 1;
    const stencil_state = if (front_facing) job.options.stencil_front else job.options.stencil_back;
    var stencil_index: ?usize = null;
    if (job.stencil) |stencil| {
        const index = y * width + x;
        if (index >= stencil.len) return;
        stencil_index = index;
        if (!compareStencil(stencil_state.compare, stencil_state.reference, stencil[index], stencil_state.read_mask)) {
            applyStencil(stencil, index, stencil_state, stencil_state.stencil_failure);
            return;
        }
    }
    if (job.depth) |depth_buffer| {
        const index = y * width + x;
        if (index >= depth_buffer.len) return;
        const current = depth_buffer[index];
        const passes = switch (job.options.depth_compare) {
            .never => false,
            .less => adjusted_depth < current,
            .equal => adjusted_depth == current,
            .less_equal => adjusted_depth <= current,
            .greater => adjusted_depth > current,
            .not_equal => adjusted_depth != current,
            .greater_equal => adjusted_depth >= current,
            .always => true,
        };
        if (!passes) {
            if (stencil_index) |stencil_pixel_index| applyStencil(job.stencil.?, stencil_pixel_index, stencil_state, stencil_state.depth_failure);
            return;
        }
        if (job.options.depth_write_enabled) depth_buffer[index] = adjusted_depth;
        stats.depth_tests_passed += 1;
    }
    if (stencil_index) |index| applyStencil(job.stencil.?, index, stencil_state, stencil_state.depth_pass);
    const fragment_color = if (job.sample_texture) |texture| texture.sample(color[0], color[1], job.options.sample_filter, job.options.sample_address_s, job.options.sample_address_t, job.options.sample_swizzle) else color;
    writeColor(job.target, x, y, fragment_color, job.options);
    if (job.options.write_extra_targets) for (job.extra_targets) |target| writeColor(target, x, y, fragment_color, job.options);
    stats.fragments_covered += 1;
    stats.color_writes += 1 + if (job.options.write_extra_targets) @as(u64, @intCast(job.extra_targets.len)) else 0;
}

fn blendChannel(channel: usize, source: f32, destination: f32, source_color: [4]f32, destination_color: [4]f32, blend_color: [4]f32, source_factor: abi.BlendFactor, destination_factor: abi.BlendFactor, operation: abi.BlendOperation) f32 {
    const source_factor_value = blendFactor(channel, source_factor, source_color, destination_color, blend_color);
    const destination_factor_value = blendFactor(channel, destination_factor, source_color, destination_color, blend_color);
    return switch (operation) {
        .add => source * source_factor_value + destination * destination_factor_value,
        .subtract => source * source_factor_value - destination * destination_factor_value,
        .reverse_subtract => destination * destination_factor_value - source * source_factor_value,
        .min => @min(source, destination),
        .max => @max(source, destination),
    };
}

fn blendFactor(channel: usize, factor: abi.BlendFactor, source: [4]f32, destination: [4]f32, blend_color: [4]f32) f32 {
    return switch (factor) {
        .zero => 0,
        .one => 1,
        .source_color => source[channel],
        .one_minus_source_color => 1 - source[channel],
        .source_alpha => source[3],
        .one_minus_source_alpha => 1 - source[3],
        .destination_color => destination[channel],
        .one_minus_destination_color => 1 - destination[channel],
        .destination_alpha => destination[3],
        .one_minus_destination_alpha => 1 - destination[3],
        .source_alpha_saturated => @min(source[3], 1 - destination[3]),
        .blend_color => blend_color[channel],
        .one_minus_blend_color => 1 - blend_color[channel],
        .blend_alpha => blend_color[3],
        .one_minus_blend_alpha => 1 - blend_color[3],
    };
}

fn scissorBounds(options: DrawOptions, width: u32, height: u32) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
    const x0 = @min(@as(usize, options.scissor.x), @as(usize, width));
    const y0 = @min(@as(usize, options.scissor.y), @as(usize, height));
    const x1 = @min(x0 +| @as(usize, options.scissor.width), @as(usize, width));
    const y1 = @min(y0 +| @as(usize, options.scissor.height), @as(usize, height));
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn pixelCoordinate(value: f32, limit: usize) ?usize {
    if (!std.math.isFinite(value) or value < 0 or value >= @as(f32, @floatFromInt(limit))) return null;
    return @intFromFloat(value);
}

fn drawPoint(job: *Job, vertex: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x = pixelCoordinate(vertex.x, bounds.x1) orelse return;
    const y = pixelCoordinate(vertex.y, bounds.y1) orelse return;
    if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) return;
    writePixel(job, x, y, vertex.z, depthBias(job, 0), vertex.color, stats, true);
}

fn drawLine(job: *Job, a: ProjectedVertex, b: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const steps_float = @ceil(@max(@abs(b.x - a.x), @abs(b.y - a.y)));
    if (!std.math.isFinite(steps_float) or steps_float > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return;
    const steps: usize = @intFromFloat(steps_float);
    if (steps == 0) {
        drawPoint(job, a, y0, y1, stats);
        return;
    }
    const slope = @abs(b.z - a.z) / @as(f32, @floatFromInt(steps));
    const depth_adjust = depthBias(job, slope);
    for (0..steps + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const x_value = a.x + (b.x - a.x) * t;
        const y_value = a.y + (b.y - a.y) * t;
        const x = pixelCoordinate(x_value, bounds.x1) orelse continue;
        const y = pixelCoordinate(y_value, bounds.y1) orelse continue;
        if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) continue;
        writePixel(job, x, y, a.z + (b.z - a.z) * t, depth_adjust, interpolateLineColor(a, b, t), stats, true);
    }
}

fn drawTriangle(job: *Job, input: [3]ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    var vertices = input;
    const area = edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
    if (!std.math.isFinite(area) or @abs(area) < 0.000001) return;
    const front_facing = if (job.options.winding == .clockwise) area > 0 else area < 0;
    if ((job.options.cull_mode == .front and front_facing) or (job.options.cull_mode == .back and !front_facing)) return;
    if (job.options.fill_mode == .lines) {
        drawLine(job, vertices[0], vertices[1], y0, y1, stats);
        drawLine(job, vertices[1], vertices[2], y0, y1, stats);
        drawLine(job, vertices[2], vertices[0], y0, y1, stats);
        stats.primitives_rasterized += 1;
        return;
    }

    const min_x = @max(@as(f32, 0), @floor(@min(vertices[0].x, @min(vertices[1].x, vertices[2].x))));
    const max_x = @min(@as(f32, @floatFromInt(job.target.width)), @ceil(@max(vertices[0].x, @max(vertices[1].x, vertices[2].x))));
    const min_y = @max(@as(f32, @floatFromInt(@max(y0, @min(@as(usize, job.options.scissor.y), @as(usize, job.target.height))))), @floor(@min(vertices[0].y, @min(vertices[1].y, vertices[2].y))));
    const max_y = @min(@as(f32, @floatFromInt(@min(y1, @as(usize, job.target.height)))), @ceil(@max(vertices[0].y, @max(vertices[1].y, vertices[2].y))));
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x_start: usize = @intFromFloat(@min(max_x, @max(@as(f32, @floatFromInt(bounds.x0)), min_x)));
    const x_end: usize = @intFromFloat(@min(max_x, @as(f32, @floatFromInt(bounds.x1))));
    const row_start: usize = @intFromFloat(@min(max_y, @max(@as(f32, @floatFromInt(bounds.y0)), min_y)));
    const row_end: usize = @intFromFloat(@min(max_y, @as(f32, @floatFromInt(@min(bounds.y1, y1)))));
    if (x_end <= x_start or row_end <= row_start) return;
    if (area < 0) {
        const second = vertices[1];
        vertices[1] = vertices[2];
        vertices[2] = second;
    }
    const depth_dx = ((vertices[1].z - vertices[0].z) * (vertices[2].y - vertices[0].y) -
        (vertices[2].z - vertices[0].z) * (vertices[1].y - vertices[0].y)) / area;
    const depth_dy = ((vertices[1].x - vertices[0].x) * (vertices[2].z - vertices[0].z) -
        (vertices[2].x - vertices[0].x) * (vertices[1].z - vertices[0].z)) / area;
    const depth_adjust = depthBias(job, @max(@abs(depth_dx), @abs(depth_dy)));
    const inverse_area = 1.0 / @abs(area);
    for (row_start..row_end) |y| {
        for (x_start..x_end) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const w0 = edge(vertices[1], vertices[2], px, py) * inverse_area;
            const w1 = edge(vertices[2], vertices[0], px, py) * inverse_area;
            const w2 = edge(vertices[0], vertices[1], px, py) * inverse_area;
            if (outsideTopLeft(w0, vertices[1], vertices[2]) or
                outsideTopLeft(w1, vertices[2], vertices[0]) or
                outsideTopLeft(w2, vertices[0], vertices[1])) continue;
            writePixel(job, x, y, vertices[0].z * w0 + vertices[1].z * w1 + vertices[2].z * w2, depth_adjust,
                interpolateTriangleColor(vertices, w0, w1, w2), stats, front_facing);
        }
    }
    stats.primitives_rasterized += 1;
}

fn drawBand(job: *Job, band: usize) Stats {
    var stats = Stats{ .primitives_submitted = if (band == 0) switch (job.primitive) {
        .point => @intCast(job.vertices.len),
        .line => @intCast(job.vertices.len / 2),
        .line_strip => if (job.vertices.len > 1) @intCast(job.vertices.len - 1) else 0,
        .triangle => @intCast(job.vertices.len / 3),
        .triangle_strip => if (job.vertices.len > 2) @intCast(job.vertices.len - 2) else 0,
    } else 0 };
    const height: usize = @intCast(job.target.height);
    const y0 = height * band / 2;
    const y1 = height * (band + 1) / 2;
    switch (job.primitive) {
        .point => for (job.vertices) |vertex| if (project(vertex, job.options.viewport)) |p| drawPoint(job, p, y0, y1, &stats),
        .line => {
            var index: usize = 0;
            while (index + 1 < job.vertices.len) : (index += 2) {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            }
        },
        .line_strip => {
            if (job.vertices.len > 1) for (0..job.vertices.len - 1) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            };
        },
        .triangle => {
            var index: usize = 0;
            while (index + 2 < job.vertices.len) : (index += 3) {
                const triangle = [3]ProjectedVertex{
                    project(job.vertices[index], job.options.viewport) orelse continue,
                    project(job.vertices[index + 1], job.options.viewport) orelse continue,
                    project(job.vertices[index + 2], job.options.viewport) orelse continue,
                };
                drawTriangle(job, triangle, y0, y1, &stats);
            }
        },
        .triangle_strip => {
            if (job.vertices.len > 2) for (0..job.vertices.len - 2) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const odd = index % 2 != 0;
                const b_index: usize = index + (if (odd) @as(usize, 2) else @as(usize, 1));
                const c_index: usize = index + (if (odd) @as(usize, 1) else @as(usize, 2));
                const b = project(job.vertices[b_index], job.options.viewport) orelse continue;
                const c = project(job.vertices[c_index], job.options.viewport) orelse continue;
                drawTriangle(job, .{ a, b, c }, y0, y1, &stats);
            };
        },
    }
    return stats;
}

fn renderWorker(job: *Job) void {
    job.bands[0] = drawBand(job, 0);
}

fn addStats(a: Stats, b: Stats) Stats {
    return .{
        .primitives_submitted = a.primitives_submitted + b.primitives_submitted,
        .primitives_rasterized = a.primitives_rasterized + b.primitives_rasterized,
        .fragments_tested = a.fragments_tested + b.fragments_tested,
        .fragments_covered = a.fragments_covered + b.fragments_covered,
        .depth_tests_passed = a.depth_tests_passed + b.depth_tests_passed,
        .color_writes = a.color_writes + b.color_writes,
    };
}

pub fn drawWithTargets(target: *Target, extra_targets: []const *Target, sample_texture: ?*const Target, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    var job = Job{ .target = target, .extra_targets = extra_targets, .sample_texture = sample_texture, .depth = depth, .stencil = stencil, .vertices = vertices, .primitive = primitive, .options = options };
    const worker = std.Thread.spawn(.{}, renderWorker, .{&job}) catch {
        job.bands[0] = drawBand(&job, 0);
        job.bands[1] = drawBand(&job, 1);
        return addStats(job.bands[0], job.bands[1]);
    };
    job.bands[1] = drawBand(&job, 1);
    worker.join();
    return addStats(job.bands[0], job.bands[1]);
}

pub fn draw(target: *Target, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    return drawWithTargets(target, &[_]*Target{}, null, depth, stencil, vertices, primitive, options);
}

pub fn drawSurface(target: *surface.Surface, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    var render_target = Target{
        .pixels = target.pixels,
        .width = target.width,
        .height = target.height,
        .stride = target.stride,
        .format = if (target.format == .rgba8_unorm) .rgba8_unorm else .bgra8_unorm,
    };
    return draw(&render_target, depth, stencil, vertices, primitive, options);
}

fn clearSurfaceBand(target: *surface.Surface, color: surface.Color, y0: usize, y1: usize) void {
    if (y1 <= y0) return;
    raster.fillRect(target, .{ .x = 0, .y = @intCast(y0), .width = target.width, .height = @intCast(y1 - y0) }, color);
}

pub fn clearTarget(target: *Target, color: [4]f32) void {
    for (0..target.height) |y| {
        for (0..target.width) |x| target.writeColor(x, y, color, @intFromEnum(abi.ColorWriteMask.all));
    }
}

pub fn clearSurface(target: *surface.Surface, color: surface.Color) void {
    const middle = @as(usize, target.height) / 2;
    const worker = std.Thread.spawn(.{}, clearSurfaceBand, .{ target, color, 0, middle }) catch {
        clearSurfaceBand(target, color, 0, @intCast(target.height));
        return;
    };
    clearSurfaceBand(target, color, middle, target.height);
    worker.join();
}

fn clearDepthBand(depth: []f32, value: f32, y0: usize, y1: usize, width: usize) void {
    for (y0..y1) |y| @memset(depth[y * width ..][0..width], value);
}

pub fn clearDepth(depth: []f32, width: u32, value: f32) void {
    if (width == 0) return;
    const rows = depth.len / @as(usize, width);
    const middle = rows / 2;
    const worker = std.Thread.spawn(.{}, clearDepthBand, .{ depth, value, 0, middle, @as(usize, width) }) catch {
        clearDepthBand(depth, value, 0, rows, @intCast(width));
        return;
    };
    clearDepthBand(depth, value, middle, rows, width);
    worker.join();
}

test "Metal viewport and scissor origins use the top-left pixel grid" {
    var pixels = [_]u8{0} ** (8 * 8 * 4);
    var target = try Target.init(&pixels, 8, 8, 8 * 4, .rgba8_unorm);
    const options = DrawOptions{
        .viewport = .{ .origin_x = 1, .origin_y = 2, .width = 6, .height = 4, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 1, .y = 2, .width = 6, .height = 4 },
    };
    const red = abi.Color{ .red = 1, .green = 0, .blue = 0, .alpha = 1 };
    const blue = abi.Color{ .red = 0, .green = 0, .blue = 1, .alpha = 1 };
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.90, 0.5, 1 }, .color = blue },
        .{ .position = .{ -0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.90, 0.5, 1 }, .color = blue },
        .{ .position = .{ -0.75, -0.90, 0.5, 1 }, .color = blue },
    };
    _ = draw(&target, null, null, &vertices, .triangle, options);

    const red_pixel = surface.Surface.read(target.row(2), 3 * 4, .rgba8_unorm);
    const red_pixel_lower = surface.Surface.read(target.row(3), 3 * 4, .rgba8_unorm);
    const blue_pixel = surface.Surface.read(target.row(4), 3 * 4, .rgba8_unorm);
    const blue_pixel_lower = surface.Surface.read(target.row(5), 3 * 4, .rgba8_unorm);
    try std.testing.expectEqual(surface.Color.rgba(255, 0, 0, 255), red_pixel);
    try std.testing.expectEqual(surface.Color.rgba(255, 0, 0, 255), red_pixel_lower);
    try std.testing.expectEqual(surface.Color.rgba(0, 0, 255, 255), blue_pixel);
    try std.testing.expectEqual(surface.Color.rgba(0, 0, 255, 255), blue_pixel_lower);
    try std.testing.expectEqual(@as(u8, 0), pixels[1 * 8 * 4 + 3 * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[6 * 8 * 4 + 3 * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[3 * 8 * 4 + 0 * 4]);
}

test "Metal depth bias and clip modes are CPU deterministic" {
    var pixels = [_]u8{0} ** (4 * 4 * 4);
    var target = try Target.init(&pixels, 4, 4, 4 * 4, .rgba8_unorm);
    var depth = [_]f32{1} ** (4 * 4);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 4, .height = 4, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .depth_bias = 0.25,
    };
    _ = draw(&target, depth[0..], null, &vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 0.5), depth[15]);

    pixels = [_]u8{0} ** (4 * 4 * 4);
    depth = [_]f32{1} ** (4 * 4);
    options.depth_bias = 0;
    options.depth_clip_mode = .clip;
    var clipped_vertices = vertices;
    for (&clipped_vertices) |*vertex| vertex.position[2] = 1.25;
    _ = draw(&target, depth[0..], null, &clipped_vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 1), depth[15]);
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);

    options.depth_clip_mode = .clamp;
    _ = draw(&target, depth[0..], null, &clipped_vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 1), depth[15]);
    try std.testing.expectEqual(@as(u8, 255), pixels[15 * 4]);
}

test "float color targets retain native texel precision" {
    var r32_bytes = [_]u8{0} ** (2 * 2 * 4);
    var r32 = try Target.init(&r32_bytes, 2, 2, 2 * 4, .r32_float);
    clearTarget(&r32, .{ 0.25, 0.5, 0.75, 1 });
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.25))), std.mem.readInt(u32, r32_bytes[0..4], .little));
    try std.testing.expectEqual(@as(f32, 0.25), r32.readColor(0, 0)[0]);

    var rgba16_bytes = [_]u8{0} ** (2 * 2 * 8);
    var rgba16 = try Target.init(&rgba16_bytes, 2, 2, 2 * 8, .rgba16_float);
    clearTarget(&rgba16, .{ 0.25, 0.5, 0.75, 1 });
    const color = rgba16.readColor(0, 0);
    try std.testing.expectEqual(@as(f32, 0.25), color[0]);
    try std.testing.expectEqual(@as(f32, 0.5), color[1]);
    try std.testing.expectEqual(@as(f32, 0.75), color[2]);
    try std.testing.expectEqual(@as(f32, 1), color[3]);
}

test "CPU texture sampling uses normalized top-left texel coordinates" {
    var pixels = [_]u8{
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    };
    const target = try Target.init(&pixels, 2, 2, 2 * 4, .rgba8_unorm);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.25, 0.25, .clamp_to_edge, .clamp_to_edge)[0]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.75, 0.25, .clamp_to_edge, .clamp_to_edge)[1]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.25, 0.75, .clamp_to_edge, .clamp_to_edge)[2]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.75, 0.75, .clamp_to_edge, .clamp_to_edge)[0]);
}

test "CPU texture sampling supports linear filtering and address modes" {
    var pixels = [_]u8{
        255, 0, 0, 255,   0, 255, 0, 255,
        0, 0, 255, 255,   255, 255, 255, 255,
    };
    const target = try Target.init(&pixels, 2, 2, 2 * 4, .rgba8_unorm);
    const center = target.sampleLinear(0.5, 0.5, .clamp_to_edge, .clamp_to_edge);
    for (center[0..3]) |channel| try std.testing.expectApproxEqAbs(@as(f32, 0.5), channel, 0.001);
    try std.testing.expectEqual(@as(f32, 1), center[3]);

    const repeated = target.sampleNearest(1.25, 0.25, .repeat, .repeat);
    try std.testing.expectEqual(@as(f32, 1), repeated[0]);
    try std.testing.expectEqual(@as(f32, 0), repeated[1]);
    const mirrored = target.sampleNearest(1.25, 0.25, .mirror_repeat, .mirror_repeat);
    try std.testing.expectEqual(@as(f32, 1), mirrored[1]);
    const mirror_clamped = target.sampleNearest(-0.25, 0.25, .mirror_clamp_to_edge, .mirror_clamp_to_edge);
    try std.testing.expectEqual(@as(f32, 1), mirror_clamped[0]);
    const outside = target.sampleNearest(-0.25, 0.25, .clamp_to_zero, .clamp_to_zero);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, outside);
}

test "CPU texture sampling applies texture-view channel swizzles" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const target = try Target.init(&pixels, 1, 1, 4, .rgba8_unorm);
    const swizzled = target.sample(0.5, 0.5, .nearest, .clamp_to_edge, .clamp_to_edge, .{
        .red = .blue,
        .green = .red,
        .blue = .one,
        .alpha = .zero,
    });
    try std.testing.expectEqual([4]f32{ 0, 1, 1, 0 }, swizzled);
}

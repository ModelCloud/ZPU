// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! C-callable entry points for the bounded, opt-in ZPU Metal-shaped layer.
//!
//! This file deliberately exposes a small native ABI instead of pretending
//! that a Zig library can implement Apple's Objective-C `MTL*` protocols or
//! register a replacement system Metal device.  It is useful to C, C++, and
//! Objective-C clients that explicitly select ZPU's deterministic CPU path.

const std = @import("std");
const abi = @import("abi.zig");
const cpu = @import("cpu.zig");
const raster3d = @import("raster3d.zig");
const surface = @import("../surface.zig");

pub const CSurface = extern struct {
    pixels: ?[*]u8,
    byte_length: usize,
    width: u32,
    height: u32,
    stride: usize,
    format: u16,
};

pub const CDrawState = extern struct {
    viewport: abi.Viewport,
    scissor: abi.ScissorRect,
    cull_mode: abi.CullMode,
    winding: abi.Winding,
    fill_mode: abi.TriangleFillMode,
};

pub const CStats = extern struct {
    primitives_submitted: u64,
    primitives_rasterized: u64,
    fragments_tested: u64,
    fragments_covered: u64,
    depth_tests_passed: u64,
    color_writes: u64,
};

const ErrorCode = enum(c_int) {
    ok = 0,
    invalid_argument = -1,
    unsupported_format = -2,
    invalid_depth = -3,
    invalid_command = -4,
};

fn validPassDescriptor(pass: *const abi.RenderPassDescriptor) bool {
    const color_load = @intFromEnum(pass.color.load_action);
    const depth_load = @intFromEnum(pass.depth.load_action);
    const color_store = @intFromEnum(pass.color.store_action);
    const depth_store = @intFromEnum(pass.depth.store_action);
    return color_load <= @intFromEnum(abi.LoadAction.clear) and
        depth_load <= @intFromEnum(abi.LoadAction.clear) and
        color_store <= @intFromEnum(abi.StoreAction.store) and
        depth_store <= @intFromEnum(abi.StoreAction.store);
}

fn validDrawState(state: *const CDrawState) bool {
    return @intFromEnum(state.cull_mode) <= @intFromEnum(abi.CullMode.back) and
        @intFromEnum(state.winding) <= @intFromEnum(abi.Winding.counter_clockwise) and
        @intFromEnum(state.fill_mode) <= @intFromEnum(abi.TriangleFillMode.lines);
}

fn writeStats(out: ?*CStats, stats: raster3d.Stats) void {
    if (out) |result| result.* = .{
        .primitives_submitted = stats.primitives_submitted,
        .primitives_rasterized = stats.primitives_rasterized,
        .fragments_tested = stats.fragments_tested,
        .fragments_covered = stats.fragments_covered,
        .depth_tests_passed = stats.depth_tests_passed,
        .color_writes = stats.color_writes,
    };
}

fn checkedSurface(input: *const CSurface) ?surface.Surface {
    const pixels = input.pixels orelse return null;
    const format: surface.Format = switch (input.format) {
        @intFromEnum(abi.PixelFormat.rgba8_unorm) => .rgba8_unorm,
        @intFromEnum(abi.PixelFormat.bgra8_unorm) => .bgra8_unorm,
        else => return null,
    };
    return surface.Surface.init(pixels[0..input.byte_length], input.width, input.height, input.stride, format) catch null;
}

/// Execute a single borrowed-resource render pass through the native ZPU
/// layer. This entry point is intentionally shader-independent: callers
/// provide the already-expanded clip-space vertex/color stream.
pub fn zpu_metal_render(
    target: ?*CSurface,
    pass: ?*const abi.RenderPassDescriptor,
    state: ?*const CDrawState,
    vertices: ?[*]const abi.Vertex,
    vertex_count: usize,
    primitive_raw: u8,
    depth_ptr: ?[*]f32,
    depth_count: usize,
    stats_out: ?*CStats,
) callconv(.c) c_int {
    const target_desc = target orelse return @intFromEnum(ErrorCode.invalid_argument);
    const pass_desc = pass orelse return @intFromEnum(ErrorCode.invalid_argument);
    const draw_state = state orelse return @intFromEnum(ErrorCode.invalid_argument);
    if (!validPassDescriptor(pass_desc) or !validDrawState(draw_state)) return @intFromEnum(ErrorCode.invalid_argument);
    var target_surface = checkedSurface(target_desc) orelse {
        const known_format = target_desc.format == @intFromEnum(abi.PixelFormat.rgba8_unorm) or target_desc.format == @intFromEnum(abi.PixelFormat.bgra8_unorm);
        return @intFromEnum(if (known_format) ErrorCode.invalid_argument else ErrorCode.unsupported_format);
    };
    const primitive: abi.PrimitiveType = switch (primitive_raw) {
        @intFromEnum(abi.PrimitiveType.point) => .point,
        @intFromEnum(abi.PrimitiveType.line) => .line,
        @intFromEnum(abi.PrimitiveType.line_strip) => .line_strip,
        @intFromEnum(abi.PrimitiveType.triangle) => .triangle,
        @intFromEnum(abi.PrimitiveType.triangle_strip) => .triangle_strip,
        else => return @intFromEnum(ErrorCode.invalid_argument),
    };
    if (vertex_count != 0 and vertices == null) return @intFromEnum(ErrorCode.invalid_argument);
    if (vertex_count > 0 and @sizeOf(abi.Vertex) > std.math.maxInt(usize) / vertex_count) return @intFromEnum(ErrorCode.invalid_argument);

    const pixel_count = std.math.mul(usize, target_desc.width, target_desc.height) catch return @intFromEnum(ErrorCode.invalid_argument);
    if (depth_count != 0 and depth_ptr == null) return @intFromEnum(ErrorCode.invalid_depth);
    if (depth_count != 0 and depth_count < pixel_count) return @intFromEnum(ErrorCode.invalid_depth);
    if (pass_desc.depth.load_action != .dont_care and depth_ptr == null) return @intFromEnum(ErrorCode.invalid_depth);
    const depth: ?[]f32 = if (depth_ptr) |ptr| ptr[0..depth_count] else null;
    const vertex_slice: []const abi.Vertex = if (vertices) |ptr| ptr[0..vertex_count] else &.{};

    var buffer = cpu.Device.systemDefault().newCommandBuffer();
    var encoder = buffer.renderCommandEncoder(&target_surface, pass_desc.*);
    if (depth) |values| encoder.setDepthBuffer(values) catch return @intFromEnum(ErrorCode.invalid_depth);
    encoder.setViewport(draw_state.viewport) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.setScissorRect(draw_state.scissor) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.setCullMode(draw_state.cull_mode) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.setFrontFacing(draw_state.winding) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.setTriangleFillMode(draw_state.fill_mode) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.drawPrimitives(primitive, vertex_slice) catch return @intFromEnum(ErrorCode.invalid_command);
    encoder.endEncoding();
    buffer.commit() catch return @intFromEnum(ErrorCode.invalid_command);
    writeStats(stats_out, buffer.completedStats());
    return @intFromEnum(ErrorCode.ok);
}

test "C Metal entry point rejects malformed borrowed resources" {
    var pixels = [_]u8{0} ** 4;
    var target = CSurface{
        .pixels = &pixels,
        .byte_length = pixels.len,
        .width = 1,
        .height = 1,
        .stride = 4,
        .format = 999,
    };
    const pass = abi.RenderPassDescriptor{ .color = .{} };
    const state = CDrawState{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 1, .height = 1, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .cull_mode = .none,
        .winding = .clockwise,
        .fill_mode = .fill,
    };
    try std.testing.expectEqual(@as(c_int, -2), zpu_metal_render(&target, &pass, &state, null, 0, @intFromEnum(abi.PrimitiveType.point), null, 0, null));
}

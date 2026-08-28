// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const s = @import("../surface.zig");
const dispatch = @import("../simd/dispatch.zig");
const pipeline = @import("../render_pipeline.zig");
const scalar = @import("scalar.zig");

threadlocal var kernel_cache = pipeline.Cache{};
threadlocal var selected_backend: ?dispatch.Backend = null;

fn cachedKernel(format: s.Format, operation: pipeline.Operation) pipeline.Kernel {
    const backend = selected_backend orelse blk: {
        const selected = dispatch.best();
        selected_backend = selected;
        break :blk selected;
    };
    return kernel_cache.get(pipeline.Key.init(format, operation, backend)) catch unreachable;
}

pub fn resetKernelCache() void {
    kernel_cache.reset();
    selected_backend = null;
}
pub fn kernelCacheStats() struct { hits: u64, misses: u64 } {
    return .{ .hits = kernel_cache.hits, .misses = kernel_cache.misses };
}

pub fn clear(surface: *s.Surface, color: s.Color) void {
    fillRect(surface, .{ .x = 0, .y = 0, .width = surface.width, .height = surface.height }, color);
}
pub fn fillRect(surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    if (clipped.width == 1 and clipped.height == 1) {
        s.Surface.write(surface.row(@intCast(clipped.y)), @as(usize, @intCast(clipped.x)) * 4, surface.format, color);
        return;
    }
    const kernel = cachedKernel(surface.format, .fill);
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| kernel.fillSpan(surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, color) catch unreachable;
}
pub fn blendRect(surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    const kernel = cachedKernel(surface.format, .source_over);
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| kernel.blendSpan(surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, color) catch unreachable;
}

pub fn fillRectWith(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: dispatch.Backend) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    if (clipped.width == 1 and clipped.height == 1) {
        s.Surface.write(surface.row(@intCast(clipped.y)), @as(usize, @intCast(clipped.x)) * 4, surface.format, color);
        return;
    }
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| dispatch.fillSpan(backend, surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, surface.format, color);
}
pub fn blendRectWith(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: dispatch.Backend) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    if (clipped.width == 1 and clipped.height == 1) {
        const row = surface.row(@intCast(clipped.y));
        const offset = @as(usize, @intCast(clipped.x)) * 4;
        s.Surface.write(row, offset, surface.format, scalar.blendPixel(s.Surface.read(row, offset, surface.format), color));
        return;
    }
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| dispatch.blendSpan(backend, surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, surface.format, color);
}

/// Draw a tightly packed RGBA8 sprite with straight-alpha source-over blending.
/// Destination clipping also advances the source origin, so off-screen draws
/// preserve the same pixels as an unclipped composition.
pub fn drawSprite(surface: *s.Surface, destination: s.Rect, source: []const u8, source_width: u32, source_height: u32) void {
    if (destination.width != source_width or destination.height != source_height) return;
    const clipped = s.clip(destination, surface.width, surface.height) orelse return;
    const source_x: usize = @intCast(clipped.x - destination.x);
    const source_y: usize = @intCast(clipped.y - destination.y);
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    const kernel = cachedKernel(surface.format, .sprite);
    for (0..clipped.height) |dy| {
        const row = surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy));
        const source_offset = ((source_y + dy) * source_width + source_x) * 4;
        kernel.spriteSpan(row, @intCast(clipped.x), source[source_offset..], clipped.width) catch unreachable;
    }
}

pub fn drawSpriteWith(surface: *s.Surface, destination: s.Rect, source: []const u8, source_width: u32, source_height: u32, backend: dispatch.Backend) void {
    if (destination.width != source_width or destination.height != source_height) return;
    const clipped = s.clip(destination, surface.width, surface.height) orelse return;
    const source_x: usize = @intCast(clipped.x - destination.x);
    const source_y: usize = @intCast(clipped.y - destination.y);
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    for (0..clipped.height) |dy| {
        const row = surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy));
        const source_offset = ((source_y + dy) * source_width + source_x) * 4;
        dispatch.blendPixels(backend, row, @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
    }
}

test "sprite draw validates source and clips while preserving source origin" {
    var pixels = [_]u8{0} ** (3 * 2 * 4);
    var surface = try s.Surface.init(&pixels, 3, 2, 12, .rgba8_unorm);
    const sprite = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    drawSpriteWith(&surface, .{ .x = -1, .y = 0, .width = 2, .height = 2 }, &sprite, 2, 2, .scalar);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255 }, pixels[0..4]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 255, 255, 255 }, pixels[12..16]);
    const before = pixels;
    if (dispatch.available(.avx2)) drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = 1, .height = 2 }, &sprite, 2, 2, .avx2);
    drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, sprite[0..4], 2, 2, .portable_vector);
    drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }, &.{}, std.math.maxInt(u32), std.math.maxInt(u32), .scalar);
    drawSpriteWith(&surface, .{ .x = 5, .y = 5, .width = 2, .height = 2 }, &sprite, 2, 2, .scalar);
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

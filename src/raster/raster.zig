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

// A tightly packed full-width rectangle is one contiguous pixel span. Keep
// the row loop out of the hot path so SIMD kernels pay their dispatch/setup
// cost once instead of once per scanline. Surfaces with padding (or a partial
// width) retain the row-wise path below.
const ContiguousSpan = struct { bytes: []u8, pixels: usize };

fn contiguousSpan(surface: *s.Surface, clipped: s.Rect) ?ContiguousSpan {
    if (clipped.x != 0 or clipped.width != surface.width) return null;
    const row_bytes = std.math.mul(usize, @as(usize, surface.width), 4) catch return null;
    if (surface.stride != row_bytes) return null;
    const start = std.math.mul(usize, @as(usize, @intCast(clipped.y)), row_bytes) catch return null;
    const pixels = std.math.mul(usize, @as(usize, @intCast(clipped.width)), @as(usize, @intCast(clipped.height))) catch return null;
    const bytes = std.math.mul(usize, pixels, 4) catch return null;
    if (start > surface.pixels.len or bytes > surface.pixels.len - start) return null;
    return .{ .bytes = surface.pixels[start .. start + bytes], .pixels = pixels };
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
    // Pixel pushes are a hot API path. Avoid the i64 rectangle clipper when
    // the caller has already supplied a one-pixel rectangle; retain the exact
    // out-of-bounds no-op semantics before narrowing the coordinates.
    if (rect.width == 1 and rect.height == 1) {
        if (rect.x < 0 or rect.y < 0 or @as(u32, @intCast(rect.x)) >= surface.width or @as(u32, @intCast(rect.y)) >= surface.height) return;
        s.Surface.write(surface.row(@intCast(rect.y)), @as(usize, @intCast(rect.x)) * 4, surface.format, color);
        return;
    }
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    const kernel = cachedKernel(surface.format, .fill);
    if (contiguousSpan(surface, clipped)) |span| {
        kernel.fillSpan(span.bytes, 0, span.pixels, color) catch unreachable;
        return;
    }
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| kernel.fillSpan(surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, color) catch unreachable;
}
pub fn blendRect(surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    const kernel = cachedKernel(surface.format, .source_over);
    if (contiguousSpan(surface, clipped)) |span| {
        kernel.blendSpan(span.bytes, 0, span.pixels, color) catch unreachable;
        return;
    }
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| kernel.blendSpan(surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, color) catch unreachable;
}

pub fn fillRectWith(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: dispatch.Backend) void {
    if (rect.width == 1 and rect.height == 1) {
        if (rect.x < 0 or rect.y < 0 or @as(u32, @intCast(rect.x)) >= surface.width or @as(u32, @intCast(rect.y)) >= surface.height) return;
        s.Surface.write(surface.row(@intCast(rect.y)), @as(usize, @intCast(rect.x)) * 4, surface.format, color);
        return;
    }
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    if (contiguousSpan(surface, clipped)) |span| {
        dispatch.fillSpan(backend, span.bytes, 0, span.pixels, surface.format, color);
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
    if (contiguousSpan(surface, clipped)) |span| {
        dispatch.blendSpan(backend, span.bytes, 0, span.pixels, surface.format, color);
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

fn drawSpriteChecked(surface: *s.Surface, destination: s.Rect, source: []const u8, source_width: u32, backend: dispatch.Backend) void {
    const clipped = s.clip(destination, surface.width, surface.height) orelse return;
    const source_x: usize = @intCast(clipped.x - destination.x);
    const source_y: usize = @intCast(clipped.y - destination.y);
    dispatch.blendPixelsRows(backend, surface, clipped, source, source_width, source_x, source_y);
}

pub fn drawSprites(surface: *s.Surface, destinations: []const s.Rect, source: []const u8, source_width: u32, source_height: u32) void {
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    const kernel = cachedKernel(surface.format, .sprite);
    dispatch.blendPixelsRowsBatch(kernel.backend, surface, destinations, source, source_width, source_height);
}

pub fn drawSpriteWith(surface: *s.Surface, destination: s.Rect, source: []const u8, source_width: u32, source_height: u32, backend: dispatch.Backend) void {
    if (destination.width != source_width or destination.height != source_height) return;
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    drawSpriteChecked(surface, destination, source, source_width, backend);
}

/// Draw multiple same-sized sprites while validating the immutable source once.
/// This keeps the per-sprite clipping and source-origin semantics, but avoids
/// repeating the source-size checks for batched UI/particle workloads.
pub fn drawSpritesWith(surface: *s.Surface, destinations: []const s.Rect, source: []const u8, source_width: u32, source_height: u32, backend: dispatch.Backend) void {
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    dispatch.blendPixelsRowsBatch(backend, surface, destinations, source, source_width, source_height);
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

    var batched_pixels = [_]u8{0} ** (3 * 2 * 4);
    var individual_pixels = [_]u8{0} ** (3 * 2 * 4);
    var batched_surface = try s.Surface.init(&batched_pixels, 3, 2, 12, .rgba8_unorm);
    var individual_surface = try s.Surface.init(&individual_pixels, 3, 2, 12, .rgba8_unorm);
    const destinations = [_]s.Rect{
        .{ .x = -1, .y = 0, .width = 2, .height = 2 },
        .{ .x = 1, .y = 0, .width = 2, .height = 2 },
    };
    drawSpritesWith(&batched_surface, &destinations, &sprite, 2, 2, .scalar);
    for (destinations) |destination| drawSpriteWith(&individual_surface, destination, &sprite, 2, 2, .scalar);
    try std.testing.expectEqualSlices(u8, &individual_pixels, &batched_pixels);
}

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
    // Narrow spans (cursor/guideline columns) never fill a SIMD lane. Writing
    // them directly avoids one vector-kernel call per scanline while retaining
    // the exact format-aware byte order.
    if (clipped.width <= 2) {
        for (0..clipped.height) |dy| for (0..clipped.width) |dx| {
            s.Surface.write(surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), (@as(usize, @intCast(clipped.x)) + dx) * 4, surface.format, color);
        };
        return;
    }
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
    if (clipped.width <= 2 and clipped.height <= 2) {
        for (0..clipped.height) |dy| {
            const row = surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy));
            for (0..clipped.width) |dx| {
                const offset = (@as(usize, @intCast(clipped.x)) + dx) * 4;
                s.Surface.write(row, offset, surface.format, scalar.blendPixel(s.Surface.read(row, offset, surface.format), color));
            }
        }
        return;
    }
    if (contiguousSpan(surface, clipped)) |span| {
        dispatch.blendSpan(backend, span.bytes, 0, span.pixels, surface.format, color);
        return;
    }
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| dispatch.blendSpan(backend, surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, surface.format, color);
}

/// A colored rectangle command used by retained-mode UI/compositor callers.
/// Keeping the color next to the geometry lets one batch contain window
/// shadows, panels, controls, and guides without allocating per draw.
pub const ColoredRect = struct { rect: s.Rect, color: s.Color };
pub const SpriteRegion = dispatch.SpriteRegion;

fn hasBinaryAlpha(source: []const u8, source_width: u32, source_height: u32) bool {
    const pixels = std.math.mul(usize, source_width, source_height) catch return false;
    const bytes = std.math.mul(usize, pixels, 4) catch return false;
    if (source.len < bytes) return false;
    var offset: usize = 3;
    while (offset < bytes) : (offset += 4) {
        const alpha = source[offset];
        if (alpha != 0 and alpha != 255) return false;
    }
    return true;
}

fn fillRectBackend(comptime backend: dispatch.Backend, surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    if (rect.width == 1 and rect.height == 1) {
        if (rect.x < 0 or rect.y < 0 or @as(u32, @intCast(rect.x)) >= surface.width or @as(u32, @intCast(rect.y)) >= surface.height) return;
        s.Surface.write(surface.row(@intCast(rect.y)), @as(usize, @intCast(rect.x)) * 4, surface.format, color);
        return;
    }
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    // Narrow spans (cursor/guideline columns) never fill a SIMD lane. Writing
    // them directly avoids one vector-kernel call per scanline while retaining
    // the exact format-aware byte order.
    if (clipped.width <= 2) {
        for (0..clipped.height) |dy| for (0..clipped.width) |dx| {
            s.Surface.write(surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), (@as(usize, @intCast(clipped.x)) + dx) * 4, surface.format, color);
        };
        return;
    }
    if (contiguousSpan(surface, clipped)) |span| {
        switch (backend) {
            .scalar => scalar.fillSpan(span.bytes, 0, span.pixels, surface.format, color),
            .portable_vector, .avx2 => dispatch.fillSpan(backend, span.bytes, 0, span.pixels, surface.format, color),
        }
        return;
    }
    dispatch.fillRows(backend, surface, clipped, color);
}

fn blendRectBackend(comptime backend: dispatch.Backend, surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    if (clipped.width == 1 and clipped.height == 1) {
        const row = surface.row(@intCast(clipped.y));
        const offset = @as(usize, @intCast(clipped.x)) * 4;
        s.Surface.write(row, offset, surface.format, scalar.blendPixel(s.Surface.read(row, offset, surface.format), color));
        return;
    }
    if (clipped.width <= 2 and clipped.height <= 2) {
        for (0..clipped.height) |dy| {
            const row = surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy));
            for (0..clipped.width) |dx| {
                const offset = (@as(usize, @intCast(clipped.x)) + dx) * 4;
                s.Surface.write(row, offset, surface.format, scalar.blendPixel(s.Surface.read(row, offset, surface.format), color));
            }
        }
        return;
    }
    if (contiguousSpan(surface, clipped)) |span| {
        switch (backend) {
            .scalar => scalar.blendSpan(span.bytes, 0, span.pixels, surface.format, color),
            .portable_vector, .avx2 => dispatch.blendSpan(backend, span.bytes, 0, span.pixels, surface.format, color),
        }
        return;
    }
    dispatch.blendRows(backend, surface, clipped, color);
}

/// Fill many independently clipped rectangles with one backend route. The
/// individual geometry and color values remain observable in draw order.
pub fn fillRectsWith(surface: *s.Surface, draws: []const ColoredRect, backend: dispatch.Backend) void {
    switch (backend) {
        .scalar => for (draws) |draw| fillRectBackend(.scalar, surface, draw.rect, draw.color),
        .portable_vector => for (draws) |draw| fillRectBackend(.portable_vector, surface, draw.rect, draw.color),
        .avx2 => for (draws) |draw| fillRectBackend(.avx2, surface, draw.rect, draw.color),
    }
}

pub fn blendRectsWith(surface: *s.Surface, draws: []const ColoredRect, backend: dispatch.Backend) void {
    switch (backend) {
        .scalar => for (draws) |draw| blendRectBackend(.scalar, surface, draw.rect, draw.color),
        .portable_vector => for (draws) |draw| blendRectBackend(.portable_vector, surface, draw.rect, draw.color),
        .avx2 => for (draws) |draw| blendRectBackend(.avx2, surface, draw.rect, draw.color),
    }
}

pub fn fillRects(surface: *s.Surface, draws: []const ColoredRect) void {
    fillRectsWith(surface, draws, cachedKernel(surface.format, .fill).backend);
}

pub fn blendRects(surface: *s.Surface, draws: []const ColoredRect) void {
    blendRectsWith(surface, draws, cachedKernel(surface.format, .source_over).backend);
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

/// Draw atlas-backed sprites in one batch. Source rectangles may differ per
/// draw, which models terminal glyph atlases and 2D engine texture sheets.
pub fn drawSpriteRegionsWith(surface: *s.Surface, regions: []const SpriteRegion, source: []const u8, source_width: u32, source_height: u32, backend: dispatch.Backend) void {
    const source_pixels = std.math.mul(usize, source_width, source_height) catch return;
    const source_bytes = std.math.mul(usize, source_pixels, 4) catch return;
    if (source.len < source_bytes) return;
    for (regions) |region| {
        const source_rect = region.source;
        if (source_rect.x < 0 or source_rect.y < 0) continue;
        const sx: u32 = @intCast(source_rect.x);
        const sy: u32 = @intCast(source_rect.y);
        if (sx > source_width or sy > source_height or source_rect.width > source_width - sx or source_rect.height > source_height - sy) continue;
        if (region.destination.width != source_rect.width or region.destination.height != source_rect.height) continue;
    }
    dispatch.blendPixelsRowsRegionsBatch(backend, surface, regions, source, source_width, source_height, hasBinaryAlpha(source, source_width, source_height));
}

pub fn drawSpriteRegions(surface: *s.Surface, regions: []const SpriteRegion, source: []const u8, source_width: u32, source_height: u32) void {
    drawSpriteRegionsWith(surface, regions, source, source_width, source_height, cachedKernel(surface.format, .sprite).backend);
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

test "colored rectangle batches preserve draw order and clipping" {
    var batched_pixels = [_]u8{0} ** (8 * 6 * 4);
    var individual_pixels = [_]u8{0} ** (8 * 6 * 4);
    var batched = try s.Surface.init(&batched_pixels, 8, 6, 32, .rgba8_unorm);
    var individual = try s.Surface.init(&individual_pixels, 8, 6, 32, .rgba8_unorm);
    const fills = [_]ColoredRect{
        .{ .rect = .{ .x = -2, .y = 1, .width = 5, .height = 4 }, .color = .rgba(210, 30, 40, 255) },
        .{ .rect = .{ .x = 3, .y = -1, .width = 6, .height = 3 }, .color = .rgba(30, 180, 70, 255) },
        .{ .rect = .{ .x = 7, .y = 4, .width = 1, .height = 1 }, .color = .rgba(20, 40, 220, 255) },
    };
    fillRectsWith(&batched, &fills, .scalar);
    for (fills) |draw| fillRectWith(&individual, draw.rect, draw.color, .scalar);
    try std.testing.expectEqualSlices(u8, &individual_pixels, &batched_pixels);
    const blends = [_]ColoredRect{
        .{ .rect = .{ .x = 1, .y = 1, .width = 4, .height = 3 }, .color = .rgba(240, 40, 90, 96) },
        .{ .rect = .{ .x = -1, .y = 3, .width = 6, .height = 4 }, .color = .rgba(20, 180, 220, 144) },
    };
    blendRectsWith(&batched, &blends, .scalar);
    for (blends) |draw| blendRectWith(&individual, draw.rect, draw.color, .scalar);
    try std.testing.expectEqualSlices(u8, &individual_pixels, &batched_pixels);
}

test "atlas sprite batches preserve source rectangles and clipping" {
    var atlas: [6 * 4 * 4]u8 = undefined;
    for (&atlas, 0..) |*byte, index| byte.* = @truncate(index * 17 + 3);
    var batched_pixels = [_]u8{0} ** (8 * 6 * 4);
    var individual_pixels = [_]u8{0} ** (8 * 6 * 4);
    var batched = try s.Surface.init(&batched_pixels, 8, 6, 32, .rgba8_unorm);
    var individual = try s.Surface.init(&individual_pixels, 8, 6, 32, .rgba8_unorm);
    const regions = [_]SpriteRegion{
        .{ .destination = .{ .x = -1, .y = 1, .width = 3, .height = 2 }, .source = .{ .x = 1, .y = 1, .width = 3, .height = 2 } },
        .{ .destination = .{ .x = 4, .y = 3, .width = 2, .height = 2 }, .source = .{ .x = 3, .y = 0, .width = 2, .height = 2 } },
    };
    drawSpriteRegionsWith(&batched, &regions, &atlas, 6, 4, .scalar);
    var first_source: [3 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..3) |x| @memcpy(first_source[(y * 3 + x) * 4 ..][0..4], atlas[((1 + y) * 6 + (1 + x)) * 4 ..][0..4]);
    drawSpriteWith(&individual, regions[0].destination, &first_source, 3, 2, .scalar);
    var second_source: [2 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..2) |x| @memcpy(second_source[(y * 2 + x) * 4 ..][0..4], atlas[(y * 6 + (3 + x)) * 4 ..][0..4]);
    drawSpriteWith(&individual, regions[1].destination, &second_source, 2, 2, .scalar);
    try std.testing.expectEqualSlices(u8, &individual_pixels, &batched_pixels);
    const before = batched_pixels;
    const invalid = [_]SpriteRegion{.{ .destination = .{ .x = 0, .y = 0, .width = 2, .height = 2 }, .source = .{ .x = 5, .y = 3, .width = 2, .height = 2 } }};
    drawSpriteRegionsWith(&batched, &invalid, &atlas, 6, 4, .scalar);
    try std.testing.expectEqualSlices(u8, &before, &batched_pixels);
}

test "binary alpha atlas batches match scalar BGRA composition" {
    var atlas: [8 * 4 * 4]u8 = undefined;
    for (0..4) |y| for (0..8) |x| {
        const index = (y * 8 + x) * 4;
        atlas[index] = @truncate(x * 31 + y * 7);
        atlas[index + 1] = @truncate(x * 13 + y * 29);
        atlas[index + 2] = @truncate(x * 19 + y * 11);
        atlas[index + 3] = if ((x + y) % 3 == 0) 255 else 0;
    };
    var batched_pixels = [_]u8{0x23} ** (8 * 6 * 4);
    var individual_pixels = batched_pixels;
    var batched = try s.Surface.init(&batched_pixels, 8, 6, 32, .bgra8_unorm);
    var individual = try s.Surface.init(&individual_pixels, 8, 6, 32, .bgra8_unorm);
    const regions = [_]SpriteRegion{
        .{ .destination = .{ .x = -1, .y = 1, .width = 4, .height = 3 }, .source = .{ .x = 1, .y = 0, .width = 4, .height = 3 } },
        .{ .destination = .{ .x = 3, .y = 3, .width = 3, .height = 1 }, .source = .{ .x = 0, .y = 2, .width = 3, .height = 1 } },
    };
    drawSpriteRegionsWith(&batched, &regions, &atlas, 8, 4, .portable_vector);
    var first_source: [4 * 3 * 4]u8 = undefined;
    for (0..3) |y| for (0..4) |x| @memcpy(first_source[(y * 4 + x) * 4 ..][0..4], atlas[(y * 8 + (1 + x)) * 4 ..][0..4]);
    drawSpriteWith(&individual, regions[0].destination, &first_source, 4, 3, .scalar);
    var second_source: [3 * 1 * 4]u8 = undefined;
    for (0..3) |x| @memcpy(second_source[x * 4 ..][0..4], atlas[(2 * 8 + x) * 4 ..][0..4]);
    drawSpriteWith(&individual, regions[1].destination, &second_source, 3, 1, .scalar);
    try std.testing.expectEqualSlices(u8, &individual_pixels, &batched_pixels);
}

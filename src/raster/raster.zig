const std = @import("std");
const s = @import("../surface.zig");
const dispatch = @import("../simd/dispatch.zig");

pub fn clear(surface: *s.Surface, color: s.Color) void {
    fillRectWith(surface, .{ .x = 0, .y = 0, .width = surface.width, .height = surface.height }, color, dispatch.best());
}
pub fn fillRect(surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    fillRectWith(surface, rect, color, dispatch.best());
}
pub fn blendRect(surface: *s.Surface, rect: s.Rect, color: s.Color) void {
    blendRectWith(surface, rect, color, dispatch.best());
}

pub fn fillRectWith(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: dispatch.Backend) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| dispatch.fillSpan(backend, surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, surface.format, color);
}
pub fn blendRectWith(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: dispatch.Backend) void {
    const clipped = s.clip(rect, surface.width, surface.height) orelse return;
    for (@intCast(clipped.y)..@as(usize, @intCast(clipped.y)) + clipped.height) |y| dispatch.blendSpan(backend, surface.row(@intCast(y)), @intCast(clipped.x), clipped.width, surface.format, color);
}

/// Draw a tightly packed RGBA8 sprite with straight-alpha source-over blending.
/// Destination clipping also advances the source origin, so off-screen draws
/// preserve the same pixels as an unclipped composition.
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
    drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = 1, .height = 2 }, &sprite, 2, 2, .avx2);
    drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, sprite[0..4], 2, 2, .avx512);
    drawSpriteWith(&surface, .{ .x = 0, .y = 0, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }, &.{}, std.math.maxInt(u32), std.math.maxInt(u32), .scalar);
    drawSpriteWith(&surface, .{ .x = 5, .y = 5, .width = 2, .height = 2 }, &sprite, 2, 2, .scalar);
    try std.testing.expectEqualSlices(u8, &before, &pixels);
}

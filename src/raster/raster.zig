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

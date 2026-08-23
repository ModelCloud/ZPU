const s = @import("../surface.zig");
const raster = @import("../raster/raster.zig");

pub const Command = union(enum) { clear: s.Color, fill: struct { rect: s.Rect, color: s.Color }, blend: struct { rect: s.Rect, color: s.Color } };
pub fn execute(surface: *s.Surface, commands: []const Command) void {
    for (commands) |command| switch (command) {
        .clear => |c| raster.clear(surface, c),
        .fill => |v| raster.fillRect(surface, v.rect, v.color),
        .blend => |v| raster.blendRect(surface, v.rect, v.color),
    };
}

const std = @import("std");
const zpu = @import("zpu");

pub fn main(init: std.process.Init) !void {
    const width = 320;
    const height = 180;
    var pixels: [width * height * 4]u8 = undefined;
    var surface = try zpu.surface.Surface.init(&pixels, width, height, width * 4, .bgra8_unorm);
    const commands = [_]zpu.command.Command{
        .{ .clear = .rgba(24, 32, 48, 255) },
        .{ .fill = .{ .rect = .{ .x = 10, .y = 8, .width = 300, .height = 164 }, .color = .rgba(54, 67, 88, 255) } },
        .{ .fill = .{ .rect = .{ .x = 18, .y = 18, .width = 284, .height = 22 }, .color = .rgba(33, 150, 243, 255) } },
        .{ .fill = .{ .rect = .{ .x = 25, .y = 52, .width = 126, .height = 100 }, .color = .rgba(238, 238, 238, 255) } },
        .{ .fill = .{ .rect = .{ .x = 165, .y = 52, .width = 128, .height = 45 }, .color = .rgba(255, 193, 7, 255) } },
        .{ .blend = .{ .rect = .{ .x = 122, .y = 75, .width = 112, .height = 73 }, .color = .rgba(233, 30, 99, 170) } },
        .{ .blend = .{ .rect = .{ .x = -8, .y = 128, .width = 96, .height = 42 }, .color = .rgba(76, 175, 80, 210) } },
    };
    zpu.command.execute(&surface, &commands);
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const path = if (args.len > 1) args[1] else "zpu-demo.ppm";
    try zpu.platform.writePpm(init.io, &surface, path);
}

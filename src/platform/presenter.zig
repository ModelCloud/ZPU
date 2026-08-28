// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const s = @import("../surface.zig");

/// Headless presentation writes binary PPM. Alpha is intentionally discarded.
pub fn writePpm(io: std.Io, surface: *s.Surface, path: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    const out = &writer.interface;
    try out.print("P6\n{d} {d}\n255\n", .{ surface.width, surface.height });
    for (0..surface.height) |y| {
        const row = surface.row(@intCast(y));
        for (0..surface.width) |x| {
            const c = s.Surface.read(row, x * 4, surface.format);
            try out.writeAll(&.{ c.r, c.g, c.b });
        }
    }
    try out.flush();
}

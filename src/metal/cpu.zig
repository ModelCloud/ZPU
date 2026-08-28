// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Native Metal-shaped CPU command recording and execution.

const std = @import("std");
const abi = @import("abi.zig");
const surface = @import("../surface.zig");
const raster = @import("../raster/raster.zig");

pub const Device = struct {
    pub fn systemDefault() Device { return .{}; }
    pub fn newCommandBuffer(_: Device) CommandBuffer { return .{}; }
};

const Work = union(enum) {
    clear: abi.Color,
    fill: struct { rect: surface.Rect, color: surface.Color },
};

pub const CommandBuffer = struct {
    target: ?*surface.Surface = null,
    pass: abi.RenderPassDescriptor = .{ .color = .{} },
    work: [64]Work = undefined,
    work_len: usize = 0,
    ended: bool = false,

    pub fn renderCommandEncoder(self: *CommandBuffer, target: *surface.Surface, descriptor: abi.RenderPassDescriptor) Encoder {
        self.target = target;
        self.pass = descriptor;
        return .{ .buffer = self };
    }

    pub fn commit(self: *CommandBuffer) !void {
        if (!self.ended or self.target == null) return error.InvalidCommandBuffer;
        const target = self.target.?;
        if (self.pass.color.load_action == .clear) raster.clear(target, toSurfaceColor(self.pass.color.clear_color));
        // The 2D encoder is intentionally serial. This is the CPU Metal
        // contract and keeps overlapping source-over operations ordered.
        for (self.work[0..self.work_len]) |work| switch (work) {
            .clear => |color| raster.clear(target, toSurfaceColor(color)),
            .fill => |fill| raster.fillRect(target, fill.rect, fill.color),
        };
        self.* = .{};
    }

    fn append(self: *CommandBuffer, work: Work) !void {
        if (self.work_len == self.work.len) return error.CommandBufferFull;
        self.work[self.work_len] = work;
        self.work_len += 1;
    }
};

pub const Encoder = struct {
    buffer: *CommandBuffer,

    pub fn clearColor(self: *Encoder, color: abi.Color) !void {
        try self.buffer.append(.{ .clear = color });
    }

    pub fn fillRect(self: *Encoder, rect: surface.Rect, color: surface.Color) !void {
        try self.buffer.append(.{ .fill = .{ .rect = rect, .color = color } });
    }

    pub fn endEncoding(self: *Encoder) void { self.buffer.ended = true; }
};

fn toSurfaceColor(color: abi.Color) surface.Color {
    return .{
        .r = @intFromFloat(std.math.clamp(color.red, 0, 1) * 255.0),
        .g = @intFromFloat(std.math.clamp(color.green, 0, 1) * 255.0),
        .b = @intFromFloat(std.math.clamp(color.blue, 0, 1) * 255.0),
        .a = @intFromFloat(std.math.clamp(color.alpha, 0, 1) * 255.0),
    };
}

test "native Metal-shaped command buffer executes ordered 2D work" {
    var pixels = [_]u8{0} ** (2 * 2 * 4);
    var target = try surface.Surface.init(&pixels, 2, 2, 8, .rgba8_unorm);
    var buffer = Device.systemDefault().newCommandBuffer();
    var encoder = buffer.renderCommandEncoder(&target, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } } });
    try encoder.fillRect(.{ .x = 0, .y = 0, .width = 1, .height = 1 }, .rgba(255, 0, 0, 255));
    encoder.endEncoding();
    try buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 0, 0, 255 }, pixels[0..8]);
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Native Metal-shaped CPU command recording and execution.
//!
//! The implementation deliberately keeps Metal's command-buffer and encoder
//! ordering rules while using ZPU-native CPU resources. Two-dimensional work
//! stays on the submitting thread; a three-dimensional draw uses that thread
//! plus one screen-band worker.

const std = @import("std");
const abi = @import("abi.zig");
const surface = @import("../surface.zig");
const raster = @import("../raster/raster.zig");
const raster3d = @import("raster3d.zig");

pub const Device = struct {
    pub fn systemDefault() Device {
        return .{};
    }

    pub fn newCommandQueue(self: Device) CommandQueue {
        return .{ .device = self };
    }

    /// Convenience entry point matching the original WIP API.
    pub fn newCommandBuffer(_: Device) CommandBuffer {
        return .{};
    }
};

pub const CommandQueue = struct {
    device: Device,

    pub fn commandBuffer(self: CommandQueue) CommandBuffer {
        return Device.newCommandBuffer(self.device);
    }
};

const Work = union(enum) {
    clear: abi.Color,
    fill: struct { rect: surface.Rect, color: surface.Color },
    draw: struct {
        vertices: []const abi.Vertex,
        primitive: abi.PrimitiveType,
        options: raster3d.DrawOptions,
    },
};

pub const CommandBuffer = struct {
    target: ?*surface.Surface = null,
    depth: ?[]f32 = null,
    pass: abi.RenderPassDescriptor = .{ .color = .{} },
    work: [64]Work = undefined,
    work_len: usize = 0,
    encoder_active: bool = false,
    ended: bool = false,
    completed_stats: raster3d.Stats = .{},

    pub fn renderCommandEncoder(self: *CommandBuffer, target: *surface.Surface, descriptor: abi.RenderPassDescriptor) Encoder {
        self.target = target;
        self.pass = descriptor;
        self.work_len = 0;
        self.encoder_active = true;
        self.ended = false;
        return .{
            .buffer = self,
            .options = .{
                .viewport = .{ .origin_x = 0, .origin_y = 0, .width = @floatFromInt(target.width), .height = @floatFromInt(target.height), .znear = 0, .zfar = 1 },
                .scissor = .{ .x = 0, .y = 0, .width = target.width, .height = target.height },
            },
        };
    }

    pub fn commit(self: *CommandBuffer) !void {
        if (!self.ended or self.encoder_active or self.target == null) return error.InvalidCommandBuffer;
        const target = self.target.?;
        const three_dimensional = self.has3dWork();
        if (self.pass.color.load_action == .clear) {
            const clear = toSurfaceColor(self.pass.color.clear_color);
            if (three_dimensional) raster3d.clearSurface(target, clear) else raster.clear(target, clear);
        }
        if (self.pass.depth.load_action == .clear) {
            if (self.depth) |depth| {
                if (depth.len < @as(usize, target.width) * target.height) return error.InvalidDepthAttachment;
                if (three_dimensional) raster3d.clearDepth(depth, target.width, self.pass.depth.clear_depth) else @memset(depth, self.pass.depth.clear_depth);
            }
        }

        var stats = raster3d.Stats{};
        for (self.work[0..self.work_len]) |work| switch (work) {
            .clear => |color| {
                if (three_dimensional) raster3d.clearSurface(target, toSurfaceColor(color)) else raster.clear(target, toSurfaceColor(color));
            },
            .fill => |fill| raster.fillRect(target, fill.rect, fill.color),
            .draw => |draw| stats = addStats(stats, raster3d.drawSurface(target, self.depth, null, draw.vertices, draw.primitive, draw.options)),
        };
        self.completed_stats = stats;
        self.* = .{ .completed_stats = stats };
    }

    pub fn completedStats(self: *const CommandBuffer) raster3d.Stats {
        return self.completed_stats;
    }

    fn append(self: *CommandBuffer, work: Work) !void {
        if (!self.encoder_active or self.ended) return error.InvalidCommandEncoder;
        if (self.work_len == self.work.len) return error.CommandBufferFull;
        self.work[self.work_len] = work;
        self.work_len += 1;
    }

    fn has3dWork(self: *const CommandBuffer) bool {
        for (self.work[0..self.work_len]) |work| switch (work) {
            .draw => return true,
            else => {},
        };
        return false;
    }
};

pub const Encoder = struct {
    buffer: *CommandBuffer,
    options: raster3d.DrawOptions,

    pub fn setDepthBuffer(self: *Encoder, depth: []f32) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.buffer.depth = depth;
    }

    pub fn setViewport(self: *Encoder, viewport: abi.Viewport) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.options.viewport = viewport;
    }

    pub fn setScissorRect(self: *Encoder, scissor: abi.ScissorRect) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.options.scissor = scissor;
    }

    pub fn setCullMode(self: *Encoder, cull_mode: abi.CullMode) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.options.cull_mode = cull_mode;
    }

    pub fn setFrontFacing(self: *Encoder, winding: abi.Winding) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.options.winding = winding;
    }

    pub fn setTriangleFillMode(self: *Encoder, fill_mode: abi.TriangleFillMode) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        self.options.fill_mode = fill_mode;
    }

    pub fn clearColor(self: *Encoder, color: abi.Color) !void {
        try self.buffer.append(.{ .clear = color });
    }

    pub fn fillRect(self: *Encoder, rect: surface.Rect, color: surface.Color) !void {
        try self.buffer.append(.{ .fill = .{ .rect = rect, .color = color } });
    }

    pub fn drawPrimitives(self: *Encoder, primitive: abi.PrimitiveType, vertices: []const abi.Vertex) !void {
        if (!self.isOpen()) return error.InvalidCommandEncoder;
        if (vertices.len == 0) return;
        try self.buffer.append(.{ .draw = .{ .vertices = vertices, .primitive = primitive, .options = self.options } });
    }

    pub fn endEncoding(self: *Encoder) void {
        if (self.buffer.encoder_active and !self.buffer.ended) {
            self.buffer.ended = true;
            self.buffer.encoder_active = false;
        }
    }

    fn isOpen(self: *const Encoder) bool {
        return self.buffer.encoder_active and !self.buffer.ended;
    }
};

fn addStats(a: raster3d.Stats, b: raster3d.Stats) raster3d.Stats {
    return .{
        .primitives_submitted = a.primitives_submitted + b.primitives_submitted,
        .primitives_rasterized = a.primitives_rasterized + b.primitives_rasterized,
        .fragments_tested = a.fragments_tested + b.fragments_tested,
        .fragments_covered = a.fragments_covered + b.fragments_covered,
        .depth_tests_passed = a.depth_tests_passed + b.depth_tests_passed,
        .color_writes = a.color_writes + b.color_writes,
    };
}

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

test "2D BGRA output stays on one ordered CPU path" {
    var pixels = [_]u8{0} ** (2 * 2 * 4);
    var target = try surface.Surface.init(&pixels, 2, 2, 8, .bgra8_unorm);
    var buffer = Device.systemDefault().newCommandBuffer();
    var encoder = buffer.renderCommandEncoder(&target, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 1, .green = 0.5, .blue = 0, .alpha = 1 } } });
    encoder.endEncoding();
    try buffer.commit();
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 127, 255, 255 }, pixels[0..4]);
}

test "3D encoder uses two-band CPU rasterization and depth ordering" {
    var pixels = [_]u8{0} ** (8 * 8 * 4);
    var depth = [_]f32{1} ** (8 * 8);
    var target = try surface.Surface.init(&pixels, 8, 8, 8 * 4, .rgba8_unorm);
    var buffer = Device.systemDefault().newCommandQueue().commandBuffer();
    var encoder = buffer.renderCommandEncoder(&target, .{ .color = .{ .load_action = .clear, .store_action = .store, .clear_color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } }, .depth = .{ .load_action = .clear, .store_action = .store, .clear_depth = 1 } });
    try encoder.setDepthBuffer(&depth);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.8, -0.8, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.8, -0.8, 0.5, 1 }, .color = .{ .red = 0, .green = 1, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 0.8, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 1, .alpha = 1 } },
    };
    try encoder.drawPrimitives(.triangle, &vertices);
    encoder.endEncoding();
    try buffer.commit();
    const stats = buffer.completedStats();
    try std.testing.expectEqual(@as(u64, 1), stats.primitives_submitted);
    try std.testing.expect(stats.color_writes > 0);
    try std.testing.expect(std.mem.indexOfScalar(u8, &pixels, 255) != null);
}

test "encoder rejects commands after endEncoding" {
    var pixels = [_]u8{0} ** 16;
    var target = try surface.Surface.init(&pixels, 1, 1, 4, .rgba8_unorm);
    var buffer = Device.systemDefault().newCommandBuffer();
    var encoder = buffer.renderCommandEncoder(&target, .{ .color = .{} });
    encoder.endEncoding();
    try std.testing.expectError(error.InvalidCommandEncoder, encoder.clearColor(.{ .red = 0, .green = 0, .blue = 0, .alpha = 0 }));
}

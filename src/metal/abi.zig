// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Stable, native ZPU Metal-facing ABI types.
//!
//! These are deliberately not Vulkan aliases.  Metal has different object
//! lifetime and command-encoder semantics, so the CPU implementation records
//! Metal-shaped commands and executes them without a Vulkan translation pass.

pub const abi_version: u32 = 1;

pub const Workload = enum(u8) {
    two_dimensional,
    three_dimensional,
};

pub const PixelFormat = enum(u16) {
    bgra8_unorm = 80,
    rgba8_unorm = 70,
};

pub const LoadAction = enum(u8) { dont_care, load, clear };
pub const StoreAction = enum(u8) { dont_care, store };
pub const PrimitiveType = enum(u8) { point, line, line_strip, triangle, triangle_strip };
pub const IndexType = enum(u8) { uint16, uint32 };
pub const CullMode = enum(u8) { none, front, back };
pub const Winding = enum(u8) { clockwise, counter_clockwise };
pub const TriangleFillMode = enum(u8) { fill, lines };

pub const Color = extern struct { red: f32, green: f32, blue: f32, alpha: f32 };
pub const Origin = extern struct { x: u32, y: u32, z: u32 };
pub const Size = extern struct { width: u32, height: u32, depth: u32 };
pub const Region = extern struct { origin: Origin, size: Size };
pub const ScissorRect = extern struct { x: u32, y: u32, width: u32, height: u32 };
pub const Viewport = extern struct {
    origin_x: f32,
    origin_y: f32,
    width: f32,
    height: f32,
    znear: f32,
    zfar: f32,
};

/// CPU Metal's deliberately small shader-independent vertex ABI. The CPU
/// backend accepts clip-space positions and interpolated RGBA colors; this is
/// a native ZPU entry point, not a claim to implement MSL or a Metal library.
pub const Vertex = extern struct {
    position: [4]f32,
    color: Color,
};

pub const RenderPassDepthAttachmentDescriptor = extern struct {
    load_action: LoadAction = .dont_care,
    store_action: StoreAction = .dont_care,
    clear_depth: f32 = 1,
};

pub const RenderPassColorAttachmentDescriptor = extern struct {
    load_action: LoadAction = .load,
    store_action: StoreAction = .store,
    clear_color: Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 },
};

pub const RenderPassDescriptor = extern struct {
    color: RenderPassColorAttachmentDescriptor,
    depth: RenderPassDepthAttachmentDescriptor = .{},
};

pub const CpuBudget = struct {
    workload: Workload,

    /// ZPU's CPU Metal contract is intentionally strict: 2D is serialized on
    /// one core; 3D may use exactly two worker lanes when the host permits it.
    pub fn maxCores(self: CpuBudget) u8 {
        return if (self.workload == .two_dimensional) 1 else 2;
    }
};

test "Metal ABI layout and CPU budgets are pinned" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 1), abi_version);
    try std.testing.expectEqual(@as(u8, 1), (CpuBudget{ .workload = .two_dimensional }).maxCores());
    try std.testing.expectEqual(@as(u8, 2), (CpuBudget{ .workload = .three_dimensional }).maxCores());
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Region));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Viewport));
}

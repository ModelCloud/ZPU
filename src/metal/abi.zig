// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Stable, native ZPU Metal-facing ABI types.
//!
//! These are deliberately not Vulkan aliases.  Metal has different object
//! lifetime and command-encoder semantics, so the CPU implementation records
//! Metal-shaped commands and executes them without a Vulkan translation pass.

/// Version of the portable ZPU ABI in `include/zpu/metal.h`.
///
/// This is intentionally not Apple's framework version.  The ZPU ABI is an
/// opt-in compatibility surface and must never be confused with an
/// implementation of the Objective-C Metal runtime.
pub const abi_version: u32 = 8;

pub const Workload = enum(u8) {
    two_dimensional,
    three_dimensional,
};

pub const PixelFormat = enum(u16) {
    bgra8_unorm = 80,
    rgba8_unorm = 70,
    r32_float = 55,
    rgba16_float = 115,
    depth32_float = 252,
    stencil8 = 253,
};

pub const LoadAction = enum(u8) { dont_care, load, clear };
pub const StoreAction = enum(u8) { dont_care, store };
pub const PrimitiveType = enum(u8) { point, line, line_strip, triangle, triangle_strip };
pub const IndexType = enum(u8) { uint16, uint32 };
pub const CullMode = enum(u8) { none, front, back };
pub const Winding = enum(u8) { clockwise, counter_clockwise };
pub const TriangleFillMode = enum(u8) { fill, lines };
pub const DepthClipMode = enum(u8) { clip = 0, clamp = 1 };
pub const SamplerFilter = enum(u8) { nearest = 0, linear = 1 };
pub const SamplerMipFilter = enum(u8) { not_mipmapped = 0, nearest = 1, linear = 2 };
pub const SamplerReductionMode = enum(u8) { weighted_average = 0, minimum = 1, maximum = 2 };
pub const SamplerAddressMode = enum(u8) {
    clamp_to_edge = 0,
    mirror_clamp_to_edge = 1,
    repeat = 2,
    mirror_repeat = 3,
    clamp_to_zero = 4,
    clamp_to_border_color = 5,
};
pub const SamplerBorderColor = enum(u8) {
    transparent_black = 0,
    opaque_black = 1,
    opaque_white = 2,
};
pub const TextureSwizzle = enum(u8) {
    zero = 0,
    one = 1,
    red = 2,
    green = 3,
    blue = 4,
    alpha = 5,
};
pub const TextureSwizzleChannels = extern struct {
    red: TextureSwizzle,
    green: TextureSwizzle,
    blue: TextureSwizzle,
    alpha: TextureSwizzle,
};
pub const CompareFunction = enum(u8) {
    never = 0,
    less = 1,
    equal = 2,
    less_equal = 3,
    greater = 4,
    not_equal = 5,
    greater_equal = 6,
    always = 7,
};
pub const StencilOperation = enum(u8) {
    keep = 0,
    zero = 1,
    replace = 2,
    increment_clamp = 3,
    decrement_clamp = 4,
    invert = 5,
    increment_wrap = 6,
    decrement_wrap = 7,
};
pub const BlendFactor = enum(u8) {
    zero = 0,
    one = 1,
    source_color = 2,
    one_minus_source_color = 3,
    source_alpha = 4,
    one_minus_source_alpha = 5,
    destination_color = 6,
    one_minus_destination_color = 7,
    destination_alpha = 8,
    one_minus_destination_alpha = 9,
    source_alpha_saturated = 10,
    blend_color = 11,
    one_minus_blend_color = 12,
    blend_alpha = 13,
    one_minus_blend_alpha = 14,
};
pub const BlendOperation = enum(u8) { add = 0, subtract = 1, reverse_subtract = 2, min = 3, max = 4 };
pub const ColorWriteMask = enum(u8) { none = 0, red = 1, green = 2, blue = 4, alpha = 8, all = 15 };
pub const VisibilityResultMode = enum(u8) { disabled = 0, boolean = 1, counting = 2 };
pub const VisibilityResultType = enum(u8) { reset = 0, accumulate = 1 };

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

pub const TextureDescriptor = extern struct {
    width: u32,
    height: u32,
    format: u16,
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
    try std.testing.expectEqual(@as(u32, 8), abi_version);
    try std.testing.expectEqual(@as(u8, 1), (CpuBudget{ .workload = .two_dimensional }).maxCores());
    try std.testing.expectEqual(@as(u8, 2), (CpuBudget{ .workload = .three_dimensional }).maxCores());
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Region));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Vertex));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(Viewport));
    try std.testing.expectEqual(@as(usize, 12), @sizeOf(TextureDescriptor));
}

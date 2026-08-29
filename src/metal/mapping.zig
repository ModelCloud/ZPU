// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Explicit Metal-to-Vulkan mapping policy.
//!
//! A direct mapping here means that the ABI shape and operation semantics are
//! already identical enough to hand the value to a Vulkan-facing layer. It is
//! not a command translation pass. Objects whose lifetime or synchronization
//! rules differ stay in the native Metal ABI.

pub const Kind = enum { direct_vulkan, native_metal };

pub const Api = enum {
    color,
    viewport,
    scissor_rect,
    r8_unorm,
    r8_uint,
    r8_sint,
    r16_unorm,
    r16_uint,
    r16_sint,
    r16_float,
    rg8_unorm,
    rg8_uint,
    rg8_sint,
    rg16_unorm,
    rg16_uint,
    rg16_sint,
    rg16_float,
    r32_uint,
    r32_sint,
    rgba8_unorm,
    rgba8_uint,
    rgba8_sint,
    bgra8_unorm,
    r32_float,
    rgba16_unorm,
    rgba16_uint,
    rgba16_sint,
    rgba16_float,
    rg32_uint,
    rg32_sint,
    rg32_float,
    rgba32_float,
    load_dont_care,
    load_load,
    load_clear,
    store_dont_care,
    store_store,
    primitive_point,
    primitive_line,
    primitive_line_strip,
    primitive_triangle,
    primitive_triangle_strip,
    device,
    command_queue,
    command_buffer,
    render_command_encoder,
    compute_command_encoder,
    blit_command_encoder,
    parallel_render_command_encoder,
    render_pass_descriptor,
    depth_attachment,
};

pub const Entry = struct {
    kind: Kind,
    /// Vulkan enum value when `kind` is `.direct_vulkan`; null for native
    /// Metal entries that must not be routed through Vulkan.
    vulkan_value: ?u32 = null,
};

pub fn entry(api: Api) Entry {
    return switch (api) {
        .color, .viewport, .scissor_rect => .{ .kind = .direct_vulkan },
        .r8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 9 }, // VK_FORMAT_R8_UNORM
        .r8_uint => .{ .kind = .direct_vulkan, .vulkan_value = 13 }, // VK_FORMAT_R8_UINT
        .r8_sint => .{ .kind = .direct_vulkan, .vulkan_value = 14 }, // VK_FORMAT_R8_SINT
        .r16_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 70 }, // VK_FORMAT_R16_UNORM
        .r16_uint => .{ .kind = .direct_vulkan, .vulkan_value = 74 }, // VK_FORMAT_R16_UINT
        .r16_sint => .{ .kind = .direct_vulkan, .vulkan_value = 75 }, // VK_FORMAT_R16_SINT
        .r16_float => .{ .kind = .direct_vulkan, .vulkan_value = 76 }, // VK_FORMAT_R16_SFLOAT
        .rg8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 16 }, // VK_FORMAT_R8G8_UNORM
        .rg8_uint => .{ .kind = .direct_vulkan, .vulkan_value = 20 }, // VK_FORMAT_R8G8_UINT
        .rg8_sint => .{ .kind = .direct_vulkan, .vulkan_value = 21 }, // VK_FORMAT_R8G8_SINT
        .rg16_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 77 }, // VK_FORMAT_R16G16_UNORM
        .rg16_uint => .{ .kind = .direct_vulkan, .vulkan_value = 81 }, // VK_FORMAT_R16G16_UINT
        .rg16_sint => .{ .kind = .direct_vulkan, .vulkan_value = 82 }, // VK_FORMAT_R16G16_SINT
        .rg16_float => .{ .kind = .direct_vulkan, .vulkan_value = 83 }, // VK_FORMAT_R16G16_SFLOAT
        .r32_uint => .{ .kind = .direct_vulkan, .vulkan_value = 98 }, // VK_FORMAT_R32_UINT
        .r32_sint => .{ .kind = .direct_vulkan, .vulkan_value = 99 }, // VK_FORMAT_R32_SINT
        .rgba8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 37 }, // VK_FORMAT_R8G8B8A8_UNORM
        .rgba8_uint => .{ .kind = .direct_vulkan, .vulkan_value = 41 }, // VK_FORMAT_R8G8B8A8_UINT
        .rgba8_sint => .{ .kind = .direct_vulkan, .vulkan_value = 42 }, // VK_FORMAT_R8G8B8A8_SINT
        .bgra8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 44 }, // VK_FORMAT_B8G8R8A8_UNORM
        .r32_float => .{ .kind = .direct_vulkan, .vulkan_value = 100 }, // VK_FORMAT_R32_SFLOAT
        .rgba16_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 91 }, // VK_FORMAT_R16G16B16A16_UNORM
        .rgba16_uint => .{ .kind = .direct_vulkan, .vulkan_value = 95 }, // VK_FORMAT_R16G16B16A16_UINT
        .rgba16_sint => .{ .kind = .direct_vulkan, .vulkan_value = 96 }, // VK_FORMAT_R16G16B16A16_SINT
        .rgba16_float => .{ .kind = .direct_vulkan, .vulkan_value = 97 }, // VK_FORMAT_R16G16B16A16_SFLOAT
        .rg32_uint => .{ .kind = .direct_vulkan, .vulkan_value = 101 }, // VK_FORMAT_R32G32_UINT
        .rg32_sint => .{ .kind = .direct_vulkan, .vulkan_value = 102 }, // VK_FORMAT_R32G32_SINT
        .rg32_float => .{ .kind = .direct_vulkan, .vulkan_value = 103 }, // VK_FORMAT_R32G32_SFLOAT
        .rgba32_float => .{ .kind = .direct_vulkan, .vulkan_value = 109 }, // VK_FORMAT_R32G32B32A32_SFLOAT
        .load_dont_care => .{ .kind = .direct_vulkan, .vulkan_value = 1 }, // VK_ATTACHMENT_LOAD_OP_DONT_CARE
        .load_load => .{ .kind = .direct_vulkan, .vulkan_value = 0 }, // VK_ATTACHMENT_LOAD_OP_LOAD
        .load_clear => .{ .kind = .direct_vulkan, .vulkan_value = 2 }, // VK_ATTACHMENT_LOAD_OP_CLEAR
        .store_dont_care => .{ .kind = .direct_vulkan, .vulkan_value = 1 }, // VK_ATTACHMENT_STORE_OP_DONT_CARE
        .store_store => .{ .kind = .direct_vulkan, .vulkan_value = 0 }, // VK_ATTACHMENT_STORE_OP_STORE
        .primitive_point => .{ .kind = .direct_vulkan, .vulkan_value = 0 }, // VK_PRIMITIVE_TOPOLOGY_POINT_LIST
        .primitive_line => .{ .kind = .direct_vulkan, .vulkan_value = 1 }, // VK_PRIMITIVE_TOPOLOGY_LINE_LIST
        .primitive_line_strip => .{ .kind = .direct_vulkan, .vulkan_value = 2 }, // VK_PRIMITIVE_TOPOLOGY_LINE_STRIP
        .primitive_triangle => .{ .kind = .direct_vulkan, .vulkan_value = 3 }, // VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST
        .primitive_triangle_strip => .{ .kind = .direct_vulkan, .vulkan_value = 5 }, // VK_PRIMITIVE_TOPOLOGY_TRIANGLE_STRIP
        .device, .command_queue, .command_buffer, .render_command_encoder, .compute_command_encoder, .blit_command_encoder, .parallel_render_command_encoder, .render_pass_descriptor, .depth_attachment => .{ .kind = .native_metal },
    };
}

test "mapping policy keeps direct values separate from native lifetimes" {
    try @import("std").testing.expectEqual(@as(?u32, 9), entry(.r8_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 13), entry(.r8_uint).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 70), entry(.r16_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 74), entry(.r16_uint).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 76), entry(.r16_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 16), entry(.rg8_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 77), entry(.rg16_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 20), entry(.rg8_uint).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 83), entry(.rg16_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 98), entry(.r32_uint).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 99), entry(.r32_sint).vulkan_value);
    try @import("std").testing.expectEqual(Kind.direct_vulkan, entry(.bgra8_unorm).kind);
    try @import("std").testing.expectEqual(@as(?u32, 44), entry(.bgra8_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 100), entry(.r32_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 97), entry(.rgba16_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 91), entry(.rgba16_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 41), entry(.rgba8_uint).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 109), entry(.rgba32_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 103), entry(.rg32_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 101), entry(.rg32_uint).vulkan_value);
    try @import("std").testing.expectEqual(Kind.direct_vulkan, entry(.primitive_triangle_strip).kind);
    try @import("std").testing.expectEqual(@as(?u32, 5), entry(.primitive_triangle_strip).vulkan_value);
    try @import("std").testing.expectEqual(Kind.native_metal, entry(.command_buffer).kind);
    try @import("std").testing.expectEqual(@as(?u32, null), entry(.command_buffer).vulkan_value);
}

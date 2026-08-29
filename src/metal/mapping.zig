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
    rgba8_unorm,
    bgra8_unorm,
    r32_float,
    rgba16_float,
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
        .rgba8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 37 }, // VK_FORMAT_R8G8B8A8_UNORM
        .bgra8_unorm => .{ .kind = .direct_vulkan, .vulkan_value = 44 }, // VK_FORMAT_B8G8R8A8_UNORM
        .r32_float => .{ .kind = .direct_vulkan, .vulkan_value = 100 }, // VK_FORMAT_R32_SFLOAT
        .rgba16_float => .{ .kind = .direct_vulkan, .vulkan_value = 97 }, // VK_FORMAT_R16G16B16A16_SFLOAT
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
    try @import("std").testing.expectEqual(Kind.direct_vulkan, entry(.bgra8_unorm).kind);
    try @import("std").testing.expectEqual(@as(?u32, 44), entry(.bgra8_unorm).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 100), entry(.r32_float).vulkan_value);
    try @import("std").testing.expectEqual(@as(?u32, 97), entry(.rgba16_float).vulkan_value);
    try @import("std").testing.expectEqual(Kind.direct_vulkan, entry(.primitive_triangle_strip).kind);
    try @import("std").testing.expectEqual(@as(?u32, 5), entry(.primitive_triangle_strip).vulkan_value);
    try @import("std").testing.expectEqual(Kind.native_metal, entry(.command_buffer).kind);
    try @import("std").testing.expectEqual(@as(?u32, null), entry(.command_buffer).vulkan_value);
}

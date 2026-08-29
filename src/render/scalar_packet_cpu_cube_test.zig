// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Phase-9 differential gate: compare the packet scalar executor with the
//! existing cpu_cube reference renderer before any optimized kernel is added.

const std = @import("std");
const cube = @import("cpu_cube");
const pipeline = @import("cluster_pipeline.zig");
const prepared = @import("prepared_primitives.zig");
const packets = @import("scalar_packet.zig");

const width: u32 = 16;
const height: u32 = 16;
const pixel_count = width * height;
const uniform_bytes = 64 + 3 * 32;

fn putFloat(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn getFloat(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}

fn oldUniform(points: [3][2]f32, depth: f32) [uniform_bytes]u8 {
    var uniform = [_]u8{0} ** uniform_bytes;
    for (0..4) |column| putFloat(&uniform, (column * 4 + column) * 4, 1);
    for (points, 0..) |point, vertex| {
        const offset = 64 + vertex * 16;
        putFloat(&uniform, offset, point[0] / 8.0 - 1.0);
        putFloat(&uniform, offset + 4, point[1] / 8.0 - 1.0);
        putFloat(&uniform, offset + 8, depth);
        putFloat(&uniform, offset + 12, 1);
    }
    const attributes = 64 + 3 * 16;
    for (0..3) |vertex| {
        putFloat(&uniform, attributes + vertex * 16, 0);
        putFloat(&uniform, attributes + vertex * 16 + 4, 0);
    }
    return uniform;
}

fn clearOld(color: []u8, depth: []u8) void {
    @memset(color, 0);
    var offset: usize = 0;
    while (offset < depth.len) : (offset += 4) putFloat(depth, offset, 1);
}

fn oldMaterial(uniform: []const u8, texture: []const u8, sample_x: usize, sample_y: usize) u32 {
    var color = [_]u8{0} ** (pixel_count * 4);
    var depth = [_]u8{0} ** (pixel_count * 4);
    clearOld(&color, &depth);
    var counters = cube.Counters{};
    _ = cube.drawReferenceCounted(
        &color,
        &depth,
        width,
        height,
        uniform,
        texture,
        1,
        1,
        3,
        .{ .x = 0, .y = 0, .width = width, .height = height, .min_depth = 0, .max_depth = 1 },
        .{ .x = 0, .y = 0, .width = width, .height = height },
        &counters,
    );
    return std.mem.readInt(u32, color[(sample_y * width + sample_x) * 4 ..][0..4], .little);
}

test "prepared scalar packets match existing cpu_cube reference" {
    const points = [2][3][2]f32{
        .{ .{ 1, 1 }, .{ 7, 1 }, .{ 1, 7 } },
        .{ .{ 2, 2 }, .{ 8, 2 }, .{ 2, 8 } },
    };
    const depths = [2]f32{ 0.0, 0.0 };
    const textures = [2][4]u8{ .{ 33, 77, 121, 255 }, .{ 191, 83, 47, 255 } };
    var uniforms: [2][uniform_bytes]u8 = undefined;
    var sources: [2]prepared.SourceTriangle = undefined;
    var materials: [2]pipeline.MaterialId = undefined;
    for (0..2) |index| {
        uniforms[index] = oldUniform(points[index], depths[index]);
        materials[index] = oldMaterial(&uniforms[index], &textures[index], 3, 3);
        sources[index] = .{
            .positions = points[index],
            .depths = .{ depths[index], depths[index], depths[index] },
            .primitive_id = @intCast(index + 10),
            .material_id = materials[index],
        };
    }

    var old_color = [_]u8{0} ** (pixel_count * 4);
    var old_depth = [_]u8{0} ** (pixel_count * 4);
    clearOld(&old_color, &old_depth);
    var old_counters = cube.Counters{};
    for (0..2) |index| {
        var draw_counters = cube.Counters{};
        _ = cube.drawReferenceCounted(
            &old_color,
            &old_depth,
            width,
            height,
            &uniforms[index],
            &textures[index],
            1,
            1,
            3,
            .{ .x = 0, .y = 0, .width = width, .height = height, .min_depth = 0, .max_depth = 1 },
            .{ .x = 0, .y = 0, .width = width, .height = height },
            &draw_counters,
        );
        old_counters.triangles_submitted += draw_counters.triangles_submitted;
        old_counters.triangles_rasterized += draw_counters.triangles_rasterized;
        old_counters.fragments_tested += draw_counters.fragments_tested;
        old_counters.fragments_covered += draw_counters.fragments_covered;
        old_counters.depth_tests_passed += draw_counters.depth_tests_passed;
        old_counters.color_writes += draw_counters.color_writes;
    }

    var primitive_storage: [2]prepared.PreparedPrimitive = undefined;
    var batch_storage: [2]prepared.PreparedPrimitiveBatch = undefined;
    const prepared_result = try prepared.prepare(&sources, width, height, 64, .{ .primitives = &primitive_storage, .batches = &batch_storage });
    try std.testing.expectEqual(@as(usize, 2), prepared_result.primitive_count);

    const clusters = [2]pipeline.Cluster{
        .{ .id = 10, .draw_id = 0, .material_id = materials[0], .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 1, .min_y = 1, .max_x = 7, .max_y = 7 }, .best_depth = depths[0], .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } },
        .{ .id = 11, .draw_id = 1, .material_id = materials[1], .first_triangle = 1, .triangle_count = 1, .bounds = .{ .min_x = 2, .min_y = 2, .max_x = 8, .max_y = 8 }, .best_depth = depths[1], .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 } },
    };
    const ranges = [2]packets.PreparedCluster{
        .{ .first_primitive = 0, .primitive_count = 1 },
        .{ .first_primitive = 1, .primitive_count = 1 },
    };

    var macro_headers: [4]pipeline.MacrobinHeader = undefined;
    var macro_entries: [8]pipeline.MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    var visible = [_]bool{ true, true };
    _ = try pipeline.buildMacrobins(&clusters, &visible, width, height, 8, 8, &macro_headers, &macro_entries, &macro_cursors);
    var tile_headers: [16]pipeline.TileHeader = undefined;
    var tile_packets: [32]pipeline.TilePacket = undefined;
    var tile_cursors: [16]u32 = undefined;
    const tile_packet_count = try pipeline.buildTilePacketsFromMacrobins(&clusters, width, height, 8, 8, &macro_headers, &macro_entries, 4, 4, .less_equal, &tile_headers, &tile_packets, &tile_cursors);

    var reference_color: [pixel_count]u32 = undefined;
    var reference_depth: [pixel_count]f32 = undefined;
    var reference_visibility: [pixel_count]pipeline.Visibility = undefined;
    var packet_color: [pixel_count]u32 = undefined;
    var packet_depth: [pixel_count]f32 = undefined;
    var packet_visibility: [pixel_count]pipeline.Visibility = undefined;
    const reference = try packets.Surface.init(&reference_color, &reference_depth, &reference_visibility, width, height, .less_equal);
    const packet = try packets.Surface.init(&packet_color, &packet_depth, &packet_visibility, width, height, .less_equal);
    reference.clear(0, 1);
    packet.clear(0, 1);
    var reference_counters = packets.Counters{};
    var packet_counters = packets.Counters{};
    var seen_clusters: [2]bool = undefined;
    const ordered = [_]u32{ 0, 1 };
    try packets.renderReference(reference, &primitive_storage, &ranges, &ordered, &reference_counters);
    try packets.renderPackets(packet, &primitive_storage, &ranges, 4, 4, &tile_headers, tile_packets[0..tile_packet_count], &seen_clusters, &packet_counters);

    try std.testing.expectEqual(reference_counters, packet_counters);
    try std.testing.expectEqual(@as(u64, old_counters.triangles_submitted), @as(u64, 2));
    try std.testing.expectEqual(old_counters.fragments_tested, packet_counters.samples_tested);
    try std.testing.expectEqual(old_counters.fragments_covered, packet_counters.samples_covered);
    try std.testing.expectEqual(old_counters.depth_tests_passed, packet_counters.depth_tests_passed);
    try std.testing.expectEqual(old_counters.color_writes, packet_counters.color_writes);

    for (0..pixel_count) |index| {
        const old_color_word = std.mem.readInt(u32, old_color[index * 4 ..][0..4], .little);
        const old_depth_value = getFloat(&old_depth, index * 4);
        try std.testing.expectEqual(old_color_word, packet_color[index]);
        try std.testing.expectEqual(old_depth_value, packet_depth[index]);
        try std.testing.expectEqual(packet_color[index], reference_color[index]);
        try std.testing.expectEqual(packet_depth[index], reference_depth[index]);
    }
    try std.testing.expectEqual(@as(u32, 11), packet_visibility[3 * width + 3].primitive_id);
    try std.testing.expectEqual(materials[1], packet_visibility[3 * width + 3].material_id);
}

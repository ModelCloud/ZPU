// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Scalar packet execution gate for the Mosaic renderer.
//!
//! This module deliberately has no vector or ISA-specific implementation. It
//! is the differential oracle for the planning redesign: the same prepared
//! primitives are rendered once in ordered source form and once through the
//! ordered tile packet stream. The two surfaces must be identical before an
//! optimized executor is allowed to replace this path.

const std = @import("std");
const pipeline = @import("mosaic_pipeline.zig");
const prepared = @import("prepared_primitives.zig");

pub const Surface = struct {
    color: []u32,
    depth: []f32,
    visibility: []pipeline.Visibility,
    width: u32,
    height: u32,
    compare: pipeline.DepthCompare,

    pub fn init(color: []u32, depth: []f32, visibility: []pipeline.Visibility, width: u32, height: u32, compare: pipeline.DepthCompare) !Surface {
        if (width == 0 or height == 0) return error.InvalidSurface;
        const count64 = @as(u64, width) * @as(u64, height);
        if (count64 > std.math.maxInt(usize)) return error.InvalidSurface;
        const count: usize = @intCast(count64);
        if (color.len < count or depth.len < count or visibility.len < count) return error.InvalidSurface;
        return .{ .color = color[0..count], .depth = depth[0..count], .visibility = visibility[0..count], .width = width, .height = height, .compare = compare };
    }

    pub fn clear(self: Surface, color: u32, depth: f32) void {
        @memset(self.color, color);
        @memset(self.depth, depth);
        @memset(self.visibility, pipeline.invalid_visibility);
    }

    fn writeIfPasses(self: Surface, x: u32, y: u32, depth: f32, value: pipeline.Visibility, color: u32, counters: *Counters) void {
        if (x >= self.width or y >= self.height or !std.math.isFinite(depth)) return;
        const index = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        const passes = switch (self.compare) {
            .less => depth < self.depth[index],
            .less_equal => depth <= self.depth[index],
            .greater => depth > self.depth[index],
            .greater_equal => depth >= self.depth[index],
        };
        if (!passes) return;
        self.depth[index] = depth;
        self.visibility[index] = value;
        self.color[index] = color;
        counters.depth_tests_passed += 1;
        counters.color_writes += 1;
    }
};

pub const PreparedCluster = struct {
    first_primitive: u32,
    primitive_count: u32,
};

pub const Counters = struct {
    primitive_tests: u64 = 0,
    samples_tested: u64 = 0,
    samples_covered: u64 = 0,
    depth_tests_passed: u64 = 0,
    color_writes: u64 = 0,
};

pub const Error = error{ InvalidSurface, InvalidRange, InvalidPacketStream, CountOverflow };

fn rangeEnd(first: u32, count: u32) ?usize {
    const start = @as(usize, first);
    const length = @as(usize, count);
    if (start > std.math.maxInt(usize) - length) return null;
    return start + length;
}

fn intersect(a: pipeline.ScreenBounds, b: pipeline.ScreenBounds) pipeline.ScreenBounds {
    return .{
        .min_x = @max(a.min_x, b.min_x),
        .min_y = @max(a.min_y, b.min_y),
        .max_x = @min(a.max_x, b.max_x),
        .max_y = @min(a.max_y, b.max_y),
    };
}

fn rasterPrimitive(surface: Surface, primitive: prepared.PreparedPrimitive, clip: pipeline.ScreenBounds, counters: *Counters) void {
    const bounds = intersect(primitive.bounds, clip).clipped(surface.width, surface.height);
    if (bounds.empty()) return;
    const color = primitive.material_id;
    const value = pipeline.Visibility{ .primitive_id = primitive.primitive_id, .material_id = primitive.material_id };
    var y = bounds.min_y;
    while (y < bounds.max_y) : (y += 1) {
        var x = bounds.min_x;
        while (x < bounds.max_x) : (x += 1) {
            counters.samples_tested += 1;
            const sample_x = @as(f32, @floatFromInt(x)) + 0.5;
            const sample_y = @as(f32, @floatFromInt(y)) + 0.5;
            if (!primitive.covers(sample_x, sample_y)) continue;
            counters.samples_covered += 1;
            surface.writeIfPasses(x, y, primitive.depthAt(sample_x, sample_y), value, color, counters);
        }
    }
}

fn renderCluster(surface: Surface, primitives: []const prepared.PreparedPrimitive, ranges: []const PreparedCluster, cluster_index: u32, clip: pipeline.ScreenBounds, count_setup: bool, counters: *Counters) Error!void {
    const index = @as(usize, cluster_index);
    if (index >= ranges.len) return error.InvalidRange;
    const range = ranges[index];
    const end = rangeEnd(range.first_primitive, range.primitive_count) orelse return error.InvalidRange;
    if (end > primitives.len) return error.InvalidRange;
    for (primitives[@as(usize, range.first_primitive)..end]) |primitive| {
        if (count_setup) counters.primitive_tests += 1;
        rasterPrimitive(surface, primitive, clip, counters);
    }
}

/// Reference execution in the API's already-established ordered cluster
/// stream. This is intentionally scalar and does not consume packet metadata.
pub fn renderReference(surface: Surface, primitives: []const prepared.PreparedPrimitive, ranges: []const PreparedCluster, ordered_cluster_indices: []const u32, counters: *Counters) Error!void {
    for (ordered_cluster_indices) |cluster_index| {
        try renderCluster(surface, primitives, ranges, cluster_index, .{ .min_x = 0, .min_y = 0, .max_x = surface.width, .max_y = surface.height }, true, counters);
    }
}

/// Execute the same prepared geometry through the tile packet stream. Tile
/// rectangles are disjoint, so each sample is visited once; packet ordering
/// remains observable for equal-depth inclusive tests within each tile.
pub fn renderPackets(surface: Surface, primitives: []const prepared.PreparedPrimitive, ranges: []const PreparedCluster, tile_w: u32, tile_h: u32, headers: []const pipeline.TileHeader, packets: []const pipeline.TilePacket, seen_clusters: []bool, counters: *Counters) Error!void {
    if (tile_w == 0 or tile_h == 0) return error.InvalidPacketStream;
    if (seen_clusters.len < ranges.len) return error.InvalidPacketStream;
    @memset(seen_clusters[0..ranges.len], false);
    const columns = (@as(usize, surface.width) + tile_w - 1) / tile_w;
    const rows = (@as(usize, surface.height) + tile_h - 1) / tile_h;
    const tile_count = columns * rows;
    if (headers.len < tile_count) return error.InvalidPacketStream;
    for (headers[0..tile_count], 0..) |header, tile_index| {
        const begin = @as(usize, header.offset);
        const end = rangeEnd(header.offset, header.count) orelse return error.InvalidPacketStream;
        if (end > packets.len) return error.InvalidPacketStream;
        const tile_x = tile_index % columns;
        const tile_y = tile_index / columns;
        const clip = pipeline.ScreenBounds{
            .min_x = @intCast(tile_x * @as(usize, tile_w)),
            .min_y = @intCast(tile_y * @as(usize, tile_h)),
            .max_x = @min(surface.width, @as(u32, @intCast((tile_x + 1) * @as(usize, tile_w)))),
            .max_y = @min(surface.height, @as(u32, @intCast((tile_y + 1) * @as(usize, tile_h)))),
        };
        for (packets[begin..end]) |packet| {
            if (packet.source_cluster_index >= ranges.len) return error.InvalidPacketStream;
            const cluster_index = @as(usize, packet.source_cluster_index);
            const count_setup = !seen_clusters[cluster_index];
            seen_clusters[cluster_index] = true;
            try renderCluster(surface, primitives, ranges, packet.source_cluster_index, clip, count_setup, counters);
        }
    }
}

fn packetBefore(a: pipeline.TilePacket, b: pipeline.TilePacket) bool {
    if (pipeline.OrderKey.less(a.order_key, b.order_key)) return true;
    if (pipeline.OrderKey.less(b.order_key, a.order_key)) return false;
    return a.source_cluster_index < b.source_cluster_index;
}

fn clusterTileRange(cluster: pipeline.Cluster, width: u32, height: u32, tile_w: u32, tile_h: u32) ?pipeline.TileRect {
    const bounds = cluster.bounds.clipped(width, height);
    if (bounds.empty()) return null;
    const max_x = @as(usize, bounds.max_x);
    const max_y = @as(usize, bounds.max_y);
    return .{
        .min_x = bounds.min_x / tile_w,
        .min_y = bounds.min_y / tile_h,
        .max_x = @intCast((max_x + tile_w - 1) / tile_w),
        .max_y = @intCast((max_y + tile_h - 1) / tile_h),
    };
}

fn tileInRange(tile_x: u32, tile_y: u32, range: pipeline.TileRect) bool {
    return tile_x >= range.min_x and tile_x < range.max_x and tile_y >= range.min_y and tile_y < range.max_y;
}

fn physicalPacketTouchesTile(packet: pipeline.TilePacket, clusters: []const pipeline.Cluster, tile_x: u32, tile_y: u32, width: u32, height: u32, tile_w: u32, tile_h: u32) bool {
    const range = clusterTileRange(clusters[packet.source_cluster_index], width, height, tile_w, tile_h) orelse return false;
    return tileInRange(tile_x, tile_y, range);
}

/// Execute the compact physical packet streams without expanding MACRO or
/// GLOBAL work into persistent per-tile records. Each tile merges the three
/// already ordered producer streams, so strict Vulkan order remains intact
/// while broad work stays physically compact in memory.
pub fn renderPhysicalPackets(
    surface: Surface,
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    tile_w: u32,
    tile_h: u32,
    local_packets: []const pipeline.LocalPacket,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
    seen_clusters: []bool,
    counters: *Counters,
) Error!void {
    if (tile_w == 0 or tile_h == 0 or ranges.len != clusters.len or seen_clusters.len < ranges.len) return error.InvalidPacketStream;
    const columns = (@as(usize, surface.width) + tile_w - 1) / tile_w;
    const rows = (@as(usize, surface.height) + tile_h - 1) / tile_h;
    const tile_count = columns * rows;
    if (columns == 0 or rows == 0 or tile_count > std.math.maxInt(u32)) return error.InvalidPacketStream;

    // Validate the compact stream once. The hot tile merge below can then
    // use direct range checks without turning malformed packet data into an
    // out-of-bounds access.
    for (local_packets) |entry| {
        if (entry.packet.extent != .local or entry.packet.source_cluster_index >= clusters.len or entry.tile_x >= columns or entry.tile_y >= rows) return error.InvalidPacketStream;
    }
    for (macro_packets) |entry| {
        if (entry.packet.extent != .macro or entry.packet.source_cluster_index >= clusters.len or
            entry.tile_range.min_x >= entry.tile_range.max_x or entry.tile_range.min_y >= entry.tile_range.max_y or
            entry.tile_range.max_x > columns or entry.tile_range.max_y > rows) return error.InvalidPacketStream;
    }
    for (global_packets) |entry| if (entry.packet.extent != .global or entry.packet.source_cluster_index >= clusters.len) return error.InvalidPacketStream;

    @memset(seen_clusters[0..ranges.len], false);
    for (0..rows) |tile_y| for (0..columns) |tile_x| {
        const clip = pipeline.ScreenBounds{
            .min_x = @intCast(tile_x * @as(usize, tile_w)),
            .min_y = @intCast(tile_y * @as(usize, tile_h)),
            .max_x = @min(surface.width, @as(u32, @intCast((tile_x + 1) * @as(usize, tile_w)))),
            .max_y = @min(surface.height, @as(u32, @intCast((tile_y + 1) * @as(usize, tile_h)))),
        };
        var local_index: usize = 0;
        var macro_index: usize = 0;
        var global_index: usize = 0;
        while (true) {
            while (local_index < local_packets.len and
                (local_packets[local_index].tile_x != tile_x or local_packets[local_index].tile_y != tile_y)) local_index += 1;
            while (macro_index < macro_packets.len and
                !tileInRange(@intCast(tile_x), @intCast(tile_y), macro_packets[macro_index].tile_range)) macro_index += 1;
            while (global_index < global_packets.len and
                !physicalPacketTouchesTile(global_packets[global_index].packet, clusters, @intCast(tile_x), @intCast(tile_y), surface.width, surface.height, tile_w, tile_h)) global_index += 1;

            if (local_index == local_packets.len and macro_index == macro_packets.len and global_index == global_packets.len) break;
            const local_packet = if (local_index < local_packets.len) local_packets[local_index].packet else null;
            const macro_packet = if (macro_index < macro_packets.len) macro_packets[macro_index].packet else null;
            const global_packet = if (global_index < global_packets.len) global_packets[global_index].packet else null;

            const selected = if (local_packet) |candidate| blk: {
                if (macro_packet) |other| if (packetBefore(other, candidate)) {
                    if (global_packet) |third| break :blk if (packetBefore(third, other)) @as(u2, 2) else @as(u2, 1);
                    break :blk @as(u2, 1);
                };
                if (global_packet) |other| if (packetBefore(other, candidate)) break :blk @as(u2, 2);
                break :blk @as(u2, 0);
            } else if (macro_packet) |candidate| blk: {
                if (global_packet) |other| if (packetBefore(other, candidate)) break :blk @as(u2, 2);
                break :blk @as(u2, 1);
            } else @as(u2, 2);

            const selected_packet = switch (selected) {
                0 => local_packets[local_index].packet,
                1 => macro_packets[macro_index].packet,
                else => global_packets[global_index].packet,
            };
            const cluster_index = @as(usize, selected_packet.source_cluster_index);
            const count_setup = !seen_clusters[cluster_index];
            seen_clusters[cluster_index] = true;
            try renderCluster(surface, primitives, ranges, selected_packet.source_cluster_index, clip, count_setup, counters);
            switch (selected) {
                0 => local_index += 1,
                1 => macro_index += 1,
                else => global_index += 1,
            }
        }
    };
}

test "scalar packet path is byte exact against ordered reference" {
    const source = [_]prepared.SourceTriangle{
        .{ .positions = .{ .{ 0.5, 0.5 }, .{ 6.5, 0.5 }, .{ 0.5, 6.5 } }, .depths = .{ 0.4, 0.4, 0.4 }, .primitive_id = 100, .material_id = 0x11 },
        .{ .positions = .{ .{ 1.5, 1.5 }, .{ 7.5, 1.5 }, .{ 1.5, 7.5 } }, .depths = .{ 0.2, 0.2, 0.2 }, .primitive_id = 200, .material_id = 0x22 },
    };
    var prepared_primitives: [2]prepared.PreparedPrimitive = undefined;
    var prepared_batches: [2]prepared.PreparedPrimitiveBatch = undefined;
    const preparation = try prepared.prepare(&source, 8, 8, 64, .{ .primitives = &prepared_primitives, .batches = &prepared_batches });
    try std.testing.expectEqual(@as(usize, 2), preparation.primitive_count);

    const clusters = [_]pipeline.Cluster{
        .{ .id = 20, .draw_id = 0, .material_id = 0x22, .first_triangle = 1, .triangle_count = 1, .bounds = .{ .min_x = 1, .min_y = 1, .max_x = 8, .max_y = 8 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 } },
        .{ .id = 10, .draw_id = 0, .material_id = 0x11, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 7, .max_y = 7 }, .best_depth = 0.4, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 } },
    };
    const ranges = [_]PreparedCluster{
        .{ .first_primitive = 1, .primitive_count = 1 },
        .{ .first_primitive = 0, .primitive_count = 1 },
    };
    var macro_headers: [1]pipeline.MacrobinHeader = undefined;
    var macro_entries: [2]pipeline.MacrobinRef = undefined;
    var macro_cursors: [1]u32 = undefined;
    const visible = [_]bool{ true, true };
    _ = try pipeline.buildMacrobins(&clusters, &visible, 8, 8, 8, 8, &macro_headers, &macro_entries, &macro_cursors);
    var tile_headers: [4]pipeline.TileHeader = undefined;
    var tile_packets: [8]pipeline.TilePacket = undefined;
    var tile_cursors: [4]u32 = undefined;
    const packet_count = try pipeline.buildTilePacketsFromMacrobins(&clusters, 8, 8, 8, 8, &macro_headers, &macro_entries, 4, 4, .less_equal, &tile_headers, &tile_packets, &tile_cursors);

    var reference_color: [64]u32 = undefined;
    var packet_color: [64]u32 = undefined;
    var reference_depth: [64]f32 = undefined;
    var packet_depth: [64]f32 = undefined;
    var reference_visibility: [64]pipeline.Visibility = undefined;
    var packet_visibility: [64]pipeline.Visibility = undefined;
    const reference = try Surface.init(&reference_color, &reference_depth, &reference_visibility, 8, 8, .less_equal);
    const packet = try Surface.init(&packet_color, &packet_depth, &packet_visibility, 8, 8, .less_equal);
    reference.clear(0, 1);
    packet.clear(0, 1);
    var reference_counters = Counters{};
    var packet_counters = Counters{};
    var seen_clusters: [2]bool = undefined;
    // The packet stream's OrderKey puts cluster 1 before cluster 0 even
    // though producer storage is deliberately shuffled.
    const ordered = [_]u32{ 1, 0 };
    try renderReference(reference, &prepared_primitives, &ranges, &ordered, &reference_counters);
    try renderPackets(packet, &prepared_primitives, &ranges, 4, 4, &tile_headers, tile_packets[0..packet_count], &seen_clusters, &packet_counters);
    try std.testing.expectEqualSlices(u32, &reference_color, &packet_color);
    try std.testing.expectEqualSlices(f32, &reference_depth, &packet_depth);
    try std.testing.expectEqualSlices(pipeline.Visibility, &reference_visibility, &packet_visibility);
    try std.testing.expectEqual(reference_counters, packet_counters);
}

test "scalar packet traversal visits prepared setup once across tile fanout" {
    const source = [_]prepared.SourceTriangle{.{ .positions = .{ .{ 0, 0 }, .{ 16, 0 }, .{ 0, 16 } }, .depths = .{ 0.1, 0.1, 0.1 }, .primitive_id = 1, .material_id = 7 }};
    var primitives: [1]prepared.PreparedPrimitive = undefined;
    var batches: [1]prepared.PreparedPrimitiveBatch = undefined;
    const result = try prepared.prepare(&source, 16, 16, 64, .{ .primitives = &primitives, .batches = &batches });
    try std.testing.expectEqual(@as(usize, 1), result.primitive_count);
    try std.testing.expectEqual(@as(usize, 1), result.batch_count);
    // The same prepared object is intentionally reused for every packet. A
    // cluster spanning all 16 tiles cannot increase this setup count.
    const cluster = pipeline.Cluster{ .id = 1, .draw_id = 0, .material_id = 7, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } };
    var macro_headers: [1]pipeline.MacrobinHeader = undefined;
    var macro_entries: [1]pipeline.MacrobinRef = undefined;
    var macro_cursors: [1]u32 = undefined;
    _ = try pipeline.buildMacrobins(&[_]pipeline.Cluster{cluster}, null, 16, 16, 16, 16, &macro_headers, &macro_entries, &macro_cursors);
    var headers: [16]pipeline.TileHeader = undefined;
    var packets: [16]pipeline.TilePacket = undefined;
    var cursors: [16]u32 = undefined;
    const count = try pipeline.buildTilePacketsFromMacrobins(&[_]pipeline.Cluster{cluster}, 16, 16, 16, 16, &macro_headers, &macro_entries, 4, 4, .less, &headers, &packets, &cursors);
    try std.testing.expectEqual(@as(usize, 16), count);
}

test "physical packet streams match expanded tile execution" {
    const source = [_]prepared.SourceTriangle{
        .{ .positions = .{ .{ 0.5, 0.5 }, .{ 3.5, 0.5 }, .{ 0.5, 3.5 } }, .depths = .{ 0.6, 0.6, 0.6 }, .primitive_id = 1, .material_id = 0x11 },
        .{ .positions = .{ .{ 5.5, 5.5 }, .{ 10.5, 5.5 }, .{ 5.5, 10.5 } }, .depths = .{ 0.4, 0.4, 0.4 }, .primitive_id = 2, .material_id = 0x22 },
        .{ .positions = .{ .{ 11.5, 11.5 }, .{ 15.5, 11.5 }, .{ 11.5, 15.5 } }, .depths = .{ 0.2, 0.2, 0.2 }, .primitive_id = 3, .material_id = 0x33 },
    };
    var prepared_primitives: [3]prepared.PreparedPrimitive = undefined;
    var prepared_batches: [3]prepared.PreparedPrimitiveBatch = undefined;
    _ = try prepared.prepare(&source, 20, 20, 16, .{ .primitives = &prepared_primitives, .batches = &prepared_batches });
    const ranges = [_]PreparedCluster{
        .{ .first_primitive = 0, .primitive_count = 1 },
        .{ .first_primitive = 1, .primitive_count = 1 },
        .{ .first_primitive = 2, .primitive_count = 1 },
    };
    const clusters = [_]pipeline.Cluster{
        .{ .id = 1, .draw_id = 0, .material_id = 0x11, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.6, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } },
        .{ .id = 2, .draw_id = 0, .material_id = 0x22, .first_triangle = 1, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .best_depth = 0.4, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 } },
        .{ .id = 3, .draw_id = 0, .material_id = 0x33, .first_triangle = 2, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 20, .max_y = 20 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 } },
    };
    var physical_local: [16]pipeline.LocalPacket = undefined;
    var physical_macro: [3]pipeline.MacroPacket = undefined;
    var physical_global: [3]pipeline.GlobalPacket = undefined;
    const physical_count = try pipeline.buildPhysicalPackets(&clusters, null, 20, 20, 1, 1, .less_equal, &physical_local, &physical_macro, &physical_global);
    try std.testing.expectEqual(@as(usize, 16), physical_count.local);
    try std.testing.expectEqual(@as(usize, 1), physical_count.macro);
    try std.testing.expectEqual(@as(usize, 1), physical_count.global);

    var macro_headers: [4]pipeline.MacrobinHeader = undefined;
    var macro_entries: [8]pipeline.MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    const macro_ref_count = try pipeline.buildMacrobins(&clusters, null, 20, 20, 16, 16, &macro_headers, &macro_entries, &macro_cursors);
    var tile_headers: [400]pipeline.TileHeader = undefined;
    var tile_packets: [2048]pipeline.TilePacket = undefined;
    var tile_cursors: [400]u32 = undefined;
    const tile_packet_count = try pipeline.buildTilePacketsFromMacrobins(&clusters, 20, 20, 16, 16, &macro_headers, macro_entries[0..macro_ref_count], 1, 1, .less_equal, &tile_headers, &tile_packets, &tile_cursors);

    var reference_color: [400]u32 = undefined;
    var expanded_color: [400]u32 = undefined;
    var physical_color: [400]u32 = undefined;
    var reference_depth: [400]f32 = undefined;
    var expanded_depth: [400]f32 = undefined;
    var physical_depth: [400]f32 = undefined;
    var reference_visibility: [400]pipeline.Visibility = undefined;
    var expanded_visibility: [400]pipeline.Visibility = undefined;
    var physical_visibility: [400]pipeline.Visibility = undefined;
    const reference = try Surface.init(&reference_color, &reference_depth, &reference_visibility, 20, 20, .less_equal);
    const expanded = try Surface.init(&expanded_color, &expanded_depth, &expanded_visibility, 20, 20, .less_equal);
    const physical = try Surface.init(&physical_color, &physical_depth, &physical_visibility, 20, 20, .less_equal);
    reference.clear(0, 1);
    expanded.clear(0, 1);
    physical.clear(0, 1);
    var reference_counters = Counters{};
    var expanded_counters = Counters{};
    var physical_counters = Counters{};
    const ordered = [_]u32{ 0, 1, 2 };
    var expanded_seen: [3]bool = undefined;
    var physical_seen: [3]bool = undefined;
    try renderReference(reference, &prepared_primitives, &ranges, &ordered, &reference_counters);
    try renderPackets(expanded, &prepared_primitives, &ranges, 1, 1, &tile_headers, tile_packets[0..tile_packet_count], &expanded_seen, &expanded_counters);
    try renderPhysicalPackets(physical, &prepared_primitives, &ranges, &clusters, 1, 1, physical_local[0..physical_count.local], physical_macro[0..physical_count.macro], physical_global[0..physical_count.global], &physical_seen, &physical_counters);
    try std.testing.expectEqualSlices(u32, &reference_color, &expanded_color);
    try std.testing.expectEqualSlices(u32, &reference_color, &physical_color);
    try std.testing.expectEqualSlices(f32, &reference_depth, &expanded_depth);
    try std.testing.expectEqualSlices(f32, &reference_depth, &physical_depth);
    try std.testing.expectEqualSlices(pipeline.Visibility, &reference_visibility, &expanded_visibility);
    try std.testing.expectEqualSlices(pipeline.Visibility, &reference_visibility, &physical_visibility);
    try std.testing.expectEqual(reference_counters, expanded_counters);
    try std.testing.expectEqual(reference_counters, physical_counters);
}

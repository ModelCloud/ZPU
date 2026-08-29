// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cluster = @import("cluster_pipeline.zig");

/// Frontends converge on this coarse clustered submission. Vulkan lowering can
/// construct it internally; a future native API can submit the same shape
/// directly without rebuilding a triangle-by-triangle queue.
pub const Submission = struct {
    clusters: []const cluster.Cluster,
    sequence_base: u64 = 0,
};

pub const Config = struct {
    macro_w: u32 = 256,
    macro_h: u32 = 256,
    tile_w: u32,
    tile_h: u32,
};

/// All high-rate storage is caller-owned. This keeps planning deterministic,
/// lets the device allocate arenas once, and avoids per-cluster/per-tile heap
/// traffic during a frame.
pub const Scratch = struct {
    hzb_values: []f32,
    hzb_levels: []cluster.HzbLevel,
    visible: []bool,
    macro_headers: []cluster.MacrobinHeader,
    macro_entries: []cluster.MacrobinRef,
    macro_cursors: []u32,
    tile_headers: []cluster.TileHeader,
    tile_packets: []cluster.TilePacket,
    tile_cursors: []u32,
};

pub const Plan = struct {
    hzb: cluster.Hzb,
    visible_count: usize,
    macro_ref_count: usize,
    tile_packet_count: usize,
};

pub const Error = cluster.HzbError || cluster.BinError || error{
    VisibleStorageTooSmall,
};

/// First executable planning backbone:
///
/// depth -> HZB -> cluster cull -> visible macrobins -> ordered tile packets.
///
/// Raster execution and material shading consume this plan in later stages;
/// this function intentionally stops before triangle expansion.
pub fn buildPlan(
    submission: Submission,
    depth: []const f32,
    width: u32,
    height: u32,
    config: Config,
    scratch: Scratch,
) Error!Plan {
    if (scratch.visible.len < submission.clusters.len) return error.VisibleStorageTooSmall;
    const hzb = try cluster.Hzb.build(depth, width, height, scratch.hzb_values, scratch.hzb_levels);
    const visible = scratch.visible[0..submission.clusters.len];
    const visible_count = try cluster.cullClustersHzb(submission.clusters, hzb, visible);
    const macro_ref_count = try cluster.buildMacrobins(
        submission.clusters,
        visible,
        width,
        height,
        config.macro_w,
        config.macro_h,
        scratch.macro_headers,
        scratch.macro_entries,
        scratch.macro_cursors,
    );
    const tile_packet_count = try cluster.buildTilePackets(
        submission.clusters,
        visible,
        submission.sequence_base,
        width,
        height,
        config.tile_w,
        config.tile_h,
        scratch.tile_headers,
        scratch.tile_packets,
        scratch.tile_cursors,
    );
    return .{
        .hzb = hzb,
        .visible_count = visible_count,
        .macro_ref_count = macro_ref_count,
        .tile_packet_count = tile_packet_count,
    };
}

test "clustered backend plans HZB culling through tile packets" {
    const depth = [_]f32{
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
    };
    const clusters = [_]cluster.Cluster{
        .{ .id = 10, .draw_id = 3, .material_id = 5, .first_triangle = 0, .triangle_count = 64, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .nearest_depth = 0.1 },
        .{ .id = 11, .draw_id = 3, .material_id = 5, .first_triangle = 64, .triangle_count = 64, .bounds = .{ .min_x = 2, .min_y = 2, .max_x = 4, .max_y = 4 }, .nearest_depth = 0.9 },
    };

    var hzb_values: [21]f32 = undefined;
    var hzb_levels: [3]cluster.HzbLevel = undefined;
    var visible: [2]bool = undefined;
    var macro_headers: [4]cluster.MacrobinHeader = undefined;
    var macro_entries: [8]cluster.MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    var tile_headers: [4]cluster.TileHeader = undefined;
    var tile_packets: [8]cluster.TilePacket = undefined;
    var tile_cursors: [4]u32 = undefined;

    const plan = try buildPlan(
        .{ .clusters = &clusters, .sequence_base = 100 },
        &depth,
        4,
        4,
        .{ .macro_w = 2, .macro_h = 2, .tile_w = 2, .tile_h = 2 },
        .{
            .hzb_values = &hzb_values,
            .hzb_levels = &hzb_levels,
            .visible = &visible,
            .macro_headers = &macro_headers,
            .macro_entries = &macro_entries,
            .macro_cursors = &macro_cursors,
            .tile_headers = &tile_headers,
            .tile_packets = &tile_packets,
            .tile_cursors = &tile_cursors,
        },
    );

    try std.testing.expectEqual(@as(usize, 1), plan.visible_count);
    try std.testing.expect(visible[0]);
    try std.testing.expect(!visible[1]);
    try std.testing.expectEqual(@as(usize, 1), plan.macro_ref_count);
    try std.testing.expectEqual(@as(usize, 1), plan.tile_packet_count);
    try std.testing.expectEqual(@as(cluster.ClusterId, 10), tile_packets[0].cluster_id);
    try std.testing.expectEqual(@as(u64, 100), tile_packets[0].sequence);
}

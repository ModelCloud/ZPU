// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cluster = @import("cluster_pipeline.zig");

/// Both frontends lower into the same coarse representation. Supplying a
/// hierarchy lets the planner reject whole subtrees before leaf-cluster tests;
/// an empty hierarchy retains the flat compatibility path.
pub const Submission = struct {
    clusters: []const cluster.Cluster,
    nodes: []const cluster.ClusterNode = &.{},
    roots: []const u32 = &.{},
};

pub const Config = struct {
    macro_w: u32 = 256,
    macro_h: u32 = 256,
    tile_w: u32,
    tile_h: u32,
    hzb: cluster.HzbPolicy,
};

pub const Scratch = struct {
    hzb_values: []f32,
    hzb_levels: []cluster.HzbLevel,
    visible: []bool,
    hierarchy_stack: []u32,
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

pub const Error = cluster.HzbError || cluster.BinError || error{ VisibleStorageTooSmall };

pub const Requirements = struct {
    hzb_values: usize,
    hzb_levels: usize,
    visible: usize,
    hierarchy_stack: usize,
    macro_headers: usize,
    macro_refs_upper_bound: usize,
    tile_headers: usize,
};

/// Exact fixed-size requirements plus a conservative macro-reference upper
/// bound. Tile packet capacity is data-dependent after macrobins are built;
/// callers can conservatively reserve macro_refs * tiles_per_macro.
pub fn requirements(submission: Submission, width: u32, height: u32, config: Config) Error!Requirements {
    const macro_headers = try cluster.requiredGridHeaders(width, height, config.macro_w, config.macro_h);
    const tile_headers = try cluster.requiredGridHeaders(width, height, config.tile_w, config.tile_h);
    return .{
        .hzb_values = try cluster.hzbValueCount(width, height),
        .hzb_levels = cluster.maxHzbLevels(width, height),
        .visible = submission.clusters.len,
        .hierarchy_stack = submission.nodes.len + submission.roots.len,
        .macro_headers = macro_headers,
        .macro_refs_upper_bound = try cluster.requiredMacroReferencesUpperBound(submission.clusters, null, width, height, config.macro_w, config.macro_h),
        .tile_headers = tile_headers,
    };
}

/// depth -> validated HZB -> hierarchy/cluster cull -> visible macrobins ->
/// ordered tile packets. Tile construction consumes the macrobins rather than
/// rescanning the original cluster slice.
pub fn buildPlan(submission: Submission, depth: []const f32, width: u32, height: u32, config: Config, scratch: Scratch) Error!Plan {
    if (scratch.visible.len < submission.clusters.len) return error.VisibleStorageTooSmall;
    const hzb = try cluster.Hzb.build(depth, width, height, config.hzb, scratch.hzb_values, scratch.hzb_levels);
    const visible = scratch.visible[0..submission.clusters.len];
    const visible_count = if (submission.nodes.len != 0 or submission.roots.len != 0)
        try cluster.cullHierarchyHzb(submission.nodes, submission.roots, submission.clusters, hzb, visible, scratch.hierarchy_stack)
    else
        try cluster.cullClustersHzb(submission.clusters, hzb, visible);

    const macro_ref_count = try cluster.buildMacrobins(submission.clusters, visible, width, height, config.macro_w, config.macro_h, scratch.macro_headers, scratch.macro_entries, scratch.macro_cursors);
    const tile_packet_count = try cluster.buildTilePacketsFromMacrobins(
        submission.clusters,
        width,
        height,
        config.macro_w,
        config.macro_h,
        scratch.macro_headers,
        scratch.macro_entries[0..macro_ref_count],
        config.tile_w,
        config.tile_h,
        scratch.tile_headers,
        scratch.tile_packets,
        scratch.tile_cursors,
    );
    return .{ .hzb = hzb, .visible_count = visible_count, .macro_ref_count = macro_ref_count, .tile_packet_count = tile_packet_count };
}

test "clustered backend plans hierarchy through macrobins into ordered tiles" {
    const depth = [_]f32{
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
        0.2, 0.2, 0.2, 0.2,
    };
    const clusters = [_]cluster.Cluster{
        .{ .id = 10, .draw_id = 3, .material_id = 5, .first_triangle = 0, .triangle_count = 64, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 }, .estimated_covered_samples = 64 },
        .{ .id = 11, .draw_id = 3, .material_id = 5, .first_triangle = 64, .triangle_count = 64, .bounds = .{ .min_x = 2, .min_y = 2, .max_x = 4, .max_y = 4 }, .best_depth = 0.9, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 }, .estimated_covered_samples = 64 },
    };
    const nodes = [_]cluster.ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .first_child = 1, .child_count = 2 },
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .first_cluster = 0, .cluster_count = 1 },
        .{ .bounds = .{ .min_x = 2, .min_y = 2, .max_x = 4, .max_y = 4 }, .best_depth = 0.9, .first_cluster = 1, .cluster_count = 1 },
    };
    const roots = [_]u32{0};

    var hzb_values: [21]f32 = undefined;
    var hzb_levels: [3]cluster.HzbLevel = undefined;
    var visible: [2]bool = undefined;
    var hierarchy_stack: [4]u32 = undefined;
    var macro_headers: [4]cluster.MacrobinHeader = undefined;
    var macro_entries: [8]cluster.MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    var tile_headers: [4]cluster.TileHeader = undefined;
    var tile_packets: [8]cluster.TilePacket = undefined;
    var tile_cursors: [4]u32 = undefined;

    const plan = try buildPlan(
        .{ .clusters = &clusters, .nodes = &nodes, .roots = &roots },
        &depth,
        4,
        4,
        .{ .macro_w = 2, .macro_h = 2, .tile_w = 2, .tile_h = 2, .hzb = .{ .source = .depth_prepass, .compare = .less } },
        .{ .hzb_values = &hzb_values, .hzb_levels = &hzb_levels, .visible = &visible, .hierarchy_stack = &hierarchy_stack, .macro_headers = &macro_headers, .macro_entries = &macro_entries, .macro_cursors = &macro_cursors, .tile_headers = &tile_headers, .tile_packets = &tile_packets, .tile_cursors = &tile_cursors },
    );
    try std.testing.expectEqual(@as(usize, 1), plan.visible_count);
    try std.testing.expect(visible[0]);
    try std.testing.expect(!visible[1]);
    try std.testing.expectEqual(@as(usize, 1), plan.macro_ref_count);
    try std.testing.expectEqual(@as(usize, 1), plan.tile_packet_count);
    try std.testing.expectEqual(@as(cluster.ClusterId, 10), tile_packets[0].cluster_id);
}

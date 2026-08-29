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
    hierarchy_revision: u64 = 0,
    /// Optional admission token. Supplying it avoids validating static
    /// topology on every frame while retaining slice identity checks.
    validated_hierarchy: ?cluster.ValidatedHierarchy = null,
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
    hierarchy_colors: []u8,
    hierarchy_parent_counts: []u8,
    hierarchy_stack: []u32,
    macro_headers: []cluster.MacrobinHeader,
    macro_entries: []cluster.MacrobinRef,
    macro_cursors: []u32,
    tile_headers: []cluster.TileHeader,
    tile_packets: []cluster.TilePacket,
    tile_cursors: []u32,
    physical_packets_enabled: bool = false,
    local_packets: []cluster.LocalPacket = &.{},
    macro_packets: []cluster.MacroPacket = &.{},
    global_packets: []cluster.GlobalPacket = &.{},
};

pub const Plan = struct {
    hzb: cluster.Hzb,
    visible_count: usize,
    macro_ref_count: usize,
    tile_packet_count: usize,
    physical_local_count: usize = 0,
    physical_macro_count: usize = 0,
    physical_global_count: usize = 0,
};

pub const Error = cluster.HzbError || cluster.BinError || error{VisibleStorageTooSmall};

pub const Requirements = struct {
    hzb_values: usize,
    hzb_levels: usize,
    visible: usize,
    hierarchy_colors: usize,
    hierarchy_parent_counts: usize,
    hierarchy_stack: usize,
    macro_headers: usize,
    macro_refs_upper_bound: usize,
    tile_headers: usize,
    tile_packets_upper_bound: usize,
    local_packets_upper_bound: usize,
    macro_packets_upper_bound: usize,
    global_packets_upper_bound: usize,
};

/// Exact fixed-size requirements plus a conservative macro-reference upper
/// bound. Tile packet capacity is data-dependent after macrobins are built;
/// callers can conservatively reserve macro_refs * tiles_per_macro.
pub fn requirements(submission: Submission, width: u32, height: u32, config: Config) Error!Requirements {
    if (config.macro_w == 0 or config.macro_h == 0 or config.tile_w == 0 or config.tile_h == 0 or config.macro_w % config.tile_w != 0 or config.macro_h % config.tile_h != 0) return error.InvalidGeometry;
    const macro_headers = try cluster.requiredGridHeaders(width, height, config.macro_w, config.macro_h);
    const tile_headers = try cluster.requiredGridHeaders(width, height, config.tile_w, config.tile_h);
    const macro_refs_upper_bound = try cluster.requiredMacroReferencesUpperBound(submission.clusters, null, width, height, config.macro_w, config.macro_h);
    const tiles_per_macro = (@as(u64, config.macro_w) / config.tile_w) * (@as(u64, config.macro_h) / config.tile_h);
    if (tiles_per_macro != 0 and @as(u64, macro_refs_upper_bound) > std.math.maxInt(u64) / tiles_per_macro) return error.CountOverflow;
    const tile_packets_upper_bound64 = @as(u64, macro_refs_upper_bound) * tiles_per_macro;
    if (tile_packets_upper_bound64 > std.math.maxInt(usize)) return error.CountOverflow;
    if (@as(u64, submission.clusters.len) > std.math.maxInt(u64) / 16) return error.CountOverflow;
    const hierarchy_stack = try cluster.requiredHierarchyStack(submission.nodes.len, submission.roots.len);
    return .{
        .hzb_values = try cluster.hzbCoarseValueCount(width, height),
        .hzb_levels = cluster.maxHzbLevels(width, height),
        .visible = submission.clusters.len,
        .hierarchy_colors = submission.nodes.len,
        .hierarchy_parent_counts = submission.nodes.len,
        .hierarchy_stack = hierarchy_stack,
        .macro_headers = macro_headers,
        .macro_refs_upper_bound = macro_refs_upper_bound,
        .tile_headers = tile_headers,
        .tile_packets_upper_bound = @intCast(tile_packets_upper_bound64),
        .local_packets_upper_bound = @intCast(@as(u64, submission.clusters.len) * 16),
        .macro_packets_upper_bound = submission.clusters.len,
        .global_packets_upper_bound = submission.clusters.len,
    };
}

fn sameSlice(comptime T: type, a: []const T, b: []const T) bool {
    return a.len == b.len and (a.len == 0 or @intFromPtr(a.ptr) == @intFromPtr(b.ptr));
}

fn validatedHierarchy(submission: Submission, compare: cluster.DepthCompare, scratch: Scratch) Error!?cluster.ValidatedHierarchy {
    if (submission.nodes.len == 0 and submission.roots.len == 0) return null;
    if (submission.nodes.len == 0 or submission.roots.len == 0) return error.InvalidHierarchy;
    if (submission.validated_hierarchy) |candidate| {
        if (!sameSlice(cluster.ClusterNode, candidate.nodes, submission.nodes) or
            !sameSlice(u32, candidate.roots, submission.roots) or
            !sameSlice(cluster.Cluster, candidate.clusters, submission.clusters) or
            candidate.compare != compare or candidate.revision != submission.hierarchy_revision) return error.InvalidHierarchy;
        return candidate;
    }
    return try cluster.validateHierarchy(submission.nodes, submission.roots, submission.clusters, compare, submission.hierarchy_revision, scratch.hierarchy_colors, scratch.hierarchy_parent_counts, scratch.hierarchy_stack);
}

/// depth -> validated HZB -> hierarchy/cluster cull -> visible macrobins ->
/// ordered tile packets. Tile construction consumes the macrobins rather than
/// rescanning the original cluster slice.
pub fn buildPlan(submission: Submission, depth: []const f32, width: u32, height: u32, config: Config, scratch: Scratch) Error!Plan {
    if (scratch.visible.len < submission.clusters.len) return error.VisibleStorageTooSmall;
    const hzb = try cluster.Hzb.build(depth, width, height, config.hzb, scratch.hzb_values, scratch.hzb_levels);
    const visible = scratch.visible[0..submission.clusters.len];
    const hierarchy = try validatedHierarchy(submission, config.hzb.compare, scratch);
    const visible_count = if (hierarchy) |validated|
        try cluster.cullValidatedHierarchyHzb(validated, hzb, visible, scratch.hierarchy_stack)
    else
        try cluster.cullClustersHzb(submission.clusters, hzb, visible);

    if (scratch.physical_packets_enabled) {
        const physical = try cluster.buildPhysicalPackets(submission.clusters, visible, width, height, config.tile_w, config.tile_h, config.hzb.compare, scratch.local_packets, scratch.macro_packets, scratch.global_packets);
        return .{ .hzb = hzb, .visible_count = visible_count, .macro_ref_count = 0, .tile_packet_count = 0, .physical_local_count = physical.local, .physical_macro_count = physical.macro, .physical_global_count = physical.global };
    }

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
        config.hzb.compare,
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
    var hierarchy_colors: [3]u8 = undefined;
    var hierarchy_parent_counts: [3]u8 = undefined;
    var hierarchy_stack: [7]u32 = undefined;
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
        .{ .hzb_values = &hzb_values, .hzb_levels = &hzb_levels, .visible = &visible, .hierarchy_colors = &hierarchy_colors, .hierarchy_parent_counts = &hierarchy_parent_counts, .hierarchy_stack = &hierarchy_stack, .macro_headers = &macro_headers, .macro_entries = &macro_entries, .macro_cursors = &macro_cursors, .tile_headers = &tile_headers, .tile_packets = &tile_packets, .tile_cursors = &tile_cursors },
    );
    try std.testing.expectEqual(@as(usize, 1), plan.visible_count);
    try std.testing.expect(visible[0]);
    try std.testing.expect(!visible[1]);
    try std.testing.expectEqual(@as(usize, 1), plan.macro_ref_count);
    try std.testing.expectEqual(@as(usize, 1), plan.tile_packet_count);
    try std.testing.expectEqual(@as(cluster.ClusterId, 10), tile_packets[0].cluster_id);
}

test "physical packet mode keeps broad work out of tile metadata" {
    var depth = [_]f32{0.9} ** (128 * 128);
    var hzb_values: [5461]f32 = undefined;
    var hzb_levels: [8]cluster.HzbLevel = undefined;
    var visible: [3]bool = undefined;
    var local_packets: [16]cluster.LocalPacket = undefined;
    var macro_packets: [3]cluster.MacroPacket = undefined;
    var global_packets: [3]cluster.GlobalPacket = undefined;
    const clusters = [_]cluster.Cluster{
        .{ .id = 1, .draw_id = 0, .material_id = 0, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } },
        .{ .id = 2, .draw_id = 0, .material_id = 0, .first_triangle = 1, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 32, .max_y = 32 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 } },
        .{ .id = 3, .draw_id = 0, .material_id = 0, .first_triangle = 2, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .best_depth = 0.3, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 } },
    };
    const plan = try buildPlan(
        .{ .clusters = &clusters },
        &depth,
        128,
        128,
        .{ .macro_w = 32, .macro_h = 32, .tile_w = 4, .tile_h = 4, .hzb = .{ .source = .depth_prepass, .compare = .less } },
        .{
            .hzb_values = &hzb_values,
            .hzb_levels = &hzb_levels,
            .visible = &visible,
            .hierarchy_colors = &.{},
            .hierarchy_parent_counts = &.{},
            .hierarchy_stack = &.{},
            .macro_headers = &.{},
            .macro_entries = &.{},
            .macro_cursors = &.{},
            .tile_headers = &.{},
            .tile_packets = &.{},
            .tile_cursors = &.{},
            .physical_packets_enabled = true,
            .local_packets = &local_packets,
            .macro_packets = &macro_packets,
            .global_packets = &global_packets,
        },
    );
    try std.testing.expectEqual(@as(usize, 3), plan.visible_count);
    try std.testing.expectEqual(@as(usize, 1), plan.physical_local_count);
    try std.testing.expectEqual(@as(usize, 1), plan.physical_macro_count);
    try std.testing.expectEqual(@as(usize, 1), plan.physical_global_count);
    try std.testing.expectEqual(@as(u64, 64), macro_packets[0].tile_range.count());
    try std.testing.expectEqual(cluster.ExtentClass.global, global_packets[0].packet.extent);
}

test "validated hierarchy token is reusable and revision-bound" {
    const clusters = [_]cluster.Cluster{.{ .id = 1, .draw_id = 0, .material_id = 0, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } }};
    const nodes = [_]cluster.ClusterNode{.{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .first_cluster = 0, .cluster_count = 1 }};
    const roots = [_]u32{0};
    var colors: [1]u8 = undefined;
    var parents: [1]u8 = undefined;
    var validation_stack: [3]u32 = undefined;
    const token = try cluster.validateHierarchy(&nodes, &roots, &clusters, .less, 42, &colors, &parents, &validation_stack);
    var depth = [_]f32{0.9} ** 4;
    var hzb_values: [1]f32 = undefined;
    var hzb_levels: [2]cluster.HzbLevel = undefined;
    var visible: [1]bool = undefined;
    var hierarchy_stack: [3]u32 = undefined;
    var macro_headers: [1]cluster.MacrobinHeader = undefined;
    var macro_entries: [1]cluster.MacrobinRef = undefined;
    var macro_cursors: [1]u32 = undefined;
    var tile_headers: [4]cluster.TileHeader = undefined;
    var tile_packets: [4]cluster.TilePacket = undefined;
    var tile_cursors: [4]u32 = undefined;
    const config = Config{ .macro_w = 2, .macro_h = 2, .tile_w = 1, .tile_h = 1, .hzb = .{ .source = .depth_prepass, .compare = .less } };
    const scratch = Scratch{
        .hzb_values = &hzb_values,
        .hzb_levels = &hzb_levels,
        .visible = &visible,
        .hierarchy_colors = &.{},
        .hierarchy_parent_counts = &.{},
        .hierarchy_stack = &hierarchy_stack,
        .macro_headers = &macro_headers,
        .macro_entries = &macro_entries,
        .macro_cursors = &macro_cursors,
        .tile_headers = &tile_headers,
        .tile_packets = &tile_packets,
        .tile_cursors = &tile_cursors,
    };
    const submission = Submission{ .clusters = &clusters, .nodes = &nodes, .roots = &roots, .hierarchy_revision = 42, .validated_hierarchy = token };
    const plan = try buildPlan(submission, &depth, 2, 2, config, scratch);
    try std.testing.expectEqual(@as(usize, 1), plan.visible_count);
    try std.testing.expectError(error.InvalidHierarchy, buildPlan(.{ .clusters = &clusters, .nodes = &nodes, .roots = &roots, .hierarchy_revision = 43, .validated_hierarchy = token }, &depth, 2, 2, config, scratch));
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Mosaic planning primitives: hierarchy/HZB culling, macrobins, and ordered
//! physical LOCAL/MACRO/GLOBAL packet streams.

const std = @import("std");

pub const pipeline_name = "Mosaic";

pub const ClusterId = u32;
pub const DrawId = u32;
pub const MaterialId = u32;

pub const ScreenBounds = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    pub fn empty(self: ScreenBounds) bool {
        return self.min_x >= self.max_x or self.min_y >= self.max_y;
    }

    pub fn area(self: ScreenBounds) u64 {
        if (self.empty()) return 0;
        return @as(u64, self.max_x - self.min_x) * @as(u64, self.max_y - self.min_y);
    }

    pub fn clipped(self: ScreenBounds, width: u32, height: u32) ScreenBounds {
        return .{
            .min_x = @min(self.min_x, width),
            .min_y = @min(self.min_y, height),
            .max_x = @min(self.max_x, width),
            .max_y = @min(self.max_y, height),
        };
    }
};

pub const OrderingClass = enum { strict, depth_reorderable, commutative };
pub const OrderKey = struct {
    submission: u32,
    command: u32,
    primitive_group: u32,

    pub fn less(a: OrderKey, b: OrderKey) bool {
        if (a.submission != b.submission) return a.submission < b.submission;
        if (a.command != b.command) return a.command < b.command;
        return a.primitive_group < b.primitive_group;
    }
};

pub const Cluster = struct {
    id: ClusterId,
    draw_id: DrawId,
    material_id: MaterialId,
    first_triangle: u32,
    triangle_count: u16,
    bounds: ScreenBounds,
    /// Minimum candidate depth for LESS-family tests, maximum candidate depth
    /// for GREATER-family tests.
    best_depth: f32,
    order_key: OrderKey,
    ordering: OrderingClass = .strict,
    /// Optional post-setup estimate. Zero keeps the primitive-SIMD path.
    estimated_covered_samples: u32 = 0,
};

pub const ClusterNode = struct {
    bounds: ScreenBounds,
    best_depth: f32,
    first_child: u32 = 0,
    child_count: u16 = 0,
    first_cluster: u32 = 0,
    cluster_count: u16 = 0,
};

pub const RasterPath = enum { primitive_simd, pixel_simd };

pub fn chooseRasterPath(cluster: Cluster) RasterPath {
    if (cluster.triangle_count == 0 or cluster.bounds.empty() or cluster.estimated_covered_samples == 0) return .primitive_simd;
    const samples_per_triangle = @as(u64, cluster.estimated_covered_samples) / @as(u64, cluster.triangle_count);
    return if (samples_per_triangle <= 16) .primitive_simd else .pixel_simd;
}

pub const Visibility = packed struct { primitive_id: u32, material_id: u32 };
pub const invalid_visibility = Visibility{ .primitive_id = std.math.maxInt(u32), .material_id = std.math.maxInt(u32) };

pub const DepthCompare = enum { less, less_equal, greater, greater_equal };
pub const HzbSource = enum { same_frame_completed, depth_prepass, previous_frame_conservative };
pub const HzbPolicy = struct {
    source: HzbSource,
    compare: DepthCompare,
    temporal_reprojection_valid: bool = false,

    pub fn valid(self: HzbPolicy) bool {
        return self.source != .previous_frame_conservative or self.temporal_reprojection_valid;
    }
};

fn depthPass(compare: DepthCompare, candidate: f32, current: f32) bool {
    return switch (compare) {
        .less => candidate < current,
        .less_equal => candidate <= current,
        .greater => candidate > current,
        .greater_equal => candidate >= current,
    };
}

pub const VisibilityBuffer = struct {
    ids: []Visibility,
    depth: []f32,
    width: u32,
    height: u32,
    compare: DepthCompare,

    pub fn init(ids: []Visibility, depth: []f32, width: u32, height: u32, compare: DepthCompare) !VisibilityBuffer {
        if (width == 0 or height == 0) return error.InvalidVisibilityStorage;
        const count64 = @as(u64, width) * @as(u64, height);
        if (count64 > std.math.maxInt(usize)) return error.InvalidVisibilityStorage;
        const count: usize = @intCast(count64);
        if (ids.len < count or depth.len < count) return error.InvalidVisibilityStorage;
        return .{ .ids = ids[0..count], .depth = depth[0..count], .width = width, .height = height, .compare = compare };
    }

    pub fn clear(self: VisibilityBuffer, clear_depth: f32) void {
        @memset(self.ids, invalid_visibility);
        @memset(self.depth, clear_depth);
    }

    pub fn writeIfPasses(self: VisibilityBuffer, x: u32, y: u32, depth: f32, visibility: Visibility) bool {
        if (x >= self.width or y >= self.height or !std.math.isFinite(depth)) return false;
        const index = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (!depthPass(self.compare, depth, self.depth[index])) return false;
        self.depth[index] = depth;
        self.ids[index] = visibility;
        return true;
    }
};

pub const HzbLevel = struct {
    offset: usize,
    width: u32,
    height: u32,
    footprint_shift: u6,
};

pub const HzbError = error{ InvalidExtent, InvalidPolicy, DepthSizeMismatch, NonFiniteDepth, StorageTooSmall, LevelStorageTooSmall, CountOverflow };

fn halfExtent(value: u32) u32 {
    return value / 2 + value % 2;
}

pub fn maxHzbLevels(width: u32, height: u32) usize {
    if (width == 0 or height == 0) return 0;
    var w = width;
    var h = height;
    var levels: usize = 1;
    while (w > 1 or h > 1) : (levels += 1) {
        w = @max(@as(u32, 1), halfExtent(w));
        h = @max(@as(u32, 1), halfExtent(h));
    }
    return levels;
}

pub fn hzbValueCount(width: u32, height: u32) HzbError!usize {
    if (width == 0 or height == 0) return 0;
    var total: usize = 0;
    var w = width;
    var h = height;
    while (true) {
        const level64 = @as(u64, w) * @as(u64, h);
        if (level64 > std.math.maxInt(usize)) return error.CountOverflow;
        const level: usize = @intCast(level64);
        if (total > std.math.maxInt(usize) - level) return error.CountOverflow;
        total += level;
        if (w == 1 and h == 1) break;
        w = @max(@as(u32, 1), halfExtent(w));
        h = @max(@as(u32, 1), halfExtent(h));
    }
    return total;
}

/// Number of values required for HZB levels above the aliased full-resolution
/// source depth. Keeping this separate from `hzbValueCount` makes storage
/// sizing explicit for callers migrating from the old copied level-0 layout.
pub fn hzbCoarseValueCount(width: u32, height: u32) HzbError!usize {
    const total = try hzbValueCount(width, height);
    if (width == 0 or height == 0) return 0;
    const base64 = @as(u64, width) * @as(u64, height);
    if (base64 > total) return error.CountOverflow;
    return total - @as(usize, @intCast(base64));
}

fn reduceDepth(compare: DepthCompare, aggregate: f32, value: f32) f32 {
    return switch (compare) {
        .less, .less_equal => @max(aggregate, value),
        .greater, .greater_equal => @min(aggregate, value),
    };
}

fn occludedByAggregate(compare: DepthCompare, best_depth: f32, aggregate: f32) bool {
    return switch (compare) {
        .less => best_depth >= aggregate,
        .less_equal => best_depth > aggregate,
        .greater => best_depth <= aggregate,
        .greater_equal => best_depth < aggregate,
    };
}

pub const Hzb = struct {
    /// Level zero aliases the completed source depth attachment. It is never
    /// copied into the coarse pyramid storage.
    base_depth: []const f32,
    /// Storage contains level 1 and above, with offsets in `HzbLevel` relative
    /// to this slice.
    values: []f32,
    levels: []HzbLevel,
    level_count: usize,
    policy: HzbPolicy,

    pub fn build(depth: []const f32, width: u32, height: u32, policy: HzbPolicy, values: []f32, levels: []HzbLevel) HzbError!Hzb {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (!policy.valid()) return error.InvalidPolicy;
        const base64 = @as(u64, width) * @as(u64, height);
        if (base64 > std.math.maxInt(usize) or depth.len != @as(usize, @intCast(base64))) return error.DepthSizeMismatch;
        for (depth) |value| if (!std.math.isFinite(value)) return error.NonFiniteDepth;
        const needed_levels = maxHzbLevels(width, height);
        const needed_values = try hzbCoarseValueCount(width, height);
        if (levels.len < needed_levels) return error.LevelStorageTooSmall;
        if (values.len < needed_values) return error.StorageTooSmall;

        levels[0] = .{ .offset = 0, .width = width, .height = height, .footprint_shift = 0 };
        var offset: usize = 0;
        var level_index: usize = 1;
        while (level_index < needed_levels) : (level_index += 1) {
            const previous = levels[level_index - 1];
            const next_w = @max(@as(u32, 1), halfExtent(previous.width));
            const next_h = @max(@as(u32, 1), halfExtent(previous.height));
            levels[level_index] = .{ .offset = offset, .width = next_w, .height = next_h, .footprint_shift = @intCast(level_index) };
            var y: u32 = 0;
            while (y < next_h) : (y += 1) {
                var x: u32 = 0;
                while (x < next_w) : (x += 1) {
                    var aggregate: f32 = 0;
                    var have = false;
                    var dy: u32 = 0;
                    while (dy < 2) : (dy += 1) {
                        const py = y * 2 + dy;
                        if (py >= previous.height) continue;
                        var dx: u32 = 0;
                        while (dx < 2) : (dx += 1) {
                            const px = x * 2 + dx;
                            if (px >= previous.width) continue;
                            const value = if (level_index - 1 == 0)
                                depth[@as(usize, py) * @as(usize, previous.width) + @as(usize, px)]
                            else
                                values[previous.offset + @as(usize, py) * @as(usize, previous.width) + @as(usize, px)];
                            aggregate = if (have) reduceDepth(policy.compare, aggregate, value) else value;
                            have = true;
                        }
                    }
                    std.debug.assert(have);
                    values[offset + @as(usize, y) * @as(usize, next_w) + @as(usize, x)] = aggregate;
                }
            }
            offset += @as(usize, next_w) * @as(usize, next_h);
        }
        return .{ .base_depth = depth, .values = values[0..needed_values], .levels = levels[0..needed_levels], .level_count = needed_levels, .policy = policy };
    }

    fn valueAt(self: Hzb, level_index: usize, x: u32, y: u32) f32 {
        const level = self.levels[level_index];
        const index = @as(usize, y) * @as(usize, level.width) + @as(usize, x);
        return if (level_index == 0) self.base_depth[index] else self.values[level.offset + index];
    }

    pub fn occludedAtLevel(self: Hzb, bounds: ScreenBounds, best_depth: f32, level_index: usize) bool {
        if (bounds.empty() or level_index >= self.level_count or !std.math.isFinite(best_depth)) return false;
        const base = self.levels[0];
        const clipped = bounds.clipped(base.width, base.height);
        if (clipped.empty()) return false;
        const level = self.levels[level_index];
        const shift = level.footprint_shift;
        const first_x = @min(level.width - 1, clipped.min_x >> @as(u5, @intCast(shift)));
        const first_y = @min(level.height - 1, clipped.min_y >> @as(u5, @intCast(shift)));
        const last_x = @min(level.width - 1, (clipped.max_x - 1) >> @as(u5, @intCast(shift)));
        const last_y = @min(level.height - 1, (clipped.max_y - 1) >> @as(u5, @intCast(shift)));
        var aggregate: f32 = 0;
        var have = false;
        var y = first_y;
        while (y <= last_y) : (y += 1) {
            var x = first_x;
            while (x <= last_x) : (x += 1) {
                const value = self.valueAt(level_index, x, y);
                aggregate = if (have) reduceDepth(self.policy.compare, aggregate, value) else value;
                have = true;
            }
        }
        return have and occludedByAggregate(self.policy.compare, best_depth, aggregate);
    }
};

pub fn chooseHzbLevel(bounds: ScreenBounds, level_count: usize) usize {
    if (level_count == 0 or bounds.empty()) return 0;
    var span = @max(bounds.max_x - bounds.min_x, bounds.max_y - bounds.min_y);
    var level: usize = 0;
    while (span > 2 and level + 1 < level_count) : (level += 1) span = (span + 1) / 2;
    return level;
}

pub const MacrobinHeader = struct { offset: u32 = 0, count: u32 = 0 };
pub const MacrobinRef = struct { cluster_index: u32 };
pub const TileHeader = struct { offset: u32 = 0, count: u32 = 0 };
pub const ExtentClass = enum { local, macro, global };
pub const TilePacket = struct {
    order_key: OrderKey,
    /// Tie-break token that keeps inclusive-depth packet resolution
    /// deterministic even when two commands share an OrderKey.
    source_cluster_index: u32,
    ordering: OrderingClass,
    draw_id: DrawId,
    cluster_id: ClusterId,
    material_id: MaterialId,
    first_triangle: u32,
    triangle_count: u16,
    path: RasterPath,
    extent: ExtentClass,
};

pub const TileRect = struct {
    min_x: u32,
    min_y: u32,
    max_x: u32,
    max_y: u32,

    pub fn count(self: TileRect) u64 {
        if (self.min_x >= self.max_x or self.min_y >= self.max_y) return 0;
        return @as(u64, self.max_x - self.min_x) * @as(u64, self.max_y - self.min_y);
    }
};

/// Physical packet streams keep broad work compact. LOCAL work still names
/// one tile, MACRO work names a rectangular tile range, and GLOBAL work is a
/// single pass-level reference.
pub const LocalPacket = struct {
    packet: TilePacket,
    tile_x: u32,
    tile_y: u32,
};
pub const MacroPacket = struct {
    packet: TilePacket,
    tile_range: TileRect,
};
pub const GlobalPacket = struct { packet: TilePacket };
pub const PhysicalPacketCounts = struct {
    local: usize = 0,
    macro: usize = 0,
    global: usize = 0,
};

pub fn effectiveOrdering(compare: DepthCompare, ordering: OrderingClass) OrderingClass {
    // Equal-depth winners under inclusive compares are observable. A later
    // execution stage may reorder only work that carries a deterministic
    // original-order tie token; classify depth-reorderable work as strict here
    // until that stronger proof is available.
    return if ((compare == .less_equal or compare == .greater_equal) and ordering == .depth_reorderable) .strict else ordering;
}

pub const BinError = error{ InvalidGeometry, HeaderStorageTooSmall, EntryStorageTooSmall, ScratchTooSmall, CountOverflow, InvalidHierarchy, HierarchyCycle, DuplicateParent, InvalidNodeShape, ParentBoundsTooSmall, ParentDepthTooFar, UnreachableNode };
const GridRange = struct { x0: usize, x1: usize, y0: usize, y1: usize };

pub const ValidatedHierarchy = struct {
    nodes: []const ClusterNode,
    roots: []const u32,
    clusters: []const Cluster,
    compare: DepthCompare,
    revision: u64,
};

pub fn requiredHierarchyStack(node_count: usize, root_count: usize) BinError!usize {
    if (node_count > (std.math.maxInt(usize) - root_count) / 2) return error.CountOverflow;
    return node_count * 2 + root_count;
}

fn rangeEnd(first: u32, count: u32) ?usize {
    const start = @as(usize, first);
    const length = @as(usize, count);
    if (start > std.math.maxInt(usize) - length) return null;
    return start + length;
}

fn containsBounds(parent: ScreenBounds, child: ScreenBounds) bool {
    return parent.min_x <= child.min_x and parent.min_y <= child.min_y and
        parent.max_x >= child.max_x and parent.max_y >= child.max_y;
}

fn containsDepth(compare: DepthCompare, parent: f32, child: f32) bool {
    return switch (compare) {
        .less, .less_equal => parent <= child,
        .greater, .greater_equal => parent >= child,
    };
}

/// Validate hierarchy topology and conservative bounds once when content is
/// admitted. The returned value is a slice-bound token: callers may retain it
/// and reuse it for every frame as long as the referenced arrays do not change.
pub fn validateHierarchy(nodes: []const ClusterNode, roots: []const u32, clusters: []const Cluster, compare: DepthCompare, revision: u64, colors: []u8, parent_counts: []u8, stack: []u32) BinError!ValidatedHierarchy {
    if (colors.len < nodes.len or parent_counts.len < nodes.len or stack.len < try requiredHierarchyStack(nodes.len, roots.len)) return error.ScratchTooSmall;
    if (nodes.len > std.math.maxInt(u32) or nodes.len > 0x7fff_ffff) return error.CountOverflow;
    @memset(colors[0..nodes.len], 0);
    @memset(parent_counts[0..nodes.len], 0);

    var stack_len: usize = 0;
    for (roots) |root| {
        const root_index = @as(usize, root);
        if (root_index >= nodes.len) return error.InvalidHierarchy;
        if (parent_counts[root_index] != 0) return error.DuplicateParent;
        parent_counts[root_index] = 1;
        stack[stack_len] = root;
        stack_len += 1;
    }

    const exit_marker: u32 = 0x8000_0000;
    while (stack_len != 0) {
        stack_len -= 1;
        const encoded = stack[stack_len];
        const node_index = @as(usize, encoded & ~exit_marker);
        if (node_index >= nodes.len) return error.InvalidHierarchy;
        if (encoded & exit_marker != 0) {
            if (colors[node_index] != 1) return error.InvalidHierarchy;
            colors[node_index] = 2;
            continue;
        }
        if (colors[node_index] == 1) return error.HierarchyCycle;
        if (colors[node_index] == 2) return error.DuplicateParent;
        colors[node_index] = 1;
        stack[stack_len] = encoded | exit_marker;
        stack_len += 1;

        const node = nodes[node_index];
        if (!std.math.isFinite(node.best_depth)) return error.InvalidHierarchy;
        if (node.child_count != 0 and node.cluster_count != 0) return error.InvalidNodeShape;
        if (node.child_count != 0) {
            const first = @as(usize, node.first_child);
            const last = rangeEnd(node.first_child, node.child_count) orelse return error.InvalidHierarchy;
            if (last > nodes.len) return error.InvalidHierarchy;
            var child = last;
            while (child > first) {
                child -= 1;
                const descendant = nodes[child];
                if (colors[child] == 1) return error.HierarchyCycle;
                if (parent_counts[child] != 0) return error.DuplicateParent;
                if (!containsBounds(node.bounds, descendant.bounds)) return error.ParentBoundsTooSmall;
                if (!containsDepth(compare, node.best_depth, descendant.best_depth)) return error.ParentDepthTooFar;
                parent_counts[child] = 1;
                stack[stack_len] = @intCast(child);
                stack_len += 1;
            }
        } else {
            const first = @as(usize, node.first_cluster);
            const last = rangeEnd(node.first_cluster, node.cluster_count) orelse return error.InvalidHierarchy;
            if (last > clusters.len) return error.InvalidHierarchy;
            for (clusters[first..last]) |leaf| {
                if (!std.math.isFinite(leaf.best_depth)) return error.InvalidHierarchy;
                if (!containsBounds(node.bounds, leaf.bounds)) return error.ParentBoundsTooSmall;
                if (!containsDepth(compare, node.best_depth, leaf.best_depth)) return error.ParentDepthTooFar;
            }
        }
    }

    for (colors[0..nodes.len]) |color| if (color == 0) return error.UnreachableNode;
    return .{ .nodes = nodes, .roots = roots, .clusters = clusters, .compare = compare, .revision = revision };
}

pub fn requiredGridHeaders(surface_w: u32, surface_h: u32, cell_w: u32, cell_h: u32) BinError!usize {
    if (surface_w == 0 or surface_h == 0 or cell_w == 0 or cell_h == 0) return error.InvalidGeometry;
    const columns = (@as(u64, surface_w) + cell_w - 1) / cell_w;
    const rows = (@as(u64, surface_h) + cell_h - 1) / cell_h;
    const count = columns * rows;
    if (count > std.math.maxInt(usize)) return error.CountOverflow;
    return @intCast(count);
}

fn gridRange(bounds: ScreenBounds, surface_w: u32, surface_h: u32, cell_w: u32, cell_h: u32, columns: usize, rows: usize) ?GridRange {
    const clipped = bounds.clipped(surface_w, surface_h);
    if (clipped.empty()) return null;
    return .{ .x0 = @as(usize, clipped.min_x / cell_w), .x1 = @min(columns - 1, @as(usize, (clipped.max_x - 1) / cell_w)), .y0 = @as(usize, clipped.min_y / cell_h), .y1 = @min(rows - 1, @as(usize, (clipped.max_y - 1) / cell_h)) };
}

fn incrementCount(value: *u32) BinError!void {
    if (value.* == std.math.maxInt(u32)) return error.CountOverflow;
    value.* += 1;
}

fn addTotal(total: *usize, value: u32) BinError!void {
    if (total.* > std.math.maxInt(usize) - @as(usize, value)) return error.CountOverflow;
    total.* += @as(usize, value);
    if (total.* > std.math.maxInt(u32)) return error.CountOverflow;
}

pub fn requiredMacroReferencesUpperBound(clusters: []const Cluster, visible: ?[]const bool, surface_w: u32, surface_h: u32, macro_w: u32, macro_h: u32) BinError!usize {
    if (surface_w == 0 or surface_h == 0 or macro_w == 0 or macro_h == 0) return error.InvalidGeometry;
    if (visible) |mask| if (mask.len != clusters.len) return error.InvalidGeometry;
    const columns = (@as(usize, surface_w) + @as(usize, macro_w) - 1) / @as(usize, macro_w);
    const rows = (@as(usize, surface_h) + @as(usize, macro_h) - 1) / @as(usize, macro_h);
    var total: usize = 0;
    for (clusters, 0..) |cluster, index| {
        if (visible) |mask| if (!mask[index]) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, macro_w, macro_h, columns, rows) orelse continue;
        const refs = (range.x1 - range.x0 + 1) * (range.y1 - range.y0 + 1);
        if (total > std.math.maxInt(usize) - refs) return error.CountOverflow;
        total += refs;
    }
    return total;
}

pub fn buildMacrobins(clusters: []const Cluster, visible: ?[]const bool, surface_w: u32, surface_h: u32, macro_w: u32, macro_h: u32, headers: []MacrobinHeader, entries: []MacrobinRef, cursors: []u32) BinError!usize {
    if (visible) |mask| if (mask.len != clusters.len) return error.InvalidGeometry;
    const bin_count = try requiredGridHeaders(surface_w, surface_h, macro_w, macro_h);
    const columns = (@as(usize, surface_w) + @as(usize, macro_w) - 1) / @as(usize, macro_w);
    const rows = bin_count / columns;
    if (headers.len < bin_count) return error.HeaderStorageTooSmall;
    if (cursors.len < bin_count) return error.ScratchTooSmall;
    for (headers[0..bin_count]) |*header| header.* = .{};
    for (clusters, 0..) |cluster, cluster_index| {
        if (visible) |mask| if (!mask[cluster_index]) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, macro_w, macro_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) try incrementCount(&headers[y * columns + x].count);
        }
    }
    var total: usize = 0;
    for (headers[0..bin_count], 0..) |*header, index| {
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        try addTotal(&total, header.count);
    }
    if (entries.len < total) return error.EntryStorageTooSmall;
    for (clusters, 0..) |cluster, cluster_index| {
        if (visible) |mask| if (!mask[cluster_index]) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, macro_w, macro_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) {
                if (cluster_index > std.math.maxInt(u32)) return error.CountOverflow;
                const bin = y * columns + x;
                const destination = @as(usize, cursors[bin]);
                entries[destination] = .{ .cluster_index = @intCast(cluster_index) };
                cursors[bin] += 1;
            }
        }
    }
    return total;
}

fn classifyExtent(range: GridRange) ExtentClass {
    const tiles = (range.x1 - range.x0 + 1) * (range.y1 - range.y0 + 1);
    return if (tiles <= 16) .local else if (tiles <= 256) .macro else .global;
}

fn packetLess(a: TilePacket, b: TilePacket) bool {
    if (OrderKey.less(a.order_key, b.order_key)) return true;
    if (OrderKey.less(b.order_key, a.order_key)) return false;
    return a.source_cluster_index < b.source_cluster_index;
}

fn heapSortPackets(packets: []TilePacket) void {
    if (packets.len < 2) return;
    var start = packets.len / 2;
    while (start != 0) {
        start -= 1;
        var root = start;
        while (root < packets.len / 2) {
            var child = root * 2 + 1;
            if (child + 1 < packets.len and packetLess(packets[child], packets[child + 1])) child += 1;
            if (!packetLess(packets[root], packets[child])) break;
            std.mem.swap(TilePacket, &packets[root], &packets[child]);
            root = child;
        }
    }
    var end = packets.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(TilePacket, &packets[0], &packets[end]);
        var root: usize = 0;
        while (root < end / 2) {
            var child = root * 2 + 1;
            if (child + 1 < end and packetLess(packets[child], packets[child + 1])) child += 1;
            if (!packetLess(packets[root], packets[child])) break;
            std.mem.swap(TilePacket, &packets[root], &packets[child]);
            root = child;
        }
    }
}

fn physicalPacketLess(comptime T: type, a: T, b: T) bool {
    return packetLess(a.packet, b.packet);
}

fn heapSortPhysical(comptime T: type, packets: []T) void {
    if (packets.len < 2) return;
    var start = packets.len / 2;
    while (start != 0) {
        start -= 1;
        var root = start;
        while (root < packets.len / 2) {
            var child = root * 2 + 1;
            if (child + 1 < packets.len and physicalPacketLess(T, packets[child], packets[child + 1])) child += 1;
            if (!physicalPacketLess(T, packets[root], packets[child])) break;
            std.mem.swap(T, &packets[root], &packets[child]);
            root = child;
        }
    }
    var end = packets.len;
    while (end > 1) {
        end -= 1;
        std.mem.swap(T, &packets[0], &packets[end]);
        var root: usize = 0;
        while (root < end / 2) {
            var child = root * 2 + 1;
            if (child + 1 < end and physicalPacketLess(T, packets[child], packets[child + 1])) child += 1;
            if (!physicalPacketLess(T, packets[root], packets[child])) break;
            std.mem.swap(T, &packets[root], &packets[child]);
            root = child;
        }
    }
}

fn packetForCluster(cluster: Cluster, cluster_index: usize, extent: ExtentClass, compare: DepthCompare) BinError!TilePacket {
    if (cluster_index > std.math.maxInt(u32)) return error.CountOverflow;
    return .{
        .order_key = cluster.order_key,
        .source_cluster_index = @intCast(cluster_index),
        .ordering = effectiveOrdering(compare, cluster.ordering),
        .draw_id = cluster.draw_id,
        .cluster_id = cluster.id,
        .material_id = cluster.material_id,
        .first_triangle = cluster.first_triangle,
        .triangle_count = cluster.triangle_count,
        .path = chooseRasterPath(cluster),
        .extent = extent,
    };
}

pub fn buildPhysicalPackets(clusters: []const Cluster, visible: ?[]const bool, surface_w: u32, surface_h: u32, tile_w: u32, tile_h: u32, compare: DepthCompare, local_packets: []LocalPacket, macro_packets: []MacroPacket, global_packets: []GlobalPacket) BinError!PhysicalPacketCounts {
    if (surface_w == 0 or surface_h == 0 or tile_w == 0 or tile_h == 0) return error.InvalidGeometry;
    if (visible) |mask| if (mask.len != clusters.len) return error.InvalidGeometry;
    const tile_count = try requiredGridHeaders(surface_w, surface_h, tile_w, tile_h);
    const columns = (@as(usize, surface_w) + tile_w - 1) / tile_w;
    const rows = tile_count / columns;
    var counts = PhysicalPacketCounts{};

    for (clusters, 0..) |item, cluster_index| {
        if (visible) |mask| if (!mask[cluster_index]) continue;
        const range = gridRange(item.bounds, surface_w, surface_h, tile_w, tile_h, columns, rows) orelse continue;
        const extent = classifyExtent(range);
        switch (extent) {
            .local => {
                const fanout = range.x1 - range.x0 + 1;
                const fanout_y = range.y1 - range.y0 + 1;
                if (counts.local > std.math.maxInt(usize) - fanout * fanout_y) return error.CountOverflow;
                counts.local += fanout * fanout_y;
            },
            .macro => counts.macro += 1,
            .global => counts.global += 1,
        }
    }
    if (local_packets.len < counts.local) return error.EntryStorageTooSmall;
    if (macro_packets.len < counts.macro) return error.EntryStorageTooSmall;
    if (global_packets.len < counts.global) return error.EntryStorageTooSmall;

    var local_index: usize = 0;
    var macro_index: usize = 0;
    var global_index: usize = 0;
    for (clusters, 0..) |item, cluster_index| {
        if (visible) |mask| if (!mask[cluster_index]) continue;
        const range = gridRange(item.bounds, surface_w, surface_h, tile_w, tile_h, columns, rows) orelse continue;
        const extent = classifyExtent(range);
        const packet = try packetForCluster(item, cluster_index, extent, compare);
        switch (extent) {
            .local => {
                var y = range.y0;
                while (y <= range.y1) : (y += 1) {
                    var x = range.x0;
                    while (x <= range.x1) : (x += 1) {
                        local_packets[local_index] = .{ .packet = packet, .tile_x = @intCast(x), .tile_y = @intCast(y) };
                        local_index += 1;
                    }
                }
            },
            .macro => {
                macro_packets[macro_index] = .{ .packet = packet, .tile_range = .{ .min_x = @intCast(range.x0), .min_y = @intCast(range.y0), .max_x = @intCast(range.x1 + 1), .max_y = @intCast(range.y1 + 1) } };
                macro_index += 1;
            },
            .global => {
                global_packets[global_index] = .{ .packet = packet };
                global_index += 1;
            },
        }
    }
    heapSortPhysical(LocalPacket, local_packets[0..counts.local]);
    heapSortPhysical(MacroPacket, macro_packets[0..counts.macro]);
    heapSortPhysical(GlobalPacket, global_packets[0..counts.global]);
    return counts;
}

pub fn buildTilePacketsFromMacrobins(clusters: []const Cluster, surface_w: u32, surface_h: u32, macro_w: u32, macro_h: u32, macro_headers: []const MacrobinHeader, macro_entries: []const MacrobinRef, tile_w: u32, tile_h: u32, compare: DepthCompare, headers: []TileHeader, packets: []TilePacket, cursors: []u32) BinError!usize {
    if (macro_w == 0 or macro_h == 0 or tile_w == 0 or tile_h == 0 or macro_w % tile_w != 0 or macro_h % tile_h != 0) return error.InvalidGeometry;
    const macro_count = try requiredGridHeaders(surface_w, surface_h, macro_w, macro_h);
    const tile_count = try requiredGridHeaders(surface_w, surface_h, tile_w, tile_h);
    if (macro_headers.len < macro_count or headers.len < tile_count) return error.HeaderStorageTooSmall;
    if (cursors.len < tile_count) return error.ScratchTooSmall;
    const macro_columns = (@as(usize, surface_w) + @as(usize, macro_w) - 1) / @as(usize, macro_w);
    const tile_columns = (@as(usize, surface_w) + @as(usize, tile_w) - 1) / @as(usize, tile_w);
    const tile_rows = tile_count / tile_columns;
    for (headers[0..tile_count]) |*header| header.* = .{};

    var macro_index: usize = 0;
    while (macro_index < macro_count) : (macro_index += 1) {
        const mx = macro_index % macro_columns;
        const my = macro_index / macro_columns;
        const macro_bounds = ScreenBounds{ .min_x = @intCast(mx * @as(usize, macro_w)), .min_y = @intCast(my * @as(usize, macro_h)), .max_x = @min(surface_w, @as(u32, @intCast((mx + 1) * @as(usize, macro_w)))), .max_y = @min(surface_h, @as(u32, @intCast((my + 1) * @as(usize, macro_h)))) };
        const mh = macro_headers[macro_index];
        const begin = @as(usize, mh.offset);
        const end = begin + @as(usize, mh.count);
        if (end > macro_entries.len) return error.InvalidGeometry;
        for (macro_entries[begin..end]) |reference| {
            const cluster_index = @as(usize, reference.cluster_index);
            if (cluster_index >= clusters.len) return error.InvalidGeometry;
            const cluster = clusters[cluster_index];
            const clipped = ScreenBounds{ .min_x = @max(cluster.bounds.min_x, macro_bounds.min_x), .min_y = @max(cluster.bounds.min_y, macro_bounds.min_y), .max_x = @min(cluster.bounds.max_x, macro_bounds.max_x), .max_y = @min(cluster.bounds.max_y, macro_bounds.max_y) };
            const range = gridRange(clipped, surface_w, surface_h, tile_w, tile_h, tile_columns, tile_rows) orelse continue;
            var y = range.y0;
            while (y <= range.y1) : (y += 1) {
                var x = range.x0;
                while (x <= range.x1) : (x += 1) try incrementCount(&headers[y * tile_columns + x].count);
            }
        }
    }

    var total: usize = 0;
    for (headers[0..tile_count], 0..) |*header, index| {
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        try addTotal(&total, header.count);
    }
    if (packets.len < total) return error.EntryStorageTooSmall;

    macro_index = 0;
    while (macro_index < macro_count) : (macro_index += 1) {
        const mx = macro_index % macro_columns;
        const my = macro_index / macro_columns;
        const macro_bounds = ScreenBounds{ .min_x = @intCast(mx * @as(usize, macro_w)), .min_y = @intCast(my * @as(usize, macro_h)), .max_x = @min(surface_w, @as(u32, @intCast((mx + 1) * @as(usize, macro_w)))), .max_y = @min(surface_h, @as(u32, @intCast((my + 1) * @as(usize, macro_h)))) };
        const mh = macro_headers[macro_index];
        const begin = @as(usize, mh.offset);
        const end = begin + @as(usize, mh.count);
        if (end > macro_entries.len) return error.InvalidGeometry;
        for (macro_entries[begin..end]) |reference| {
            const cluster_index = @as(usize, reference.cluster_index);
            if (cluster_index >= clusters.len) return error.InvalidGeometry;
            const cluster = clusters[cluster_index];
            const full_range = gridRange(cluster.bounds, surface_w, surface_h, tile_w, tile_h, tile_columns, tile_rows) orelse continue;
            const extent = classifyExtent(full_range);
            const clipped = ScreenBounds{ .min_x = @max(cluster.bounds.min_x, macro_bounds.min_x), .min_y = @max(cluster.bounds.min_y, macro_bounds.min_y), .max_x = @min(cluster.bounds.max_x, macro_bounds.max_x), .max_y = @min(cluster.bounds.max_y, macro_bounds.max_y) };
            const range = gridRange(clipped, surface_w, surface_h, tile_w, tile_h, tile_columns, tile_rows) orelse continue;
            var y = range.y0;
            while (y <= range.y1) : (y += 1) {
                var x = range.x0;
                while (x <= range.x1) : (x += 1) {
                    const tile = y * tile_columns + x;
                    const destination = @as(usize, cursors[tile]);
                    if (cluster_index > std.math.maxInt(u32)) return error.CountOverflow;
                    packets[destination] = .{ .order_key = cluster.order_key, .source_cluster_index = @intCast(cluster_index), .ordering = effectiveOrdering(compare, cluster.ordering), .draw_id = cluster.draw_id, .cluster_id = cluster.id, .material_id = cluster.material_id, .first_triangle = cluster.first_triangle, .triangle_count = cluster.triangle_count, .path = chooseRasterPath(cluster), .extent = extent };
                    cursors[tile] += 1;
                }
            }
        }
    }
    for (headers[0..tile_count]) |header| {
        const begin = @as(usize, header.offset);
        const end = begin + @as(usize, header.count);
        heapSortPackets(packets[begin..end]);
    }
    return total;
}

pub fn cullClustersHzb(clusters: []const Cluster, hzb: Hzb, visible: []bool) BinError!usize {
    if (clusters.len != visible.len) return error.InvalidGeometry;
    var count: usize = 0;
    for (clusters, visible) |cluster, *is_visible| {
        const level = chooseHzbLevel(cluster.bounds, hzb.level_count);
        is_visible.* = !hzb.occludedAtLevel(cluster.bounds, cluster.best_depth, level);
        if (is_visible.*) count += 1;
    }
    return count;
}

pub fn cullValidatedHierarchyHzb(hierarchy: ValidatedHierarchy, hzb: Hzb, visible: []bool, stack: []u32) BinError!usize {
    const nodes = hierarchy.nodes;
    const roots = hierarchy.roots;
    const clusters = hierarchy.clusters;
    if (hzb.policy.compare != hierarchy.compare) return error.InvalidHierarchy;
    if (visible.len != clusters.len or stack.len < nodes.len + roots.len) return error.ScratchTooSmall;
    @memset(visible, false);
    var stack_len: usize = 0;
    for (roots) |root| {
        if (@as(usize, root) >= nodes.len) return error.InvalidHierarchy;
        stack[stack_len] = root;
        stack_len += 1;
    }
    var count: usize = 0;
    while (stack_len != 0) {
        stack_len -= 1;
        const node = nodes[@as(usize, stack[stack_len])];
        const level = chooseHzbLevel(node.bounds, hzb.level_count);
        if (hzb.occludedAtLevel(node.bounds, node.best_depth, level)) continue;
        if (node.child_count != 0) {
            const first = @as(usize, node.first_child);
            const last = first + @as(usize, node.child_count);
            if (last > nodes.len) return error.InvalidHierarchy;
            var child = last;
            while (child > first) {
                child -= 1;
                stack[stack_len] = @intCast(child);
                stack_len += 1;
            }
        } else {
            const first = @as(usize, node.first_cluster);
            const last = first + @as(usize, node.cluster_count);
            if (last > clusters.len) return error.InvalidHierarchy;
            for (first..last) |cluster_index| {
                const cluster = clusters[cluster_index];
                const cluster_level = chooseHzbLevel(cluster.bounds, hzb.level_count);
                if (!hzb.occludedAtLevel(cluster.bounds, cluster.best_depth, cluster_level) and !visible[cluster_index]) {
                    visible[cluster_index] = true;
                    count += 1;
                }
            }
        }
    }
    return count;
}

/// Compatibility entry point for callers that already validated their input.
/// New code should retain the `ValidatedHierarchy` token and call
/// `cullValidatedHierarchyHzb()` directly so validation is not repeated.
pub fn cullHierarchyHzb(nodes: []const ClusterNode, roots: []const u32, clusters: []const Cluster, hzb: Hzb, visible: []bool, stack: []u32) BinError!usize {
    return cullValidatedHierarchyHzb(.{ .nodes = nodes, .roots = roots, .clusters = clusters, .compare = hzb.policy.compare }, hzb, visible, stack);
}

test "HZB odd dimensions use exact power-of-two footprints" {
    var depth = [_]f32{0.2} ** 9;
    depth[3] = 1.0;
    var values: [20]f32 = undefined;
    var levels: [5]HzbLevel = undefined;
    const hzb = try Hzb.build(&depth, 9, 1, .{ .source = .depth_prepass, .compare = .less }, &values, &levels);
    try std.testing.expectEqual(@as(u6, 2), hzb.levels[2].footprint_shift);
    try std.testing.expect(!hzb.occludedAtLevel(.{ .min_x = 3, .min_y = 0, .max_x = 8, .max_y = 1 }, 0.8, 2));
}

test "HZB supports reverse Z" {
    const depth = [_]f32{ 0.8, 0.8, 0.8, 0.8 };
    var values: [5]f32 = undefined;
    var levels: [2]HzbLevel = undefined;
    const hzb = try Hzb.build(&depth, 2, 2, .{ .source = .same_frame_completed, .compare = .greater }, &values, &levels);
    try std.testing.expect(hzb.occludedAtLevel(.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, 0.5, 1));
    try std.testing.expect(!hzb.occludedAtLevel(.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, 0.9, 1));
}

test "previous-frame HZB requires conservative reprojection proof" {
    const depth = [_]f32{0.5};
    var values: [1]f32 = undefined;
    var levels: [1]HzbLevel = undefined;
    try std.testing.expectError(error.InvalidPolicy, Hzb.build(&depth, 1, 1, .{ .source = .previous_frame_conservative, .compare = .less }, &values, &levels));
}

test "HZB aliases full-resolution depth and stores only coarse levels" {
    var depth = [_]f32{ 0.1, 0.2, 0.3, 0.4 };
    var values: [1]f32 = undefined;
    var levels: [2]HzbLevel = undefined;
    const hzb = try Hzb.build(&depth, 2, 2, .{ .source = .depth_prepass, .compare = .less }, &values, &levels);
    try std.testing.expectEqual(@intFromPtr(depth[0..].ptr), @intFromPtr(hzb.base_depth.ptr));
    try std.testing.expectEqual(@as(usize, 1), hzb.values.len);
    try std.testing.expectEqual(@as(usize, 1), try hzbCoarseValueCount(2, 2));
}

test "HZB rejects non-finite source depth" {
    var depth = [_]f32{ 0.1, std.math.inf(f32) };
    var values: [1]f32 = undefined;
    var levels: [2]HzbLevel = undefined;
    try std.testing.expectError(error.NonFiniteDepth, Hzb.build(&depth, 2, 1, .{ .source = .same_frame_completed, .compare = .less }, &values, &levels));
}

test "tile packets consume macrobins and enforce order" {
    const clusters = [_]Cluster{
        .{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 64, .triangle_count = 64, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 }, .estimated_covered_samples = 64 },
        .{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 64, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 }, .estimated_covered_samples = 64 },
    };
    const visible = [_]bool{ true, true };
    var mh: [1]MacrobinHeader = undefined;
    var me: [2]MacrobinRef = undefined;
    var mc: [1]u32 = undefined;
    _ = try buildMacrobins(&clusters, &visible, 16, 16, 16, 16, &mh, &me, &mc);
    var th: [1]TileHeader = undefined;
    var packets: [2]TilePacket = undefined;
    var tc: [1]u32 = undefined;
    const count = try buildTilePacketsFromMacrobins(&clusters, 16, 16, 16, 16, &mh, &me, 16, 16, .less, &th, &packets, &tc);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(ClusterId, 1), packets[0].cluster_id);
    try std.testing.expectEqual(@as(ClusterId, 2), packets[1].cluster_id);
}

test "raster path uses covered-sample estimate, not cluster bbox" {
    const tiny = Cluster{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 128, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 512, .max_y = 512 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 }, .estimated_covered_samples = 128 };
    const broad = Cluster{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 2, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 }, .estimated_covered_samples = 4096 };
    try std.testing.expectEqual(RasterPath.primitive_simd, chooseRasterPath(tiny));
    try std.testing.expectEqual(RasterPath.pixel_simd, chooseRasterPath(broad));
}

fn validationScratch(comptime node_count: usize, comptime root_count: usize) struct {
    colors: [node_count]u8,
    parents: [node_count]u8,
    stack: [node_count * 2 + root_count]u32,
} {
    return undefined;
}

test "hierarchy validator rejects self and ancestor cycles" {
    var self_nodes = [_]ClusterNode{.{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .first_child = 0, .child_count = 1 }};
    var self_scratch = validationScratch(1, 1);
    try std.testing.expectError(error.HierarchyCycle, validateHierarchy(&self_nodes, &[_]u32{0}, &.{}, .less, 1, &self_scratch.colors, &self_scratch.parents, &self_scratch.stack));

    var cycle_nodes = [_]ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .first_child = 1, .child_count = 1 },
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .first_child = 0, .child_count = 1 },
    };
    var cycle_scratch = validationScratch(2, 1);
    try std.testing.expectError(error.HierarchyCycle, validateHierarchy(&cycle_nodes, &[_]u32{0}, &.{}, .less, 1, &cycle_scratch.colors, &cycle_scratch.parents, &cycle_scratch.stack));
}

test "hierarchy validator rejects malformed ranges and node forms" {
    var out_of_range = [_]ClusterNode{.{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .best_depth = 0.1, .first_child = 1, .child_count = 1 }};
    var one = validationScratch(1, 1);
    try std.testing.expectError(error.InvalidHierarchy, validateHierarchy(&out_of_range, &[_]u32{0}, &.{}, .less, 1, &one.colors, &one.parents, &one.stack));

    var mixed = [_]ClusterNode{.{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .best_depth = 0.1, .first_child = 0, .child_count = 1, .first_cluster = 0, .cluster_count = 1 }};
    var mixed_scratch = validationScratch(1, 1);
    try std.testing.expectError(error.InvalidNodeShape, validateHierarchy(&mixed, &[_]u32{0}, &[_]Cluster{.{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 } }}, .less, 1, &mixed_scratch.colors, &mixed_scratch.parents, &mixed_scratch.stack));
}

test "hierarchy validator rejects non-conservative bounds and depth" {
    var bounds_nodes = [_]ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .first_child = 1, .child_count = 1 },
        .{ .bounds = .{ .min_x = 1, .min_y = 1, .max_x = 3, .max_y = 3 }, .best_depth = 0.2, .first_cluster = 0, .cluster_count = 0 },
    };
    var bounds_scratch = validationScratch(2, 1);
    try std.testing.expectError(error.ParentBoundsTooSmall, validateHierarchy(&bounds_nodes, &[_]u32{0}, &.{}, .less, 1, &bounds_scratch.colors, &bounds_scratch.parents, &bounds_scratch.stack));

    var depth_nodes = [_]ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.5, .first_child = 1, .child_count = 1 },
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.2, .first_cluster = 0, .cluster_count = 0 },
    };
    var depth_scratch = validationScratch(2, 1);
    try std.testing.expectError(error.ParentDepthTooFar, validateHierarchy(&depth_nodes, &[_]u32{0}, &.{}, .less, 1, &depth_scratch.colors, &depth_scratch.parents, &depth_scratch.stack));

    var reverse_scratch = validationScratch(2, 1);
    depth_nodes[0].best_depth = 0.2;
    depth_nodes[1].best_depth = 0.5;
    try std.testing.expectError(error.ParentDepthTooFar, validateHierarchy(&depth_nodes, &[_]u32{0}, &.{}, .greater, 1, &reverse_scratch.colors, &reverse_scratch.parents, &reverse_scratch.stack));
}

test "hierarchy validator rejects duplicate parents and unreachable nodes" {
    var duplicate_nodes = [_]ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .first_child = 1, .child_count = 1 },
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, .best_depth = 0.1, .first_cluster = 0, .cluster_count = 0 },
    };
    var duplicate_scratch = validationScratch(2, 2);
    try std.testing.expectError(error.DuplicateParent, validateHierarchy(&duplicate_nodes, &[_]u32{ 0, 1 }, &.{}, .less, 1, &duplicate_scratch.colors, &duplicate_scratch.parents, &duplicate_scratch.stack));

    var unreachable_nodes = [_]ClusterNode{
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .best_depth = 0.1 },
        .{ .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 }, .best_depth = 0.1 },
    };
    var unreachable_scratch = validationScratch(2, 1);
    try std.testing.expectError(error.UnreachableNode, validateHierarchy(&unreachable_nodes, &[_]u32{0}, &.{}, .less, 1, &unreachable_scratch.colors, &unreachable_scratch.parents, &unreachable_scratch.stack));
}

test "full cluster fanout controls extent classification" {
    const cluster = [_]Cluster{.{ .id = 7, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 }, .estimated_covered_samples = 4096 }};
    var mh: [16]MacrobinHeader = undefined;
    var me: [16]MacrobinRef = undefined;
    var mc: [16]u32 = undefined;
    const refs = try buildMacrobins(&cluster, null, 128, 128, 32, 32, &mh, &me, &mc);
    var th: [1024]TileHeader = undefined;
    var packets: [1024]TilePacket = undefined;
    var tc: [1024]u32 = undefined;
    _ = refs;
    const packet_count = try buildTilePacketsFromMacrobins(&cluster, 128, 128, 32, 32, &mh, &me, 4, 4, .less, &th, &packets, &tc);
    try std.testing.expectEqual(@as(usize, 1024), packet_count);
    try std.testing.expectEqual(ExtentClass.global, packets[0].extent);
}

test "physical packet streams keep broad work compact" {
    const clusters = [_]Cluster{
        .{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, .best_depth = 0.1, .order_key = .{ .submission = 0, .command = 0, .primitive_group = 0 }, .estimated_covered_samples = 4 },
        .{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 1, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 32, .max_y = 32 }, .best_depth = 0.2, .order_key = .{ .submission = 0, .command = 1, .primitive_group = 0 }, .estimated_covered_samples = 1024 },
        .{ .id = 0, .draw_id = 1, .material_id = 1, .first_triangle = 2, .triangle_count = 1, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .best_depth = 0.3, .order_key = .{ .submission = 0, .command = 2, .primitive_group = 0 }, .estimated_covered_samples = 16384 },
    };
    var local: [16]LocalPacket = undefined;
    var macro: [3]MacroPacket = undefined;
    var global: [3]GlobalPacket = undefined;
    const counts = try buildPhysicalPackets(&clusters, null, 128, 128, 4, 4, .less, &local, &macro, &global);
    try std.testing.expectEqual(@as(usize, 1), counts.local);
    try std.testing.expectEqual(@as(usize, 1), counts.macro);
    try std.testing.expectEqual(@as(usize, 1), counts.global);
    try std.testing.expectEqual(@as(u64, 64), macro[0].tile_range.count());
    try std.testing.expectEqual(@as(ClusterId, 0), global[0].packet.cluster_id);
}

fn oracleOccluded(depth: []const f32, width: u32, height: u32, bounds: ScreenBounds, best_depth: f32, compare: DepthCompare) bool {
    const clipped = bounds.clipped(width, height);
    if (clipped.empty()) return false;
    var aggregate: f32 = 0;
    var have = false;
    var y = clipped.min_y;
    while (y < clipped.max_y) : (y += 1) {
        var x = clipped.min_x;
        while (x < clipped.max_x) : (x += 1) {
            const value = depth[@as(usize, y) * @as(usize, width) + @as(usize, x)];
            aggregate = if (have) reduceDepth(compare, aggregate, value) else value;
            have = true;
        }
    }
    return have and occludedByAggregate(compare, best_depth, aggregate);
}

test "HZB never rejects a rectangle that the full-resolution oracle keeps visible" {
    const compares = [_]DepthCompare{ .less, .less_equal, .greater, .greater_equal };
    const candidate_depths = [_]f32{ 0.0, 0.25, 0.5, 0.75, 1.0 };
    var seed: u32 = 0x6d2b79f5;
    for (1..34) |width_usize| {
        for (1..34) |height_usize| {
            const width: u32 = @intCast(width_usize);
            const height: u32 = @intCast(height_usize);
            const pixel_count = width_usize * height_usize;
            var depth: [33 * 33]f32 = undefined;
            for (0..pixel_count) |index| {
                seed = seed *% 1_664_525 +% 1_013_904_223;
                const value = @as(f32, @floatFromInt((seed >> 8) % 101)) / 100.0;
                const x = index % width_usize;
                const y = index / width_usize;
                depth[index] = if ((x * 7 + y * 11 + width_usize + height_usize) % 13 == 0) 0.5 else value;
            }

            var rectangles: [12]ScreenBounds = undefined;
            var rectangle_count: usize = 0;
            rectangles[rectangle_count] = .{ .min_x = 0, .min_y = 0, .max_x = width, .max_y = height };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = 0, .min_y = 0, .max_x = 1, .max_y = 1 };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = width - 1, .min_y = height - 1, .max_x = width, .max_y = height };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = width / 2, .min_y = 0, .max_x = width, .max_y = height };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = 0, .min_y = height / 2, .max_x = width, .max_y = height };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = width / 3, .min_y = height / 3, .max_x = @min(width, width / 3 + 3), .max_y = @min(height, height / 3 + 3) };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = width - 1, .min_y = 0, .max_x = width + 1, .max_y = height };
            rectangle_count += 1;
            rectangles[rectangle_count] = .{ .min_x = 0, .min_y = height - 1, .max_x = width, .max_y = height + 1 };
            rectangle_count += 1;

            var values: [512]f32 = undefined;
            var levels: [8]HzbLevel = undefined;
            for (compares) |compare| {
                const hzb = try Hzb.build(depth[0..pixel_count], width, height, .{ .source = .depth_prepass, .compare = compare }, &values, &levels);
                for (rectangles[0..rectangle_count]) |bounds| {
                    for (candidate_depths) |best_depth| {
                        const expected = oracleOccluded(depth[0..pixel_count], width, height, bounds, best_depth, compare);
                        for (0..hzb.level_count) |level| {
                            const actual = hzb.occludedAtLevel(bounds, best_depth, level);
                            if (actual and !expected) return error.HzbRejectedVisible;
                            if (level == 0) try std.testing.expectEqual(expected, actual);
                        }
                    }
                }
            }
        }
    }
}

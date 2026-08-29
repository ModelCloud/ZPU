// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

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

pub const HzbError = error{ InvalidExtent, InvalidPolicy, DepthSizeMismatch, StorageTooSmall, LevelStorageTooSmall, CountOverflow };

pub fn maxHzbLevels(width: u32, height: u32) usize {
    if (width == 0 or height == 0) return 0;
    var w = width;
    var h = height;
    var levels: usize = 1;
    while (w > 1 or h > 1) : (levels += 1) {
        w = @max(@as(u32, 1), (w + 1) / 2);
        h = @max(@as(u32, 1), (h + 1) / 2);
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
        w = @max(@as(u32, 1), (w + 1) / 2);
        h = @max(@as(u32, 1), (h + 1) / 2);
    }
    return total;
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
    values: []f32,
    levels: []HzbLevel,
    level_count: usize,
    policy: HzbPolicy,

    pub fn build(depth: []const f32, width: u32, height: u32, policy: HzbPolicy, values: []f32, levels: []HzbLevel) HzbError!Hzb {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (!policy.valid()) return error.InvalidPolicy;
        const base64 = @as(u64, width) * @as(u64, height);
        if (base64 > std.math.maxInt(usize) or depth.len != @as(usize, @intCast(base64))) return error.DepthSizeMismatch;
        const needed_levels = maxHzbLevels(width, height);
        const needed_values = try hzbValueCount(width, height);
        if (levels.len < needed_levels) return error.LevelStorageTooSmall;
        if (values.len < needed_values) return error.StorageTooSmall;

        levels[0] = .{ .offset = 0, .width = width, .height = height, .footprint_shift = 0 };
        @memcpy(values[0..depth.len], depth);
        var offset = depth.len;
        var level_index: usize = 1;
        while (level_index < needed_levels) : (level_index += 1) {
            const previous = levels[level_index - 1];
            const next_w = @max(@as(u32, 1), (previous.width + 1) / 2);
            const next_h = @max(@as(u32, 1), (previous.height + 1) / 2);
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
                            const value = values[previous.offset + @as(usize, py) * @as(usize, previous.width) + @as(usize, px)];
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
        return .{ .values = values[0..needed_values], .levels = levels[0..needed_levels], .level_count = needed_levels, .policy = policy };
    }

    pub fn occludedAtLevel(self: Hzb, bounds: ScreenBounds, best_depth: f32, level_index: usize) bool {
        if (bounds.empty() or level_index >= self.level_count or !std.math.isFinite(best_depth)) return false;
        const base = self.levels[0];
        const clipped = bounds.clipped(base.width, base.height);
        if (clipped.empty()) return false;
        const level = self.levels[level_index];
        const shift = level.footprint_shift;
        const first_x = @min(level.width - 1, clipped.min_x >> shift);
        const first_y = @min(level.height - 1, clipped.min_y >> shift);
        const last_x = @min(level.width - 1, (clipped.max_x - 1) >> shift);
        const last_y = @min(level.height - 1, (clipped.max_y - 1) >> shift);
        var aggregate: f32 = 0;
        var have = false;
        var y = first_y;
        while (y <= last_y) : (y += 1) {
            var x = first_x;
            while (x <= last_x) : (x += 1) {
                const value = self.values[level.offset + @as(usize, y) * @as(usize, level.width) + @as(usize, x)];
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
    ordering: OrderingClass,
    draw_id: DrawId,
    cluster_id: ClusterId,
    material_id: MaterialId,
    first_triangle: u32,
    triangle_count: u16,
    path: RasterPath,
    extent: ExtentClass,
};

pub const BinError = error{ InvalidGeometry, HeaderStorageTooSmall, EntryStorageTooSmall, ScratchTooSmall, CountOverflow, InvalidHierarchy };
const GridRange = struct { x0: usize, x1: usize, y0: usize, y1: usize };

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
    return OrderKey.less(a.order_key, b.order_key);
}

fn stableSortPackets(packets: []TilePacket) void {
    var i: usize = 1;
    while (i < packets.len) : (i += 1) {
        const value = packets[i];
        var j = i;
        while (j != 0 and packetLess(value, packets[j - 1])) : (j -= 1) packets[j] = packets[j - 1];
        packets[j] = value;
    }
}

pub fn buildTilePacketsFromMacrobins(clusters: []const Cluster, surface_w: u32, surface_h: u32, macro_w: u32, macro_h: u32, macro_headers: []const MacrobinHeader, macro_entries: []const MacrobinRef, tile_w: u32, tile_h: u32, headers: []TileHeader, packets: []TilePacket, cursors: []u32) BinError!usize {
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
        for (macro_entries[begin..end]) |reference| {
            const cluster = clusters[@as(usize, reference.cluster_index)];
            const clipped = ScreenBounds{ .min_x = @max(cluster.bounds.min_x, macro_bounds.min_x), .min_y = @max(cluster.bounds.min_y, macro_bounds.min_y), .max_x = @min(cluster.bounds.max_x, macro_bounds.max_x), .max_y = @min(cluster.bounds.max_y, macro_bounds.max_y) };
            const range = gridRange(clipped, surface_w, surface_h, tile_w, tile_h, tile_columns, tile_rows) orelse continue;
            const extent = classifyExtent(range);
            var y = range.y0;
            while (y <= range.y1) : (y += 1) {
                var x = range.x0;
                while (x <= range.x1) : (x += 1) {
                    const tile = y * tile_columns + x;
                    const destination = @as(usize, cursors[tile]);
                    packets[destination] = .{ .order_key = cluster.order_key, .ordering = cluster.ordering, .draw_id = cluster.draw_id, .cluster_id = cluster.id, .material_id = cluster.material_id, .first_triangle = cluster.first_triangle, .triangle_count = cluster.triangle_count, .path = chooseRasterPath(cluster), .extent = extent };
                    cursors[tile] += 1;
                }
            }
        }
    }
    for (headers[0..tile_count]) |header| {
        const begin = @as(usize, header.offset);
        const end = begin + @as(usize, header.count);
        stableSortPackets(packets[begin..end]);
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

pub fn cullHierarchyHzb(nodes: []const ClusterNode, roots: []const u32, clusters: []const Cluster, hzb: Hzb, visible: []bool, stack: []u32) BinError!usize {
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
    const count = try buildTilePacketsFromMacrobins(&clusters, 16, 16, 16, 16, &mh, &me, 16, 16, &th, &packets, &tc);
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

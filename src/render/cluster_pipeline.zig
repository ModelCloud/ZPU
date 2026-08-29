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

/// One coarse geometry packet. The packet represents many source triangles;
/// triangle expansion is intentionally deferred until after coarse visibility.
pub const Cluster = struct {
    id: ClusterId,
    draw_id: DrawId,
    material_id: MaterialId,
    first_triangle: u32,
    triangle_count: u16,
    bounds: ScreenBounds,
    nearest_depth: f32,
};

pub const RasterPath = enum {
    primitive_simd,
    pixel_simd,
};

/// Tiny triangles are more naturally processed across primitives; larger
/// primitives expose enough covered pixels to vectorize across pixels.
pub fn chooseRasterPath(cluster: Cluster) RasterPath {
    if (cluster.triangle_count == 0 or cluster.bounds.empty()) return .primitive_simd;
    const pixels_per_triangle = cluster.bounds.area() / @as(u64, cluster.triangle_count);
    return if (pixels_per_triangle <= 16) .primitive_simd else .pixel_simd;
}

pub const Visibility = packed struct {
    primitive_id: u32,
    material_id: u32,
};

pub const invalid_visibility = Visibility{
    .primitive_id = std.math.maxInt(u32),
    .material_id = std.math.maxInt(u32),
};

/// Visibility storage is intentionally split from shading. Opaque raster can
/// publish compact primitive/material identity first; later shading operates
/// only on samples that survived depth/coverage.
pub const VisibilityBuffer = struct {
    ids: []Visibility,
    depth: []f32,
    width: u32,
    height: u32,

    pub fn init(ids: []Visibility, depth: []f32, width: u32, height: u32) !VisibilityBuffer {
        const count = @as(usize, width) * @as(usize, height);
        if (width == 0 or height == 0 or ids.len < count or depth.len < count) return error.InvalidVisibilityStorage;
        return .{ .ids = ids[0..count], .depth = depth[0..count], .width = width, .height = height };
    }

    pub fn clear(self: VisibilityBuffer, clear_depth: f32) void {
        @memset(self.ids, invalid_visibility);
        @memset(self.depth, clear_depth);
    }

    pub fn writeIfNearer(self: VisibilityBuffer, x: u32, y: u32, depth: f32, visibility: Visibility) bool {
        if (x >= self.width or y >= self.height or !std.math.isFinite(depth)) return false;
        const index = @as(usize, y) * @as(usize, self.width) + @as(usize, x);
        if (depth >= self.depth[index]) return false;
        self.depth[index] = depth;
        self.ids[index] = visibility;
        return true;
    }
};

pub const HzbLevel = struct {
    offset: usize,
    width: u32,
    height: u32,
};

pub const HzbError = error{
    InvalidExtent,
    DepthSizeMismatch,
    StorageTooSmall,
    LevelStorageTooSmall,
};

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

pub fn hzbValueCount(width: u32, height: u32) usize {
    if (width == 0 or height == 0) return 0;
    var total: usize = 0;
    var w = width;
    var h = height;
    while (true) {
        total += @as(usize, w) * @as(usize, h);
        if (w == 1 and h == 1) break;
        w = @max(@as(u32, 1), (w + 1) / 2);
        h = @max(@as(u32, 1), (h + 1) / 2);
    }
    return total;
}

/// A conservative HZB for a conventional 0-near/1-far LESS depth test.
/// Coarse levels store the farthest depth in each covered region. A cluster
/// can be rejected only when its nearest possible depth is farther than every
/// depth represented by the sampled coarse cells.
pub const Hzb = struct {
    values: []f32,
    levels: []HzbLevel,
    level_count: usize,

    pub fn build(depth: []const f32, width: u32, height: u32, values: []f32, levels: []HzbLevel) HzbError!Hzb {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (depth.len != @as(usize, width) * @as(usize, height)) return error.DepthSizeMismatch;
        const needed_levels = maxHzbLevels(width, height);
        const needed_values = hzbValueCount(width, height);
        if (levels.len < needed_levels) return error.LevelStorageTooSmall;
        if (values.len < needed_values) return error.StorageTooSmall;

        var offset: usize = 0;
        levels[0] = .{ .offset = 0, .width = width, .height = height };
        @memcpy(values[0..depth.len], depth);
        offset += depth.len;

        var level_index: usize = 1;
        while (level_index < needed_levels) : (level_index += 1) {
            const previous = levels[level_index - 1];
            const next_w = @max(@as(u32, 1), (previous.width + 1) / 2);
            const next_h = @max(@as(u32, 1), (previous.height + 1) / 2);
            levels[level_index] = .{ .offset = offset, .width = next_w, .height = next_h };
            var y: u32 = 0;
            while (y < next_h) : (y += 1) {
                var x: u32 = 0;
                while (x < next_w) : (x += 1) {
                    var farthest: f32 = 0.0;
                    var dy: u32 = 0;
                    while (dy < 2) : (dy += 1) {
                        const py = y * 2 + dy;
                        if (py >= previous.height) continue;
                        var dx: u32 = 0;
                        while (dx < 2) : (dx += 1) {
                            const px = x * 2 + dx;
                            if (px >= previous.width) continue;
                            const previous_index = previous.offset + @as(usize, py) * @as(usize, previous.width) + @as(usize, px);
                            farthest = @max(farthest, values[previous_index]);
                        }
                    }
                    const next_index = offset + @as(usize, y) * @as(usize, next_w) + @as(usize, x);
                    values[next_index] = farthest;
                }
            }
            offset += @as(usize, next_w) * @as(usize, next_h);
        }
        return .{ .values = values[0..needed_values], .levels = levels[0..needed_levels], .level_count = needed_levels };
    }

    pub fn occludedAtLevel(self: Hzb, bounds: ScreenBounds, nearest_depth: f32, level_index: usize) bool {
        if (bounds.empty() or level_index >= self.level_count or !std.math.isFinite(nearest_depth)) return false;
        const base = self.levels[0];
        const clipped = bounds.clipped(base.width, base.height);
        if (clipped.empty()) return false;
        const level = self.levels[level_index];
        const scale_x = @max(@as(u32, 1), (base.width + level.width - 1) / level.width);
        const scale_y = @max(@as(u32, 1), (base.height + level.height - 1) / level.height);
        const first_x = @min(level.width - 1, clipped.min_x / scale_x);
        const first_y = @min(level.height - 1, clipped.min_y / scale_y);
        const last_x = @min(level.width - 1, (clipped.max_x - 1) / scale_x);
        const last_y = @min(level.height - 1, (clipped.max_y - 1) / scale_y);

        var farthest: f32 = 0.0;
        var y = first_y;
        while (y <= last_y) : (y += 1) {
            var x = first_x;
            while (x <= last_x) : (x += 1) {
                const index = level.offset + @as(usize, y) * @as(usize, level.width) + @as(usize, x);
                farthest = @max(farthest, self.values[index]);
            }
        }
        return nearest_depth > farthest;
    }
};

pub fn chooseHzbLevel(bounds: ScreenBounds, level_count: usize) usize {
    if (level_count == 0 or bounds.empty()) return 0;
    var span = @max(bounds.max_x - bounds.min_x, bounds.max_y - bounds.min_y);
    var level: usize = 0;
    while (span > 2 and level + 1 < level_count) : (level += 1) span = (span + 1) / 2;
    return level;
}

pub const MacrobinHeader = struct {
    offset: u32 = 0,
    count: u32 = 0,
};

pub const MacrobinRef = struct {
    cluster_index: u32,
};

pub const BinError = error{
    InvalidGeometry,
    HeaderStorageTooSmall,
    EntryStorageTooSmall,
    ScratchTooSmall,
    CountOverflow,
};

const GridRange = struct {
    x0: usize,
    x1: usize,
    y0: usize,
    y1: usize,
};

fn gridRange(bounds: ScreenBounds, surface_w: u32, surface_h: u32, cell_w: u32, cell_h: u32, columns: usize, rows: usize) ?GridRange {
    const clipped = bounds.clipped(surface_w, surface_h);
    if (clipped.empty()) return null;
    return .{
        .x0 = @as(usize, clipped.min_x / cell_w),
        .x1 = @min(columns - 1, @as(usize, (clipped.max_x - 1) / cell_w)),
        .y0 = @as(usize, clipped.min_y / cell_h),
        .y1 = @min(rows - 1, @as(usize, (clipped.max_y - 1) / cell_h)),
    };
}

fn incrementCount(value: *u32) BinError!void {
    if (value.* == std.math.maxInt(u32)) return error.CountOverflow;
    value.* += 1;
}

fn selected(mask: ?[]const bool, index: usize) bool {
    return if (mask) |values| values[index] else true;
}

/// Two-pass contiguous macrobinner. No per-bin allocations and no linked
/// lists; the output is one dense reference array plus fixed headers.
pub fn buildMacrobins(
    clusters: []const Cluster,
    visible: ?[]const bool,
    surface_w: u32,
    surface_h: u32,
    macro_w: u32,
    macro_h: u32,
    headers: []MacrobinHeader,
    entries: []MacrobinRef,
    cursors: []u32,
) BinError!usize {
    if (visible) |mask| if (mask.len != clusters.len) return error.InvalidGeometry;
    if (surface_w == 0 or surface_h == 0 or macro_w == 0 or macro_h == 0) return error.InvalidGeometry;
    const columns = (@as(usize, surface_w) + @as(usize, macro_w) - 1) / @as(usize, macro_w);
    const rows = (@as(usize, surface_h) + @as(usize, macro_h) - 1) / @as(usize, macro_h);
    const bin_count = columns * rows;
    if (headers.len < bin_count) return error.HeaderStorageTooSmall;
    if (cursors.len < bin_count) return error.ScratchTooSmall;
    for (headers[0..bin_count]) |*header| header.* = .{};

    for (clusters, 0..) |cluster, cluster_index| {
        if (!selected(visible, cluster_index)) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, macro_w, macro_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) try incrementCount(&headers[y * columns + x].count);
        }
    }

    var total: usize = 0;
    for (headers[0..bin_count], 0..) |*header, index| {
        if (total > std.math.maxInt(u32)) return error.CountOverflow;
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        total += @as(usize, header.count);
    }
    if (entries.len < total) return error.EntryStorageTooSmall;

    for (clusters, 0..) |cluster, cluster_index| {
        if (!selected(visible, cluster_index)) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, macro_w, macro_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) {
                const bin = y * columns + x;
                const destination = @as(usize, cursors[bin]);
                entries[destination] = .{ .cluster_index = @intCast(cluster_index) };
                cursors[bin] += 1;
            }
        }
    }
    return total;
}

pub const TilePacket = struct {
    sequence: u64,
    draw_id: DrawId,
    cluster_id: ClusterId,
    material_id: MaterialId,
    first_triangle: u32,
    triangle_count: u16,
    path: RasterPath,
};

pub const TileHeader = struct {
    offset: u32 = 0,
    count: u32 = 0,
};

/// Expands visible coarse clusters into ordered tile packet streams. This
/// still emits cluster/range packets, never one entry per triangle.
pub fn buildTilePackets(
    clusters: []const Cluster,
    visible: []const bool,
    sequence_base: u64,
    surface_w: u32,
    surface_h: u32,
    tile_w: u32,
    tile_h: u32,
    headers: []TileHeader,
    packets: []TilePacket,
    cursors: []u32,
) BinError!usize {
    if (clusters.len != visible.len or surface_w == 0 or surface_h == 0 or tile_w == 0 or tile_h == 0) return error.InvalidGeometry;
    const columns = (@as(usize, surface_w) + @as(usize, tile_w) - 1) / @as(usize, tile_w);
    const rows = (@as(usize, surface_h) + @as(usize, tile_h) - 1) / @as(usize, tile_h);
    const tile_count = columns * rows;
    if (headers.len < tile_count) return error.HeaderStorageTooSmall;
    if (cursors.len < tile_count) return error.ScratchTooSmall;
    for (headers[0..tile_count]) |*header| header.* = .{};

    for (clusters, visible) |cluster, is_visible| {
        if (!is_visible) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, tile_w, tile_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) try incrementCount(&headers[y * columns + x].count);
        }
    }

    var total: usize = 0;
    for (headers[0..tile_count], 0..) |*header, index| {
        if (total > std.math.maxInt(u32)) return error.CountOverflow;
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        total += @as(usize, header.count);
    }
    if (packets.len < total) return error.EntryStorageTooSmall;

    for (clusters, visible, 0..) |cluster, is_visible, cluster_index| {
        if (!is_visible) continue;
        const range = gridRange(cluster.bounds, surface_w, surface_h, tile_w, tile_h, columns, rows) orelse continue;
        var y = range.y0;
        while (y <= range.y1) : (y += 1) {
            var x = range.x0;
            while (x <= range.x1) : (x += 1) {
                const tile = y * columns + x;
                const destination = @as(usize, cursors[tile]);
                packets[destination] = .{
                    .sequence = sequence_base + @as(u64, cluster_index),
                    .draw_id = cluster.draw_id,
                    .cluster_id = cluster.id,
                    .material_id = cluster.material_id,
                    .first_triangle = cluster.first_triangle,
                    .triangle_count = cluster.triangle_count,
                    .path = chooseRasterPath(cluster),
                };
                cursors[tile] += 1;
            }
        }
    }
    return total;
}

pub fn cullClustersHzb(clusters: []const Cluster, hzb: Hzb, visible: []bool) BinError!usize {
    if (clusters.len != visible.len) return error.InvalidGeometry;
    var count: usize = 0;
    for (clusters, visible) |cluster, *is_visible| {
        const level = chooseHzbLevel(cluster.bounds, hzb.level_count);
        is_visible.* = !hzb.occludedAtLevel(cluster.bounds, cluster.nearest_depth, level);
        if (is_visible.*) count += 1;
    }
    return count;
}

test "visibility buffer publishes only nearer samples" {
    var ids: [4]Visibility = undefined;
    var depth: [4]f32 = undefined;
    const visibility = try VisibilityBuffer.init(&ids, &depth, 2, 2);
    visibility.clear(1.0);
    try std.testing.expect(visibility.writeIfNearer(1, 0, 0.4, .{ .primitive_id = 3, .material_id = 9 }));
    try std.testing.expect(!visibility.writeIfNearer(1, 0, 0.6, .{ .primitive_id = 4, .material_id = 10 }));
    try std.testing.expectEqual(@as(u32, 3), visibility.ids[1].primitive_id);
    try std.testing.expectApproxEqAbs(@as(f32, 0.4), visibility.depth[1], 0.00001);
}

test "HZB stores conservative farthest depth and rejects hidden clusters" {
    const depth = [_]f32{
        0.2, 0.3, 0.4, 0.5,
        0.1, 0.2, 0.3, 0.4,
        0.2, 0.2, 0.2, 0.2,
        0.1, 0.1, 0.1, 0.1,
    };
    var values: [21]f32 = undefined;
    var levels: [3]HzbLevel = undefined;
    const hzb = try Hzb.build(&depth, 4, 4, &values, &levels);
    try std.testing.expectEqual(@as(usize, 3), hzb.level_count);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), hzb.values[hzb.levels[2].offset], 0.00001);
    try std.testing.expect(hzb.occludedAtLevel(.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, 0.8, 2));
    try std.testing.expect(!hzb.occludedAtLevel(.{ .min_x = 0, .min_y = 0, .max_x = 4, .max_y = 4 }, 0.3, 2));
}

test "HZB holes remain conservative" {
    const depth = [_]f32{ 0.2, 0.2, 0.2, 1.0 };
    var values: [5]f32 = undefined;
    var levels: [2]HzbLevel = undefined;
    const hzb = try Hzb.build(&depth, 2, 2, &values, &levels);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), hzb.values[hzb.levels[1].offset], 0.00001);
    try std.testing.expect(!hzb.occludedAtLevel(.{ .min_x = 0, .min_y = 0, .max_x = 2, .max_y = 2 }, 0.8, 1));
}

test "macrobins and tile packets keep clusters coarse" {
    const clusters = [_]Cluster{
        .{ .id = 10, .draw_id = 1, .material_id = 7, .first_triangle = 0, .triangle_count = 128, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 40, .max_y = 40 }, .nearest_depth = 0.2 },
        .{ .id = 11, .draw_id = 1, .material_id = 7, .first_triangle = 128, .triangle_count = 64, .bounds = .{ .min_x = 48, .min_y = 0, .max_x = 64, .max_y = 16 }, .nearest_depth = 0.3 },
    };
    var macro_headers: [4]MacrobinHeader = undefined;
    var macro_entries: [8]MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    const macro_count = try buildMacrobins(&clusters, null, 64, 64, 32, 32, &macro_headers, &macro_entries, &macro_cursors);
    try std.testing.expectEqual(@as(usize, 5), macro_count);

    const visible = [_]bool{ true, true };
    var tile_headers: [16]TileHeader = undefined;
    var packets: [32]TilePacket = undefined;
    var tile_cursors: [16]u32 = undefined;
    const packet_count = try buildTilePackets(&clusters, &visible, 1000, 64, 64, 16, 16, &tile_headers, &packets, &tile_cursors);
    try std.testing.expect(packet_count > 2);
    for (packets[0..packet_count]) |packet| {
        try std.testing.expect(packet.triangle_count == 128 or packet.triangle_count == 64);
    }
}

test "macrobinner skips HZB-culled clusters" {
    const clusters = [_]Cluster{
        .{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 64, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 32, .max_y = 32 }, .nearest_depth = 0.2 },
        .{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 64, .triangle_count = 64, .bounds = .{ .min_x = 32, .min_y = 0, .max_x = 64, .max_y = 32 }, .nearest_depth = 0.9 },
    };
    const visible = [_]bool{ true, false };
    var headers: [2]MacrobinHeader = undefined;
    var entries: [2]MacrobinRef = undefined;
    var cursors: [2]u32 = undefined;
    const count = try buildMacrobins(&clusters, &visible, 64, 32, 32, 32, &headers, &entries, &cursors);
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(@as(u32, 0), entries[0].cluster_index);
}

test "off-screen clusters do not alias the last bin" {
    const clusters = [_]Cluster{
        .{ .id = 7, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 32, .bounds = .{ .min_x = 1000, .min_y = 1000, .max_x = 1100, .max_y = 1100 }, .nearest_depth = 0.2 },
    };
    var headers: [4]MacrobinHeader = undefined;
    var entries: [1]MacrobinRef = undefined;
    var cursors: [4]u32 = undefined;
    const count = try buildMacrobins(&clusters, null, 64, 64, 32, 32, &headers, &entries, &cursors);
    try std.testing.expectEqual(@as(usize, 0), count);
}

test "raster path separates tiny and broad clusters" {
    const tiny = Cluster{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 128, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .nearest_depth = 0.2 };
    const broad = Cluster{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 2, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .nearest_depth = 0.2 };
    try std.testing.expectEqual(RasterPath.primitive_simd, chooseRasterPath(tiny));
    try std.testing.expectEqual(RasterPath.pixel_simd, chooseRasterPath(broad));
}

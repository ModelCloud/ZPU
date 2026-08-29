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
        return @as(u64, self.max_x - self.min_x) * (self.max_y - self.min_y);
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
    const pixels = cluster.bounds.area();
    const pixels_per_triangle = pixels / cluster.triangle_count;
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
        total += @as(usize, w) * h;
        if (w == 1 and h == 1) break;
        w = @max(@as(u32, 1), (w + 1) / 2);
        h = @max(@as(u32, 1), (h + 1) / 2);
    }
    return total;
}

/// A conservative HZB for a conventional 0-near/1-far depth test. Coarse
/// levels store the *farthest* depth in their covered region. A cluster can be
/// rejected only when its nearest possible depth is farther than that value.
pub const Hzb = struct {
    values: []f32,
    levels: []HzbLevel,
    level_count: usize,

    pub fn build(depth: []const f32, width: u32, height: u32, values: []f32, levels: []HzbLevel) HzbError!Hzb {
        if (width == 0 or height == 0) return error.InvalidExtent;
        if (depth.len != @as(usize, width) * height) return error.DepthSizeMismatch;
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
                            const value = values[previous.offset + @as(usize, py) * previous.width + px];
                            farthest = @max(farthest, value);
                        }
                    }
                    values[offset + @as(usize, y) * next_w + x] = farthest;
                }
            }
            offset += @as(usize, next_w) * next_h;
        }
        return .{ .values = values[0..needed_values], .levels = levels[0..needed_levels], .level_count = needed_levels };
    }

    /// Tests one rectangle against one conservative level. The caller chooses
    /// a level whose texel footprint approximately matches the cluster bounds.
    pub fn occludedAtLevel(self: Hzb, bounds: ScreenBounds, nearest_depth: f32, level_index: usize) bool {
        if (bounds.empty() or level_index >= self.level_count) return false;
        const base = self.levels[0];
        const level = self.levels[level_index];
        const scale_x = @max(@as(u32, 1), (base.width + level.width - 1) / level.width);
        const scale_y = @max(@as(u32, 1), (base.height + level.height - 1) / level.height);
        const first_x = @min(level.width - 1, bounds.min_x / scale_x);
        const first_y = @min(level.height - 1, bounds.min_y / scale_y);
        const last_x = @min(level.width - 1, (bounds.max_x - 1) / scale_x);
        const last_y = @min(level.height - 1, (bounds.max_y - 1) / scale_y);

        var farthest: f32 = 0.0;
        var y = first_y;
        while (y <= last_y) : (y += 1) {
            var x = first_x;
            while (x <= last_x) : (x += 1) {
                farthest = @max(farthest, self.values[level.offset + @as(usize, y) * level.width + x]);
            }
        }
        return nearest_depth > farthest;
    }
};

pub fn chooseHzbLevel(width: u32, height: u32, bounds: ScreenBounds, level_count: usize) usize {
    if (level_count == 0 or bounds.empty()) return 0;
    var span = @max(bounds.max_x - bounds.min_x, bounds.max_y - bounds.min_y);
    var level: usize = 0;
    while (span > 2 and level + 1 < level_count) : (level += 1) span = (span + 1) / 2;
    _ = width;
    _ = height;
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
};

/// Two-pass contiguous macrobinner. No per-bin allocations and no linked
/// lists; the output is one dense reference array plus fixed headers.
pub fn buildMacrobins(
    clusters: []const Cluster,
    surface_w: u32,
    surface_h: u32,
    macro_w: u32,
    macro_h: u32,
    headers: []MacrobinHeader,
    entries: []MacrobinRef,
    cursors: []u32,
) BinError!usize {
    if (surface_w == 0 or surface_h == 0 or macro_w == 0 or macro_h == 0) return error.InvalidGeometry;
    const columns = (@as(usize, surface_w) + macro_w - 1) / macro_w;
    const rows = (@as(usize, surface_h) + macro_h - 1) / macro_h;
    const bin_count = columns * rows;
    if (headers.len < bin_count) return error.HeaderStorageTooSmall;
    if (cursors.len < bin_count) return error.ScratchTooSmall;
    for (headers[0..bin_count]) |*header| header.* = .{};

    for (clusters) |cluster| {
        if (cluster.bounds.empty()) continue;
        const x0 = @min(columns - 1, cluster.bounds.min_x / macro_w);
        const x1 = @min(columns - 1, (cluster.bounds.max_x - 1) / macro_w);
        const y0 = @min(rows - 1, cluster.bounds.min_y / macro_h);
        const y1 = @min(rows - 1, (cluster.bounds.max_y - 1) / macro_h);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) headers[y * columns + x].count += 1;
        }
    }

    var total: usize = 0;
    for (headers[0..bin_count], 0..) |*header, index| {
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        total += header.count;
    }
    if (entries.len < total) return error.EntryStorageTooSmall;

    for (clusters, 0..) |cluster, cluster_index| {
        if (cluster.bounds.empty()) continue;
        const x0 = @min(columns - 1, cluster.bounds.min_x / macro_w);
        const x1 = @min(columns - 1, (cluster.bounds.max_x - 1) / macro_w);
        const y0 = @min(rows - 1, cluster.bounds.min_y / macro_h);
        const y1 = @min(rows - 1, (cluster.bounds.max_y - 1) / macro_h);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const bin = y * columns + x;
                const destination = cursors[bin];
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
    const columns = (@as(usize, surface_w) + tile_w - 1) / tile_w;
    const rows = (@as(usize, surface_h) + tile_h - 1) / tile_h;
    const tile_count = columns * rows;
    if (headers.len < tile_count) return error.HeaderStorageTooSmall;
    if (cursors.len < tile_count) return error.ScratchTooSmall;
    for (headers[0..tile_count]) |*header| header.* = .{};

    for (clusters, visible) |cluster, is_visible| {
        if (!is_visible or cluster.bounds.empty()) continue;
        const x0 = @min(columns - 1, cluster.bounds.min_x / tile_w);
        const x1 = @min(columns - 1, (cluster.bounds.max_x - 1) / tile_w);
        const y0 = @min(rows - 1, cluster.bounds.min_y / tile_h);
        const y1 = @min(rows - 1, (cluster.bounds.max_y - 1) / tile_h);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) headers[y * columns + x].count += 1;
        }
    }

    var total: usize = 0;
    for (headers[0..tile_count], 0..) |*header, index| {
        header.offset = @intCast(total);
        cursors[index] = header.offset;
        total += header.count;
    }
    if (packets.len < total) return error.EntryStorageTooSmall;

    for (clusters, visible, 0..) |cluster, is_visible, cluster_index| {
        if (!is_visible or cluster.bounds.empty()) continue;
        const x0 = @min(columns - 1, cluster.bounds.min_x / tile_w);
        const x1 = @min(columns - 1, (cluster.bounds.max_x - 1) / tile_w);
        const y0 = @min(rows - 1, cluster.bounds.min_y / tile_h);
        const y1 = @min(rows - 1, (cluster.bounds.max_y - 1) / tile_h);
        var y = y0;
        while (y <= y1) : (y += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                const tile = y * columns + x;
                const destination = cursors[tile];
                packets[destination] = .{
                    .sequence = sequence_base + cluster_index,
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
        const level = chooseHzbLevel(hzb.levels[0].width, hzb.levels[0].height, cluster.bounds, hzb.level_count);
        is_visible.* = !hzb.occludedAtLevel(cluster.bounds, cluster.nearest_depth, level);
        if (is_visible.*) count += 1;
    }
    return count;
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

test "macrobins and tile packets keep clusters coarse" {
    const clusters = [_]Cluster{
        .{ .id = 10, .draw_id = 1, .material_id = 7, .first_triangle = 0, .triangle_count = 128, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 40, .max_y = 40 }, .nearest_depth = 0.2 },
        .{ .id = 11, .draw_id = 1, .material_id = 7, .first_triangle = 128, .triangle_count = 64, .bounds = .{ .min_x = 48, .min_y = 0, .max_x = 64, .max_y = 16 }, .nearest_depth = 0.3 },
    };
    var macro_headers: [4]MacrobinHeader = undefined;
    var macro_entries: [8]MacrobinRef = undefined;
    var macro_cursors: [4]u32 = undefined;
    const macro_count = try buildMacrobins(&clusters, 64, 64, 32, 32, &macro_headers, &macro_entries, &macro_cursors);
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

test "raster path separates tiny and broad clusters" {
    const tiny = Cluster{ .id = 1, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 128, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 16, .max_y = 16 }, .nearest_depth = 0.2 };
    const broad = Cluster{ .id = 2, .draw_id = 1, .material_id = 1, .first_triangle = 0, .triangle_count = 2, .bounds = .{ .min_x = 0, .min_y = 0, .max_x = 128, .max_y = 128 }, .nearest_depth = 0.2 };
    try std.testing.expectEqual(RasterPath.primitive_simd, chooseRasterPath(tiny));
    try std.testing.expectEqual(RasterPath.pixel_simd, chooseRasterPath(broad));
}

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
const builtin = @import("builtin");
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

pub const Error = error{ InvalidSurface, InvalidRange, InvalidPacketStream, CountOverflow, SchedulerUnavailable, PlanStorageTooSmall, TopologyMismatch };

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

fn validatePhysicalPacket(packet: pipeline.TilePacket, primitives: []const prepared.PreparedPrimitive, ranges: []const PreparedCluster, clusters: []const pipeline.Cluster) Error!void {
    if (packet.source_cluster_index >= clusters.len or packet.source_cluster_index >= ranges.len) return error.InvalidPacketStream;
    const range = ranges[@as(usize, packet.source_cluster_index)];
    const end = rangeEnd(range.first_primitive, range.primitive_count) orelse return error.InvalidPacketStream;
    if (end > primitives.len) return error.InvalidPacketStream;
}

fn validatePhysicalStreams(
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    columns: usize,
    rows: usize,
    local_packets: []const pipeline.LocalPacket,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
) Error!void {
    for (local_packets) |entry| {
        if (entry.packet.extent != .local or @as(usize, entry.tile_x) >= columns or @as(usize, entry.tile_y) >= rows) return error.InvalidPacketStream;
        try validatePhysicalPacket(entry.packet, primitives, ranges, clusters);
    }
    for (macro_packets) |entry| {
        if (entry.packet.extent != .macro or entry.tile_range.min_x >= entry.tile_range.max_x or entry.tile_range.min_y >= entry.tile_range.max_y or
            @as(usize, entry.tile_range.max_x) > columns or @as(usize, entry.tile_range.max_y) > rows) return error.InvalidPacketStream;
        try validatePhysicalPacket(entry.packet, primitives, ranges, clusters);
    }
    for (global_packets) |entry| {
        if (entry.packet.extent != .global) return error.InvalidPacketStream;
        try validatePhysicalPacket(entry.packet, primitives, ranges, clusters);
    }
}

fn physicalTileClip(surface: Surface, tile_w: u32, tile_h: u32, tile_x: usize, tile_y: usize) pipeline.ScreenBounds {
    return .{
        .min_x = @intCast(tile_x * @as(usize, tile_w)),
        .min_y = @intCast(tile_y * @as(usize, tile_h)),
        .max_x = @min(surface.width, @as(u32, @intCast((tile_x + 1) * @as(usize, tile_w)))),
        .max_y = @min(surface.height, @as(u32, @intCast((tile_y + 1) * @as(usize, tile_h)))),
    };
}

fn renderPhysicalTile(
    surface: Surface,
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    tile_w: u32,
    tile_h: u32,
    local_packets: []const pipeline.LocalPacket,
    local_packet_indices: []const u32,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
    tile_x: usize,
    tile_y: usize,
    counters: *Counters,
) Error!void {
    const clip = physicalTileClip(surface, tile_w, tile_h, tile_x, tile_y);
    var local_index: usize = 0;
    var macro_index: usize = 0;
    var global_index: usize = 0;
    while (true) {
        while (macro_index < macro_packets.len and
            !tileInRange(@intCast(tile_x), @intCast(tile_y), macro_packets[macro_index].tile_range)) macro_index += 1;
        while (global_index < global_packets.len and
            !physicalPacketTouchesTile(global_packets[global_index].packet, clusters, @intCast(tile_x), @intCast(tile_y), surface.width, surface.height, tile_w, tile_h)) global_index += 1;

        if (local_index == local_packet_indices.len and macro_index == macro_packets.len and global_index == global_packets.len) break;
        const local_packet = if (local_index < local_packet_indices.len) local_packets[local_packet_indices[local_index]].packet else null;
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
            0 => local_packets[local_packet_indices[local_index]].packet,
            1 => macro_packets[macro_index].packet,
            else => global_packets[global_index].packet,
        };
        // Setup accounting is performed once before parallel tile execution.
        // The tile workers only rasterize their disjoint sample rectangles.
        try renderCluster(surface, primitives, ranges, selected_packet.source_cluster_index, clip, false, counters);
        switch (selected) {
            0 => local_index += 1,
            1 => macro_index += 1,
            else => global_index += 1,
        }
    }
}

fn addPacketCounters(total: *Counters, value: Counters) void {
    total.primitive_tests += value.primitive_tests;
    total.samples_tested += value.samples_tested;
    total.samples_covered += value.samples_covered;
    total.depth_tests_passed += value.depth_tests_passed;
    total.color_writes += value.color_writes;
}

pub const WorkerTopology = struct {
    /// Optional OS CPU ID. When present, the queue owner is pinned before it
    /// touches render memory, making spatial ownership physical rather than a
    /// scheduler hint.
    cpu: ?u32 = null,
    numa: u16 = 0,
    llc: u16 = 0,
};

pub const PacketLoadOp = union(enum) {
    load,
    clear: struct {
        color: u32,
        depth: f32,
    },
};

pub const PacketSchedulerConfig = struct {
    worker_count: usize,
    group_w: u32 = 4,
    group_h: u32 = 4,
    load_op: PacketLoadOp = .load,
    /// Empty means one NUMA/LLC domain. A supplied topology must contain one
    /// entry per worker and all workers must belong to the same NUMA node.
    topology: []const WorkerTopology = &.{},
};

const max_packet_workers = 128;
pub const PacketWorkItem = struct {
    first_tile_x: u32,
    first_tile_y: u32,
    last_tile_x: u32,
    last_tile_y: u32,
    morton: u64,
};

pub const PacketWorkerQueue = struct {
    first_item: u32,
    item_count: u32,
    topology: WorkerTopology,
};

pub const PacketTileHeader = struct {
    offset: u32 = 0,
    count: u32 = 0,
};

pub const PacketWorkPlan = struct {
    surface_w: u32,
    surface_h: u32,
    tile_w: u32,
    tile_h: u32,
    columns: u32,
    rows: u32,
    items: []const PacketWorkItem,
    queues: []const PacketWorkerQueue,
    local_headers: []const PacketTileHeader,
    local_indices: []const u32,
    load_op: PacketLoadOp,
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    local_packets: []const pipeline.LocalPacket,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
    active_clusters: []const u32,
    setup_primitive_tests: u64,
};

pub const PacketPlanStorage = struct {
    items: []PacketWorkItem,
    queues: []PacketWorkerQueue,
    local_headers: []PacketTileHeader,
    local_indices: []u32,
    active_clusters: []u32,
    cluster_seen: []bool,
};

pub const PacketSchedulerStats = struct {
    work_items: u64 = 0,
    owner_items: u64 = 0,
    same_llc_steals: u64 = 0,
    same_numa_steals: u64 = 0,
};

fn morton2D(x: u32, y: u32) u64 {
    var result: u64 = 0;
    for (0..32) |bit| {
        result |= (@as(u64, (x >> @intCast(bit)) & 1) << @intCast(bit * 2));
        result |= (@as(u64, (y >> @intCast(bit)) & 1) << @intCast(bit * 2 + 1));
    }
    return result;
}

fn workItemBefore(_: void, a: PacketWorkItem, b: PacketWorkItem) bool {
    return a.morton < b.morton;
}

fn partitionStart(total: usize, partitions: usize, index: usize) usize {
    const base = total / partitions;
    const remainder = total % partitions;
    return index * base + @min(index, remainder);
}

/// Build an immutable, spatially ordered pass plan. Contiguous Morton ranges
/// give each core an initial block of the render grid; execution state lives in
/// separate cache-line-isolated queue cursors.
pub fn buildPacketWorkPlan(
    surface_w: u32,
    surface_h: u32,
    tile_w: u32,
    tile_h: u32,
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    local_packets: []const pipeline.LocalPacket,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
    config: PacketSchedulerConfig,
    storage: PacketPlanStorage,
) Error!PacketWorkPlan {
    if (surface_w == 0 or surface_h == 0 or tile_w == 0 or tile_h == 0 or config.worker_count == 0 or config.worker_count > max_packet_workers or config.group_w == 0 or config.group_h == 0) return error.InvalidPacketStream;
    if (config.topology.len != 0 and config.topology.len < config.worker_count) return error.TopologyMismatch;
    if (config.topology.len != 0) {
        const numa = config.topology[0].numa;
        for (config.topology[0..config.worker_count]) |topology| if (topology.numa != numa) return error.TopologyMismatch;
    }
    const columns = (@as(usize, surface_w) + tile_w - 1) / tile_w;
    const rows = (@as(usize, surface_h) + tile_h - 1) / tile_h;
    if (columns == 0 or rows == 0 or columns > std.math.maxInt(u32) or rows > std.math.maxInt(u32)) return error.InvalidPacketStream;
    const group_w = @as(usize, config.group_w);
    const group_h = @as(usize, config.group_h);
    const group_columns = (columns + group_w - 1) / group_w;
    const group_rows = (rows + group_h - 1) / group_h;
    const group_count = group_columns * group_rows;
    if (group_count == 0 or group_count > std.math.maxInt(u32)) return error.InvalidPacketStream;
    const tile_count = columns * rows;
    if (local_packets.len > std.math.maxInt(u32) or storage.items.len < group_count or storage.queues.len < config.worker_count or
        storage.local_headers.len < tile_count or storage.local_indices.len < local_packets.len or storage.active_clusters.len < clusters.len or storage.cluster_seen.len < clusters.len) return error.PlanStorageTooSmall;
    if (ranges.len != clusters.len) return error.InvalidPacketStream;
    try validatePhysicalStreams(primitives, ranges, clusters, columns, rows, local_packets, macro_packets, global_packets);

    @memset(storage.cluster_seen[0..clusters.len], false);
    var active_cluster_count: usize = 0;
    var setup_primitive_tests: u64 = 0;
    const remember = struct {
        fn one(packet: pipeline.TilePacket, ranges_: []const PreparedCluster, seen: []bool, active: []u32, active_count: *usize, setup_count: *u64) void {
            const index = @as(usize, packet.source_cluster_index);
            if (seen[index]) return;
            seen[index] = true;
            active[active_count.*] = packet.source_cluster_index;
            active_count.* += 1;
            setup_count.* += ranges_[index].primitive_count;
        }
    }.one;
    for (local_packets) |entry| remember(entry.packet, ranges, storage.cluster_seen, storage.active_clusters, &active_cluster_count, &setup_primitive_tests);
    for (macro_packets) |entry| remember(entry.packet, ranges, storage.cluster_seen, storage.active_clusters, &active_cluster_count, &setup_primitive_tests);
    for (global_packets) |entry| remember(entry.packet, ranges, storage.cluster_seen, storage.active_clusters, &active_cluster_count, &setup_primitive_tests);

    @memset(storage.local_headers[0..tile_count], .{});
    for (local_packets) |entry| {
        if (entry.packet.extent != .local or @as(usize, entry.tile_x) >= columns or @as(usize, entry.tile_y) >= rows) return error.InvalidPacketStream;
        const tile_index = @as(usize, entry.tile_y) * columns + @as(usize, entry.tile_x);
        if (storage.local_headers[tile_index].count == std.math.maxInt(u32)) return error.CountOverflow;
        storage.local_headers[tile_index].count += 1;
    }
    var local_offset: u32 = 0;
    for (storage.local_headers[0..tile_count]) |*header| {
        const count = header.count;
        header.* = .{ .offset = local_offset };
        local_offset += count;
    }
    for (local_packets, 0..) |entry, packet_index| {
        const tile_index = @as(usize, entry.tile_y) * columns + @as(usize, entry.tile_x);
        const header = &storage.local_headers[tile_index];
        storage.local_indices[@as(usize, header.offset) + @as(usize, header.count)] = @intCast(packet_index);
        header.count += 1;
    }

    var item_index: usize = 0;
    for (0..group_rows) |group_y| for (0..group_columns) |group_x| {
        const first_x = group_x * group_w;
        const first_y = group_y * group_h;
        storage.items[item_index] = .{
            .first_tile_x = @intCast(first_x),
            .first_tile_y = @intCast(first_y),
            .last_tile_x = @intCast(@min(columns, first_x + group_w)),
            .last_tile_y = @intCast(@min(rows, first_y + group_h)),
            .morton = morton2D(@intCast(group_x), @intCast(group_y)),
        };
        item_index += 1;
    };
    std.mem.sort(PacketWorkItem, storage.items[0..group_count], {}, workItemBefore);

    for (0..config.worker_count) |worker_index| {
        const first = partitionStart(group_count, config.worker_count, worker_index);
        const end = partitionStart(group_count, config.worker_count, worker_index + 1);
        storage.queues[worker_index] = .{
            .first_item = @intCast(first),
            .item_count = @intCast(end - first),
            .topology = if (config.topology.len == 0) .{} else config.topology[worker_index],
        };
    }
    return .{
        .surface_w = surface_w,
        .surface_h = surface_h,
        .tile_w = tile_w,
        .tile_h = tile_h,
        .columns = @intCast(columns),
        .rows = @intCast(rows),
        .items = storage.items[0..group_count],
        .queues = storage.queues[0..config.worker_count],
        .local_headers = storage.local_headers[0..tile_count],
        .local_indices = storage.local_indices[0..local_packets.len],
        .load_op = config.load_op,
        .primitives = primitives,
        .ranges = ranges,
        .clusters = clusters,
        .local_packets = local_packets,
        .macro_packets = macro_packets,
        .global_packets = global_packets,
        .active_clusters = storage.active_clusters[0..active_cluster_count],
        .setup_primitive_tests = setup_primitive_tests,
    };
}

const QueueCursor = struct {
    next: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    padding: [64 - @sizeOf(std.atomic.Value(usize))]u8 = [_]u8{0} ** (64 - @sizeOf(std.atomic.Value(usize))),
};

const WorkerPacketResult = struct {
    counters: Counters = .{},
    stats: PacketSchedulerStats = .{},
    padding: [128 - @sizeOf(Counters) - @sizeOf(PacketSchedulerStats)]u8 = [_]u8{0} ** (128 - @sizeOf(Counters) - @sizeOf(PacketSchedulerStats)),
};

fn pinPacketWorker(topology: WorkerTopology) bool {
    const cpu = topology.cpu orelse return true;
    if (builtin.os.tag != .linux) return false;
    const CpuSet = std.os.linux.cpu_set_t;
    const bit_count = @sizeOf(CpuSet) * 8;
    if (cpu >= bit_count) return false;
    const bits_per_word = @bitSizeOf(usize);
    var set = [_]usize{0} ** @typeInfo(CpuSet).array.len;
    set[@as(usize, cpu) / bits_per_word] |= @as(usize, 1) << @intCast(@as(usize, cpu) % bits_per_word);
    std.os.linux.sched_setaffinity(0, &set) catch return false;
    return true;
}

fn applyPacketLoad(surface: Surface, clip: pipeline.ScreenBounds, load_op: PacketLoadOp) void {
    switch (load_op) {
        .load => {},
        .clear => |value| {
            var y = clip.min_y;
            while (y < clip.max_y) : (y += 1) {
                const first = @as(usize, y) * @as(usize, surface.width) + @as(usize, clip.min_x);
                const end = first + @as(usize, clip.max_x - clip.min_x);
                @memset(surface.color[first..end], value.color);
                @memset(surface.depth[first..end], value.depth);
                @memset(surface.visibility[first..end], pipeline.invalid_visibility);
            }
        },
    }
}

const PhysicalPacketParallelContext = struct {
    surface: Surface,
    primitives: []const prepared.PreparedPrimitive,
    ranges: []const PreparedCluster,
    clusters: []const pipeline.Cluster,
    tile_w: u32,
    tile_h: u32,
    local_packets: []const pipeline.LocalPacket,
    macro_packets: []const pipeline.MacroPacket,
    global_packets: []const pipeline.GlobalPacket,
    plan: PacketWorkPlan,
    cursors: [max_packet_workers]QueueCursor = [_]QueueCursor{.{}} ** max_packet_workers,
    failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ready_workers: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    dispatch: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    results: [max_packet_workers]WorkerPacketResult = [_]WorkerPacketResult{.{}} ** max_packet_workers,
};

const WorkClaimClass = enum { owner, same_llc, same_numa };

const WorkClaim = struct {
    item: PacketWorkItem,
    class: WorkClaimClass,
};

fn claimQueue(context: *PhysicalPacketParallelContext, queue_index: usize, class: WorkClaimClass) ?WorkClaim {
    const queue = context.plan.queues[queue_index];
    const position = context.cursors[queue_index].next.fetchAdd(1, .monotonic);
    if (position >= @as(usize, queue.item_count)) return null;
    return .{ .item = context.plan.items[@as(usize, queue.first_item) + position], .class = class };
}

fn claimWork(context: *PhysicalPacketParallelContext, worker_index: usize) ?WorkClaim {
    if (claimQueue(context, worker_index, .owner)) |claim| return claim;
    const topology = context.plan.queues[worker_index].topology;
    for (1..context.plan.queues.len) |offset| {
        const candidate = (worker_index + offset) % context.plan.queues.len;
        const other = context.plan.queues[candidate].topology;
        if (other.numa == topology.numa and other.llc == topology.llc) if (claimQueue(context, candidate, .same_llc)) |claim| return claim;
    }
    for (1..context.plan.queues.len) |offset| {
        const candidate = (worker_index + offset) % context.plan.queues.len;
        const other = context.plan.queues[candidate].topology;
        if (other.numa == topology.numa and other.llc != topology.llc) if (claimQueue(context, candidate, .same_numa)) |claim| return claim;
    }
    return null;
}

fn runPhysicalPacketWorker(context: *PhysicalPacketParallelContext, worker_index: usize) void {
    while (!context.failed.load(.acquire)) {
        const claim = claimWork(context, worker_index) orelse return;
        context.results[worker_index].stats.work_items += 1;
        switch (claim.class) {
            .owner => context.results[worker_index].stats.owner_items += 1,
            .same_llc => context.results[worker_index].stats.same_llc_steals += 1,
            .same_numa => context.results[worker_index].stats.same_numa_steals += 1,
        }
        var tile_y = @as(usize, claim.item.first_tile_y);
        while (tile_y < @as(usize, claim.item.last_tile_y)) : (tile_y += 1) {
            var tile_x = @as(usize, claim.item.first_tile_x);
            while (tile_x < @as(usize, claim.item.last_tile_x)) : (tile_x += 1) {
                const tile_index = tile_y * @as(usize, context.plan.columns) + tile_x;
                const local_header = context.plan.local_headers[tile_index];
                const local_end = @as(usize, local_header.offset) + @as(usize, local_header.count);
                applyPacketLoad(context.surface, physicalTileClip(context.surface, context.tile_w, context.tile_h, tile_x, tile_y), context.plan.load_op);
                renderPhysicalTile(
                    context.surface,
                    context.primitives,
                    context.ranges,
                    context.clusters,
                    context.tile_w,
                    context.tile_h,
                    context.local_packets,
                    context.plan.local_indices[@as(usize, local_header.offset)..local_end],
                    context.macro_packets,
                    context.global_packets,
                    tile_x,
                    tile_y,
                    &context.results[worker_index].counters,
                ) catch {
                    context.failed.store(true, .release);
                    return;
                };
            }
        }
    }
}

fn startPhysicalPacketWorker(context: *PhysicalPacketParallelContext, worker_index: usize) void {
    if (!pinPacketWorker(context.plan.queues[worker_index].topology)) {
        context.failed.store(true, .release);
    }
    _ = context.ready_workers.fetchAdd(1, .release);
    while (!context.dispatch.load(.acquire) and !context.failed.load(.acquire)) {
        std.atomic.spinLoopHint();
    }
    if (!context.failed.load(.acquire)) runPhysicalPacketWorker(context, worker_index);
}

fn validatePacketExecution(surface: Surface, seen_clusters: []bool, plan: PacketWorkPlan) Error!void {
    if (plan.tile_w == 0 or plan.tile_h == 0 or plan.ranges.len != plan.clusters.len or seen_clusters.len < plan.ranges.len or
        plan.queues.len == 0 or plan.queues.len > max_packet_workers or plan.surface_w != surface.width or plan.surface_h != surface.height) return error.InvalidPacketStream;
    const columns = (@as(usize, surface.width) + plan.tile_w - 1) / plan.tile_w;
    const rows = (@as(usize, surface.height) + plan.tile_h - 1) / plan.tile_h;
    const tile_count = columns * rows;
    if (columns == 0 or rows == 0 or tile_count > std.math.maxInt(u32) or
        @as(usize, plan.columns) != columns or @as(usize, plan.rows) != rows or
        plan.local_headers.len != tile_count or plan.local_indices.len != plan.local_packets.len) return error.InvalidPacketStream;
}

fn preparePacketContext(surface: Surface, seen_clusters: []bool, plan: PacketWorkPlan) PhysicalPacketParallelContext {
    @memset(seen_clusters[0..plan.ranges.len], false);
    for (plan.active_clusters) |cluster_index| seen_clusters[cluster_index] = true;
    return .{
        .surface = surface,
        .primitives = plan.primitives,
        .ranges = plan.ranges,
        .clusters = plan.clusters,
        .tile_w = plan.tile_w,
        .tile_h = plan.tile_h,
        .local_packets = plan.local_packets,
        .macro_packets = plan.macro_packets,
        .global_packets = plan.global_packets,
        .plan = plan,
    };
}

fn finishPacketContext(context: *PhysicalPacketParallelContext, counters: *Counters) Error!PacketSchedulerStats {
    if (context.failed.load(.acquire)) return error.InvalidPacketStream;
    var total = Counters{ .primitive_tests = context.plan.setup_primitive_tests };
    var stats = PacketSchedulerStats{};
    for (0..context.plan.queues.len) |worker_index| {
        addPacketCounters(&total, context.results[worker_index].counters);
        stats.work_items += context.results[worker_index].stats.work_items;
        stats.owner_items += context.results[worker_index].stats.owner_items;
        stats.same_llc_steals += context.results[worker_index].stats.same_llc_steals;
        stats.same_numa_steals += context.results[worker_index].stats.same_numa_steals;
    }
    addPacketCounters(counters, total);
    return stats;
}

/// Execute an immutable physical-packet pass plan. Each worker owns one Morton
/// range, drains its own queue, steals from its LLC, then steals only within
/// the same NUMA node. Joining the workers is the pass's single completion
/// barrier.
pub fn renderPhysicalPacketPlan(
    surface: Surface,
    seen_clusters: []bool,
    counters: *Counters,
    plan: PacketWorkPlan,
) Error!PacketSchedulerStats {
    try validatePacketExecution(surface, seen_clusters, plan);
    var context = preparePacketContext(surface, seen_clusters, plan);

    var threads: [max_packet_workers - 1]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned + 1 < plan.queues.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, startPhysicalPacketWorker, .{ &context, spawned + 1 }) catch {
            context.failed.store(true, .release);
            context.dispatch.store(true, .release);
            for (threads[0..spawned]) |*thread| thread.join();
            return error.SchedulerUnavailable;
        };
    }
    if (!pinPacketWorker(plan.queues[0].topology)) context.failed.store(true, .release);
    while (context.ready_workers.load(.acquire) != spawned and !context.failed.load(.acquire)) std.atomic.spinLoopHint();
    context.dispatch.store(true, .release);
    if (!context.failed.load(.acquire)) runPhysicalPacketWorker(&context, 0);
    for (threads[0..spawned]) |*thread| thread.join();
    return finishPacketContext(&context, counters);
}

const PersistentPacketWorker = struct {
    executor: *PacketExecutor,
    worker_index: usize,
};

/// Persistent, topology-pinned Mosaic workers. Dispatch is a generation
/// publish; the caller and background workers execute their owned queues, then
/// the caller waits at one pass-completion barrier. Planning and thread
/// creation are outside the frame hot path.
pub const PacketExecutor = struct {
    worker_count: usize = 0,
    spawned: usize = 0,
    initialized: bool = false,
    topology: [max_packet_workers]WorkerTopology = [_]WorkerTopology{.{}} ** max_packet_workers,
    threads: [max_packet_workers - 1]std.Thread = undefined,
    workers: [max_packet_workers - 1]PersistentPacketWorker = undefined,
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    context_address: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    ready: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    completed: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    startup_failed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    last_worker_stats: [max_packet_workers]PacketSchedulerStats = [_]PacketSchedulerStats{.{}} ** max_packet_workers,

    pub fn init(self: *PacketExecutor, topology: []const WorkerTopology) Error!void {
        if (self.initialized or topology.len == 0 or topology.len > max_packet_workers) return error.SchedulerUnavailable;
        const numa = topology[0].numa;
        for (topology) |entry| if (entry.numa != numa) return error.TopologyMismatch;
        self.* = .{ .worker_count = topology.len };
        @memcpy(self.topology[0..topology.len], topology);
        while (self.spawned + 1 < topology.len) : (self.spawned += 1) {
            self.workers[self.spawned] = .{ .executor = self, .worker_index = self.spawned + 1 };
            self.threads[self.spawned] = std.Thread.spawn(.{}, persistentPacketWorkerMain, .{&self.workers[self.spawned]}) catch {
                self.stop.store(true, .release);
                _ = self.generation.fetchAdd(1, .release);
                for (self.threads[0..self.spawned]) |*thread| thread.join();
                self.spawned = 0;
                return error.SchedulerUnavailable;
            };
        }
        while (self.ready.load(.acquire) != self.spawned) std.atomic.spinLoopHint();
        if (self.startup_failed.load(.acquire) or !pinPacketWorker(topology[0])) {
            self.stop.store(true, .release);
            _ = self.generation.fetchAdd(1, .release);
            for (self.threads[0..self.spawned]) |*thread| thread.join();
            self.spawned = 0;
            return error.SchedulerUnavailable;
        }
        self.initialized = true;
    }

    pub fn deinit(self: *PacketExecutor) void {
        if (!self.initialized) return;
        self.stop.store(true, .release);
        _ = self.generation.fetchAdd(1, .release);
        for (self.threads[0..self.spawned]) |*thread| thread.join();
        self.initialized = false;
        self.spawned = 0;
    }

    pub fn render(self: *PacketExecutor, surface: Surface, seen_clusters: []bool, counters: *Counters, plan: PacketWorkPlan) Error!PacketSchedulerStats {
        if (!self.initialized or plan.queues.len != self.worker_count) return error.SchedulerUnavailable;
        for (plan.queues, 0..) |queue, index| if (!std.meta.eql(queue.topology, self.topology[index])) return error.TopologyMismatch;
        try validatePacketExecution(surface, seen_clusters, plan);
        var context = preparePacketContext(surface, seen_clusters, plan);
        self.completed.store(0, .monotonic);
        self.context_address.store(@intFromPtr(&context), .release);
        _ = self.generation.fetchAdd(1, .release);
        runPhysicalPacketWorker(&context, 0);
        while (self.completed.load(.acquire) != self.spawned) std.atomic.spinLoopHint();
        self.context_address.store(0, .release);
        for (context.results[0..self.worker_count], 0..) |result, index| self.last_worker_stats[index] = result.stats;
        return finishPacketContext(&context, counters);
    }

    pub fn workerStats(self: *const PacketExecutor) []const PacketSchedulerStats {
        return self.last_worker_stats[0..self.worker_count];
    }
};

fn persistentPacketWorkerMain(worker: *PersistentPacketWorker) void {
    const executor = worker.executor;
    var observed_generation = executor.generation.load(.acquire);
    if (!pinPacketWorker(executor.topology[worker.worker_index])) executor.startup_failed.store(true, .release);
    _ = executor.ready.fetchAdd(1, .release);
    while (true) {
        var generation = executor.generation.load(.acquire);
        while (generation == observed_generation and !executor.stop.load(.acquire)) {
            std.atomic.spinLoopHint();
            generation = executor.generation.load(.acquire);
        }
        if (executor.stop.load(.acquire)) return;
        observed_generation = generation;
        const address = executor.context_address.load(.acquire);
        if (address == 0) {
            executor.startup_failed.store(true, .release);
            return;
        }
        const context: *PhysicalPacketParallelContext = @ptrFromInt(address);
        runPhysicalPacketWorker(context, worker.worker_index);
        _ = executor.completed.fetchAdd(1, .release);
    }
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

    var parallel_color: [400]u32 = undefined;
    var parallel_depth: [400]f32 = undefined;
    var parallel_visibility: [400]pipeline.Visibility = undefined;
    var work_items: [100]PacketWorkItem = undefined;
    var worker_queues: [4]PacketWorkerQueue = undefined;
    var local_headers: [400]PacketTileHeader = undefined;
    var local_indices: [16]u32 = undefined;
    var active_clusters: [3]u32 = undefined;
    var cluster_seen: [3]bool = undefined;
    const worker_topology = [_]WorkerTopology{
        .{ .numa = 0, .llc = 0 },
        .{ .numa = 0, .llc = 0 },
        .{ .numa = 0, .llc = 1 },
        .{ .numa = 0, .llc = 1 },
    };
    for ([_]usize{ 1, 2, 3, 4 }) |worker_count| {
        const parallel = try Surface.init(&parallel_color, &parallel_depth, &parallel_visibility, 20, 20, .less_equal);
        parallel.clear(0, 1);
        var parallel_counters = Counters{};
        var parallel_seen: [3]bool = undefined;
        const work_plan = try buildPacketWorkPlan(
            20,
            20,
            1,
            1,
            &prepared_primitives,
            &ranges,
            &clusters,
            physical_local[0..physical_count.local],
            physical_macro[0..physical_count.macro],
            physical_global[0..physical_count.global],
            .{ .worker_count = worker_count, .group_w = 2, .group_h = 2, .topology = worker_topology[0..worker_count] },
            .{ .items = &work_items, .queues = &worker_queues, .local_headers = &local_headers, .local_indices = &local_indices, .active_clusters = &active_clusters, .cluster_seen = &cluster_seen },
        );
        const stats = try renderPhysicalPacketPlan(
            parallel,
            &parallel_seen,
            &parallel_counters,
            work_plan,
        );
        try std.testing.expectEqualSlices(u32, &reference_color, &parallel_color);
        try std.testing.expectEqualSlices(f32, &reference_depth, &parallel_depth);
        try std.testing.expectEqualSlices(pipeline.Visibility, &reference_visibility, &parallel_visibility);
        try std.testing.expectEqual(reference_counters, parallel_counters);
        try std.testing.expectEqualSlices(bool, &physical_seen, &parallel_seen);
        try std.testing.expectEqual(@as(u64, 100), stats.work_items);
        try std.testing.expectEqual(stats.work_items, stats.owner_items + stats.same_llc_steals + stats.same_numa_steals);

        if (worker_count == 4) {
            parallel.clear(0, 1);
            parallel_counters = .{};
            var executor = PacketExecutor{};
            try executor.init(&worker_topology);
            errdefer executor.deinit();
            const persistent_stats = try executor.render(parallel, &parallel_seen, &parallel_counters, work_plan);
            executor.deinit();
            try std.testing.expectEqualSlices(u32, &reference_color, &parallel_color);
            try std.testing.expectEqualSlices(f32, &reference_depth, &parallel_depth);
            try std.testing.expectEqualSlices(pipeline.Visibility, &reference_visibility, &parallel_visibility);
            try std.testing.expectEqual(reference_counters, parallel_counters);
            try std.testing.expectEqual(@as(u64, 100), persistent_stats.work_items);
        }
    }
}

test "packet work plans reject cross-NUMA worker sets" {
    var items: [1]PacketWorkItem = undefined;
    var queues: [2]PacketWorkerQueue = undefined;
    var headers: [1]PacketTileHeader = undefined;
    var local_indices: [0]u32 = .{};
    var active_clusters: [0]u32 = .{};
    var cluster_seen: [0]bool = .{};
    const topology = [_]WorkerTopology{
        .{ .numa = 0, .llc = 0 },
        .{ .numa = 1, .llc = 0 },
    };
    try std.testing.expectError(error.TopologyMismatch, buildPacketWorkPlan(
        1,
        1,
        1,
        1,
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        &.{},
        .{ .worker_count = 2, .topology = &topology },
        .{ .items = &items, .queues = &queues, .local_headers = &headers, .local_indices = &local_indices, .active_clusters = &active_clusters, .cluster_seen = &cluster_seen },
    ));
}

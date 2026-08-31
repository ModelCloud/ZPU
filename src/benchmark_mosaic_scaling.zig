// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Same-NUMA Mosaic packet-scheduler benchmark.
//!
//! This intentionally benchmarks the physical packet executor, rather than
//! the older cpu_cube batch bridge. Each run prepares a realistic workload
//! once, then compares serial and 1/2/3/4-worker spatial execution with the
//! same output checksum and counters.

const std = @import("std");
const pipeline = @import("render/mosaic_pipeline.zig");
const prepared = @import("render/prepared_primitives.zig");
const packets = @import("render/scalar_packet.zig");
const cpu_locality = @import("vulkan/cpu_locality.zig");

const width: u32 = 800;
const height: u32 = 600;
const tile_w: u32 = 16;
const tile_h: u32 = 16;
const sample_count = 5;

const Profile = enum { terminal, desktop_ui, complex_demo };

const Workload = struct {
    name: []const u8,
    sources: []prepared.SourceTriangle,
    primitives: []prepared.PreparedPrimitive,
    batches: []prepared.PreparedPrimitiveBatch,
    ranges: []packets.PreparedCluster,
    clusters: []pipeline.Cluster,
    local_packets: []pipeline.LocalPacket,
    macro_packets: []pipeline.MacroPacket,
    global_packets: []pipeline.GlobalPacket,
    local_count: usize,
    macro_count: usize,
    global_count: usize,

    fn local(self: *const Workload) []const pipeline.LocalPacket {
        return self.local_packets[0..self.local_count];
    }

    fn macro(self: *const Workload) []const pipeline.MacroPacket {
        return self.macro_packets[0..self.macro_count];
    }

    fn global(self: *const Workload) []const pipeline.GlobalPacket {
        return self.global_packets[0..self.global_count];
    }
};

const Execution = struct {
    counters: packets.Counters,
    scheduler: packets.PacketSchedulerStats,
};

const Measurement = struct {
    median_ns: u64,
    scheduler: packets.PacketSchedulerStats,
    worker_items: [8]u64 = [_]u64{0} ** 8,
    worker_count: usize,
};

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn parseCount(text: []const u8) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, text, ',');
    while (tokens.next()) |_| count += 1;
    return count;
}

fn quadSources(sources: []prepared.SourceTriangle, clusters: []pipeline.Cluster, ranges: []packets.PreparedCluster, index: usize, x: f32, y: f32, w: f32, h: f32, depth: f32) void {
    const first = index * 2;
    sources[first] = .{ .positions = .{ .{ x, y }, .{ x + w, y }, .{ x, y + h } }, .depths = .{ depth, depth, depth }, .primitive_id = @intCast(first), .material_id = @intCast(index + 1) };
    sources[first + 1] = .{ .positions = .{ .{ x + w, y }, .{ x + w, y + h }, .{ x, y + h } }, .depths = .{ depth, depth, depth }, .primitive_id = @intCast(first + 1), .material_id = @intCast(index + 1) };
    clusters[index] = .{
        .id = @intCast(index),
        .draw_id = @intCast(index),
        .material_id = @intCast(index + 1),
        .first_triangle = @intCast(first),
        .triangle_count = 2,
        .bounds = .{ .min_x = @intFromFloat(@max(x, 0)), .min_y = @intFromFloat(@max(y, 0)), .max_x = @intFromFloat(@min(x + w, @as(f32, @floatFromInt(width)))), .max_y = @intFromFloat(@min(y + h, @as(f32, @floatFromInt(height)))) },
        .best_depth = depth,
        .order_key = .{ .submission = 0, .command = @intCast(index), .primitive_group = 0 },
        .estimated_covered_samples = @intFromFloat(@max(w * h, 1)),
    };
    ranges[index] = .{ .first_primitive = @intCast(first), .primitive_count = 2 };
}

fn profileCount(profile: Profile) usize {
    return switch (profile) {
        .terminal => 4_800,
        .desktop_ui => 192,
        .complex_demo => 768,
    };
}

fn makeWorkload(allocator: std.mem.Allocator, profile: Profile) !Workload {
    const cluster_count = profileCount(profile);
    const sources = try allocator.alloc(prepared.SourceTriangle, cluster_count * 2);
    const primitives = try allocator.alloc(prepared.PreparedPrimitive, sources.len);
    const batches = try allocator.alloc(prepared.PreparedPrimitiveBatch, sources.len);
    const ranges = try allocator.alloc(packets.PreparedCluster, cluster_count);
    const clusters = try allocator.alloc(pipeline.Cluster, cluster_count);

    for (0..cluster_count) |index| {
        const x: f32 = switch (profile) {
            .terminal => @floatFromInt((index % 120) * 6),
            .desktop_ui => @floatFromInt((index % 12) * 48),
            .complex_demo => @floatFromInt((index % 32) * 24),
        };
        const y: f32 = switch (profile) {
            .terminal => @floatFromInt((index / 120) * 13),
            .desktop_ui => @floatFromInt((index / 12) * 28),
            .complex_demo => @floatFromInt((index / 32) * 24),
        };
        const quad_w: f32 = switch (profile) {
            .terminal => 5,
            .desktop_ui => 42,
            .complex_demo => 30,
        };
        const quad_h: f32 = switch (profile) {
            .terminal => 10,
            .desktop_ui => 22,
            .complex_demo => 28,
        };
        const depth: f32 = if (profile == .complex_demo) 0.15 + @as(f32, @floatFromInt(index % 32)) * 0.01 else 0.5;
        quadSources(sources, clusters, ranges, index, x, y, quad_w, quad_h, depth);
    }

    _ = try prepared.prepare(sources, width, height, 16, .{ .primitives = primitives, .batches = batches });
    const local_packets = try allocator.alloc(pipeline.LocalPacket, cluster_count * 16);
    const macro_packets = try allocator.alloc(pipeline.MacroPacket, cluster_count);
    const global_packets = try allocator.alloc(pipeline.GlobalPacket, cluster_count);
    const counts = try pipeline.buildPhysicalPackets(clusters, null, width, height, tile_w, tile_h, .less_equal, local_packets, macro_packets, global_packets);
    return .{
        .name = switch (profile) {
            .terminal => "terminal glyph grid",
            .desktop_ui => "desktop UI",
            .complex_demo => "complex 3D demo",
        },
        .sources = sources,
        .primitives = primitives,
        .batches = batches,
        .ranges = ranges,
        .clusters = clusters,
        .local_packets = local_packets,
        .macro_packets = macro_packets,
        .global_packets = global_packets,
        .local_count = counts.local,
        .macro_count = counts.macro,
        .global_count = counts.global,
    };
}

fn checksum(values: []const u32) u64 {
    var result: u64 = 0xcbf29ce484222325;
    for (values) |value| result = (result ^ value) *% 0x100000001b3;
    return result;
}

fn clear(surface: packets.Surface) void {
    surface.clear(0, 1);
}

fn execute(executor: *packets.PacketExecutor, color: []u32, depth: []f32, visibility: []pipeline.Visibility, seen: []bool, plan: packets.PacketWorkPlan) !Execution {
    const surface = try packets.Surface.init(color, depth, visibility, width, height, .less_equal);
    var counters = packets.Counters{};
    const scheduler = try executor.render(surface, seen, &counters, plan);
    return .{ .counters = counters, .scheduler = scheduler };
}

fn measure(allocator: std.mem.Allocator, executor: *packets.PacketExecutor, workload: *const Workload, plan: packets.PacketWorkPlan, reference_color: []const u32, reference_depth: []const f32, reference_visibility: []const pipeline.Visibility, reference_counters: packets.Counters) !Measurement {
    const color = try allocator.alloc(u32, @as(usize, width) * height);
    defer allocator.free(color);
    const depth = try allocator.alloc(f32, @as(usize, width) * height);
    defer allocator.free(depth);
    const visibility = try allocator.alloc(pipeline.Visibility, @as(usize, width) * height);
    defer allocator.free(visibility);
    const seen = try allocator.alloc(bool, workload.clusters.len);
    defer allocator.free(seen);

    var samples: [sample_count]u64 = undefined;
    var scheduler = packets.PacketSchedulerStats{};
    for (0..2) |_| _ = try execute(executor, color, depth, visibility, seen, plan);
    for (0..sample_count) |sample| {
        const start = nowNs();
        const execution = try execute(executor, color, depth, visibility, seen, plan);
        samples[sample] = nowNs() -| start;
        scheduler = execution.scheduler;
        try std.testing.expectEqualSlices(u32, reference_color, color);
        try std.testing.expectEqualSlices(f32, reference_depth, depth);
        try std.testing.expectEqualSlices(pipeline.Visibility, reference_visibility, visibility);
        try std.testing.expectEqual(reference_counters, execution.counters);
        try std.testing.expectEqual(execution.scheduler.work_items, execution.scheduler.owner_items + execution.scheduler.same_llc_steals + execution.scheduler.same_numa_steals);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    var measurement = Measurement{ .median_ns = samples[sample_count / 2], .scheduler = scheduler, .worker_count = executor.workerStats().len };
    for (executor.workerStats(), 0..) |stats, index| measurement.worker_items[index] = stats.work_items;
    return measurement;
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityGate;
    const selected_count = parseCount(selected);
    if (selected_count == 0 or selected_count > 8) return error.InvalidAffinityWidth;
    const allocator = init.arena.allocator();
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const work_allocator = arena.allocator();
    var discovered: [8]cpu_locality.CpuTopology = undefined;
    const discovered_count = cpu_locality.selectedCpuTopology(&discovered);
    if (discovered_count != selected_count) return error.TopologyMismatch;
    var worker_topology: [8]packets.WorkerTopology = undefined;
    for (discovered[0..discovered_count], 0..) |entry, index| {
        if (entry.cpu > std.math.maxInt(u32) or entry.numa > std.math.maxInt(u16) or entry.llc > std.math.maxInt(u16)) return error.TopologyMismatch;
        worker_topology[index] = .{ .cpu = @intCast(entry.cpu), .numa = @intCast(entry.numa), .llc = @intCast(entry.llc) };
    }
    std.debug.print("Mosaic physical scheduler: selected_cpus={s} workers={d} tile={d}x{d}\n", .{ selected, selected_count, tile_w, tile_h });
    for (worker_topology[0..selected_count], 0..) |entry, index| std.debug.print("  owner={d} cpu={d} numa={d} llc={d}\n", .{ index, entry.cpu.?, entry.numa, entry.llc });

    for ([_]Profile{ .terminal, .desktop_ui, .complex_demo }) |profile| {
        const workload = try makeWorkload(work_allocator, profile);
        const color = try allocator.alloc(u32, @as(usize, width) * height);
        defer allocator.free(color);
        const depth = try allocator.alloc(f32, @as(usize, width) * height);
        defer allocator.free(depth);
        const visibility = try allocator.alloc(pipeline.Visibility, @as(usize, width) * height);
        defer allocator.free(visibility);
        const surface = try packets.Surface.init(color, depth, visibility, width, height, .less_equal);
        clear(surface);
        var reference_counters = packets.Counters{};
        const reference_seen = try allocator.alloc(bool, workload.clusters.len);
        defer allocator.free(reference_seen);
        try packets.renderPhysicalPackets(surface, workload.primitives, workload.ranges, workload.clusters, tile_w, tile_h, workload.local(), workload.macro(), workload.global(), reference_seen, &reference_counters);
        const reference_color = try allocator.dupe(u32, color);
        defer allocator.free(reference_color);
        const reference_depth = try allocator.dupe(f32, depth);
        defer allocator.free(reference_depth);
        const reference_visibility = try allocator.dupe(pipeline.Visibility, visibility);
        defer allocator.free(reference_visibility);

        std.debug.print("{s}: clusters={d} local={d} macro={d} global={d}\n", .{ workload.name, workload.clusters.len, workload.local_count, workload.macro_count, workload.global_count });
        var worker_count: usize = 1;
        while (worker_count <= selected_count) : (worker_count += 1) {
            const columns = (@as(usize, width) + tile_w - 1) / tile_w;
            const rows = (@as(usize, height) + tile_h - 1) / tile_h;
            const work_item_capacity = ((columns + 3) / 4) * ((rows + 3) / 4);
            const work_items = try allocator.alloc(packets.PacketWorkItem, work_item_capacity);
            defer allocator.free(work_items);
            const worker_queues = try allocator.alloc(packets.PacketWorkerQueue, worker_count);
            defer allocator.free(worker_queues);
            const local_headers = try allocator.alloc(packets.PacketTileHeader, columns * rows);
            defer allocator.free(local_headers);
            const local_indices = try allocator.alloc(u32, workload.local_count);
            defer allocator.free(local_indices);
            const active_clusters = try allocator.alloc(u32, workload.clusters.len);
            defer allocator.free(active_clusters);
            const cluster_seen = try allocator.alloc(bool, workload.clusters.len);
            defer allocator.free(cluster_seen);
            const plan = try packets.buildPacketWorkPlan(
                width,
                height,
                tile_w,
                tile_h,
                workload.primitives,
                workload.ranges,
                workload.clusters,
                workload.local(),
                workload.macro(),
                workload.global(),
                .{ .worker_count = worker_count, .group_w = 4, .group_h = 4, .load_op = .{ .clear = .{ .color = 0, .depth = 1 } }, .topology = worker_topology[0..worker_count] },
                .{ .items = work_items, .queues = worker_queues, .local_headers = local_headers, .local_indices = local_indices, .active_clusters = active_clusters, .cluster_seen = cluster_seen },
            );
            var executor = packets.PacketExecutor{};
            try executor.init(worker_topology[0..worker_count]);
            defer executor.deinit();
            const measurement = try measure(allocator, &executor, &workload, plan, reference_color, reference_depth, reference_visibility, reference_counters);
            std.debug.print("  workers={d} median={d} us work={d} owner={d} llc_steal={d} numa_steal={d} checksum={x:0>16}\n", .{
                worker_count,
                measurement.median_ns / 1000,
                measurement.scheduler.work_items,
                measurement.scheduler.owner_items,
                measurement.scheduler.same_llc_steals,
                measurement.scheduler.same_numa_steals,
                checksum(reference_color),
            });
            std.debug.print("    per_worker=", .{});
            for (measurement.worker_items[0..measurement.worker_count], 0..) |items, index| std.debug.print("{s}{d}", .{ if (index == 0) "" else ",", items });
            std.debug.print("\n", .{});
        }
    }
}

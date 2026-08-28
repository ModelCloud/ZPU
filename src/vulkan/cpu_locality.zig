// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");

const CpuSet = if (builtin.os.tag == .linux) std.os.linux.cpu_set_t else [1]usize;
const cpu_capacity = @sizeOf(CpuSet) * 8;
const bits_per_word = @bitSizeOf(usize);

pub const Role = enum(usize) {
    render = 0,
    raster_1 = 1,
    raster_2 = 2,
    raster_3 = 3,
    raster_4 = 4,
    present = 5,
    raster_5 = 6,
};

var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var initialized = false;
var selected_cpus: [cpu_capacity]usize = undefined;
var selected_count: usize = 0;
var selected_node: ?usize = null;

fn contains(set: CpuSet, cpu: usize) bool {
    return set[cpu / bits_per_word] & (@as(usize, 1) << @intCast(cpu % bits_per_word)) != 0;
}

fn singleton(cpu: usize) CpuSet {
    var set = [_]usize{0} ** @typeInfo(CpuSet).array.len;
    set[cpu / bits_per_word] |= @as(usize, 1) << @intCast(cpu % bits_per_word);
    return set;
}

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn capacityScore(cpu: usize) u64 {
    var one = singleton(cpu);
    std.os.linux.sched_setaffinity(0, &one) catch return 0;
    var worst: u64 = std.math.maxInt(u64);
    for (0..5) |round| {
        const start = monotonicNs();
        var operations: u64 = 0;
        var state: u64 = 0x9e3779b97f4a7c15 ^ round;
        while (monotonicNs() -| start < 2_000_000) {
            for (0..128) |_| state = (state ^ (state >> 11)) *% 0xbf58476d1ce4e5b9;
            operations += 128;
        }
        std.mem.doNotOptimizeAway(state);
        worst = @min(worst, operations);
    }
    return worst;
}

fn cpuListContains(text: []const u8, wanted: usize) bool {
    var entries = std.mem.tokenizeScalar(u8, text, ',');
    while (entries.next()) |entry| {
        var bounds = std.mem.splitScalar(u8, std.mem.trim(u8, entry, " \t\r\n"), '-');
        const first = std.fmt.parseInt(usize, bounds.next() orelse continue, 10) catch continue;
        const last = if (bounds.next()) |value| std.fmt.parseInt(usize, value, 10) catch continue else first;
        if (wanted >= first and wanted <= last) return true;
    }
    return false;
}

fn shareCache(first: usize, second: usize) bool {
    var path_buffer: [160]u8 = undefined;
    var contents: [512]u8 = undefined;
    for (0..8) |index| {
        const path = std.fmt.bufPrintZ(&path_buffer, "/sys/devices/system/cpu/cpu{d}/cache/index{d}/shared_cpu_list", .{ first, index }) catch continue;
        const opened = std.os.linux.open(path, .{}, 0);
        if (opened > std.math.maxInt(usize) - 4096) continue;
        const fd: i32 = @intCast(opened);
        defer _ = std.os.linux.close(fd);
        const count = std.os.linux.read(fd, &contents, contents.len);
        if (count > std.math.maxInt(usize) - 4096) continue;
        if (cpuListContains(contents[0..count], second)) return true;
    }
    return false;
}

fn prioritizeCacheLocalPair(scores: []const u64) void {
    if (selected_count < 2) return;
    var anchor: usize = 0;
    var largest_group: usize = 0;
    for (0..selected_count) |first| {
        var group_size: usize = 0;
        for (0..selected_count) |second| if (shareCache(selected_cpus[first], selected_cpus[second])) {
            group_size += 1;
        };
        if (group_size > largest_group or (group_size == largest_group and scores[first] > scores[anchor])) {
            anchor = first;
            largest_group = group_size;
        }
    }
    if (largest_group < 2) return;
    var pair_first: ?usize = null;
    var pair_second: ?usize = null;
    for (0..selected_count) |index| {
        if (!shareCache(selected_cpus[anchor], selected_cpus[index])) continue;
        if (pair_first == null) pair_first = index else {
            pair_second = index;
            break;
        }
    }
    if (pair_second == null) return;
    const first = selected_cpus[pair_first.?];
    const second = selected_cpus[pair_second.?];
    var reordered: [cpu_capacity]usize = undefined;
    reordered[0] = first;
    reordered[1] = second;
    var output: usize = 2;
    for (selected_cpus[0..selected_count], 0..) |cpu, index| {
        if (index == pair_first.? or index == pair_second.?) continue;
        reordered[output] = cpu;
        output += 1;
    }
    @memcpy(selected_cpus[0..selected_count], reordered[0..selected_count]);
}

fn rankSelectedCpus(allowed: CpuSet) void {
    var scores = [_]u64{0} ** cpu_capacity;
    for (selected_cpus[0..selected_count], 0..) |cpu, index| scores[index] = capacityScore(cpu);
    std.os.linux.sched_setaffinity(0, &allowed) catch {};
    // Stable insertion sort: ties retain the inherited affinity ordering.
    for (1..selected_count) |index| {
        const cpu = selected_cpus[index];
        const score = scores[index];
        var destination = index;
        while (destination != 0 and score > scores[destination - 1]) : (destination -= 1) {
            selected_cpus[destination] = selected_cpus[destination - 1];
            scores[destination] = scores[destination - 1];
        }
        selected_cpus[destination] = cpu;
        scores[destination] = score;
    }
    // Two-core 3D shares substantial color/depth traffic. Keep the selected
    // pair in one cache domain when the inherited affinity offers such a pair.
    prioritizeCacheLocalPair(scores[0..selected_count]);
}

fn discoverLinux() void {
    const allowed = std.posix.sched_getaffinity(0) catch return;
    var cpu_nodes = [_]usize{std.math.maxInt(usize)} ** cpu_capacity;
    var node_counts = [_]usize{0} ** cpu_capacity;
    var initial_node: usize = 0;
    _ = std.os.linux.getcpu(null, &initial_node);

    for (0..cpu_capacity) |cpu| {
        if (!contains(allowed, cpu)) continue;
        var one = singleton(cpu);
        std.os.linux.sched_setaffinity(0, &one) catch continue;
        var node: usize = 0;
        if (std.os.linux.getcpu(null, &node) == 0 and node < cpu_capacity) {
            cpu_nodes[cpu] = node;
            node_counts[node] += 1;
        }
    }
    std.os.linux.sched_setaffinity(0, &allowed) catch {};

    var best_node: ?usize = null;
    var best_count: usize = 0;
    for (node_counts, 0..) |count, node| {
        if (count > best_count or (count == best_count and count != 0 and node == initial_node)) {
            best_node = node;
            best_count = count;
        }
    }
    if (best_node) |node| {
        for (cpu_nodes, 0..) |cpu_node, cpu| if (cpu_node == node) {
            selected_cpus[selected_count] = cpu;
            selected_count += 1;
        };
        selected_node = node;
    }

    // getcpu can be unavailable under a restrictive seccomp profile. CPU
    // pinning still remains useful, so preserve the process affinity in that
    // case and omit only the NUMA memory-policy syscall.
    if (selected_count == 0) for (0..cpu_capacity) |cpu| if (contains(allowed, cpu)) {
        selected_cpus[selected_count] = cpu;
        selected_count += 1;
    };
    rankSelectedCpus(allowed);
}

fn ensureInitialized() void {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (initialized) return;
    initialized = true;
    if (builtin.os.tag == .linux) discoverLinux();
}

fn roleCpuIndex(role: Role, cpu_count: usize) usize {
    std.debug.assert(cpu_count != 0);
    return if (role == .render or cpu_count == 1) 0 else 1;
}

/// Pins the current ZPU execution thread to a deterministic CPU within the
/// process's inherited affinity mask and chosen NUMA node.
pub fn pinCurrent(role: Role) bool {
    if (builtin.os.tag != .linux) return false;
    ensureInitialized();
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (selected_count == 0) return false;
    const role_index = roleCpuIndex(role, selected_count);
    var role_mask = singleton(selected_cpus[role_index]);
    if (role == .present and selected_count >= 2) {
        const render_cpu = selected_cpus[0];
        role_mask[render_cpu / bits_per_word] |= @as(usize, 1) << @intCast(render_cpu % bits_per_word);
    }
    std.os.linux.sched_setaffinity(0, &role_mask) catch return false;
    return true;
}

pub fn pinRasterWorker(worker_index: usize) bool {
    const roles = [_]Role{ .raster_1, .raster_2, .raster_3, .raster_4, .raster_5 };
    return pinCurrent(roles[worker_index % roles.len]);
}

/// Applies the NUMA policy before first touch, then requests transparent huge
/// pages for large internal caches to reduce remote faults and TLB pressure.
pub fn prepareMemory(bytes: []u8) void {
    if (builtin.os.tag != .linux or bytes.len < 2 * 1024 * 1024) return;
    ensureInitialized();
    const page_size = std.heap.page_size_min;
    const raw_start = @intFromPtr(bytes.ptr);
    const start = std.mem.alignForward(usize, raw_start, page_size);
    const end = std.mem.alignBackward(usize, raw_start + bytes.len, page_size);
    if (end <= start) return;
    const address: [*]align(page_size) u8 = @ptrFromInt(start);
    const length = end - start;

    _ = std.c.pthread_mutex_lock(&mutex);
    const node = selected_node;
    _ = std.c.pthread_mutex_unlock(&mutex);
    if (node) |chosen_node| {
        var node_mask = [_]usize{0} ** @typeInfo(CpuSet).array.len;
        node_mask[chosen_node / bits_per_word] |= @as(usize, 1) << @intCast(chosen_node % bits_per_word);
        // MPOL_BIND = 2. The mapping is not touched yet, so no migration flag
        // is needed: every subsequent first fault is allocated on this node.
        _ = std.os.linux.syscall6(.mbind, start, length, 2, @intFromPtr(&node_mask), chosen_node + 1, 0);
    }
    std.posix.madvise(address, length, std.posix.MADV.HUGEPAGE) catch {};
}

test "CPU masks select exactly one requested processor" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const cpu = @min(@as(usize, 73), cpu_capacity - 1);
    const set = singleton(cpu);
    try std.testing.expect(contains(set, cpu));
    try std.testing.expectEqual(@as(usize, 1), @popCount(set[cpu / bits_per_word]));
}

test "ZPU roles never select more than two CPUs" {
    for (std.enums.values(Role)) |role| {
        try std.testing.expectEqual(@as(usize, 0), roleCpuIndex(role, 1));
        try std.testing.expect(roleCpuIndex(role, 2) <= 1);
        try std.testing.expect(roleCpuIndex(role, 8) <= 1);
    }
    try std.testing.expectEqual(@as(usize, 0), roleCpuIndex(.render, 8));
    try std.testing.expectEqual(@as(usize, 1), roleCpuIndex(.raster_1, 8));
    try std.testing.expectEqual(@as(usize, 1), roleCpuIndex(.present, 8));
}

test "Linux CPU-list parser recognizes cache-sharing ranges" {
    try std.testing.expect(cpuListContains("0-3,8,10-12\n", 2));
    try std.testing.expect(cpuListContains("0-3,8,10-12\n", 8));
    try std.testing.expect(cpuListContains("0-3,8,10-12\n", 11));
    try std.testing.expect(!cpuListContains("0-3,8,10-12\n", 9));
}

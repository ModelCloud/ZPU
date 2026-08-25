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
    var best: u64 = 0;
    for (0..3) |round| {
        const start = monotonicNs();
        var operations: u64 = 0;
        var state: u64 = 0x9e3779b97f4a7c15 ^ round;
        while (monotonicNs() -| start < 750_000) {
            for (0..128) |_| state = (state ^ (state >> 11)) *% 0xbf58476d1ce4e5b9;
            operations += 128;
        }
        std.mem.doNotOptimizeAway(state);
        best = @max(best, operations);
    }
    return best;
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

/// Pins the current ZPU execution thread to a deterministic CPU within the
/// process's inherited affinity mask and chosen NUMA node.
pub fn pinCurrent(role: Role) bool {
    if (builtin.os.tag != .linux) return false;
    ensureInitialized();
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (selected_count == 0) return false;
    const role_index = @intFromEnum(role);
    var one = singleton(selected_cpus[role_index % selected_count]);
    // Five render lanes receive two same-node fallback CPUs. Their individual
    // masks remain narrower than the process mask, while Linux can migrate a
    // preempted lane without crossing the selected NUMA boundary. The present
    // lane retains its own dedicated CPU.
    if (selected_count >= 8 and role_index < 5) {
        for (selected_cpus[6..8]) |cpu| one[cpu / bits_per_word] |= @as(usize, 1) << @intCast(cpu % bits_per_word);
    }
    std.os.linux.sched_setaffinity(0, &one) catch return false;
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

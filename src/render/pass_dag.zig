// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const PassId = u16;

pub const Frontend = enum { vulkan, native_clustered, internal };
pub const Kind = enum { graphics, compute, hzb_build, cluster_cull, macrobin, tile_raster, visibility_shade, resolve, present };

pub const Pass = struct {
    frontend: Frontend,
    kind: Kind,
    sequence: u64,
    user_tag: u32 = 0,
};

pub const Edge = struct { before: PassId, after: PassId };

pub const ResourceKind = enum { buffer, image };
pub const Access = enum { read, write, read_write };
pub const ResourceUse = struct {
    resource: u32,
    kind: ResourceKind,
    access: Access,
    subresource_begin: u32 = 0,
    subresource_count: u32 = 1,
};

pub const Error = error{
    PassCapacity,
    EdgeCapacity,
    InvalidPass,
    DuplicateDependency,
    Cycle,
    ScratchTooSmall,
    CountOverflow,
};

/// Explicit reusable scratch for O(V + E) adjacency construction plus an
/// O(log V) deterministic ready heap. No scheduler-time heap allocation.
pub const SortScratch = struct {
    indegree: []u32,
    out_count: []u32,
    offsets: []u32,
    cursors: []u32,
    adjacency: []PassId,
    ready_heap: []PassId,
};

pub const Dag = struct {
    passes: []Pass,
    edges: []Edge,
    pass_count: usize = 0,
    edge_count: usize = 0,

    pub fn init(pass_storage: []Pass, edge_storage: []Edge) Dag {
        return .{ .passes = pass_storage, .edges = edge_storage };
    }

    pub fn reset(self: *Dag) void {
        self.pass_count = 0;
        self.edge_count = 0;
    }

    pub fn addPass(self: *Dag, pass: Pass) Error!PassId {
        if (self.pass_count >= self.passes.len or self.pass_count > std.math.maxInt(PassId)) return error.PassCapacity;
        const id: PassId = @intCast(self.pass_count);
        self.passes[self.pass_count] = pass;
        self.pass_count += 1;
        return id;
    }

    pub fn addDependency(self: *Dag, before: PassId, after: PassId) Error!void {
        if (@as(usize, before) >= self.pass_count or @as(usize, after) >= self.pass_count or before == after) return error.InvalidPass;
        for (self.edges[0..self.edge_count]) |edge| if (edge.before == before and edge.after == after) return error.DuplicateDependency;
        if (self.edge_count >= self.edges.len) return error.EdgeCapacity;
        self.edges[self.edge_count] = .{ .before = before, .after = after };
        self.edge_count += 1;
    }

    fn less(self: *const Dag, a: PassId, b: PassId) bool {
        const pa = self.passes[@as(usize, a)];
        const pb = self.passes[@as(usize, b)];
        return pa.sequence < pb.sequence or (pa.sequence == pb.sequence and a < b);
    }

    fn heapPush(self: *const Dag, heap: []PassId, len: *usize, value: PassId) void {
        var index = len.*;
        heap[index] = value;
        len.* += 1;
        while (index != 0) {
            const parent = (index - 1) / 2;
            if (!self.less(heap[index], heap[parent])) break;
            std.mem.swap(PassId, &heap[index], &heap[parent]);
            index = parent;
        }
    }

    fn heapPop(self: *const Dag, heap: []PassId, len: *usize) PassId {
        const result = heap[0];
        len.* -= 1;
        if (len.* == 0) return result;
        heap[0] = heap[len.*];
        var index: usize = 0;
        while (true) {
            const left = index * 2 + 1;
            if (left >= len.*) break;
            const right = left + 1;
            var best = left;
            if (right < len.* and self.less(heap[right], heap[left])) best = right;
            if (!self.less(heap[best], heap[index])) break;
            std.mem.swap(PassId, &heap[best], &heap[index]);
            index = best;
        }
        return result;
    }

    /// Deterministic Kahn ordering using CSR adjacency and a sequence-keyed
    /// ready heap. Complexity is O(V + E + V log V), versus rescanning all
    /// passes and edges for every emitted node.
    pub fn topologicalOrder(self: *const Dag, order: []PassId, scratch: SortScratch) Error!usize {
        const v = self.pass_count;
        const e = self.edge_count;
        if (order.len < v or scratch.indegree.len < v or scratch.out_count.len < v or scratch.offsets.len < v + 1 or scratch.cursors.len < v or scratch.adjacency.len < e or scratch.ready_heap.len < v) return error.ScratchTooSmall;
        @memset(scratch.indegree[0..v], 0);
        @memset(scratch.out_count[0..v], 0);

        for (self.edges[0..e]) |edge| {
            const before = @as(usize, edge.before);
            const after = @as(usize, edge.after);
            if (scratch.indegree[after] == std.math.maxInt(u32) or scratch.out_count[before] == std.math.maxInt(u32)) return error.CountOverflow;
            scratch.indegree[after] += 1;
            scratch.out_count[before] += 1;
        }

        scratch.offsets[0] = 0;
        var i: usize = 0;
        while (i < v) : (i += 1) {
            const next = @as(u64, scratch.offsets[i]) + scratch.out_count[i];
            if (next > std.math.maxInt(u32)) return error.CountOverflow;
            scratch.offsets[i + 1] = @intCast(next);
            scratch.cursors[i] = scratch.offsets[i];
        }
        for (self.edges[0..e]) |edge| {
            const before = @as(usize, edge.before);
            const dst = @as(usize, scratch.cursors[before]);
            scratch.adjacency[dst] = edge.after;
            scratch.cursors[before] += 1;
        }

        var heap_len: usize = 0;
        for (0..v) |index| if (scratch.indegree[index] == 0) self.heapPush(scratch.ready_heap, &heap_len, @intCast(index));

        var output: usize = 0;
        while (heap_len != 0) {
            const id = self.heapPop(scratch.ready_heap, &heap_len);
            order[output] = id;
            output += 1;
            const begin = @as(usize, scratch.offsets[@as(usize, id)]);
            const end = @as(usize, scratch.offsets[@as(usize, id) + 1]);
            for (scratch.adjacency[begin..end]) |after| {
                const index = @as(usize, after);
                std.debug.assert(scratch.indegree[index] != 0);
                scratch.indegree[index] -= 1;
                if (scratch.indegree[index] == 0) self.heapPush(scratch.ready_heap, &heap_len, after);
            }
        }
        if (output != v) return error.Cycle;
        return output;
    }
};

fn testScratch() struct {
    indegree: [8]u32,
    out_count: [8]u32,
    offsets: [9]u32,
    cursors: [8]u32,
    adjacency: [16]PassId,
    ready: [8]PassId,
} {
    return undefined;
}

test "common DAG is deterministic by sequence" {
    var passes: [8]Pass = undefined;
    var edges: [16]Edge = undefined;
    var dag = Dag.init(&passes, &edges);
    const late = try dag.addPass(.{ .frontend = .vulkan, .kind = .graphics, .sequence = 20 });
    const early = try dag.addPass(.{ .frontend = .native_clustered, .kind = .graphics, .sequence = 10 });
    const hzb = try dag.addPass(.{ .frontend = .internal, .kind = .hzb_build, .sequence = 30 });
    const raster = try dag.addPass(.{ .frontend = .internal, .kind = .tile_raster, .sequence = 40 });
    try dag.addDependency(late, hzb);
    try dag.addDependency(early, hzb);
    try dag.addDependency(hzb, raster);
    var order: [8]PassId = undefined;
    var s = testScratch();
    const count = try dag.topologicalOrder(&order, .{ .indegree = &s.indegree, .out_count = &s.out_count, .offsets = &s.offsets, .cursors = &s.cursors, .adjacency = &s.adjacency, .ready_heap = &s.ready });
    try std.testing.expectEqual(@as(usize, 4), count);
    try std.testing.expectEqual(early, order[0]);
    try std.testing.expectEqual(late, order[1]);
    try std.testing.expectEqual(hzb, order[2]);
    try std.testing.expectEqual(raster, order[3]);
}

test "DAG rejects cycles" {
    var passes: [3]Pass = undefined;
    var edges: [3]Edge = undefined;
    var dag = Dag.init(&passes, &edges);
    const a = try dag.addPass(.{ .frontend = .internal, .kind = .graphics, .sequence = 0 });
    const b = try dag.addPass(.{ .frontend = .internal, .kind = .compute, .sequence = 1 });
    try dag.addDependency(a, b);
    try dag.addDependency(b, a);
    var order: [3]PassId = undefined;
    var indegree: [3]u32 = undefined;
    var out_count: [3]u32 = undefined;
    var offsets: [4]u32 = undefined;
    var cursors: [3]u32 = undefined;
    var adjacency: [3]PassId = undefined;
    var ready: [3]PassId = undefined;
    try std.testing.expectError(error.Cycle, dag.topologicalOrder(&order, .{ .indegree = &indegree, .out_count = &out_count, .offsets = &offsets, .cursors = &cursors, .adjacency = &adjacency, .ready_heap = &ready }));
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const PassId = u16;

pub const Frontend = enum {
    vulkan,
    native_clustered,
    internal,
};

pub const Kind = enum {
    graphics,
    compute,
    hzb_build,
    cluster_cull,
    macrobin,
    tile_raster,
    visibility_shade,
    resolve,
    present,
};

pub const Pass = struct {
    frontend: Frontend,
    kind: Kind,
    sequence: u64,
    user_tag: u32 = 0,
};

pub const Edge = struct {
    before: PassId,
    after: PassId,
};

pub const Error = error{
    PassCapacity,
    EdgeCapacity,
    InvalidPass,
    DuplicateDependency,
    Cycle,
    ScratchTooSmall,
};

/// Caller-owned, bounded DAG. The renderer controls storage lifetime and never
/// needs one heap allocation per pass or dependency.
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
        for (self.edges[0..self.edge_count]) |edge| {
            if (edge.before == before and edge.after == after) return error.DuplicateDependency;
        }
        if (self.edge_count >= self.edges.len) return error.EdgeCapacity;
        self.edges[self.edge_count] = .{ .before = before, .after = after };
        self.edge_count += 1;
    }

    /// Deterministic Kahn topological ordering. `indegree` is explicit scratch
    /// so large frame graphs do not allocate in the scheduler hot path.
    pub fn topologicalOrder(self: *const Dag, order: []PassId, indegree: []u16) Error!usize {
        if (order.len < self.pass_count or indegree.len < self.pass_count) return error.ScratchTooSmall;
        @memset(indegree[0..self.pass_count], 0);
        for (self.edges[0..self.edge_count]) |edge| {
            const index = @as(usize, edge.after);
            if (indegree[index] == std.math.maxInt(u16)) return error.EdgeCapacity;
            indegree[index] += 1;
        }

        var output: usize = 0;
        while (output < self.pass_count) {
            var selected: ?PassId = null;
            var index: usize = 0;
            while (index < self.pass_count) : (index += 1) {
                if (indegree[index] != 0) continue;
                var already_output = false;
                for (order[0..output]) |existing| {
                    if (@as(usize, existing) == index) {
                        already_output = true;
                        break;
                    }
                }
                if (already_output) continue;
                selected = @intCast(index);
                break;
            }
            const id = selected orelse return error.Cycle;
            order[output] = id;
            output += 1;
            for (self.edges[0..self.edge_count]) |edge| {
                if (edge.before != id) continue;
                const after_index = @as(usize, edge.after);
                if (indegree[after_index] == 0) return error.Cycle;
                indegree[after_index] -= 1;
            }
        }
        return output;
    }
};

test "common DAG orders Vulkan, clustered, and internal passes" {
    var pass_storage: [8]Pass = undefined;
    var edge_storage: [12]Edge = undefined;
    var dag = Dag.init(&pass_storage, &edge_storage);

    const vulkan = try dag.addPass(.{ .frontend = .vulkan, .kind = .graphics, .sequence = 10 });
    const native = try dag.addPass(.{ .frontend = .native_clustered, .kind = .graphics, .sequence = 11 });
    const hzb = try dag.addPass(.{ .frontend = .internal, .kind = .hzb_build, .sequence = 12 });
    const cull = try dag.addPass(.{ .frontend = .internal, .kind = .cluster_cull, .sequence = 13 });
    const raster = try dag.addPass(.{ .frontend = .internal, .kind = .tile_raster, .sequence = 14 });

    try dag.addDependency(vulkan, hzb);
    try dag.addDependency(native, hzb);
    try dag.addDependency(hzb, cull);
    try dag.addDependency(cull, raster);

    var order: [8]PassId = undefined;
    var indegree: [8]u16 = undefined;
    const count = try dag.topologicalOrder(&order, &indegree);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expect(order[0] == vulkan or order[0] == native);
    try std.testing.expect(order[1] == vulkan or order[1] == native);
    try std.testing.expect(order[0] != order[1]);
    try std.testing.expectEqual(hzb, order[2]);
    try std.testing.expectEqual(cull, order[3]);
    try std.testing.expectEqual(raster, order[4]);
}

test "DAG rejects cycles" {
    var pass_storage: [3]Pass = undefined;
    var edge_storage: [3]Edge = undefined;
    var dag = Dag.init(&pass_storage, &edge_storage);
    const a = try dag.addPass(.{ .frontend = .internal, .kind = .graphics, .sequence = 0 });
    const b = try dag.addPass(.{ .frontend = .internal, .kind = .compute, .sequence = 1 });
    try dag.addDependency(a, b);
    try dag.addDependency(b, a);
    var order: [3]PassId = undefined;
    var indegree: [3]u16 = undefined;
    try std.testing.expectError(error.Cycle, dag.topologicalOrder(&order, &indegree));
}

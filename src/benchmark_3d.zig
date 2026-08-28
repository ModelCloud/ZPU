// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const cube = @import("vulkan/cpu_cube.zig");

pub const schema_version: u32 = 3;
pub const workload_id = "zpu-vkcube-cpu-3d-v3-800x600-cube12";
pub const target_workload_id = "zpu-vkcube-cpu-3d-v3-800x600-cube12-2core-target";
pub const width: u32 = 800;
pub const height: u32 = 600;
pub const reference_checksum: u64 = 0x37d978fe1c101415;
pub const baseline_triangles_s: f64 = 3_133.92;
pub const target_speedup: f64 = 10.0;
pub const target_triangles_s: f64 = baseline_triangles_s * target_speedup;
pub const target_cpu_cores: u8 = 2;

const Percentiles = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64, p999_ns: u64, max_ns: u64, cv: f64 };
const Metric = struct {
    name: []const u8 = "vkcube_cpu_cube",
    backend: []const u8 = "vkcube-specific-cpu",
    iterations: u32,
    checksum: u64,
    checksum_hex: []const u8,
    fps: f64,
    triangles_s: f64,
    cpu_cores: u8 = 1,
    baseline_triangles_s: f64 = baseline_triangles_s,
    target_triangles_s: f64 = target_triangles_s,
    speedup_vs_baseline: f64 = 1.0,
    target_speedup: f64 = target_speedup,
    frame: Percentiles,
    counters_per_frame: cube.Counters,
};
const Report = struct {
    schema_version: u32 = schema_version,
    workload_id: []const u8 = workload_id,
    renderer_scope: []const u8 = "existing vkcube-specific cpu_cube renderer; not general SPIR-V",
    resolution: []const u8 = "800x600",
    warmup_iterations: u32,
    sample_count: u32,
    source_commit: []const u8,
    utc: []const u8,
    compiler: []const u8 = builtin.zig_version_string,
    build_mode: []const u8 = @tagName(builtin.mode),
    metric: Metric,
};

fn putFloat(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

const Scene = struct { uniform: [64 + 36 * 32]u8, texture: [4 * 4 * 4]u8 };

fn scene(mutant: bool) Scene {
    var result: Scene = .{ .uniform = [_]u8{0} ** (64 + 36 * 32), .texture = undefined };
    for (0..4) |i| putFloat(&result.uniform, (i * 4 + i) * 4, 1);
    const v = [_][4]f32{
        .{ -0.62, -0.62, 0.20, 1 }, .{ 0.62, -0.62, 0.20, 1 }, .{ 0.62, 0.62, 0.20, 1 }, .{ -0.62, 0.62, 0.20, 1 },
        .{ -0.42, -0.42, 0.72, 1 }, .{ 0.42, -0.42, 0.72, 1 }, .{ 0.42, 0.42, 0.72, 1 }, .{ -0.42, 0.42, 0.72, 1 },
    };
    const indices = [_]u8{ 0, 1, 2, 0, 2, 3, 5, 4, 7, 5, 7, 6, 4, 0, 3, 4, 3, 7, 1, 5, 6, 1, 6, 2, 3, 2, 6, 3, 6, 7, 4, 5, 1, 4, 1, 0 };
    for (indices, 0..) |index, i| {
        for (v[index], 0..) |value, c| putFloat(&result.uniform, 64 + i * 16 + c * 4, value);
        const uv = [_]f32{ @floatFromInt(index & 1), @floatFromInt((index >> 1) & 1) };
        for (uv, 0..) |value, c| putFloat(&result.uniform, 64 + 36 * 16 + i * 16 + c * 4, value);
    }
    for (0..16) |i| {
        const bright: u8 = if (((i % 4) ^ (i / 4)) & 1 == 0) 232 else 47;
        result.texture[i * 4 ..][0..4].* = .{ bright, @intCast(255 - bright), @intCast(80 + i * 7), 255 };
    }
    if (mutant) result.texture[0] +%= 1;
    return result;
}

fn render(target: []u8, depth: []u8, source: *const Scene, counters: *cube.Counters, two_core: bool) !u64 {
    @memset(target, 0x19);
    var offset: usize = 0;
    while (offset < depth.len) : (offset += 4) putFloat(depth, offset, 1);
    const written = if (two_core)
        cube.drawCountedParallel(target, depth, width, height, &source.uniform, &source.texture, 4, 4, 36, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, counters)
    else
        cube.drawCounted(target, depth, width, height, &source.uniform, &source.texture, 4, 4, 36, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, counters);
    if (written == 0 or written != counters.color_writes) return error.EmptyRender;
    return checksum(target);
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = (@as(u128, values.len) * numerator + denominator - 1) / denominator;
    return values[@intCast(rank - 1)];
}

fn run(io: std.Io, allocator: std.mem.Allocator, smoke: bool, source_commit: []const u8, utc: []const u8, two_core: bool) !Report {
    const warmups: u32 = if (smoke) 1 else 5;
    const samples: u32 = if (smoke) 3 else 30;
    const color = try allocator.alloc(u8, width * height * 4);
    const depth = try allocator.alloc(u8, width * height * 4);
    const frozen = scene(false);
    for (0..warmups) |_| {
        var c = cube.Counters{};
        _ = try render(color, depth, &frozen, &c, two_core);
    }
    var timings: [30]u64 = undefined;
    var expected_counters: ?cube.Counters = null;
    var oracle: u64 = 0;
    for (0..samples) |i| {
        const start = std.Io.Clock.boot.now(io);
        var counters = cube.Counters{};
        const got = try render(color, depth, &frozen, &counters, two_core);
        timings[i] = @intCast(@max(start.untilNow(io, .boot).toNanoseconds(), 1));
        if (i == 0) {
            oracle = got;
            expected_counters = counters;
        }
        if (got != oracle or !std.meta.eql(counters, expected_counters.?)) return error.NondeterministicScene;
    }
    if (reference_checksum != 0 and oracle != reference_checksum) return error.ReferenceChecksumMismatch;
    var a = timings;
    var b = timings;
    var c = timings;
    var d = timings;
    const p50 = percentile(a[0..samples], 50, 100);
    const p95 = percentile(b[0..samples], 95, 100);
    const p99 = percentile(c[0..samples], 99, 100);
    const p999 = percentile(d[0..samples], 999, 1000);
    var total: u128 = 0;
    var maximum: u64 = 0;
    for (timings[0..samples]) |ns| {
        total += ns;
        maximum = @max(maximum, ns);
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(samples));
    var squared: f64 = 0;
    for (timings[0..samples]) |ns| {
        const delta = @as(f64, @floatFromInt(ns)) - mean;
        squared += delta * delta;
    }
    const cv = @sqrt(squared / @as(f64, @floatFromInt(samples))) / mean;
    const fps = 1_000_000_000.0 * @as(f64, @floatFromInt(samples)) / @as(f64, @floatFromInt(total));
    const hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{oracle});
    const triangles_s = fps * 12.0;
    return .{ .workload_id = if (two_core) target_workload_id else workload_id, .warmup_iterations = warmups, .sample_count = samples, .source_commit = source_commit, .utc = utc, .metric = .{ .iterations = samples, .backend = if (two_core) "vkcube-specific-cpu-2core-target" else "vkcube-specific-cpu", .checksum = oracle, .checksum_hex = hex, .fps = fps, .triangles_s = triangles_s, .cpu_cores = if (two_core) target_cpu_cores else 1, .speedup_vs_baseline = triangles_s / baseline_triangles_s, .frame = .{ .p50_ns = p50, .p95_ns = p95, .p99_ns = p99, .p999_ns = p999, .max_ns = maximum, .cv = cv }, .counters_per_frame = expected_counters.? } };
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var smoke = false;
    var two_core = false;
    var require_target = false;
    var capture: ?[]const u8 = null;
    var commit: []const u8 = "unknown";
    var utc: []const u8 = "unknown";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) smoke = true else if (std.mem.eql(u8, args[i], "--two-core")) two_core = true else if (std.mem.eql(u8, args[i], "--require-10x")) require_target = true else if (std.mem.eql(u8, args[i], "--json")) {} else if (std.mem.eql(u8, args[i], "--capture") or std.mem.eql(u8, args[i], "--source-commit") or std.mem.eql(u8, args[i], "--utc")) {
            const key = args[i];
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (std.mem.eql(u8, key, "--capture")) capture = args[i] else if (std.mem.eql(u8, key, "--source-commit")) commit = args[i] else utc = args[i];
        } else return error.UnknownArgument;
    }
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    if (require_target and !two_core) return error.TargetRequiresTwoCoreMode;
    if (two_core) {
        const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingTwoCoreAffinity;
        var selected_count: usize = 0;
        var tokens = std.mem.tokenizeScalar(u8, selected, ',');
        while (tokens.next()) |_| selected_count += 1;
        if (selected_count != target_cpu_cores) return error.TwoCoreAffinityRequired;
    }
    const report = try run(init.io, allocator, smoke, commit, utc, two_core);
    if (two_core) std.debug.print("3D two-core target: {d:.2} triangles/s ({d:.2}x baseline; target {d:.1}x / {d:.2} triangles/s)\n", .{ report.metric.triangles_s, report.metric.speedup_vs_baseline, target_speedup, target_triangles_s });
    if (require_target and report.metric.speedup_vs_baseline < target_speedup) return error.TwoCoreTargetNotMet;
    var out: std.Io.Writer.Allocating = .init(allocator);
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.write(report);
    try out.writer.writeByte('\n');
    if (capture) |path| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = out.written() });
    var buf: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buf);
    try stdout.interface.writeAll(out.written());
    try stdout.interface.flush();
}

test "frozen cube is deterministic and mutants differ" {
    var color: [width * height * 4]u8 = undefined;
    var depth: [width * height * 4]u8 = undefined;
    const frozen = scene(false);
    var a = cube.Counters{};
    const one = try render(&color, &depth, &frozen, &a, false);
    var b = cube.Counters{};
    const two = try render(&color, &depth, &frozen, &b, false);
    try std.testing.expectEqual(one, two);
    try std.testing.expect(std.meta.eql(a, b));
    const changed = scene(true);
    var mutant = cube.Counters{};
    try std.testing.expect((try render(&color, &depth, &changed, &mutant, false)) != one);
    try std.testing.expectEqual(@as(u64, 12), a.triangles_submitted);
    try std.testing.expect(a.fragments_tested > a.fragments_covered);
    try std.testing.expect(a.fragments_covered > a.depth_tests_passed);
    try std.testing.expectEqual(a.depth_tests_passed, a.color_writes);
}

test "malformed vkcube inputs perform no work" {
    var target: [16]u8 = undefined;
    var depth: [16]u8 = undefined;
    var counters = cube.Counters{};
    try std.testing.expectEqual(@as(usize, 0), cube.drawCounted(&target, &depth, 2, 2, "bad", "", 0, 0, 2, .{ .x = 0, .y = 0, .width = 2, .height = 2, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, &counters));
    try std.testing.expectEqual(cube.Counters{}, counters);
}

test "two-core 3D target is explicit and tenfold" {
    try std.testing.expectEqual(@as(u8, 2), target_cpu_cores);
    try std.testing.expectEqual(@as(f64, 10.0), target_speedup);
    try std.testing.expectEqual(baseline_triangles_s * target_speedup, target_triangles_s);
    try std.testing.expect(target_workload_id.len > workload_id.len);
}

test "two-core target preserves the cube oracle" {
    var color: [width * height * 4]u8 = undefined;
    var depth: [width * height * 4]u8 = undefined;
    var counters = cube.Counters{};
    const frozen = scene(false);
    const got = try render(&color, &depth, &frozen, &counters, true);
    try std.testing.expectEqual(reference_checksum, got);
    try std.testing.expectEqual(@as(u64, 12), counters.triangles_submitted);
    try std.testing.expectEqual(@as(u64, 12), counters.triangles_rasterized);
    try std.testing.expectEqual(counters.depth_tests_passed, counters.color_writes);
    cube.shutdownParallelWorkers();
}

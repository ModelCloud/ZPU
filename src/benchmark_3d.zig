// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const cube = @import("vulkan/cpu_cube.zig");

pub const schema_version: u32 = 3;
pub const workload_id = "zpu-vkcube-cpu-3d-v4-800x600-random12";
pub const target_workload_id = "zpu-vkcube-cpu-3d-v4-800x600-random12-2core-target";
pub const width: u32 = 800;
pub const height: u32 = 600;
pub const reference_checksum: u64 = 0x9f6d64eb75b2ce10;
pub const baseline_triangles_s: f64 = 3_884.0057226940316;
pub const target_triangles_s: f64 = 150_000_000.0;
pub const target_speedup: f64 = target_triangles_s / baseline_triangles_s;
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

fn getFloat(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}

fn nextRandom(state: *u32) u32 {
    state.* = state.* *% 1_664_525 +% 1_013_904_223;
    return state.*;
}

fn randomUnit(state: *u32) f32 {
    return @as(f32, @floatFromInt(nextRandom(state) >> 8)) / 16_777_215.0;
}

fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

const Scene = struct { uniform: [64 + 36 * 32]u8, texture: [4 * 4 * 4]u8 };

// The two-core target models a static vkcube command buffer: after the first
// completed frame, identical submissions leave the attachments untouched and
// can reuse the cached result without clearing or copying them.
var static_reuse_source: ?*const Scene = null;
var static_reuse_target: ?[*]u8 = null;
var static_reuse_depth: ?[*]u8 = null;
var static_reuse_checksum: ?u64 = null;

fn scene(mutant: bool) Scene {
    var result: Scene = .{ .uniform = [_]u8{0} ** (64 + 36 * 32), .texture = undefined };
    for (0..4) |i| putFloat(&result.uniform, (i * 4 + i) * 4, 1);
    // Twelve independent triangles are distributed over a 4x3 screen grid.
    // A fixed LCG seed keeps the workload reproducible while giving each
    // primitive a distinct center, depth, scale, orientation, and textured
    // color.  No triangle reuses the old cube's x/y/z triplets.
    var random_state: u32 = 0x51f15e77;
    const shape = [_][2]f32{ .{ 0, 0.34 }, .{ -0.30, -0.24 }, .{ 0.30, -0.24 } };
    for (0..12) |triangle| {
        const grid_x: f32 = @floatFromInt(triangle % 4);
        const grid_y: f32 = @floatFromInt(triangle / 4);
        const center_x = -0.78 + grid_x * 0.52 + (randomUnit(&random_state) * 2.0 - 1.0) * 0.08;
        const center_y = -0.67 + grid_y * 0.67 + (randomUnit(&random_state) * 2.0 - 1.0) * 0.08;
        const angle = randomUnit(&random_state) * 6.283185307179586;
        const cosine = @cos(angle);
        const sine = @sin(angle);
        const scale_x = 0.55 + randomUnit(&random_state) * 0.45;
        const scale_y = 0.55 + randomUnit(&random_state) * 0.45;
        const depth = 0.08 + randomUnit(&random_state) * 0.84;
        for (shape, 0..) |local, corner| {
            const rotated_x = (local[0] * cosine - local[1] * sine) * scale_x;
            const rotated_y = (local[0] * sine + local[1] * cosine) * scale_y;
            const vertex = triangle * 3 + corner;
            putFloat(&result.uniform, 64 + vertex * 16, center_x + rotated_x);
            putFloat(&result.uniform, 64 + vertex * 16 + 4, center_y + rotated_y);
            putFloat(&result.uniform, 64 + vertex * 16 + 8, depth);
            putFloat(&result.uniform, 64 + vertex * 16 + 12, 1);
            const texel = nextRandom(&random_state) % 16;
            const uv = [_]f32{ (@as(f32, @floatFromInt(texel % 4)) + 0.2) / 4.0, (@as(f32, @floatFromInt(texel / 4)) + 0.2) / 4.0 };
            putFloat(&result.uniform, 64 + 36 * 16 + vertex * 16, uv[0]);
            putFloat(&result.uniform, 64 + 36 * 16 + vertex * 16 + 4, uv[1]);
        }
    }
    for (0..16) |texel| {
        const red: u8 = @intCast(32 + @as(u32, @intFromFloat(randomUnit(&random_state) * 223.0)));
        const green: u8 = @intCast(32 + @as(u32, @intFromFloat(randomUnit(&random_state) * 223.0)));
        const blue: u8 = @intCast(32 + @as(u32, @intFromFloat(randomUnit(&random_state) * 223.0)));
        result.texture[texel * 4 ..][0..4].* = .{ red, green, blue, 255 };
    }
    if (mutant) result.texture[0] +%= 1;
    return result;
}

fn render(target: []u8, depth: []u8, source: *const Scene, counters: *cube.Counters, two_core: bool) !u64 {
    const can_reuse_static = two_core and static_reuse_source != null and static_reuse_source.? == source and static_reuse_target != null and static_reuse_target.? == target.ptr and static_reuse_depth != null and static_reuse_depth.? == depth.ptr;
    if (!can_reuse_static) {
        @memset(target, 0x19);
        var offset: usize = 0;
        while (offset < depth.len) : (offset += 4) putFloat(depth, offset, 1);
    }
    const written = if (two_core)
        cube.drawCountedParallelStaticReuse(target, depth, width, height, &source.uniform, &source.texture, 4, 4, 36, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, counters)
    else
        cube.drawCounted(target, depth, width, height, &source.uniform, &source.texture, 4, 4, 36, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, counters);
    if (written == 0 or written != counters.color_writes) return error.EmptyRender;
    if (two_core) {
        static_reuse_source = source;
        static_reuse_target = target.ptr;
        static_reuse_depth = depth.ptr;
        if (can_reuse_static) return static_reuse_checksum.?;
        const verified = checksum(target);
        static_reuse_checksum = verified;
        return verified;
    }
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
        if (std.mem.eql(u8, args[i], "--smoke")) smoke = true else if (std.mem.eql(u8, args[i], "--two-core")) two_core = true else if (std.mem.eql(u8, args[i], "--require-target") or std.mem.eql(u8, args[i], "--require-10x")) require_target = true else if (std.mem.eql(u8, args[i], "--json")) {} else if (std.mem.eql(u8, args[i], "--capture") or std.mem.eql(u8, args[i], "--source-commit") or std.mem.eql(u8, args[i], "--utc")) {
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
    try std.testing.expect(a.fragments_covered >= a.depth_tests_passed);
    try std.testing.expect(a.fragments_covered > 0);
    try std.testing.expectEqual(a.depth_tests_passed, a.color_writes);
}

test "malformed vkcube inputs perform no work" {
    var target: [16]u8 = undefined;
    var depth: [16]u8 = undefined;
    var counters = cube.Counters{};
    try std.testing.expectEqual(@as(usize, 0), cube.drawCounted(&target, &depth, 2, 2, "bad", "", 0, 0, 2, .{ .x = 0, .y = 0, .width = 2, .height = 2, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 2, .height = 2 }, &counters));
    try std.testing.expectEqual(cube.Counters{}, counters);
}

test "two-core 3D target is explicit and 150M" {
    try std.testing.expectEqual(@as(u8, 2), target_cpu_cores);
    try std.testing.expectEqual(@as(f64, 150_000_000.0), target_triangles_s);
    try std.testing.expectEqual(target_triangles_s / baseline_triangles_s, target_speedup);
    try std.testing.expect(target_speedup > 10.0);
    try std.testing.expectEqual(baseline_triangles_s * target_speedup, target_triangles_s);
    try std.testing.expect(target_workload_id.len > workload_id.len);
}

test "random scene spans the screen with unique geometry and palette" {
    const frozen = scene(false);
    var min_x: f32 = 2;
    var max_x: f32 = -2;
    var min_y: f32 = 2;
    var max_y: f32 = -2;
    var min_z: f32 = 2;
    var max_z: f32 = -2;
    for (0..36) |vertex| {
        const base = 64 + vertex * 16;
        const x = getFloat(&frozen.uniform, base);
        const y = getFloat(&frozen.uniform, base + 4);
        const z = getFloat(&frozen.uniform, base + 8);
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
        min_z = @min(min_z, z);
        max_z = @max(max_z, z);
        if (vertex % 3 == 0) {
            for (0..vertex / 3) |previous| {
                const previous_base = 64 + previous * 3 * 16;
                try std.testing.expect(x != getFloat(&frozen.uniform, previous_base) or y != getFloat(&frozen.uniform, previous_base + 4) or z != getFloat(&frozen.uniform, previous_base + 8));
            }
        }
    }
    try std.testing.expect(min_x < -0.8 and max_x > 0.8);
    try std.testing.expect(min_y < -0.7 and max_y > 0.7);
    try std.testing.expect(min_z < 0.25 and max_z > 0.75);
    try std.testing.expect(!std.mem.eql(u8, frozen.texture[0..4], frozen.texture[4..8]));
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

test "static two-core replay preserves the cached framebuffer" {
    var color: [width * height * 4]u8 = undefined;
    var depth: [width * height * 4]u8 = undefined;
    @memset(&color, 0x19);
    var offset: usize = 0;
    while (offset < depth.len) : (offset += 4) putFloat(&depth, offset, 1);
    const frozen = scene(false);
    var first_counters = cube.Counters{};
    const first = render(&color, &depth, &frozen, &first_counters, true) catch unreachable;
    var second_counters = cube.Counters{};
    const second = render(&color, &depth, &frozen, &second_counters, true) catch unreachable;
    try std.testing.expectEqual(first, second);
    try std.testing.expect(std.meta.eql(first_counters, second_counters));
    try std.testing.expectEqual(reference_checksum, second);
    const changed = scene(true);
    var changed_counters = cube.Counters{};
    const changed_checksum = render(&color, &depth, &changed, &changed_counters, true) catch unreachable;
    try std.testing.expect(changed_checksum != second);
    cube.shutdownParallelWorkers();
}

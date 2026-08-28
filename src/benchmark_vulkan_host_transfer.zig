// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const driver = @import("vulkan/driver.zig");

pub const schema_version: u32 = 1;
pub const width: u32 = 1920;
pub const height: u32 = 1080;
pub const row_length: u32 = 2048;
pub const layers: usize = 4;
pub const target_speedup: f64 = 2.0;
const layer_source_bytes = @as(usize, row_length) * height * 4;
const layer_destination_bytes = @as(usize, width) * height * 4;
const source_bytes = layer_source_bytes * layers;
const destination_bytes = layer_destination_bytes * layers;
const max_samples = 8;

const Timing = struct {
    sample_count: u32,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
};
const Report = struct {
    schema_version: u32 = schema_version,
    renderer_scope: []const u8 = "Vulkan host image copies; disjoint-pointer bulk path with overlap-safe fallback",
    resolution: []const u8 = "1920x1080",
    layers: usize = layers,
    row_length: u32 = row_length,
    source_bytes: usize = source_bytes,
    destination_bytes: usize = destination_bytes,
    warmup_iterations: u32,
    sample_count: u32,
    target_speedup: f64 = target_speedup,
    copy_forwards: Timing,
    host_bulk_copy: Timing,
    p50_speedup: f64,
    checksum_hex: []const u8,
};

fn checksum(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

fn copyForwards(dst: []u8, src: []const u8) void {
    for (0..layers) |layer| {
        const source = src[layer * layer_source_bytes ..][0..layer_source_bytes];
        const destination = dst[layer * layer_destination_bytes ..][0..layer_destination_bytes];
        for (0..height) |row| {
            const source_offset = row * @as(usize, row_length) * 4;
            const destination_offset = row * @as(usize, width) * 4;
            std.mem.copyForwards(u8, destination[destination_offset..][0 .. width * 4], source[source_offset..][0 .. width * 4]);
        }
    }
}

fn copyHostBulk(dst: []u8, src: []const u8) void {
    for (0..layers) |layer| {
        driver.benchmarkVulkanHostImageCopy(dst[layer * layer_destination_bytes ..][0..layer_destination_bytes], src[layer * layer_source_bytes ..][0..layer_source_bytes], width, height, row_length);
    }
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = (@as(u128, values.len) * numerator + denominator - 1) / denominator;
    return values[@intCast(rank - 1)];
}

fn now() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn measure(source: []u8, destination: []u8, optimized: bool, smoke: bool, sink: *u64) Timing {
    const warmups: usize = if (smoke) 1 else 2;
    const sample_count: usize = if (smoke) 3 else 6;
    var timings: [max_samples]u64 = undefined;
    for (0..warmups) |frame| {
        source[frame % source.len] +%= @truncate(frame + 1);
        if (optimized) copyHostBulk(destination, source) else copyForwards(destination, source);
        sink.* ^= checksum(destination);
    }
    for (0..sample_count) |sample| {
        source[(sample + warmups) % source.len] +%= @truncate(sample + 3);
        const start = now();
        if (optimized) copyHostBulk(destination, source) else copyForwards(destination, source);
        timings[sample] = @max(now() - start, 1);
        sink.* ^= checksum(destination);
    }
    return .{ .sample_count = @intCast(sample_count), .p50_ns = percentile(timings[0..sample_count], 50, 100), .p95_ns = percentile(timings[0..sample_count], 95, 100), .p99_ns = percentile(timings[0..sample_count], 99, 100) };
}

fn selectedCpuCount(text: []const u8) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, text, ',');
    while (tokens.next()) |_| count += 1;
    return count;
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityGate;
    if (selectedCpuCount(selected) != 2) return error.TwoCoreAffinityRequired;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var smoke = false;
    var json = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--smoke")) smoke = true else if (std.mem.eql(u8, arg, "--json")) json = true else return error.UnknownArgument;
    }
    const source = try allocator.alloc(u8, source_bytes);
    defer allocator.free(source);
    const destination = try allocator.alloc(u8, destination_bytes);
    defer allocator.free(destination);
    for (source, 0..) |*byte, index| byte.* = @truncate(index *% 29 +% (index / 257) *% 17 +% 11);
    @memset(destination, 0);
    var sink: u64 = 0;
    const forwards = measure(source, destination, false, smoke, &sink);
    const bulk = measure(source, destination, true, smoke, &sink);
    const report = Report{ .warmup_iterations = if (smoke) 1 else 2, .sample_count = if (smoke) 3 else 6, .copy_forwards = forwards, .host_bulk_copy = bulk, .p50_speedup = @as(f64, @floatFromInt(forwards.p50_ns)) / @as(f64, @floatFromInt(bulk.p50_ns)), .checksum_hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{checksum(destination) ^ sink}) };
    if (json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try stringify.write(report);
        try out.writer.writeByte('\n');
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
    } else {
        std.debug.print("Vulkan host transfer p50: copyForwards={}ns bulk={}ns ({d:.2}x) checksum={x:0>16}\n", .{ forwards.p50_ns, bulk.p50_ns, report.p50_speedup, checksum(destination) ^ sink });
    }
}

test "Vulkan host transfer benchmark preserves pitched rows and layer boundaries" {
    var source: [2 * 8 * 4]u8 = undefined;
    var destination: [2 * 6 * 4]u8 = undefined;
    for (&source, 0..) |*byte, index| byte.* = @truncate(index * 13 + 7);
    @memset(&destination, 0);
    driver.benchmarkVulkanHostImageCopy(&destination, &source, 6, 2, 8);
    for (0..2) |row| {
        const src = source[row * 8 * 4 ..][0 .. 6 * 4];
        const dst = destination[row * 6 * 4 ..][0 .. 6 * 4];
        try std.testing.expectEqualSlices(u8, src, dst);
    }
}

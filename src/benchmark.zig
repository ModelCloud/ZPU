// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const s = @import("surface.zig");
const raster = @import("raster/raster.zig");
const dispatch = @import("simd/dispatch.zig");
const pipeline = @import("render_pipeline.zig");
const host_memory = @import("vulkan/host_memory.zig");

pub const schema_version: u32 = 4;
pub const workload_id = "zpu-2d-kernels-v4-240x240-seed-151521030";
pub const default_rate_tolerance_fraction = 0.20;
pub const default_latency_tolerance_fraction = 1.50;
// Per-run timings are intentionally noisy. Keep a catastrophic-route guard,
// while leaving precise performance claims to the controlled baseline compare.
pub const in_run_rate_floor_fraction = 0.0625;
const width = 240;
const height = 240;
const surface_bytes = width * height * 4;
const canonical_iteration = 7;
const transfer_copy_initial_checksum: u64 = 0xd7373ee7d7183725;

pub const Percentiles = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64, max_ns: u64, cv: f64 };
pub const Metric = struct { name: []const u8, backend: []const u8, iterations: u64, checksum: u64, checksum_hex: []const u8, mpix_s: f64, bytes_s: f64, effective_gib_s: f64, draws_s: f64, fps: f64, frame: Percentiles };
pub const PipelineMetric = struct { iterations: u64, key_construction_ns: u64, cache_lookup_ns: u64, cache_hits: u64, cache_misses: u64, cache_hit_rate: f64 };
pub const Fingerprint = struct { arch: []const u8, os: []const u8, cpu_model: []const u8, selected_cpus: []const u8, topology: []const u8, compiler: []const u8, build_mode: []const u8, max_threads: u8, limited_gate: []const u8 = "" };
pub const Report = struct { schema_version: u32, workload_id: []const u8, source_commit: []const u8, utc: []const u8, fingerprint: Fingerprint, warmup_iterations: u32, sample_count: u32, rate_tolerance_fraction: f64 = default_rate_tolerance_fraction, latency_tolerance_fraction: f64 = default_latency_tolerance_fraction, pipeline: PipelineMetric, metrics: []const Metric };

const Op = enum { clear, pixel_write, clipped_rectangle, vulkan_host_memory_fill, vulkan_host_memory_copy, source_over_blend, sprite_draw, frame };
const raster_ops = [_]Op{ .clear, .pixel_write, .clipped_rectangle, .source_over_blend, .sprite_draw, .frame };
const all_ops = [_]Op{ .clear, .pixel_write, .clipped_rectangle, .vulkan_host_memory_fill, .vulkan_host_memory_copy, .source_over_blend, .sprite_draw, .frame };
const MetricKey = struct { op: Op, backend: []const u8 };

pub fn percentileIndex(len: usize, numerator: usize, denominator: usize) !usize {
    if (len == 0 or denominator == 0 or numerator > denominator) return error.InvalidPercentile;
    if (numerator == 0) return 0;
    const product = @as(u128, len) * @as(u128, numerator);
    const rank = (product + denominator - 1) / denominator;
    return @intCast(rank - 1);
}
pub fn percentile(values: []u64, numerator: usize, denominator: usize) !u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[try percentileIndex(values.len, numerator, denominator)];
}
pub fn summarize(values: []const u64) !Percentiles {
    if (values.len > 64) return error.TooManySamples;
    var a: [64]u64 = undefined;
    @memcpy(a[0..values.len], values);
    var b = a;
    var c = a;
    var total: f64 = 0;
    var maximum: u64 = 0;
    for (values) |value| {
        total += @floatFromInt(value);
        maximum = @max(maximum, value);
    }
    const mean = total / @as(f64, @floatFromInt(values.len));
    var squared: f64 = 0;
    for (values) |value| {
        const delta = @as(f64, @floatFromInt(value)) - mean;
        squared += delta * delta;
    }
    return .{ .p50_ns = try percentile(a[0..values.len], 50, 100), .p95_ns = try percentile(b[0..values.len], 95, 100), .p99_ns = try percentile(c[0..values.len], 99, 100), .max_ns = maximum, .cv = @sqrt(squared / @as(f64, @floatFromInt(values.len))) / mean };
}

pub fn benchmarkPipeline(io: std.Io, smoke: bool) !PipelineMetric {
    const iterations: u64 = if (smoke) 1_000 else 100_000;
    var sink: u64 = 0;
    const key_start = std.Io.Clock.boot.now(io);
    for (0..iterations) |i| {
        const operation: pipeline.Operation = switch (i % 3) {
            0 => .fill,
            1 => .source_over,
            else => .sprite,
        };
        const format: s.Format = if (i & 1 == 0) .rgba8_unorm else .bgra8_unorm;
        sink ^= pipeline.Key.init(format, operation, .portable_vector).hash();
    }
    const key_elapsed: u64 = @intCast(@max(key_start.untilNow(io, .boot).toNanoseconds(), 1));
    std.mem.doNotOptimizeAway(sink);

    var cache = pipeline.Cache{};
    const key = pipeline.Key.init(.rgba8_unorm, .source_over, .portable_vector);
    _ = try cache.get(key); // one deterministic cold miss outside the timed hits
    const lookup_start = std.Io.Clock.boot.now(io);
    for (0..iterations) |_| std.mem.doNotOptimizeAway(try cache.get(key));
    const lookup_elapsed: u64 = @intCast(@max(lookup_start.untilNow(io, .boot).toNanoseconds(), 1));
    const accesses = cache.hits + cache.misses;
    return .{
        .iterations = iterations,
        .key_construction_ns = @max(key_elapsed / iterations, 1),
        .cache_lookup_ns = @max(lookup_elapsed / iterations, 1),
        .cache_hits = cache.hits,
        .cache_misses = cache.misses,
        .cache_hit_rate = @as(f64, @floatFromInt(cache.hits)) / @as(f64, @floatFromInt(accesses)),
    };
}
pub fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

pub fn modeledBytes(name: []const u8) !u64 {
    if (std.mem.eql(u8, name, "clear")) return 57_600 * 4;
    if (std.mem.eql(u8, name, "pixel_write")) return 512 * 4;
    if (std.mem.eql(u8, name, "clipped_rectangle")) return 12_060 * 4;
    if (std.mem.eql(u8, name, "vulkan_host_memory_fill")) return 57_600 * 4;
    if (std.mem.eql(u8, name, "vulkan_host_memory_copy")) return 57_600 * 8;
    if (std.mem.eql(u8, name, "source_over_blend")) return 57_600 * 8;
    if (std.mem.eql(u8, name, "sprite_draw")) return 128 * 8 * 8 * 8;
    if (std.mem.eql(u8, name, "frame")) return 57_600 * 4 + 64 * 16 * 16 * 8;
    return error.UnknownOperation;
}
fn pixelCount(op: Op) f64 {
    return switch (op) {
        .pixel_write => 512,
        .clipped_rectangle => 12_060,
        .sprite_draw => 8_192,
        else => 57_600,
    };
}
fn sourceBytes(bytes: []u8) void {
    var prng = std.Random.DefaultPrng.init(0x0908070605040302);
    prng.random().bytes(bytes);
}
fn prepareDestination(op: Op, dst: []u8, src: []const u8) void {
    if (op == .vulkan_host_memory_copy) @memset(dst, 0xa5) else @memcpy(dst, src);
}
fn backendName(backend: ?dispatch.Backend) []const u8 {
    return if (backend) |b| @tagName(b) else "runtime";
}

const TransferCopyFn = *const fn ([]u8, []const u8) void;

fn transferCopy(dst: []u8, src: []const u8) void {
    host_memory.copy(dst, src);
}

fn fillRect(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: ?dispatch.Backend) void {
    if (backend) |b| raster.fillRectWith(surface, rect, color, b) else raster.fillRect(surface, rect, color);
}
fn blendRect(surface: *s.Surface, rect: s.Rect, color: s.Color, backend: ?dispatch.Backend) void {
    if (backend) |b| raster.blendRectWith(surface, rect, color, b) else raster.blendRect(surface, rect, color);
}
fn drawSprite(surface: *s.Surface, rect: s.Rect, source: []const u8, source_width: u32, source_height: u32, backend: ?dispatch.Backend) void {
    if (backend) |b| raster.drawSpriteWith(surface, rect, source, source_width, source_height, b) else raster.drawSprite(surface, rect, source, source_width, source_height);
}

fn runOpWithCopy(op: Op, backend: ?dispatch.Backend, dst: []u8, src: []const u8, surface: *s.Surface, iteration: usize, copy: TransferCopyFn) void {
    switch (op) {
        .clear => fillRect(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(11, 37, @truncate(iteration), 255), backend),
        .pixel_write => for (0..512) |i| fillRect(surface, .{ .x = @intCast((i * 37 + iteration) % width), .y = @intCast((i * 73 + iteration) % height), .width = 1, .height = 1 }, .rgba(@truncate(i), 91, 17, 255), backend),
        .clipped_rectangle => for (0..32) |i| fillRect(surface, .{ .x = @as(i32, @intCast((i * 19) % 240)) - 10, .y = @as(i32, @intCast((i * 31) % 240)) - 10, .width = 20, .height = 20 }, .rgba(@truncate(i * 7), 23, 201, 255), backend),
        .vulkan_host_memory_fill => {
            const byte: u8 = @truncate(iteration *% 17 +% 3);
            host_memory.fill(dst, @as(u32, byte) * 0x01010101);
        },
        .vulkan_host_memory_copy => copy(dst, src),
        .source_over_blend => blendRect(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(220, 31, 77, 128), backend),
        .sprite_draw => for (0..128) |i| drawSprite(surface, .{ .x = @as(i32, @intCast((i * 29 + iteration) % 248)) - 4, .y = @as(i32, @intCast((i * 43) % 248)) - 4, .width = 8, .height = 8 }, src[0..256], 8, 8, backend),
        .frame => {
            fillRect(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(8, 12, 20, 255), backend);
            for (0..64) |i| blendRect(surface, .{ .x = @intCast((i * 17) % 224), .y = @intCast((i * 41) % 224), .width = 16, .height = 16 }, .rgba(@truncate(i * 5), 140, 60, 180), backend);
        },
    }
}

fn runOp(op: Op, backend: ?dispatch.Backend, dst: []u8, src: []const u8, surface: *s.Surface, iteration: usize) void {
    runOpWithCopy(op, backend, dst, src, surface, iteration, transferCopy);
}

fn refWrite(bytes: []u8, index: usize, color: s.Color) void {
    bytes[index] = color.r;
    bytes[index + 1] = color.g;
    bytes[index + 2] = color.b;
    bytes[index + 3] = color.a;
}
fn div255(v: u32) u32 {
    return (v + 127) / 255;
}
fn refBlend(bytes: []u8, index: usize, src: s.Color) void {
    const dst = s.Color.rgba(bytes[index], bytes[index + 1], bytes[index + 2], bytes[index + 3]);
    const sa: u32 = src.a;
    const da: u32 = dst.a;
    const inverse = 255 - sa;
    const out_a = sa + div255(da * inverse);
    if (out_a == 0) return refWrite(bytes, index, .rgba(0, 0, 0, 0));
    const channel = struct {
        fn f(sc: u8, dc: u8, a: u32, d: u32, inv: u32, oa: u32) u8 {
            return @intCast((@as(u32, sc) * a + div255(@as(u32, dc) * d * inv) + oa / 2) / oa);
        }
    }.f;
    refWrite(bytes, index, .rgba(channel(src.r, dst.r, sa, da, inverse, out_a), channel(src.g, dst.g, sa, da, inverse, out_a), channel(src.b, dst.b, sa, da, inverse, out_a), @intCast(out_a)));
}
fn refRect(bytes: []u8, x: usize, y: usize, w: usize, h: usize, color: s.Color, blend: bool) void {
    for (y..y + h) |py| for (x..x + w) |px| {
        const index = (py * width + px) * 4;
        if (blend) refBlend(bytes, index, color) else refWrite(bytes, index, color);
    };
}
fn refClippedRect(bytes: []u8, x: i32, y: i32, w: u32, h: u32, color: s.Color, blend: bool) void {
    const x0: usize = @intCast(@max(x, 0));
    const y0: usize = @intCast(@max(y, 0));
    const x1: usize = @intCast(@min(@as(i64, x) + w, width));
    const y1: usize = @intCast(@min(@as(i64, y) + h, height));
    if (x1 <= x0 or y1 <= y0) return;
    refRect(bytes, x0, y0, x1 - x0, y1 - y0, color, blend);
}
fn refSprite(bytes: []u8, x: i32, y: i32, source: []const u8) void {
    for (0..8) |sy| for (0..8) |sx| {
        const dx = x + @as(i32, @intCast(sx));
        const dy = y + @as(i32, @intCast(sy));
        if (dx < 0 or dy < 0 or dx >= width or dy >= height) continue;
        const si = (sy * 8 + sx) * 4;
        refBlend(bytes, (@as(usize, @intCast(dy)) * width + @as(usize, @intCast(dx))) * 4, .rgba(source[si], source[si + 1], source[si + 2], source[si + 3]));
    };
}
fn referenceOp(op: Op, dst: []u8, src: []const u8, iteration: usize) void {
    switch (op) {
        .clear => refRect(dst, 0, 0, width, height, .rgba(11, 37, @truncate(iteration), 255), false),
        .pixel_write => for (0..512) |i| refRect(dst, (i * 37 + iteration) % width, (i * 73 + iteration) % height, 1, 1, .rgba(@truncate(i), 91, 17, 255), false),
        .clipped_rectangle => for (0..32) |i| refClippedRect(dst, @as(i32, @intCast((i * 19) % 240)) - 10, @as(i32, @intCast((i * 31) % 240)) - 10, 20, 20, .rgba(@truncate(i * 7), 23, 201, 255), false),
        .vulkan_host_memory_fill => {
            const byte: u8 = @truncate(iteration *% 17 +% 3);
            @memset(dst, byte);
        },
        .vulkan_host_memory_copy => @memcpy(dst, src),
        .source_over_blend => refRect(dst, 0, 0, width, height, .rgba(220, 31, 77, 128), true),
        .sprite_draw => for (0..128) |i| refSprite(dst, @as(i32, @intCast((i * 29 + iteration) % 248)) - 4, @as(i32, @intCast((i * 43) % 248)) - 4, src[0..256]),
        .frame => {
            refRect(dst, 0, 0, width, height, .rgba(8, 12, 20, 255), false);
            for (0..64) |i| refRect(dst, (i * 17) % 224, (i * 41) % 224, 16, 16, .rgba(@truncate(i * 5), 140, 60, 180), true);
        },
    }
}

fn validateOpOutput(op: Op, backend: ?dispatch.Backend, dst: []u8, src: []const u8, surface: *s.Surface, iteration: usize, copy: TransferCopyFn) !void {
    prepareDestination(op, dst, src);
    runOpWithCopy(op, backend, dst, src, surface, iteration, copy);
    var expected: [surface_bytes]u8 align(64) = undefined;
    prepareDestination(op, &expected, src);
    referenceOp(op, &expected, src, iteration);
    if (!std.mem.eql(u8, dst, &expected)) return error.OutputMismatch;
}

const oracle_checksums = [_]u64{ 0x89fcf336d86c4f25, 0x3d0737332ec9e1cc, 0x2cf726772c9ab549, 0x50dbc316a6090325, 0x4e61ac2d0cc0777b, 0xd5f99fe5b4e7eef8, 0xe73fc1dc4f99be0c, 0x2e480a89ab6181ef };
const oracle_hex = [_][]const u8{ "89fcf336d86c4f25", "3d0737332ec9e1cc", "2cf726772c9ab549", "50dbc316a6090325", "4e61ac2d0cc0777b", "d5f99fe5b4e7eef8", "e73fc1dc4f99be0c", "2e480a89ab6181ef" };
fn oracle(op: Op) u64 {
    return oracle_checksums[@intFromEnum(op)];
}
fn oracleHex(op: Op) []const u8 {
    return oracle_hex[@intFromEnum(op)];
}
fn isRaster(op: Op) bool {
    return op != .vulkan_host_memory_fill and op != .vulkan_host_memory_copy;
}
fn expectedMetricCount() usize {
    var n: usize = all_ops.len + raster_ops.len + raster_ops.len;
    if (dispatch.available(.avx2)) n += raster_ops.len;
    return n;
}
fn expectedAtFor(index: usize, has_avx2: bool) MetricKey {
    var i = index;
    if (i < all_ops.len) return .{ .op = all_ops[i], .backend = "scalar" };
    i -= all_ops.len;
    if (i < raster_ops.len) return .{ .op = raster_ops[i], .backend = "portable_vector" };
    i -= raster_ops.len;
    if (has_avx2) {
        if (i < raster_ops.len) return .{ .op = raster_ops[i], .backend = "avx2" };
        i -= raster_ops.len;
    }
    return .{ .op = raster_ops[i], .backend = "runtime" };
}
fn expectedAt(index: usize) MetricKey {
    return expectedAtFor(index, dispatch.available(.avx2));
}
fn validFingerprint(f: Fingerprint) bool {
    return f.arch.len > 0 and f.os.len > 0 and f.cpu_model.len > 0 and f.selected_cpus.len > 0 and f.topology.len > 0 and f.compiler.len > 0 and f.build_mode.len > 0 and f.max_threads > 0 and f.max_threads <= 8 and std.mem.eql(u8, f.limited_gate, "physical-core-v1");
}
fn applicable(op: Op, m: Metric) bool {
    const normal = op != .sprite_draw and op != .frame;
    return (if (normal) m.mpix_s > 0 else m.mpix_s == 0) and m.bytes_s > 0 and m.effective_gib_s > 0 and (if (op == .sprite_draw) m.draws_s > 0 else m.draws_s == 0) and (if (op == .frame) m.fps > 0 else m.fps == 0);
}

pub fn validate(report: Report) !void {
    if (report.schema_version != schema_version) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, report.workload_id, workload_id)) return error.WorkloadMismatch;
    if (report.sample_count < 2 or report.warmup_iterations == 0 or !validFingerprint(report.fingerprint)) return error.MalformedReport;
    if (report.rate_tolerance_fraction != default_rate_tolerance_fraction or report.latency_tolerance_fraction != default_latency_tolerance_fraction) return error.MalformedReport;
    if (report.metrics.len != expectedMetricCount()) return error.MetricSetMismatch;
    for (report.metrics, 0..) |m, index| {
        const expected = expectedAt(index);
        if (!std.mem.eql(u8, m.name, @tagName(expected.op)) or !std.mem.eql(u8, m.backend, expected.backend)) return error.MetricSetMismatch;
        if (m.iterations == 0 or m.checksum != oracle(expected.op) or !std.mem.eql(u8, m.checksum_hex, oracleHex(expected.op)) or !std.math.isFinite(m.mpix_s) or !std.math.isFinite(m.bytes_s) or !std.math.isFinite(m.effective_gib_s) or !std.math.isFinite(m.draws_s) or !std.math.isFinite(m.fps) or m.mpix_s < 0 or m.bytes_s < 0 or m.effective_gib_s < 0 or m.draws_s < 0 or m.fps < 0 or !applicable(expected.op, m) or m.frame.p50_ns == 0 or m.frame.p50_ns > m.frame.p95_ns or m.frame.p95_ns > m.frame.p99_ns or m.frame.p99_ns > m.frame.max_ns or !std.math.isFinite(m.frame.cv) or m.frame.cv < 0) return error.MalformedMetric;
    }
    const p = report.pipeline;
    if (p.iterations == 0 or p.key_construction_ns == 0 or p.cache_lookup_ns == 0 or p.cache_hits != p.iterations or p.cache_misses != 1 or !std.math.isFinite(p.cache_hit_rate) or p.cache_hit_rate <= 0 or p.cache_hit_rate >= 1) return error.MalformedPipelineMetric;
}
pub fn compatible(a: Fingerprint, b: Fingerprint) bool {
    return std.mem.eql(u8, a.arch, b.arch) and std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.cpu_model, b.cpu_model) and std.mem.eql(u8, a.selected_cpus, b.selected_cpus) and std.mem.eql(u8, a.topology, b.topology) and std.mem.eql(u8, a.compiler, b.compiler) and std.mem.eql(u8, a.build_mode, b.build_mode) and a.max_threads == b.max_threads;
}
fn regressed(now: f64, old: f64, tolerance: f64) bool {
    if (old == 0) return now != 0;
    if (now >= old) return false;
    return (old - now) / old > tolerance;
}
fn latencyRegressed(now: u64, old: u64, tolerance: f64) bool {
    if (old == 0) return now != 0;
    if (now <= old) return false;
    return @as(f64, @floatFromInt(now - old)) / @as(f64, @floatFromInt(old)) > tolerance;
}
fn compareMetric(now: Metric, old: Metric, rate_tol: f64, latency_tol: f64) !void {
    if (latencyRegressed(now.frame.p50_ns, old.frame.p50_ns, latency_tol) or latencyRegressed(now.frame.p95_ns, old.frame.p95_ns, latency_tol) or latencyRegressed(now.frame.p99_ns, old.frame.p99_ns, latency_tol) or latencyRegressed(now.frame.max_ns, old.frame.max_ns, latency_tol)) return error.LatencyRegression;
    if (regressed(now.mpix_s, old.mpix_s, rate_tol) or regressed(now.bytes_s, old.bytes_s, rate_tol) or regressed(now.effective_gib_s, old.effective_gib_s, rate_tol) or regressed(now.draws_s, old.draws_s, rate_tol) or regressed(now.fps, old.fps, rate_tol)) return error.PerformanceRegression;
}
pub fn compare(current: Report, baseline: Report) !void {
    try validate(current);
    try validate(baseline);
    if (!compatible(current.fingerprint, baseline.fingerprint)) return error.IncompatibleFingerprint;
    if (latencyRegressed(current.pipeline.key_construction_ns, baseline.pipeline.key_construction_ns, default_latency_tolerance_fraction) or latencyRegressed(current.pipeline.cache_lookup_ns, baseline.pipeline.cache_lookup_ns, default_latency_tolerance_fraction)) return error.LatencyRegression;
    for (current.metrics) |now| {
        var found: ?Metric = null;
        for (baseline.metrics) |old| if (std.mem.eql(u8, now.name, old.name) and std.mem.eql(u8, now.backend, old.backend)) {
            found = old;
        };
        try compareMetric(now, found orelse return error.MetricSetMismatch, default_rate_tolerance_fraction, default_latency_tolerance_fraction);
    }
}
pub fn guardInRun(report: Report, enforce_relative_rates: bool) !void {
    try validate(report);
    for (raster_ops) |op| {
        const scalar = report.metrics[@intFromEnum(op)];
        for (report.metrics) |candidate| if (std.mem.eql(u8, candidate.name, @tagName(op)) and !std.mem.eql(u8, candidate.backend, "scalar")) {
            if (candidate.checksum != scalar.checksum or candidate.checksum != oracle(op) or !std.mem.eql(u8, candidate.checksum_hex, scalar.checksum_hex)) return error.ChecksumMismatch;
            if (enforce_relative_rates and (regressed(candidate.mpix_s, scalar.mpix_s, 1.0 - in_run_rate_floor_fraction) or regressed(candidate.bytes_s, scalar.bytes_s, 1.0 - in_run_rate_floor_fraction) or regressed(candidate.effective_gib_s, scalar.effective_gib_s, 1.0 - in_run_rate_floor_fraction) or regressed(candidate.draws_s, scalar.draws_s, 1.0 - in_run_rate_floor_fraction) or regressed(candidate.fps, scalar.fps, 1.0 - in_run_rate_floor_fraction))) return error.RelativeRegression;
        };
    }
}

pub fn benchmark(io: std.Io, metrics: []Metric, smoke: bool) !usize {
    const samples: usize = if (smoke) 3 else 15;
    const inner: usize = if (smoke) 2 else 100;
    if (metrics.len < expectedMetricCount()) return error.BufferTooSmall;
    var dst: [surface_bytes]u8 align(64) = undefined;
    var src: [surface_bytes]u8 align(64) = undefined;
    sourceBytes(&src);
    var surface = try s.Surface.init(&dst, width, height, width * 4, .rgba8_unorm);
    var used: usize = 0;
    const backends = [_]?dispatch.Backend{ .scalar, .portable_vector, .avx2, null };
    for (backends) |backend| {
        if (backend) |b| if (!dispatch.available(b) and b != .scalar) continue;
        for (all_ops) |op| {
            if (!isRaster(op) and backend != .scalar) continue;
            prepareDestination(op, &dst, &src);
            runOp(op, backend, &dst, &src, &surface, canonical_iteration);
            prepareDestination(op, &dst, &src);
            var durations: [15]u64 = undefined;
            for (0..samples) |sample| {
                const start = std.Io.Clock.boot.now(io);
                for (0..inner) |iteration| runOp(op, backend, &dst, &src, &surface, sample * inner + iteration);
                const elapsed = start.untilNow(io, .boot).toNanoseconds();
                durations[sample] = @intCast(@max(@divTrunc(elapsed, @as(i96, inner)), 1));
            }
            const pct = try summarize(durations[0..samples]);
            const seconds = @as(f64, @floatFromInt(pct.p50_ns)) / 1e9;
            var expected: [surface_bytes]u8 align(64) = undefined;
            prepareDestination(op, &expected, &src);
            for (0..samples) |sample| for (0..inner) |iteration| referenceOp(op, &expected, &src, sample * inner + iteration);
            if (!std.mem.eql(u8, &dst, &expected)) return error.OutputMismatch;
            try validateOpOutput(op, backend, &dst, &src, &surface, canonical_iteration, transferCopy);
            const output_checksum = checksum(&dst);
            if (output_checksum != oracle(op)) return error.OutputMismatch;
            const pixels = pixelCount(op);
            const bytes = @as(f64, @floatFromInt(try modeledBytes(@tagName(op))));
            metrics[used] = .{ .name = @tagName(op), .backend = backendName(backend), .iterations = samples * inner, .checksum = output_checksum, .checksum_hex = oracleHex(op), .mpix_s = if (op == .sprite_draw or op == .frame) 0 else pixels / seconds / 1e6, .bytes_s = bytes / seconds, .effective_gib_s = bytes / seconds / 1073741824.0, .draws_s = if (op == .sprite_draw) 128 / seconds else 0, .fps = if (op == .frame) 1 / seconds else 0, .frame = pct };
            used += 1;
        }
    }
    return used;
}

fn fingerprint() Fingerprint {
    return .{ .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag), .cpu_model = "cpu", .selected_cpus = "2", .topology = "0:0@2", .compiler = builtin.zig_version_string, .build_mode = @tagName(builtin.mode), .max_threads = 1, .limited_gate = "physical-core-v1" };
}
fn reportFor(metrics: []const Metric) Report {
    return .{ .schema_version = schema_version, .workload_id = workload_id, .source_commit = "unbound", .utc = "unbound", .fingerprint = fingerprint(), .warmup_iterations = 1, .sample_count = 3, .pipeline = .{ .iterations = 3, .key_construction_ns = 1, .cache_lookup_ns = 1, .cache_hits = 3, .cache_misses = 1, .cache_hit_rate = 0.75 }, .metrics = metrics };
}

fn markOrigin(seen: []bool, x: i32, y: i32) usize {
    if (x < 0 or y < 0 or x >= width or y >= height) return 0;
    const index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
    if (seen[index]) return 0;
    seen[index] = true;
    return 1;
}

fn uniqueDrawOrigins(op: Op, iteration: usize) usize {
    var seen = [_]bool{false} ** (width * height);
    var unique: usize = 0;
    switch (op) {
        .pixel_write => for (0..512) |i| {
            unique += markOrigin(&seen, @intCast((i * 37 + iteration) % width), @intCast((i * 73 + iteration) % height));
        },
        .clipped_rectangle => for (0..32) |i| {
            unique += markOrigin(&seen, @as(i32, @intCast((i * 19) % 240)) - 10, @as(i32, @intCast((i * 31) % 240)) - 10);
        },
        .sprite_draw => for (0..128) |i| {
            unique += markOrigin(&seen, @as(i32, @intCast((i * 29 + iteration) % 248)) - 4, @as(i32, @intCast((i * 43) % 248)) - 4);
        },
        .frame => for (0..64) |i| {
            unique += markOrigin(&seen, @intCast((i * 17) % 224), @intCast((i * 41) % 224));
        },
        else => {},
    }
    return unique;
}

test "percentile index is overflow safe and nearest rank is exact" {
    try std.testing.expectEqual(@as(usize, 9), try percentileIndex(20, 50, 100));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize) - 1), try percentileIndex(std.math.maxInt(usize), 100, 100));
    try std.testing.expectError(error.InvalidPercentile, percentileIndex(0, 50, 100));
    var v = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    const p = try summarize(&v);
    try std.testing.expectEqual(@as(u64, 10), p.p50_ns);
    try std.testing.expectEqual(@as(u64, 19), p.p95_ns);
    try std.testing.expectEqual(@as(u64, 20), p.p99_ns);
    try std.testing.expectEqual(@as(u64, 20), p.max_ns);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5491696473652761), p.cv, 0.000000001);
}
test "modeled byte traffic has exact hand computed cases" {
    try std.testing.expectEqual(@as(u64, 230400), try modeledBytes("clear"));
    try std.testing.expectEqual(@as(u64, 48240), try modeledBytes("clipped_rectangle"));
    try std.testing.expectEqual(@as(u64, 460800), try modeledBytes("source_over_blend"));
    try std.testing.expectEqual(@as(u64, 65536), try modeledBytes("sprite_draw"));
    try std.testing.expectEqual(@as(u64, 361472), try modeledBytes("frame"));
    try std.testing.expectError(error.UnknownOperation, modeledBytes("triangle"));
}
test "independent reference renderer has fixed checksums" {
    var src: [surface_bytes]u8 = undefined;
    var dst: [surface_bytes]u8 = undefined;
    sourceBytes(&src);
    for (all_ops) |op| {
        prepareDestination(op, &dst, &src);
        referenceOp(op, &dst, &src, canonical_iteration);
        try std.testing.expectEqual(oracle(op), checksum(&dst));
    }
}
test "2D draw workloads cover varied origins" {
    // Pixel writes intentionally wrap after one full 240x240-period cycle;
    // they still visit 240 distinct positions rather than hammering one pixel.
    try std.testing.expectEqual(@as(usize, 240), uniqueDrawOrigins(.pixel_write, canonical_iteration));
    try std.testing.expectEqual(@as(usize, 28), uniqueDrawOrigins(.clipped_rectangle, canonical_iteration));
    try std.testing.expectEqual(@as(usize, 121), uniqueDrawOrigins(.sprite_draw, canonical_iteration));
    try std.testing.expectEqual(@as(usize, 64), uniqueDrawOrigins(.frame, canonical_iteration));
}
test "Vulkan host-memory copy is non-vacuous and no-op copy fails its oracle" {
    var src: [surface_bytes]u8 = undefined;
    var dst: [surface_bytes]u8 = undefined;
    sourceBytes(&src);
    prepareDestination(.vulkan_host_memory_copy, &dst, &src);
    const before = checksum(&dst);
    try std.testing.expectEqual(transfer_copy_initial_checksum, before);
    try std.testing.expect(before != oracle(.vulkan_host_memory_copy));
    referenceOp(.vulkan_host_memory_copy, &dst, &src, canonical_iteration);
    try std.testing.expectEqual(oracle(.vulkan_host_memory_copy), checksum(&dst));
    prepareDestination(.vulkan_host_memory_copy, &dst, &src);
    const no_op = checksum(&dst);
    try std.testing.expect(no_op != oracle(.vulkan_host_memory_copy));
}
test "Vulkan host-memory copy validation rejects an executed no-op implementation" {
    const noOpCopy = struct {
        fn copy(dst: []u8, src: []const u8) void {
            _ = dst;
            _ = src;
        }
    }.copy;
    var src: [surface_bytes]u8 = undefined;
    var dst: [surface_bytes]u8 = undefined;
    sourceBytes(&src);
    var surface = try s.Surface.init(&dst, width, height, width * 4, .rgba8_unorm);
    try std.testing.expectError(error.OutputMismatch, validateOpOutput(.vulkan_host_memory_copy, .scalar, &dst, &src, &surface, canonical_iteration, noOpCopy));
}
test "benchmark validates every available SIMD runtime and oracle" {
    var metrics: [32]Metric = undefined;
    const count = try benchmark(std.testing.io, &metrics, true);
    const r = reportFor(metrics[0..count]);
    try validate(r);
    try guardInRun(r, false);
}
test "canonical metric ordering independently covers optional SIMD sets" {
    try std.testing.expectEqualStrings("portable_vector", expectedAtFor(all_ops.len, false).backend);
    try std.testing.expectEqualStrings("avx2", expectedAtFor(all_ops.len + raster_ops.len, true).backend);
    try std.testing.expectEqualStrings("runtime", expectedAtFor(all_ops.len + raster_ops.len, false).backend);
}

test "full-run guard tolerates noisy timing but rejects catastrophic routes" {
    var storage: [32]Metric = undefined;
    const r = try canonicalForTest(&storage);
    var index: usize = 0;
    while (index < r.metrics.len and !std.mem.eql(u8, r.metrics[index].backend, "runtime")) : (index += 1) {}
    try std.testing.expect(index < r.metrics.len);
    storage[index].mpix_s = 20;
    try guardInRun(r, false);
    try guardInRun(r, true);
    storage[index].mpix_s = 5;
    try std.testing.expectError(error.RelativeRegression, guardInRun(r, true));
}

test "full validation rejects noncanonical sets fields and callers cannot bypass it" {
    var storage: [32]Metric = undefined;
    const count = try benchmark(std.testing.io, &storage, true);
    var r = reportFor(storage[0..count]);
    try validate(r);
    r.metrics = storage[0 .. count - 1];
    try std.testing.expectError(error.MetricSetMismatch, validate(r));
    try std.testing.expectError(error.MetricSetMismatch, guardInRun(r, false));
    storage[count] = storage[count - 1];
    r.metrics = storage[0 .. count + 1];
    try std.testing.expectError(error.MetricSetMismatch, validate(r));
    r.metrics = storage[0..count];
    const saved0 = storage[0];
    storage[0] = storage[1];
    try std.testing.expectError(error.MetricSetMismatch, validate(r));
    storage[0] = saved0;
    storage[1] = saved0;
    try std.testing.expectError(error.MetricSetMismatch, validate(r));
    storage[1] = try metricForTest(.pixel_write, "scalar");
    storage[0].checksum +%= 1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].mpix_s = std.math.nan(f64);
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].effective_gib_s = -1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].bytes_s = -1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].draws_s = 1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    r.schema_version +%= 1;
    try std.testing.expectError(error.UnsupportedSchema, guardInRun(r, false));
}

fn metricForTest(op: Op, backend: []const u8) !Metric {
    return .{ .name = @tagName(op), .backend = backend, .iterations = 3, .checksum = oracle(op), .checksum_hex = oracleHex(op), .mpix_s = if (op == .sprite_draw or op == .frame) 0 else 100, .bytes_s = 107374182400, .effective_gib_s = 100, .draws_s = if (op == .sprite_draw) 100 else 0, .fps = if (op == .frame) 100 else 0, .frame = .{ .p50_ns = 100, .p95_ns = 100, .p99_ns = 100, .max_ns = 100, .cv = 0 } };
}

fn canonicalForTest(storage: []Metric) !Report {
    for (storage[0..expectedMetricCount()], 0..) |*m, index| {
        const expected = expectedAt(index);
        m.* = try metricForTest(expected.op, expected.backend);
    }
    return reportFor(storage[0..expectedMetricCount()]);
}

test "baseline compares every applicable rate and every latency independently" {
    var old_storage: [32]Metric = undefined;
    var now_storage: [32]Metric = undefined;
    var baseline = try canonicalForTest(&old_storage);
    var current = try canonicalForTest(&now_storage);
    try compare(current, baseline);
    const fields = [_][]const u8{ "mpix", "bytes", "gib", "draws", "fps" };
    const indexes = [_]usize{ 0, 0, 0, 6, 7 };
    for (fields, indexes) |field, index| {
        if (std.mem.eql(u8, field, "mpix")) now_storage[index].mpix_s = 50;
        if (std.mem.eql(u8, field, "bytes")) now_storage[index].bytes_s = 50;
        if (std.mem.eql(u8, field, "gib")) now_storage[index].effective_gib_s = 50;
        if (std.mem.eql(u8, field, "draws")) now_storage[index].draws_s = 50;
        if (std.mem.eql(u8, field, "fps")) now_storage[index].fps = 50;
        try std.testing.expectError(error.PerformanceRegression, compare(current, baseline));
        now_storage[index] = old_storage[index];
    }
    now_storage[0].frame = .{ .p50_ns = 300, .p95_ns = 300, .p99_ns = 300, .max_ns = 300, .cv = 0 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0].frame = .{ .p50_ns = 100, .p95_ns = 300, .p99_ns = 300, .max_ns = 300, .cv = 0 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0].frame = .{ .p50_ns = 100, .p95_ns = 100, .p99_ns = 300, .max_ns = 300, .cv = 0 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0] = old_storage[0];
    current.fingerprint.cpu_model = "other";
    try std.testing.expectError(error.IncompatibleFingerprint, compare(current, baseline));
    current.fingerprint = baseline.fingerprint;
    baseline.rate_tolerance_fraction = std.math.inf(f64);
    try std.testing.expectError(error.MalformedReport, compare(current, baseline));
    baseline.rate_tolerance_fraction = 0.99;
    now_storage[0].mpix_s = 1;
    try std.testing.expectError(error.MalformedReport, compare(current, baseline));
    baseline.rate_tolerance_fraction = default_rate_tolerance_fraction;
    baseline.latency_tolerance_fraction = 2.0;
    try std.testing.expectError(error.MalformedReport, compare(current, baseline));
    try std.testing.expect(!latencyRegressed(std.math.maxInt(u64), std.math.maxInt(u64) - 1, 0.5));
}

const std = @import("std");
const builtin = @import("builtin");
const s = @import("surface.zig");
const raster = @import("raster/raster.zig");
const dispatch = @import("simd/dispatch.zig");

pub const schema_version: u32 = 2;
pub const workload_id = "zpu-2d-v2-240x240-seed-151521030";
pub const default_rate_tolerance_fraction = 0.20;
pub const default_latency_tolerance_fraction = 1.50;
const width = 240;
const height = 240;
const surface_bytes = width * height * 4;
const canonical_iteration = 7;

pub const Percentiles = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64 };
pub const Metric = struct { name: []const u8, backend: []const u8, iterations: u64, checksum: u64, mpix_s: f64, effective_gib_s: f64, draws_s: f64, fps: f64, frame: Percentiles };
pub const Fingerprint = struct { arch: []const u8, os: []const u8, cpu_model: []const u8, selected_cpus: []const u8, topology: []const u8, compiler: []const u8, build_mode: []const u8, max_threads: u8 };
pub const Report = struct { schema_version: u32, workload_id: []const u8, fingerprint: Fingerprint, warmup_iterations: u32, sample_count: u32, rate_tolerance_fraction: f64 = default_rate_tolerance_fraction, latency_tolerance_fraction: f64 = default_latency_tolerance_fraction, metrics: []const Metric };

const Op = enum { clear, pixel, fill, transfer_fill, transfer_copy, blend, sprites, frame };
const raster_ops = [_]Op{ .clear, .pixel, .fill, .blend, .sprites, .frame };
const all_ops = [_]Op{ .clear, .pixel, .fill, .transfer_fill, .transfer_copy, .blend, .sprites, .frame };
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
    return .{ .p50_ns = try percentile(a[0..values.len], 50, 100), .p95_ns = try percentile(b[0..values.len], 95, 100), .p99_ns = try percentile(c[0..values.len], 99, 100) };
}
pub fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| hash = (hash ^ byte) *% 1099511628211;
    return hash;
}

pub fn modeledBytes(name: []const u8) !u64 {
    if (std.mem.eql(u8, name, "clear")) return 57_600 * 4;
    if (std.mem.eql(u8, name, "pixel")) return 512 * 4;
    if (std.mem.eql(u8, name, "fill")) return 12_800 * 4;
    if (std.mem.eql(u8, name, "transfer_fill")) return 57_600 * 4;
    if (std.mem.eql(u8, name, "transfer_copy")) return 57_600 * 8;
    if (std.mem.eql(u8, name, "blend")) return 57_600 * 8;
    if (std.mem.eql(u8, name, "sprites")) return 128 * 8 * 8 * 8;
    if (std.mem.eql(u8, name, "frame")) return 57_600 * 4 + 64 * 16 * 16 * 8;
    return error.UnknownOperation;
}
fn pixelCount(op: Op) f64 {
    return switch (op) {
        .pixel => 512,
        .fill => 12_800,
        .sprites => 8_192,
        else => 57_600,
    };
}
fn sourceBytes(bytes: []u8) void {
    var prng = std.Random.DefaultPrng.init(0x0908070605040302);
    prng.random().bytes(bytes);
}
fn backendName(backend: ?dispatch.Backend) []const u8 {
    return if (backend) |b| @tagName(b) else "runtime";
}

fn runOp(op: Op, backend: ?dispatch.Backend, dst: []u8, src: []const u8, surface: *s.Surface, iteration: usize) void {
    const b = backend orelse dispatch.best();
    switch (op) {
        .clear => raster.fillRectWith(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(11, 37, @truncate(iteration), 255), b),
        .pixel => for (0..512) |i| raster.fillRectWith(surface, .{ .x = @intCast((i * 37 + iteration) % width), .y = @intCast((i * 73 + iteration) % height), .width = 1, .height = 1 }, .rgba(@truncate(i), 91, 17, 255), b),
        .fill => for (0..32) |i| raster.fillRectWith(surface, .{ .x = @intCast((i * 19) % 220), .y = @intCast((i * 31) % 220), .width = 20, .height = 20 }, .rgba(@truncate(i * 7), 23, 201, 255), b),
        .transfer_fill => @memset(dst, @truncate(iteration *% 17 +% 3)),
        .transfer_copy => std.mem.copyForwards(u8, dst, src),
        .blend => raster.blendRectWith(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(220, 31, 77, 128), b),
        .sprites => for (0..128) |i| raster.blendRectWith(surface, .{ .x = @intCast((i * 29 + iteration) % 232), .y = @intCast((i * 43) % 232), .width = 8, .height = 8 }, .rgba(@truncate(i * 3), 101, 233, 160), b),
        .frame => {
            raster.fillRectWith(surface, .{ .x = 0, .y = 0, .width = width, .height = height }, .rgba(8, 12, 20, 255), b);
            for (0..64) |i| raster.blendRectWith(surface, .{ .x = @intCast((i * 17) % 224), .y = @intCast((i * 41) % 224), .width = 16, .height = 16 }, .rgba(@truncate(i * 5), 140, 60, 180), b);
        },
    }
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
fn referenceOp(op: Op, dst: []u8, src: []const u8) void {
    const iteration = canonical_iteration;
    switch (op) {
        .clear => refRect(dst, 0, 0, width, height, .rgba(11, 37, @truncate(iteration), 255), false),
        .pixel => for (0..512) |i| refRect(dst, (i * 37 + iteration) % width, (i * 73 + iteration) % height, 1, 1, .rgba(@truncate(i), 91, 17, 255), false),
        .fill => for (0..32) |i| refRect(dst, (i * 19) % 220, (i * 31) % 220, 20, 20, .rgba(@truncate(i * 7), 23, 201, 255), false),
        .transfer_fill => @memset(dst, @truncate(iteration *% 17 +% 3)),
        .transfer_copy => @memcpy(dst, src),
        .blend => refRect(dst, 0, 0, width, height, .rgba(220, 31, 77, 128), true),
        .sprites => for (0..128) |i| refRect(dst, (i * 29 + iteration) % 232, (i * 43) % 232, 8, 8, .rgba(@truncate(i * 3), 101, 233, 160), true),
        .frame => {
            refRect(dst, 0, 0, width, height, .rgba(8, 12, 20, 255), false);
            for (0..64) |i| refRect(dst, (i * 17) % 224, (i * 41) % 224, 16, 16, .rgba(@truncate(i * 5), 140, 60, 180), true);
        },
    }
}

const oracle_checksums = [_]u64{ 0x89fcf336d86c4f25, 0x3d0737332ec9e1cc, 0xb5cb439ce748a598, 0x50dbc316a6090325, 0x4e61ac2d0cc0777b, 0xd5f99fe5b4e7eef8, 0x3717a00e187d9381, 0x2e480a89ab6181ef };
fn oracle(op: Op) u64 {
    return oracle_checksums[@intFromEnum(op)];
}
fn isRaster(op: Op) bool {
    return op != .transfer_fill and op != .transfer_copy;
}
fn expectedMetricCount() usize {
    var n: usize = all_ops.len + raster_ops.len;
    if (dispatch.available(.avx2)) n += raster_ops.len;
    if (dispatch.available(.avx512)) n += raster_ops.len;
    return n;
}
fn expectedAtFor(index: usize, has_avx2: bool, has_avx512: bool) MetricKey {
    var i = index;
    if (i < all_ops.len) return .{ .op = all_ops[i], .backend = "scalar" };
    i -= all_ops.len;
    if (has_avx2) {
        if (i < raster_ops.len) return .{ .op = raster_ops[i], .backend = "avx2" };
        i -= raster_ops.len;
    }
    if (has_avx512) {
        if (i < raster_ops.len) return .{ .op = raster_ops[i], .backend = "avx512" };
        i -= raster_ops.len;
    }
    return .{ .op = raster_ops[i], .backend = "runtime" };
}
fn expectedAt(index: usize) MetricKey {
    return expectedAtFor(index, dispatch.available(.avx2), dispatch.available(.avx512));
}
fn validFingerprint(f: Fingerprint) bool {
    return f.arch.len > 0 and f.os.len > 0 and f.cpu_model.len > 0 and f.selected_cpus.len > 0 and f.topology.len > 0 and f.compiler.len > 0 and f.build_mode.len > 0 and f.max_threads > 0 and f.max_threads <= 8;
}
fn applicable(op: Op, m: Metric) bool {
    const normal = op != .sprites and op != .frame;
    return (if (normal) m.mpix_s > 0 else m.mpix_s == 0) and m.effective_gib_s > 0 and (if (op == .sprites) m.draws_s > 0 else m.draws_s == 0) and (if (op == .frame) m.fps > 0 else m.fps == 0);
}

pub fn validate(report: Report) !void {
    if (report.schema_version != schema_version) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, report.workload_id, workload_id)) return error.WorkloadMismatch;
    if (report.sample_count < 2 or report.warmup_iterations == 0 or !validFingerprint(report.fingerprint)) return error.MalformedReport;
    if (!std.math.isFinite(report.rate_tolerance_fraction) or report.rate_tolerance_fraction < 0 or report.rate_tolerance_fraction >= 1 or !std.math.isFinite(report.latency_tolerance_fraction) or report.latency_tolerance_fraction < 0 or report.latency_tolerance_fraction > 2) return error.MalformedReport;
    if (report.metrics.len != expectedMetricCount()) return error.MetricSetMismatch;
    for (report.metrics, 0..) |m, index| {
        const expected = expectedAt(index);
        if (!std.mem.eql(u8, m.name, @tagName(expected.op)) or !std.mem.eql(u8, m.backend, expected.backend)) return error.MetricSetMismatch;
        if (m.iterations == 0 or m.checksum != oracle(expected.op) or !std.math.isFinite(m.mpix_s) or !std.math.isFinite(m.effective_gib_s) or !std.math.isFinite(m.draws_s) or !std.math.isFinite(m.fps) or m.mpix_s < 0 or m.effective_gib_s < 0 or m.draws_s < 0 or m.fps < 0 or !applicable(expected.op, m) or m.frame.p50_ns == 0 or m.frame.p50_ns > m.frame.p95_ns or m.frame.p95_ns > m.frame.p99_ns) return error.MalformedMetric;
    }
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
    if (regressed(now.mpix_s, old.mpix_s, rate_tol) or regressed(now.effective_gib_s, old.effective_gib_s, rate_tol) or regressed(now.draws_s, old.draws_s, rate_tol) or regressed(now.fps, old.fps, rate_tol)) return error.PerformanceRegression;
    if (latencyRegressed(now.frame.p50_ns, old.frame.p50_ns, latency_tol) or latencyRegressed(now.frame.p95_ns, old.frame.p95_ns, latency_tol) or latencyRegressed(now.frame.p99_ns, old.frame.p99_ns, latency_tol)) return error.LatencyRegression;
}
pub fn compare(current: Report, baseline: Report) !void {
    try validate(current);
    try validate(baseline);
    if (!compatible(current.fingerprint, baseline.fingerprint)) return error.IncompatibleFingerprint;
    for (current.metrics) |now| {
        var found: ?Metric = null;
        for (baseline.metrics) |old| if (std.mem.eql(u8, now.name, old.name) and std.mem.eql(u8, now.backend, old.backend)) {
            found = old;
        };
        try compareMetric(now, found orelse return error.MetricSetMismatch, baseline.rate_tolerance_fraction, baseline.latency_tolerance_fraction);
    }
}
pub fn guardInRun(report: Report) !void {
    try validate(report);
    for (raster_ops) |op| {
        const scalar = report.metrics[@intFromEnum(op)];
        for (report.metrics) |candidate| if (std.mem.eql(u8, candidate.name, @tagName(op)) and !std.mem.eql(u8, candidate.backend, "scalar")) {
            std.debug.assert(candidate.checksum == scalar.checksum and candidate.checksum == oracle(op));
            if (regressed(candidate.mpix_s, scalar.mpix_s, 0.75) or regressed(candidate.effective_gib_s, scalar.effective_gib_s, 0.75) or regressed(candidate.draws_s, scalar.draws_s, 0.75) or regressed(candidate.fps, scalar.fps, 0.75)) return error.RelativeRegression;
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
    const backends = [_]?dispatch.Backend{ .scalar, .avx2, .avx512, null };
    for (backends) |backend| {
        if (backend) |b| if (!dispatch.available(b) and b != .scalar) continue;
        for (all_ops) |op| {
            if (!isRaster(op) and backend != .scalar) continue;
            @memcpy(&dst, &src);
            runOp(op, backend, &dst, &src, &surface, canonical_iteration);
            @memcpy(&dst, &src);
            var durations: [15]u64 = undefined;
            for (0..samples) |sample| {
                const start = std.Io.Clock.boot.now(io);
                for (0..inner) |iteration| runOp(op, backend, &dst, &src, &surface, sample * inner + iteration);
                const elapsed = start.untilNow(io, .boot).toNanoseconds();
                durations[sample] = @intCast(@max(@divTrunc(elapsed, @as(i96, inner)), 1));
            }
            const pct = try summarize(durations[0..samples]);
            const seconds = @as(f64, @floatFromInt(pct.p50_ns)) / 1e9;
            @memcpy(&dst, &src);
            runOp(op, backend, &dst, &src, &surface, canonical_iteration);
            const output_checksum = checksum(&dst);
            const pixels = pixelCount(op);
            const bytes = @as(f64, @floatFromInt(try modeledBytes(@tagName(op))));
            metrics[used] = .{ .name = @tagName(op), .backend = backendName(backend), .iterations = samples * inner, .checksum = output_checksum, .mpix_s = if (op == .sprites or op == .frame) 0 else pixels / seconds / 1e6, .effective_gib_s = bytes / seconds / 1073741824.0, .draws_s = if (op == .sprites) 128 / seconds else 0, .fps = if (op == .frame) 1 / seconds else 0, .frame = pct };
            used += 1;
        }
    }
    return used;
}

fn fingerprint() Fingerprint {
    return .{ .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag), .cpu_model = "cpu", .selected_cpus = "2", .topology = "0:0@2", .compiler = builtin.zig_version_string, .build_mode = @tagName(builtin.mode), .max_threads = 1 };
}
fn reportFor(metrics: []const Metric) Report {
    return .{ .schema_version = schema_version, .workload_id = workload_id, .fingerprint = fingerprint(), .warmup_iterations = 1, .sample_count = 3, .metrics = metrics };
}

test "percentile index is overflow safe and nearest rank is exact" {
    try std.testing.expectEqual(@as(usize, 9), try percentileIndex(20, 50, 100));
    try std.testing.expectEqual(@as(usize, std.math.maxInt(usize) - 1), try percentileIndex(std.math.maxInt(usize), 100, 100));
    try std.testing.expectError(error.InvalidPercentile, percentileIndex(0, 50, 100));
    var v = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    const p = try summarize(&v);
    try std.testing.expectEqualDeep(Percentiles{ .p50_ns = 10, .p95_ns = 19, .p99_ns = 20 }, p);
}
test "modeled byte traffic has exact hand computed cases" {
    try std.testing.expectEqual(@as(u64, 230400), try modeledBytes("clear"));
    try std.testing.expectEqual(@as(u64, 460800), try modeledBytes("blend"));
    try std.testing.expectEqual(@as(u64, 65536), try modeledBytes("sprites"));
    try std.testing.expectEqual(@as(u64, 361472), try modeledBytes("frame"));
    try std.testing.expectError(error.UnknownOperation, modeledBytes("triangle"));
}
test "independent reference renderer has fixed checksums" {
    var src: [surface_bytes]u8 = undefined;
    var dst: [surface_bytes]u8 = undefined;
    sourceBytes(&src);
    for (all_ops) |op| {
        @memcpy(&dst, &src);
        referenceOp(op, &dst, &src);
        try std.testing.expectEqual(oracle(op), checksum(&dst));
    }
}
test "benchmark validates every available SIMD runtime and oracle" {
    var metrics: [32]Metric = undefined;
    const count = try benchmark(std.testing.io, &metrics, true);
    const r = reportFor(metrics[0..count]);
    try validate(r);
    try guardInRun(r);
}
test "canonical metric ordering independently covers optional SIMD sets" {
    try std.testing.expectEqualStrings("avx512", expectedAtFor(all_ops.len, false, true).backend);
    try std.testing.expectEqualStrings("avx512", expectedAtFor(all_ops.len + raster_ops.len, true, true).backend);
    try std.testing.expectEqualStrings("runtime", expectedAtFor(all_ops.len, false, false).backend);
}

test "in-run guard independently rejects a slow SIMD or runtime route" {
    var storage: [32]Metric = undefined;
    const r = try canonicalForTest(&storage);
    var index: usize = 0;
    while (index < r.metrics.len and !std.mem.eql(u8, r.metrics[index].backend, "runtime")) : (index += 1) {}
    try std.testing.expect(index < r.metrics.len);
    storage[index].mpix_s = 10;
    try std.testing.expectError(error.RelativeRegression, guardInRun(r));
}

test "full validation rejects noncanonical sets fields and callers cannot bypass it" {
    var storage: [32]Metric = undefined;
    const count = try benchmark(std.testing.io, &storage, true);
    var r = reportFor(storage[0..count]);
    try validate(r);
    r.metrics = storage[0 .. count - 1];
    try std.testing.expectError(error.MetricSetMismatch, validate(r));
    try std.testing.expectError(error.MetricSetMismatch, guardInRun(r));
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
    storage[1] = try metricForTest(.pixel, "scalar");
    storage[0].checksum +%= 1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].mpix_s = std.math.nan(f64);
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].effective_gib_s = -1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    storage[0].draws_s = 1;
    try std.testing.expectError(error.MalformedMetric, validate(r));
    storage[0] = saved0;
    r.schema_version +%= 1;
    try std.testing.expectError(error.UnsupportedSchema, guardInRun(r));
}

fn metricForTest(op: Op, backend: []const u8) !Metric {
    return .{ .name = @tagName(op), .backend = backend, .iterations = 3, .checksum = oracle(op), .mpix_s = if (op == .sprites or op == .frame) 0 else 100, .effective_gib_s = 100, .draws_s = if (op == .sprites) 100 else 0, .fps = if (op == .frame) 100 else 0, .frame = .{ .p50_ns = 100, .p95_ns = 100, .p99_ns = 100 } };
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
    const fields = [_][]const u8{ "mpix", "gib", "draws", "fps" };
    const indexes = [_]usize{ 0, 0, 6, 7 };
    for (fields, indexes) |field, index| {
        if (std.mem.eql(u8, field, "mpix")) now_storage[index].mpix_s = 50;
        if (std.mem.eql(u8, field, "gib")) now_storage[index].effective_gib_s = 50;
        if (std.mem.eql(u8, field, "draws")) now_storage[index].draws_s = 50;
        if (std.mem.eql(u8, field, "fps")) now_storage[index].fps = 50;
        try std.testing.expectError(error.PerformanceRegression, compare(current, baseline));
        now_storage[index] = old_storage[index];
    }
    now_storage[0].frame = .{ .p50_ns = 300, .p95_ns = 300, .p99_ns = 300 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0].frame = .{ .p50_ns = 100, .p95_ns = 300, .p99_ns = 300 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0].frame = .{ .p50_ns = 100, .p95_ns = 100, .p99_ns = 300 };
    try std.testing.expectError(error.LatencyRegression, compare(current, baseline));
    now_storage[0] = old_storage[0];
    current.fingerprint.cpu_model = "other";
    try std.testing.expectError(error.IncompatibleFingerprint, compare(current, baseline));
    current.fingerprint = baseline.fingerprint;
    baseline.rate_tolerance_fraction = std.math.inf(f64);
    try std.testing.expectError(error.MalformedReport, compare(current, baseline));
    try std.testing.expect(!latencyRegressed(std.math.maxInt(u64), std.math.maxInt(u64) - 1, 0.5));
}

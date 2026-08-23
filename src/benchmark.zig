const std = @import("std");
const builtin = @import("builtin");
const s = @import("surface.zig");
const raster = @import("raster/raster.zig");
const dispatch = @import("simd/dispatch.zig");

pub const schema_version: u32 = 1;
pub const workload_id = "zpu-2d-v1-240x240-seed-151521030";
pub const default_rate_tolerance_fraction = 0.20;
pub const default_p95_tolerance_fraction = 1.00;

pub const Percentiles = struct { p50_ns: u64, p95_ns: u64, p99_ns: u64 };
pub const Metric = struct {
    name: []const u8,
    backend: []const u8,
    iterations: u64,
    checksum: u64,
    mpix_s: f64,
    effective_gib_s: f64,
    draws_s: f64,
    fps: f64,
    frame: Percentiles,
};
pub const Fingerprint = struct {
    arch: []const u8,
    os: []const u8,
    cpu_model: []const u8,
    selected_cpus: []const u8,
    max_threads: u8,
};
pub const Report = struct {
    schema_version: u32,
    workload_id: []const u8,
    fingerprint: Fingerprint,
    warmup_iterations: u32,
    sample_count: u32,
    rate_tolerance_fraction: f64 = default_rate_tolerance_fraction,
    p95_tolerance_fraction: f64 = default_p95_tolerance_fraction,
    metrics: []const Metric,
};

pub fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.debug.assert(values.len > 0 and numerator <= denominator and denominator > 0);
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = (values.len * numerator + denominator - 1) / denominator;
    return values[@max(rank, 1) - 1];
}

pub fn summarize(values: []u64) Percentiles {
    var a: [64]u64 = undefined;
    std.debug.assert(values.len <= a.len);
    @memcpy(a[0..values.len], values);
    var b = a;
    var c = a;
    return .{ .p50_ns = percentile(a[0..values.len], 50, 100), .p95_ns = percentile(b[0..values.len], 95, 100), .p99_ns = percentile(c[0..values.len], 99, 100) };
}

pub fn checksum(bytes: []const u8) u64 {
    var hash: u64 = 14695981039346656037;
    for (bytes) |byte| {
        hash = (hash ^ byte) *% 1099511628211;
    }
    return hash;
}

pub fn compatible(a: Fingerprint, b: Fingerprint) bool {
    return std.mem.eql(u8, a.arch, b.arch) and std.mem.eql(u8, a.os, b.os) and std.mem.eql(u8, a.cpu_model, b.cpu_model) and std.mem.eql(u8, a.selected_cpus, b.selected_cpus) and a.max_threads == b.max_threads;
}

pub fn validate(report: Report) !void {
    if (report.schema_version != schema_version) return error.UnsupportedSchema;
    if (!std.mem.eql(u8, report.workload_id, workload_id)) return error.WorkloadMismatch;
    if (report.metrics.len == 0 or report.sample_count < 2 or report.warmup_iterations == 0) return error.MalformedBaseline;
    if (!std.math.isFinite(report.rate_tolerance_fraction) or report.rate_tolerance_fraction < 0 or report.rate_tolerance_fraction >= 1 or !std.math.isFinite(report.p95_tolerance_fraction) or report.p95_tolerance_fraction < 0 or report.p95_tolerance_fraction > 2) return error.MalformedBaseline;
    if (report.fingerprint.arch.len == 0 or report.fingerprint.os.len == 0 or report.fingerprint.cpu_model.len == 0 or report.fingerprint.selected_cpus.len == 0 or report.fingerprint.max_threads == 0 or report.fingerprint.max_threads > 8) return error.MalformedBaseline;
    for (report.metrics) |m| if (m.name.len == 0 or m.backend.len == 0 or m.iterations == 0 or m.checksum == 0 or !std.math.isFinite(m.mpix_s) or m.mpix_s < 0 or !std.math.isFinite(m.effective_gib_s) or m.effective_gib_s < 0 or !std.math.isFinite(m.draws_s) or m.draws_s < 0 or !std.math.isFinite(m.fps) or m.fps < 0 or m.frame.p50_ns > m.frame.p95_ns or m.frame.p95_ns > m.frame.p99_ns) return error.MalformedBaseline;
}

pub fn compare(current: Report, baseline: Report) !void {
    try validate(current);
    try validate(baseline);
    if (!compatible(current.fingerprint, baseline.fingerprint)) return error.IncompatibleFingerprint;
    if (current.metrics.len != baseline.metrics.len) return error.MalformedBaseline;
    for (current.metrics, baseline.metrics) |now, old| {
        if (!std.mem.eql(u8, now.name, old.name) or !std.mem.eql(u8, now.backend, old.backend) or now.checksum != old.checksum) return error.WorkloadMismatch;
        const old_rate = @max(@max(old.mpix_s, old.draws_s), old.fps);
        const new_rate = @max(@max(now.mpix_s, now.draws_s), now.fps);
        if (old_rate > 0 and new_rate < old_rate * (1.0 - baseline.rate_tolerance_fraction)) return error.PerformanceRegression;
        if (old.frame.p95_ns > 0 and @as(f64, @floatFromInt(now.frame.p95_ns)) > @as(f64, @floatFromInt(old.frame.p95_ns)) * (1.0 + baseline.p95_tolerance_fraction)) return error.PerformanceRegression;
    }
}

pub fn guardInRun(report: Report) !void {
    const required = [_][]const u8{ "clear", "pixel", "fill", "transfer_fill", "transfer_copy", "blend", "sprites", "frame" };
    for (required) |name| {
        var scalar: ?Metric = null;
        var runtime: ?Metric = null;
        for (report.metrics) |m| if (std.mem.eql(u8, m.name, name)) {
            if (std.mem.eql(u8, m.backend, "scalar")) scalar = m;
            if (std.mem.eql(u8, m.backend, "runtime")) runtime = m;
        };
        if (scalar == null) return error.MissingWorkload;
        if (!std.mem.startsWith(u8, name, "transfer_") and runtime == null) return error.MissingWorkload;
        if (runtime) |r| {
            const reference = scalar.?;
            if (r.checksum != reference.checksum) return error.ChecksumMismatch;
            const reference_rate = @max(@max(reference.mpix_s, reference.draws_s), reference.fps);
            const runtime_rate = @max(@max(r.mpix_s, r.draws_s), r.fps);
            if (reference_rate > 0 and runtime_rate < reference_rate * 0.25) return error.RelativeRegression;
        }
    }
}

const Op = enum { clear, pixel, fill, transfer_fill, transfer_copy, blend, sprites, frame };
fn backendName(backend: ?dispatch.Backend) []const u8 {
    return if (backend) |b| @tagName(b) else "runtime";
}

fn runOp(op: Op, backend: ?dispatch.Backend, dst: []u8, src: []const u8, surface: *s.Surface, iteration: usize) void {
    const b = backend orelse dispatch.best();
    switch (op) {
        .clear => raster.fillRectWith(surface, .{ .x = 0, .y = 0, .width = 240, .height = 240 }, .rgba(11, 37, @truncate(iteration), 255), b),
        .pixel => for (0..512) |i| raster.fillRectWith(surface, .{ .x = @intCast((i * 37 + iteration) % 240), .y = @intCast((i * 73 + iteration) % 240), .width = 1, .height = 1 }, .rgba(@truncate(i), 91, 17, 255), b),
        .fill => for (0..32) |i| raster.fillRectWith(surface, .{ .x = @intCast((i * 19) % 220), .y = @intCast((i * 31) % 220), .width = 20, .height = 20 }, .rgba(@truncate(i * 7), 23, 201, 255), b),
        .transfer_fill => @memset(dst, @truncate(iteration *% 17 +% 3)),
        .transfer_copy => std.mem.copyForwards(u8, dst, src),
        .blend => raster.blendRectWith(surface, .{ .x = 0, .y = 0, .width = 240, .height = 240 }, .rgba(220, 31, 77, 128), b),
        .sprites => for (0..128) |i| raster.blendRectWith(surface, .{ .x = @intCast((i * 29 + iteration) % 232), .y = @intCast((i * 43) % 232), .width = 8, .height = 8 }, .rgba(@truncate(i * 3), 101, 233, 160), b),
        .frame => {
            raster.fillRectWith(surface, .{ .x = 0, .y = 0, .width = 240, .height = 240 }, .rgba(8, 12, 20, 255), b);
            for (0..64) |i| raster.blendRectWith(surface, .{ .x = @intCast((i * 17) % 224), .y = @intCast((i * 41) % 224), .width = 16, .height = 16 }, .rgba(@truncate(i * 5), 140, 60, 180), b);
        },
    }
}

pub fn benchmark(io: std.Io, metrics: []Metric, smoke: bool) !usize {
    const samples: usize = if (smoke) 3 else 15;
    const inner: usize = if (smoke) 2 else 20;
    var dst: [240 * 240 * 4]u8 align(64) = undefined;
    var src: [240 * 240 * 4]u8 align(64) = undefined;
    var prng = std.Random.DefaultPrng.init(0x0908070605040302);
    prng.random().bytes(&src);
    @memcpy(&dst, &src);
    var surface = try s.Surface.init(&dst, 240, 240, 240 * 4, .rgba8_unorm);
    const ops = [_]Op{ .clear, .pixel, .fill, .transfer_fill, .transfer_copy, .blend, .sprites, .frame };
    const backends = [_]?dispatch.Backend{ .scalar, .avx2, .avx512, null };
    var used: usize = 0;
    for (backends) |backend| {
        if (backend) |b| if (!dispatch.available(b) and b != .scalar) continue;
        for (ops) |op| {
            if ((op == .transfer_fill or op == .transfer_copy) and backend != .scalar) continue;
            @memcpy(&dst, &src);
            runOp(op, backend, &dst, &src, &surface, 0);
            @memcpy(&dst, &src);
            var durations: [15]u64 = undefined;
            for (0..samples) |sample| {
                const start = std.Io.Clock.boot.now(io);
                for (0..inner) |i| runOp(op, backend, &dst, &src, &surface, i + sample * inner);
                const elapsed = start.untilNow(io, .boot).toNanoseconds();
                durations[sample] = @intCast(@max(@divTrunc(elapsed, @as(i96, inner)), 1));
            }
            const pct = summarize(durations[0..samples]);
            const seconds = @as(f64, @floatFromInt(pct.p50_ns)) / 1e9;
            const pixels: f64 = switch (op) {
                .pixel => 512,
                .fill => 12800,
                .sprites => 8192,
                else => 57600,
            };
            const bytes: f64 = switch (op) {
                .transfer_copy, .blend => pixels * 8,
                else => pixels * 4,
            };
            metrics[used] = .{ .name = @tagName(op), .backend = backendName(backend), .iterations = samples * inner, .checksum = checksum(&dst), .mpix_s = if (op == .sprites or op == .frame) 0 else pixels / seconds / 1e6, .effective_gib_s = bytes / seconds / 1073741824.0, .draws_s = if (op == .sprites) 128 / seconds else 0, .fps = if (op == .frame) 1 / seconds else 0, .frame = pct };
            used += 1;
        }
    }
    return used;
}

test "nearest-rank percentiles and checksum are deterministic" {
    var values = [_]u64{ 9, 1, 8, 2, 7, 3, 6, 4, 5, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 };
    const p = summarize(&values);
    try std.testing.expectEqual(@as(u64, 10), p.p50_ns);
    try std.testing.expectEqual(@as(u64, 19), p.p95_ns);
    try std.testing.expectEqual(@as(u64, 20), p.p99_ns);
    try std.testing.expectEqual(@as(u64, 0xe71fa2190541574b), checksum("abc"));
}

fn fixture(rate: f64, model: []const u8) Report {
    const metrics = &[_]Metric{.{ .name = "fill", .backend = "scalar", .iterations = 3, .checksum = 1, .mpix_s = rate, .effective_gib_s = 1, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 10, .p95_ns = 12, .p99_ns = 13 } }};
    return .{ .schema_version = 1, .workload_id = workload_id, .fingerprint = .{ .arch = "x86_64", .os = "linux", .cpu_model = model, .selected_cpus = "2", .max_threads = 1 }, .warmup_iterations = 1, .sample_count = 3, .metrics = metrics };
}
test "baseline tolerance and fingerprints" {
    var current = fixture(86, "cpu");
    var baseline = fixture(100, "cpu");
    var current_metric = [_]Metric{.{ .name = "fill", .backend = "scalar", .iterations = 3, .checksum = 1, .mpix_s = 86, .effective_gib_s = 1, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 10, .p95_ns = 12, .p99_ns = 13 } }};
    const baseline_metric = [_]Metric{.{ .name = "fill", .backend = "scalar", .iterations = 3, .checksum = 1, .mpix_s = 100, .effective_gib_s = 1, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 10, .p95_ns = 12, .p99_ns = 13 } }};
    current.metrics = &current_metric;
    baseline.metrics = &baseline_metric;
    try compare(current, baseline);
    current_metric[0].mpix_s = 10;
    try std.testing.expectError(error.PerformanceRegression, compare(current, baseline));
    current_metric[0].mpix_s = 100;
    current.fingerprint.cpu_model = "other";
    try std.testing.expectError(error.IncompatibleFingerprint, compare(current, baseline));
}
test "schema workload and malformed baseline rejection" {
    var r = fixture(1, "cpu");
    r.schema_version = 2;
    try std.testing.expectError(error.UnsupportedSchema, validate(r));
    r = fixture(1, "cpu");
    r.workload_id = "wrong";
    try std.testing.expectError(error.WorkloadMismatch, validate(r));
    r = fixture(1, "cpu");
    r.sample_count = 0;
    try std.testing.expectError(error.MalformedBaseline, validate(r));
    r = fixture(1, "cpu");
    r.fingerprint.max_threads = 9;
    try std.testing.expectError(error.MalformedBaseline, validate(r));
    r = fixture(1, "cpu");
    r.rate_tolerance_fraction = 1;
    try std.testing.expectError(error.MalformedBaseline, validate(r));
    var bad_metric = [_]Metric{.{ .name = "fill", .backend = "scalar", .iterations = 3, .checksum = 0, .mpix_s = 1, .effective_gib_s = 1, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 3, .p95_ns = 2, .p99_ns = 1 } }};
    r = fixture(1, "cpu");
    r.metrics = &bad_metric;
    try std.testing.expectError(error.MalformedBaseline, validate(r));
}

test "in-run guard checks identity checksum and relative dispatch" {
    var ms: [14]Metric = undefined;
    const names = [_][]const u8{ "clear", "pixel", "fill", "blend", "sprites", "frame" };
    var n: usize = 0;
    for (names) |name| for ([_][]const u8{ "scalar", "runtime" }) |backend| {
        ms[n] = .{ .name = name, .backend = backend, .iterations = 3, .checksum = 9, .mpix_s = 10, .effective_gib_s = 1, .draws_s = if (std.mem.eql(u8, name, "sprites")) 10 else 0, .fps = if (std.mem.eql(u8, name, "frame")) 10 else 0, .frame = .{ .p50_ns = 1, .p95_ns = 2, .p99_ns = 3 } };
        n += 1;
    };
    for ([_][]const u8{ "transfer_fill", "transfer_copy" }) |name| {
        ms[n] = .{ .name = name, .backend = "scalar", .iterations = 3, .checksum = 9, .mpix_s = 10, .effective_gib_s = 1, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 1, .p95_ns = 2, .p99_ns = 3 } };
        n += 1;
    }
    var r = fixture(1, "cpu");
    r.metrics = ms[0..n];
    try guardInRun(r);
    ms[1].checksum = 8;
    try std.testing.expectError(error.ChecksumMismatch, guardInRun(r));
    ms[1].checksum = 9;
    ms[1].mpix_s = 2;
    try std.testing.expectError(error.RelativeRegression, guardInRun(r));
    ms[1].mpix_s = 10;
    r.metrics = r.metrics[0 .. n - 1];
    try std.testing.expectError(error.MissingWorkload, guardInRun(r));
}

test "smoke benchmark executes every available workload" {
    var metrics: [32]Metric = undefined;
    const count = try benchmark(std.testing.io, &metrics, true);
    var report = fixture(1, "cpu");
    report.metrics = metrics[0..count];
    try validate(report);
    try guardInRun(report);
}

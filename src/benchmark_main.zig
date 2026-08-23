const std = @import("std");
const builtin = @import("builtin");
const bench = @import("benchmark.zig");

fn emitJson(allocator: std.mem.Allocator, report: bench.Report) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.write(report);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn parseBaseline(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(bench.Report) {
    return std.json.parseFromSlice(bench.Report, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var json_only = false;
    var smoke = false;
    var capture: ?[]const u8 = null;
    var compare_path: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) json_only = true else if (std.mem.eql(u8, args[i], "--smoke")) smoke = true else if (std.mem.eql(u8, args[i], "--capture") or std.mem.eql(u8, args[i], "--compare")) {
            const is_capture = std.mem.eql(u8, args[i], "--capture");
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (is_capture) capture = args[i] else compare_path = args[i];
        } else return error.UnknownArgument;
    }
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityFingerprint;
    const cpu_model = init.environ_map.get("ZPU_CPU_MODEL") orelse return error.MissingCpuFingerprint;
    const cap_text = init.environ_map.get("ZPU_MAX_THREADS") orelse return error.MissingThreadCap;
    const cap = try std.fmt.parseInt(u8, cap_text, 10);
    if (cap == 0 or cap > 8) return error.InvalidThreadCap;
    var metrics: [32]bench.Metric = undefined;
    const count = try bench.benchmark(init.io, &metrics, smoke);
    const report = bench.Report{ .schema_version = bench.schema_version, .workload_id = bench.workload_id, .fingerprint = .{ .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag), .cpu_model = cpu_model, .selected_cpus = selected, .max_threads = cap }, .warmup_iterations = 1, .sample_count = if (smoke) 3 else 15, .metrics = metrics[0..count] };
    try bench.validate(report);
    try bench.guardInRun(report);
    const encoded = try emitJson(allocator, report);
    if (capture) |path| try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = encoded });
    if (compare_path) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(16 * 1024 * 1024));
        var parsed = parseBaseline(allocator, bytes) catch return error.MalformedBaseline;
        defer parsed.deinit();
        try bench.compare(report, parsed.value);
    }
    var buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.stdout().writer(init.io, &buffer);
    const out = &stdout_file.interface;
    if (json_only) try out.writeAll(encoded) else {
        try out.print("ZPU 2D benchmark: {s}\n", .{bench.workload_id});
        for (report.metrics) |m| try out.print("{s: <8} {s: <7} {d: >9.2} MPix/s {d: >7.2} GiB/s {d: >10.0} draws/s {d: >8.1} FPS p50/p95/p99={d}/{d}/{d} ns checksum={x}\n", .{ m.name, m.backend, m.mpix_s, m.effective_gib_s, m.draws_s, m.fps, m.frame.p50_ns, m.frame.p95_ns, m.frame.p99_ns, m.checksum });
    }
    try out.flush();
}

test "JSON round trip and malformed input" {
    const r = bench.Report{ .schema_version = 1, .workload_id = bench.workload_id, .fingerprint = .{ .arch = "x86_64", .os = "linux", .cpu_model = "cpu", .selected_cpus = "2", .max_threads = 1 }, .warmup_iterations = 1, .sample_count = 3, .metrics = &[_]bench.Metric{.{ .name = "copy", .backend = "scalar", .iterations = 3, .checksum = 4, .mpix_s = 1, .effective_gib_s = 2, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 1, .p95_ns = 2, .p99_ns = 3 } }} };
    const bytes = try emitJson(std.testing.allocator, r);
    defer std.testing.allocator.free(bytes);
    var parsed = try parseBaseline(std.testing.allocator, bytes);
    defer parsed.deinit();
    try bench.validate(parsed.value);
    try std.testing.expectError(error.UnexpectedEndOfInput, parseBaseline(std.testing.allocator, "{"));
    try std.testing.expectError(error.UnknownField, parseBaseline(std.testing.allocator, "{\"schema_version\":1,\"bogus\":2}"));
}

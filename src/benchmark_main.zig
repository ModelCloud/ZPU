const std = @import("std");
const builtin = @import("builtin");
const bench = @import("benchmark.zig");

fn emitJson(allocator: std.mem.Allocator, report: bench.Report) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var json: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try json.write(report);
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn parseBaseline(allocator: std.mem.Allocator, bytes: []const u8) !std.json.Parsed(bench.Report) {
    return std.json.parseFromSlice(bench.Report, allocator, bytes, .{ .allocate = .alloc_always, .ignore_unknown_fields = false });
}

fn fieldValue(text: []const u8, prefix: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (std.mem.startsWith(u8, line, prefix)) {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    };
    return null;
}

fn expandCpuList(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var first = true;
    var groups = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\n"), ',');
    while (groups.next()) |group_raw| {
        const group = std.mem.trim(u8, group_raw, " \t");
        if (group.len == 0) return error.InvalidCpuList;
        if (std.mem.indexOfScalar(u8, group, '-')) |dash| {
            const start = try std.fmt.parseInt(u32, group[0..dash], 10);
            const end = try std.fmt.parseInt(u32, group[dash + 1 ..], 10);
            if (end < start or end - start > 4096) return error.InvalidCpuList;
            for (start..end + 1) |cpu| {
                if (!first) try out.writer.writeByte(',');
                try out.writer.print("{d}", .{cpu});
                first = false;
            }
        } else {
            const cpu = try std.fmt.parseInt(u32, group, 10);
            if (!first) try out.writer.writeByte(',');
            try out.writer.print("{d}", .{cpu});
            first = false;
        }
    }
    if (first) return error.InvalidCpuList;
    return out.toOwnedSlice();
}

fn cpuCount(expanded: []const u8) !u8 {
    if (expanded.len == 0) return error.InvalidCpuList;
    var count: usize = 1;
    for (expanded) |c| {
        if (c == ',') count += 1;
    }
    if (count > 8) return error.InvalidThreadCap;
    return @intCast(count);
}

fn readSpecial(io: std.Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = file.readStreaming(io, &.{&buffer}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (count == 0) break;
        if (out.written().len + count > limit) return error.StreamTooLong;
        try out.writer.writeAll(buffer[0..count]);
    }
    return out.toOwnedSlice();
}

fn trustedTopology(io: std.Io, allocator: std.mem.Allocator, selected: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var cpus = std.mem.splitScalar(u8, selected, ',');
    var first = true;
    while (cpus.next()) |cpu| {
        _ = try std.fmt.parseInt(u32, cpu, 10);
        const package_path = try std.fmt.allocPrint(allocator, "devices/system/cpu/cpu{s}/topology/physical_package_id", .{cpu});
        defer allocator.free(package_path);
        const core_path = try std.fmt.allocPrint(allocator, "devices/system/cpu/cpu{s}/topology/core_id", .{cpu});
        defer allocator.free(core_path);
        var sys = try std.Io.Dir.openDirAbsolute(io, "/sys", .{});
        defer sys.close(io);
        const package_bytes = try sys.readFileAlloc(io, package_path, allocator, .limited(64));
        defer allocator.free(package_bytes);
        const core_bytes = try sys.readFileAlloc(io, core_path, allocator, .limited(64));
        defer allocator.free(core_bytes);
        const package = std.mem.trim(u8, package_bytes, " \t\n");
        const core = std.mem.trim(u8, core_bytes, " \t\n");
        if (!first) try out.writer.writeByte(';');
        try out.writer.print("{s}:{s}@{s}", .{ package, core, cpu });
        first = false;
    }
    return out.toOwnedSlice();
}

fn verifyTrustedFingerprint(io: std.Io, allocator: std.mem.Allocator, selected: []const u8, model: []const u8, topology: []const u8) !u8 {
    const status = try readSpecial(io, allocator, "/proc/self/status", 1024 * 1024);
    defer allocator.free(status);
    const affinity_marker = "Cpus_allowed_list:";
    const affinity_start = std.mem.indexOf(u8, status, affinity_marker) orelse return error.MissingTrustedAffinity;
    const affinity_tail = status[affinity_start + affinity_marker.len ..];
    const affinity_end = std.mem.indexOfScalar(u8, affinity_tail, '\n') orelse affinity_tail.len;
    const actual_list = std.mem.trim(u8, affinity_tail[0..affinity_end], " \t");
    const actual = try expandCpuList(allocator, actual_list);
    defer allocator.free(actual);
    if (!std.mem.eql(u8, selected, actual)) return error.UntrustedAffinityFingerprint;
    const cpuinfo = try readSpecial(io, allocator, "/proc/cpuinfo", 4 * 1024 * 1024);
    defer allocator.free(cpuinfo);
    const actual_model = fieldValue(cpuinfo, "model name") orelse fieldValue(cpuinfo, "Hardware") orelse return error.MissingTrustedCpuModel;
    if (!std.mem.eql(u8, model, actual_model)) return error.UntrustedCpuFingerprint;
    const actual_topology = try trustedTopology(io, allocator, selected);
    defer allocator.free(actual_topology);
    if (!std.mem.eql(u8, topology, actual_topology)) return error.UntrustedTopologyFingerprint;
    return cpuCount(actual);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var json_only = false;
    var smoke = false;
    var capture: ?[]const u8 = null;
    var compare_path: ?[]const u8 = null;
    var source_commit: []const u8 = "unbound";
    var utc: []const u8 = "unbound";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--json")) json_only = true else if (std.mem.eql(u8, args[i], "--smoke")) smoke = true else if (std.mem.eql(u8, args[i], "--capture") or std.mem.eql(u8, args[i], "--compare") or std.mem.eql(u8, args[i], "--source-commit") or std.mem.eql(u8, args[i], "--utc")) {
            const is_capture = std.mem.eql(u8, args[i], "--capture");
            const is_compare = std.mem.eql(u8, args[i], "--compare");
            const is_commit = std.mem.eql(u8, args[i], "--source-commit");
            i += 1;
            if (i >= args.len) return error.MissingArgument;
            if (is_capture) capture = args[i] else if (is_compare) compare_path = args[i] else if (is_commit) source_commit = args[i] else utc = args[i];
        } else return error.UnknownArgument;
    }
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityFingerprint;
    const cpu_model = init.environ_map.get("ZPU_CPU_MODEL") orelse return error.MissingCpuFingerprint;
    const topology = init.environ_map.get("ZPU_TOPOLOGY") orelse return error.MissingTopologyFingerprint;
    const cap_text = init.environ_map.get("ZPU_MAX_THREADS") orelse return error.MissingThreadCap;
    const requested_cap = try std.fmt.parseInt(u8, cap_text, 10);
    if (requested_cap == 0 or requested_cap > 8) return error.InvalidThreadCap;
    const cap = try verifyTrustedFingerprint(init.io, allocator, selected, cpu_model, topology);
    if (requested_cap != cap) return error.ThreadCapAffinityMismatch;
    var metrics: [32]bench.Metric = undefined;
    const count = try bench.benchmark(init.io, &metrics, smoke);
    const pipeline_metric = try bench.benchmarkPipeline(init.io, smoke);
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const report = bench.Report{ .schema_version = bench.schema_version, .workload_id = bench.workload_id, .source_commit = source_commit, .utc = utc, .fingerprint = .{ .arch = @tagName(builtin.cpu.arch), .os = @tagName(builtin.os.tag), .cpu_model = cpu_model, .selected_cpus = selected, .topology = topology, .compiler = builtin.zig_version_string, .build_mode = @tagName(builtin.mode), .max_threads = cap, .limited_gate = "physical-core-v1" }, .warmup_iterations = 1, .sample_count = if (smoke) 3 else 15, .pipeline = pipeline_metric, .metrics = metrics[0..count] };
    try bench.validate(report);
    try bench.guardInRun(report, !smoke);
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
        try out.print("pipeline key={d} ns cache-hit={d} ns hits/misses={d}/{d} hit-rate={d:.6}\n", .{ report.pipeline.key_construction_ns, report.pipeline.cache_lookup_ns, report.pipeline.cache_hits, report.pipeline.cache_misses, report.pipeline.cache_hit_rate });
        for (report.metrics) |m| try out.print("{s: <26} {s: <15} {d: >9.2} MPix/s {d: >12.2} bytes/s {d: >7.2} modeled-GiB/s {d: >10.0} draws/s {d: >8.1} FPS p50/p95/p99/max/CV={d}/{d}/{d}/{d}/{d:.6} checksum={s}\n", .{ m.name, m.backend, m.mpix_s, m.bytes_s, m.effective_gib_s, m.draws_s, m.fps, m.frame.p50_ns, m.frame.p95_ns, m.frame.p99_ns, m.frame.max_ns, m.frame.cv, m.checksum_hex });
    }
    try out.flush();
}

test "JSON round trip and malformed input" {
    const r = bench.Report{ .schema_version = bench.schema_version, .workload_id = bench.workload_id, .source_commit = "unbound", .utc = "unbound", .fingerprint = .{ .arch = "x86_64", .os = "linux", .cpu_model = "cpu", .selected_cpus = "2", .topology = "0:0@2", .compiler = builtin.zig_version_string, .build_mode = @tagName(builtin.mode), .max_threads = 1, .limited_gate = "physical-core-v1" }, .warmup_iterations = 1, .sample_count = 3, .pipeline = .{ .iterations = 3, .key_construction_ns = 1, .cache_lookup_ns = 1, .cache_hits = 3, .cache_misses = 1, .cache_hit_rate = 0.75 }, .metrics = &[_]bench.Metric{.{ .name = "copy", .backend = "scalar", .iterations = 3, .checksum = 4, .checksum_hex = "0000000000000004", .mpix_s = 1, .bytes_s = 2147483648, .effective_gib_s = 2, .draws_s = 0, .fps = 0, .frame = .{ .p50_ns = 1, .p95_ns = 2, .p99_ns = 3, .max_ns = 3, .cv = 0.5 } }} };
    const bytes = try emitJson(std.testing.allocator, r);
    defer std.testing.allocator.free(bytes);
    var parsed = try parseBaseline(std.testing.allocator, bytes);
    defer parsed.deinit();
    try std.testing.expectError(error.UnexpectedEndOfInput, parseBaseline(std.testing.allocator, "{"));
    try std.testing.expectError(error.UnknownField, parseBaseline(std.testing.allocator, "{\"schema_version\":1,\"bogus\":2}"));
}

test "CPU list parsing handles cgroup ranges lists and malformed forms" {
    try std.testing.expect(fieldValue("Name:\tzpu\n", "Missing") == null);
    const a = try expandCpuList(std.testing.allocator, "2-4,8,10-11\n");
    defer std.testing.allocator.free(a);
    try std.testing.expectEqualStrings("2,3,4,8,10,11", a);
    try std.testing.expectError(error.InvalidCpuList, expandCpuList(std.testing.allocator, "4-2"));
    try std.testing.expectError(error.InvalidCpuList, expandCpuList(std.testing.allocator, ""));
}

test "forged environment fingerprint cannot pass trusted host verification" {
    const status = try readSpecial(std.testing.io, std.testing.allocator, "/proc/self/status", 1024 * 1024);
    defer std.testing.allocator.free(status);
    const marker = "Cpus_allowed_list:";
    const start = std.mem.indexOf(u8, status, marker) orelse return error.MissingTrustedAffinity;
    const tail = status[start + marker.len ..];
    const end = std.mem.indexOfScalar(u8, tail, '\n') orelse tail.len;
    const selected = try expandCpuList(std.testing.allocator, std.mem.trim(u8, tail[0..end], " \t"));
    defer std.testing.allocator.free(selected);
    const info = try readSpecial(std.testing.io, std.testing.allocator, "/proc/cpuinfo", 4 * 1024 * 1024);
    defer std.testing.allocator.free(info);
    const real_model = fieldValue(info, "model name") orelse fieldValue(info, "Hardware") orelse return error.MissingTrustedCpuModel;
    const real_topology = try trustedTopology(std.testing.io, std.testing.allocator, selected);
    defer std.testing.allocator.free(real_topology);
    try std.testing.expectError(error.UntrustedCpuFingerprint, verifyTrustedFingerprint(std.testing.io, std.testing.allocator, selected, "forged-model", real_topology));
    try std.testing.expectError(error.UntrustedTopologyFingerprint, verifyTrustedFingerprint(std.testing.io, std.testing.allocator, selected, real_model, "forged-topology"));
}

const std = @import("std");

const Summary = struct {
    files: []const File,
    covered_lines: u64,
    total_lines: u64,

    const File = struct {
        file: []const u8,
        covered_lines: std.json.Value,
        total_lines: std.json.Value,
    };
};

fn integer(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |number| std.math.cast(u64, number) orelse error.InvalidCoverage,
        .string => |text| try std.fmt.parseInt(u64, text, 10),
        else => error.InvalidCoverage,
    };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 2) return error.ExpectedCoverageDirectory;

    var directory = try std.Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer directory.close(io);
    var walker = try directory.walk(allocator);
    defer walker.deinit();

    var summary_path: ?[]const u8 = null;
    var records_path: ?[]const u8 = null;
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file and std.mem.eql(u8, std.fs.path.basename(entry.path), "coverage.json")) {
            if (summary_path != null) return error.MultipleCoverageSummaries;
            summary_path = try allocator.dupe(u8, entry.path);
        } else if (entry.kind == .file and std.mem.eql(u8, std.fs.path.basename(entry.path), "codecov.json")) {
            if (records_path != null) return error.MultipleCoverageRecords;
            records_path = try allocator.dupe(u8, entry.path);
        }
    }
    const path = summary_path orelse return error.MissingCoverageSummary;
    const text = try directory.readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(Summary, allocator, text, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    const summary = parsed.value;

    if (summary.files.len != 1) return error.UnexpectedCoverageScope;
    const file = summary.files[0];
    if (!std.mem.endsWith(u8, file.file, "/src/vulkan/driver.zig")) return error.UnexpectedCoverageScope;
    const file_covered = try integer(file.covered_lines);
    const file_total = try integer(file.total_lines);
    if (file_total == 0 or summary.total_lines != file_total or summary.covered_lines != file_covered) return error.InvalidCoverage;
    if (file_covered != file_total) {
        std.debug.print("ICD coverage FAILED: {d}/{d} executable lines ({d} uncovered)\n", .{ file_covered, file_total, file_total - file_covered });
        return error.CoverageBelow100Percent;
    }

    const records_text = try directory.readFileAlloc(io, records_path orelse return error.MissingCoverageRecords, allocator, .limited(4 * 1024 * 1024));
    const records_parsed = try std.json.parseFromSlice(std.json.Value, allocator, records_text, .{});
    defer records_parsed.deinit();
    const coverage = records_parsed.value.object.get("coverage") orelse return error.InvalidCoverageRecords;
    if (coverage != .object or coverage.object.count() != 1) return error.UnexpectedCoverageScope;
    const line_map = coverage.object.get(file.file) orelse return error.CoverageIdentityMismatch;
    if (line_map != .object or line_map.object.count() != file_total) return error.InvalidCoverageRecords;
    var lines = line_map.object.iterator();
    while (lines.next()) |entry| {
        const line_number = try std.fmt.parseInt(u64, entry.key_ptr.*, 10);
        if (line_number == 0 or entry.value_ptr.* != .string) return error.InvalidCoverageRecords;
        var parts = std.mem.splitScalar(u8, entry.value_ptr.string, '/');
        const executed = try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidCoverageRecords, 10);
        const instrumented = try std.fmt.parseInt(u64, parts.next() orelse return error.InvalidCoverageRecords, 10);
        if (parts.next() != null or executed == 0 or instrumented == 0 or executed > instrumented) return error.InvalidCoverageRecords;
    }
    std.debug.print("ICD coverage PASS: {d}/{d} executable lines (100.00%) in {s}\n", .{ file_covered, file_total, file.file });
}

const std = @import("std");
const exec = @import("render_ir_exec.zig");
const ir = @import("vulkan/render_ir.zig");

const samples = 1000;
fn percentile(values: []u64, n: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    return values[((values.len * n + 99) / 100) - 1];
}
fn report(name: []const u8, original: [samples]u64) void {
    var values = original;
    var a = original;
    var b = original;
    var total: u128 = 0;
    var max: u64 = 0;
    for (values) |v| {
        total += v;
        max = @max(max, v);
    }
    const mean = @as(f64, @floatFromInt(total)) / samples;
    var variance: f64 = 0;
    for (values) |v| {
        const d = @as(f64, @floatFromInt(v)) - mean;
        variance += d * d;
    }
    std.debug.print("{s}: p50={d}ns p95={d}ns p99={d}ns max={d}ns cv={d:.6}\n", .{ name, percentile(&values, 50), percentile(&a, 95), percentile(&b, 99), max, @sqrt(variance / samples) / mean });
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const allocator = std.heap.page_allocator;
    var literal: [4]u8 = undefined;
    std.mem.writeInt(u32, &literal, @bitCast(@as(f32, 1)), .little);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{ .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &literal }, .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0 }, .literal = &.{} } };
    const bytes = try ir.serialize(allocator, .fragment, "main", &interfaces, &instructions);
    defer allocator.free(bytes);
    var program = ir.Program{ .stage = .fragment, .entry_name = @constCast("main"), .interfaces = &interfaces, .instructions = &instructions, .bytes = bytes, .identity = ir.identify(bytes) };
    var cold: [samples]u64 = undefined;
    var warm: [samples]u64 = undefined;
    var output: [4]u8 = undefined;
    for (0..samples) |i| {
        const start = std.Io.Clock.boot.now(init.io);
        var executor = try exec.Executor.init(allocator, &program);
        cold[i] = @intCast(@max(start.untilNow(init.io, .boot).toNanoseconds(), 1));
        executor.deinit();
    }
    var executor = try exec.Executor.init(allocator, &program);
    defer executor.deinit();
    for (0..samples) |i| {
        const start = std.Io.Clock.boot.now(init.io);
        try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
        warm[i] = @intCast(@max(start.untilNow(init.io, .boot).toNanoseconds(), 1));
    }
    report("scalar cold/setup", cold);
    report("scalar warm execution", warm);
    std.debug.print("allocations: setup_calls=10 warm_per_invocation=0 samples={d}\n", .{samples});
}

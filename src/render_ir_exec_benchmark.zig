const std = @import("std");
const exec = @import("vulkan/render_ir_exec.zig");
const ir = @import("vulkan/render_ir.zig");
extern fn sched_getaffinity(pid: c_int, size: usize, mask: *anyopaque) c_int;

const samples = 10_000;
const warmups = 2_000;
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

fn benchmarkGuard(before: usize, after: usize, checksum: u64) !usize {
    if (after < before) return error.InvalidAllocationCounter;
    const observed = after - before;
    if (observed != 0) return error.WarmAllocation;
    if (checksum == 0) return error.UnobservableExecution;
    return observed;
}

noinline fn executeObserved(executor: *exec.Executor, output: *[4]u8, checksum: *u64) !void {
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = output }});
    var next = checksum.*;
    for (output.*) |byte| next = (next ^ byte) *% 1099511628211;
    checksum.* = next;
    std.mem.doNotOptimizeAway(output);
    std.mem.doNotOptimizeAway(checksum);
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityGate;
    var actual: [128]u8 = .{0} ** 128;
    if (sched_getaffinity(0, actual.len, &actual) != 0) return error.AffinityQueryFailed;
    var expected: [128]u8 = .{0} ** 128;
    var parts = std.mem.splitScalar(u8, selected, ',');
    var count: usize = 0;
    while (parts.next()) |part| {
        const cpu = try std.fmt.parseInt(usize, part, 10);
        if (cpu >= expected.len * 8) return error.InvalidAffinity;
        expected[cpu / 8] |= @as(u8, 1) << @intCast(cpu % 8);
        count += 1;
    }
    if (count == 0 or !std.mem.eql(u8, &actual, &expected)) return error.AffinityMismatch;
    const allocator = std.heap.page_allocator;
    var literal: [4]u8 = undefined;
    std.mem.writeInt(u32, &literal, @bitCast(@as(f32, 1)), .little);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{ .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &literal }, .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0 }, .literal = &.{} } };
    const bytes = try ir.serialize(allocator, .fragment, "main", &interfaces, &instructions);
    defer allocator.free(bytes);
    var program = ir.Program{ .stage = .fragment, .entry_name = @constCast("main"), .interfaces = &interfaces, .instructions = &instructions, .bytes = bytes, .identity = ir.identify(bytes) };
    var setup: [samples]u64 = undefined;
    var teardown: [samples]u64 = undefined;
    var warm: [samples]u64 = undefined;
    var output: [4]u8 = undefined;
    var allocation_probe = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    var counted = try exec.Executor.init(allocation_probe.allocator(), &program);
    counted.deinit();
    const setup_allocations = allocation_probe.allocations;
    for (0..samples) |i| {
        const start = std.Io.Clock.boot.now(init.io);
        var executor = try exec.Executor.init(allocator, &program);
        setup[i] = @intCast(@max(start.untilNow(init.io, .boot).toNanoseconds(), 1));
        const deinit_start = std.Io.Clock.boot.now(init.io);
        executor.deinit();
        teardown[i] = @intCast(@max(deinit_start.untilNow(init.io, .boot).toNanoseconds(), 1));
    }
    var warm_counter = std.testing.FailingAllocator.init(allocator, .{ .fail_index = std.math.maxInt(usize) });
    var executor = try exec.Executor.init(warm_counter.allocator(), &program);
    defer executor.deinit();
    for (0..warmups) |_| {
        var ignored: u64 = 1;
        try executeObserved(&executor, &output, &ignored);
    }
    const warm_allocations_before = warm_counter.allocations;
    var checksum: u64 = 14695981039346656037;
    for (0..samples) |i| {
        const start = std.Io.Clock.boot.now(init.io);
        try executeObserved(&executor, &output, &checksum);
        warm[i] = @intCast(@max(start.untilNow(init.io, .boot).toNanoseconds(), 1));
    }
    const observed_warm_allocations = try benchmarkGuard(warm_allocations_before, warm_counter.allocations, checksum);
    report("scalar setup", setup);
    report("scalar warm execution", warm);
    report("scalar deinit", teardown);
    std.debug.print("allocations: measured_setup_calls={d} observed_warm_loop_calls={d} samples={d} warmups={d} checksum={x}\n", .{ setup_allocations, observed_warm_allocations, samples, warmups, checksum });
    std.debug.print("timer note: sub-microsecond execution tails include clock quantization, interrupts, and scheduler outliers; this is kernel latency, not frame stability\n", .{});
}

test "benchmark guard rejects allocations counter corruption and unobservable work" {
    try std.testing.expectEqual(@as(usize, 0), try benchmarkGuard(7, 7, 1));
    try std.testing.expectError(error.WarmAllocation, benchmarkGuard(7, 8, 1));
    try std.testing.expectError(error.InvalidAllocationCounter, benchmarkGuard(8, 7, 1));
    try std.testing.expectError(error.UnobservableExecution, benchmarkGuard(7, 7, 0));
}

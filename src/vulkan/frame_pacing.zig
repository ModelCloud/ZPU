const std = @import("std");

pub const ns_per_second: u64 = 1_000_000_000;
pub const default_hz: u64 = 120;

/// Phase-locked rational refresh clock. Late callers skip elapsed clock slots,
/// never FIFO work, preventing catch-up bursts without rounded-period drift.
pub const Rate = struct {
    numerator: u64,
    denominator: u64,

    pub fn init(numerator: u64, denominator: u64) ?Rate {
        if (numerator == 0 or denominator == 0) return null;
        const divisor = std.math.gcd(numerator, denominator);
        return .{ .numerator = numerator / divisor, .denominator = denominator / divisor };
    }

    pub fn hz120() Rate {
        return .{ .numerator = default_hz, .denominator = 1 };
    }
};

pub const Clock = struct {
    epoch_ns: u64,
    tick: u64 = 1,
    rate: Rate,

    pub fn init(now_ns: u64, rate: Rate) Clock {
        return .{ .epoch_ns = now_ns, .rate = rate };
    }

    pub fn init120(now_ns: u64) Clock {
        return init(now_ns, Rate.hz120());
    }

    pub fn deadline(self: Clock) u64 {
        const ticks_ns = std.math.mul(u128, self.tick, ns_per_second) catch return std.math.maxInt(u64);
        const scaled = std.math.mul(u128, ticks_ns, self.rate.denominator) catch return std.math.maxInt(u64);
        const offset = scaled / self.rate.numerator;
        return std.math.cast(u64, @as(u128, self.epoch_ns) + offset) orelse std.math.maxInt(u64);
    }

    pub fn advance(self: *Clock, now_ns: u64) void {
        if (self.tick != std.math.maxInt(u64)) self.tick += 1;
        if (now_ns <= self.epoch_ns) return;
        const elapsed: u128 = now_ns - self.epoch_ns;
        const first_future = (elapsed * self.rate.numerator) / (@as(u128, ns_per_second) * self.rate.denominator) + 1;
        self.tick = @max(self.tick, std.math.cast(u64, first_future) orelse std.math.maxInt(u64));
    }
};

pub fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) unreachable;
    return @as(u64, @intCast(ts.sec)) * ns_per_second + @as(u64, @intCast(ts.nsec));
}

pub fn sleepUntil(deadline_ns: u64) void {
    const ts = std.c.timespec{
        .sec = @intCast(deadline_ns / ns_per_second),
        .nsec = @intCast(deadline_ns % ns_per_second),
    };
    while (true) {
        const rc = std.c.clock_nanosleep(.MONOTONIC, .{ .ABSTIME = true }, &ts, null);
        if (rc == 0) return;
        if (rc != @intFromEnum(std.c.E.INTR)) return;
    }
}

/// Absolute sleep remains the baseline; the final bounded interval is spun on
/// an isolated driver CPU to remove ordinary ~50 us scheduler wake variance.
/// The bound is deliberately tiny relative to an 8.333 ms slot.
pub fn sleepUntilPrecise(deadline_ns: u64, spin_ns: u64) void {
    const bounded_spin = @min(spin_ns, 100_000);
    if (deadline_ns > bounded_spin) {
        const sleep_deadline = deadline_ns - bounded_spin;
        if (monotonicNs() < sleep_deadline) sleepUntil(sleep_deadline);
    }
    while (monotonicNs() < deadline_ns) std.atomic.spinLoopHint();
}

test "120 Hz rational deadlines are phase exact" {
    var clock = Clock.init120(10_000);
    try std.testing.expectEqual(@as(u64, 8_343_333), clock.deadline());
    var index: usize = 0;
    while (index < 120) : (index += 1) clock.advance(clock.deadline());
    try std.testing.expectEqual(@as(u64, 1_008_343_333), clock.deadline());
}

test "lateness preserves phase and prevents catch-up bursts" {
    var clock = Clock.init120(0);
    clock.advance(30_000_000);
    try std.testing.expectEqual(@as(u64, 33_333_333), clock.deadline());
    clock.advance(clock.deadline());
    try std.testing.expectEqual(@as(u64, 41_666_666), clock.deadline());
}

test "clock arithmetic saturates instead of wrapping" {
    var clock = Clock.init(std.math.maxInt(u64) - 10, Rate.init(1, std.math.maxInt(u64)).?);
    clock.tick = std.math.maxInt(u64);
    try std.testing.expectEqual(std.math.maxInt(u64), clock.deadline());
    clock.advance(std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), clock.tick);
}

test "swapchain clocks have independent phases and rates" {
    const a = Clock.init120(100);
    const b = Clock.init(1_000, Rate.init(240, 1).?);
    try std.testing.expectEqual(@as(u64, 8_333_433), a.deadline());
    try std.testing.expectEqual(@as(u64, 4_167_666), b.deadline());
}

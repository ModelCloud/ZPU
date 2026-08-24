const std = @import("std");

pub const hz: u64 = 60;
pub const ns_per_second: u64 = 1_000_000_000;

/// Phase-locked rational 60 Hz clock. `next` is always strictly after `now`
/// after the first deadline has been consumed. Late callers skip elapsed clock
/// slots, never FIFO work, which prevents catch-up bursts without accumulating
/// drift from rounded 16,666,667 ns sleeps.
pub const Clock = struct {
    epoch_ns: u64,
    tick: u64 = 0,

    pub fn init(now_ns: u64) Clock {
        return .{ .epoch_ns = now_ns };
    }

    pub fn deadline(self: Clock) u64 {
        return self.epoch_ns + @divFloor(self.tick * ns_per_second, hz);
    }

    pub fn advance(self: *Clock, now_ns: u64) void {
        self.tick += 1;
        if (now_ns < self.epoch_ns) return;
        const elapsed = now_ns - self.epoch_ns;
        const first_future = @divFloor(elapsed * hz, ns_per_second) + 1;
        self.tick = @max(self.tick, first_future);
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

test "rational deadlines do not drift" {
    var clock = Clock.init(10_000);
    try std.testing.expectEqual(@as(u64, 10_000), clock.deadline());
    clock.advance(10_000);
    try std.testing.expectEqual(@as(u64, 16_676_666), clock.deadline());
    var index: usize = 1;
    while (index < 60) : (index += 1) clock.advance(clock.deadline());
    try std.testing.expectEqual(@as(u64, 1_000_010_000), clock.deadline());
}

test "lateness preserves phase and prevents catch-up bursts" {
    var clock = Clock.init(0);
    clock.advance(0);
    try std.testing.expectEqual(@as(u64, 16_666_666), clock.deadline());
    clock.advance(50_000_000);
    try std.testing.expectEqual(@as(u64, 66_666_666), clock.deadline());
    clock.advance(66_666_666);
    try std.testing.expectEqual(@as(u64, 83_333_333), clock.deadline());
}

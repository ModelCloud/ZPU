const std = @import("std");
const frame_pacing = @import("frame_pacing.zig");
const xcb_present = @import("xcb_present.zig");

pub const Work = struct {
    transport: *xcb_present.Transport,
    cadence: *?frame_pacing.Clock,
    pixels: []const u8,
    context: *anyopaque,
    image_index: u32,
    release: *const fn (*anyopaque, u32) void,
    enqueued_ns: u64 = 0,
};

const capacity = 24;
var entries: [capacity]Work = undefined;
var head: usize = 0;
var count: usize = 0;
var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var started = false;

fn run() void {
    while (true) {
        _ = std.c.pthread_mutex_lock(&mutex);
        while (count == 0) _ = std.c.pthread_cond_wait(&condition, &mutex);
        const work = entries[head];
        head = (head + 1) % capacity;
        count -= 1;
        _ = std.c.pthread_mutex_unlock(&mutex);

        const before = frame_pacing.monotonicNs();
        work.transport.last.queue_wait_ns = before - work.enqueued_ns;
        if (work.cadence.* == null) work.cadence.* = frame_pacing.Clock.init120(before);
        const deadline = work.cadence.*.?.deadline();
        if (deadline > before) frame_pacing.sleepUntil(deadline);
        const woke = frame_pacing.monotonicNs();
        work.transport.last.wake_error_ns = if (woke >= deadline) @intCast(woke - deadline) else -@as(i64, @intCast(deadline - woke));
        _ = xcb_present.present(work.transport, work.pixels);
        const finished = frame_pacing.monotonicNs();
        work.transport.last.frame_total_ns = finished - work.enqueued_ns;
        work.cadence.*.?.advance(finished);
        work.release(work.context, work.image_index);
    }
}

pub fn ensureStarted() bool {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (started) return true;
    const worker = std.Thread.spawn(.{}, run, .{}) catch return false;
    worker.detach();
    started = true;
    return true;
}

pub fn enqueue(input: Work) bool {
    var work = input;
    work.enqueued_ns = frame_pacing.monotonicNs();
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (count == capacity) return false;
    entries[(head + count) % capacity] = work;
    count += 1;
    _ = std.c.pthread_cond_signal(&condition);
    return true;
}

test "bounded FIFO rejects overflow without corrupting queued entries" {
    const saved_count = count;
    count = capacity;
    defer count = saved_count;
    var transport: xcb_present.Transport = undefined;
    var cadence: ?frame_pacing.Clock = null;
    try std.testing.expect(!enqueue(.{ .transport = &transport, .cadence = &cadence, .pixels = "", .context = @ptrFromInt(8), .image_index = 0, .release = struct { fn f(_: *anyopaque, _: u32) void {} }.f }));
}

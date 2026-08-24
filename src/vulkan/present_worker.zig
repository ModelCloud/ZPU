const std = @import("std");
const frame_pacing = @import("frame_pacing.zig");
const xcb_present = @import("xcb_present.zig");

pub const Work = struct {
    transport: *xcb_present.Transport,
    pixels: []const u8,
    context: *anyopaque,
    image_index: u32,
    release: *const fn (*anyopaque, u32) void,
};

const capacity = 24;
var entries: [capacity]Work = undefined;
var head: usize = 0;
var count: usize = 0;
var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var started = false;

fn run() void {
    var cadence: ?frame_pacing.Clock = null;
    while (true) {
        _ = std.c.pthread_mutex_lock(&mutex);
        while (count == 0) _ = std.c.pthread_cond_wait(&condition, &mutex);
        const work = entries[head];
        head = (head + 1) % capacity;
        count -= 1;
        _ = std.c.pthread_mutex_unlock(&mutex);

        const before = frame_pacing.monotonicNs();
        if (cadence == null) {
            cadence = frame_pacing.Clock.init(before);
            cadence.?.advance(before);
        }
        const deadline = cadence.?.deadline();
        if (deadline > before) frame_pacing.sleepUntil(deadline);
        _ = xcb_present.present(work.transport, work.pixels);
        cadence.?.advance(frame_pacing.monotonicNs());
        work.release(work.context, work.image_index);
    }
}

pub fn ensureStarted() bool {
    if (started) return true;
    const worker = std.Thread.spawn(.{}, run, .{}) catch return false;
    worker.detach();
    started = true;
    return true;
}

pub fn enqueue(work: Work) bool {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (count == capacity) return false;
    entries[(head + count) % capacity] = work;
    count += 1;
    _ = std.c.pthread_cond_signal(&condition);
    return true;
}

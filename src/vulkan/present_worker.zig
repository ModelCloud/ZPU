const std = @import("std");
const cpu_locality = @import("cpu_locality.zig");
const frame_pacing = @import("frame_pacing.zig");
const xcb_present = @import("xcb_present.zig");

pub const Trace = struct {
    render_complete_ns: u64,
    deadline_ns: u64,
    wake_ns: u64,
    wake_error_ns: i64,
    present_start_ns: u64,
    upload_end_ns: u64,
    copy_start_ns: u64,
    copy_end_ns: u64,
    flush_end_ns: u64,
    render_clear_ns: u64,
    render_draw_ns: u64,
    frame_end_ns: u64,
};

pub const Work = struct {
    transport: *xcb_present.Transport,
    cadence: *?frame_pacing.Clock,
    pixels: []const u8,
    content: xcb_present.Region,
    force_full: bool,
    context: *anyopaque,
    image_index: u32,
    release: *const fn (*anyopaque, u32) void,
    trace: ?*const fn (Trace) void = null,
    render_clear_ns: u64 = 0,
    render_draw_ns: u64 = 0,
    target_ns: ?u64 = null,
    enqueued_ns: u64 = 0,
};

const capacity = 24;
var entries: [capacity]Work = undefined;
var head: usize = 0;
var count: usize = 0;
var mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var started = false;
var stopping = false;
var worker_thread: ?std.Thread = null;

fn run() void {
    _ = cpu_locality.pinCurrent(.present);
    while (true) {
        _ = std.c.pthread_mutex_lock(&mutex);
        while (count == 0 and !stopping) _ = std.c.pthread_cond_wait(&condition, &mutex);
        if (count == 0 and stopping) {
            _ = std.c.pthread_mutex_unlock(&mutex);
            return;
        }
        const work = entries[head];
        head = (head + 1) % capacity;
        count -= 1;
        _ = std.c.pthread_mutex_unlock(&mutex);

        const before = frame_pacing.monotonicNs();
        work.transport.last.queue_wait_ns = before - work.enqueued_ns;
        if (work.cadence.* == null) work.cadence.* = frame_pacing.Clock.init(before, frame_pacing.configuredRate());
        const deadline = work.target_ns orelse work.cadence.*.?.deadline();
        if (!xcb_present.upload(work.transport, work.pixels, work.content, work.force_full)) {
            work.release(work.context, work.image_index);
            continue;
        }
        const commit_deadline = deadline -| frame_pacing.present_commit_lead_ns;
        if (commit_deadline > before) frame_pacing.sleepUntilPrecise(commit_deadline, frame_pacing.precision_spin_ns);
        const woke = frame_pacing.monotonicNs();
        work.transport.last.wake_error_ns = if (woke >= deadline) @intCast(woke - deadline) else -@as(i64, @intCast(deadline - woke));
        _ = xcb_present.commit(work.transport, work.pixels);
        const finished = frame_pacing.monotonicNs();
        work.transport.last.frame_total_ns = finished - work.enqueued_ns;
        work.cadence.*.?.advance(finished);
        if (work.trace) |record| record(.{
            .render_complete_ns = work.enqueued_ns,
            .deadline_ns = deadline,
            .wake_ns = woke,
            .wake_error_ns = work.transport.last.wake_error_ns,
            .present_start_ns = work.transport.last.present_start_ns,
            .upload_end_ns = work.transport.last.upload_end_ns,
            .copy_start_ns = work.transport.last.copy_start_ns,
            .copy_end_ns = work.transport.last.copy_end_ns,
            .flush_end_ns = work.transport.last.flush_end_ns,
            .render_clear_ns = work.render_clear_ns,
            .render_draw_ns = work.render_draw_ns,
            .frame_end_ns = finished,
        });
        work.release(work.context, work.image_index);
    }
}

pub fn ensureStarted() bool {
    _ = std.c.pthread_mutex_lock(&mutex);
    defer _ = std.c.pthread_mutex_unlock(&mutex);
    if (started) return true;
    stopping = false;
    worker_thread = std.Thread.spawn(.{}, run, .{}) catch return false;
    started = true;
    return true;
}

pub fn shutdown() void {
    _ = std.c.pthread_mutex_lock(&mutex);
    if (!started) {
        _ = std.c.pthread_mutex_unlock(&mutex);
        return;
    }
    stopping = true;
    _ = std.c.pthread_cond_broadcast(&condition);
    const worker = worker_thread.?;
    _ = std.c.pthread_mutex_unlock(&mutex);
    worker.join();
    _ = std.c.pthread_mutex_lock(&mutex);
    started = false;
    stopping = false;
    worker_thread = null;
    head = 0;
    count = 0;
    _ = std.c.pthread_mutex_unlock(&mutex);
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
    try std.testing.expect(!enqueue(.{ .transport = &transport, .cadence = &cadence, .pixels = "", .content = .{}, .force_full = false, .context = @ptrFromInt(8), .image_index = 0, .release = struct {
        fn f(_: *anyopaque, _: u32) void {}
    }.f }));
}

test "idle presentation worker shuts down and restarts cleanly" {
    try std.testing.expect(ensureStarted());
    shutdown();
    try std.testing.expect(ensureStarted());
    shutdown();
}

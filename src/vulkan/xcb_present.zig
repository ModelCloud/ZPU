// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const cpu_locality = @import("cpu_locality.zig");

const Connection = opaque {};
const VoidCookie = extern struct { sequence: u32 };
const InputFocusCookie = extern struct { sequence: u32 };
const InputFocusReply = opaque {};
const GenericError = extern struct { response_type: u8, error_code: u8, sequence: u16, resource_id: u32, minor_code: u16, major_code: u8, pad0: u8, pad: [5]u32, full_sequence: u32 };
const GetImageCookie = extern struct { sequence: u32 };
const GetImageReply = opaque {};
var verification_done = false;
var previous_metric_present_ns: u64 = 0;
const max_frame_metrics = 7_200;
var frame_metrics: [max_frame_metrics]u64 = undefined;
var frame_metric_count: usize = 0;
var frame_metrics_written = false;

const ShmAttachFn = *const fn (*Connection, u32, u32, u8) callconv(.c) VoidCookie;
const ShmDetachFn = *const fn (*Connection, u32) callconv(.c) VoidCookie;
const ShmPutImageFn = *const fn (*Connection, u32, u32, u16, u16, u16, u16, u16, u16, i16, i16, u8, u8, u8, u32, u32) callconv(.c) VoidCookie;
const ShmApi = struct { attach_checked: ShmAttachFn, detach: ShmDetachFn, put_image: ShmPutImageFn };

const SharedUpload = struct {
    api: ShmApi,
    address: []align(std.heap.page_size_min) u8,
    segment: u32,
    image_size: usize,
    image_stride: usize,
};

var shm_load_attempted = false;
var loaded_shm_api: ?ShmApi = null;

fn loadShmApi() ?ShmApi {
    if (shm_load_attempted) return loaded_shm_api;
    shm_load_attempted = true;
    if (builtin.os.tag != .linux) return null;
    const handle = std.c.dlopen("libxcb-shm.so.0", .{ .NOW = true }) orelse return null;
    const attach_symbol = std.c.dlsym(handle, "xcb_shm_attach_checked") orelse {
        _ = std.c.dlclose(handle);
        return null;
    };
    const detach_symbol = std.c.dlsym(handle, "xcb_shm_detach") orelse {
        _ = std.c.dlclose(handle);
        return null;
    };
    const put_image_symbol = std.c.dlsym(handle, "xcb_shm_put_image") orelse {
        _ = std.c.dlclose(handle);
        return null;
    };
    const attach_checked: ShmAttachFn = @ptrCast(@alignCast(attach_symbol));
    const detach: ShmDetachFn = @ptrCast(@alignCast(detach_symbol));
    const put_image: ShmPutImageFn = @ptrCast(@alignCast(put_image_symbol));
    loaded_shm_api = .{ .attach_checked = attach_checked, .detach = detach, .put_image = put_image };
    return loaded_shm_api;
}

fn initSharedUpload(connection: *Connection, image_size: usize, image_count: u32) ?SharedUpload {
    const api = loadShmApi() orelse return null;
    const image_stride = std.mem.alignForward(usize, image_size, std.heap.page_size_min);
    const size = std.math.mul(usize, image_stride, image_count) catch return null;
    const shmid = shmget(0, size, 0o1600);
    if (shmid < 0) return null;
    const raw_address = shmat(shmid, null, 0);
    if (@intFromPtr(raw_address) == std.math.maxInt(usize)) {
        _ = shmctl(shmid, 0, null);
        return null;
    }
    const address: [*]align(std.heap.page_size_min) u8 = @ptrCast(@alignCast(raw_address));
    cpu_locality.prepareMemory(address[0..size]);
    const segment = xcb_generate_id(connection);
    if (segment == 0) {
        _ = shmdt(raw_address);
        _ = shmctl(shmid, 0, null);
        return null;
    }
    if (xcb_request_check(connection, api.attach_checked(connection, segment, @intCast(shmid), 0))) |xcb_error| {
        std.c.free(xcb_error);
        _ = shmdt(raw_address);
        _ = shmctl(shmid, 0, null);
        return null;
    }
    _ = shmctl(shmid, 0, null);
    return .{ .api = api, .address = address[0..size], .segment = segment, .image_size = image_size, .image_stride = image_stride };
}

extern fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern fn write(fd: c_int, buffer: *const anyopaque, count: usize) isize;
extern fn close(fd: c_int) c_int;

fn frameMetricLimit() usize {
    const raw = std.c.getenv("ZPU_FRAME_METRICS_COUNT") orelse return 0;
    return @min(std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0, max_frame_metrics);
}

fn writeFrameMetrics() void {
    if (frame_metrics_written) return;
    const path = std.c.getenv("ZPU_FRAME_METRICS_PATH") orelse return;
    const fd = open(path, 0x241, 0o600); // O_WRONLY | O_CREAT | O_TRUNC
    if (fd < 0) return;
    const bytes = std.mem.sliceAsBytes(frame_metrics[0..frame_metric_count]);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (amount <= 0) break;
        offset += @intCast(amount);
    }
    _ = close(fd);
    frame_metrics_written = offset == bytes.len;
}

fn recordFrameMetric(now: u64) void {
    const enabled = std.c.getenv("ZPU_FRAME_METRICS") orelse return;
    if (enabled[0] != '1') return;
    if (previous_metric_present_ns != 0 and now > previous_metric_present_ns) {
        const limit = frameMetricLimit();
        if (limit != 0 and std.c.getenv("ZPU_FRAME_METRICS_PATH") != null) {
            if (frame_metric_count < limit) {
                frame_metrics[frame_metric_count] = now - previous_metric_present_ns;
                frame_metric_count += 1;
                if (frame_metric_count == limit) writeFrameMetrics();
            }
        } else {
            std.debug.print("zpu_vkcube_frame_ns={}\n", .{now - previous_metric_present_ns});
        }
    }
    previous_metric_present_ns = now;
}
pub const Region = struct { x: u32 = 0, y: u32 = 0, width: u32 = 0, height: u32 = 0 };

fn unionRegion(a: Region, b: Region) Region {
    if (a.width == 0 or a.height == 0) return b;
    if (b.width == 0 or b.height == 0) return a;
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.width, b.x + b.width);
    const y1 = @max(a.y + a.height, b.y + b.height);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

fn clampRegion(region: Region, width: u32, height: u32) Region {
    const x0 = @min(region.x, width);
    const y0 = @min(region.y, height);
    const x1 = @min(region.x +| region.width, width);
    const y1 = @min(region.y +| region.height, height);
    return .{ .x = x0, .y = y0, .width = x1 - x0, .height = y1 - y0 };
}

pub const Transport = struct {
    connection: *Connection,
    window: u32,
    pixmap: u32,
    gc: u32,
    width: u32,
    height: u32,
    /// A headless surface has no X11 drawable.  Keep the same transport ABI
    /// so the swapchain and timing paths remain shared, but make upload and
    /// commit pure offscreen operations.
    headless: bool = false,
    shared_upload: ?SharedUpload = null,
    visible_region: Region = .{},
    visible_valid: bool = false,
    pending_region: Region = .{},
    pending_content: Region = .{},
    last: StageTimings = .{},
};

pub const StageTimings = struct {
    queue_wait_ns: u64 = 0,
    wake_error_ns: i64 = 0,
    upload_ns: u64 = 0,
    copy_ns: u64 = 0,
    flush_ns: u64 = 0,
    transport_total_ns: u64 = 0,
    frame_total_ns: u64 = 0,
    upload_requests: u32 = 0,
    present_start_ns: u64 = 0,
    upload_start_ns: u64 = 0,
    upload_end_ns: u64 = 0,
    copy_start_ns: u64 = 0,
    copy_end_ns: u64 = 0,
    flush_end_ns: u64 = 0,
};

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Creates persistent X resources once per swapchain. Frames are uploaded to
/// an off-screen pixmap and made visible by one CopyArea, so strip boundaries
/// can never become partially exposed window contents.
pub fn init(connection_opaque: *anyopaque, window: u32, width: u32, height: u32, image_count: u32) ?Transport {
    if (builtin.is_test) return if (window == 0 or width == 0 or height == 0 or image_count == 0) null else .{ .connection = @ptrFromInt(8), .window = window, .pixmap = 2, .gc = 3, .width = width, .height = height };
    if (width == 0 or height == 0 or image_count == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return null;
    const connection: *Connection = @ptrCast(connection_opaque);
    if (xcb_connection_has_error(connection) != 0) return null;
    const pixmap = xcb_generate_id(connection);
    const gc = xcb_generate_id(connection);
    if (pixmap == 0 or gc == 0) return null;
    _ = xcb_create_pixmap(connection, 24, pixmap, window, @intCast(width), @intCast(height));
    _ = xcb_create_gc(connection, gc, pixmap, 0, null);
    if (xcb_flush(connection) <= 0) return null;
    const byte_count = @as(usize, width) * height * 4;
    return .{ .connection = connection, .window = window, .pixmap = pixmap, .gc = gc, .width = width, .height = height, .shared_upload = initSharedUpload(connection, byte_count, image_count) };
}

/// Creates an offscreen transport for VK_EXT_headless_surface.  Headless
/// presentation still validates the complete pixel envelope and records the
/// frame cadence, but never opens or touches an X11 connection.
pub fn initHeadless(width: u32, height: u32, image_count: u32) ?Transport {
    if (width == 0 or height == 0 or image_count == 0) return null;
    return .{ .connection = @ptrFromInt(8), .window = 0, .pixmap = 0, .gc = 0, .width = width, .height = height, .headless = true };
}

pub fn swapchainImageBytes(transport: *Transport, image_index: u32) ?[]align(64) u8 {
    const shared = transport.shared_upload orelse return null;
    const offset = std.math.mul(usize, image_index, shared.image_stride) catch return null;
    if (offset > shared.address.len or shared.image_size > shared.address.len - offset) return null;
    const pointer: [*]align(64) u8 = @ptrCast(@alignCast(shared.address.ptr + offset));
    return pointer[0..shared.image_size];
}

pub fn deinit(transport: *Transport) void {
    if (builtin.is_test or transport.headless) return;
    if (transport.shared_upload) |shared| {
        _ = shared.api.detach(transport.connection, shared.segment);
        _ = xcb_flush(transport.connection);
        _ = shmdt(shared.address.ptr);
        transport.shared_upload = null;
    }
    _ = xcb_free_gc(transport.connection, transport.gc);
    _ = xcb_free_pixmap(transport.connection, transport.pixmap);
    _ = xcb_flush(transport.connection);
}

pub fn upload(transport: *Transport, pixels: []const u8, content: Region, force_full: bool) bool {
    const total_start = monotonicNs();
    transport.last.present_start_ns = total_start;
    transport.last.upload_requests = 0;
    const width = transport.width;
    const height = transport.height;
    if (transport.headless) {
        transport.last.upload_start_ns = total_start;
        transport.last.upload_end_ns = total_start;
        transport.last.upload_ns = 0;
        transport.pending_region = .{ .width = width, .height = height };
        transport.pending_content = clampRegion(content, width, height);
        return pixels.len == @as(usize, width) * height * 4;
    }
    if (builtin.is_test) return pixels.len == @as(usize, width) * height * 4;
    const expected = std.math.mul(usize, @as(usize, width) * height, 4) catch return false;
    if (pixels.len != expected or pixels.len > std.math.maxInt(u32)) return false;
    const connection = transport.connection;
    if (xcb_connection_has_error(connection) != 0) return false;
    const row_bytes = @as(usize, width) * 4;
    const request_bytes = @as(usize, xcb_get_maximum_request_length(connection)) * 4;
    const payload_bytes = if (request_bytes > 64) request_bytes - 64 else 0;
    const rows_per_request = @max(@as(usize, 1), payload_bytes / row_bytes);
    var y: usize = 0;
    const upload_start = monotonicNs();
    transport.last.upload_start_ns = upload_start;
    const current_content = clampRegion(content, width, height);
    const full = Region{ .width = width, .height = height };
    const damage = if (force_full or !transport.visible_valid) full else unionRegion(transport.visible_region, current_content);
    transport.pending_region = damage;
    transport.pending_content = current_content;
    if (transport.shared_upload) |shared| {
        const shared_start = @intFromPtr(shared.address.ptr);
        const pixel_start = @intFromPtr(pixels.ptr);
        if (pixels.len > shared.address.len or pixel_start < shared_start or pixel_start - shared_start > shared.address.len - pixels.len) return false;
        if (damage.width != 0 and damage.height != 0) {
            const offset: u32 = @intCast(pixel_start - shared_start);
            _ = shared.api.put_image(connection, transport.pixmap, transport.gc, @intCast(width), @intCast(height), @intCast(damage.x), @intCast(damage.y), @intCast(damage.width), @intCast(damage.height), @intCast(damage.x), @intCast(damage.y), 24, 2, 0, shared.segment, offset);
            transport.last.upload_requests = 1;
            const reply = xcb_get_input_focus_reply(connection, xcb_get_input_focus(connection), null) orelse return false;
            std.c.free(reply);
        }
    } else {
        while (y < height) {
            const rows = @min(rows_per_request, @as(usize, height) - y);
            const data = pixels[y * row_bytes ..][0 .. rows * row_bytes];
            _ = xcb_put_image(connection, 2, transport.pixmap, transport.gc, @intCast(width), @intCast(rows), 0, @intCast(y), 0, 24, @intCast(data.len), data.ptr);
            transport.last.upload_requests += 1;
            y += rows;
        }
    }
    transport.last.upload_end_ns = monotonicNs();
    transport.last.upload_ns = transport.last.upload_end_ns - upload_start;
    return true;
}

pub fn commit(transport: *Transport, pixels: []const u8) bool {
    const width = transport.width;
    const height = transport.height;
    if (transport.headless) {
        if (pixels.len != @as(usize, width) * height * 4) return false;
        const now = monotonicNs();
        transport.last.copy_start_ns = now;
        transport.last.copy_end_ns = now;
        transport.last.flush_end_ns = now;
        transport.last.transport_total_ns = now -| transport.last.present_start_ns;
        transport.visible_region = transport.pending_content;
        transport.visible_valid = true;
        recordFrameMetric(now);
        return true;
    }
    if (builtin.is_test) return pixels.len == @as(usize, width) * height * 4;
    const expected = std.math.mul(usize, @as(usize, width) * height, 4) catch return false;
    if (pixels.len != expected) return false;
    const connection = transport.connection;
    const copy_start = monotonicNs();
    transport.last.copy_start_ns = copy_start;
    const damage = transport.pending_region;
    if (damage.width != 0 and damage.height != 0) _ = xcb_copy_area(connection, transport.pixmap, transport.window, transport.gc, @intCast(damage.x), @intCast(damage.y), @intCast(damage.x), @intCast(damage.y), @intCast(damage.width), @intCast(damage.height));
    transport.last.copy_end_ns = monotonicNs();
    transport.last.copy_ns = transport.last.copy_end_ns - copy_start;
    const flush_start = monotonicNs();
    if (xcb_flush(connection) <= 0) return false;
    transport.last.flush_end_ns = monotonicNs();
    transport.last.flush_ns = transport.last.flush_end_ns - flush_start;
    transport.last.transport_total_ns = transport.last.flush_end_ns - transport.last.present_start_ns;
    transport.visible_region = transport.pending_content;
    transport.visible_valid = true;
    recordFrameMetric(transport.last.flush_end_ns);
    const verify = std.c.getenv("ZPU_VERIFY_PRESENT") orelse null;
    if (!verification_done and verify != null and verify.?[0] == '1') {
        verification_done = true;
        const reply = xcb_get_image_reply(connection, xcb_get_image(connection, 2, transport.window, @intCast(width / 2), @intCast(height / 2), 1, 1, std.math.maxInt(u32)), null);
        if (reply) |image_reply| {
            defer std.c.free(image_reply);
            const data = xcb_get_image_data(image_reply);
            const source_offset = (@as(usize, height / 2) * width + width / 2) * 4;
            if (std.mem.eql(u8, data[0..4], pixels[source_offset..][0..4])) std.debug.print("zpu_visual_present=BGRA({},{},{},{})\n", .{ data[0], data[1], data[2], data[3] });
        }
    }
    return true;
}

pub fn present(transport: *Transport, pixels: []const u8) bool {
    return upload(transport, pixels, .{ .width = transport.width, .height = transport.height }, true) and commit(transport, pixels);
}

extern fn xcb_generate_id(connection: *Connection) u32;
extern fn xcb_connection_has_error(connection: *Connection) i32;
extern fn xcb_get_maximum_request_length(connection: *Connection) u32;
extern fn xcb_request_check(connection: *Connection, cookie: VoidCookie) ?*GenericError;
extern fn xcb_get_input_focus(connection: *Connection) InputFocusCookie;
extern fn xcb_get_input_focus_reply(connection: *Connection, cookie: InputFocusCookie, error_out: ?*?*GenericError) ?*InputFocusReply;
extern fn xcb_create_pixmap(connection: *Connection, depth: u8, pixmap: u32, drawable: u32, width: u16, height: u16) VoidCookie;
extern fn xcb_free_pixmap(connection: *Connection, pixmap: u32) VoidCookie;
extern fn xcb_create_gc(connection: *Connection, gc: u32, drawable: u32, value_mask: u32, values: ?[*]const u32) VoidCookie;
extern fn xcb_free_gc(connection: *Connection, gc: u32) VoidCookie;
extern fn xcb_put_image(connection: *Connection, format: u8, drawable: u32, gc: u32, width: u16, height: u16, dst_x: i16, dst_y: i16, left_pad: u8, depth: u8, data_len: u32, data: [*]const u8) VoidCookie;
extern fn xcb_copy_area(connection: *Connection, src: u32, dst: u32, gc: u32, src_x: i16, src_y: i16, dst_x: i16, dst_y: i16, width: u16, height: u16) VoidCookie;
extern fn xcb_flush(connection: *Connection) i32;
extern fn xcb_get_image(connection: *Connection, format: u8, drawable: u32, x: i16, y: i16, width: u16, height: u16, plane_mask: u32) GetImageCookie;
extern fn xcb_get_image_reply(connection: *Connection, cookie: GetImageCookie, error_out: ?*?*GenericError) ?*GetImageReply;
extern fn xcb_get_image_data(reply: *const GetImageReply) [*]u8;
extern fn shmget(key: c_int, size: usize, flags: c_int) c_int;
extern fn shmat(shmid: c_int, address: ?*const anyopaque, flags: c_int) *anyopaque;
extern fn shmdt(address: *const anyopaque) c_int;
extern fn shmctl(shmid: c_int, command: c_int, buffer: ?*anyopaque) c_int;

test "test-mode presentation validates the image envelope without touching XCB" {
    var pixels = [_]u8{0} ** 16;
    var transport = init(@ptrFromInt(8), 1, 2, 2, 1).?;
    try std.testing.expect(present(&transport, &pixels));
    try std.testing.expect(init(@ptrFromInt(8), 0, 2, 2, 1) == null);
    try std.testing.expect(!present(&transport, pixels[0..4]));
}

test "headless transport presents offscreen without XCB" {
    var pixels = [_]u8{0} ** 16;
    var transport = initHeadless(2, 2, 2).?;
    try std.testing.expect(transport.headless);
    try std.testing.expect(swapchainImageBytes(&transport, 0) == null);
    try std.testing.expect(present(&transport, &pixels));
    try std.testing.expect(transport.visible_valid);
    try std.testing.expect(!present(&transport, pixels[0..4]));
    deinit(&transport);
    try std.testing.expect(initHeadless(0, 2, 1) == null);
}

test "transport exposes a complete frame after all upload chunks" {
    // The production ordering is deliberately structural: every PutImage
    // targets the invisible pixmap and exactly one CopyArea follows the loop.
    var pixels = [_]u8{0} ** 64;
    var transport = init(@ptrFromInt(8), 1, 4, 4, 1).?;
    try std.testing.expect(present(&transport, &pixels));
}

test "damage covers old and new content and clamps to the drawable" {
    try std.testing.expectEqual(Region{ .x = 2, .y = 3, .width = 9, .height = 8 }, unionRegion(.{ .x = 2, .y = 3, .width = 4, .height = 5 }, .{ .x = 8, .y = 6, .width = 3, .height = 5 }));
    try std.testing.expectEqual(Region{ .x = 8, .y = 7, .width = 2, .height = 3 }, clampRegion(.{ .x = 8, .y = 7, .width = 50, .height = 50 }, 10, 10));
    try std.testing.expectEqual(Region{ .x = 1, .y = 1, .width = 2, .height = 2 }, unionRegion(.{}, .{ .x = 1, .y = 1, .width = 2, .height = 2 }));
}

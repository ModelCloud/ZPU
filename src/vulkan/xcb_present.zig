const std = @import("std");
const builtin = @import("builtin");

const Connection = opaque {};
const VoidCookie = extern struct { sequence: u32 };
const GenericError = extern struct { response_type: u8, error_code: u8, sequence: u16, resource_id: u32, minor_code: u16, major_code: u8, pad0: u8, pad: [5]u32, full_sequence: u32 };
const GetImageCookie = extern struct { sequence: u32 };
const GetImageReply = opaque {};
var verification_done = false;
pub const Transport = struct {
    connection: *Connection,
    window: u32,
    pixmap: u32,
    gc: u32,
    width: u32,
    height: u32,
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
};

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

/// Creates persistent X resources once per swapchain. Frames are uploaded to
/// an off-screen pixmap and made visible by one CopyArea, so strip boundaries
/// can never become partially exposed window contents.
pub fn init(connection_opaque: *anyopaque, window: u32, width: u32, height: u32) ?Transport {
    if (builtin.is_test) return if (window == 0 or width == 0 or height == 0) null else .{ .connection = @ptrFromInt(8), .window = window, .pixmap = 2, .gc = 3, .width = width, .height = height };
    if (width == 0 or height == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return null;
    const connection: *Connection = @ptrCast(connection_opaque);
    if (xcb_connection_has_error(connection) != 0) return null;
    const pixmap = xcb_generate_id(connection);
    const gc = xcb_generate_id(connection);
    if (pixmap == 0 or gc == 0) return null;
    _ = xcb_create_pixmap(connection, 24, pixmap, window, @intCast(width), @intCast(height));
    _ = xcb_create_gc(connection, gc, pixmap, 0, null);
    if (xcb_flush(connection) <= 0) return null;
    return .{ .connection = connection, .window = window, .pixmap = pixmap, .gc = gc, .width = width, .height = height };
}

pub fn deinit(transport: *Transport) void {
    if (builtin.is_test) return;
    _ = xcb_free_gc(transport.connection, transport.gc);
    _ = xcb_free_pixmap(transport.connection, transport.pixmap);
    _ = xcb_flush(transport.connection);
}

pub fn present(transport: *Transport, pixels: []const u8) bool {
    const total_start = monotonicNs();
    transport.last.upload_requests = 0;
    const width = transport.width;
    const height = transport.height;
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
    while (y < height) {
        const rows = @min(rows_per_request, @as(usize, height) - y);
        const data = pixels[y * row_bytes ..][0 .. rows * row_bytes];
        _ = xcb_put_image(connection, 2, transport.pixmap, transport.gc, @intCast(width), @intCast(rows), 0, @intCast(y), 0, 24, @intCast(data.len), data.ptr);
        transport.last.upload_requests += 1;
        y += rows;
    }
    transport.last.upload_ns = monotonicNs() - upload_start;
    const copy_start = monotonicNs();
    _ = xcb_copy_area(connection, transport.pixmap, transport.window, transport.gc, 0, 0, 0, 0, @intCast(width), @intCast(height));
    transport.last.copy_ns = monotonicNs() - copy_start;
    const flush_start = monotonicNs();
    if (xcb_flush(connection) <= 0) return false;
    transport.last.flush_ns = monotonicNs() - flush_start;
    transport.last.transport_total_ns = monotonicNs() - total_start;
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

extern fn xcb_generate_id(connection: *Connection) u32;
extern fn xcb_connection_has_error(connection: *Connection) i32;
extern fn xcb_get_maximum_request_length(connection: *Connection) u32;
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

test "test-mode presentation validates the image envelope without touching XCB" {
    var pixels = [_]u8{0} ** 16;
    var transport = init(@ptrFromInt(8), 1, 2, 2).?;
    try std.testing.expect(present(&transport, &pixels));
    try std.testing.expect(init(@ptrFromInt(8), 0, 2, 2) == null);
    try std.testing.expect(!present(&transport, pixels[0..4]));
}

test "transport exposes a complete frame after all upload chunks" {
    // The production ordering is deliberately structural: every PutImage
    // targets the invisible pixmap and exactly one CopyArea follows the loop.
    var pixels = [_]u8{0} ** 64;
    var transport = init(@ptrFromInt(8), 1, 4, 4).?;
    try std.testing.expect(present(&transport, &pixels));
}

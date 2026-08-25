const std = @import("std");
const builtin = @import("builtin");

const Connection = opaque {};
const VoidCookie = extern struct { sequence: u32 };
const GenericError = extern struct { response_type: u8, error_code: u8, sequence: u16, resource_id: u32, minor_code: u16, major_code: u8, pad0: u8, pad: [5]u32, full_sequence: u32 };
const GetImageCookie = extern struct { sequence: u32 };
const GetImageReply = opaque {};
var verification_done = false;
var previous_metric_present_ns: u64 = 0;

fn recordFrameMetric() void {
    const enabled = std.c.getenv("ZPU_FRAME_METRICS") orelse return;
    if (enabled[0] != '1') return;
    var timestamp: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &timestamp) != 0) return;
    const now: u64 = @as(u64, @intCast(timestamp.sec)) * std.time.ns_per_s + @as(u64, @intCast(timestamp.nsec));
    if (previous_metric_present_ns != 0 and now > previous_metric_present_ns)
        std.debug.print("zpu_vkcube_frame_ns={}\n", .{now - previous_metric_present_ns});
    previous_metric_present_ns = now;
}
/// Uploads a tightly packed BGRA8 swapchain image into an existing XCB window.
/// The X server owns the connection and window; this function owns only its
/// temporary graphics context.
pub fn present(connection_opaque: *anyopaque, window: u32, width: u32, height: u32, pixels: []const u8) bool {
    if (builtin.is_test) return pixels.len == @as(usize, width) * height * 4 and window != 0;
    if (width == 0 or height == 0 or width > std.math.maxInt(u16) or height > std.math.maxInt(u16)) return false;
    const expected = std.math.mul(usize, @as(usize, width) * height, 4) catch return false;
    if (pixels.len != expected or pixels.len > std.math.maxInt(u32)) return false;
    const connection: *Connection = @ptrCast(connection_opaque);
    if (xcb_connection_has_error(connection) != 0) return false;

    const gc = xcb_generate_id(connection);
    if (gc == 0) return false;
    _ = xcb_create_gc(connection, gc, window, 0, null);
    const row_bytes = @as(usize, width) * 4;
    const rows_per_request = @max(@as(usize, 1), (60 * 1024) / row_bytes);
    var y: usize = 0;
    while (y < height) {
        const rows = @min(rows_per_request, @as(usize, height) - y);
        const data = pixels[y * row_bytes ..][0 .. rows * row_bytes];
        const cookie = xcb_put_image_checked(connection, 2, window, gc, @intCast(width), @intCast(rows), 0, @intCast(y), 0, 24, @intCast(data.len), data.ptr);
        if (xcb_request_check(connection, cookie)) |request_error| {
            std.c.free(request_error);
            return false;
        }
        y += rows;
    }
    _ = xcb_free_gc(connection, gc);
    if (xcb_flush(connection) <= 0) return false;
    recordFrameMetric();
    const verify = std.c.getenv("ZPU_VERIFY_PRESENT") orelse null;
    if (!verification_done and verify != null and verify.?[0] == '1') {
        verification_done = true;
        const reply = xcb_get_image_reply(connection, xcb_get_image(connection, 2, window, @intCast(width / 2), @intCast(height / 2), 1, 1, std.math.maxInt(u32)), null);
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
extern fn xcb_create_gc(connection: *Connection, gc: u32, drawable: u32, value_mask: u32, values: ?[*]const u32) VoidCookie;
extern fn xcb_free_gc(connection: *Connection, gc: u32) VoidCookie;
extern fn xcb_put_image_checked(connection: *Connection, format: u8, drawable: u32, gc: u32, width: u16, height: u16, dst_x: i16, dst_y: i16, left_pad: u8, depth: u8, data_len: u32, data: [*]const u8) VoidCookie;
extern fn xcb_request_check(connection: *Connection, cookie: VoidCookie) ?*GenericError;
extern fn xcb_flush(connection: *Connection) i32;
extern fn xcb_get_image(connection: *Connection, format: u8, drawable: u32, x: i16, y: i16, width: u16, height: u16, plane_mask: u32) GetImageCookie;
extern fn xcb_get_image_reply(connection: *Connection, cookie: GetImageCookie, error_out: ?*?*GenericError) ?*GetImageReply;
extern fn xcb_get_image_data(reply: *const GetImageReply) [*]u8;

test "test-mode presentation validates the image envelope without touching XCB" {
    var pixels = [_]u8{0} ** 16;
    try std.testing.expect(present(@ptrFromInt(8), 1, 2, 2, &pixels));
    try std.testing.expect(!present(@ptrFromInt(8), 0, 2, 2, &pixels));
    try std.testing.expect(!present(@ptrFromInt(8), 1, 1, 1, &pixels));
}

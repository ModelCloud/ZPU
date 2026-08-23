const std = @import("std");

pub fn fill(bytes: []u8, data: u32) void {
    var i: usize = 0;
    while (i < bytes.len) : (i += 4) std.mem.writeInt(u32, bytes[i..][0..4], data, .little);
}

pub fn copy(dst: []u8, src: []const u8) void {
    std.mem.copyForwards(u8, dst, src);
}

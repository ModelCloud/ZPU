// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub fn fill(bytes: []u8, data: u32) void {
    const lanes = 8;
    const V = @Vector(lanes, u32);
    const native_pattern = std.mem.nativeTo(u32, data, .little);
    const patterns: V = @splat(native_pattern);
    const pattern_bytes: [lanes * 4]u8 = @bitCast(patterns);
    var i: usize = 0;
    while (i + pattern_bytes.len <= bytes.len) : (i += pattern_bytes.len) {
        @memcpy(bytes[i..][0..pattern_bytes.len], &pattern_bytes);
    }
    while (i < bytes.len) : (i += 4) std.mem.writeInt(u32, bytes[i..][0..4], data, .little);
}

pub fn copy(dst: []u8, src: []const u8) void {
    // Vulkan host-visible transfers are non-overlapping by API contract.
    // Use the compiler's bulk memcpy lowering (which selects the CPU's tuned
    // copy routine) instead of the overlap-safe byte loop. Keep a defensive
    // overlap fallback for direct helper users; validated Vulkan commands
    // never take this branch.
    const dst_start = @intFromPtr(dst.ptr);
    const src_start = @intFromPtr(src.ptr);
    const dst_end = dst_start +| dst.len;
    const src_end = src_start +| src.len;
    if (dst_start < src_end and src_start < dst_end) {
        @memmove(dst, src);
        return;
    }
    @memcpy(dst, src);
}

test "native vector fill preserves little-endian Vulkan words for unaligned chunks and tails" {
    var storage = [_]u8{0xaa} ** 70;
    fill(storage[1..69], 0x44332211);
    try std.testing.expectEqual(@as(u8, 0xaa), storage[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), storage[69]);
    var offset: usize = 1;
    while (offset < 69) : (offset += 4) {
        try std.testing.expectEqualSlices(u8, &.{ 0x11, 0x22, 0x33, 0x44 }, storage[offset..][0..4]);
    }
}

test "bulk host copy preserves a non-overlapping unaligned transfer" {
    var source = [_]u8{0} ** 37;
    for (&source, 0..) |*value, index| value.* = @truncate(index * 13 + 5);
    var destination = [_]u8{0xaa} ** 43;
    copy(destination[3..40], source[0..37]);
    try std.testing.expectEqualSlices(u8, source[0..], destination[3..40]);
    try std.testing.expectEqual(@as(u8, 0xaa), destination[0]);
    try std.testing.expectEqual(@as(u8, 0xaa), destination[40]);
}

test "overlapping helper copies retain memmove semantics" {
    var bytes = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7 };
    copy(bytes[1..], bytes[0..7]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 1, 2, 3, 4, 5, 6 }, &bytes);
}

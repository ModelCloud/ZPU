// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const State = enum(u8) { available, acquired, queued };

pub fn acquire(states: []State, cursor: *u32) ?u32 {
    var offset: u32 = 0;
    while (offset < states.len) : (offset += 1) {
        const index = (cursor.* + offset) % @as(u32, @intCast(states.len));
        if (states[index] == .available) {
            states[index] = .acquired;
            cursor.* = (index + 1) % @as(u32, @intCast(states.len));
            return index;
        }
    }
    return null;
}

pub fn queue(states: []State, index: u32) bool {
    if (index >= states.len or states[index] != .acquired) return false;
    states[index] = .queued;
    return true;
}

pub fn release(states: []State, index: u32) bool {
    if (index >= states.len or states[index] != .queued) return false;
    states[index] = .available;
    return true;
}

test "bounded swapchain images are unavailable until FIFO release" {
    var states = [_]State{ .available, .available, .available };
    var cursor: u32 = 0;
    try std.testing.expectEqual(@as(?u32, 0), acquire(&states, &cursor));
    try std.testing.expectEqual(@as(?u32, 1), acquire(&states, &cursor));
    try std.testing.expectEqual(@as(?u32, 2), acquire(&states, &cursor));
    try std.testing.expect(acquire(&states, &cursor) == null);
    try std.testing.expect(queue(&states, 0));
    try std.testing.expect(acquire(&states, &cursor) == null);
    try std.testing.expect(release(&states, 0));
    try std.testing.expectEqual(@as(?u32, 0), acquire(&states, &cursor));
}

test "invalid present and duplicate release preserve lifecycle" {
    var states = [_]State{ .available, .available };
    try std.testing.expect(!queue(&states, 0));
    var cursor: u32 = 0;
    _ = acquire(&states, &cursor);
    try std.testing.expect(queue(&states, 0));
    try std.testing.expect(!queue(&states, 0));
    try std.testing.expect(release(&states, 0));
    try std.testing.expect(!release(&states, 0));
}

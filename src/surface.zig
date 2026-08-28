// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");

pub const Format = enum { rgba8_unorm, bgra8_unorm };

pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
};

pub const Rect = struct { x: i32, y: i32, width: u32, height: u32 };

pub const Surface = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    format: Format,

    pub fn init(pixels: []u8, width: u32, height: u32, stride: usize, format: Format) !Surface {
        const row_bytes = try std.math.mul(usize, width, 4);
        if (stride < row_bytes) return error.InvalidStride;
        const required = if (height == 0) 0 else try std.math.add(usize, try std.math.mul(usize, height - 1, stride), row_bytes);
        if (pixels.len < required) return error.BufferTooSmall;
        return .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .format = format };
    }

    pub fn row(self: *Surface, y: u32) []u8 {
        const start = @as(usize, y) * self.stride;
        return self.pixels[start .. start + @as(usize, self.width) * 4];
    }

    pub fn write(row_bytes: []u8, offset: usize, format: Format, c: Color) void {
        switch (format) {
            .rgba8_unorm => {
                row_bytes[offset] = c.r;
                row_bytes[offset + 1] = c.g;
                row_bytes[offset + 2] = c.b;
            },
            .bgra8_unorm => {
                row_bytes[offset] = c.b;
                row_bytes[offset + 1] = c.g;
                row_bytes[offset + 2] = c.r;
            },
        }
        row_bytes[offset + 3] = c.a;
    }

    pub fn read(row_bytes: []const u8, offset: usize, format: Format) Color {
        return switch (format) {
            .rgba8_unorm => .rgba(row_bytes[offset], row_bytes[offset + 1], row_bytes[offset + 2], row_bytes[offset + 3]),
            .bgra8_unorm => .rgba(row_bytes[offset + 2], row_bytes[offset + 1], row_bytes[offset], row_bytes[offset + 3]),
        };
    }
};

pub fn clip(rect: Rect, width: u32, height: u32) ?Rect {
    // Most draw calls are already in bounds. Use subtraction-based checks so
    // the fast path avoids widening coordinates and cannot overflow on large
    // rectangles; zero-sized inputs still retain the null result below.
    if (rect.width != 0 and rect.height != 0 and rect.x >= 0 and rect.y >= 0) {
        const x: u32 = @intCast(rect.x);
        const y: u32 = @intCast(rect.y);
        if (x <= width and rect.width <= width - x and y <= height and rect.height <= height - y) return rect;
    }
    const x0 = @max(@as(i64, rect.x), 0);
    const y0 = @max(@as(i64, rect.y), 0);
    const x1 = @min(@as(i64, rect.x) + rect.width, width);
    const y1 = @min(@as(i64, rect.y) + rect.height, height);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = @intCast(x0), .y = @intCast(y0), .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
}

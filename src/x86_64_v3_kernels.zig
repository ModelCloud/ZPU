// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Eight-lane kernel objects compiled for the x86-64-v3 feature level.
//!
//! This file is built by `build.zig` as its own static library with an
//! explicit `x86_64_v3` CPU model, never as part of the default (baseline)
//! artifact codegen. Baseline artifacts reach these kernels only through the
//! extern symbols declared in `simd/kernel_abi.zig`, and
//! `simd/dispatch.zig` gates every call behind runtime CPUID/XGETBV support
//! checks. The arithmetic inside is identical to the four-lane portable
//! kernels in `simd/vector.zig` instantiated at eight lanes, so pixel results
//! are bit-for-bit unchanged.
//!
//! This file lives at the src/ root because a Zig module cannot import files
//! outside its root path; the kernels need `surface.zig` and `simd/vector.zig`.
//!
//! Safety posture: Debug-mode safety plumbing would drag std.debug/DWARF
//! machinery into this v3-feature tier, so the library is always built
//! optimized WITHOUT relying on optimizer-promised `unreachable` elision.
//! Every ABI-input violation takes an explicit `@trap()` — a mandatory `ud2`
//! instruction the optimizer must preserve — so malformed calls halt instead
//! of corrupting pixels or reading out of bounds. `tools/kernel_guard_regression.sh`
//! deterministically verifies those trap instructions survived compilation in
//! the emitted kernel objects, and correctness is pinned by differential
//! oracle tests that compare every tier byte-for-byte against scalar.
const abi = @import("simd/kernel_abi.zig");
const std = @import("std");
const s = @import("surface.zig");
const vector = @import("simd/vector.zig");

fn unpackColor(packed_color: u32) s.Color {
    return .{
        .r = @truncate(packed_color),
        .g = @truncate(packed_color >> 8),
        .b = @truncate(packed_color >> 16),
        .a = @truncate(packed_color >> 24),
    };
}

fn packedColor(color: s.Color, format: s.Format) u32 {
    return switch (format) {
        .rgba8_unorm => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24),
        .bgra8_unorm => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16) | (@as(u32, color.a) << 24),
    };
}

fn checkedFormat(format_tag: u8) s.Format {
    return switch (format_tag) {
        0 => .rgba8_unorm,
        1 => .bgra8_unorm,
        // Only dispatch.zig calls these wrappers; a tag outside the two known
        // formats means the ABI contract is broken. Trap loudly instead of
        // silently writing wrong pixels via an invalid enum value.
        else => @trap(),
    };
}

/// Traps unless `row_len` covers `(start + count) * 4` bytes without overflow.
inline fn checkSpanBounds(row_len: usize, start: usize, count: usize) void {
    const pixels = std.math.add(usize, start, count) catch @trap();
    const bytes = std.math.mul(usize, pixels, 4) catch @trap();
    if (bytes > row_len) @trap();
}

/// Validate a row-oriented rectangle before entering the vector loop. The
/// pointer passed by dispatch points at the first clipped row and row_len is
/// the remaining backing allocation, not merely the visible row width; this
/// lets padded surfaces and a short final row remain memory-safe.
inline fn checkRowsBounds(row_len: usize, stride: usize, start: usize, count: usize, rows: usize) void {
    checkSpanBounds(stride, start, count);
    if (rows == 0) return;
    const row_offset = std.math.mul(usize, rows - 1, stride) catch @trap();
    const end_pixel = std.math.add(usize, start, count) catch @trap();
    const end = std.math.add(usize, row_offset, std.math.mul(usize, end_pixel, 4) catch @trap()) catch @trap();
    if (end > row_len) @trap();
}

fn fillImpl(row_ptr: [*]u8, row_len: usize, start: usize, count: usize, format_tag: u8, packed_color: u32) callconv(.c) void {
    checkSpanBounds(row_len, start, count);
    vector.fill(8, row_ptr[0..row_len], start, count, checkedFormat(format_tag), unpackColor(packed_color));
}

fn blendSpanImpl(row_ptr: [*]u8, row_len: usize, start: usize, count: usize, format_tag: u8, packed_color: u32) callconv(.c) void {
    checkSpanBounds(row_len, start, count);
    vector.blend(8, row_ptr[0..row_len], start, count, checkedFormat(format_tag), unpackColor(packed_color));
}

fn blendPixelsImpl(row_ptr: [*]u8, row_len: usize, start: usize, source_ptr: [*]const u8, source_len: usize, count: usize, format_tag: u8) callconv(.c) void {
    checkSpanBounds(row_len, start, count);
    const source_bytes = std.math.mul(usize, count, 4) catch @trap();
    if (source_bytes > source_len) @trap();
    vector.blendPixels(8, row_ptr[0..row_len], start, source_ptr[0..source_len], count, checkedFormat(format_tag));
}

fn fillRowsImpl(row_ptr: [*]u8, row_len: usize, stride: usize, start: usize, count: usize, rows: usize, format_tag: u8, packed_color: u32) callconv(.c) void {
    checkRowsBounds(row_len, stride, start, count, rows);
    const format = checkedFormat(format_tag);
    const color = unpackColor(packed_color);
    const pixel_bits = packedColor(color, format);
    for (0..rows) |y| {
        const offset = std.math.mul(usize, y, stride) catch @trap();
        vector.fillPacked(8, row_ptr[offset..row_len], start, count, pixel_bits);
    }
}

fn blendRowsImpl(row_ptr: [*]u8, row_len: usize, stride: usize, start: usize, count: usize, rows: usize, format_tag: u8, packed_color: u32) callconv(.c) void {
    checkRowsBounds(row_len, stride, start, count, rows);
    const format = checkedFormat(format_tag);
    const color = unpackColor(packed_color);
    for (0..rows) |y| {
        const offset = std.math.mul(usize, y, stride) catch @trap();
        vector.blend(8, row_ptr[offset..row_len], start, count, format, color);
    }
}

fn blendPixelsRowsImpl(row_ptr: [*]u8, row_len: usize, stride: usize, source_ptr: [*]const u8, source_len: usize, source_stride: usize, start: usize, count: usize, rows: usize, format_tag: u8) callconv(.c) void {
    checkRowsBounds(row_len, stride, start, count, rows);
    checkRowsBounds(source_len, source_stride, 0, count, rows);
    const format = checkedFormat(format_tag);
    for (0..rows) |y| {
        const destination_offset = std.math.mul(usize, y, stride) catch @trap();
        const source_offset = std.math.mul(usize, y, source_stride) catch @trap();
        vector.blendPixels(8, row_ptr[destination_offset..row_len], start, source_ptr[source_offset..source_len], count, format);
    }
}

fn fillRectsImpl(row_ptr: [*]u8, row_len: usize, stride: usize, commands: [*]const abi.RectColorCommand, command_count: usize, format_tag: u8) callconv(.c) void {
    const format = checkedFormat(format_tag);
    for (0..command_count) |index| {
        const command = commands[index];
        if (command.rect.x < 0 or command.rect.y < 0) @trap();
        const start = @as(usize, @intCast(command.rect.x));
        const row = @as(usize, @intCast(command.rect.y));
        const row_offset = std.math.mul(usize, row, stride) catch @trap();
        if (row_offset > row_len) @trap();
        checkRowsBounds(row_len - row_offset, stride, start, command.rect.width, command.rect.height);
        const pixel_bits = packedColor(command.color, format);
        for (0..command.rect.height) |dy| {
            const offset = std.math.mul(usize, dy, stride) catch @trap();
            vector.fillPacked(8, row_ptr[row_offset + offset .. row_len], start, command.rect.width, pixel_bits);
        }
    }
}

comptime {
    @export(&fillImpl, .{ .name = abi.fill_span_8_name });
    @export(&blendSpanImpl, .{ .name = abi.blend_span_8_name });
    @export(&blendPixelsImpl, .{ .name = abi.blend_pixels_8_name });
    @export(&fillRowsImpl, .{ .name = abi.fill_rows_8_name });
    @export(&blendRowsImpl, .{ .name = abi.blend_rows_8_name });
    @export(&blendPixelsRowsImpl, .{ .name = abi.blend_pixels_rows_8_name });
    @export(&fillRectsImpl, .{ .name = abi.fill_rects_8_name });
}

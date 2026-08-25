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

comptime {
    @export(&fillImpl, .{ .name = abi.fill_span_8_name });
    @export(&blendSpanImpl, .{ .name = abi.blend_span_8_name });
    @export(&blendPixelsImpl, .{ .name = abi.blend_pixels_8_name });
}

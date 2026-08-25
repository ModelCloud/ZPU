//! Eight-lane kernel objects compiled for the x86-64-v3 feature level.
//!
//! This file is built by `build.zig` as its own static library with an
//! explicit `x86_64_v3` CPU model, never as part of the default (baseline)
//! artifact codegen. Baseline artifacts reach these kernels only through the
//! extern C symbols below, and `simd/dispatch.zig` gates every call behind
//! runtime CPUID/XGETBV support checks. The arithmetic inside is identical to
//! the four-lane portable kernels in `simd/vector.zig` instantiated at eight
//! lanes, so pixel results are bit-for-bit unchanged.
//!
//! This file lives at the src/ root because a Zig module cannot import files
//! outside its root path; the kernels need `surface.zig` and `simd/vector.zig`.
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

export fn zpu_v3_fill_span_8(row_ptr: [*]u8, row_len: usize, start: usize, count: usize, format_tag: u8, packed_color: u32) void {
    vector.fill(8, row_ptr[0..row_len], start, count, @enumFromInt(format_tag), unpackColor(packed_color));
}

export fn zpu_v3_blend_span_8(row_ptr: [*]u8, row_len: usize, start: usize, count: usize, format_tag: u8, packed_color: u32) void {
    vector.blend(8, row_ptr[0..row_len], start, count, @enumFromInt(format_tag), unpackColor(packed_color));
}

export fn zpu_v3_blend_pixels_8(row_ptr: [*]u8, row_len: usize, start: usize, source_ptr: [*]const u8, source_len: usize, count: usize, format_tag: u8) void {
    vector.blendPixels(8, row_ptr[0..row_len], start, source_ptr[0..source_len], count, @enumFromInt(format_tag));
}

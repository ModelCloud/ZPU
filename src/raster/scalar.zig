// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const s = @import("../surface.zig");

pub fn fillSpan(row: []u8, start_pixel: usize, count: usize, format: s.Format, color: s.Color) void {
    for (0..count) |i| s.Surface.write(row, (start_pixel + i) * 4, format, color);
}

fn div255(v: u32) u32 {
    return (v + 127) / 255;
}

pub fn blendPixel(dst: s.Color, src: s.Color) s.Color {
    const sa: u32 = src.a;
    const da: u32 = dst.a;
    const inv = 255 - sa;
    const out_a = sa + div255(da * inv);
    if (out_a == 0) return s.Color.rgba(0, 0, 0, 0);
    const blend = struct {
        fn channel(sc: u8, dc: u8, src_a: u32, dst_a: u32, inverse: u32, oa: u32) u8 {
            const premul = @as(u32, sc) * src_a + div255(@as(u32, dc) * dst_a * inverse);
            return @intCast((premul + oa / 2) / oa);
        }
    }.channel;
    return .rgba(blend(src.r, dst.r, sa, da, inv, out_a), blend(src.g, dst.g, sa, da, inv, out_a), blend(src.b, dst.b, sa, da, inv, out_a), @intCast(out_a));
}

pub fn blendSpan(row: []u8, start_pixel: usize, count: usize, format: s.Format, color: s.Color) void {
    for (0..count) |i| {
        const off = (start_pixel + i) * 4;
        s.Surface.write(row, off, format, blendPixel(s.Surface.read(row, off, format), color));
    }
}

/// Blend a tightly packed RGBA8 source span over a destination row. Keeping
/// this separate from the constant-color span gives texture/sprite callers a
/// scalar reference with the same rounding rules as the vector backends.
pub fn blendPixels(row: []u8, start_pixel: usize, source: []const u8, count: usize, format: s.Format) void {
    for (0..count) |i| {
        const source_offset = i * 4;
        const destination_offset = (start_pixel + i) * 4;
        const color = s.Color.rgba(source[source_offset], source[source_offset + 1], source[source_offset + 2], source[source_offset + 3]);
        s.Surface.write(row, destination_offset, format, blendPixel(s.Surface.read(row, destination_offset, format), color));
    }
}

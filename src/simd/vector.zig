// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const s = @import("../surface.zig");
const scalar = @import("../raster/scalar.zig");

fn div255Fast(comptime T: type, value: T) T {
    // All callers pass values <= 255*255. This is an exact strength
    // reduction of (value + 127) / 255 for that range.
    const shifted = value + @as(T, @splat(128));
    return (shifted + (shifted >> @as(T, @splat(8)))) >> @as(T, @splat(8));
}

// Pixel starts are always four-byte aligned relative to the surface/source
// base, but the public API accepts byte slices with only alignment-1 metadata.
// An explicitly unaligned word view lets optimized targets issue direct SIMD
// loads/stores without temporary stack arrays while remaining valid for every
// caller-provided slice.
fn loadNativePacked(comptime lanes: usize, bytes: []const u8, offset: usize) @Vector(lanes, u32) {
    const ptr: *align(1) const [lanes]u32 = @ptrCast(bytes.ptr + offset);
    const native: @Vector(lanes, u32) = @bitCast(ptr.*);
    return if (comptime builtin.cpu.arch.endian() == .little) native else @byteSwap(native);
}

fn storeNativePacked(comptime lanes: usize, bytes: []u8, offset: usize, values: @Vector(lanes, u32)) void {
    const ptr: *align(1) [lanes]u32 = @ptrCast(bytes.ptr + offset);
    const native = if (comptime builtin.cpu.arch.endian() == .little) values else @byteSwap(values);
    ptr.* = @bitCast(native);
}

fn storeNativeWord(bytes: []u8, offset: usize, value: u32) void {
    const ptr: *align(1) u32 = @ptrCast(bytes.ptr + offset);
    ptr.* = if (comptime builtin.cpu.arch.endian() == .little) value else @byteSwap(value);
}

/// Fill a span from an already packed native-order pixel. Keeping this
/// separate from the format-aware wrapper lets multi-row kernels compute the
/// color packing once per draw instead of once per scanline.
pub inline fn fillPacked(comptime lanes: usize, row: []u8, start: usize, count: usize, pixel_bits: u32) void {
    const V = @Vector(lanes, u32);
    const values: V = @splat(pixel_bits);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) storeNativePacked(lanes, row, (start + i) * 4, values);
    while (i < count) : (i += 1) storeNativeWord(row, (start + i) * 4, pixel_bits);
}

pub fn fill(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    const V = @Vector(lanes, u32);
    const pixel_bits: u32 = switch (format) {
        .rgba8_unorm => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24),
        .bgra8_unorm => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16) | (@as(u32, color.a) << 24),
    };
    const values: V = @splat(pixel_bits);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) storeNativePacked(lanes, row, (start + i) * 4, values);
    scalar.fillSpan(row, start + i, count - i, format, color);
}

pub inline fn blend(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    if (color.a == 0) return;
    if (color.a == 255) return fill(lanes, row, start, count, format, color);
    const V = @Vector(lanes, u32);
    const channel_mask: V = @splat(0xff);
    const sa: V = @splat(color.a);
    const inverse: V = @splat(255 - @as(u32, color.a));
    const half: V = @splat(127);
    const scale: V = @splat(255);
    // Source-over with a partially transparent color is idempotent once an
    // opaque destination already contains that color. This commonly occurs
    // in repeated compositing passes; recognize the stable packed value
    // before doing any channel arithmetic or issuing a store.
    const stable_bits: u32 = switch (format) {
        .rgba8_unorm => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | 0xff000000,
        .bgra8_unorm => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16) | 0xff000000,
    };
    const stable: V = @splat(stable_bits);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const destination_packed: V = loadNativePacked(lanes, row, (start + i) * 4);
        if (@reduce(.And, destination_packed == stable)) continue;
        const low = destination_packed & channel_mask;
        const dg = (destination_packed >> @as(V, @splat(8))) & channel_mask;
        const high = (destination_packed >> @as(V, @splat(16))) & channel_mask;
        const dva = destination_packed >> @as(V, @splat(24));
        const dr = if (format == .rgba8_unorm) low else high;
        const db = if (format == .rgba8_unorm) high else low;
        const destination_is_opaque = @reduce(.And, dva == @as(V, @splat(255)));
        const out_a = if (destination_is_opaque) @as(V, @splat(255)) else sa + div255Fast(V, dva * inverse);
        const divisor = @select(u32, out_a == @as(V, @splat(0)), @as(V, @splat(1)), out_a);
        const blendChannel = struct {
            fn run(dst: V, source: u8, src_a: V, dst_a: V, inv: V, rounding: V, divisor_scale: V, oa: V) V {
                const premul = @as(V, @splat(source)) * src_a + (dst * dst_a * inv + rounding) / divisor_scale;
                return (premul + oa / @as(V, @splat(2))) / oa;
            }
        }.run;
        const rr = if (destination_is_opaque) div255Fast(V, @as(V, @splat(color.r)) * sa + dr * inverse) else blendChannel(dr, color.r, sa, dva, inverse, half, scale, divisor);
        const rg = if (destination_is_opaque) div255Fast(V, @as(V, @splat(color.g)) * sa + dg * inverse) else blendChannel(dg, color.g, sa, dva, inverse, half, scale, divisor);
        const rb = if (destination_is_opaque) div255Fast(V, @as(V, @splat(color.b)) * sa + db * inverse) else blendChannel(db, color.b, sa, dva, inverse, half, scale, divisor);
        const packed_output = (if (format == .rgba8_unorm) rr | (rg << @as(V, @splat(8))) | (rb << @as(V, @splat(16))) else rb | (rg << @as(V, @splat(8))) | (rr << @as(V, @splat(16)))) | (out_a << @as(V, @splat(24)));
        storeNativePacked(lanes, row, (start + i) * 4, packed_output);
    }
    scalar.blendSpan(row, start + i, count - i, format, color);
}

pub inline fn blendPixels(comptime lanes: usize, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    const V = @Vector(lanes, u32);
    const channel_mask: V = @splat(0xff);
    const half: V = @splat(127);
    const scale: V = @splat(255);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const packed_source: V = loadNativePacked(lanes, source, i * 4);
        const sr = packed_source & channel_mask;
        const sg = (packed_source >> @as(V, @splat(8))) & channel_mask;
        const sb = (packed_source >> @as(V, @splat(16))) & channel_mask;
        const sva = packed_source >> @as(V, @splat(24));
        if (@reduce(.And, sva == @as(V, @splat(0)))) continue;
        if (@reduce(.And, sva == @as(V, @splat(255)))) {
            const packed_output = if (format == .rgba8_unorm)
                packed_source
            else
                sb | (sg << @as(V, @splat(8))) | (sr << @as(V, @splat(16))) | (sva << @as(V, @splat(24)));
            storeNativePacked(lanes, row, (start + i) * 4, packed_output);
            continue;
        }
        const packed_destination: V = loadNativePacked(lanes, row, (start + i) * 4);
        const destination_low = packed_destination & channel_mask;
        const dg = (packed_destination >> @as(V, @splat(8))) & channel_mask;
        const destination_high = (packed_destination >> @as(V, @splat(16))) & channel_mask;
        const dva = packed_destination >> @as(V, @splat(24));
        const dr = if (format == .rgba8_unorm) destination_low else destination_high;
        const db = if (format == .rgba8_unorm) destination_high else destination_low;
        const inverse = scale - sva;
        const destination_is_opaque = @reduce(.And, dva == @as(V, @splat(255)));
        const out_a = if (destination_is_opaque) @as(V, @splat(255)) else sva + div255Fast(V, dva * inverse);
        const divisor = @select(u32, out_a == @as(V, @splat(0)), @as(V, @splat(1)), out_a);
        const blendChannel = struct {
            fn run(src: V, dst: V, src_a: V, dst_a: V, inv: V, rounding: V, divisor_scale: V, oa: V) V {
                const premul = src * src_a + (dst * dst_a * inv + rounding) / divisor_scale;
                return (premul + oa / @as(V, @splat(2))) / oa;
            }
        }.run;
        const rr = if (destination_is_opaque) div255Fast(V, sr * sva + dr * inverse) else blendChannel(sr, dr, sva, dva, inverse, half, scale, divisor);
        const rg = if (destination_is_opaque) div255Fast(V, sg * sva + dg * inverse) else blendChannel(sg, dg, sva, dva, inverse, half, scale, divisor);
        const rb = if (destination_is_opaque) div255Fast(V, sb * sva + db * inverse) else blendChannel(sb, db, sva, dva, inverse, half, scale, divisor);
        const packed_output = (if (format == .rgba8_unorm) rr | (rg << @as(V, @splat(8))) | (rb << @as(V, @splat(16))) else rb | (rg << @as(V, @splat(8))) | (rr << @as(V, @splat(16)))) | (out_a << @as(V, @splat(24)));
        storeNativePacked(lanes, row, (start + i) * 4, packed_output);
    }
    scalar.blendPixels(row, start + i, source[i * 4 ..], count - i, format);
}

/// Blend a source span with binary alpha coverage. The vector path selects
/// between the unchanged destination and an opaque source pixel, avoiding the
/// source-over divides used by arbitrary-alpha textures.
pub fn blendPixelsBinary(comptime lanes: usize, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    const V = @Vector(lanes, u32);
    const channel_mask: V = @splat(0xff);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const packed_source: V = loadNativePacked(lanes, source, i * 4);
        const sr = packed_source & channel_mask;
        const sg = (packed_source >> @as(V, @splat(8))) & channel_mask;
        const sb = (packed_source >> @as(V, @splat(16))) & channel_mask;
        const sa = packed_source >> @as(V, @splat(24));
        const transparent_mask = sa == @as(V, @splat(0));
        const opaque_mask = sa == @as(V, @splat(255));
        if (@reduce(.And, transparent_mask)) continue;
        const packed_destination: V = loadNativePacked(lanes, row, (start + i) * 4);
        const source_as_destination = if (format == .rgba8_unorm)
            packed_source
        else
            sb | (sg << @as(V, @splat(8))) | (sr << @as(V, @splat(16))) | (sa << @as(V, @splat(24)));
        const packed_output = @select(u32, opaque_mask, source_as_destination, packed_destination);
        storeNativePacked(lanes, row, (start + i) * 4, packed_output);
    }
    scalar.blendPixelsBinary(row, start + i, source[i * 4 ..], count - i, format);
}

/// RGBA8 specialization of the binary-alpha span. Packed source and
/// destination pixels already share byte order, so no channel unpack/repack is
/// needed for mixed transparent/opaque SIMD groups.
pub fn blendPixelsBinaryRgba(comptime lanes: usize, row: []u8, start: usize, source: []const u8, count: usize) void {
    const V = @Vector(lanes, u32);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const packed_source: V = loadNativePacked(lanes, source, i * 4);
        const alpha = packed_source >> @as(V, @splat(24));
        const transparent = alpha == @as(V, @splat(0));
        const opaque_mask = alpha == @as(V, @splat(255));
        if (@reduce(.And, transparent)) continue;
        const packed_destination: V = loadNativePacked(lanes, row, (start + i) * 4);
        const packed_output = @select(u32, opaque_mask, packed_source, packed_destination);
        storeNativePacked(lanes, row, (start + i) * 4, packed_output);
    }
    scalar.blendPixelsBinary(row, start + i, source[i * 4 ..], count - i, .rgba8_unorm);
}

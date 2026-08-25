const builtin = @import("builtin");
const s = @import("../surface.zig");
const scalar = @import("../raster/scalar.zig");

fn nativePacked(comptime lanes: usize, bytes: [lanes * 4]u8) @Vector(lanes, u32) {
    const native: @Vector(lanes, u32) = @bitCast(bytes);
    return if (comptime builtin.cpu.arch.endian() == .little) native else @byteSwap(native);
}

fn packedBytes(comptime lanes: usize, values: @Vector(lanes, u32)) [lanes * 4]u8 {
    return @bitCast(if (comptime builtin.cpu.arch.endian() == .little) values else @byteSwap(values));
}

pub fn fill(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    const V = @Vector(lanes, u32);
    const pixel_bits: u32 = switch (format) {
        .rgba8_unorm => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24),
        .bgra8_unorm => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16) | (@as(u32, color.a) << 24),
    };
    const values: V = @splat(pixel_bits);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const bytes = packedBytes(lanes, values);
        @memcpy(row[(start + i) * 4 ..][0 .. lanes * 4], &bytes);
    }
    scalar.fillSpan(row, start + i, count - i, format, color);
}

pub fn blend(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    const V = @Vector(lanes, u32);
    const channel_mask: V = @splat(0xff);
    const sa: V = @splat(color.a);
    const inverse: V = @splat(255 - @as(u32, color.a));
    const half: V = @splat(127);
    const scale: V = @splat(255);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        var destination_bytes: [lanes * 4]u8 = undefined;
        @memcpy(&destination_bytes, row[(start + i) * 4 ..][0 .. lanes * 4]);
        const destination_packed: V = nativePacked(lanes, destination_bytes);
        const low = destination_packed & channel_mask;
        const dg = (destination_packed >> @as(V, @splat(8))) & channel_mask;
        const high = (destination_packed >> @as(V, @splat(16))) & channel_mask;
        const dva = destination_packed >> @as(V, @splat(24));
        const dr = if (format == .rgba8_unorm) low else high;
        const db = if (format == .rgba8_unorm) high else low;
        const out_a = sa + (dva * inverse + half) / scale;
        const divisor = @select(u32, out_a == @as(V, @splat(0)), @as(V, @splat(1)), out_a);
        const blendChannel = struct {
            fn run(dst: V, source: u8, src_a: V, dst_a: V, inv: V, rounding: V, divisor_scale: V, oa: V) V {
                const premul = @as(V, @splat(source)) * src_a + (dst * dst_a * inv + rounding) / divisor_scale;
                return (premul + oa / @as(V, @splat(2))) / oa;
            }
        }.run;
        const rr = blendChannel(dr, color.r, sa, dva, inverse, half, scale, divisor);
        const rg = blendChannel(dg, color.g, sa, dva, inverse, half, scale, divisor);
        const rb = blendChannel(db, color.b, sa, dva, inverse, half, scale, divisor);
        const packed_output = (if (format == .rgba8_unorm) rr | (rg << @as(V, @splat(8))) | (rb << @as(V, @splat(16))) else rb | (rg << @as(V, @splat(8))) | (rr << @as(V, @splat(16)))) | (out_a << @as(V, @splat(24)));
        const output_bytes = packedBytes(lanes, packed_output);
        @memcpy(row[(start + i) * 4 ..][0 .. lanes * 4], &output_bytes);
    }
    scalar.blendSpan(row, start + i, count - i, format, color);
}

pub fn blendPixels(comptime lanes: usize, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    const V = @Vector(lanes, u32);
    const channel_mask: V = @splat(0xff);
    const half: V = @splat(127);
    const scale: V = @splat(255);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        var source_bytes: [lanes * 4]u8 = undefined;
        var destination_bytes: [lanes * 4]u8 = undefined;
        @memcpy(&source_bytes, source[i * 4 ..][0 .. lanes * 4]);
        @memcpy(&destination_bytes, row[(start + i) * 4 ..][0 .. lanes * 4]);
        const packed_source: V = nativePacked(lanes, source_bytes);
        const packed_destination: V = nativePacked(lanes, destination_bytes);
        const sr = packed_source & channel_mask;
        const sg = (packed_source >> @as(V, @splat(8))) & channel_mask;
        const sb = (packed_source >> @as(V, @splat(16))) & channel_mask;
        const sva = packed_source >> @as(V, @splat(24));
        const destination_low = packed_destination & channel_mask;
        const dg = (packed_destination >> @as(V, @splat(8))) & channel_mask;
        const destination_high = (packed_destination >> @as(V, @splat(16))) & channel_mask;
        const dva = packed_destination >> @as(V, @splat(24));
        const dr = if (format == .rgba8_unorm) destination_low else destination_high;
        const db = if (format == .rgba8_unorm) destination_high else destination_low;
        const inverse = scale - sva;
        const out_a = sva + (dva * inverse + half) / scale;
        const divisor = @select(u32, out_a == @as(V, @splat(0)), @as(V, @splat(1)), out_a);
        const blendChannel = struct {
            fn run(src: V, dst: V, src_a: V, dst_a: V, inv: V, rounding: V, divisor_scale: V, oa: V) V {
                const premul = src * src_a + (dst * dst_a * inv + rounding) / divisor_scale;
                return (premul + oa / @as(V, @splat(2))) / oa;
            }
        }.run;
        const rr = blendChannel(sr, dr, sva, dva, inverse, half, scale, divisor);
        const rg = blendChannel(sg, dg, sva, dva, inverse, half, scale, divisor);
        const rb = blendChannel(sb, db, sva, dva, inverse, half, scale, divisor);
        const packed_output = (if (format == .rgba8_unorm) rr | (rg << @as(V, @splat(8))) | (rb << @as(V, @splat(16))) else rb | (rg << @as(V, @splat(8))) | (rr << @as(V, @splat(16)))) | (out_a << @as(V, @splat(24)));
        const output_bytes = packedBytes(lanes, packed_output);
        @memcpy(row[(start + i) * 4 ..][0 .. lanes * 4], &output_bytes);
    }
    scalar.blendPixels(row, start + i, source[i * 4 ..], count - i, format);
}

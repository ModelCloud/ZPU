const s = @import("../surface.zig");
const scalar = @import("../raster/scalar.zig");

pub fn fill(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    const V = @Vector(lanes, u32);
    const pixel_bits: u32 = switch (format) {
        .rgba8_unorm => @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24),
        .bgra8_unorm => @as(u32, color.b) | (@as(u32, color.g) << 8) | (@as(u32, color.r) << 16) | (@as(u32, color.a) << 24),
    };
    const values: V = @splat(pixel_bits);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        const bytes: [lanes * 4]u8 = @bitCast(values);
        @memcpy(row[(start + i) * 4 ..][0 .. lanes * 4], &bytes);
    }
    scalar.fillSpan(row, start + i, count - i, format, color);
}

pub fn blend(comptime lanes: usize, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    const V = @Vector(lanes, u32);
    const sa: V = @splat(color.a);
    const inverse: V = @splat(255 - @as(u32, color.a));
    const half: V = @splat(127);
    const scale: V = @splat(255);
    var i: usize = 0;
    while (i + lanes <= count) : (i += lanes) {
        var dr: [lanes]u32 = undefined;
        var dg: [lanes]u32 = undefined;
        var db: [lanes]u32 = undefined;
        var da: [lanes]u32 = undefined;
        for (0..lanes) |lane| {
            const dst = s.Surface.read(row, (start + i + lane) * 4, format);
            dr[lane] = dst.r;
            dg[lane] = dst.g;
            db[lane] = dst.b;
            da[lane] = dst.a;
        }
        const dva: V = da;
        const out_a = sa + (dva * inverse + half) / scale;
        const divisor = @select(u32, out_a == @as(V, @splat(0)), @as(V, @splat(1)), out_a);
        const blendChannel = struct {
            fn run(dst: V, source: u8, src_a: V, dst_a: V, inv: V, rounding: V, divisor_scale: V, oa: V) V {
                const premul = @as(V, @splat(source)) * src_a + (dst * dst_a * inv + rounding) / divisor_scale;
                return (premul + oa / @as(V, @splat(2))) / oa;
            }
        }.run;
        const rr: [lanes]u32 = blendChannel(dr, color.r, sa, dva, inverse, half, scale, divisor);
        const rg: [lanes]u32 = blendChannel(dg, color.g, sa, dva, inverse, half, scale, divisor);
        const rb: [lanes]u32 = blendChannel(db, color.b, sa, dva, inverse, half, scale, divisor);
        const ra: [lanes]u32 = out_a;
        for (0..lanes) |lane| s.Surface.write(row, (start + i + lane) * 4, format, .rgba(@intCast(rr[lane]), @intCast(rg[lane]), @intCast(rb[lane]), @intCast(ra[lane])));
    }
    scalar.blendSpan(row, start + i, count - i, format, color);
}

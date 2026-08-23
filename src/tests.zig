const std = @import("std");
const s = @import("surface.zig");
const raster = @import("raster/raster.zig");
const dispatch = @import("simd/dispatch.zig");

fn exercise(format: s.Format, seed: u64, backend: dispatch.Backend, actual: []u8, expected: []u8) !void {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    random.bytes(expected);
    @memcpy(actual, expected);
    var scalar_surface = try s.Surface.init(expected[3..], 37, 13, 153, format);
    var test_surface = try s.Surface.init(actual[3..], 37, 13, 153, format);
    const colors = [_]s.Color{ .rgba(1, 2, 3, 0), .rgba(255, 0, 128, 255), .rgba(13, 201, 77, 1), .rgba(240, 19, 91, 128), .rgba(7, 111, 222, 254) };
    const rects = [_]s.Rect{
        .{ .x = -9, .y = -3, .width = 17, .height = 8 },
        .{ .x = 1, .y = 1, .width = 1, .height = 1 },
        .{ .x = 3, .y = 2, .width = 7, .height = 4 },
        .{ .x = 5, .y = 5, .width = 17, .height = 3 },
        .{ .x = 0, .y = 0, .width = 37, .height = 13 },
        .{ .x = 34, .y = 10, .width = 19, .height = 9 },
        .{ .x = 80, .y = 80, .width = 4, .height = 4 },
    };
    for (rects, 0..) |rect, i| {
        raster.fillRectWith(&scalar_surface, rect, colors[i % colors.len], .scalar);
        raster.fillRectWith(&test_surface, rect, colors[i % colors.len], backend);
        raster.blendRectWith(&scalar_surface, rect, colors[(i + 2) % colors.len], .scalar);
        raster.blendRectWith(&test_surface, rect, colors[(i + 2) % colors.len], backend);
    }
    for (0..64) |_| {
        const rect = s.Rect{ .x = random.intRangeAtMost(i32, -20, 45), .y = random.intRangeAtMost(i32, -10, 18), .width = random.intRangeAtMost(u32, 0, 50), .height = random.intRangeAtMost(u32, 0, 20) };
        const color = s.Color.rgba(random.int(u8), random.int(u8), random.int(u8), random.int(u8));
        raster.blendRectWith(&scalar_surface, rect, color, .scalar);
        raster.blendRectWith(&test_surface, rect, color, backend);
    }
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "all SIMD-width backends match scalar exactly" {
    var expected: [3 + 153 * 13]u8 = undefined;
    var actual: [3 + 153 * 13]u8 = undefined;
    for ([_]s.Format{ .rgba8_unorm, .bgra8_unorm }) |format| {
        // Forced backend calls are safe: portable vectors are legalized for the build target.
        for ([_]dispatch.Backend{ .scalar, .avx2, .avx512 }) |backend| try exercise(format, 0x5a50555eed, backend, &actual, &expected);
    }
}

test "runtime selection never selects unavailable ISA" {
    const selected = dispatch.best();
    try std.testing.expect(dispatch.available(selected));
    if (!dispatch.available(.avx2)) try std.testing.expect(selected == .scalar);
}

test "surface validation and clipping" {
    var bytes: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidStride, s.Surface.init(&bytes, 2, 2, 7, .rgba8_unorm));
    try std.testing.expectEqual(s.Rect{ .x = 0, .y = 2, .width = 3, .height = 2 }, s.clip(.{ .x = -2, .y = 2, .width = 5, .height = 9 }, 8, 4).?);
}

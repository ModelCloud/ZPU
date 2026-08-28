// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

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
    var sprite: [33 * 9 * 4]u8 = undefined;
    random.bytes(&sprite);
    const alphas = [_]u8{ 0, 1, 128, 254, 255 };
    for (0..sprite.len / 4) |pixel| sprite[pixel * 4 + 3] = alphas[pixel % alphas.len];
    const sprites = [_]s.Rect{
        .{ .x = -5, .y = -3, .width = 17, .height = 9 },
        .{ .x = 3, .y = 2, .width = 1, .height = 1 },
        .{ .x = 7, .y = 4, .width = 7, .height = 5 },
        .{ .x = 9, .y = 1, .width = 8, .height = 4 },
        .{ .x = 5, .y = 6, .width = 9, .height = 3 },
        .{ .x = 2, .y = 10, .width = 16, .height = 2 },
        .{ .x = 18, .y = 8, .width = 17, .height = 6 },
        .{ .x = 31, .y = 15, .width = 33, .height = 7 },
    };
    for (sprites) |rect| {
        const source = sprite[0 .. @as(usize, rect.width) * rect.height * 4];
        raster.drawSpriteWith(&scalar_surface, rect, source, rect.width, rect.height, .scalar);
        raster.drawSpriteWith(&test_surface, rect, source, rect.width, rect.height, backend);
    }
    try std.testing.expectEqualSlices(u8, expected, actual);
}

test "all SIMD-width backends match scalar exactly" {
    var expected: [3 + 153 * 13]u8 = undefined;
    var actual: [3 + 153 * 13]u8 = undefined;
    for ([_]s.Format{ .rgba8_unorm, .bgra8_unorm }) |format| {
        // Forced backend calls are gated on runtime support: portable vectors
        // are legalized for the pinned baseline artifact target and the
        // eight-lane tier lives in separately compiled x86-64-v3 kernels.
        for ([_]dispatch.Backend{ .scalar, .portable_vector, .avx2 }) |backend| {
            if (dispatch.available(backend)) try exercise(format, 0x5a50555eed, backend, &actual, &expected);
        }
    }
}

test "runtime selection never selects unavailable ISA" {
    const selected = dispatch.best();
    try std.testing.expect(dispatch.available(selected));
    if (!dispatch.available(.avx2)) try std.testing.expect(selected == .portable_vector);
}

test "every alignment lane tail format and blend boundary is differential" {
    var scalar_storage: [16 + 64 * 4 + 16]u8 = undefined;
    var test_storage: [16 + 64 * 4 + 16]u8 = undefined;
    var source: [64 * 4]u8 = undefined;
    var prng = std.Random.DefaultPrng.init(0xd1ff_2d5e_ed00_0001);
    const random = prng.random();
    random.bytes(&source);
    const alphas = [_]u8{ 0, 1, 127, 128, 254, 255 };
    for (0..64) |i| source[i * 4 + 3] = alphas[i % alphas.len];
    const colors = [_]s.Color{ .rgba(0, 0, 0, 0), .rgba(1, 2, 3, 1), .rgba(17, 91, 203, 127), .rgba(240, 19, 77, 128), .rgba(254, 253, 252, 254), .rgba(255, 255, 255, 255) };
    for ([_]s.Format{ .rgba8_unorm, .bgra8_unorm }) |format| {
        for ([_]dispatch.Backend{ .portable_vector, .avx2 }) |backend| {
            if (!dispatch.available(backend)) continue;
            for (0..16) |alignment| for (0..34) |count| {
                random.bytes(&scalar_storage);
                @memcpy(&test_storage, &scalar_storage);
                const scalar_row = scalar_storage[alignment .. alignment + 64 * 4];
                const test_row = test_storage[alignment .. alignment + 64 * 4];
                const start = (alignment * 7) % (64 - count + 1);
                for (colors) |color| {
                    dispatch.fillSpan(.scalar, scalar_row, start, count, format, color);
                    dispatch.fillSpan(backend, test_row, start, count, format, color);
                    dispatch.blendSpan(.scalar, scalar_row, start, count, format, color);
                    dispatch.blendSpan(backend, test_row, start, count, format, color);
                }
                dispatch.blendPixels(.scalar, scalar_row, start, &source, count, format);
                dispatch.blendPixels(backend, test_row, start, &source, count, format);
                try std.testing.expectEqualSlices(u8, &scalar_storage, &test_storage);
            };
        }
    }
}

test "normal raster entry points use a deterministic kernel cache" {
    var pixels = [_]u8{0} ** (8 * 8 * 4);
    var surface = try s.Surface.init(&pixels, 8, 8, 32, .rgba8_unorm);
    raster.resetKernelCache();
    raster.fillRect(&surface, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, .rgba(1, 2, 3, 255));
    raster.fillRect(&surface, .{ .x = 1, .y = 1, .width = 2, .height = 2 }, .rgba(4, 5, 6, 255));
    raster.blendRect(&surface, .{ .x = 0, .y = 0, .width = 1, .height = 1 }, .rgba(7, 8, 9, 128));
    const stats = raster.kernelCacheStats();
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 2), stats.misses);
}

test "surface validation and clipping" {
    var bytes: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidStride, s.Surface.init(&bytes, 2, 2, 7, .rgba8_unorm));
    try std.testing.expectEqual(s.Rect{ .x = 0, .y = 2, .width = 3, .height = 2 }, s.clip(.{ .x = -2, .y = 2, .width = 5, .height = 9 }, 8, 4).?);
}

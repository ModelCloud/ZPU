// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");
const config = @import("zpu_config");
const abi = @import("kernel_abi.zig");
const s = @import("../surface.zig");
const scalar = @import("../raster/scalar.zig");
const vector = @import("vector.zig");

/// ISA tiers, truthfully:
/// - `scalar`: no data-parallel assumption at all.
/// - `portable_vector`: four-pixel `@Vector` kernels compiled for the artifact
///   target. `build.zig` pins default builds to the x86-64 baseline CPU model,
///   so this tier cannot emit AVX2, AVX-512, or any other VEX-encoded
///   instruction; a `-Dcpu` override is an explicit opt into a higher tier.
/// - `avx2`: eight-pixel kernels compiled as a separate x86-64-v3 static
///   library (see `simd/x86_64_v3.zig` and `build.zig`) that baseline codegen
///   only reaches through the extern symbols below after the runtime
///   CPU/OS support checks in `available`.
/// AVX-512 remains excluded pending controlled frame-time-tail evidence.
pub const Backend = enum { scalar, portable_vector, avx2 };
pub const SpriteRegion = struct { destination: s.Rect, source: s.Rect };
pub const RectColorCommand = abi.RectColorCommand;

/// Comptime-known availability of the separately compiled eight-lane kernel
/// objects for this artifact. True exactly when `build.zig` linked the
/// x86-64-v3 kernel library (x86_64 artifact target and `-Dv3-kernels`, which
/// defaults to on; `-Dv3-kernels=false` produces kernel-free artifacts).
pub const eight_lane_boundary = config.v3_kernels and builtin.cpu.arch == .x86_64;

/// Pure decision function over probed CPU/OS bits: OSXSAVE and AVX state from
/// leaf 1, XCR0 must enable both YMM state slots, and leaf 7 must report AVX2.
pub fn decodeAvx2Support(osxsave: bool, avx: bool, xcr0: u64, leaf7_avx2: bool) bool {
    return osxsave and avx and (xcr0 & 0x6) == 0x6 and leaf7_avx2;
}

var probed_support = std.atomic.Value(u8).init(0);

fn probeAvx2() bool {
    return switch (probed_support.load(.acquire)) {
        1 => false,
        2 => true,
        else => {
            const supported = blk: {
                if (!eight_lane_boundary) break :blk false;
                const leaf1 = cpuid(1, 0);
                const leaf7 = cpuid(7, 0);
                break :blk decodeAvx2Support(
                    leaf1.c & (1 << 27) != 0,
                    leaf1.c & (1 << 28) != 0,
                    xgetbv(),
                    leaf7.b & (1 << 5) != 0,
                );
            };
            probed_support.store(if (supported) 2 else 1, .release);
            return supported;
        },
    };
}

pub fn available(backend: Backend) bool {
    return switch (backend) {
        .scalar, .portable_vector => true,
        .avx2 => probeAvx2(),
    };
}

pub fn best() Backend {
    if (available(.avx2)) return .avx2;
    return .portable_vector;
}

const v3 = struct {
    const fill_span_8: abi.FillSpan8Fn = @extern(abi.FillSpan8Fn, .{ .name = abi.fill_span_8_name });
    const blend_span_8: abi.BlendSpan8Fn = @extern(abi.BlendSpan8Fn, .{ .name = abi.blend_span_8_name });
    const blend_pixels_8: abi.BlendPixels8Fn = @extern(abi.BlendPixels8Fn, .{ .name = abi.blend_pixels_8_name });
    const fill_rows_8: abi.FillRows8Fn = @extern(abi.FillRows8Fn, .{ .name = abi.fill_rows_8_name });
    const blend_rows_8: abi.BlendRows8Fn = @extern(abi.BlendRows8Fn, .{ .name = abi.blend_rows_8_name });
    const blend_pixels_rows_8: abi.BlendPixelsRows8Fn = @extern(abi.BlendPixelsRows8Fn, .{ .name = abi.blend_pixels_rows_8_name });
    const fill_rects_8: abi.FillRects8Fn = @extern(abi.FillRects8Fn, .{ .name = abi.fill_rects_8_name });
    const blend_sprite_batch_8: abi.BlendSpriteBatch8Fn = @extern(abi.BlendSpriteBatch8Fn, .{ .name = abi.blend_sprite_batch_8_name });
};

/// Linkage consistency proof (build-time): an artifact whose comptime
/// configuration claims eight-lane capability must physically contain the
/// kernel objects. Materializing the extern function pointers as runtime data
/// forces symbol resolution, making a missing or misconfigured kernel library
/// a hard link error instead of a latent unsupported-instruction fault.
/// Conversely, when this flag is false the symbols are never referenced, so
/// kernel-free artifacts cannot carry them (asserted by the disassembly
/// gate's `--no-kernel-symbols` mode).
const linkage_proof = if (eight_lane_boundary)
    [8]*const anyopaque{
        @ptrCast(v3.fill_span_8),
        @ptrCast(v3.blend_span_8),
        @ptrCast(v3.blend_pixels_8),
        @ptrCast(v3.fill_rows_8),
        @ptrCast(v3.blend_rows_8),
        @ptrCast(v3.blend_pixels_rows_8),
        @ptrCast(v3.fill_rects_8),
        @ptrCast(v3.blend_sprite_batch_8),
    }
else
    [0]*const anyopaque{};

test "boundary claim matches linked kernel symbols" {
    try std.testing.expectEqual(eight_lane_boundary, linkage_proof.len != 0);
}

fn packColor(color: s.Color) u32 {
    return @as(u32, color.r) | (@as(u32, color.g) << 8) | (@as(u32, color.b) << 16) | (@as(u32, color.a) << 24);
}

/// Tripwire making unsupported eight-lane execution loud instead of silently
/// wrong: every entry point selects `.avx2` only through `available`, so this
/// can only fire on caller misuse.
fn requireEightLaneSupport() void {
    if (!available(.avx2)) @panic("eight-lane AVX2 kernel reached without runtime CPU/OS support checks");
}

pub fn fillSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.fillSpan(row, start, count, format, color),
        .portable_vector => vector.fill(4, row, start, count, format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.fill_span_8(row.ptr, row.len, start, count, @intFromEnum(format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}
pub fn blendSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.blendSpan(row, start, count, format, color),
        .portable_vector => vector.blend(4, row, start, count, format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.blend_span_8(row.ptr, row.len, start, count, @intFromEnum(format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Blend a span after the caller has verified that every destination pixel is
/// opaque. The AVX2 entry keeps the existing ABI symbol and marks the private
/// format-tag bit so the kernel can select its division-free arithmetic.
pub fn blendOpaqueSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.blendSpan(row, start, count, format, color),
        .portable_vector => vector.blendOpaque(4, row, start, count, format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.blend_span_8(row.ptr, row.len, start, count, @intFromEnum(format) | abi.opaque_format_bit, packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Fill every row in a clipped rectangle after selecting the backend once.
/// This keeps tiny/partial rectangles from paying an ISA probe and dispatch
/// switch for each scanline (notably the many narrow guides in design tools).
pub fn fillRows(comptime backend: Backend, surface: *s.Surface, rectangle: s.Rect, color: s.Color) void {
    switch (backend) {
        .scalar => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            scalar.fillSpan(surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .portable_vector => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            vector.fill(4, surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            const row_offset = std.math.mul(usize, @as(usize, @intCast(rectangle.y)), surface.stride) catch unreachable;
            v3.fill_rows_8(surface.pixels.ptr + row_offset, surface.pixels.len - row_offset, surface.stride, @intCast(rectangle.x), rectangle.width, rectangle.height, @intFromEnum(surface.format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Blend every row in a clipped rectangle after selecting the backend once.
/// The ABI kernels remain row-oriented, but the safety probe and backend
/// selection now happen once per rectangle rather than once per row.
pub fn blendRows(comptime backend: Backend, surface: *s.Surface, rectangle: s.Rect, color: s.Color) void {
    switch (backend) {
        .scalar => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            scalar.blendSpan(surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .portable_vector => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            vector.blend(4, surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            const row_offset = std.math.mul(usize, @as(usize, @intCast(rectangle.y)), surface.stride) catch unreachable;
            v3.blend_rows_8(surface.pixels.ptr + row_offset, surface.pixels.len - row_offset, surface.stride, @intCast(rectangle.x), rectangle.width, rectangle.height, @intFromEnum(surface.format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Runtime-backend wrapper for public clipped-rectangle APIs. Keeping the
/// backend switch in one dispatch function avoids cloning the row loop at
/// every raster call while still validating the AVX2 boundary exactly once.
pub fn fillRowsRuntime(backend: Backend, surface: *s.Surface, rectangle: s.Rect, color: s.Color) void {
    switch (backend) {
        .scalar => fillRows(.scalar, surface, rectangle, color),
        .portable_vector => fillRows(.portable_vector, surface, rectangle, color),
        .avx2 => fillRows(.avx2, surface, rectangle, color),
    }
}

pub fn blendRowsRuntime(backend: Backend, surface: *s.Surface, rectangle: s.Rect, color: s.Color) void {
    switch (backend) {
        .scalar => blendRows(.scalar, surface, rectangle, color),
        .portable_vector => blendRows(.portable_vector, surface, rectangle, color),
        .avx2 => blendRows(.avx2, surface, rectangle, color),
    }
}

pub fn blendOpaqueRows(comptime backend: Backend, surface: *s.Surface, rectangle: s.Rect, color: s.Color) void {
    switch (backend) {
        .scalar => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            scalar.blendSpan(surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .portable_vector => for (@intCast(rectangle.y)..@as(usize, @intCast(rectangle.y)) + rectangle.height) |y|
            vector.blendOpaque(4, surface.row(@intCast(y)), @intCast(rectangle.x), rectangle.width, surface.format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            const row_offset = std.math.mul(usize, @as(usize, @intCast(rectangle.y)), surface.stride) catch unreachable;
            v3.blend_rows_8(surface.pixels.ptr + row_offset, surface.pixels.len - row_offset, surface.stride, @intCast(rectangle.x), rectangle.width, rectangle.height, @intFromEnum(surface.format) | abi.opaque_format_bit, packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Submit a batch of fully in-bounds rectangle fills through one validated
/// AVX2 ABI call. The command layout is shared with raster.ColoredRect, so
/// draw order and per-command colors remain unchanged.
pub fn fillRects8(surface: *s.Surface, draws: []const RectColorCommand) void {
    if (comptime eight_lane_boundary) {
        requireEightLaneSupport();
        v3.fill_rects_8(surface.pixels.ptr, surface.pixels.len, surface.stride, draws.ptr, draws.len, @intFromEnum(surface.format));
    } else @panic("eight-lane kernels require an x86_64 artifact target");
}

/// Reuse the validated rectangle ABI for an in-bounds opaque-destination
/// source-over batch. The private format bit selects blending in the kernel;
/// no new exported symbol or ISA gate is required.
pub fn blendOpaqueRects8(surface: *s.Surface, draws: []const RectColorCommand) void {
    if (comptime eight_lane_boundary) {
        requireEightLaneSupport();
        v3.fill_rects_8(surface.pixels.ptr, surface.pixels.len, surface.stride, draws.ptr, draws.len, @intFromEnum(surface.format) | abi.opaque_format_bit);
    } else @panic("eight-lane kernels require an x86_64 artifact target");
}

pub fn blendSpriteBatch8(surface: *s.Surface, commands: []const abi.SpriteCommand, source: []const u8, source_stride: usize, opaque_destination: bool, binary_alpha: bool) void {
    if (comptime eight_lane_boundary) {
        requireEightLaneSupport();
        const format_tag = @intFromEnum(surface.format) |
            (if (opaque_destination) abi.opaque_format_bit else 0) |
            (if (binary_alpha) abi.binary_alpha_format_bit else 0);
        v3.blend_sprite_batch_8(surface.pixels.ptr, surface.pixels.len, surface.stride, commands.ptr, commands.len, source.ptr, source.len, source_stride, format_tag);
    } else @panic("eight-lane kernels require an x86_64 artifact target");
}

pub fn blendPixels(backend: Backend, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    switch (backend) {
        .scalar => scalar.blendPixels(row, start, source, count, format),
        .portable_vector => vector.blendPixels(4, row, start, source, count, format),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.blend_pixels_8(row.ptr, row.len, start, source.ptr, source.len, count, @intFromEnum(format));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Blend source pixels over a caller-proven opaque destination. The private
/// ABI tag keeps this on the existing eight-lane symbol while selecting the
/// division-free opaque-destination kernel.
pub fn blendPixelsOpaque(backend: Backend, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    switch (backend) {
        .scalar => scalar.blendPixels(row, start, source, count, format),
        .portable_vector => vector.blendPixelsOpaque(4, row, start, source, count, format),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.blend_pixels_8(row.ptr, row.len, start, source.ptr, source.len, count, @intFromEnum(format) | abi.opaque_format_bit);
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Blend a clipped multi-row sprite while selecting the backend once. The
/// kernel ABI is row-oriented, so this keeps the per-row calls but removes the
/// repeated backend switch from the raster hot path.
pub fn blendPixelsRows(backend: Backend, surface: *s.Surface, destination: s.Rect, source: []const u8, source_width: u32, source_x: usize, source_y: usize) void {
    switch (backend) {
        .scalar => for (0..destination.height) |dy| {
            const source_offset = ((source_y + dy) * source_width + source_x) * 4;
            scalar.blendPixels(surface.row(@intCast(@as(usize, @intCast(destination.y)) + dy)), @intCast(destination.x), source[source_offset..], destination.width, surface.format);
        },
        .portable_vector => for (0..destination.height) |dy| {
            const source_offset = ((source_y + dy) * source_width + source_x) * 4;
            vector.blendPixels(4, surface.row(@intCast(@as(usize, @intCast(destination.y)) + dy)), @intCast(destination.x), source[source_offset..], destination.width, surface.format);
        },
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            const destination_offset = std.math.mul(usize, @as(usize, @intCast(destination.y)), surface.stride) catch unreachable;
            const source_offset = std.math.mul(usize, std.math.add(usize, std.math.mul(usize, source_y, source_width) catch unreachable, source_x) catch unreachable, 4) catch unreachable;
            v3.blend_pixels_rows_8(surface.pixels.ptr + destination_offset, surface.pixels.len - destination_offset, surface.stride, source.ptr + source_offset, source.len - source_offset, @as(usize, source_width) * 4, @intCast(destination.x), destination.width, destination.height, @intFromEnum(surface.format));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Batch sprite rows with one backend selection. Clipping remains per sprite,
/// but all sprites in the batch use the same already-validated source and
/// backend route.
pub fn blendPixelsRowsBatch(backend: Backend, surface: *s.Surface, destinations: []const s.Rect, source: []const u8, source_width: u32, source_height: u32) void {
    switch (backend) {
        .scalar => for (destinations) |destination| {
            if (destination.width != source_width or destination.height != source_height) continue;
            const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
            const source_x: usize = @intCast(clipped.x - destination.x);
            const source_y: usize = @intCast(clipped.y - destination.y);
            for (0..clipped.height) |dy| {
                const source_offset = ((source_y + dy) * source_width + source_x) * 4;
                scalar.blendPixels(surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
            }
        },
        .portable_vector => for (destinations) |destination| {
            if (destination.width != source_width or destination.height != source_height) continue;
            const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
            const source_x: usize = @intCast(clipped.x - destination.x);
            const source_y: usize = @intCast(clipped.y - destination.y);
            for (0..clipped.height) |dy| {
                const source_offset = ((source_y + dy) * source_width + source_x) * 4;
                vector.blendPixels(4, surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
            }
        },
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            if (destinations.len >= 2 and destinations.len <= 256) {
                var commands: [256]abi.SpriteCommand = undefined;
                var command_count: usize = 0;
                for (destinations) |destination| {
                    if (destination.width != source_width or destination.height != source_height) continue;
                    const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
                    commands[command_count] = .{
                        .x = clipped.x,
                        .y = clipped.y,
                        .source_x = @intCast(clipped.x - destination.x),
                        .source_y = @intCast(clipped.y - destination.y),
                        .width = clipped.width,
                        .height = clipped.height,
                    };
                    command_count += 1;
                }
                if (command_count >= 2) {
                    blendSpriteBatch8(surface, commands[0..command_count], source, @as(usize, source_width) * 4, false, false);
                    return;
                }
            }
            for (destinations) |destination| {
                if (destination.width != source_width or destination.height != source_height) continue;
                const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
                const source_x: usize = @intCast(clipped.x - destination.x);
                const source_y: usize = @intCast(clipped.y - destination.y);
                const destination_offset = std.math.mul(usize, @as(usize, @intCast(clipped.y)), surface.stride) catch unreachable;
                const source_offset = std.math.mul(usize, std.math.add(usize, std.math.mul(usize, source_y, source_width) catch unreachable, source_x) catch unreachable, 4) catch unreachable;
                v3.blend_pixels_rows_8(surface.pixels.ptr + destination_offset, surface.pixels.len - destination_offset, surface.stride, source.ptr + source_offset, source.len - source_offset, @as(usize, source_width) * 4, @intCast(clipped.x), clipped.width, clipped.height, @intFromEnum(surface.format));
            }
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Batch same-sized sprites over a destination known to be opaque. Clipping
/// and source-origin handling intentionally mirror blendPixelsRowsBatch.
pub fn blendPixelsRowsOpaqueBatch(backend: Backend, surface: *s.Surface, destinations: []const s.Rect, source: []const u8, source_width: u32, source_height: u32) void {
    switch (backend) {
        .scalar => blendPixelsRowsBatch(.scalar, surface, destinations, source, source_width, source_height),
        .portable_vector => for (destinations) |destination| {
            if (destination.width != source_width or destination.height != source_height) continue;
            const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
            const source_x: usize = @intCast(clipped.x - destination.x);
            const source_y: usize = @intCast(clipped.y - destination.y);
            for (0..clipped.height) |dy| {
                const source_offset = ((source_y + dy) * source_width + source_x) * 4;
                vector.blendPixelsOpaque(4, surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
            }
        },
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            if (destinations.len >= 2 and destinations.len <= 256) {
                var commands: [256]abi.SpriteCommand = undefined;
                var command_count: usize = 0;
                for (destinations) |destination| {
                    if (destination.width != source_width or destination.height != source_height) continue;
                    const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
                    commands[command_count] = .{
                        .x = clipped.x,
                        .y = clipped.y,
                        .source_x = @intCast(clipped.x - destination.x),
                        .source_y = @intCast(clipped.y - destination.y),
                        .width = clipped.width,
                        .height = clipped.height,
                    };
                    command_count += 1;
                }
                if (command_count >= 2) {
                    blendSpriteBatch8(surface, commands[0..command_count], source, @as(usize, source_width) * 4, true, false);
                    return;
                }
            }
            for (destinations) |destination| {
                if (destination.width != source_width or destination.height != source_height) continue;
                const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
                const source_x: usize = @intCast(clipped.x - destination.x);
                const source_y: usize = @intCast(clipped.y - destination.y);
                const destination_offset = std.math.mul(usize, @as(usize, @intCast(clipped.y)), surface.stride) catch unreachable;
                const source_offset = std.math.mul(usize, std.math.add(usize, std.math.mul(usize, source_y, source_width) catch unreachable, source_x) catch unreachable, 4) catch unreachable;
                v3.blend_pixels_rows_8(surface.pixels.ptr + destination_offset, surface.pixels.len - destination_offset, surface.stride, source.ptr + source_offset, source.len - source_offset, @as(usize, source_width) * 4, @intCast(clipped.x), clipped.width, clipped.height, @intFromEnum(surface.format) | abi.opaque_format_bit);
            }
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

/// Batch atlas sprites with one backend route. Each source rectangle must be
/// in the immutable atlas and match its destination dimensions; destination
/// clipping advances the source origin exactly like drawSprite.
pub fn blendPixelsRowsRegionsBatch(backend: Backend, surface: *s.Surface, regions: []const SpriteRegion, source: []const u8, source_width: u32, source_height: u32, binary_alpha: bool) void {
    switch (backend) {
        .scalar => for (regions) |region| {
            const destination = region.destination;
            const source_rect = region.source;
            if (source_rect.x < 0 or source_rect.y < 0) continue;
            const sx: u32 = @intCast(source_rect.x);
            const sy: u32 = @intCast(source_rect.y);
            if (sx > source_width or sy > source_height or source_rect.width > source_width - sx or source_rect.height > source_height - sy) continue;
            if (destination.width != source_rect.width or destination.height != source_rect.height) continue;
            const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
            const source_x: usize = @intCast(source_rect.x + (clipped.x - destination.x));
            const source_y: usize = @intCast(source_rect.y + (clipped.y - destination.y));
            for (0..clipped.height) |dy| {
                const source_offset = ((source_y + dy) * source_width + source_x) * 4;
                if (binary_alpha) scalar.blendPixelsBinary(surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format) else scalar.blendPixels(surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
            }
        },
        .portable_vector => for (regions) |region| {
            const destination = region.destination;
            const source_rect = region.source;
            if (source_rect.x < 0 or source_rect.y < 0) continue;
            const sx: u32 = @intCast(source_rect.x);
            const sy: u32 = @intCast(source_rect.y);
            if (sx > source_width or sy > source_height or source_rect.width > source_width - sx or source_rect.height > source_height - sy) continue;
            if (destination.width != source_rect.width or destination.height != source_rect.height) continue;
            const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
            const source_x: usize = @intCast(source_rect.x + (clipped.x - destination.x));
            const source_y: usize = @intCast(source_rect.y + (clipped.y - destination.y));
            for (0..clipped.height) |dy| {
                const source_offset = ((source_y + dy) * source_width + source_x) * 4;
                if (binary_alpha) {
                    if (surface.format == .rgba8_unorm) vector.blendPixelsBinaryRgba(4, surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width) else vector.blendPixelsBinary(4, surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
                } else vector.blendPixels(4, surface.row(@intCast(@as(usize, @intCast(clipped.y)) + dy)), @intCast(clipped.x), source[source_offset..], clipped.width, surface.format);
            }
        },
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            // Atlas draws have independent source origins, so the fixed-size
            // sprite batch path is the only way to avoid one ABI call per
            // glyph. Flush bounded command chunks to keep stack usage fixed
            // while preserving the original draw order across chunks.
            var commands: [256]abi.SpriteCommand = undefined;
            var command_count: usize = 0;
            for (regions) |region| {
                const destination = region.destination;
                const source_rect = region.source;
                if (source_rect.x < 0 or source_rect.y < 0) continue;
                const sx: u32 = @intCast(source_rect.x);
                const sy: u32 = @intCast(source_rect.y);
                if (sx > source_width or sy > source_height or source_rect.width > source_width - sx or source_rect.height > source_height - sy) continue;
                if (destination.width != source_rect.width or destination.height != source_rect.height) continue;
                const clipped = s.clip(destination, surface.width, surface.height) orelse continue;
                const source_x: usize = @intCast(source_rect.x + (clipped.x - destination.x));
                const source_y: usize = @intCast(source_rect.y + (clipped.y - destination.y));
                commands[command_count] = .{
                    .x = clipped.x,
                    .y = clipped.y,
                    .source_x = @intCast(source_x),
                    .source_y = @intCast(source_y),
                    .width = clipped.width,
                    .height = clipped.height,
                };
                command_count += 1;
                if (command_count == commands.len) {
                    blendSpriteBatch8(surface, commands[0..command_count], source, @as(usize, source_width) * 4, false, binary_alpha);
                    command_count = 0;
                }
            }
            if (command_count != 0) blendSpriteBatch8(surface, commands[0..command_count], source, @as(usize, source_width) * 4, false, binary_alpha);
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}

test "avx2 decode requires every CPU and OS precondition" {
    try std.testing.expect(!decodeAvx2Support(false, true, 0b110, true));
    try std.testing.expect(!decodeAvx2Support(true, false, 0b110, true));
    try std.testing.expect(!decodeAvx2Support(true, true, 0b010, true));
    try std.testing.expect(!decodeAvx2Support(true, true, 0b1000, true));
    try std.testing.expect(!decodeAvx2Support(true, true, 0b110, false));
    try std.testing.expect(decodeAvx2Support(true, true, 0b110, true));
}

test "eight-lane tier is bounded by the linked kernel boundary" {
    if (comptime eight_lane_boundary) {
        try std.testing.expect(available(.avx2) == probeAvx2());
    } else {
        try std.testing.expect(!available(.avx2));
        try std.testing.expect(best() != .avx2);
    }
    try std.testing.expect(available(.scalar));
    try std.testing.expect(available(.portable_vector));
    try std.testing.expect(available(best()));
}

test "runtime selection never selects unavailable ISA" {
    const selected = best();
    try std.testing.expect(available(selected));
    if (!available(.avx2)) try std.testing.expect(selected == .portable_vector);
}

const Cpuid = struct { a: u32, b: u32, c: u32, d: u32 };
fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var a: u32 = leaf;
        var b: u32 = undefined;
        var c: u32 = subleaf;
        var d: u32 = undefined;
        asm volatile ("cpuid"
            : [a] "+{eax}" (a),
              [b] "={ebx}" (b),
              [c] "+{ecx}" (c),
              [d] "={edx}" (d),
            :
            : .{ .memory = true });
        return .{ .a = a, .b = b, .c = c, .d = d };
    } else return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
}
fn xgetbv() u64 {
    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var eax: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("xgetbv"
            : [eax] "={eax}" (eax),
              [edx] "={edx}" (edx),
            : [ecx] "{ecx}" (@as(u32, 0)),
        );
        return (@as(u64, edx) << 32) | eax;
    } else return 0;
}

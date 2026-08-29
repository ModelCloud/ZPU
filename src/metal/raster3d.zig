// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Small, deterministic CPU rasterizer for the native Metal-facing ABI.
//!
//! Work is split into two non-overlapping screen bands. The calling thread
//! owns one band and a single worker owns the other, so a 3D submission never
//! creates more than two rendering lanes and no pixel/depth lock is needed.

const std = @import("std");
const abi = @import("abi.zig");
const surface = @import("../surface.zig");
const raster = @import("../raster/raster.zig");

pub const Stats = struct {
    primitives_submitted: u64 = 0,
    primitives_rasterized: u64 = 0,
    fragments_tested: u64 = 0,
    fragments_covered: u64 = 0,
    depth_tests_passed: u64 = 0,
    color_writes: u64 = 0,
};

const ProjectedVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    inverse_w: f32,
    color: [4]f32,
};

pub const DrawOptions = struct {
    viewport: abi.Viewport,
    scissor: abi.ScissorRect,
    cull_mode: abi.CullMode = .none,
    winding: abi.Winding = .clockwise,
    fill_mode: abi.TriangleFillMode = .fill,
    depth_clip_mode: abi.DepthClipMode = .clip,
    depth_bias: f32 = 0,
    slope_scale: f32 = 0,
    depth_bias_clamp: f32 = 0,
    depth_test_min_bound: f32 = 0,
    depth_test_max_bound: f32 = 1,
    fragment_color: ?[4]f32 = null,
    sample_min_filter: abi.SamplerFilter = .nearest,
    sample_mag_filter: abi.SamplerFilter = .nearest,
    sample_mip_filter: abi.SamplerMipFilter = .not_mipmapped,
    sample_lod_min_clamp: f32 = 0,
    sample_lod_max_clamp: f32 = std.math.floatMax(f32),
    sample_lod_bias: f32 = 0,
    sample_max_anisotropy: u32 = 1,
    sample_normalized_coordinates: bool = true,
    sample_reduction_mode: abi.SamplerReductionMode = .weighted_average,
    sample_address_s: abi.SamplerAddressMode = .clamp_to_edge,
    sample_address_t: abi.SamplerAddressMode = .clamp_to_edge,
    sample_border_color: abi.SamplerBorderColor = .transparent_black,
    sample_swizzle: abi.TextureSwizzleChannels = .{
        .red = .red,
        .green = .green,
        .blue = .blue,
        .alpha = .alpha,
    },
    rasterization_enabled: bool = true,
    depth_compare: abi.CompareFunction = .less_equal,
    depth_write_enabled: bool = true,
    blending_enabled: bool = false,
    source_rgb_factor: abi.BlendFactor = .one,
    destination_rgb_factor: abi.BlendFactor = .zero,
    rgb_operation: abi.BlendOperation = .add,
    source_alpha_factor: abi.BlendFactor = .one,
    destination_alpha_factor: abi.BlendFactor = .zero,
    alpha_operation: abi.BlendOperation = .add,
    color_write_mask: u8 = @intFromEnum(abi.ColorWriteMask.all),
    write_extra_targets: bool = false,
    blend_color: [4]f32 = .{ 0, 0, 0, 0 },
    stencil_front: StencilFace = .{},
    stencil_back: StencilFace = .{},
};

pub const StencilFace = struct {
    compare: abi.CompareFunction = .always,
    stencil_failure: abi.StencilOperation = .keep,
    depth_failure: abi.StencilOperation = .keep,
    depth_pass: abi.StencilOperation = .keep,
    read_mask: u8 = 0xff,
    write_mask: u8 = 0xff,
    reference: u8 = 0,
};

pub const TargetFormat = enum {
    a8_unorm,
    r8_unorm,
    r8_unorm_srgb,
    r8_snorm,
    r16_unorm,
    r16_snorm,
    r16_float,
    rg8_unorm,
    rg8_unorm_srgb,
    rg8_snorm,
    rg16_unorm,
    rg16_snorm,
    rg16_float,
    rgba8_unorm,
    rgba8_unorm_srgb,
    rgba8_snorm,
    bgra8_unorm,
    bgra8_unorm_srgb,
    r32_float,
    rgba16_unorm,
    rgba16_snorm,
    rgba16_float,
    rg32_float,
    rgba32_float,
    b5g6r5_unorm,
    a1bgr5_unorm,
    abgr4_unorm,
    bgr5a1_unorm,
    rgb10a2_unorm,
    bgr10a2_unorm,
    rg11b10_float,
    rgb9e5_float,
};

pub const Target = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: usize,
    format: TargetFormat,

    fn bytesPerPixel(format: TargetFormat) usize {
        return switch (format) {
            .a8_unorm => 1,
            .r8_unorm, .r8_unorm_srgb, .r8_snorm => 1,
            .r16_unorm, .r16_snorm => 2,
            .r16_float => 2,
            .rg8_unorm, .rg8_unorm_srgb, .rg8_snorm => 2,
            .rg16_unorm, .rg16_snorm => 4,
            .rg16_float => 4,
            .rgba8_unorm, .rgba8_unorm_srgb, .rgba8_snorm, .bgra8_unorm, .bgra8_unorm_srgb, .r32_float => 4,
            .rgba16_unorm, .rgba16_snorm, .rgba16_float => 8,
            .rg32_float => 8,
            .rgba32_float => 16,
            .b5g6r5_unorm, .a1bgr5_unorm, .abgr4_unorm, .bgr5a1_unorm => 2,
            .rgb10a2_unorm, .bgr10a2_unorm, .rg11b10_float, .rgb9e5_float => 4,
        };
    }

    pub fn init(pixels: []u8, width: u32, height: u32, stride: usize, format: TargetFormat) !Target {
        const row_bytes = try std.math.mul(usize, width, bytesPerPixel(format));
        if (stride < row_bytes) return error.InvalidStride;
        const required = if (height == 0) 0 else try std.math.add(usize, try std.math.mul(usize, height - 1, stride), row_bytes);
        if (pixels.len < required) return error.BufferTooSmall;
        return .{ .pixels = pixels, .width = width, .height = height, .stride = stride, .format = format };
    }

    pub fn row(self: *const Target, y: u32) []u8 {
        const start = @as(usize, y) * self.stride;
        return self.pixels[start .. start + @as(usize, self.width) * bytesPerPixel(self.format)];
    }

    fn readF32(row_bytes: []const u8, offset: usize) f32 {
        return @bitCast(std.mem.readInt(u32, row_bytes[offset..][0..4], .little));
    }

    fn writeF32(row_bytes: []u8, offset: usize, value: f32) void {
        std.mem.writeInt(u32, row_bytes[offset..][0..4], @bitCast(value), .little);
    }

    fn readF16(row_bytes: []const u8, offset: usize) f32 {
        return @floatCast(@as(f16, @bitCast(std.mem.readInt(u16, row_bytes[offset..][0..2], .little))));
    }

    fn readU16(row_bytes: []const u8, offset: usize) f32 {
        return @as(f32, @floatFromInt(std.mem.readInt(u16, row_bytes[offset..][0..2], .little))) / 65535.0;
    }

    fn readS8(row_bytes: []const u8, offset: usize) f32 {
        const value: i8 = @bitCast(row_bytes[offset]);
        return if (value == std.math.minInt(i8)) -1 else @as(f32, @floatFromInt(value)) / 127.0;
    }

    fn readS16(row_bytes: []const u8, offset: usize) f32 {
        const value = std.mem.readInt(i16, row_bytes[offset..][0..2], .little);
        return if (value == std.math.minInt(i16)) -1 else @as(f32, @floatFromInt(value)) / 32767.0;
    }

    fn writeF16(row_bytes: []u8, offset: usize, value: f32) void {
        const half: f16 = @floatCast(value);
        std.mem.writeInt(u16, row_bytes[offset..][0..2], @bitCast(half), .little);
    }

    fn writeU16(row_bytes: []u8, offset: usize, value: f32) void {
        const quantized: u16 = @intFromFloat(std.math.clamp(value, 0, 1) * 65535.0 + 0.5);
        std.mem.writeInt(u16, row_bytes[offset..][0..2], quantized, .little);
    }

    fn packedUnorm(value: f32, maximum: u32) u32 {
        return @intFromFloat(std.math.clamp(value, 0, 1) * @as(f32, @floatFromInt(maximum)) + 0.5);
    }

    fn packedUnormValue(bits: u32, maximum: u32) f32 {
        return @as(f32, @floatFromInt(bits)) / @as(f32, @floatFromInt(maximum));
    }

    fn roundToEven(value: f64) u32 {
        if (!(value > 0)) return 0;
        const lower_float = @floor(value);
        const lower: u64 = @intFromFloat(lower_float);
        const fraction = value - lower_float;
        const rounded = if (fraction > 0.5 or (fraction == 0.5 and lower % 2 == 1)) lower + 1 else lower;
        return @intCast(rounded);
    }

    fn readUnsignedFloat(bits: u32, mantissa_bits: u32) f32 {
        const mantissa_mask = (@as(u32, 1) << @intCast(mantissa_bits)) - 1;
        const mantissa = bits & mantissa_mask;
        const exponent = (bits >> @intCast(mantissa_bits)) & 0x1f;
        if (exponent == 0) {
            return @floatCast(@as(f64, @floatFromInt(mantissa)) * std.math.pow(f64, 2.0, -14.0 - @as(f64, @floatFromInt(mantissa_bits))));
        }
        if (exponent == 0x1f) return if (mantissa == 0) std.math.inf(f32) else std.math.nan(f32);
        const scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 15.0);
        return @floatCast((1.0 + @as(f64, @floatFromInt(mantissa)) /
            std.math.pow(f64, 2.0, @as(f64, @floatFromInt(mantissa_bits)))) * scale);
    }

    fn writeUnsignedFloat(value: f32, mantissa_bits: u32) u32 {
        if (!(value > 0)) return 0;
        if (!std.math.isFinite(value)) return (@as(u32, 0x1f) << @intCast(mantissa_bits));
        const x: f64 = @floatCast(value);
        const mantissa_scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(mantissa_bits)));
        const minimum_normal = std.math.pow(f64, 2.0, -14.0);
        if (x < minimum_normal) return roundToEven(x * std.math.pow(f64, 2.0, 14.0 + @as(f64, @floatFromInt(mantissa_bits))));
        var exponent: i32 = @intFromFloat(@floor(std.math.log2(x)));
        var mantissa = roundToEven((x / std.math.pow(f64, 2.0, @floatFromInt(exponent)) - 1.0) * mantissa_scale);
        const mantissa_limit = @as(u32, 1) << @intCast(mantissa_bits);
        if (mantissa >= mantissa_limit) {
            exponent += 1;
            mantissa = 0;
        }
        if (exponent > 15) return (@as(u32, 0x1f) << @intCast(mantissa_bits));
        return (@as(u32, @intCast(exponent + 15)) << @intCast(mantissa_bits)) | mantissa;
    }

    fn readRgb9e5(bits: u32) [4]f32 {
        const exponent = (bits >> 27) & 0x1f;
        const scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
        return .{
            @floatCast(@as(f64, @floatFromInt(bits & 0x1ff)) * scale),
            @floatCast(@as(f64, @floatFromInt((bits >> 9) & 0x1ff)) * scale),
            @floatCast(@as(f64, @floatFromInt((bits >> 18) & 0x1ff)) * scale),
            1,
        };
    }

    fn writeRgb9e5(color: [4]f32) u32 {
        var maximum: f64 = 0;
        for (color[0..3]) |component| maximum = @max(maximum, @as(f64, @floatCast(std.math.clamp(component, 0, std.math.inf(f32)))));
        if (!(maximum > 0)) return 0;
        var exponent: i32 = @as(i32, @intFromFloat(@floor(std.math.log2(maximum)))) + 16;
        exponent = std.math.clamp(exponent, 0, 31);
        var scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
        var red = roundToEven(@as(f64, @floatCast(std.math.clamp(color[0], 0, std.math.inf(f32)))) / scale);
        var green = roundToEven(@as(f64, @floatCast(std.math.clamp(color[1], 0, std.math.inf(f32)))) / scale);
        var blue = roundToEven(@as(f64, @floatCast(std.math.clamp(color[2], 0, std.math.inf(f32)))) / scale);
        if (@max(@max(red, green), blue) > 0x1ff and exponent < 31) {
            exponent += 1;
            scale = std.math.pow(f64, 2.0, @as(f64, @floatFromInt(exponent)) - 24.0);
            red = roundToEven(@as(f64, @floatCast(std.math.clamp(color[0], 0, std.math.inf(f32)))) / scale);
            green = roundToEven(@as(f64, @floatCast(std.math.clamp(color[1], 0, std.math.inf(f32)))) / scale);
            blue = roundToEven(@as(f64, @floatCast(std.math.clamp(color[2], 0, std.math.inf(f32)))) / scale);
        }
        return @as(u32, @intCast(@min(red, 0x1ff))) |
            (@as(u32, @intCast(@min(green, 0x1ff))) << 9) |
            (@as(u32, @intCast(@min(blue, 0x1ff))) << 18) |
            (@as(u32, @intCast(exponent)) << 27);
    }

    fn readPacked16(row_bytes: []const u8, offset: usize) u16 {
        return std.mem.readInt(u16, row_bytes[offset..][0..2], .little);
    }

    fn writePacked16(row_bytes: []u8, offset: usize, value: u16) void {
        std.mem.writeInt(u16, row_bytes[offset..][0..2], value, .little);
    }

    fn readPacked32(row_bytes: []const u8, offset: usize) u32 {
        return std.mem.readInt(u32, row_bytes[offset..][0..4], .little);
    }

    fn writePacked32(row_bytes: []u8, offset: usize, value: u32) void {
        std.mem.writeInt(u32, row_bytes[offset..][0..4], value, .little);
    }

    fn writeS8(row_bytes: []u8, offset: usize, value: f32) void {
        const clamped = std.math.clamp(value, -1, 1);
        const quantized: i16 = if (clamped < 0)
            @intFromFloat(clamped * 127.0 - 0.5)
        else
            @intFromFloat(clamped * 127.0 + 0.5);
        row_bytes[offset] = @bitCast(@as(i8, @intCast(std.math.clamp(quantized, -128, 127))));
    }

    fn writeS16(row_bytes: []u8, offset: usize, value: f32) void {
        const clamped = std.math.clamp(value, -1, 1);
        const quantized: i32 = if (clamped < 0)
            @intFromFloat(clamped * 32767.0 - 0.5)
        else
            @intFromFloat(clamped * 32767.0 + 0.5);
        std.mem.writeInt(i16, row_bytes[offset..][0..2], @intCast(std.math.clamp(quantized, -32768, 32767)), .little);
    }

    fn srgbToLinear(value: u8) f32 {
        const normalized = @as(f32, @floatFromInt(value)) / 255.0;
        const decoded = if (normalized <= 0.04045)
            normalized / 12.92
        else
            std.math.pow(f32, (normalized + 0.055) / 1.055, 2.4);
        return @round(decoded * 4095.0) / 4095.0;
    }

    fn linearToSrgb(value: f32) f32 {
        const clamped = std.math.clamp(value, 0, 1);
        return if (clamped <= 0.0031308)
            clamped * 12.92
        else
            1.055 * std.math.pow(f32, clamped, 1.0 / 2.4) - 0.055;
    }

    fn srgbByte(value: f32) u8 {
        const clamped = std.math.clamp(value, 0, 1);
        const linear = @floor(clamped * 4095.0 + 0.5) / 4095.0;
        return @intFromFloat(linearToSrgb(linear) * 255.0 + 0.5);
    }

    fn readColor(self: *const Target, x: usize, y: usize) [4]f32 {
        const row_bytes = self.row(@intCast(y));
        const offset = x * bytesPerPixel(self.format);
        return switch (self.format) {
            .a8_unorm => .{ 0, 0, 0, @as(f32, @floatFromInt(row_bytes[offset])) / 255.0 },
            .r8_unorm => .{ @as(f32, @floatFromInt(row_bytes[offset])) / 255.0, 0, 0, 1 },
            .r8_unorm_srgb => .{ srgbToLinear(row_bytes[offset]), 0, 0, 1 },
            .r8_snorm => .{ readS8(row_bytes, offset), 0, 0, 1 },
            .r16_unorm => .{ readU16(row_bytes, offset), 0, 0, 1 },
            .r16_snorm => .{ readS16(row_bytes, offset), 0, 0, 1 },
            .r16_float => .{ readF16(row_bytes, offset), 0, 0, 1 },
            .rg8_unorm => .{
                @as(f32, @floatFromInt(row_bytes[offset])) / 255.0,
                @as(f32, @floatFromInt(row_bytes[offset + 1])) / 255.0,
                0,
                1,
            },
            .rg8_unorm_srgb => .{ srgbToLinear(row_bytes[offset]), srgbToLinear(row_bytes[offset + 1]), 0, 1 },
            .rg8_snorm => .{ readS8(row_bytes, offset), readS8(row_bytes, offset + 1), 0, 1 },
            .rg16_unorm => .{ readU16(row_bytes, offset), readU16(row_bytes, offset + 2), 0, 1 },
            .rg16_snorm => .{ readS16(row_bytes, offset), readS16(row_bytes, offset + 2), 0, 1 },
            .rg16_float => .{ readF16(row_bytes, offset), readF16(row_bytes, offset + 2), 0, 1 },
            .rgba8_snorm => .{
                readS8(row_bytes, offset),     readS8(row_bytes, offset + 1),
                readS8(row_bytes, offset + 2), readS8(row_bytes, offset + 3),
            },
            .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb => blk: {
                const format: surface.Format = if (self.format == .rgba8_unorm or self.format == .rgba8_unorm_srgb)
                    .rgba8_unorm
                else
                    .bgra8_unorm;
                const color = surface.Surface.read(row_bytes, offset, format);
                break :blk .{
                    if (self.format == .rgba8_unorm_srgb or self.format == .bgra8_unorm_srgb) srgbToLinear(color.r) else @as(f32, @floatFromInt(color.r)) / 255.0,
                    if (self.format == .rgba8_unorm_srgb or self.format == .bgra8_unorm_srgb) srgbToLinear(color.g) else @as(f32, @floatFromInt(color.g)) / 255.0,
                    if (self.format == .rgba8_unorm_srgb or self.format == .bgra8_unorm_srgb) srgbToLinear(color.b) else @as(f32, @floatFromInt(color.b)) / 255.0,
                    @as(f32, @floatFromInt(color.a)) / 255.0,
                };
            },
            .r32_float => .{ readF32(row_bytes, offset), 0, 0, 1 },
            .rgba16_unorm => .{ readU16(row_bytes, offset), readU16(row_bytes, offset + 2), readU16(row_bytes, offset + 4), readU16(row_bytes, offset + 6) },
            .rgba16_snorm => .{ readS16(row_bytes, offset), readS16(row_bytes, offset + 2), readS16(row_bytes, offset + 4), readS16(row_bytes, offset + 6) },
            .rgba16_float => .{
                readF16(row_bytes, offset),     readF16(row_bytes, offset + 2),
                readF16(row_bytes, offset + 4), readF16(row_bytes, offset + 6),
            },
            .rgba32_float => .{
                readF32(row_bytes, offset),     readF32(row_bytes, offset + 4),
                readF32(row_bytes, offset + 8), readF32(row_bytes, offset + 12),
            },
            .rg32_float => .{ readF32(row_bytes, offset), readF32(row_bytes, offset + 4), 0, 1 },
            .b5g6r5_unorm => blk: {
                const bits = readPacked16(row_bytes, offset);
                break :blk .{
                    packedUnormValue((bits >> 11) & 0x1f, 31),
                    packedUnormValue((bits >> 5) & 0x3f, 63),
                    packedUnormValue(bits & 0x1f, 31),
                    1,
                };
            },
            .a1bgr5_unorm => blk: {
                const bits = readPacked16(row_bytes, offset);
                break :blk .{
                    packedUnormValue((bits >> 11) & 0x1f, 31),
                    packedUnormValue((bits >> 6) & 0x1f, 31),
                    packedUnormValue((bits >> 1) & 0x1f, 31),
                    if ((bits & 1) != 0) 1 else 0,
                };
            },
            .abgr4_unorm => blk: {
                const bits = readPacked16(row_bytes, offset);
                break :blk .{
                    packedUnormValue((bits >> 12) & 0xf, 15),
                    packedUnormValue((bits >> 8) & 0xf, 15),
                    packedUnormValue((bits >> 4) & 0xf, 15),
                    packedUnormValue(bits & 0xf, 15),
                };
            },
            .bgr5a1_unorm => blk: {
                const bits = readPacked16(row_bytes, offset);
                break :blk .{
                    packedUnormValue((bits >> 10) & 0x1f, 31),
                    packedUnormValue((bits >> 5) & 0x1f, 31),
                    packedUnormValue(bits & 0x1f, 31),
                    if ((bits >> 15) != 0) 1 else 0,
                };
            },
            .rgb10a2_unorm, .bgr10a2_unorm => blk: {
                const bits = readPacked32(row_bytes, offset);
                const red_bits = if (self.format == .rgb10a2_unorm) bits & 0x3ff else (bits >> 20) & 0x3ff;
                const blue_bits = if (self.format == .rgb10a2_unorm) (bits >> 20) & 0x3ff else bits & 0x3ff;
                break :blk .{
                    packedUnormValue(red_bits, 1023),  packedUnormValue((bits >> 10) & 0x3ff, 1023),
                    packedUnormValue(blue_bits, 1023), packedUnormValue((bits >> 30) & 3, 3),
                };
            },
            .rg11b10_float => blk: {
                const bits = readPacked32(row_bytes, offset);
                break :blk .{
                    readUnsignedFloat(bits & 0x7ff, 6),
                    readUnsignedFloat((bits >> 11) & 0x7ff, 6),
                    readUnsignedFloat((bits >> 22) & 0x3ff, 5),
                    1,
                };
            },
            .rgb9e5_float => readRgb9e5(readPacked32(row_bytes, offset)),
        };
    }

    fn writeColor(self: *Target, x: usize, y: usize, color: [4]f32, write_mask: u8) void {
        const row_bytes = self.row(@intCast(y));
        const offset = x * bytesPerPixel(self.format);
        switch (self.format) {
            .a8_unorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) row_bytes[offset] = colorByte(color[3]);
            },
            .r8_unorm, .r8_unorm_srgb => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) row_bytes[offset] = if (self.format == .r8_unorm_srgb) srgbByte(color[0]) else colorByte(color[0]);
            },
            .r8_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS8(row_bytes, offset, color[0]);
            },
            .r16_unorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeU16(row_bytes, offset, color[0]);
            },
            .r16_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS16(row_bytes, offset, color[0]);
            },
            .r16_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF16(row_bytes, offset, color[0]);
            },
            .rg8_unorm, .rg8_unorm_srgb => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) row_bytes[offset] = if (self.format == .rg8_unorm_srgb) srgbByte(color[0]) else colorByte(color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) row_bytes[offset + 1] = if (self.format == .rg8_unorm_srgb) srgbByte(color[1]) else colorByte(color[1]);
            },
            .rg8_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS8(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeS8(row_bytes, offset + 1, color[1]);
            },
            .rg16_unorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeU16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeU16(row_bytes, offset + 2, color[1]);
            },
            .rg16_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeS16(row_bytes, offset + 2, color[1]);
            },
            .rg16_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeF16(row_bytes, offset + 2, color[1]);
            },
            .rgba8_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS8(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeS8(row_bytes, offset + 1, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeS8(row_bytes, offset + 2, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeS8(row_bytes, offset + 3, color[3]);
            },
            .rgba8_unorm, .rgba8_unorm_srgb, .bgra8_unorm, .bgra8_unorm_srgb => {
                const srgb = self.format == .rgba8_unorm_srgb or self.format == .bgra8_unorm_srgb;
                const format: surface.Format = if (self.format == .rgba8_unorm or self.format == .rgba8_unorm_srgb)
                    .rgba8_unorm
                else
                    .bgra8_unorm;
                var output = surface.Surface.read(row_bytes, offset, format);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) output.r = if (srgb) srgbByte(color[0]) else colorByte(color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) output.g = if (srgb) srgbByte(color[1]) else colorByte(color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) output.b = if (srgb) srgbByte(color[2]) else colorByte(color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) output.a = colorByte(color[3]);
                surface.Surface.write(row_bytes, offset, format, output);
            },
            .r32_float => if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF32(row_bytes, offset, color[0]),
            .rgba16_unorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeU16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeU16(row_bytes, offset + 2, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeU16(row_bytes, offset + 4, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeU16(row_bytes, offset + 6, color[3]);
            },
            .rgba16_snorm => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeS16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeS16(row_bytes, offset + 2, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeS16(row_bytes, offset + 4, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeS16(row_bytes, offset + 6, color[3]);
            },
            .rgba16_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF16(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeF16(row_bytes, offset + 2, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeF16(row_bytes, offset + 4, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeF16(row_bytes, offset + 6, color[3]);
            },
            .rgba32_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF32(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeF32(row_bytes, offset + 4, color[1]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) writeF32(row_bytes, offset + 8, color[2]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) writeF32(row_bytes, offset + 12, color[3]);
            },
            .rg32_float => {
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) writeF32(row_bytes, offset, color[0]);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) writeF32(row_bytes, offset + 4, color[1]);
            },
            .b5g6r5_unorm => {
                var bits = readPacked16(row_bytes, offset);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~@as(u16, 0xf800)) | @as(u16, @intCast(packedUnorm(color[0], 31) << 11));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u16, 0x07e0)) | @as(u16, @intCast(packedUnorm(color[1], 63) << 5));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~@as(u16, 0x001f)) | @as(u16, @intCast(packedUnorm(color[2], 31)));
                writePacked16(row_bytes, offset, bits);
            },
            .a1bgr5_unorm => {
                var bits = readPacked16(row_bytes, offset);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~@as(u16, 0xf800)) | @as(u16, @intCast(packedUnorm(color[0], 31) << 11));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u16, 0x07c0)) | @as(u16, @intCast(packedUnorm(color[1], 31) << 6));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~@as(u16, 0x003e)) | @as(u16, @intCast(packedUnorm(color[2], 31) << 1));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) bits = (bits & ~@as(u16, 0x0001)) | @as(u16, @intCast(packedUnorm(color[3], 1)));
                writePacked16(row_bytes, offset, bits);
            },
            .abgr4_unorm => {
                var bits = readPacked16(row_bytes, offset);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~@as(u16, 0xf000)) | @as(u16, @intCast(packedUnorm(color[0], 15) << 12));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u16, 0x0f00)) | @as(u16, @intCast(packedUnorm(color[1], 15) << 8));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~@as(u16, 0x00f0)) | @as(u16, @intCast(packedUnorm(color[2], 15) << 4));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) bits = (bits & ~@as(u16, 0x000f)) | @as(u16, @intCast(packedUnorm(color[3], 15)));
                writePacked16(row_bytes, offset, bits);
            },
            .bgr5a1_unorm => {
                var bits = readPacked16(row_bytes, offset);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~@as(u16, 0x7c00)) | @as(u16, @intCast(packedUnorm(color[0], 31) << 10));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u16, 0x03e0)) | @as(u16, @intCast(packedUnorm(color[1], 31) << 5));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~@as(u16, 0x001f)) | @as(u16, @intCast(packedUnorm(color[2], 31)));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) bits = (bits & ~@as(u16, 0x8000)) | @as(u16, @intCast(packedUnorm(color[3], 1) << 15));
                writePacked16(row_bytes, offset, bits);
            },
            .rgb10a2_unorm, .bgr10a2_unorm => {
                var bits = readPacked32(row_bytes, offset);
                const red_mask: u32 = if (self.format == .rgb10a2_unorm) 0x000003ff else 0x3ff00000;
                const blue_mask: u32 = if (self.format == .rgb10a2_unorm) 0x3ff00000 else 0x000003ff;
                const red_bits: u32 = packedUnorm(color[0], 1023) << (if (self.format == .rgb10a2_unorm) 0 else 20);
                const blue_bits: u32 = packedUnorm(color[2], 1023) << (if (self.format == .rgb10a2_unorm) 20 else 0);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~red_mask) | red_bits;
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u32, 0x000ffc00)) | (packedUnorm(color[1], 1023) << 10);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~blue_mask) | blue_bits;
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.alpha)) != 0) bits = (bits & ~@as(u32, 0xc0000000)) | (packedUnorm(color[3], 3) << 30);
                writePacked32(row_bytes, offset, bits);
            },
            .rg11b10_float => {
                var bits = readPacked32(row_bytes, offset);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) bits = (bits & ~@as(u32, 0x000007ff)) | writeUnsignedFloat(color[0], 6);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) bits = (bits & ~@as(u32, 0x003ff800)) | (writeUnsignedFloat(color[1], 6) << 11);
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) bits = (bits & ~@as(u32, 0xffc00000)) | (writeUnsignedFloat(color[2], 5) << 22);
                writePacked32(row_bytes, offset, bits);
            },
            .rgb9e5_float => {
                var old = readRgb9e5(readPacked32(row_bytes, offset));
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.red)) != 0) old[0] = color[0];
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.green)) != 0) old[1] = color[1];
                if ((write_mask & @intFromEnum(abi.ColorWriteMask.blue)) != 0) old[2] = color[2];
                writePacked32(row_bytes, offset, writeRgb9e5(old));
            },
        }
    }

    pub fn storeColor(self: *Target, x: usize, y: usize, color: [4]f32) void {
        if (x >= self.width or y >= self.height) return;
        self.writeColor(x, y, color, @intFromEnum(abi.ColorWriteMask.all));
    }

    fn addressCoordinate(value: f32, mode: abi.SamplerAddressMode) ?f32 {
        if (!std.math.isFinite(value)) return null;
        return switch (mode) {
            .clamp_to_edge => std.math.clamp(value, 0, 1),
            .mirror_clamp_to_edge => if (value < -1) 0 else if (value > 1) 1 else @abs(value),
            .repeat => value - @floor(value),
            .mirror_repeat => blk: {
                const period = value - @floor(value / 2) * 2;
                break :blk if (period <= 1) period else 2 - period;
            },
            .clamp_to_zero, .clamp_to_border_color => if (value < 0 or value > 1) null else value,
        };
    }

    fn sampleIndex(index: i64, limit: u32, mode: abi.SamplerAddressMode) ?usize {
        if (limit == 0) return null;
        const extent: i64 = @intCast(limit);
        return switch (mode) {
            .clamp_to_edge => @intCast(std.math.clamp(index, 0, extent - 1)),
            .mirror_clamp_to_edge => @intCast(std.math.clamp(index, 0, extent - 1)),
            .repeat => blk: {
                var wrapped = @rem(index, extent);
                if (wrapped < 0) wrapped += extent;
                break :blk @intCast(wrapped);
            },
            .mirror_repeat => blk: {
                const period = extent * 2;
                var wrapped = @rem(index, period);
                if (wrapped < 0) wrapped += period;
                break :blk @intCast(if (wrapped < extent) wrapped else period - wrapped - 1);
            },
            .clamp_to_zero, .clamp_to_border_color => if (index < 0 or index >= extent) null else @intCast(index),
        };
    }

    fn borderSampleColor(self: *const Target, border_color: abi.SamplerBorderColor) [4]f32 {
        return switch (border_color) {
            .transparent_black => self.zeroSampleColor(),
            .opaque_black => .{ 0, 0, 0, 1 },
            .opaque_white => .{ 1, 1, 1, 1 },
        };
    }

    fn outOfRangeSampleColor(self: *const Target, mode: abi.SamplerAddressMode, border_color: abi.SamplerBorderColor) [4]f32 {
        return if (mode == .clamp_to_border_color) self.borderSampleColor(border_color) else self.zeroSampleColor();
    }

    fn sampleTexel(self: *const Target, x: i64, y: i64, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode, border_color: abi.SamplerBorderColor) [4]f32 {
        const sample_x = sampleIndex(x, self.width, address_s) orelse return self.outOfRangeSampleColor(address_s, border_color);
        const sample_y = sampleIndex(y, self.height, address_t) orelse return self.outOfRangeSampleColor(address_t, border_color);
        return self.readColor(sample_x, sample_y);
    }

    fn zeroSampleColor(self: *const Target) [4]f32 {
        return if (self.format == .r32_float) .{ 0, 0, 0, 1 } else .{ 0, 0, 0, 0 };
    }

    fn sampleNearest(self: *const Target, u: f32, v: f32, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode, border_color: abi.SamplerBorderColor) [4]f32 {
        const normalized_u = addressCoordinate(u, address_s) orelse return self.outOfRangeSampleColor(address_s, border_color);
        const normalized_v = addressCoordinate(v, address_t) orelse return self.outOfRangeSampleColor(address_t, border_color);
        const x: i64 = @intFromFloat(@min(normalized_u, 0.99999994) * @as(f32, @floatFromInt(self.width)));
        const y: i64 = @intFromFloat(@min(normalized_v, 0.99999994) * @as(f32, @floatFromInt(self.height)));
        return self.sampleTexel(x, y, address_s, address_t, border_color);
    }

    fn sampleLinear(self: *const Target, u: f32, v: f32, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode, border_color: abi.SamplerBorderColor, reduction_mode: abi.SamplerReductionMode) [4]f32 {
        const normalized_u = addressCoordinate(u, address_s) orelse return self.outOfRangeSampleColor(address_s, border_color);
        const normalized_v = addressCoordinate(v, address_t) orelse return self.outOfRangeSampleColor(address_t, border_color);
        const x = normalized_u * @as(f32, @floatFromInt(self.width)) - 0.5;
        const y = normalized_v * @as(f32, @floatFromInt(self.height)) - 0.5;
        const x0_float = @floor(x);
        const y0_float = @floor(y);
        const x0: i64 = @intFromFloat(x0_float);
        const y0: i64 = @intFromFloat(y0_float);
        const x_weight = x - x0_float;
        const y_weight = y - y0_float;
        const top_left = self.sampleTexel(x0, y0, address_s, address_t, border_color);
        const top_right = self.sampleTexel(x0 + 1, y0, address_s, address_t, border_color);
        const bottom_left = self.sampleTexel(x0, y0 + 1, address_s, address_t, border_color);
        const bottom_right = self.sampleTexel(x0 + 1, y0 + 1, address_s, address_t, border_color);
        var result: [4]f32 = undefined;
        switch (reduction_mode) {
            .weighted_average => for (0..4) |channel| {
                const top = top_left[channel] + (top_right[channel] - top_left[channel]) * x_weight;
                const bottom = bottom_left[channel] + (bottom_right[channel] - bottom_left[channel]) * x_weight;
                result[channel] = top + (bottom - top) * y_weight;
            },
            .minimum => {
                for (0..4) |channel| result[channel] = @min(@min(top_left[channel], top_right[channel]), @min(bottom_left[channel], bottom_right[channel]));
            },
            .maximum => {
                for (0..4) |channel| result[channel] = @max(@max(top_left[channel], top_right[channel]), @max(bottom_left[channel], bottom_right[channel]));
            },
        }
        return result;
    }

    fn swizzleValue(color: [4]f32, channel: abi.TextureSwizzle) f32 {
        return switch (channel) {
            .zero => 0,
            .one => 1,
            .red => color[0],
            .green => color[1],
            .blue => color[2],
            .alpha => color[3],
        };
    }

    fn applySwizzle(color: [4]f32, swizzle: abi.TextureSwizzleChannels) [4]f32 {
        return .{
            swizzleValue(color, swizzle.red),
            swizzleValue(color, swizzle.green),
            swizzleValue(color, swizzle.blue),
            swizzleValue(color, swizzle.alpha),
        };
    }

    fn sample(self: *const Target, u: f32, v: f32, filter: abi.SamplerFilter, address_s: abi.SamplerAddressMode, address_t: abi.SamplerAddressMode, border_color: abi.SamplerBorderColor, swizzle: abi.TextureSwizzleChannels, normalized_coordinates: bool, reduction_mode: abi.SamplerReductionMode) [4]f32 {
        const sample_u = if (normalized_coordinates) u else u / @as(f32, @floatFromInt(self.width));
        const sample_v = if (normalized_coordinates) v else v / @as(f32, @floatFromInt(self.height));
        const color = switch (filter) {
            .nearest => self.sampleNearest(sample_u, sample_v, address_s, address_t, border_color),
            .linear => self.sampleLinear(sample_u, sample_v, address_s, address_t, border_color, reduction_mode),
        };
        return applySwizzle(color, swizzle);
    }
};

const Job = struct {
    target: *Target,
    extra_targets: []const *Target,
    sample_texture: ?*const Target,
    sample_mipmaps: []const Target,
    depth: ?[]f32,
    stencil: ?[]u8,
    vertices: []const abi.Vertex,
    primitive: abi.PrimitiveType,
    options: DrawOptions,
    bands: [2]Stats = .{ .{}, .{} },
};

fn project(vertex: abi.Vertex, viewport: abi.Viewport) ?ProjectedVertex {
    const p = vertex.position;
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or !std.math.isFinite(p[2]) or !std.math.isFinite(p[3]) or @abs(p[3]) < 0.000001) return null;
    const inverse_w = 1.0 / p[3];
    const nx = p[0] * inverse_w;
    const ny = p[1] * inverse_w;
    const nz = p[2] * inverse_w;
    if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) return null;
    return .{
        .x = viewport.origin_x + (nx * 0.5 + 0.5) * viewport.width,
        // Metal's render-target row zero is the top row: clip-space +Y maps
        // toward the viewport origin, while the CPU surface is addressed
        // with increasing Y down the image.
        .y = viewport.origin_y + (0.5 - ny * 0.5) * viewport.height,
        .z = viewport.znear + nz * (viewport.zfar - viewport.znear),
        .inverse_w = inverse_w,
        .color = .{ vertex.color.red, vertex.color.green, vertex.color.blue, vertex.color.alpha },
    };
}

fn interpolateLineColor(a: ProjectedVertex, b: ProjectedVertex, t: f32) [4]f32 {
    const weight_a = 1 - t;
    const weight_b = t;
    const denominator = a.inverse_w * weight_a + b.inverse_w * weight_b;
    if (!std.math.isFinite(denominator) or @abs(denominator) < 0.000001) return .{ 0, 0, 0, 1 };
    var color: [4]f32 = undefined;
    for (0..4) |channel| {
        color[channel] = (a.color[channel] * a.inverse_w * weight_a + b.color[channel] * b.inverse_w * weight_b) / denominator;
    }
    return color;
}

fn interpolateTriangleColor(vertices: [3]ProjectedVertex, w0: f32, w1: f32, w2: f32) [4]f32 {
    const denominator = vertices[0].inverse_w * w0 + vertices[1].inverse_w * w1 + vertices[2].inverse_w * w2;
    if (!std.math.isFinite(denominator) or @abs(denominator) < 0.000001) return .{ 0, 0, 0, 1 };
    var color: [4]f32 = undefined;
    for (0..4) |channel| {
        color[channel] = (vertices[0].color[channel] * vertices[0].inverse_w * w0 +
            vertices[1].color[channel] * vertices[1].inverse_w * w1 +
            vertices[2].color[channel] * vertices[2].inverse_w * w2) / denominator;
    }
    return color;
}

fn edge(a: ProjectedVertex, b: ProjectedVertex, x: f32, y: f32) f32 {
    return (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
}

fn topLeftEdge(a: ProjectedVertex, b: ProjectedVertex) bool {
    const dy = b.y - a.y;
    const dx = b.x - a.x;
    return dy < 0 or (dy == 0 and dx > 0);
}

fn outsideTopLeft(value: f32, a: ProjectedVertex, b: ProjectedVertex, positive_area: bool) bool {
    // edge() is written as cross(point - a, b - a). For a positive-area
    // triangle its positive half-plane uses the reverse directed edge; a
    // negative-area triangle keeps the original direction. Metal's strip
    // rasterizer relies on this distinction for the two alternating faces.
    const inclusive_edge = if (positive_area) topLeftEdge(b, a) else topLeftEdge(a, b);
    return value < 0 or (@abs(value) < 0.000001 and !inclusive_edge);
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255.0 + 0.5);
}

fn compareStencil(compare: abi.CompareFunction, reference: u8, current: u8, mask: u8) bool {
    const lhs = reference & mask;
    const rhs = current & mask;
    return switch (compare) {
        .never => false,
        .less => lhs < rhs,
        .equal => lhs == rhs,
        .less_equal => lhs <= rhs,
        .greater => lhs > rhs,
        .not_equal => lhs != rhs,
        .greater_equal => lhs >= rhs,
        .always => true,
    };
}

fn stencilOperation(operation: abi.StencilOperation, current: u8, reference: u8) u8 {
    return switch (operation) {
        .keep => current,
        .zero => 0,
        .replace => reference,
        .increment_clamp => if (current == 0xff) 0xff else current + 1,
        .decrement_clamp => if (current == 0) 0 else current - 1,
        .invert => ~current,
        .increment_wrap => current +% 1,
        .decrement_wrap => current -% 1,
    };
}

fn applyStencil(stencil: []u8, index: usize, state: StencilFace, operation: abi.StencilOperation) void {
    const current = stencil[index];
    const result = stencilOperation(operation, current, state.reference);
    stencil[index] = (current & ~state.write_mask) | (result & state.write_mask);
}

fn writeColor(target: *Target, x: usize, y: usize, color: [4]f32, options: DrawOptions) void {
    if (x >= target.width or y >= target.height) return;
    const destination_color = target.readColor(x, y);
    const output_color = if (options.blending_enabled) .{
        blendChannel(0, color[0], destination_color[0], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(1, color[1], destination_color[1], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(2, color[2], destination_color[2], color, destination_color, options.blend_color, options.source_rgb_factor, options.destination_rgb_factor, options.rgb_operation),
        blendChannel(3, color[3], destination_color[3], color, destination_color, options.blend_color, options.source_alpha_factor, options.destination_alpha_factor, options.alpha_operation),
    } else color;
    target.writeColor(x, y, output_color, options.color_write_mask);
}

fn adjustedDepth(job: *const Job, z: f32, bias: f32) ?f32 {
    var result = z + bias;
    if (job.options.depth_clip_mode == .clamp) {
        result = std.math.clamp(result, 0, 1);
    } else if (result < 0 or result > 1) {
        return null;
    }
    return result;
}

fn depthBias(job: *const Job, slope: f32) f32 {
    var result = job.options.depth_bias + job.options.slope_scale * slope;
    if (job.options.depth_bias_clamp != 0) {
        const limit = @abs(job.options.depth_bias_clamp);
        result = std.math.clamp(result, -limit, limit);
    }
    return result;
}

const SampleSelection = struct {
    filter: abi.SamplerFilter,
    level0: usize = 0,
    level1: usize = 0,
    level_weight: f32 = 0,
    anisotropic_major_u: f32 = 0,
    anisotropic_major_v: f32 = 0,
    anisotropic_taps: usize = 1,
};

fn sampleSelection(job: *const Job, filter: abi.SamplerFilter, rho: f32) SampleSelection {
    if (job.sample_mipmaps.len <= 1 or job.options.sample_mip_filter == .not_mipmapped) {
        return .{ .filter = filter };
    }
    var lod = if (std.math.isFinite(rho) and rho > 0) std.math.log2(rho) else 0;
    lod += job.options.sample_lod_bias;
    lod = std.math.clamp(lod, job.options.sample_lod_min_clamp, job.options.sample_lod_max_clamp);
    lod = std.math.clamp(lod, 0, @as(f32, @floatFromInt(job.sample_mipmaps.len - 1)));
    return switch (job.options.sample_mip_filter) {
        .not_mipmapped => .{ .filter = filter },
        .nearest => .{ .filter = filter, .level0 = @intFromFloat(@floor(lod + 0.5)) },
        .linear => blk: {
            const level0_float = @floor(lod);
            const level0: usize = @intFromFloat(level0_float);
            const level1 = @min(level0 + 1, job.sample_mipmaps.len - 1);
            break :blk .{
                .filter = filter,
                .level0 = level0,
                .level1 = level1,
                .level_weight = lod - level0_float,
            };
        },
    };
}

fn sampleSelectionWithFootprint(job: *const Job, rho_x: f32, rho_y: f32, major_u: f32, major_v: f32) SampleSelection {
    const major_rho = @max(rho_x, rho_y);
    const minor_rho = @min(rho_x, rho_y);
    const anisotropic = job.options.sample_max_anisotropy > 1 and
        job.options.sample_min_filter == .linear and job.options.sample_mag_filter == .linear and
        job.options.sample_normalized_coordinates and std.math.isFinite(major_rho) and
        std.math.isFinite(minor_rho) and minor_rho > 0 and major_rho > minor_rho;
    const filter = if (major_rho > 1) job.options.sample_min_filter else job.options.sample_mag_filter;
    var selection = sampleSelection(job, filter, if (anisotropic) minor_rho else major_rho);
    if (anisotropic) {
        selection.anisotropic_major_u = major_u;
        selection.anisotropic_major_v = major_v;
        selection.anisotropic_taps = @intCast(@min(job.options.sample_max_anisotropy, 16));
    }
    return selection;
}

fn effectiveSampleReductionMode(options: DrawOptions) abi.SamplerReductionMode {
    // Metal ignores reductionMode unless all three filtering stages can
    // contribute a linear footprint. Keep this decision at sampler-state
    // level rather than relying on the selected min/mag filter for one pixel.
    if (options.sample_min_filter != .linear or options.sample_mag_filter != .linear or
        options.sample_mip_filter != .linear) return .weighted_average;
    return options.sample_reduction_mode;
}

fn sampleTextureWithSelection(job: *const Job, u: f32, v: f32, selection: SampleSelection) [4]f32 {
    const texture = job.sample_texture.?;
    const reduction_mode = effectiveSampleReductionMode(job.options);
    const tap_count = @max(selection.anisotropic_taps, 1);
    var result = [4]f32{ 0, 0, 0, 0 };
    for (0..tap_count) |tap| {
        const tap_position = if (tap_count == 1) @as(f32, 0) else (@as(f32, @floatFromInt(tap)) + 0.5) / @as(f32, @floatFromInt(tap_count)) - 0.5;
        const tap_u = u + selection.anisotropic_major_u * tap_position;
        const tap_v = v + selection.anisotropic_major_v * tap_position;
        const level0 = if (job.sample_mipmaps.len != 0) &job.sample_mipmaps[selection.level0] else texture;
        const color0 = level0.sample(tap_u, tap_v, selection.filter, job.options.sample_address_s, job.options.sample_address_t, job.options.sample_border_color, job.options.sample_swizzle, job.options.sample_normalized_coordinates, reduction_mode);
        var color = color0;
        if (selection.level1 != selection.level0 and job.sample_mipmaps.len != 0) {
            const color1 = job.sample_mipmaps[selection.level1].sample(tap_u, tap_v, selection.filter, job.options.sample_address_s, job.options.sample_address_t, job.options.sample_border_color, job.options.sample_swizzle, job.options.sample_normalized_coordinates, reduction_mode);
            for (0..4) |channel| color[channel] = color0[channel] +
                (color1[channel] - color0[channel]) * selection.level_weight;
        }
        for (0..4) |channel| result[channel] += color[channel];
    }
    for (0..4) |channel| result[channel] /= @as(f32, @floatFromInt(tap_count));
    return result;
}

fn writePixel(job: *Job, x: usize, y: usize, z: f32, depth_adjust: f32, color: [4]f32, selection: SampleSelection, stats: *Stats, front_facing: bool) void {
    const width: usize = @intCast(job.target.width);
    if (x >= width or y >= job.target.height) return;
    const adjusted_depth = adjustedDepth(job, z, depth_adjust) orelse return;
    stats.fragments_tested += 1;
    const stencil_state = if (front_facing) job.options.stencil_front else job.options.stencil_back;
    var stencil_index: ?usize = null;
    if (job.stencil) |stencil| {
        const index = y * width + x;
        if (index >= stencil.len) return;
        stencil_index = index;
        if (!compareStencil(stencil_state.compare, stencil_state.reference, stencil[index], stencil_state.read_mask)) {
            applyStencil(stencil, index, stencil_state, stencil_state.stencil_failure);
            return;
        }
    }
    if (adjusted_depth < job.options.depth_test_min_bound or adjusted_depth > job.options.depth_test_max_bound) {
        if (stencil_index) |index| applyStencil(job.stencil.?, index, stencil_state, stencil_state.depth_failure);
        return;
    }
    if (job.depth) |depth_buffer| {
        const index = y * width + x;
        if (index >= depth_buffer.len) return;
        const current = depth_buffer[index];
        const passes = switch (job.options.depth_compare) {
            .never => false,
            .less => adjusted_depth < current,
            .equal => adjusted_depth == current,
            .less_equal => adjusted_depth <= current,
            .greater => adjusted_depth > current,
            .not_equal => adjusted_depth != current,
            .greater_equal => adjusted_depth >= current,
            .always => true,
        };
        if (!passes) {
            if (stencil_index) |stencil_pixel_index| applyStencil(job.stencil.?, stencil_pixel_index, stencil_state, stencil_state.depth_failure);
            return;
        }
        if (job.options.depth_write_enabled) depth_buffer[index] = adjusted_depth;
        stats.depth_tests_passed += 1;
    }
    if (stencil_index) |index| applyStencil(job.stencil.?, index, stencil_state, stencil_state.depth_pass);
    const fragment_color = if (job.sample_texture != null)
        sampleTextureWithSelection(job, color[0], color[1], selection)
    else
        job.options.fragment_color orelse color;
    writeColor(job.target, x, y, fragment_color, job.options);
    if (job.options.write_extra_targets) for (job.extra_targets) |target| writeColor(target, x, y, fragment_color, job.options);
    stats.fragments_covered += 1;
    stats.color_writes += 1 + if (job.options.write_extra_targets) @as(u64, @intCast(job.extra_targets.len)) else 0;
}

fn blendChannel(channel: usize, source: f32, destination: f32, source_color: [4]f32, destination_color: [4]f32, blend_color: [4]f32, source_factor: abi.BlendFactor, destination_factor: abi.BlendFactor, operation: abi.BlendOperation) f32 {
    const source_factor_value = blendFactor(channel, source_factor, source_color, destination_color, blend_color);
    const destination_factor_value = blendFactor(channel, destination_factor, source_color, destination_color, blend_color);
    return switch (operation) {
        .add => source * source_factor_value + destination * destination_factor_value,
        .subtract => source * source_factor_value - destination * destination_factor_value,
        .reverse_subtract => destination * destination_factor_value - source * source_factor_value,
        .min => @min(source, destination),
        .max => @max(source, destination),
    };
}

fn blendFactor(channel: usize, factor: abi.BlendFactor, source: [4]f32, destination: [4]f32, blend_color: [4]f32) f32 {
    return switch (factor) {
        .zero => 0,
        .one => 1,
        .source_color => source[channel],
        .one_minus_source_color => 1 - source[channel],
        .source_alpha => source[3],
        .one_minus_source_alpha => 1 - source[3],
        .destination_color => destination[channel],
        .one_minus_destination_color => 1 - destination[channel],
        .destination_alpha => destination[3],
        .one_minus_destination_alpha => 1 - destination[3],
        .source_alpha_saturated => @min(source[3], 1 - destination[3]),
        .blend_color => blend_color[channel],
        .one_minus_blend_color => 1 - blend_color[channel],
        .blend_alpha => blend_color[3],
        .one_minus_blend_alpha => 1 - blend_color[3],
    };
}

fn scissorBounds(options: DrawOptions, width: u32, height: u32) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
    const x0 = @min(@as(usize, options.scissor.x), @as(usize, width));
    const y0 = @min(@as(usize, options.scissor.y), @as(usize, height));
    const x1 = @min(x0 +| @as(usize, options.scissor.width), @as(usize, width));
    const y1 = @min(y0 +| @as(usize, options.scissor.height), @as(usize, height));
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn pixelCoordinate(value: f32, limit: usize) ?usize {
    if (!std.math.isFinite(value) or value < 0 or value >= @as(f32, @floatFromInt(limit))) return null;
    return @intFromFloat(value);
}

fn drawPoint(job: *Job, vertex: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x = pixelCoordinate(vertex.x, bounds.x1) orelse return;
    const y = pixelCoordinate(vertex.y, bounds.y1) orelse return;
    if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) return;
    writePixel(job, x, y, vertex.z, depthBias(job, 0), vertex.color, sampleSelection(job, job.options.sample_mag_filter, 0), stats, true);
}

fn lineSampleSelection(job: *const Job, a: ProjectedVertex, b: ProjectedVertex) SampleSelection {
    if (job.sample_texture == null) return .{ .filter = job.options.sample_mag_filter };
    const steps = @max(@abs(b.x - a.x), @abs(b.y - a.y));
    if (!std.math.isFinite(steps) or steps <= 0) return .{ .filter = job.options.sample_mag_filter };
    const texture = job.sample_texture.?;
    const coordinate_scale_u = if (job.options.sample_normalized_coordinates) @as(f32, @floatFromInt(texture.width)) else 1;
    const coordinate_scale_v = if (job.options.sample_normalized_coordinates) @as(f32, @floatFromInt(texture.height)) else 1;
    const footprint_u = @abs(b.color[0] - a.color[0]) * coordinate_scale_u / steps;
    const footprint_v = @abs(b.color[1] - a.color[1]) * coordinate_scale_v / steps;
    return sampleSelectionWithFootprint(job, footprint_u, footprint_v, (b.color[0] - a.color[0]) / steps, (b.color[1] - a.color[1]) / steps);
}

fn lineSampleFilter(job: *const Job, a: ProjectedVertex, b: ProjectedVertex) abi.SamplerFilter {
    return lineSampleSelection(job, a, b).filter;
}

fn drawLine(job: *Job, a: ProjectedVertex, b: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const steps_float = @ceil(@max(@abs(b.x - a.x), @abs(b.y - a.y)));
    if (!std.math.isFinite(steps_float) or steps_float > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return;
    const steps: usize = @intFromFloat(steps_float);
    if (steps == 0) {
        drawPoint(job, a, y0, y1, stats);
        return;
    }
    const slope = @abs(b.z - a.z) / @as(f32, @floatFromInt(steps));
    const depth_adjust = depthBias(job, slope);
    for (0..steps + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const x_value = a.x + (b.x - a.x) * t;
        const y_value = a.y + (b.y - a.y) * t;
        const x = pixelCoordinate(x_value, bounds.x1) orelse continue;
        const y = pixelCoordinate(y_value, bounds.y1) orelse continue;
        if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) continue;
        writePixel(job, x, y, a.z + (b.z - a.z) * t, depth_adjust, interpolateLineColor(a, b, t), lineSampleSelection(job, a, b), stats, true);
    }
}

fn triangleSampleSelection(job: *const Job, vertices: [3]ProjectedVertex, w0: f32, w1: f32, w2: f32) SampleSelection {
    if (job.sample_texture == null) return .{ .filter = job.options.sample_mag_filter };
    const area = edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
    if (!std.math.isFinite(area) or @abs(area) < 0.000001) return .{ .filter = job.options.sample_mag_filter };
    const dx10 = vertices[1].x - vertices[0].x;
    const dx20 = vertices[2].x - vertices[0].x;
    const dy10 = vertices[1].y - vertices[0].y;
    const dy20 = vertices[2].y - vertices[0].y;
    const denominator = -area;
    const perspective_denominator = vertices[0].inverse_w * w0 + vertices[1].inverse_w * w1 + vertices[2].inverse_w * w2;
    if (!std.math.isFinite(perspective_denominator) or @abs(perspective_denominator) < 0.000001) return .{ .filter = job.options.sample_mag_filter };
    const uq0 = vertices[0].color[0] * vertices[0].inverse_w;
    const uq1 = vertices[1].color[0] * vertices[1].inverse_w;
    const uq2 = vertices[2].color[0] * vertices[2].inverse_w;
    const vq0 = vertices[0].color[1] * vertices[0].inverse_w;
    const vq1 = vertices[1].color[1] * vertices[1].inverse_w;
    const vq2 = vertices[2].color[1] * vertices[2].inverse_w;
    const d_u_dx_numerator = ((uq1 - uq0) * dy20 - (uq2 - uq0) * dy10) / denominator;
    const d_u_dy_numerator = (dx10 * (uq2 - uq0) - dx20 * (uq1 - uq0)) / denominator;
    const d_v_dx_numerator = ((vq1 - vq0) * dy20 - (vq2 - vq0) * dy10) / denominator;
    const d_v_dy_numerator = (dx10 * (vq2 - vq0) - dx20 * (vq1 - vq0)) / denominator;
    const d_w_dx = ((vertices[1].inverse_w - vertices[0].inverse_w) * dy20 -
        (vertices[2].inverse_w - vertices[0].inverse_w) * dy10) / denominator;
    const d_w_dy = (dx10 * (vertices[2].inverse_w - vertices[0].inverse_w) -
        dx20 * (vertices[1].inverse_w - vertices[0].inverse_w)) / denominator;
    const denominator_squared = perspective_denominator * perspective_denominator;
    const du_dx = (d_u_dx_numerator * perspective_denominator -
        (uq0 * w0 + uq1 * w1 + uq2 * w2) * d_w_dx) / denominator_squared;
    const du_dy = (d_u_dy_numerator * perspective_denominator -
        (uq0 * w0 + uq1 * w1 + uq2 * w2) * d_w_dy) / denominator_squared;
    const dv_dx = (d_v_dx_numerator * perspective_denominator -
        (vq0 * w0 + vq1 * w1 + vq2 * w2) * d_w_dx) / denominator_squared;
    const dv_dy = (d_v_dy_numerator * perspective_denominator -
        (vq0 * w0 + vq1 * w1 + vq2 * w2) * d_w_dy) / denominator_squared;
    if (!std.math.isFinite(du_dx) or !std.math.isFinite(du_dy) or
        !std.math.isFinite(dv_dx) or !std.math.isFinite(dv_dy)) return .{ .filter = job.options.sample_mag_filter };
    const texture = job.sample_texture.?;
    const width = if (job.options.sample_normalized_coordinates) @as(f32, @floatFromInt(texture.width)) else 1;
    const height = if (job.options.sample_normalized_coordinates) @as(f32, @floatFromInt(texture.height)) else 1;
    const rho_x = @sqrt((du_dx * width) * (du_dx * width) + (dv_dx * height) * (dv_dx * height));
    const rho_y = @sqrt((du_dy * width) * (du_dy * width) + (dv_dy * height) * (dv_dy * height));
    const major_u = if (rho_x >= rho_y) du_dx else du_dy;
    const major_v = if (rho_x >= rho_y) dv_dx else dv_dy;
    return sampleSelectionWithFootprint(job, rho_x, rho_y, major_u, major_v);
}

fn triangleSampleFilter(job: *const Job, vertices: [3]ProjectedVertex, w0: f32, w1: f32, w2: f32) abi.SamplerFilter {
    return triangleSampleSelection(job, vertices, w0, w1, w2).filter;
}

fn drawTriangle(job: *Job, input: [3]ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const vertices = input;
    const area = edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
    if (!std.math.isFinite(area) or @abs(area) < 0.000001) return;
    const front_facing = if (job.options.winding == .clockwise) area > 0 else area < 0;
    if ((job.options.cull_mode == .front and front_facing) or (job.options.cull_mode == .back and !front_facing)) return;
    if (job.options.fill_mode == .lines) {
        drawLine(job, vertices[0], vertices[1], y0, y1, stats);
        drawLine(job, vertices[1], vertices[2], y0, y1, stats);
        drawLine(job, vertices[2], vertices[0], y0, y1, stats);
        stats.primitives_rasterized += 1;
        return;
    }

    const min_x = @max(@as(f32, 0), @floor(@min(vertices[0].x, @min(vertices[1].x, vertices[2].x))));
    const max_x = @min(@as(f32, @floatFromInt(job.target.width)), @ceil(@max(vertices[0].x, @max(vertices[1].x, vertices[2].x))));
    const min_y = @max(@as(f32, @floatFromInt(@max(y0, @min(@as(usize, job.options.scissor.y), @as(usize, job.target.height))))), @floor(@min(vertices[0].y, @min(vertices[1].y, vertices[2].y))));
    const max_y = @min(@as(f32, @floatFromInt(@min(y1, @as(usize, job.target.height)))), @ceil(@max(vertices[0].y, @max(vertices[1].y, vertices[2].y))));
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x_start: usize = @intFromFloat(@min(max_x, @max(@as(f32, @floatFromInt(bounds.x0)), min_x)));
    const x_end: usize = @intFromFloat(@min(max_x, @as(f32, @floatFromInt(bounds.x1))));
    const row_start: usize = @intFromFloat(@min(max_y, @max(@as(f32, @floatFromInt(bounds.y0)), min_y)));
    const row_end: usize = @intFromFloat(@min(max_y, @as(f32, @floatFromInt(@min(bounds.y1, y1)))));
    if (x_end <= x_start or row_end <= row_start) return;
    const depth_dx = ((vertices[1].z - vertices[0].z) * (vertices[2].y - vertices[0].y) -
        (vertices[2].z - vertices[0].z) * (vertices[1].y - vertices[0].y)) / area;
    const depth_dy = ((vertices[1].x - vertices[0].x) * (vertices[2].z - vertices[0].z) -
        (vertices[2].x - vertices[0].x) * (vertices[1].z - vertices[0].z)) / area;
    const depth_adjust = depthBias(job, @max(@abs(depth_dx), @abs(depth_dy)));
    const inverse_area = 1.0 / @abs(area);
    const positive_area = area > 0;
    const edge_sign: f32 = if (positive_area) 1.0 else -1.0;
    for (row_start..row_end) |y| {
        for (x_start..x_end) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const edge0 = edge(vertices[1], vertices[2], px, py);
            const edge1 = edge(vertices[2], vertices[0], px, py);
            const edge2 = edge(vertices[0], vertices[1], px, py);
            if (outsideTopLeft(edge0 * edge_sign, vertices[1], vertices[2], positive_area) or
                outsideTopLeft(edge1 * edge_sign, vertices[2], vertices[0], positive_area) or
                outsideTopLeft(edge2 * edge_sign, vertices[0], vertices[1], positive_area)) continue;
            const w0 = edge0 * edge_sign * inverse_area;
            const w1 = edge1 * edge_sign * inverse_area;
            const w2 = edge2 * edge_sign * inverse_area;
            writePixel(job, x, y, vertices[0].z * w0 + vertices[1].z * w1 + vertices[2].z * w2, depth_adjust, interpolateTriangleColor(vertices, w0, w1, w2), triangleSampleSelection(job, vertices, w0, w1, w2), stats, front_facing);
        }
    }
    stats.primitives_rasterized += 1;
}

fn drawBand(job: *Job, band: usize) Stats {
    var stats = Stats{ .primitives_submitted = if (band == 0) switch (job.primitive) {
        .point => @intCast(job.vertices.len),
        .line => @intCast(job.vertices.len / 2),
        .line_strip => if (job.vertices.len > 1) @intCast(job.vertices.len - 1) else 0,
        .triangle => @intCast(job.vertices.len / 3),
        .triangle_strip => if (job.vertices.len > 2) @intCast(job.vertices.len - 2) else 0,
    } else 0 };
    const height: usize = @intCast(job.target.height);
    const y0 = height * band / 2;
    const y1 = height * (band + 1) / 2;
    switch (job.primitive) {
        .point => for (job.vertices) |vertex| if (project(vertex, job.options.viewport)) |p| drawPoint(job, p, y0, y1, &stats),
        .line => {
            var index: usize = 0;
            while (index + 1 < job.vertices.len) : (index += 2) {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            }
        },
        .line_strip => {
            if (job.vertices.len > 1) for (0..job.vertices.len - 1) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            };
        },
        .triangle => {
            var index: usize = 0;
            while (index + 2 < job.vertices.len) : (index += 3) {
                const triangle = [3]ProjectedVertex{
                    project(job.vertices[index], job.options.viewport) orelse continue,
                    project(job.vertices[index + 1], job.options.viewport) orelse continue,
                    project(job.vertices[index + 2], job.options.viewport) orelse continue,
                };
                drawTriangle(job, triangle, y0, y1, &stats);
            }
        },
        .triangle_strip => {
            if (job.vertices.len > 2) for (0..job.vertices.len - 2) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const odd = index % 2 != 0;
                const b_index: usize = index + (if (odd) @as(usize, 2) else @as(usize, 1));
                const c_index: usize = index + (if (odd) @as(usize, 1) else @as(usize, 2));
                const b = project(job.vertices[b_index], job.options.viewport) orelse continue;
                const c = project(job.vertices[c_index], job.options.viewport) orelse continue;
                drawTriangle(job, .{ a, b, c }, y0, y1, &stats);
            };
        },
    }
    return stats;
}

fn renderWorker(job: *Job) void {
    job.bands[0] = drawBand(job, 0);
}

fn addStats(a: Stats, b: Stats) Stats {
    return .{
        .primitives_submitted = a.primitives_submitted + b.primitives_submitted,
        .primitives_rasterized = a.primitives_rasterized + b.primitives_rasterized,
        .fragments_tested = a.fragments_tested + b.fragments_tested,
        .fragments_covered = a.fragments_covered + b.fragments_covered,
        .depth_tests_passed = a.depth_tests_passed + b.depth_tests_passed,
        .color_writes = a.color_writes + b.color_writes,
    };
}

pub fn drawWithTargetMipmaps(target: *Target, extra_targets: []const *Target, sample_texture: ?*const Target, sample_mipmaps: []const Target, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    if (!options.rasterization_enabled) return .{ .primitives_submitted = switch (primitive) {
        .point => @intCast(vertices.len),
        .line => @intCast(vertices.len / 2),
        .line_strip => if (vertices.len > 1) @intCast(vertices.len - 1) else 0,
        .triangle => @intCast(vertices.len / 3),
        .triangle_strip => if (vertices.len > 2) @intCast(vertices.len - 2) else 0,
    } };
    var job = Job{ .target = target, .extra_targets = extra_targets, .sample_texture = sample_texture, .sample_mipmaps = sample_mipmaps, .depth = depth, .stencil = stencil, .vertices = vertices, .primitive = primitive, .options = options };
    const worker = std.Thread.spawn(.{}, renderWorker, .{&job}) catch {
        job.bands[0] = drawBand(&job, 0);
        job.bands[1] = drawBand(&job, 1);
        return addStats(job.bands[0], job.bands[1]);
    };
    job.bands[1] = drawBand(&job, 1);
    worker.join();
    return addStats(job.bands[0], job.bands[1]);
}

pub fn drawWithTargets(target: *Target, extra_targets: []const *Target, sample_texture: ?*const Target, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    return drawWithTargetMipmaps(target, extra_targets, sample_texture, &.{}, depth, stencil, vertices, primitive, options);
}

pub fn draw(target: *Target, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    return drawWithTargets(target, &[_]*Target{}, null, depth, stencil, vertices, primitive, options);
}

pub fn drawSurface(target: *surface.Surface, depth: ?[]f32, stencil: ?[]u8, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    var render_target = Target{
        .pixels = target.pixels,
        .width = target.width,
        .height = target.height,
        .stride = target.stride,
        .format = if (target.format == .rgba8_unorm) .rgba8_unorm else .bgra8_unorm,
    };
    return draw(&render_target, depth, stencil, vertices, primitive, options);
}

fn clearSurfaceBand(target: *surface.Surface, color: surface.Color, y0: usize, y1: usize) void {
    if (y1 <= y0) return;
    raster.fillRect(target, .{ .x = 0, .y = @intCast(y0), .width = target.width, .height = @intCast(y1 - y0) }, color);
}

pub fn clearTarget(target: *Target, color: [4]f32) void {
    for (0..target.height) |y| {
        for (0..target.width) |x| target.writeColor(x, y, color, @intFromEnum(abi.ColorWriteMask.all));
    }
}

pub fn clearSurface(target: *surface.Surface, color: surface.Color) void {
    const middle = @as(usize, target.height) / 2;
    const worker = std.Thread.spawn(.{}, clearSurfaceBand, .{ target, color, 0, middle }) catch {
        clearSurfaceBand(target, color, 0, @intCast(target.height));
        return;
    };
    clearSurfaceBand(target, color, middle, target.height);
    worker.join();
}

fn clearDepthBand(depth: []f32, value: f32, y0: usize, y1: usize, width: usize) void {
    for (y0..y1) |y| @memset(depth[y * width ..][0..width], value);
}

pub fn clearDepth(depth: []f32, width: u32, value: f32) void {
    if (width == 0) return;
    const rows = depth.len / @as(usize, width);
    const middle = rows / 2;
    const worker = std.Thread.spawn(.{}, clearDepthBand, .{ depth, value, 0, middle, @as(usize, width) }) catch {
        clearDepthBand(depth, value, 0, rows, @intCast(width));
        return;
    };
    clearDepthBand(depth, value, middle, rows, width);
    worker.join();
}

test "Metal viewport and scissor origins use the top-left pixel grid" {
    var pixels = [_]u8{0} ** (8 * 8 * 4);
    var target = try Target.init(&pixels, 8, 8, 8 * 4, .rgba8_unorm);
    const options = DrawOptions{
        .viewport = .{ .origin_x = 1, .origin_y = 2, .width = 6, .height = 4, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 1, .y = 2, .width = 6, .height = 4 },
    };
    const red = abi.Color{ .red = 1, .green = 0, .blue = 0, .alpha = 1 };
    const blue = abi.Color{ .red = 0, .green = 0, .blue = 1, .alpha = 1 };
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, 0.90, 0.5, 1 }, .color = red },
        .{ .position = .{ 0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, 0.10, 0.5, 1 }, .color = red },
        .{ .position = .{ -0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.90, 0.5, 1 }, .color = blue },
        .{ .position = .{ -0.75, -0.10, 0.5, 1 }, .color = blue },
        .{ .position = .{ 0.75, -0.90, 0.5, 1 }, .color = blue },
        .{ .position = .{ -0.75, -0.90, 0.5, 1 }, .color = blue },
    };
    _ = draw(&target, null, null, &vertices, .triangle, options);

    const red_pixel = surface.Surface.read(target.row(2), 3 * 4, .rgba8_unorm);
    const red_pixel_lower = surface.Surface.read(target.row(3), 3 * 4, .rgba8_unorm);
    const blue_pixel = surface.Surface.read(target.row(4), 3 * 4, .rgba8_unorm);
    const blue_pixel_lower = surface.Surface.read(target.row(5), 3 * 4, .rgba8_unorm);
    try std.testing.expectEqual(surface.Color.rgba(255, 0, 0, 255), red_pixel);
    try std.testing.expectEqual(surface.Color.rgba(255, 0, 0, 255), red_pixel_lower);
    try std.testing.expectEqual(surface.Color.rgba(0, 0, 255, 255), blue_pixel);
    try std.testing.expectEqual(surface.Color.rgba(0, 0, 255, 255), blue_pixel_lower);
    try std.testing.expectEqual(@as(u8, 0), pixels[1 * 8 * 4 + 3 * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[6 * 8 * 4 + 3 * 4]);
    try std.testing.expectEqual(@as(u8, 0), pixels[3 * 8 * 4 + 0 * 4]);
}

test "Metal triangle strips preserve directed edge coverage" {
    var pixels = [_]u8{0} ** (8 * 8 * 4);
    var target = try Target.init(&pixels, 8, 8, 8 * 4, .rgba8_unorm);
    const color = abi.Color{ .red = 0.25, .green = 0.5, .blue = 0.75, .alpha = 1 };
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -0.75, -0.75, 0.5, 1 }, .color = color },
        .{ .position = .{ 0.75, -0.75, 0.5, 1 }, .color = color },
        .{ .position = .{ 0.75, 0.75, 0.5, 1 }, .color = color },
        .{ .position = .{ -0.75, 0.75, 0.5, 1 }, .color = color },
    };
    const options = DrawOptions{
        .viewport = .{ .origin_x = 1, .origin_y = 1, .width = 6, .height = 6, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 2, .y = 1, .width = 4, .height = 5 },
    };
    _ = draw(&target, null, null, &vertices, .triangle_strip, options);
    for (0..8) |y| {
        for (0..8) |x| {
            const covered = (y == 2 and x >= 2 and x <= 5) or
                (y == 3 and x >= 3 and x <= 5) or
                (y == 4 and x >= 3 and x <= 5) or
                (y == 5 and x >= 2 and x <= 5);
            try std.testing.expectEqual(if (covered) @as(u8, 64) else @as(u8, 0), pixels[(y * 8 + x) * 4]);
        }
    }
}

test "Metal depth bias and clip modes are CPU deterministic" {
    var pixels = [_]u8{0} ** (4 * 4 * 4);
    var target = try Target.init(&pixels, 4, 4, 4 * 4, .rgba8_unorm);
    var depth = [_]f32{1} ** (4 * 4);
    const vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.25, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
    };
    var options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 4, .height = 4, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .depth_bias = 0.25,
    };
    _ = draw(&target, depth[0..], null, &vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 0.5), depth[15]);

    pixels = [_]u8{0} ** (4 * 4 * 4);
    depth = [_]f32{1} ** (4 * 4);
    options.depth_bias = 0;
    options.depth_clip_mode = .clip;
    var clipped_vertices = vertices;
    for (&clipped_vertices) |*vertex| vertex.position[2] = 1.25;
    _ = draw(&target, depth[0..], null, &clipped_vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 1), depth[15]);
    try std.testing.expectEqual(@as(u8, 0), pixels[0]);

    options.depth_clip_mode = .clamp;
    _ = draw(&target, depth[0..], null, &clipped_vertices, .triangle, options);
    try std.testing.expectEqual(@as(f32, 1), depth[15]);
    try std.testing.expectEqual(@as(u8, 255), pixels[15 * 4]);
}

test "float color targets retain native texel precision" {
    var r32_bytes = [_]u8{0} ** (2 * 2 * 4);
    var r32 = try Target.init(&r32_bytes, 2, 2, 2 * 4, .r32_float);
    clearTarget(&r32, .{ 0.25, 0.5, 0.75, 1 });
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 0.25))), std.mem.readInt(u32, r32_bytes[0..4], .little));
    try std.testing.expectEqual(@as(f32, 0.25), r32.readColor(0, 0)[0]);

    var rgba16_bytes = [_]u8{0} ** (2 * 2 * 8);
    var rgba16 = try Target.init(&rgba16_bytes, 2, 2, 2 * 8, .rgba16_float);
    clearTarget(&rgba16, .{ 0.25, 0.5, 0.75, 1 });
    const color = rgba16.readColor(0, 0);
    try std.testing.expectEqual(@as(f32, 0.25), color[0]);
    try std.testing.expectEqual(@as(f32, 0.5), color[1]);
    try std.testing.expectEqual(@as(f32, 0.75), color[2]);
    try std.testing.expectEqual(@as(f32, 1), color[3]);
}

test "CPU sRGB targets decode samples and encode stores" {
    var rgba_pixels = [_]u8{0} ** 4;
    var rgba = try Target.init(&rgba_pixels, 1, 1, 4, .rgba8_unorm_srgb);
    rgba.storeColor(0, 0, .{ 0.25, 0.5, 0.75, 0.5 });
    try std.testing.expectEqual([4]u8{ 137, 188, 225, 128 }, rgba_pixels);
    const rgba_color = rgba.readColor(0, 0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), rgba_color[0], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rgba_color[1], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), rgba_color[2], 0.005);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), rgba_color[3], 0.005);

    var bgra_pixels = [_]u8{0} ** 4;
    var bgra = try Target.init(&bgra_pixels, 1, 1, 4, .bgra8_unorm_srgb);
    bgra.storeColor(0, 0, .{ 0.25, 0.5, 0.75, 0.5 });
    try std.testing.expectEqual([4]u8{ 225, 188, 137, 128 }, bgra_pixels);

    var r_pixels = [_]u8{0};
    var r = try Target.init(&r_pixels, 1, 1, 1, .r8_unorm_srgb);
    r.storeColor(0, 0, .{ 0.25, 0, 0, 1 });
    try std.testing.expectEqual(@as(u8, 137), r_pixels[0]);

    var rg_pixels = [_]u8{0} ** 2;
    var rg = try Target.init(&rg_pixels, 1, 1, 2, .rg8_unorm_srgb);
    rg.storeColor(0, 0, .{ 0.25, 0.5, 0, 1 });
    try std.testing.expectEqual([2]u8{ 137, 188 }, rg_pixels);
}

test "CPU sRGB stores use Apple fixed-point conversion boundaries" {
    var pixels = [_]u8{ 0, 0, 0, 0 };
    var target = try Target.init(&pixels, 1, 1, 4, .rgba8_unorm_srgb);
    clearTarget(&target, .{ 0.4045177, 0.4045177, 0.4045177, 1 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 171, 171, 171, 255 }, &pixels);
}

test "narrow unorm color targets retain channel width and masks" {
    var r8_bytes = [_]u8{ 0, 0, 0, 0 };
    var r8 = try Target.init(&r8_bytes, 2, 2, 2, .r8_unorm);
    clearTarget(&r8, .{ 0.25, 0.5, 0.75, 1 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 64, 64, 64 }, &r8_bytes);
    try std.testing.expectApproxEqAbs(@as(f32, 64.0 / 255.0), r8.readColor(1, 1)[0], 0.0001);
    r8.writeColor(0, 0, .{ 1, 0, 0, 1 }, @intFromEnum(abi.ColorWriteMask.green));
    try std.testing.expectEqual(@as(u8, 64), r8_bytes[0]);

    var rg8_bytes = [_]u8{0} ** 4;
    var rg8 = try Target.init(&rg8_bytes, 2, 1, 4, .rg8_unorm);
    rg8.storeColor(0, 0, .{ 0.25, 0.5, 0.75, 1 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 64, 128, 0, 0 }, &rg8_bytes);
    try std.testing.expectApproxEqAbs(@as(f32, 128.0 / 255.0), rg8.readColor(0, 0)[1], 0.0001);
}

test "packed normalized color targets preserve component bits and masks" {
    const color = [4]f32{ 0.25, 0.5, 0.75, 1 };
    const formats = [_]struct { format: TargetFormat, bytes_per_pixel: usize, expected: u32 }{
        .{ .format = .b5g6r5_unorm, .bytes_per_pixel = 2, .expected = 0x4417 },
        .{ .format = .a1bgr5_unorm, .bytes_per_pixel = 2, .expected = 0x442f },
        .{ .format = .abgr4_unorm, .bytes_per_pixel = 2, .expected = 0x48bf },
        .{ .format = .bgr5a1_unorm, .bytes_per_pixel = 2, .expected = 0xa217 },
        .{ .format = .rgb10a2_unorm, .bytes_per_pixel = 4, .expected = 0xeff80100 },
        .{ .format = .bgr10a2_unorm, .bytes_per_pixel = 4, .expected = 0xd00802ff },
    };
    for (formats) |case| {
        var bytes = [_]u8{ 0, 0, 0, 0 };
        var target = try Target.init(&bytes, 1, 1, case.bytes_per_pixel, case.format);
        target.storeColor(0, 0, color);
        const actual = if (case.bytes_per_pixel == 2)
            @as(u32, std.mem.readInt(u16, bytes[0..2], .little))
        else
            std.mem.readInt(u32, bytes[0..4], .little);
        try std.testing.expectEqual(case.expected, actual);
        const decoded = target.readColor(0, 0);
        try std.testing.expectApproxEqAbs(color[0], decoded[0], 1.0 / 15.0);
        try std.testing.expectApproxEqAbs(color[1], decoded[1], 1.0 / 15.0);
        try std.testing.expectApproxEqAbs(color[2], decoded[2], 1.0 / 15.0);
        try std.testing.expectApproxEqAbs(color[3], decoded[3], 1.0 / 3.0);

        const preserved = actual;
        target.writeColor(0, 0, .{ 0, 0, 0, 0 }, @intFromEnum(abi.ColorWriteMask.red));
        const masked = if (case.bytes_per_pixel == 2)
            @as(u32, std.mem.readInt(u16, bytes[0..2], .little))
        else
            std.mem.readInt(u32, bytes[0..4], .little);
        const red_mask: u32 = switch (case.format) {
            .b5g6r5_unorm, .a1bgr5_unorm => 0xf800,
            .abgr4_unorm => 0xf000,
            .bgr5a1_unorm => 0x7c00,
            .rgb10a2_unorm => 0x000003ff,
            .bgr10a2_unorm => 0x3ff00000,
            else => unreachable,
        };
        try std.testing.expectEqual(preserved & ~red_mask, masked & ~red_mask);
    }
}

test "packed float color targets preserve native encodings" {
    const color = [4]f32{ 0.25, 0.5, 0.75, 1 };

    var rg11_bytes = [_]u8{0} ** 4;
    var rg11 = try Target.init(&rg11_bytes, 1, 1, 4, .rg11b10_float);
    rg11.storeColor(0, 0, color);
    try std.testing.expectEqual(@as(u32, 0x741c0340), std.mem.readInt(u32, rg11_bytes[0..4], .little));
    const rg11_color = rg11.readColor(0, 0);
    try std.testing.expectEqual(@as(f32, 0.25), rg11_color[0]);
    try std.testing.expectEqual(@as(f32, 0.5), rg11_color[1]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), rg11_color[2], 0.001);
    rg11.writeColor(0, 0, .{ 0, 0, 0, 1 }, @intFromEnum(abi.ColorWriteMask.red));
    try std.testing.expectEqual(@as(u32, 0x741c0000), std.mem.readInt(u32, rg11_bytes[0..4], .little));

    var rgb9e5_bytes = [_]u8{0} ** 4;
    var rgb9e5 = try Target.init(&rgb9e5_bytes, 1, 1, 4, .rgb9e5_float);
    rgb9e5.storeColor(0, 0, color);
    try std.testing.expectEqual(@as(u32, 0x7e020080), std.mem.readInt(u32, rgb9e5_bytes[0..4], .little));
    const rgb9e5_color = rgb9e5.readColor(0, 0);
    try std.testing.expectEqual(@as(f32, 0.25), rgb9e5_color[0]);
    try std.testing.expectEqual(@as(f32, 0.5), rgb9e5_color[1]);
    try std.testing.expectEqual(@as(f32, 0.75), rgb9e5_color[2]);
    try std.testing.expectEqual(@as(f32, 1), rgb9e5_color[3]);
}

test "CPU texture sampling uses normalized top-left texel coordinates" {
    var pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const target = try Target.init(&pixels, 2, 2, 2 * 4, .rgba8_unorm);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.25, 0.25, .clamp_to_edge, .clamp_to_edge, .transparent_black)[0]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.75, 0.25, .clamp_to_edge, .clamp_to_edge, .transparent_black)[1]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.25, 0.75, .clamp_to_edge, .clamp_to_edge, .transparent_black)[2]);
    try std.testing.expectEqual(@as(f32, 1), target.sampleNearest(0.75, 0.75, .clamp_to_edge, .clamp_to_edge, .transparent_black)[0]);
}

test "CPU texture sampling supports linear filtering and address modes" {
    var pixels = [_]u8{
        255, 0, 0,   255, 0,   255, 0,   255,
        0,   0, 255, 255, 255, 255, 255, 255,
    };
    const target = try Target.init(&pixels, 2, 2, 2 * 4, .rgba8_unorm);
    const center = target.sampleLinear(0.5, 0.5, .clamp_to_edge, .clamp_to_edge, .transparent_black, .weighted_average);
    for (center[0..3]) |channel| try std.testing.expectApproxEqAbs(@as(f32, 0.5), channel, 0.001);
    try std.testing.expectEqual(@as(f32, 1), center[3]);

    const repeated = target.sampleNearest(1.25, 0.25, .repeat, .repeat, .transparent_black);
    try std.testing.expectEqual(@as(f32, 1), repeated[0]);
    try std.testing.expectEqual(@as(f32, 0), repeated[1]);
    const mirrored = target.sampleNearest(1.25, 0.25, .mirror_repeat, .mirror_repeat, .transparent_black);
    try std.testing.expectEqual(@as(f32, 1), mirrored[1]);
    const mirror_clamped = target.sampleNearest(-0.25, 0.25, .mirror_clamp_to_edge, .mirror_clamp_to_edge, .transparent_black);
    try std.testing.expectEqual(@as(f32, 1), mirror_clamped[0]);
    const outside = target.sampleNearest(-0.25, 0.25, .clamp_to_zero, .clamp_to_zero, .transparent_black);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, outside);
    const border = target.sampleNearest(-0.25, 0.25, .clamp_to_border_color, .clamp_to_border_color, .opaque_white);
    try std.testing.expectEqual([4]f32{ 1, 1, 1, 1 }, border);

    var scalar_pixels = [_]u8{ 0, 0, 128, 63 };
    const scalar_target = try Target.init(&scalar_pixels, 1, 1, 4, .r32_float);
    const scalar_outside = scalar_target.sampleNearest(-0.25, 0.5, .clamp_to_zero, .clamp_to_zero, .transparent_black);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 1 }, scalar_outside);
}

test "CPU texture sampling applies texture-view channel swizzles" {
    var pixels = [_]u8{ 255, 0, 0, 255 };
    const target = try Target.init(&pixels, 1, 1, 4, .rgba8_unorm);
    const swizzled = target.sample(0.5, 0.5, .nearest, .clamp_to_edge, .clamp_to_edge, .transparent_black, .{
        .red = .blue,
        .green = .red,
        .blue = .one,
        .alpha = .zero,
    }, true, .weighted_average);
    try std.testing.expectEqual([4]f32{ 0, 1, 1, 0 }, swizzled);
}

test "CPU sampler selects minification and magnification filters from footprint" {
    var output_pixels = [_]u8{0} ** 16;
    var source_pixels = [_]u8{0} ** 64;
    var output = try Target.init(&output_pixels, 2, 2, 2 * 4, .rgba8_unorm);
    var source = try Target.init(&source_pixels, 4, 4, 4 * 4, .rgba8_unorm);
    var vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, -1, 0.5, 1 }, .color = .{ .red = 1, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 1, 1, 0.5, 1 }, .color = .{ .red = 1, .green = 1, .blue = 0, .alpha = 1 } },
    };
    const options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 2, .height = 2, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .sample_min_filter = .linear,
        .sample_mag_filter = .nearest,
    };
    var projected = [3]ProjectedVertex{
        project(vertices[0], options.viewport).?,
        project(vertices[1], options.viewport).?,
        project(vertices[2], options.viewport).?,
    };
    var job = Job{
        .target = &output,
        .extra_targets = &[_]*Target{},
        .sample_texture = &source,
        .sample_mipmaps = &.{},
        .depth = null,
        .stencil = null,
        .vertices = &vertices,
        .primitive = .triangle,
        .options = options,
    };
    try std.testing.expectEqual(abi.SamplerFilter.linear, triangleSampleFilter(&job, projected, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0));
    projected[1].color = .{ 0.1, 0, 0, 1 };
    projected[2].color = .{ 0.1, 0.1, 0, 1 };
    try std.testing.expectEqual(abi.SamplerFilter.nearest, triangleSampleFilter(&job, projected, 1.0 / 3.0, 1.0 / 3.0, 1.0 / 3.0));
}

test "CPU sampler LOD uses perspective-correct texture derivatives" {
    var output_pixels = [_]u8{0} ** 16;
    var source_pixels = [_]u8{0} ** 64;
    var output = try Target.init(&output_pixels, 2, 2, 2 * 4, .rgba8_unorm);
    var source = try Target.init(&source_pixels, 4, 4, 4 * 4, .rgba8_unorm);
    const options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 2, .height = 2, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 2, .height = 2 },
        .sample_min_filter = .linear,
        .sample_mag_filter = .nearest,
    };
    var vertices = [_]abi.Vertex{
        .{ .position = .{ -1, -1, 0.5, 1 }, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0.5, -0.5, 0.5, 0.5 }, .color = .{ .red = 0.5, .green = 0, .blue = 0, .alpha = 1 } },
        .{ .position = .{ 0, 1, 0.5, 2 }, .color = .{ .red = 1, .green = 1, .blue = 0, .alpha = 1 } },
    };
    const projected = [3]ProjectedVertex{
        project(vertices[0], options.viewport).?,
        project(vertices[1], options.viewport).?,
        project(vertices[2], options.viewport).?,
    };
    var job = Job{
        .target = &output,
        .extra_targets = &[_]*Target{},
        .sample_texture = &source,
        .sample_mipmaps = &.{},
        .depth = null,
        .stencil = null,
        .vertices = &vertices,
        .primitive = .triangle,
        .options = options,
    };
    const area = edge(projected[0], projected[1], projected[2].x, projected[2].y);
    const inverse_area = 1.0 / @abs(area);
    const edge_sign: f32 = if (area > 0) 1.0 else -1.0;
    const sample_x: f32 = 0.5;
    const sample_y: f32 = 0.5;
    const w0 = edge(projected[1], projected[2], sample_x, sample_y) * edge_sign * inverse_area;
    const w1 = edge(projected[2], projected[0], sample_x, sample_y) * edge_sign * inverse_area;
    const w2 = edge(projected[0], projected[1], sample_x, sample_y) * edge_sign * inverse_area;
    try std.testing.expectEqual(abi.SamplerFilter.linear, triangleSampleFilter(&job, projected, w0, w1, w2));
}

test "CPU sampler mip filter selects clamped levels" {
    var level0_pixels = [_]u8{0} ** 64;
    var level1_pixels = [_]u8{0} ** 16;
    var level2_pixels = [_]u8{0} ** 4;
    var level0 = try Target.init(&level0_pixels, 4, 4, 16, .rgba8_unorm);
    const level1 = try Target.init(&level1_pixels, 2, 2, 8, .rgba8_unorm);
    const level2 = try Target.init(&level2_pixels, 1, 1, 4, .rgba8_unorm);
    var levels = [_]Target{ level0, level1, level2 };
    const options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 4, .height = 4, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 4, .height = 4 },
        .sample_mip_filter = .nearest,
    };
    var job = Job{
        .target = &level0,
        .extra_targets = &[_]*Target{},
        .sample_texture = &level0,
        .sample_mipmaps = &levels,
        .depth = null,
        .stencil = null,
        .vertices = &[_]abi.Vertex{},
        .primitive = .triangle,
        .options = options,
    };
    try std.testing.expectEqual(@as(usize, 2), sampleSelection(&job, .nearest, 4).level0);
    job.options.sample_mip_filter = .linear;
    job.options.sample_lod_min_clamp = 0.5;
    job.options.sample_lod_max_clamp = 1.5;
    const selection = sampleSelection(&job, .linear, 0.25);
    try std.testing.expectEqual(@as(usize, 0), selection.level0);
    try std.testing.expectEqual(@as(usize, 1), selection.level1);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), selection.level_weight, 0.000001);

    job.options.sample_lod_min_clamp = 0;
    job.options.sample_lod_max_clamp = std.math.floatMax(f32);
    job.options.sample_lod_bias = 1;
    const biased = sampleSelection(&job, .nearest, 1);
    try std.testing.expectEqual(@as(usize, 1), biased.level0);
}

test "CPU sampler reduction modes reduce bilinear texels per channel" {
    var pixels = [_]u8{
        255, 0,  64,  255, 0,   128, 32, 255,
        64,  64, 255, 255, 128, 32,  16, 255,
    };
    const target = try Target.init(&pixels, 2, 2, 2 * 4, .rgba8_unorm);
    const minimum = target.sampleLinear(0.5, 0.5, .clamp_to_edge, .clamp_to_edge, .transparent_black, .minimum);
    const maximum = target.sampleLinear(0.5, 0.5, .clamp_to_edge, .clamp_to_edge, .transparent_black, .maximum);
    const minimum_expected = [4]f32{ 0, 0, 16.0 / 255.0, 1 };
    const maximum_expected = [4]f32{ 1, 128.0 / 255.0, 1, 1 };
    for (0..4) |channel| {
        try std.testing.expectApproxEqAbs(minimum_expected[channel], minimum[channel], 0.000001);
        try std.testing.expectApproxEqAbs(maximum_expected[channel], maximum[channel], 0.000001);
    }
}

test "CPU sampler ignores reduction when Metal filtering disables it" {
    const weighted_options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 1, .height = 1, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
    };
    try std.testing.expectEqual(abi.SamplerReductionMode.weighted_average, effectiveSampleReductionMode(weighted_options));

    var options = DrawOptions{
        .viewport = weighted_options.viewport,
        .scissor = weighted_options.scissor,
        .sample_min_filter = .linear,
        .sample_mag_filter = .linear,
        .sample_mip_filter = .nearest,
        .sample_reduction_mode = .minimum,
    };
    try std.testing.expectEqual(abi.SamplerReductionMode.weighted_average, effectiveSampleReductionMode(options));
    options.sample_mip_filter = .linear;
    try std.testing.expectEqual(abi.SamplerReductionMode.minimum, effectiveSampleReductionMode(options));
    options.sample_mag_filter = .nearest;
    try std.testing.expectEqual(abi.SamplerReductionMode.weighted_average, effectiveSampleReductionMode(options));
}

test "CPU sampler uses bounded anisotropic major-axis taps" {
    var source_pixels = [_]u8{
        0, 0, 0, 255, 85, 0, 0, 255, 170, 0, 0, 255, 255, 0, 0, 255,
    };
    var source = try Target.init(&source_pixels, 4, 1, 4 * 4, .rgba8_unorm);
    const options = DrawOptions{
        .viewport = .{ .origin_x = 0, .origin_y = 0, .width = 1, .height = 1, .znear = 0, .zfar = 1 },
        .scissor = .{ .x = 0, .y = 0, .width = 1, .height = 1 },
        .sample_min_filter = .linear,
        .sample_mag_filter = .linear,
        .sample_max_anisotropy = 2,
    };
    const selection = sampleSelectionWithFootprint(&Job{
        .target = &source,
        .extra_targets = &.{},
        .sample_texture = &source,
        .sample_mipmaps = &.{},
        .depth = null,
        .stencil = null,
        .vertices = &.{},
        .primitive = .point,
        .options = options,
    }, 4, 1, 0.75, 0);
    var job = Job{
        .target = &source,
        .extra_targets = &.{},
        .sample_texture = &source,
        .sample_mipmaps = &.{},
        .depth = null,
        .stencil = null,
        .vertices = &.{},
        .primitive = .point,
        .options = options,
    };
    try std.testing.expectEqual(@as(usize, 2), selection.anisotropic_taps);
    const sampled = sampleTextureWithSelection(&job, 0.5, 0.5, selection);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), sampled[0], 0.001);
}

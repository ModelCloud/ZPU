const builtin = @import("builtin");
const std = @import("std");
const config = @import("zpu_config");
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
    extern fn zpu_v3_fill_span_8([*]u8, usize, usize, usize, u8, u32) void;
    extern fn zpu_v3_blend_span_8([*]u8, usize, usize, usize, u8, u32) void;
    extern fn zpu_v3_blend_pixels_8([*]u8, usize, usize, [*]const u8, usize, usize, u8) void;
};

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
            v3.zpu_v3_fill_span_8(row.ptr, row.len, start, count, @intFromEnum(format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}
pub fn blendSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.blendSpan(row, start, count, format, color),
        .portable_vector => vector.blend(4, row, start, count, format, color),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.zpu_v3_blend_span_8(row.ptr, row.len, start, count, @intFromEnum(format), packColor(color));
        } else @panic("eight-lane kernels require an x86_64 artifact target"),
    }
}
pub fn blendPixels(backend: Backend, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    switch (backend) {
        .scalar => scalar.blendPixels(row, start, source, count, format),
        .portable_vector => vector.blendPixels(4, row, start, source, count, format),
        .avx2 => if (comptime eight_lane_boundary) {
            requireEightLaneSupport();
            v3.zpu_v3_blend_pixels_8(row.ptr, row.len, start, source.ptr, source.len, count, @intFromEnum(format));
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

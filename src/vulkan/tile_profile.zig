// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const builtin = @import("builtin");
const std = @import("std");
const build_caps = @import("build_caps.zig");

pub const IsaClass = enum { scalar, portable_vector, avx2, avx512 };

pub const Capabilities = struct {
    avx: bool = false,
    osxsave: bool = false,
    ymm_state: bool = false,
    zmm_state: bool = false,
    avx2: bool = false,
    avx512f: bool = false,
};

/// Separates CPU capability from the kernel objects actually present in the
/// artifact. A host feature bit alone must never make an unsupported backend
/// executable.
pub const CompiledKernels = build_caps.Compiled;

pub const Profile = struct {
    host_class: IsaClass,
    executable_class: IsaClass,
    scheduler_w: u16,
    scheduler_h: u16,
    micro_w: u8,
    micro_h: u8,
    group_w: u8,
    group_h: u8,
    command_batch: u8,
    vector_lanes: u8,

    pub fn schedulerPixels(self: Profile) u32 {
        return @as(u32, self.scheduler_w) * self.scheduler_h;
    }

    pub fn groupTiles(self: Profile) u16 {
        return @as(u16, self.group_w) * self.group_h;
    }
};

pub const baseline = Profile{
    .host_class = .scalar,
    .executable_class = .scalar,
    .scheduler_w = 8,
    .scheduler_h = 8,
    .micro_w = 1,
    .micro_h = 1,
    .group_w = 1,
    .group_h = 1,
    .command_batch = 4,
    .vector_lanes = 1,
};

pub fn hostClass(caps: Capabilities) IsaClass {
    const avx2_ready = caps.avx and caps.osxsave and caps.ymm_state and caps.avx2;
    const avx512_ready = avx2_ready and caps.zmm_state and caps.avx512f;
    if (avx512_ready) return .avx512;
    if (avx2_ready) return .avx2;
    return .portable_vector;
}

/// Initial deterministic candidate policy. Geometry is keyed primarily to the
/// executable kernel width; wider host capability may be recorded for future
/// autotuning but does not silently change the active kernel or its scheduler
/// shape until measurements justify doing so.
pub fn choose(caps: Capabilities, compiled: CompiledKernels) Profile {
    const host = hostClass(caps);
    const can_avx2 = (host == .avx2 or host == .avx512) and compiled.hasClusteredAvx2();
    const can_avx512 = host == .avx512 and compiled.hasClusteredAvx512();

    if (can_avx512) return .{
        .host_class = host,
        .executable_class = .avx512,
        .scheduler_w = 64,
        .scheduler_h = 16,
        .micro_w = 16,
        .micro_h = 4,
        .group_w = 2,
        .group_h = 4,
        .command_batch = 24,
        .vector_lanes = 16,
    };
    if (can_avx2) return .{
        .host_class = host,
        .executable_class = .avx2,
        .scheduler_w = 32,
        .scheduler_h = 32,
        .micro_w = 8,
        .micro_h = 4,
        .group_w = 2,
        .group_h = 2,
        .command_batch = 16,
        .vector_lanes = 8,
    };
    if (compiled.portable_vector) return .{
        .host_class = host,
        .executable_class = .portable_vector,
        .scheduler_w = 16,
        .scheduler_h = 16,
        .micro_w = 4,
        .micro_h = 2,
        .group_w = 2,
        .group_h = 2,
        .command_batch = 8,
        .vector_lanes = 4,
    };
    var result = baseline;
    result.host_class = host;
    return result;
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
    }
    return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
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
    }
    return 0;
}

pub fn detectCapabilities() Capabilities {
    if (comptime builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return .{};
    const leaf0 = cpuid(0, 0);
    if (leaf0.a < 1) return .{};
    const leaf1 = cpuid(1, 0);
    const osxsave = leaf1.c & (1 << 27) != 0;
    const avx = leaf1.c & (1 << 28) != 0;
    const xcr0 = if (osxsave and avx) xgetbv() else 0;
    const ymm_state = (xcr0 & 0x6) == 0x6;
    const zmm_state = (xcr0 & 0xe6) == 0xe6;
    const leaf7 = if (leaf0.a >= 7) cpuid(7, 0) else Cpuid{ .a = 0, .b = 0, .c = 0, .d = 0 };
    return .{
        .avx = avx,
        .osxsave = osxsave,
        .ymm_state = ymm_state,
        .zmm_state = zmm_state,
        .avx2 = leaf7.b & (1 << 5) != 0,
        .avx512f = leaf7.b & (1 << 16) != 0,
    };
}

pub fn detect(compiled: CompiledKernels) Profile {
    return choose(detectCapabilities(), compiled);
}

test "kernel linkage gates executable ISA" {
    const host_avx512 = Capabilities{ .avx = true, .osxsave = true, .ymm_state = true, .zmm_state = true, .avx2 = true, .avx512f = true };
    const portable = choose(host_avx512, .{});
    try std.testing.expectEqual(IsaClass.avx512, portable.host_class);
    try std.testing.expectEqual(IsaClass.portable_vector, portable.executable_class);
    try std.testing.expectEqual(@as(u8, 4), portable.vector_lanes);

    const avx2 = choose(host_avx512, .{ .clustered_primitive_avx2 = true });
    try std.testing.expectEqual(IsaClass.avx2, avx2.executable_class);
    try std.testing.expectEqual(@as(u16, 32), avx2.scheduler_w);
    try std.testing.expectEqual(@as(u8, 8), avx2.vector_lanes);

    const avx512 = choose(host_avx512, .{ .clustered_primitive_avx2 = true, .clustered_pixel_avx512 = true });
    try std.testing.expectEqual(IsaClass.avx512, avx512.executable_class);
    try std.testing.expectEqual(@as(u8, 16), avx512.vector_lanes);
}

test "OS vector state gates host class" {
    const no_ymm = choose(.{ .avx = true, .osxsave = true, .avx2 = true }, .{ .clustered_primitive_avx2 = true });
    try std.testing.expectEqual(IsaClass.portable_vector, no_ymm.executable_class);
    const no_zmm = choose(.{ .avx = true, .osxsave = true, .ymm_state = true, .avx2 = true, .avx512f = true }, .{ .clustered_primitive_avx2 = true, .clustered_pixel_avx512 = true });
    try std.testing.expectEqual(IsaClass.avx2, no_zmm.host_class);
    try std.testing.expectEqual(IsaClass.avx2, no_zmm.executable_class);
}

test "profile geometry remains aligned" {
    const caps = Capabilities{ .avx = true, .osxsave = true, .ymm_state = true, .zmm_state = true, .avx2 = true, .avx512f = true };
    const profiles = [_]Profile{ choose(.{}, .{}), choose(caps, .{ .clustered_primitive_avx2 = true }), choose(caps, .{ .clustered_primitive_avx2 = true, .clustered_pixel_avx512 = true }) };
    for (profiles) |profile| {
        try std.testing.expect(profile.scheduler_w % profile.micro_w == 0);
        try std.testing.expect(profile.scheduler_h % profile.micro_h == 0);
        try std.testing.expect(profile.schedulerPixels() >= @as(u32, profile.micro_w) * profile.micro_h);
        try std.testing.expect(profile.groupTiles() != 0);
    }
}

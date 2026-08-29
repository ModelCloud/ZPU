// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Artifact capabilities. Host CPUID answers what the machine can execute;
//! this module answers which exact kernel families were linked into the
//! artifact. Keeping the two questions separate prevents a surface-only v3
//! library from accidentally enabling an unlinked clustered raster kernel.

pub const Compiled = struct {
    portable_vector: bool = true,
    surface_avx2: bool = false,
    clustered_primitive_avx2: bool = false,
    clustered_pixel_avx2: bool = false,
    surface_avx512: bool = false,
    clustered_primitive_avx512: bool = false,
    clustered_pixel_avx512: bool = false,

    pub fn hasClusteredAvx2(self: Compiled) bool {
        return self.clustered_primitive_avx2 or self.clustered_pixel_avx2;
    }

    pub fn hasClusteredAvx512(self: Compiled) bool {
        return self.clustered_primitive_avx512 or self.clustered_pixel_avx512;
    }
};

/// Direct source-file tests and the current clustered planner have no
/// clustered ISA kernels linked. This is deliberately conservative.
pub const standalone = Compiled{};

pub fn surfaceOnly(avx2: bool, avx512: bool) Compiled {
    return .{ .portable_vector = true, .surface_avx2 = avx2, .surface_avx512 = avx512 };
}

test "surface linkage never implies clustered linkage" {
    const std = @import("std");
    const caps = surfaceOnly(true, true);
    try std.testing.expect(caps.surface_avx2);
    try std.testing.expect(caps.surface_avx512);
    try std.testing.expect(!caps.hasClusteredAvx2());
    try std.testing.expect(!caps.hasClusteredAvx512());
}

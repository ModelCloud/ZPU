// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! ZPU CPU graphics foundation and experimental loader-compatible Vulkan ICD.
const config = @import("zpu_config");
const build_caps = @import("vulkan/build_caps.zig");

/// Build-time facts about linked kernel families. Surface SIMD availability
/// is deliberately independent from clustered primitive/pixel availability.
pub const compiled_capabilities = build_caps.Compiled{
    .surface_avx2 = config.surface_avx2,
    .clustered_primitive_avx2 = config.clustered_primitive_avx2,
    .clustered_pixel_avx2 = config.clustered_pixel_avx2,
    .surface_avx512 = config.surface_avx512,
    .clustered_primitive_avx512 = config.clustered_primitive_avx512,
    .clustered_pixel_avx512 = config.clustered_pixel_avx512,
};

pub const surface = @import("surface.zig");
pub const raster = @import("raster/raster.zig");
pub const simd = @import("simd/dispatch.zig");
pub const command = @import("command/processor.zig");
pub const vulkan = @import("vulkan/icd.zig");
pub const platform = @import("platform/presenter.zig");
pub const benchmark = @import("benchmark.zig");
pub const render_pipeline = @import("render_pipeline.zig");
pub const render_ir_exec = @import("vulkan/render_ir_exec.zig");

/// Experimental render-redesign APIs are kept behind an explicit namespace
/// until their execution and Vulkan hazard contracts stabilize.
pub const experimental = struct {
    pub const pass_dag = @import("render/pass_dag.zig");
    pub const cluster_pipeline = @import("render/cluster_pipeline.zig");
    pub const clustered_backend = @import("render/clustered_backend.zig");
    pub const prepared_primitives = @import("render/prepared_primitives.zig");
    pub const scalar_packet = @import("render/scalar_packet.zig");
};

test {
    _ = @import("tests.zig");
    _ = @import("vulkan/driver.zig");
    _ = @import("render_pipeline.zig");
    _ = @import("vulkan/render_ir_exec.zig");
    _ = @import("render/pass_dag.zig");
    _ = @import("render/cluster_pipeline.zig");
    _ = @import("render/clustered_backend.zig");
    _ = @import("render/prepared_primitives.zig");
    _ = @import("render/scalar_packet.zig");
}

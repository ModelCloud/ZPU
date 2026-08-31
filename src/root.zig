// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! ZPU CPU graphics foundation and experimental loader-compatible Vulkan ICD.
const config = @import("zpu_config");
const build_caps = @import("vulkan/build_caps.zig");

/// Build-time facts about linked kernel families. Surface SIMD availability
/// is deliberately independent from Mosaic primitive/pixel availability.
pub const compiled_capabilities = build_caps.Compiled{
    .surface_avx2 = config.surface_avx2,
    .mosaic_primitive_avx2 = config.mosaic_primitive_avx2,
    .mosaic_pixel_avx2 = config.mosaic_pixel_avx2,
    .surface_avx512 = config.surface_avx512,
    .mosaic_primitive_avx512 = config.mosaic_primitive_avx512,
    .mosaic_pixel_avx512 = config.mosaic_pixel_avx512,
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
pub const metal = @import("metal.zig");

/// Experimental render-redesign APIs are kept behind an explicit namespace
/// until their execution and Vulkan hazard contracts stabilize.
pub const experimental = struct {
    /// Mosaic is ZPU's hierarchy-first, packetized tile renderer. The API is
    /// experimental until its Vulkan execution and hazard contracts stabilize.
    pub const mosaic = struct {
        pub const pass_dag = @import("render/pass_dag.zig");
        pub const pipeline = @import("render/mosaic_pipeline.zig");
        pub const backend = @import("render/mosaic_backend.zig");
        pub const prepared_primitives = @import("render/prepared_primitives.zig");
        pub const scalar_packet = @import("render/scalar_packet.zig");
    };
};

test {
    _ = @import("tests.zig");
    _ = @import("vulkan/driver.zig");
    _ = @import("render_pipeline.zig");
    _ = @import("vulkan/render_ir_exec.zig");
    _ = @import("metal/abi.zig");
    _ = @import("metal/mapping.zig");
    _ = @import("metal/cpu.zig");
    _ = @import("cpu_ml.zig");
    _ = @import("metal/c_api.zig");
    _ = @import("metal/runtime.zig");
    _ = @import("render/pass_dag.zig");
    _ = @import("render/mosaic_pipeline.zig");
    _ = @import("render/mosaic_backend.zig");
    _ = @import("render/prepared_primitives.zig");
    _ = @import("render/scalar_packet.zig");
}

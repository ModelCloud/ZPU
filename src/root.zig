// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! ZPU CPU graphics foundation and experimental loader-compatible Vulkan ICD.
pub const surface = @import("surface.zig");
pub const raster = @import("raster/raster.zig");
pub const simd = @import("simd/dispatch.zig");
pub const command = @import("command/processor.zig");
pub const vulkan = @import("vulkan/icd.zig");
pub const platform = @import("platform/presenter.zig");
pub const benchmark = @import("benchmark.zig");
pub const render_pipeline = @import("render_pipeline.zig");
pub const render_ir_exec = @import("vulkan/render_ir_exec.zig");
pub const pass_dag = @import("render/pass_dag.zig");
pub const cluster_pipeline = @import("render/cluster_pipeline.zig");
pub const clustered_backend = @import("render/clustered_backend.zig");

test {
    _ = @import("tests.zig");
    _ = @import("vulkan/driver.zig");
    _ = @import("render_pipeline.zig");
    _ = @import("vulkan/render_ir_exec.zig");
    _ = @import("render/pass_dag.zig");
    _ = @import("render/cluster_pipeline.zig");
    _ = @import("render/clustered_backend.zig");
}

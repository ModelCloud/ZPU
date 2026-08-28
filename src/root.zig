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
pub const metal = @import("metal.zig");

test {
    _ = @import("tests.zig");
    _ = @import("vulkan/driver.zig");
    _ = @import("render_pipeline.zig");
    _ = @import("vulkan/render_ir_exec.zig");
    _ = @import("metal/abi.zig");
    _ = @import("metal/cpu.zig");
}

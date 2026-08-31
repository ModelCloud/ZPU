// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Module-root adapter for the public C Metal-shaped entry points.
//!
//! Keeping this root under `src/` lets the implementation share the same
//! source tree as the rest of ZPU while satisfying Zig 0.16's module import
//! boundary checks.

const api = @import("metal/c_api.zig");
const abi = @import("metal/abi.zig");
const ml_cpu = @import("metal/ml_cpu.zig");
const runtime = @import("metal/runtime.zig");

comptime {
    // Keep the exported resource/encoder functions in the standalone C
    // library even though the one-shot entry point lives in c_api.zig.
    _ = runtime;
    _ = ml_cpu;
}

pub const CSurface = api.CSurface;
pub const CDrawState = api.CDrawState;
pub const CStats = api.CStats;

pub export fn zpu_metal_render(
    target: ?*api.CSurface,
    pass: ?*const abi.RenderPassDescriptor,
    state: ?*const api.CDrawState,
    vertices: ?[*]const abi.Vertex,
    vertex_count: usize,
    primitive_raw: u8,
    depth_ptr: ?[*]f32,
    depth_count: usize,
    stats_out: ?*api.CStats,
) callconv(.c) c_int {
    return api.zpu_metal_render(target, pass, state, vertices, vertex_count, primitive_raw, depth_ptr, depth_count, stats_out);
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cube = @import("vulkan/cpu_cube.zig");

// This benchmark measures the Vulkan command-to-Mosaic submission boundary.
// The upstream projects below are workload references, not runtime
// dependencies and not claims that this narrow renderer implements them.
pub const schema_version: u32 = 3;
pub const width: u32 = 800;
pub const height: u32 = 600;
pub const target_cpu_cores: u8 = 2;
pub const target_speedup: f64 = 4.0;

const surface_bytes = @as(usize, width) * height * 4;
const clear_color: u32 = 0x19191919;
const clear_depth: u32 = @bitCast(@as(f32, 1));
const max_samples = 8;
const legacy_batch_limit: usize = 256;
const mosaic_batch_limit: usize = cube.max_batch_commands;

const Mode = enum { per_draw, legacy_batched, mosaic_batched };
const Target = enum {
    wezterm_terminal,
    imgui_vulkan_app,
    khronos_complex_demo,
    vkquake_fps,
    vkquake2_fps,
    vkdoom_fps,
    vulkan_voxel_world,
    space_menace_platformer,
};

const TargetSpec = struct {
    id: []const u8,
    project: []const u8,
    shape: []const u8,
    draw_count: usize,
    vertices_per_draw: u32,
    texture_width: u32,
    texture_height: u32,
};

fn spec(target: Target) TargetSpec {
    return switch (target) {
        .wezterm_terminal => .{
            .id = "wezterm-vulkan-terminal-v1-800x600",
            .project = "https://github.com/wezterm/wezterm",
            .shape = "120x40 glyph grid plus background",
            .draw_count = 4_801,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .imgui_vulkan_app => .{
            .id = "imgui-sdl2-vulkan-app-v1-800x600",
            .project = "https://github.com/ocornut/imgui",
            .shape = "dockable desktop UI panels, controls, icons, and text",
            .draw_count = 192,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .khronos_complex_demo => .{
            .id = "khronos-vulkan-samples-complex-v1-800x600",
            .project = "https://github.com/KhronosGroup/Vulkan-Samples",
            .shape = "materialized scene objects with six quad faces each",
            .draw_count = 128,
            .vertices_per_draw = 36,
            .texture_width = 4,
            .texture_height = 4,
        },
        .vkquake_fps => .{
            .id = "vkquake-fps-v1-800x600",
            .project = "https://github.com/Novum/vkQuake",
            .shape = "BSP-like world surfaces, entities, particles, sky, and HUD",
            .draw_count = 2_048,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .vkquake2_fps => .{
            .id = "vkquake2-fps-v1-800x600",
            .project = "https://github.com/kondrak/vkQuake2",
            .shape = "BSP materials, dynamic-light surfaces, sprites, and HUD",
            .draw_count = 1_536,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .vkdoom_fps => .{
            .id = "vkdoom-fps-v1-800x600",
            .project = "https://github.com/nashmuhandes/VkDoom",
            .shape = "sector walls, masked sprites, particles, sky, and HUD",
            .draw_count = 1_792,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .vulkan_voxel_world => .{
            .id = "vulkan-voxel-world-v1-800x600",
            .project = "https://github.com/pimpale/vulkan-voxel-game",
            .shape = "chunk faces, atlas materials, terrain horizon, and overlays",
            .draw_count = 1_024,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
        .space_menace_platformer => .{
            .id = "space-menace-platformer-v1-800x600",
            .project = "https://github.com/amethyst/space-menace",
            .shape = "Vulkan 2D-platformer tiles, sprites, particles, and HUD",
            .draw_count = 768,
            .vertices_per_draw = 6,
            .texture_width = 16,
            .texture_height = 16,
        },
    };
}

const Draw = struct { uniform: []u8, vertex_count: u32 };
const Workload = struct {
    target: Target,
    draws: []Draw,
    commands: []cube.DrawCommand,
    texture: []u8,
    texture_width: u32,
    texture_height: u32,

    fn deinit(self: *Workload, allocator: std.mem.Allocator) void {
        for (self.draws) |draw| allocator.free(draw.uniform);
        allocator.free(self.draws);
        allocator.free(self.commands);
        allocator.free(self.texture);
    }
};

const Frame = struct { checksum: u64, pixels_written: usize };
const Timing = struct {
    sample_count: u32,
    fps: f64,
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
};
const Metric = struct {
    workload_id: []const u8,
    upstream_project: []const u8,
    usage_shape: []const u8,
    draw_calls: u32,
    triangles_per_frame: u32,
    legacy_batch_submissions: u32,
    mosaic_batch_submissions: u32,
    per_draw: Timing,
    legacy_batched: Timing,
    mosaic_batched: Timing,
    p50_speedup: f64,
    mosaic_speedup_over_legacy: f64,
    first_checksum_hex: []const u8,
    final_checksum_hex: []const u8,
};
const Report = struct {
    schema_version: u32 = schema_version,
    renderer_scope: []const u8 = "Vulkan cpu_cube_v1 ABI boundary with adaptive private Mosaic spatial execution; upstream projects are usage-shape references",
    resolution: []const u8 = "800x600",
    cpu_cores: u8 = target_cpu_cores,
    warmup_iterations: u32,
    sample_count: u32,
    target_speedup: f64 = target_speedup,
    workloads: []const Metric,
};

fn f32From(value: usize) f32 {
    return @floatFromInt(value);
}

fn revisionBase(target: Target) u64 {
    // Keep separate modeled application lifetimes from colliding when the
    // allocator reuses command/uniform addresses between workload runs.
    return (@as(u64, @intFromEnum(target)) + 1) * 1_000_000;
}

fn ndcX(pixel: f32) f32 {
    return pixel / @as(f32, @floatFromInt(width)) * 2.0 - 1.0;
}

fn ndcY(pixel: f32) f32 {
    return pixel / @as(f32, @floatFromInt(height)) * 2.0 - 1.0;
}

fn putFloat(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn identityUniform(uniform: []u8) void {
    @memset(uniform, 0);
    for (0..4) |column| putFloat(uniform, (column * 4 + column) * 4, 1);
}

fn pixelQuad(x: f32, y: f32, quad_width: f32, quad_height: f32, z: f32) [4][3]f32 {
    return .{
        .{ ndcX(x), ndcY(y), z },
        .{ ndcX(x + quad_width), ndcY(y), z },
        .{ ndcX(x + quad_width), ndcY(y + quad_height), z },
        .{ ndcX(x), ndcY(y + quad_height), z },
    };
}

fn writeVertex(uniform: []u8, vertex_count: usize, index: usize, position: [3]f32, uv: [2]f32) void {
    const position_offset = 64 + index * 16;
    putFloat(uniform, position_offset, position[0]);
    putFloat(uniform, position_offset + 4, position[1]);
    putFloat(uniform, position_offset + 8, position[2]);
    putFloat(uniform, position_offset + 12, 1);
    const uv_offset = 64 + vertex_count * 16 + index * 16;
    putFloat(uniform, uv_offset, uv[0]);
    putFloat(uniform, uv_offset + 4, uv[1]);
}

fn writeQuad(uniform: []u8, vertex_count: usize, points: [4][3]f32, uvs: [4][2]f32) void {
    const order = [_]usize{ 0, 1, 2, 0, 2, 3 };
    for (order, 0..) |corner, index| writeVertex(uniform, vertex_count, index, points[corner], uvs[corner]);
}

fn makeTexture(allocator: std.mem.Allocator, texture_width: u32, texture_height: u32, seed: u32) ![]u8 {
    const texture = try allocator.alloc(u8, @as(usize, texture_width) * texture_height * 4);
    for (0..texture_height) |y| for (0..texture_width) |x| {
        const value = seed +% @as(u32, @intCast(x * 31 + y * 17));
        const offset = (y * @as(usize, texture_width) + x) * 4;
        texture[offset..][0..4].* = .{
            @truncate(value *% 13 +% 41),
            @truncate(value *% 29 +% 67),
            @truncate(value *% 47 +% 89),
            255,
        };
    };
    return texture;
}

fn writeTerminal(uniform: []u8, glyph: usize, frame: usize) void {
    const column = glyph % 120;
    const row = glyph / 120;
    const cell = (glyph + frame) % 16;
    const x = f32From(column) * 6.7;
    const y = f32From(row) * 14.8;
    const u = f32From(cell % 4) / 4.0;
    const v = f32From(cell / 4) / 4.0;
    const uvs = [4][2]f32{ .{ u, v }, .{ u + 0.249, v }, .{ u + 0.249, v + 0.249 }, .{ u, v + 0.249 } };
    writeQuad(uniform, 6, pixelQuad(x, y, 6.2, 14.4, 0.35), uvs);
}

fn writeTerminalBackground(uniform: []u8) void {
    const uv = [4][2]f32{ .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 } };
    writeQuad(uniform, 6, pixelQuad(0, 0, @floatFromInt(width), @floatFromInt(height), 0.95), uv);
}

fn writeApp(uniform: []u8, draw: usize) void {
    const panel = draw % 16;
    const kind = draw / 16;
    const column = panel % 4;
    const row = panel / 4;
    const x = f32From(column) * 198.0 + if (kind % 2 == 0) @as(f32, 8.0) else 18.0;
    const y = f32From(row) * 142.0 + f32From(kind % 5) * 9.0;
    const w: f32 = if (kind % 3 == 0) 180.0 else 132.0;
    const h: f32 = if (kind % 4 == 0) 76.0 else 22.0;
    const cell = (draw * 5 + kind) % 16;
    const u = (f32From(cell % 4) + 0.5) / 4.0;
    const v = (f32From(cell / 4) + 0.5) / 4.0;
    const uv = [4][2]f32{ .{ u, v }, .{ u, v }, .{ u, v }, .{ u, v } };
    writeQuad(uniform, 6, pixelQuad(x, y, w, h, 0.72 - f32From(kind) * 0.0003), uv);
}

fn rotate(x: f32, y: f32, cosine: f32, sine: f32) [2]f32 {
    return .{ x * cosine - y * sine, x * sine + y * cosine };
}

fn writeComplex(uniform: []u8, object: usize, frame: usize) void {
    const column = object % 16;
    const row = object / 16;
    const phase = f32From(object * 13 + frame * 7) * 0.025;
    const cosine = @cos(phase);
    const sine = @sin(phase);
    const center_x = -0.92 + f32From(column) * 0.122;
    const center_y = -0.74 + f32From(row) * 0.20;
    const half_width = 0.045 + @sin(phase * 0.7) * 0.004;
    const half_height = 0.065 + @cos(phase * 0.5) * 0.004;
    for (0..6) |face| {
        const local_x = (f32From(face % 3) - 1.0) * 0.032;
        const local_y = (f32From(face / 3) - 0.5) * 0.042;
        const corners = [4][2]f32{ .{ -half_width, -half_height }, .{ half_width, -half_height }, .{ half_width, half_height }, .{ -half_width, half_height } };
        var points: [4][3]f32 = undefined;
        for (corners, 0..) |corner, index| {
            const rotated = rotate(corner[0], corner[1], cosine, sine);
            points[index] = .{ center_x + local_x + rotated[0], center_y + local_y + rotated[1], 0.08 + f32From(object) * 0.001 + f32From(face) * 0.00001 };
        }
        const cell = (object + face) % 16;
        const uv = [4][2]f32{ .{ (f32From(cell % 4) + 0.2) / 4.0, (f32From(cell / 4) + 0.2) / 4.0 }, .{ (f32From(cell % 4) + 0.8) / 4.0, (f32From(cell / 4) + 0.2) / 4.0 }, .{ (f32From(cell % 4) + 0.8) / 4.0, (f32From(cell / 4) + 0.8) / 4.0 }, .{ (f32From(cell % 4) + 0.2) / 4.0, (f32From(cell / 4) + 0.8) / 4.0 } };
        writeQuad(uniform[0..], 36, points, uv);
        const source_position = uniform[64..][0 .. 6 * 16];
        const source_uv = uniform[64 + 36 * 16 ..][0 .. 6 * 16];
        const destination_position = 64 + face * 6 * 16;
        const destination_uv = 64 + 36 * 16 + face * 6 * 16;
        if (destination_position != 64) @memcpy(uniform[destination_position..][0 .. 6 * 16], source_position);
        if (destination_uv != 64 + 36 * 16) @memcpy(uniform[destination_uv..][0 .. 6 * 16], source_uv);
    }
}

fn writeGameQuad(uniform: []u8, x: f32, y: f32, quad_width: f32, quad_height: f32, z: f32, cell: usize) void {
    const u = (f32From(cell % 4) + 0.15) / 4.0;
    const v = (f32From((cell / 4) % 4) + 0.15) / 4.0;
    const uv = [4][2]f32{
        .{ u, v },
        .{ u + 0.70 / 4.0, v },
        .{ u + 0.70 / 4.0, v + 0.70 / 4.0 },
        .{ u, v + 0.70 / 4.0 },
    };
    writeQuad(uniform, 6, pixelQuad(x, y, quad_width, quad_height, z), uv);
}

fn writeQuake(uniform: []u8, draw: usize, frame: usize) void {
    if (draw == 0) {
        writeGameQuad(uniform, 0, 0, @floatFromInt(width), @floatFromInt(height), 0.99, 0);
        return;
    }
    const surface = draw - 1;
    const dynamic = surface % 17 == 0;
    const phase = f32From((surface * 13 + if (dynamic) frame * 5 else 0) % 97) * 0.01;
    if (surface % 17 == 0) {
        // Entity and particle sprites are broader and move independently of
        // the mostly stable world-surface grid.
        const column = surface % 11;
        const row = (surface / 11) % 7;
        writeGameQuad(uniform, f32From(column) * 73.0 - 12.0 + @sin(phase) * 4.0, f32From(row) * 81.0 - 9.0, 34.0, 48.0, 0.18 + f32From(surface % 29) * 0.001, surface);
    } else {
        // A BSP-like stream: many small visible surfaces with repeated atlas
        // materials and a few partially off-screen edges.
        const column = surface % 20;
        const row = (surface / 20) % 12;
        const layer = (surface / 240) % 7;
        writeGameQuad(uniform, f32From(column) * 42.0 - 8.0, f32From(row) * 49.0 - 6.0, 48.0, 54.0, 0.08 + f32From(layer * 9 + surface % 7) * 0.0007, surface);
    }
}

fn writeQuake2(uniform: []u8, draw: usize, frame: usize) void {
    if (draw == 0) {
        writeGameQuad(uniform, 0, 0, @floatFromInt(width), @floatFromInt(height), 0.995, 3);
        return;
    }
    const surface = draw - 1;
    const family = surface % 19;
    const dynamic = family < 3;
    const phase = f32From((surface * 7 + if (dynamic) frame * 11 else 0) % 113) * 0.008;
    if (family < 3) {
        const column = surface % 13;
        const row = (surface / 13) % 8;
        writeGameQuad(uniform, f32From(column) * 64.0 + @cos(phase) * 6.0, f32From(row) * 72.0, 58.0, 38.0, 0.23 + f32From(surface % 31) * 0.0008, surface + 4);
    } else {
        const column = surface % 16;
        const row = (surface / 16) % 11;
        writeGameQuad(uniform, f32From(column) * 53.0 - 5.0, f32From(row) * 57.0 - 4.0, 61.0, 62.0, 0.10 + f32From((surface / 176) % 8) * 0.004, surface);
    }
}

fn writeVkdoom(uniform: []u8, draw: usize, frame: usize) void {
    if (draw == 0) {
        writeGameQuad(uniform, 0, 0, @floatFromInt(width), @floatFromInt(height), 0.998, 7);
        return;
    }
    const surface = draw - 1;
    const dynamic = surface % 13 < 2;
    const phase = f32From((surface * 17 + if (dynamic) frame * 3 else 0) % 89) * 0.012;
    if (surface % 13 < 2) {
        // Masked sprite / muzzle-flash-like work has a different footprint
        // from the sector-wall majority and exercises mixed fanout.
        const column = surface % 10;
        const row = (surface / 10) % 6;
        writeGameQuad(uniform, f32From(column) * 82.0 + @sin(phase) * 7.0, f32From(row) * 96.0 + 10.0, 28.0, 42.0, 0.16 + f32From(surface % 23) * 0.001, surface + 9);
    } else {
        const column = surface % 18;
        const row = (surface / 18) % 10;
        const wall_height = 36.0 + f32From(surface % 4) * 9.0;
        writeGameQuad(uniform, f32From(column) * 47.0 - 10.0, f32From(row) * 61.0 - 8.0, 53.0, wall_height, 0.06 + f32From((surface / 180) % 9) * 0.003, surface);
    }
}

fn writeVoxelWorld(uniform: []u8, draw: usize, frame: usize) void {
    if (draw == 0) {
        writeGameQuad(uniform, 0, 0, @floatFromInt(width), @floatFromInt(height), 0.999, 11);
        return;
    }
    const face = draw - 1;
    const chunk = face % 64;
    const chunk_face = (face / 64) % 6;
    const column = chunk % 8;
    const row = chunk / 8;
    const x = f32From(column) * 102.0 - 13.0;
    const y = f32From(row) * 92.0 - 10.0;
    const size = 46.0 + f32From(chunk_face % 3) * 11.0;
    writeGameQuad(uniform, x, y, size, 42.0 + f32From(chunk_face) * 4.0, 0.12 + f32From(chunk_face + (face / 384) % 7) * 0.002, face + frame);
}

fn writePlatformer(uniform: []u8, draw: usize, frame: usize) void {
    if (draw == 0) {
        writeGameQuad(uniform, 0, 0, @floatFromInt(width), @floatFromInt(height), 0.999, 14);
        return;
    }
    const sprite = draw - 1;
    if (sprite % 7 == 0) {
        const column = sprite % 12;
        const row = (sprite / 12) % 6;
        writeGameQuad(uniform, f32From(column) * 68.0 + @sin(f32From(frame) * 0.04 + f32From(sprite)) * 8.0, f32From(row) * 92.0, 32.0, 40.0, 0.20 + f32From(sprite % 16) * 0.002, sprite + 3);
    } else {
        const tile = sprite % 120;
        const column = tile % 15;
        const row = tile / 15;
        writeGameQuad(uniform, f32From(column) * 55.0 - 7.0, f32From(row) * 64.0 - 5.0, 62.0, 54.0, 0.10 + f32From((sprite / 120) % 6) * 0.004, sprite);
    }
}

fn buildWorkload(allocator: std.mem.Allocator, target: Target) !Workload {
    const target_spec = spec(target);
    var workload = Workload{
        .target = target,
        .draws = undefined,
        .commands = undefined,
        .texture = try makeTexture(allocator, target_spec.texture_width, target_spec.texture_height, @as(u32, @intFromEnum(target)) * 97 + 11),
        .texture_width = target_spec.texture_width,
        .texture_height = target_spec.texture_height,
    };
    errdefer allocator.free(workload.texture);
    workload.draws = try allocator.alloc(Draw, target_spec.draw_count);
    errdefer {
        for (workload.draws) |draw| if (draw.uniform.len != 0) allocator.free(draw.uniform);
        allocator.free(workload.draws);
    }
    for (workload.draws, 0..) |*draw, index| {
        draw.* = .{ .uniform = try allocator.alloc(u8, 64 + @as(usize, target_spec.vertices_per_draw) * 32), .vertex_count = target_spec.vertices_per_draw };
        identityUniform(draw.uniform);
        switch (target) {
            .wezterm_terminal => if (index == 0) writeTerminalBackground(draw.uniform) else writeTerminal(draw.uniform, index - 1, 0),
            .imgui_vulkan_app => writeApp(draw.uniform, index),
            .khronos_complex_demo => writeComplex(draw.uniform, index, 0),
            .vkquake_fps => writeQuake(draw.uniform, index, 0),
            .vkquake2_fps => writeQuake2(draw.uniform, index, 0),
            .vkdoom_fps => writeVkdoom(draw.uniform, index, 0),
            .vulkan_voxel_world => writeVoxelWorld(draw.uniform, index, 0),
            .space_menace_platformer => writePlatformer(draw.uniform, index, 0),
        }
    }
    workload.commands = try allocator.alloc(cube.DrawCommand, target_spec.draw_count);
    const revision_base = revisionBase(target);
    const viewport = cube.Viewport{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 };
    const scissor = cube.Rect{ .x = 0, .y = 0, .width = width, .height = height };
    for (workload.draws, 0..) |draw, index| workload.commands[index] = .{
        .uniform = draw.uniform,
        .texture = workload.texture,
        .texture_width = workload.texture_width,
        .texture_height = workload.texture_height,
        .vertex_count = draw.vertex_count,
        .viewport = viewport,
        .scissor = scissor,
        .uniform_revision = revision_base + 1,
        .geometry_revision = revision_base + 1,
        .texture_revision = revision_base + 1,
    };
    return workload;
}

fn updateWorkload(workload: *Workload, frame: usize) void {
    switch (workload.target) {
        .wezterm_terminal => for (workload.draws[1..], 0..) |draw, glyph| {
            writeTerminal(draw.uniform, glyph, frame);
            workload.commands[glyph + 1].uniform_revision = revisionBase(.wezterm_terminal) + @as(u64, @intCast(frame + 2));
        },
        .imgui_vulkan_app => {},
        .khronos_complex_demo => for (workload.draws, 0..) |draw, object| {
            writeComplex(draw.uniform, object, frame);
            workload.commands[object].uniform_revision = revisionBase(.khronos_complex_demo) + @as(u64, @intCast(frame + 2));
            workload.commands[object].geometry_revision = revisionBase(.khronos_complex_demo) + @as(u64, @intCast(frame + 2));
        },
        .vkquake_fps => for (workload.draws, 0..) |draw, index| {
            if (index == 0 or (index - 1) % 17 != 0) continue;
            writeQuake(draw.uniform, index, frame);
            workload.commands[index].uniform_revision = revisionBase(.vkquake_fps) + @as(u64, @intCast(frame + 2));
            workload.commands[index].geometry_revision = revisionBase(.vkquake_fps) + @as(u64, @intCast(frame + 2));
        },
        .vkquake2_fps => for (workload.draws, 0..) |draw, index| {
            if (index == 0 or (index - 1) % 19 >= 3) continue;
            writeQuake2(draw.uniform, index, frame);
            workload.commands[index].uniform_revision = revisionBase(.vkquake2_fps) + @as(u64, @intCast(frame + 2));
            workload.commands[index].geometry_revision = revisionBase(.vkquake2_fps) + @as(u64, @intCast(frame + 2));
        },
        .vkdoom_fps => for (workload.draws, 0..) |draw, index| {
            if (index == 0 or (index - 1) % 13 >= 2) continue;
            writeVkdoom(draw.uniform, index, frame);
            workload.commands[index].uniform_revision = revisionBase(.vkdoom_fps) + @as(u64, @intCast(frame + 2));
            workload.commands[index].geometry_revision = revisionBase(.vkdoom_fps) + @as(u64, @intCast(frame + 2));
        },
        .vulkan_voxel_world => {},
        .space_menace_platformer => for (workload.draws, 0..) |draw, index| {
            if (index == 0 or (index - 1) % 7 != 0) continue;
            writePlatformer(draw.uniform, index, frame);
            workload.commands[index].uniform_revision = revisionBase(.space_menace_platformer) + @as(u64, @intCast(frame + 2));
            workload.commands[index].geometry_revision = revisionBase(.space_menace_platformer) + @as(u64, @intCast(frame + 2));
        },
    }
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.XxHash3.hash(0, bytes);
}

fn clearAttachments(color: []u8, depth: []u8) void {
    @memset(color, 0x19);
    const depth_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(depth)));
    @memset(depth_words, clear_depth);
}

fn render(workload: *const Workload, mode: Mode, color: []u8, depth: []u8) !Frame {
    clearAttachments(color, depth);
    var pixels_written: usize = 0;
    switch (mode) {
        .per_draw => for (workload.commands) |command| {
            pixels_written += cube.drawUncountedParallel(color, depth, width, height, command.uniform, command.texture, command.texture_width, command.texture_height, command.vertex_count, command.viewport, command.scissor);
        },
        .legacy_batched, .mosaic_batched => {
            const limit: usize = if (mode == .legacy_batched) legacy_batch_limit else mosaic_batch_limit;
            var start: usize = 0;
            while (start < workload.commands.len) {
                const end = @min(start + limit, workload.commands.len);
                var bounds = cube.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
                pixels_written += if (mode == .legacy_batched)
                    cube.drawUncountedParallelBatchTracked(color, depth, width, height, workload.commands[start..end], &bounds)
                else
                    cube.drawUncountedParallelBatchMosaic(color, depth, width, height, workload.commands[start..end], &bounds);
                start = end;
            }
        },
    }
    if (pixels_written == 0) return error.EmptyRender;
    return .{ .checksum = checksum(color), .pixels_written = pixels_written };
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = (@as(u128, values.len) * numerator + denominator - 1) / denominator;
    return values[@intCast(rank - 1)];
}

fn measure(allocator: std.mem.Allocator, io: std.Io, workload: *Workload, mode: Mode, smoke: bool) !Timing {
    const warmups: usize = if (smoke) 1 else 2;
    const sample_count: usize = if (smoke) 3 else 6;
    var timings: [max_samples]u64 = undefined;
    const color = try allocator.alloc(u8, surface_bytes);
    defer allocator.free(color);
    const depth = try allocator.alloc(u8, surface_bytes);
    defer allocator.free(depth);
    for (0..warmups) |frame| {
        updateWorkload(workload, frame);
        _ = try render(workload, mode, color, depth);
    }
    for (0..sample_count) |sample| {
        updateWorkload(workload, warmups + sample);
        const start = std.Io.Clock.boot.now(io);
        _ = try render(workload, mode, color, depth);
        timings[sample] = @intCast(@max(start.untilNow(io, .boot).toNanoseconds(), 1));
    }
    var total: u128 = 0;
    for (timings[0..sample_count]) |value| total += value;
    return .{
        .sample_count = @intCast(sample_count),
        .fps = 1_000_000_000.0 * @as(f64, @floatFromInt(sample_count)) / @as(f64, @floatFromInt(total)),
        .p50_ns = percentile(timings[0..sample_count], 50, 100),
        .p95_ns = percentile(timings[0..sample_count], 95, 100),
        .p99_ns = percentile(timings[0..sample_count], 99, 100),
    };
}

fn selectedCpuCount(text: []const u8) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, text, ',');
    while (tokens.next()) |_| count += 1;
    return count;
}

fn parseTarget(name: []const u8) ?Target {
    if (std.mem.eql(u8, name, "wezterm_terminal")) return .wezterm_terminal;
    if (std.mem.eql(u8, name, "imgui_vulkan_app")) return .imgui_vulkan_app;
    if (std.mem.eql(u8, name, "khronos_complex_demo")) return .khronos_complex_demo;
    if (std.mem.eql(u8, name, "vkquake_fps")) return .vkquake_fps;
    if (std.mem.eql(u8, name, "vkquake2_fps")) return .vkquake2_fps;
    if (std.mem.eql(u8, name, "vkdoom_fps")) return .vkdoom_fps;
    if (std.mem.eql(u8, name, "vulkan_voxel_world")) return .vulkan_voxel_world;
    if (std.mem.eql(u8, name, "space_menace_platformer")) return .space_menace_platformer;
    return null;
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityGate;
    const cpu_cores = selectedCpuCount(selected);
    if (cpu_cores == 0 or cpu_cores > 8) return error.InvalidAffinityWidth;
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var smoke = false;
    var json = false;
    var only: ?Target = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--smoke")) smoke = true else if (std.mem.eql(u8, args[index], "--json")) json = true else if (std.mem.eql(u8, args[index], "--scenario")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            only = parseTarget(args[index]) orelse return error.UnknownScenario;
        } else return error.UnknownArgument;
    }
    const targets = [_]Target{ .wezterm_terminal, .imgui_vulkan_app, .khronos_complex_demo, .vkquake_fps, .vkquake2_fps, .vkdoom_fps, .vulkan_voxel_world, .space_menace_platformer };
    const metric_count: usize = if (only == null) targets.len else 1;
    const metrics = try allocator.alloc(Metric, metric_count);
    var metric_index: usize = 0;
    for (targets) |target| {
        if (only != null and only.? != target) continue;
        var per_draw_workload = try buildWorkload(allocator, target);
        var legacy_batched_workload = try buildWorkload(allocator, target);
        var batched_workload = try buildWorkload(allocator, target);
        const target_spec = spec(target);
        const per_draw = try measure(allocator, init.io, &per_draw_workload, .per_draw, smoke);
        const legacy_batched = try measure(allocator, init.io, &legacy_batched_workload, .legacy_batched, smoke);
        const mosaic_batched = try measure(allocator, init.io, &batched_workload, .mosaic_batched, smoke);
        const per_color = try allocator.alloc(u8, surface_bytes);
        const per_depth = try allocator.alloc(u8, surface_bytes);
        const legacy_color = try allocator.alloc(u8, surface_bytes);
        const legacy_depth = try allocator.alloc(u8, surface_bytes);
        const mosaic_color = try allocator.alloc(u8, surface_bytes);
        const mosaic_depth = try allocator.alloc(u8, surface_bytes);
        const per_checksum = try render(&per_draw_workload, .per_draw, per_color, per_depth);
        const legacy_checksum = try render(&legacy_batched_workload, .legacy_batched, legacy_color, legacy_depth);
        const mosaic_checksum = try render(&batched_workload, .mosaic_batched, mosaic_color, mosaic_depth);
        if (per_checksum.checksum != legacy_checksum.checksum or per_checksum.checksum != mosaic_checksum.checksum) return error.BatchOracleMismatch;
        const first_hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{mosaic_checksum.checksum});
        const per_hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{per_checksum.checksum});
        metrics[metric_index] = .{
            .workload_id = target_spec.id,
            .upstream_project = target_spec.project,
            .usage_shape = target_spec.shape,
            .draw_calls = @intCast(target_spec.draw_count),
            .triangles_per_frame = @intCast(target_spec.draw_count * target_spec.vertices_per_draw / 3),
            .legacy_batch_submissions = @intCast((target_spec.draw_count + legacy_batch_limit - 1) / legacy_batch_limit),
            .mosaic_batch_submissions = @intCast((target_spec.draw_count + mosaic_batch_limit - 1) / mosaic_batch_limit),
            .per_draw = per_draw,
            .legacy_batched = legacy_batched,
            .mosaic_batched = mosaic_batched,
            .p50_speedup = @as(f64, @floatFromInt(per_draw.p50_ns)) / @as(f64, @floatFromInt(mosaic_batched.p50_ns)),
            .mosaic_speedup_over_legacy = @as(f64, @floatFromInt(legacy_batched.p50_ns)) / @as(f64, @floatFromInt(mosaic_batched.p50_ns)),
            .first_checksum_hex = first_hex,
            .final_checksum_hex = per_hex,
        };
        per_draw_workload.deinit(allocator);
        legacy_batched_workload.deinit(allocator);
        batched_workload.deinit(allocator);
        metric_index += 1;
    }
    defer cube.shutdownParallelWorkers();
    const report = Report{ .cpu_cores = @intCast(cpu_cores), .warmup_iterations = if (smoke) 1 else 2, .sample_count = if (smoke) 3 else 6, .workloads = metrics };
    if (json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try stringify.write(report);
        try out.writer.writeByte('\n');
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
    } else for (metrics) |metric| std.debug.print("{s}: per-draw={d}us, legacy-256={d}us, Mosaic-8192={d}us, {d:.2}x vs legacy, target {d:.1}x\n", .{ metric.workload_id, metric.per_draw.p50_ns / 1000, metric.legacy_batched.p50_ns / 1000, metric.mosaic_batched.p50_ns / 1000, metric.mosaic_speedup_over_legacy, target_speedup });
}

test "Vulkan ABI targets freeze realistic stream shapes" {
    try std.testing.expectEqual(@as(usize, 4_801), spec(.wezterm_terminal).draw_count);
    try std.testing.expectEqual(@as(usize, 192), spec(.imgui_vulkan_app).draw_count);
    try std.testing.expectEqual(@as(usize, 128), spec(.khronos_complex_demo).draw_count);
    try std.testing.expectEqual(@as(usize, 2_048), spec(.vkquake_fps).draw_count);
    try std.testing.expectEqual(@as(usize, 1_536), spec(.vkquake2_fps).draw_count);
    try std.testing.expectEqual(@as(usize, 1_792), spec(.vkdoom_fps).draw_count);
    try std.testing.expectEqual(@as(usize, 1_024), spec(.vulkan_voxel_world).draw_count);
    try std.testing.expectEqual(@as(usize, 768), spec(.space_menace_platformer).draw_count);
    try std.testing.expectEqual(@as(usize, 19), (spec(.wezterm_terminal).draw_count + legacy_batch_limit - 1) / legacy_batch_limit);
    try std.testing.expectEqual(@as(usize, 1), (spec(.wezterm_terminal).draw_count + mosaic_batch_limit - 1) / mosaic_batch_limit);
    try std.testing.expect(mosaic_batch_limit == cube.max_batch_commands);
    try std.testing.expectEqual(@as(f64, 4.0), target_speedup);
}

test "Vulkan ABI batch stream matches per-draw oracle" {
    const allocator = std.testing.allocator;
    defer cube.shutdownParallelWorkers();
    const targets = [_]Target{ .wezterm_terminal, .imgui_vulkan_app, .khronos_complex_demo, .vkquake_fps, .vkquake2_fps, .vkdoom_fps, .vulkan_voxel_world, .space_menace_platformer };
    for (targets) |target| {
        var per_draw_workload = try buildWorkload(allocator, target);
        defer per_draw_workload.deinit(allocator);
        var legacy_batched_workload = try buildWorkload(allocator, target);
        defer legacy_batched_workload.deinit(allocator);
        var mosaic_batched_workload = try buildWorkload(allocator, target);
        defer mosaic_batched_workload.deinit(allocator);
        const per_color = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(per_color);
        const per_depth = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(per_depth);
        const legacy_color = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(legacy_color);
        const legacy_depth = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(legacy_depth);
        const mosaic_color = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(mosaic_color);
        const mosaic_depth = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(mosaic_depth);
        const per = try render(&per_draw_workload, .per_draw, per_color, per_depth);
        const legacy = try render(&legacy_batched_workload, .legacy_batched, legacy_color, legacy_depth);
        const mosaic = try render(&mosaic_batched_workload, .mosaic_batched, mosaic_color, mosaic_depth);
        try std.testing.expectEqual(per.checksum, legacy.checksum);
        try std.testing.expectEqual(per.checksum, mosaic.checksum);
        try std.testing.expectEqualSlices(u8, per_color, legacy_color);
        try std.testing.expectEqualSlices(u8, per_depth, legacy_depth);
        try std.testing.expectEqualSlices(u8, per_color, mosaic_color);
        try std.testing.expectEqualSlices(u8, per_depth, mosaic_depth);
        try std.testing.expect(per.pixels_written > 0);
        try std.testing.expectEqual(per.pixels_written, legacy.pixels_written);
        try std.testing.expectEqual(per.pixels_written, mosaic.pixels_written);
    }
}

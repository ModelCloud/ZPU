// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cube = @import("vulkan/cpu_cube.zig");

// These workloads intentionally exercise the existing vkcube-specific CPU
// raster API. They are usage-shaped tests, not a claim that this renderer is a
// general SPIR-V implementation.
pub const schema_version: u32 = 1;
pub const width: u32 = 800;
pub const height: u32 = 600;
pub const target_cpu_cores: u8 = 2;

const surface_bytes = @as(usize, width) * height * 4;
const clear_color: u32 = 0x19191919;
const clear_depth: u32 = @bitCast(@as(f32, 1));
const max_samples = 16;
const fnv_offset: u64 = 14695981039346656037;
const fnv_prime: u64 = 1099511628211;

const Kind = enum { desktop, terminal, game };

const Draw = struct {
    uniform: []u8 = &[_]u8{},
    vertex_count: u32 = 0,
    texture: []u8 = &[_]u8{},
    texture_width: u32 = 0,
    texture_height: u32 = 0,
};

const Workload = struct {
    kind: Kind,
    id: []const u8,
    category: []const u8,
    draws: []Draw,
    texture: []u8,
    texture_width: u32,
    texture_height: u32,
    triangles_per_frame: u32,

    fn deinit(self: *Workload, allocator: std.mem.Allocator) void {
        for (self.draws) |draw| {
            if (draw.uniform.len != 0) allocator.free(draw.uniform);
            if (draw.texture.len != 0) allocator.free(draw.texture);
        }
        if (self.draws.len != 0) allocator.free(self.draws);
        if (self.texture.len != 0) allocator.free(self.texture);
    }
};

const Percentiles = struct {
    p50_ns: u64,
    p95_ns: u64,
    p99_ns: u64,
    max_ns: u64,
    cv: f64,
};

const Metric = struct {
    workload_id: []const u8,
    category: []const u8,
    draw_calls: u32,
    triangles_per_frame: u32,
    sample_count: u32,
    fps: f64,
    draws_s: f64,
    triangles_s: f64,
    first_checksum: u64,
    first_checksum_hex: []const u8,
    final_checksum: u64,
    final_checksum_hex: []const u8,
    frame: Percentiles,
    counters_per_frame: cube.Counters,
};

const Report = struct {
    schema_version: u32 = schema_version,
    renderer_scope: []const u8 = "existing vkcube-specific cpu_cube renderer; usage-shaped app workloads, not general SPIR-V",
    resolution: []const u8 = "800x600",
    cpu_cores: u8 = target_cpu_cores,
    warmup_iterations: u32,
    sample_count: u32,
    workloads: []const Metric,
};

const FrameResult = struct {
    checksum: u64,
    counters: cube.Counters,
};

fn kindId(kind: Kind) []const u8 {
    return switch (kind) {
        .desktop => "zpu-3d-app-desktop-windows-v1-800x600",
        .terminal => "zpu-3d-app-terminal-glyphs-v1-800x600",
        .game => "zpu-3d-app-game-dynamic-mesh-v1-800x600",
    };
}

fn kindCategory(kind: Kind) []const u8 {
    return switch (kind) {
        .desktop => "desktop_window_compositor",
        .terminal => "terminal_text_glyphs",
        .game => "game_engine_dynamic_mesh",
    };
}

fn kindName(kind: Kind) []const u8 {
    return switch (kind) {
        .desktop => "desktop",
        .terminal => "terminal",
        .game => "game",
    };
}

fn f32From(value: usize) f32 {
    return @floatFromInt(value);
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

fn getFloat(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}

fn identityUniform(uniform: []u8) void {
    @memset(uniform, 0);
    for (0..4) |column| putFloat(uniform, (column * 4 + column) * 4, 1);
}

fn allocateUniform(allocator: std.mem.Allocator, vertex_count: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, 64 + vertex_count * 32);
    identityUniform(bytes);
    return bytes;
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

fn pixelQuad(x: f32, y: f32, quad_width: f32, quad_height: f32, z: f32) [4][3]f32 {
    return .{
        .{ ndcX(x), ndcY(y), z },
        .{ ndcX(x + quad_width), ndcY(y), z },
        .{ ndcX(x + quad_width), ndcY(y + quad_height), z },
        .{ ndcX(x), ndcY(y + quad_height), z },
    };
}

fn makeTexture(allocator: std.mem.Allocator, texture_width: u32, texture_height: u32, seed: u32) ![]u8 {
    const texture = try allocator.alloc(u8, @as(usize, texture_width) * texture_height * 4);
    errdefer allocator.free(texture);
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

fn writeDesktopDraw(uniform: []u8, window: usize, layer: usize) void {
    const column = window % 4;
    const row = window / 4;
    const x = -20.0 + f32From(column) * 200.0 + f32From(row % 2) * 4.0;
    const y = -10.0 + f32From(row) * 190.0;
    const quad_width = 178.0 - f32From(row % 3) * 8.0;
    const quad_height = 150.0 + f32From(column % 2) * 12.0;
    const base_depth = 0.72 - f32From(window) * 0.012;
    const points = switch (layer) {
        0 => pixelQuad(x - 7, y + 8, quad_width + 14, quad_height + 14, base_depth + 0.025),
        1 => pixelQuad(x, y, quad_width, quad_height, base_depth),
        else => pixelQuad(x + 4, y + 4, quad_width - 8, 24, base_depth - 0.012),
    };
    const cell = (window * 3 + layer) % 16;
    const cell_u = (f32From(cell % 4) + 0.5) / 4.0;
    const cell_v = (f32From(cell / 4) + 0.5) / 4.0;
    const uvs = [4][2]f32{ .{ cell_u, cell_v }, .{ cell_u, cell_v }, .{ cell_u, cell_v }, .{ cell_u, cell_v } };
    writeQuad(uniform, 6, points, uvs);
}

fn writeTerminalDraw(uniform: []u8, glyph: usize, cell: usize) void {
    const column = glyph % 24;
    const row = glyph / 24;
    const x = -12.0 + f32From(column) * 34.0;
    const y = -8.0 + f32From(row) * 50.0;
    const cell_x = f32From(cell % 4) / 4.0;
    const cell_y = f32From(cell / 4) / 4.0;
    const cell_x1 = cell_x + 0.249;
    const cell_y1 = cell_y + 0.249;
    const points = pixelQuad(x, y, 32, 46, 0.35);
    const uvs = [4][2]f32{ .{ cell_x, cell_y }, .{ cell_x1, cell_y }, .{ cell_x1, cell_y1 }, .{ cell_x, cell_y1 } };
    writeQuad(uniform, 6, points, uvs);
}

fn rotatePoint(center_x: f32, center_y: f32, x: f32, y: f32, cosine: f32, sine: f32, z: f32) [3]f32 {
    return .{ center_x + x * cosine - y * sine, center_y + x * sine + y * cosine, z };
}

fn writeGameDraw(uniform: []u8, object: usize, frame: usize) void {
    const column = object % 8;
    const row = object / 8;
    const phase = f32From(object * 13 + frame * 7) * 0.035;
    const cosine = @cos(phase);
    const sine = @sin(phase);
    const center_x = -0.82 + f32From(column) * 0.235 + @sin(phase * 0.7) * 0.025;
    const center_y = -0.70 + f32From(row) * 0.46 + @cos(phase * 0.53) * 0.025;
    const scale = 0.88 + @sin(phase * 1.3) * 0.08;
    for (0..6) |face| {
        const face_x = (f32From(face % 3) - 1.0) * 0.057;
        const face_y = (f32From(face / 3) - 0.5) * 0.070;
        const half_width = 0.061 * scale;
        const half_height = 0.073 * scale;
        const z = 0.12 + f32From(object) * 0.002 + f32From(face) * 0.0001 + @sin(phase) * 0.0005;
        const points = [4][3]f32{
            rotatePoint(center_x, center_y, face_x - half_width, face_y - half_height, cosine, sine, z),
            rotatePoint(center_x, center_y, face_x + half_width, face_y - half_height, cosine, sine, z),
            rotatePoint(center_x, center_y, face_x + half_width, face_y + half_height, cosine, sine, z),
            rotatePoint(center_x, center_y, face_x - half_width, face_y + half_height, cosine, sine, z),
        };
        const cell = (object + face) % 16;
        const u = (f32From(cell % 4) + 0.5) / 4.0;
        const v = (f32From(cell / 4) + 0.5) / 4.0;
        const uvs = [4][2]f32{ .{ u, v }, .{ u, v }, .{ u, v }, .{ u, v } };
        writeQuad(uniform[0..], 36, points, uvs);
        // writeQuad writes six vertices at the start; move this face's data to
        // its slot after keeping the helper's compact quad convention.
        const face_uniform = uniform;
        const source_positions = face_uniform[64..][0 .. 6 * 16];
        const source_uvs = face_uniform[64 + 36 * 16 ..][0 .. 6 * 16];
        const destination_position = 64 + face * 6 * 16;
        const destination_uv = 64 + 36 * 16 + face * 6 * 16;
        if (destination_position != 64) @memcpy(uniform[destination_position..][0 .. 6 * 16], source_positions);
        if (destination_uv != 64 + 36 * 16) @memcpy(uniform[destination_uv..][0 .. 6 * 16], source_uvs);
    }
}

fn buildWorkload(allocator: std.mem.Allocator, kind: Kind) !Workload {
    const draw_count: usize = switch (kind) {
        .desktop => 36,
        .terminal => 241,
        .game => 32,
    };
    const texture_width: u32 = if (kind == .desktop) 1 else if (kind == .terminal) 16 else 4;
    const texture_height: u32 = if (kind == .desktop) 1 else if (kind == .terminal) 16 else 4;
    var workload = Workload{
        .kind = kind,
        .id = kindId(kind),
        .category = kindCategory(kind),
        .draws = @constCast(&[_]Draw{}),
        .texture = @constCast(&[_]u8{}),
        .texture_width = texture_width,
        .texture_height = texture_height,
        .triangles_per_frame = switch (kind) {
            .game => @intCast(draw_count * 12),
            else => @intCast(draw_count * 2),
        },
    };
    errdefer workload.deinit(allocator);

    workload.draws = try allocator.alloc(Draw, draw_count);
    for (workload.draws) |*draw| draw.* = .{};
    if (kind != .desktop) workload.texture = try makeTexture(allocator, texture_width, texture_height, @as(u32, @intFromEnum(kind)) * 97 + 11);

    switch (kind) {
        .desktop => for (workload.draws, 0..) |*draw, index| {
            draw.uniform = try allocateUniform(allocator, 6);
            draw.texture = try makeTexture(allocator, 1, 1, @as(u32, @intCast(index * 17 + 11)));
            draw.texture_width = 1;
            draw.texture_height = 1;
            writeDesktopDraw(draw.uniform, index / 3, index % 3);
            draw.vertex_count = 6;
        },
        .terminal => {
            workload.draws[0].uniform = try allocateUniform(allocator, 6);
            const background_points = pixelQuad(0, 0, @floatFromInt(width), @floatFromInt(height), 0.95);
            const background_uvs = [4][2]f32{ .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 }, .{ 0.53125, 0.53125 } };
            writeQuad(workload.draws[0].uniform, 6, background_points, background_uvs);
            workload.draws[0].vertex_count = 6;
            for (workload.draws[1..], 0..) |*draw, glyph| {
                draw.uniform = try allocateUniform(allocator, 6);
                writeTerminalDraw(draw.uniform, glyph, glyph % 16);
                draw.vertex_count = 6;
            }
        },
        .game => for (workload.draws, 0..) |*draw, object| {
            draw.uniform = try allocateUniform(allocator, 36);
            writeGameDraw(draw.uniform, object, 0);
            draw.vertex_count = 36;
        },
    }
    return workload;
}

fn updateWorkload(workload: *Workload, frame: usize) void {
    switch (workload.kind) {
        .desktop => {},
        .terminal => for (workload.draws[1..], 0..) |draw, glyph| writeTerminalDraw(draw.uniform, glyph, (glyph + frame) % 16),
        .game => for (workload.draws, 0..) |draw, object| writeGameDraw(draw.uniform, object, frame),
    }
}

fn checksum(bytes: []const u8) u64 {
    var hash = fnv_offset;
    for (bytes) |byte| hash = (hash ^ byte) *% fnv_prime;
    return hash;
}

fn clearAttachments(color: []u8, depth: []u8) void {
    @memset(color, 0x19);
    const depth_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(depth)));
    @memset(depth_words, clear_depth);
}

fn addCounters(total: *cube.Counters, value: cube.Counters) void {
    total.triangles_submitted += value.triangles_submitted;
    total.triangles_rasterized += value.triangles_rasterized;
    total.fragments_tested += value.fragments_tested;
    total.fragments_covered += value.fragments_covered;
    total.depth_tests_passed += value.depth_tests_passed;
    total.color_writes += value.color_writes;
}

fn renderSerial(workload: *const Workload, color: []u8, depth: []u8) !FrameResult {
    clearAttachments(color, depth);
    var counters = cube.Counters{};
    for (workload.draws) |draw| {
        var draw_counters = cube.Counters{};
        const texture = if (draw.texture.len != 0) draw.texture else workload.texture;
        const texture_width = if (draw.texture.len != 0) draw.texture_width else workload.texture_width;
        const texture_height = if (draw.texture.len != 0) draw.texture_height else workload.texture_height;
        const written = cube.drawCounted(color, depth, width, height, draw.uniform, texture, texture_width, texture_height, draw.vertex_count, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, &draw_counters);
        if (written == 0) return error.EmptyRender;
        addCounters(&counters, draw_counters);
    }
    return .{ .checksum = checksum(color), .counters = counters };
}

fn renderParallel(workload: *const Workload, color: []u8, depth: []u8) !FrameResult {
    clearAttachments(color, depth);
    var counters = cube.Counters{};
    for (workload.draws) |draw| {
        var draw_counters = cube.Counters{};
        const texture = if (draw.texture.len != 0) draw.texture else workload.texture;
        const texture_width = if (draw.texture.len != 0) draw.texture_width else workload.texture_width;
        const texture_height = if (draw.texture.len != 0) draw.texture_height else workload.texture_height;
        const written = cube.drawCountedParallel(color, depth, width, height, draw.uniform, texture, texture_width, texture_height, draw.vertex_count, .{ .x = 0, .y = 0, .width = @floatFromInt(width), .height = @floatFromInt(height), .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = width, .height = height }, &draw_counters);
        if (written == 0) return error.EmptyRender;
        addCounters(&counters, draw_counters);
    }
    return .{ .checksum = checksum(color), .counters = counters };
}

fn percentile(values: []u64, numerator: usize, denominator: usize) u64 {
    std.mem.sort(u64, values, {}, std.sort.asc(u64));
    const rank = (@as(u128, values.len) * numerator + denominator - 1) / denominator;
    return values[@intCast(rank - 1)];
}

fn summarize(values: []const u64) Percentiles {
    var p50: [max_samples]u64 = undefined;
    var p95 = p50;
    var p99 = p50;
    @memcpy(p50[0..values.len], values);
    @memcpy(p95[0..values.len], values);
    @memcpy(p99[0..values.len], values);
    var total: u128 = 0;
    var maximum: u64 = 0;
    for (values) |value| {
        total += value;
        maximum = @max(maximum, value);
    }
    const mean = @as(f64, @floatFromInt(total)) / @as(f64, @floatFromInt(values.len));
    var squared: f64 = 0;
    for (values) |value| {
        const delta = @as(f64, @floatFromInt(value)) - mean;
        squared += delta * delta;
    }
    return .{
        .p50_ns = percentile(p50[0..values.len], 50, 100),
        .p95_ns = percentile(p95[0..values.len], 95, 100),
        .p99_ns = percentile(p99[0..values.len], 99, 100),
        .max_ns = maximum,
        .cv = @sqrt(squared / @as(f64, @floatFromInt(values.len))) / mean,
    };
}

fn measure(allocator: std.mem.Allocator, io: std.Io, workload: *Workload, smoke: bool) !Metric {
    const warmups: usize = if (smoke) 1 else 3;
    const sample_count: usize = if (smoke) 3 else 12;
    var timings: [max_samples]u64 = undefined;
    const color = try allocator.alloc(u8, surface_bytes);
    defer allocator.free(color);
    const depth = try allocator.alloc(u8, surface_bytes);
    defer allocator.free(depth);

    for (0..warmups) |frame| {
        updateWorkload(workload, frame);
        _ = try renderParallel(workload, color, depth);
    }

    var first: ?FrameResult = null;
    var final_checksum: u64 = 0;
    for (0..sample_count) |sample| {
        updateWorkload(workload, warmups + sample);
        const start = std.Io.Clock.boot.now(io);
        const result = try renderParallel(workload, color, depth);
        timings[sample] = @intCast(@max(start.untilNow(io, .boot).toNanoseconds(), 1));
        if (first == null) first = result;
        final_checksum = result.checksum;
    }

    var total: u128 = 0;
    for (timings[0..sample_count]) |value| total += value;
    const fps = 1_000_000_000.0 * @as(f64, @floatFromInt(sample_count)) / @as(f64, @floatFromInt(total));
    const frame = summarize(timings[0..sample_count]);
    const first_result = first.?;
    const first_hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{first_result.checksum});
    const final_hex = try std.fmt.allocPrint(allocator, "{x:0>16}", .{final_checksum});
    return .{
        .workload_id = workload.id,
        .category = workload.category,
        .draw_calls = @intCast(workload.draws.len),
        .triangles_per_frame = workload.triangles_per_frame,
        .sample_count = @intCast(sample_count),
        .fps = fps,
        .draws_s = fps * @as(f64, @floatFromInt(workload.draws.len)),
        .triangles_s = fps * @as(f64, @floatFromInt(workload.triangles_per_frame)),
        .first_checksum = first_result.checksum,
        .first_checksum_hex = first_hex,
        .final_checksum = final_checksum,
        .final_checksum_hex = final_hex,
        .frame = frame,
        .counters_per_frame = first_result.counters,
    };
}

fn parseKind(name: []const u8) ?Kind {
    for (std.enums.values(Kind)) |kind| if (std.mem.eql(u8, name, kindName(kind))) return kind;
    return null;
}

fn selectedCpuCount(text: []const u8) usize {
    var count: usize = 0;
    var tokens = std.mem.tokenizeScalar(u8, text, ',');
    while (tokens.next()) |_| count += 1;
    return count;
}

pub fn main(init: std.process.Init) !void {
    if (!std.mem.eql(u8, init.environ_map.get("ZPU_LIMITED") orelse "", "physical-core-v1")) return error.MissingAffinityGate;
    const selected = init.environ_map.get("ZPU_SELECTED_CPUS") orelse return error.MissingAffinityGate;
    if (selectedCpuCount(selected) != target_cpu_cores) return error.TwoCoreAffinityRequired;

    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    var smoke = false;
    var json = false;
    var only: ?Kind = null;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        if (std.mem.eql(u8, args[index], "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, args[index], "--json")) {
            json = true;
        } else if (std.mem.eql(u8, args[index], "--scenario")) {
            index += 1;
            if (index >= args.len) return error.MissingArgument;
            only = parseKind(args[index]) orelse return error.UnknownScenario;
        } else {
            return error.UnknownArgument;
        }
    }

    const kinds = [_]Kind{ .desktop, .terminal, .game };
    const report_count: usize = if (only == null) kinds.len else 1;
    const metrics = try allocator.alloc(Metric, report_count);
    var metric_index: usize = 0;
    for (kinds) |kind| {
        if (only != null and only.? != kind) continue;
        var workload = try buildWorkload(allocator, kind);
        metrics[metric_index] = try measure(allocator, init.io, &workload, smoke);
        workload.deinit(allocator);
        metric_index += 1;
    }

    const report = Report{ .warmup_iterations = if (smoke) 1 else 3, .sample_count = if (smoke) 3 else 12, .workloads = metrics };
    if (json) {
        var out: std.Io.Writer.Allocating = .init(allocator);
        var stringify: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try stringify.write(report);
        try out.writer.writeByte('\n');
        var buffer: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &buffer);
        try stdout.interface.writeAll(out.written());
        try stdout.interface.flush();
    } else {
        for (metrics) |metric| std.debug.print("{s}: {d:.2} FPS, {d:.2} draws/s, {d:.2} triangles/s, p50/p95/p99={d}/{d}/{d}us\n", .{ metric.category, metric.fps, metric.draws_s, metric.triangles_s, metric.frame.p50_ns / 1000, metric.frame.p95_ns / 1000, metric.frame.p99_ns / 1000 });
    }
}

test "application workload profiles represent distinct draw usage" {
    const allocator = std.testing.allocator;
    var desktop = try buildWorkload(allocator, .desktop);
    defer desktop.deinit(allocator);
    var terminal = try buildWorkload(allocator, .terminal);
    defer terminal.deinit(allocator);
    var game = try buildWorkload(allocator, .game);
    defer game.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 36), desktop.draws.len);
    try std.testing.expectEqual(@as(u32, 72), desktop.triangles_per_frame);
    try std.testing.expectEqual(@as(usize, 241), terminal.draws.len);
    try std.testing.expectEqual(@as(u32, 482), terminal.triangles_per_frame);
    try std.testing.expectEqual(@as(usize, 32), game.draws.len);
    try std.testing.expectEqual(@as(u32, 384), game.triangles_per_frame);
    try std.testing.expect(terminal.texture_width > 4);
    try std.testing.expect(game.draws[0].uniform.len > desktop.draws[0].uniform.len);
    try std.testing.expect(getFloat(desktop.draws[0].uniform, 64) < -1.0);
    try std.testing.expect(getFloat(terminal.draws[1].uniform, 64) < -1.0);
}

test "application workloads match the serial raster oracle" {
    const allocator = std.testing.allocator;
    const kinds = [_]Kind{ .desktop, .terminal, .game };
    defer cube.shutdownParallelWorkers();

    for (kinds) |kind| {
        var workload = try buildWorkload(allocator, kind);
        defer workload.deinit(allocator);
        const serial_color = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(serial_color);
        const serial_depth = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(serial_depth);
        const parallel_color = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(parallel_color);
        const parallel_depth = try allocator.alloc(u8, surface_bytes);
        defer allocator.free(parallel_depth);

        const serial = try renderSerial(&workload, serial_color, serial_depth);
        const parallel = try renderParallel(&workload, parallel_color, parallel_depth);
        try std.testing.expectEqual(serial.checksum, parallel.checksum);
        try std.testing.expectEqualSlices(u8, serial_color, parallel_color);
        try std.testing.expectEqualSlices(u8, serial_depth, parallel_depth);
        try std.testing.expectEqual(serial.counters.triangles_submitted, parallel.counters.triangles_submitted);
        try std.testing.expectEqual(serial.counters.triangles_rasterized, parallel.counters.triangles_rasterized);
        try std.testing.expect(serial.counters.triangles_submitted > 0);
        try std.testing.expect(serial.counters.fragments_covered > 0);
        try std.testing.expect(serial.counters.fragments_tested >= serial.counters.fragments_covered);

        if (kind == .game) {
            updateWorkload(&workload, 9);
            const dynamic_serial = try renderSerial(&workload, serial_color, serial_depth);
            const dynamic_parallel = try renderParallel(&workload, parallel_color, parallel_depth);
            try std.testing.expect(dynamic_serial.checksum != serial.checksum);
            try std.testing.expectEqual(dynamic_serial.checksum, dynamic_parallel.checksum);
            try std.testing.expectEqualSlices(u8, serial_color, parallel_color);
            try std.testing.expectEqualSlices(u8, serial_depth, parallel_depth);
        }
    }
}

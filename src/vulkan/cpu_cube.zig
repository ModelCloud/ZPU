const std = @import("std");
const cpu_locality = @import("cpu_locality.zig");

pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };
pub const Rect = extern struct { x: i32, y: i32, width: u32, height: u32 };

/// Exact work counters for the deliberately narrow vkcube CPU rasterizer.
pub const Counters = struct {
    triangles_submitted: u64 = 0,
    triangles_rasterized: u64 = 0,
    fragments_tested: u64 = 0,
    fragments_covered: u64 = 0,
    depth_tests_passed: u64 = 0,
    color_writes: u64 = 0,
};

const Vertex = struct { screen: [3]f32, clip_w: f32, uv: [2]f32 };
const max_prepared_triangles = 12;
const PreparedTriangle = struct {
    valid: bool = false,
    vertices: [3]Vertex = undefined,
    lighting: [256]u8 = undefined,
};
const PreparedDraw = struct {
    count: usize = 0,
    triangles: [max_prepared_triangles]PreparedTriangle = [_]PreparedTriangle{.{}} ** max_prepared_triangles,
};

fn readFloat(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}

fn writeFloat(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn edge(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
}

fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(value: f32) f32 {
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

fn transformedVertex(uniform: []const u8, index: u32, vertex_count: u32, viewport: Viewport) ?Vertex {
    const position_base = 64 + @as(usize, index) * 16;
    const attr_base = 64 + @as(usize, vertex_count) * 16 + @as(usize, index) * 16;
    const position = [4]f32{ readFloat(uniform, position_base), readFloat(uniform, position_base + 4), readFloat(uniform, position_base + 8), readFloat(uniform, position_base + 12) };
    var clip = [_]f32{0} ** 4;
    for (0..4) |row| for (0..4) |column| {
        clip[row] += readFloat(uniform, (column * 4 + row) * 4) * position[column];
    };
    if (!std.math.isFinite(clip[3]) or @abs(clip[3]) < 0.000001) return null;
    const inverse_w = 1.0 / clip[3];
    const ndc = [3]f32{ clip[0] * inverse_w, clip[1] * inverse_w, clip[2] * inverse_w };
    return .{
        .screen = .{ viewport.x + (ndc[0] * 0.5 + 0.5) * viewport.width, viewport.y + (ndc[1] * 0.5 + 0.5) * viewport.height, viewport.min_depth + ndc[2] * (viewport.max_depth - viewport.min_depth) },
        .clip_w = clip[3],
        .uv = .{ readFloat(uniform, attr_base), readFloat(uniform, attr_base + 4) },
    };
}

fn lightingTable(light: f32) [256]u8 {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*result, encoded_value| {
        const encoded = @as(f32, @floatFromInt(encoded_value)) / 255.0;
        const lit = std.math.clamp(srgbToLinear(encoded) * light, 0, 1);
        result.* = @intFromFloat(std.math.clamp(linearToSrgb(lit), 0, 1) * 255.0);
    }
    return table;
}

fn triangleLight(v0: Vertex, v1: Vertex, v2: Vertex) f32 {
    const dx1 = v1.screen[0] - v0.screen[0];
    const dy1 = v1.screen[1] - v0.screen[1];
    const dz1 = v1.screen[2] - v0.screen[2];
    const dx2 = v2.screen[0] - v0.screen[0];
    const dy2 = v2.screen[1] - v0.screen[1];
    const dz2 = v2.screen[2] - v0.screen[2];
    var normal = [3]f32{ dy1 * dz2 - dz1 * dy2, dz1 * dx2 - dx1 * dz2, dx1 * dy2 - dy1 * dx2 };
    const normal_length = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
    if (normal_length > 0.000001) {
        for (&normal) |*component| component.* /= normal_length;
    }
    return std.math.clamp(normal[0] * 0.424 + normal[1] * 0.566 + normal[2] * 0.707, 0.15, 1.0);
}

fn prepareDraw(uniform: []const u8, vertex_count: u32, viewport: Viewport) PreparedDraw {
    var prepared = PreparedDraw{ .count = @min(vertex_count / 3, max_prepared_triangles) };
    for (prepared.triangles[0..prepared.count], 0..) |*triangle, index| {
        const first: u32 = @intCast(index * 3);
        const v0 = transformedVertex(uniform, first, vertex_count, viewport) orelse continue;
        const v1 = transformedVertex(uniform, first + 1, vertex_count, viewport) orelse continue;
        const v2 = transformedVertex(uniform, first + 2, vertex_count, viewport) orelse continue;
        triangle.* = .{ .valid = true, .vertices = .{ v0, v1, v2 }, .lighting = lightingTable(triangleLight(v0, v1, v2)) };
    }
    return prepared;
}

fn preparedBounds(prepared: *const PreparedDraw, width: u32, height: u32, scissor: Rect) Rect {
    var min_x: f32 = @floatFromInt(width);
    var min_y: f32 = @floatFromInt(height);
    var max_x: f32 = 0;
    var max_y: f32 = 0;
    var found = false;
    for (prepared.triangles[0..prepared.count]) |triangle| {
        if (!triangle.valid) continue;
        for (triangle.vertices) |vertex| {
            if (!std.math.isFinite(vertex.screen[0]) or !std.math.isFinite(vertex.screen[1])) continue;
            min_x = @min(min_x, vertex.screen[0]);
            min_y = @min(min_y, vertex.screen[1]);
            max_x = @max(max_x, vertex.screen[0]);
            max_y = @max(max_y, vertex.screen[1]);
            found = true;
        }
    }
    if (!found) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    const x0 = @max(@as(i32, @intFromFloat(@floor(std.math.clamp(min_x, 0, @as(f32, @floatFromInt(width)))))), scissor.x, 0);
    const y0 = @max(@as(i32, @intFromFloat(@floor(std.math.clamp(min_y, 0, @as(f32, @floatFromInt(height)))))), scissor.y, 0);
    const x1 = @min(@as(i32, @intFromFloat(@ceil(std.math.clamp(max_x, 0, @as(f32, @floatFromInt(width)))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
    const y1 = @min(@as(i32, @intFromFloat(@ceil(std.math.clamp(max_y, 0, @as(f32, @floatFromInt(height)))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
    if (x1 <= x0 or y1 <= y0) return .{ .x = 0, .y = 0, .width = 0, .height = 0 };
    return .{ .x = x0, .y = y0, .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
}

fn shade(texture: []const u8, texture_width: u32, texture_height: u32, u: f32, v: f32, table: *const [256]u8) [4]u8 {
    const clamped_u = std.math.clamp(u, 0, 0.999999);
    const clamped_v = std.math.clamp(v, 0, 0.999999);
    const x: usize = @intFromFloat(clamped_u * @as(f32, @floatFromInt(texture_width)));
    const y: usize = @intFromFloat(clamped_v * @as(f32, @floatFromInt(texture_height)));
    const offset = (y * texture_width + x) * 4;
    const rgb = [3]u8{ table[texture[offset]], table[texture[offset + 1]], table[texture[offset + 2]] };
    return .{ rgb[2], rgb[1], rgb[0], texture[offset + 3] };
}

fn stripeLane(y: i32, height: u32, lane_count: usize, stripe_count: usize) usize {
    if (lane_count == 1) return 0;
    const stripe = @min((@as(u64, @intCast(y)) * stripe_count) / height, stripe_count - 1);
    return @intCast(stripe % lane_count);
}

fn drawInternal(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters, optimized: bool, cull_mode: u32, front_face: i32, lane_index: usize, lane_count: usize, stripe_count: usize, prepared: ?*const PreparedDraw, comptime count_work: bool) usize {
    if (vertex_count == 0 or vertex_count % 3 != 0 or uniform.len < 64 + @as(usize, vertex_count) * 32 or target.len != @as(usize, width) * height * 4 or depth.len < @as(usize, width) * height * 4 or texture.len != @as(usize, texture_width) * texture_height * 4 or texture_width == 0 or texture_height == 0) return 0;
    if (count_work) counters.triangles_submitted += vertex_count / 3;
    var row_lanes: [4096]u8 = undefined;
    if (lane_count != 1) {
        for (row_lanes[0..height], 0..) |*lane, y| lane.* = @intCast(stripeLane(@intCast(y), height, lane_count, stripe_count));
    }
    var pixels_written: usize = 0;
    var lighting_keys: [12]u32 = undefined;
    var lighting_tables: [12][256]u8 = undefined;
    var lighting_count: usize = 0;
    var triangle: u32 = 0;
    while (triangle < vertex_count) : (triangle += 3) {
        const prepared_triangle: ?*const PreparedTriangle = if (prepared) |state| blk: {
            const index = triangle / 3;
            if (index >= state.count) break :blk null;
            if (!state.triangles[index].valid) continue;
            break :blk &state.triangles[index];
        } else null;
        const v0 = if (prepared_triangle) |state| state.vertices[0] else transformedVertex(uniform, triangle, vertex_count, viewport) orelse continue;
        const v1 = if (prepared_triangle) |state| state.vertices[1] else transformedVertex(uniform, triangle + 1, vertex_count, viewport) orelse continue;
        const v2 = if (prepared_triangle) |state| state.vertices[2] else transformedVertex(uniform, triangle + 2, vertex_count, viewport) orelse continue;
        const p0 = [2]f32{ v0.screen[0], v0.screen[1] };
        const p1 = [2]f32{ v1.screen[0], v1.screen[1] };
        const p2 = [2]f32{ v2.screen[0], v2.screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const front_facing = if (front_face == 0) area < 0 else area > 0;
        if ((front_facing and cull_mode & 1 != 0) or (!front_facing and cull_mode & 2 != 0)) continue;
        if (count_work) counters.triangles_rasterized += 1;

        const lighting = if (prepared_triangle) |state| &state.lighting else blk: {
            const light = triangleLight(v0, v1, v2);
            const lighting_key: u32 = @bitCast(light);
            var lighting_index: usize = 0;
            while (lighting_index < lighting_count and lighting_keys[lighting_index] != lighting_key) : (lighting_index += 1) {}
            if (lighting_index == lighting_count) {
                if (lighting_count == lighting_tables.len) lighting_index = 0;
                lighting_keys[lighting_index] = lighting_key;
                lighting_tables[lighting_index] = lightingTable(light);
                if (lighting_count < lighting_tables.len) lighting_count += 1;
            }
            break :blk &lighting_tables[lighting_index];
        };

        const inverse_area = 1.0 / area;
        const inv_w0 = 1.0 / v0.clip_w;
        const inv_w1 = 1.0 / v1.clip_w;
        const inv_w2 = 1.0 / v2.clip_w;
        const z0w = v0.screen[2] * inv_w0;
        const z1w = v1.screen[2] * inv_w1;
        const z2w = v2.screen[2] * inv_w2;
        const u_over_w0 = v0.uv[0] * inv_w0;
        const u_over_w1 = v1.uv[0] * inv_w1;
        const u_over_w2 = v2.uv[0] * inv_w2;
        const v_over_w0 = v0.uv[1] * inv_w0;
        const v_over_w1 = v1.uv[1] * inv_w1;
        const v_over_w2 = v2.uv[1] * inv_w2;
        const b0_dx = (p2[1] - p1[1]) * inverse_area;
        const b1_dx = (p0[1] - p2[1]) * inverse_area;
        const b2_dx = (p1[1] - p0[1]) * inverse_area;
        const inverse_w_dx = b0_dx * inv_w0 + b1_dx * inv_w1 + b2_dx * inv_w2;
        const z_over_w_dx = b0_dx * z0w + b1_dx * z1w + b2_dx * z2w;
        const u_over_w_dx = b0_dx * u_over_w0 + b1_dx * u_over_w1 + b2_dx * u_over_w2;
        const v_over_w_dx = b0_dx * v_over_w0 + b1_dx * v_over_w1 + b2_dx * v_over_w2;

        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), scissor.x, 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), scissor.y, 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
        const tile_size: i32 = if (optimized) 8 else 1;
        var tile_y: i32 = min_y;
        while (tile_y < max_y) : (tile_y += tile_size) {
            const tile_max_y = @min(tile_y + tile_size, max_y);
            if (lane_count != 1) {
                var lane_has_rows = false;
                var candidate_y = tile_y;
                while (candidate_y < tile_max_y) : (candidate_y += 1) {
                    if (row_lanes[@intCast(candidate_y)] == lane_index) lane_has_rows = true;
                }
                if (!lane_has_rows) continue;
            }
            var tile_x: i32 = min_x;
            while (tile_x < max_x) : (tile_x += tile_size) {
                const tile_max_x = @min(tile_x + tile_size, max_x);
                // Reject a tile when every one of its sample-space corners is
                // outside the same edge. This is conservative and retains the
                // original per-fragment coverage/depth/draw ordering.
                const corners = [4][2]f32{
                    .{ @as(f32, @floatFromInt(tile_x)) + 0.5, @as(f32, @floatFromInt(tile_y)) + 0.5 },
                    .{ @as(f32, @floatFromInt(tile_max_x - 1)) + 0.5, @as(f32, @floatFromInt(tile_y)) + 0.5 },
                    .{ @as(f32, @floatFromInt(tile_x)) + 0.5, @as(f32, @floatFromInt(tile_max_y - 1)) + 0.5 },
                    .{ @as(f32, @floatFromInt(tile_max_x - 1)) + 0.5, @as(f32, @floatFromInt(tile_max_y - 1)) + 0.5 },
                };
                var reject = false;
                var fully_covered = true;
                inline for (.{ .{ p1, p2 }, .{ p2, p0 }, .{ p0, p1 } }) |segment| {
                    const corner_edges = [4]f32{
                        edge(segment[0], segment[1], corners[0]) * inverse_area,
                        edge(segment[0], segment[1], corners[1]) * inverse_area,
                        edge(segment[0], segment[1], corners[2]) * inverse_area,
                        edge(segment[0], segment[1], corners[3]) * inverse_area,
                    };
                    if (corner_edges[0] < 0 and corner_edges[1] < 0 and corner_edges[2] < 0 and corner_edges[3] < 0) reject = true;
                    if (corner_edges[0] < 0 or corner_edges[1] < 0 or corner_edges[2] < 0 or corner_edges[3] < 0) fully_covered = false;
                }
                if (optimized and reject) continue;
                var y = tile_y;
                while (y < tile_max_y) : (y += 1) {
                    if (lane_count != 1 and row_lanes[@intCast(y)] != lane_index) continue;
                    var x = tile_x;
                    const first_sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                    var b0 = edge(p1, p2, first_sample) * inverse_area;
                    var b1 = edge(p2, p0, first_sample) * inverse_area;
                    var b2 = edge(p0, p1, first_sample) * inverse_area;
                    var stepped_inverse_w = b0 * inv_w0 + b1 * inv_w1 + b2 * inv_w2;
                    var stepped_z_over_w = b0 * z0w + b1 * z1w + b2 * z2w;
                    var stepped_u_over_w = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
                    var stepped_v_over_w = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
                    while (x < tile_max_x) : (x += 1) {
                        const sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                        const fragment_b0 = if (optimized) b0 else edge(p1, p2, sample) * inverse_area;
                        const fragment_b1 = if (optimized) b1 else edge(p2, p0, sample) * inverse_area;
                        const fragment_b2 = if (optimized) b2 else edge(p0, p1, sample) * inverse_area;
                        if (count_work) counters.fragments_tested += 1;
                        if (fully_covered or (fragment_b0 >= 0 and fragment_b1 >= 0 and fragment_b2 >= 0)) {
                            if (count_work) counters.fragments_covered += 1;
                            const inverse_w = if (optimized) stepped_inverse_w else fragment_b0 * inv_w0 + fragment_b1 * inv_w1 + fragment_b2 * inv_w2;
                            if (@abs(inverse_w) >= 0.000001) {
                                const reciprocal_w = 1.0 / inverse_w;
                                const z_over_w = if (optimized) stepped_z_over_w else fragment_b0 * z0w + fragment_b1 * z1w + fragment_b2 * z2w;
                                const z = z_over_w * reciprocal_w;
                                const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                const depth_offset = pixel_index * 4;
                                if (z <= readFloat(depth, depth_offset)) {
                                    if (count_work) counters.depth_tests_passed += 1;
                                    writeFloat(depth, depth_offset, z);
                                    const u_over_w = if (optimized) stepped_u_over_w else fragment_b0 * u_over_w0 + fragment_b1 * u_over_w1 + fragment_b2 * u_over_w2;
                                    const v_over_w = if (optimized) stepped_v_over_w else fragment_b0 * v_over_w0 + fragment_b1 * v_over_w1 + fragment_b2 * v_over_w2;
                                    const u = u_over_w * reciprocal_w;
                                    const v = v_over_w * reciprocal_w;
                                    const color = shade(texture, texture_width, texture_height, u, v, lighting);
                                    @memcpy(target[pixel_index * 4 ..][0..4], &color);
                                    if (count_work) counters.color_writes += 1;
                                    pixels_written += 1;
                                }
                            }
                        }
                        b0 += b0_dx;
                        b1 += b1_dx;
                        b2 += b2_dx;
                        stepped_inverse_w += inverse_w_dx;
                        stepped_z_over_w += z_over_w_dx;
                        stepped_u_over_w += u_over_w_dx;
                        stepped_v_over_w += v_over_w_dx;
                    }
                }
            }
        }
    }
    return pixels_written;
}

pub fn drawCounted(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, true, 0, 0, 0, 1, 1, null, true);
}

/// Untiled scalar oracle used by differential tests and checksum validation.
pub fn drawReferenceCounted(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, false, 0, 0, 0, 1, 1, null, true);
}

const parallel_band_count = 5;
const parallel_slice_count = 40;
const ParallelBand = struct { counters: Counters = .{}, pixels_written: usize = 0 };
const ParallelDraw = struct {
    target: []u8,
    depth: []u8,
    width: u32,
    height: u32,
    uniform: []const u8,
    texture: []const u8,
    texture_width: u32,
    texture_height: u32,
    vertex_count: u32,
    viewport: Viewport,
    scissor: Rect,
    cull_mode: u32,
    front_face: i32,
    prepared: PreparedDraw,
    bands: [parallel_band_count]ParallelBand = [_]ParallelBand{.{}} ** parallel_band_count,
};
const ParallelClear = struct { color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32 = 0, rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
const ParallelJob = union(enum) { draw: *ParallelDraw, clear: *ParallelClear };

var parallel_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var parallel_condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var parallel_started = false;
var parallel_available = false;
var parallel_ready: usize = 0;
var parallel_generation = std.atomic.Value(u64).init(0);
var parallel_completed = std.atomic.Value(usize).init(0);
var parallel_active: ?ParallelJob = null;

// A raster worker normally finishes less than one frame before its next job.
// Keep it runnable across that short gap so the render thread is not exposed
// to the millisecond-scale tail of a condition-variable wake. Idle workers
// still sleep after this bounded interval.
const parallel_idle_spin_ns: u64 = 5_000_000;

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn waitForParallelGeneration(observed_generation: u64) u64 {
    const deadline = monotonicNs() +| parallel_idle_spin_ns;
    var spins: usize = 0;
    while (parallel_generation.load(.acquire) == observed_generation) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins % 1024 == 0 and monotonicNs() >= deadline) break;
    }
    const current_generation = parallel_generation.load(.acquire);
    if (current_generation != observed_generation) return current_generation;

    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    while (parallel_generation.load(.acquire) == observed_generation) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    const next_generation = parallel_generation.load(.acquire);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    return next_generation;
}

fn runParallelBand(context: *ParallelDraw, band_index: usize) void {
    const band = &context.bands[band_index];
    band.pixels_written = drawInternal(context.target, context.depth, context.width, context.height, context.uniform, context.texture, context.texture_width, context.texture_height, context.vertex_count, context.viewport, context.scissor, &band.counters, true, context.cull_mode, context.front_face, band_index, parallel_band_count, parallel_slice_count, &context.prepared, false);
}

fn fillPatternLane(bytes: []u8, pattern: u32, lane_index: usize) void {
    const aligned: []align(4) u8 = @alignCast(bytes);
    const words = std.mem.bytesAsSlice(u32, aligned);
    const start = words.len * lane_index / parallel_band_count;
    const end = words.len * (lane_index + 1) / parallel_band_count;
    @memset(words[start..end], pattern);
}

fn fillPatternRectLane(bytes: []u8, width: u32, rect: Rect, pattern: u32, lane_index: usize) void {
    if (rect.width == 0 or rect.height == 0) return;
    const aligned: []align(4) u8 = @alignCast(bytes);
    const words = std.mem.bytesAsSlice(u32, aligned);
    const first_row = @as(usize, @intCast(rect.y)) + @as(usize, rect.height) * lane_index / parallel_band_count;
    const last_row = @as(usize, @intCast(rect.y)) + @as(usize, rect.height) * (lane_index + 1) / parallel_band_count;
    const x: usize = @intCast(rect.x);
    for (first_row..last_row) |y| {
        const start = y * width + x;
        @memset(words[start..][0..rect.width], pattern);
    }
}

fn runParallelJob(job: ParallelJob, lane_index: usize) void {
    switch (job) {
        .draw => |context| runParallelBand(context, lane_index),
        .clear => |context| {
            if (context.width == 0) {
                fillPatternLane(context.color, context.color_pattern, lane_index);
                fillPatternLane(context.depth, context.depth_pattern, lane_index);
            } else {
                fillPatternRectLane(context.color, context.width, context.rect, context.color_pattern, lane_index);
                fillPatternRectLane(context.depth, context.width, context.rect, context.depth_pattern, lane_index);
            }
        },
    }
}

fn parallelWorker(worker_index: usize) void {
    _ = cpu_locality.pinRasterWorker(worker_index);
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    parallel_ready += 1;
    _ = std.c.pthread_cond_broadcast(&parallel_condition);
    var observed_generation = parallel_generation.load(.acquire);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    while (true) {
        observed_generation = waitForParallelGeneration(observed_generation);
        const job = parallel_active.?;
        runParallelJob(job, worker_index + 1);
        _ = parallel_completed.fetchAdd(1, .release);
    }
}

fn ensureParallelWorkers() bool {
    if (parallel_started) return parallel_available;
    parallel_started = true;
    for (0..(parallel_band_count - 1)) |worker_index| {
        const worker = std.Thread.spawn(.{}, parallelWorker, .{worker_index}) catch return false;
        worker.detach();
    }
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    while (parallel_ready != parallel_band_count - 1) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    parallel_available = true;
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    return true;
}

fn dispatchParallel(job: ParallelJob) bool {
    if (!ensureParallelWorkers()) return false;
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    while (parallel_active != null) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    parallel_active = job;
    parallel_completed.store(0, .release);
    _ = parallel_generation.fetchAdd(1, .release);
    _ = std.c.pthread_cond_broadcast(&parallel_condition);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);

    runParallelJob(job, 0);
    while (parallel_completed.load(.acquire) != parallel_band_count - 1) std.atomic.spinLoopHint();

    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    parallel_active = null;
    _ = std.c.pthread_cond_broadcast(&parallel_condition);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    return true;
}

fn drawParallel(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: ?*Rect) ?usize {
    var context = ParallelDraw{ .target = target, .depth = depth, .width = width, .height = height, .uniform = uniform, .texture = texture, .texture_width = texture_width, .texture_height = texture_height, .vertex_count = vertex_count, .viewport = viewport, .scissor = scissor, .cull_mode = cull_mode, .front_face = front_face, .prepared = prepareDraw(uniform, vertex_count, viewport) };
    if (bounds) |output| output.* = preparedBounds(&context.prepared, width, height, scissor);
    if (!dispatchParallel(.{ .draw = &context })) return null;

    var pixels_written: usize = 0;
    for (context.bands) |band| pixels_written += band.pixels_written;
    return pixels_written;
}

pub fn clearImagesParallel(color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32) bool {
    var context = ParallelClear{ .color = color, .color_pattern = color_pattern, .depth = depth, .depth_pattern = depth_pattern };
    return dispatchParallel(.{ .clear = &context });
}

pub fn clearImageRegionsParallel(color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32, rect: Rect) bool {
    var context = ParallelClear{ .color = color, .color_pattern = color_pattern, .depth = depth, .depth_pattern = depth_pattern, .width = width, .rect = rect };
    return dispatchParallel(.{ .clear = &context });
}

pub fn drawTracked(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect) usize {
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, cull_mode, front_face, bounds)) |pixels_written| return pixels_written;
    const prepared = prepareDraw(uniform, vertex_count, viewport);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, false);
}

pub fn draw(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32) usize {
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, cull_mode, front_face, null)) |pixels_written| return pixels_written;
    var counters = Counters{};
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, null, false);
}

test "one textured triangle updates color and depth" {
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 1 } };
    for (positions, 0..) |position, i| {
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + i * 16 + component * 4, value);
        for (uvs[i], 0..) |value, component| writeFloat(&uniform, 64 + 3 * 16 + i * 16 + component * 4, value);
    }
    var target = [_]u8{0} ** (8 * 8 * 4);
    var depth = [_]u8{0} ** (8 * 8 * 4);
    var offset: usize = 0;
    while (offset < depth.len) : (offset += 4) writeFloat(&depth, offset, 1);
    const texture = [_]u8{ 255, 255, 255, 255 };
    try std.testing.expect(draw(&target, &depth, 8, 8, &uniform, &texture, 1, 1, 3, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0, 0) > 0);
    try std.testing.expect(target[(4 * 8 + 4) * 4] != 0);
    try std.testing.expect(readFloat(&depth, (4 * 8 + 4) * 4) < 1);

    var culled_target = [_]u8{0} ** (8 * 8 * 4);
    var culled_depth = [_]u8{0} ** (8 * 8 * 4);
    offset = 0;
    while (offset < culled_depth.len) : (offset += 4) writeFloat(&culled_depth, offset, 1);
    try std.testing.expectEqual(@as(usize, 0), draw(&culled_target, &culled_depth, 8, 8, &uniform, &texture, 1, 1, 3, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, 1, 0));
}

test "tiled renderer is pixel exact with untiled scalar reference for odd tails" {
    const w = 17;
    const h = 13;
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.91, -0.77, 0.5, 1 }, .{ 0.83, -0.61, 0.5, 1 }, .{ 0.07, 0.94, 0.5, 1 } };
    const uvs = [_][2]f32{ .{ -0.2, 0 }, .{ 1.2, 0.1 }, .{ 0.5, 1.1 } };
    for (positions, 0..) |position, i| {
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + i * 16 + component * 4, value);
        for (uvs[i], 0..) |value, component| writeFloat(&uniform, 64 + 3 * 16 + i * 16 + component * 4, value);
    }
    const texture = [_]u8{ 1, 2, 3, 255, 20, 30, 40, 255, 90, 80, 70, 255, 250, 240, 230, 255 };
    var fast = [_]u8{7} ** (w * h * 4);
    var reference = fast;
    var fast_depth: [w * h * 4]u8 = undefined;
    var reference_depth: [w * h * 4]u8 = undefined;
    var offset: usize = 0;
    while (offset < fast_depth.len) : (offset += 4) {
        writeFloat(&fast_depth, offset, 1);
        writeFloat(&reference_depth, offset, 1);
    }
    var fast_counters = Counters{};
    var reference_counters = Counters{};
    const viewport = Viewport{ .x = 0, .y = 0, .width = w, .height = h, .min_depth = 0, .max_depth = 1 };
    const scissor = Rect{ .x = 1, .y = 1, .width = w - 2, .height = h - 2 };
    const fast_written = drawCounted(&fast, &fast_depth, w, h, &uniform, &texture, 2, 2, 3, viewport, scissor, &fast_counters);
    const reference_written = drawReferenceCounted(&reference, &reference_depth, w, h, &uniform, &texture, 2, 2, 3, viewport, scissor, &reference_counters);
    try std.testing.expectEqual(reference_written, fast_written);
    try std.testing.expectEqualSlices(u8, &reference, &fast);
    try std.testing.expectEqualSlices(u8, &reference_depth, &fast_depth);
}

test "interleaved parallel lanes are pixel exact with serial rendering" {
    const w = 17;
    const h = 129;
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.91, -0.77, 0.5, 1 }, .{ 0.83, -0.61, 0.5, 1 }, .{ 0.07, 0.94, 0.5, 1 } };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 1 } };
    for (positions, 0..) |position, i| {
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + i * 16 + component * 4, value);
        for (uvs[i], 0..) |value, component| writeFloat(&uniform, 64 + 3 * 16 + i * 16 + component * 4, value);
    }
    const texture = [_]u8{ 1, 2, 3, 255, 20, 30, 40, 255, 90, 80, 70, 255, 250, 240, 230, 255 };
    var parallel = [_]u8{7} ** (w * h * 4);
    var serial = parallel;
    var parallel_depth: [w * h * 4]u8 = undefined;
    var serial_depth: [w * h * 4]u8 = undefined;
    var offset: usize = 0;
    while (offset < parallel_depth.len) : (offset += 4) {
        writeFloat(&parallel_depth, offset, 1);
        writeFloat(&serial_depth, offset, 1);
    }
    const viewport = Viewport{ .x = 0, .y = 0, .width = w, .height = h, .min_depth = 0, .max_depth = 1 };
    const scissor = Rect{ .x = 0, .y = 0, .width = w, .height = h };
    var serial_counters = Counters{};
    const serial_written = drawInternal(&serial, &serial_depth, w, h, &uniform, &texture, 2, 2, 3, viewport, scissor, &serial_counters, true, 0, 0, 0, 1, 1, null, false);
    var parallel_written: usize = 0;
    for (0..parallel_band_count) |lane| {
        var counters = Counters{};
        parallel_written += drawInternal(&parallel, &parallel_depth, w, h, &uniform, &texture, 2, 2, 3, viewport, scissor, &counters, true, 0, 0, lane, parallel_band_count, parallel_slice_count, null, false);
    }
    try std.testing.expectEqual(serial_written, parallel_written);
    try std.testing.expectEqualSlices(u8, &serial, &parallel);
    try std.testing.expectEqualSlices(u8, &serial_depth, &parallel_depth);
}

test "prepared bounds conservatively cover transformed content" {
    const vertex = Vertex{ .screen = .{ 3.25, 4.5, 0.5 }, .clip_w = 1, .uv = .{ 0, 0 } };
    var prepared = PreparedDraw{ .count = 1 };
    prepared.triangles[0] = .{ .valid = true, .vertices = .{
        vertex,
        .{ .screen = .{ 12.75, 5.25, 0.5 }, .clip_w = 1, .uv = .{ 0, 0 } },
        .{ .screen = .{ 8.5, 15.75, 0.5 }, .clip_w = 1, .uv = .{ 0, 0 } },
    }, .lighting = undefined };
    try std.testing.expectEqual(Rect{ .x = 3, .y = 4, .width = 10, .height = 12 }, preparedBounds(&prepared, 20, 20, .{ .x = 0, .y = 0, .width = 20, .height = 20 }));
    try std.testing.expectEqual(Rect{ .x = 5, .y = 6, .width = 5, .height = 4 }, preparedBounds(&prepared, 20, 20, .{ .x = 5, .y = 6, .width = 5, .height = 4 }));
}

test "regional clear changes only the requested rectangle" {
    var bytes = [_]u8{0} ** (8 * 8 * 4);
    for (0..parallel_band_count) |lane| fillPatternRectLane(&bytes, 8, .{ .x = 2, .y = 1, .width = 3, .height = 5 }, 0x44332211, lane);
    const words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(&bytes)));
    for (0..8) |y| for (0..8) |x| {
        const inside = x >= 2 and x < 5 and y >= 1 and y < 6;
        try std.testing.expectEqual(if (inside) @as(u32, 0x44332211) else 0, words[y * 8 + x]);
    };
}

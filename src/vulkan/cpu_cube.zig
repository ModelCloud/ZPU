// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const cpu_locality = @import("cpu_locality.zig");

pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };
pub const Rect = extern struct { x: i32, y: i32, width: u32, height: u32 };
pub const dirty_tile_size: usize = 32;
pub const max_dirty_tile_bytes: usize = 8192;

pub fn dirtyTileByteCount(width: u32, height: u32) usize {
    const columns = (@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size;
    const rows = (@as(usize, height) + dirty_tile_size - 1) / dirty_tile_size;
    return (columns * rows + 7) / 8;
}

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
const QuadFloat = @Vector(4, f32);
const QuadClassification = struct { reject: bool, fully_covered: bool };
const max_prepared_triangles = 12;
const PreparedTriangle = struct {
    valid: bool = false,
    vertices: [3]Vertex = undefined,
    lighting: *const [256]u8 = undefined,
    unit_uv: bool = false,
};
const PreparedDraw = struct {
    count: usize = 0,
    triangles: [max_prepared_triangles]PreparedTriangle = [_]PreparedTriangle{.{}} ** max_prepared_triangles,
};

pub const IndexStream = struct {
    bytes: []const u8,
    index_type: i32,
    vertex_offset: i32,

    pub fn init(bytes: []const u8, index_type: i32, vertex_offset: i32) ?IndexStream {
        const index_size: usize = if (index_type == 0) 2 else if (index_type == 1) 4 else return null;
        if (bytes.len == 0 or bytes.len % index_size != 0) return null;
        return .{ .bytes = bytes, .index_type = index_type, .vertex_offset = vertex_offset };
    }

    fn sourceIndex(self: IndexStream, emitted_index: u32) ?u32 {
        const index_size: usize = if (self.index_type == 0) 2 else 4;
        const offset = @as(usize, emitted_index) * index_size;
        if (offset > self.bytes.len or index_size > self.bytes.len - offset) return null;
        const raw: u32 = if (index_size == 2) std.mem.readInt(u16, self.bytes[offset..][0..2], .little) else std.mem.readInt(u32, self.bytes[offset..][0..4], .little);
        const adjusted = @as(i64, raw) + self.vertex_offset;
        if (adjusted < 0 or adjusted > std.math.maxInt(u32)) return null;
        return @intCast(adjusted);
    }
};

fn packedVertexCount(uniform: []const u8) ?u32 {
    if (uniform.len < 64 + 32 or (uniform.len - 64) % 32 != 0) return null;
    const count = (uniform.len - 64) / 32;
    if (count > std.math.maxInt(u32)) return null;
    return @intCast(count);
}

fn readFloat(bytes: []const u8, offset: usize) f32 {
    return @bitCast(std.mem.readInt(u32, bytes[offset..][0..4], .little));
}

fn writeFloat(bytes: []u8, offset: usize, value: f32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], @bitCast(value), .little);
}

fn edge(a: [2]f32, b: [2]f32, p: [2]f32) f32 {
    return (p[0] - a[0]) * (b[1] - a[1]) - (p[1] - a[1]) * (b[0] - a[0]);
}

fn classifyQuad(p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, x: QuadFloat, y: QuadFloat) QuadClassification {
    var result = QuadClassification{ .reject = false, .fully_covered = true };
    inline for (.{ .{ p1, p2 }, .{ p2, p0 }, .{ p0, p1 } }) |segment| {
        const values = ((x - @as(QuadFloat, @splat(segment[0][0]))) * @as(QuadFloat, @splat(segment[1][1] - segment[0][1])) - (y - @as(QuadFloat, @splat(segment[0][1]))) * @as(QuadFloat, @splat(segment[1][0] - segment[0][0]))) * @as(QuadFloat, @splat(inverse_area));
        const outside = values < @as(QuadFloat, @splat(0));
        result.reject = result.reject or @reduce(.And, outside);
        result.fully_covered = result.fully_covered and !@reduce(.Or, outside);
    }
    return result;
}

fn srgbToLinear(value: f32) f32 {
    return if (value <= 0.04045) value / 12.92 else std.math.pow(f32, (value + 0.055) / 1.055, 2.4);
}

fn linearToSrgb(value: f32) f32 {
    return if (value <= 0.0031308) value * 12.92 else 1.055 * std.math.pow(f32, value, 1.0 / 2.4) - 0.055;
}

fn transformedVertex(uniform: []const u8, index: u32, vertex_count: u32, viewport: Viewport, indexed: ?IndexStream) ?Vertex {
    const source_index = if (indexed) |stream| stream.sourceIndex(index) orelse return null else index;
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse return null else vertex_count;
    if (source_index >= source_vertex_count) return null;
    const position_base = 64 + @as(usize, source_index) * 16;
    const attr_base = 64 + @as(usize, source_vertex_count) * 16 + @as(usize, source_index) * 16;
    const position = [4]f32{ readFloat(uniform, position_base), readFloat(uniform, position_base + 4), readFloat(uniform, position_base + 8), readFloat(uniform, position_base + 12) };
    var clip_vector: QuadFloat = @splat(0);
    for (0..4) |column| {
        const matrix_column: QuadFloat = .{ readFloat(uniform, (column * 4) * 4), readFloat(uniform, (column * 4 + 1) * 4), readFloat(uniform, (column * 4 + 2) * 4), readFloat(uniform, (column * 4 + 3) * 4) };
        clip_vector += matrix_column * @as(QuadFloat, @splat(position[column]));
    }
    const clip: [4]f32 = clip_vector;
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

var lighting_cache_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var lighting_cache_ready = std.atomic.Value(bool).init(false);
const lighting_cache_levels = 256;
var lighting_cache: [lighting_cache_levels][256]u8 = undefined;

fn cachedLightingTable(light: f32) *const [256]u8 {
    if (!lighting_cache_ready.load(.acquire)) {
        _ = std.c.pthread_mutex_lock(&lighting_cache_mutex);
        defer _ = std.c.pthread_mutex_unlock(&lighting_cache_mutex);
        if (!lighting_cache_ready.load(.monotonic)) {
            for (&lighting_cache, 0..) |*table, level| {
                table.* = lightingTable(@as(f32, @floatFromInt(level)) / @as(f32, lighting_cache_levels - 1));
            }
            lighting_cache_ready.store(true, .release);
        }
    }
    const level: usize = @intFromFloat(std.math.clamp(light, 0, 1) * @as(f32, lighting_cache_levels - 1) + 0.5);
    return &lighting_cache[level];
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

fn prepareDraw(uniform: []const u8, vertex_count: u32, base_vertex: u32, viewport: Viewport, indexed: ?IndexStream) PreparedDraw {
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse 0 else base_vertex +| vertex_count;
    const max_uniform_vertices = (std.math.maxInt(usize) - 64) / 32;
    if (source_vertex_count > max_uniform_vertices or uniform.len < 64 + @as(usize, source_vertex_count) * 32) return .{};
    var prepared = PreparedDraw{ .count = @min(vertex_count / 3, max_prepared_triangles) };
    for (prepared.triangles[0..prepared.count], 0..) |*triangle, index| {
        const first: u32 = @intCast(index * 3);
        const first_source = if (indexed != null) first else base_vertex +| first;
        const v0 = transformedVertex(uniform, first_source, source_vertex_count, viewport, indexed) orelse continue;
        const v1 = transformedVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed) orelse continue;
        const v2 = transformedVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed) orelse continue;
        const unit_uv = for ([3]Vertex{ v0, v1, v2 }) |vertex| {
            if (vertex.uv[0] < 0 or vertex.uv[0] > 1 or vertex.uv[1] < 0 or vertex.uv[1] > 1) break false;
        } else (v0.clip_w > 0 and v1.clip_w > 0 and v2.clip_w > 0) or (v0.clip_w < 0 and v1.clip_w < 0 and v2.clip_w < 0);
        triangle.* = .{ .valid = true, .vertices = .{ v0, v1, v2 }, .lighting = cachedLightingTable(triangleLight(v0, v1, v2)), .unit_uv = unit_uv };
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

fn markPreparedDirtyTiles(prepared: *const PreparedDraw, width: u32, height: u32, scissor: Rect, cull_mode: u32, front_face: i32, tiles: []u8) void {
    const columns = (@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size;
    for (prepared.triangles[0..prepared.count]) |triangle| {
        if (!triangle.valid) continue;
        const p0 = [2]f32{ triangle.vertices[0].screen[0], triangle.vertices[0].screen[1] };
        const p1 = [2]f32{ triangle.vertices[1].screen[0], triangle.vertices[1].screen[1] };
        const p2 = [2]f32{ triangle.vertices[2].screen[0], triangle.vertices[2].screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const front_facing = if (front_face == 0) area < 0 else area > 0;
        if ((front_facing and cull_mode & 1 != 0) or (!front_facing and cull_mode & 2 != 0)) continue;
        const inverse_area = 1.0 / area;
        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), scissor.x, 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), scissor.y, 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
        if (max_x <= min_x or max_y <= min_y) continue;
        const first_tile_x: usize = @intCast(min_x);
        const last_tile_x: usize = @intCast(max_x - 1);
        const first_tile_y: usize = @intCast(min_y);
        const last_tile_y: usize = @intCast(max_y - 1);
        for (first_tile_y / dirty_tile_size..last_tile_y / dirty_tile_size + 1) |tile_y| {
            for (first_tile_x / dirty_tile_size..last_tile_x / dirty_tile_size + 1) |tile_x| {
                const x0 = @as(f32, @floatFromInt(tile_x * dirty_tile_size)) + 0.5;
                const y0 = @as(f32, @floatFromInt(tile_y * dirty_tile_size)) + 0.5;
                const x1 = @as(f32, @floatFromInt(@min((tile_x + 1) * dirty_tile_size, width) - 1)) + 0.5;
                const y1 = @as(f32, @floatFromInt(@min((tile_y + 1) * dirty_tile_size, height) - 1)) + 0.5;
                const classification = classifyQuad(p0, p1, p2, inverse_area, .{ x0, x1, x0, x1 }, .{ y0, y0, y1, y1 });
                if (!classification.reject) {
                    const index = tile_y * columns + tile_x;
                    tiles[index / 8] |= @as(u8, 1) << @intCast(index % 8);
                }
            }
        }
    }
}

fn shade(texture: []const u8, texture_width: u32, texture_height: u32, u: f32, v: f32, table: *const [256]u8, unit_uv: bool) u32 {
    const x: usize = if (unit_uv) @intFromFloat(u * (@as(f32, @floatFromInt(texture_width)) * 0.999999)) else @intFromFloat(std.math.clamp(u, 0, 0.999999) * @as(f32, @floatFromInt(texture_width)));
    const y: usize = if (unit_uv) @intFromFloat(v * (@as(f32, @floatFromInt(texture_height)) * 0.999999)) else @intFromFloat(std.math.clamp(v, 0, 0.999999) * @as(f32, @floatFromInt(texture_height)));
    const offset = (y * texture_width + x) * 4;
    return @as(u32, table[texture[offset + 2]]) |
        @as(u32, table[texture[offset + 1]]) << 8 |
        @as(u32, table[texture[offset]]) << 16 |
        @as(u32, texture[offset + 3]) << 24;
}

fn stripeLane(y: i32, height: u32, lane_count: usize, stripe_count: usize) usize {
    if (lane_count == 1) return 0;
    const stripe = @min((@as(u64, @intCast(y)) * stripe_count) / height, stripe_count - 1);
    return @intCast(stripe % lane_count);
}

fn drawInternal(target: ?[]u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, counters: *Counters, comptime optimized: bool, cull_mode: u32, front_face: i32, lane_index: usize, lane_count: usize, stripe_count: usize, prepared: ?*const PreparedDraw, indexed: ?IndexStream, comptime count_work: bool) usize {
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse return 0 else base_vertex +| vertex_count;
    if (vertex_count == 0 or vertex_count % 3 != 0 or source_vertex_count == 0 or uniform.len < 64 + @as(usize, source_vertex_count) * 32 or (target == null and depth == null) or texture.len != @as(usize, texture_width) * texture_height * 4 or texture_width == 0 or texture_height == 0) return 0;
    if (target) |color_bytes| if (color_bytes.len != @as(usize, width) * height * 4) return 0;
    if (depth) |depth_bytes| if (depth_bytes.len < @as(usize, width) * height * 4) return 0;
    if (count_work) counters.triangles_submitted += vertex_count / 3;
    var row_lanes: [8192]u8 = undefined;
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
        const first_source = if (indexed != null) triangle else base_vertex +| triangle;
        const v0 = if (prepared_triangle) |state| state.vertices[0] else transformedVertex(uniform, first_source, source_vertex_count, viewport, indexed) orelse continue;
        const v1 = if (prepared_triangle) |state| state.vertices[1] else transformedVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed) orelse continue;
        const v2 = if (prepared_triangle) |state| state.vertices[2] else transformedVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed) orelse continue;
        const p0 = [2]f32{ v0.screen[0], v0.screen[1] };
        const p1 = [2]f32{ v1.screen[0], v1.screen[1] };
        const p2 = [2]f32{ v2.screen[0], v2.screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const front_facing = if (front_face == 0) area < 0 else area > 0;
        if ((front_facing and cull_mode & 1 != 0) or (!front_facing and cull_mode & 2 != 0)) continue;
        if (count_work) counters.triangles_rasterized += 1;

        const lighting = if (target == null) &lighting_tables[0] else if (prepared_triangle) |state| state.lighting else blk: {
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
        const unit_uv = if (prepared_triangle) |state| state.unit_uv else false;

        const inverse_area = 1.0 / area;
        const inv_w0 = 1.0 / v0.clip_w;
        const inv_w1 = 1.0 / v1.clip_w;
        const inv_w2 = 1.0 / v2.clip_w;
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
        const z_dx = b0_dx * v0.screen[2] + b1_dx * v1.screen[2] + b2_dx * v2.screen[2];
        const u_over_w_dx = b0_dx * u_over_w0 + b1_dx * u_over_w1 + b2_dx * u_over_w2;
        const v_over_w_dx = b0_dx * v_over_w0 + b1_dx * v_over_w1 + b2_dx * v_over_w2;

        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), scissor.x, 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), scissor.y, 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
        const tile_size: i32 = if (optimized and width >= 3840) 32 else if (optimized) 8 else 1;
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
                const x0 = @as(f32, @floatFromInt(tile_x)) + 0.5;
                const y0 = @as(f32, @floatFromInt(tile_y)) + 0.5;
                const x1 = @as(f32, @floatFromInt(tile_max_x - 1)) + 0.5;
                const y1 = @as(f32, @floatFromInt(tile_max_y - 1)) + 0.5;
                const classification = classifyQuad(p0, p1, p2, inverse_area, .{ x0, x1, x0, x1 }, .{ y0, y0, y1, y1 });
                if (optimized and classification.reject) continue;
                const fully_covered = classification.fully_covered;
                var y = tile_y;
                while (y < tile_max_y) : (y += 1) {
                    if (lane_count != 1 and row_lanes[@intCast(y)] != lane_index) continue;
                    var x = tile_x;
                    const first_sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                    var b0 = edge(p1, p2, first_sample) * inverse_area;
                    var b1 = edge(p2, p0, first_sample) * inverse_area;
                    var b2 = edge(p0, p1, first_sample) * inverse_area;
                    var stepped_inverse_w = b0 * inv_w0 + b1 * inv_w1 + b2 * inv_w2;
                    var stepped_z = b0 * v0.screen[2] + b1 * v1.screen[2] + b2 * v2.screen[2];
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
                                const z = if (optimized) stepped_z else fragment_b0 * v0.screen[2] + fragment_b1 * v1.screen[2] + fragment_b2 * v2.screen[2];
                                const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                const depth_pass = if (depth) |depth_bytes| blk: {
                                    const depth_offset = pixel_index * 4;
                                    if (z > readFloat(depth_bytes, depth_offset)) break :blk false;
                                    if (count_work) counters.depth_tests_passed += 1;
                                    writeFloat(depth_bytes, depth_offset, z);
                                    break :blk true;
                                } else true;
                                if (depth_pass) {
                                    if (target) |color_bytes| {
                                        const reciprocal_w = 1.0 / inverse_w;
                                        const u_over_w = if (optimized) stepped_u_over_w else fragment_b0 * u_over_w0 + fragment_b1 * u_over_w1 + fragment_b2 * u_over_w2;
                                        const v_over_w = if (optimized) stepped_v_over_w else fragment_b0 * v_over_w0 + fragment_b1 * v_over_w1 + fragment_b2 * v_over_w2;
                                        const u = u_over_w * reciprocal_w;
                                        const v = v_over_w * reciprocal_w;
                                        const color = shade(texture, texture_width, texture_height, u, v, lighting, unit_uv);
                                        std.mem.writeInt(u32, color_bytes[pixel_index * 4 ..][0..4], color, .little);
                                        if (count_work) counters.color_writes += 1;
                                    }
                                    pixels_written += 1;
                                }
                            }
                        }
                        b0 += b0_dx;
                        b1 += b1_dx;
                        b2 += b2_dx;
                        stepped_inverse_w += inverse_w_dx;
                        stepped_z += z_dx;
                        stepped_u_over_w += u_over_w_dx;
                        stepped_v_over_w += v_over_w_dx;
                    }
                }
            }
        }
    }
    return pixels_written;
}

pub fn drawCounted(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, counters, true, 0, 0, 0, 1, 1, null, null, true);
}

/// Untiled scalar oracle used by differential tests and checksum validation.
pub fn drawReferenceCounted(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, counters, false, 0, 0, 0, 1, 1, null, null, true);
}

const parallel_band_count = 2;
const parallel_slice_count = 10;
const parallel_8k_slice_count = 40;
const ParallelBand = struct { counters: Counters = .{}, pixels_written: usize = 0 };
const ParallelDraw = struct {
    target: []u8,
    depth: ?[]u8,
    width: u32,
    height: u32,
    uniform: []const u8,
    texture: []const u8,
    texture_width: u32,
    texture_height: u32,
    vertex_count: u32,
    base_vertex: u32,
    viewport: Viewport,
    scissor: Rect,
    cull_mode: u32,
    front_face: i32,
    indexed: ?IndexStream,
    prepared: PreparedDraw,
    bands: [parallel_band_count]ParallelBand = [_]ParallelBand{.{}} ** parallel_band_count,
};
const ParallelClear = struct { color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32 = 0, rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
const ParallelTileClear = struct { color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32, height: u32, tiles: []const u8 };
const ParallelJob = union(enum) { draw: *ParallelDraw, clear: *ParallelClear, tile_clear: *ParallelTileClear };

var parallel_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var parallel_condition: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER;
var parallel_started = false;
var parallel_available = false;
var parallel_ready: usize = 0;
var parallel_stop = std.atomic.Value(bool).init(false);
var parallel_threads: [parallel_band_count - 1]std.Thread = undefined;
var parallel_generation = std.atomic.Value(u64).init(0);
var parallel_completed = std.atomic.Value(usize).init(0);
var parallel_active: ?ParallelJob = null;

// A raster worker normally finishes less than one frame before its next job.
// Keep it runnable across that short gap so the render thread is not exposed
// to the millisecond-scale tail of a condition-variable wake. The window only
// grows when an observed inter-job gap requires it, remains capped, and idle
// workers still sleep after that bounded interval.
const parallel_initial_spin_ns: u64 = 5_000_000;
const parallel_max_spin_ns: u64 = 16_000_000;
const parallel_spin_margin_ns: u64 = 500_000;

fn monotonicNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn waitForParallelGeneration(observed_generation: u64, spin_budget_ns: *u64) u64 {
    const wait_start = monotonicNs();
    const deadline = wait_start +| spin_budget_ns.*;
    var spins: usize = 0;
    while (parallel_generation.load(.acquire) == observed_generation) {
        std.atomic.spinLoopHint();
        spins +%= 1;
        if (spins % 1024 == 0 and monotonicNs() >= deadline) break;
    }
    const current_generation = parallel_generation.load(.acquire);
    if (current_generation != observed_generation) {
        const learned = monotonicNs() -| wait_start +| parallel_spin_margin_ns;
        spin_budget_ns.* = @min(@max(spin_budget_ns.*, learned), parallel_max_spin_ns);
        return current_generation;
    }

    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    while (parallel_generation.load(.acquire) == observed_generation) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    const next_generation = parallel_generation.load(.acquire);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    const learned = monotonicNs() -| wait_start +| parallel_spin_margin_ns;
    spin_budget_ns.* = @min(@max(spin_budget_ns.*, learned), parallel_max_spin_ns);
    return next_generation;
}

fn runParallelBand(context: *ParallelDraw, band_index: usize) void {
    const band = &context.bands[band_index];
    const stripe_count: usize = if (context.width >= 7680) parallel_8k_slice_count else parallel_slice_count;
    band.pixels_written = drawInternal(context.target, context.depth, context.width, context.height, context.uniform, context.texture, context.texture_width, context.texture_height, context.vertex_count, context.base_vertex, context.viewport, context.scissor, &band.counters, true, context.cull_mode, context.front_face, band_index, parallel_band_count, stripe_count, &context.prepared, context.indexed, false);
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

fn fillPatternRectAll(bytes: []u8, width: u32, rect: Rect, pattern: u32) void {
    if (rect.width == 0 or rect.height == 0) return;
    const words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(bytes)));
    const x: usize = @intCast(rect.x);
    const first_y: usize = @intCast(rect.y);
    for (first_y..first_y + rect.height) |y| {
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
        .tile_clear => |context| {
            const columns = (@as(usize, context.width) + dirty_tile_size - 1) / dirty_tile_size;
            const rows = (@as(usize, context.height) + dirty_tile_size - 1) / dirty_tile_size;
            const tile_count = columns * rows;
            var tile_index = lane_index;
            while (tile_index < tile_count) : (tile_index += parallel_band_count) {
                if (context.tiles[tile_index / 8] & (@as(u8, 1) << @intCast(tile_index % 8)) == 0) continue;
                const tile_x = tile_index % columns;
                const tile_y = tile_index / columns;
                const x = tile_x * dirty_tile_size;
                const y = tile_y * dirty_tile_size;
                const rect = Rect{ .x = @intCast(x), .y = @intCast(y), .width = @intCast(@min(dirty_tile_size, @as(usize, context.width) - x)), .height = @intCast(@min(dirty_tile_size, @as(usize, context.height) - y)) };
                fillPatternRectAll(context.color, context.width, rect, context.color_pattern);
                fillPatternRectAll(context.depth, context.width, rect, context.depth_pattern);
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
    var spin_budget_ns = parallel_initial_spin_ns;
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    while (true) {
        observed_generation = waitForParallelGeneration(observed_generation, &spin_budget_ns);
        if (parallel_stop.load(.acquire)) return;
        const job = parallel_active.?;
        runParallelJob(job, worker_index + 1);
        _ = parallel_completed.fetchAdd(1, .release);
    }
}

fn ensureParallelWorkers() bool {
    if (parallel_started) return parallel_available;
    parallel_started = true;
    parallel_stop.store(false, .release);
    for (0..(parallel_band_count - 1)) |worker_index| {
        const worker = std.Thread.spawn(.{}, parallelWorker, .{worker_index}) catch {
            parallel_started = false;
            return false;
        };
        parallel_threads[worker_index] = worker;
    }
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    while (parallel_ready != parallel_band_count - 1) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    parallel_available = true;
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    return true;
}

pub fn shutdownParallelWorkers() void {
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    if (!parallel_started or !parallel_available) {
        _ = std.c.pthread_mutex_unlock(&parallel_mutex);
        return;
    }
    // A device can be torn down while queue execution is rendering on the
    // shared workers.  Wait for dispatchParallel to clear its active job
    // before requesting worker exit; stopping here would leave the render
    // thread spinning forever on parallel_completed.
    while (parallel_active != null) _ = std.c.pthread_cond_wait(&parallel_condition, &parallel_mutex);
    parallel_stop.store(true, .release);
    _ = parallel_generation.fetchAdd(1, .release);
    _ = std.c.pthread_cond_broadcast(&parallel_condition);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    for (&parallel_threads) |*worker| worker.join();
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    parallel_started = false;
    parallel_available = false;
    parallel_ready = 0;
    parallel_active = null;
    parallel_completed.store(0, .release);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
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

fn drawParallel(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: ?*Rect, dirty_output: ?[]u8, indexed: ?IndexStream) ?usize {
    const dirty_bytes = dirtyTileByteCount(width, height);
    if (dirty_bytes > max_dirty_tile_bytes) return null;
    if (dirty_output) |output| if (output.len < dirty_bytes) return null;
    var context = ParallelDraw{ .target = target, .depth = depth, .width = width, .height = height, .uniform = uniform, .texture = texture, .texture_width = texture_width, .texture_height = texture_height, .vertex_count = vertex_count, .base_vertex = base_vertex, .viewport = viewport, .scissor = scissor, .cull_mode = cull_mode, .front_face = front_face, .indexed = indexed, .prepared = prepareDraw(uniform, vertex_count, base_vertex, viewport, indexed) };
    if (bounds) |output| output.* = preparedBounds(&context.prepared, width, height, scissor);
    if (dirty_output) |output| markPreparedDirtyTiles(&context.prepared, width, height, scissor, cull_mode, front_face, output);
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

pub fn clearDirtyTilesParallel(color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32, height: u32, tiles: []const u8) bool {
    if (tiles.len < dirtyTileByteCount(width, height)) return false;
    var context = ParallelTileClear{ .color = color, .color_pattern = color_pattern, .depth = depth, .depth_pattern = depth_pattern, .width = width, .height = height, .tiles = tiles };
    return dispatchParallel(.{ .tile_clear = &context });
}

pub fn drawTracked(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect) usize {
    return drawTrackedTiles(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, cull_mode, front_face, bounds, null);
}

pub fn drawTrackedTiles(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, dirty_output: ?[]u8) usize {
    return drawTrackedTilesBase(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, cull_mode, front_face, bounds, dirty_output);
}

pub fn drawTrackedTilesBase(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, dirty_output: ?[]u8) usize {
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, base_vertex, viewport, scissor, cull_mode, front_face, bounds, dirty_output, null)) |pixels_written| return pixels_written;
    const prepared = prepareDraw(uniform, vertex_count, base_vertex, viewport, null);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    if (dirty_output) |output| markPreparedDirtyTiles(&prepared, width, height, scissor, cull_mode, front_face, output);
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, base_vertex, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, null, false);
}

pub fn drawIndexedTrackedTiles(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, index_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, dirty_output: ?[]u8, indexed: IndexStream) usize {
    const primitive_index_count = index_count - index_count % 3;
    if (primitive_index_count == 0) {
        bounds.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return 0;
    }
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, cull_mode, front_face, bounds, dirty_output, indexed)) |pixels_written| return pixels_written;
    const prepared = prepareDraw(uniform, primitive_index_count, 0, viewport, indexed);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    if (dirty_output) |output| markPreparedDirtyTiles(&prepared, width, height, scissor, cull_mode, front_face, output);
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, indexed, false);
}

/// Rasterize triangles into depth without requiring a color attachment.
/// This intentionally stays on the bounded scalar path: depth-only draws are
/// uncommon and avoiding a parallel target alias keeps the optional color
/// target semantics explicit and allocation-free.
pub fn drawDepthOnlyTracked(depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect) usize {
    const prepared = prepareDraw(uniform, vertex_count, base_vertex, viewport, null);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    return drawInternal(null, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, base_vertex, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, null, false);
}

/// Indexed depth-only counterpart to drawIndexedTrackedTiles.
pub fn drawIndexedDepthOnlyTracked(depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, index_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, indexed: IndexStream) usize {
    const primitive_index_count = index_count - index_count % 3;
    if (primitive_index_count == 0) {
        bounds.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return 0;
    }
    const prepared = prepareDraw(uniform, primitive_index_count, 0, viewport, indexed);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    return drawInternal(null, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, indexed, false);
}

pub fn draw(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32) usize {
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, cull_mode, front_face, null, null, null)) |pixels_written| return pixels_written;
    var counters = Counters{};
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, null, null, false);
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

    var depth_only = [_]u8{0} ** (8 * 8 * 4);
    offset = 0;
    while (offset < depth_only.len) : (offset += 4) writeFloat(&depth_only, offset, 1);
    var depth_only_bounds = Rect{ .x = 0, .y = 0, .width = 0, .height = 0 };
    try std.testing.expect(drawDepthOnlyTracked(&depth_only, 8, 8, &uniform, &texture, 1, 1, 3, 0, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0, 0, &depth_only_bounds) > 0);
    try std.testing.expect(readFloat(&depth_only, (4 * 8 + 4) * 4) < 1);
    try std.testing.expect(depth_only_bounds.width > 0 and depth_only_bounds.height > 0);

    var culled_target = [_]u8{0} ** (8 * 8 * 4);
    var culled_depth = [_]u8{0} ** (8 * 8 * 4);
    offset = 0;
    while (offset < culled_depth.len) : (offset += 4) writeFloat(&culled_depth, offset, 1);
    try std.testing.expectEqual(@as(usize, 0), draw(&culled_target, &culled_depth, 8, 8, &uniform, &texture, 1, 1, 3, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, 1, 0));
}

test "color-only rasterization skips depth storage" {
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    for (positions, 0..) |position, i| for (position, 0..) |value, component| writeFloat(&uniform, 64 + i * 16 + component * 4, value);
    const texture = [_]u8{ 255, 255, 255, 255 };
    var target = [_]u8{0} ** (8 * 8 * 4);
    const written = draw(&target, null, 8, 8, &uniform, &texture, 1, 1, 3, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }, 0, 0);
    try std.testing.expect(written > 0);
    try std.testing.expect(target[(4 * 8 + 4) * 4] != 0);
}

test "indexed rasterization matches direct geometry for uint16 uint32 and signed vertex offsets" {
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 1 } };
    for (positions, 0..) |position, i| {
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + i * 16 + component * 4, value);
        for (uvs[i], 0..) |value, component| writeFloat(&uniform, 64 + 3 * 16 + i * 16 + component * 4, value);
    }
    const texture = [_]u8{ 255, 255, 255, 255 };
    const viewport = Viewport{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 };
    const scissor = Rect{ .x = 0, .y = 0, .width = 8, .height = 8 };
    var direct = [_]u8{0} ** (8 * 8 * 4);
    var direct_depth: [8 * 8 * 4]u8 = undefined;
    var offset: usize = 0;
    while (offset < direct_depth.len) : (offset += 4) writeFloat(&direct_depth, offset, 1);
    var direct_bounds: Rect = undefined;
    const direct_written = drawTrackedTiles(&direct, &direct_depth, 8, 8, &uniform, &texture, 1, 1, 3, viewport, scissor, 0, 0, &direct_bounds, null);

    const indices16 = std.mem.asBytes(&[_]u16{ 1, 2, 3 });
    const stream16 = IndexStream.init(indices16, 0, -1).?;
    var indexed16 = [_]u8{0} ** (8 * 8 * 4);
    var indexed16_depth: [8 * 8 * 4]u8 = undefined;
    offset = 0;
    while (offset < indexed16_depth.len) : (offset += 4) writeFloat(&indexed16_depth, offset, 1);
    var indexed16_bounds: Rect = undefined;
    try std.testing.expectEqual(direct_written, drawIndexedTrackedTiles(&indexed16, &indexed16_depth, 8, 8, &uniform, &texture, 1, 1, 3, viewport, scissor, 0, 0, &indexed16_bounds, null, stream16));
    try std.testing.expectEqualSlices(u8, &direct, &indexed16);
    try std.testing.expectEqualSlices(u8, &direct_depth, &indexed16_depth);
    try std.testing.expectEqual(direct_bounds, indexed16_bounds);
    var indexed16_depth_only: [8 * 8 * 4]u8 = undefined;
    offset = 0;
    while (offset < indexed16_depth_only.len) : (offset += 4) writeFloat(&indexed16_depth_only, offset, 1);
    var indexed16_depth_only_bounds: Rect = undefined;
    try std.testing.expectEqual(direct_written, drawIndexedDepthOnlyTracked(&indexed16_depth_only, 8, 8, &uniform, &texture, 1, 1, 3, viewport, scissor, 0, 0, &indexed16_depth_only_bounds, stream16));
    try std.testing.expectEqualSlices(u8, &direct_depth, &indexed16_depth_only);
    try std.testing.expectEqual(direct_bounds, indexed16_depth_only_bounds);

    const indices32 = std.mem.asBytes(&[_]u32{ 0, 1, 2 });
    const stream32 = IndexStream.init(indices32, 1, 0).?;
    var indexed32 = [_]u8{0} ** (8 * 8 * 4);
    var indexed32_depth: [8 * 8 * 4]u8 = undefined;
    offset = 0;
    while (offset < indexed32_depth.len) : (offset += 4) writeFloat(&indexed32_depth, offset, 1);
    var indexed32_bounds: Rect = undefined;
    try std.testing.expectEqual(direct_written, drawIndexedTrackedTiles(&indexed32, &indexed32_depth, 8, 8, &uniform, &texture, 1, 1, 4, viewport, scissor, 0, 0, &indexed32_bounds, null, stream32));
    try std.testing.expectEqualSlices(u8, &direct, &indexed32);

    var expanded_uniform = [_]u8{0} ** (64 + 4 * 32);
    @memcpy(expanded_uniform[0..64], uniform[0..64]);
    for (positions, 0..) |position, i| {
        for (position, 0..) |value, component| writeFloat(&expanded_uniform, 64 + i * 16 + component * 4, value);
        for (uvs[i], 0..) |value, component| writeFloat(&expanded_uniform, 64 + 4 * 16 + i * 16 + component * 4, value);
    }
    var subset = [_]u8{0} ** (8 * 8 * 4);
    var subset_depth: [8 * 8 * 4]u8 = undefined;
    offset = 0;
    while (offset < subset_depth.len) : (offset += 4) writeFloat(&subset_depth, offset, 1);
    var subset_bounds: Rect = undefined;
    try std.testing.expectEqual(direct_written, drawIndexedTrackedTiles(&subset, &subset_depth, 8, 8, &expanded_uniform, &texture, 1, 1, 3, viewport, scissor, 0, 0, &subset_bounds, null, stream32));
    try std.testing.expectEqualSlices(u8, &direct, &subset);
    try std.testing.expectEqualSlices(u8, &direct_depth, &subset_depth);
    try std.testing.expectEqual(direct_bounds, subset_bounds);

    var base_uniform = [_]u8{0} ** (64 + 4 * 32);
    @memcpy(base_uniform[0..64], uniform[0..64]);
    for (0..3) |i| {
        @memcpy(base_uniform[64 + (i + 1) * 16 ..][0..16], uniform[64 + i * 16 ..][0..16]);
        @memcpy(base_uniform[64 + 4 * 16 + (i + 1) * 16 ..][0..16], uniform[64 + 3 * 16 + i * 16 ..][0..16]);
    }
    var base_target = [_]u8{0} ** (8 * 8 * 4);
    var base_depth: [8 * 8 * 4]u8 = undefined;
    offset = 0;
    while (offset < base_depth.len) : (offset += 4) writeFloat(&base_depth, offset, 1);
    var base_bounds: Rect = undefined;
    try std.testing.expectEqual(direct_written, drawTrackedTilesBase(&base_target, &base_depth, 8, 8, &base_uniform, &texture, 1, 1, 3, 1, viewport, scissor, 0, 0, &base_bounds, null));
    try std.testing.expectEqualSlices(u8, &direct, &base_target);
    try std.testing.expectEqualSlices(u8, &direct_depth, &base_depth);
    try std.testing.expectEqual(direct_bounds, base_bounds);

    var empty_bounds = Rect{ .x = 99, .y = 99, .width = 99, .height = 99 };
    try std.testing.expectEqual(@as(usize, 0), drawIndexedTrackedTiles(&subset, &subset_depth, 8, 8, &expanded_uniform, &texture, 1, 1, 2, viewport, scissor, 0, 0, &empty_bounds, null, stream32));
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .width = 0, .height = 0 }, empty_bounds);
    try std.testing.expect(IndexStream.init(indices16[0..5], 0, 0) == null);
    try std.testing.expect(IndexStream.init(indices16, 2, 0) == null);
    try std.testing.expect(IndexStream.init(&.{}, 0, 0) == null);
}

test "tiled renderer matches untiled scalar reference for odd tails" {
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
    offset = 0;
    while (offset < fast_depth.len) : (offset += 4) {
        try std.testing.expectApproxEqAbs(readFloat(&reference_depth, offset), readFloat(&fast_depth, offset), 0.000001);
    }
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
    const serial_written = drawInternal(&serial, &serial_depth, w, h, &uniform, &texture, 2, 2, 3, 0, viewport, scissor, &serial_counters, true, 0, 0, 0, 1, 1, null, null, false);
    var parallel_written: usize = 0;
    for (0..parallel_band_count) |lane| {
        var counters = Counters{};
        parallel_written += drawInternal(&parallel, &parallel_depth, w, h, &uniform, &texture, 2, 2, 3, 0, viewport, scissor, &counters, true, 0, 0, lane, parallel_band_count, parallel_slice_count, null, null, false);
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

test "dirty tile cache conservatively covers every raster write" {
    const w = 64;
    const h = 64;
    const color_pattern: u32 = 0x44332211;
    const depth_pattern: u32 = @bitCast(@as(f32, 1));
    var color: [w * h * 4]u8 align(4) = undefined;
    var depth: [w * h * 4]u8 align(4) = undefined;
    @memset(std.mem.bytesAsSlice(u32, &color), color_pattern);
    @memset(std.mem.bytesAsSlice(u32, &depth), depth_pattern);
    var uniform = [_]u8{0} ** (64 + 3 * 32);
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    const uvs = [_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0.5, 1 } };
    for (positions, 0..) |position, index| {
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + index * 16 + component * 4, value);
        writeFloat(&uniform, 64 + 3 * 16 + index * 16, uvs[index][0]);
        writeFloat(&uniform, 64 + 3 * 16 + index * 16 + 4, uvs[index][1]);
    }
    const texture = [_]u8{255} ** 16;
    var tiles = [_]u8{0} ** max_dirty_tile_bytes;
    var bounds: Rect = undefined;
    _ = drawTrackedTiles(&color, &depth, w, h, &uniform, &texture, 2, 2, 3, .{ .x = 0, .y = 0, .width = w, .height = h, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = w, .height = h }, 0, 0, &bounds, tiles[0..dirtyTileByteCount(w, h)]);
    var any_dirty = false;
    for (tiles[0..dirtyTileByteCount(w, h)]) |value| any_dirty = any_dirty or value != 0;
    try std.testing.expect(any_dirty);
    try std.testing.expect(clearDirtyTilesParallel(&color, color_pattern, &depth, depth_pattern, w, h, tiles[0..dirtyTileByteCount(w, h)]));
    defer shutdownParallelWorkers();
    for (std.mem.bytesAsSlice(u32, &color)) |pixel| try std.testing.expectEqual(color_pattern, pixel);
    for (std.mem.bytesAsSlice(u32, &depth)) |pixel| try std.testing.expectEqual(depth_pattern, pixel);
}

test "parallel worker shuts down and restarts without detached execution" {
    var color: [64]u8 align(4) = [_]u8{0} ** 64;
    var depth: [64]u8 align(4) = [_]u8{0} ** 64;
    try std.testing.expect(clearImagesParallel(&color, 0x11223344, &depth, 0x55667788));
    shutdownParallelWorkers();
    try std.testing.expectEqual(@as(u32, 0x11223344), std.mem.readInt(u32, color[0..4], .little));
    try std.testing.expect(clearImagesParallel(&color, 0xaabbccdd, &depth, 0x01020304));
    shutdownParallelWorkers();
    try std.testing.expectEqual(@as(u32, 0xaabbccdd), std.mem.readInt(u32, color[0..4], .little));
}

const ParallelShutdownProbe = struct {
    started: *std.atomic.Value(bool),
    done: *std.atomic.Value(bool),
};

fn parallelShutdownProbe(context: *ParallelShutdownProbe) void {
    context.started.store(true, .release);
    shutdownParallelWorkers();
    context.done.store(true, .release);
}

test "parallel shutdown waits for an active render job" {
    var color: [64]u8 align(4) = [_]u8{0} ** 64;
    var depth: [64]u8 align(4) = [_]u8{0} ** 64;
    try std.testing.expect(clearImagesParallel(&color, 0x11223344, &depth, 0x55667788));

    var held_job = ParallelClear{ .color = &color, .color_pattern = 0, .depth = &depth, .depth_pattern = 0 };
    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    parallel_active = .{ .clear = &held_job };
    var started = std.atomic.Value(bool).init(false);
    var done = std.atomic.Value(bool).init(false);
    var context = ParallelShutdownProbe{ .started = &started, .done = &done };
    const shutdown_thread = try std.Thread.spawn(.{}, parallelShutdownProbe, .{&context});
    while (!started.load(.acquire)) std.atomic.spinLoopHint();
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    std.Thread.yield() catch {};
    try std.testing.expect(!done.load(.acquire));

    _ = std.c.pthread_mutex_lock(&parallel_mutex);
    parallel_active = null;
    _ = std.c.pthread_cond_broadcast(&parallel_condition);
    _ = std.c.pthread_mutex_unlock(&parallel_mutex);
    shutdown_thread.join();
    try std.testing.expect(done.load(.acquire));
}

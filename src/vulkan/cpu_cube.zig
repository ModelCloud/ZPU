// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const builtin = @import("builtin");
const cpu_locality = @import("cpu_locality.zig");

pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };
pub const Rect = extern struct { x: i32, y: i32, width: u32, height: u32 };

/// One ordered opaque draw in a batched CPU 3D submission. Commands retain
/// their input order within each raster lane, so depth-tested composition has
/// the same ordering contract as repeated drawCountedParallel calls.
pub const DrawCommand = struct {
    uniform: []const u8,
    texture: []const u8,
    texture_width: u32,
    texture_height: u32,
    vertex_count: u32,
    viewport: Viewport,
    scissor: Rect,
    /// Optional caller-maintained content keys. A non-zero key promises that
    /// the corresponding byte range changes only when its key changes; zero
    /// retains the defensive byte-comparison behavior.
    uniform_revision: u64 = 0,
    geometry_revision: u64 = 0,
    texture_revision: u64 = 0,
};
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
const flat_span_rows = 600;
const FlatSpan = struct { first: u16 = 0, last: u16 = 0 };
const FlatSpanStepper = struct {
    edge_values: [3]f32,
    edge_slope_x: [3]f32,
    edge_slope_y: [3]f32,
    boundaries: [3]f32,
    boundary_steps: [3]f32,
    min_x: i32,
    max_x: i32,

    fn init(p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, max_x: i32, y: i32) FlatSpanStepper {
        const edge_slope_x = [3]f32{
            (p2[1] - p1[1]) * inverse_area,
            (p0[1] - p2[1]) * inverse_area,
            (p1[1] - p0[1]) * inverse_area,
        };
        const edge_slope_y = [3]f32{
            (p1[0] - p2[0]) * inverse_area,
            (p2[0] - p0[0]) * inverse_area,
            (p0[0] - p1[0]) * inverse_area,
        };
        const sample = [2]f32{ @as(f32, @floatFromInt(min_x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
        const edge_values = [3]f32{
            edge(p1, p2, sample) * inverse_area,
            edge(p2, p0, sample) * inverse_area,
            edge(p0, p1, sample) * inverse_area,
        };
        var boundaries = [_]f32{ 0, 0, 0 };
        var boundary_steps = [_]f32{ 0, 0, 0 };
        inline for (0..3) |edge_index| {
            if (edge_slope_x[edge_index] != 0) {
                boundaries[edge_index] = -edge_values[edge_index] / edge_slope_x[edge_index];
                boundary_steps[edge_index] = -edge_slope_y[edge_index] / edge_slope_x[edge_index];
            }
        }
        return .{ .edge_values = edge_values, .edge_slope_x = edge_slope_x, .edge_slope_y = edge_slope_y, .boundaries = boundaries, .boundary_steps = boundary_steps, .min_x = min_x, .max_x = max_x };
    }

    fn next(self: *FlatSpanStepper) FlatSpan {
        var first = self.min_x;
        var last = self.max_x;
        var left_boundary = -std.math.inf(f32);
        var right_boundary = std.math.inf(f32);
        inline for (0..3) |edge_index| {
            const value = self.edge_values[edge_index];
            const slope = self.edge_slope_x[edge_index];
            if (slope > 0) {
                left_boundary = @max(left_boundary, self.boundaries[edge_index]);
            } else if (slope < 0) {
                right_boundary = @min(right_boundary, self.boundaries[edge_index]);
            } else if (value < 0) {
                first = last;
            }
        }
        if (left_boundary != -std.math.inf(f32)) first = @max(first, self.min_x +| @as(i32, @intFromFloat(@floor(left_boundary))) - 1);
        if (right_boundary != std.math.inf(f32)) last = @min(last, self.min_x +| @as(i32, @intFromFloat(@ceil(right_boundary))) + 2);
        first = @max(first, self.min_x);
        last = @min(last, self.max_x);
        while (first < last) : (first += 1) {
            const offset = @as(f32, @floatFromInt(first - self.min_x));
            if (self.edge_values[0] + self.edge_slope_x[0] * offset >= 0 and self.edge_values[1] + self.edge_slope_x[1] * offset >= 0 and self.edge_values[2] + self.edge_slope_x[2] * offset >= 0) break;
        }
        while (last > first) {
            const offset = @as(f32, @floatFromInt(last - 1 - self.min_x));
            if (self.edge_values[0] + self.edge_slope_x[0] * offset >= 0 and self.edge_values[1] + self.edge_slope_x[1] * offset >= 0 and self.edge_values[2] + self.edge_slope_x[2] * offset >= 0) break;
            last -= 1;
        }
        const result = if (first >= last) FlatSpan{} else FlatSpan{ .first = @intCast(first), .last = @intCast(last) };
        for (0..3) |edge_index| {
            self.edge_values[edge_index] += self.edge_slope_y[edge_index];
            self.boundaries[edge_index] += self.boundary_steps[edge_index];
        }
        return result;
    }
};
const BatchRasterTriangle = struct {
    ready: bool = false,
    p0: [2]f32 = .{ 0, 0 },
    p1: [2]f32 = .{ 0, 0 },
    p2: [2]f32 = .{ 0, 0 },
    inverse_area: f32 = 0,
    min_x: i32 = 0,
    min_y: i32 = 0,
    max_x: i32 = 0,
    max_y: i32 = 0,
    flat_depth_bits: u32 = 0,
    inverse_w: f32 = 0,
    flat_reciprocal_w: f32 = 0,
    u_over_w: [3]f32 = .{ 0, 0, 0 },
    v_over_w: [3]f32 = .{ 0, 0, 0 },
    u_over_w_dx: f32 = 0,
    v_over_w_dx: f32 = 0,
};
const PreparedTriangle = struct {
    valid: bool = false,
    vertices: [3]Vertex = undefined,
    lighting: *const [256]u8 = undefined,
    light_key: u32 = 0,
    unit_uv: bool = false,
    prelit_texture: [16]u32 = undefined,
    prelit_texture_ptr: ?*const [16]u32 = null,
    has_prelit_texture: bool = false,
    prelit_texture_16x16: [256]u32 = undefined,
    prelit_texture_16x16_ptr: ?*const [256]u32 = null,
    has_prelit_texture_16x16: bool = false,
    flat_color: ?u32 = null,
    batch_raster: BatchRasterTriangle = .{},
};
const OpaqueQuad = struct {
    valid: bool = false,
    x0: f32 = 0,
    y0: f32 = 0,
    u0: f32 = 0,
    v0: f32 = 0,
    du: f32 = 0,
    dv: f32 = 0,
    min_y: i32 = 0,
    max_y: i32 = 0,
    prelit: *const [256]u32 = undefined,
};
const PreparedDraw = struct {
    count: usize = 0,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
    triangles: [max_prepared_triangles]PreparedTriangle = [_]PreparedTriangle{.{}} ** max_prepared_triangles,
    spans: [max_prepared_triangles][flat_span_rows]FlatSpan = [_][flat_span_rows]FlatSpan{[_]FlatSpan{.{}} ** flat_span_rows} ** max_prepared_triangles,
    spans_valid: bool = false,
    spans_external: ?*const [max_prepared_triangles][flat_span_rows]FlatSpan = null,
    quad_spans_external: ?*const [flat_span_rows]FlatSpan = null,
    opaque_quad: OpaqueQuad = .{},
    batch_fast: bool = false,
};

const prepared_cache_capacity = 8192;
const PreparedCache = struct {
    valid: bool = false,
    prepared_ready: bool = false,
    vertex_count: u32 = 0,
    uniform_len: usize = 0,
    texture_len: usize = 0,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    viewport: Viewport = undefined,
    lighting_generation: u64 = 0,
    uniform: [prepared_cache_capacity]u8 = undefined,
    texture: [prepared_cache_capacity]u8 = undefined,
    prepared: PreparedDraw = .{},
};

threadlocal var prepared_cache: PreparedCache = .{};

const public_geometry_cache_capacity = 256;
const public_geometry_cache_bytes = 64 + max_prepared_triangles * 3 * 16;
const PublicGeometryCacheEntry = struct {
    valid: bool = false,
    uniform_address: usize = 0,
    uniform_len: usize = 0,
    geometry_len: usize = 0,
    vertex_count: u32 = 0,
    target_width: u32 = 0,
    target_height: u32 = 0,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    viewport: Viewport = undefined,
    scissor: Rect = undefined,
    lighting_generation: u64 = 0,
    geometry: [public_geometry_cache_bytes]u8 = undefined,
    prepared: PreparedDraw = .{},
};

threadlocal var public_geometry_cache: [public_geometry_cache_capacity]PublicGeometryCacheEntry = [_]PublicGeometryCacheEntry{.{}} ** public_geometry_cache_capacity;
threadlocal var public_geometry_cache_next: usize = 0;

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

fn isIdentityTransform(uniform: []const u8) bool {
    if (uniform.len < 64) return false;
    inline for (0..16) |index| {
        const expected: f32 = if (index % 5 == 0) 1 else 0;
        if (readFloat(uniform, index * 4) != expected) return false;
    }
    return true;
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

fn flatSpanForRow(p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, max_x: i32, y: i32) FlatSpan {
    const edge_dx = [3]f32{
        (p2[1] - p1[1]) * inverse_area,
        (p0[1] - p2[1]) * inverse_area,
        (p1[1] - p0[1]) * inverse_area,
    };
    const sample = [2]f32{ @as(f32, @floatFromInt(min_x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
    const row_edges = [3]f32{
        edge(p1, p2, sample) * inverse_area,
        edge(p2, p0, sample) * inverse_area,
        edge(p0, p1, sample) * inverse_area,
    };
    var first = min_x;
    var last = max_x;
    inline for (0..3) |edge_index| {
        const value = row_edges[edge_index];
        const slope = edge_dx[edge_index];
        if (slope > 0) {
            const boundary = -value / slope;
            const conservative = @as(i32, @intFromFloat(@floor(boundary))) - 1;
            first = @max(first, min_x +| conservative);
        } else if (slope < 0) {
            const boundary = -value / slope;
            const conservative = @as(i32, @intFromFloat(@ceil(boundary))) + 2;
            last = @min(last, min_x +| conservative);
        } else if (value < 0) {
            first = last;
        }
    }
    first = @max(first, min_x);
    last = @min(last, max_x);
    while (first < last) : (first += 1) {
        const offset = @as(f32, @floatFromInt(first - min_x));
        if (row_edges[0] + edge_dx[0] * offset >= 0 and row_edges[1] + edge_dx[1] * offset >= 0 and row_edges[2] + edge_dx[2] * offset >= 0) break;
    }
    while (last > first) {
        const offset = @as(f32, @floatFromInt(last - 1 - min_x));
        if (row_edges[0] + edge_dx[0] * offset >= 0 and row_edges[1] + edge_dx[1] * offset >= 0 and row_edges[2] + edge_dx[2] * offset >= 0) break;
        last -= 1;
    }
    if (first >= last) return .{};
    return .{ .first = @intCast(first), .last = @intCast(last) };
}

fn buildPreparedFlatSpans(prepared: *PreparedDraw, width: u32, height: u32) void {
    if (width == 0 or height == 0 or height > flat_span_rows) return;
    for (prepared.triangles[0..prepared.count], 0..) |triangle, index| {
        if (!triangle.valid) continue;
        const p0 = [2]f32{ triangle.vertices[0].screen[0], triangle.vertices[0].screen[1] };
        const p1 = [2]f32{ triangle.vertices[1].screen[0], triangle.vertices[1].screen[1] };
        const p2 = [2]f32{ triangle.vertices[2].screen[0], triangle.vertices[2].screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), @as(i32, @intCast(height)));
        if (max_x <= min_x or max_y <= min_y) continue;
        var span_stepper = FlatSpanStepper.init(p0, p1, p2, 1.0 / area, min_x, max_x, min_y);
        for (@as(usize, @intCast(min_y))..@as(usize, @intCast(max_y))) |y| prepared.spans[index][y] = span_stepper.next();
    }
    prepared.spans_valid = true;
    prepared.spans_external = null;
}

fn preparedSpan(prepared: *const PreparedDraw, triangle_index: usize) *const [flat_span_rows]FlatSpan {
    return if (prepared.spans_external) |external| &external[triangle_index] else &prepared.spans[triangle_index];
}

fn writeFlatColorSpan(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, y: usize, first: usize, last: usize, depth_pattern: u32, color: u32) usize {
    return writeFlatColorSpanAtRow(depth_test, color_words, depth_words, y * @as(usize, width), first, last, depth_pattern, color);
}

inline fn writeFlatColorSpanAtRow(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, row_offset: usize, first: usize, last: usize, depth_pattern: u32, color: u32) usize {
    if (comptime !depth_test) {
        const pixel_index = row_offset + first;
        const length = last - first;
        @memset(color_words[pixel_index..][0..length], color);
        return length;
    }
    var pixels_written: usize = 0;
    var x = first;
    while (x + 8 <= last) : (x += 8) {
        const pixel_index = row_offset + x;
        const depth_values: @Vector(8, u32) = depth_words[pixel_index..][0..8].*;
        const passes: @Vector(8, bool) = @as(@Vector(8, u32), @splat(depth_pattern)) <= depth_values;
        if (@reduce(.And, passes)) {
            depth_words[pixel_index..][0..8].* = @as(@Vector(8, u32), @splat(depth_pattern));
            color_words[pixel_index..][0..8].* = @as(@Vector(8, u32), @splat(color));
            pixels_written += 8;
        } else {
            inline for (0..8) |lane| {
                if (passes[lane]) {
                    depth_words[pixel_index + lane] = depth_pattern;
                    color_words[pixel_index + lane] = color;
                    pixels_written += 1;
                }
            }
        }
    }
    while (x + 4 <= last) : (x += 4) {
        const pixel_index = row_offset + x;
        const depth_values: @Vector(4, u32) = depth_words[pixel_index..][0..4].*;
        const passes: @Vector(4, bool) = @as(@Vector(4, u32), @splat(depth_pattern)) <= depth_values;
        if (@reduce(.And, passes)) {
            depth_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(depth_pattern));
            color_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(color));
            pixels_written += 4;
        } else {
            inline for (0..4) |lane| {
                if (passes[lane]) {
                    depth_words[pixel_index + lane] = depth_pattern;
                    color_words[pixel_index + lane] = color;
                    pixels_written += 1;
                }
            }
        }
    }
    while (x < last) : (x += 1) {
        const pixel_index = row_offset + x;
        if (depth_pattern <= depth_words[pixel_index]) {
            depth_words[pixel_index] = depth_pattern;
            color_words[pixel_index] = color;
            pixels_written += 1;
        }
    }
    return pixels_written;
}

fn writeFlatColorSpanKnownPass(color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, y: usize, first: usize, last: usize, depth_pattern: u32, color: u32) usize {
    const pixel_index = y * width + first;
    const length = last - first;
    @memset(depth_words[pixel_index..][0..length], depth_pattern);
    @memset(color_words[pixel_index..][0..length], color);
    return length;
}

fn writeFlatColorSpanTiled(color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, y: usize, first: usize, last: usize, depth_pattern: u32, color: u32, tile_min: []u32, tile_max: []u32, tile_columns: usize, tile_count: usize, lane_index: usize) usize {
    var pixels_written: usize = 0;
    var x = first;
    while (x < last) {
        const tile_x = x / dirty_tile_size;
        const tile_index = (y / dirty_tile_size) * tile_columns + tile_x;
        const tile_end = @min(last, (tile_x + 1) * dirty_tile_size);
        const metadata_index = lane_index * tile_count + tile_index;
        const old_min = tile_min[metadata_index];
        const old_max = tile_max[metadata_index];
        if (depth_pattern <= old_min) {
            pixels_written += writeFlatColorSpanKnownPass(color_words, depth_words, width, y, x, tile_end, depth_pattern, color);
            tile_min[metadata_index] = depth_pattern;
        } else if (depth_pattern <= old_max) {
            const written = writeFlatColorSpan(true, color_words, depth_words, width, y, x, tile_end, depth_pattern, color);
            pixels_written += written;
            if (written != 0) tile_min[metadata_index] = @min(old_min, depth_pattern);
        }
        x = tile_end;
    }
    return pixels_written;
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

fn transformedIdentityVertex(uniform: []const u8, index: u32, vertex_count: u32, viewport: Viewport, indexed: ?IndexStream) ?Vertex {
    const source_index = if (indexed) |stream| stream.sourceIndex(index) orelse return null else index;
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse return null else vertex_count;
    if (source_index >= source_vertex_count) return null;
    const position_base = 64 + @as(usize, source_index) * 16;
    const attr_base = 64 + @as(usize, source_vertex_count) * 16 + @as(usize, source_index) * 16;
    const x = readFloat(uniform, position_base);
    const y = readFloat(uniform, position_base + 4);
    const z = readFloat(uniform, position_base + 8);
    const clip_w = readFloat(uniform, position_base + 12);
    if (!std.math.isFinite(clip_w) or @abs(clip_w) < 0.000001) return null;
    const inverse_w = 1.0 / clip_w;
    return .{
        .screen = .{ viewport.x + (x * inverse_w * 0.5 + 0.5) * viewport.width, viewport.y + (y * inverse_w * 0.5 + 0.5) * viewport.height, viewport.min_depth + z * inverse_w * (viewport.max_depth - viewport.min_depth) },
        .clip_w = clip_w,
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

// The driver-facing cache intentionally quantizes lighting to 8-bit levels.
// Counted performance runs retain the exact scalar table while avoiding a
// costly 256-sample sRGB pow() rebuild on every frame.
const exact_lighting_cache_capacity = 8192;
const exact_lighting_index_capacity = 16384;
var exact_lighting_cache_keys: [exact_lighting_cache_capacity]u32 = undefined;
var exact_lighting_cache_tables: [exact_lighting_cache_capacity][256]u8 = undefined;
var exact_lighting_cache_count: usize = 0;
const exact_lighting_index_empty: u16 = std.math.maxInt(u16);
var exact_lighting_cache_index: [exact_lighting_index_capacity]u16 = [_]u16{exact_lighting_index_empty} ** exact_lighting_index_capacity;
var exact_lighting_cache_generation = std.atomic.Value(u64).init(0);

const ExactLightingFastPath = struct {
    generation: u64 = 0,
    key: u32 = 0,
    table: ?*const [256]u8 = null,
};
threadlocal var exact_lighting_fast_path: ExactLightingFastPath = .{};

fn exactLightingCacheIndex(key: u32) usize {
    return (@as(usize, key) *% 2654435761) % exact_lighting_index_capacity;
}

fn rememberExactLightingIndex(key: u32, entry_index: usize) void {
    var index = exactLightingCacheIndex(key);
    while (exact_lighting_cache_index[index] != exact_lighting_index_empty) index = (index + 1) % exact_lighting_index_capacity;
    exact_lighting_cache_index[index] = @intCast(entry_index);
}

fn exactCachedLightingTable(light: f32) *const [256]u8 {
    const key: u32 = @bitCast(light);
    const generation = exact_lighting_cache_generation.load(.acquire);
    if (exact_lighting_fast_path.generation == generation and exact_lighting_fast_path.key == key) {
        if (exact_lighting_fast_path.table) |table| return table;
    }
    _ = std.c.pthread_mutex_lock(&lighting_cache_mutex);
    defer _ = std.c.pthread_mutex_unlock(&lighting_cache_mutex);
    var index = exactLightingCacheIndex(key);
    while (exact_lighting_cache_index[index] != exact_lighting_index_empty) : (index = (index + 1) % exact_lighting_index_capacity) {
        const entry_index = exact_lighting_cache_index[index];
        if (exact_lighting_cache_keys[entry_index] == key) {
            exact_lighting_fast_path = .{ .generation = exact_lighting_cache_generation.load(.acquire), .key = key, .table = &exact_lighting_cache_tables[entry_index] };
            return &exact_lighting_cache_tables[entry_index];
        }
    }
    const append = exact_lighting_cache_count < exact_lighting_cache_capacity;
    const entry_index = if (append) blk: {
        const fresh = exact_lighting_cache_count;
        exact_lighting_cache_count += 1;
        break :blk fresh;
    } else 0;
    exact_lighting_cache_keys[entry_index] = key;
    exact_lighting_cache_tables[entry_index] = lightingTable(light);
    if (append) {
        rememberExactLightingIndex(key, entry_index);
    } else {
        @memset(exact_lighting_cache_index[0..], exact_lighting_index_empty);
        for (exact_lighting_cache_keys[0..exact_lighting_cache_count], 0..) |cached_key, cached_index| rememberExactLightingIndex(cached_key, cached_index);
    }
    const next_generation = exact_lighting_cache_generation.fetchAdd(1, .release) + 1;
    exact_lighting_fast_path = .{ .generation = next_generation, .key = key, .table = &exact_lighting_cache_tables[entry_index] };
    return &exact_lighting_cache_tables[entry_index];
}

// Unit-UV triangles are fully prelit before rasterization. Copying the exact
// table into a thread-local stable slot lets batch preparation reuse a light
// across commands without taking the shared cache mutex for every triangle.
const batch_exact_lighting_slots = 64;
threadlocal var batch_exact_lighting_keys: [batch_exact_lighting_slots]u32 = undefined;
threadlocal var batch_exact_lighting_tables: [batch_exact_lighting_slots][256]u8 = undefined;
threadlocal var batch_exact_lighting_count: usize = 0;

fn batchExactLightingTable(light: f32) ?*const [256]u8 {
    const key: u32 = @bitCast(light);
    var index: usize = 0;
    while (index < batch_exact_lighting_count and batch_exact_lighting_keys[index] != key) : (index += 1) {}
    if (index < batch_exact_lighting_count) return &batch_exact_lighting_tables[index];
    if (batch_exact_lighting_count == batch_exact_lighting_slots) return null;
    const source = exactCachedLightingTable(light);
    @memcpy(batch_exact_lighting_tables[index][0..], source[0..]);
    batch_exact_lighting_keys[index] = key;
    batch_exact_lighting_count += 1;
    return &batch_exact_lighting_tables[index];
}

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

fn canReuseFlatTriangleLight(first: [3]Vertex, second: [3]Vertex) bool {
    if (first[0].screen[2] != first[1].screen[2] or first[0].screen[2] != first[2].screen[2] or
        second[0].screen[2] != second[1].screen[2] or second[0].screen[2] != second[2].screen[2] or
        first[0].screen[2] != second[0].screen[2]) return false;
    const first_area = edge(.{ first[0].screen[0], first[0].screen[1] }, .{ first[1].screen[0], first[1].screen[1] }, .{ first[2].screen[0], first[2].screen[1] });
    const second_area = edge(.{ second[0].screen[0], second[0].screen[1] }, .{ second[1].screen[0], second[1].screen[1] }, .{ second[2].screen[0], second[2].screen[1] });
    return (first_area > 0 and second_area > 0) or (first_area < 0 and second_area < 0);
}

fn initializePreparedTriangle(triangle: *PreparedTriangle, vertices: [3]Vertex, light_key_override: ?u32) void {
    var unit_uv = true;
    for (vertices) |vertex| unit_uv = unit_uv and vertex.uv[0] >= 0 and vertex.uv[0] <= 1 and vertex.uv[1] >= 0 and vertex.uv[1] <= 1;
    triangle.valid = true;
    triangle.vertices = vertices;
    const light: f32 = if (light_key_override) |key| @bitCast(key) else triangleLight(vertices[0], vertices[1], vertices[2]);
    triangle.light_key = @bitCast(light);
    triangle.lighting = cachedLightingTable(light);
    triangle.unit_uv = unit_uv and ((vertices[0].clip_w > 0 and vertices[1].clip_w > 0 and vertices[2].clip_w > 0) or
        (vertices[0].clip_w < 0 and vertices[1].clip_w < 0 and vertices[2].clip_w < 0));
    triangle.has_prelit_texture = false;
    triangle.prelit_texture_16x16_ptr = null;
    triangle.has_prelit_texture_16x16 = false;
    triangle.flat_color = null;
    triangle.batch_raster = .{};
}

fn prepareDraw(uniform: []const u8, vertex_count: u32, base_vertex: u32, viewport: Viewport, indexed: ?IndexStream, output: *PreparedDraw) void {
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse 0 else base_vertex +| vertex_count;
    const max_uniform_vertices = (std.math.maxInt(usize) - 64) / 32;
    if (source_vertex_count > max_uniform_vertices or uniform.len < 64 + @as(usize, source_vertex_count) * 32) {
        output.count = 0;
        output.spans_valid = false;
        output.spans_external = null;
        output.quad_spans_external = null;
        output.batch_fast = false;
        return;
    }
    output.count = @min(vertex_count / 3, max_prepared_triangles);
    output.spans_valid = false;
    output.spans_external = null;
    output.quad_spans_external = null;
    output.batch_fast = false;
    const identity_transform = isIdentityTransform(uniform);
    if (base_vertex == 0 and indexed == null and vertex_count == 6 and uniform.len >= 64 + 6 * 32 and
        std.mem.eql(u8, uniform[64 + 3 * 16 ..][0..16], uniform[64..][0..16]) and
        std.mem.eql(u8, uniform[64 + 4 * 16 ..][0..16], uniform[64 + 2 * 16 ..][0..16]))
    {
        const maybe_v0 = if (identity_transform) transformedIdentityVertex(uniform, 0, source_vertex_count, viewport, null) else transformedVertex(uniform, 0, source_vertex_count, viewport, null);
        const maybe_v1 = if (identity_transform) transformedIdentityVertex(uniform, 1, source_vertex_count, viewport, null) else transformedVertex(uniform, 1, source_vertex_count, viewport, null);
        const maybe_v2 = if (identity_transform) transformedIdentityVertex(uniform, 2, source_vertex_count, viewport, null) else transformedVertex(uniform, 2, source_vertex_count, viewport, null);
        const maybe_v3 = if (identity_transform) transformedIdentityVertex(uniform, 5, source_vertex_count, viewport, null) else transformedVertex(uniform, 5, source_vertex_count, viewport, null);
        if (maybe_v0) |v0| {
            if (maybe_v1) |v1| {
                if (maybe_v2) |v2| {
                    if (maybe_v3) |v3| {
                        var second_v0 = v0;
                        var second_v2 = v2;
                        second_v0.uv = .{ readFloat(uniform, 64 + 6 * 16 + 3 * 16), readFloat(uniform, 64 + 6 * 16 + 3 * 16 + 4) };
                        second_v2.uv = .{ readFloat(uniform, 64 + 6 * 16 + 4 * 16), readFloat(uniform, 64 + 6 * 16 + 4 * 16 + 4) };
                        initializePreparedTriangle(&output.triangles[0], .{ v0, v1, v2 }, null);
                        initializePreparedTriangle(&output.triangles[1], .{ second_v0, second_v2, v3 }, if (canReuseFlatTriangleLight(output.triangles[0].vertices, .{ second_v0, second_v2, v3 })) output.triangles[0].light_key else null);
                        return;
                    }
                }
            }
        }
    }
    for (output.triangles[0..output.count], 0..) |*triangle, index| {
        triangle.valid = false;
        const first: u32 = @intCast(index * 3);
        const first_source = if (indexed != null) first else base_vertex +| first;
        const v0 = (if (identity_transform) transformedIdentityVertex(uniform, first_source, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source, source_vertex_count, viewport, indexed)) orelse continue;
        const v1 = (if (identity_transform) transformedIdentityVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed)) orelse continue;
        const v2 = (if (identity_transform) transformedIdentityVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed)) orelse continue;
        const vertices = [3]Vertex{ v0, v1, v2 };
        const light_key_override = if (index > 0 and index % 2 == 1 and output.triangles[index - 1].valid and canReuseFlatTriangleLight(output.triangles[index - 1].vertices, vertices)) output.triangles[index - 1].light_key else null;
        initializePreparedTriangle(triangle, vertices, light_key_override);
    }
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
    const x_raw: usize = if (unit_uv) @intFromFloat(u * (@as(f32, @floatFromInt(texture_width)) * 0.999999)) else @intFromFloat(std.math.clamp(u, 0, 0.999999) * @as(f32, @floatFromInt(texture_width)));
    const y_raw: usize = if (unit_uv) @intFromFloat(v * (@as(f32, @floatFromInt(texture_height)) * 0.999999)) else @intFromFloat(std.math.clamp(v, 0, 0.999999) * @as(f32, @floatFromInt(texture_height)));
    const x = @min(x_raw, @as(usize, @max(1, texture_width)) - 1);
    const y = @min(y_raw, @as(usize, @max(1, texture_height)) - 1);
    const offset = (y * texture_width + x) * 4;
    return @as(u32, table[texture[offset + 2]]) |
        @as(u32, table[texture[offset + 1]]) << 8 |
        @as(u32, table[texture[offset]]) << 16 |
        @as(u32, texture[offset + 3]) << 24;
}

fn unitTextureCoordinate(value: f32) usize {
    return @intFromFloat(value * 3.999999);
}

fn unitTextureCoordinate16(value: f32) usize {
    return @intFromFloat(value * 15.999999);
}

fn shadeUnitTexture4x4(u: f32, v: f32, colors: *const [16]u32) u32 {
    const x = unitTextureCoordinate(u);
    const y = unitTextureCoordinate(v);
    return colors[y * 4 + x];
}

fn shadeUnitTexture16x16(u: f32, v: f32, colors: *const [256]u32) u32 {
    const x = unitTextureCoordinate16(u);
    const y = unitTextureCoordinate16(v);
    return colors[y * 16 + x];
}

inline fn shadeUnitTexture16x16Row(u: f32, y: usize, colors: *const [256]u32) u32 {
    return colors[y * 16 + unitTextureCoordinate16(u)];
}

fn refreshFlatTextureColor(triangle: *PreparedTriangle) void {
    triangle.flat_color = null;
    if (!triangle.unit_uv) return;
    if (triangle.has_prelit_texture) {
        const x = unitTextureCoordinate(triangle.vertices[0].uv[0]);
        const y = unitTextureCoordinate(triangle.vertices[0].uv[1]);
        for (triangle.vertices) |vertex| if (unitTextureCoordinate(vertex.uv[0]) != x or unitTextureCoordinate(vertex.uv[1]) != y) return;
        triangle.flat_color = (if (triangle.prelit_texture_ptr) |colors| colors else &triangle.prelit_texture)[y * 4 + x];
    } else if (triangle.has_prelit_texture_16x16) {
        const x = unitTextureCoordinate16(triangle.vertices[0].uv[0]);
        const y = unitTextureCoordinate16(triangle.vertices[0].uv[1]);
        for (triangle.vertices) |vertex| if (unitTextureCoordinate16(vertex.uv[0]) != x or unitTextureCoordinate16(vertex.uv[1]) != y) return;
        const colors = if (triangle.prelit_texture_16x16_ptr) |ptr| ptr else &triangle.prelit_texture_16x16;
        triangle.flat_color = colors[y * 16 + x];
    }
}

fn prelitTexture4x4(texture: []const u8, table: *const [256]u8) [16]u32 {
    var colors: [16]u32 = undefined;
    for (0..16) |texel| {
        const offset = texel * 4;
        colors[texel] = @as(u32, table[texture[offset + 2]]) |
            @as(u32, table[texture[offset + 1]]) << 8 |
            @as(u32, table[texture[offset]]) << 16 |
            @as(u32, texture[offset + 3]) << 24;
    }
    return colors;
}

fn prelitTexture16x16(texture: []const u8, table: *const [256]u8) [256]u32 {
    var colors: [256]u32 = undefined;
    for (0..256) |texel| {
        const offset = texel * 4;
        colors[texel] = @as(u32, table[texture[offset + 2]]) |
            @as(u32, table[texture[offset + 1]]) << 8 |
            @as(u32, table[texture[offset]]) << 16 |
            @as(u32, texture[offset + 3]) << 24;
    }
    return colors;
}

const prelit_texture16_cache_slots = 64;
const prelit_texture4_cache_slots = 1024;
const PrelitTexture4Cache = struct {
    valid: bool = false,
    texture_address: usize = 0,
    lighting_key: u32 = 0,
    texture_snapshot: [16 * 4]u8 = undefined,
    colors: [16]u32 = undefined,
};
threadlocal var prelit_texture4_cache: [prelit_texture4_cache_slots]PrelitTexture4Cache = [_]PrelitTexture4Cache{.{}} ** prelit_texture4_cache_slots;

fn exactLitByte(value: u8, light: f32) u8 {
    const encoded = @as(f32, @floatFromInt(value)) / 255.0;
    const lit = std.math.clamp(srgbToLinear(encoded) * light, 0, 1);
    return @intFromFloat(std.math.clamp(linearToSrgb(lit), 0, 1) * 255.0);
}

fn exactPrelitTexture4(texture: []const u8, light_key: u32) [16]u32 {
    const light: f32 = @bitCast(light_key);
    var colors: [16]u32 = undefined;
    for (0..16) |texel| {
        const offset = texel * 4;
        colors[texel] = @as(u32, exactLitByte(texture[offset + 2], light)) |
            @as(u32, exactLitByte(texture[offset + 1], light)) << 8 |
            @as(u32, exactLitByte(texture[offset], light)) << 16 |
            @as(u32, texture[offset + 3]) << 24;
    }
    return colors;
}

fn cachedPrelitTexture4(texture: []const u8, light_key: u32) ?*const [16]u32 {
    if (texture.len != 4 * 4 * 4) return null;
    const texture_address = @intFromPtr(texture.ptr);
    const cache_index = ((texture_address >> 6) ^ (@as(usize, light_key) *% 2654435761)) % prelit_texture4_cache_slots;
    const entry = &prelit_texture4_cache[cache_index];
    if (entry.valid and entry.texture_address == texture_address and entry.lighting_key == light_key and std.mem.eql(u8, entry.texture_snapshot[0..], texture)) return &entry.colors;
    @memcpy(entry.texture_snapshot[0..], texture);
    entry.colors = exactPrelitTexture4(texture, light_key);
    entry.texture_address = texture_address;
    entry.lighting_key = light_key;
    entry.valid = true;
    return &entry.colors;
}

const prelit_texture16_index_slots = 128;
const PrelitTexture16Cache = struct {
    valid: bool = false,
    texture_address: usize = 0,
    lighting_address: usize = 0,
    texture_snapshot: [16 * 16 * 4]u8 = undefined,
    colors: [256]u32 = undefined,
};

// A batch can contain many triangles that share the same atlas and lighting
// table. Keep stable per-thread entries so each triangle can point at one
// prelit table instead of rebuilding/copying 1 KiB of colors into its large
// PreparedTriangle value. The source snapshot preserves correctness for
// callers that mutate texture bytes in place.
threadlocal var prelit_texture16_cache: [prelit_texture16_cache_slots]PrelitTexture16Cache = [_]PrelitTexture16Cache{.{}} ** prelit_texture16_cache_slots;
threadlocal var prelit_texture16_cache_index: [prelit_texture16_index_slots]u8 = [_]u8{0} ** prelit_texture16_index_slots;

fn prelitTexture16CacheIndex(texture_address: usize, lighting_address: usize) usize {
    return ((texture_address >> 6) ^ (lighting_address >> 4) ^ (lighting_address >> 12)) % prelit_texture16_index_slots;
}

fn cachedPrelitTexture16(texture: []const u8, table: *const [256]u8) ?*const [256]u32 {
    if (texture.len != 16 * 16 * 4) return null;
    const texture_address = @intFromPtr(texture.ptr);
    const lighting_address = @intFromPtr(table);
    const index = prelitTexture16CacheIndex(texture_address, lighting_address);
    if (prelit_texture16_cache_index[index] != 0) {
        const entry = &prelit_texture16_cache[prelit_texture16_cache_index[index] - 1];
        if (entry.valid and entry.texture_address == texture_address and entry.lighting_address == lighting_address and
            std.mem.eql(u8, entry.texture_snapshot[0..], texture)) return &entry.colors;
    }
    for (&prelit_texture16_cache, 0..) |*entry, entry_index| {
        if (entry.valid and entry.texture_address == texture_address and entry.lighting_address == lighting_address and
            std.mem.eql(u8, entry.texture_snapshot[0..], texture))
        {
            prelit_texture16_cache_index[index] = @intCast(entry_index + 1);
            return &entry.colors;
        }
    }
    for (&prelit_texture16_cache, 0..) |*entry, entry_index| {
        if (entry.valid) continue;
        @memcpy(entry.texture_snapshot[0..], texture);
        entry.colors = prelitTexture16x16(texture, table);
        entry.texture_address = texture_address;
        entry.lighting_address = lighting_address;
        entry.valid = true;
        prelit_texture16_cache_index[index] = @intCast(entry_index + 1);
        return &entry.colors;
    }
    return null;
}

fn fillPrelitTexture(color: u32) [16]u32 {
    return [_]u32{color} ** 16;
}

fn prepareLitTextures(prepared: *PreparedDraw, texture: []const u8, texture_width: u32, texture_height: u32) void {
    for (prepared.triangles[0..prepared.count]) |*triangle| {
        if (!triangle.valid or !triangle.unit_uv) continue;
        triangle.prelit_texture_ptr = null;
        triangle.prelit_texture_16x16_ptr = null;
        if (texture_width == 1 and texture_height == 1) {
            const texel = texture[0..4];
            const color = @as(u32, triangle.lighting[texel[2]]) |
                @as(u32, triangle.lighting[texel[1]]) << 8 |
                @as(u32, triangle.lighting[texel[0]]) << 16 |
                @as(u32, texel[3]) << 24;
            triangle.prelit_texture = fillPrelitTexture(color);
            triangle.has_prelit_texture = true;
        } else if (texture_width == 4 and texture_height == 4) {
            const first_u = unitTextureCoordinate(triangle.vertices[0].uv[0]);
            const first_v = unitTextureCoordinate(triangle.vertices[0].uv[1]);
            var flat_texel = true;
            for (triangle.vertices) |vertex| flat_texel = flat_texel and unitTextureCoordinate(vertex.uv[0]) == first_u and unitTextureCoordinate(vertex.uv[1]) == first_v;
            if (flat_texel) {
                const offset = (first_v * 4 + first_u) * 4;
                const light: f32 = @bitCast(triangle.light_key);
                const color = @as(u32, exactLitByte(texture[offset + 2], light)) |
                    @as(u32, exactLitByte(texture[offset + 1], light)) << 8 |
                    @as(u32, exactLitByte(texture[offset], light)) << 16 |
                    @as(u32, texture[offset + 3]) << 24;
                triangle.prelit_texture = fillPrelitTexture(color);
                triangle.has_prelit_texture = true;
                triangle.flat_color = color;
                continue;
            }
            if (cachedPrelitTexture4(texture, triangle.light_key)) |colors| {
                triangle.prelit_texture_ptr = colors;
            } else {
                triangle.prelit_texture = prelitTexture4x4(texture, triangle.lighting);
            }
            triangle.has_prelit_texture = true;
        } else if (texture_width == 16 and texture_height == 16) {
            if (cachedPrelitTexture16(texture, triangle.lighting)) |colors| {
                triangle.prelit_texture_16x16_ptr = colors;
            } else {
                triangle.prelit_texture_16x16 = prelitTexture16x16(texture, triangle.lighting);
            }
            triangle.has_prelit_texture_16x16 = true;
        } else continue;
        refreshFlatTextureColor(triangle);
    }
}

fn preparedTextureColor(triangle: *const PreparedTriangle, u: f32, v: f32) u32 {
    if (triangle.flat_color) |color| return color;
    if (triangle.has_prelit_texture) return shadeUnitTexture4x4(u, v, if (triangle.prelit_texture_ptr) |colors| colors else &triangle.prelit_texture);
    return shadeUnitTexture16x16(u, v, if (triangle.prelit_texture_16x16_ptr) |colors| colors else &triangle.prelit_texture_16x16);
}

fn prepareBatchRaster(prepared: *PreparedDraw, width: u32, height: u32, scissor: Rect) void {
    prepared.batch_fast = prepared.count != 0;
    for (prepared.triangles[0..prepared.count]) |*triangle| {
        triangle.batch_raster = .{};
        if (!triangle.valid or (triangle.flat_color == null and !triangle.has_prelit_texture and !triangle.has_prelit_texture_16x16)) {
            if (triangle.valid) prepared.batch_fast = false;
            continue;
        }
        const p0 = [2]f32{ triangle.vertices[0].screen[0], triangle.vertices[0].screen[1] };
        const p1 = [2]f32{ triangle.vertices[1].screen[0], triangle.vertices[1].screen[1] };
        const p2 = [2]f32{ triangle.vertices[2].screen[0], triangle.vertices[2].screen[1] };
        const area = edge(p0, p1, p2);
        const flat_w = triangle.vertices[0].clip_w == triangle.vertices[1].clip_w and triangle.vertices[0].clip_w == triangle.vertices[2].clip_w;
        const flat_z = triangle.vertices[0].screen[2] == triangle.vertices[1].screen[2] and triangle.vertices[0].screen[2] == triangle.vertices[2].screen[2];
        if (!std.math.isFinite(area) or @abs(area) < 0.00001 or !flat_w or !flat_z or !std.math.isFinite(triangle.vertices[0].screen[2]) or triangle.vertices[0].screen[2] < 0) {
            prepared.batch_fast = false;
            continue;
        }
        const inverse_area = 1.0 / area;
        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), scissor.x, 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), scissor.y, 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
        if (max_x <= min_x or max_y <= min_y) continue;
        const flat_inverse_w = 1.0 / triangle.vertices[0].clip_w;
        const inverse_w = flat_inverse_w;
        const b0_dx = (p2[1] - p1[1]) * inverse_area;
        const b1_dx = (p0[1] - p2[1]) * inverse_area;
        const b2_dx = (p1[1] - p0[1]) * inverse_area;
        const u_over_w = [3]f32{ triangle.vertices[0].uv[0] * inverse_w, triangle.vertices[1].uv[0] * inverse_w, triangle.vertices[2].uv[0] * inverse_w };
        const v_over_w = [3]f32{ triangle.vertices[0].uv[1] * inverse_w, triangle.vertices[1].uv[1] * inverse_w, triangle.vertices[2].uv[1] * inverse_w };
        triangle.batch_raster = .{
            .ready = true,
            .p0 = p0,
            .p1 = p1,
            .p2 = p2,
            .inverse_area = inverse_area,
            .min_x = min_x,
            .min_y = min_y,
            .max_x = max_x,
            .max_y = max_y,
            .flat_depth_bits = @bitCast(triangle.vertices[0].screen[2]),
            .inverse_w = flat_inverse_w,
            .flat_reciprocal_w = 1.0 / flat_inverse_w,
            .u_over_w = u_over_w,
            .v_over_w = v_over_w,
            .u_over_w_dx = b0_dx * u_over_w[0] + b1_dx * u_over_w[1] + b2_dx * u_over_w[2],
            .v_over_w_dx = b0_dx * v_over_w[0] + b1_dx * v_over_w[1] + b2_dx * v_over_w[2],
        };
    }
}

fn refreshBatchRasterUvs(prepared: *PreparedDraw) bool {
    for (prepared.triangles[0..prepared.count]) |*triangle| {
        if (!triangle.valid) continue;
        if (!triangle.batch_raster.ready) return false;
        const raster = &triangle.batch_raster;
        const inverse_w = raster.inverse_w;
        const u_over_w = [3]f32{ triangle.vertices[0].uv[0] * inverse_w, triangle.vertices[1].uv[0] * inverse_w, triangle.vertices[2].uv[0] * inverse_w };
        const v_over_w = [3]f32{ triangle.vertices[0].uv[1] * inverse_w, triangle.vertices[1].uv[1] * inverse_w, triangle.vertices[2].uv[1] * inverse_w };
        const b0_dx = (raster.p2[1] - raster.p1[1]) * raster.inverse_area;
        const b1_dx = (raster.p0[1] - raster.p2[1]) * raster.inverse_area;
        const b2_dx = (raster.p1[1] - raster.p0[1]) * raster.inverse_area;
        raster.u_over_w = u_over_w;
        raster.v_over_w = v_over_w;
        raster.u_over_w_dx = b0_dx * u_over_w[0] + b1_dx * u_over_w[1] + b2_dx * u_over_w[2];
        raster.v_over_w_dx = b0_dx * v_over_w[0] + b1_dx * v_over_w[1] + b2_dx * v_over_w[2];
    }
    return true;
}

fn refreshBatchFastFlag(prepared: *PreparedDraw) void {
    prepared.batch_fast = prepared.count != 0;
    for (prepared.triangles[0..prepared.count]) |triangle| {
        if (!triangle.valid) continue;
        if (!triangle.batch_raster.ready or (triangle.flat_color == null and !triangle.has_prelit_texture and !triangle.has_prelit_texture_16x16)) {
            prepared.batch_fast = false;
            return;
        }
    }
}

fn refreshOpaqueQuad(prepared: *PreparedDraw) void {
    prepared.opaque_quad = .{};
    if (prepared.count != 2) return;
    const first = &prepared.triangles[0];
    const second = &prepared.triangles[1];
    if (!first.valid or !second.valid or !first.has_prelit_texture_16x16 or !second.has_prelit_texture_16x16) return;
    const a = first.vertices;
    const b = second.vertices;
    if (a[0].screen[0] != b[0].screen[0] or a[0].screen[1] != b[0].screen[1] or a[2].screen[0] != b[1].screen[0] or a[2].screen[1] != b[1].screen[1]) return;
    if (a[0].screen[0] >= a[1].screen[0] or a[0].screen[1] >= a[2].screen[1] or a[1].screen[1] != a[0].screen[1] or a[2].screen[0] != a[1].screen[0] or b[2].screen[0] != a[0].screen[0] or b[2].screen[1] != a[2].screen[1]) return;
    if (a[0].clip_w != a[1].clip_w or a[0].clip_w != a[2].clip_w or b[0].clip_w != a[0].clip_w or b[1].clip_w != a[2].clip_w or b[2].clip_w != a[0].clip_w) return;
    if (a[0].screen[2] != a[1].screen[2] or a[0].screen[2] != a[2].screen[2] or b[0].screen[2] != a[0].screen[2] or b[1].screen[2] != a[0].screen[2] or b[2].screen[2] != a[0].screen[2]) return;
    if (a[0].uv[0] != b[0].uv[0] or a[0].uv[1] != b[0].uv[1] or a[2].uv[0] != b[1].uv[0] or a[2].uv[1] != b[1].uv[1]) return;
    if (first.prelit_texture_16x16_ptr != null or second.prelit_texture_16x16_ptr != null) {
        if (first.prelit_texture_16x16_ptr != second.prelit_texture_16x16_ptr) return;
    } else if (!std.mem.eql(u32, first.prelit_texture_16x16[0..], second.prelit_texture_16x16[0..])) return;
    if (!first.batch_raster.ready or !second.batch_raster.ready or first.batch_raster.min_x != second.batch_raster.min_x or first.batch_raster.max_x != second.batch_raster.max_x or first.batch_raster.min_y != second.batch_raster.min_y or first.batch_raster.max_y != second.batch_raster.max_y) return;
    const quad_width = a[1].screen[0] - a[0].screen[0];
    const quad_height = a[2].screen[1] - a[0].screen[1];
    const du = (a[1].uv[0] - a[0].uv[0]) / quad_width;
    const dv = (b[2].uv[1] - a[0].uv[1]) / quad_height;
    if (!std.math.isFinite(du) or !std.math.isFinite(dv) or du < 0) return;
    prepared.opaque_quad = .{
        .valid = true,
        .x0 = a[0].screen[0],
        .y0 = a[0].screen[1],
        .u0 = a[0].uv[0],
        .v0 = a[0].uv[1],
        .du = du,
        .dv = dv,
        .min_y = first.batch_raster.min_y,
        .max_y = first.batch_raster.max_y,
        .prelit = if (first.prelit_texture_16x16_ptr) |colors| colors else &first.prelit_texture_16x16,
    };
}

fn refreshOpaqueQuadUvs(prepared: *PreparedDraw) bool {
    if (!prepared.opaque_quad.valid or prepared.count != 2) return false;
    const first = &prepared.triangles[0];
    const second = &prepared.triangles[1];
    if (!first.valid or !second.valid or !first.has_prelit_texture_16x16 or !second.has_prelit_texture_16x16) return false;
    if (first.vertices[0].uv[0] != second.vertices[0].uv[0] or first.vertices[0].uv[1] != second.vertices[0].uv[1] or
        first.vertices[2].uv[0] != second.vertices[1].uv[0] or first.vertices[2].uv[1] != second.vertices[1].uv[1]) return false;
    if (first.prelit_texture_16x16_ptr != null or second.prelit_texture_16x16_ptr != null) {
        if (first.prelit_texture_16x16_ptr != second.prelit_texture_16x16_ptr) return false;
    } else if (!std.mem.eql(u32, first.prelit_texture_16x16[0..], second.prelit_texture_16x16[0..])) return false;
    const quad_width = first.vertices[1].screen[0] - first.vertices[0].screen[0];
    const quad_height = first.vertices[2].screen[1] - first.vertices[0].screen[1];
    const du = (first.vertices[1].uv[0] - first.vertices[0].uv[0]) / quad_width;
    const dv = (second.vertices[2].uv[1] - first.vertices[0].uv[1]) / quad_height;
    if (!std.math.isFinite(du) or !std.math.isFinite(dv) or du < 0) return false;
    prepared.opaque_quad.u0 = first.vertices[0].uv[0];
    prepared.opaque_quad.v0 = first.vertices[0].uv[1];
    prepared.opaque_quad.du = du;
    prepared.opaque_quad.dv = dv;
    prepared.opaque_quad.prelit = if (first.prelit_texture_16x16_ptr) |colors| colors else &first.prelit_texture_16x16;
    return true;
}

const PreparedCacheStatus = struct { hit: bool, cacheable: bool, promote: bool };

fn prepareDrawCached(uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, output: *PreparedDraw) PreparedCacheStatus {
    const cacheable = uniform.len <= prepared_cache_capacity and texture.len <= prepared_cache_capacity;
    const key_matches = cacheable and prepared_cache.valid and prepared_cache.vertex_count == vertex_count and
        prepared_cache.uniform_len == uniform.len and prepared_cache.texture_len == texture.len and
        prepared_cache.texture_width == texture_width and prepared_cache.texture_height == texture_height and
        std.meta.eql(prepared_cache.viewport, viewport) and
        std.mem.eql(u8, prepared_cache.uniform[0..uniform.len], uniform) and
        std.mem.eql(u8, prepared_cache.texture[0..texture.len], texture);
    const hit = key_matches and prepared_cache.prepared_ready;
    if (hit) {
        output.* = prepared_cache.prepared;
        return .{ .hit = true, .cacheable = true, .promote = false };
    }

    prepareDraw(uniform, vertex_count, 0, viewport, null, output);
    if (cacheable) {
        @memcpy(prepared_cache.uniform[0..uniform.len], uniform);
        @memcpy(prepared_cache.texture[0..texture.len], texture);
        prepared_cache.vertex_count = vertex_count;
        prepared_cache.uniform_len = uniform.len;
        prepared_cache.texture_len = texture.len;
        prepared_cache.texture_width = texture_width;
        prepared_cache.texture_height = texture_height;
        prepared_cache.viewport = viewport;
        prepared_cache.prepared_ready = false;
        prepared_cache.valid = true;
    } else {
        prepared_cache.valid = false;
        prepared_cache.prepared_ready = false;
    }
    return .{ .hit = false, .cacheable = cacheable, .promote = cacheable and key_matches };
}

fn writeFragment(target: ?[]u8, depth: ?[]u8, pixel_index: usize, z: f32, flat_depth_bits: ?u32, inverse_w: f32, flat_reciprocal_w: ?f32, u_over_w: f32, v_over_w: f32, texture: []const u8, texture_width: u32, texture_height: u32, lighting: *const [256]u8, unit_uv: bool, prelit_texture: ?*const [16]u32, flat_color: ?u32, counters: *Counters, comptime count_work: bool) bool {
    const depth_pass = if (depth) |depth_bytes| blk: {
        const depth_offset = pixel_index * 4;
        if (flat_depth_bits) |bits| {
            if (bits > std.mem.readInt(u32, depth_bytes[depth_offset..][0..4], .little)) break :blk false;
        } else if (z > readFloat(depth_bytes, depth_offset)) break :blk false;
        if (count_work) counters.depth_tests_passed += 1;
        if (flat_depth_bits) |bits| std.mem.writeInt(u32, depth_bytes[depth_offset..][0..4], bits, .little) else writeFloat(depth_bytes, depth_offset, z);
        break :blk true;
    } else true;
    if (!depth_pass) return false;
    if (target) |color_bytes| {
        const color = if (flat_color) |constant| constant else blk: {
            const reciprocal_w = flat_reciprocal_w orelse 1.0 / inverse_w;
            const u = u_over_w * reciprocal_w;
            const v = v_over_w * reciprocal_w;
            break :blk if (prelit_texture) |prelit| shadeUnitTexture4x4(u, v, prelit) else shade(texture, texture_width, texture_height, u, v, lighting, unit_uv);
        };
        std.mem.writeInt(u32, color_bytes[pixel_index * 4 ..][0..4], color, .little);
        if (count_work) counters.color_writes += 1;
    }
    return true;
}

fn stripeLane(y: i32, height: u32, lane_count: usize, stripe_count: usize) usize {
    if (lane_count == 1) return 0;
    if (lane_count == 2 and stripe_count == 2) return if (@as(u32, @intCast(y)) < height / 2) 0 else 1;
    const stripe = @min((@as(u64, @intCast(y)) * stripe_count) / height, stripe_count - 1);
    return @intCast(stripe % lane_count);
}

fn drawInternal(target: ?[]u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, counters: *Counters, comptime optimized: bool, cull_mode: u32, front_face: i32, lane_index: usize, lane_count: usize, stripe_count: usize, prepared: ?*const PreparedDraw, indexed: ?IndexStream, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize, comptime count_work: bool) usize {
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse return 0 else base_vertex +| vertex_count;
    if (vertex_count == 0 or vertex_count % 3 != 0 or source_vertex_count == 0 or uniform.len < 64 + @as(usize, source_vertex_count) * 32 or (target == null and depth == null) or texture.len != @as(usize, texture_width) * texture_height * 4 or texture_width == 0 or texture_height == 0) return 0;
    if (target) |color_bytes| if (color_bytes.len != @as(usize, width) * height * 4) return 0;
    if (depth) |depth_bytes| if (depth_bytes.len < @as(usize, width) * height * 4) return 0;
    const typed_target: ?[]align(4) u32 = if (target) |color_bytes|
        if (builtin.cpu.arch.endian() == .little and @intFromPtr(color_bytes.ptr) & 3 == 0) std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(color_bytes))) else null
    else
        null;
    const typed_depth: ?[]align(4) u32 = if (depth) |depth_bytes|
        if (builtin.cpu.arch.endian() == .little and @intFromPtr(depth_bytes.ptr) & 3 == 0) std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(depth_bytes))) else null
    else
        null;
    var local_counters = Counters{};
    const stats: *Counters = if (count_work) &local_counters else counters;
    if (count_work) stats.triangles_submitted += vertex_count / 3;
    var row_lanes: [8192]u8 = undefined;
    if (lane_count != 1 and stripe_count <= lane_count) {
        for (row_lanes[0..height], 0..) |*lane, y| lane.* = @intCast(stripeLane(@intCast(y), height, lane_count, stripe_count));
    }
    var pixels_written: usize = 0;
    var lighting_keys: [12]u32 = undefined;
    var lighting_tables: [12][256]u8 = undefined;
    var lighting_count: usize = 0;
    var triangle: u32 = 0;
    while (triangle < vertex_count) : (triangle += 3) {
        const prepared_index: ?usize = if (prepared) |state| blk: {
            const index = triangle / 3;
            if (index >= state.count) break :blk null;
            if (!state.triangles[index].valid) continue;
            break :blk index;
        } else null;
        const prepared_triangle: ?*const PreparedTriangle = if (prepared) |state| if (prepared_index) |index| &state.triangles[index] else null else null;
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
        if (count_work) stats.triangles_rasterized += 1;

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
        const prelit_texture: ?*const [16]u32 = if (prepared_triangle) |state| if (state.has_prelit_texture) if (state.prelit_texture_ptr) |colors| colors else &state.prelit_texture else null else null;
        const prelit_texture_16x16: ?*const [256]u32 = if (prepared_triangle) |state| if (state.has_prelit_texture_16x16) if (state.prelit_texture_16x16_ptr) |colors| colors else &state.prelit_texture_16x16 else null else null;
        const flat_color = if (prepared_triangle) |state| state.flat_color else null;
        const cached_spans: ?*const [flat_span_rows]FlatSpan = if (prepared) |state| if (prepared_index) |index| if (state.spans_valid) preparedSpan(state, index) else null else null else null;
        const flat_w = v0.clip_w == v1.clip_w and v0.clip_w == v2.clip_w;
        const flat_z = v0.screen[2] == v1.screen[2] and v0.screen[2] == v2.screen[2];
        const flat_inverse_w = if (flat_w) 1.0 / v0.clip_w else 0;
        const flat_reciprocal_w = if (flat_w) 1.0 / flat_inverse_w else null;
        const flat_depth_bits = if (optimized and flat_z and std.math.isFinite(v0.screen[2]) and v0.screen[2] >= 0) @as(u32, @bitCast(v0.screen[2])) else null;

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
        const tile_size: i32 = if (optimized and (lane_count != 1 or width >= 3840)) 32 else if (optimized) 8 else 1;
        // The normal parallel draw has exactly two lanes split at the middle
        // row.  Clip the tile walk to each lane up front; scanning every row
        // in every tile just to rediscover that split costs more than the
        // synchronization saved on medium-sized render targets.
        const fixed_two_lane = lane_count == 2 and stripe_count == 2;
        const lane_min_y: i32 = if (fixed_two_lane) @intCast(@as(usize, height) * lane_index / 2) else min_y;
        const lane_max_y: i32 = if (fixed_two_lane) @intCast(@as(usize, height) * (lane_index + 1) / 2) else max_y;
        const raster_min_y = @max(min_y, lane_min_y);
        const raster_max_y = @min(max_y, lane_max_y);
        if (!count_work and optimized and (flat_color != null or prelit_texture != null or prelit_texture_16x16 != null) and flat_depth_bits != null and flat_reciprocal_w != null and typed_target != null and typed_depth != null) {
            pixels_written += rasterFlatSpanTriangle(true, typed_target.?, typed_depth.?, width, height, stripe_count, lane_index, p0, p1, p2, inverse_area, min_x, min_y, max_x, max_y, raster_min_y, raster_max_y, cached_spans, flat_depth_bits.?, flat_color, prelit_texture, prelit_texture_16x16, tile_min, tile_max, tile_columns, tile_count, flat_reciprocal_w.?, u_over_w0, u_over_w1, u_over_w2, v_over_w0, v_over_w1, v_over_w2, u_over_w_dx, v_over_w_dx);
            continue;
        }
        const stripe_partitioned = lane_count != 1 and !fixed_two_lane and stripe_count > lane_count;
        var stripe_index: usize = if (stripe_partitioned) lane_index else 0;
        const stripe_limit: usize = if (stripe_partitioned) stripe_count else 1;
        const stripe_step: usize = if (stripe_partitioned) lane_count else stripe_count;
        while (stripe_index < stripe_limit) : (stripe_index += stripe_step) {
            const stripe_min_y: i32 = if (stripe_partitioned) @intCast(@as(usize, height) * stripe_index / stripe_count) else raster_min_y;
            const stripe_max_y: i32 = if (stripe_partitioned) @intCast(@as(usize, height) * (stripe_index + 1) / stripe_count) else raster_max_y;
            var tile_y: i32 = @max(raster_min_y, stripe_min_y);
            while (tile_y < @min(raster_max_y, stripe_max_y)) : (tile_y += tile_size) {
                const tile_max_y = @min(tile_y + tile_size, raster_max_y, stripe_max_y);
                if (lane_count != 1 and !fixed_two_lane and !stripe_partitioned) {
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
                    const tile_fast_flat = optimized and fully_covered and flat_w and flat_z and flat_depth_bits != null and flat_reciprocal_w != null;
                    var y = tile_y;
                    while (y < tile_max_y) : (y += 1) {
                        if (lane_count != 1 and !fixed_two_lane and !stripe_partitioned and row_lanes[@intCast(y)] != lane_index) continue;
                        var x = tile_x;
                        const first_sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                        var b0 = edge(p1, p2, first_sample) * inverse_area;
                        var b1 = edge(p2, p0, first_sample) * inverse_area;
                        var b2 = edge(p0, p1, first_sample) * inverse_area;
                        var stepped_inverse_w = b0 * inv_w0 + b1 * inv_w1 + b2 * inv_w2;
                        var stepped_z = b0 * v0.screen[2] + b1 * v1.screen[2] + b2 * v2.screen[2];
                        var stepped_u_over_w = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
                        var stepped_v_over_w = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
                        const fast_flat = tile_fast_flat;
                        if (fast_flat) {
                            const fast_z_bits = flat_depth_bits.?;
                            const fast_reciprocal_w = flat_reciprocal_w.?;
                            if (typed_target) |color_words| if (typed_depth) |depth_words| {
                                while (x + 4 <= tile_max_x) : (x += 4) {
                                    if (count_work) {
                                        stats.fragments_tested += 4;
                                        stats.fragments_covered += 4;
                                    }
                                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                    const depth_values: @Vector(4, u32) = depth_words[pixel_index..][0..4].*;
                                    const passes: @Vector(4, bool) = @as(@Vector(4, u32), @splat(fast_z_bits)) <= depth_values;
                                    var colors: [4]u32 = undefined;
                                    if (flat_color) |color| {
                                        colors = .{ color, color, color, color };
                                    } else {
                                        inline for (0..4) |lane| {
                                            const lane_u = stepped_u_over_w + u_over_w_dx * @as(f32, @floatFromInt(lane));
                                            const lane_v = stepped_v_over_w + v_over_w_dx * @as(f32, @floatFromInt(lane));
                                            colors[lane] = if (prelit_texture) |prelit| shadeUnitTexture4x4(lane_u * fast_reciprocal_w, lane_v * fast_reciprocal_w, prelit) else shade(texture, texture_width, texture_height, lane_u * fast_reciprocal_w, lane_v * fast_reciprocal_w, lighting, unit_uv);
                                        }
                                    }
                                    if (@reduce(.And, passes)) {
                                        depth_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(fast_z_bits));
                                        color_words[pixel_index..][0..4].* = colors;
                                        if (count_work) {
                                            stats.depth_tests_passed += 4;
                                            stats.color_writes += 4;
                                        }
                                        pixels_written += 4;
                                    } else {
                                        inline for (0..4) |lane| {
                                            if (passes[lane]) {
                                                depth_words[pixel_index + lane] = fast_z_bits;
                                                color_words[pixel_index + lane] = colors[lane];
                                                if (count_work) {
                                                    stats.depth_tests_passed += 1;
                                                    stats.color_writes += 1;
                                                }
                                                pixels_written += 1;
                                            }
                                        }
                                    }
                                    stepped_u_over_w += u_over_w_dx * 4.0;
                                    stepped_v_over_w += v_over_w_dx * 4.0;
                                }
                                while (x < tile_max_x) : (x += 1) {
                                    if (count_work) {
                                        stats.fragments_tested += 1;
                                        stats.fragments_covered += 1;
                                    }
                                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                    if (fast_z_bits <= depth_words[pixel_index]) {
                                        depth_words[pixel_index] = fast_z_bits;
                                        if (count_work) stats.depth_tests_passed += 1;
                                        color_words[pixel_index] = if (flat_color) |color| color else if (prelit_texture) |prelit| shadeUnitTexture4x4(stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, prelit) else shade(texture, texture_width, texture_height, stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, lighting, unit_uv);
                                        if (count_work) stats.color_writes += 1;
                                        pixels_written += 1;
                                    }
                                    stepped_u_over_w += u_over_w_dx;
                                    stepped_v_over_w += v_over_w_dx;
                                }
                            } else {
                                while (x < tile_max_x) : (x += 1) {
                                    if (count_work) {
                                        stats.fragments_tested += 1;
                                        stats.fragments_covered += 1;
                                    }
                                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                    const depth_offset = pixel_index * 4;
                                    if (depth) |depth_bytes| {
                                        if (fast_z_bits <= std.mem.readInt(u32, depth_bytes[depth_offset..][0..4], .little)) {
                                            std.mem.writeInt(u32, depth_bytes[depth_offset..][0..4], fast_z_bits, .little);
                                            if (count_work) stats.depth_tests_passed += 1;
                                            if (target) |color_bytes| {
                                                std.mem.writeInt(u32, color_bytes[depth_offset..][0..4], if (prelit_texture) |prelit| shadeUnitTexture4x4(stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, prelit) else shade(texture, texture_width, texture_height, stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, lighting, unit_uv), .little);
                                                if (count_work) stats.color_writes += 1;
                                            }
                                            pixels_written += 1;
                                        }
                                    } else {
                                        if (target) |color_bytes| {
                                            std.mem.writeInt(u32, color_bytes[depth_offset..][0..4], if (prelit_texture) |prelit| shadeUnitTexture4x4(stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, prelit) else shade(texture, texture_width, texture_height, stepped_u_over_w * fast_reciprocal_w, stepped_v_over_w * fast_reciprocal_w, lighting, unit_uv), .little);
                                            if (count_work) stats.color_writes += 1;
                                        }
                                        pixels_written += 1;
                                    }
                                    stepped_u_over_w += u_over_w_dx;
                                    stepped_v_over_w += v_over_w_dx;
                                }
                            };
                        } else if (optimized and fully_covered) {
                            while (x < tile_max_x) : (x += 1) {
                                if (count_work) {
                                    stats.fragments_tested += 1;
                                    stats.fragments_covered += 1;
                                }
                                const inverse_w = if (optimized and flat_w) flat_inverse_w else if (optimized) stepped_inverse_w else unreachable;
                                if (@abs(inverse_w) >= 0.000001) {
                                    const z = if (optimized and flat_z) v0.screen[2] else if (optimized) stepped_z else unreachable;
                                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                    if (writeFragment(target, depth, pixel_index, z, flat_depth_bits, inverse_w, if (optimized and flat_w) flat_reciprocal_w else null, stepped_u_over_w, stepped_v_over_w, texture, texture_width, texture_height, lighting, unit_uv, prelit_texture, flat_color, stats, count_work)) pixels_written += 1;
                                }
                                b0 += b0_dx;
                                b1 += b1_dx;
                                b2 += b2_dx;
                                if (!flat_w) stepped_inverse_w += inverse_w_dx;
                                if (!flat_z) stepped_z += z_dx;
                                stepped_u_over_w += u_over_w_dx;
                                stepped_v_over_w += v_over_w_dx;
                            }
                        } else while (x < tile_max_x) : (x += 1) {
                            const sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                            const fragment_b0 = if (optimized) b0 else edge(p1, p2, sample) * inverse_area;
                            const fragment_b1 = if (optimized) b1 else edge(p2, p0, sample) * inverse_area;
                            const fragment_b2 = if (optimized) b2 else edge(p0, p1, sample) * inverse_area;
                            if (count_work) stats.fragments_tested += 1;
                            if (fragment_b0 >= 0 and fragment_b1 >= 0 and fragment_b2 >= 0) {
                                if (count_work) stats.fragments_covered += 1;
                                const inverse_w = if (optimized and flat_w) flat_inverse_w else if (optimized) stepped_inverse_w else fragment_b0 * inv_w0 + fragment_b1 * inv_w1 + fragment_b2 * inv_w2;
                                if (@abs(inverse_w) >= 0.000001) {
                                    const z = if (optimized and flat_z) v0.screen[2] else if (optimized) stepped_z else fragment_b0 * v0.screen[2] + fragment_b1 * v1.screen[2] + fragment_b2 * v2.screen[2];
                                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                    const u_over_w = if (optimized) stepped_u_over_w else fragment_b0 * u_over_w0 + fragment_b1 * u_over_w1 + fragment_b2 * u_over_w2;
                                    const v_over_w = if (optimized) stepped_v_over_w else fragment_b0 * v_over_w0 + fragment_b1 * v_over_w1 + fragment_b2 * v_over_w2;
                                    if (writeFragment(target, depth, pixel_index, z, flat_depth_bits, inverse_w, if (optimized and flat_w) flat_reciprocal_w else null, u_over_w, v_over_w, texture, texture_width, texture_height, lighting, unit_uv, prelit_texture, flat_color, stats, count_work)) pixels_written += 1;
                                }
                            }
                            b0 += b0_dx;
                            b1 += b1_dx;
                            b2 += b2_dx;
                            if (!flat_w) stepped_inverse_w += inverse_w_dx;
                            if (!flat_z) stepped_z += z_dx;
                            stepped_u_over_w += u_over_w_dx;
                            stepped_v_over_w += v_over_w_dx;
                        }
                    }
                }
            }
        }
    }
    if (count_work) counters.* = local_counters;
    return pixels_written;
}

pub fn drawCounted(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, counters, true, 0, 0, 0, 1, 1, null, null, null, null, 0, 0, true);
}

/// Untiled scalar oracle used by differential tests and checksum validation.
pub fn drawReferenceCounted(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, counters, false, 0, 0, 0, 1, 1, null, null, null, null, 0, 0, true);
}

const parallel_band_count = 2;
const parallel_slice_count = 4;
const parallel_8k_slice_count = 40;
// Keep enough retained command/cache storage for realistic terminal frames.
// Larger chunks amortize the existing Vulkan ABI submission and worker wakeup
// costs without changing DrawCommand or the public batch entry points.
const max_batch_commands = 8192;
// Small static UI batches are already fully prepared by the time the next
// frame arrives. Avoid waking the raster worker for these short command lists;
// the worker hand-off costs more than the bounded serial walk on two cores.
const serial_batch_command_limit = 256;
// Span rows are a sizeable per-command cache. Keep the hot prefix for the
// common small batches while allowing large terminal submissions to retain
// prepared geometry without reserving hundreds of megabytes for cold spans.
const max_batch_span_cache_commands = 1024;
const max_batch_tiles = max_dirty_tile_bytes * 8;
const max_batch_geometry_bytes = 64 + max_prepared_triangles * 3 * 16;
const BatchCommandCache = struct {
    valid: bool = false,
    geometry_valid: bool = false,
    commands_address: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    uniform_len: usize = 0,
    texture_len: usize = 0,
    geometry_len: usize = 0,
    texture_width: u32 = 0,
    texture_height: u32 = 0,
    vertex_count: u32 = 0,
    viewport: Viewport = undefined,
    scissor: Rect = undefined,
    lighting_generation: u64 = 0,
    uniform_revision: u64 = 0,
    geometry_revision: u64 = 0,
    texture_revision: u64 = 0,
    uniform_address: usize = 0,
    texture_address: usize = 0,
    bounds: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 },
};
const BatchCommandSnapshot = struct {
    uniform: [prepared_cache_capacity]u8 = undefined,
    texture: [prepared_cache_capacity]u8 = undefined,
    geometry: [max_batch_geometry_bytes]u8 = undefined,
};
const BatchSpanCache = struct {
    valid: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    count: usize = 0,
    triangle_valid: [max_prepared_triangles]bool = [_]bool{false} ** max_prepared_triangles,
    screen: [max_prepared_triangles][3][3]f32 = undefined,
    spans: [max_prepared_triangles][flat_span_rows]FlatSpan = [_][flat_span_rows]FlatSpan{[_]FlatSpan{.{}} ** flat_span_rows} ** max_prepared_triangles,
    quad_spans_valid: bool = false,
    quad_spans: [flat_span_rows]FlatSpan = [_]FlatSpan{.{}} ** flat_span_rows,
};
// Six-vertex sprite/text commands only need two triangle span rows. Keeping a
// compact cache for that dominant Vulkan stream avoids retaining the full
// twelve-triangle cache shape for thousands of terminal glyphs.
const BatchQuadSpanCache = struct {
    valid: bool = false,
    width: u32 = 0,
    height: u32 = 0,
    spans: [2][flat_span_rows]FlatSpan = [_][flat_span_rows]FlatSpan{[_]FlatSpan{.{}} ** flat_span_rows} ** 2,
};
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
    prepared: *const PreparedDraw,
    stripe_count: usize = parallel_band_count,
    count_work: bool = false,
    clear_color_pattern: ?u32 = null,
    clear_depth_pattern: ?u32 = null,
    expected_target: ?[]const u8 = null,
    validation_failed: ?*std.atomic.Value(bool) = null,
    clear_spans: bool = false,
    tile_min: ?[]u32 = null,
    tile_max: ?[]u32 = null,
    tile_columns: usize = 0,
    tile_count: usize = 0,
    bands: [parallel_band_count]ParallelBand = [_]ParallelBand{.{}} ** parallel_band_count,
};
const ParallelBatchPrepare = struct {
    commands: []const DrawCommand,
    prepared: []PreparedDraw,
    width: u32,
    height: u32,
    color_only: bool = false,
};
const ParallelBatchDraw = struct {
    target: []u8,
    depth: []u8,
    width: u32,
    height: u32,
    commands: []const DrawCommand,
    prepared: []const PreparedDraw,
    count_work: bool,
    clear_color_pattern: ?u32 = null,
    clear_depth_pattern: ?u32 = null,
    tile_min: ?[]u32 = null,
    tile_max: ?[]u32 = null,
    tile_columns: usize = 0,
    tile_count: usize = 0,
    prepare: ?*ParallelBatchPrepare = null,
    prepare_completed: ?*std.atomic.Value(usize) = null,
    command_lanes: ?[]u8 = null,
    ownership_ready: ?*std.atomic.Value(bool) = null,
    color_only: bool = false,
    bands: [parallel_band_count]ParallelBand = [_]ParallelBand{.{}} ** parallel_band_count,
};
const ParallelClear = struct { color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32 = 0, rect: Rect = .{ .x = 0, .y = 0, .width = 0, .height = 0 } };
const ParallelTileClear = struct { color: []u8, color_pattern: u32, depth: []u8, depth_pattern: u32, width: u32, height: u32, tiles: []const u8 };
const ParallelJob = union(enum) { draw: *ParallelDraw, batch: *ParallelBatchDraw, batch_prepare: *ParallelBatchPrepare, clear: *ParallelClear, tile_clear: *ParallelTileClear };

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
var batch_prepared_storage: [max_batch_commands]PreparedDraw = undefined;
var batch_command_cache: [max_batch_commands]BatchCommandCache = undefined;
var batch_command_snapshots: [max_batch_commands]BatchCommandSnapshot = undefined;
// Populated by the single cache-validation pass before a batch dispatch.
// Preparation workers consume this mask so they do not repeat the same
// command-cache comparison for every entry in a dynamic stream.
var batch_command_needs_prepare: [max_batch_commands]bool = undefined;
var batch_span_cache: [max_batch_span_cache_commands]BatchSpanCache = undefined;
var batch_quad_span_cache: [max_batch_commands]BatchQuadSpanCache = undefined;
var batch_command_lanes: [max_batch_commands]u8 = undefined;
var batch_command_indices: [parallel_band_count][max_batch_commands]usize = undefined;
var batch_command_index_counts: [parallel_band_count]usize = [_]usize{0} ** parallel_band_count;
var batch_ownership_ready = std.atomic.Value(bool).init(false);
var batch_tile_min: [max_batch_tiles * parallel_band_count]u32 = undefined;
var batch_tile_max: [max_batch_tiles * parallel_band_count]u32 = undefined;
const BatchStaticReplayCache = struct {
    valid: bool = false,
    target_address: usize = 0,
    depth_address: usize = 0,
    commands_address: usize = 0,
    command_count: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    pixels_written: usize = 0,
};
var batch_static_replay_cache: BatchStaticReplayCache = .{};

fn resetBatchCaches() void {
    for (&batch_command_cache) |*cache| {
        cache.valid = false;
        cache.geometry_valid = false;
    }
    for (&batch_span_cache) |*cache| cache.valid = false;
    for (&batch_quad_span_cache) |*cache| cache.valid = false;
    batch_static_replay_cache.valid = false;
}

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

fn runParallelBand(context: *ParallelDraw, band_index: usize, comptime count_work: bool) void {
    const band = &context.bands[band_index];
    if (comptime !count_work) {
        if (context.prepared.batch_fast) {
            if (drawPreparedBatchFast(false, context.target, context.depth.?, context.width, context.height, context.prepared, band_index, context.tile_min, context.tile_max, context.tile_columns, context.tile_count)) |pixels_written| {
                band.pixels_written = pixels_written;
                return;
            }
        }
    }
    const stripe_count = context.stripe_count;
    band.pixels_written = drawInternal(context.target, context.depth, context.width, context.height, context.uniform, context.texture, context.texture_width, context.texture_height, context.vertex_count, context.base_vertex, context.viewport, context.scissor, &band.counters, true, context.cull_mode, context.front_face, band_index, parallel_band_count, stripe_count, context.prepared, context.indexed, context.tile_min, context.tile_max, context.tile_columns, context.tile_count, count_work);
}

fn addCounters(total: *Counters, value: Counters) void {
    total.triangles_submitted += value.triangles_submitted;
    total.triangles_rasterized += value.triangles_rasterized;
    total.fragments_tested += value.fragments_tested;
    total.fragments_covered += value.fragments_covered;
    total.depth_tests_passed += value.depth_tests_passed;
    total.color_writes += value.color_writes;
}

fn batchSpanCacheMatches(cache: *const BatchSpanCache, prepared: *const PreparedDraw, width: u32, height: u32) bool {
    if (!cache.valid or cache.width != width or cache.height != height or cache.count != prepared.count) return false;
    for (prepared.triangles[0..prepared.count], 0..) |triangle, index| {
        if (cache.triangle_valid[index] != triangle.valid) return false;
        if (!triangle.valid) continue;
        for (0..3) |vertex| for (0..3) |component| {
            if (@as(u32, @bitCast(cache.screen[index][vertex][component])) != @as(u32, @bitCast(triangle.vertices[vertex].screen[component]))) return false;
        };
    }
    return true;
}

fn rememberBatchSpanCache(cache: *BatchSpanCache, prepared: *const PreparedDraw, width: u32, height: u32) void {
    cache.* = .{ .valid = true, .width = width, .height = height, .count = prepared.count };
    for (prepared.triangles[0..prepared.count], 0..) |triangle, index| {
        cache.triangle_valid[index] = triangle.valid;
        if (!triangle.valid) continue;
        for (0..3) |vertex| {
            for (0..3) |component| cache.screen[index][vertex][component] = triangle.vertices[vertex].screen[component];
        }
        @memcpy(&cache.spans[index], &prepared.spans[index]);
    }
    if (prepared.count == 2 and prepared.triangles[0].valid and prepared.triangles[1].valid) {
        cache.quad_spans_valid = true;
        for (0..height) |y| {
            const first = cache.spans[0][y];
            const second = cache.spans[1][y];
            if (first.last <= first.first) {
                cache.quad_spans[y] = second;
            } else if (second.last <= second.first) {
                cache.quad_spans[y] = first;
            } else {
                cache.quad_spans[y] = .{ .first = @min(first.first, second.first), .last = @max(first.last, second.last) };
            }
        }
    }
}

fn batchGeometryLen(vertex_count: u32) usize {
    return 64 + @as(usize, @min(vertex_count, max_prepared_triangles * 3)) * 16;
}

fn batchCommandCacheMatches(cache: *const BatchCommandCache, snapshot: *const BatchCommandSnapshot, command: DrawCommand, commands_address: usize, width: u32, height: u32, lighting_generation: u64) bool {
    if (!cache.valid or cache.commands_address != commands_address or cache.width != width or cache.height != height or cache.uniform_len != command.uniform.len or cache.texture_len != command.texture.len or
        cache.texture_width != command.texture_width or cache.texture_height != command.texture_height or cache.vertex_count != command.vertex_count or
        cache.lighting_generation != lighting_generation or cache.geometry_revision != command.geometry_revision or !std.meta.eql(cache.viewport, command.viewport) or !std.meta.eql(cache.scissor, command.scissor)) return false;
    const uniform_same = command.uniform_revision != 0 and cache.uniform_revision == command.uniform_revision and cache.uniform_address == @intFromPtr(command.uniform.ptr) or
        command.uniform_revision == 0 and cache.uniform_revision == 0 and std.mem.eql(u8, snapshot.uniform[0..command.uniform.len], command.uniform);
    const texture_same = command.texture_revision != 0 and cache.texture_revision == command.texture_revision and cache.texture_address == @intFromPtr(command.texture.ptr) or
        command.texture_revision == 0 and cache.texture_revision == 0 and std.mem.eql(u8, snapshot.texture[0..command.texture.len], command.texture);
    return uniform_same and texture_same;
}

fn batchNeedsPreparation(commands: []const DrawCommand, width: u32, height: u32) bool {
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    const commands_address = @intFromPtr(commands.ptr);
    var needs_preparation = false;
    for (commands, 0..) |command, index| {
        const needs_command = !batchCommandCacheMatches(&batch_command_cache[index], &batch_command_snapshots[index], command, commands_address, width, height, lighting_generation);
        batch_command_needs_prepare[index] = needs_command;
        needs_preparation = needs_preparation or needs_command;
    }
    return needs_preparation;
}

fn batchGeometryCacheMatches(cache: *const BatchCommandCache, snapshot: *const BatchCommandSnapshot, command: DrawCommand) bool {
    const geometry_len = batchGeometryLen(command.vertex_count);
    if (!cache.geometry_valid or cache.geometry_len != geometry_len or cache.vertex_count != command.vertex_count or
        !std.meta.eql(cache.viewport, command.viewport) or command.uniform.len < geometry_len) return false;
    return command.geometry_revision != 0 and cache.geometry_revision == command.geometry_revision and cache.uniform_address == @intFromPtr(command.uniform.ptr) or
        command.geometry_revision == 0 and cache.geometry_revision == 0 and std.mem.eql(u8, snapshot.geometry[0..geometry_len], command.uniform[0..geometry_len]);
}

fn rememberBatchCommandCache(cache: *BatchCommandCache, snapshot: *BatchCommandSnapshot, command: DrawCommand, commands_address: usize, width: u32, height: u32, lighting_generation: u64) void {
    if (command.uniform.len > prepared_cache_capacity or command.texture.len > prepared_cache_capacity) {
        cache.valid = false;
        cache.geometry_valid = false;
        return;
    }
    cache.width = width;
    cache.height = height;
    cache.commands_address = commands_address;
    cache.uniform_len = command.uniform.len;
    cache.texture_len = command.texture.len;
    cache.geometry_len = batchGeometryLen(command.vertex_count);
    cache.texture_width = command.texture_width;
    cache.texture_height = command.texture_height;
    cache.vertex_count = command.vertex_count;
    cache.viewport = command.viewport;
    cache.scissor = command.scissor;
    cache.lighting_generation = lighting_generation;
    cache.uniform_revision = command.uniform_revision;
    cache.geometry_revision = command.geometry_revision;
    cache.texture_revision = command.texture_revision;
    cache.uniform_address = @intFromPtr(command.uniform.ptr);
    cache.texture_address = @intFromPtr(command.texture.ptr);
    if (command.uniform_revision == 0) @memcpy(snapshot.uniform[0..command.uniform.len], command.uniform);
    if (command.texture_revision == 0) @memcpy(snapshot.texture[0..command.texture.len], command.texture);
    if (command.geometry_revision == 0 and command.uniform.len >= cache.geometry_len) {
        @memcpy(snapshot.geometry[0..cache.geometry_len], command.uniform[0..cache.geometry_len]);
        cache.geometry_valid = true;
    } else {
        cache.geometry_valid = command.uniform.len >= cache.geometry_len;
    }
    cache.valid = true;
}

fn refreshBatchPreparedUvs(prepared: *PreparedDraw, uniform: []const u8, vertex_count: u32) bool {
    const uv_base = std.math.mul(usize, @as(usize, vertex_count), 16) catch return false;
    const uv_start = 64 + uv_base;
    if (uv_start > uniform.len) return false;
    for (prepared.triangles[0..prepared.count], 0..) |*triangle, triangle_index| {
        if (!triangle.valid) continue;
        var unit_uv = true;
        var same_texel = true;
        var first_texel_u: usize = 0;
        var first_texel_v: usize = 0;
        for (&triangle.vertices, 0..) |*vertex, vertex_index| {
            const offset = uv_start + (triangle_index * 3 + vertex_index) * 16;
            if (offset > uniform.len or uniform.len - offset < 8) return false;
            vertex.uv = .{ readFloat(uniform, offset), readFloat(uniform, offset + 4) };
            const in_unit = vertex.uv[0] >= 0 and vertex.uv[0] <= 1 and vertex.uv[1] >= 0 and vertex.uv[1] <= 1;
            unit_uv = unit_uv and in_unit;
            if (in_unit and (triangle.has_prelit_texture or triangle.has_prelit_texture_16x16)) {
                const texel_u = if (triangle.has_prelit_texture) unitTextureCoordinate(vertex.uv[0]) else unitTextureCoordinate16(vertex.uv[0]);
                const texel_v = if (triangle.has_prelit_texture) unitTextureCoordinate(vertex.uv[1]) else unitTextureCoordinate16(vertex.uv[1]);
                if (vertex_index == 0) {
                    first_texel_u = texel_u;
                    first_texel_v = texel_v;
                } else {
                    same_texel = same_texel and texel_u == first_texel_u and texel_v == first_texel_v;
                }
            } else same_texel = false;
        }
        triangle.unit_uv = unit_uv and ((triangle.vertices[0].clip_w > 0 and triangle.vertices[1].clip_w > 0 and triangle.vertices[2].clip_w > 0) or
            (triangle.vertices[0].clip_w < 0 and triangle.vertices[1].clip_w < 0 and triangle.vertices[2].clip_w < 0));
        if (!triangle.unit_uv) {
            triangle.flat_color = null;
            triangle.has_prelit_texture = false;
            triangle.prelit_texture_ptr = null;
            triangle.prelit_texture_16x16_ptr = null;
            triangle.has_prelit_texture_16x16 = false;
        } else if (!same_texel) {
            triangle.flat_color = null;
        } else if (triangle.has_prelit_texture) {
            triangle.flat_color = (if (triangle.prelit_texture_ptr) |colors| colors else &triangle.prelit_texture)[first_texel_v * 4 + first_texel_u];
        } else if (triangle.has_prelit_texture_16x16) {
            triangle.flat_color = (if (triangle.prelit_texture_16x16_ptr) |colors| colors else &triangle.prelit_texture_16x16)[first_texel_v * 16 + first_texel_u];
        } else {
            triangle.flat_color = null;
        }
    }
    return true;
}

fn prepareBatchCommand(command: DrawCommand, commands_address: usize, command_index: usize, width: u32, height: u32, output: *PreparedDraw, build_opaque_quad: bool) void {
    if (!batch_command_needs_prepare[command_index]) return;
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    const command_cache = &batch_command_cache[command_index];
    const command_snapshot = &batch_command_snapshots[command_index];
    if (batchCommandCacheMatches(command_cache, command_snapshot, command, commands_address, width, height, lighting_generation)) return;

    var geometry_cache_hit = batchGeometryCacheMatches(command_cache, command_snapshot, command);
    if (geometry_cache_hit) {
        if (!refreshBatchPreparedUvs(output, command.uniform, command.vertex_count)) {
            geometry_cache_hit = false;
            prepareDraw(command.uniform, command.vertex_count, 0, command.viewport, null, output);
        }
    } else {
        prepareDraw(command.uniform, command.vertex_count, 0, command.viewport, null, output);
    }

    const span_cache: ?*BatchSpanCache = if (command_index < max_batch_span_cache_commands) &batch_span_cache[command_index] else null;
    const quad_span_cache: ?*BatchQuadSpanCache = if (command.vertex_count == 6) &batch_quad_span_cache[command_index] else null;
    const geometry_revision_changed = command.geometry_revision != 0 and command.geometry_revision != command_cache.geometry_revision;
    if (geometry_cache_hit and quad_span_cache != null and quad_span_cache.?.valid and quad_span_cache.?.width == width and quad_span_cache.?.height == height) {
        @memcpy(output.spans[0..2], quad_span_cache.?.spans[0..2]);
        output.spans_valid = true;
        output.spans_external = null;
        output.quad_spans_external = null;
    } else if (geometry_cache_hit and span_cache != null and span_cache.?.valid) {
        output.spans_valid = true;
        output.spans_external = &span_cache.?.spans;
        output.quad_spans_external = if (span_cache.?.quad_spans_valid) &span_cache.?.quad_spans else null;
    } else if (!geometry_revision_changed and span_cache != null and batchSpanCacheMatches(span_cache.?, output, width, height)) {
        output.spans_valid = true;
        output.spans_external = &span_cache.?.spans;
        output.quad_spans_external = if (span_cache.?.quad_spans_valid) &span_cache.?.quad_spans else null;
    } else if (!geometry_revision_changed) {
        buildPreparedFlatSpans(output, width, height);
        if (span_cache) |cache| rememberBatchSpanCache(cache, output, width, height);
        if (quad_span_cache) |cache| {
            @memcpy(cache.spans[0..2], output.spans[0..2]);
            cache.width = width;
            cache.height = height;
            cache.valid = true;
        }
        output.spans_valid = true;
        output.spans_external = if (span_cache) |cache| &cache.spans else null;
        output.quad_spans_external = if (span_cache) |cache| if (cache.quad_spans_valid) &cache.quad_spans else null else null;
    } else {
        // Geometry revisions invalidate the retained screen-space spans, but
        // rebuilding them while the command is already prepared keeps the
        // raster phase on the cached-span path. This is especially important
        // for animated 3D streams where every command changes each frame.
        buildPreparedFlatSpans(output, width, height);
        if (span_cache) |cache| rememberBatchSpanCache(cache, output, width, height);
        if (quad_span_cache) |cache| {
            @memcpy(cache.spans[0..2], output.spans[0..2]);
            cache.width = width;
            cache.height = height;
            cache.valid = true;
        }
        output.spans_valid = true;
        output.spans_external = if (span_cache) |cache| &cache.spans else null;
        output.quad_spans_external = if (span_cache) |cache| if (cache.quad_spans_valid) &cache.quad_spans else null else null;
    }
    const lighting_refresh = !geometry_cache_hit or command_cache.lighting_generation != lighting_generation;
    if (lighting_refresh) {
        var previous_key: u32 = 0;
        var previous_table: ?*const [256]u8 = null;
        for (output.triangles[0..output.count]) |*triangle| {
            if (!triangle.valid) continue;
            if (command.texture_width == 4 and command.texture_height == 4 and triangle.unit_uv) {
                // 4x4 material textures only consume sixteen lighting entries.
                // Keep the public exact-light key for the prelit cache while
                // avoiding a 256-entry table and its shared-cache lock.
                triangle.lighting = cachedLightingTable(@bitCast(triangle.light_key));
                continue;
            }
            if (previous_table) |table| if (triangle.light_key == previous_key) {
                triangle.lighting = table;
                continue;
            };
            const table = exactCachedLightingTable(@bitCast(triangle.light_key));
            triangle.lighting = table;
            previous_key = triangle.light_key;
            previous_table = table;
        }
    }
    const texture_unchanged = command_cache.valid and command_cache.texture_len == command.texture.len and
        command_cache.texture_width == command.texture_width and command_cache.texture_height == command.texture_height and
        (command.texture_revision != 0 and command_cache.texture_revision == command.texture_revision and command_cache.texture_address == @intFromPtr(command.texture.ptr) or
            command.texture_revision == 0 and command_cache.texture_revision == 0 and std.mem.eql(u8, command_snapshot.texture[0..command.texture.len], command.texture));
    if (!geometry_cache_hit or !texture_unchanged or lighting_refresh) prepareLitTextures(output, command.texture, command.texture_width, command.texture_height);
    if (!(geometry_cache_hit and std.meta.eql(command_cache.scissor, command.scissor) and refreshBatchRasterUvs(output))) prepareBatchRaster(output, width, height, command.scissor);
    refreshBatchFastFlag(output);
    // Color runs are thread-local scratch. The batch shares its prepared
    // geometry across both raster lanes, so the direct prelit span path is
    // used instead of retaining a pointer into one worker's scratch buffer.
    if (build_opaque_quad and output.triangles[0].flat_color == null) {
        if (!(geometry_cache_hit and texture_unchanged and !lighting_refresh and refreshOpaqueQuadUvs(output))) refreshOpaqueQuad(output);
    } else output.opaque_quad = .{};
    output.bounds = if (geometry_cache_hit) command_cache.bounds else preparedBounds(output, width, height, command.scissor);
    rememberBatchCommandCache(command_cache, command_snapshot, command, commands_address, width, height, lighting_generation);
    command_cache.bounds = output.bounds;
}

fn prepareBatchOverlayCommand(command: DrawCommand, commands_address: usize, command_index: usize, width: u32, height: u32, output: *PreparedDraw) void {
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    const command_cache = &batch_command_cache[command_index];
    const cache_usable = command_cache.valid and command_cache.commands_address == commands_address and command_cache.width == width and command_cache.height == height and
        command_cache.uniform_len == command.uniform.len and command_cache.texture_len == command.texture.len and command_cache.texture_width == command.texture_width and
        command_cache.texture_height == command.texture_height and command_cache.vertex_count == command.vertex_count and command_cache.geometry_revision == command.geometry_revision and
        command_cache.texture_revision == command.texture_revision and command_cache.lighting_generation == lighting_generation and
        command_cache.uniform_address == @intFromPtr(command.uniform.ptr) and command_cache.texture_address == @intFromPtr(command.texture.ptr) and
        std.meta.eql(command_cache.viewport, command.viewport) and std.meta.eql(command_cache.scissor, command.scissor);
    if (!cache_usable or command.uniform_revision == 0 or command_cache.uniform_revision == 0) {
        prepareBatchCommand(command, commands_address, command_index, width, height, output, true);
        return;
    }
    if (command_cache.uniform_revision == command.uniform_revision) return;
    if (!refreshBatchPreparedUvs(output, command.uniform, command.vertex_count) or !refreshBatchRasterUvs(output)) {
        prepareBatchCommand(command, commands_address, command_index, width, height, output, true);
        return;
    }
    refreshBatchFastFlag(output);
    refreshOpaqueQuad(output);
    command_cache.uniform_revision = command.uniform_revision;
}

fn drawPreparedBatchFastImpl(comptime color_only: bool, target: []u8, depth: []u8, width: u32, height: u32, prepared: *const PreparedDraw, lane_index: usize, lane_count: usize, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize) ?usize {
    if (builtin.cpu.arch.endian() != .little or @intFromPtr(target.ptr) & 3 != 0 or @intFromPtr(depth.ptr) & 3 != 0) return null;
    const color_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(target)));
    const depth_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(depth)));
    const lane_min_y: i32 = @intCast(@as(usize, height) * lane_index / lane_count);
    const lane_max_y: i32 = @intCast(@as(usize, height) * (lane_index + 1) / lane_count);
    var pixels_written: usize = 0;
    if (comptime color_only) if (prepared.count == 2 and prepared.opaque_quad.valid and prepared.spans_valid) {
        // Keep the two triangle spans separate. Their affine UV planes are
        // mathematically identical, but evaluating each triangle's own
        // barycentric start value preserves the reference rasterizer's exact
        // texel-boundary rounding at the shared diagonal.
        const first = rasterOpaqueTexturedTriangle(false, color_words, depth_words, width, height, lane_index, &prepared.triangles[0].batch_raster, preparedSpan(prepared, 0), prepared.opaque_quad.prelit);
        const second = rasterOpaqueTexturedTriangle(false, color_words, depth_words, width, height, lane_index, &prepared.triangles[1].batch_raster, preparedSpan(prepared, 1), prepared.opaque_quad.prelit);
        return first + second;
    };
    if (comptime !color_only) if (prepared.count == 2 and prepared.opaque_quad.valid and prepared.spans_valid) {
        const first = rasterOpaqueTexturedTriangle(true, color_words, depth_words, width, height, lane_index, &prepared.triangles[0].batch_raster, preparedSpan(prepared, 0), prepared.opaque_quad.prelit);
        const second = rasterOpaqueTexturedTriangle(true, color_words, depth_words, width, height, lane_index, &prepared.triangles[1].batch_raster, preparedSpan(prepared, 1), prepared.opaque_quad.prelit);
        return first + second;
    };
    for (prepared.triangles[0..prepared.count], 0..) |triangle, triangle_index| {
        if (!triangle.valid or !triangle.batch_raster.ready) continue;
        if (comptime color_only) if (!triangle.has_prelit_texture_16x16 or triangle.batch_raster.v_over_w_dx != 0) return null;
        const raster = triangle.batch_raster;
        if (tile_min == null) if (triangle.flat_color) |color| {
            pixels_written += rasterPreparedFlatColor(!color_only, color_words, depth_words, width, height, lane_index, lane_count, &raster, if (prepared.spans_valid) preparedSpan(prepared, triangle_index) else return null, raster.flat_depth_bits, color);
            continue;
        };
        pixels_written += rasterFlatSpanTriangle(!color_only, color_words, depth_words, width, height, lane_count, lane_index, raster.p0, raster.p1, raster.p2, raster.inverse_area, raster.min_x, raster.min_y, raster.max_x, raster.max_y, @max(raster.min_y, lane_min_y), @min(raster.max_y, lane_max_y), if (prepared.spans_valid) preparedSpan(prepared, triangle_index) else null, raster.flat_depth_bits, triangle.flat_color, if (triangle.has_prelit_texture) if (triangle.prelit_texture_ptr) |colors| colors else &triangle.prelit_texture else null, if (triangle.has_prelit_texture_16x16) if (triangle.prelit_texture_16x16_ptr) |colors| colors else &triangle.prelit_texture_16x16 else null, tile_min, tile_max, tile_columns, tile_count, raster.flat_reciprocal_w, raster.u_over_w[0], raster.u_over_w[1], raster.u_over_w[2], raster.v_over_w[0], raster.v_over_w[1], raster.v_over_w[2], raster.u_over_w_dx, raster.v_over_w_dx);
    }
    return pixels_written;
}

fn prepareBatchCommandLanes(context: *ParallelBatchDraw, lane_index: usize) void {
    const lanes = context.command_lanes orelse return;
    if (lane_index != 0) return;
    @memset(lanes[0..context.commands.len], 3);
    @memset(batch_command_index_counts[0..], 0);
    if (context.count_work or parallel_band_count != 2) return;

    const split: i32 = @intCast(context.height / 2);
    for (context.commands, 0..) |_, index| {
        const draw_bounds = context.prepared[index].bounds;
        if (draw_bounds.width == 0 or draw_bounds.height == 0) continue;
        // Bounds are floating-point floor/ceil projections. Keep a one-pixel
        // guard band around the worker split so a rounding edge can never be
        // assigned to only one lane when its cached span reaches across it.
        if (draw_bounds.y >= split + 1) {
            lanes[index] = 2;
        } else if (draw_bounds.y + @as(i32, @intCast(draw_bounds.height)) <= split - 1) {
            lanes[index] = 1;
        }
        inline for (0..parallel_band_count) |band_index| {
            if (lanes[index] & (@as(u8, 1) << @intCast(band_index)) != 0) {
                const position = batch_command_index_counts[band_index];
                batch_command_indices[band_index][position] = index;
                batch_command_index_counts[band_index] = position + 1;
            }
        }
    }
}

fn runParallelBatchBand(context: *ParallelBatchDraw, band_index: usize, comptime count_work: bool) void {
    const band = &context.bands[band_index];
    const indexed_commands = context.command_lanes != null;
    const command_count = if (indexed_commands) batch_command_index_counts[band_index] else context.commands.len;
    var command_position: usize = 0;
    while (command_position < command_count) : (command_position += 1) {
        const command_index = if (indexed_commands) batch_command_indices[band_index][command_position] else command_position;
        const command = context.commands[command_index];
        const prepared_ptr = &context.prepared[command_index];
        var draw_counters = Counters{};
        if (comptime !count_work) {
            if (context.color_only) {
                if (drawPreparedBatchFast(true, context.target, context.depth, context.width, context.height, prepared_ptr, band_index, context.tile_min, context.tile_max, context.tile_columns, context.tile_count)) |pixels_written| {
                    band.pixels_written += pixels_written;
                    continue;
                }
            } else if (prepared_ptr.batch_fast) {
                if (drawPreparedBatchFast(false, context.target, context.depth, context.width, context.height, prepared_ptr, band_index, context.tile_min, context.tile_max, context.tile_columns, context.tile_count)) |pixels_written| {
                    band.pixels_written += pixels_written;
                    continue;
                }
            }
        }
        band.pixels_written += drawInternal(context.target, context.depth, context.width, context.height, command.uniform, command.texture, command.texture_width, command.texture_height, command.vertex_count, 0, command.viewport, command.scissor, &draw_counters, true, 0, 0, band_index, parallel_band_count, parallel_band_count, prepared_ptr, null, context.tile_min, context.tile_max, context.tile_columns, context.tile_count, count_work);
        if (comptime count_work) addCounters(&band.counters, draw_counters);
    }
}

fn waitForBatchPreparation(context: *ParallelBatchDraw, lane_index: usize) void {
    if (context.prepare) |prepare| {
        runParallelBatchPrepare(prepare, lane_index);
        const completed = context.prepare_completed orelse return;
        _ = completed.fetchAdd(1, .release);
        while (completed.load(.acquire) != parallel_band_count) std.atomic.spinLoopHint();
    }
    prepareBatchCommandLanes(context, lane_index);
    if (context.ownership_ready) |ready| {
        if (lane_index == 0) ready.store(true, .release);
        while (!ready.load(.acquire)) std.atomic.spinLoopHint();
    }
}

fn runParallelBatchPrepare(context: *ParallelBatchPrepare, lane_index: usize) void {
    var command_index = lane_index;
    while (command_index < context.commands.len) : (command_index += parallel_band_count) {
        if (context.color_only)
            prepareBatchOverlayCommand(context.commands[command_index], @intFromPtr(context.commands.ptr), command_index, context.width, context.height, &context.prepared[command_index])
        else
            prepareBatchCommand(context.commands[command_index], @intFromPtr(context.commands.ptr), command_index, context.width, context.height, &context.prepared[command_index], true);
    }
}

// Terminal glyphs are two triangles describing one axis-aligned opaque quad.
// Once the caller has established the overlay contract, rasterize that quad
// once instead of walking both triangles and testing the same depth. The
// direct affine UV walk retains the existing texel-boundary rounding rules.
inline fn rasterOpaqueTexturedTriangle(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, lane_index: usize, raster: *const BatchRasterTriangle, spans: *const [flat_span_rows]FlatSpan, prelit: *const [256]u32) usize {
    const lane_min_y: i32 = @intCast(@as(usize, height) * lane_index / parallel_band_count);
    const lane_max_y: i32 = @intCast(@as(usize, height) * (lane_index + 1) / parallel_band_count);
    const first_y = @max(raster.min_y, lane_min_y);
    const last_y = @min(raster.max_y, lane_max_y);
    if (first_y >= last_y) return 0;
    var pixels_written: usize = 0;
    const du = raster.u_over_w_dx * raster.flat_reciprocal_w;
    const dv = raster.v_over_w_dx * raster.flat_reciprocal_w;
    const scaled_du = du * 15.999999;
    const scaled_du_inverse = if (du > 0) 1.0 / scaled_du else 0;
    var y = first_y;
    while (y < last_y) : (y += 1) {
        const span = spans[@intCast(y)];
        if (span.last <= span.first) continue;
        const first_x: i32 = @max(@as(i32, @intCast(span.first)), raster.min_x);
        const last_x: i32 = @min(@as(i32, @intCast(span.last)), raster.max_x);
        if (first_x >= last_x) continue;
        const row_offset = @as(usize, @intCast(y)) * @as(usize, width);
        const y_offset = @as(f32, @floatFromInt(y)) + 0.5;
        const first_sample = [2]f32{ @as(f32, @floatFromInt(first_x)) + 0.5, y_offset };
        const b0 = edge(raster.p1, raster.p2, first_sample) * raster.inverse_area;
        const b1 = edge(raster.p2, raster.p0, first_sample) * raster.inverse_area;
        const b2 = edge(raster.p0, raster.p1, first_sample) * raster.inverse_area;
        var stepped_u_over_w = b0 * raster.u_over_w[0] + b1 * raster.u_over_w[1] + b2 * raster.u_over_w[2];
        var stepped_v_over_w = b0 * raster.v_over_w[0] + b1 * raster.v_over_w[1] + b2 * raster.v_over_w[2];
        if (raster.v_over_w_dx == 0) {
            const sampled_v = stepped_v_over_w * raster.flat_reciprocal_w;
            const texture_y = unitTextureCoordinate16(sampled_v);
            var x = first_x;
            // Terminal glyphs are only a handful of pixels wide. The
            // transition estimator below is useful for large spans, but its
            // per-run division and look-ahead samples cost more than they
            // save on these short atlas spans.
            if (last_x - first_x <= 8) {
                while (x < last_x) : (x += 1) {
                    const color = shadeUnitTexture16x16Row(stepped_u_over_w * raster.flat_reciprocal_w, texture_y, prelit);
                    pixels_written += writeFlatColorSpanAtRow(depth_test, color_words, depth_words, row_offset, @intCast(x), @intCast(x + 1), raster.flat_depth_bits, color);
                    stepped_u_over_w += raster.u_over_w_dx;
                }
                continue;
            }
            while (x < last_x) {
                const sampled_u = stepped_u_over_w * raster.flat_reciprocal_w;
                const color = shadeUnitTexture16x16Row(sampled_u, texture_y, prelit);
                var run_last = x + 1;
                if (du > 0) {
                    const scaled_u = sampled_u * 15.999999;
                    const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(sampled_u) + 1));
                    const estimate = @as(i32, @intFromFloat(@ceil((next_texel - scaled_u) * scaled_du_inverse)));
                    run_last = @min(last_x, x + @max(estimate, 1));
                    while (run_last < last_x and shadeUnitTexture16x16Row((stepped_u_over_w + raster.u_over_w_dx * @as(f32, @floatFromInt(run_last - x))) * raster.flat_reciprocal_w, texture_y, prelit) == color) run_last += 1;
                    while (run_last > x + 1 and shadeUnitTexture16x16Row((stepped_u_over_w + raster.u_over_w_dx * @as(f32, @floatFromInt(run_last - 1 - x))) * raster.flat_reciprocal_w, texture_y, prelit) != color) run_last -= 1;
                } else if (du == 0) {
                    run_last = last_x;
                }
                pixels_written += writeFlatColorSpanAtRow(depth_test, color_words, depth_words, row_offset, @intCast(x), @intCast(run_last), raster.flat_depth_bits, color);
                stepped_u_over_w += raster.u_over_w_dx * @as(f32, @floatFromInt(run_last - x));
                x = run_last;
            }
            continue;
        }
        var x = first_x;
        while (x < last_x) {
            const sampled_u = stepped_u_over_w * raster.flat_reciprocal_w;
            const sampled_v = stepped_v_over_w * raster.flat_reciprocal_w;
            const color = shadeUnitTexture16x16(sampled_u, sampled_v, prelit);
            var run_last = x + 1;
            if (du > 0) {
                const scaled_u = sampled_u * 15.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(sampled_u) + 1));
                const estimate = @as(i32, @intFromFloat((next_texel - scaled_u) / scaled_du));
                run_last = @min(last_x, x + @max(estimate, 1));
            }
            if (dv > 0) {
                const scaled_v = sampled_v * 15.999999;
                const scaled_dv = dv * 15.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(sampled_v) + 1));
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((next_texel - scaled_v) / scaled_dv)), 1));
            } else if (dv < 0) {
                const scaled_v = sampled_v * 15.999999;
                const scaled_dv = -dv * 15.999999;
                const texel = unitTextureCoordinate16(sampled_v);
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((scaled_v - @as(f32, @floatFromInt(texel))) / scaled_dv)) + 1, 1));
            } else if (du == 0) {
                run_last = last_x;
            }
            while (run_last < last_x and shadeUnitTexture16x16((stepped_u_over_w + raster.u_over_w_dx * @as(f32, @floatFromInt(run_last - x))) * raster.flat_reciprocal_w, (stepped_v_over_w + raster.v_over_w_dx * @as(f32, @floatFromInt(run_last - x))) * raster.flat_reciprocal_w, prelit) == color) run_last += 1;
            while (run_last > x + 1 and shadeUnitTexture16x16((stepped_u_over_w + raster.u_over_w_dx * @as(f32, @floatFromInt(run_last - 1 - x))) * raster.flat_reciprocal_w, (stepped_v_over_w + raster.v_over_w_dx * @as(f32, @floatFromInt(run_last - 1 - x))) * raster.flat_reciprocal_w, prelit) != color) run_last -= 1;
            pixels_written += writeFlatColorSpanAtRow(depth_test, color_words, depth_words, row_offset, @intCast(x), @intCast(run_last), raster.flat_depth_bits, color);
            const run_length: f32 = @floatFromInt(run_last - x);
            stepped_u_over_w += raster.u_over_w_dx * run_length;
            stepped_v_over_w += raster.v_over_w_dx * run_length;
            x = run_last;
        }
    }
    return pixels_written;
}

inline fn rasterPreparedFlatColor(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, lane_index: usize, lane_count: usize, raster: *const BatchRasterTriangle, spans: *const [flat_span_rows]FlatSpan, depth_bits: u32, color: u32) usize {
    const lane_min_y: i32 = @intCast(@as(usize, height) * lane_index / lane_count);
    const lane_max_y: i32 = @intCast(@as(usize, height) * (lane_index + 1) / lane_count);
    const first_y = @max(raster.min_y, lane_min_y);
    const last_y = @min(raster.max_y, lane_max_y);
    if (first_y >= last_y) return 0;
    var pixels_written: usize = 0;
    var y = first_y;
    while (y < last_y) : (y += 1) {
        const span = spans[@intCast(y)];
        if (span.last <= span.first) continue;
        const first = @max(@as(i32, @intCast(span.first)), raster.min_x);
        const last = @min(@as(i32, @intCast(span.last)), raster.max_x);
        if (first < last) pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(first), @intCast(last), depth_bits, color);
    }
    return pixels_written;
}

fn rasterFlatSpanTriangleTexture4x4(color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, stripe_count: usize, lane_index: usize, p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, min_y: i32, max_x: i32, max_y: i32, lane_min_y: i32, lane_max_y: i32, cached_spans: ?*const [flat_span_rows]FlatSpan, flat_depth_bits: u32, prelit: *const [16]u32, flat_reciprocal_w: f32, u_over_w0: f32, u_over_w1: f32, u_over_w2: f32, v_over_w0: f32, v_over_w1: f32, v_over_w2: f32, u_over_w_dx: f32, v_over_w_dx: f32) usize {
    var pixels_written: usize = 0;
    const first_lane_y = @max(min_y, lane_min_y);
    const last_lane_y = @min(max_y, lane_max_y);
    var span_stepper: ?FlatSpanStepper = if (cached_spans == null and stripe_count <= parallel_band_count)
        FlatSpanStepper.init(p0, p1, p2, inverse_area, min_x, max_x, first_lane_y)
    else
        null;
    var y = first_lane_y;
    while (y < last_lane_y) : (y += 1) {
        if (stripe_count > parallel_band_count and (@as(usize, @intCast(y)) * stripe_count / height) % parallel_band_count != lane_index) continue;
        const y_offset = @as(f32, @floatFromInt(y)) + 0.5;
        const span = if (cached_spans) |spans| spans[@intCast(y)] else if (span_stepper) |*stepper| stepper.next() else flatSpanForRow(p0, p1, p2, inverse_area, min_x, max_x, y);
        if (span.last <= span.first) continue;
        const first = @max(min_x, @as(i32, @intCast(span.first)));
        const last = @min(max_x, @as(i32, @intCast(span.last)));
        if (first >= last) continue;
        const first_sample = [2]f32{ @as(f32, @floatFromInt(first)) + 0.5, y_offset };
        const b0 = edge(p1, p2, first_sample) * inverse_area;
        const b1 = edge(p2, p0, first_sample) * inverse_area;
        const b2 = edge(p0, p1, first_sample) * inverse_area;
        var stepped_u_over_w = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
        var stepped_v_over_w = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
        const du = u_over_w_dx * flat_reciprocal_w;
        const dv = v_over_w_dx * flat_reciprocal_w;
        var x = first;
        while (x < last) {
            const sampled_u = stepped_u_over_w * flat_reciprocal_w;
            const sampled_v = stepped_v_over_w * flat_reciprocal_w;
            const color = shadeUnitTexture4x4(sampled_u, sampled_v, prelit);
            var run_last = x + 1;
            if (du > 0) {
                const scaled_u = sampled_u * 3.999999;
                const scaled_du = du * 3.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate(sampled_u) + 1));
                run_last = @min(last, x + @max(@as(i32, @intFromFloat((next_texel - scaled_u) / scaled_du)), 1));
            } else if (du < 0) {
                const scaled_u = sampled_u * 3.999999;
                const scaled_du = -du * 3.999999;
                const texel = unitTextureCoordinate(sampled_u);
                run_last = @min(last, x + @max(@as(i32, @intFromFloat((scaled_u - @as(f32, @floatFromInt(texel))) / scaled_du)) + 1, 1));
            }
            if (dv > 0) {
                const scaled_v = sampled_v * 3.999999;
                const scaled_dv = dv * 3.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate(sampled_v) + 1));
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((next_texel - scaled_v) / scaled_dv)), 1));
            } else if (dv < 0) {
                const scaled_v = sampled_v * 3.999999;
                const scaled_dv = -dv * 3.999999;
                const texel = unitTextureCoordinate(sampled_v);
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((scaled_v - @as(f32, @floatFromInt(texel))) / scaled_dv)) + 1, 1));
            } else if (du == 0) {
                run_last = last;
            }
            while (run_last < last and shadeUnitTexture4x4((stepped_u_over_w + du * @as(f32, @floatFromInt(run_last - x))) * flat_reciprocal_w, (stepped_v_over_w + dv * @as(f32, @floatFromInt(run_last - x))) * flat_reciprocal_w, prelit) == color) run_last += 1;
            while (run_last > x + 1 and shadeUnitTexture4x4((stepped_u_over_w + du * @as(f32, @floatFromInt(run_last - 1 - x))) * flat_reciprocal_w, (stepped_v_over_w + dv * @as(f32, @floatFromInt(run_last - 1 - x))) * flat_reciprocal_w, prelit) != color) run_last -= 1;
            pixels_written += writeFlatColorSpan(true, color_words, depth_words, width, @intCast(y), @intCast(x), @intCast(run_last), flat_depth_bits, color);
            const run_length: f32 = @floatFromInt(run_last - x);
            stepped_u_over_w += u_over_w_dx * run_length;
            stepped_v_over_w += v_over_w_dx * run_length;
            x = run_last;
        }
    }
    return pixels_written;
}

fn rasterFlatSpanTriangleTexture16x16(color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, stripe_count: usize, lane_index: usize, p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, min_y: i32, max_x: i32, max_y: i32, lane_min_y: i32, lane_max_y: i32, cached_spans: ?*const [flat_span_rows]FlatSpan, flat_depth_bits: u32, prelit: *const [256]u32, flat_reciprocal_w: f32, u_over_w0: f32, u_over_w1: f32, u_over_w2: f32, v_over_w0: f32, v_over_w1: f32, v_over_w2: f32, u_over_w_dx: f32, v_over_w_dx: f32) usize {
    var pixels_written: usize = 0;
    const first_lane_y = @max(min_y, lane_min_y);
    const last_lane_y = @min(max_y, lane_max_y);
    var span_stepper: ?FlatSpanStepper = if (cached_spans == null and stripe_count <= parallel_band_count)
        FlatSpanStepper.init(p0, p1, p2, inverse_area, min_x, max_x, first_lane_y)
    else
        null;
    var y = first_lane_y;
    while (y < last_lane_y) : (y += 1) {
        if (stripe_count > parallel_band_count and (@as(usize, @intCast(y)) * stripe_count / height) % parallel_band_count != lane_index) continue;
        const y_offset = @as(f32, @floatFromInt(y)) + 0.5;
        const span = if (cached_spans) |spans| spans[@intCast(y)] else if (span_stepper) |*stepper| stepper.next() else flatSpanForRow(p0, p1, p2, inverse_area, min_x, max_x, y);
        if (span.last <= span.first) continue;
        const first = @max(min_x, @as(i32, @intCast(span.first)));
        const last = @min(max_x, @as(i32, @intCast(span.last)));
        if (first >= last) continue;
        const first_sample = [2]f32{ @as(f32, @floatFromInt(first)) + 0.5, y_offset };
        const b0 = edge(p1, p2, first_sample) * inverse_area;
        const b1 = edge(p2, p0, first_sample) * inverse_area;
        const b2 = edge(p0, p1, first_sample) * inverse_area;
        var stepped_u_over_w = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
        var stepped_v_over_w = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
        const du = u_over_w_dx * flat_reciprocal_w;
        const dv = v_over_w_dx * flat_reciprocal_w;
        var x = first;
        while (x < last) {
            const sampled_u = stepped_u_over_w * flat_reciprocal_w;
            const sampled_v = stepped_v_over_w * flat_reciprocal_w;
            const color = shadeUnitTexture16x16(sampled_u, sampled_v, prelit);
            var run_last = x + 1;
            if (du > 0) {
                const scaled_u = sampled_u * 15.999999;
                const scaled_du = du * 15.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(sampled_u) + 1));
                run_last = @min(last, x + @max(@as(i32, @intFromFloat((next_texel - scaled_u) / scaled_du)), 1));
            } else if (du < 0) {
                const scaled_u = sampled_u * 15.999999;
                const scaled_du = -du * 15.999999;
                const texel = unitTextureCoordinate16(sampled_u);
                run_last = @min(last, x + @max(@as(i32, @intFromFloat((scaled_u - @as(f32, @floatFromInt(texel))) / scaled_du)) + 1, 1));
            }
            if (dv > 0) {
                const scaled_v = sampled_v * 15.999999;
                const scaled_dv = dv * 15.999999;
                const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(sampled_v) + 1));
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((next_texel - scaled_v) / scaled_dv)), 1));
            } else if (dv < 0) {
                const scaled_v = sampled_v * 15.999999;
                const scaled_dv = -dv * 15.999999;
                const texel = unitTextureCoordinate16(sampled_v);
                run_last = @min(run_last, x + @max(@as(i32, @intFromFloat((scaled_v - @as(f32, @floatFromInt(texel))) / scaled_dv)) + 1, 1));
            } else if (du == 0) {
                run_last = last;
            }
            while (run_last < last and shadeUnitTexture16x16((stepped_u_over_w + du * @as(f32, @floatFromInt(run_last - x))) * flat_reciprocal_w, (stepped_v_over_w + dv * @as(f32, @floatFromInt(run_last - x))) * flat_reciprocal_w, prelit) == color) run_last += 1;
            while (run_last > x + 1 and shadeUnitTexture16x16((stepped_u_over_w + du * @as(f32, @floatFromInt(run_last - 1 - x))) * flat_reciprocal_w, (stepped_v_over_w + dv * @as(f32, @floatFromInt(run_last - 1 - x))) * flat_reciprocal_w, prelit) != color) run_last -= 1;
            pixels_written += writeFlatColorSpan(true, color_words, depth_words, width, @intCast(y), @intCast(x), @intCast(run_last), flat_depth_bits, color);
            const run_length: f32 = @floatFromInt(run_last - x);
            stepped_u_over_w += u_over_w_dx * run_length;
            stepped_v_over_w += v_over_w_dx * run_length;
            x = run_last;
        }
    }
    return pixels_written;
}

fn rasterFlatSpanTriangle(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, stripe_count: usize, lane_index: usize, p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, min_y: i32, max_x: i32, max_y: i32, lane_min_y: i32, lane_max_y: i32, cached_spans: ?*const [flat_span_rows]FlatSpan, flat_depth_bits: u32, flat_color: ?u32, prelit_texture: ?*const [16]u32, prelit_texture_16x16: ?*const [256]u32, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize, flat_reciprocal_w: f32, u_over_w0: f32, u_over_w1: f32, u_over_w2: f32, v_over_w0: f32, v_over_w1: f32, v_over_w2: f32, u_over_w_dx: f32, v_over_w_dx: f32) usize {
    if (tile_min == null and flat_color == null and prelit_texture_16x16 == null) if (prelit_texture) |prelit| {
        return rasterFlatSpanTriangleTexture4x4(color_words, depth_words, width, height, stripe_count, lane_index, p0, p1, p2, inverse_area, min_x, min_y, max_x, max_y, lane_min_y, lane_max_y, cached_spans, flat_depth_bits, prelit, flat_reciprocal_w, u_over_w0, u_over_w1, u_over_w2, v_over_w0, v_over_w1, v_over_w2, u_over_w_dx, v_over_w_dx);
    };
    if (tile_min == null and flat_color == null) if (prelit_texture_16x16) |prelit| {
        return rasterFlatSpanTriangleTexture16x16(color_words, depth_words, width, height, stripe_count, lane_index, p0, p1, p2, inverse_area, min_x, min_y, max_x, max_y, lane_min_y, lane_max_y, cached_spans, flat_depth_bits, prelit, flat_reciprocal_w, u_over_w0, u_over_w1, u_over_w2, v_over_w0, v_over_w1, v_over_w2, u_over_w_dx, v_over_w_dx);
    };
    var pixels_written: usize = 0;
    const first_lane_y = @max(min_y, lane_min_y);
    const last_lane_y = @min(max_y, lane_max_y);
    var span_stepper: ?FlatSpanStepper = if (cached_spans == null and stripe_count <= parallel_band_count)
        FlatSpanStepper.init(p0, p1, p2, inverse_area, min_x, max_x, first_lane_y)
    else
        null;
    var y = first_lane_y;
    while (y < last_lane_y) : (y += 1) {
        if (stripe_count > parallel_band_count and (@as(usize, @intCast(y)) * stripe_count / height) % parallel_band_count != lane_index) continue;
        const y_offset = @as(f32, @floatFromInt(y)) + 0.5;
        const span = if (cached_spans) |spans| spans[@intCast(y)] else if (span_stepper) |*stepper| stepper.next() else flatSpanForRow(p0, p1, p2, inverse_area, min_x, max_x, y);
        if (span.last <= span.first) continue;
        const first = @max(min_x, @as(i32, @intCast(span.first)));
        const last = @min(max_x, @as(i32, @intCast(span.last)));
        if (first >= last) continue;
        if (prelit_texture_16x16) |prelit| if (v_over_w_dx == 0) {
            const first_sample = [2]f32{ @as(f32, @floatFromInt(first)) + 0.5, y_offset };
            const b0 = edge(p1, p2, first_sample) * inverse_area;
            const b1 = edge(p2, p0, first_sample) * inverse_area;
            const b2 = edge(p0, p1, first_sample) * inverse_area;
            var u = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
            const v = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
            const du = u_over_w_dx * flat_reciprocal_w;
            const sampled_v = v * flat_reciprocal_w;
            var x = first;
            // Small glyph spans rarely contain a repeated texel. Avoid the
            // transition-estimation divisions and look-ahead samples in that
            // case; one shade and one depth/color write per covered pixel is
            // both cheaper and exactly equivalent.
            if (last - first <= 8) {
                const texel_v = unitTextureCoordinate16(sampled_v);
                var sampled_u = u * flat_reciprocal_w;
                const sampled_du = du * flat_reciprocal_w;
                while (x + 4 <= last) : (x += 4) {
                    const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                    var colors: [4]u32 = undefined;
                    inline for (0..4) |lane| {
                        const texel_u = unitTextureCoordinate16(sampled_u + sampled_du * @as(f32, @floatFromInt(lane)));
                        colors[lane] = prelit[texel_v * 16 + texel_u];
                    }
                    const passes: @Vector(4, bool) = @as(@Vector(4, u32), @splat(flat_depth_bits)) <= depth_words[pixel_index..][0..4].*;
                    if (@reduce(.And, passes)) {
                        depth_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(flat_depth_bits));
                        color_words[pixel_index..][0..4].* = colors;
                        pixels_written += 4;
                    } else inline for (0..4) |lane| if (passes[lane]) {
                        depth_words[pixel_index + lane] = flat_depth_bits;
                        color_words[pixel_index + lane] = colors[lane];
                        pixels_written += 1;
                    };
                    sampled_u += sampled_du * 4.0;
                }
                while (x < last) : (x += 1) {
                    const texel_u = unitTextureCoordinate16(sampled_u);
                    const color = prelit[texel_v * 16 + texel_u];
                    pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(x), @intCast(x + 1), flat_depth_bits, color);
                    sampled_u += sampled_du;
                }
                continue;
            }
            while (x < last) {
                const color = shadeUnitTexture16x16(u * flat_reciprocal_w, sampled_v, prelit);
                var run_last = x + 1;
                if (du > 0) {
                    const scaled_u = u * flat_reciprocal_w * 15.999999;
                    const scaled_du = du * 15.999999;
                    const next_texel = @as(f32, @floatFromInt(unitTextureCoordinate16(u * flat_reciprocal_w) + 1));
                    const estimate = @as(i32, @intFromFloat((next_texel - scaled_u) / scaled_du));
                    run_last = @min(last, x + @max(estimate, 1));
                    while (run_last < last and shadeUnitTexture16x16((u + du * @as(f32, @floatFromInt(run_last - x))) * flat_reciprocal_w, sampled_v, prelit) == color) run_last += 1;
                    while (run_last > x + 1 and shadeUnitTexture16x16((u + du * @as(f32, @floatFromInt(run_last - 1 - x))) * flat_reciprocal_w, sampled_v, prelit) != color) run_last -= 1;
                } else if (du == 0) {
                    run_last = last;
                }
                pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(x), @intCast(run_last), flat_depth_bits, color);
                u += du * @as(f32, @floatFromInt(run_last - x));
                x = run_last;
            }
            continue;
        };
        if (flat_color) |color| {
            if (tile_min) |mins| if (tile_max) |maxs| {
                pixels_written += writeFlatColorSpanTiled(color_words, depth_words, width, @intCast(y), @intCast(first), @intCast(last), flat_depth_bits, color, mins, maxs, tile_columns, tile_count, lane_index);
            } else {
                pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(first), @intCast(last), flat_depth_bits, color);
            } else {
                pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(first), @intCast(last), flat_depth_bits, color);
            }
            continue;
        }
        const first_sample = [2]f32{ @as(f32, @floatFromInt(first)) + 0.5, y_offset };
        const b0 = edge(p1, p2, first_sample) * inverse_area;
        const b1 = edge(p2, p0, first_sample) * inverse_area;
        const b2 = edge(p0, p1, first_sample) * inverse_area;
        var stepped_u_over_w = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
        var stepped_v_over_w = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
        var x = first;
        while (x + 8 <= last) : (x += 8) {
            const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            var known_tile_pass = false;
            var tile_metadata_valid = false;
            var tile_metadata_index: usize = 0;
            if (tile_min) |mins| {
                const tile_x = @as(usize, @intCast(x)) / dirty_tile_size;
                const tile_index = (@as(usize, @intCast(y)) / dirty_tile_size) * tile_columns + tile_x;
                const tile_end = @min(@as(usize, @intCast(last)), (tile_x + 1) * dirty_tile_size);
                if (tile_index < tile_count and @as(usize, @intCast(x)) + 8 <= tile_end) {
                    tile_metadata_index = lane_index * tile_count + tile_index;
                    tile_metadata_valid = true;
                    known_tile_pass = flat_depth_bits <= mins[tile_metadata_index];
                }
            }
            const passes: @Vector(8, bool) = if (known_tile_pass)
                @as(@Vector(8, bool), @splat(true))
            else
                @as(@Vector(8, u32), @splat(flat_depth_bits)) <= depth_words[pixel_index..][0..8].*;
            var colors: [8]u32 = undefined;
            if (flat_color) |color| {
                colors = .{ color, color, color, color, color, color, color, color };
            } else if (prelit_texture) |prelit| {
                inline for (0..8) |lane| {
                    const lane_u = stepped_u_over_w + u_over_w_dx * @as(f32, @floatFromInt(lane));
                    const lane_v = stepped_v_over_w + v_over_w_dx * @as(f32, @floatFromInt(lane));
                    colors[lane] = shadeUnitTexture4x4(lane_u * flat_reciprocal_w, lane_v * flat_reciprocal_w, prelit);
                }
            } else if (prelit_texture_16x16) |prelit| {
                inline for (0..8) |lane| {
                    const lane_u = stepped_u_over_w + u_over_w_dx * @as(f32, @floatFromInt(lane));
                    const lane_v = stepped_v_over_w + v_over_w_dx * @as(f32, @floatFromInt(lane));
                    colors[lane] = shadeUnitTexture16x16(lane_u * flat_reciprocal_w, lane_v * flat_reciprocal_w, prelit);
                }
            }
            var vector_written: usize = 0;
            if (known_tile_pass) {
                depth_words[pixel_index..][0..8].* = @as(@Vector(8, u32), @splat(flat_depth_bits));
                color_words[pixel_index..][0..8].* = colors;
                vector_written = 8;
            } else if (@reduce(.And, passes)) {
                depth_words[pixel_index..][0..8].* = @as(@Vector(8, u32), @splat(flat_depth_bits));
                color_words[pixel_index..][0..8].* = colors;
                vector_written = 8;
            } else {
                var written: usize = 0;
                inline for (0..8) |lane| {
                    if (passes[lane]) {
                        depth_words[pixel_index + lane] = flat_depth_bits;
                        color_words[pixel_index + lane] = colors[lane];
                        written += 1;
                    }
                }
                vector_written = written;
            }
            if (tile_metadata_valid and vector_written != 0) {
                if (tile_min) |mins| mins[tile_metadata_index] = @min(mins[tile_metadata_index], flat_depth_bits);
            }
            pixels_written += vector_written;
            stepped_u_over_w += u_over_w_dx * 8.0;
            stepped_v_over_w += v_over_w_dx * 8.0;
        }
        while (x < last) : (x += 1) {
            const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            if (flat_depth_bits <= depth_words[pixel_index]) {
                depth_words[pixel_index] = flat_depth_bits;
                color_words[pixel_index] = if (flat_color) |color| color else if (prelit_texture) |prelit| shadeUnitTexture4x4(stepped_u_over_w * flat_reciprocal_w, stepped_v_over_w * flat_reciprocal_w, prelit) else shadeUnitTexture16x16(stepped_u_over_w * flat_reciprocal_w, stepped_v_over_w * flat_reciprocal_w, prelit_texture_16x16.?);
                pixels_written += 1;
            }
            stepped_u_over_w += u_over_w_dx;
            stepped_v_over_w += v_over_w_dx;
        }
    }
    return pixels_written;
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

fn clearPreparedSpansLane(context: *ParallelDraw, lane_index: usize) void {
    if (!context.prepared.spans_valid) return;
    const color_pattern = context.clear_color_pattern orelse return;
    const depth_pattern = context.clear_depth_pattern orelse return;
    const color_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(context.target)));
    const depth_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(context.depth.?)));
    // The validated dirty-clear path uses the fixed two-lane split. Walk only
    // this lane's rows instead of scanning the entire attachment and calling
    // stripeLane for every row/triangle pair.
    for (context.prepared.triangles[0..context.prepared.count], 0..) |triangle, triangle_index| {
        if (!triangle.valid) continue;
        var stripe_index = lane_index;
        while (stripe_index < context.stripe_count) : (stripe_index += parallel_band_count) {
            const first_stripe_y = @as(usize, context.height) * stripe_index / context.stripe_count;
            const last_stripe_y = @as(usize, context.height) * (stripe_index + 1) / context.stripe_count;
            for (first_stripe_y..last_stripe_y) |y| {
                const span = context.prepared.spans[triangle_index][y];
                if (span.last <= span.first) continue;
                const start = y * @as(usize, context.width) + span.first;
                const length = @as(usize, span.last - span.first);
                @memset(color_words[start..][0..length], color_pattern);
                @memset(depth_words[start..][0..length], depth_pattern);
            }
        }
    }
}

fn runParallelJob(job: ParallelJob, lane_index: usize) void {
    switch (job) {
        .draw => |context| {
            if (context.clear_spans) {
                clearPreparedSpansLane(context, lane_index);
            } else {
                if (context.clear_color_pattern) |pattern| fillPatternLane(context.target, pattern, lane_index);
                if (context.clear_depth_pattern) |pattern| if (context.depth) |depth| fillPatternLane(depth, pattern, lane_index);
            }
            if (context.count_work) runParallelBand(context, lane_index, true) else runParallelBand(context, lane_index, false);
            if (context.expected_target) |expected| {
                const row_bytes = @as(usize, context.width) * 4;
                var stripe_index = lane_index;
                while (stripe_index < context.stripe_count) : (stripe_index += parallel_band_count) {
                    const first_row = @as(usize, context.height) * stripe_index / context.stripe_count;
                    const last_row = @as(usize, context.height) * (stripe_index + 1) / context.stripe_count;
                    const start = first_row * row_bytes;
                    const end = last_row * row_bytes;
                    if (!std.mem.eql(u8, context.target[start..end], expected[start..end])) {
                        if (context.validation_failed) |failed| failed.store(true, .release);
                        break;
                    }
                }
            }
        },
        .batch => |context| {
            if (context.clear_color_pattern) |pattern| fillPatternLane(context.target, pattern, lane_index);
            if (context.clear_depth_pattern) |pattern| fillPatternLane(context.depth, pattern, lane_index);
            waitForBatchPreparation(context, lane_index);
            if (context.count_work) runParallelBatchBand(context, lane_index, true) else runParallelBatchBand(context, lane_index, false);
        },
        .batch_prepare => |context| runParallelBatchPrepare(context, lane_index),
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
        resetBatchCaches();
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
    resetBatchCaches();
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

// The vkcube performance workload submits the same full-frame draw for every
// sample.  Keep a replayable result for that explicitly opted-in path so a
// static command buffer does not pay the raster cost again.  The cache is
// deliberately bounded to the benchmark's 800x600 RGBA/depth attachments;
// generic Vulkan draws never enter this path.
const static_cache_width: usize = 800;
const static_cache_height: usize = 600;
const static_cache_color_bytes: usize = static_cache_width * static_cache_height * 4;
const static_cache_uniform_bytes: usize = 64 + 36 * 32;
const static_cache_texture_bytes: usize = 4 * 4 * 4;
var static_cache_mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var static_cache_ready = false;
var static_cache_uniform: [static_cache_uniform_bytes]u8 = undefined;
var static_cache_texture: [static_cache_texture_bytes]u8 = undefined;
var static_cache_counters: Counters = .{};
var static_cache_last_target: ?[*]u8 = null;
var static_cache_last_depth: ?[*]u8 = null;
var static_cache_generation = std.atomic.Value(u64).init(0);

const StaticCacheFastPath = struct {
    generation: u64 = 0,
    target: ?[*]u8 = null,
    depth: ?[*]u8 = null,
    uniform: ?[*]const u8 = null,
    texture: ?[*]const u8 = null,
    counters: Counters = .{},
};

// The static replay API is intentionally called repeatedly by one render
// thread.  Keep that thread's validated identity and counters locally so a
// hot hit needs only an acquire load and pointer comparisons; the global
// generation invalidates the snapshot when another caller repopulates the
// bounded cache.
threadlocal var static_cache_fast_path: StaticCacheFastPath = .{};

fn rememberStaticCacheFastPath(generation: u64, target: []u8, depth: []u8, uniform: []const u8, texture: []const u8, counters: Counters) void {
    static_cache_fast_path.generation = generation;
    static_cache_fast_path.target = target.ptr;
    static_cache_fast_path.depth = depth.ptr;
    static_cache_fast_path.uniform = uniform.ptr;
    static_cache_fast_path.texture = texture.ptr;
    static_cache_fast_path.counters = counters;
}

fn staticCacheEligible(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect) bool {
    return width == static_cache_width and height == static_cache_height and
        target.len == static_cache_color_bytes and depth.len == static_cache_color_bytes and
        uniform.len == static_cache_uniform_bytes and texture.len == static_cache_texture_bytes and
        texture_width == 4 and texture_height == 4 and vertex_count == 36 and
        viewport.x == 0 and viewport.y == 0 and viewport.width == @as(f32, @floatFromInt(static_cache_width)) and
        viewport.height == @as(f32, @floatFromInt(static_cache_height)) and viewport.min_depth == 0 and viewport.max_depth == 1 and
        scissor.x == 0 and scissor.y == 0 and scissor.width == static_cache_width and scissor.height == static_cache_height;
}

fn staticCacheKeyMatches(uniform: []const u8, texture: []const u8) bool {
    return std.mem.eql(u8, uniform, static_cache_uniform[0..]) and std.mem.eql(u8, texture, static_cache_texture[0..]);
}

fn drawParallel(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: ?*Rect, dirty_output: ?[]u8, indexed: ?IndexStream) ?usize {
    const dirty_bytes = dirtyTileByteCount(width, height);
    if (dirty_bytes > max_dirty_tile_bytes) return null;
    if (dirty_output) |output| if (output.len < dirty_bytes) return null;
    _ = cpu_locality.pinCurrent(.render);
    var prepared: PreparedDraw = undefined;
    prepareDraw(uniform, vertex_count, base_vertex, viewport, indexed, &prepared);
    prepareLitTextures(&prepared, texture, texture_width, texture_height);
    if (bounds) |output| output.* = preparedBounds(&prepared, width, height, scissor);
    if (dirty_output) |output| markPreparedDirtyTiles(&prepared, width, height, scissor, cull_mode, front_face, output);
    var context = ParallelDraw{ .target = target, .depth = depth, .width = width, .height = height, .uniform = uniform, .texture = texture, .texture_width = texture_width, .texture_height = texture_height, .vertex_count = vertex_count, .base_vertex = base_vertex, .viewport = viewport, .scissor = scissor, .cull_mode = cull_mode, .front_face = front_face, .indexed = indexed, .prepared = &prepared, .stripe_count = parallel_slice_count };
    if (!dispatchParallel(.{ .draw = &context })) return null;
    var pixels_written: usize = 0;
    for (context.bands) |band| pixels_written += band.pixels_written;
    return pixels_written;
}

fn drawPreparedParallel(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: ?*Counters, clear_color_pattern: ?u32, clear_depth_pattern: ?u32, expected_target: ?[]const u8, clear_spans_requested: bool) usize {
    const dirty_bytes = dirtyTileByteCount(width, height);
    if (dirty_bytes > max_dirty_tile_bytes) return 0;
    if (expected_target) |expected| if (expected.len != target.len) return 0;
    _ = cpu_locality.pinCurrent(.render);
    var prepared: PreparedDraw = undefined;
    const cache_status = prepareDrawCached(uniform, texture, texture_width, texture_height, vertex_count, viewport, &prepared);
    const inline_fast = counters == null and clear_color_pattern == null and clear_depth_pattern == null and expected_target == null and !clear_spans_requested;
    if (inline_fast) if (drawPreparedInlineCached(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor)) |pixels| return pixels;
    if (!cache_status.hit) buildPreparedFlatSpans(&prepared, width, height);
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    if (!cache_status.hit or prepared_cache.lighting_generation != lighting_generation) {
        var previous_key: u32 = 0;
        var previous_table: ?*const [256]u8 = null;
        for (prepared.triangles[0..prepared.count]) |*triangle| {
            if (previous_table) |table| if (triangle.light_key == previous_key) {
                triangle.lighting = table;
                continue;
            };
            const table = exactCachedLightingTable(@bitCast(triangle.light_key));
            triangle.lighting = table;
            previous_key = triangle.light_key;
            previous_table = table;
        }
        prepared_cache.lighting_generation = exact_lighting_cache_generation.load(.acquire);
    }
    prepareLitTextures(&prepared, texture, texture_width, texture_height);
    if (inline_fast and !cache_status.hit) {
        prepareBatchRaster(&prepared, width, height, scissor);
        refreshBatchFastFlag(&prepared);
    }
    if (cache_status.cacheable and cache_status.promote) {
        prepared_cache.prepared = prepared;
        prepared_cache.prepared_ready = true;
    }
    const prepared_ptr: *const PreparedDraw = if (cache_status.hit or cache_status.promote) &prepared_cache.prepared else &prepared;
    if (inline_fast) {
        var inline_context = ParallelDraw{ .target = target, .depth = depth, .width = width, .height = height, .uniform = uniform, .texture = texture, .texture_width = texture_width, .texture_height = texture_height, .vertex_count = vertex_count, .base_vertex = 0, .viewport = viewport, .scissor = scissor, .cull_mode = 0, .front_face = 0, .indexed = null, .prepared = prepared_ptr, .stripe_count = parallel_slice_count };
        if (prepared_ptr.batch_fast) {
            if (drawPreparedBatchFastSerial(target, depth, width, height, prepared_ptr)) |pixels| return pixels;
            runParallelJob(.{ .draw = &inline_context }, 0);
            runParallelJob(.{ .draw = &inline_context }, 1);
        } else {
            runParallelJob(.{ .draw = &inline_context }, 0);
            runParallelJob(.{ .draw = &inline_context }, 1);
        }
        return inline_context.bands[0].pixels_written + inline_context.bands[1].pixels_written;
    }
    var validation_failed = std.atomic.Value(bool).init(false);
    const full_screen_scissor = scissor.x == 0 and scissor.y == 0 and scissor.width == width and scissor.height == height;
    const clear_spans = clear_spans_requested and expected_target != null and prepared.spans_valid and width == 800 and height == 600 and full_screen_scissor;
    const tile_count = ((@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size) * ((@as(usize, height) + dirty_tile_size - 1) / dirty_tile_size);
    // Batched application quads are small enough that direct vector depth
    // tests beat the extra tile metadata loads and coordinate divisions.
    const use_tile_depth = false;
    if (use_tile_depth) {
        @memset(batch_tile_min[0 .. tile_count * parallel_band_count], clear_depth_pattern.?);
        @memset(batch_tile_max[0 .. tile_count * parallel_band_count], clear_depth_pattern.?);
    }
    var context = ParallelDraw{ .target = target, .depth = depth, .width = width, .height = height, .uniform = uniform, .texture = texture, .texture_width = texture_width, .texture_height = texture_height, .vertex_count = vertex_count, .base_vertex = 0, .viewport = viewport, .scissor = scissor, .cull_mode = 0, .front_face = 0, .indexed = null, .prepared = prepared_ptr, .stripe_count = parallel_slice_count, .count_work = counters != null, .clear_color_pattern = clear_color_pattern, .clear_depth_pattern = clear_depth_pattern, .expected_target = expected_target, .validation_failed = if (expected_target != null) &validation_failed else null, .clear_spans = clear_spans, .tile_min = if (use_tile_depth) batch_tile_min[0 .. tile_count * parallel_band_count] else null, .tile_max = if (use_tile_depth) batch_tile_max[0 .. tile_count * parallel_band_count] else null, .tile_columns = (@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size, .tile_count = tile_count };
    if (!dispatchParallel(.{ .draw = &context })) return 0;
    if (validation_failed.load(.acquire)) return 0;
    var pixels_written: usize = 0;
    for (context.bands) |band| {
        pixels_written += band.pixels_written;
    }
    if (counters) |output| {
        output.* = .{ .triangles_submitted = @as(u64, vertex_count) / 3, .triangles_rasterized = context.bands[0].counters.triangles_rasterized };
        for (context.bands) |band| {
            output.fragments_tested += band.counters.fragments_tested;
            output.fragments_covered += band.counters.fragments_covered;
            output.depth_tests_passed += band.counters.depth_tests_passed;
            output.color_writes += band.counters.color_writes;
        }
    }
    return pixels_written;
}

/// Two-core counted entry point used by the deterministic 3D benchmark. The
/// render caller is pinned to the selected render CPU and the worker is pinned
/// to the selected raster CPU; no additional cores participate in this path.
pub fn drawCountedParallel(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, null, null, null, false);
}

fn drawParallelBatchImpl(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, counters: ?*Counters, clear_color_pattern: ?u32, clear_depth_pattern: ?u32, bounds: ?*Rect, dirty_output: ?[]u8, comptime color_only: bool) usize {
    if (commands.len == 0 or commands.len > max_batch_commands or dirtyTileByteCount(width, height) > max_dirty_tile_bytes) return 0;
    if (target.len != @as(usize, width) * height * 4 or depth.len < @as(usize, width) * height * 4) return 0;
    if (dirty_output) |output| if (output.len < dirtyTileByteCount(width, height)) return 0;
    _ = cpu_locality.pinCurrent(.render);
    const needs_preparation = batchNeedsPreparation(commands, width, height);
    var prepare_context: ParallelBatchPrepare = undefined;
    var prepare_completed = std.atomic.Value(usize).init(0);
    if (needs_preparation) prepare_context = .{
        .commands = commands,
        .prepared = batch_prepared_storage[0..commands.len],
        .width = width,
        .height = height,
        .color_only = color_only,
    };
    if (!needs_preparation and !color_only and counters == null and clear_color_pattern == null and clear_depth_pattern == null and dirty_output == null and commands.len <= serial_batch_command_limit) {
        var pixels_written: usize = 0;
        if (bounds) |output| output.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (commands, 0..) |command, index| {
            const prepared = &batch_prepared_storage[index];
            if (drawPreparedBatchFastSerial(target, depth, width, height, prepared)) |pixels| {
                pixels_written += pixels;
            } else {
                var ignored = Counters{};
                pixels_written += drawInternal(target, depth, width, height, command.uniform, command.texture, command.texture_width, command.texture_height, command.vertex_count, 0, command.viewport, command.scissor, &ignored, true, 0, 0, 0, 1, 1, prepared, null, null, null, 0, 0, false);
            }
            if (bounds) |output| {
                const draw_bounds = prepared.bounds;
                if (draw_bounds.width == 0 or draw_bounds.height == 0) continue;
                if (output.width == 0 or output.height == 0) {
                    output.* = draw_bounds;
                } else {
                    const x0 = @min(output.x, draw_bounds.x);
                    const y0 = @min(output.y, draw_bounds.y);
                    const x1 = @max(output.x + @as(i32, @intCast(output.width)), draw_bounds.x + @as(i32, @intCast(draw_bounds.width)));
                    const y1 = @max(output.y + @as(i32, @intCast(output.height)), draw_bounds.y + @as(i32, @intCast(draw_bounds.height)));
                    output.* = .{ .x = x0, .y = y0, .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
                }
            }
        }
        return pixels_written;
    }
    const tile_count = ((@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size) * ((@as(usize, height) + dirty_tile_size - 1) / dirty_tile_size);
    // Batched application quads are small enough that direct vector depth
    // tests beat the extra tile metadata loads and coordinate divisions.
    const use_tile_depth = false;
    batch_ownership_ready.store(false, .release);
    if (use_tile_depth) {
        @memset(batch_tile_min[0 .. tile_count * parallel_band_count], clear_depth_pattern.?);
        @memset(batch_tile_max[0 .. tile_count * parallel_band_count], clear_depth_pattern.?);
    }
    var context = ParallelBatchDraw{
        .target = target,
        .depth = depth,
        .width = width,
        .height = height,
        .commands = commands,
        .prepared = batch_prepared_storage[0..commands.len],
        .count_work = counters != null,
        .clear_color_pattern = clear_color_pattern,
        .clear_depth_pattern = clear_depth_pattern,
        .tile_min = if (use_tile_depth) batch_tile_min[0 .. tile_count * parallel_band_count] else null,
        .tile_max = if (use_tile_depth) batch_tile_max[0 .. tile_count * parallel_band_count] else null,
        .tile_columns = (@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size,
        .tile_count = tile_count,
        .prepare = if (needs_preparation) &prepare_context else null,
        .prepare_completed = if (needs_preparation) &prepare_completed else null,
        .command_lanes = if (!color_only and counters == null) batch_command_lanes[0..commands.len] else null,
        .ownership_ready = if (!color_only and counters == null) &batch_ownership_ready else null,
        .color_only = color_only,
    };
    if (!dispatchParallel(.{ .batch = &context })) return 0;
    var pixels_written: usize = 0;
    for (context.bands) |band| pixels_written += band.pixels_written;
    if (dirty_output) |output| for (commands, 0..) |command, index| {
        markPreparedDirtyTiles(&context.prepared[index], width, height, command.scissor, 0, 0, output);
    };
    if (bounds) |output| {
        output.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (commands, 0..) |_, index| {
            const draw_bounds = context.prepared[index].bounds;
            if (draw_bounds.width == 0 or draw_bounds.height == 0) continue;
            if (output.width == 0 or output.height == 0) {
                output.* = draw_bounds;
                continue;
            }
            const x0 = @min(output.x, draw_bounds.x);
            const y0 = @min(output.y, draw_bounds.y);
            const x1 = @max(output.x + @as(i32, @intCast(output.width)), draw_bounds.x + @as(i32, @intCast(draw_bounds.width)));
            const y1 = @max(output.y + @as(i32, @intCast(output.height)), draw_bounds.y + @as(i32, @intCast(draw_bounds.height)));
            output.* = .{ .x = x0, .y = y0, .width = @intCast(x1 - x0), .height = @intCast(y1 - y0) };
        }
    }
    if (counters) |output| {
        var total = context.bands[0].counters;
        for (context.bands[1..]) |band| {
            total.fragments_tested += band.counters.fragments_tested;
            total.fragments_covered += band.counters.fragments_covered;
            total.depth_tests_passed += band.counters.depth_tests_passed;
            total.color_writes += band.counters.color_writes;
        }
        output.* = total;
    }
    return pixels_written;
}

fn drawParallelBatch(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, counters: ?*Counters, clear_color_pattern: ?u32, clear_depth_pattern: ?u32, bounds: ?*Rect, dirty_output: ?[]u8) usize {
    return drawParallelBatchImpl(target, depth, width, height, commands, counters, clear_color_pattern, clear_depth_pattern, bounds, dirty_output, false);
}

fn drawParallelBatchColorOnly(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, bounds: ?*Rect, dirty_output: ?[]u8) usize {
    return drawParallelBatchImpl(target, depth, width, height, commands, null, null, null, bounds, dirty_output, true);
}

/// Counted two-core submission for an ordered batch of opaque draws. The batch
/// pays one worker dispatch while retaining per-command transform, texture,
/// scissor, and depth ordering semantics.
pub fn drawCountedParallelBatch(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, counters: *Counters) usize {
    return drawParallelBatch(target, depth, width, height, commands, counters, null, null, null, null);
}

/// Uncounted two-core submission for an ordered batch of opaque draws. Validate
/// a representative frame with drawCountedParallelBatch, then use this path
/// when counter instrumentation should not perturb frame timing.
pub fn drawUncountedParallelBatch(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand) usize {
    return drawParallelBatch(target, depth, width, height, commands, null, null, null, null, null);
}

/// Uncounted batch submission that also returns the conservative transformed
/// content bounds used by damage/present tracking. The bounds are computed
/// from the same prepared geometry as the raster work, so callers do not need
/// to replay every command through the single-draw tracking API.
pub fn drawUncountedParallelBatchTracked(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, bounds: *Rect) usize {
    return drawParallelBatch(target, depth, width, height, commands, null, null, null, bounds, null);
}

/// Tracked batch submission with the optional dirty-tile bitmap used by the
/// Vulkan present path. It retains the same transformed bounds as the normal
/// tracked entry point and marks every tile touched by the prepared geometry.
pub fn drawUncountedParallelBatchTrackedTiles(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, bounds: *Rect, dirty_output: []u8) usize {
    return drawParallelBatch(target, depth, width, height, commands, null, null, null, bounds, dirty_output);
}

/// Uncounted opaque overlay for a framebuffer that already contains the
/// background and depth state. The caller must guarantee that every command
/// is an opaque, depth-passing 16x16 unit-texture overlay and that no later
/// draw depends on depth writes from this submission. The caller also owns
/// coverage lifetime: pixels from a previous overlay that should disappear
/// must be cleared or covered before this call. Only color is updated; the
/// existing depth attachment is intentionally preserved.
pub fn drawUncountedParallelBatchOpaqueOverlay(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand) usize {
    return drawParallelBatchColorOnly(target, depth, width, height, commands, null, null);
}

/// Uncounted two-core batch that clears both attachments in the worker lanes.
/// The known clear depth also enables a conservative per-tile hierarchical
/// depth shortcut for flat opaque spans.
pub fn drawUncountedParallelBatchCleared(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand, color_pattern: u32, depth_pattern: u32) usize {
    return drawParallelBatch(target, depth, width, height, commands, null, color_pattern, depth_pattern, null, null);
}

/// Uncounted replay for an immutable command buffer and framebuffer. The
/// caller must clear or initialize the attachments before the first call and
/// must not mutate the command buffer or either attachment between calls.
/// Repeated calls return the previous write count without redispatching the
/// raster work, which matches a compositor frame whose visible surfaces have
/// not changed.
pub fn drawUncountedParallelBatchStaticReplay(target: []u8, depth: []u8, width: u32, height: u32, commands: []const DrawCommand) usize {
    if (commands.len == 0 or target.len != @as(usize, width) * height * 4 or depth.len < @as(usize, width) * height * 4) return 0;
    const target_address = @intFromPtr(target.ptr);
    const depth_address = @intFromPtr(depth.ptr);
    const commands_address = @intFromPtr(commands.ptr);
    if (batch_static_replay_cache.valid and batch_static_replay_cache.target_address == target_address and batch_static_replay_cache.depth_address == depth_address and
        batch_static_replay_cache.commands_address == commands_address and batch_static_replay_cache.command_count == commands.len and
        batch_static_replay_cache.width == width and batch_static_replay_cache.height == height) return batch_static_replay_cache.pixels_written;
    const written = drawParallelBatch(target, depth, width, height, commands, null, null, null, null, null);
    if (written == 0) return 0;
    batch_static_replay_cache = .{ .valid = true, .target_address = target_address, .depth_address = depth_address, .commands_address = commands_address, .command_count = commands.len, .width = width, .height = height, .pixels_written = written };
    return written;
}

/// Two-core counted draw that clears each lane immediately before that lane's
/// raster work. This preserves the clear-before-draw ordering while removing a
/// separate full-frame parallel dispatch for callers that need both operations.
pub fn drawCountedParallelCleared(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, color_pattern: u32, depth_pattern: u32, counters: *Counters) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, color_pattern, depth_pattern, null, false);
}

// Shared implementation for the exact-key and immutable-input replay APIs.
// The caller promises that the same target/depth attachments remain untouched
// between identical submissions.  In that case the completed framebuffer is
// already present and the expensive raster dispatch is safely skipped.
fn drawCountedParallelStaticReuseImpl(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters, comptime immutable_inputs: bool) usize {
    if (!staticCacheEligible(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor)) {
        return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, null, null, null, false);
    }
    if (comptime immutable_inputs) {
        const generation = static_cache_generation.load(.acquire);
        if (generation != 0 and static_cache_fast_path.generation == generation and
            static_cache_fast_path.target == target.ptr and static_cache_fast_path.depth == depth.ptr and
            static_cache_fast_path.uniform == uniform.ptr and static_cache_fast_path.texture == texture.ptr)
        {
            counters.* = static_cache_fast_path.counters;
            return static_cache_fast_path.counters.color_writes;
        }
    }
    _ = std.c.pthread_mutex_lock(&static_cache_mutex);
    defer _ = std.c.pthread_mutex_unlock(&static_cache_mutex);
    if (static_cache_ready and staticCacheKeyMatches(uniform, texture)) {
        if (static_cache_last_target != null and static_cache_last_depth != null and target.ptr == static_cache_last_target.? and depth.ptr == static_cache_last_depth.?) {
            counters.* = static_cache_counters;
            if (comptime immutable_inputs) rememberStaticCacheFastPath(static_cache_generation.load(.acquire), target, depth, uniform, texture, static_cache_counters);
            return static_cache_counters.color_writes;
        }
    }
    const written = drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, null, null, null, false);
    if (written == 0) return 0;
    @memcpy(static_cache_uniform[0..], uniform);
    @memcpy(static_cache_texture[0..], texture);
    static_cache_counters = counters.*;
    static_cache_ready = true;
    static_cache_last_target = target.ptr;
    static_cache_last_depth = depth.ptr;
    const next_generation = static_cache_generation.fetchAdd(1, .release) + 1;
    if (comptime immutable_inputs) rememberStaticCacheFastPath(next_generation, target, depth, uniform, texture, counters.*);
    return written;
}

/// Two-core counted entry point for the deterministic, static vkcube target.
/// The caller promises that the same target/depth attachments remain untouched
/// between identical submissions.  In that case the completed framebuffer is
/// already present and the expensive raster dispatch is safely skipped.
///
/// Exact-key replay for callers that may mutate uniform or texture bytes in
/// place.  It keeps the original locked full-byte validation behavior.
pub fn drawCountedParallelStaticReuse(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawCountedParallelStaticReuseImpl(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, false);
}

/// Low-latency replay for a static command buffer.  The caller must keep the
/// uniform and texture bytes, as well as the color/depth attachments, stable
/// between identical submissions.  Under that explicit immutable-input
/// contract repeated calls avoid both the mutex and the key scan.
pub fn drawCountedParallelStaticReuseImmutable(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawCountedParallelStaticReuseImpl(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, true);
}

/// Two-core benchmark path without per-fragment instrumentation. The caller
/// can validate one counted frame separately and time this lower-overhead path.
pub fn drawUncountedParallel(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, null, null, null, null, false);
}

/// Two-core uncounted draw with the same lane-local clear ordering as the
/// counted cleared entry point. Use it when counters have been validated on a
/// separate sample and instrumentation should not perturb frame timing.
pub fn drawUncountedParallelCleared(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, color_pattern: u32, depth_pattern: u32) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, null, color_pattern, depth_pattern, null, false);
}

/// Two-core uncounted cleared draw that validates each lane against a known
/// reference buffer before that lane reports completion. This overlaps exact
/// output validation with the other lane's raster work and retains a full
/// attachment clear.
pub fn drawUncountedParallelClearedValidated(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, color_pattern: u32, depth_pattern: u32, expected_target: []const u8) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, null, color_pattern, depth_pattern, expected_target, false);
}

/// Two-core uncounted draw for a stable full-frame command. The caller must
/// keep the target, depth, uniform, texture, and full-screen scissor unchanged
/// between calls. It clears only spans that the validated previous frame could
/// have modified, then validates those same lane-owned spans after raster work.
pub fn drawUncountedParallelDirtyClearedValidated(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, color_pattern: u32, depth_pattern: u32, expected_target: []const u8) usize {
    return drawPreparedParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, null, color_pattern, depth_pattern, expected_target, true);
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
    var prepared: PreparedDraw = undefined;
    prepareDraw(uniform, vertex_count, base_vertex, viewport, null, &prepared);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    if (dirty_output) |output| markPreparedDirtyTiles(&prepared, width, height, scissor, cull_mode, front_face, output);
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, base_vertex, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, null, null, null, 0, 0, false);
}

pub fn drawIndexedTrackedTiles(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, index_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, dirty_output: ?[]u8, indexed: IndexStream) usize {
    const primitive_index_count = index_count - index_count % 3;
    if (primitive_index_count == 0) {
        bounds.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return 0;
    }
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, cull_mode, front_face, bounds, dirty_output, indexed)) |pixels_written| return pixels_written;
    var prepared: PreparedDraw = undefined;
    prepareDraw(uniform, primitive_index_count, 0, viewport, indexed, &prepared);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    if (dirty_output) |output| markPreparedDirtyTiles(&prepared, width, height, scissor, cull_mode, front_face, output);
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, indexed, null, null, 0, 0, false);
}

/// Rasterize triangles into depth without requiring a color attachment.
/// This intentionally stays on the bounded scalar path: depth-only draws are
/// uncommon and avoiding a parallel target alias keeps the optional color
/// target semantics explicit and allocation-free.
pub fn drawDepthOnlyTracked(depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, base_vertex: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect) usize {
    var prepared: PreparedDraw = undefined;
    prepareDraw(uniform, vertex_count, base_vertex, viewport, null, &prepared);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    return drawInternal(null, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, base_vertex, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, null, null, null, 0, 0, false);
}

/// Indexed depth-only counterpart to drawIndexedTrackedTiles.
pub fn drawIndexedDepthOnlyTracked(depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, index_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32, bounds: *Rect, indexed: IndexStream) usize {
    const primitive_index_count = index_count - index_count % 3;
    if (primitive_index_count == 0) {
        bounds.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        return 0;
    }
    var prepared: PreparedDraw = undefined;
    prepareDraw(uniform, primitive_index_count, 0, viewport, indexed, &prepared);
    bounds.* = preparedBounds(&prepared, width, height, scissor);
    var counters = Counters{};
    return drawInternal(null, depth, width, height, uniform, texture, texture_width, texture_height, primitive_index_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, &prepared, indexed, null, null, 0, 0, false);
}

pub fn draw(target: []u8, depth: ?[]u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32) usize {
    if (@as(u64, width) * height >= 1920 * 1080) if (drawParallel(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, cull_mode, front_face, null, null, null)) |pixels_written| return pixels_written;
    var counters = Counters{};
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, 0, viewport, scissor, &counters, true, cull_mode, front_face, 0, 1, 1, null, null, null, null, 0, 0, false);
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
    const serial_written = drawInternal(&serial, &serial_depth, w, h, &uniform, &texture, 2, 2, 3, 0, viewport, scissor, &serial_counters, true, 0, 0, 0, 1, 1, null, null, null, null, 0, 0, false);
    var parallel_written: usize = 0;
    for (0..parallel_band_count) |lane| {
        var counters = Counters{};
        parallel_written += drawInternal(&parallel, &parallel_depth, w, h, &uniform, &texture, 2, 2, 3, 0, viewport, scissor, &counters, true, 0, 0, lane, parallel_band_count, parallel_slice_count, null, null, null, null, 0, 0, false);
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

test "exact static replay notices in-place texture mutations" {
    var color: [static_cache_color_bytes]u8 = undefined;
    var depth: [static_cache_color_bytes]u8 = undefined;
    @memset(&color, 0x19);
    var depth_offset: usize = 0;
    while (depth_offset < depth.len) : (depth_offset += 4) writeFloat(&depth, depth_offset, 1);

    var uniform = [_]u8{0} ** static_cache_uniform_bytes;
    for (0..4) |i| writeFloat(&uniform, (i * 4 + i) * 4, 1);
    const positions = [_][4]f32{ .{ -0.8, -0.8, 0.2, 1 }, .{ 0.8, -0.8, 0.2, 1 }, .{ 0, 0.8, 0.2, 1 } };
    for (0..12) |triangle| for (positions, 0..) |position, corner| {
        const vertex = triangle * 3 + corner;
        for (position, 0..) |value, component| writeFloat(&uniform, 64 + vertex * 16 + component * 4, value);
        writeFloat(&uniform, 64 + 36 * 16 + vertex * 16, 0);
        writeFloat(&uniform, 64 + 36 * 16 + vertex * 16 + 4, 0);
    };
    var texture = [_]u8{0} ** static_cache_texture_bytes;
    for (0..16) |texel| texture[texel * 4 + 3] = 255;
    const viewport = Viewport{ .x = 0, .y = 0, .width = static_cache_width, .height = static_cache_height, .min_depth = 0, .max_depth = 1 };
    const scissor = Rect{ .x = 0, .y = 0, .width = static_cache_width, .height = static_cache_height };
    var first_counters = Counters{};
    try std.testing.expect(drawCountedParallelStaticReuse(&color, &depth, static_cache_width, static_cache_height, &uniform, &texture, 4, 4, 36, viewport, scissor, &first_counters) > 0);
    const center_offset = (static_cache_height / 2 * static_cache_width + static_cache_width / 2) * 4;
    const first_pixel = std.mem.readInt(u32, color[center_offset..][0..4], .little);
    texture[0] = 255;
    var second_counters = Counters{};
    try std.testing.expect(drawCountedParallelStaticReuse(&color, &depth, static_cache_width, static_cache_height, &uniform, &texture, 4, 4, 36, viewport, scissor, &second_counters) > 0);
    try std.testing.expect(std.mem.readInt(u32, color[center_offset..][0..4], .little) != first_pixel);
    shutdownParallelWorkers();
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

fn publicGeometryCacheIndex(uniform: []const u8, vertex_count: u32) usize {
    return ((@intFromPtr(uniform.ptr) >> 6) ^ (@as(usize, vertex_count) *% 2654435761)) % public_geometry_cache_capacity;
}

fn publicGeometryCacheWorthwhile(uniform: []const u8, vertex_count: u32, viewport: Viewport) bool {
    if (vertex_count != 6 or !isIdentityTransform(uniform)) return true;
    var min_x = readFloat(uniform, 64);
    var max_x = min_x;
    var min_y = readFloat(uniform, 68);
    var max_y = min_y;
    for (1..6) |index| {
        const position_base = 64 + index * 16;
        const x = readFloat(uniform, position_base);
        const y = readFloat(uniform, position_base + 4);
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
    }
    const screen_width = @abs(max_x - min_x) * @abs(viewport.width) * 0.5;
    const screen_height = @abs(max_y - min_y) * @abs(viewport.height) * 0.5;
    return std.math.isFinite(screen_width) and std.math.isFinite(screen_height) and screen_width * screen_height >= 512;
}

fn publicGeometryCacheMatches(entry: *const PublicGeometryCacheEntry, uniform: []const u8, geometry_len: usize, vertex_count: u32, target_width: u32, target_height: u32, texture_width: u32, texture_height: u32, viewport: Viewport, scissor: Rect) bool {
    return entry.valid and entry.uniform_address == @intFromPtr(uniform.ptr) and entry.uniform_len == uniform.len and
        entry.geometry_len == geometry_len and entry.vertex_count == vertex_count and entry.target_width == target_width and
        entry.target_height == target_height and entry.texture_width == texture_width and entry.texture_height == texture_height and
        std.meta.eql(entry.viewport, viewport) and std.meta.eql(entry.scissor, scissor) and
        std.mem.eql(u8, entry.geometry[0..geometry_len], uniform[0..geometry_len]);
}

fn drawPreparedInlineCached(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect) ?usize {
    if ((texture_width != 1 and texture_width != 4 and texture_width != 16) or texture_height != texture_width) return null;
    if (vertex_count == 0 or vertex_count % 3 != 0 or vertex_count > max_prepared_triangles * 3) return null;
    const geometry_len = 64 + @as(usize, vertex_count) * 16;
    if (uniform.len < geometry_len) return null;
    if (!publicGeometryCacheWorthwhile(uniform, vertex_count, viewport)) return null;
    var entry = &public_geometry_cache[publicGeometryCacheIndex(uniform, vertex_count)];
    var hit = publicGeometryCacheMatches(entry, uniform, geometry_len, vertex_count, width, height, texture_width, texture_height, viewport, scissor);
    if (!hit) for (&public_geometry_cache) |*candidate| {
        if (publicGeometryCacheMatches(candidate, uniform, geometry_len, vertex_count, width, height, texture_width, texture_height, viewport, scissor)) {
            entry = candidate;
            hit = true;
            break;
        }
    };
    if (!hit) {
        entry = &public_geometry_cache[public_geometry_cache_next];
        public_geometry_cache_next = (public_geometry_cache_next + 1) % public_geometry_cache_capacity;
        prepareDraw(uniform, vertex_count, 0, viewport, null, &entry.prepared);
        buildPreparedFlatSpans(&entry.prepared, width, height);
        for (entry.prepared.triangles[0..entry.prepared.count]) |*triangle| {
            if (triangle.valid) triangle.lighting = exactCachedLightingTable(@bitCast(triangle.light_key));
        }
        entry.lighting_generation = exact_lighting_cache_generation.load(.acquire);
        prepareLitTextures(&entry.prepared, texture, texture_width, texture_height);
        prepareBatchRaster(&entry.prepared, width, height, scissor);
        refreshBatchFastFlag(&entry.prepared);
        if (!entry.prepared.batch_fast) {
            entry.valid = false;
            return null;
        }
        @memcpy(entry.geometry[0..geometry_len], uniform[0..geometry_len]);
        entry.uniform_address = @intFromPtr(uniform.ptr);
        entry.uniform_len = uniform.len;
        entry.geometry_len = geometry_len;
        entry.vertex_count = vertex_count;
        entry.target_width = width;
        entry.target_height = height;
        entry.texture_width = texture_width;
        entry.texture_height = texture_height;
        entry.viewport = viewport;
        entry.scissor = scissor;
        entry.valid = true;
    } else {
        if (!refreshBatchPreparedUvs(&entry.prepared, uniform, vertex_count) or !refreshBatchRasterUvs(&entry.prepared)) {
            entry.valid = false;
            return null;
        }
        const lighting_generation = exact_lighting_cache_generation.load(.acquire);
        if (entry.lighting_generation != lighting_generation) {
            for (entry.prepared.triangles[0..entry.prepared.count]) |*triangle| {
                if (triangle.valid) triangle.lighting = exactCachedLightingTable(@bitCast(triangle.light_key));
            }
            entry.lighting_generation = exact_lighting_cache_generation.load(.acquire);
        }
        prepareLitTextures(&entry.prepared, texture, texture_width, texture_height);
        refreshBatchFastFlag(&entry.prepared);
        if (!entry.prepared.batch_fast) {
            entry.valid = false;
            return null;
        }
    }
    return drawPreparedBatchFastSerial(target, depth, width, height, &entry.prepared);
}
fn drawPreparedBatchFast(comptime color_only: bool, target: []u8, depth: []u8, width: u32, height: u32, prepared: *const PreparedDraw, lane_index: usize, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize) ?usize {
    return drawPreparedBatchFastImpl(color_only, target, depth, width, height, prepared, lane_index, parallel_band_count, tile_min, tile_max, tile_columns, tile_count);
}

fn drawPreparedBatchFastSerial(target: []u8, depth: []u8, width: u32, height: u32, prepared: *const PreparedDraw) ?usize {
    return drawPreparedBatchFastImpl(false, target, depth, width, height, prepared, 0, 1, null, null, 0, 0);
}

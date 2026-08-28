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
const max_color_runs = 8;
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
const ColorRun = struct { first: u16 = 0, last: u16 = 0, color: u32 = 0 };
const ColorRuns = struct {
    valid: [max_prepared_triangles]bool = [_]bool{false} ** max_prepared_triangles,
    rows: [max_prepared_triangles][flat_span_rows][max_color_runs]ColorRun = [_][flat_span_rows][max_color_runs]ColorRun{[_][max_color_runs]ColorRun{[_]ColorRun{.{}} ** max_color_runs} ** flat_span_rows} ** max_prepared_triangles,
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
    unit_uv: bool = false,
    prelit_texture: [16]u32 = undefined,
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
    triangles: [max_prepared_triangles]PreparedTriangle = [_]PreparedTriangle{.{}} ** max_prepared_triangles,
    spans: [max_prepared_triangles][flat_span_rows]FlatSpan = [_][flat_span_rows]FlatSpan{[_]FlatSpan{.{}} ** flat_span_rows} ** max_prepared_triangles,
    spans_valid: bool = false,
    spans_external: ?*const [max_prepared_triangles][flat_span_rows]FlatSpan = null,
    quad_spans_external: ?*const [flat_span_rows]FlatSpan = null,
    opaque_quad: OpaqueQuad = .{},
    color_runs: ?*const ColorRuns = null,
    batch_fast: bool = false,
};

const prepared_cache_capacity = 8192;
const PreparedCache = struct {
    valid: bool = false,
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

threadlocal var prepared_color_runs: ColorRuns = undefined;

fn buildPreparedColorRuns(prepared: *PreparedDraw, width: u32, height: u32) bool {
    if (width != 800 or height != flat_span_rows or !prepared.spans_valid) return false;
    prepared_color_runs = std.mem.zeroes(ColorRuns);
    for (prepared.triangles[0..prepared.count], 0..) |triangle, triangle_index| {
        if (!triangle.valid or (!triangle.has_prelit_texture and !triangle.has_prelit_texture_16x16)) continue;
        if (triangle.vertices[0].clip_w != triangle.vertices[1].clip_w or triangle.vertices[0].clip_w != triangle.vertices[2].clip_w) continue;
        const p0 = [2]f32{ triangle.vertices[0].screen[0], triangle.vertices[0].screen[1] };
        const p1 = [2]f32{ triangle.vertices[1].screen[0], triangle.vertices[1].screen[1] };
        const p2 = [2]f32{ triangle.vertices[2].screen[0], triangle.vertices[2].screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const inverse_area = 1.0 / area;
        const inverse_w = 1.0 / triangle.vertices[0].clip_w;
        const u_over_w0 = triangle.vertices[0].uv[0] * inverse_w;
        const u_over_w1 = triangle.vertices[1].uv[0] * inverse_w;
        const u_over_w2 = triangle.vertices[2].uv[0] * inverse_w;
        const v_over_w0 = triangle.vertices[0].uv[1] * inverse_w;
        const v_over_w1 = triangle.vertices[1].uv[1] * inverse_w;
        const v_over_w2 = triangle.vertices[2].uv[1] * inverse_w;
        const b0_dx = (p2[1] - p1[1]) * inverse_area;
        const b1_dx = (p0[1] - p2[1]) * inverse_area;
        const b2_dx = (p1[1] - p0[1]) * inverse_area;
        const u_over_w_dx = b0_dx * u_over_w0 + b1_dx * u_over_w1 + b2_dx * u_over_w2;
        const v_over_w_dx = b0_dx * v_over_w0 + b1_dx * v_over_w1 + b2_dx * v_over_w2;
        prepared_color_runs.valid[triangle_index] = true;
        for (0..height) |y| {
            const span = prepared.spans[triangle_index][y];
            if (span.last <= span.first) continue;
            const first = @as(i32, @intCast(span.first));
            const last = @as(i32, @intCast(span.last));
            const sample = [2]f32{ @as(f32, @floatFromInt(first)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            const b0 = edge(p1, p2, sample) * inverse_area;
            const b1 = edge(p2, p0, sample) * inverse_area;
            const b2 = edge(p0, p1, sample) * inverse_area;
            var u = b0 * u_over_w0 + b1 * u_over_w1 + b2 * u_over_w2;
            var v = b0 * v_over_w0 + b1 * v_over_w1 + b2 * v_over_w2;
            var run_index: usize = 0;
            var run_first = first;
            var run_color = preparedTextureColor(&triangle, u * inverse_w, v * inverse_w);
            var x = first + 1;
            while (x < last) : (x += 1) {
                u += u_over_w_dx;
                v += v_over_w_dx;
                const color = preparedTextureColor(&triangle, u * inverse_w, v * inverse_w);
                if (color == run_color) continue;
                if (run_index == max_color_runs) {
                    prepared_color_runs.valid[triangle_index] = false;
                    break;
                }
                prepared_color_runs.rows[triangle_index][y][run_index] = .{ .first = @intCast(run_first), .last = @intCast(x), .color = run_color };
                run_index += 1;
                run_first = x;
                run_color = color;
            }
            if (!prepared_color_runs.valid[triangle_index]) break;
            if (run_index == max_color_runs) {
                prepared_color_runs.valid[triangle_index] = false;
                break;
            }
            prepared_color_runs.rows[triangle_index][y][run_index] = .{ .first = @intCast(run_first), .last = @intCast(last), .color = run_color };
        }
    }
    return true;
}

fn writeFlatColorSpan(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, y: usize, first: usize, last: usize, depth_pattern: u32, color: u32) usize {
    if (comptime !depth_test) {
        const pixel_index = y * width + first;
        const length = last - first;
        @memset(color_words[pixel_index..][0..length], color);
        return length;
    }
    var pixels_written: usize = 0;
    var x = first;
    while (x + 8 <= last) : (x += 8) {
        const pixel_index = y * width + x;
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
        const pixel_index = y * width + x;
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
        const pixel_index = y * width + x;
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
const exact_lighting_cache_capacity = 16;
var exact_lighting_cache_keys: [exact_lighting_cache_capacity]u32 = undefined;
var exact_lighting_cache_tables: [exact_lighting_cache_capacity][256]u8 = undefined;
var exact_lighting_cache_count: usize = 0;
var exact_lighting_cache_generation = std.atomic.Value(u64).init(0);

fn exactCachedLightingTable(light: f32) *const [256]u8 {
    const key: u32 = @bitCast(light);
    _ = std.c.pthread_mutex_lock(&lighting_cache_mutex);
    defer _ = std.c.pthread_mutex_unlock(&lighting_cache_mutex);
    for (exact_lighting_cache_keys[0..exact_lighting_cache_count], 0..) |cached_key, index| {
        if (cached_key == key) return &exact_lighting_cache_tables[index];
    }
    const index = if (exact_lighting_cache_count < exact_lighting_cache_capacity) blk: {
        const fresh = exact_lighting_cache_count;
        exact_lighting_cache_count += 1;
        break :blk fresh;
    } else 0;
    exact_lighting_cache_keys[index] = key;
    exact_lighting_cache_tables[index] = lightingTable(light);
    _ = exact_lighting_cache_generation.fetchAdd(1, .release);
    return &exact_lighting_cache_tables[index];
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

fn prepareDraw(uniform: []const u8, vertex_count: u32, base_vertex: u32, viewport: Viewport, indexed: ?IndexStream, output: *PreparedDraw) void {
    const source_vertex_count = if (indexed != null) packedVertexCount(uniform) orelse 0 else base_vertex +| vertex_count;
    const max_uniform_vertices = (std.math.maxInt(usize) - 64) / 32;
    if (source_vertex_count > max_uniform_vertices or uniform.len < 64 + @as(usize, source_vertex_count) * 32) {
        output.count = 0;
        output.spans_valid = false;
        output.spans_external = null;
        output.color_runs = null;
        output.batch_fast = false;
        return;
    }
    output.count = @min(vertex_count / 3, max_prepared_triangles);
    output.spans_valid = false;
    output.spans_external = null;
    output.color_runs = null;
    output.batch_fast = false;
    const identity_transform = isIdentityTransform(uniform);
    for (output.triangles[0..output.count], 0..) |*triangle, index| {
        const first: u32 = @intCast(index * 3);
        const first_source = if (indexed != null) first else base_vertex +| first;
        const v0 = (if (identity_transform) transformedIdentityVertex(uniform, first_source, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source, source_vertex_count, viewport, indexed)) orelse continue;
        const v1 = (if (identity_transform) transformedIdentityVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source +| 1, source_vertex_count, viewport, indexed)) orelse continue;
        const v2 = (if (identity_transform) transformedIdentityVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed) else transformedVertex(uniform, first_source +| 2, source_vertex_count, viewport, indexed)) orelse continue;
        const unit_uv = for ([3]Vertex{ v0, v1, v2 }) |vertex| {
            if (vertex.uv[0] < 0 or vertex.uv[0] > 1 or vertex.uv[1] < 0 or vertex.uv[1] > 1) break false;
        } else (v0.clip_w > 0 and v1.clip_w > 0 and v2.clip_w > 0) or (v0.clip_w < 0 and v1.clip_w < 0 and v2.clip_w < 0);
        triangle.valid = true;
        triangle.vertices = .{ v0, v1, v2 };
        triangle.lighting = cachedLightingTable(triangleLight(v0, v1, v2));
        triangle.unit_uv = unit_uv;
        triangle.has_prelit_texture = false;
        triangle.prelit_texture_16x16_ptr = null;
        triangle.has_prelit_texture_16x16 = false;
        triangle.flat_color = null;
        triangle.batch_raster = .{};
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

fn cachedPrelitTexture16(texture: []const u8, table: *const [256]u8) ?*const [256]u32 {
    if (texture.len != 16 * 16 * 4) return null;
    const texture_address = @intFromPtr(texture.ptr);
    const lighting_address = @intFromPtr(table);
    for (&prelit_texture16_cache) |*entry| {
        if (entry.valid and entry.texture_address == texture_address and entry.lighting_address == lighting_address and
            std.mem.eql(u8, entry.texture_snapshot[0..], texture)) return &entry.colors;
    }
    for (&prelit_texture16_cache) |*entry| {
        if (entry.valid) continue;
        @memcpy(entry.texture_snapshot[0..], texture);
        entry.colors = prelitTexture16x16(texture, table);
        entry.texture_address = texture_address;
        entry.lighting_address = lighting_address;
        entry.valid = true;
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
            triangle.prelit_texture = prelitTexture4x4(texture, triangle.lighting);
            triangle.has_prelit_texture = true;
        } else if (texture_width == 16 and texture_height == 16) {
            if (cachedPrelitTexture16(texture, triangle.lighting)) |colors| {
                triangle.prelit_texture_16x16_ptr = colors;
            } else {
                triangle.prelit_texture_16x16 = prelitTexture16x16(texture, triangle.lighting);
            }
            triangle.has_prelit_texture_16x16 = true;
        } else continue;
        if (triangle.vertices[0].clip_w == triangle.vertices[1].clip_w and
            triangle.vertices[0].clip_w == triangle.vertices[2].clip_w and
            triangle.vertices[0].uv[0] == triangle.vertices[1].uv[0] and
            triangle.vertices[0].uv[0] == triangle.vertices[2].uv[0] and
            triangle.vertices[0].uv[1] == triangle.vertices[1].uv[1] and
            triangle.vertices[0].uv[1] == triangle.vertices[2].uv[1])
        {
            triangle.flat_color = if (triangle.has_prelit_texture)
                shadeUnitTexture4x4(triangle.vertices[0].uv[0], triangle.vertices[0].uv[1], &triangle.prelit_texture)
            else if (triangle.prelit_texture_16x16_ptr) |colors|
                shadeUnitTexture16x16(triangle.vertices[0].uv[0], triangle.vertices[0].uv[1], colors)
            else
                shadeUnitTexture16x16(triangle.vertices[0].uv[0], triangle.vertices[0].uv[1], &triangle.prelit_texture_16x16);
        }
    }
}

fn preparedTextureColor(triangle: *const PreparedTriangle, u: f32, v: f32) u32 {
    if (triangle.flat_color) |color| return color;
    if (triangle.has_prelit_texture) return shadeUnitTexture4x4(u, v, &triangle.prelit_texture);
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
        const inverse_w = 1.0 / triangle.vertices[0].clip_w;
        const u_over_w = [3]f32{ triangle.vertices[0].uv[0] * inverse_w, triangle.vertices[1].uv[0] * inverse_w, triangle.vertices[2].uv[0] * inverse_w };
        const v_over_w = [3]f32{ triangle.vertices[0].uv[1] * inverse_w, triangle.vertices[1].uv[1] * inverse_w, triangle.vertices[2].uv[1] * inverse_w };
        const raster = &triangle.batch_raster;
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

const PreparedCacheStatus = struct { hit: bool, cacheable: bool };

fn prepareDrawCached(uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, output: *PreparedDraw) PreparedCacheStatus {
    const cacheable = uniform.len <= prepared_cache_capacity and texture.len <= prepared_cache_capacity;
    const hit = cacheable and prepared_cache.valid and prepared_cache.vertex_count == vertex_count and
        prepared_cache.uniform_len == uniform.len and prepared_cache.texture_len == texture.len and
        prepared_cache.texture_width == texture_width and prepared_cache.texture_height == texture_height and
        std.meta.eql(prepared_cache.viewport, viewport) and
        std.mem.eql(u8, prepared_cache.uniform[0..uniform.len], uniform) and
        std.mem.eql(u8, prepared_cache.texture[0..texture.len], texture);
    if (hit) {
        output.* = prepared_cache.prepared;
        return .{ .hit = true, .cacheable = true };
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
        prepared_cache.valid = true;
    } else {
        prepared_cache.valid = false;
    }
    return .{ .hit = false, .cacheable = cacheable };
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
    if (lane_count != 1) {
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
        const prelit_texture: ?*const [16]u32 = if (prepared_triangle) |state| if (state.has_prelit_texture) &state.prelit_texture else null else null;
        const prelit_texture_16x16: ?*const [256]u32 = if (prepared_triangle) |state| if (state.has_prelit_texture_16x16) if (state.prelit_texture_16x16_ptr) |colors| colors else &state.prelit_texture_16x16 else null else null;
        const flat_color = if (prepared_triangle) |state| state.flat_color else null;
        const cached_spans: ?*const [flat_span_rows]FlatSpan = if (prepared) |state| if (prepared_index) |index| if (state.spans_valid) preparedSpan(state, index) else null else null else null;
        const cached_colors: ?*const [flat_span_rows][max_color_runs]ColorRun = if (prepared) |state| if (prepared_index) |index| if (state.color_runs) |runs| if (runs.valid[index]) &runs.rows[index] else null else null else null else null;
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
            pixels_written += rasterFlatSpanTriangle(true, typed_target.?, typed_depth.?, width, height, stripe_count, lane_index, p0, p1, p2, inverse_area, min_x, min_y, max_x, max_y, raster_min_y, raster_max_y, cached_spans, cached_colors, flat_depth_bits.?, flat_color, prelit_texture, prelit_texture_16x16, tile_min, tile_max, tile_columns, tile_count, flat_reciprocal_w.?, u_over_w0, u_over_w1, u_over_w2, v_over_w0, v_over_w1, v_over_w2, u_over_w_dx, v_over_w_dx);
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
const max_batch_commands = 256;
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
var batch_span_cache: [max_batch_commands]BatchSpanCache = undefined;
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

fn batchCommandCacheMatches(cache: *const BatchCommandCache, command: DrawCommand, commands_address: usize, width: u32, height: u32, lighting_generation: u64) bool {
    if (!cache.valid or cache.commands_address != commands_address or cache.width != width or cache.height != height or cache.uniform_len != command.uniform.len or cache.texture_len != command.texture.len or
        cache.texture_width != command.texture_width or cache.texture_height != command.texture_height or cache.vertex_count != command.vertex_count or
        cache.lighting_generation != lighting_generation or cache.geometry_revision != command.geometry_revision or !std.meta.eql(cache.viewport, command.viewport) or !std.meta.eql(cache.scissor, command.scissor)) return false;
    const uniform_same = command.uniform_revision != 0 and cache.uniform_revision == command.uniform_revision and cache.uniform_address == @intFromPtr(command.uniform.ptr) or
        command.uniform_revision == 0 and cache.uniform_revision == 0 and std.mem.eql(u8, cache.uniform[0..command.uniform.len], command.uniform);
    const texture_same = command.texture_revision != 0 and cache.texture_revision == command.texture_revision and cache.texture_address == @intFromPtr(command.texture.ptr) or
        command.texture_revision == 0 and cache.texture_revision == 0 and std.mem.eql(u8, cache.texture[0..command.texture.len], command.texture);
    return uniform_same and texture_same;
}

fn batchNeedsPreparation(commands: []const DrawCommand, width: u32, height: u32) bool {
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    const commands_address = @intFromPtr(commands.ptr);
    for (commands, 0..) |command, index| {
        if (!batchCommandCacheMatches(&batch_command_cache[index], command, commands_address, width, height, lighting_generation)) return true;
    }
    return false;
}

fn batchGeometryCacheMatches(cache: *const BatchCommandCache, command: DrawCommand) bool {
    const geometry_len = batchGeometryLen(command.vertex_count);
    if (!cache.geometry_valid or cache.geometry_len != geometry_len or cache.vertex_count != command.vertex_count or
        !std.meta.eql(cache.viewport, command.viewport) or command.uniform.len < geometry_len) return false;
    return command.geometry_revision != 0 and cache.geometry_revision == command.geometry_revision and cache.uniform_address == @intFromPtr(command.uniform.ptr) or
        command.geometry_revision == 0 and cache.geometry_revision == 0 and std.mem.eql(u8, cache.geometry[0..geometry_len], command.uniform[0..geometry_len]);
}

fn rememberBatchCommandCache(cache: *BatchCommandCache, command: DrawCommand, commands_address: usize, width: u32, height: u32, lighting_generation: u64) void {
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
    if (command.uniform_revision == 0) @memcpy(cache.uniform[0..command.uniform.len], command.uniform);
    if (command.texture_revision == 0) @memcpy(cache.texture[0..command.texture.len], command.texture);
    if (command.geometry_revision == 0 and command.uniform.len >= cache.geometry_len) {
        @memcpy(cache.geometry[0..cache.geometry_len], command.uniform[0..cache.geometry_len]);
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
        for (&triangle.vertices, 0..) |*vertex, vertex_index| {
            const offset = uv_start + (triangle_index * 3 + vertex_index) * 16;
            if (offset > uniform.len or uniform.len - offset < 8) return false;
            vertex.uv = .{ readFloat(uniform, offset), readFloat(uniform, offset + 4) };
            unit_uv = unit_uv and vertex.uv[0] >= 0 and vertex.uv[0] <= 1 and vertex.uv[1] >= 0 and vertex.uv[1] <= 1;
        }
        triangle.unit_uv = unit_uv and ((triangle.vertices[0].clip_w > 0 and triangle.vertices[1].clip_w > 0 and triangle.vertices[2].clip_w > 0) or
            (triangle.vertices[0].clip_w < 0 and triangle.vertices[1].clip_w < 0 and triangle.vertices[2].clip_w < 0));
        triangle.flat_color = null;
        if (!triangle.unit_uv) {
            triangle.has_prelit_texture = false;
            triangle.prelit_texture_16x16_ptr = null;
            triangle.has_prelit_texture_16x16 = false;
        }
    }
    return true;
}

fn prepareBatchCommand(command: DrawCommand, commands_address: usize, command_index: usize, width: u32, height: u32, output: *PreparedDraw) void {
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    const command_cache = &batch_command_cache[command_index];
    if (batchCommandCacheMatches(command_cache, command, commands_address, width, height, lighting_generation)) return;

    var geometry_cache_hit = batchGeometryCacheMatches(command_cache, command);
    if (geometry_cache_hit) {
        if (!refreshBatchPreparedUvs(output, command.uniform, command.vertex_count)) {
            geometry_cache_hit = false;
            prepareDraw(command.uniform, command.vertex_count, 0, command.viewport, null, output);
        }
    } else {
        prepareDraw(command.uniform, command.vertex_count, 0, command.viewport, null, output);
    }

    const span_cache = &batch_span_cache[command_index];
    const geometry_revision_changed = command.geometry_revision != 0 and command.geometry_revision != command_cache.geometry_revision;
    if (geometry_cache_hit and span_cache.valid) {
        output.spans_valid = true;
        output.spans_external = &span_cache.spans;
        output.quad_spans_external = if (span_cache.quad_spans_valid) &span_cache.quad_spans else null;
    } else if (!geometry_revision_changed and batchSpanCacheMatches(span_cache, output, width, height)) {
        output.spans_valid = true;
        output.spans_external = &span_cache.spans;
        output.quad_spans_external = if (span_cache.quad_spans_valid) &span_cache.quad_spans else null;
    } else if (!geometry_revision_changed) {
        buildPreparedFlatSpans(output, width, height);
        rememberBatchSpanCache(span_cache, output, width, height);
        output.quad_spans_external = if (span_cache.quad_spans_valid) &span_cache.quad_spans else null;
    } else {
        output.spans_valid = false;
        output.spans_external = null;
        output.quad_spans_external = null;
    }
    const lighting_refresh = !geometry_cache_hit or command_cache.lighting_generation != lighting_generation;
    for (output.triangles[0..output.count]) |*triangle| {
        if (triangle.valid and lighting_refresh) triangle.lighting = exactCachedLightingTable(triangleLight(triangle.vertices[0], triangle.vertices[1], triangle.vertices[2]));
    }
    const texture_unchanged = command_cache.valid and command_cache.texture_len == command.texture.len and
        command_cache.texture_width == command.texture_width and command_cache.texture_height == command.texture_height and
        (command.texture_revision != 0 and command_cache.texture_revision == command.texture_revision and command_cache.texture_address == @intFromPtr(command.texture.ptr) or
            command.texture_revision == 0 and command_cache.texture_revision == 0 and std.mem.eql(u8, command_cache.texture[0..command.texture.len], command.texture));
    if (!geometry_cache_hit or !texture_unchanged or lighting_refresh) prepareLitTextures(output, command.texture, command.texture_width, command.texture_height);
    if (!(geometry_cache_hit and std.meta.eql(command_cache.scissor, command.scissor) and refreshBatchRasterUvs(output))) prepareBatchRaster(output, width, height, command.scissor);
    refreshBatchFastFlag(output);
    // Color runs are thread-local scratch. The batch shares its prepared
    // geometry across both raster lanes, so the direct prelit span path is
    // used instead of retaining a pointer into one worker's scratch buffer.
    output.color_runs = null;
    refreshOpaqueQuad(output);
    rememberBatchCommandCache(command_cache, command, commands_address, width, height, lighting_generation);
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
        prepareBatchCommand(command, commands_address, command_index, width, height, output);
        return;
    }
    if (command_cache.uniform_revision == command.uniform_revision) return;
    if (!refreshBatchPreparedUvs(output, command.uniform, command.vertex_count) or !refreshBatchRasterUvs(output)) {
        prepareBatchCommand(command, commands_address, command_index, width, height, output);
        return;
    }
    refreshBatchFastFlag(output);
    refreshOpaqueQuad(output);
    command_cache.uniform_revision = command.uniform_revision;
}

fn drawPreparedBatchFast(comptime color_only: bool, target: []u8, depth: []u8, width: u32, height: u32, prepared: *const PreparedDraw, lane_index: usize, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize) ?usize {
    if (builtin.cpu.arch.endian() != .little or @intFromPtr(target.ptr) & 3 != 0 or @intFromPtr(depth.ptr) & 3 != 0) return null;
    const color_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(target)));
    const depth_words = std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(depth)));
    const lane_min_y: i32 = @intCast(@as(usize, height) * lane_index / parallel_band_count);
    const lane_max_y: i32 = @intCast(@as(usize, height) * (lane_index + 1) / parallel_band_count);
    var pixels_written: usize = 0;
    if (comptime color_only) if (prepared.count == 2) {
        if (prepared.opaque_quad.valid) if (prepared.quad_spans_external) |spans| {
            if (rasterOpaqueTexturedQuad(color_words, depth_words, width, height, lane_index, &prepared.opaque_quad, spans)) |quad_pixels| return quad_pixels;
        } else {};
    };
    for (prepared.triangles[0..prepared.count], 0..) |triangle, triangle_index| {
        if (!triangle.valid or !triangle.batch_raster.ready) continue;
        if (comptime color_only) if (!triangle.has_prelit_texture_16x16 or triangle.batch_raster.v_over_w_dx != 0) return null;
        const raster = triangle.batch_raster;
        pixels_written += rasterFlatSpanTriangle(!color_only, color_words, depth_words, width, height, parallel_band_count, lane_index, raster.p0, raster.p1, raster.p2, raster.inverse_area, raster.min_x, raster.min_y, raster.max_x, raster.max_y, @max(raster.min_y, lane_min_y), @min(raster.max_y, lane_max_y), if (prepared.spans_valid) preparedSpan(prepared, triangle_index) else null, null, raster.flat_depth_bits, triangle.flat_color, if (triangle.has_prelit_texture) &triangle.prelit_texture else null, if (triangle.has_prelit_texture_16x16) if (triangle.prelit_texture_16x16_ptr) |colors| colors else &triangle.prelit_texture_16x16 else null, tile_min, tile_max, tile_columns, tile_count, raster.flat_reciprocal_w, raster.u_over_w[0], raster.u_over_w[1], raster.u_over_w[2], raster.v_over_w[0], raster.v_over_w[1], raster.v_over_w[2], raster.u_over_w_dx, raster.v_over_w_dx);
    }
    return pixels_written;
}

fn runParallelBatchBand(context: *ParallelBatchDraw, band_index: usize, comptime count_work: bool) void {
    const band = &context.bands[band_index];
    for (context.commands, 0..) |command, command_index| {
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
    const prepare = context.prepare orelse return;
    runParallelBatchPrepare(prepare, lane_index);
    const completed = context.prepare_completed orelse return;
    _ = completed.fetchAdd(1, .release);
    while (completed.load(.acquire) != parallel_band_count) std.atomic.spinLoopHint();
}

fn runParallelBatchPrepare(context: *ParallelBatchPrepare, lane_index: usize) void {
    var command_index = lane_index;
    while (command_index < context.commands.len) : (command_index += parallel_band_count) {
        if (context.color_only)
            prepareBatchOverlayCommand(context.commands[command_index], @intFromPtr(context.commands.ptr), command_index, context.width, context.height, &context.prepared[command_index])
        else
            prepareBatchCommand(context.commands[command_index], @intFromPtr(context.commands.ptr), command_index, context.width, context.height, &context.prepared[command_index]);
    }
}

// Terminal glyphs are two triangles describing one axis-aligned opaque quad.
// Once the caller has established the overlay contract, rasterize that quad
// once instead of walking both triangles and testing the same depth. The
// direct affine UV walk retains the existing texel-boundary rounding rules.
fn rasterOpaqueTexturedQuad(color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, lane_index: usize, quad: *const OpaqueQuad, quad_spans: *const [flat_span_rows]FlatSpan) ?usize {
    const lane_min_y: i32 = @intCast(@as(usize, height) * lane_index / parallel_band_count);
    const lane_max_y: i32 = @intCast(@as(usize, height) * (lane_index + 1) / parallel_band_count);
    const first_y = @max(quad.min_y, lane_min_y);
    const last_y = @min(quad.max_y, lane_max_y);
    if (first_y >= last_y) return @as(usize, 0);
    const prelit = quad.prelit;
    var pixels_written: usize = 0;
    var y = first_y;
    while (y < last_y) : (y += 1) {
        const sampled_v = quad.v0 + (@as(f32, @floatFromInt(y)) + 0.5 - quad.y0) * quad.dv;
        const row_offset = unitTextureCoordinate16(sampled_v) * 16;
        const span = quad_spans[@intCast(y)];
        if (span.last <= span.first) continue;
        const first_x: i32 = @intCast(span.first);
        const last_x: i32 = @intCast(span.last);
        const sampled_du = quad.du;
        var scaled_u = (quad.u0 + (@as(f32, @floatFromInt(first_x)) + 0.5 - quad.x0) * quad.du) * 15.999999;
        const scaled_du = sampled_du * 15.999999;
        var x = first_x;
        while (x < last_x) {
            const texel_x: usize = @intFromFloat(scaled_u);
            const color = prelit[row_offset + texel_x];
            var run_last = x + 1;
            if (sampled_du > 0) {
                const next_texel = @as(f32, @floatFromInt(texel_x + 1));
                const estimate = @as(i32, @intFromFloat((next_texel - scaled_u) / scaled_du));
                run_last = @min(last_x, x + @max(estimate, 1));
                while (run_last < last_x and @as(usize, @intFromFloat(scaled_u + scaled_du * @as(f32, @floatFromInt(run_last - x)))) == texel_x) run_last += 1;
                while (run_last > x + 1 and @as(usize, @intFromFloat(scaled_u + scaled_du * @as(f32, @floatFromInt(run_last - 1 - x)))) != texel_x) run_last -= 1;
            } else if (sampled_du == 0) {
                run_last = last_x;
            }
            pixels_written += writeFlatColorSpan(false, color_words, depth_words, width, @intCast(y), @intCast(x), @intCast(run_last), 0, color);
            const run_length: f32 = @floatFromInt(run_last - x);
            scaled_u += scaled_du * run_length;
            x = run_last;
        }
    }
    return pixels_written;
}

fn rasterFlatSpanTriangle(comptime depth_test: bool, color_words: []align(4) u32, depth_words: []align(4) u32, width: u32, height: u32, stripe_count: usize, lane_index: usize, p0: [2]f32, p1: [2]f32, p2: [2]f32, inverse_area: f32, min_x: i32, min_y: i32, max_x: i32, max_y: i32, lane_min_y: i32, lane_max_y: i32, cached_spans: ?*const [flat_span_rows]FlatSpan, cached_colors: ?*const [flat_span_rows][max_color_runs]ColorRun, flat_depth_bits: u32, flat_color: ?u32, prelit_texture: ?*const [16]u32, prelit_texture_16x16: ?*const [256]u32, tile_min: ?[]u32, tile_max: ?[]u32, tile_columns: usize, tile_count: usize, flat_reciprocal_w: f32, u_over_w0: f32, u_over_w1: f32, u_over_w2: f32, v_over_w0: f32, v_over_w1: f32, v_over_w2: f32, u_over_w_dx: f32, v_over_w_dx: f32) usize {
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
        if (cached_colors) |colors| {
            for (colors[@intCast(y)]) |run| {
                if (run.last <= run.first) break;
                const run_first = @max(first, @as(i32, @intCast(run.first)));
                const run_last = @min(last, @as(i32, @intCast(run.last)));
                if (run_first < run_last) pixels_written += writeFlatColorSpan(depth_test, color_words, depth_words, width, @intCast(y), @intCast(run_first), @intCast(run_last), flat_depth_bits, run.color);
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
        while (x + 4 <= last) : (x += 4) {
            const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
            var known_tile_pass = false;
            var tile_metadata_valid = false;
            var tile_metadata_index: usize = 0;
            if (tile_min) |mins| {
                const tile_x = @as(usize, @intCast(x)) / dirty_tile_size;
                const tile_index = (@as(usize, @intCast(y)) / dirty_tile_size) * tile_columns + tile_x;
                const tile_end = @min(@as(usize, @intCast(last)), (tile_x + 1) * dirty_tile_size);
                if (tile_index < tile_count and @as(usize, @intCast(x)) + 4 <= tile_end) {
                    tile_metadata_index = lane_index * tile_count + tile_index;
                    tile_metadata_valid = true;
                    known_tile_pass = flat_depth_bits <= mins[tile_metadata_index];
                }
            }
            const passes: @Vector(4, bool) = if (known_tile_pass)
                @as(@Vector(4, bool), @splat(true))
            else
                @as(@Vector(4, u32), @splat(flat_depth_bits)) <= depth_words[pixel_index..][0..4].*;
            var colors: [4]u32 = undefined;
            if (flat_color) |color| {
                colors = .{ color, color, color, color };
            } else if (prelit_texture) |prelit| {
                inline for (0..4) |lane| {
                    const lane_u = stepped_u_over_w + u_over_w_dx * @as(f32, @floatFromInt(lane));
                    const lane_v = stepped_v_over_w + v_over_w_dx * @as(f32, @floatFromInt(lane));
                    colors[lane] = shadeUnitTexture4x4(lane_u * flat_reciprocal_w, lane_v * flat_reciprocal_w, prelit);
                }
            } else if (prelit_texture_16x16) |prelit| {
                inline for (0..4) |lane| {
                    const lane_u = stepped_u_over_w + u_over_w_dx * @as(f32, @floatFromInt(lane));
                    const lane_v = stepped_v_over_w + v_over_w_dx * @as(f32, @floatFromInt(lane));
                    colors[lane] = shadeUnitTexture16x16(lane_u * flat_reciprocal_w, lane_v * flat_reciprocal_w, prelit);
                }
            }
            var vector_written: usize = 0;
            if (known_tile_pass) {
                depth_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(flat_depth_bits));
                color_words[pixel_index..][0..4].* = colors;
                vector_written = 4;
            } else if (@reduce(.And, passes)) {
                depth_words[pixel_index..][0..4].* = @as(@Vector(4, u32), @splat(flat_depth_bits));
                color_words[pixel_index..][0..4].* = colors;
                vector_written = 4;
            } else {
                var written: usize = 0;
                inline for (0..4) |lane| {
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
            stepped_u_over_w += u_over_w_dx * 4.0;
            stepped_v_over_w += v_over_w_dx * 4.0;
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
    for (context.prepared.triangles[0..context.prepared.count], 0..) |triangle, triangle_index| {
        if (!triangle.valid) continue;
        for (0..context.height) |y| {
            if (stripeLane(@intCast(y), context.height, parallel_band_count, context.stripe_count) != lane_index) continue;
            const span = context.prepared.spans[triangle_index][y];
            if (span.last <= span.first) continue;
            const start = y * @as(usize, context.width) + span.first;
            const length = @as(usize, span.last - span.first);
            @memset(color_words[start..][0..length], color_pattern);
            @memset(depth_words[start..][0..length], depth_pattern);
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
    if (dirty_output) |output| for (commands, 0..) |command, index| {
        markPreparedDirtyTiles(&context.prepared[index], width, height, command.scissor, 0, 0, output);
    };
    if (bounds) |output| {
        output.* = .{ .x = 0, .y = 0, .width = 0, .height = 0 };
        for (commands, 0..) |command, index| {
            const draw_bounds = preparedBounds(&context.prepared[index], width, height, command.scissor);
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
    return pixels_written;
}

fn drawPreparedParallel(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: ?*Counters, clear_color_pattern: ?u32, clear_depth_pattern: ?u32, expected_target: ?[]const u8, clear_spans_requested: bool) usize {
    const dirty_bytes = dirtyTileByteCount(width, height);
    if (dirty_bytes > max_dirty_tile_bytes) return 0;
    if (expected_target) |expected| if (expected.len != target.len) return 0;
    _ = cpu_locality.pinCurrent(.render);
    var prepared: PreparedDraw = .{};
    const cache_status = prepareDrawCached(uniform, texture, texture_width, texture_height, vertex_count, viewport, &prepared);
    if (!cache_status.hit) buildPreparedFlatSpans(&prepared, width, height);
    const lighting_generation = exact_lighting_cache_generation.load(.acquire);
    if (!cache_status.hit or prepared_cache.lighting_generation != lighting_generation) {
        for (prepared.triangles[0..prepared.count]) |*triangle| {
            triangle.lighting = exactCachedLightingTable(triangleLight(triangle.vertices[0], triangle.vertices[1], triangle.vertices[2]));
        }
        prepared_cache.lighting_generation = exact_lighting_cache_generation.load(.acquire);
    }
    prepareLitTextures(&prepared, texture, texture_width, texture_height);
    if (!cache_status.hit and buildPreparedColorRuns(&prepared, width, height)) prepared.color_runs = &prepared_color_runs;
    if (cache_status.cacheable) prepared_cache.prepared = prepared;
    const prepared_ptr: *const PreparedDraw = if (cache_status.cacheable) &prepared_cache.prepared else &prepared;
    var validation_failed = std.atomic.Value(bool).init(false);
    const full_screen_scissor = scissor.x == 0 and scissor.y == 0 and scissor.width == width and scissor.height == height;
    const clear_spans = clear_spans_requested and expected_target != null and prepared.spans_valid and width == 800 and height == 600 and full_screen_scissor;
    const tile_count = ((@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size) * ((@as(usize, height) + dirty_tile_size - 1) / dirty_tile_size);
    const use_tile_depth = clear_depth_pattern != null and tile_count <= max_batch_tiles;
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
    const tile_count = ((@as(usize, width) + dirty_tile_size - 1) / dirty_tile_size) * ((@as(usize, height) + dirty_tile_size - 1) / dirty_tile_size);
    // Batched application quads are small enough that direct vector depth
    // tests beat the extra tile metadata loads and coordinate divisions.
    const use_tile_depth = false;
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
        .color_only = color_only,
    };
    if (!dispatchParallel(.{ .batch = &context })) return 0;
    var pixels_written: usize = 0;
    for (context.bands) |band| pixels_written += band.pixels_written;
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
    const written = drawParallelBatch(target, depth, width, height, commands, null, null, null);
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

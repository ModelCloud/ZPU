// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Scalar triangle setup boundary for the Mosaic renderer. The planner
//! prepares each visible primitive once; tile execution consumes this stable
//! representation instead of repeating vertex/edge/depth setup per tile.

const std = @import("std");
const pipeline = @import("mosaic_pipeline.zig");

pub const EdgeEquation = struct {
    a: f32,
    b: f32,
    c: f32,

    pub fn evaluate(self: EdgeEquation, x: f32, y: f32) f32 {
        return self.a * x + self.b * y + self.c;
    }
};

pub const SourceTriangle = struct {
    positions: [3][2]f32,
    depths: [3]f32,
    reciprocal_w: [3]f32 = .{ 1, 1, 1 },
    primitive_id: u32,
    material_id: pipeline.MaterialId,
};

pub const PreparedPrimitive = struct {
    bounds: pipeline.ScreenBounds,
    edges: [3]EdgeEquation,
    depth_origin: f32,
    depth_dx: f32,
    depth_dy: f32,
    reciprocal_w_origin: f32,
    reciprocal_w_dx: f32,
    reciprocal_w_dy: f32,
    primitive_id: u32,
    material_id: pipeline.MaterialId,
    estimated_covered_samples: u32,
    raster_path: pipeline.RasterPath,

    pub fn covers(self: PreparedPrimitive, x: f32, y: f32) bool {
        return self.edges[0].evaluate(x, y) >= 0 and self.edges[1].evaluate(x, y) >= 0 and self.edges[2].evaluate(x, y) >= 0;
    }

    pub fn depthAt(self: PreparedPrimitive, x: f32, y: f32) f32 {
        return self.depth_origin + self.depth_dx * x + self.depth_dy * y;
    }
};

pub const PreparedPrimitiveBatch = struct {
    first_primitive: u32,
    primitive_count: u16,
    estimated_covered_samples: u32,
    raster_path: pipeline.RasterPath,
};

pub const Storage = struct {
    primitives: []PreparedPrimitive,
    batches: []PreparedPrimitiveBatch,
};

pub const Result = struct {
    primitive_count: usize,
    batch_count: usize,
};

pub const Error = error{ StorageTooSmall, CountOverflow, InvalidTriangle };

fn finite2(position: [2]f32) bool {
    return std.math.isFinite(position[0]) and std.math.isFinite(position[1]);
}

fn edgeFor(a: [2]f32, b: [2]f32, winding: f32) EdgeEquation {
    return .{ .a = (a[1] - b[1]) * winding, .b = (b[0] - a[0]) * winding, .c = (a[0] * b[1] - b[0] * a[1]) * winding };
}

fn planeOrigin(values: [3]f32, positions: [3][2]f32, area: f32) struct { origin: f32, dx: f32, dy: f32 } {
    const dx = ((values[1] - values[0]) * (positions[2][1] - positions[0][1]) - (values[2] - values[0]) * (positions[1][1] - positions[0][1])) / area;
    const dy = ((values[2] - values[0]) * (positions[1][0] - positions[0][0]) - (values[1] - values[0]) * (positions[2][0] - positions[0][0])) / area;
    return .{ .origin = values[0] - dx * positions[0][0] - dy * positions[0][1], .dx = dx, .dy = dy };
}

fn floorClamped(value: f32, limit: u32) u32 {
    const integral = @floor(@as(f64, value));
    if (integral <= 0) return 0;
    if (integral >= @as(f64, @floatFromInt(limit))) return limit;
    return @intCast(@as(i64, @intFromFloat(integral)));
}

fn ceilClamped(value: f32, limit: u32) u32 {
    const integral = @ceil(@as(f64, value));
    if (integral <= 0) return 0;
    if (integral >= @as(f64, @floatFromInt(limit))) return limit;
    return @intCast(@as(i64, @intFromFloat(integral)));
}

fn pixelBounds(positions: [3][2]f32, surface_w: u32, surface_h: u32) pipeline.ScreenBounds {
    var min_x = positions[0][0];
    var max_x = positions[0][0];
    var min_y = positions[0][1];
    var max_y = positions[0][1];
    for (positions[1..]) |position| {
        min_x = @min(min_x, position[0]);
        max_x = @max(max_x, position[0]);
        min_y = @min(min_y, position[1]);
        max_y = @max(max_y, position[1]);
    }
    return .{
        .min_x = floorClamped(min_x, surface_w),
        .min_y = floorClamped(min_y, surface_h),
        .max_x = ceilClamped(max_x, surface_w),
        .max_y = ceilClamped(max_y, surface_h),
    };
}

fn preparedFinite(primitive: PreparedPrimitive) bool {
    if (!std.math.isFinite(primitive.depth_origin) or
        !std.math.isFinite(primitive.depth_dx) or
        !std.math.isFinite(primitive.depth_dy) or
        !std.math.isFinite(primitive.reciprocal_w_origin) or
        !std.math.isFinite(primitive.reciprocal_w_dx) or
        !std.math.isFinite(primitive.reciprocal_w_dy)) return false;
    for (primitive.edges) |edge| {
        if (!std.math.isFinite(edge.a) or !std.math.isFinite(edge.b) or !std.math.isFinite(edge.c)) return false;
    }
    return true;
}

fn coverageEstimate(primitive: PreparedPrimitive) u32 {
    const area = primitive.bounds.area();
    if (area == 0) return 0;
    // Small bounds are cheap to count exactly and make the tiny-primitive
    // crossover geometry-driven. Large primitives use the conservative pixel
    // footprint as a bounded preparation cost.
    if (area > 4096) return if (area > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(area);
    var covered: u32 = 0;
    var y = primitive.bounds.min_y;
    while (y < primitive.bounds.max_y) : (y += 1) {
        var x = primitive.bounds.min_x;
        while (x < primitive.bounds.max_x) : (x += 1) {
            if (primitive.covers(@as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5)) covered += 1;
        }
    }
    return covered;
}

fn prepareOne(source: SourceTriangle, surface_w: u32, surface_h: u32, crossover_samples: u32) Error!PreparedPrimitive {
    for (source.positions) |position| if (!finite2(position)) return error.InvalidTriangle;
    for (source.depths) |value| if (!std.math.isFinite(value)) return error.InvalidTriangle;
    for (source.reciprocal_w) |value| if (!std.math.isFinite(value)) return error.InvalidTriangle;
    const area = (source.positions[1][0] - source.positions[0][0]) * (source.positions[2][1] - source.positions[0][1]) - (source.positions[1][1] - source.positions[0][1]) * (source.positions[2][0] - source.positions[0][0]);
    if (!std.math.isFinite(area) or @abs(area) < 0.00001) return error.InvalidTriangle;
    const winding: f32 = if (area > 0) 1 else -1;
    const depth = planeOrigin(source.depths, source.positions, area);
    const reciprocal_w = planeOrigin(source.reciprocal_w, source.positions, area);
    var result = PreparedPrimitive{
        .bounds = pixelBounds(source.positions, surface_w, surface_h),
        .edges = .{ edgeFor(source.positions[1], source.positions[2], winding), edgeFor(source.positions[2], source.positions[0], winding), edgeFor(source.positions[0], source.positions[1], winding) },
        .depth_origin = depth.origin,
        .depth_dx = depth.dx,
        .depth_dy = depth.dy,
        .reciprocal_w_origin = reciprocal_w.origin,
        .reciprocal_w_dx = reciprocal_w.dx,
        .reciprocal_w_dy = reciprocal_w.dy,
        .primitive_id = source.primitive_id,
        .material_id = source.material_id,
        .estimated_covered_samples = 0,
        .raster_path = .primitive_simd,
    };
    result.estimated_covered_samples = coverageEstimate(result);
    result.raster_path = if (result.estimated_covered_samples <= crossover_samples) .primitive_simd else .pixel_simd;
    return result;
}

/// Prepare source triangles once and form path-homogeneous batches in source
/// order. A later tile executor may consume one batch from many tiles without
/// repeating this setup work.
pub fn prepare(source: []const SourceTriangle, surface_w: u32, surface_h: u32, crossover_samples: u32, storage: Storage) Error!Result {
    if (surface_w == 0 or surface_h == 0) return error.InvalidTriangle;
    if (source.len > std.math.maxInt(u32)) return error.CountOverflow;
    if (storage.primitives.len < source.len) return error.StorageTooSmall;
    var primitive_count: usize = 0;
    var batch_count: usize = 0;
    var current_path: ?pipeline.RasterPath = null;
    var current_first: usize = 0;
    var current_count: usize = 0;
    var current_samples: u64 = 0;
    for (source, 0..) |triangle, index| {
        const prepared = try prepareOne(triangle, surface_w, surface_h, crossover_samples);
        if (!preparedFinite(prepared)) return error.InvalidTriangle;
        storage.primitives[index] = prepared;
        primitive_count += 1;
        const starts_batch = current_path == null or current_path.? != prepared.raster_path or current_count == std.math.maxInt(u16);
        if (starts_batch) {
            if (current_path) |path| {
                if (batch_count >= storage.batches.len) return error.StorageTooSmall;
                storage.batches[batch_count] = .{ .first_primitive = @intCast(current_first), .primitive_count = @intCast(current_count), .estimated_covered_samples = @intCast(@min(current_samples, std.math.maxInt(u32))), .raster_path = path };
                batch_count += 1;
            }
            current_path = prepared.raster_path;
            current_first = index;
            current_count = 0;
            current_samples = 0;
        }
        current_count += 1;
        current_samples += prepared.estimated_covered_samples;
    }
    if (current_path) |path| {
        if (batch_count >= storage.batches.len) return error.StorageTooSmall;
        storage.batches[batch_count] = .{ .first_primitive = @intCast(current_first), .primitive_count = @intCast(current_count), .estimated_covered_samples = @intCast(@min(current_samples, std.math.maxInt(u32))), .raster_path = path };
        batch_count += 1;
    }
    return .{ .primitive_count = primitive_count, .batch_count = batch_count };
}

test "prepared geometry performs setup once and exposes scalar planes" {
    const source = [_]SourceTriangle{.{ .positions = .{ .{ 2, 2 }, .{ 12, 2 }, .{ 2, 12 } }, .depths = .{ 0.1, 0.2, 0.3 }, .primitive_id = 9, .material_id = 4 }};
    var primitives: [1]PreparedPrimitive = undefined;
    var batches: [1]PreparedPrimitiveBatch = undefined;
    const result = try prepare(&source, 32, 32, 64, .{ .primitives = &primitives, .batches = &batches });
    try std.testing.expectEqual(@as(usize, 1), result.primitive_count);
    try std.testing.expectEqual(@as(usize, 1), result.batch_count);
    try std.testing.expect(primitives[0].covers(3.5, 3.5));
    try std.testing.expectApproxEqAbs(@as(f32, 0.115), primitives[0].depthAt(2.5, 2.5), 0.00001);
}

test "prepared coverage chooses different paths for sparse and broad primitives" {
    const source = [_]SourceTriangle{
        .{ .positions = .{ .{ 1, 1 }, .{ 2, 1 }, .{ 1, 2 } }, .depths = .{ 0.1, 0.1, 0.1 }, .primitive_id = 1, .material_id = 1 },
        .{ .positions = .{ .{ 0, 0 }, .{ 80, 0 }, .{ 0, 80 } }, .depths = .{ 0.2, 0.2, 0.2 }, .primitive_id = 2, .material_id = 1 },
    };
    var primitives: [2]PreparedPrimitive = undefined;
    var batches: [2]PreparedPrimitiveBatch = undefined;
    const result = try prepare(&source, 128, 128, 16, .{ .primitives = &primitives, .batches = &batches });
    try std.testing.expectEqual(@as(usize, 2), result.primitive_count);
    try std.testing.expectEqual(pipeline.RasterPath.primitive_simd, primitives[0].raster_path);
    try std.testing.expectEqual(pipeline.RasterPath.pixel_simd, primitives[1].raster_path);
    try std.testing.expectEqual(@as(usize, 2), result.batch_count);
}

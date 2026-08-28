// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Small, deterministic CPU rasterizer for the native Metal-facing ABI.
//!
//! Work is split into two non-overlapping screen bands. The calling thread
//! owns one band and a single worker owns the other, so a 3D submission never
//! creates more than two rendering lanes and no pixel/depth lock is needed.

const std = @import("std");
const abi = @import("abi.zig");
const surface = @import("../surface.zig");

pub const Stats = struct {
    primitives_submitted: u64 = 0,
    primitives_rasterized: u64 = 0,
    fragments_tested: u64 = 0,
    fragments_covered: u64 = 0,
    depth_tests_passed: u64 = 0,
    color_writes: u64 = 0,
};

const ProjectedVertex = struct {
    x: f32,
    y: f32,
    z: f32,
    color: [4]f32,
};

pub const DrawOptions = struct {
    viewport: abi.Viewport,
    scissor: abi.ScissorRect,
    cull_mode: abi.CullMode = .none,
    winding: abi.Winding = .clockwise,
    fill_mode: abi.TriangleFillMode = .fill,
};

const Job = struct {
    target: *surface.Surface,
    depth: ?[]f32,
    vertices: []const abi.Vertex,
    primitive: abi.PrimitiveType,
    options: DrawOptions,
    bands: [2]Stats = .{ .{}, .{} },
};

fn project(vertex: abi.Vertex, viewport: abi.Viewport) ?ProjectedVertex {
    const p = vertex.position;
    if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1]) or !std.math.isFinite(p[2]) or !std.math.isFinite(p[3]) or @abs(p[3]) < 0.000001) return null;
    const inverse_w = 1.0 / p[3];
    const nx = p[0] * inverse_w;
    const ny = p[1] * inverse_w;
    const nz = p[2] * inverse_w;
    if (!std.math.isFinite(nx) or !std.math.isFinite(ny) or !std.math.isFinite(nz)) return null;
    return .{
        .x = viewport.origin_x + (nx * 0.5 + 0.5) * viewport.width,
        .y = viewport.origin_y + (ny * 0.5 + 0.5) * viewport.height,
        .z = viewport.znear + nz * (viewport.zfar - viewport.znear),
        .color = .{ vertex.color.red, vertex.color.green, vertex.color.blue, vertex.color.alpha },
    };
}

fn edge(a: ProjectedVertex, b: ProjectedVertex, x: f32, y: f32) f32 {
    return (x - a.x) * (b.y - a.y) - (y - a.y) * (b.x - a.x);
}

fn colorByte(value: f32) u8 {
    return @intFromFloat(std.math.clamp(value, 0, 1) * 255.0 + 0.5);
}

fn writePixel(job: *Job, x: usize, y: usize, z: f32, color: [4]f32, stats: *Stats) void {
    const width: usize = @intCast(job.target.width);
    if (x >= width or y >= job.target.height) return;
    stats.fragments_tested += 1;
    if (job.depth) |depth| {
        const index = y * width + x;
        if (index >= depth.len or z > depth[index]) return;
        depth[index] = z;
        stats.depth_tests_passed += 1;
    }
    const output = surface.Color.rgba(colorByte(color[0]), colorByte(color[1]), colorByte(color[2]), colorByte(color[3]));
    surface.Surface.write(job.target.row(@intCast(y)), x * 4, job.target.format, output);
    stats.fragments_covered += 1;
    stats.color_writes += 1;
}

fn scissorBounds(options: DrawOptions, width: u32, height: u32) struct { x0: usize, y0: usize, x1: usize, y1: usize } {
    const x0 = @min(@as(usize, options.scissor.x), @as(usize, width));
    const y0 = @min(@as(usize, options.scissor.y), @as(usize, height));
    const x1 = @min(x0 +| @as(usize, options.scissor.width), @as(usize, width));
    const y1 = @min(y0 +| @as(usize, options.scissor.height), @as(usize, height));
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn pixelCoordinate(value: f32, limit: usize) ?usize {
    if (!std.math.isFinite(value) or value < 0 or value >= @as(f32, @floatFromInt(limit))) return null;
    return @intFromFloat(value);
}

fn drawPoint(job: *Job, vertex: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x = pixelCoordinate(vertex.x, bounds.x1) orelse return;
    const y = pixelCoordinate(vertex.y, bounds.y1) orelse return;
    if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) return;
    writePixel(job, x, y, vertex.z, vertex.color, stats);
}

fn drawLine(job: *Job, a: ProjectedVertex, b: ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const steps_float = @ceil(@max(@abs(b.x - a.x), @abs(b.y - a.y)));
    if (!std.math.isFinite(steps_float) or steps_float > @as(f32, @floatFromInt(std.math.maxInt(u32)))) return;
    const steps: usize = @intFromFloat(steps_float);
    if (steps == 0) {
        drawPoint(job, a, y0, y1, stats);
        return;
    }
    for (0..steps + 1) |step| {
        const t = @as(f32, @floatFromInt(step)) / @as(f32, @floatFromInt(steps));
        const x_value = a.x + (b.x - a.x) * t;
        const y_value = a.y + (b.y - a.y) * t;
        const x = pixelCoordinate(x_value, bounds.x1) orelse continue;
        const y = pixelCoordinate(y_value, bounds.y1) orelse continue;
        if (x < bounds.x0 or y < @max(bounds.y0, y0) or y >= @min(bounds.y1, y1)) continue;
        writePixel(job, x, y, a.z + (b.z - a.z) * t, .{
            a.color[0] + (b.color[0] - a.color[0]) * t,
            a.color[1] + (b.color[1] - a.color[1]) * t,
            a.color[2] + (b.color[2] - a.color[2]) * t,
            a.color[3] + (b.color[3] - a.color[3]) * t,
        }, stats);
    }
}

fn drawTriangle(job: *Job, input: [3]ProjectedVertex, y0: usize, y1: usize, stats: *Stats) void {
    var vertices = input;
    const area = edge(vertices[0], vertices[1], vertices[2].x, vertices[2].y);
    if (!std.math.isFinite(area) or @abs(area) < 0.000001) return;
    const front_facing = if (job.options.winding == .clockwise) area > 0 else area < 0;
    if ((job.options.cull_mode == .front and front_facing) or (job.options.cull_mode == .back and !front_facing)) return;
    if (job.options.fill_mode == .lines) {
        drawLine(job, vertices[0], vertices[1], y0, y1, stats);
        drawLine(job, vertices[1], vertices[2], y0, y1, stats);
        drawLine(job, vertices[2], vertices[0], y0, y1, stats);
        stats.primitives_rasterized += 1;
        return;
    }

    const min_x = @max(@as(f32, 0), @floor(@min(vertices[0].x, @min(vertices[1].x, vertices[2].x))));
    const max_x = @min(@as(f32, @floatFromInt(job.target.width)), @ceil(@max(vertices[0].x, @max(vertices[1].x, vertices[2].x))));
    const min_y = @max(@as(f32, @floatFromInt(@max(y0, @min(@as(usize, job.options.scissor.y), @as(usize, job.target.height))))), @floor(@min(vertices[0].y, @min(vertices[1].y, vertices[2].y))));
    const max_y = @min(@as(f32, @floatFromInt(@min(y1, @as(usize, job.target.height)))), @ceil(@max(vertices[0].y, @max(vertices[1].y, vertices[2].y))));
    const bounds = scissorBounds(job.options, job.target.width, job.target.height);
    const x_start: usize = @intFromFloat(@min(max_x, @max(@as(f32, @floatFromInt(bounds.x0)), min_x)));
    const x_end: usize = @intFromFloat(@min(max_x, @as(f32, @floatFromInt(bounds.x1))));
    const row_start: usize = @intFromFloat(@min(max_y, @max(@as(f32, @floatFromInt(bounds.y0)), min_y)));
    const row_end: usize = @intFromFloat(@min(max_y, @as(f32, @floatFromInt(@min(bounds.y1, y1)))));
    if (x_end <= x_start or row_end <= row_start) return;
    if (area < 0) {
        const second = vertices[1];
        vertices[1] = vertices[2];
        vertices[2] = second;
    }
    const inverse_area = 1.0 / @abs(area);
    for (row_start..row_end) |y| {
        for (x_start..x_end) |x| {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const w0 = edge(vertices[1], vertices[2], px, py) * inverse_area;
            const w1 = edge(vertices[2], vertices[0], px, py) * inverse_area;
            const w2 = edge(vertices[0], vertices[1], px, py) * inverse_area;
            if (w0 < 0 or w1 < 0 or w2 < 0) continue;
            writePixel(job, x, y, vertices[0].z * w0 + vertices[1].z * w1 + vertices[2].z * w2, .{
                vertices[0].color[0] * w0 + vertices[1].color[0] * w1 + vertices[2].color[0] * w2,
                vertices[0].color[1] * w0 + vertices[1].color[1] * w1 + vertices[2].color[1] * w2,
                vertices[0].color[2] * w0 + vertices[1].color[2] * w1 + vertices[2].color[2] * w2,
                vertices[0].color[3] * w0 + vertices[1].color[3] * w1 + vertices[2].color[3] * w2,
            }, stats);
        }
    }
    stats.primitives_rasterized += 1;
}

fn drawBand(job: *Job, band: usize) Stats {
    var stats = Stats{ .primitives_submitted = if (band == 0) switch (job.primitive) {
        .point => @intCast(job.vertices.len),
        .line => @intCast(job.vertices.len / 2),
        .line_strip => if (job.vertices.len > 1) @intCast(job.vertices.len - 1) else 0,
        .triangle => @intCast(job.vertices.len / 3),
        .triangle_strip => if (job.vertices.len > 2) @intCast(job.vertices.len - 2) else 0,
    } else 0 };
    const height: usize = @intCast(job.target.height);
    const y0 = height * band / 2;
    const y1 = height * (band + 1) / 2;
    switch (job.primitive) {
        .point => for (job.vertices) |vertex| if (project(vertex, job.options.viewport)) |p| drawPoint(job, p, y0, y1, &stats),
        .line => {
            var index: usize = 0;
            while (index + 1 < job.vertices.len) : (index += 2) {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            }
        },
        .line_strip => {
            if (job.vertices.len > 1) for (0..job.vertices.len - 1) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const b = project(job.vertices[index + 1], job.options.viewport) orelse continue;
                drawLine(job, a, b, y0, y1, &stats);
            };
        },
        .triangle => {
            var index: usize = 0;
            while (index + 2 < job.vertices.len) : (index += 3) {
                const triangle = [3]ProjectedVertex{
                    project(job.vertices[index], job.options.viewport) orelse continue,
                    project(job.vertices[index + 1], job.options.viewport) orelse continue,
                    project(job.vertices[index + 2], job.options.viewport) orelse continue,
                };
                drawTriangle(job, triangle, y0, y1, &stats);
            }
        },
        .triangle_strip => {
            if (job.vertices.len > 2) for (0..job.vertices.len - 2) |index| {
                const a = project(job.vertices[index], job.options.viewport) orelse continue;
                const odd = index % 2 != 0;
                const b_index: usize = index + (if (odd) @as(usize, 2) else @as(usize, 1));
                const c_index: usize = index + (if (odd) @as(usize, 1) else @as(usize, 2));
                const b = project(job.vertices[b_index], job.options.viewport) orelse continue;
                const c = project(job.vertices[c_index], job.options.viewport) orelse continue;
                drawTriangle(job, .{ a, b, c }, y0, y1, &stats);
            };
        },
    }
    return stats;
}

fn renderWorker(job: *Job) void {
    job.bands[0] = drawBand(job, 0);
}

fn addStats(a: Stats, b: Stats) Stats {
    return .{
        .primitives_submitted = a.primitives_submitted + b.primitives_submitted,
        .primitives_rasterized = a.primitives_rasterized + b.primitives_rasterized,
        .fragments_tested = a.fragments_tested + b.fragments_tested,
        .fragments_covered = a.fragments_covered + b.fragments_covered,
        .depth_tests_passed = a.depth_tests_passed + b.depth_tests_passed,
        .color_writes = a.color_writes + b.color_writes,
    };
}

pub fn draw(target: *surface.Surface, depth: ?[]f32, vertices: []const abi.Vertex, primitive: abi.PrimitiveType, options: DrawOptions) Stats {
    var job = Job{ .target = target, .depth = depth, .vertices = vertices, .primitive = primitive, .options = options };
    const worker = std.Thread.spawn(.{}, renderWorker, .{&job}) catch {
        job.bands[0] = drawBand(&job, 0);
        job.bands[1] = drawBand(&job, 1);
        return addStats(job.bands[0], job.bands[1]);
    };
    job.bands[1] = drawBand(&job, 1);
    worker.join();
    return addStats(job.bands[0], job.bands[1]);
}

fn clearSurfaceBand(target: *surface.Surface, color: surface.Color, y0: usize, y1: usize) void {
    for (y0..y1) |y| {
        const row = target.row(@intCast(y));
        for (0..target.width) |x| surface.Surface.write(row, x * 4, target.format, color);
    }
}

pub fn clearSurface(target: *surface.Surface, color: surface.Color) void {
    const middle = @as(usize, target.height) / 2;
    const worker = std.Thread.spawn(.{}, clearSurfaceBand, .{ target, color, 0, middle }) catch {
        clearSurfaceBand(target, color, 0, @intCast(target.height));
        return;
    };
    clearSurfaceBand(target, color, middle, target.height);
    worker.join();
}

fn clearDepthBand(depth: []f32, value: f32, y0: usize, y1: usize, width: usize) void {
    for (y0..y1) |y| @memset(depth[y * width ..][0..width], value);
}

pub fn clearDepth(depth: []f32, width: u32, value: f32) void {
    if (width == 0) return;
    const rows = depth.len / @as(usize, width);
    const middle = rows / 2;
    const worker = std.Thread.spawn(.{}, clearDepthBand, .{ depth, value, 0, middle, @as(usize, width) }) catch {
        clearDepthBand(depth, value, 0, rows, @intCast(width));
        return;
    };
    clearDepthBand(depth, value, middle, rows, width);
    worker.join();
}

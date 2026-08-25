const std = @import("std");

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

fn shade(texture: []const u8, texture_width: u32, texture_height: u32, u: f32, v: f32, table: *const [256]u8) [4]u8 {
    const clamped_u = std.math.clamp(u, 0, 0.999999);
    const clamped_v = std.math.clamp(v, 0, 0.999999);
    const x: usize = @intFromFloat(clamped_u * @as(f32, @floatFromInt(texture_width)));
    const y: usize = @intFromFloat(clamped_v * @as(f32, @floatFromInt(texture_height)));
    const offset = (y * texture_width + x) * 4;
    const rgb = [3]u8{ table[texture[offset]], table[texture[offset + 1]], table[texture[offset + 2]] };
    return .{ rgb[2], rgb[1], rgb[0], texture[offset + 3] };
}

fn drawInternal(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters, optimized: bool, cull_mode: u32, front_face: i32) usize {
    if (vertex_count == 0 or vertex_count % 3 != 0 or uniform.len < 64 + @as(usize, vertex_count) * 32 or target.len != @as(usize, width) * height * 4 or depth.len < @as(usize, width) * height * 4 or texture.len != @as(usize, texture_width) * texture_height * 4 or texture_width == 0 or texture_height == 0) return 0;
    counters.triangles_submitted += vertex_count / 3;
    var pixels_written: usize = 0;
    var lighting_keys: [12]u32 = undefined;
    var lighting_tables: [12][256]u8 = undefined;
    var lighting_count: usize = 0;
    var triangle: u32 = 0;
    while (triangle < vertex_count) : (triangle += 3) {
        const v0 = transformedVertex(uniform, triangle, vertex_count, viewport) orelse continue;
        const v1 = transformedVertex(uniform, triangle + 1, vertex_count, viewport) orelse continue;
        const v2 = transformedVertex(uniform, triangle + 2, vertex_count, viewport) orelse continue;
        const p0 = [2]f32{ v0.screen[0], v0.screen[1] };
        const p1 = [2]f32{ v1.screen[0], v1.screen[1] };
        const p2 = [2]f32{ v2.screen[0], v2.screen[1] };
        const area = edge(p0, p1, p2);
        if (!std.math.isFinite(area) or @abs(area) < 0.00001) continue;
        const front_facing = if (front_face == 0) area < 0 else area > 0;
        if ((front_facing and cull_mode & 1 != 0) or (!front_facing and cull_mode & 2 != 0)) continue;
        counters.triangles_rasterized += 1;

        const dx1 = v1.screen[0] - v0.screen[0];
        const dy1 = v1.screen[1] - v0.screen[1];
        const dz1 = v1.screen[2] - v0.screen[2];
        const dx2 = v2.screen[0] - v0.screen[0];
        const dy2 = v2.screen[1] - v0.screen[1];
        const dz2 = v2.screen[2] - v0.screen[2];
        var normal = [3]f32{ dy1 * dz2 - dz1 * dy2, dz1 * dx2 - dx1 * dz2, dx1 * dy2 - dy1 * dx2 };
        const normal_length = @sqrt(normal[0] * normal[0] + normal[1] * normal[1] + normal[2] * normal[2]);
        if (normal_length > 0.000001) for (&normal) |*component| {
            component.* /= normal_length;
        };
        const light = std.math.clamp(normal[0] * 0.424 + normal[1] * 0.566 + normal[2] * 0.707, 0.15, 1.0);
        const lighting_key: u32 = @bitCast(light);
        var lighting_index: usize = 0;
        while (lighting_index < lighting_count and lighting_keys[lighting_index] != lighting_key) : (lighting_index += 1) {}
        if (lighting_index == lighting_count) {
            if (lighting_count == lighting_tables.len) lighting_index = 0;
            lighting_keys[lighting_index] = lighting_key;
            lighting_tables[lighting_index] = lightingTable(light);
            if (lighting_count < lighting_tables.len) lighting_count += 1;
        }
        const lighting = &lighting_tables[lighting_index];

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
                        counters.fragments_tested += 1;
                        if (fully_covered or (fragment_b0 >= 0 and fragment_b1 >= 0 and fragment_b2 >= 0)) {
                            counters.fragments_covered += 1;
                            const inverse_w = if (optimized) stepped_inverse_w else fragment_b0 * inv_w0 + fragment_b1 * inv_w1 + fragment_b2 * inv_w2;
                            if (@abs(inverse_w) >= 0.000001) {
                                const reciprocal_w = 1.0 / inverse_w;
                                const z_over_w = if (optimized) stepped_z_over_w else fragment_b0 * z0w + fragment_b1 * z1w + fragment_b2 * z2w;
                                const z = z_over_w * reciprocal_w;
                                const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                                const depth_offset = pixel_index * 4;
                                if (z <= readFloat(depth, depth_offset)) {
                                    counters.depth_tests_passed += 1;
                                    writeFloat(depth, depth_offset, z);
                                    const u_over_w = if (optimized) stepped_u_over_w else fragment_b0 * u_over_w0 + fragment_b1 * u_over_w1 + fragment_b2 * u_over_w2;
                                    const v_over_w = if (optimized) stepped_v_over_w else fragment_b0 * v_over_w0 + fragment_b1 * v_over_w1 + fragment_b2 * v_over_w2;
                                    const u = u_over_w * reciprocal_w;
                                    const v = v_over_w * reciprocal_w;
                                    const color = shade(texture, texture_width, texture_height, u, v, lighting);
                                    @memcpy(target[pixel_index * 4 ..][0..4], &color);
                                    counters.color_writes += 1;
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
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, true, 0, 0);
}

/// Untiled scalar oracle used by differential tests and checksum validation.
pub fn drawReferenceCounted(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, counters: *Counters) usize {
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, counters, false, 0, 0);
}

pub fn draw(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect, cull_mode: u32, front_face: i32) usize {
    var counters = Counters{};
    return drawInternal(target, depth, width, height, uniform, texture, texture_width, texture_height, vertex_count, viewport, scissor, &counters, true, cull_mode, front_face);
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

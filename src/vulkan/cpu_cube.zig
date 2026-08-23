const std = @import("std");

pub const Viewport = extern struct { x: f32, y: f32, width: f32, height: f32, min_depth: f32, max_depth: f32 };
pub const Rect = extern struct { x: i32, y: i32, width: u32, height: u32 };

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

fn shade(texture: []const u8, texture_width: u32, texture_height: u32, u: f32, v: f32, light: f32) [4]u8 {
    const clamped_u = std.math.clamp(u, 0, 0.999999);
    const clamped_v = std.math.clamp(v, 0, 0.999999);
    const x: usize = @intFromFloat(clamped_u * @as(f32, @floatFromInt(texture_width)));
    const y: usize = @intFromFloat(clamped_v * @as(f32, @floatFromInt(texture_height)));
    const offset = (y * texture_width + x) * 4;
    var rgb: [3]u8 = undefined;
    for (0..3) |channel| {
        const encoded = @as(f32, @floatFromInt(texture[offset + channel])) / 255.0;
        const lit = std.math.clamp(srgbToLinear(encoded) * light, 0, 1);
        rgb[channel] = @intFromFloat(std.math.clamp(linearToSrgb(lit), 0, 1) * 255.0);
    }
    return .{ rgb[2], rgb[1], rgb[0], texture[offset + 3] };
}

pub fn draw(target: []u8, depth: []u8, width: u32, height: u32, uniform: []const u8, texture: []const u8, texture_width: u32, texture_height: u32, vertex_count: u32, viewport: Viewport, scissor: Rect) usize {
    if (vertex_count == 0 or vertex_count % 3 != 0 or uniform.len < 64 + @as(usize, vertex_count) * 32 or target.len != @as(usize, width) * height * 4 or depth.len < @as(usize, width) * height * 4 or texture.len != @as(usize, texture_width) * texture_height * 4 or texture_width == 0 or texture_height == 0) return 0;
    var pixels_written: usize = 0;
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

        const min_x = @max(@as(i32, @intFromFloat(@floor(@min(p0[0], @min(p1[0], p2[0]))))), scissor.x, 0);
        const min_y = @max(@as(i32, @intFromFloat(@floor(@min(p0[1], @min(p1[1], p2[1]))))), scissor.y, 0);
        const max_x = @min(@as(i32, @intFromFloat(@ceil(@max(p0[0], @max(p1[0], p2[0]))))), scissor.x + @as(i32, @intCast(scissor.width)), @as(i32, @intCast(width)));
        const max_y = @min(@as(i32, @intFromFloat(@ceil(@max(p0[1], @max(p1[1], p2[1]))))), scissor.y + @as(i32, @intCast(scissor.height)), @as(i32, @intCast(height)));
        var y = min_y;
        while (y < max_y) : (y += 1) {
            var x = min_x;
            while (x < max_x) : (x += 1) {
                const sample = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
                const b0 = edge(p1, p2, sample) / area;
                const b1 = edge(p2, p0, sample) / area;
                const b2 = edge(p0, p1, sample) / area;
                if (b0 < 0 or b1 < 0 or b2 < 0) continue;
                const inverse_w = b0 / v0.clip_w + b1 / v1.clip_w + b2 / v2.clip_w;
                if (@abs(inverse_w) < 0.000001) continue;
                const z = (b0 * v0.screen[2] / v0.clip_w + b1 * v1.screen[2] / v1.clip_w + b2 * v2.screen[2] / v2.clip_w) / inverse_w;
                const pixel_index = @as(usize, @intCast(y)) * width + @as(usize, @intCast(x));
                const depth_offset = pixel_index * 4;
                if (z > readFloat(depth, depth_offset)) continue;
                writeFloat(depth, depth_offset, z);
                const u = (b0 * v0.uv[0] / v0.clip_w + b1 * v1.uv[0] / v1.clip_w + b2 * v2.uv[0] / v2.clip_w) / inverse_w;
                const v = (b0 * v0.uv[1] / v0.clip_w + b1 * v1.uv[1] / v1.clip_w + b2 * v2.uv[1] / v2.clip_w) / inverse_w;
                const color = shade(texture, texture_width, texture_height, u, v, light);
                @memcpy(target[pixel_index * 4 ..][0..4], &color);
                pixels_written += 1;
            }
        }
    }
    return pixels_written;
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
    try std.testing.expect(draw(&target, &depth, 8, 8, &uniform, &texture, 1, 1, 3, .{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 }, .{ .x = 0, .y = 0, .width = 8, .height = 8 }) > 0);
    try std.testing.expect(target[(4 * 8 + 4) * 4] != 0);
    try std.testing.expect(readFloat(&depth, (4 * 8 + 4) * 4) < 1);
}

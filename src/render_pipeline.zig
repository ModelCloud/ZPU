//! Small deterministic 2D render IR and AOT kernel selector.
const std = @import("std");
const builtin = @import("builtin");
const s = @import("surface.zig");
const dispatch = @import("simd/dispatch.zig");

pub const serialization_version: u8 = 1;
pub const kernel_abi_version: u16 = 1;
pub const compiler_version = builtin.zig_version;

pub const Operation = enum(u8) { fill, source_over, sprite };
pub const Blend = enum(u8) { replace, straight_source_over };
pub const Source = enum(u8) { constant_rgba, rgba8_pixels };
pub const CpuFeatures = packed struct(u8) { avx2: bool = false, reserved: u7 = 0 };

/// Complete immutable identity for every behavior-affecting supported trait.
pub const Key = struct {
    format: s.Format,
    operation: Operation,
    source: Source,
    blend: Blend,
    lanes: u8,
    cpu: CpuFeatures,
    compiler_major: u16,
    compiler_minor: u16,
    compiler_patch: u16,
    kernel_abi: u16,
    serialization: u8,

    pub fn init(format: s.Format, operation: Operation, backend: dispatch.Backend) Key {
        return .{
            .format = format,
            .operation = operation,
            .source = if (operation == .sprite) .rgba8_pixels else .constant_rgba,
            .blend = if (operation == .fill) .replace else .straight_source_over,
            .lanes = switch (backend) {
                .scalar => 1,
                .portable_vector => 4,
                .avx2 => 8,
            },
            .cpu = .{ .avx2 = backend == .avx2 },
            .compiler_major = compiler_version.major,
            .compiler_minor = compiler_version.minor,
            .compiler_patch = compiler_version.patch,
            .kernel_abi = kernel_abi_version,
            .serialization = serialization_version,
        };
    }

    pub const serialized_len = 15;
    pub fn serialize(self: Key) [serialized_len]u8 {
        var out: [serialized_len]u8 = undefined;
        out[0] = self.serialization;
        out[1] = @intFromEnum(self.format);
        out[2] = @intFromEnum(self.operation);
        out[3] = @intFromEnum(self.source);
        out[4] = @intFromEnum(self.blend);
        out[5] = self.lanes;
        out[6] = @bitCast(self.cpu);
        std.mem.writeInt(u16, out[7..9], self.compiler_major, .little);
        std.mem.writeInt(u16, out[9..11], self.compiler_minor, .little);
        std.mem.writeInt(u16, out[11..13], self.compiler_patch, .little);
        std.mem.writeInt(u16, out[13..15], self.kernel_abi, .little);
        return out;
    }
    pub fn eql(a: Key, b: Key) bool {
        return std.mem.eql(u8, &a.serialize(), &b.serialize());
    }
    pub fn hash(self: Key) u64 {
        var h: u64 = 14695981039346656037;
        for (self.serialize()) |byte| h = (h ^ byte) *% 1099511628211;
        return h;
    }
};

pub const Op = union(enum) {
    nop,
    fill: struct { rect: s.Rect, color: s.Color },
    blend: struct { rect: s.Rect, color: s.Color },
    sprite: struct { rect: s.Rect },
};

pub const Program = struct {
    ops: [32]Op = undefined,
    len: u8 = 0,
    pub fn append(self: *Program, op: Op) !void {
        if (self.len == self.ops.len) return error.ProgramFull;
        self.ops[self.len] = op;
        self.len += 1;
    }
    pub fn canonicalize(self: *Program, width: u32, height: u32) void {
        var write: u8 = 0;
        for (self.ops[0..self.len]) |raw| {
            var op = raw;
            switch (op) {
                .nop => continue,
                .fill => |v| op = .{ .fill = .{ .rect = s.clip(v.rect, width, height) orelse continue, .color = v.color } },
                .blend => |v| {
                    const clipped = s.clip(v.rect, width, height) orelse continue;
                    if (v.color.a == 0) continue;
                    op = if (v.color.a == 255) .{ .fill = .{ .rect = clipped, .color = v.color } } else .{ .blend = .{ .rect = clipped, .color = v.color } };
                },
                .sprite => |v| op = .{ .sprite = .{ .rect = s.clip(v.rect, width, height) orelse continue } },
            }
            if (write != 0 and sameOverwriteRegion(self.ops[write - 1], op)) write -= 1;
            self.ops[write] = op;
            write += 1;
        }
        self.len = write;
    }
};

fn sameOverwriteRegion(a: Op, b: Op) bool {
    const ar = switch (a) {
        .fill => |v| v.rect,
        else => return false,
    };
    const br = switch (b) {
        .fill => |v| v.rect,
        else => return false,
    };
    return std.meta.eql(ar, br);
}

pub const Kernel = struct {
    key: Key,
    backend: dispatch.Backend,
    pub fn fillSpan(self: Kernel, row: []u8, start: usize, count: usize, color: s.Color) !void {
        if (self.key.operation != .fill) return error.WrongKernelOperation;
        dispatch.fillSpan(self.backend, row, start, count, self.key.format, color);
    }
    pub fn blendSpan(self: Kernel, row: []u8, start: usize, count: usize, color: s.Color) !void {
        if (self.key.operation != .source_over) return error.WrongKernelOperation;
        dispatch.blendSpan(self.backend, row, start, count, self.key.format, color);
    }
    pub fn spriteSpan(self: Kernel, row: []u8, start: usize, source: []const u8, count: usize) !void {
        if (self.key.operation != .sprite) return error.WrongKernelOperation;
        dispatch.blendPixels(self.backend, row, start, source, count, self.key.format);
    }
};

pub fn compile(key: Key) !Kernel {
    if (key.serialization != serialization_version or key.kernel_abi != kernel_abi_version or key.compiler_major != compiler_version.major or key.compiler_minor != compiler_version.minor or key.compiler_patch != compiler_version.patch) return error.UnsupportedPipeline;
    const expected_source: Source = if (key.operation == .sprite) .rgba8_pixels else .constant_rgba;
    const expected_blend: Blend = if (key.operation == .fill) .replace else .straight_source_over;
    if (key.source != expected_source or key.blend != expected_blend or key.cpu.reserved != 0) return error.UnsupportedPipeline;
    const backend: dispatch.Backend = switch (key.lanes) {
        1 => .scalar,
        4 => .portable_vector,
        8 => .avx2,
        else => return error.UnsupportedPipeline,
    };
    if (key.cpu.avx2 != (backend == .avx2) or !dispatch.available(backend)) return error.UnsupportedPipeline;
    return .{ .key = key, .backend = backend };
}

pub const Cache = struct {
    const capacity = 16;
    entries: [capacity]?Kernel = [_]?Kernel{null} ** capacity,
    next: usize = 0,
    hits: u64 = 0,
    misses: u64 = 0,
    pub fn reset(self: *Cache) void {
        self.* = .{};
    }
    pub fn get(self: *Cache, key: Key) !Kernel {
        for (self.entries) |entry| if (entry) |kernel| if (Key.eql(kernel.key, key)) {
            self.hits += 1;
            return kernel;
        };
        const kernel = try compile(key);
        self.misses += 1;
        self.entries[self.next] = kernel;
        self.next = (self.next + 1) % capacity;
        return kernel;
    }
};

test "semantic keys serialize hash and compare deterministically" {
    const a = Key.init(.rgba8_unorm, .fill, .portable_vector);
    const b = Key.init(.rgba8_unorm, .fill, .portable_vector);
    try std.testing.expect(Key.eql(a, b));
    try std.testing.expectEqual(a.hash(), b.hash());
    try std.testing.expectEqualSlices(u8, &a.serialize(), &b.serialize());
    var c = b;
    c.blend = .straight_source_over;
    try std.testing.expect(!Key.eql(a, c));
    try std.testing.expect(a.hash() != c.hash());
}

test "canonical IR folds removes normalizes and safely fuses" {
    var p = Program{};
    try p.append(.nop);
    try p.append(.{ .blend = .{ .rect = .{ .x = -2, .y = 0, .width = 4, .height = 3 }, .color = .rgba(1, 2, 3, 0) } });
    try p.append(.{ .fill = .{ .rect = .{ .x = -2, .y = 0, .width = 4, .height = 3 }, .color = .rgba(1, 2, 3, 4) } });
    try p.append(.{ .blend = .{ .rect = .{ .x = 0, .y = 0, .width = 2, .height = 3 }, .color = .rgba(9, 8, 7, 255) } });
    p.canonicalize(8, 8);
    try std.testing.expectEqual(@as(u8, 1), p.len);
    try std.testing.expectEqualDeep(s.Color.rgba(9, 8, 7, 255), p.ops[0].fill.color);
}

test "cache lifecycle is deterministic and unsupported traits fail safely" {
    var cache = Cache{};
    const key = Key.init(.bgra8_unorm, .sprite, .portable_vector);
    _ = try cache.get(key);
    _ = try cache.get(key);
    try std.testing.expectEqual(@as(u64, 1), cache.hits);
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    var bad = key;
    bad.lanes = 16;
    try std.testing.expectError(error.UnsupportedPipeline, cache.get(bad));
    try std.testing.expectEqual(@as(u64, 1), cache.misses);
    var wrong_source = key;
    wrong_source.source = .constant_rgba;
    try std.testing.expectError(error.UnsupportedPipeline, cache.get(wrong_source));
    var wrong_reserved = key;
    wrong_reserved.cpu.reserved = 1;
    try std.testing.expectError(error.UnsupportedPipeline, cache.get(wrong_reserved));
    var wrong_abi = key;
    wrong_abi.kernel_abi +%= 1;
    try std.testing.expectError(error.UnsupportedPipeline, cache.get(wrong_abi));
    var pixel = [_]u8{0} ** 4;
    try std.testing.expectError(error.WrongKernelOperation, (try compile(key)).fillSpan(&pixel, 0, 1, .rgba(0, 0, 0, 0)));
    cache.reset();
    try std.testing.expectEqual(@as(u64, 0), cache.hits);
}

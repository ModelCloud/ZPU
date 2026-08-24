const std = @import("std");
const spirv = @import("spirv.zig");

pub const max_instructions: usize = 16 * 1024;
pub const max_module_bytes: usize = 1024 * 1024;
pub const max_module_words: usize = max_module_bytes / @sizeOf(u32);

pub const Error = error{ Malformed, LimitExceeded, OutOfMemory };

pub const Instruction = struct {
    opcode: u16,
    words: []const u32,
    offset: u32,
};

/// An owned decoding. Instruction operands point into `words`; callers never
/// retain pointers into VkShaderModuleCreateInfo memory.
pub const Module = struct {
    words: []u32,
    instructions: []Instruction,
    bound: u32,

    pub fn decode(allocator: std.mem.Allocator, source: []const u32) Error!Module {
        if (source.len > max_module_words) return error.LimitExceeded;
        if (source.len < 5 or source[0] != spirv.magic or source[1] != spirv.supported_spirv_version or
            source[3] == 0 or source[3] > spirv.max_id_bound or source[4] != 0)
            return error.Malformed;
        var count: usize = 0;
        var cursor: usize = 5;
        while (cursor < source.len) {
            const width = source[cursor] >> 16;
            if (width == 0 or width > source.len - cursor) return error.Malformed;
            count += 1;
            if (count > max_instructions) return error.LimitExceeded;
            cursor += width;
        }
        const words = allocator.dupe(u32, source) catch return error.OutOfMemory;
        errdefer allocator.free(words);
        const instructions = allocator.alloc(Instruction, count) catch return error.OutOfMemory;
        var index: usize = 0;
        cursor = 5;
        while (cursor < words.len) {
            const width: usize = words[cursor] >> 16;
            instructions[index] = .{
                .opcode = @truncate(words[cursor]),
                .words = words[cursor + 1 .. cursor + width],
                .offset = @intCast(cursor),
            };
            index += 1;
            cursor += width;
        }
        return .{ .words = words, .instructions = instructions, .bound = words[3] };
    }

    pub fn deinit(self: *Module, allocator: std.mem.Allocator) void {
        allocator.free(self.instructions);
        allocator.free(self.words);
        self.* = undefined;
    }
};

test "decode owns words and classifies malformed structure and limits" {
    var source = [_]u32{ spirv.magic, spirv.supported_spirv_version, 0, 2, 0, (2 << 16) | 17, 1 };
    var decoded = try Module.decode(std.testing.allocator, &source);
    defer decoded.deinit(std.testing.allocator);
    source[6] = 9;
    try std.testing.expectEqual(@as(u16, 17), decoded.instructions[0].opcode);
    try std.testing.expectEqual(@as(u32, 1), decoded.instructions[0].words[0]);
    try std.testing.expectEqual(@as(u32, 5), decoded.instructions[0].offset);
    for ([_][]const u32{
        &.{},
        &.{ spirv.magic, spirv.supported_spirv_version, 0, 1 },
        &.{ 0, spirv.supported_spirv_version, 0, 1, 0 },
        &.{ spirv.magic, 0x0001_0100, 0, 1, 0 },
        &.{ spirv.magic, spirv.supported_spirv_version, 0, 0, 0 },
        &.{ spirv.magic, spirv.supported_spirv_version, 0, spirv.max_id_bound + 1, 0 },
        &.{ spirv.magic, spirv.supported_spirv_version, 0, 1, 1 },
        &.{ spirv.magic, spirv.supported_spirv_version, 0, 1, 0, 0 },
        &.{ spirv.magic, spirv.supported_spirv_version, 0, 1, 0, (2 << 16) | 17 },
    }) |bad| try std.testing.expectError(error.Malformed, Module.decode(std.testing.allocator, bad));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, Module.decode(failing.allocator(), &source));

    const many = try std.testing.allocator.alloc(u32, 5 + max_instructions + 1);
    defer std.testing.allocator.free(many);
    @memset(many, (1 << 16) | 0);
    many[0] = spirv.magic;
    many[1] = spirv.supported_spirv_version;
    many[2] = 0x1234_0000;
    many[3] = 1;
    many[4] = 0;
    try std.testing.expectError(error.LimitExceeded, Module.decode(std.testing.allocator, many));
}

test "decode accepts exactly one MiB and rejects one additional word before allocation" {
    const exact = try std.testing.allocator.alloc(u32, max_module_words);
    defer std.testing.allocator.free(exact);
    @memset(exact, 0);
    exact[0] = spirv.magic;
    exact[1] = spirv.supported_spirv_version;
    exact[3] = 1;
    var cursor: usize = 5;
    while (exact.len - cursor > std.math.maxInt(u16)) {
        exact[cursor] = (@as(u32, std.math.maxInt(u16)) << 16);
        cursor += std.math.maxInt(u16);
    }
    exact[cursor] = (@as(u32, @intCast(exact.len - cursor)) << 16);
    var decoded = try Module.decode(std.testing.allocator, exact);
    defer decoded.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_module_words, decoded.words.len);

    const above = try std.testing.allocator.alloc(u32, max_module_words + 1);
    defer std.testing.allocator.free(above);
    @memset(above, 0);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.LimitExceeded, Module.decode(failing.allocator(), above));
}

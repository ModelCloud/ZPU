// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const frontend = @import("frontend");
const ir = frontend.ir;

fn u32le(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try list.append(allocator, @truncate(value));
    try list.append(allocator, @truncate(value >> 8));
    try list.append(allocator, @truncate(value >> 16));
    try list.append(allocator, @truncate(value >> 24));
}

/// Test-only serializer written independently from render_ir.serialize.
fn referenceSerialize(allocator: std.mem.Allocator, program: *const ir.Program) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, &.{ 90, 80, 85, 73, 82, 51, 68, 0 });
    try u32le(&out, allocator, ir.profile_version);
    try u32le(&out, allocator, ir.serialization_version);
    try out.append(allocator, @intFromEnum(program.stage));
    try u32le(&out, allocator, @intCast(program.entry_name.len));
    try out.appendSlice(allocator, program.entry_name);
    try u32le(&out, allocator, @intCast(program.interfaces.len));
    for (program.interfaces) |item| {
        try out.append(allocator, @intFromEnum(item.storage));
        try out.append(allocator, @intFromEnum(item.ty.scalar));
        try out.append(allocator, item.ty.columns);
        try out.append(allocator, item.ty.rows);
        try u32le(&out, allocator, item.location orelse 0xffff_ffff);
        try u32le(&out, allocator, item.descriptor_set orelse 0xffff_ffff);
        try u32le(&out, allocator, item.binding orelse 0xffff_ffff);
        try out.append(allocator, @intFromBool(item.builtin_position));
        try out.append(allocator, @intFromBool(item.builtin_frag_coord));
        try out.append(allocator, @intFromBool(item.builtin_front_facing));
        try out.append(allocator, @intFromBool(item.flat));
        try out.append(allocator, @intFromBool(item.block));
        try out.append(allocator, item.member_count);
        for (item.members[0..item.member_count]) |member| {
            try out.append(allocator, @intFromEnum(member.ty.scalar));
            try out.append(allocator, member.ty.columns);
            try out.append(allocator, member.ty.rows);
            try u32le(&out, allocator, member.offset);
        }
    }
    try u32le(&out, allocator, @intCast(program.instructions.len));
    for (program.instructions) |item| {
        try out.append(allocator, @intFromEnum(item.op));
        try out.append(allocator, @intFromEnum(item.ty.scalar));
        try out.append(allocator, item.ty.columns);
        try out.append(allocator, item.ty.rows);
        try u32le(&out, allocator, @intCast(item.operands.len));
        for (item.operands) |operand| try u32le(&out, allocator, operand);
        try u32le(&out, allocator, @intCast(item.literal.len));
        try out.appendSlice(allocator, item.literal);
    }
    return out.toOwnedSlice(allocator);
}

fn staticGolden(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len % 2 != 0) return error.InvalidGolden;
    const bytes = try allocator.alloc(u8, trimmed.len / 2);
    errdefer allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = std.fmt.parseInt(u8, trimmed[index * 2 ..][0..2], 16) catch return error.InvalidGolden;
    return bytes;
}

const Value = struct { lanes: [16]f32 = .{0} ** 16, count: usize = 0 };

/// Test-only interpreter for constant frontend semantics. It is never called
/// by vkCmdDraw and intentionally has no image, raster, or Vulkan state.
fn referenceInterpret(program: *const ir.Program) !Value {
    var values: [ir.max_instructions]Value = undefined;
    var output: Value = .{};
    for (program.instructions, 0..) |instruction, index| switch (instruction.op) {
        .constant => {
            values[index].count = instruction.ty.columns * instruction.ty.rows;
            for (0..values[index].count) |lane| values[index].lanes[lane] = @bitCast(std.mem.readInt(u32, instruction.literal[lane * 4 ..][0..4], .little));
        },
        .constant_composite, .composite => {
            values[index].count = 0;
            for (instruction.operands) |operand| for (values[operand].lanes[0..values[operand].count]) |lane| {
                values[index].lanes[values[index].count] = lane;
                values[index].count += 1;
            };
        },
        .matrix_times_vector => {
            const matrix = values[instruction.operands[0]];
            const vector = values[instruction.operands[1]];
            values[index].count = 4;
            for (0..4) |row| {
                for (0..4) |column| values[index].lanes[row] += matrix.lanes[column * 4 + row] * vector.lanes[column];
            }
        },
        .output => output = values[instruction.operands[1]],
        else => return error.UnsupportedReferenceOperation,
    };
    return output;
}

test "independent serializer and frontend-only interpreter match canonical program" {
    var program = try frontend.compile(std.testing.allocator, &frontend.positive_vertex, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    const bytes = try referenceSerialize(std.testing.allocator, &program);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, program.bytes, bytes);
    const value = try referenceInterpret(&program);
    try std.testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, value.lanes[0..value.count]);

    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    const cases = .{
        .{ &frontend.rich_vertex, ir.Stage.vertex, &[_]frontend.Specialization{.{ .id = 7, .bytes = &replacement }} },
        .{ &frontend.uniform_vertex, ir.Stage.vertex, &[_]frontend.Specialization{} },
        .{ &frontend.bool_fragment, ir.Stage.fragment, &[_]frontend.Specialization{} },
    };
    inline for (cases) |case| {
        var other = try frontend.compile(std.testing.allocator, case[0], case[1], "main", case[2]);
        defer other.deinit(std.testing.allocator);
        const reference = try referenceSerialize(std.testing.allocator, &other);
        defer std.testing.allocator.free(reference);
        try std.testing.expectEqualSlices(u8, other.bytes, reference);
    }
}

test "checked-in full canonical bytes and digests are exact" {
    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    const cases = .{
        .{ &frontend.positive_vertex, ir.Stage.vertex, &[_]frontend.Specialization{}, @embedFile("fixtures/render_ir/basic.hex"), [32]u8{ 203, 242, 69, 54, 222, 0, 3, 151, 46, 85, 239, 251, 223, 126, 162, 154, 1, 126, 42, 74, 37, 90, 185, 28, 113, 134, 45, 69, 241, 214, 26, 246 } },
        .{ &frontend.rich_vertex, ir.Stage.vertex, &[_]frontend.Specialization{.{ .id = 7, .bytes = &replacement }}, @embedFile("fixtures/render_ir/rich-specialized.hex"), [32]u8{ 32, 54, 120, 171, 171, 47, 37, 140, 249, 223, 164, 90, 213, 117, 244, 105, 27, 199, 198, 147, 250, 157, 214, 189, 189, 56, 122, 213, 62, 182, 128, 184 } },
        .{ &frontend.uniform_vertex, ir.Stage.vertex, &[_]frontend.Specialization{}, @embedFile("fixtures/render_ir/uniform.hex"), [32]u8{ 4, 251, 107, 70, 145, 166, 94, 68, 132, 217, 147, 216, 245, 172, 184, 175, 208, 170, 80, 235, 66, 218, 171, 187, 47, 60, 251, 20, 5, 236, 98, 211 } },
        .{ &frontend.bool_fragment, ir.Stage.fragment, &[_]frontend.Specialization{}, @embedFile("fixtures/render_ir/fragment.hex"), [32]u8{ 3, 96, 59, 154, 106, 162, 89, 4, 120, 130, 239, 208, 160, 86, 145, 157, 132, 181, 51, 33, 96, 218, 195, 223, 199, 40, 210, 139, 230, 176, 86, 139 } },
    };
    inline for (cases) |case| {
        var program = try frontend.compile(std.testing.allocator, case[0], case[1], "main", case[2]);
        defer program.deinit(std.testing.allocator);
        const golden = try staticGolden(std.testing.allocator, case[3]);
        defer std.testing.allocator.free(golden);
        try std.testing.expectEqualSlices(u8, golden, program.bytes);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(golden, &digest, .{});
        try std.testing.expectEqual(case[4], digest);
        try std.testing.expectEqual(case[4], program.identity.digest);
        const reference = try referenceSerialize(std.testing.allocator, &program);
        defer std.testing.allocator.free(reference);
        try std.testing.expectEqualSlices(u8, golden, reference);
    }
}

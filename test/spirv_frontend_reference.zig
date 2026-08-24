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
    try u32le(&out, allocator, 1);
    try u32le(&out, allocator, 1);
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
        .composite => {
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
}

const std = @import("std");
pub const decode = @import("spirv_decode.zig");
pub const ir = @import("render_ir.zig");

pub const max_profile_bound: u32 = 8192;
pub const max_interfaces: usize = 64;
pub const max_specializations: usize = 64;
pub const max_uniform_block_bytes: u32 = 16 * 1024;
const max_debug_string_words: u16 = 256;
const max_entry_point_operands: u16 = 3 + 64 + @as(u16, max_interfaces);

pub const Error = error{ Malformed, Unsupported, LimitExceeded, OutOfMemory };

pub const Specialization = struct { id: u32, bytes: []const u8 };

const Kind = enum { none, void, bool, int, float, vector, matrix, pointer, structure, function, ext_inst_import, constant, variable, function_value, label };
const Node = struct {
    kind: Kind = .none,
    type_id: u32 = 0,
    a: u32 = 0,
    b: u32 = 0,
    opcode: u16 = 0,
    words: []const u32 = &.{},
};
const Decorations = struct {
    spec_id: ?u32 = null,
    location: ?u32 = null,
    binding: ?u32 = null,
    descriptor_set: ?u32 = null,
    builtin_position: bool = false,
    block: bool = false,
};
const Entry = struct { stage: ir.Stage, function: u32, name: []const u8, interfaces: []const u32 };

/// A bounded, side-effect-free structured conditional that can be lowered to
/// a canonical SSA select.  General control flow remains outside profile v1;
/// retaining this metadata lets the lowering preserve both branch values
/// without executing either branch as a host-side side effect.
const DynamicBranch = struct {
    condition: u32,
    true_label: u32,
    false_label: u32,
    merge_label: u32,
};

const DynamicSwitch = struct {
    selector: u32,
    case_value: u32,
    case_label: u32,
    default_label: u32,
    merge_label: u32,
};

const Count = struct { min: u16, max: u16 };
const OpcodeMeta = struct { opcode: u16, operands: Count, supported: bool = true };
const opcode_schema = [_]OpcodeMeta{
    .{ .opcode = 0, .operands = .{ .min = 0, .max = 0 } },
    .{ .opcode = 317, .operands = .{ .min = 0, .max = 0 } }, // OpNoLine
    .{ .opcode = 2, .operands = .{ .min = 1, .max = max_debug_string_words } },
    .{ .opcode = 3, .operands = .{ .min = 2, .max = 3 + max_debug_string_words } },
    .{ .opcode = 4, .operands = .{ .min = 1, .max = max_debug_string_words } },
    .{ .opcode = 5, .operands = .{ .min = 2, .max = 1 + max_debug_string_words } },
    .{ .opcode = 6, .operands = .{ .min = 3, .max = 2 + max_debug_string_words } },
    .{ .opcode = 7, .operands = .{ .min = 2, .max = 1 + max_debug_string_words } },
    .{ .opcode = 8, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 11, .operands = .{ .min = 2, .max = 1 + max_debug_string_words } }, // OpExtInstImport
    .{ .opcode = 12, .operands = .{ .min = 4, .max = 7 } }, // OpExtInst (bounded GLSL.std.450)
    .{ .opcode = 14, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 15, .operands = .{ .min = 3, .max = max_entry_point_operands } },
    .{ .opcode = 16, .operands = .{ .min = 2, .max = 5 } },
    .{ .opcode = 17, .operands = .{ .min = 1, .max = 1 } },
    .{ .opcode = 19, .operands = .{ .min = 1, .max = 1 } },
    .{ .opcode = 20, .operands = .{ .min = 1, .max = 1 } },
    .{ .opcode = 21, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 22, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 23, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 24, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 30, .operands = .{ .min = 1, .max = 17 } },
    .{ .opcode = 32, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 33, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 41, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 42, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 43, .operands = .{ .min = 3, .max = 6 } },
    .{ .opcode = 44, .operands = .{ .min = 3, .max = 18 } },
    .{ .opcode = 48, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 49, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 50, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 51, .operands = .{ .min = 3, .max = 18 }, .supported = false },
    .{ .opcode = 54, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 56, .operands = .{ .min = 0, .max = 0 } },
    .{ .opcode = 59, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 61, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 62, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 65, .operands = .{ .min = 4, .max = 19 } },
    .{ .opcode = 79, .operands = .{ .min = 5, .max = 8 } },
    .{ .opcode = 80, .operands = .{ .min = 3, .max = 18 } },
    .{ .opcode = 81, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 82, .operands = .{ .min = 5, .max = 5 } },
    .{ .opcode = 83, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 84, .operands = .{ .min = 3, .max = 3 } },
    // Branch widths are checked by the stage-aware function parser below so
    // non-compute profiles classify the entire family as unsupported rather
    // than exposing a misleading schema-arity error.
    .{ .opcode = 249, .operands = .{ .min = 0, .max = max_entry_point_operands } },
    .{ .opcode = 250, .operands = .{ .min = 0, .max = max_entry_point_operands } },
    .{ .opcode = 251, .operands = .{ .min = 0, .max = max_entry_point_operands } },
    .{ .opcode = 245, .operands = .{ .min = 0, .max = max_entry_point_operands } },
    .{ .opcode = 109, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 110, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 111, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 112, .operands = .{ .min = 3, .max = 3 } },
    // The bounded IR has only 32-bit scalar domains, so the 32-bit
    // SConvert/UConvert/FConvert forms are exact type conversions.
    .{ .opcode = 113, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 114, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 115, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 116, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 124, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 126, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 127, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 128, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 129, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 130, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 131, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 132, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 133, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 134, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 135, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 136, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 137, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 138, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 139, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 140, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 141, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 142, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 143, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 144, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 145, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 146, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 147, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 148, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 149, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 150, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 151, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 152, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 154, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 155, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 156, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 157, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 158, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 159, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 160, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 161, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 162, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 163, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 164, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 165, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 166, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 167, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 168, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 169, .operands = .{ .min = 5, .max = 5 } },
    .{ .opcode = 170, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 171, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 172, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 173, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 174, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 175, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 176, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 177, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 178, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 179, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 182, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 183, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 184, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 185, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 186, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 187, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 188, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 189, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 190, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 191, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 192, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 193, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 194, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 195, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 196, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 197, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 198, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 199, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 200, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 77, .operands = .{ .min = 4, .max = 4 } },
    .{ .opcode = 78, .operands = .{ .min = 5, .max = 5 } },
    .{ .opcode = 201, .operands = .{ .min = 6, .max = 6 } },
    .{ .opcode = 202, .operands = .{ .min = 5, .max = 5 } },
    .{ .opcode = 203, .operands = .{ .min = 5, .max = 5 } },
    .{ .opcode = 204, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 205, .operands = .{ .min = 3, .max = 3 } },
    .{ .opcode = 248, .operands = .{ .min = 1, .max = 1 } },
    // Structured selection metadata is semantically consumed by the CFG
    // resolver; only the default control mask is admitted in profile v1.
    .{ .opcode = 247, .operands = .{ .min = 2, .max = 2 } },
    .{ .opcode = 253, .operands = .{ .min = 0, .max = 0 } },
    .{ .opcode = 71, .operands = .{ .min = 2, .max = 3 } },
    .{ .opcode = 72, .operands = .{ .min = 3, .max = 4 } },
    .{ .opcode = 999, .operands = .{ .min = 0, .max = 0 }, .supported = false },
};

fn opcodeMeta(opcode: u16) ?OpcodeMeta {
    for (opcode_schema) |meta| if (meta.opcode == opcode) return meta;
    return null;
}

const ValueMeta = struct { value: u32, supported: bool, operands: Count = .{ .min = 0, .max = 0 } };
const capability_schema = [_]ValueMeta{.{ .value = 1, .supported = true }};
const storage_schema = [_]ValueMeta{
    .{ .value = 1, .supported = true },  .{ .value = 2, .supported = true },   .{ .value = 3, .supported = true },
    .{ .value = 9, .supported = false }, .{ .value = 12, .supported = false },
};
const type_schema = [_]ValueMeta{
    .{ .value = 19, .supported = true }, .{ .value = 20, .supported = true },
    .{ .value = 21, .supported = true }, .{ .value = 22, .supported = true },
    .{ .value = 23, .supported = true }, .{ .value = 24, .supported = true },
    .{ .value = 30, .supported = true }, .{ .value = 32, .supported = true },
    .{ .value = 33, .supported = true },
};
const decoration_schema = [_]ValueMeta{
    .{ .value = 1, .supported = true, .operands = .{ .min = 1, .max = 1 } },
    .{ .value = 2, .supported = true },
    .{ .value = 11, .supported = true, .operands = .{ .min = 1, .max = 1 } },
    .{ .value = 30, .supported = true, .operands = .{ .min = 1, .max = 1 } },
    .{ .value = 33, .supported = true, .operands = .{ .min = 1, .max = 1 } },
    .{ .value = 34, .supported = true, .operands = .{ .min = 1, .max = 1 } },
    .{ .value = 35, .supported = true, .operands = .{ .min = 1, .max = 1 } },
};
const execution_mode_schema = [_]ValueMeta{
    .{ .value = 7, .supported = false },                                       .{ .value = 8, .supported = false },
    .{ .value = 17, .supported = false, .operands = .{ .min = 3, .max = 3 } },
};

fn valueMeta(schema: []const ValueMeta, value: u32) ?ValueMeta {
    for (schema) |meta| if (meta.value == value) return meta;
    return null;
}

fn validateProfileSchema(module: *const decode.Module) Error!void {
    for (module.instructions) |instruction| {
        const meta = opcodeMeta(instruction.opcode) orelse return error.Unsupported;
        if (instruction.words.len < meta.operands.min or instruction.words.len > meta.operands.max) return error.Malformed;
        if (instruction.opcode >= 19 and instruction.opcode <= 33 and valueMeta(&type_schema, instruction.opcode) == null) return error.Unsupported;
    }
}

fn uniformSizeAlignment(shape: ir.Type) Error!struct { size: u32, alignment: u32 } {
    if (shape.rows == 4 and shape.columns == 4 and shape.scalar == .f32) return .{ .size = 64, .alignment = 16 };
    if (shape.rows != 1) return error.Unsupported;
    return switch (shape.columns) {
        1 => .{ .size = 4, .alignment = 4 },
        2 => .{ .size = 8, .alignment = 8 },
        3 => .{ .size = 12, .alignment = 16 },
        4 => .{ .size = 16, .alignment = 16 },
        else => error.Unsupported,
    };
}

fn stringOperand(words: []const u32) Error!struct { value: []const u8, word_count: usize } {
    const bytes = std.mem.sliceAsBytes(words);
    const end = std.mem.indexOfScalar(u8, bytes, 0) orelse return error.Malformed;
    const word_count = end / 4 + 1;
    for (bytes[end + 1 .. @min(bytes.len, word_count * 4)]) |byte| if (byte != 0) return error.Malformed;
    return .{ .value = bytes[0..end], .word_count = word_count };
}

fn id(nodes: []const Node, value: u32) Error!usize {
    if (value == 0 or value >= nodes.len) return error.Malformed;
    return @intCast(value);
}

fn resultShape(nodes: []const Node, type_id: u32) Error!ir.Type {
    const node = nodes[try id(nodes, type_id)];
    return switch (node.kind) {
        .bool => .{ .scalar = .bool },
        .int => if (node.a == 32) .{ .scalar = if (node.b == 0) .u32 else .i32 } else error.Unsupported,
        .float => if (node.a == 32) .{ .scalar = .f32 } else error.Unsupported,
        .vector => blk: {
            if (node.b < 2 or node.b > 4) return error.Unsupported;
            var shape = try resultShape(nodes, node.a);
            if (shape.columns != 1 or shape.rows != 1) return error.Unsupported;
            shape.columns = @intCast(node.b);
            break :blk shape;
        },
        .matrix => blk: {
            if (node.b != 4) return error.Unsupported;
            const column = try resultShape(nodes, node.a);
            if (column.scalar != .f32 or column.columns != 4 or column.rows != 1) return error.Unsupported;
            break :blk .{ .scalar = .f32, .columns = 4, .rows = 4 };
        },
        // The bounded arithmetic profile represents the two scalar members
        // returned by OpIAddCarry/OpISubBorrow/OpUMulExtended/OpSMulExtended
        // as a two-lane value.  General arrays and structures remain outside
        // the profile; only this exact pair shape is admitted.
        .structure => blk: {
            if (node.words.len != 2) return error.Unsupported;
            const first = try resultShape(nodes, node.words[0]);
            const second = try resultShape(nodes, node.words[1]);
            if (!sameShape(first, second) or first.columns != 1 or first.rows != 1 or (first.scalar != .i32 and first.scalar != .u32)) return error.Unsupported;
            var pair = first;
            pair.columns = 2;
            break :blk pair;
        },
        else => error.Unsupported,
    };
}

fn sameShape(a: ir.Type, b: ir.Type) bool {
    return a.scalar == b.scalar and a.columns == b.columns and a.rows == b.rows;
}

fn supportedGlslExtInst(ext: u32, result: ir.Type, operand: ir.Type) bool {
    return switch (ext) {
        33 => result.scalar == .f32 and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.columns == 4 and operand.rows == 4,
        34 => result.scalar == .f32 and result.columns == 4 and result.rows == 4 and sameShape(result, operand),
        53 => result.scalar == .f32 and result.rows == 1 and sameShape(result, operand),
        54, 55 => (result.scalar == .i32 or result.scalar == .u32) and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.columns == 4 and operand.rows == 1,
        56, 57 => (result.scalar == .i32 or result.scalar == .u32) and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.columns == 2 and operand.rows == 1,
        58 => (result.scalar == .i32 or result.scalar == .u32) and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.columns == 2 and operand.rows == 1,
        59, 60 => result.scalar == .f32 and result.columns == 2 and result.rows == 1 and (operand.scalar == .i32 or operand.scalar == .u32) and operand.columns == 1 and operand.rows == 1,
        61 => result.scalar == .f32 and result.columns == 2 and result.rows == 1 and (operand.scalar == .i32 or operand.scalar == .u32) and operand.columns == 1 and operand.rows == 1,
        62, 63 => result.scalar == .f32 and result.columns == 4 and result.rows == 1 and (operand.scalar == .i32 or operand.scalar == .u32) and operand.columns == 1 and operand.rows == 1,
        65 => result.scalar == .f32 and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.rows == 1 and operand.columns >= 2 and operand.columns <= 4,
        66 => result.scalar == .f32 and result.columns == 1 and result.rows == 1 and operand.scalar == .f32 and operand.rows == 1 and operand.columns >= 2 and operand.columns <= 4,
        67 => result.scalar == .f32 and result.columns == 3 and result.rows == 1 and operand.scalar == .f32 and operand.columns == 3 and operand.rows == 1,
        68, 69, 70, 71 => result.scalar == .f32 and result.rows == 1 and result.columns >= 2 and result.columns <= 4 and sameShape(result, operand),
        72 => result.scalar == .i32 and result.rows == 1 and result.columns >= 1 and result.columns <= 4 and operand.rows == 1 and operand.columns == result.columns and (operand.scalar == .i32 or operand.scalar == .u32),
        73 => result.scalar == .i32 and result.rows == 1 and result.columns >= 1 and result.columns <= 4 and operand.scalar == .i32 and operand.rows == 1 and operand.columns == result.columns,
        74 => result.scalar == .i32 and result.rows == 1 and result.columns >= 1 and result.columns <= 4 and operand.scalar == .u32 and operand.rows == 1 and operand.columns == result.columns,
        else => blk: {
            if (!sameShape(result, operand)) break :blk false;
            break :blk switch (ext) {
                1, 2, 3, 4, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 27, 28, 29, 30, 31, 32 => result.scalar == .f32,
                25, 26 => result.scalar == .f32 and result.rows == 1,
                5 => result.scalar == .i32,
                6 => result.scalar == .f32 and result.rows == 1,
                7 => result.scalar == .i32 and result.rows == 1,
                // GLSL.std.450 FMin/FMax and integer min/max accept scalar or vector
                // values; the bounded IR deliberately excludes matrix operands.
                37, 40 => result.scalar == .f32 and result.rows == 1,
                38, 41 => result.scalar == .u32 and result.rows == 1,
                39, 42 => result.scalar == .i32 and result.rows == 1,
                43 => result.scalar == .f32 and result.rows == 1,
                44 => result.scalar == .u32 and result.rows == 1,
                45 => result.scalar == .i32 and result.rows == 1,
                46, 48, 49, 50, 79, 80, 81 => result.scalar == .f32 and result.rows == 1,
                else => false,
            };
        },
    };
}

fn valueShape(nodes: []const Node, value_id: u32) Error!ir.Type {
    const value = nodes[try id(nodes, value_id)];
    if (value.kind != .constant and value.kind != .function_value) return error.Malformed;
    return resultShape(nodes, value.type_id);
}

const ScalarClass = enum { integer, float };
fn scalarClass(shape: ir.Type, class: ScalarClass) bool {
    return switch (class) {
        .integer => shape.scalar == .i32 or shape.scalar == .u32,
        .float => shape.scalar == .f32,
    };
}

/// Resolve the bounded static boolean conditions used by compute control
/// flow. Integer comparisons are admitted only when both operands are literal
/// scalar constants; dynamic comparisons remain outside the profile.
fn staticCondition(nodes: []const Node, value_id: u32) Error!?bool {
    return staticConditionAt(nodes, value_id, 0);
}

fn staticConditionAt(nodes: []const Node, value_id: u32, depth: u8) Error!?bool {
    if (depth >= 64) return error.Unsupported;
    const node = nodes[try id(nodes, value_id)];
    if (node.kind == .constant) return switch (node.opcode) {
        41 => true,
        42 => false,
        else => null,
    };
    if (node.kind != .function_value) return null;
    if (node.opcode >= 164 and node.opcode <= 168) {
        const operand_count: usize = if (node.opcode == 168) 1 else 2;
        if (node.words.len != operand_count) return error.Malformed;
        const left = try staticConditionAt(nodes, node.words[0], depth + 1) orelse return null;
        if (node.opcode == 168) return !left;
        const right = try staticConditionAt(nodes, node.words[1], depth + 1) orelse return null;
        return switch (node.opcode) {
            164 => left == right,
            165 => left != right,
            166 => left or right,
            167 => left and right,
            else => unreachable,
        };
    }
    if (node.opcode == 169) {
        if (node.words.len != 3) return error.Malformed;
        const condition = try staticConditionAt(nodes, node.words[0], depth + 1) orelse return null;
        return staticConditionAt(nodes, if (condition) node.words[1] else node.words[2], depth + 1);
    }
    if (node.opcode < 170 or node.opcode > 179) return null;
    if (node.words.len != 2) return error.Malformed;
    const left = nodes[try id(nodes, node.words[0])];
    const right = nodes[try id(nodes, node.words[1])];
    if (left.kind != .constant or right.kind != .constant or left.opcode != 43 or right.opcode != 43) return null;
    const left_shape = try resultShape(nodes, left.type_id);
    const right_shape = try resultShape(nodes, right.type_id);
    if (!sameShape(left_shape, right_shape) or !scalarClass(left_shape, .integer) or left_shape.columns != 1 or left_shape.rows != 1 or left.words.len != 1 or right.words.len != 1) return error.Malformed;
    const unsigned_left = left.words[0];
    const unsigned_right = right.words[0];
    const signed_left: i32 = @bitCast(unsigned_left);
    const signed_right: i32 = @bitCast(unsigned_right);
    return switch (node.opcode) {
        170 => unsigned_left == unsigned_right,
        171 => unsigned_left != unsigned_right,
        172 => unsigned_left > unsigned_right,
        173 => unsigned_left >= unsigned_right,
        174 => unsigned_left < unsigned_right,
        175 => unsigned_left <= unsigned_right,
        176 => signed_left > signed_right,
        177 => signed_left >= signed_right,
        178 => signed_left < signed_right,
        179 => signed_left <= signed_right,
        else => unreachable,
    };
}

fn define(nodes: []Node, result_id: u32, node: Node) Error!void {
    const index = try id(nodes, result_id);
    if (nodes[index].kind != .none) return error.Malformed;
    nodes[index] = node;
}

fn checkSpecializations(specs: []const Specialization) Error!void {
    if (specs.len > max_specializations) return error.LimitExceeded;
    for (specs, 0..) |item, i| {
        if (item.bytes.len != 4) return error.Unsupported;
        for (specs[0..i]) |prior| if (prior.id == item.id) return error.Malformed;
    }
}

fn interfaceLess(_: void, a: ir.Interface, b: ir.Interface) bool {
    if (@intFromEnum(a.storage) != @intFromEnum(b.storage)) return @intFromEnum(a.storage) < @intFromEnum(b.storage);
    if ((a.descriptor_set orelse 0) != (b.descriptor_set orelse 0)) return (a.descriptor_set orelse 0) < (b.descriptor_set orelse 0);
    if ((a.binding orelse 0) != (b.binding orelse 0)) return (a.binding orelse 0) < (b.binding orelse 0);
    return (a.location orelse std.math.maxInt(u32)) < (b.location orelse std.math.maxInt(u32));
}

fn indexedType(nodes: []const Node, current_type: u32, index: u32) Error!u32 {
    const aggregate = nodes[try id(nodes, current_type)];
    return switch (aggregate.kind) {
        .structure => if (index < aggregate.words.len) aggregate.words[index] else error.Unsupported,
        .vector => if (index < aggregate.b) aggregate.a else error.Unsupported,
        .matrix => if (index < aggregate.b) aggregate.a else error.Unsupported,
        else => error.Unsupported,
    };
}

fn interfacesUnique(items: []const ir.Interface) bool {
    if (items.len < 2) return true;
    for (items[1..], items[0 .. items.len - 1]) |item, prior| {
        if (item.storage != prior.storage) continue;
        if (item.storage == .uniform) {
            if (item.descriptor_set == prior.descriptor_set and item.binding == prior.binding) return false;
        } else if ((item.builtin_position and prior.builtin_position) or (item.location != null and item.location == prior.location)) return false;
    }
    return true;
}

fn findLabelOffset(module: *const decode.Module, instruction_functions: []const u32, function: u32, label: u32) ?usize {
    for (module.instructions, instruction_functions, 0..) |instruction, instruction_function, instruction_index| {
        if (instruction_function == function and instruction.opcode == 248 and instruction.words.len == 1 and instruction.words[0] == label)
            return instruction_index;
    }
    return null;
}

/// Mark one side of the narrow dynamic-conditional profile.  The arm must be
/// a straight-line, side-effect-free block ending in an unconditional branch
/// to the merge label.  This deliberately excludes stores, nested branches,
/// loops, and phi nodes; those require a real CFG executor rather than a
/// select lowering.
fn markDynamicArm(
    module: *const decode.Module,
    instruction_functions: []const u32,
    function: u32,
    start: usize,
    label: u32,
    merge_label: u32,
    reachable: []bool,
    predecessor: []u32,
) Error!void {
    var cursor = start;
    while (cursor < module.instructions.len and instruction_functions[cursor] == function) : (cursor += 1) {
        const instruction = module.instructions[cursor];
        if (cursor != start and instruction.opcode == 248) return error.Unsupported;
        reachable[cursor] = true;
        predecessor[cursor] = label;
        switch (instruction.opcode) {
            249 => {
                if (instruction.words.len != 1 or instruction.words[0] != merge_label) return error.Unsupported;
                return;
            },
            245, 250, 251, 252, 253, 56, 62 => return error.Unsupported,
            else => {},
        }
    }
    return error.Malformed;
}

fn dynamicArmTarget(
    module: *const decode.Module,
    instruction_functions: []const u32,
    function: u32,
    start: usize,
) Error!u32 {
    var cursor = start;
    while (cursor < module.instructions.len and instruction_functions[cursor] == function) : (cursor += 1) {
        const instruction = module.instructions[cursor];
        if (cursor != start and instruction.opcode == 248) return error.Unsupported;
        switch (instruction.opcode) {
            249 => {
                if (instruction.words.len != 1) return error.Malformed;
                return instruction.words[0];
            },
            245, 250, 251, 252, 253, 56, 62 => return error.Unsupported,
            else => {},
        }
    }
    return error.Malformed;
}

/// Strict zpu_spirv_render_profile_v1 compilation. `Malformed` denotes broken
/// SPIR-V structure/def-use; `Unsupported` denotes valid constructs outside
/// this deliberately small frontend profile.
pub fn compile(allocator: std.mem.Allocator, words: []const u32, requested_stage: ir.Stage, requested_entry: []const u8, specs: []const Specialization) Error!ir.Program {
    try checkSpecializations(specs);
    var module = decode.Module.decode(allocator, words) catch |err| return switch (err) {
        error.Malformed => error.Malformed,
        error.LimitExceeded => error.LimitExceeded,
        error.OutOfMemory => error.OutOfMemory,
    };
    defer module.deinit(allocator);
    try validateProfileSchema(&module);
    if (module.bound > max_profile_bound) return error.LimitExceeded;
    const nodes = allocator.alloc(Node, module.bound) catch return error.OutOfMemory;
    defer allocator.free(nodes);
    @memset(nodes, .{});
    const decorations = allocator.alloc(Decorations, module.bound) catch return error.OutOfMemory;
    defer allocator.free(decorations);
    @memset(decorations, .{});
    const member_offsets = allocator.alloc(?u32, @as(usize, module.bound) * 16) catch return error.OutOfMemory;
    defer allocator.free(member_offsets);
    @memset(member_offsets, null);

    var capability = false;
    var memory_model = false;
    var entries: std.ArrayList(Entry) = .empty;
    defer entries.deinit(allocator);
    var function_count: usize = 0;
    var in_function = false;
    var label_seen = false;
    var terminated = false;
    var block_terminated = true;
    var current_function: u32 = 0;
    const instruction_functions = allocator.alloc(u32, module.instructions.len) catch return error.OutOfMemory;
    defer allocator.free(instruction_functions);
    @memset(instruction_functions, 0);

    for (module.instructions, 0..) |instruction, instruction_index| {
        const w = instruction.words;
        const instruction_meta = opcodeMeta(instruction.opcode).?;
        instruction_functions[instruction_index] = current_function;
        switch (instruction.opcode) {
            0, 2, 3, 4, 5, 6, 7, 8, 317 => {}, // bounded debug/non-semantic declarations are discarded
            11 => {
                if (w.len < 2) return error.Malformed;
                const name = try stringOperand(w[1..]);
                if (!std.mem.eql(u8, name.value, "GLSL.std.450")) return error.Unsupported;
                try define(nodes, w[0], .{ .kind = .ext_inst_import, .a = 450 });
            },
            17 => {
                const meta = valueMeta(&capability_schema, w[0]) orelse return error.Unsupported;
                if (!meta.supported or capability) return error.Unsupported;
                capability = true;
            },
            14 => {
                if (w.len != 2) return error.Malformed;
                if (w[0] != 0 or w[1] != 1 or memory_model) return error.Unsupported;
                memory_model = true;
            },
            15 => {
                if (w.len < 3) return error.Malformed;
                const stage: ir.Stage = switch (w[0]) {
                    0 => .vertex,
                    4 => .fragment,
                    5 => .compute,
                    else => return error.Unsupported,
                };
                const name = try stringOperand(w[2..]);
                const start = 2 + name.word_count;
                if (start > w.len) return error.Malformed;
                try entries.append(allocator, .{ .stage = stage, .function = w[1], .name = name.value, .interfaces = w[start..] });
            },
            16 => {
                const meta = valueMeta(&execution_mode_schema, w[1]) orelse return error.Unsupported;
                const payload = w.len - 2;
                if (payload < meta.operands.min or payload > meta.operands.max) return error.Malformed;
                if (!meta.supported and !(requested_stage == .compute and w[1] == 17)) return error.Unsupported;
            },
            71 => {
                const meta = valueMeta(&decoration_schema, w[1]) orelse return error.Unsupported;
                const payload = w.len - 2;
                if (payload < meta.operands.min or payload > meta.operands.max) return error.Malformed;
                if (!meta.supported) return error.Unsupported;
                const target = try id(nodes, w[0]);
                switch (w[1]) {
                    1 => if (decorations[target].spec_id == null) {
                        decorations[target].spec_id = w[2];
                    } else return error.Malformed,
                    2 => if (!decorations[target].block) {
                        decorations[target].block = true;
                    } else return error.Malformed,
                    11 => if (!decorations[target].builtin_position and w[2] == 0) {
                        decorations[target].builtin_position = true;
                    } else return error.Unsupported,
                    30 => if (decorations[target].location == null) {
                        decorations[target].location = w[2];
                    } else return error.Malformed,
                    33 => if (decorations[target].binding == null) {
                        decorations[target].binding = w[2];
                    } else return error.Malformed,
                    34 => if (decorations[target].descriptor_set == null) {
                        decorations[target].descriptor_set = w[2];
                    } else return error.Malformed,
                    else => unreachable,
                }
            },
            72 => {
                const meta = valueMeta(&decoration_schema, w[2]) orelse return error.Unsupported;
                const payload = w.len - 3;
                if (payload < meta.operands.min or payload > meta.operands.max) return error.Malformed;
                if (!meta.supported or w[2] != 35) return error.Unsupported;
                const target = try id(nodes, w[0]);
                if (w[1] >= 16 or w[3] % 4 != 0) return error.Unsupported;
                const offset_index = target * 16 + w[1];
                if (member_offsets[offset_index] != null) return error.Malformed;
                member_offsets[offset_index] = w[3];
            },
            19 => {
                if (w.len != 1) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .void });
            },
            20 => {
                if (w.len != 1) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .bool });
            },
            21 => {
                if (w.len != 3) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .int, .a = w[1], .b = w[2] });
                _ = try resultShape(nodes, w[0]);
            },
            22 => {
                if (w.len != 2) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .float, .a = w[1] });
                _ = try resultShape(nodes, w[0]);
            },
            23, 24 => {
                if (w.len != 3) return error.Malformed;
                try define(nodes, w[0], .{ .kind = if (instruction.opcode == 23) .vector else .matrix, .a = w[1], .b = w[2] });
                _ = try resultShape(nodes, w[0]);
            },
            30 => {
                if (w.len < 1 or w.len > 17) return if (w.len < 1) error.Malformed else error.LimitExceeded;
                try define(nodes, w[0], .{ .kind = .structure, .words = w[1..] });
            },
            32 => {
                const storage = valueMeta(&storage_schema, w[1]) orelse return error.Unsupported;
                if (!storage.supported and !(requested_stage == .compute and w[1] == 12)) return error.Unsupported;
                try define(nodes, w[0], .{ .kind = .pointer, .a = w[1], .b = w[2] });
            },
            33 => {
                if (w.len < 2 or w.len > 2) return error.Unsupported;
                try define(nodes, w[0], .{ .kind = .function, .a = w[1] });
            },
            41, 42 => {
                if (w.len != 2) return error.Malformed;
                try define(nodes, w[1], .{ .kind = .constant, .type_id = w[0], .opcode = instruction.opcode });
            },
            43, 48, 49, 50 => {
                if (w.len < 2) return error.Malformed;
                const shape = try resultShape(nodes, w[0]);
                const bytes: usize = @as(usize, shape.columns) * shape.rows * 4;
                if ((instruction.opcode == 43 or instruction.opcode == 50) and w.len != 2 + bytes / 4) return error.Malformed;
                if (shape.scalar == .f32 and w.len == 3 and !std.math.isFinite(@as(f32, @bitCast(w[2])))) return error.Unsupported;
                try define(nodes, w[1], .{ .kind = .constant, .type_id = w[0], .opcode = instruction.opcode, .words = w[2..] });
            },
            44 => {
                if (w.len < 3) return error.Malformed;
                _ = try resultShape(nodes, w[0]);
                try define(nodes, w[1], .{ .kind = .constant, .type_id = w[0], .opcode = instruction.opcode, .words = w[2..] });
            },
            59 => {
                const storage = valueMeta(&storage_schema, w[2]) orelse return error.Unsupported;
                if (!storage.supported and !(requested_stage == .compute and w[2] == 12)) return error.Unsupported;
                const pointer = nodes[try id(nodes, w[0])];
                if (pointer.kind != .pointer or pointer.a != w[2]) return error.Malformed;
                try define(nodes, w[1], .{ .kind = .variable, .type_id = w[0], .a = w[2] });
            },
            54 => {
                if (w.len != 4 or in_function or w[2] != 0) return error.Unsupported;
                try define(nodes, w[1], .{ .kind = .function_value, .type_id = w[0], .a = w[3] });
                in_function = true;
                current_function = w[1];
                instruction_functions[instruction_index] = current_function;
                label_seen = false;
                terminated = false;
                block_terminated = true;
                function_count += 1;
            },
            248 => {
                if (!in_function or (label_seen and !block_terminated) or w.len != 1) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .label });
                label_seen = true;
                block_terminated = false;
            },
            247 => {
                if (requested_stage != .compute) return error.Unsupported;
                if (!in_function or !label_seen or terminated or block_terminated or w.len != 2) return error.Malformed;
                if (w[1] != 0) return error.Unsupported;
                _ = try id(nodes, w[0]);
            },
            253 => {
                if (!in_function or !label_seen or terminated or block_terminated or w.len != 0) return error.Malformed;
                terminated = true;
                block_terminated = true;
            },
            12 => {
                if (!in_function or !label_seen or terminated or block_terminated or w.len < 5 or w.len > 7) return error.Malformed;
                const set = nodes[try id(nodes, w[2])];
                if (set.kind != .ext_inst_import or set.a != 450) return error.Unsupported;
                if (w[3] < 1 or w[3] > 24 and w[3] != 25 and w[3] != 26 and w[3] != 27 and w[3] != 28 and w[3] != 29 and w[3] != 30 and w[3] != 31 and w[3] != 32 and w[3] != 33 and w[3] != 34 and w[3] != 37 and w[3] != 38 and w[3] != 39 and w[3] != 40 and w[3] != 41 and w[3] != 42 and w[3] != 43 and w[3] != 44 and w[3] != 45 and w[3] != 46 and w[3] != 48 and w[3] != 49 and w[3] != 50 and w[3] != 53 and w[3] != 54 and w[3] != 55 and w[3] != 56 and w[3] != 57 and w[3] != 58 and w[3] != 59 and w[3] != 60 and w[3] != 61 and w[3] != 62 and w[3] != 63 and w[3] != 65 and w[3] != 66 and w[3] != 67 and w[3] != 68 and w[3] != 69 and w[3] != 70 and w[3] != 71 and w[3] != 72 and w[3] != 73 and w[3] != 74 and w[3] != 79 and w[3] != 80 and w[3] != 81) return error.Unsupported;
                if ((w[3] >= 1 and w[3] <= 24 or w[3] >= 27 and w[3] <= 34 or w[3] >= 54 and w[3] <= 61 or w[3] == 62 or w[3] == 63 or w[3] == 65 or w[3] == 68 or w[3] >= 72 and w[3] <= 74) and w.len != 5) return error.Malformed;
                if ((w[3] == 25 or w[3] == 26 or w[3] == 53) and w.len != 6) return error.Malformed;
                if ((w[3] >= 37 and w[3] <= 42 or w[3] == 48 or w[3] == 66 or w[3] == 67 or w[3] == 70 or w[3] == 79 or w[3] == 80) and w.len != 6) return error.Malformed;
                if ((w[3] >= 43 and w[3] <= 46 or w[3] == 49 or w[3] == 50 or w[3] == 69 or w[3] == 71 or w[3] == 81) and w.len != 7) return error.Malformed;
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[4]);
                if (!supportedGlslExtInst(w[3], result, operand)) return error.Unsupported;
                if ((w[3] >= 37 and w[3] <= 42 or w[3] == 48 or w[3] == 79 or w[3] == 80) and !sameShape(result, try valueShape(nodes, w[5]))) return error.Unsupported;
                if ((w[3] >= 43 and w[3] <= 46 or w[3] == 49 or w[3] == 50 or w[3] == 81) and (!sameShape(result, try valueShape(nodes, w[5])) or !sameShape(result, try valueShape(nodes, w[6])))) return error.Unsupported;
                if ((w[3] == 66 or w[3] == 67 or w[3] == 70) and !sameShape(operand, try valueShape(nodes, w[5]))) return error.Unsupported;
                if (w[3] == 69 and (!sameShape(result, try valueShape(nodes, w[5])) or !sameShape(result, try valueShape(nodes, w[6])))) return error.Unsupported;
                if (w[3] == 71 and (!sameShape(result, try valueShape(nodes, w[5])) or (try valueShape(nodes, w[6])).scalar != .f32 or (try valueShape(nodes, w[6])).columns != 1 or (try valueShape(nodes, w[6])).rows != 1)) return error.Unsupported;
                if (w[3] == 53) {
                    const exponent = try valueShape(nodes, w[5]);
                    if (exponent.scalar != .i32 or exponent.rows != 1 or exponent.columns != operand.columns) return error.Unsupported;
                }
                try define(nodes, w[1], .{ .kind = .function_value, .type_id = w[0], .opcode = 12, .a = w[2], .b = w[3], .words = w[4..] });
            },
            56 => {
                if (!in_function or !label_seen or !terminated or !block_terminated or w.len != 0) return error.Malformed;
                in_function = false;
                current_function = 0;
            },
            245 => {
                if (requested_stage != .compute) return error.Unsupported;
                if (!in_function or !label_seen or terminated or block_terminated or w.len < 6 or (w.len - 2) % 2 != 0) return error.Malformed;
                const result = try resultShape(nodes, w[0]);
                var pair_index: usize = 2;
                while (pair_index < w.len) : (pair_index += 2) {
                    const value_shape = try valueShape(nodes, w[pair_index]);
                    if (!sameShape(result, value_shape)) return error.Malformed;
                    const label = nodes[try id(nodes, w[pair_index + 1])];
                    if (label.kind != .label) return error.Malformed;
                    var prior_pair: usize = 2;
                    while (prior_pair < pair_index) : (prior_pair += 2) if (w[prior_pair + 1] == w[pair_index + 1]) return error.Malformed;
                }
                try define(nodes, w[1], .{ .kind = .function_value, .type_id = w[0], .opcode = 245, .words = w[2..] });
            },
            249, 250, 251 => {
                if (requested_stage != .compute) return error.Unsupported;
                if (!in_function or !label_seen or terminated or block_terminated) return error.Malformed;
                if (instruction.opcode == 249 and w.len != 1) return error.Malformed;
                if (instruction.opcode == 250 and w.len != 3) return error.Malformed;
                if (instruction.opcode == 251) {
                    if (w.len < 2 or (w.len - 2) % 2 != 0) return error.Malformed;
                    const selector = nodes[try id(nodes, w[0])];
                    const selector_shape = try valueShape(nodes, w[0]);
                    if (!scalarClass(selector_shape, .integer) or selector_shape.columns != 1 or selector_shape.rows != 1) return error.Unsupported;
                    if (selector.kind != .constant and selector.kind != .function_value) return error.Unsupported;
                    if (selector.kind == .constant and (selector.opcode != 43 or selector.words.len != 1)) return error.Unsupported;
                    if (selector.kind == .function_value and w.len != 4) return error.Unsupported;
                    _ = try id(nodes, w[1]);
                    var pair_index: usize = 2;
                    while (pair_index < w.len) : (pair_index += 2) {
                        _ = try id(nodes, w[pair_index + 1]);
                        var prior_pair: usize = 2;
                        while (prior_pair < pair_index) : (prior_pair += 2) if (w[prior_pair] == w[pair_index]) return error.Malformed;
                    }
                } else if (instruction.opcode == 250) {
                    const condition = nodes[try id(nodes, w[0])];
                    const condition_shape = try valueShape(nodes, w[0]);
                    if (condition_shape.scalar != .bool or condition_shape.columns != 1 or condition_shape.rows != 1) return error.Unsupported;
                    if (condition.kind != .constant and condition.kind != .function_value) return error.Unsupported;
                }
                if (instruction.opcode == 249) {
                    _ = try id(nodes, w[0]);
                } else if (instruction.opcode == 250) {
                    _ = try id(nodes, w[1]);
                    _ = try id(nodes, w[2]);
                }
                block_terminated = true;
            },
            61, 62, 65, 77, 78, 79, 80, 81, 82, 83, 84, 109, 110, 111, 112, 113, 114, 115, 116, 124, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 154...163, 164...169, 170...179, 182...205 => {
                if (!in_function or !label_seen or terminated or block_terminated) return error.Malformed;
                const valid_arity = switch (instruction.opcode) {
                    61, 84 => w.len == 3,
                    62 => w.len == 2,
                    65 => w.len >= 4,
                    77 => w.len == 4,
                    78 => w.len == 5,
                    79 => w.len >= 5,
                    80 => w.len >= 3,
                    81 => w.len >= 4,
                    82 => w.len == 5,
                    83, 109, 110, 111, 112, 113, 114, 115, 116, 124, 126, 127, 154, 155, 156, 157, 158, 159, 160 => w.len == 3,
                    128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 161, 162, 163, 164...167, 170...179, 182...199 => w.len == 4,
                    201 => w.len == 6,
                    202, 203 => w.len == 5,
                    204, 205 => w.len == 3,
                    200 => w.len == 3,
                    168 => w.len == 3,
                    169 => w.len == 5,
                    else => unreachable,
                };
                if (!valid_arity) return error.Malformed;
                if (instruction.opcode != 62)
                    try define(nodes, w[1], .{ .kind = .function_value, .type_id = w[0], .opcode = instruction.opcode, .words = w[2..] });
            },
            51 => return error.Unsupported,
            else => if (instruction_meta.supported) unreachable else return error.Unsupported,
        }
    }
    if (!capability or !memory_model or in_function or function_count == 0) return error.Malformed;
    for (nodes, decorations, 0..) |node, decoration, node_index| {
        const any_decoration = decoration.spec_id != null or decoration.location != null or decoration.binding != null or decoration.descriptor_set != null or decoration.builtin_position or decoration.block;
        if (any_decoration and node.kind == .none) return error.Malformed;
        if (decoration.spec_id != null and !(node.kind == .constant and node.opcode >= 48 and node.opcode <= 50)) return error.Unsupported;
        if ((decoration.location != null or decoration.binding != null or decoration.descriptor_set != null or decoration.builtin_position) and node.kind != .variable) return error.Unsupported;
        if (decoration.block and node.kind != .structure) return error.Unsupported;
        for (member_offsets[node_index * 16 ..][0..16], 0..) |offset, member_index| if (offset != null and (node.kind != .structure or member_index >= node.words.len)) return if (node.kind == .none) error.Malformed else error.Unsupported;
    }
    for (specs) |spec| {
        var matched = false;
        for (nodes, decorations) |node, decoration| if (decoration.spec_id == spec.id) {
            if (matched) return error.Malformed;
            matched = true;
            if (node.kind != .constant or node.opcode < 48 or node.opcode > 50) return error.Unsupported;
            const shape = try resultShape(nodes, node.type_id);
            if (shape.columns != 1 or shape.rows != 1 or spec.bytes.len != 4) return error.Unsupported;
        };
        if (!matched) return error.Unsupported;
    }

    var selected: ?Entry = null;
    for (entries.items) |entry| if (entry.stage == requested_stage and std.mem.eql(u8, entry.name, requested_entry)) {
        if (selected != null) return error.Unsupported;
        selected = entry;
    };
    const entry = selected orelse return error.Unsupported;
    const function = nodes[try id(nodes, entry.function)];
    if (function.kind != .function_value) return error.Malformed;
    const function_type = nodes[try id(nodes, function.a)];
    if (function_type.kind != .function or nodes[try id(nodes, function.type_id)].kind != .void or nodes[try id(nodes, function_type.a)].kind != .void) return error.Unsupported;

    // Validate exact operand types before lowering. No implicit widening,
    // contraction, or relaxed float operation is part of profile v1.
    for (module.instructions, instruction_functions) |instruction, instruction_function| {
        if (instruction_function != 0 and instruction_function != entry.function) continue;
        const w = instruction.words;
        switch (instruction.opcode) {
            12 => {
                if (w.len < 5 or w.len > 7) return error.Malformed;
                const set = nodes[try id(nodes, w[2])];
                if (set.kind != .ext_inst_import or set.a != 450 or (w[3] < 1 or w[3] > 24 and w[3] != 25 and w[3] != 26 and w[3] != 27 and w[3] != 28 and w[3] != 29 and w[3] != 30 and w[3] != 31 and w[3] != 32 and w[3] != 33 and w[3] != 34 and w[3] != 37 and w[3] != 38 and w[3] != 39 and w[3] != 40 and w[3] != 41 and w[3] != 42 and w[3] != 43 and w[3] != 44 and w[3] != 45 and w[3] != 46 and w[3] != 48 and w[3] != 49 and w[3] != 50 and w[3] != 53 and w[3] != 54 and w[3] != 55 and w[3] != 56 and w[3] != 57 and w[3] != 58 and w[3] != 59 and w[3] != 60 and w[3] != 61 and w[3] != 62 and w[3] != 63 and w[3] != 65 and w[3] != 66 and w[3] != 67 and w[3] != 68 and w[3] != 69 and w[3] != 70 and w[3] != 71 and w[3] != 72 and w[3] != 73 and w[3] != 74 and w[3] != 79 and w[3] != 80 and w[3] != 81)) return error.Unsupported;
                if ((w[3] >= 1 and w[3] <= 24 or w[3] >= 27 and w[3] <= 34 or w[3] >= 54 and w[3] <= 61 or w[3] == 62 or w[3] == 63 or w[3] == 65 or w[3] == 68 or w[3] >= 72 and w[3] <= 74) and w.len != 5) return error.Malformed;
                if ((w[3] == 25 or w[3] == 26 or w[3] == 53) and w.len != 6) return error.Malformed;
                if ((w[3] >= 37 and w[3] <= 42 or w[3] == 48 or w[3] == 66 or w[3] == 67 or w[3] == 70 or w[3] == 79 or w[3] == 80) and w.len != 6) return error.Malformed;
                if ((w[3] >= 43 and w[3] <= 46 or w[3] == 49 or w[3] == 50 or w[3] == 69 or w[3] == 71 or w[3] == 81) and w.len != 7) return error.Malformed;
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[4]);
                if (!supportedGlslExtInst(w[3], result, operand)) return error.Unsupported;
                if ((w[3] >= 37 and w[3] <= 42 or w[3] == 48 or w[3] == 79 or w[3] == 80) and !sameShape(result, try valueShape(nodes, w[5]))) return error.Unsupported;
                if ((w[3] >= 43 and w[3] <= 46 or w[3] == 49 or w[3] == 50 or w[3] == 81) and (!sameShape(result, try valueShape(nodes, w[5])) or !sameShape(result, try valueShape(nodes, w[6])))) return error.Unsupported;
                if ((w[3] == 66 or w[3] == 67 or w[3] == 70) and !sameShape(operand, try valueShape(nodes, w[5]))) return error.Unsupported;
                if (w[3] == 69 and (!sameShape(result, try valueShape(nodes, w[5])) or !sameShape(result, try valueShape(nodes, w[6])))) return error.Unsupported;
                if (w[3] == 71 and (!sameShape(result, try valueShape(nodes, w[5])) or (try valueShape(nodes, w[6])).scalar != .f32 or (try valueShape(nodes, w[6])).columns != 1 or (try valueShape(nodes, w[6])).rows != 1)) return error.Unsupported;
                if (w[3] == 53) {
                    const exponent = try valueShape(nodes, w[5]);
                    if (exponent.scalar != .i32 or exponent.rows != 1 or exponent.columns != operand.columns) return error.Unsupported;
                }
            },
            44, 80 => {
                const result = try resultShape(nodes, w[0]);
                if (result.rows == 1 and result.columns > 1) {
                    if (w.len - 2 != result.columns) return error.Malformed;
                    for (w[2..]) |operand| {
                        const part = try valueShape(nodes, operand);
                        if (part.scalar != result.scalar or part.columns != 1 or part.rows != 1) return error.Malformed;
                    }
                } else if (result.rows == 4 and result.columns == 4) {
                    if (w.len != 6) return error.Malformed;
                    for (w[2..]) |operand| {
                        const part = try valueShape(nodes, operand);
                        if (part.scalar != .f32 or part.columns != 4 or part.rows != 1) return error.Malformed;
                    }
                } else return error.Unsupported;
            },
            61 => {
                const pointer_value = nodes[try id(nodes, w[2])];
                const pointer = nodes[try id(nodes, pointer_value.type_id)];
                if (pointer.kind != .pointer or !sameShape(try resultShape(nodes, w[0]), try resultShape(nodes, pointer.b))) return error.Malformed;
                if (pointer.a != 1 and pointer.a != 2 and !(requested_stage == .compute and pointer.a == 12)) return error.Unsupported;
            },
            62 => {
                const pointer_value = nodes[try id(nodes, w[0])];
                const pointer = nodes[try id(nodes, pointer_value.type_id)];
                if (pointer.kind != .pointer or (pointer.a != 3 and !(requested_stage == .compute and pointer.a == 12))) return error.Unsupported;
                const pointee = nodes[try id(nodes, pointer.b)];
                const pointee_shape = if (requested_stage == .compute and pointer.a == 12 and pointee.kind == .structure and pointee.words.len == 1) try resultShape(nodes, pointee.words[0]) else try resultShape(nodes, pointer.b);
                if (!sameShape(pointee_shape, try valueShape(nodes, w[1]))) return error.Malformed;
            },
            65 => {
                const result_pointer = nodes[try id(nodes, w[0])];
                const base = nodes[try id(nodes, w[2])];
                const base_pointer = nodes[try id(nodes, base.type_id)];
                if (result_pointer.kind != .pointer or base_pointer.kind != .pointer or result_pointer.a != base_pointer.a) return error.Malformed;
                var current_type = base_pointer.b;
                for (w[3..], 0..) |index_id, index_position| {
                    const index_node = nodes[try id(nodes, index_id)];
                    const index_shape = try valueShape(nodes, index_id);
                    if (!scalarClass(index_shape, .integer) or index_shape.columns != 1) return error.Unsupported;
                    if (index_node.kind == .constant) {
                        if (index_node.words.len != 1) return error.Malformed;
                        current_type = try indexedType(nodes, current_type, index_node.words[0]);
                    } else {
                        // A dynamic index is admitted only for a final vector
                        // component. Structure, matrix, and nested aggregate
                        // indices remain statically resolved so offsets and
                        // ABI ranges stay deterministic.
                        const aggregate = nodes[try id(nodes, current_type)];
                        if (index_position + 1 != w[3..].len or aggregate.kind != .vector or index_shape.scalar != .u32) return error.Unsupported;
                        current_type = aggregate.a;
                    }
                }
                if (current_type != result_pointer.b) return error.Malformed;
            },
            79 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (left.rows != 1 or right.rows != 1 or left.scalar != right.scalar or result.scalar != left.scalar or result.rows != 1 or w.len - 4 != result.columns) return error.Malformed;
                for (w[4..]) |selector| if (selector == std.math.maxInt(u32) or selector >= @as(u32, left.columns) + right.columns) return error.Unsupported;
            },
            81 => {
                const source = try valueShape(nodes, w[2]);
                if (w.len != 4 or source.rows != 1 or w[3] >= source.columns) return error.Unsupported;
                var expected = source;
                expected.columns = 1;
                if (!sameShape(expected, try resultShape(nodes, w[0]))) return error.Malformed;
            },
            82 => {
                const result = try resultShape(nodes, w[0]);
                const object = try valueShape(nodes, w[2]);
                const composite = try valueShape(nodes, w[3]);
                if (result.rows != 1 or result.columns < 2 or result.columns > 4 or !sameShape(result, composite) or object.scalar != result.scalar or object.columns != 1 or object.rows != 1 or w[4] >= result.columns) return error.Malformed;
            },
            83 => {
                const result = try resultShape(nodes, w[0]);
                const source = try valueShape(nodes, w[2]);
                if (!sameShape(result, source)) return error.Malformed;
            },
            77 => {
                const result = try resultShape(nodes, w[0]);
                const vector = try valueShape(nodes, w[2]);
                const index = try valueShape(nodes, w[3]);
                if (vector.rows != 1 or vector.columns < 2 or vector.columns > 4 or result.scalar != vector.scalar or result.columns != 1 or result.rows != 1 or !scalarClass(index, .integer) or index.columns != 1 or index.rows != 1) return error.Malformed;
            },
            78 => {
                const result = try resultShape(nodes, w[0]);
                const vector = try valueShape(nodes, w[2]);
                const component = try valueShape(nodes, w[3]);
                const index = try valueShape(nodes, w[4]);
                if (result.rows != 1 or result.columns < 2 or result.columns > 4 or !sameShape(result, vector) or component.scalar != result.scalar or component.columns != 1 or component.rows != 1 or !scalarClass(index, .integer) or index.columns != 1 or index.rows != 1) return error.Malformed;
            },
            84 => {
                const result = try resultShape(nodes, w[0]);
                const source = try valueShape(nodes, w[2]);
                if (result.scalar != .f32 or result.columns != 4 or result.rows != 4 or !sameShape(result, source)) return error.Malformed;
            },
            109, 110, 111, 112, 113, 114, 115, 124 => {
                const result = try resultShape(nodes, w[0]);
                const source = try valueShape(nodes, w[2]);
                if (result.columns != source.columns or result.rows != source.rows) return error.Malformed;
                const supported = switch (instruction.opcode) {
                    109 => result.scalar == .u32 and source.scalar == .f32,
                    110 => result.scalar == .i32 and source.scalar == .f32,
                    111 => result.scalar == .f32 and source.scalar == .i32,
                    112 => result.scalar == .f32 and source.scalar == .u32,
                    113 => result.scalar == .u32 and scalarClass(source, .integer),
                    114 => result.scalar == .i32 and scalarClass(source, .integer),
                    115 => result.scalar == .f32 and source.scalar == .f32,
                    124 => result.scalar != .bool and source.scalar != .bool and result.scalar != source.scalar,
                    else => unreachable,
                };
                if (!supported) return error.Unsupported;
            },
            116 => {
                const result = try resultShape(nodes, w[0]);
                const source = try valueShape(nodes, w[2]);
                if (result.scalar != .f32 or source.scalar != .f32 or result.rows != 1 or source.rows != 1 or result.columns != source.columns or result.columns < 1 or result.columns > 4) return error.Malformed;
            },
            127 => {
                const result = try resultShape(nodes, w[0]);
                if (!scalarClass(result, .float) or !sameShape(result, try valueShape(nodes, w[2]))) return error.Malformed;
            },
            126, 128, 130, 132, 129, 131, 133, 134, 135, 136, 137, 138, 139, 140, 141 => {
                const result = try resultShape(nodes, w[0]);
                if (instruction.opcode == 126) {
                    if (result.scalar != .i32 or !sameShape(result, try valueShape(nodes, w[2]))) return error.Malformed;
                } else if (instruction.opcode == 134 or instruction.opcode == 137) {
                    if (result.scalar != .u32 or !sameShape(result, try valueShape(nodes, w[2])) or !sameShape(result, try valueShape(nodes, w[3]))) return error.Malformed;
                } else if (instruction.opcode == 135 or instruction.opcode == 138 or instruction.opcode == 139) {
                    if (result.scalar != .i32 or !sameShape(result, try valueShape(nodes, w[2])) or !sameShape(result, try valueShape(nodes, w[3]))) return error.Malformed;
                } else {
                    const class: ScalarClass = if (instruction.opcode == 128 or instruction.opcode == 130 or instruction.opcode == 132) .integer else .float;
                    if (!scalarClass(result, class) or !sameShape(result, try valueShape(nodes, w[2])) or !sameShape(result, try valueShape(nodes, w[3]))) return error.Malformed;
                }
            },
            142 => {
                const result = try resultShape(nodes, w[0]);
                const vector = try valueShape(nodes, w[2]);
                const scalar = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns < 2 or !sameShape(result, vector) or scalar.scalar != .f32 or scalar.columns != 1 or scalar.rows != 1) return error.Malformed;
            },
            145 => {
                const result = try resultShape(nodes, w[0]);
                const matrix = try valueShape(nodes, w[2]);
                const vector = try valueShape(nodes, w[3]);
                if (matrix.scalar != .f32 or matrix.columns != 4 or matrix.rows != 4 or result.scalar != .f32 or result.columns != 4 or result.rows != 1 or !sameShape(result, vector)) return error.Malformed;
            },
            143 => {
                const result = try resultShape(nodes, w[0]);
                const matrix = try valueShape(nodes, w[2]);
                const scalar = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns != 4 or result.rows != 4 or !sameShape(result, matrix) or scalar.scalar != .f32 or scalar.columns != 1 or scalar.rows != 1) return error.Malformed;
            },
            144 => {
                const result = try resultShape(nodes, w[0]);
                const vector = try valueShape(nodes, w[2]);
                const matrix = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns != 4 or result.rows != 1 or !sameShape(result, vector) or matrix.scalar != .f32 or matrix.columns != 4 or matrix.rows != 4) return error.Malformed;
            },
            146 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns != 4 or result.rows != 4 or !sameShape(result, left) or !sameShape(result, right)) return error.Malformed;
            },
            147 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns != 4 or result.rows != 4 or left.scalar != .f32 or right.scalar != .f32 or left.columns != 4 or right.columns != 4 or left.rows != 1 or right.rows != 1 or !sameShape(left, right)) return error.Malformed;
            },
            148 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .f32 or result.columns != 1 or result.rows != 1 or left.scalar != .f32 or right.scalar != .f32 or left.columns < 2 or left.columns > 4 or left.rows != 1 or !sameShape(left, right)) return error.Malformed;
            },
            149...152 => {
                const result_node = nodes[try id(nodes, w[0])];
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result_node.kind != .structure or result_node.words.len != 2 or result.columns != 2 or result.rows != 1 or left.columns != 1 or left.rows != 1 or !sameShape(left, right)) return error.Malformed;
                const member = try resultShape(nodes, result_node.words[0]);
                if (!sameShape(member, left)) return error.Malformed;
                if (instruction.opcode == 152) {
                    if (left.scalar != .i32) return error.Malformed;
                } else if (left.scalar != .u32) return error.Malformed;
            },
            154, 155 => {
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[2]);
                if (result.scalar != .bool or result.columns != 1 or result.rows != 1 or operand.scalar != .bool or operand.columns < 2 or operand.columns > 4 or operand.rows != 1) return error.Malformed;
            },
            156, 157, 158, 159, 160 => {
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[2]);
                if (result.scalar != .bool or result.rows != 1 or operand.scalar != .f32 or operand.rows != 1 or result.columns != operand.columns) return error.Malformed;
            },
            161, 162, 163 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .bool or result.rows != 1 or left.scalar != .f32 or left.rows != 1 or !sameShape(left, right) or result.columns != left.columns) return error.Malformed;
            },
            164...167 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .bool or result.columns < 1 or result.columns > 4 or result.rows != 1 or left.scalar != .bool or left.columns < 1 or left.columns > 4 or left.rows != 1 or !sameShape(left, right) or !sameShape(result, left)) return error.Malformed;
            },
            168 => {
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[2]);
                if (result.scalar != .bool or result.columns < 1 or result.columns > 4 or result.rows != 1 or operand.scalar != .bool or operand.columns < 1 or operand.columns > 4 or operand.rows != 1 or !sameShape(result, operand)) return error.Malformed;
            },
            169 => {
                const result = try resultShape(nodes, w[0]);
                const condition = try valueShape(nodes, w[2]);
                const when_true = try valueShape(nodes, w[3]);
                const when_false = try valueShape(nodes, w[4]);
                if (condition.scalar != .bool or condition.columns != 1 or condition.rows != 1 or !sameShape(result, when_true) or !sameShape(result, when_false)) return error.Malformed;
            },
            194...196 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (!scalarClass(result, .integer) or !sameShape(result, left) or !sameShape(result, right)) return error.Malformed;
                if (instruction.opcode == 195 and result.scalar != .i32) return error.Malformed;
            },
            197...199 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (!scalarClass(result, .integer) or !sameShape(result, left) or !sameShape(result, right)) return error.Malformed;
            },
            200, 204, 205 => {
                const result = try resultShape(nodes, w[0]);
                const operand = try valueShape(nodes, w[2]);
                if (!scalarClass(result, .integer) or !sameShape(result, operand)) return error.Malformed;
            },
            201 => {
                const result = try resultShape(nodes, w[0]);
                const base = try valueShape(nodes, w[2]);
                const insert = try valueShape(nodes, w[3]);
                const offset = try valueShape(nodes, w[4]);
                const count = try valueShape(nodes, w[5]);
                if (!scalarClass(result, .integer) or !sameShape(result, base) or !sameShape(result, insert) or !scalarClass(offset, .integer) or offset.columns != 1 or offset.rows != 1 or !scalarClass(count, .integer) or count.columns != 1 or count.rows != 1) return error.Malformed;
            },
            202, 203 => {
                const result = try resultShape(nodes, w[0]);
                const base = try valueShape(nodes, w[2]);
                const offset = try valueShape(nodes, w[3]);
                const count = try valueShape(nodes, w[4]);
                if (!scalarClass(result, .integer) or !sameShape(result, base) or !scalarClass(offset, .integer) or offset.columns != 1 or offset.rows != 1 or !scalarClass(count, .integer) or count.columns != 1 or count.rows != 1) return error.Malformed;
            },
            170...179 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                const scalar_ok = switch (instruction.opcode) {
                    170, 171 => scalarClass(left, .integer),
                    172, 173, 174, 175 => left.scalar == .u32,
                    176, 177, 178, 179 => left.scalar == .i32,
                    else => unreachable,
                };
                if (result.scalar != .bool or result.columns != 1 or result.rows != 1 or !scalar_ok or !sameShape(left, right)) return error.Malformed;
            },
            182...193 => {
                const result = try resultShape(nodes, w[0]);
                const left = try valueShape(nodes, w[2]);
                const right = try valueShape(nodes, w[3]);
                if (result.scalar != .bool or result.columns != 1 or result.rows != 1 or left.scalar != .f32 or left.columns != 1 or left.rows != 1 or !sameShape(left, right)) return error.Malformed;
            },
            else => {},
        }
    }

    var interfaces: std.ArrayList(ir.Interface) = .empty;
    defer interfaces.deinit(allocator);
    if (entry.interfaces.len > max_interfaces) return error.LimitExceeded;
    for (entry.interfaces) |interface_id| {
        const index = try id(nodes, interface_id);
        const variable = nodes[index];
        if (variable.kind != .variable) return error.Malformed;
        const pointer = nodes[try id(nodes, variable.type_id)];
        const storage: ir.Storage = switch (variable.a) {
            1 => .input,
            3 => .output,
            2 => .uniform,
            12 => if (requested_stage == .compute) .output else return error.Unsupported,
            else => return error.Unsupported,
        };
        var shape: ir.Type = undefined;
        var interface = ir.Interface{ .storage = storage, .ty = .{ .scalar = .u32 }, .location = decorations[index].location, .descriptor_set = decorations[index].descriptor_set, .binding = decorations[index].binding, .builtin_position = decorations[index].builtin_position };
        const pointee = nodes[try id(nodes, pointer.b)];
        if (storage == .uniform) {
            if (pointee.kind != .structure or !decorations[try id(nodes, pointer.b)].block) return error.Unsupported;
            shape = .{ .scalar = .u32 }; // structural uniform marker; members are validated below
            interface.block = true;
            interface.member_count = @intCast(pointee.words.len);
            const Range = struct { start: u32 = 0, end: u32 = 0 };
            var ranges: [ir.max_uniform_members]Range = .{Range{}} ** ir.max_uniform_members;
            for (pointee.words, 0..) |member, member_index| {
                const member_shape = try resultShape(nodes, member);
                const offset = member_offsets[@as(usize, pointer.b) * 16 + member_index] orelse return error.Unsupported;
                const layout = try uniformSizeAlignment(member_shape);
                if (offset % layout.alignment != 0) return error.Unsupported;
                const end = std.math.add(u32, offset, layout.size) catch return error.LimitExceeded;
                if (end > max_uniform_block_bytes) return error.LimitExceeded;
                for (ranges[0..member_index]) |prior| if (offset < prior.end and prior.start < end) return error.Unsupported;
                ranges[member_index] = .{ .start = offset, .end = end };
                interface.members[member_index] = .{ .ty = member_shape, .offset = offset };
            }
            if (decorations[index].binding == null or decorations[index].descriptor_set == null or decorations[index].location != null or decorations[index].builtin_position) return error.Unsupported;
        } else if (requested_stage == .compute and variable.a == 12) {
            if (pointee.kind == .structure and decorations[try id(nodes, pointer.b)].block and pointee.words.len == 1) {
                shape = try resultShape(nodes, pointee.words[0]);
                interface.block = true;
                interface.member_count = 1;
                interface.members[0] = .{ .ty = shape, .offset = member_offsets[@as(usize, pointer.b) * 16] orelse return error.Unsupported };
                if (interface.members[0].offset != 0) return error.Unsupported;
            } else shape = try resultShape(nodes, pointer.b);
            if (decorations[index].binding == null or decorations[index].descriptor_set == null or decorations[index].location != null or decorations[index].builtin_position) return error.Unsupported;
        } else {
            shape = try resultShape(nodes, pointer.b);
            if ((decorations[index].location == null) == !decorations[index].builtin_position or decorations[index].binding != null or decorations[index].descriptor_set != null) return error.Unsupported;
            if (decorations[index].builtin_position and !(storage == .output and requested_stage == .vertex and shape.scalar == .f32 and shape.columns == 4)) return error.Unsupported;
        }
        interface.ty = shape;
        try interfaces.append(allocator, interface);
    }
    std.mem.sort(ir.Interface, interfaces.items, {}, interfaceLess);
    if (!interfacesUnique(interfaces.items)) return error.Unsupported;

    // Resolve the bounded control-flow slice before SSA lowering. Statically
    // selected acyclic branches and one side-effect-free dynamic conditional
    // are admitted; this keeps canonical IR straight-line while ensuring that
    // writes in an unselected block cannot become observable side effects.
    const reachable = allocator.alloc(bool, module.instructions.len) catch return error.OutOfMemory;
    defer allocator.free(reachable);
    @memset(reachable, false);
    const predecessor = allocator.alloc(u32, module.instructions.len) catch return error.OutOfMemory;
    defer allocator.free(predecessor);
    @memset(predecessor, std.math.maxInt(u32));
    var first_label: ?usize = null;
    for (module.instructions, instruction_functions, 0..) |instruction, instruction_function, instruction_index| {
        if (instruction_function == entry.function and instruction.opcode == 248) {
            first_label = instruction_index;
            break;
        }
    }
    var current_block = first_label orelse return error.Malformed;
    var predecessor_label: u32 = std.math.maxInt(u32);
    const visited_labels = allocator.alloc(bool, module.bound) catch return error.OutOfMemory;
    defer allocator.free(visited_labels);
    @memset(visited_labels, false);
    var dynamic_branch: ?DynamicBranch = null;
    var dynamic_switch: ?DynamicSwitch = null;
    while (true) {
        if (current_block >= module.instructions.len or module.instructions[current_block].opcode != 248) return error.Malformed;
        const label_id = module.instructions[current_block].words[0];
        const label_index = try id(nodes, label_id);
        if (nodes[label_index].kind != .label or visited_labels[label_index]) return error.Unsupported;
        visited_labels[label_index] = true;
        var cursor = current_block;
        var next_label: ?u32 = null;
        var block_done = false;
        while (cursor < module.instructions.len and instruction_functions[cursor] == entry.function) : (cursor += 1) {
            const instruction = module.instructions[cursor];
            if (cursor != current_block and instruction.opcode == 248) return error.Malformed;
            reachable[cursor] = true;
            predecessor[cursor] = predecessor_label;
            switch (instruction.opcode) {
                249 => {
                    next_label = instruction.words[0];
                    block_done = true;
                },
                250 => {
                    const condition_id = instruction.words[0];
                    if (try staticCondition(nodes, condition_id)) |condition| {
                        next_label = if (condition) instruction.words[1] else instruction.words[2];
                    } else {
                        // Admit one structured, side-effect-free dynamic if:
                        // both arms must be straight-line blocks that branch
                        // to the same merge, where OpPhi can become OpSelect.
                        if (dynamic_branch != null) return error.Unsupported;
                        const condition_shape = try valueShape(nodes, condition_id);
                        if (condition_shape.scalar != .bool or condition_shape.columns != 1 or condition_shape.rows != 1) return error.Unsupported;
                        const true_label = instruction.words[1];
                        const false_label = instruction.words[2];
                        if (true_label == false_label) return error.Unsupported;
                        const true_start = findLabelOffset(&module, instruction_functions, entry.function, true_label) orelse return error.Malformed;
                        const false_start = findLabelOffset(&module, instruction_functions, entry.function, false_label) orelse return error.Malformed;
                        const merge_label = try dynamicArmTarget(&module, instruction_functions, entry.function, true_start);
                        if (merge_label != try dynamicArmTarget(&module, instruction_functions, entry.function, false_start)) return error.Unsupported;
                        if (merge_label == true_label or merge_label == false_label) return error.Unsupported;
                        const merge_start = findLabelOffset(&module, instruction_functions, entry.function, merge_label) orelse return error.Malformed;
                        if (merge_start == true_start or merge_start == false_start) return error.Unsupported;
                        dynamic_branch = .{ .condition = condition_id, .true_label = true_label, .false_label = false_label, .merge_label = merge_label };
                        try markDynamicArm(&module, instruction_functions, entry.function, true_start, true_label, merge_label, reachable, predecessor);
                        try markDynamicArm(&module, instruction_functions, entry.function, false_start, false_label, merge_label, reachable, predecessor);
                        visited_labels[try id(nodes, true_label)] = true;
                        visited_labels[try id(nodes, false_label)] = true;
                        next_label = merge_label;
                    }
                    block_done = true;
                },
                251 => {
                    const selector = nodes[try id(nodes, instruction.words[0])];
                    const selector_shape = try valueShape(nodes, instruction.words[0]);
                    if (!scalarClass(selector_shape, .integer) or selector_shape.columns != 1 or selector_shape.rows != 1) return error.Unsupported;
                    if (selector.kind == .constant and selector.opcode == 43 and selector.words.len == 1) {
                        next_label = instruction.words[1];
                        var pair_index: usize = 2;
                        while (pair_index < instruction.words.len) : (pair_index += 2) if (instruction.words[pair_index] == selector.words[0]) {
                            next_label = instruction.words[pair_index + 1];
                            break;
                        };
                    } else {
                        // Admit one runtime case plus the default arm. Both
                        // arms must be straight-line and converge at one
                        // merge so the switch becomes compare + select.
                        if (dynamic_branch != null or dynamic_switch != null or instruction.words.len != 4) return error.Unsupported;
                        const default_label = instruction.words[1];
                        const case_value = instruction.words[2];
                        const case_label = instruction.words[3];
                        if (default_label == case_label) return error.Unsupported;
                        const case_start = findLabelOffset(&module, instruction_functions, entry.function, case_label) orelse return error.Malformed;
                        const default_start = findLabelOffset(&module, instruction_functions, entry.function, default_label) orelse return error.Malformed;
                        const merge_label = try dynamicArmTarget(&module, instruction_functions, entry.function, case_start);
                        if (merge_label != try dynamicArmTarget(&module, instruction_functions, entry.function, default_start)) return error.Unsupported;
                        if (merge_label == case_label or merge_label == default_label) return error.Unsupported;
                        const merge_start = findLabelOffset(&module, instruction_functions, entry.function, merge_label) orelse return error.Malformed;
                        if (merge_start == case_start or merge_start == default_start) return error.Unsupported;
                        dynamic_switch = .{ .selector = instruction.words[0], .case_value = case_value, .case_label = case_label, .default_label = default_label, .merge_label = merge_label };
                        try markDynamicArm(&module, instruction_functions, entry.function, case_start, case_label, merge_label, reachable, predecessor);
                        try markDynamicArm(&module, instruction_functions, entry.function, default_start, default_label, merge_label, reachable, predecessor);
                        visited_labels[try id(nodes, case_label)] = true;
                        visited_labels[try id(nodes, default_label)] = true;
                        next_label = merge_label;
                    }
                    block_done = true;
                },
                253 => block_done = true,
                56 => return error.Malformed,
                else => {},
            }
            if (block_done) break;
        }
        if (!block_done) return error.Malformed;
        if (next_label) |target| {
            const target_index = try id(nodes, target);
            if (nodes[target_index].kind != .label) return error.Malformed;
            current_block = 0;
            var found = false;
            for (module.instructions, instruction_functions, 0..) |candidate, candidate_function, candidate_index| {
                if (candidate_function == entry.function and candidate.opcode == 248 and candidate.words[0] == target) {
                    current_block = candidate_index;
                    found = true;
                    break;
                }
            }
            if (!found) return error.Malformed;
            predecessor_label = if ((dynamic_branch != null and target == dynamic_branch.?.merge_label) or (dynamic_switch != null and target == dynamic_switch.?.merge_label)) std.math.maxInt(u32) else label_id;
        } else break;
    }

    const needed = allocator.alloc(bool, module.bound) catch return error.OutOfMemory;
    defer allocator.free(needed);
    @memset(needed, false);
    if (dynamic_branch) |branch| needed[try id(nodes, branch.condition)] = true;
    if (dynamic_switch) |switch_info| needed[try id(nodes, switch_info.selector)] = true;
    for (module.instructions, instruction_functions, reachable) |instruction, instruction_function, is_reachable| {
        if (is_reachable and instruction_function == entry.function and instruction.opcode == 62)
            needed[try id(nodes, instruction.words[1])] = true;
    }
    var changed = true;
    while (changed) {
        changed = false;
        var reverse_index = module.instructions.len;
        while (reverse_index != 0) {
            reverse_index -= 1;
            const instruction = module.instructions[reverse_index];
            const w = instruction.words;
            const result_id: ?u32 = switch (instruction.opcode) {
                12, 41, 42, 43, 44, 48, 49, 50, 61, 65, 77, 78, 79, 80, 81, 82, 83, 84, 109, 110, 111, 112, 113, 114, 115, 116, 124, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 154...163, 164...169, 170...179, 182...205, 245 => w[1],
                else => null,
            };
            const result = result_id orelse continue;
            if (!needed[try id(nodes, result)]) continue;
            const first_operand: usize = switch (instruction.opcode) {
                12 => 4,
                41, 42, 43, 48, 49, 50 => continue,
                164...168 => if (try staticCondition(nodes, result) != null) continue else 2,
                170...179 => if (try staticCondition(nodes, result) != null) continue else 2,
                182...193 => 2,
                else => 2,
            };
            if (instruction.opcode == 245) {
                const selected_predecessor = predecessor[reverse_index];
                if (selected_predecessor == std.math.maxInt(u32)) {
                    const branch = dynamic_branch;
                    const switch_info = dynamic_switch;
                    if (branch == null and switch_info == null) continue;
                    // The merge has two incoming values; both are required
                    // because lowering will materialize a runtime select.
                    var pair_index: usize = 2;
                    var matched = false;
                    while (pair_index < w.len) : (pair_index += 2) {
                        const incoming_label = w[pair_index + 1];
                        const accepted = if (branch) |branch_info|
                            incoming_label == branch_info.true_label or incoming_label == branch_info.false_label
                        else if (switch_info) |switch_value|
                            incoming_label == switch_value.case_label or incoming_label == switch_value.default_label
                        else
                            false;
                        if (!accepted) continue;
                        const operand_index = try id(nodes, w[pair_index]);
                        if (!needed[operand_index]) {
                            needed[operand_index] = true;
                            changed = true;
                        }
                        matched = true;
                    }
                    if (!matched) return error.Malformed;
                    continue;
                }
                var pair_index: usize = 2;
                var selected_phi = false;
                while (pair_index < w.len) : (pair_index += 2) if (w[pair_index + 1] == selected_predecessor) {
                    const operand_index = try id(nodes, w[pair_index]);
                    if (!needed[operand_index]) {
                        needed[operand_index] = true;
                        changed = true;
                    }
                    selected_phi = true;
                    break;
                };
                if (!selected_phi) return error.Malformed;
                continue;
            }
            const operand_end: usize = switch (instruction.opcode) {
                12 => w.len,
                79 => 4,
                81 => 3,
                82 => 4,
                else => w.len,
            };
            for (w[first_operand..operand_end]) |operand| {
                const operand_index = try id(nodes, operand);
                if (!needed[operand_index]) {
                    needed[operand_index] = true;
                    changed = true;
                }
            }
        }
    }

    // Lower reachable straight-line value instructions. Canonical value IDs
    // are instruction ordinals, never source IDs.
    const canonical_ids = allocator.alloc(u32, module.bound) catch return error.OutOfMemory;
    defer allocator.free(canonical_ids);
    @memset(canonical_ids, std.math.maxInt(u32));
    var lowered: std.ArrayList(ir.Instruction) = .empty;
    errdefer {
        for (lowered.items) |item| {
            allocator.free(item.operands);
            allocator.free(item.literal);
        }
        lowered.deinit(allocator);
    }
    var active_predecessor: u32 = std.math.maxInt(u32);
    for (module.instructions, instruction_functions, reachable, predecessor) |instruction, instruction_function, is_reachable, selected_predecessor| {
        if (instruction_function != 0 and instruction_function != entry.function) continue;
        if (instruction_function == entry.function and !is_reachable) continue;
        const w = instruction.words;
        if (instruction.opcode == 248) active_predecessor = selected_predecessor;
        if (instruction.opcode == 245) {
            const phi_index = try id(nodes, w[1]);
            if (!needed[phi_index]) continue;
            const selected_label = active_predecessor;
            if (selected_label == std.math.maxInt(u32)) {
                const phi_shape = try resultShape(nodes, w[0]);
                var condition_canonical: u32 = std.math.maxInt(u32);
                var true_label: u32 = 0;
                var false_label: u32 = 0;
                if (dynamic_branch) |branch| {
                    condition_canonical = canonical_ids[try id(nodes, branch.condition)];
                    true_label = branch.true_label;
                    false_label = branch.false_label;
                } else if (dynamic_switch) |switch_info| {
                    const selector_canonical = canonical_ids[try id(nodes, switch_info.selector)];
                    if (selector_canonical == std.math.maxInt(u32)) return error.Malformed;
                    const selector_shape = try valueShape(nodes, switch_info.selector);
                    if (lowered.items.len > ir.max_instructions - 3) return error.LimitExceeded;
                    var case_literal: [4]u8 = undefined;
                    std.mem.writeInt(u32, &case_literal, switch_info.case_value, .little);
                    lowered.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                    const constant_operands = allocator.dupe(u32, &.{}) catch return error.OutOfMemory;
                    const constant_literal = allocator.dupe(u8, &case_literal) catch {
                        allocator.free(constant_operands);
                        return error.OutOfMemory;
                    };
                    lowered.appendAssumeCapacity(.{ .op = .constant, .ty = selector_shape, .operands = constant_operands, .literal = constant_literal });
                    const constant_canonical: u32 = @intCast(lowered.items.len - 1);
                    lowered.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                    const compare_operands = allocator.dupe(u32, &.{ selector_canonical, constant_canonical }) catch return error.OutOfMemory;
                    const compare_literal = allocator.dupe(u8, &.{}) catch {
                        allocator.free(compare_operands);
                        return error.OutOfMemory;
                    };
                    lowered.appendAssumeCapacity(.{ .op = .ieq, .ty = .{ .scalar = .bool }, .operands = compare_operands, .literal = compare_literal });
                    condition_canonical = @intCast(lowered.items.len - 1);
                    true_label = switch_info.case_label;
                    false_label = switch_info.default_label;
                } else return error.Malformed;
                if (condition_canonical == std.math.maxInt(u32)) return error.Malformed;
                var true_source: ?u32 = null;
                var false_source: ?u32 = null;
                var pair_index: usize = 2;
                while (pair_index < w.len) : (pair_index += 2) {
                    if (w[pair_index + 1] == true_label) true_source = w[pair_index];
                    if (w[pair_index + 1] == false_label) false_source = w[pair_index];
                }
                const true_id = true_source orelse return error.Malformed;
                const false_id = false_source orelse return error.Malformed;
                const true_canonical = canonical_ids[try id(nodes, true_id)];
                const false_canonical = canonical_ids[try id(nodes, false_id)];
                if (true_canonical == std.math.maxInt(u32) or false_canonical == std.math.maxInt(u32)) return error.Malformed;
                if (lowered.items.len >= ir.max_instructions) return error.LimitExceeded;
                lowered.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
                const select_operands = allocator.dupe(u32, &.{ condition_canonical, true_canonical, false_canonical }) catch return error.OutOfMemory;
                const select_literal = allocator.dupe(u8, &.{}) catch {
                    allocator.free(select_operands);
                    return error.OutOfMemory;
                };
                lowered.appendAssumeCapacity(.{ .op = .select, .ty = phi_shape, .operands = select_operands, .literal = select_literal });
                canonical_ids[phi_index] = @intCast(lowered.items.len - 1);
                continue;
            }
            var pair_index: usize = 2;
            var source_id: ?u32 = null;
            while (pair_index < w.len) : (pair_index += 2) if (w[pair_index + 1] == selected_label) {
                source_id = w[pair_index];
                break;
            };
            const source = source_id orelse return error.Malformed;
            const source_canonical = canonical_ids[try id(nodes, source)];
            if (source_canonical == std.math.maxInt(u32)) return error.Malformed;
            canonical_ids[phi_index] = source_canonical;
            continue;
        }
        if (instruction.opcode == 62) {
            const target = nodes[try id(nodes, w[0])];
            if (target.kind != .variable or (target.a != 3 and !(requested_stage == .compute and target.a == 12))) return error.Unsupported;
            const value = canonical_ids[try id(nodes, w[1])];
            if (value == std.math.maxInt(u32)) return error.Malformed;
            var semantic_index: ?u32 = null;
            const decoration = decorations[try id(nodes, w[0])];
            for (interfaces.items, 0..) |item, interface_index| {
                if (requested_stage == .compute and target.a == 12) {
                    if (item.storage == .output and item.binding == decoration.binding and item.descriptor_set == decoration.descriptor_set) semantic_index = @intCast(interface_index);
                } else if (item.storage == .output and item.location == decoration.location and item.builtin_position == decoration.builtin_position) semantic_index = @intCast(interface_index);
            }
            const target_index = semantic_index orelse return error.Unsupported;
            const pointer = nodes[try id(nodes, target.type_id)];
            const output_shape = if (requested_stage == .compute and target.a == 12) interfaces.items[target_index].ty else try resultShape(nodes, pointer.b);
            lowered.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
            const operands = allocator.dupe(u32, &.{ target_index, value }) catch return error.OutOfMemory;
            const literal = allocator.dupe(u8, &.{}) catch return error.OutOfMemory;
            lowered.appendAssumeCapacity(.{ .op = .output, .ty = output_shape, .operands = operands, .literal = literal });
            continue;
        }
        const result_id: ?u32 = switch (instruction.opcode) {
            12, 41, 42, 43, 44, 48, 49, 50, 61, 65, 77, 78, 79, 80, 81, 82, 83, 84, 109, 110, 111, 112, 113, 114, 115, 116, 124, 126, 127, 128, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 140, 141, 142, 143, 144, 145, 146, 147, 148, 149, 150, 151, 152, 154...163, 164...169, 170...179, 182...205, 245 => w[1],
            else => null,
        };
        const rid = result_id orelse continue;
        if (!needed[try id(nodes, rid)]) continue;
        const node = nodes[try id(nodes, rid)];
        const shape = if (instruction.opcode == 65) blk: {
            const pointer = nodes[try id(nodes, node.type_id)];
            if (pointer.kind != .pointer) return error.Malformed;
            break :blk try resultShape(nodes, pointer.b);
        } else try resultShape(nodes, node.type_id);
        var op: ir.Op = switch (instruction.opcode) {
            12 => switch (node.b) {
                1 => .f_round,
                2 => .f_round_even,
                3 => .f_trunc,
                4 => .f_abs,
                5 => .i_abs,
                6 => .f_sign,
                7 => .i_sign,
                8 => .f_floor,
                9 => .f_ceil,
                10 => .f_fract,
                11 => .f_radians,
                12 => .f_degrees,
                13 => .f_sin,
                14 => .f_cos,
                15 => .f_tan,
                16 => .f_asin,
                17 => .f_acos,
                18 => .f_atan,
                19 => .f_sinh,
                20 => .f_cosh,
                21 => .f_tanh,
                22 => .f_asinh,
                23 => .f_acosh,
                24 => .f_atanh,
                25 => .f_atan2,
                26 => .f_pow,
                27 => .f_exp,
                28 => .f_log,
                29 => .f_exp2,
                30 => .f_log2,
                31 => .f_sqrt,
                32 => .f_inverse_sqrt,
                33 => .f_determinant,
                34 => .f_matrix_inverse,
                53 => .f_ldexp,
                54 => .i_pack_snorm4x8,
                55 => .i_pack_unorm4x8,
                56 => .i_pack_snorm2x16,
                57 => .i_pack_unorm2x16,
                58 => .i_pack_half2x16,
                59 => .f_unpack_snorm2x16,
                60 => .f_unpack_unorm2x16,
                61 => .f_unpack_half2x16,
                62 => .f_unpack_snorm4x8,
                63 => .f_unpack_unorm4x8,
                65 => .f_length,
                66 => .f_distance,
                67 => .f_cross,
                68 => .f_normalize,
                69 => .f_face_forward,
                70 => .f_reflect,
                71 => .f_refract,
                72 => .i_find_lsb,
                73 => .i_find_s_msb,
                74 => .i_find_u_msb,
                79 => .f_n_min,
                80 => .f_n_max,
                81 => .f_n_clamp,
                37 => .f_min,
                38 => .u_min,
                39 => .i_min,
                40 => .f_max,
                41 => .u_max,
                42 => .i_max,
                43 => .f_clamp,
                44 => .u_clamp,
                45 => .i_clamp,
                46 => .f_mix,
                48 => .f_step,
                49 => .f_smooth_step,
                50 => .fma,
                else => unreachable,
            },
            41, 42, 43, 48, 49, 50 => .constant,
            44 => .constant_composite,
            80 => .composite,
            61 => .input,
            65 => .access,
            79 => .shuffle,
            81 => .extract,
            77 => .vector_extract_dynamic,
            78 => .vector_insert_dynamic,
            82 => .composite_insert,
            83 => .copy_object,
            84 => .transpose,
            109, 110, 111, 112, 113, 114, 115 => .convert,
            116 => .quantize_f16,
            124 => .bitcast,
            126 => .ineg,
            127 => .fneg,
            128 => .iadd,
            129 => .fadd,
            130 => .isub,
            131 => .fsub,
            132 => .imul,
            133 => .fmul,
            134 => .udiv,
            135 => .sdiv,
            136 => .fdiv,
            137 => .umod,
            138 => .srem,
            139 => .smod,
            140 => .frem,
            141 => .fmod,
            194 => .shr_logical,
            195 => .shr_arithmetic,
            196 => .shl_logical,
            197 => .bit_or,
            198 => .bit_xor,
            199 => .bit_and,
            200 => .bit_not,
            201 => .bit_field_insert,
            202 => .bit_field_s_extract,
            203 => .bit_field_u_extract,
            204 => .bit_reverse,
            205 => .bit_count,
            142 => .vector_times_scalar,
            143 => .matrix_times_scalar,
            144 => .vector_times_matrix,
            145 => .matrix_times_vector,
            146 => .matrix_times_matrix,
            147 => .outer_product,
            148 => .dot,
            149 => .iadd_carry,
            150 => .isub_borrow,
            151 => .umul_extended,
            152 => .smul_extended,
            154 => .any,
            155 => .all,
            156 => .is_nan,
            157 => .is_inf,
            158 => .is_finite,
            159 => .is_normal,
            160 => .sign_bit_set,
            161 => .less_or_greater,
            162 => .ordered,
            163 => .unordered,
            169 => .select,
            164...168 => if ((try staticCondition(nodes, rid)) != null) .constant else switch (instruction.opcode) {
                164 => .logical_eq,
                165 => .logical_ne,
                166 => .logical_or,
                167 => .logical_and,
                168 => .logical_not,
                else => unreachable,
            },
            170...179 => if ((try staticCondition(nodes, rid)) != null) .constant else switch (instruction.opcode) {
                170 => .ieq,
                171 => .ine,
                172 => .ugt,
                173 => .uge,
                174 => .ult,
                175 => .ule,
                176 => .sgt,
                177 => .sge,
                178 => .slt,
                179 => .sle,
                else => unreachable,
            },
            182 => .ford_eq,
            183 => .funord_eq,
            184 => .ford_ne,
            185 => .funord_ne,
            186 => .ford_lt,
            187 => .funord_lt,
            188 => .ford_gt,
            189 => .funord_gt,
            190 => .ford_le,
            191 => .funord_le,
            192 => .ford_ge,
            193 => .funord_ge,
            else => unreachable,
        };
        var operands: std.ArrayList(u32) = .empty;
        defer operands.deinit(allocator);
        var literal: [16]u8 = .{0} ** 16;
        var literal_len: usize = 0;
        if (op == .constant) {
            var value_words = node.words;
            var specialized = false;
            if (node.opcode >= 48 and node.opcode <= 51) if (decorations[try id(nodes, rid)].spec_id) |spec_id| for (specs) |spec| if (spec.id == spec_id) {
                specialized = true;
                if (node.opcode == 48 or node.opcode == 49) {
                    const boolean = std.mem.readInt(u32, spec.bytes[0..4], .little);
                    if (boolean > 1) return error.Unsupported;
                    literal[0] = @intCast(boolean);
                    literal_len = 1;
                    value_words = &.{};
                } else {
                    std.mem.copyForwards(u8, literal[0..4], spec.bytes);
                    if (shape.scalar == .f32 and !std.math.isFinite(@as(f32, @bitCast(std.mem.readInt(u32, spec.bytes[0..4], .little))))) return error.Unsupported;
                    literal_len = 4;
                    value_words = &.{};
                }
            };
            if (!specialized and (node.opcode == 41 or node.opcode == 48)) {
                literal[0] = 1;
                literal_len = 1;
            } else if (!specialized and (node.opcode == 42 or node.opcode == 49)) {
                literal[0] = 0;
                literal_len = 1;
            } else if (!specialized and ((node.opcode >= 164 and node.opcode <= 168) or (node.opcode >= 170 and node.opcode <= 179))) {
                literal[0] = @intFromBool(try staticCondition(nodes, rid) orelse return error.Unsupported);
                literal_len = 1;
            } else if (!specialized) {
                for (value_words) |value| {
                    std.mem.writeInt(u32, literal[literal_len..][0..4], value, .little);
                    literal_len += 4;
                }
            }
        } else {
            const source_operands = node.words;
            const value_operand_count: usize = switch (instruction.opcode) {
                79 => 2,
                81 => 1,
                82 => 2,
                else => source_operands.len,
            };
            for (source_operands, 0..) |source_id, operand_index| {
                if (operand_index >= value_operand_count) {
                    try operands.append(allocator, source_id); // literal selector, not a source ID
                    continue;
                }
                const source_index = try id(nodes, source_id);
                if (canonical_ids[source_index] == std.math.maxInt(u32)) {
                    if (instruction.opcode == 61 or (instruction.opcode == 65 and operand_index == 0)) {
                        const pointer_node = nodes[source_index];
                        if (pointer_node.kind != .variable) return error.Unsupported;
                        const decoration = decorations[source_index];
                        var semantic_index: ?u32 = null;
                        const expected_storage: ir.Storage = switch (pointer_node.a) {
                            2 => .uniform,
                            12 => .output,
                            else => .input,
                        };
                        for (interfaces.items, 0..) |item, interface_index| {
                            if (item.storage == expected_storage and item.location == decoration.location and item.binding == decoration.binding and item.descriptor_set == decoration.descriptor_set)
                                semantic_index = @intCast(interface_index);
                        }
                        try operands.append(allocator, semantic_index orelse return error.Unsupported);
                        continue;
                    }
                    return error.Malformed;
                }
                try operands.append(allocator, canonical_ids[source_index]);
            }
            if (instruction.opcode == 61) {
                const pointer_id = node.words[0];
                const pointer_node = nodes[try id(nodes, pointer_id)];
                op = if (pointer_node.kind == .variable) switch (pointer_node.a) {
                    2 => .uniform,
                    12 => .storage,
                    else => .input,
                } else .extract;
            }
        }
        const owned_operands = allocator.dupe(u32, operands.items) catch return error.OutOfMemory;
        errdefer allocator.free(owned_operands);
        const owned_literal = allocator.dupe(u8, literal[0..literal_len]) catch return error.OutOfMemory;
        errdefer allocator.free(owned_literal);
        try lowered.append(allocator, .{ .op = op, .ty = shape, .operands = owned_operands, .literal = owned_literal });
        canonical_ids[try id(nodes, rid)] = @intCast(lowered.items.len - 1);
        if (lowered.items.len > ir.max_instructions) return error.LimitExceeded;
    }
    const owned_interfaces = allocator.dupe(ir.Interface, interfaces.items) catch return error.OutOfMemory;
    errdefer allocator.free(owned_interfaces);
    const owned_name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
    errdefer allocator.free(owned_name);
    const owned_instructions = lowered.toOwnedSlice(allocator) catch return error.OutOfMemory;
    defer {
        for (owned_instructions) |item| {
            allocator.free(item.operands);
            allocator.free(item.literal);
        }
        allocator.free(owned_instructions);
    }
    const canonical_instructions = ir.canonicalize(allocator, owned_instructions) catch return error.OutOfMemory;
    errdefer {
        for (canonical_instructions) |item| {
            allocator.free(item.operands);
            allocator.free(item.literal);
        }
        allocator.free(canonical_instructions);
    }
    const bytes = ir.serialize(allocator, requested_stage, owned_name, owned_interfaces, canonical_instructions) catch return error.OutOfMemory;
    return .{ .stage = requested_stage, .entry_name = owned_name, .interfaces = owned_interfaces, .instructions = canonical_instructions, .bytes = bytes, .identity = ir.identify(bytes) };
}

pub const positive_vertex = [_]u32{
    0x0723_0203,    0x0001_0000,     0,              12,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15, 0,               10,             0x6e69616d,     0,
    6,              (4 << 16) | 71,  6,              11,             0,
    (2 << 16) | 19, 1,               (3 << 16) | 22, 2,              32,
    (4 << 16) | 23, 3,               2,              4,              (4 << 16) | 32,
    4,              3,               3,              (3 << 16) | 33, 5,
    1,              (4 << 16) | 59,  4,              6,              3,
    (4 << 16) | 43, 2,               7,              0x3f80_0000,    (7 << 16) | 44,
    3,              8,               7,              7,              7,
    7,              (5 << 16) | 54,  1,              10,             0,
    5,              (2 << 16) | 248, 11,             (3 << 16) | 62, 6,
    8,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Minimal compute profile fixture: one StorageBuffer u32 is written by the
/// entry point. It is intentionally straight-line so the host executor can
/// prove dispatch side effects without accepting general control flow.
pub const compute_store = [_]u32{
    0x0723_0203,    0x0001_0000,    0,               10,             0,
    (2 << 16) | 17, 1,              (3 << 16) | 14,  0,              1,
    (6 << 16) | 15, 5,              8,               0x6e69616d,     0,
    5,              (6 << 16) | 16, 8,               17,             1,
    1,              1,              (3 << 16) | 71,  3,              2,
    (5 << 16) | 72, 3,              0,               35,             0,
    (4 << 16) | 71, 5,              33,              0,              (4 << 16) | 71,
    5,              34,             0,               (2 << 16) | 19, 1,
    (4 << 16) | 21, 2,              32,              0,              (3 << 16) | 30,
    3,              2,              (4 << 16) | 32,  4,              12,
    3,              (4 << 16) | 59, 4,               5,              12,
    (3 << 16) | 33, 6,              1,               (4 << 16) | 43, 2,
    7,              42,             (5 << 16) | 54,  1,              8,
    0,              6,              (2 << 16) | 248, 9,              (3 << 16) | 62,
    5,              7,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising an exact 32-bit signed conversion before
/// the StorageBuffer write.  The source is u32 and the output member is i32;
/// both domains are represented losslessly by the canonical conversion IR.
pub const compute_sconvert_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,              12,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14, 0,               1,
    (6 << 16) | 15,  5,               8,              0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,              17,              1,
    1,               1,               (3 << 16) | 71, 3,               2,
    (4 << 16) | 71,  5,               33,             0,               (5 << 16) | 72,
    3,               0,               35,             0,               (4 << 16) | 71,
    5,               34,              0,              (2 << 16) | 19,  1,
    (4 << 16) | 21,  2,               32,             0,               (4 << 16) | 21,
    10,              32,              1,              (3 << 16) | 30,  3,
    10,              (4 << 16) | 32,  4,              12,              3,
    (4 << 16) | 59,  4,               5,              12,              (3 << 16) | 33,
    6,               1,               (4 << 16) | 43, 2,               7,
    42,              (5 << 16) | 54,  1,              8,               0,
    6,               (2 << 16) | 248, 9,              (4 << 16) | 114, 10,
    11,              7,               (3 << 16) | 62, 5,               11,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising component-wise integer multiplication
/// before the StorageBuffer write. Both operands are literal u32 constants so
/// the frontend can lower the operation into canonical IR without adding
/// dynamic control-flow or indexing semantics.
pub const compute_mul_store = [_]u32{
    0x0723_0203,     0x0001_0000,    0,               12,         0,
    (2 << 16) | 17,  1,              (3 << 16) | 14,  0,          1,
    (6 << 16) | 15,  5,              8,               0x6e69616d, 0,
    5,               (6 << 16) | 16, 8,               17,         1,
    1,               1,              (4 << 16) | 71,  5,          33,
    0,               (4 << 16) | 71, 5,               34,         0,
    (2 << 16) | 19,  1,              (4 << 16) | 21,  2,          32,
    0,               (4 << 16) | 32, 4,               12,         2,
    (4 << 16) | 59,  4,              5,               12,         (3 << 16) | 33,
    6,               1,              (4 << 16) | 43,  2,          7,
    6,               (4 << 16) | 43, 2,               10,         7,
    (5 << 16) | 54,  1,              8,               0,          6,
    (2 << 16) | 248, 9,              (5 << 16) | 132, 2,          11,
    7,               10,             (3 << 16) | 62,  5,          11,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising signed integer negation before the
/// StorageBuffer write. The signedness bit on `OpTypeInt` is set explicitly;
/// unsigned input is rejected by the frontend rather than reinterpreted.
pub const compute_ineg_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,              11,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14, 0,               1,
    (6 << 16) | 15,  5,               8,              0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,              17,              1,
    1,               1,               (4 << 16) | 71, 5,               33,
    0,               (4 << 16) | 71,  5,              34,              0,
    (2 << 16) | 19,  1,               (4 << 16) | 21, 2,               32,
    1,               (4 << 16) | 32,  4,              12,              2,
    (4 << 16) | 59,  4,               5,              12,              (3 << 16) | 33,
    6,               1,               (4 << 16) | 43, 2,               7,
    42,              (5 << 16) | 54,  1,              8,               0,
    6,               (2 << 16) | 248, 9,              (4 << 16) | 126, 2,
    10,              7,               (3 << 16) | 62, 5,               10,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising the integer bitwise family. The four
/// operations remain component-wise and straight-line, making their canonical
/// execution bounded while validating every SPIR-V opcode mapping.
pub const compute_bitwise_store = [_]u32{
    0x0723_0203,     0x0001_0000,    0,               15,         0,
    (2 << 16) | 17,  1,              (3 << 16) | 14,  0,          1,
    (6 << 16) | 15,  5,              8,               0x6e69616d, 0,
    5,               (6 << 16) | 16, 8,               17,         1,
    1,               1,              (4 << 16) | 71,  5,          33,
    0,               (4 << 16) | 71, 5,               34,         0,
    (2 << 16) | 19,  1,              (4 << 16) | 21,  2,          32,
    0,               (4 << 16) | 32, 4,               12,         2,
    (4 << 16) | 59,  4,              5,               12,         (3 << 16) | 33,
    6,               1,              (4 << 16) | 43,  2,          7,
    0xf0f0_f0f0,     (4 << 16) | 43, 2,               10,         0x0ff0_0ff0,
    (5 << 16) | 54,  1,              8,               0,          6,
    (2 << 16) | 248, 9,              (5 << 16) | 199, 2,          11,
    7,               10,             (5 << 16) | 197, 2,          12,
    11,              10,             (5 << 16) | 198, 2,          13,
    12,              7,              (4 << 16) | 200, 2,          14,
    13,              (3 << 16) | 62, 5,               14,         (1 << 16) | 253,
    (1 << 16) | 56,
};

/// Compute profile variant exercising unsigned division/remainder. The same
/// fixture is switched to signed opcodes in the frontend regression test so
/// all five integer quotient/remainder mappings share identical ABI coverage.
pub const compute_integer_div_store = [_]u32{
    0x0723_0203,     0x0001_0000,    0,               14,         0,
    (2 << 16) | 17,  1,              (3 << 16) | 14,  0,          1,
    (6 << 16) | 15,  5,              8,               0x6e69616d, 0,
    5,               (6 << 16) | 16, 8,               17,         1,
    1,               1,              (4 << 16) | 71,  5,          33,
    0,               (4 << 16) | 71, 5,               34,         0,
    (2 << 16) | 19,  1,              (4 << 16) | 21,  2,          32,
    0,               (4 << 16) | 32, 4,               12,         2,
    (4 << 16) | 59,  4,              5,               12,         (3 << 16) | 33,
    6,               1,              (4 << 16) | 43,  2,          7,
    42,              (4 << 16) | 43, 2,               10,         5,
    (5 << 16) | 54,  1,              8,               0,          6,
    (2 << 16) | 248, 9,              (5 << 16) | 134, 2,          11,
    7,               10,             (5 << 16) | 137, 2,          12,
    7,               10,             (5 << 16) | 128, 2,          13,
    11,              12,             (3 << 16) | 62,  5,          13,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising logical left/right shifts. The frontend
/// regression switches the left-shift instruction to arithmetic right shift
/// under a signed `OpTypeInt` to cover all three opcode mappings.
pub const compute_shift_store = [_]u32{
    0x0723_0203,     0x0001_0000,    0,               14,         0,
    (2 << 16) | 17,  1,              (3 << 16) | 14,  0,          1,
    (6 << 16) | 15,  5,              8,               0x6e69616d, 0,
    5,               (6 << 16) | 16, 8,               17,         1,
    1,               1,              (4 << 16) | 71,  5,          33,
    0,               (4 << 16) | 71, 5,               34,         0,
    (2 << 16) | 19,  1,              (4 << 16) | 21,  2,          32,
    0,               (4 << 16) | 32, 4,               12,         2,
    (4 << 16) | 59,  4,              5,               12,         (3 << 16) | 33,
    6,               1,              (4 << 16) | 43,  2,          7,
    0x8000_0001,     (4 << 16) | 43, 2,               10,         1,
    (5 << 16) | 54,  1,              8,               0,          6,
    (2 << 16) | 248, 9,              (5 << 16) | 196, 2,          11,
    7,               10,             (5 << 16) | 194, 2,          12,
    7,               10,             (5 << 16) | 128, 2,          13,
    11,              12,             (3 << 16) | 62,  5,          13,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant that compares a runtime StorageBuffer load before
/// selecting one of two scalar values for the same buffer. This exercises the
/// dynamic integer-comparison lowering while keeping execution straight-line.
pub const compute_dynamic_compare_store = [_]u32{
    0x0723_0203,    0x0001_0000,     0,               17,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14,  0,              1,
    (6 << 16) | 15, 5,               8,               0x6e69616d,     0,
    5,              (6 << 16) | 16,  8,               17,             1,
    1,              1,               (4 << 16) | 71,  5,              33,
    0,              (4 << 16) | 71,  5,               34,             0,
    (2 << 16) | 19, 1,               (4 << 16) | 21,  2,              32,
    0,              (2 << 16) | 20,  12,              (4 << 16) | 32, 4,
    12,             2,               (4 << 16) | 59,  4,              5,
    12,             (3 << 16) | 33,  6,               1,              (4 << 16) | 43,
    2,              11,              42,              (4 << 16) | 43, 2,
    14,             1,               (4 << 16) | 43,  2,              15,
    0,              (5 << 16) | 54,  1,               8,              0,
    6,              (2 << 16) | 248, 9,               (4 << 16) | 61, 2,
    10,             5,               (5 << 16) | 170, 12,             13,
    10,             11,              (6 << 16) | 169, 2,              16,
    13,             14,              15,              (3 << 16) | 62, 5,
    16,             (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant that compares a runtime f32 StorageBuffer load and
/// selects between two float values. The test mutates the comparison opcode to
/// cover every ordered and unordered floating-point predicate mapping.
pub const compute_dynamic_float_compare_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,              17,             0,
    (2 << 16) | 17,  1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15,  5,               8,              0x6e69616d,     0,
    5,               (6 << 16) | 16,  8,              17,             1,
    1,               1,               (4 << 16) | 71, 5,              33,
    0,               (4 << 16) | 71,  5,              34,             0,
    (2 << 16) | 19,  1,               (3 << 16) | 22, 2,              32,
    (2 << 16) | 20,  12,              (4 << 16) | 32, 4,              12,
    2,               (4 << 16) | 59,  4,              5,              12,
    (3 << 16) | 33,  6,               1,              (4 << 16) | 43, 2,
    11,              0x3f80_0000,     (4 << 16) | 43, 2,              14,
    0x4000_0000,     (4 << 16) | 43,  2,              15,             0,
    (5 << 16) | 54,  1,               8,              0,              6,
    (2 << 16) | 248, 9,               (4 << 16) | 61, 2,              10,
    5,               (5 << 16) | 188, 12,             13,             10,
    11,              (6 << 16) | 169, 2,              16,             13,
    14,              15,              (3 << 16) | 62, 5,              16,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant exercising `OpFRem` before the StorageBuffer store.
pub const compute_float_remainder_store = [_]u32{
    0x0723_0203,    0x0001_0000,     0,              12,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15, 5,               8,              0x6e69616d,     0,
    5,              (6 << 16) | 16,  8,              17,             1,
    1,              1,               (4 << 16) | 71, 5,              33,
    0,              (4 << 16) | 71,  5,              34,             0,
    (2 << 16) | 19, 1,               (3 << 16) | 22, 2,              32,
    (4 << 16) | 32, 4,               12,             2,              (4 << 16) | 59,
    4,              5,               12,             (3 << 16) | 33, 6,
    1,              (4 << 16) | 43,  2,              7,              0x40e0_0000,
    (4 << 16) | 43, 2,               10,             0x4000_0000,    (5 << 16) | 54,
    1,              8,               0,              6,              (2 << 16) | 248,
    9,              (5 << 16) | 140, 2,              11,             7,
    10,             (3 << 16) | 62,  5,              11,             (1 << 16) | 253,
    (1 << 16) | 56,
};

/// Scalar-pointer form of the bounded compute store profile.  Unlike the
/// block form above, this exercises the direct StorageBuffer pointee path.
pub const compute_scalar_store = [_]u32{
    0x0723_0203,    0x0001_0000,     0,              10,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15, 5,               8,              0x6e69616d,     0,
    5,              (6 << 16) | 16,  8,              17,             1,
    1,              1,               (4 << 16) | 71, 5,              33,
    0,              (4 << 16) | 71,  5,              34,             0,
    (2 << 16) | 19, 1,               (4 << 16) | 21, 2,              32,
    0,              (4 << 16) | 32,  4,              12,             2,
    (4 << 16) | 59, 4,               5,              12,             (3 << 16) | 33,
    6,              1,               (4 << 16) | 43, 2,              7,
    42,             (5 << 16) | 54,  1,              8,              0,
    6,              (2 << 16) | 248, 9,              (3 << 16) | 62, 5,
    7,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant that reads and writes the same scalar StorageBuffer
/// binding. This exercises the direct OpLoad lowering path and keeps the
/// descriptor as a transactional read/write interface.
pub const compute_scalar_load_store = [_]u32{
    0x0723_0203,    0x0001_0000,     0,               11,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14,  0,              1,
    (6 << 16) | 15, 5,               8,               0x6e69616d,     0,
    5,              (6 << 16) | 16,  8,               17,             1,
    1,              1,               (4 << 16) | 71,  5,              33,
    0,              (4 << 16) | 71,  5,               34,             0,
    (2 << 16) | 19, 1,               (4 << 16) | 21,  2,              32,
    0,              (4 << 16) | 32,  4,               12,             2,
    (4 << 16) | 59, 4,               5,               12,             (3 << 16) | 33,
    6,              1,               (5 << 16) | 54,  1,              8,
    0,              6,               (2 << 16) | 248, 9,              (4 << 16) | 61,
    2,              10,              5,               (3 << 16) | 62, 5,
    10,             (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant using a statically indexed struct member access
/// chain before loading and writing the same StorageBuffer binding.
pub const compute_access_load_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,              14,             0,
    (2 << 16) | 17,  1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15,  5,               8,              0x6e69616d,     0,
    5,               (6 << 16) | 16,  8,              17,             1,
    1,               1,               (3 << 16) | 71, 3,              2,
    (5 << 16) | 72,  3,               0,              35,             0,
    (4 << 16) | 71,  5,               33,             0,              (4 << 16) | 71,
    5,               34,              0,              (2 << 16) | 19, 1,
    (4 << 16) | 21,  2,               32,             0,              (3 << 16) | 30,
    3,               2,               (4 << 16) | 32, 4,              12,
    3,               (4 << 16) | 32,  10,             12,             2,
    (4 << 16) | 59,  4,               5,              12,             (3 << 16) | 33,
    6,               1,               (4 << 16) | 43, 2,              11,
    0,               (5 << 16) | 54,  1,              8,              0,
    6,               (2 << 16) | 248, 9,              (5 << 16) | 65, 10,
    12,              5,               11,             (4 << 16) | 61, 2,
    13,              12,              (3 << 16) | 62, 5,              13,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant with a statically resolved conditional branch. The
/// unselected block writes a different value and must not become observable in
/// the canonical straight-line program.
pub const compute_static_branch_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,               16,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14,  0,               1,
    (6 << 16) | 15,  5,               8,               0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,               17,              1,
    1,               1,               (4 << 16) | 71,  5,               33,
    0,               (4 << 16) | 71,  5,               34,              0,
    (2 << 16) | 19,  1,               (4 << 16) | 21,  2,               32,
    0,               (4 << 16) | 32,  4,               12,              2,
    (2 << 16) | 20,  14,              (4 << 16) | 59,  4,               5,
    12,              (3 << 16) | 33,  6,               1,               (4 << 16) | 43,
    2,               7,               42,              (4 << 16) | 43,  2,
    13,              99,              (3 << 16) | 41,  14,              15,
    (5 << 16) | 54,  1,               8,               0,               6,
    (2 << 16) | 248, 9,               (4 << 16) | 250, 15,              10,
    11,              (2 << 16) | 248, 10,              (3 << 16) | 62,  5,
    7,               (2 << 16) | 249, 12,              (2 << 16) | 248, 11,
    (3 << 16) | 62,  5,               13,              (2 << 16) | 249, 12,
    (2 << 16) | 248, 12,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant with a statically resolved switch. The selector
/// chooses the first case, while the default and second case write a different
/// value that must remain unreachable in the canonical straight-line program.
pub const compute_static_switch_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,               16,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14,  0,               1,
    (6 << 16) | 15,  5,               8,               0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,               17,              1,
    1,               1,               (4 << 16) | 71,  5,               33,
    0,               (4 << 16) | 71,  5,               34,              0,
    (2 << 16) | 19,  1,               (4 << 16) | 21,  2,               32,
    0,               (4 << 16) | 32,  4,               12,              2,
    (2 << 16) | 20,  14,              (4 << 16) | 59,  4,               5,
    12,              (3 << 16) | 33,  6,               1,               (4 << 16) | 43,
    2,               7,               42,              (4 << 16) | 43,  2,
    13,              99,              (3 << 16) | 41,  14,              15,
    (5 << 16) | 54,  1,               8,               0,               6,
    (2 << 16) | 248, 9,               (7 << 16) | 251, 7,               11,
    42,              10,              13,              11,              (2 << 16) | 248,
    10,              (3 << 16) | 62,  5,               7,               (2 << 16) | 249,
    12,              (2 << 16) | 248, 11,              (3 << 16) | 62,  5,
    13,              (2 << 16) | 249, 12,              (2 << 16) | 248, 12,
    (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant with a statically selected conditional merge. The
/// branch values are merged with OpPhi at the join; only the incoming value
/// from the selected predecessor may reach the storage output.
pub const compute_static_branch_phi_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,               17,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14,  0,               1,
    (6 << 16) | 15,  5,               8,               0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,               17,              1,
    1,               1,               (4 << 16) | 71,  5,               33,
    0,               (4 << 16) | 71,  5,               34,              0,
    (2 << 16) | 19,  1,               (4 << 16) | 21,  2,               32,
    0,               (4 << 16) | 32,  4,               12,              2,
    (2 << 16) | 20,  14,              (4 << 16) | 59,  4,               5,
    12,              (3 << 16) | 33,  6,               1,               (4 << 16) | 43,
    2,               7,               42,              (4 << 16) | 43,  2,
    13,              99,              (3 << 16) | 41,  14,              15,
    (5 << 16) | 54,  1,               8,               0,               6,
    (2 << 16) | 248, 9,               (4 << 16) | 250, 15,              10,
    11,              (2 << 16) | 248, 10,              (2 << 16) | 249, 12,
    (2 << 16) | 248, 11,              (2 << 16) | 249, 12,              (2 << 16) | 248,
    12,              (7 << 16) | 245, 2,               16,              7,
    10,              13,              11,              (3 << 16) | 62,  5,
    16,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant whose static branch condition is an integer
/// equality comparison. The comparison is constant-folded before selecting
/// the predecessor used by the join OpPhi.
pub const compute_static_compare_phi_store = [_]u32{
    0x0723_0203,     0x0001_0000,     0,               18,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14,  0,               1,
    (6 << 16) | 15,  5,               8,               0x6e69616d,      0,
    5,               (6 << 16) | 16,  8,               17,              1,
    1,               1,               (4 << 16) | 71,  5,               33,
    0,               (4 << 16) | 71,  5,               34,              0,
    (2 << 16) | 19,  1,               (4 << 16) | 21,  2,               32,
    0,               (4 << 16) | 32,  4,               12,              2,
    (2 << 16) | 20,  14,              (4 << 16) | 59,  4,               5,
    12,              (3 << 16) | 33,  6,               1,               (4 << 16) | 43,
    2,               7,               42,              (4 << 16) | 43,  2,
    13,              99,              (3 << 16) | 41,  14,              15,
    (5 << 16) | 54,  1,               8,               0,               6,
    (2 << 16) | 248, 9,               (5 << 16) | 170, 14,              17,
    7,               7,               (4 << 16) | 250, 17,              10,
    11,              (2 << 16) | 248, 10,              (2 << 16) | 249, 12,
    (2 << 16) | 248, 11,              (2 << 16) | 249, 12,              (2 << 16) | 248,
    12,              (7 << 16) | 245, 2,               16,              7,
    10,              13,              11,              (3 << 16) | 62,  5,
    16,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant using a scalar boolean select before the storage
/// write. This is the first non-straight-line value operation admitted by the
/// bounded frontend; it remains side-effect free and fully SSA-bounded.
pub const compute_select_store = [_]u32{
    0x0723_0203,    0x0001_0000,     0,               18,              0,
    (2 << 16) | 17, 1,               (3 << 16) | 14,  0,               1,
    (6 << 16) | 15, 5,               8,               0x6e69616d,      0,
    5,              (6 << 16) | 16,  8,               17,              1,
    1,              1,               (3 << 16) | 71,  3,               2,
    (5 << 16) | 72, 3,               0,               35,              0,
    (4 << 16) | 71, 5,               33,              0,               (4 << 16) | 71,
    5,              34,              0,               (2 << 16) | 19,  1,
    (4 << 16) | 21, 2,               32,              0,               (3 << 16) | 30,
    3,              2,               (4 << 16) | 32,  4,               12,
    3,              (4 << 16) | 59,  4,               5,               12,
    (3 << 16) | 33, 6,               1,               (4 << 16) | 43,  2,
    7,              42,              (4 << 16) | 43,  2,               16,
    7,              (2 << 16) | 20,  13,              (3 << 16) | 41,  13,
    14,             (5 << 16) | 54,  1,               8,               0,
    6,              (2 << 16) | 248, 9,               (6 << 16) | 169, 2,
    17,             14,              7,               16,              (3 << 16) | 62,
    5,              17,              (1 << 16) | 253, (1 << 16) | 56,
};

/// Compute profile variant: read one statically indexed u32 from a uniform
/// block at set 0/binding 0 and store it into a StorageBuffer at binding 1.
pub const compute_uniform_store = [_]u32{
    0x0723_0203,    0x0001_0000,    0,               18,              0,
    (2 << 16) | 17, 1,              (3 << 16) | 14,  0,               1,
    (7 << 16) | 15, 5,              8,               0x6e69616d,      0,
    5,              9,              (6 << 16) | 16,  8,               17,
    1,              1,              1,               (3 << 16) | 71,  3,
    2,              (5 << 16) | 72, 3,               0,               35,
    0,              (4 << 16) | 71, 5,               33,              0,
    (4 << 16) | 71, 5,              34,              0,               (3 << 16) | 71,
    10,             2,              (5 << 16) | 72,  10,              0,
    35,             0,              (4 << 16) | 71,  9,               33,
    1,              (4 << 16) | 71, 9,               34,              0,
    (2 << 16) | 19, 1,              (4 << 16) | 21,  2,               32,
    0,              (3 << 16) | 30, 3,               2,               (4 << 16) | 32,
    4,              2,              3,               (4 << 16) | 59,  4,
    5,              2,              (3 << 16) | 30,  10,              2,
    (4 << 16) | 32, 11,             12,              10,              (4 << 16) | 59,
    11,             9,              12,              (4 << 16) | 32,  12,
    2,              2,              (3 << 16) | 33,  6,               1,
    (4 << 16) | 43, 2,              7,               0,               (4 << 16) | 43,
    2,              16,             1,               (5 << 16) | 54,  1,
    8,              0,              6,               (2 << 16) | 248, 15,
    (5 << 16) | 65, 12,             13,              5,               7,
    (4 << 16) | 61, 2,              14,              13,              (5 << 16) | 128,
    2,              17,             14,              16,              (3 << 16) | 62,
    9,              17,             (1 << 16) | 253, (1 << 16) | 56,
};

const renumbered_positive_vertex = [_]u32{
    0x0723_0203,    0x0001_0000,     0,              12,             0,
    (2 << 16) | 17, 1,               (3 << 16) | 14, 0,              1,
    (6 << 16) | 15, 0,               1,              0x6e69616d,     0,
    5,              (4 << 16) | 71,  5,              11,             0,
    (2 << 16) | 19, 9,               (3 << 16) | 22, 4,              32,
    (4 << 16) | 23, 7,               4,              4,              (4 << 16) | 32,
    2,              3,               7,              (3 << 16) | 33, 10,
    9,              (4 << 16) | 59,  2,              5,              3,
    (4 << 16) | 43, 4,               3,              0x3f80_0000,    (7 << 16) | 44,
    7,              6,               3,              3,              3,
    3,              (5 << 16) | 54,  9,              1,              0,
    10,             (2 << 16) | 248, 8,              (3 << 16) | 62, 5,
    6,              (1 << 16) | 253, (1 << 16) | 56,
};

pub const rich_vertex = [_]u32{
    0x0723_0203,     0x0001_0000,     0,               64,              0,
    (2 << 16) | 17,  1,               (3 << 16) | 14,  0,               1,
    (7 << 16) | 15,  0,               40,              0x6e69616d,      0,
    30,              31,              (4 << 16) | 71,  30,              11,
    0,               (4 << 16) | 71,  31,              30,              0,
    (4 << 16) | 71,  20,              1,               7,               (2 << 16) | 19,
    1,               (2 << 16) | 20,  2,               (4 << 16) | 21,  3,
    32,              1,               (4 << 16) | 21,  4,               32,
    0,               (3 << 16) | 22,  5,               32,              (4 << 16) | 23,
    6,               5,               2,               (4 << 16) | 23,  7,
    5,               4,               (4 << 16) | 24,  8,               7,
    4,               (4 << 16) | 32,  9,               3,               7,
    (4 << 16) | 32,  10,              1,               7,               (3 << 16) | 33,
    11,              1,               (4 << 16) | 59,  9,               30,
    3,               (4 << 16) | 59,  10,              31,              1,
    (4 << 16) | 50,  5,               20,              0x3f80_0000,     (4 << 16) | 43,
    5,               21,              0x4000_0000,     (4 << 16) | 43,  3,
    22,              1,               (4 << 16) | 43,  4,               23,
    1,               (3 << 16) | 41,  2,               24,              (3 << 16) | 42,
    2,               25,              (7 << 16) | 44,  7,               26,
    20,              20,              20,              20,              (5 << 16) | 44,
    6,               27,              20,              21,              (7 << 16) | 44,
    8,               28,              26,              26,              26,
    26,              (4 << 16) | 50,  5,               29,              0x4040_0000,
    (5 << 16) | 54,  1,               40,              0,               11,
    (2 << 16) | 248, 41,              (4 << 16) | 61,  7,               42,
    31,              (9 << 16) | 79,  7,               43,              42,
    26,              0,               1,               4,               5,
    (5 << 16) | 81,  5,               44,              43,              0,
    (7 << 16) | 80,  7,               45,              44,              44,
    44,              44,              (4 << 16) | 127, 5,               46,
    44,              (5 << 16) | 129, 5,               47,              44,
    46,              (5 << 16) | 131, 5,               48,              47,
    44,              (5 << 16) | 133, 5,               49,              48,
    44,              (5 << 16) | 136, 5,               50,              49,
    44,              (4 << 16) | 109, 4,               51,              44,
    (4 << 16) | 110, 3,               52,              44,              (4 << 16) | 111,
    5,               53,              22,              (4 << 16) | 112, 5,
    54,              23,              (4 << 16) | 124, 4,               55,
    44,              (5 << 16) | 128, 3,               56,              22,
    22,              (5 << 16) | 130, 4,               57,              23,
    23,              (5 << 16) | 142, 7,               58,              45,
    44,              (5 << 16) | 145, 7,               59,              28,
    45,              (3 << 16) | 62,  30,              59,              (1 << 16) | 253,
    (1 << 16) | 56,
};

pub const uniform_vertex = [_]u32{
    0x0723_0203,     0x0001_0000,    0,              48,             0,
    (2 << 16) | 17,  1,              (3 << 16) | 14, 0,              1,
    (7 << 16) | 15,  0,              40,             0x6e69616d,     0,
    30,              31,             (4 << 16) | 71, 30,             11,
    0,               (3 << 16) | 71, 12,             2,              (5 << 16) | 72,
    12,              0,              35,             0,              (4 << 16) | 71,
    31,              34,             0,              (4 << 16) | 71, 31,
    33,              2,              (2 << 16) | 19, 1,              (4 << 16) | 21,
    3,               32,             0,              (3 << 16) | 22, 5,
    32,              (4 << 16) | 23, 7,              5,              4,
    (3 << 16) | 30,  12,             7,              (4 << 16) | 32, 9,
    3,               7,              (4 << 16) | 32, 13,             2,
    12,              (4 << 16) | 32, 14,             2,              7,
    (3 << 16) | 33,  11,             1,              (4 << 16) | 59, 9,
    30,              3,              (4 << 16) | 59, 13,             31,
    2,               (4 << 16) | 43, 3,              20,             0,
    (5 << 16) | 54,  1,              40,             0,              11,
    (2 << 16) | 248, 41,             (5 << 16) | 65, 14,             42,
    31,              20,             (4 << 16) | 61, 7,              43,
    42,              (3 << 16) | 62, 30,             43,             (1 << 16) | 253,
    (1 << 16) | 56,
};

pub const bool_fragment = [_]u32{
    0x0723_0203,    0x0001_0000,    0,               9,              0,
    (2 << 16) | 17, 1,              (3 << 16) | 14,  0,              1,
    (6 << 16) | 15, 4,              7,               0x6e69616d,     0,
    5,              (4 << 16) | 71, 5,               30,             0,
    (4 << 16) | 71, 6,              1,               9,              (2 << 16) | 19,
    1,              (2 << 16) | 20, 2,               (4 << 16) | 32, 3,
    3,              2,              (3 << 16) | 33,  4,              1,
    (4 << 16) | 59, 3,              5,               3,              (3 << 16) | 48,
    2,              6,              (5 << 16) | 54,  1,              7,
    0,              4,              (2 << 16) | 248, 8,              (3 << 16) | 62,
    5,              6,              (1 << 16) | 253, (1 << 16) | 56,
};

fn testOpcodeOffset(words: []const u32, opcode: u16, occurrence: usize) ?usize {
    var cursor: usize = 5;
    var seen: usize = 0;
    while (cursor < words.len) : (cursor += words[cursor] >> 16) if (@as(u16, @truncate(words[cursor])) == opcode) {
        if (seen == occurrence) return cursor;
        seen += 1;
    };
    return null;
}

fn testInsertWords(allocator: std.mem.Allocator, source: []const u32, offset: usize, inserted: []const u32) ![]u32 {
    const result = try allocator.alloc(u32, source.len + inserted.len);
    std.mem.copyForwards(u32, result[0..offset], source[0..offset]);
    std.mem.copyForwards(u32, result[offset..][0..inserted.len], inserted);
    std.mem.copyForwards(u32, result[offset + inserted.len ..], source[offset..]);
    return result;
}

fn testReplaceInstruction(allocator: std.mem.Allocator, source: []const u32, offset: usize, replacement: []const u32) ![]u32 {
    const width: usize = source[offset] >> 16;
    const result = try allocator.alloc(u32, source.len - width + replacement.len);
    std.mem.copyForwards(u32, result[0..offset], source[0..offset]);
    std.mem.copyForwards(u32, result[offset..][0..replacement.len], replacement);
    std.mem.copyForwards(u32, result[offset + replacement.len ..], source[offset + width ..]);
    return result;
}

fn testDynamicVectorAccessVariant(allocator: std.mem.Allocator) ![]u32 {
    var words: std.ArrayList(u32) = .empty;
    try words.appendSlice(allocator, &uniform_vertex);

    // Reserve otherwise-unused IDs for a uniform scalar result pointer, an
    // input scalar pointer, the loaded runtime index, and its input variable.
    // The fixture's bound is already large enough for IDs 15, 16, 44, and 45.
    const function = testOpcodeOffset(words.items, 54, 0).?;
    try words.insertSlice(allocator, function, &.{
        (4 << 16) | 32, 15, 2, 5, // OpTypePointer Uniform f32
        (4 << 16) | 32, 16, 1, 3, // OpTypePointer Input u32
        (4 << 16) | 59, 16, 45, 1, // OpVariable Input
        (4 << 16) | 71, 45, 30, 1, // OpDecorate Location 1
    });
    const entry_point = testOpcodeOffset(words.items, 15, 0).?;
    words.items[entry_point] += 1 << 16;
    try words.insertSlice(allocator, entry_point + 7, &.{45}); // expose runtime index input

    const output_pointer = testOpcodeOffset(words.items, 32, 0).?;
    words.items[output_pointer + 3] = 5; // output pointer becomes scalar f32
    words.items[testOpcodeOffset(words.items, 71, 0).? + 2] = 30; // BuiltIn Position -> Location 0
    const access = testOpcodeOffset(words.items, 65, 0).?;
    words.items[access + 1] = 15; // scalar result pointer
    words.items[access] += 1 << 16;
    try words.insertSlice(allocator, access + 5, &.{44}); // dynamic vector lane
    try words.insertSlice(allocator, access, &.{ (4 << 16) | 61, 3, 44, 45 }); // runtime u32 index
    const load = testOpcodeOffset(words.items, 61, 1).?;
    words.items[load + 1] = 5; // load the selected scalar lane
    return words.toOwnedSlice(allocator);
}

fn testRemoveWord(allocator: std.mem.Allocator, source: []const u32, offset: usize) ![]u32 {
    const result = try allocator.alloc(u32, source.len - 1);
    std.mem.copyForwards(u32, result[0..offset], source[0..offset]);
    std.mem.copyForwards(u32, result[offset..], source[offset + 1 ..]);
    return result;
}

fn testSwapAdjacentInstructions(allocator: std.mem.Allocator, source: []const u32, first: usize) ![]u32 {
    const first_len: usize = source[first] >> 16;
    const second = first + first_len;
    const second_len: usize = source[second] >> 16;
    const result = try allocator.dupe(u32, source);
    std.mem.copyForwards(u32, result[first..][0..second_len], source[second..][0..second_len]);
    std.mem.copyForwards(u32, result[first + second_len ..][0..first_len], source[first..][0..first_len]);
    return result;
}

fn expectDecorationArity(source: []const u32, opcode: u16, occurrence: usize, has_payload: bool, stage: ir.Stage) !void {
    const offset = testOpcodeOffset(source, opcode, occurrence).?;
    const width = source[offset] >> 16;
    if (has_payload) {
        const missing = try testRemoveWord(std.testing.allocator, source, offset + width - 1);
        defer std.testing.allocator.free(missing);
        missing[offset] -= 1 << 16;
        try std.testing.expectError(error.Malformed, compile(std.testing.allocator, missing, stage, "main", &.{}));
    }
    const extra = try testInsertWords(std.testing.allocator, source, offset + width, &.{0});
    defer std.testing.allocator.free(extra);
    extra[offset] += 1 << 16;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, extra, stage, "main", &.{}));
}

test "profile compiles selected straight-line vertex to owned canonical IR" {
    var program = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Stage.vertex, program.stage);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expect(program.interfaces[0].builtin_position);
    try std.testing.expectEqual(ir.Op.output, program.instructions[2].op);
    try std.testing.expectEqualSlices(u8, "ZPUIR3D\x00", program.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{
        90, 80, 85, 73, 82,  51,  68,  0,   1,   0,   0,   0,   2,   0,   0,   0,   0, 4, 0, 0, 0, 109, 97, 105, 110, 1, 0, 0, 0,
        1,  3,  4,  1,  255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 0, 0, 3, 0, 0,   0,  0,   3,   1, 1, 0, 0,
        0,  0,  4,  0,  0,   0,   0,   0,   128, 63,  1,   3,   4,   1,   4,   0,   0, 0, 0, 0, 0, 0,   0,  0,   0,   0, 0, 0, 0,
        0,  0,  0,  0,  0,   0,   0,   0,   0,   18,  3,   4,   1,   2,   0,   0,   0, 0, 0, 0, 0, 1,   0,  0,   0,   0, 0, 0, 0,
    }, program.bytes);
    try std.testing.expectEqualSlices(u8, &.{
        147, 176, 210, 157, 182, 241, 166, 53, 43, 75, 183, 222, 184, 184, 234, 234,
        215, 129, 120, 163, 36,  111, 87,  19, 0,  16, 171, 170, 61,  214, 239, 158,
    }, &program.identity.digest);
    var clone = try program.clone(std.testing.allocator);
    defer clone.deinit(std.testing.allocator);
    try std.testing.expect(program.identity.eql(clone.identity));
}

test "compute profile lowers a bounded storage-buffer store" {
    var program = try compile(std.testing.allocator, &compute_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Stage.compute, program.stage);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expectEqual(ir.Storage.output, program.interfaces[0].storage);
    try std.testing.expectEqual(@as(?u32, 0), program.interfaces[0].descriptor_set);
    try std.testing.expectEqual(@as(?u32, 0), program.interfaces[0].binding);
    try std.testing.expectEqual(ir.Scalar.u32, program.interfaces[0].ty.scalar);
    try std.testing.expectEqual(@as(u8, 1), program.interfaces[0].member_count);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(ir.Op.output, program.instructions[1].op);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));
}

test "compute profile lowers 32-bit signed conversion through canonical IR" {
    var program = try compile(std.testing.allocator, &compute_sconvert_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_convert = false;
    for (program.instructions) |instruction| {
        saw_convert = saw_convert or instruction.op == .convert;
        if (instruction.op == .convert) {
            try std.testing.expectEqual(ir.Scalar.i32, instruction.ty.scalar);
            try std.testing.expectEqual(@as(usize, 1), instruction.operands.len);
        }
    }
    try std.testing.expect(saw_convert);
    try std.testing.expectEqual(ir.Scalar.i32, program.interfaces[0].ty.scalar);

    // Rewire the same module to exercise OpUConvert (i32 -> u32) without
    // changing its serialized control-flow shape.
    var unsigned = compute_sconvert_store;
    const unsigned_struct = testOpcodeOffset(&unsigned, 30, 0).?;
    unsigned[unsigned_struct + 2] = 2;
    const unsigned_constant = testOpcodeOffset(&unsigned, 43, 0).?;
    unsigned[unsigned_constant + 1] = 10;
    const unsigned_convert = testOpcodeOffset(&unsigned, 114, 0).?;
    unsigned[unsigned_convert] = (@as(u32, 4) << 16) | 113;
    unsigned[unsigned_convert + 1] = 2;
    var unsigned_program = try compile(std.testing.allocator, &unsigned, .compute, "main", &.{});
    defer unsigned_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Scalar.u32, unsigned_program.interfaces[0].ty.scalar);
    try std.testing.expectEqual(ir.Op.convert, unsigned_program.instructions[1].op);

    // Add a supported f32 type and use OpFConvert as an exact f32-domain
    // identity.  The output remains a single scalar storage member.
    const struct_offset = testOpcodeOffset(&compute_sconvert_store, 30, 0).?;
    var float_words = try testInsertWords(std.testing.allocator, &compute_sconvert_store, struct_offset, &.{ (3 << 16) | 22, 12, 32 });
    defer std.testing.allocator.free(float_words);
    float_words[3] = 13;
    const float_struct = testOpcodeOffset(float_words, 30, 0).?;
    float_words[float_struct + 2] = 12;
    const float_constant = testOpcodeOffset(float_words, 43, 0).?;
    float_words[float_constant + 1] = 12;
    float_words[float_constant + 3] = 0x3f80_0000;
    const float_convert = testOpcodeOffset(float_words, 114, 0).?;
    float_words[float_convert] = (@as(u32, 4) << 16) | 115;
    float_words[float_convert + 1] = 12;
    var float_program = try compile(std.testing.allocator, float_words, .compute, "main", &.{});
    defer float_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Scalar.f32, float_program.interfaces[0].ty.scalar);
    try std.testing.expectEqual(ir.Op.convert, float_program.instructions[1].op);

    var malformed = compute_sconvert_store;
    const malformed_convert = testOpcodeOffset(&malformed, 114, 0).?;
    malformed[malformed_convert + 1] = 2; // OpSConvert must produce signed i32.
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &malformed, .compute, "main", &.{}));
}

test "compute profile lowers bounded GLSL.std.450 absolute values" {
    var base_words = try testInsertWords(std.testing.allocator, &compute_float_remainder_store, testOpcodeOffset(&compute_float_remainder_store, 54, 0).?, &.{
        (6 << 16) | 11, 12, 0x4c534c47, 0x6474732e, 0x3035342e, 0,
    });
    defer std.testing.allocator.free(base_words);
    base_words[3] = 16;
    const store = testOpcodeOffset(base_words, 62, 0).?;
    base_words[store + 2] = 15;
    const label = testOpcodeOffset(base_words, 248, 0).?;
    const words = try testInsertWords(std.testing.allocator, base_words, label + (base_words[label] >> 16), &.{
        (6 << 16) | 12, 2,              13, 12, 4,  7,
        (7 << 16) | 12, 2,              14, 12, 37, 13,
        7,              (7 << 16) | 12, 2,  15, 12, 40,
        14,             7,
    });
    defer std.testing.allocator.free(words);
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), program.instructions.len);
    var saw_abs = false;
    var saw_min = false;
    var saw_max = false;
    for (program.instructions) |instruction| if (instruction.op == .f_abs) {
        saw_abs = true;
        try std.testing.expectEqual(@as(usize, 1), instruction.operands.len);
        try std.testing.expectEqual(@as(u32, 0), instruction.operands[0]);
    } else if (instruction.op == .f_min) {
        saw_min = true;
        try std.testing.expectEqualSlices(u32, &.{ 1, 0 }, instruction.operands);
    } else if (instruction.op == .f_max) {
        saw_max = true;
        try std.testing.expectEqualSlices(u32, &.{ 2, 0 }, instruction.operands);
    };
    try std.testing.expect(saw_abs);
    try std.testing.expect(saw_min);
    try std.testing.expect(saw_max);
    try std.testing.expectEqual(@as(f32, 7), @as(f32, @bitCast(std.mem.readInt(u32, program.instructions[0].literal[0..4], .little))));
    try std.testing.expectEqual(ir.Op.output, program.instructions[4].op);

    const unsupported = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (6 << 16) | 12, 2, 13, 12, 99, 7 });
    defer std.testing.allocator.free(unsupported);
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, unsupported, .compute, "main", &.{}));

    const malformed = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 1).?, &.{ (6 << 16) | 12, 2, 14, 12, 37, 13 });
    defer std.testing.allocator.free(malformed);
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, malformed, .compute, "main", &.{}));

    // The same f32 chain accepts the bounded GLSL.std.450 FSign opcode.
    var sign_words = try std.testing.allocator.alloc(u32, words.len);
    defer std.testing.allocator.free(sign_words);
    std.mem.copyForwards(u32, sign_words, words);
    const sign_ext = testOpcodeOffset(sign_words, 12, 0).?;
    sign_words[sign_ext + 4] = 6;
    var sign_program = try compile(std.testing.allocator, sign_words, .compute, "main", &.{});
    defer sign_program.deinit(std.testing.allocator);
    var saw_sign = false;
    for (sign_program.instructions) |instruction| saw_sign = saw_sign or instruction.op == .f_sign;
    try std.testing.expect(saw_sign);

    const clamp_words = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (8 << 16) | 12, 2, 13, 12, 43, 7, 7, 7 });
    defer std.testing.allocator.free(clamp_words);
    var clamp_program = try compile(std.testing.allocator, clamp_words, .compute, "main", &.{});
    defer clamp_program.deinit(std.testing.allocator);
    var saw_clamp = false;
    for (clamp_program.instructions) |instruction| saw_clamp = saw_clamp or instruction.op == .f_clamp;
    try std.testing.expect(saw_clamp);
    const malformed_clamp = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (7 << 16) | 12, 2, 13, 12, 43, 7, 7 });
    defer std.testing.allocator.free(malformed_clamp);
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, malformed_clamp, .compute, "main", &.{}));

    for ([_]u32{ 46, 50 }) |ext| {
        const ternary = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (8 << 16) | 12, 2, 13, 12, ext, 7, 7, 7 });
        defer std.testing.allocator.free(ternary);
        var ternary_program = try compile(std.testing.allocator, ternary, .compute, "main", &.{});
        defer ternary_program.deinit(std.testing.allocator);
        const expected: ir.Op = if (ext == 46) .f_mix else .fma;
        try std.testing.expectEqual(expected, ternary_program.instructions[1].op);
        try std.testing.expectEqual(@as(usize, 3), ternary_program.instructions[1].operands.len);
    }
    const step = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (7 << 16) | 12, 2, 13, 12, 48, 7, 7 });
    defer std.testing.allocator.free(step);
    var step_program = try compile(std.testing.allocator, step, .compute, "main", &.{});
    defer step_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Op.f_step, step_program.instructions[1].op);
    const smooth_step = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (8 << 16) | 12, 2, 13, 12, 49, 7, 7, 7 });
    defer std.testing.allocator.free(smooth_step);
    var smooth_step_program = try compile(std.testing.allocator, smooth_step, .compute, "main", &.{});
    defer smooth_step_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Op.f_smooth_step, smooth_step_program.instructions[1].op);
    for ([_]u32{ 1, 2, 3 }) |ext| {
        const rounding = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (6 << 16) | 12, 2, 13, 12, ext, 7 });
        defer std.testing.allocator.free(rounding);
        var rounding_program = try compile(std.testing.allocator, rounding, .compute, "main", &.{});
        defer rounding_program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (ext) {
            1 => .f_round,
            2 => .f_round_even,
            3 => .f_trunc,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, rounding_program.instructions[1].op);
    }
    for ([_]u32{ 8, 9, 10 }) |ext| {
        const elementary = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (6 << 16) | 12, 2, 13, 12, ext, 7 });
        defer std.testing.allocator.free(elementary);
        var elementary_program = try compile(std.testing.allocator, elementary, .compute, "main", &.{});
        defer elementary_program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (ext) {
            8 => .f_floor,
            9 => .f_ceil,
            10 => .f_fract,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, elementary_program.instructions[1].op);
    }
    for ([_]u32{ 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24 }) |ext| {
        const conversion = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (6 << 16) | 12, 2, 13, 12, ext, 7 });
        defer std.testing.allocator.free(conversion);
        var conversion_program = try compile(std.testing.allocator, conversion, .compute, "main", &.{});
        defer conversion_program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (ext) {
            11 => .f_radians,
            12 => .f_degrees,
            13 => .f_sin,
            14 => .f_cos,
            15 => .f_tan,
            16 => .f_asin,
            17 => .f_acos,
            18 => .f_atan,
            19 => .f_sinh,
            20 => .f_cosh,
            21 => .f_tanh,
            22 => .f_asinh,
            23 => .f_acosh,
            24 => .f_atanh,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, conversion_program.instructions[1].op);
    }
    const malformed_trig = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (7 << 16) | 12, 2, 13, 12, 13, 7, 7 });
    defer std.testing.allocator.free(malformed_trig);
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, malformed_trig, .compute, "main", &.{}));
    for ([_]u32{ 27, 28, 29, 30, 31, 32 }) |ext| {
        const elementary = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (6 << 16) | 12, 2, 13, 12, ext, 7 });
        defer std.testing.allocator.free(elementary);
        var elementary_program = try compile(std.testing.allocator, elementary, .compute, "main", &.{});
        defer elementary_program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (ext) {
            27 => .f_exp,
            28 => .f_log,
            29 => .f_exp2,
            30 => .f_log2,
            31 => .f_sqrt,
            32 => .f_inverse_sqrt,
            else => unreachable,
        };
        try std.testing.expectEqual(expected, elementary_program.instructions[1].op);
    }
    for ([_]u32{ 25, 26 }) |ext| {
        const binary = try testReplaceInstruction(std.testing.allocator, words, testOpcodeOffset(words, 12, 0).?, &.{ (7 << 16) | 12, 2, 13, 12, ext, 7, 7 });
        defer std.testing.allocator.free(binary);
        var binary_program = try compile(std.testing.allocator, binary, .compute, "main", &.{});
        defer binary_program.deinit(std.testing.allocator);
        try std.testing.expectEqual(if (ext == 25) ir.Op.f_atan2 else ir.Op.f_pow, binary_program.instructions[1].op);
        try std.testing.expectEqual(@as(usize, 2), binary_program.instructions[1].operands.len);
    }
}

test "GLSL determinant and matrix inverse admissions enforce 4x4 f32 shapes" {
    const scalar = ir.Type{ .scalar = .f32 };
    const matrix = ir.Type{ .scalar = .f32, .columns = 4, .rows = 4 };
    try std.testing.expect(supportedGlslExtInst(33, scalar, matrix));
    try std.testing.expect(supportedGlslExtInst(34, matrix, matrix));
    try std.testing.expect(!supportedGlslExtInst(33, matrix, matrix));
    try std.testing.expect(!supportedGlslExtInst(34, scalar, scalar));
    try std.testing.expect(!supportedGlslExtInst(33, scalar, ir.Type{ .scalar = .f32, .columns = 3, .rows = 3 }));
}

test "GLSL Ldexp admissions preserve f32 value shape" {
    const scalar = ir.Type{ .scalar = .f32 };
    const vec4 = ir.Type{ .scalar = .f32, .columns = 4 };
    const matrix = ir.Type{ .scalar = .f32, .columns = 4, .rows = 4 };
    try std.testing.expect(supportedGlslExtInst(53, scalar, scalar));
    try std.testing.expect(supportedGlslExtInst(53, vec4, vec4));
    try std.testing.expect(!supportedGlslExtInst(53, scalar, matrix));
    try std.testing.expect(!supportedGlslExtInst(53, matrix, matrix));
}

test "GLSL non-NaN min/max/clamp admissions preserve f32 shapes" {
    const scalar = ir.Type{ .scalar = .f32 };
    const vec4 = ir.Type{ .scalar = .f32, .columns = 4 };
    const matrix = ir.Type{ .scalar = .f32, .columns = 4, .rows = 4 };
    try std.testing.expect(supportedGlslExtInst(79, scalar, scalar));
    try std.testing.expect(supportedGlslExtInst(80, vec4, vec4));
    try std.testing.expect(supportedGlslExtInst(81, vec4, vec4));
    try std.testing.expect(!supportedGlslExtInst(79, matrix, matrix));
}

test "GLSL normalized pack and unpack admissions enforce fixed lane counts" {
    const f32_vec2 = ir.Type{ .scalar = .f32, .columns = 2 };
    const f32_vec4 = ir.Type{ .scalar = .f32, .columns = 4 };
    const f32_scalar = ir.Type{ .scalar = .f32 };
    const u32_scalar = ir.Type{ .scalar = .u32 };
    try std.testing.expect(supportedGlslExtInst(54, u32_scalar, f32_vec4));
    try std.testing.expect(supportedGlslExtInst(56, u32_scalar, f32_vec2));
    try std.testing.expect(supportedGlslExtInst(58, u32_scalar, f32_vec2));
    try std.testing.expect(supportedGlslExtInst(59, f32_vec2, u32_scalar));
    try std.testing.expect(supportedGlslExtInst(61, f32_vec2, u32_scalar));
    try std.testing.expect(supportedGlslExtInst(62, f32_vec4, u32_scalar));
    try std.testing.expect(!supportedGlslExtInst(54, u32_scalar, f32_vec2));
    try std.testing.expect(!supportedGlslExtInst(59, f32_scalar, u32_scalar));
    try std.testing.expect(!supportedGlslExtInst(58, u32_scalar, f32_vec4));
}

test "GLSL geometric admissions enforce vector arity and component shapes" {
    const scalar = ir.Type{ .scalar = .f32 };
    const vec2 = ir.Type{ .scalar = .f32, .columns = 2 };
    const vec3 = ir.Type{ .scalar = .f32, .columns = 3 };
    const vec4 = ir.Type{ .scalar = .f32, .columns = 4 };
    try std.testing.expect(supportedGlslExtInst(65, scalar, vec4));
    try std.testing.expect(supportedGlslExtInst(66, scalar, vec2));
    try std.testing.expect(supportedGlslExtInst(67, vec3, vec3));
    try std.testing.expect(supportedGlslExtInst(68, vec4, vec4));
    try std.testing.expect(supportedGlslExtInst(69, vec2, vec2));
    try std.testing.expect(supportedGlslExtInst(70, vec4, vec4));
    try std.testing.expect(supportedGlslExtInst(71, vec3, vec3));
    try std.testing.expect(!supportedGlslExtInst(67, vec4, vec4));
    try std.testing.expect(!supportedGlslExtInst(65, vec4, vec4));
    try std.testing.expect(!supportedGlslExtInst(62, scalar, vec4));
}

test "GLSL integer bit-index admissions preserve signed result shape" {
    const i32_scalar = ir.Type{ .scalar = .i32 };
    const i32_vec4 = ir.Type{ .scalar = .i32, .columns = 4 };
    const u32_vec4 = ir.Type{ .scalar = .u32, .columns = 4 };
    try std.testing.expect(supportedGlslExtInst(72, i32_vec4, u32_vec4));
    try std.testing.expect(supportedGlslExtInst(72, i32_vec4, i32_vec4));
    try std.testing.expect(supportedGlslExtInst(73, i32_vec4, i32_vec4));
    try std.testing.expect(supportedGlslExtInst(74, i32_vec4, u32_vec4));
    try std.testing.expect(supportedGlslExtInst(72, i32_scalar, i32_scalar));
    try std.testing.expect(!supportedGlslExtInst(73, i32_vec4, u32_vec4));
    try std.testing.expect(!supportedGlslExtInst(74, i32_vec4, i32_vec4));
}

test "compute profile lowers bounded GLSL.std.450 integer min/max" {
    for ([_]u32{ 38, 39, 41, 42 }) |ext| {
        var words = compute_ineg_store;
        words[3] = 13; // Reserve IDs through the injected ext-inst import.
        const integer_type = testOpcodeOffset(&words, 21, 0).?;
        words[integer_type + 3] = if (ext == 38 or ext == 41) 0 else 1;
        const function = testOpcodeOffset(&words, 54, 0).?;
        const imported = try testInsertWords(std.testing.allocator, &words, function, &.{
            (6 << 16) | 11, 12, 0x4c534c47, 0x6474732e, 0x3035342e, 0,
        });
        defer std.testing.allocator.free(imported);
        const sneg = testOpcodeOffset(imported, 126, 0).?;
        const ext_min_max = try testReplaceInstruction(std.testing.allocator, imported, sneg, &.{ (7 << 16) | 12, 2, 10, 12, ext, 7, 7 });
        defer std.testing.allocator.free(ext_min_max);
        var program = try compile(std.testing.allocator, ext_min_max, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (ext) {
            38 => .u_min,
            39 => .i_min,
            41 => .u_max,
            42 => .i_max,
            else => unreachable,
        };
        try std.testing.expectEqual(@as(usize, 3), program.instructions.len);
        try std.testing.expectEqual(expected, program.instructions[1].op);
        try std.testing.expectEqual(if (ext == 38 or ext == 41) ir.Scalar.u32 else ir.Scalar.i32, program.instructions[1].ty.scalar);
        try std.testing.expectEqual(ir.Op.output, program.instructions[2].op);
    }
}

test "compute profile lowers bounded GLSL.std.450 integer clamps" {
    for ([_]u32{ 44, 45 }) |ext| {
        var words = compute_ineg_store;
        words[3] = 13;
        const integer_type = testOpcodeOffset(&words, 21, 0).?;
        words[integer_type + 3] = if (ext == 44) 0 else 1;
        const function = testOpcodeOffset(&words, 54, 0).?;
        const imported = try testInsertWords(std.testing.allocator, &words, function, &.{
            (6 << 16) | 11, 12, 0x4c534c47, 0x6474732e, 0x3035342e, 0,
        });
        defer std.testing.allocator.free(imported);
        const sneg = testOpcodeOffset(imported, 126, 0).?;
        const ext_clamp = try testReplaceInstruction(std.testing.allocator, imported, sneg, &.{ (8 << 16) | 12, 2, 10, 12, ext, 7, 7, 7 });
        defer std.testing.allocator.free(ext_clamp);
        var program = try compile(std.testing.allocator, ext_clamp, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 3), program.instructions.len);
        try std.testing.expectEqual(if (ext == 44) ir.Op.u_clamp else ir.Op.i_clamp, program.instructions[1].op);
        try std.testing.expectEqual(if (ext == 44) ir.Scalar.u32 else ir.Scalar.i32, program.instructions[1].ty.scalar);
    }
}

test "compute profile lowers integer multiply before storage output" {
    var program = try compile(std.testing.allocator, &compute_mul_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), program.instructions.len);
    try std.testing.expectEqual(ir.Op.imul, program.instructions[2].op);
    try std.testing.expectEqual(ir.Scalar.u32, program.instructions[2].ty.scalar);
    try std.testing.expectEqual(@as(usize, 2), program.instructions[2].operands.len);
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));
    try std.testing.expectEqual(@as(u32, 7), std.mem.readInt(u32, program.instructions[1].literal[0..4], .little));
    try std.testing.expectEqual(ir.Op.output, program.instructions[3].op);

    var signed = compute_mul_store;
    const integer_type = testOpcodeOffset(&signed, 21, 0).?;
    signed[integer_type + 3] = 1;
    var signed_program = try compile(std.testing.allocator, &signed, .compute, "main", &.{});
    defer signed_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Scalar.i32, signed_program.instructions[2].ty.scalar);
}

test "compute profile lowers signed integer negation and rejects unsigned form" {
    var program = try compile(std.testing.allocator, &compute_ineg_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), program.instructions.len);
    try std.testing.expectEqual(ir.Op.ineg, program.instructions[1].op);
    try std.testing.expectEqual(ir.Scalar.i32, program.instructions[1].ty.scalar);
    try std.testing.expectEqual(ir.Op.output, program.instructions[2].op);

    var unsigned = compute_ineg_store;
    const integer_type = testOpcodeOffset(&unsigned, 21, 0).?;
    unsigned[integer_type + 3] = 0;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &unsigned, .compute, "main", &.{}));
}

test "compute profile lowers the integer bitwise operation family" {
    var program = try compile(std.testing.allocator, &compute_bitwise_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_or = false;
    var saw_xor = false;
    var saw_and = false;
    var saw_not = false;
    for (program.instructions) |instruction| {
        saw_or = saw_or or instruction.op == .bit_or;
        saw_xor = saw_xor or instruction.op == .bit_xor;
        saw_and = saw_and or instruction.op == .bit_and;
        saw_not = saw_not or instruction.op == .bit_not;
    }
    try std.testing.expect(saw_or and saw_xor and saw_and and saw_not);
    try std.testing.expectEqual(ir.Op.output, program.instructions[program.instructions.len - 1].op);
    try std.testing.expectEqual(ir.Scalar.u32, program.instructions[program.instructions.len - 1].ty.scalar);
}

test "compute profile lowers integer bit reversal and population count" {
    const offset = testOpcodeOffset(&compute_bitwise_store, 200, 0).?;
    for ([_]u16{ 204, 205 }) |opcode| {
        var words = compute_bitwise_store;
        words[offset] = (@as(u32, 4) << 16) | opcode;
        var program = try compile(std.testing.allocator, &words, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected: ir.Op = if (opcode == 204) .bit_reverse else .bit_count;
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected;
        try std.testing.expect(found);
    }
}

test "compute profile lowers integer bit-field operations" {
    const offset = testOpcodeOffset(&compute_bitwise_store, 200, 0).?;
    for ([_]u16{ 201, 202, 203 }) |opcode| {
        const extra: []const u32 = switch (opcode) {
            201 => &.{ 12, 7, 7 },
            202, 203 => &.{ 7, 7 },
            else => unreachable,
        };
        var words = try testInsertWords(std.testing.allocator, &compute_bitwise_store, offset + 4, extra);
        defer std.testing.allocator.free(words);
        words[offset] = ((@as(u32, @intCast(4 + extra.len))) << 16) | opcode;
        var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected: ir.Op = switch (opcode) {
            201 => .bit_field_insert,
            202 => .bit_field_s_extract,
            203 => .bit_field_u_extract,
            else => unreachable,
        };
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected;
        try std.testing.expect(found);
    }
}

test "profile lowers dynamic vector extract and insert" {
    var extract = rich_vertex;
    const extract_offset = testOpcodeOffset(&extract, 81, 0).?;
    extract[extract_offset] = (5 << 16) | 77;
    extract[extract_offset + 4] = 22;
    var extract_program = try compile(std.testing.allocator, &extract, .vertex, "main", &.{});
    defer extract_program.deinit(std.testing.allocator);
    var saw_extract = false;
    for (extract_program.instructions) |instruction| saw_extract = saw_extract or instruction.op == .vector_extract_dynamic;
    try std.testing.expect(saw_extract);

    var insert = try testInsertWords(std.testing.allocator, &rich_vertex, rich_vertex.len, &.{});
    defer std.testing.allocator.free(insert);
    const shuffle_offset = testOpcodeOffset(insert, 79, 0).?;
    for (0..3) |_| {
        const shorter = try testRemoveWord(std.testing.allocator, insert, shuffle_offset + 6);
        std.testing.allocator.free(insert);
        insert = shorter;
    }
    insert[shuffle_offset] = (6 << 16) | 78;
    insert[shuffle_offset + 4] = 20;
    insert[shuffle_offset + 5] = 22;
    var insert_program = try compile(std.testing.allocator, insert, .vertex, "main", &.{});
    defer insert_program.deinit(std.testing.allocator);
    var saw_insert = false;
    for (insert_program.instructions) |instruction| saw_insert = saw_insert or instruction.op == .vector_insert_dynamic;
    try std.testing.expect(saw_insert);
}

test "profile lowers static vector composite insertion" {
    var words = try testInsertWords(std.testing.allocator, &rich_vertex, rich_vertex.len, &.{});
    defer std.testing.allocator.free(words);
    const shuffle_offset = testOpcodeOffset(words, 79, 0).?;
    for (0..3) |_| {
        const shorter = try testRemoveWord(std.testing.allocator, words, shuffle_offset + 6);
        std.testing.allocator.free(words);
        words = shorter;
    }
    words[shuffle_offset] = (6 << 16) | 82;
    words[shuffle_offset + 3] = 20;
    words[shuffle_offset + 4] = 42;
    words[shuffle_offset + 5] = 2;
    var program = try compile(std.testing.allocator, words, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var found = false;
    for (program.instructions) |instruction| found = found or instruction.op == .composite_insert;
    try std.testing.expect(found);
}

test "profile lowers OpBitcast with payload-preserving IR semantics" {
    const type_insert_at = testOpcodeOffset(&compute_store, 43, 0).?;
    var words = try testInsertWords(std.testing.allocator, &compute_store, type_insert_at, &.{
        (3 << 16) | 22,
        10,
        32,
        (4 << 16) | 43,
        10,
        11,
        0x3f80_0000,
    });
    const bitcast_insert_at = testOpcodeOffset(words, 62, 0).?;
    const with_bitcast = try testInsertWords(std.testing.allocator, words, bitcast_insert_at, &.{
        (4 << 16) | 124,
        2,
        12,
        11,
    });
    std.testing.allocator.free(words);
    words = with_bitcast;
    defer std.testing.allocator.free(words);
    words[3] = 13;
    const store_offset = testOpcodeOffset(words, 62, 0).?;
    words[store_offset + 2] = 12;
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var found = false;
    for (program.instructions) |instruction| found = found or instruction.op == .bitcast;
    try std.testing.expect(found);
}

test "compute profile lowers OpCopyObject as an exact value copy" {
    const store_offset = testOpcodeOffset(&compute_store, 62, 0).?;
    var words = try testInsertWords(std.testing.allocator, &compute_store, store_offset, &.{
        (4 << 16) | 83,
        2,
        10,
        7,
    });
    defer std.testing.allocator.free(words);
    words[3] = 11;
    const rewritten_store = testOpcodeOffset(words, 62, 0).?;
    words[rewritten_store + 2] = 10;
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var found = false;
    for (program.instructions) |instruction| found = found or instruction.op == .copy_object;
    try std.testing.expect(found);
}

test "compute profile lowers OpQuantizeToF16 for bounded f32 values" {
    const integer_type = testOpcodeOffset(&compute_store, 21, 0).?;
    var words = try testRemoveWord(std.testing.allocator, &compute_store, integer_type + 3);
    words[integer_type] = (3 << 16) | 22;
    const store_offset = testOpcodeOffset(words, 62, 0).?;
    const with_quantize = try testInsertWords(std.testing.allocator, words, store_offset, &.{
        (4 << 16) | 116,
        2,
        10,
        7,
    });
    std.testing.allocator.free(words);
    words = with_quantize;
    defer std.testing.allocator.free(words);
    words[3] = 11;
    const rewritten_store = testOpcodeOffset(words, 62, 0).?;
    words[rewritten_store + 2] = 10;
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var found = false;
    for (program.instructions) |instruction| found = found or instruction.op == .quantize_f16;
    try std.testing.expect(found);
}

test "compute profile lowers scalar extended integer arithmetic and extracts the low member" {
    var words = compute_store;
    words[3] = 14;
    const struct_offset = testOpcodeOffset(&words, 30, 0).?;
    const with_second_member = try testInsertWords(std.testing.allocator, &words, struct_offset + 3, &.{
        (4 << 16) | 30,
        10,
        2,
        2,
    });
    defer std.testing.allocator.free(with_second_member);

    const constant_offset = testOpcodeOffset(with_second_member, 43, 0).?;
    const with_second_constant = try testInsertWords(std.testing.allocator, with_second_member, constant_offset + 4, &.{
        (4 << 16) | 43,
        2,
        11,
        5,
    });
    defer std.testing.allocator.free(with_second_constant);
    const label_offset = testOpcodeOffset(with_second_constant, 248, 0).?;
    const with_extended = try testInsertWords(std.testing.allocator, with_second_constant, label_offset + 2, &.{
        (5 << 16) | 149,
        10,
        12,
        7,
        11,
        (5 << 16) | 81,
        2,
        13,
        12,
        0,
    });
    defer std.testing.allocator.free(with_extended);
    const store_offset = testOpcodeOffset(with_extended, 62, 0).?;
    with_extended[store_offset + 2] = 13;
    const extended_offset = testOpcodeOffset(with_extended, 149, 0).?;
    for ([_]u16{ 149, 150, 151, 152 }) |opcode| {
        var candidate = try std.testing.allocator.dupe(u32, with_extended);
        defer std.testing.allocator.free(candidate);
        candidate[extended_offset] = (@as(u32, 5) << 16) | opcode;
        if (opcode == 152) {
            const integer_type = testOpcodeOffset(candidate, 21, 0).?;
            candidate[integer_type + 3] = 1;
        }
        const expected_op: ir.Op = switch (opcode) {
            149 => .iadd_carry,
            150 => .isub_borrow,
            151 => .umul_extended,
            152 => .smul_extended,
            else => unreachable,
        };
        var program = try compile(std.testing.allocator, candidate, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        var saw_extended = false;
        var saw_extract = false;
        for (program.instructions) |instruction| {
            saw_extended = saw_extended or instruction.op == expected_op;
            saw_extract = saw_extract or instruction.op == .extract;
        }
        try std.testing.expect(saw_extended and saw_extract);
    }
}

test "compute profile lowers integer division and remainder with exact signedness" {
    var program = try compile(std.testing.allocator, &compute_integer_div_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_udiv = false;
    var saw_umod = false;
    for (program.instructions) |instruction| {
        saw_udiv = saw_udiv or instruction.op == .udiv;
        saw_umod = saw_umod or instruction.op == .umod;
    }
    try std.testing.expect(saw_udiv and saw_umod);

    const first_div = testOpcodeOffset(&compute_integer_div_store, 134, 0).?;
    const second_div = testOpcodeOffset(&compute_integer_div_store, 137, 0).?;
    const signed_type = testOpcodeOffset(&compute_integer_div_store, 21, 0).?;
    var signed_div = compute_integer_div_store;
    signed_div[signed_type + 3] = 1;
    signed_div[first_div] = (5 << 16) | 135;
    signed_div[second_div] = (5 << 16) | 138;
    var signed_program = try compile(std.testing.allocator, &signed_div, .compute, "main", &.{});
    defer signed_program.deinit(std.testing.allocator);
    var saw_sdiv = false;
    for (signed_program.instructions) |instruction| saw_sdiv = saw_sdiv or instruction.op == .sdiv;
    try std.testing.expect(saw_sdiv);

    for ([_]u16{ 138, 139 }) |opcode| {
        var signed_remainder = compute_integer_div_store;
        signed_remainder[signed_type + 3] = 1;
        signed_remainder[first_div] = (5 << 16) | 135;
        signed_remainder[second_div] = (@as(u32, 5) << 16) | opcode;
        var remainder_program = try compile(std.testing.allocator, &signed_remainder, .compute, "main", &.{});
        defer remainder_program.deinit(std.testing.allocator);
        var saw_remainder = false;
        for (remainder_program.instructions) |instruction| saw_remainder = saw_remainder or (opcode == 138 and instruction.op == .srem) or (opcode == 139 and instruction.op == .smod);
        try std.testing.expect(saw_remainder);
    }
}

test "compute profile lowers logical and arithmetic integer shifts" {
    var program = try compile(std.testing.allocator, &compute_shift_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_left = false;
    var saw_logical_right = false;
    for (program.instructions) |instruction| {
        saw_left = saw_left or instruction.op == .shl_logical;
        saw_logical_right = saw_logical_right or instruction.op == .shr_logical;
    }
    try std.testing.expect(saw_left and saw_logical_right);

    var arithmetic = compute_shift_store;
    const shift = testOpcodeOffset(&arithmetic, 196, 0).?;
    const integer_type = testOpcodeOffset(&arithmetic, 21, 0).?;
    arithmetic[shift] = (5 << 16) | 195;
    arithmetic[integer_type + 3] = 1;
    var arithmetic_program = try compile(std.testing.allocator, &arithmetic, .compute, "main", &.{});
    defer arithmetic_program.deinit(std.testing.allocator);
    var saw_arithmetic = false;
    for (arithmetic_program.instructions) |instruction| saw_arithmetic = saw_arithmetic or instruction.op == .shr_arithmetic;
    try std.testing.expect(saw_arithmetic);
}

test "compute profile lowers dynamic integer comparison before select" {
    var program = try compile(std.testing.allocator, &compute_dynamic_compare_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_load = false;
    var saw_compare = false;
    var saw_select = false;
    for (program.instructions) |instruction| {
        saw_load = saw_load or instruction.op == .storage;
        saw_compare = saw_compare or instruction.op == .ieq;
        saw_select = saw_select or instruction.op == .select;
    }
    try std.testing.expect(saw_load and saw_compare and saw_select);

    var not_equal = compute_dynamic_compare_store;
    const compare = testOpcodeOffset(&not_equal, 170, 0).?;
    not_equal[compare] = (5 << 16) | 171;
    var unequal_program = try compile(std.testing.allocator, &not_equal, .compute, "main", &.{});
    defer unequal_program.deinit(std.testing.allocator);
    var saw_ine = false;
    for (unequal_program.instructions) |instruction| saw_ine = saw_ine or instruction.op == .ine;
    try std.testing.expect(saw_ine);
}

test "compute profile lowers a side-effect-free dynamic branch phi to select" {
    const select_offset = testOpcodeOffset(&compute_dynamic_compare_store, 169, 0).?;
    const branch_and_merge = [_]u32{
        (3 << 16) | 247, 20,              0,
        (4 << 16) | 250, 13,              18,
        19,              (2 << 16) | 248, 18,
        (2 << 16) | 249, 20,              (2 << 16) | 248,
        19,              (2 << 16) | 249, 20,
        (2 << 16) | 248, 20,              (7 << 16) | 245,
        2,               16,              14,
        18,              15,              19,
    };
    var words = try testReplaceInstruction(std.testing.allocator, &compute_dynamic_compare_store, select_offset, &branch_and_merge);
    defer std.testing.allocator.free(words);
    words[3] = 21;
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_compare = false;
    var saw_select = false;
    for (program.instructions) |instruction| {
        saw_compare = saw_compare or instruction.op == .ieq;
        saw_select = saw_select or instruction.op == .select;
    }
    try std.testing.expect(saw_compare and saw_select);
    var select_index: ?usize = null;
    for (program.instructions, 0..) |instruction, index| {
        if (instruction.op == .select) select_index = index;
    }
    try std.testing.expect(select_index != null);
    try std.testing.expectEqual(@as(usize, 3), program.instructions[select_index.?].operands.len);
    try std.testing.expectEqual(ir.Op.ieq, program.instructions[program.instructions[select_index.?].operands[0]].op);

    var mismatched = try std.testing.allocator.dupe(u32, words);
    defer std.testing.allocator.free(mismatched);
    const second_branch = testOpcodeOffset(mismatched, 249, 1).?;
    mismatched[second_branch + 1] = 18;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, mismatched, .compute, "main", &.{}));

    const true_label = testOpcodeOffset(words, 248, 1).?;
    var side_effect = try testInsertWords(std.testing.allocator, words, true_label + 2, &.{ (3 << 16) | 62, 5, 14 });
    defer std.testing.allocator.free(side_effect);
    side_effect[3] = 21;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, side_effect, .compute, "main", &.{}));
}

test "dynamic branch frontend warm path remains bounded and deterministic" {
    const select_offset = testOpcodeOffset(&compute_dynamic_compare_store, 169, 0).?;
    const branch_and_merge = [_]u32{
        (3 << 16) | 247, 20,              0,
        (4 << 16) | 250, 13,              18,
        19,              (2 << 16) | 248, 18,
        (2 << 16) | 249, 20,              (2 << 16) | 248,
        19,              (2 << 16) | 249, 20,
        (2 << 16) | 248, 20,              (7 << 16) | 245,
        2,               16,              14,
        18,              15,              19,
    };
    var words = try testReplaceInstruction(std.testing.allocator, &compute_dynamic_compare_store, select_offset, &branch_and_merge);
    defer std.testing.allocator.free(words);
    words[3] = 21;
    var baseline = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer baseline.deinit(std.testing.allocator);
    try std.testing.expect(baseline.instructions.len <= ir.max_instructions);
    for (0..64) |_| {
        var candidate = try compile(std.testing.allocator, words, .compute, "main", &.{});
        defer candidate.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, baseline.bytes, candidate.bytes);
    }
}

test "compute profile lowers a one-case dynamic switch phi to compare and select" {
    const select_offset = testOpcodeOffset(&compute_dynamic_compare_store, 169, 0).?;
    const switch_and_merge = [_]u32{
        (3 << 16) | 247, 20,              0,
        (5 << 16) | 251, 10,              19,
        14,              18,              (2 << 16) | 248,
        18,              (2 << 16) | 249, 20,
        (2 << 16) | 248, 19,              (2 << 16) | 249,
        20,              (2 << 16) | 248, 20,
        (7 << 16) | 245, 2,               16,
        14,              18,              15,
        19,
    };
    var words = try testReplaceInstruction(std.testing.allocator, &compute_dynamic_compare_store, select_offset, &switch_and_merge);
    defer std.testing.allocator.free(words);
    words[3] = 21;
    var program = try compile(std.testing.allocator, words, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var saw_compare = false;
    var saw_select = false;
    var saw_case_constant = false;
    for (program.instructions) |instruction| {
        saw_compare = saw_compare or instruction.op == .ieq;
        saw_select = saw_select or instruction.op == .select;
        if (instruction.op == .constant and instruction.literal.len == 4)
            saw_case_constant = saw_case_constant or std.mem.eql(u8, instruction.literal, &.{ 14, 0, 0, 0 });
    }
    try std.testing.expect(saw_compare and saw_select and saw_case_constant);

    for (0..32) |_| {
        var candidate = try compile(std.testing.allocator, words, .compute, "main", &.{});
        defer candidate.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, program.bytes, candidate.bytes);
    }

    var mismatched = try std.testing.allocator.dupe(u32, words);
    defer std.testing.allocator.free(mismatched);
    const second_branch = testOpcodeOffset(mismatched, 249, 1).?;
    mismatched[second_branch + 1] = 18;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, mismatched, .compute, "main", &.{}));
}

test "compute profile lowers dynamic boolean logical operations" {
    const opcodes = [_]u16{ 164, 165, 166, 167, 168 };
    const expected = [_]ir.Op{ .logical_eq, .logical_ne, .logical_or, .logical_and, .logical_not };
    for (opcodes, expected) |opcode, expected_op| {
        var words = compute_dynamic_compare_store;
        words[3] = 20;
        const select = testOpcodeOffset(&words, 169, 0).?;
        const binary = opcode != 168;
        const inserted_words: []const u32 = if (binary)
            &[_]u32{ (@as(u32, 5) << 16) | opcode, 12, 19, 13, 13 }
        else
            &[_]u32{ (@as(u32, 4) << 16) | opcode, 12, 19, 13 };
        var expanded = try testInsertWords(std.testing.allocator, &words, select, inserted_words);
        defer std.testing.allocator.free(expanded);
        const selected = testOpcodeOffset(expanded, 169, 0).?;
        expanded[selected + 3] = 19;
        var program = try compile(std.testing.allocator, expanded, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected_op;
        try std.testing.expect(found);
    }
}

test "compute profile lowers ordered and unordered float comparisons" {
    const opcodes = [_]u16{ 182, 183, 184, 185, 186, 187, 188, 189, 190, 191, 192, 193 };
    const expected = [_]ir.Op{ .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge };
    for (opcodes, expected) |opcode, expected_op| {
        var words = compute_dynamic_float_compare_store;
        const comparison = testOpcodeOffset(&words, 188, 0).?;
        words[comparison] = (@as(u32, 5) << 16) | opcode;
        var program = try compile(std.testing.allocator, &words, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected_op;
        try std.testing.expect(found);
    }
}

test "compute profile lowers floating remainder" {
    var program = try compile(std.testing.allocator, &compute_float_remainder_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var found = false;
    for (program.instructions) |instruction| found = found or instruction.op == .frem;
    try std.testing.expect(found);

    var modulo_words = compute_float_remainder_store;
    const modulo_offset = testOpcodeOffset(&modulo_words, 140, 0).?;
    modulo_words[modulo_offset] = (5 << 16) | 141;
    var modulo_program = try compile(std.testing.allocator, &modulo_words, .compute, "main", &.{});
    defer modulo_program.deinit(std.testing.allocator);
    var modulo_found = false;
    for (modulo_program.instructions) |instruction| modulo_found = modulo_found or instruction.op == .fmod;
    try std.testing.expect(modulo_found);
}

test "compute profile lowers floating classifications and ordered domains" {
    var words = compute_float_remainder_store;
    const pointer_offset = testOpcodeOffset(&words, 32, 0).?;
    var typed = try testInsertWords(std.testing.allocator, &words, pointer_offset, &.{ (2 << 16) | 20, 3 });
    defer std.testing.allocator.free(typed);
    const pointer = testOpcodeOffset(typed, 32, 0).?;
    typed[pointer + 3] = 3;
    const remainder = testOpcodeOffset(typed, 140, 0).?;
    var unary = try testRemoveWord(std.testing.allocator, typed, remainder + 4);
    defer std.testing.allocator.free(unary);
    unary[remainder] = (4 << 16) | 156;
    unary[remainder + 1] = 3;
    for ([_]u16{ 156, 157, 158, 159, 160 }) |opcode| {
        unary[remainder] = (@as(u32, 4) << 16) | opcode;
        var program = try compile(std.testing.allocator, unary, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected = switch (opcode) {
            156 => ir.Op.is_nan,
            157 => ir.Op.is_inf,
            158 => ir.Op.is_finite,
            159 => ir.Op.is_normal,
            160 => ir.Op.sign_bit_set,
            else => unreachable,
        };
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected;
        try std.testing.expect(found);
    }
    for ([_]u16{ 161, 162, 163 }) |opcode| {
        var binary = try testInsertWords(std.testing.allocator, unary, remainder + 4, &.{10});
        defer std.testing.allocator.free(binary);
        binary[remainder] = (@as(u32, 5) << 16) | opcode;
        var program = try compile(std.testing.allocator, binary, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected = switch (opcode) {
            161 => ir.Op.less_or_greater,
            162 => ir.Op.ordered,
            163 => ir.Op.unordered,
            else => unreachable,
        };
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected;
        try std.testing.expect(found);
    }
}

test "compute profile lowers boolean any and all reductions" {
    var words = compute_float_remainder_store;
    const pointer_offset = testOpcodeOffset(&words, 32, 0).?;
    var typed = try testInsertWords(std.testing.allocator, &words, pointer_offset, &.{ (2 << 16) | 20, 3 });
    defer std.testing.allocator.free(typed);
    const pointer = testOpcodeOffset(typed, 32, 0).?;
    typed[pointer + 3] = 3;
    const function_offset = testOpcodeOffset(typed, 54, 0).?;
    var declarations = try testInsertWords(std.testing.allocator, typed, function_offset, &.{
        (4 << 16) | 23, 12, 3,              4,
        (3 << 16) | 41, 3,  13,             (3 << 16) | 42,
        3,              14, (7 << 16) | 44, 12,
        15,             13, 14,             13,
        14,
    });
    defer std.testing.allocator.free(declarations);
    declarations[3] = 16;
    const remainder = testOpcodeOffset(declarations, 140, 0).?;
    var reduction = try testRemoveWord(std.testing.allocator, declarations, remainder + 4);
    defer std.testing.allocator.free(reduction);
    reduction[remainder] = (4 << 16) | 154;
    reduction[remainder + 1] = 3;
    reduction[remainder + 2] = 11;
    reduction[remainder + 3] = 15;
    for ([_]u16{ 154, 155 }) |opcode| {
        reduction[remainder] = (@as(u32, 4) << 16) | opcode;
        var program = try compile(std.testing.allocator, reduction, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const expected: ir.Op = if (opcode == 154) .any else .all;
        var found = false;
        for (program.instructions) |instruction| found = found or instruction.op == expected;
        try std.testing.expect(found);
    }
}

test "compute profile accepts a scalar storage-buffer pointer" {
    var program = try compile(std.testing.allocator, &compute_scalar_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expectEqual(ir.Storage.output, program.interfaces[0].storage);
    try std.testing.expectEqual(@as(u8, 0), program.interfaces[0].member_count);
    try std.testing.expectEqual(ir.Op.output, program.instructions[1].op);
}

test "compute profile lowers a scalar storage-buffer load" {
    var program = try compile(std.testing.allocator, &compute_scalar_load_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expectEqual(ir.Storage.output, program.interfaces[0].storage);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(ir.Op.storage, program.instructions[0].op);
    try std.testing.expectEqual(ir.Op.output, program.instructions[1].op);
}

test "compute profile lowers a static storage-buffer access-chain load" {
    var program = try compile(std.testing.allocator, &compute_access_load_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    var saw_access = false;
    var saw_extract = false;
    var saw_output = false;
    for (program.instructions) |instruction| {
        saw_access = saw_access or instruction.op == .access;
        saw_extract = saw_extract or instruction.op == .extract;
        saw_output = saw_output or instruction.op == .output;
    }
    try std.testing.expect(saw_access and saw_extract and saw_output);
}

test "compute profile resolves a static conditional branch" {
    var program = try compile(std.testing.allocator, &compute_static_branch_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(ir.Op.constant, program.instructions[0].op);
    try std.testing.expectEqual(ir.Op.output, program.instructions[1].op);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));
    const branch_offset = testOpcodeOffset(&compute_static_branch_store, 250, 0).?;
    var structured = try testInsertWords(std.testing.allocator, &compute_static_branch_store, branch_offset, &.{ (3 << 16) | 247, 12, 0 });
    defer std.testing.allocator.free(structured);
    var structured_program = try compile(std.testing.allocator, structured, .compute, "main", &.{});
    defer structured_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), structured_program.instructions.len);
    structured[testOpcodeOffset(structured, 247, 0).? + 2] = 1;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, structured, .compute, "main", &.{}));
    var dynamic = compute_static_branch_store;
    const branch = testOpcodeOffset(&dynamic, 250, 0).?;
    dynamic[branch + 1] = 7;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &dynamic, .compute, "main", &.{}));
    var false_branch = compute_static_branch_store;
    const condition = testOpcodeOffset(&false_branch, 41, 0).?;
    false_branch[condition] = (3 << 16) | 42;
    var false_program = try compile(std.testing.allocator, &false_branch, .compute, "main", &.{});
    defer false_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, false_program.instructions[0].literal[0..4], .little));
}

test "compute profile resolves a static switch and rejects dynamic or duplicate cases" {
    var program = try compile(std.testing.allocator, &compute_static_switch_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));

    var dynamic = compute_static_switch_store;
    const switch_offset = testOpcodeOffset(&dynamic, 251, 0).?;
    dynamic[switch_offset + 1] = 15;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &dynamic, .compute, "main", &.{}));

    var duplicate = compute_static_switch_store;
    duplicate[switch_offset + 5] = 42;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &duplicate, .compute, "main", &.{}));

    var default_case = compute_static_switch_store;
    default_case[switch_offset + 3] = 7;
    var default_program = try compile(std.testing.allocator, &default_case, .compute, "main", &.{});
    defer default_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, default_program.instructions[0].literal[0..4], .little));
}

test "compute profile resolves a static branch phi merge" {
    var program = try compile(std.testing.allocator, &compute_static_branch_phi_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(ir.Op.constant, program.instructions[0].op);
    try std.testing.expectEqual(ir.Op.output, program.instructions[1].op);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));

    var false_branch = compute_static_branch_phi_store;
    const condition = testOpcodeOffset(&false_branch, 41, 0).?;
    false_branch[condition] = (3 << 16) | 42;
    var false_program = try compile(std.testing.allocator, &false_branch, .compute, "main", &.{});
    defer false_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), false_program.instructions.len);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, false_program.instructions[0].literal[0..4], .little));

    var duplicate_predecessor = compute_static_branch_phi_store;
    const phi = testOpcodeOffset(&duplicate_predecessor, 245, 0).?;
    duplicate_predecessor[phi + 6] = 10;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &duplicate_predecessor, .compute, "main", &.{}));

    var dynamic = compute_static_branch_phi_store;
    const branch = testOpcodeOffset(&dynamic, 250, 0).?;
    dynamic[branch + 1] = 7;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &dynamic, .compute, "main", &.{}));
}

test "compute profile folds constant integer comparisons for branch phi" {
    var program = try compile(std.testing.allocator, &compute_static_compare_phi_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), program.instructions.len);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));

    var false_compare = compute_static_compare_phi_store;
    const compare = testOpcodeOffset(&false_compare, 170, 0).?;
    false_compare[compare + 4] = 13;
    var false_program = try compile(std.testing.allocator, &false_compare, .compute, "main", &.{});
    defer false_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, false_program.instructions[0].literal[0..4], .little));

    var not_equal = compute_static_compare_phi_store;
    not_equal[compare] = (5 << 16) | 171;
    var not_equal_program = try compile(std.testing.allocator, &not_equal, .compute, "main", &.{});
    defer not_equal_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, not_equal_program.instructions[0].literal[0..4], .little));

    const comparison_opcodes = [_]u16{ 170, 171, 172, 173, 174, 175, 176, 177, 178, 179 };
    const expected_true = [_]bool{ true, false, false, true, false, true, false, true, false, true };
    for (comparison_opcodes, expected_true) |opcode, expected| {
        var candidate = compute_static_compare_phi_store;
        const candidate_compare = testOpcodeOffset(&candidate, 170, 0).?;
        candidate[candidate_compare] = (@as(u32, 5) << 16) | opcode;
        if (opcode >= 176) {
            const integer_type = testOpcodeOffset(&candidate, 21, 0).?;
            candidate[integer_type + 3] = 1;
        }
        var candidate_program = try compile(std.testing.allocator, &candidate, .compute, "main", &.{});
        defer candidate_program.deinit(std.testing.allocator);
        const expected_value: u32 = if (expected) 42 else 99;
        try std.testing.expectEqual(expected_value, std.mem.readInt(u32, candidate_program.instructions[0].literal[0..4], .little));
    }

    var unsupported = compute_static_compare_phi_store;
    const branch = testOpcodeOffset(&unsupported, 250, 0).?;
    unsupported[branch + 1] = 7;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &unsupported, .compute, "main", &.{}));
}

test "compute profile folds nested static logical conditions" {
    const branch_offset = testOpcodeOffset(&compute_static_compare_phi_store, 250, 0).?;
    const binary_words = [_]u32{ (5 << 16) | 166, 14, 18, 17, 15 };
    var binary = try testInsertWords(std.testing.allocator, &compute_static_compare_phi_store, branch_offset, &binary_words);
    defer std.testing.allocator.free(binary);
    binary[3] = 19;
    const binary_branch = testOpcodeOffset(binary, 250, 0).?;
    binary[binary_branch + 1] = 18;
    const logical = testOpcodeOffset(binary, 166, 0).?;
    const logical_opcodes = [_]u16{ 164, 165, 166, 167 };
    const logical_expected = [_]u32{ 42, 99, 42, 42 };
    for (logical_opcodes, logical_expected) |opcode, expected| {
        binary[logical] = (@as(u32, 5) << 16) | opcode;
        var program = try compile(std.testing.allocator, binary, .compute, "main", &.{});
        defer program.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected, std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));
    }

    var unary = try testInsertWords(std.testing.allocator, &compute_static_compare_phi_store, branch_offset, &.{ (4 << 16) | 168, 14, 18, 17 });
    defer std.testing.allocator.free(unary);
    unary[3] = 19;
    const unary_branch = testOpcodeOffset(unary, 250, 0).?;
    unary[unary_branch + 1] = 18;
    var unary_program = try compile(std.testing.allocator, unary, .compute, "main", &.{});
    defer unary_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, unary_program.instructions[0].literal[0..4], .little));
}

test "compute profile resolves a static boolean select branch" {
    const true_offset = testOpcodeOffset(&compute_static_compare_phi_store, 41, 0).?;
    var with_false = try testInsertWords(std.testing.allocator, &compute_static_compare_phi_store, true_offset, &.{ (3 << 16) | 42, 14, 18 });
    defer std.testing.allocator.free(with_false);
    with_false[3] = 20;
    const branch_offset = testOpcodeOffset(with_false, 250, 0).?;
    var selected = try testInsertWords(std.testing.allocator, with_false, branch_offset, &.{ (6 << 16) | 169, 14, 19, 17, 15, 18 });
    defer std.testing.allocator.free(selected);
    selected[3] = 20;
    const selected_branch = testOpcodeOffset(selected, 250, 0).?;
    selected[selected_branch + 1] = 19;
    var program = try compile(std.testing.allocator, selected, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, program.instructions[0].literal[0..4], .little));

    const compare = testOpcodeOffset(selected, 170, 0).?;
    selected[compare + 4] = 13;
    var false_program = try compile(std.testing.allocator, selected, .compute, "main", &.{});
    defer false_program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 99), std.mem.readInt(u32, false_program.instructions[0].literal[0..4], .little));
}

test "compute profile lowers a boolean select into storage output" {
    var program = try compile(std.testing.allocator, &compute_select_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 5), program.instructions.len);
    try std.testing.expectEqual(ir.Op.select, program.instructions[3].op);
    try std.testing.expectEqual(ir.Op.output, program.instructions[4].op);
    try std.testing.expectEqual(ir.Scalar.u32, program.instructions[3].ty.scalar);
}

test "compute profile lowers a static uniform load into storage output" {
    var program = try compile(std.testing.allocator, &compute_uniform_store, .compute, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Stage.compute, program.stage);
    try std.testing.expectEqual(@as(usize, 2), program.interfaces.len);
    var uniform_index: ?usize = null;
    var output_index: ?usize = null;
    for (program.interfaces, 0..) |interface, index| {
        if (interface.storage == .uniform) uniform_index = index;
        if (interface.storage == .output) output_index = index;
    }
    try std.testing.expect(uniform_index != null and output_index != null);
    try std.testing.expectEqual(@as(?u32, 0), program.interfaces[uniform_index.?].binding);
    try std.testing.expectEqual(@as(?u32, 1), program.interfaces[output_index.?].binding);
    var saw_access = false;
    var saw_iadd = false;
    var saw_output = false;
    for (program.instructions) |instruction| {
        saw_access = saw_access or instruction.op == .access;
        saw_iadd = saw_iadd or instruction.op == .iadd;
        saw_output = saw_output or instruction.op == .output;
    }
    try std.testing.expect(saw_access and saw_iadd and saw_output);
}

test "rich profile fixture removes dead arithmetic without changing live matrix data flow" {
    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    var program = try compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 7, .bytes = &replacement }});
    defer program.deinit(std.testing.allocator);
    var seen = [_]bool{false} ** @typeInfo(ir.Op).@"enum".fields.len;
    for (program.instructions) |instruction| seen[@intFromEnum(instruction.op)] = true;
    for ([_]ir.Op{ .constant, .constant_composite, .matrix_times_vector, .output }) |op|
        try std.testing.expect(seen[@intFromEnum(op)]);
    try std.testing.expect(!seen[@intFromEnum(ir.Op.fadd)]);
    try std.testing.expect(std.mem.indexOf(u8, program.bytes, &replacement) != null);
    const non_finite = [_]u8{ 0, 0, 0x80, 0x7f };
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 7, .bytes = &non_finite }}));
}

test "profile lowers the complete bounded matrix arithmetic family" {
    const output_offset = testOpcodeOffset(&rich_vertex, 62, 0).?;
    var extended = try testInsertWords(std.testing.allocator, &rich_vertex, output_offset, &.{
        (5 << 16) | 143, 8, 60, 28, 20,
        (5 << 16) | 144, 7, 61, 45, 28,
        (5 << 16) | 146, 8, 62, 28, 60,
        (5 << 16) | 145, 7, 63, 62, 61,
    });
    defer std.testing.allocator.free(extended);
    const new_output_offset = testOpcodeOffset(extended, 62, 0).?;
    extended[new_output_offset + 2] = 63;
    var program = try compile(std.testing.allocator, extended, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var seen = [_]bool{false} ** @typeInfo(ir.Op).@"enum".fields.len;
    for (program.instructions) |instruction| seen[@intFromEnum(instruction.op)] = true;
    for ([_]ir.Op{ .matrix_times_scalar, .vector_times_matrix, .matrix_times_matrix, .matrix_times_vector, .output }) |op|
        try std.testing.expect(seen[@intFromEnum(op)]);
}

test "profile lowers transpose outer product and dot through a live value chain" {
    const output_offset = testOpcodeOffset(&rich_vertex, 62, 0).?;
    var extended = try testInsertWords(std.testing.allocator, &rich_vertex, output_offset, &.{
        (4 << 16) | 84,  8,               60,              28,
        (5 << 16) | 147, 8,               61,              45,
        45,              (5 << 16) | 146, 8,               62,
        60,              61,              (5 << 16) | 145, 7,
        63,              62,              45,              (5 << 16) | 148,
        5,               64,              45,              45,
        (5 << 16) | 142, 7,               65,              63,
        64,
    });
    defer std.testing.allocator.free(extended);
    extended[3] = 128;
    const new_output_offset = testOpcodeOffset(extended, 62, 0).?;
    extended[new_output_offset + 2] = 65;
    var program = try compile(std.testing.allocator, extended, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    var seen = [_]bool{false} ** @typeInfo(ir.Op).@"enum".fields.len;
    for (program.instructions) |instruction| seen[@intFromEnum(instruction.op)] = true;
    for ([_]ir.Op{ .transpose, .outer_product, .matrix_times_matrix, .matrix_times_vector, .dot, .vector_times_scalar, .output }) |op|
        try std.testing.expect(seen[@intFromEnum(op)]);
}

test "uniform block constant access chain is read only and descriptor identity is semantic" {
    var program = try compile(std.testing.allocator, &uniform_vertex, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), program.interfaces.len);
    try std.testing.expectEqual(ir.Storage.output, program.interfaces[0].storage);
    try std.testing.expectEqual(ir.Storage.uniform, program.interfaces[1].storage);
    try std.testing.expectEqual(@as(?u32, 0), program.interfaces[1].descriptor_set);
    try std.testing.expectEqual(@as(?u32, 2), program.interfaces[1].binding);
    try std.testing.expectEqual(ir.Op.access, program.instructions[1].op);
    try std.testing.expectEqual(ir.Op.extract, program.instructions[2].op);
}

test "profile v1 rejects runtime scalar u32 access chain index" {
    const access_offset = testOpcodeOffset(&uniform_vertex, 65, 0).?;
    const runtime_index = [_]u32{ (5 << 16) | 128, 3, 44, 20, 20 };
    const dynamic = try testInsertWords(std.testing.allocator, &uniform_vertex, access_offset, &runtime_index);
    defer std.testing.allocator.free(dynamic);
    dynamic[testOpcodeOffset(dynamic, 65, 0).? + 4] = 44;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, dynamic, .vertex, "main", &.{}));
}

test "profile admits a runtime vector component in a final access-chain index" {
    const dynamic = try testDynamicVectorAccessVariant(std.testing.allocator);
    defer std.testing.allocator.free(dynamic);
    var program = try compile(std.testing.allocator, dynamic, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), program.interfaces.len);
    var access_seen: usize = 0;
    for (program.instructions) |instruction| if (instruction.op == ir.Op.access) {
        access_seen += 1;
        try std.testing.expectEqual(@as(usize, 3), instruction.operands.len);
        try std.testing.expectEqual(ir.Op.constant, program.instructions[instruction.operands[1]].op);
        try std.testing.expectEqual(ir.Op.input, program.instructions[instruction.operands[2]].op);
    };
    try std.testing.expectEqual(@as(usize, 1), access_seen);
}

test "boolean true and false constants retain exact frontend values" {
    var truth = try compile(std.testing.allocator, &bool_fragment, .fragment, "main", &.{});
    defer truth.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{1}, truth.instructions[0].literal);
    var false_words = bool_fragment;
    var cursor: usize = 5;
    while (cursor < false_words.len) : (cursor += false_words[cursor] >> 16) if (@as(u16, @truncate(false_words[cursor])) == 48) {
        false_words[cursor] = (3 << 16) | 49;
        break;
    };
    var falsity = try compile(std.testing.allocator, &false_words, .fragment, "main", &.{});
    defer falsity.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{0}, falsity.instructions[0].literal);
    const false_specialization = [_]u8{ 0, 0, 0, 0 };
    var specialized = try compile(std.testing.allocator, &bool_fragment, .fragment, "main", &.{.{ .id = 9, .bytes = &false_specialization }});
    defer specialized.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, &.{0}, specialized.instructions[0].literal);
    const invalid_specialization = [_]u8{ 2, 0, 0, 0 };
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &bool_fragment, .fragment, "main", &.{.{ .id = 9, .bytes = &invalid_specialization }}));
}

test "profile distinguishes malformed from unsupported" {
    var malformed = positive_vertex;
    malformed[5] = 0;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &malformed, .vertex, "main", &.{}));
    var unsupported = positive_vertex;
    unsupported[6] = 2;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &unsupported, .vertex, "main", &.{}));
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &positive_vertex, .fragment, "main", &.{}));
    var execution_mode = positive_vertex;
    execution_mode[execution_mode.len - 2] = (1 << 16) | 16;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &execution_mode, .vertex, "main", &.{}));
    const exact_execution_mode = [_]u32{ (3 << 16) | 16, 10, 7 };
    const with_execution_mode = try testInsertWords(std.testing.allocator, &positive_vertex, testOpcodeOffset(&positive_vertex, 19, 0).?, &exact_execution_mode);
    defer std.testing.allocator.free(with_execution_mode);
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, with_execution_mode, .vertex, "main", &.{}));
    var unknown_opcode = positive_vertex;
    unknown_opcode[unknown_opcode.len - 2] = (1 << 16) | 999;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &unknown_opcode, .vertex, "main", &.{}));
}

test "every explicitly excluded instruction family capability type storage and constant is unsupported" {
    const excluded_opcodes = [_]u16{
        45, // OpUndef
        57, // OpFunctionCall
        87, // OpImageSampleImplicitLod
        207, // derivative family
        224, // OpControlBarrier
        227, // atomic family
        246, // OpLoopMerge
        249, // OpBranch
        250, // OpBranchConditional
        251, // OpSwitch
        252, // OpKill
    };
    for (excluded_opcodes) |opcode| {
        var changed = positive_vertex;
        changed[changed.len - 2] = (@as(u32, 1) << 16) | opcode;
        try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    }
    for ([_]u32{ 0, 2, 3, 10, 11, 12, 64 }) |capability| {
        var changed = positive_vertex;
        changed[6] = capability;
        try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    }
    var changed = positive_vertex;
    changed[1] = 0x0001_0100;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    changed = positive_vertex;
    changed[3] = max_profile_bound + 1;
    try std.testing.expectError(error.LimitExceeded, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    changed = positive_vertex;
    changed[testOpcodeOffset(&changed, 71, 0).? + 2] = 0;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    changed = positive_vertex;
    changed[testOpcodeOffset(&changed, 22, 0).? + 2] = 64;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    var rich_changed = rich_vertex;
    rich_changed[testOpcodeOffset(&rich_changed, 21, 0).? + 2] = 16;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_changed, .vertex, "main", &.{}));
    rich_changed = rich_vertex;
    rich_changed[testOpcodeOffset(&rich_changed, 23, 0).? + 3] = 1;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_changed, .vertex, "main", &.{}));
    rich_changed = rich_vertex;
    rich_changed[testOpcodeOffset(&rich_changed, 24, 0).? + 3] = 3;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_changed, .vertex, "main", &.{}));
    changed = positive_vertex;
    changed[testOpcodeOffset(&changed, 32, 0).? + 2] = 9;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    for ([_]u32{ 0x7f80_0000, 0xff80_0000, 0x7fc0_0000 }) |non_finite| {
        changed = positive_vertex;
        changed[testOpcodeOffset(&changed, 43, 0).? + 3] = non_finite;
        try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    }
}

test "operand IDs entry strings and exact arithmetic types classify malformed separately" {
    var changed = positive_vertex;
    changed[testOpcodeOffset(&changed, 62, 0).? + 2] = changed[3];
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    changed = positive_vertex;
    const entry = testOpcodeOffset(&changed, 15, 0).?;
    changed[entry + 3] = 0xffff_ffff;
    changed[entry + 4] = 0xffff_ffff;
    changed[entry + 5] = 0xffff_ffff;
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &changed, .vertex, "main", &.{}));
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &positive_vertex, .vertex, "missing", &.{}));
    var rich_changed = rich_vertex;
    const add = testOpcodeOffset(&rich_changed, 129, 0).?;
    rich_changed[add] = (5 << 16) | 128; // integer opcode with float result and operands
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, &rich_changed, .vertex, "main", &.{}));
    rich_changed = rich_vertex;
    const shuffle = testOpcodeOffset(&rich_changed, 79, 0).?;
    rich_changed[shuffle + 5] = 0xffff_ffff;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_changed, .vertex, "main", &.{}));
}

test "entry selection permits other names but rejects duplicate selected entries" {
    const type_offset = testOpcodeOffset(&positive_vertex, 19, 0).?;
    const alternate_entry = [_]u32{ (4 << 16) | 15, 0, 10, 0x0074_6c61 }; // "alt"
    const alternate_words = try testInsertWords(std.testing.allocator, &positive_vertex, type_offset, &alternate_entry);
    defer std.testing.allocator.free(alternate_words);
    var baseline = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer baseline.deinit(std.testing.allocator);
    var selected = try compile(std.testing.allocator, alternate_words, .vertex, "main", &.{});
    defer selected.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, baseline.bytes, selected.bytes);

    const entry_offset = testOpcodeOffset(&positive_vertex, 15, 0).?;
    const entry_width: usize = positive_vertex[entry_offset] >> 16;
    const duplicated = try testInsertWords(std.testing.allocator, &positive_vertex, type_offset, positive_vertex[entry_offset..][0..entry_width]);
    defer std.testing.allocator.free(duplicated);
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, duplicated, .vertex, "main", &.{}));
}

test "unselected straight-line functions and debug declarations do not enter identity" {
    const dead_function = [_]u32{
        (5 << 16) | 54,  1,  12,              0,              5,
        (2 << 16) | 248, 13, (1 << 16) | 253, (1 << 16) | 56,
    };
    const debug_name = [_]u32{ (4 << 16) | 5, 10, 0x6461_6564, 0 };
    const with_dead_raw = try testInsertWords(std.testing.allocator, &positive_vertex, positive_vertex.len, &dead_function);
    defer std.testing.allocator.free(with_dead_raw);
    with_dead_raw[3] = 14;
    const with_dead = try testInsertWords(std.testing.allocator, with_dead_raw, testOpcodeOffset(with_dead_raw, 19, 0).?, &debug_name);
    defer std.testing.allocator.free(with_dead);
    var baseline = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer baseline.deinit(std.testing.allocator);
    var compiled = try compile(std.testing.allocator, with_dead, .vertex, "main", &.{});
    defer compiled.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, baseline.bytes, compiled.bytes);

    const label = testOpcodeOffset(&positive_vertex, 248, 0).?;
    const with_no_line = try testInsertWords(std.testing.allocator, &positive_vertex, label + 2, &.{(1 << 16) | 317});
    defer std.testing.allocator.free(with_no_line);
    var no_line_program = try compile(std.testing.allocator, with_no_line, .vertex, "main", &.{});
    defer no_line_program.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, baseline.bytes, no_line_program.bytes);
    const malformed_no_line = try testInsertWords(std.testing.allocator, &positive_vertex, label + 2, &.{ (2 << 16) | 317, 0 });
    defer std.testing.allocator.free(malformed_no_line);
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, malformed_no_line, .vertex, "main", &.{}));
}

test "raw SPIR-V ID permutation cannot change canonical bytes or identity" {
    var baseline = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer baseline.deinit(std.testing.allocator);
    var renumbered = try compile(std.testing.allocator, &renumbered_positive_vertex, .vertex, "main", &.{});
    defer renumbered.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, baseline.bytes, renumbered.bytes);
    try std.testing.expect(baseline.identity.eql(renumbered.identity));
}

test "independent constant composite declaration order cannot change canonical bytes" {
    const first_composite = testOpcodeOffset(&rich_vertex, 44, 0).?;
    const reordered = try testSwapAdjacentInstructions(std.testing.allocator, &rich_vertex, first_composite);
    defer std.testing.allocator.free(reordered);
    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    var first = try compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 7, .bytes = &replacement }});
    defer first.deinit(std.testing.allocator);
    var second = try compile(std.testing.allocator, reordered, .vertex, "main", &.{.{ .id = 7, .bytes = &replacement }});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, first.bytes, second.bytes);
    try std.testing.expect(first.identity.eql(second.identity));
}

test "type specialization and semantic helper boundaries are exact" {
    var nodes = [_]Node{.{}} ** 8;
    nodes[1] = .{ .kind = .bool };
    nodes[2] = .{ .kind = .int, .a = 32, .b = 0 };
    nodes[3] = .{ .kind = .int, .a = 32, .b = 1 };
    nodes[4] = .{ .kind = .float, .a = 32 };
    nodes[5] = .{ .kind = .vector, .a = 4, .b = 4 };
    nodes[6] = .{ .kind = .matrix, .a = 5, .b = 4 };
    nodes[7] = .{ .kind = .vector, .a = 4, .b = 2 };
    try std.testing.expectEqual(ir.Scalar.bool, (try resultShape(&nodes, 1)).scalar);
    try std.testing.expectEqual(ir.Scalar.u32, (try resultShape(&nodes, 2)).scalar);
    try std.testing.expectEqual(ir.Scalar.i32, (try resultShape(&nodes, 3)).scalar);
    try std.testing.expectEqual(@as(u3, 4), (try resultShape(&nodes, 5)).columns);
    try std.testing.expectEqual(@as(u3, 4), (try resultShape(&nodes, 6)).rows);
    nodes[2].a = 16;
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 2));
    nodes[4].a = 64;
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 4));
    nodes[5].b = 1;
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 5));
    nodes[5].b = 4;
    nodes[5].a = 7;
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 5));
    nodes[5].a = 4;
    nodes[6].b = 3;
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 6));
    nodes[7] = .{};
    try std.testing.expectError(error.Unsupported, resultShape(&nodes, 7));
    try std.testing.expectError(error.Malformed, resultShape(&nodes, 8));

    try checkSpecializations(&.{.{ .id = 1, .bytes = &.{ 0, 0, 0, 0 } }});
    try std.testing.expectError(error.Unsupported, checkSpecializations(&.{.{ .id = 1, .bytes = &.{0} }}));
    try std.testing.expectError(error.Malformed, checkSpecializations(&.{ .{ .id = 1, .bytes = &.{ 0, 0, 0, 0 } }, .{ .id = 1, .bytes = &.{ 1, 0, 0, 0 } } }));
    var too_many = [_]Specialization{.{ .id = 0, .bytes = &.{ 0, 0, 0, 0 } }} ** (max_specializations + 1);
    try std.testing.expectError(error.LimitExceeded, checkSpecializations(&too_many));
    try std.testing.expectEqual(@as(?usize, null), testOpcodeOffset(&positive_vertex, 999, 0));

    nodes[5] = .{ .kind = .vector, .a = 4, .b = 4 };
    nodes[6] = .{ .kind = .matrix, .a = 5, .b = 4 };
    try std.testing.expectEqual(@as(u32, 4), try indexedType(&nodes, 5, 3));
    try std.testing.expectEqual(@as(u32, 5), try indexedType(&nodes, 6, 2));
    try std.testing.expectError(error.Unsupported, indexedType(&nodes, 5, 4));
    try std.testing.expectError(error.Unsupported, indexedType(&nodes, 6, 4));

    const base = ir.Interface{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 1, .binding = 2, .location = 3 };
    var other = base;
    other.descriptor_set = 2;
    try std.testing.expect(interfaceLess({}, base, other));
    other = base;
    other.binding = 3;
    try std.testing.expect(interfaceLess({}, base, other));
    other = base;
    other.location = 4;
    try std.testing.expect(interfaceLess({}, base, other));
    try std.testing.expect(interfacesUnique(&.{base}));
    try std.testing.expect(!interfacesUnique(&.{ base, base }));
    const location = ir.Interface{ .storage = .input, .ty = .{ .scalar = .f32 }, .location = 3 };
    try std.testing.expect(!interfacesUnique(&.{ location, location }));
    const output = ir.Interface{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 3 };
    try std.testing.expect(interfacesUnique(&.{ location, output }));
}

test "allocation failures never publish a partial frontend program" {
    var fail_index: usize = 0;
    while (fail_index < 128) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var result = compile(failing.allocator(), &positive_vertex, .vertex, "main", &.{}) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        result.deinit(failing.allocator());
        break;
    }
}

test "table driven profile schema is unique and every decoration has exact payload metadata" {
    for (opcode_schema, 0..) |meta, index| {
        try std.testing.expect(meta.operands.min <= meta.operands.max);
        try std.testing.expect(meta.operands.max != std.math.maxInt(u16));
        try std.testing.expectEqual(meta, opcodeMeta(meta.opcode).?);
        for (opcode_schema[0..index]) |prior| try std.testing.expect(meta.opcode != prior.opcode);
    }
    try std.testing.expectEqual(@as(?OpcodeMeta, null), opcodeMeta(998));
    for ([_][]const ValueMeta{ &capability_schema, &type_schema, &storage_schema, &decoration_schema, &execution_mode_schema }) |schema| for (schema, 0..) |meta, index| {
        try std.testing.expect(meta.operands.min <= meta.operands.max);
        try std.testing.expectEqual(meta, valueMeta(schema, meta.value).?);
        for (schema[0..index]) |prior| try std.testing.expect(meta.value != prior.value);
    };
    try std.testing.expectEqual(@as(?ValueMeta, null), valueMeta(&decoration_schema, 999));
    try std.testing.expectEqual(@as(u16, 257), opcodeMeta(5).?.operands.max);
    try std.testing.expectEqual(@as(u16, 258), opcodeMeta(6).?.operands.max);
    try std.testing.expectEqual(max_entry_point_operands, opcodeMeta(15).?.operands.max);

    const name_offset = testOpcodeOffset(&positive_vertex, 19, 0).?;
    const name_max = opcodeMeta(5).?.operands.max;
    const debug_exact = try std.testing.allocator.alloc(u32, @as(usize, name_max) + 1);
    defer std.testing.allocator.free(debug_exact);
    @memset(debug_exact, 0);
    debug_exact[0] = (@as(u32, name_max + 1) << 16) | 5;
    debug_exact[1] = 1;
    const with_exact_debug = try testInsertWords(std.testing.allocator, &positive_vertex, name_offset, debug_exact);
    defer std.testing.allocator.free(with_exact_debug);
    var exact_program = try compile(std.testing.allocator, with_exact_debug, .vertex, "main", &.{});
    defer exact_program.deinit(std.testing.allocator);
    const debug_extra = try std.testing.allocator.alloc(u32, debug_exact.len + 1);
    defer std.testing.allocator.free(debug_extra);
    @memset(debug_extra, 0);
    debug_extra[0] = (@as(u32, name_max + 2) << 16) | 5;
    const with_extra_debug = try testInsertWords(std.testing.allocator, &positive_vertex, name_offset, debug_extra);
    defer std.testing.allocator.free(with_extra_debug);
    try std.testing.expectError(error.Malformed, compile(std.testing.allocator, with_extra_debug, .vertex, "main", &.{}));

    try expectDecorationArity(&positive_vertex, 71, 0, true, .vertex); // BuiltIn
    try expectDecorationArity(&rich_vertex, 71, 2, true, .vertex); // SpecId
    try expectDecorationArity(&rich_vertex, 71, 1, true, .vertex); // Location
    try expectDecorationArity(&uniform_vertex, 71, 1, false, .vertex); // Block
    try expectDecorationArity(&uniform_vertex, 71, 2, true, .vertex); // DescriptorSet
    try expectDecorationArity(&uniform_vertex, 71, 3, true, .vertex); // Binding
    try expectDecorationArity(&uniform_vertex, 72, 0, true, .vertex); // Offset
}

test "uniform block semantic layout is serialized and validates alignment overlap and bounds" {
    const type_offset = testOpcodeOffset(&uniform_vertex, 30, 0).?;
    var two_members = try testInsertWords(std.testing.allocator, &uniform_vertex, type_offset + 3, &.{7});
    defer std.testing.allocator.free(two_members);
    two_members[type_offset] += 1 << 16;
    const first_member_decoration = testOpcodeOffset(two_members, 72, 0).?;
    const second_decoration = [_]u32{ (5 << 16) | 72, 12, 1, 35, 16 };
    const valid = try testInsertWords(std.testing.allocator, two_members, first_member_decoration + 5, &second_decoration);
    defer std.testing.allocator.free(valid);
    var program = try compile(std.testing.allocator, valid, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u8, 2), program.interfaces[1].member_count);
    try std.testing.expect(program.interfaces[1].block);
    try std.testing.expectEqual(ir.Type{ .scalar = .f32, .columns = 4 }, program.interfaces[1].members[1].ty);
    try std.testing.expectEqual(@as(u32, 16), program.interfaces[1].members[1].offset);

    var misaligned = try std.testing.allocator.dupe(u32, valid);
    defer std.testing.allocator.free(misaligned);
    misaligned[testOpcodeOffset(misaligned, 72, 1).? + 4] = 2;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, misaligned, .vertex, "main", &.{}));
    var overlap = try std.testing.allocator.dupe(u32, valid);
    defer std.testing.allocator.free(overlap);
    overlap[testOpcodeOffset(overlap, 72, 1).? + 4] = 0;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, overlap, .vertex, "main", &.{}));
    var out_of_bounds = try std.testing.allocator.dupe(u32, valid);
    defer std.testing.allocator.free(out_of_bounds);
    out_of_bounds[testOpcodeOffset(out_of_bounds, 72, 1).? + 4] = max_uniform_block_bytes;
    try std.testing.expectError(error.LimitExceeded, compile(std.testing.allocator, out_of_bounds, .vertex, "main", &.{}));
}

test "composite specialization payloads are explicitly rejected in profile v1" {
    const composite_offset = testOpcodeOffset(&rich_vertex, 44, 0).?;
    var composite = rich_vertex;
    composite[composite_offset] = (composite[composite_offset] & 0xffff_0000) | 51;
    try std.testing.expect(!opcodeMeta(51).?.supported);
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &composite, .vertex, "main", &.{}));
    const decoration = [_]u32{ (4 << 16) | 71, 26, 1, 99 };
    const decorated = try testInsertWords(std.testing.allocator, &composite, testOpcodeOffset(&composite, 19, 0).?, &decoration);
    defer std.testing.allocator.free(decorated);
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, decorated, .vertex, "main", &.{.{ .id = 99, .bytes = &.{ 1, 2, 3, 4 } }}));
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, decorated, .vertex, "main", &.{.{ .id = 99, .bytes = &.{ 1, 2, 3, 4, 5, 6, 7, 8 } }}));
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 999, .bytes = &.{ 1, 2, 3, 4 } }}));

    const nested_words = [_]u32{ (4 << 16) | 51, 5, 39, 26 };
    var nested = try testInsertWords(std.testing.allocator, &composite, testOpcodeOffset(&composite, 54, 0).?, &nested_words);
    defer std.testing.allocator.free(nested);
    nested[3] = 40;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, nested, .vertex, "main", &.{}));
}

test "specialization uniform matrix and fragment canonical identities are golden" {
    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    const cases = .{
        .{ &rich_vertex, ir.Stage.vertex, &[_]Specialization{.{ .id = 7, .bytes = &replacement }}, @as(usize, 283), @as(usize, 9), @as(usize, 2), [32]u8{ 242, 93, 216, 29, 239, 147, 201, 3, 137, 2, 38, 142, 165, 61, 60, 169, 8, 175, 106, 183, 205, 163, 191, 253, 124, 28, 118, 43, 152, 86, 230, 249 } },
        .{ &uniform_vertex, ir.Stage.vertex, &[_]Specialization{}, @as(usize, 150), @as(usize, 4), @as(usize, 2), [32]u8{ 30, 212, 169, 98, 196, 78, 72, 125, 143, 18, 20, 237, 172, 191, 75, 237, 76, 143, 228, 48, 240, 29, 76, 137, 99, 203, 167, 140, 34, 44, 186, 23 } },
        .{ &bool_fragment, ir.Stage.fragment, &[_]Specialization{}, @as(usize, 85), @as(usize, 2), @as(usize, 1), [32]u8{ 30, 165, 50, 56, 182, 94, 19, 153, 156, 158, 78, 65, 182, 13, 122, 116, 179, 148, 44, 58, 254, 23, 145, 87, 22, 132, 220, 133, 154, 106, 223, 87 } },
    };
    inline for (cases) |case| {
        var program = try compile(std.testing.allocator, case[0], case[1], "main", case[2]);
        defer program.deinit(std.testing.allocator);
        try std.testing.expectEqual(case[3], program.bytes.len);
        try std.testing.expectEqual(case[4], program.instructions.len);
        try std.testing.expectEqual(case[5], program.interfaces.len);
        try std.testing.expectEqual(case[6], program.identity.digest);
    }
}

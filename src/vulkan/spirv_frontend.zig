const std = @import("std");
pub const decode = @import("spirv_decode.zig");
pub const ir = @import("render_ir.zig");

pub const max_profile_bound: u32 = 8192;
pub const max_interfaces: usize = 64;
pub const max_specializations: usize = 64;

pub const Error = error{ Malformed, Unsupported, LimitExceeded, OutOfMemory };

pub const Specialization = struct { id: u32, bytes: []const u8 };

const Kind = enum { none, void, bool, int, float, vector, matrix, pointer, structure, function, constant, variable, function_value, label };
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
        else => error.Unsupported,
    };
}

fn sameShape(a: ir.Type, b: ir.Type) bool {
    return a.scalar == b.scalar and a.columns == b.columns and a.rows == b.rows;
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

fn decorationAllowed(value: u32) bool {
    return value == 1 or value == 2 or value == 11 or value == 30 or value == 33 or value == 34;
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
    var current_function: u32 = 0;
    const instruction_functions = allocator.alloc(u32, module.instructions.len) catch return error.OutOfMemory;
    defer allocator.free(instruction_functions);
    @memset(instruction_functions, 0);

    for (module.instructions, 0..) |instruction, instruction_index| {
        const w = instruction.words;
        instruction_functions[instruction_index] = current_function;
        switch (instruction.opcode) {
            0, 3, 4, 5, 6, 7, 8 => {}, // debug/non-semantic declarations are discarded
            17 => {
                if (w.len != 1) return error.Malformed;
                if (w[0] != 1 or capability) return error.Unsupported;
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
                    else => return error.Unsupported,
                };
                const name = try stringOperand(w[2..]);
                const start = 2 + name.word_count;
                if (start > w.len) return error.Malformed;
                try entries.append(allocator, .{ .stage = stage, .function = w[1], .name = name.value, .interfaces = w[start..] });
            },
            16 => return error.Unsupported, // no execution mode is required by this profile
            71 => {
                if (w.len < 2 or !decorationAllowed(w[1])) return if (w.len < 2) error.Malformed else error.Unsupported;
                const target = try id(nodes, w[0]);
                const value = if (w.len == 3) w[2] else if (w.len == 2) 0 else return error.Malformed;
                switch (w[1]) {
                    1 => if (decorations[target].spec_id == null) {
                        decorations[target].spec_id = value;
                    } else return error.Malformed,
                    2 => if (!decorations[target].block and w.len == 2) {
                        decorations[target].block = true;
                    } else return error.Malformed,
                    11 => if (!decorations[target].builtin_position and value == 0) {
                        decorations[target].builtin_position = true;
                    } else return error.Unsupported,
                    30 => if (decorations[target].location == null) {
                        decorations[target].location = value;
                    } else return error.Malformed,
                    33 => if (decorations[target].binding == null) {
                        decorations[target].binding = value;
                    } else return error.Malformed,
                    34 => if (decorations[target].descriptor_set == null) {
                        decorations[target].descriptor_set = value;
                    } else return error.Malformed,
                    else => unreachable,
                }
            },
            72 => {
                if (w.len != 4 or w[2] != 35) return if (w.len != 4) error.Malformed else error.Unsupported;
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
                if (w.len != 3) return error.Malformed;
                if (w[1] != 1 and w[1] != 2 and w[1] != 3) return error.Unsupported;
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
            44, 51 => {
                if (w.len < 3) return error.Malformed;
                _ = try resultShape(nodes, w[0]);
                try define(nodes, w[1], .{ .kind = .constant, .type_id = w[0], .opcode = instruction.opcode, .words = w[2..] });
            },
            59 => {
                if (w.len != 3) return error.Unsupported;
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
                function_count += 1;
            },
            248 => {
                if (!in_function or label_seen or w.len != 1) return error.Malformed;
                try define(nodes, w[0], .{ .kind = .label });
                label_seen = true;
            },
            253 => {
                if (!in_function or !label_seen or terminated or w.len != 0) return error.Malformed;
                terminated = true;
            },
            56 => {
                if (!in_function or !label_seen or !terminated or w.len != 0) return error.Malformed;
                in_function = false;
                current_function = 0;
            },
            61, 62, 65, 79, 80, 81, 109, 110, 111, 112, 124, 127, 128, 129, 130, 131, 133, 136, 142, 145 => {
                if (!in_function or !label_seen or terminated) return error.Malformed;
                const valid_arity = switch (instruction.opcode) {
                    61 => w.len == 3,
                    62 => w.len == 2,
                    65 => w.len >= 4,
                    79 => w.len >= 5,
                    80 => w.len >= 3,
                    81 => w.len >= 4,
                    109, 110, 111, 112, 124, 127 => w.len == 3,
                    128, 129, 130, 131, 133, 136, 142, 145 => w.len == 4,
                    else => unreachable,
                };
                if (!valid_arity) return error.Malformed;
                if (instruction.opcode != 62)
                    try define(nodes, w[1], .{ .kind = .function_value, .type_id = w[0], .opcode = instruction.opcode, .words = w[2..] });
            },
            else => return error.Unsupported,
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
            44, 51, 80 => {
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
                if (pointer.a != 1 and pointer.a != 2) return error.Unsupported;
            },
            62 => {
                const pointer_value = nodes[try id(nodes, w[0])];
                const pointer = nodes[try id(nodes, pointer_value.type_id)];
                if (pointer.kind != .pointer or pointer.a != 3) return error.Unsupported;
                if (!sameShape(try resultShape(nodes, pointer.b), try valueShape(nodes, w[1]))) return error.Malformed;
            },
            65 => {
                const result_pointer = nodes[try id(nodes, w[0])];
                const base = nodes[try id(nodes, w[2])];
                const base_pointer = nodes[try id(nodes, base.type_id)];
                if (result_pointer.kind != .pointer or base_pointer.kind != .pointer or result_pointer.a != base_pointer.a) return error.Malformed;
                var current_type = base_pointer.b;
                for (w[3..]) |index_id| {
                    const index_node = nodes[try id(nodes, index_id)];
                    const index_shape = try valueShape(nodes, index_id);
                    if (index_node.kind != .constant or !scalarClass(index_shape, .integer) or index_shape.columns != 1 or index_node.words.len != 1) return error.Unsupported;
                    const index = index_node.words[0];
                    current_type = try indexedType(nodes, current_type, index);
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
            109, 110, 111, 112, 124 => {
                const result = try resultShape(nodes, w[0]);
                const source = try valueShape(nodes, w[2]);
                if (result.columns != source.columns or result.rows != source.rows) return error.Malformed;
                const supported = switch (instruction.opcode) {
                    109 => result.scalar == .u32 and source.scalar == .f32,
                    110 => result.scalar == .i32 and source.scalar == .f32,
                    111 => result.scalar == .f32 and source.scalar == .i32,
                    112 => result.scalar == .f32 and source.scalar == .u32,
                    124 => result.scalar != .bool and source.scalar != .bool,
                    else => unreachable,
                };
                if (!supported) return error.Unsupported;
            },
            127 => {
                const result = try resultShape(nodes, w[0]);
                if (!scalarClass(result, .float) or !sameShape(result, try valueShape(nodes, w[2]))) return error.Malformed;
            },
            128, 130, 129, 131, 133, 136 => {
                const result = try resultShape(nodes, w[0]);
                const class: ScalarClass = if (instruction.opcode == 128 or instruction.opcode == 130) .integer else .float;
                if (!scalarClass(result, class) or !sameShape(result, try valueShape(nodes, w[2])) or !sameShape(result, try valueShape(nodes, w[3]))) return error.Malformed;
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
            else => return error.Unsupported,
        };
        var shape: ir.Type = undefined;
        const pointee = nodes[try id(nodes, pointer.b)];
        if (storage == .uniform) {
            if (pointee.kind != .structure or !decorations[try id(nodes, pointer.b)].block) return error.Unsupported;
            shape = .{ .scalar = .u32 }; // structural uniform marker; members are validated below
            var end_offset: u32 = 0;
            for (pointee.words, 0..) |member, member_index| {
                const member_shape = try resultShape(nodes, member);
                const offset = member_offsets[@as(usize, pointer.b) * 16 + member_index] orelse return error.Unsupported;
                if (offset < end_offset) return error.Unsupported;
                end_offset = std.math.add(u32, offset, @as(u32, member_shape.columns) * member_shape.rows * 4) catch return error.LimitExceeded;
            }
            if (decorations[index].binding == null or decorations[index].descriptor_set == null or decorations[index].location != null or decorations[index].builtin_position) return error.Unsupported;
        } else {
            shape = try resultShape(nodes, pointer.b);
            if ((decorations[index].location == null) == !decorations[index].builtin_position or decorations[index].binding != null or decorations[index].descriptor_set != null) return error.Unsupported;
            if (decorations[index].builtin_position and !(storage == .output and requested_stage == .vertex and shape.scalar == .f32 and shape.columns == 4)) return error.Unsupported;
        }
        try interfaces.append(allocator, .{ .storage = storage, .ty = shape, .location = decorations[index].location, .descriptor_set = decorations[index].descriptor_set, .binding = decorations[index].binding, .builtin_position = decorations[index].builtin_position });
    }
    std.mem.sort(ir.Interface, interfaces.items, {}, interfaceLess);
    if (!interfacesUnique(interfaces.items)) return error.Unsupported;

    const needed = allocator.alloc(bool, module.bound) catch return error.OutOfMemory;
    defer allocator.free(needed);
    @memset(needed, false);
    for (module.instructions, instruction_functions) |instruction, instruction_function| {
        if (instruction_function == entry.function and instruction.opcode == 62)
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
                41, 42, 43, 44, 48, 49, 50, 51, 61, 65, 79, 80, 81, 109, 110, 111, 112, 124, 127, 128, 129, 130, 131, 133, 136, 142, 145 => w[1],
                else => null,
            };
            const result = result_id orelse continue;
            if (!needed[try id(nodes, result)]) continue;
            const first_operand: usize = switch (instruction.opcode) {
                41, 42, 43, 48, 49, 50 => continue,
                else => 2,
            };
            const operand_end: usize = switch (instruction.opcode) {
                79 => 4,
                81 => 3,
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
    for (module.instructions, instruction_functions) |instruction, instruction_function| {
        if (instruction_function != 0 and instruction_function != entry.function) continue;
        const w = instruction.words;
        if (instruction.opcode == 62) {
            const target = nodes[try id(nodes, w[0])];
            if (target.kind != .variable or target.a != 3) return error.Unsupported;
            const value = canonical_ids[try id(nodes, w[1])];
            if (value == std.math.maxInt(u32)) return error.Malformed;
            var semantic_index: ?u32 = null;
            const decoration = decorations[try id(nodes, w[0])];
            for (interfaces.items, 0..) |item, interface_index| {
                if (item.storage == .output and item.location == decoration.location and item.builtin_position == decoration.builtin_position)
                    semantic_index = @intCast(interface_index);
            }
            const target_index = semantic_index orelse return error.Unsupported;
            const pointer = nodes[try id(nodes, target.type_id)];
            const output_shape = try resultShape(nodes, pointer.b);
            lowered.ensureUnusedCapacity(allocator, 1) catch return error.OutOfMemory;
            const operands = allocator.dupe(u32, &.{ target_index, value }) catch return error.OutOfMemory;
            const literal = allocator.dupe(u8, &.{}) catch return error.OutOfMemory;
            lowered.appendAssumeCapacity(.{ .op = .output, .ty = output_shape, .operands = operands, .literal = literal });
            continue;
        }
        const result_id: ?u32 = switch (instruction.opcode) {
            41, 42, 43, 44, 48, 49, 50, 51, 61, 65, 79, 80, 81, 109, 110, 111, 112, 124, 127, 128, 129, 130, 131, 133, 136, 142, 145 => w[1],
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
            41, 42, 43, 48, 49, 50 => .constant,
            44, 51, 80 => .composite,
            61 => .input,
            65 => .access,
            79 => .shuffle,
            81 => .extract,
            109, 110, 111, 112, 124 => .convert,
            127 => .fneg,
            128 => .iadd,
            129 => .fadd,
            130 => .isub,
            131 => .fsub,
            133 => .fmul,
            136 => .fdiv,
            142 => .vector_times_scalar,
            145 => .matrix_times_vector,
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
                        for (interfaces.items, 0..) |item, interface_index| {
                            if (item.storage == (if (pointer_node.a == 2) ir.Storage.uniform else ir.Storage.input) and item.location == decoration.location and item.binding == decoration.binding and item.descriptor_set == decoration.descriptor_set)
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
                op = if (pointer_node.kind == .variable) (if (pointer_node.a == 2) .uniform else .input) else .extract;
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

const uniform_vertex = [_]u32{
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

test "profile compiles selected straight-line vertex to owned canonical IR" {
    var program = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    try std.testing.expectEqual(ir.Stage.vertex, program.stage);
    try std.testing.expectEqual(@as(usize, 1), program.interfaces.len);
    try std.testing.expect(program.interfaces[0].builtin_position);
    try std.testing.expectEqual(ir.Op.output, program.instructions[2].op);
    try std.testing.expectEqualSlices(u8, "ZPUIR3D\x00", program.bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{
        90, 80, 85, 73, 82, 51, 68, 0, 1,   0,   0,   0,   1,   0,   0,   0,   0,   4,   0,   0,   0, 109, 97, 105, 110,
        1,  0,  0,  0,  1,  3,  4,  1, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 1, 3,   0,  0,   0,
        0,  3,  1,  1,  0,  0,  0,  0, 4,   0,   0,   0,   0,   0,   128, 63,  4,   3,   4,   1,   4, 0,   0,  0,   0,
        0,  0,  0,  0,  0,  0,  0,  0, 0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   0,   17,  3, 4,   1,  2,   0,
        0,  0,  0,  0,  0,  0,  1,  0, 0,   0,   0,   0,   0,   0,
    }, program.bytes);
    try std.testing.expectEqualSlices(u8, &.{
        66,  179, 83,  120, 78,  31, 204, 247, 58,  24,  77,  166, 247, 37,  177, 70,
        152, 91,  153, 222, 240, 21, 193, 235, 145, 133, 246, 107, 23,  114, 182, 127,
    }, &program.identity.digest);
    var clone = try program.clone(std.testing.allocator);
    defer clone.deinit(std.testing.allocator);
    try std.testing.expect(program.identity.eql(clone.identity));
}

test "rich profile fixture removes dead arithmetic without changing live matrix data flow" {
    const replacement = [_]u8{ 0, 0, 0x80, 0x40 };
    var program = try compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 7, .bytes = &replacement }});
    defer program.deinit(std.testing.allocator);
    var seen = [_]bool{false} ** @typeInfo(ir.Op).@"enum".fields.len;
    for (program.instructions) |instruction| seen[@intFromEnum(instruction.op)] = true;
    for ([_]ir.Op{ .constant, .composite, .matrix_times_vector, .output }) |op|
        try std.testing.expect(seen[@intFromEnum(op)]);
    try std.testing.expect(!seen[@intFromEnum(ir.Op.fadd)]);
    try std.testing.expect(std.mem.indexOf(u8, program.bytes, &replacement) != null);
    const non_finite = [_]u8{ 0, 0, 0x80, 0x7f };
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &rich_vertex, .vertex, "main", &.{.{ .id = 7, .bytes = &non_finite }}));
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
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &execution_mode, .vertex, "main", &.{}));
    var unknown_opcode = positive_vertex;
    unknown_opcode[unknown_opcode.len - 2] = (1 << 16) | 999;
    try std.testing.expectError(error.Unsupported, compile(std.testing.allocator, &unknown_opcode, .vertex, "main", &.{}));
}

test "every explicitly excluded instruction family capability type storage and constant is unsupported" {
    const excluded_opcodes = [_]u16{
        12, // OpExtInst
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
}

test "raw SPIR-V ID permutation cannot change canonical bytes or identity" {
    var baseline = try compile(std.testing.allocator, &positive_vertex, .vertex, "main", &.{});
    defer baseline.deinit(std.testing.allocator);
    var renumbered = try compile(std.testing.allocator, &renumbered_positive_vertex, .vertex, "main", &.{});
    defer renumbered.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, baseline.bytes, renumbered.bytes);
    try std.testing.expect(baseline.identity.eql(renumbered.identity));
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

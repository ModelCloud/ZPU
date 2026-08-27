const std = @import("std");

pub const profile_version: u32 = 1;
pub const serialization_version: u32 = 2;
pub const max_values: usize = 4096;
pub const max_instructions: usize = 4096;

pub const Stage = enum(u8) { vertex = 0, fragment = 1, compute = 2 };
pub const Scalar = enum(u8) { bool = 0, i32 = 1, u32 = 2, f32 = 3 };
pub const Type = packed struct { scalar: Scalar, columns: u3 = 1, rows: u3 = 1, _pad: u6 = 0 };
pub const Op = enum(u8) {
    constant,
    constant_composite,
    input,
    uniform,
    access,
    composite,
    extract,
    shuffle,
    fneg,
    iadd,
    isub,
    fadd,
    fsub,
    fmul,
    fdiv,
    vector_times_scalar,
    matrix_times_vector,
    convert,
    output,
    select,
    storage,
    /// Component-wise two's-complement integer multiplication. Appended to
    /// preserve the serialized numeric values of existing operations.
    imul,
    /// Component-wise two's-complement signed integer negation. Appended to
    /// preserve the serialized numeric values of existing operations.
    ineg,
    /// Component-wise integer bitwise OR. Appended to preserve existing
    /// serialized operation values.
    bit_or,
    /// Component-wise integer bitwise XOR. Appended to preserve existing
    /// serialized operation values.
    bit_xor,
    /// Component-wise integer bitwise AND. Appended to preserve existing
    /// serialized operation values.
    bit_and,
    /// Component-wise integer bitwise NOT. Appended to preserve existing
    /// serialized operation values.
    bit_not,
    /// Component-wise unsigned integer division.
    udiv,
    /// Component-wise signed integer division.
    sdiv,
    /// Component-wise unsigned integer remainder.
    umod,
    /// Component-wise signed integer remainder with dividend sign.
    srem,
    /// Component-wise signed modulo with divisor sign.
    smod,
    /// Component-wise logical left shift.
    shl_logical,
    /// Component-wise logical right shift.
    shr_logical,
    /// Component-wise arithmetic right shift.
    shr_arithmetic,
    /// Scalar integer equality comparison producing a boolean.
    ieq,
    /// Scalar integer inequality comparison producing a boolean.
    ine,
    /// Scalar unsigned greater-than comparison producing a boolean.
    ugt,
    /// Scalar unsigned greater-than-or-equal comparison producing a boolean.
    uge,
    /// Scalar unsigned less-than comparison producing a boolean.
    ult,
    /// Scalar unsigned less-than-or-equal comparison producing a boolean.
    ule,
    /// Scalar signed greater-than comparison producing a boolean.
    sgt,
    /// Scalar signed greater-than-or-equal comparison producing a boolean.
    sge,
    /// Scalar signed less-than comparison producing a boolean.
    slt,
    /// Scalar signed less-than-or-equal comparison producing a boolean.
    sle,
    /// Ordered floating-point equality comparison producing a boolean.
    ford_eq,
    /// Unordered floating-point equality comparison producing a boolean.
    funord_eq,
    /// Ordered floating-point inequality comparison producing a boolean.
    ford_ne,
    /// Unordered floating-point inequality comparison producing a boolean.
    funord_ne,
    /// Ordered floating-point less-than comparison producing a boolean.
    ford_lt,
    /// Unordered floating-point less-than comparison producing a boolean.
    funord_lt,
    /// Ordered floating-point greater-than comparison producing a boolean.
    ford_gt,
    /// Unordered floating-point greater-than comparison producing a boolean.
    funord_gt,
    /// Ordered floating-point less-than-or-equal comparison producing a boolean.
    ford_le,
    /// Unordered floating-point less-than-or-equal comparison producing a boolean.
    funord_le,
    /// Ordered floating-point greater-than-or-equal comparison producing a boolean.
    ford_ge,
    /// Unordered floating-point greater-than-or-equal comparison producing a boolean.
    funord_ge,
    /// Scalar boolean equality operation.
    logical_eq,
    /// Scalar boolean inequality operation.
    logical_ne,
    /// Scalar boolean OR operation.
    logical_or,
    /// Scalar boolean AND operation.
    logical_and,
    /// Scalar boolean NOT operation.
    logical_not,
    /// Component-wise floating-point remainder with truncating quotient.
    frem,
    /// Column-major 4x4 matrix multiplied by a scalar.
    matrix_times_scalar,
    /// Row-vector f32x4 multiplied by a column-major 4x4 matrix.
    vector_times_matrix,
    /// Column-major 4x4 matrix multiplied by a column-major 4x4 matrix.
    matrix_times_matrix,
    /// Transpose of a column-major 4x4 matrix.
    transpose,
    /// Outer product of two f32x4 vectors, producing a column-major 4x4 matrix.
    outer_product,
    /// Dot product of equal-length f32 vectors, producing a scalar.
    dot,
    /// Reduction of a bool vector to whether any lane is true.
    any,
    /// Reduction of a bool vector to whether all lanes are true.
    all,
    /// Per-lane floating-point NaN classification.
    is_nan,
    /// Per-lane floating-point infinity classification.
    is_inf,
    /// Per-lane floating-point finite classification.
    is_finite,
    /// Per-lane floating-point normal-number classification.
    is_normal,
    /// Per-lane floating-point sign-bit classification.
    sign_bit_set,
    /// Per-lane ordered less-than-or-greater-than comparison.
    less_or_greater,
    /// Per-lane ordered classification for two floating-point values.
    ordered,
    /// Per-lane unordered classification for two floating-point values.
    unordered,
    /// Component-wise floating-point modulo with floor quotient.
    fmod,
    /// Component-wise integer bit reversal.
    bit_reverse,
    /// Component-wise integer population count.
    bit_count,
    /// Component-wise integer bit-field insertion.
    bit_field_insert,
    /// Component-wise signed integer bit-field extraction.
    bit_field_s_extract,
    /// Component-wise unsigned integer bit-field extraction.
    bit_field_u_extract,
    /// Dynamic extraction of one component from a vector.
    vector_extract_dynamic,
    /// Dynamic replacement of one component in a vector.
    vector_insert_dynamic,
    /// Static replacement of one component in a vector composite.
    composite_insert,
    /// Bit-preserving reinterpretation between numeric scalar types.
    /// Appended to preserve the serialized numeric values of existing operations.
    bitcast,
    /// Type-preserving value copy corresponding to SPIR-V OpCopyObject.
    /// Appended to preserve the serialized numeric values of existing operations.
    copy_object,
    /// Round an f32 value to f16 precision while retaining an f32 result.
    quantize_f16,
    /// Unsigned scalar addition returning low bits and carry as a two-lane
    /// value (bounded representation of SPIR-V OpIAddCarry).
    iadd_carry,
    /// Unsigned scalar subtraction returning low bits and borrow as a
    /// two-lane value (bounded representation of SPIR-V OpISubBorrow).
    isub_borrow,
    /// Unsigned scalar multiplication returning low and high words as a
    /// two-lane value (bounded representation of SPIR-V OpUMulExtended).
    umul_extended,
    /// Signed scalar multiplication returning low and high words as a
    /// two-lane value (bounded representation of SPIR-V OpSMulExtended).
    smul_extended,
    /// Component-wise floating-point absolute value from GLSL.std.450.
    f_abs,
    /// Component-wise signed integer absolute value from GLSL.std.450.
    i_abs,
    /// Component-wise floating-point minimum from GLSL.std.450.
    f_min,
    /// Component-wise floating-point maximum from GLSL.std.450.
    f_max,
    /// Component-wise floating-point sign from GLSL.std.450.
    f_sign,
    /// Component-wise signed integer sign from GLSL.std.450.
    i_sign,
    /// Component-wise unsigned integer minimum from GLSL.std.450.
    u_min,
    /// Component-wise signed integer minimum from GLSL.std.450.
    i_min,
    /// Component-wise unsigned integer maximum from GLSL.std.450.
    u_max,
    /// Component-wise signed integer maximum from GLSL.std.450.
    i_max,
    /// Component-wise floating-point clamp from GLSL.std.450.
    f_clamp,
    /// Component-wise unsigned integer clamp from GLSL.std.450.
    u_clamp,
    /// Component-wise signed integer clamp from GLSL.std.450.
    i_clamp,
    /// Component-wise floating-point linear interpolation from GLSL.std.450.
    f_mix,
    /// Component-wise floating-point fused multiply-add from GLSL.std.450.
    fma,
    /// Component-wise floating-point step function from GLSL.std.450.
    f_step,
    /// Component-wise floating-point smooth step from GLSL.std.450.
    f_smooth_step,
    /// Component-wise floating-point round-to-nearest from GLSL.std.450.
    f_round,
    /// Component-wise floating-point round-to-nearest-even from GLSL.std.450.
    f_round_even,
    /// Component-wise floating-point truncation from GLSL.std.450.
    f_trunc,
    /// Component-wise floating-point floor from GLSL.std.450.
    f_floor,
    /// Component-wise floating-point ceiling from GLSL.std.450.
    f_ceil,
    /// Component-wise floating-point fractional part from GLSL.std.450.
    f_fract,
    /// Component-wise degrees-to-radians conversion from GLSL.std.450.
    f_radians,
    /// Component-wise radians-to-degrees conversion from GLSL.std.450.
    f_degrees,
    /// Component-wise sine from GLSL.std.450.
    f_sin,
    /// Component-wise cosine from GLSL.std.450.
    f_cos,
    /// Component-wise tangent from GLSL.std.450.
    f_tan,
    /// Component-wise inverse sine from GLSL.std.450.
    f_asin,
    /// Component-wise inverse cosine from GLSL.std.450.
    f_acos,
    /// Component-wise inverse tangent from GLSL.std.450.
    f_atan,
    /// Component-wise hyperbolic sine from GLSL.std.450.
    f_sinh,
    /// Component-wise hyperbolic cosine from GLSL.std.450.
    f_cosh,
    /// Component-wise hyperbolic tangent from GLSL.std.450.
    f_tanh,
    /// Component-wise inverse hyperbolic sine from GLSL.std.450.
    f_asinh,
    /// Component-wise inverse hyperbolic cosine from GLSL.std.450.
    f_acosh,
    /// Component-wise inverse hyperbolic tangent from GLSL.std.450.
    f_atanh,
    /// Component-wise base-e exponentiation from GLSL.std.450.
    f_exp,
    /// Component-wise natural logarithm from GLSL.std.450.
    f_log,
    /// Component-wise base-two exponentiation from GLSL.std.450.
    f_exp2,
    /// Component-wise base-two logarithm from GLSL.std.450.
    f_log2,
    /// Component-wise square root from GLSL.std.450.
    f_sqrt,
    /// Component-wise reciprocal square root from GLSL.std.450.
    f_inverse_sqrt,
    /// Component-wise two-argument arc tangent from GLSL.std.450.
    f_atan2,
    /// Component-wise floating-point power from GLSL.std.450.
    f_pow,
    /// Determinant of a column-major 4x4 f32 matrix from GLSL.std.450.
    f_determinant,
    /// Inverse of a column-major 4x4 f32 matrix from GLSL.std.450.
    f_matrix_inverse,
    /// Length of an f32 vector from GLSL.std.450.
    f_length,
    /// Euclidean distance between f32 vectors from GLSL.std.450.
    f_distance,
    /// Cross product of f32 3-vectors from GLSL.std.450.
    f_cross,
    /// Normalized f32 vector from GLSL.std.450.
    f_normalize,
    /// Face-forward orientation of an f32 vector from GLSL.std.450.
    f_face_forward,
    /// Reflection of an f32 incident vector from GLSL.std.450.
    f_reflect,
    /// Refraction of an f32 incident vector from GLSL.std.450.
    f_refract,
    /// Index of the least-significant set bit from GLSL.std.450.
    i_find_lsb,
    /// Index of the most-significant bit differing from the sign from GLSL.std.450.
    i_find_s_msb,
    /// Index of the most-significant set bit from GLSL.std.450.
    i_find_u_msb,
    /// Builds an f32 value from a value and a signed power-of-two exponent
    /// from GLSL.std.450 Ldexp.
    f_ldexp,
    /// Component-wise floating-point minimum that prefers non-NaN operands.
    f_n_min,
    /// Component-wise floating-point maximum that prefers non-NaN operands.
    f_n_max,
    /// Component-wise non-NaN-preferred floating-point clamp.
    f_n_clamp,
    /// Pack four normalized signed f32 lanes into one 32-bit word.
    i_pack_snorm4x8,
    /// Pack four normalized unsigned f32 lanes into one 32-bit word.
    i_pack_unorm4x8,
    /// Pack two normalized signed f32 lanes into one 32-bit word.
    i_pack_snorm2x16,
    /// Pack two normalized unsigned f32 lanes into one 32-bit word.
    i_pack_unorm2x16,
    /// Unpack two normalized signed 16-bit lanes into f32 values.
    f_unpack_snorm2x16,
    /// Unpack two normalized unsigned 16-bit lanes into f32 values.
    f_unpack_unorm2x16,
    /// Unpack four normalized signed 8-bit lanes into f32 values.
    f_unpack_snorm4x8,
    /// Unpack four normalized unsigned 8-bit lanes into f32 values.
    f_unpack_unorm4x8,
};

pub const Instruction = struct {
    op: Op,
    ty: Type,
    operands: []const u32,
    literal: []const u8,
};

pub const Storage = enum(u8) { input, output, uniform };
pub const max_uniform_members: usize = 16;
pub const UniformMember = struct { ty: Type = .{ .scalar = .u32 }, offset: u32 = 0 };
pub const Interface = struct {
    storage: Storage,
    ty: Type,
    location: ?u32 = null,
    descriptor_set: ?u32 = null,
    binding: ?u32 = null,
    builtin_position: bool = false,
    block: bool = false,
    member_count: u8 = 0,
    members: [max_uniform_members]UniformMember = .{UniformMember{}} ** max_uniform_members,
};

pub const Identity = struct {
    digest: [32]u8,
    bytes: []const u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return std.mem.eql(u8, &a.digest, &b.digest) and std.mem.eql(u8, a.bytes, b.bytes);
    }
};

pub const Program = struct {
    stage: Stage,
    entry_name: []u8,
    interfaces: []Interface,
    instructions: []Instruction,
    bytes: []u8,
    identity: Identity,

    pub fn deinit(self: *Program, allocator: std.mem.Allocator) void {
        for (self.instructions) |instruction| {
            allocator.free(instruction.operands);
            allocator.free(instruction.literal);
        }
        allocator.free(self.instructions);
        allocator.free(self.interfaces);
        allocator.free(self.entry_name);
        allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn clone(self: *const Program, allocator: std.mem.Allocator) !Program {
        var result = Program{
            .stage = self.stage,
            .entry_name = try allocator.dupe(u8, self.entry_name),
            .interfaces = undefined,
            .instructions = undefined,
            .bytes = undefined,
            .identity = undefined,
        };
        errdefer allocator.free(result.entry_name);
        result.interfaces = try allocator.dupe(Interface, self.interfaces);
        errdefer allocator.free(result.interfaces);
        result.instructions = try allocator.alloc(Instruction, self.instructions.len);
        var made: usize = 0;
        errdefer {
            for (result.instructions[0..made]) |item| {
                allocator.free(item.operands);
                allocator.free(item.literal);
            }
            allocator.free(result.instructions);
        }
        for (self.instructions, 0..) |item, i| {
            result.instructions[i] = .{ .op = item.op, .ty = item.ty, .operands = try allocator.dupe(u32, item.operands), .literal = &.{} };
            result.instructions[i].literal = allocator.dupe(u8, item.literal) catch |err| {
                allocator.free(result.instructions[i].operands);
                return err;
            };
            made += 1;
        }
        result.bytes = try allocator.dupe(u8, self.bytes);
        result.identity = .{ .digest = self.identity.digest, .bytes = result.bytes };
        return result;
    }
};

fn putU32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try list.appendSlice(allocator, &bytes);
}

/// Canonical serialization contains no SPIR-V IDs. Values are numbered by
/// instruction order after lowering and declarations are sorted semantically.
pub fn serialize(allocator: std.mem.Allocator, stage: Stage, entry_name: []const u8, interfaces: []const Interface, instructions: []const Instruction) ![]u8 {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(allocator);
    try list.appendSlice(allocator, "ZPUIR3D\x00");
    try putU32(&list, allocator, profile_version);
    try putU32(&list, allocator, serialization_version);
    try list.append(allocator, @intFromEnum(stage));
    try putU32(&list, allocator, @intCast(entry_name.len));
    try list.appendSlice(allocator, entry_name);
    try putU32(&list, allocator, @intCast(interfaces.len));
    for (interfaces) |item| {
        try list.append(allocator, @intFromEnum(item.storage));
        try list.append(allocator, @intFromEnum(item.ty.scalar));
        try list.append(allocator, item.ty.columns);
        try list.append(allocator, item.ty.rows);
        try putU32(&list, allocator, item.location orelse std.math.maxInt(u32));
        try putU32(&list, allocator, item.descriptor_set orelse std.math.maxInt(u32));
        try putU32(&list, allocator, item.binding orelse std.math.maxInt(u32));
        try list.append(allocator, @intFromBool(item.builtin_position));
        try list.append(allocator, @intFromBool(item.block));
        try list.append(allocator, item.member_count);
        for (item.members[0..item.member_count]) |member| {
            try list.append(allocator, @intFromEnum(member.ty.scalar));
            try list.append(allocator, member.ty.columns);
            try list.append(allocator, member.ty.rows);
            try putU32(&list, allocator, member.offset);
        }
    }
    try putU32(&list, allocator, @intCast(instructions.len));
    for (instructions) |item| {
        try list.append(allocator, @intFromEnum(item.op));
        try list.append(allocator, @intFromEnum(item.ty.scalar));
        try list.append(allocator, item.ty.columns);
        try list.append(allocator, item.ty.rows);
        try putU32(&list, allocator, @intCast(item.operands.len));
        for (item.operands) |operand| try putU32(&list, allocator, operand);
        try putU32(&list, allocator, @intCast(item.literal.len));
        try list.appendSlice(allocator, item.literal);
    }
    return try list.toOwnedSlice(allocator);
}

pub fn identify(bytes: []const u8) Identity {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return .{ .digest = digest, .bytes = bytes };
}

fn valueOperand(op: Op, operand_index: usize) bool {
    return switch (op) {
        .constant, .input, .uniform, .storage => false,
        .constant_composite => true,
        .access => operand_index != 0,
        .composite => true,
        .extract => operand_index == 0,
        .shuffle => operand_index < 2,
        .fneg, .ineg, .f_abs, .i_abs, .f_sign, .i_sign, .bit_not, .convert, .bitcast, .copy_object, .quantize_f16 => operand_index == 0,
        .select => operand_index < 3,
        .u_min, .i_min, .u_max, .i_max => operand_index < 2,
        .f_clamp, .u_clamp, .i_clamp, .f_n_clamp => operand_index < 3,
        .f_mix, .fma => operand_index < 3,
        .f_step => operand_index < 2,
        .f_smooth_step => operand_index < 3,
        .f_round, .f_round_even, .f_trunc => operand_index == 0,
        .f_floor, .f_ceil, .f_fract => operand_index == 0,
        .f_radians, .f_degrees, .f_sin, .f_cos, .f_tan, .f_asin, .f_acos, .f_atan, .f_sinh, .f_cosh, .f_tanh, .f_asinh, .f_acosh, .f_atanh, .f_exp, .f_log, .f_exp2, .f_log2, .f_sqrt, .f_inverse_sqrt, .f_determinant, .f_matrix_inverse, .f_length, .f_normalize => operand_index == 0,
        .f_atan2, .f_pow, .f_ldexp, .f_n_min, .f_n_max => operand_index < 2,
        .f_distance, .f_cross, .f_reflect => operand_index < 2,
        .f_face_forward, .f_refract => operand_index < 3,
        .i_find_lsb, .i_find_s_msb, .i_find_u_msb => operand_index == 0,
        .i_pack_snorm4x8, .i_pack_unorm4x8, .i_pack_snorm2x16, .i_pack_unorm2x16, .f_unpack_snorm2x16, .f_unpack_unorm2x16, .f_unpack_snorm4x8, .f_unpack_unorm4x8 => operand_index == 0,
        .iadd, .isub, .imul, .iadd_carry, .isub_borrow, .umul_extended, .smul_extended, .bit_or, .bit_xor, .bit_and, .udiv, .sdiv, .umod, .srem, .smod, .shl_logical, .shr_logical, .shr_arithmetic, .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle, .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge, .logical_eq, .logical_ne, .logical_or, .logical_and, .fadd, .fsub, .fmul, .fdiv, .frem, .fmod, .f_min, .f_max, .vector_times_scalar, .matrix_times_vector, .matrix_times_scalar, .vector_times_matrix, .matrix_times_matrix, .outer_product, .dot, .less_or_greater, .ordered, .unordered => operand_index < 2,
        .transpose, .any, .all, .is_nan, .is_inf, .is_finite, .is_normal, .sign_bit_set, .bit_reverse, .bit_count => operand_index == 0,
        .bit_field_insert => operand_index < 4,
        .bit_field_s_extract, .bit_field_u_extract => operand_index < 3,
        .vector_extract_dynamic => operand_index < 2,
        .vector_insert_dynamic => operand_index < 3,
        .composite_insert => operand_index < 2,
        .logical_not => operand_index == 0,
        .output => operand_index == 1,
    };
}

const DeclarationContext = struct { items: []const Instruction, remap: []const u32 };
fn declarationLess(context: DeclarationContext, a: u32, b: u32) bool {
    const left = context.items[a];
    const right = context.items[b];
    if (left.op != right.op) return @intFromEnum(left.op) < @intFromEnum(right.op);
    if (left.ty.scalar != right.ty.scalar) return @intFromEnum(left.ty.scalar) < @intFromEnum(right.ty.scalar);
    if (left.ty.columns != right.ty.columns) return left.ty.columns < right.ty.columns;
    if (left.ty.rows != right.ty.rows) return left.ty.rows < right.ty.rows;
    const literal_order = std.mem.order(u8, left.literal, right.literal);
    if (literal_order != .eq) return literal_order == .lt;
    const common = @min(left.operands.len, right.operands.len);
    for (0..common) |index| {
        const l = if (valueOperand(left.op, index)) context.remap[left.operands[index]] else left.operands[index];
        const r = if (valueOperand(right.op, index)) context.remap[right.operands[index]] else right.operands[index];
        if (l != r) return l < r;
    }
    return left.operands.len < right.operands.len;
}

fn declaration(op: Op) bool {
    return op == .constant or op == .constant_composite;
}

/// Deterministically renumbers scalar constants by semantic bytes, then
/// remaps every SSA use. It is intentionally conservative: operation order is
/// otherwise preserved, so no floating-point reassociation can occur.
pub fn canonicalize(allocator: std.mem.Allocator, source: []const Instruction) ![]Instruction {
    if (source.len > max_instructions) return error.LimitExceeded;
    const order = try allocator.alloc(u32, source.len);
    defer allocator.free(order);
    const remap = try allocator.alloc(u32, source.len);
    defer allocator.free(remap);
    @memset(remap, std.math.maxInt(u32));
    const pending = try allocator.alloc(bool, source.len);
    defer allocator.free(pending);
    var declaration_count: usize = 0;
    for (source, 0..) |instruction, index| {
        pending[index] = declaration(instruction.op);
        declaration_count += @intFromBool(pending[index]);
    }
    var produced: usize = 0;
    while (produced < declaration_count) {
        var candidates: std.ArrayList(u32) = .empty;
        defer candidates.deinit(allocator);
        for (source, pending, 0..) |instruction, is_pending, index| if (is_pending) {
            var ready = true;
            for (instruction.operands, 0..) |operand, operand_index| if (valueOperand(instruction.op, operand_index)) {
                if (operand >= source.len) return error.InvalidDependency;
                if (remap[operand] == std.math.maxInt(u32)) {
                    ready = false;
                    break;
                }
            };
            if (ready) {
                try candidates.append(allocator, @intCast(index));
            }
        };
        if (candidates.items.len == 0) return error.InvalidDependency;
        // Declaration inputs are already in source-topological order. Sort each
        // ready frontier by semantic data after dependency remapping.
        std.mem.sort(u32, candidates.items, DeclarationContext{ .items = source, .remap = remap }, declarationLess);
        for (candidates.items) |candidate| {
            order[produced] = candidate;
            remap[candidate] = @intCast(produced);
            pending[candidate] = false;
            produced += 1;
        }
    }
    for (source, 0..) |instruction, index| if (!declaration(instruction.op)) {
        order[produced] = @intCast(index);
        remap[index] = @intCast(produced);
        produced += 1;
    };
    const result = try allocator.alloc(Instruction, source.len);
    var made: usize = 0;
    errdefer {
        for (result[0..made]) |item| {
            allocator.free(item.operands);
            allocator.free(item.literal);
        }
        allocator.free(result);
    }
    for (order, 0..) |old, new| {
        const item = source[old];
        const operands = try allocator.dupe(u32, item.operands);
        errdefer allocator.free(operands);
        for (operands, 0..) |*operand, operand_index| {
            if (valueOperand(item.op, operand_index)) {
                if (operand.* >= source.len or remap[operand.*] == std.math.maxInt(u32)) return error.InvalidDependency;
                operand.* = remap[operand.*];
            }
        }
        const literal = try allocator.dupe(u8, item.literal);
        result[new] = .{ .op = item.op, .ty = item.ty, .operands = operands, .literal = literal };
        made += 1;
    }
    return result;
}

test "serialization is exact little endian and identity checks full bytes" {
    var interfaces = [_]Interface{.{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 2, .block = true, .member_count = 1 }};
    interfaces[0].members[0] = .{ .ty = .{ .scalar = .f32, .columns = 4 }, .offset = 16 };
    const instructions = [_]Instruction{.{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &.{ 4, 3, 2, 1 } }};
    const bytes = try serialize(std.testing.allocator, .fragment, "main", &interfaces, &instructions);
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualSlices(u8, "ZPUIR3D\x00\x01\x00\x00\x00\x02\x00\x00\x00\x01\x04\x00\x00\x00main", bytes[0..25]);
    const first = identify(bytes);
    var changed = try std.testing.allocator.dupe(u8, bytes);
    defer std.testing.allocator.free(changed);
    changed[changed.len - 1] ^= 1;
    try std.testing.expect(!first.eql(identify(changed)));
    var collision = identify(changed);
    collision.digest = first.digest;
    try std.testing.expect(!first.eql(collision));

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    try std.testing.expectError(error.OutOfMemory, serialize(failing.allocator(), .vertex, "entry", &interfaces, &instructions));
}

test "canonicalization is idempotent and scalar declaration order invariant" {
    const first_source = [_]Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &.{ 0, 0, 0, 0x40 } },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &.{ 0, 0, 0x80, 0x3f } },
        .{ .op = .fsub, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
    };
    const second_source = [_]Instruction{
        first_source[1],                                                                      first_source[0],
        .{ .op = .fsub, .ty = .{ .scalar = .f32 }, .operands = &.{ 1, 0 }, .literal = &.{} },
    };
    const first = try canonicalize(std.testing.allocator, &first_source);
    defer {
        for (first) |item| {
            std.testing.allocator.free(item.operands);
            std.testing.allocator.free(item.literal);
        }
        std.testing.allocator.free(first);
    }
    const second = try canonicalize(std.testing.allocator, &second_source);
    defer {
        for (second) |item| {
            std.testing.allocator.free(item.operands);
            std.testing.allocator.free(item.literal);
        }
        std.testing.allocator.free(second);
    }
    const again = try canonicalize(std.testing.allocator, first);
    defer {
        for (again) |item| {
            std.testing.allocator.free(item.operands);
            std.testing.allocator.free(item.literal);
        }
        std.testing.allocator.free(again);
    }
    const a = try serialize(std.testing.allocator, .vertex, "main", &.{}, first);
    defer std.testing.allocator.free(a);
    const b = try serialize(std.testing.allocator, .vertex, "main", &.{}, second);
    defer std.testing.allocator.free(b);
    const c = try serialize(std.testing.allocator, .vertex, "main", &.{}, again);
    defer std.testing.allocator.free(c);
    try std.testing.expectEqualSlices(u8, a, b);
    try std.testing.expectEqualSlices(u8, a, c);

    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        const failed = canonicalize(failing.allocator(), &first_source) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        for (failed) |item| {
            failing.allocator().free(item.operands);
            failing.allocator().free(item.literal);
        }
        failing.allocator().free(failed);
        break;
    }
}

test "constant composite declaration permutations have identical golden identity" {
    const a = [_]Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &.{ 0, 0, 0x80, 0x3f } },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &.{ 0, 0, 0, 0x40 } },
        .{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{ 1, 0 }, .literal = &.{} },
        .{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{ 0, 1, 0 }, .literal = &.{} },
        .{ .op = .fneg, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{2}, .literal = &.{} },
    };
    const b = [_]Instruction{
        a[1],
        a[0],
        .{ .op = .constant_composite, .ty = a[2].ty, .operands = &.{ 1, 0 }, .literal = &.{} },
        .{ .op = .constant_composite, .ty = a[3].ty, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .constant_composite, .ty = a[4].ty, .operands = &.{ 1, 0, 1 }, .literal = &.{} },
        .{ .op = .fneg, .ty = a[5].ty, .operands = &.{2}, .literal = &.{} },
    };
    const first = try canonicalize(std.testing.allocator, &a);
    defer freeInstructionsForTest(first);
    const second = try canonicalize(std.testing.allocator, &b);
    defer freeInstructionsForTest(second);
    const first_bytes = try serialize(std.testing.allocator, .vertex, "permutation", &.{}, first);
    defer std.testing.allocator.free(first_bytes);
    const second_bytes = try serialize(std.testing.allocator, .vertex, "permutation", &.{}, second);
    defer std.testing.allocator.free(second_bytes);
    try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
    try std.testing.expect(identify(first_bytes).eql(identify(second_bytes)));
}

test "canonicalize enforces its own instruction limit before allocation" {
    const over = try std.testing.allocator.alloc(Instruction, max_instructions + 1);
    defer std.testing.allocator.free(over);
    @memset(over, .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &.{ 0, 0, 0, 0 } });
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.LimitExceeded, canonicalize(failing.allocator(), over));
}

test "canonicalize rejects invalid declaration and executable dependencies" {
    const bad_declaration = [_]Instruction{.{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{1}, .literal = &.{} }};
    try std.testing.expectError(error.InvalidDependency, canonicalize(std.testing.allocator, &bad_declaration));
    const cyclic_declaration = [_]Instruction{.{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 2 }, .operands = &.{0}, .literal = &.{} }};
    try std.testing.expectError(error.InvalidDependency, canonicalize(std.testing.allocator, &cyclic_declaration));
    const bad_executable = [_]Instruction{.{ .op = .fneg, .ty = .{ .scalar = .f32 }, .operands = &.{1}, .literal = &.{} }};
    try std.testing.expectError(error.InvalidDependency, canonicalize(std.testing.allocator, &bad_executable));
}

fn freeInstructionsForTest(items: []Instruction) void {
    for (items) |item| {
        std.testing.allocator.free(item.operands);
        std.testing.allocator.free(item.literal);
    }
    std.testing.allocator.free(items);
}

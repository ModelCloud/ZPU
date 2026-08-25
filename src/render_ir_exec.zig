//! Standalone scalar executor for `zpu_spirv_render_profile_v1` canonical IR.
//!
//! This module is synthetic and opt-in.  It is not wired to Vulkan draw or
//! presentation.  Floating point follows Zig/IEEE f32 operations in program
//! order. NaN results are canonicalized to quiet `0x7fc00000`; signed zero is
//! preserved except conversions to integer, which map both zeros to zero.
const std = @import("std");
const ir = @import("vulkan/render_ir.zig");

pub const abi_version: u32 = 1;
pub const backend_version: u32 = 1;
pub const max_key_ir_bytes: usize = 256 * 1024;

pub const Error = error{
    InvalidProgram,
    InvalidType,
    InvalidShape,
    InvalidOperand,
    InvalidStorage,
    InvalidOutput,
    MissingInput,
    Bounds,
    NumericDomain,
    LimitExceeded,
    OutOfMemory,
};

pub const Value = struct {
    ty: ir.Type,
    bits: [16]u32 = .{0} ** 16,

    pub fn lanes(self: Value) usize {
        return @as(usize, self.ty.columns) * self.ty.rows;
    }
};

pub const Binding = struct { interface: u32, bytes: []const u8 };
pub const Output = struct { interface: u32, bytes: []u8 };

pub const KeyFields = struct {
    abi: u32 = abi_version,
    backend: u32 = backend_version,
    isa: u64,
    render_state: [32]u8,
};

pub const ExecutableKey = struct {
    fields: KeyFields,
    digest: [32]u8,
    ir_bytes: []u8,

    pub fn init(allocator: std.mem.Allocator, program: *const ir.Program, fields: KeyFields) Error!ExecutableKey {
        if (program.bytes.len > max_key_ir_bytes) return error.LimitExceeded;
        const bytes = allocator.dupe(u8, program.bytes) catch return error.OutOfMemory;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(std.mem.asBytes(&fields.abi));
        hash.update(std.mem.asBytes(&fields.backend));
        hash.update(std.mem.asBytes(&fields.isa));
        hash.update(&fields.render_state);
        hash.update(bytes);
        var digest: [32]u8 = undefined;
        hash.final(&digest);
        return .{ .fields = fields, .digest = digest, .ir_bytes = bytes };
    }
    pub fn deinit(self: *ExecutableKey, allocator: std.mem.Allocator) void {
        allocator.free(self.ir_bytes);
        self.* = undefined;
    }
    pub fn eql(a: ExecutableKey, b: ExecutableKey) bool {
        return std.meta.eql(a.fields, b.fields) and std.mem.eql(u8, &a.digest, &b.digest) and std.mem.eql(u8, a.ir_bytes, b.ir_bytes);
    }
};

fn lanes(ty: ir.Type) Error!usize {
    if (ty._pad != 0 or ty.columns < 1 or ty.columns > 4 or ty.rows < 1 or ty.rows > 4) return error.InvalidShape;
    if (ty.rows != 1 and !(ty.scalar == .f32 and ty.rows == 4 and ty.columns == 4)) return error.InvalidShape;
    return @as(usize, ty.columns) * ty.rows;
}
fn byteSize(ty: ir.Type) Error!usize {
    return (try lanes(ty)) * 4;
}
fn same(a: ir.Type, b: ir.Type) bool {
    return a.scalar == b.scalar and a.columns == b.columns and a.rows == b.rows and a._pad == b._pad;
}
fn valueRef(values: []const Value, current: usize, id: u32) Error!Value {
    if (id >= current) return error.InvalidOperand;
    return values[id];
}
fn canonicalFloat(bits: u32) u32 {
    const x: f32 = @bitCast(bits);
    return if (std.math.isNan(x)) 0x7fc00000 else bits;
}
fn readValue(ty: ir.Type, bytes: []const u8) Error!Value {
    const size = try byteSize(ty);
    if (bytes.len < size) return error.Bounds;
    var result = Value{ .ty = ty };
    for (0..try lanes(ty)) |i| result.bits[i] = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
    return result;
}
fn findBinding(bindings: []const Binding, index: u32) Error![]const u8 {
    var found: ?[]const u8 = null;
    for (bindings) |binding| if (binding.interface == index) {
        if (found != null) return error.InvalidOperand;
        found = binding.bytes;
    };
    return found orelse error.MissingInput;
}
fn validateType(ty: ir.Type) Error!void {
    _ = try lanes(ty);
}

pub const Executor = struct {
    allocator: std.mem.Allocator,
    program: ir.Program,
    values: []Value,
    output_scratch: []u8,

    pub fn init(allocator: std.mem.Allocator, source: *const ir.Program) Error!Executor {
        if (source.instructions.len > ir.max_instructions or source.bytes.len > max_key_ir_bytes) return error.LimitExceeded;
        var program = source.clone(allocator) catch return error.OutOfMemory;
        errdefer program.deinit(allocator);
        try validate(&program);
        const values = allocator.alloc(Value, program.instructions.len) catch return error.OutOfMemory;
        errdefer allocator.free(values);
        var total: usize = 0;
        for (program.interfaces) |interface| if (interface.storage == .output) {
            total = std.math.add(usize, total, try byteSize(interface.ty)) catch return error.LimitExceeded;
        };
        const scratch = allocator.alloc(u8, total) catch return error.OutOfMemory;
        return .{ .allocator = allocator, .program = program, .values = values, .output_scratch = scratch };
    }
    pub fn deinit(self: *Executor) void {
        self.allocator.free(self.output_scratch);
        self.allocator.free(self.values);
        self.program.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn execute(self: *Executor, bindings: []const Binding, outputs: []const Output) Error!void {
        var out_offset: usize = 0;
        for (self.program.interfaces, 0..) |interface, i| if (interface.storage == .output) {
            var found: ?[]u8 = null;
            for (outputs) |output| if (output.interface == i) {
                if (found != null) return error.InvalidOutput;
                found = output.bytes;
            };
            const size = try byteSize(interface.ty);
            if (found == null or found.?.len < size) return error.InvalidOutput;
            out_offset += size;
        };
        for (outputs) |output| {
            if (output.interface >= self.program.interfaces.len or self.program.interfaces[output.interface].storage != .output) return error.InvalidOutput;
        }
        @memset(self.output_scratch, 0);
        out_offset = 0;
        for (self.program.instructions, 0..) |instruction, pc| {
            var result = Value{ .ty = instruction.ty };
            switch (instruction.op) {
                .constant => {
                    if (instruction.ty.scalar == .bool) result.bits[0] = instruction.literal[0] else result = try readValue(instruction.ty, instruction.literal);
                },
                .constant_composite, .composite => {
                    var at: usize = 0;
                    for (instruction.operands) |operand| {
                        const part = try valueRef(self.values, pc, operand);
                        for (part.bits[0..part.lanes()]) |bits| {
                            result.bits[at] = bits;
                            at += 1;
                        }
                    }
                },
                .input => result = try readValue(instruction.ty, try findBinding(bindings, instruction.operands[0])),
                .uniform => result = try readValue(instruction.ty, try findBinding(bindings, instruction.operands[0])),
                .access => {
                    const interface_index = instruction.operands[0];
                    if (interface_index >= self.program.interfaces.len) return error.InvalidOperand;
                    const interface = self.program.interfaces[interface_index];
                    if (interface.storage != .uniform) return error.InvalidStorage;
                    const member_index = (try valueRef(self.values, pc, instruction.operands[1])).bits[0];
                    if (member_index >= interface.member_count) return error.Bounds;
                    const bytes = try findBinding(bindings, interface_index);
                    const offset = interface.members[member_index].offset;
                    const member_ty = interface.members[member_index].ty;
                    const size = try byteSize(member_ty);
                    if (offset > bytes.len or size > bytes.len - offset) return error.Bounds;
                    const loaded = try readValue(member_ty, bytes[offset..]);
                    if (instruction.operands.len == 2) {
                        if (!same(member_ty, instruction.ty)) return error.InvalidType;
                        result = loaded;
                    } else {
                        if (instruction.operands.len != 3 or try lanes(instruction.ty) != 1) return error.InvalidShape;
                        const index = (try valueRef(self.values, pc, instruction.operands[2])).bits[0];
                        if (index >= loaded.lanes()) return error.Bounds;
                        result.bits[0] = loaded.bits[index];
                    }
                },
                .extract => {
                    const source = try valueRef(self.values, pc, instruction.operands[0]);
                    if (instruction.operands.len == 1) {
                        if (!same(source.ty, instruction.ty)) return error.InvalidType;
                        result = source;
                    } else {
                        const selector = instruction.operands[1];
                        if (selector >= source.lanes()) return error.Bounds;
                        result.bits[0] = source.bits[selector];
                    }
                },
                .shuffle => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (instruction.operands[2..], 0..) |selector, i| {
                        if (selector >= a.lanes() + b.lanes()) return error.Bounds;
                        result.bits[i] = if (selector < a.lanes()) a.bits[selector] else b.bits[selector - a.lanes()];
                    }
                },
                .fneg => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    for (0..result.lanes()) |i| result.bits[i] = canonicalFloat(a.bits[i] ^ 0x80000000);
                },
                .iadd, .isub => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| result.bits[i] = if (instruction.op == .iadd) a.bits[i] +% b.bits[i] else a.bits[i] -% b.bits[i];
                },
                .fadd, .fsub, .fmul, .fdiv => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| {
                        const x: f32 = @bitCast(a.bits[i]);
                        const y: f32 = @bitCast(b.bits[i]);
                        const z = switch (instruction.op) {
                            .fadd => x + y,
                            .fsub => x - y,
                            .fmul => x * y,
                            .fdiv => x / y,
                            else => unreachable,
                        };
                        result.bits[i] = canonicalFloat(@bitCast(z));
                    }
                },
                .vector_times_scalar => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b: f32 = @bitCast((try valueRef(self.values, pc, instruction.operands[1])).bits[0]);
                    for (0..result.lanes()) |i| result.bits[i] = canonicalFloat(@bitCast(@as(f32, @bitCast(a.bits[i])) * b));
                },
                .matrix_times_vector => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..4) |row| {
                        var sum: f32 = 0;
                        for (0..4) |col| sum += @as(f32, @bitCast(a.bits[col * 4 + row])) * @as(f32, @bitCast(b.bits[col]));
                        result.bits[row] = canonicalFloat(@bitCast(sum));
                    }
                },
                .convert => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    for (0..result.lanes()) |i| result.bits[i] = try convert(a.ty.scalar, instruction.ty.scalar, a.bits[i]);
                },
                .output => {
                    const interface_index = instruction.operands[0];
                    const source = try valueRef(self.values, pc, instruction.operands[1]);
                    var offset: usize = 0;
                    for (self.program.interfaces[0..interface_index]) |item| if (item.storage == .output) {
                        offset += try byteSize(item.ty);
                    };
                    for (0..source.lanes()) |i| std.mem.writeInt(u32, self.output_scratch[offset + i * 4 ..][0..4], source.bits[i], .little);
                },
            }
            self.values[pc] = result;
        }
        out_offset = 0;
        for (self.program.interfaces, 0..) |interface, i| if (interface.storage == .output) {
            const size = try byteSize(interface.ty);
            for (outputs) |output| if (output.interface == i) @memcpy(output.bytes[0..size], self.output_scratch[out_offset..][0..size]);
            out_offset += size;
        };
    }
};

fn convert(from: ir.Scalar, to: ir.Scalar, bits: u32) Error!u32 {
    if (from == to) return bits;
    return switch (to) {
        .f32 => canonicalFloat(@bitCast(if (from == .i32) @as(f32, @floatFromInt(@as(i32, @bitCast(bits)))) else if (from == .u32) @as(f32, @floatFromInt(bits)) else return error.InvalidType)),
        .i32 => if (from == .f32) blk: {
            const x: f32 = @bitCast(bits);
            if (!std.math.isFinite(x) or x < @as(f32, @floatFromInt(std.math.minInt(i32))) or x >= 2147483648.0) return error.NumericDomain;
            break :blk @bitCast(@as(i32, @intFromFloat(x)));
        } else bits,
        .u32 => if (from == .f32) blk: {
            const x: f32 = @bitCast(bits);
            if (!std.math.isFinite(x) or x < 0 or x >= 4294967296.0) return error.NumericDomain;
            break :blk @intFromFloat(x);
        } else bits,
        .bool => return error.InvalidType,
    };
}

fn validate(program: *const ir.Program) Error!void {
    for (program.interfaces) |interface| {
        try validateType(interface.ty);
        if (interface.storage == .uniform) {
            if (!interface.block or interface.member_count == 0 or interface.member_count > ir.max_uniform_members) return error.InvalidStorage;
            for (interface.members[0..interface.member_count]) |m| try validateType(m.ty);
        }
    }
    var outputs_seen: [ir.max_values]bool = .{false} ** ir.max_values;
    for (program.instructions, 0..) |instruction, pc| {
        try validateType(instruction.ty);
        const n = instruction.operands.len;
        const arity_ok = switch (instruction.op) {
            .constant => n == 0,
            .constant_composite, .composite => n > 0,
            .input, .uniform => n == 1,
            .access => n >= 2 and n <= 3,
            .extract => n == 1 or n == 2,
            .shuffle => n == 2 + try lanes(instruction.ty),
            .fneg, .convert => n == 1,
            .iadd, .isub, .fadd, .fsub, .fmul, .fdiv, .vector_times_scalar, .matrix_times_vector => n == 2,
            .output => n == 2,
        };
        if (!arity_ok) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.literal.len != (if (instruction.ty.scalar == .bool) 1 else try byteSize(instruction.ty))) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.ty.scalar == .bool and instruction.literal[0] > 1) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.ty.scalar == .f32) for (0..try lanes(instruction.ty)) |i| if (!std.math.isFinite(@as(f32, @bitCast(std.mem.readInt(u32, instruction.literal[i * 4 ..][0..4], .little))))) return error.NumericDomain;
        if (instruction.op != .constant and instruction.literal.len != 0) return error.InvalidOperand;
        if (instruction.op == .input or instruction.op == .uniform) {
            const x = instruction.operands[0];
            const expected: ir.Storage = if (instruction.op == .input) .input else .uniform;
            if (x >= program.interfaces.len or program.interfaces[x].storage != expected) return error.InvalidStorage;
        }
        if (instruction.op == .output) {
            const x = instruction.operands[0];
            if (x >= program.interfaces.len or program.interfaces[x].storage != .output or outputs_seen[x]) return error.InvalidOutput;
            outputs_seen[x] = true;
            if (!same(program.interfaces[x].ty, instruction.ty)) return error.InvalidType;
        }
        for (instruction.operands, 0..) |operand, oi| if (isValueOperand(instruction.op, oi) and operand >= pc) return error.InvalidOperand;
        for (instruction.operands, 0..) |operand, oi| if (isValueOperand(instruction.op, oi)) {
            const source_ty = program.instructions[operand].ty;
            switch (instruction.op) {
                .constant_composite, .composite => if (source_ty.scalar != instruction.ty.scalar) return error.InvalidType,
                .fneg, .iadd, .isub, .fadd, .fsub, .fmul, .fdiv => if (!same(source_ty, instruction.ty)) return error.InvalidType,
                .output => if (!same(source_ty, instruction.ty)) return error.InvalidType,
                .vector_times_scalar => if ((oi == 0 and !same(source_ty, instruction.ty)) or (oi == 1 and (source_ty.scalar != .f32 or try lanes(source_ty) != 1))) return error.InvalidType,
                .matrix_times_vector => if ((oi == 0 and !(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 4)) or (oi == 1 and !same(source_ty, instruction.ty))) return error.InvalidType,
                .convert => if (try lanes(source_ty) != try lanes(instruction.ty)) return error.InvalidShape,
                else => {},
            }
        };
        if (instruction.op == .constant_composite or instruction.op == .composite) {
            var total: usize = 0;
            for (instruction.operands) |operand| {
                const part = program.instructions[operand].ty;
                total += try lanes(part);
                if (instruction.ty.rows == 1 and try lanes(part) != 1) return error.InvalidShape;
                if (instruction.ty.rows == 4 and !(part.rows == 1 and part.columns == 4)) return error.InvalidShape;
            }
            if (total != try lanes(instruction.ty)) return error.InvalidShape;
        }
        switch (instruction.op) {
            .fneg, .fadd, .fsub, .fmul, .fdiv, .vector_times_scalar, .matrix_times_vector => if (instruction.ty.scalar != .f32) return error.InvalidType,
            .iadd, .isub => if (instruction.ty.scalar != .i32 and instruction.ty.scalar != .u32) return error.InvalidType,
            else => {},
        }
        if (instruction.op == .convert) {
            const from = program.instructions[instruction.operands[0]].ty.scalar;
            const to = instruction.ty.scalar;
            if (from == .bool or to == .bool or (from == to)) return error.InvalidType;
        }
    }
}
fn isValueOperand(op: ir.Op, i: usize) bool {
    return switch (op) {
        .constant, .input, .uniform => false,
        .access => i != 0,
        .extract => i == 0,
        .shuffle => i < 2,
        .output => i == 1,
        else => true,
    };
}

fn testProgram(interfaces: []ir.Interface, instructions: []ir.Instruction) !ir.Program {
    const bytes = try ir.serialize(std.testing.allocator, .vertex, "main", interfaces, instructions);
    return .{ .stage = .vertex, .entry_name = @constCast("main"), .interfaces = interfaces, .instructions = instructions, .bytes = bytes, .identity = ir.identify(bytes) };
}
fn f32bytes(x: f32) [4]u8 {
    var b: [4]u8 = undefined;
    std.mem.writeInt(u32, &b, @bitCast(x), .little);
    return b;
}

test "every profile operation executes with owned allocation-free warm state" {
    const one = f32bytes(1);
    const two = f32bytes(2);
    const zero: [4]u8 = .{0} ** 4;
    var interfaces = [_]ir.Interface{
        .{ .storage = .input, .ty = .{ .scalar = .f32, .columns = 4 }, .location = 0 },
        .{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 },
        .{ .storage = .output, .ty = .{ .scalar = .f32, .columns = 4 }, .builtin_position = true },
    };
    interfaces[1].members[0] = .{ .ty = .{ .scalar = .f32, .columns = 4 }, .offset = 0 };
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &two },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &zero },
        .{ .op = .constant, .ty = .{ .scalar = .bool }, .operands = &.{}, .literal = &.{1} },
        .{ .op = .constant_composite, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 0, 1, 0, 1 }, .literal = &.{} },
        .{ .op = .input, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{0}, .literal = &.{} },
        .{ .op = .uniform, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{1}, .literal = &.{} },
        .{ .op = .access, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 1, 2 }, .literal = &.{} },
        .{ .op = .extract, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{7}, .literal = &.{} },
        .{ .op = .extract, .ty = .{ .scalar = .f32 }, .operands = &.{ 5, 2 }, .literal = &.{} },
        .{ .op = .composite, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 9, 0, 1, 9 }, .literal = &.{} },
        .{ .op = .shuffle, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 5, 6, 0, 5, 2, 7 }, .literal = &.{} },
        .{ .op = .fneg, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{11}, .literal = &.{} },
        .{ .op = .fadd, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 11, 4 }, .literal = &.{} },
        .{ .op = .fsub, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 13, 4 }, .literal = &.{} },
        .{ .op = .fmul, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 14, 4 }, .literal = &.{} },
        .{ .op = .fdiv, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 15, 4 }, .literal = &.{} },
        .{ .op = .vector_times_scalar, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 16, 1 }, .literal = &.{} },
        .{ .op = .convert, .ty = .{ .scalar = .u32 }, .operands = &.{0}, .literal = &.{} },
        .{ .op = .iadd, .ty = .{ .scalar = .u32 }, .operands = &.{ 18, 2 }, .literal = &.{} },
        .{ .op = .isub, .ty = .{ .scalar = .u32 }, .operands = &.{ 19, 2 }, .literal = &.{} },
        .{ .op = .convert, .ty = .{ .scalar = .f32 }, .operands = &.{20}, .literal = &.{} },
        .{ .op = .composite, .ty = .{ .scalar = .f32, .columns = 4, .rows = 4 }, .operands = &.{ 4, 4, 4, 4 }, .literal = &.{} },
        .{ .op = .matrix_times_vector, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 22, 17 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .f32, .columns = 4 }, .operands = &.{ 2, 23 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    @memset(source.bytes, 0); // executor owns the entire pipeline IR lifetime
    var input: [16]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u32, input[i * 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(i + 1))), .little);
    var uniform = input;
    var output: [16]u8 = .{0xaa} ** 16;
    const fixed = std.heap.FixedBufferAllocator.init(&.{});
    _ = fixed; // execute accepts no allocator and cannot allocate
    try executor.execute(&.{ .{ .interface = 0, .bytes = &input }, .{ .interface = 1, .bytes = &uniform } }, &.{.{ .interface = 2, .bytes = &output }});
    try std.testing.expect(!std.mem.allEqual(u8, &output, 0xaa));
}

test "rejection is explicit and output transactional" {
    const one = f32bytes(1);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{ .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one }, .{ .op = .convert, .ty = .{ .scalar = .u32 }, .operands = &.{0}, .literal = &.{} }, .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0 }, .literal = &.{} } };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var sentinel = [_]u8{0x5a} ** 4;
    try std.testing.expectError(error.InvalidOutput, executor.execute(&.{}, &.{}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 4), &sentinel);
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &sentinel }});
}

test "key compares full bounded bytes and all execution fields" {
    const one = f32bytes(1);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{.{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one }};
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    const fields = KeyFields{ .isa = 7, .render_state = .{3} ** 32 };
    var a = try ExecutableKey.init(std.testing.allocator, &source, fields);
    defer a.deinit(std.testing.allocator);
    var b = try ExecutableKey.init(std.testing.allocator, &source, fields);
    defer b.deinit(std.testing.allocator);
    try std.testing.expect(a.eql(b));
    b.ir_bytes[b.ir_bytes.len - 1] ^= 1;
    b.digest = a.digest;
    try std.testing.expect(!a.eql(b));
}

test "setup and key clean up every injected allocation failure" {
    const one = f32bytes(1);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{.{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one }};
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var saw_success = false;
    var fail_index: usize = 0;
    while (fail_index < 32) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        var executor = Executor.init(failing.allocator(), &source) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        executor.deinit();
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_success);
    var failing_key = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, ExecutableKey.init(failing_key.allocator(), &source, .{ .isa = 0, .render_state = .{0} ** 32 }));
}

test "uniform component bounds and numeric conversion domains are explicit" {
    const zero: [4]u8 = .{0} ** 4;
    const one: [4]u8 = .{ 1, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 }};
    interfaces[0].members[0] = .{ .ty = .{ .scalar = .f32, .columns = 4 }, .offset = 0 };
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &zero },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &one },
        .{ .op = .access, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0, 1 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var uniform: [16]u8 = .{0} ** 16;
    std.mem.writeInt(u32, uniform[4..8], @bitCast(@as(f32, 9)), .little);
    try executor.execute(&.{.{ .interface = 0, .bytes = &uniform }}, &.{});
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 9))), executor.values[2].bits[0]);
    executor.values[1].bits[0] = 4; // execution rewrites it, so malformed bounds are setup-tested below
    try std.testing.expectEqual(@as(u32, @bitCast(@as(i32, -2))), try convert(.f32, .i32, @bitCast(@as(f32, -2))));
    try std.testing.expectError(error.NumericDomain, convert(.f32, .i32, @bitCast(std.math.nan(f32))));
    try std.testing.expectError(error.NumericDomain, convert(.f32, .u32, @bitCast(@as(f32, -1))));
    try std.testing.expectError(error.InvalidType, convert(.u32, .bool, 0));
}

test "generated valid scalar DAGs are total and stable" {
    var prng = std.Random.DefaultPrng.init(0x5a4d4c31);
    for (0..128) |_| {
        var literals: [8][4]u8 = undefined;
        var instructions: [17]ir.Instruction = undefined;
        for (0..8) |i| {
            const value = prng.random().int(u32);
            std.mem.writeInt(u32, &literals[i], value, .little);
            instructions[i] = .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &literals[i] };
        }
        const pairs = [_][2]u32{ .{ 0, 1 }, .{ 2, 3 }, .{ 4, 5 }, .{ 6, 7 }, .{ 8, 9 }, .{ 10, 11 }, .{ 12, 13 }, .{ 14, 0 } };
        for (pairs, 0..) |_, i| instructions[8 + i] = .{ .op = if (prng.random().boolean()) .iadd else .isub, .ty = .{ .scalar = .u32 }, .operands = &pairs[i], .literal = &.{} };
        instructions[16] = .{ .op = .iadd, .ty = .{ .scalar = .u32 }, .operands = &.{ 14, 15 }, .literal = &.{} };
        var interfaces = [_]ir.Interface{};
        var source = try testProgram(&interfaces, &instructions);
        defer std.testing.allocator.free(source.bytes);
        var executor = try Executor.init(std.testing.allocator, &source);
        defer executor.deinit();
        try executor.execute(&.{}, &.{});
        const first = executor.values[16].bits[0];
        try executor.execute(&.{}, &.{});
        try std.testing.expectEqual(first, executor.values[16].bits[0]);
        const canonical = try ir.canonicalize(std.testing.allocator, &instructions);
        defer {
            for (canonical) |item| {
                std.testing.allocator.free(item.operands);
                std.testing.allocator.free(item.literal);
            }
            std.testing.allocator.free(canonical);
        }
        const again = try ir.canonicalize(std.testing.allocator, canonical);
        defer {
            for (again) |item| {
                std.testing.allocator.free(item.operands);
                std.testing.allocator.free(item.literal);
            }
            std.testing.allocator.free(again);
        }
        const a = try ir.serialize(std.testing.allocator, .vertex, "main", &.{}, canonical);
        defer std.testing.allocator.free(a);
        const b = try ir.serialize(std.testing.allocator, .vertex, "main", &.{}, again);
        defer std.testing.allocator.free(b);
        try std.testing.expectEqualSlices(u8, a, b);
    }
}

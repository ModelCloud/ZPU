//! Standalone scalar executor for `zpu_spirv_render_profile_v1` canonical IR.
//!
//! This module is synthetic and opt-in.  It is not wired to Vulkan draw or
//! presentation.  Floating point follows Zig/IEEE f32 operations in program
//! order. NaN results are canonicalized to quiet `0x7fc00000`; signed zero is
//! preserved except conversions to integer, which map both zeros to zero.
const std = @import("std");
const ir = @import("vulkan/render_ir.zig");
const frontend = @import("vulkan/spirv_frontend.zig");

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
        try validate(program);
        const canonical = ir.canonicalize(allocator, program.instructions) catch |err| return if (err == error.OutOfMemory) error.OutOfMemory else error.InvalidProgram;
        defer freeInstructions(allocator, canonical);
        const structural = ir.serialize(allocator, program.stage, program.entry_name, program.interfaces, canonical) catch return error.OutOfMemory;
        defer allocator.free(structural);
        const identity = ir.identify(program.bytes);
        if (!std.mem.eql(u8, structural, program.bytes) or !program.identity.eql(identity)) return error.InvalidProgram;
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
    for (0..try lanes(ty)) |i| {
        const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
        result.bits[i] = switch (ty.scalar) {
            .bool => if (bits <= 1) bits else return error.NumericDomain,
            .f32 => canonicalFloat(bits),
            else => bits,
        };
    }
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
        for (outputs, 0..) |left, i| {
            const left_size = try byteSize(self.program.interfaces[left.interface].ty);
            const left_start = @intFromPtr(left.bytes.ptr);
            const left_end = std.math.add(usize, left_start, left_size) catch return error.InvalidOutput;
            for (outputs[i + 1 ..]) |right| {
                const right_size = try byteSize(self.program.interfaces[right.interface].ty);
                const right_start = @intFromPtr(right.bytes.ptr);
                const right_end = std.math.add(usize, right_start, right_size) catch return error.InvalidOutput;
                if (left_start < right_end and right_start < left_end) return error.InvalidOutput;
            }
            for (bindings) |binding| {
                const binding_start = @intFromPtr(binding.bytes.ptr);
                const binding_end = std.math.add(usize, binding_start, binding.bytes.len) catch return error.InvalidOperand;
                if (left_start < binding_end and binding_start < left_end) return error.InvalidOutput;
            }
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
            if (!same(instruction.ty, program.interfaces[x].ty)) return error.InvalidType;
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
        switch (instruction.op) {
            .access => {
                const interface_index = instruction.operands[0];
                if (interface_index >= program.interfaces.len or program.interfaces[interface_index].storage != .uniform) return error.InvalidStorage;
                const interface = program.interfaces[interface_index];
                for (instruction.operands[1..]) |index_id| {
                    const index_ty = program.instructions[index_id].ty;
                    if (index_ty.scalar != .u32 or try lanes(index_ty) != 1 or program.instructions[index_id].op != .constant) return error.InvalidType;
                }
                const member_id = std.mem.readInt(u32, program.instructions[instruction.operands[1]].literal[0..4], .little);
                if (member_id >= interface.member_count) return error.Bounds;
                const member_ty = interface.members[member_id].ty;
                if (instruction.operands.len == 2) {
                    if (!same(instruction.ty, member_ty)) return error.InvalidType;
                } else if (member_ty.rows != 1 or instruction.ty.rows != 1 or instruction.ty.columns != 1 or instruction.ty.scalar != member_ty.scalar) return error.InvalidType else {
                    const component = std.mem.readInt(u32, program.instructions[instruction.operands[2]].literal[0..4], .little);
                    if (component >= member_ty.columns) return error.Bounds;
                }
            },
            .extract => {
                const source = program.instructions[instruction.operands[0]].ty;
                if (instruction.operands.len == 1) {
                    if (!same(source, instruction.ty)) return error.InvalidType;
                } else if (source.rows != 1 or instruction.ty.rows != 1 or instruction.ty.columns != 1 or instruction.ty.scalar != source.scalar) return error.InvalidType else if (instruction.operands[1] >= source.columns) return error.Bounds;
            },
            .shuffle => {
                const a = program.instructions[instruction.operands[0]].ty;
                const b = program.instructions[instruction.operands[1]].ty;
                if (a.rows != 1 or b.rows != 1 or instruction.ty.rows != 1 or a.scalar != b.scalar or instruction.ty.scalar != a.scalar) return error.InvalidType;
                for (instruction.operands[2..]) |selector| if (selector >= @as(u32, a.columns) + b.columns) return error.Bounds;
            },
            else => {},
        }
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
fn freeInstructions(allocator: std.mem.Allocator, items: []ir.Instruction) void {
    for (items) |item| {
        allocator.free(item.operands);
        allocator.free(item.literal);
    }
    allocator.free(items);
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
        .{ .storage = .uniform, .ty = .{ .scalar = .f32, .columns = 4 }, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 },
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
    var changed_fields = fields;
    changed_fields.isa += 1;
    var determinant = try ExecutableKey.init(std.testing.allocator, &source, changed_fields);
    defer determinant.deinit(std.testing.allocator);
    try std.testing.expect(!a.eql(determinant));
    instructions[0].ty.scalar = .u32;
    try std.testing.expectError(error.InvalidProgram, ExecutableKey.init(std.testing.allocator, &source, fields));
    instructions[0].ty.scalar = .f32;
    interfaces[0].location = 9;
    try std.testing.expectError(error.InvalidProgram, ExecutableKey.init(std.testing.allocator, &source, fields));
    interfaces[0].location = 0;
    source.bytes[source.bytes.len - 1] ^= 1;
    source.identity = ir.identify(source.bytes);
    try std.testing.expectError(error.InvalidProgram, ExecutableKey.init(std.testing.allocator, &source, fields));
}

test "clone setup and key report every allocation failure without outstanding memory" {
    const one = f32bytes(1);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{.{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one }};
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var clone_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var clone = try source.clone(clone_probe.allocator());
    clone.deinit(clone_probe.allocator());
    try std.testing.expectEqual(clone_probe.allocated_bytes, clone_probe.freed_bytes);
    try std.testing.expectEqual(clone_probe.allocations, clone_probe.deallocations);
    const clone_allocations = clone_probe.allocations;
    for (0..clone_allocations) |fail_index| {
        var direct = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, source.clone(direct.allocator()));
        try std.testing.expectEqual(@as(usize, 0), direct.allocated_bytes - direct.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), direct.allocations - direct.deallocations);

        var through_init = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Executor.init(through_init.allocator(), &source));
        try std.testing.expectEqual(@as(usize, 0), through_init.allocated_bytes - through_init.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), through_init.allocations - through_init.deallocations);
    }
    var setup_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var complete = try Executor.init(setup_probe.allocator(), &source);
    complete.deinit();
    try std.testing.expectEqual(setup_probe.allocated_bytes, setup_probe.freed_bytes);
    try std.testing.expectEqual(setup_probe.allocations, setup_probe.deallocations);
    const setup_allocations = setup_probe.allocations;
    for (clone_allocations..setup_allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Executor.init(failing.allocator(), &source));
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations - failing.deallocations);
    }
    var key_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var key = try ExecutableKey.init(key_probe.allocator(), &source, .{ .isa = 0, .render_state = .{0} ** 32 });
    key.deinit(key_probe.allocator());
    try std.testing.expectEqual(key_probe.allocated_bytes, key_probe.freed_bytes);
    try std.testing.expectEqual(key_probe.allocations, key_probe.deallocations);
    for (0..key_probe.allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, ExecutableKey.init(failing.allocator(), &source, .{ .isa = 0, .render_state = .{0} ** 32 }));
        try std.testing.expectEqual(@as(usize, 0), failing.allocated_bytes - failing.freed_bytes);
        try std.testing.expectEqual(@as(usize, 0), failing.allocations - failing.deallocations);
    }
    std.debug.print("allocation failure matrix: Program.clone={d} Executor.init.clone_stage={d} Executor.init.other={d} ExecutableKey={d} outstanding_allocations=0 outstanding_bytes=0\n", .{ clone_allocations, clone_allocations, setup_allocations - clone_allocations, key_probe.allocations });
}

test "profile v1 frontend admission satisfies executor constant-index setup rule" {
    var program = try frontend.compile(std.testing.allocator, &frontend.uniform_vertex, .vertex, "main", &.{});
    defer program.deinit(std.testing.allocator);
    for (program.instructions) |instruction| if (instruction.op == .access) {
        for (instruction.operands[1..]) |index_id| {
            try std.testing.expectEqual(ir.Op.constant, program.instructions[index_id].op);
            try std.testing.expectEqual(ir.Scalar.u32, program.instructions[index_id].ty.scalar);
            try std.testing.expectEqual(@as(u3, 1), program.instructions[index_id].ty.columns);
            try std.testing.expectEqual(@as(u3, 1), program.instructions[index_id].ty.rows);
        }
    };
    var executor = try Executor.init(std.testing.allocator, &program);
    executor.deinit();
}

test "executor setup rejects runtime scalar u32 access indices" {
    var interfaces = [_]ir.Interface{
        .{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 },
        .{ .storage = .input, .ty = .{ .scalar = .u32 }, .location = 0 },
    };
    interfaces[0].members[0] = .{ .ty = .{ .scalar = .f32 }, .offset = 0 };
    var instructions = [_]ir.Instruction{
        .{ .op = .input, .ty = .{ .scalar = .u32 }, .operands = &.{1}, .literal = &.{} },
        .{ .op = .access, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    try std.testing.expectError(error.InvalidType, Executor.init(std.testing.allocator, &source));
}

test "bool input and output aliases reject without mutation while NaNs canonicalize" {
    var interfaces = [_]ir.Interface{
        .{ .storage = .input, .ty = .{ .scalar = .bool }, .location = 0 },
        .{ .storage = .input, .ty = .{ .scalar = .f32 }, .location = 1 },
        .{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 },
        .{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 1 },
    };
    var instructions = [_]ir.Instruction{
        .{ .op = .input, .ty = .{ .scalar = .bool }, .operands = &.{0}, .literal = &.{} },
        .{ .op = .input, .ty = .{ .scalar = .f32 }, .operands = &.{1}, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 2, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 3, 1 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var bad_bool = [_]u8{ 2, 0, 0, 0 };
    var nan = [_]u8{ 1, 0, 0xc0, 0x7f };
    var target = [_]u8{0x5a} ** 8;
    const bindings = [_]Binding{ .{ .interface = 0, .bytes = &bad_bool }, .{ .interface = 1, .bytes = &nan } };
    try std.testing.expectError(error.InvalidOutput, executor.execute(&bindings, &.{ .{ .interface = 2, .bytes = target[0..4] }, .{ .interface = 3, .bytes = target[2..6] } }));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 8), &target);
    var a: [4]u8 = .{0} ** 4;
    var b: [4]u8 = .{0} ** 4;
    try std.testing.expectError(error.NumericDomain, executor.execute(&bindings, &.{ .{ .interface = 2, .bytes = &a }, .{ .interface = 3, .bytes = &b } }));
    bad_bool[0] = 1;
    try executor.execute(&bindings, &.{ .{ .interface = 2, .bytes = &a }, .{ .interface = 3, .bytes = &b } });
    try std.testing.expectEqual(@as(u32, 0x7fc00000), std.mem.readInt(u32, &a, .little));
    const before = a;
    try std.testing.expectError(error.InvalidOutput, executor.execute(&.{ .{ .interface = 0, .bytes = &a }, .{ .interface = 1, .bytes = &nan } }, &.{ .{ .interface = 2, .bytes = &a }, .{ .interface = 3, .bytes = &b } }));
    try std.testing.expectEqualSlices(u8, &before, &a);
}

test "late numeric rejection rolls back earlier output" {
    const one = f32bytes(1);
    var interfaces = [_]ir.Interface{ .{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }, .{ .storage = .input, .ty = .{ .scalar = .f32 }, .location = 0 } };
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one },
        .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 0 }, .literal = &.{} },
        .{ .op = .input, .ty = .{ .scalar = .f32 }, .operands = &.{1}, .literal = &.{} },
        .{ .op = .convert, .ty = .{ .scalar = .u32 }, .operands = &.{2}, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var nan = [_]u8{ 1, 0, 0xc0, 0x7f };
    var output = [_]u8{0xa5} ** 4;
    try std.testing.expectError(error.NumericDomain, executor.execute(&.{.{ .interface = 1, .bytes = &nan }}, &.{.{ .interface = 0, .bytes = &output }}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 4), &output);
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

const property_types = [_]ir.Type{
    .{ .scalar = .bool },
    .{ .scalar = .i32 },
    .{ .scalar = .i32, .columns = 2 },
    .{ .scalar = .i32, .columns = 3 },
    .{ .scalar = .i32, .columns = 4 },
    .{ .scalar = .u32 },
    .{ .scalar = .u32, .columns = 2 },
    .{ .scalar = .u32, .columns = 3 },
    .{ .scalar = .u32, .columns = 4 },
    .{ .scalar = .f32 },
    .{ .scalar = .f32, .columns = 2 },
    .{ .scalar = .f32, .columns = 3 },
    .{ .scalar = .f32, .columns = 4 },
    .{ .scalar = .f32, .columns = 4, .rows = 4 },
};

fn propertyLiteral(arena: std.mem.Allocator, ty: ir.Type) ![]u8 {
    if (ty.scalar == .bool) return try arena.dupe(u8, &.{1});
    const result = try arena.alloc(u8, try byteSize(ty));
    for (0..try lanes(ty)) |lane| {
        const bits: u32 = if (ty.scalar == .f32) @bitCast(@as(f32, 1)) else 1;
        std.mem.writeInt(u32, result[lane * 4 ..][0..4], bits, .little);
    }
    return result;
}

fn propertyInstruction(arena: std.mem.Allocator, list: *std.ArrayList(ir.Instruction), op: ir.Op, ty: ir.Type, operands: []const u32, literal: []const u8) !u32 {
    const id: u32 = @intCast(list.items.len);
    try list.append(arena, .{ .op = op, .ty = ty, .operands = try arena.dupe(u32, operands), .literal = try arena.dupe(u8, literal) });
    return id;
}

fn propertyConstant(arena: std.mem.Allocator, list: *std.ArrayList(ir.Instruction), ty: ir.Type) !u32 {
    return propertyInstruction(arena, list, .constant, ty, &.{}, try propertyLiteral(arena, ty));
}

fn runPropertyCase(op: ir.Op, result_ty: ir.Type, convert_from: ?ir.Scalar) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var instructions: std.ArrayList(ir.Instruction) = .empty;
    var interfaces: [2]ir.Interface = undefined;
    var interface_count: usize = 0;
    var bindings: [2]Binding = undefined;
    var binding_count: usize = 0;
    var input_bytes: [64]u8 = .{0} ** 64;
    var output_bytes: [64]u8 = .{0xa5} ** 64;
    var outputs: [1]Output = undefined;
    var output_count: usize = 0;
    for (0..try lanes(result_ty)) |lane| std.mem.writeInt(u32, input_bytes[lane * 4 ..][0..4], if (result_ty.scalar == .f32) @bitCast(@as(f32, 1)) else 1, .little);

    var result_id: u32 = undefined;
    switch (op) {
        .constant => result_id = try propertyConstant(arena, &instructions, result_ty),
        .constant_composite, .composite => {
            var parts: [16]u32 = undefined;
            const part_ty = if (result_ty.rows == 4) ir.Type{ .scalar = .f32, .columns = 4 } else ir.Type{ .scalar = result_ty.scalar };
            const part_count: usize = if (result_ty.rows == 4) 4 else result_ty.columns;
            for (0..part_count) |i| parts[i] = try propertyConstant(arena, &instructions, part_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, parts[0..part_count], &.{});
        },
        .input, .uniform => {
            interfaces[0] = .{ .storage = if (op == .input) .input else .uniform, .ty = result_ty, .location = if (op == .input) 0 else null, .descriptor_set = if (op == .uniform) 0 else null, .binding = if (op == .uniform) 0 else null, .block = op == .uniform, .member_count = if (op == .uniform) 1 else 0 };
            if (op == .uniform) interfaces[0].members[0] = .{ .ty = result_ty, .offset = 0 };
            interface_count = 1;
            bindings[0] = .{ .interface = 0, .bytes = input_bytes[0..try byteSize(result_ty)] };
            binding_count = 1;
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{0}, &.{});
        },
        .access => {
            interfaces[0] = .{ .storage = .uniform, .ty = result_ty, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 };
            interfaces[0].members[0] = .{ .ty = result_ty, .offset = 0 };
            interface_count = 1;
            bindings[0] = .{ .interface = 0, .bytes = input_bytes[0..try byteSize(result_ty)] };
            binding_count = 1;
            const index = try propertyInstruction(arena, &instructions, .constant, .{ .scalar = .u32 }, &.{}, &.{ 0, 0, 0, 0 });
            result_id = try propertyInstruction(arena, &instructions, .access, result_ty, &.{ 0, index }, &.{});
        },
        .extract => {
            const source = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, .extract, result_ty, &.{source}, &.{});
        },
        .shuffle => {
            const a = try propertyConstant(arena, &instructions, result_ty);
            const b = try propertyConstant(arena, &instructions, result_ty);
            var operands: [18]u32 = undefined;
            operands[0] = a;
            operands[1] = b;
            for (0..try lanes(result_ty)) |i| operands[2 + i] = @intCast(i);
            result_id = try propertyInstruction(arena, &instructions, .shuffle, result_ty, operands[0 .. 2 + try lanes(result_ty)], &.{});
        },
        .fneg, .convert => {
            var source_ty = result_ty;
            if (convert_from) |scalar| source_ty.scalar = scalar;
            const source = try propertyConstant(arena, &instructions, source_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{source}, &.{});
        },
        .iadd, .isub, .fadd, .fsub, .fmul, .fdiv => {
            const a = try propertyConstant(arena, &instructions, result_ty);
            const b = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ a, b }, &.{});
        },
        .vector_times_scalar => {
            const vector = try propertyConstant(arena, &instructions, result_ty);
            const scalar = try propertyConstant(arena, &instructions, .{ .scalar = .f32 });
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ vector, scalar }, &.{});
        },
        .matrix_times_vector => {
            const matrix = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4, .rows = 4 });
            const vector = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ matrix, vector }, &.{});
        },
        .output => {
            interfaces[0] = .{ .storage = .output, .ty = result_ty, .location = 0 };
            interface_count = 1;
            const source = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, .output, result_ty, &.{ 0, source }, &.{});
            outputs[0] = .{ .interface = 0, .bytes = output_bytes[0..try byteSize(result_ty)] };
            output_count = 1;
        },
    }
    var source = try testProgram(interfaces[0..interface_count], instructions.items);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    try executor.execute(bindings[0..binding_count], outputs[0..output_count]);
    const first = executor.values[result_id];
    try executor.execute(bindings[0..binding_count], outputs[0..output_count]);
    try std.testing.expectEqual(first.ty, executor.values[result_id].ty);
    try std.testing.expectEqualSlices(u32, first.bits[0..first.lanes()], executor.values[result_id].bits[0..first.lanes()]);
}

test "generated bounded operation by type-family property matrix is complete" {
    var totals = [_]usize{0} ** @typeInfo(ir.Op).@"enum".fields.len;
    for (property_types) |ty| {
        const is_numeric = ty.scalar != .bool;
        const is_integer = ty.scalar == .i32 or ty.scalar == .u32;
        const is_float = ty.scalar == .f32;
        const is_vector = ty.rows == 1 and ty.columns > 1;
        const is_non_matrix = ty.rows == 1;
        inline for ([_]ir.Op{ .constant, .input, .uniform, .access, .extract, .output }) |op| {
            try runPropertyCase(op, ty, null);
            totals[@intFromEnum(op)] += 1;
        }
        if (is_numeric and (is_vector or ty.rows == 4)) inline for ([_]ir.Op{ .constant_composite, .composite }) |op| {
            try runPropertyCase(op, ty, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_non_matrix) {
            try runPropertyCase(.shuffle, ty, null);
            totals[@intFromEnum(ir.Op.shuffle)] += 1;
        }
        if (is_float) inline for ([_]ir.Op{ .fneg, .fadd, .fsub, .fmul, .fdiv }) |op| {
            try runPropertyCase(op, ty, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_integer) inline for ([_]ir.Op{ .iadd, .isub }) |op| {
            try runPropertyCase(op, ty, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_float and is_vector) {
            try runPropertyCase(.vector_times_scalar, ty, null);
            totals[@intFromEnum(ir.Op.vector_times_scalar)] += 1;
        }
        if (is_numeric and is_non_matrix) for ([_]ir.Scalar{ .i32, .u32, .f32 }) |from| if (from != ty.scalar) {
            try runPropertyCase(.convert, ty, from);
            totals[@intFromEnum(ir.Op.convert)] += 1;
        };
    }
    try runPropertyCase(.matrix_times_vector, .{ .scalar = .f32, .columns = 4 }, null);
    totals[@intFromEnum(ir.Op.matrix_times_vector)] += 1;
    const expected = [_]usize{ 14, 10, 14, 14, 14, 10, 14, 13, 5, 8, 8, 5, 5, 5, 5, 3, 1, 24, 14 };
    try std.testing.expectEqual(expected, totals);
    var total: usize = 0;
    for (totals) |count| {
        try std.testing.expect(count > 0);
        total += count;
    }
    try std.testing.expectEqual(@as(usize, 186), total);
    std.debug.print("generated property matrix: operations=19 type_families=scalar+vec2+vec3+vec4+mat4 valid={d} per_operation={any}\n", .{ total, totals });
}

fn expectGeneratedSetupError(expected: Error, interfaces: []ir.Interface, instructions: []ir.Instruction) !void {
    var source = try testProgram(interfaces, instructions);
    defer std.testing.allocator.free(source.bytes);
    try std.testing.expectError(expected, Executor.init(std.testing.allocator, &source));
}

test "generated bounded negative and runtime property categories are complete" {
    var malformed: usize = 0;
    inline for (@typeInfo(ir.Op).@"enum".fields) |field| {
        const op: ir.Op = @enumFromInt(field.value);
        const operands: []const u32 = if (op == .constant) &.{0} else &.{};
        var instructions = [_]ir.Instruction{.{ .op = op, .ty = .{ .scalar = .f32 }, .operands = operands, .literal = if (op == .constant) &.{ 0, 0, 0, 0 } else &.{} }};
        try expectGeneratedSetupError(error.InvalidOperand, &.{}, &instructions);
        malformed += 1;
    }

    var bounds: usize = 0;
    for (property_types) |ty| {
        var interfaces = [_]ir.Interface{.{ .storage = .uniform, .ty = ty, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 }};
        interfaces[0].members[0] = .{ .ty = ty, .offset = 0 };
        var one = [_]u8{ 1, 0, 0, 0 };
        var instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &one },
            .{ .op = .access, .ty = ty, .operands = &.{ 0, 0 }, .literal = &.{} },
        };
        try expectGeneratedSetupError(error.Bounds, &interfaces, &instructions);
        bounds += 1;
    }
    for (property_types) |ty| if (ty.rows == 1 and ty.columns > 1) {
        var literal: [16]u8 = .{0} ** 16;
        if (ty.scalar == .f32) for (0..ty.columns) |lane| std.mem.writeInt(u32, literal[lane * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
        var extract_instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = ty, .operands = &.{}, .literal = literal[0..try byteSize(ty)] },
            .{ .op = .extract, .ty = .{ .scalar = ty.scalar }, .operands = &.{ 0, ty.columns }, .literal = &.{} },
        };
        try expectGeneratedSetupError(error.Bounds, &.{}, &extract_instructions);
        bounds += 1;
        var shuffle_operands: [6]u32 = .{ 0, 0, 0, 0, 0, 0 };
        for (0..ty.columns) |lane| shuffle_operands[2 + lane] = if (lane + 1 == ty.columns) @as(u32, ty.columns) * 2 else @intCast(lane);
        var shuffle_instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = ty, .operands = &.{}, .literal = literal[0..try byteSize(ty)] },
            .{ .op = .shuffle, .ty = ty, .operands = shuffle_operands[0 .. 2 + ty.columns], .literal = &.{} },
        };
        try expectGeneratedSetupError(error.Bounds, &.{}, &shuffle_instructions);
        bounds += 1;
        var interfaces = [_]ir.Interface{.{ .storage = .uniform, .ty = ty, .descriptor_set = 0, .binding = 0, .block = true, .member_count = 1 }};
        interfaces[0].members[0] = .{ .ty = ty, .offset = 0 };
        var zero = [_]u8{0} ** 4;
        var component = [_]u8{ 0, 0, 0, 0 };
        std.mem.writeInt(u32, &component, ty.columns, .little);
        var access_instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &zero },
            .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &component },
            .{ .op = .access, .ty = .{ .scalar = ty.scalar }, .operands = &.{ 0, 0, 1 }, .literal = &.{} },
        };
        try expectGeneratedSetupError(error.Bounds, &interfaces, &access_instructions);
        bounds += 1;
    };

    var aliases: usize = 0;
    for (property_types) |ty| {
        var interfaces = [_]ir.Interface{ .{ .storage = .input, .ty = ty, .location = 0 }, .{ .storage = .output, .ty = ty, .location = 0 } };
        var instructions = [_]ir.Instruction{
            .{ .op = .input, .ty = ty, .operands = &.{0}, .literal = &.{} },
            .{ .op = .output, .ty = ty, .operands = &.{ 1, 0 }, .literal = &.{} },
        };
        var source = try testProgram(&interfaces, &instructions);
        defer std.testing.allocator.free(source.bytes);
        var executor = try Executor.init(std.testing.allocator, &source);
        defer executor.deinit();
        var storage = [_]u8{0x5a} ** 64;
        const before = storage;
        const size = try byteSize(ty);
        try std.testing.expectError(error.InvalidOutput, executor.execute(&.{.{ .interface = 0, .bytes = storage[0..size] }}, &.{.{ .interface = 1, .bytes = storage[0..size] }}));
        try std.testing.expectEqualSlices(u8, &before, &storage);
        aliases += 1;
    }

    var runtime_nan: usize = 0;
    var signed_zero: usize = 0;
    for (property_types) |ty| if (ty.scalar == .f32) {
        var interfaces = [_]ir.Interface{ .{ .storage = .input, .ty = ty, .location = 0 }, .{ .storage = .output, .ty = ty, .location = 0 } };
        var instructions = [_]ir.Instruction{
            .{ .op = .input, .ty = ty, .operands = &.{0}, .literal = &.{} },
            .{ .op = .output, .ty = ty, .operands = &.{ 1, 0 }, .literal = &.{} },
        };
        var source = try testProgram(&interfaces, &instructions);
        defer std.testing.allocator.free(source.bytes);
        var executor = try Executor.init(std.testing.allocator, &source);
        defer executor.deinit();
        var input: [64]u8 = undefined;
        var output: [64]u8 = undefined;
        const lane_count = try lanes(ty);
        for (0..lane_count) |lane| std.mem.writeInt(u32, input[lane * 4 ..][0..4], 0x7fa12345, .little);
        try executor.execute(&.{.{ .interface = 0, .bytes = input[0 .. lane_count * 4] }}, &.{.{ .interface = 1, .bytes = output[0 .. lane_count * 4] }});
        for (0..lane_count) |lane| try std.testing.expectEqual(@as(u32, 0x7fc00000), std.mem.readInt(u32, output[lane * 4 ..][0..4], .little));
        runtime_nan += 1;
        for (0..lane_count) |lane| std.mem.writeInt(u32, input[lane * 4 ..][0..4], 0x80000000, .little);
        try executor.execute(&.{.{ .interface = 0, .bytes = input[0 .. lane_count * 4] }}, &.{.{ .interface = 1, .bytes = output[0 .. lane_count * 4] }});
        for (0..lane_count) |lane| try std.testing.expectEqual(@as(u32, 0x80000000), std.mem.readInt(u32, output[lane * 4 ..][0..4], .little));
        signed_zero += 1;
    };

    var rollback: usize = 0;
    for ([_]u3{ 1, 2, 3, 4 }) |columns| {
        const byte_count: usize = @as(usize, columns) * 4;
        const fty = ir.Type{ .scalar = .f32, .columns = columns };
        const uty = ir.Type{ .scalar = .u32, .columns = columns };
        var interfaces = [_]ir.Interface{ .{ .storage = .output, .ty = fty, .location = 0 }, .{ .storage = .input, .ty = fty, .location = 0 } };
        var literal: [16]u8 = undefined;
        for (0..columns) |lane| std.mem.writeInt(u32, literal[lane * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
        var instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = fty, .operands = &.{}, .literal = literal[0..byte_count] },
            .{ .op = .output, .ty = fty, .operands = &.{ 0, 0 }, .literal = &.{} },
            .{ .op = .input, .ty = fty, .operands = &.{1}, .literal = &.{} },
            .{ .op = .convert, .ty = uty, .operands = &.{2}, .literal = &.{} },
        };
        var source = try testProgram(&interfaces, &instructions);
        defer std.testing.allocator.free(source.bytes);
        var executor = try Executor.init(std.testing.allocator, &source);
        defer executor.deinit();
        var input: [16]u8 = undefined;
        var output = [_]u8{0xa5} ** 16;
        const before = output;
        for (0..columns) |lane| std.mem.writeInt(u32, input[lane * 4 ..][0..4], 0x7fc00000, .little);
        try std.testing.expectError(error.NumericDomain, executor.execute(&.{.{ .interface = 1, .bytes = input[0..byte_count] }}, &.{.{ .interface = 0, .bytes = output[0..byte_count] }}));
        try std.testing.expectEqualSlices(u8, &before, &output);
        rollback += 1;
    }
    try std.testing.expectEqual(@as(usize, 19), malformed);
    try std.testing.expectEqual(@as(usize, 41), bounds);
    try std.testing.expectEqual(@as(usize, 14), aliases);
    try std.testing.expectEqual(@as(usize, 4), rollback);
    try std.testing.expectEqual(@as(usize, 5), runtime_nan);
    try std.testing.expectEqual(@as(usize, 5), signed_zero);
    std.debug.print("generated property categories: malformed=19 bounds=41 aliases=14 rollback_after_late_failure=4 runtime_nan=5 signed_zero=5\n", .{});
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

test "generated float type-family DAGs preserve canonical NaN and signed zero policy" {
    var prng = std.Random.DefaultPrng.init(0x6633325f444147);
    for (0..64) |case| {
        const x: f32 = if (case == 0) -0.0 else @floatFromInt(@as(i16, @bitCast(prng.random().int(u16))));
        const y: f32 = if (case == 1) 0.0 else @floatFromInt(@as(i16, @bitCast(prng.random().int(u16))));
        var xb = f32bytes(x);
        var yb = f32bytes(y);
        var instructions = [_]ir.Instruction{
            .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &xb },
            .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &yb },
            .{ .op = .fadd, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
            .{ .op = .fsub, .ty = .{ .scalar = .f32 }, .operands = &.{ 2, 1 }, .literal = &.{} },
            .{ .op = .fmul, .ty = .{ .scalar = .f32 }, .operands = &.{ 3, 0 }, .literal = &.{} },
            .{ .op = .fdiv, .ty = .{ .scalar = .f32 }, .operands = &.{ 4, 1 }, .literal = &.{} },
            .{ .op = .fneg, .ty = .{ .scalar = .f32 }, .operands = &.{5}, .literal = &.{} },
        };
        var interfaces = [_]ir.Interface{};
        var source = try testProgram(&interfaces, &instructions);
        defer std.testing.allocator.free(source.bytes);
        var executor = try Executor.init(std.testing.allocator, &source);
        defer executor.deinit();
        try executor.execute(&.{}, &.{});
        const bits = executor.values[6].bits[0];
        const value: f32 = @bitCast(bits);
        if (std.math.isNan(value)) try std.testing.expectEqual(@as(u32, 0x7fc00000), bits);
        try executor.execute(&.{}, &.{});
        try std.testing.expectEqual(bits, executor.values[6].bits[0]);
    }
}

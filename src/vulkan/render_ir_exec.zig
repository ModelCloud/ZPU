//! Standalone scalar executor for `zpu_spirv_render_profile_v1` canonical IR.
//!
//! This module is synthetic and opt-in.  It is not wired to Vulkan draw or
//! presentation.  Floating point follows Zig/IEEE f32 operations in program
//! order. NaN results are canonicalized to quiet `0x7fc00000`; signed zero is
//! preserved except conversions to integer, which map both zeros to zero.
const std = @import("std");
const ir = @import("render_ir.zig");
const frontend = @import("spirv_frontend.zig");

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
        for (bindings, 0..) |binding, i| {
            if (binding.interface >= self.program.interfaces.len) return error.InvalidOperand;
            const storage = self.program.interfaces[binding.interface].storage;
            if (storage != .input and storage != .uniform and storage != .output) return error.InvalidStorage;
            for (bindings[0..i]) |prior| if (prior.interface == binding.interface) return error.InvalidOperand;
        }
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
                // Compute StorageBuffer interfaces are read/write bindings. The
                // same descriptor range is intentionally supplied as both a
                // binding and an output, so permit that exact interface/range
                // pair while retaining overlap rejection for all other inputs.
                if (left.interface == binding.interface and left_start == binding_start) continue;
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
                .storage => {
                    const interface_index = instruction.operands[0];
                    if (interface_index >= self.program.interfaces.len or self.program.interfaces[interface_index].storage != .output) return error.InvalidStorage;
                    result = try readValue(instruction.ty, try findBinding(bindings, interface_index));
                },
                .access => {
                    const interface_index = instruction.operands[0];
                    if (interface_index >= self.program.interfaces.len) return error.InvalidOperand;
                    const interface = self.program.interfaces[interface_index];
                    if (interface.storage != .uniform and interface.storage != .output) return error.InvalidStorage;
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
                .fneg, .ineg, .bit_not, .logical_not => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    for (0..result.lanes()) |i| result.bits[i] = switch (instruction.op) {
                        .fneg => canonicalFloat(a.bits[i] ^ 0x80000000),
                        .ineg => 0 -% a.bits[i],
                        .bit_not => ~a.bits[i],
                        .logical_not => @intFromBool(a.bits[i] == 0),
                        else => unreachable,
                    };
                },
                .iadd, .isub, .imul, .bit_or, .bit_xor, .bit_and => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| result.bits[i] = switch (instruction.op) {
                        .iadd => a.bits[i] +% b.bits[i],
                        .isub => a.bits[i] -% b.bits[i],
                        .imul => a.bits[i] *% b.bits[i],
                        .bit_or => a.bits[i] | b.bits[i],
                        .bit_xor => a.bits[i] ^ b.bits[i],
                        .bit_and => a.bits[i] & b.bits[i],
                        else => unreachable,
                    };
                },
                .udiv, .sdiv, .umod, .srem, .smod => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| {
                        if (b.bits[i] == 0) return error.NumericDomain;
                        result.bits[i] = switch (instruction.op) {
                            .udiv => a.bits[i] / b.bits[i],
                            .umod => a.bits[i] % b.bits[i],
                            .sdiv => blk: {
                                const lhs: i32 = @bitCast(a.bits[i]);
                                const rhs: i32 = @bitCast(b.bits[i]);
                                if (lhs == std.math.minInt(i32) and rhs == -1) return error.NumericDomain;
                                break :blk @bitCast(@divTrunc(lhs, rhs));
                            },
                            .srem => blk: {
                                const lhs: i32 = @bitCast(a.bits[i]);
                                const rhs: i32 = @bitCast(b.bits[i]);
                                if (lhs == std.math.minInt(i32) and rhs == -1) return error.NumericDomain;
                                break :blk @bitCast(@rem(lhs, rhs));
                            },
                            .smod => blk: {
                                const lhs: i32 = @bitCast(a.bits[i]);
                                const rhs: i32 = @bitCast(b.bits[i]);
                                if (lhs == std.math.minInt(i32) and rhs == -1) return error.NumericDomain;
                                break :blk @bitCast(@mod(lhs, rhs));
                            },
                            else => unreachable,
                        };
                    }
                },
                .shl_logical, .shr_logical, .shr_arithmetic => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| {
                        if (b.bits[i] >= 32) return error.NumericDomain;
                        const amount: u5 = @intCast(b.bits[i]);
                        result.bits[i] = switch (instruction.op) {
                            .shl_logical => a.bits[i] << amount,
                            .shr_logical => a.bits[i] >> amount,
                            .shr_arithmetic => @bitCast(@as(i32, @bitCast(a.bits[i])) >> amount),
                            else => unreachable,
                        };
                    }
                },
                .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| {
                        const lhs = a.bits[i];
                        const rhs = b.bits[i];
                        result.bits[i] = @intFromBool(switch (instruction.op) {
                            .ieq => lhs == rhs,
                            .ine => lhs != rhs,
                            .ugt => lhs > rhs,
                            .uge => lhs >= rhs,
                            .ult => lhs < rhs,
                            .ule => lhs <= rhs,
                            .sgt => @as(i32, @bitCast(lhs)) > @as(i32, @bitCast(rhs)),
                            .sge => @as(i32, @bitCast(lhs)) >= @as(i32, @bitCast(rhs)),
                            .slt => @as(i32, @bitCast(lhs)) < @as(i32, @bitCast(rhs)),
                            .sle => @as(i32, @bitCast(lhs)) <= @as(i32, @bitCast(rhs)),
                            else => unreachable,
                        });
                    }
                },
                .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..result.lanes()) |i| {
                        const lhs: f32 = @bitCast(a.bits[i]);
                        const rhs: f32 = @bitCast(b.bits[i]);
                        const unordered = std.math.isNan(lhs) or std.math.isNan(rhs);
                        result.bits[i] = @intFromBool(switch (instruction.op) {
                            .ford_eq => !unordered and lhs == rhs,
                            .funord_eq => unordered or lhs == rhs,
                            .ford_ne => !unordered and lhs != rhs,
                            .funord_ne => unordered or lhs != rhs,
                            .ford_lt => !unordered and lhs < rhs,
                            .funord_lt => unordered or lhs < rhs,
                            .ford_gt => !unordered and lhs > rhs,
                            .funord_gt => unordered or lhs > rhs,
                            .ford_le => !unordered and lhs <= rhs,
                            .funord_le => unordered or lhs <= rhs,
                            .ford_ge => !unordered and lhs >= rhs,
                            .funord_ge => unordered or lhs >= rhs,
                            else => unreachable,
                        });
                    }
                },
                .logical_eq, .logical_ne, .logical_or, .logical_and => {
                    const a = try valueRef(self.values, pc, instruction.operands[0]);
                    const b = try valueRef(self.values, pc, instruction.operands[1]);
                    result.bits[0] = @intFromBool(switch (instruction.op) {
                        .logical_eq => a.bits[0] == b.bits[0],
                        .logical_ne => a.bits[0] != b.bits[0],
                        .logical_or => a.bits[0] != 0 or b.bits[0] != 0,
                        .logical_and => a.bits[0] != 0 and b.bits[0] != 0,
                        else => unreachable,
                    });
                },
                .fadd, .fsub, .fmul, .fdiv, .frem => {
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
                            .frem => blk: {
                                if (y == 0) return error.NumericDomain;
                                break :blk x - @trunc(x / y) * y;
                            },
                            else => unreachable,
                        };
                        result.bits[i] = canonicalFloat(@bitCast(z));
                    }
                },
                .select => {
                    const condition = try valueRef(self.values, pc, instruction.operands[0]);
                    const when_true = try valueRef(self.values, pc, instruction.operands[1]);
                    const when_false = try valueRef(self.values, pc, instruction.operands[2]);
                    if (condition.ty.scalar != .bool or condition.ty.columns != 1 or condition.ty.rows != 1 or !same(when_true.ty, when_false.ty) or !same(when_true.ty, instruction.ty)) return error.InvalidType;
                    result = if (condition.bits[0] != 0) when_true else when_false;
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
                .matrix_times_scalar => {
                    const matrix = try valueRef(self.values, pc, instruction.operands[0]);
                    const scalar: f32 = @bitCast((try valueRef(self.values, pc, instruction.operands[1])).bits[0]);
                    for (0..16) |i| result.bits[i] = canonicalFloat(@bitCast(@as(f32, @bitCast(matrix.bits[i])) * scalar));
                },
                .vector_times_matrix => {
                    const vector = try valueRef(self.values, pc, instruction.operands[0]);
                    const matrix = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..4) |col| {
                        var sum: f32 = 0;
                        for (0..4) |row| sum += @as(f32, @bitCast(vector.bits[row])) * @as(f32, @bitCast(matrix.bits[col * 4 + row]));
                        result.bits[col] = canonicalFloat(@bitCast(sum));
                    }
                },
                .matrix_times_matrix => {
                    const left = try valueRef(self.values, pc, instruction.operands[0]);
                    const right = try valueRef(self.values, pc, instruction.operands[1]);
                    for (0..4) |col| for (0..4) |row| {
                        var sum: f32 = 0;
                        for (0..4) |k| sum += @as(f32, @bitCast(left.bits[k * 4 + row])) * @as(f32, @bitCast(right.bits[col * 4 + k]));
                        result.bits[col * 4 + row] = canonicalFloat(@bitCast(sum));
                    };
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
            .input, .uniform, .storage => n == 1,
            .access => n >= 2 and n <= 3,
            .extract => n == 1 or n == 2,
            .shuffle => n == 2 + try lanes(instruction.ty),
            .fneg, .ineg, .bit_not, .logical_not, .convert => n == 1,
            .select => n == 3,
            .iadd, .isub, .imul, .bit_or, .bit_xor, .bit_and, .udiv, .sdiv, .umod, .srem, .smod, .shl_logical, .shr_logical, .shr_arithmetic, .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle, .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge, .logical_eq, .logical_ne, .logical_or, .logical_and, .fadd, .fsub, .fmul, .fdiv, .frem, .vector_times_scalar, .matrix_times_vector, .matrix_times_scalar, .vector_times_matrix, .matrix_times_matrix => n == 2,
            .output => n == 2,
        };
        if (!arity_ok) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.literal.len != (if (instruction.ty.scalar == .bool) 1 else try byteSize(instruction.ty))) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.ty.scalar == .bool and instruction.literal[0] > 1) return error.InvalidOperand;
        if (instruction.op == .constant and instruction.ty.scalar == .f32) for (0..try lanes(instruction.ty)) |i| if (!std.math.isFinite(@as(f32, @bitCast(std.mem.readInt(u32, instruction.literal[i * 4 ..][0..4], .little))))) return error.NumericDomain;
        if (instruction.op != .constant and instruction.literal.len != 0) return error.InvalidOperand;
        if (instruction.op == .input or instruction.op == .uniform or instruction.op == .storage) {
            const x = instruction.operands[0];
            const expected: ir.Storage = switch (instruction.op) {
                .input => .input,
                .uniform => .uniform,
                .storage => .output,
                else => unreachable,
            };
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
                .fneg, .ineg, .bit_not, .logical_not, .iadd, .isub, .imul, .bit_or, .bit_xor, .bit_and, .udiv, .sdiv, .umod, .srem, .smod, .shl_logical, .shr_logical, .shr_arithmetic, .fadd, .fsub, .fmul, .fdiv, .frem => if (!same(source_ty, instruction.ty)) return error.InvalidType,
                .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle => if (source_ty.scalar != .i32 and source_ty.scalar != .u32 or source_ty.columns != 1 or source_ty.rows != 1) return error.InvalidType,
                .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge => if (source_ty.scalar != .f32 or source_ty.columns != 1 or source_ty.rows != 1) return error.InvalidType,
                .logical_eq, .logical_ne, .logical_or, .logical_and => if (source_ty.scalar != .bool or source_ty.columns != 1 or source_ty.rows != 1) return error.InvalidType,
                .select => if (oi == 0) {
                    if (source_ty.scalar != .bool or try lanes(source_ty) != 1) return error.InvalidType;
                } else if (!same(source_ty, instruction.ty)) return error.InvalidType,
                .output => if (!same(source_ty, instruction.ty)) return error.InvalidType,
                .vector_times_scalar => if ((oi == 0 and !same(source_ty, instruction.ty)) or (oi == 1 and (source_ty.scalar != .f32 or try lanes(source_ty) != 1))) return error.InvalidType,
                .matrix_times_vector => if ((oi == 0 and !(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 4)) or (oi == 1 and !same(source_ty, instruction.ty))) return error.InvalidType,
                .matrix_times_scalar => if ((oi == 0 and (!(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 4) or !same(source_ty, instruction.ty))) or (oi == 1 and (source_ty.scalar != .f32 or try lanes(source_ty) != 1))) return error.InvalidType,
                .vector_times_matrix => if ((oi == 0 and (!(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 1) or !same(source_ty, instruction.ty))) or (oi == 1 and !(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 4))) return error.InvalidType,
                .matrix_times_matrix => if (!(source_ty.scalar == .f32 and source_ty.columns == 4 and source_ty.rows == 4) or !same(source_ty, instruction.ty)) return error.InvalidType,
                .convert => if (try lanes(source_ty) != try lanes(instruction.ty)) return error.InvalidShape,
                else => {},
            }
        };
        switch (instruction.op) {
            .access => {
                const interface_index = instruction.operands[0];
                if (interface_index >= program.interfaces.len or (program.interfaces[interface_index].storage != .uniform and program.interfaces[interface_index].storage != .output)) return error.InvalidStorage;
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
            .fneg, .fadd, .fsub, .fmul, .fdiv, .frem, .vector_times_scalar, .matrix_times_vector, .matrix_times_scalar, .vector_times_matrix, .matrix_times_matrix => if (instruction.ty.scalar != .f32) return error.InvalidType,
            .ineg => if (instruction.ty.scalar != .i32) return error.InvalidType,
            .bit_not, .bit_or, .bit_xor, .bit_and => if (instruction.ty.scalar != .i32 and instruction.ty.scalar != .u32) return error.InvalidType,
            .udiv, .umod => if (instruction.ty.scalar != .u32) return error.InvalidType,
            .sdiv, .srem, .smod => if (instruction.ty.scalar != .i32) return error.InvalidType,
            .shl_logical, .shr_logical => if (instruction.ty.scalar != .i32 and instruction.ty.scalar != .u32) return error.InvalidType,
            .shr_arithmetic => if (instruction.ty.scalar != .i32) return error.InvalidType,
            .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle => {
                if (instruction.ty.scalar != .bool or instruction.ty.columns != 1 or instruction.ty.rows != 1) return error.InvalidType;
                const left = program.instructions[instruction.operands[0]].ty;
                const right = program.instructions[instruction.operands[1]].ty;
                if (!same(left, right) or left.columns != 1 or left.rows != 1 or (left.scalar != .i32 and left.scalar != .u32)) return error.InvalidType;
                switch (instruction.op) {
                    .ugt, .uge, .ult, .ule => if (left.scalar != .u32) return error.InvalidType,
                    .sgt, .sge, .slt, .sle => if (left.scalar != .i32) return error.InvalidType,
                    else => {},
                }
            },
            .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge => {
                if (instruction.ty.scalar != .bool or instruction.ty.columns != 1 or instruction.ty.rows != 1) return error.InvalidType;
                const left = program.instructions[instruction.operands[0]].ty;
                const right = program.instructions[instruction.operands[1]].ty;
                if (!same(left, right) or left.scalar != .f32 or left.columns != 1 or left.rows != 1) return error.InvalidType;
            },
            .logical_eq, .logical_ne, .logical_or, .logical_and => {
                if (instruction.ty.scalar != .bool or instruction.ty.columns != 1 or instruction.ty.rows != 1) return error.InvalidType;
                const left = program.instructions[instruction.operands[0]].ty;
                const right = program.instructions[instruction.operands[1]].ty;
                if (!same(left, right) or left.scalar != .bool or left.columns != 1 or left.rows != 1) return error.InvalidType;
            },
            .logical_not => {
                if (instruction.ty.scalar != .bool or instruction.ty.columns != 1 or instruction.ty.rows != 1) return error.InvalidType;
                const source = program.instructions[instruction.operands[0]].ty;
                if (source.scalar != .bool or source.columns != 1 or source.rows != 1) return error.InvalidType;
            },
            .iadd, .isub, .imul => if (instruction.ty.scalar != .i32 and instruction.ty.scalar != .u32) return error.InvalidType,
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
        .constant, .input, .uniform, .storage => false,
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

test "storage-buffer access reads descriptor contents before transactional write" {
    const five = [_]u8{ 5, 0, 0, 0 };
    const zero = [_]u8{ 0, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 1, .block = true, .member_count = 1 }};
    interfaces[0].members[0] = .{ .ty = .{ .scalar = .u32 }, .offset = 0 };
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &five },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &zero },
        .{ .op = .access, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .iadd, .ty = .{ .scalar = .u32 }, .operands = &.{ 2, 0 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 3 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var storage = [_]u8{ 37, 0, 0, 0 };
    try executor.execute(&.{.{ .interface = 0, .bytes = &storage }}, &.{.{ .interface = 0, .bytes = &storage }});
    try std.testing.expectEqual(@as(u32, 42), std.mem.readInt(u32, &storage, .little));
    for (0..4096) |_| try executor.execute(&.{.{ .interface = 0, .bytes = &storage }}, &.{.{ .interface = 0, .bytes = &storage }});
    try std.testing.expectEqual(@as(u32, 42 + 4096 * 5), std.mem.readInt(u32, &storage, .little));
}

test "integer multiply is component-wise and wraps at 32 bits on the warm path" {
    const max = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    const three = [_]u8{ 3, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .u32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &max },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &three },
        .{ .op = .imul, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 2 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0xffff_fffd), std.mem.readInt(u32, &output, .little));
}

test "signed integer negation preserves two's-complement semantics" {
    const minimum = [_]u8{ 0, 0, 0, 0x80 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .i32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &minimum },
        .{ .op = .ineg, .ty = .{ .scalar = .i32 }, .operands = &.{0}, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0x8000_0000), std.mem.readInt(u32, &output, .little));
}

test "integer bitwise operations are component-wise and allocation-free when warm" {
    const left = [_]u8{ 0xf0, 0xf0, 0xf0, 0xf0 };
    const right = [_]u8{ 0xf0, 0x0f, 0xf0, 0x0f };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .u32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &left },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &right },
        .{ .op = .bit_and, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .bit_or, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .bit_xor, .ty = .{ .scalar = .u32 }, .operands = &.{ 2, 3 }, .literal = &.{} },
        .{ .op = .bit_not, .ty = .{ .scalar = .u32 }, .operands = &.{4}, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 5 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0x00ff_00ff), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0x00ff_00ff), std.mem.readInt(u32, &output, .little));
}

test "integer division and remainder honor signedness and reject zero divisors" {
    const signed_left = [_]u8{ 0xf9, 0xff, 0xff, 0xff }; // -7
    const signed_right = [_]u8{ 3, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .i32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &signed_left },
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &signed_right },
        .{ .op = .sdiv, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .srem, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .smod, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 4 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(i32, 2), @as(i32, @bitCast(std.mem.readInt(u32, &output, .little))));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(i32, 2), @as(i32, @bitCast(std.mem.readInt(u32, &output, .little))));

    var zero_instructions = instructions;
    zero_instructions[1].literal = &.{ 0, 0, 0, 0 };
    zero_instructions[5].operands = &.{ 0, 2 };
    var zero_source = try testProgram(&interfaces, &zero_instructions);
    defer std.testing.allocator.free(zero_source.bytes);
    var zero_executor = try Executor.init(std.testing.allocator, &zero_source);
    defer zero_executor.deinit();
    var sentinel = [_]u8{0xa5} ** 4;
    try std.testing.expectError(error.NumericDomain, zero_executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &sentinel }}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 4), &sentinel);
}

test "integer shifts preserve logical and arithmetic semantics with bounded amounts" {
    const bits = [_]u8{ 1, 0, 0, 0x80 };
    const minus_two = [_]u8{ 0xfe, 0xff, 0xff, 0xff };
    const one = [_]u8{ 1, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .i32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &bits },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &one },
        .{ .op = .shl_logical, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .shr_logical, .ty = .{ .scalar = .u32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &minus_two },
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &one },
        .{ .op = .shr_arithmetic, .ty = .{ .scalar = .i32 }, .operands = &.{ 4, 5 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .i32 }, .operands = &.{ 0, 6 }, .literal = &.{} },
    };
    // The output interface type is signed; the two logical-shift values are
    // still validated and executed before the final arithmetic result.
    interfaces[0].ty = .{ .scalar = .i32 };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), std.mem.readInt(u32, &output, .little));

    var out_of_range = instructions;
    const invalid_shift = [_]u8{ 32, 0, 0, 0 };
    out_of_range[1].literal = &invalid_shift;
    var range_source = try testProgram(&interfaces, &out_of_range);
    defer std.testing.allocator.free(range_source.bytes);
    var range_executor = try Executor.init(std.testing.allocator, &range_source);
    defer range_executor.deinit();
    var sentinel = [_]u8{0xa5} ** 4;
    try std.testing.expectError(error.NumericDomain, range_executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &sentinel }}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 4), &sentinel);
}

test "integer comparisons preserve signedness and boolean results on the warm path" {
    const unsigned_high = [_]u8{ 0xff, 0xff, 0xff, 0xff };
    const unsigned_one = [_]u8{ 1, 0, 0, 0 };
    const signed_negative = [_]u8{ 0xfe, 0xff, 0xff, 0xff };
    const signed_one = [_]u8{ 1, 0, 0, 0 };
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .bool }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &unsigned_high },
        .{ .op = .constant, .ty = .{ .scalar = .u32 }, .operands = &.{}, .literal = &unsigned_one },
        .{ .op = .ieq, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 0 }, .literal = &.{} },
        .{ .op = .ine, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ugt, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .uge, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ult, .ty = .{ .scalar = .bool }, .operands = &.{ 1, 0 }, .literal = &.{} },
        .{ .op = .ule, .ty = .{ .scalar = .bool }, .operands = &.{ 1, 0 }, .literal = &.{} },
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &signed_negative },
        .{ .op = .constant, .ty = .{ .scalar = .i32 }, .operands = &.{}, .literal = &signed_one },
        .{ .op = .sgt, .ty = .{ .scalar = .bool }, .operands = &.{ 8, 9 }, .literal = &.{} },
        .{ .op = .sge, .ty = .{ .scalar = .bool }, .operands = &.{ 8, 9 }, .literal = &.{} },
        .{ .op = .slt, .ty = .{ .scalar = .bool }, .operands = &.{ 8, 9 }, .literal = &.{} },
        .{ .op = .sle, .ty = .{ .scalar = .bool }, .operands = &.{ 8, 9 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 13 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &output, .little));
    try std.testing.expectEqual(@as(u32, 1), executor.values[2].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[3].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[4].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[5].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[6].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[7].bits[0]);
    try std.testing.expectEqual(@as(u32, 0), executor.values[10].bits[0]);
    try std.testing.expectEqual(@as(u32, 0), executor.values[11].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[12].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[13].bits[0]);
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &output, .little));
}

test "ordered and unordered float comparisons honor NaN domains" {
    const one = [_]u8{ 0, 0, 0x80, 0x3f };
    var interfaces = [_]ir.Interface{
        .{ .storage = .input, .ty = .{ .scalar = .f32 }, .location = 0 },
        .{ .storage = .output, .ty = .{ .scalar = .bool }, .location = 0 },
    };
    var instructions = [_]ir.Instruction{
        .{ .op = .input, .ty = .{ .scalar = .f32 }, .operands = &.{0}, .literal = &.{} },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &one },
        .{ .op = .ford_eq, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_eq, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ford_ne, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_ne, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ford_lt, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_lt, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ford_gt, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_gt, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ford_le, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_le, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .ford_ge, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .funord_ge, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .bool }, .operands = &.{ 1, 13 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var input = [_]u8{ 0, 0, 0xc0, 0x7f };
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{.{ .interface = 0, .bytes = &input }}, &.{.{ .interface = 1, .bytes = &output }});
    for ([_]usize{ 2, 4, 6, 8, 10, 12 }) |index| try std.testing.expectEqual(@as(u32, 0), executor.values[index].bits[0]);
    for ([_]usize{ 3, 5, 7, 9, 11, 13 }) |index| try std.testing.expectEqual(@as(u32, 1), executor.values[index].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{.{ .interface = 0, .bytes = &input }}, &.{.{ .interface = 1, .bytes = &output }});
}

test "boolean logical operations preserve scalar truth tables on the warm path" {
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .bool }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .bool }, .operands = &.{}, .literal = &.{1} },
        .{ .op = .constant, .ty = .{ .scalar = .bool }, .operands = &.{}, .literal = &.{0} },
        .{ .op = .logical_eq, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .logical_ne, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .logical_or, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .logical_and, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .logical_not, .ty = .{ .scalar = .bool }, .operands = &.{1}, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .bool }, .operands = &.{ 0, 3 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, 0), executor.values[2].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[3].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[4].bits[0]);
    try std.testing.expectEqual(@as(u32, 0), executor.values[5].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), executor.values[6].bits[0]);
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
}

test "floating remainder uses truncating quotient and rejects zero divisor" {
    const seven = f32bytes(7);
    const two = f32bytes(2);
    const zero = f32bytes(0);
    var interfaces = [_]ir.Interface{.{ .storage = .output, .ty = .{ .scalar = .f32 }, .location = 0 }};
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &seven },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &two },
        .{ .op = .frem, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = .{ .scalar = .f32 }, .operands = &.{ 0, 2 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var output = [_]u8{0} ** 4;
    try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});
    try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, 1))), std.mem.readInt(u32, &output, .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &output }});

    var invalid = instructions;
    invalid[1].literal = &zero;
    var invalid_source = try testProgram(&interfaces, &invalid);
    defer std.testing.allocator.free(invalid_source.bytes);
    var invalid_executor = try Executor.init(std.testing.allocator, &invalid_source);
    defer invalid_executor.deinit();
    var sentinel = [_]u8{0xa5} ** 4;
    try std.testing.expectError(error.NumericDomain, invalid_executor.execute(&.{}, &.{.{ .interface = 0, .bytes = &sentinel }}));
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 4), &sentinel);
}

test "four by four matrix arithmetic preserves column-major Vulkan semantics" {
    const matrix_ty = ir.Type{ .scalar = .f32, .columns = 4, .rows = 4 };
    const vector_ty = ir.Type{ .scalar = .f32, .columns = 4 };
    var matrix_a: [64]u8 = undefined;
    var matrix_identity: [64]u8 = .{0} ** 64;
    for (0..16) |i| std.mem.writeInt(u32, matrix_a[i * 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(i + 1))), .little);
    for (0..4) |diagonal| std.mem.writeInt(u32, matrix_identity[(diagonal * 4 + diagonal) * 4 ..][0..4], @bitCast(@as(f32, 1)), .little);
    const scalar = f32bytes(2);
    var vector: [16]u8 = undefined;
    for (0..4) |i| std.mem.writeInt(u32, vector[i * 4 ..][0..4], @bitCast(@as(f32, @floatFromInt(i + 1))), .little);
    var interfaces = [_]ir.Interface{
        .{ .storage = .output, .ty = matrix_ty, .location = 0 },
        .{ .storage = .output, .ty = vector_ty, .location = 1 },
        .{ .storage = .output, .ty = matrix_ty, .location = 2 },
    };
    var instructions = [_]ir.Instruction{
        .{ .op = .constant, .ty = matrix_ty, .operands = &.{}, .literal = &matrix_a },
        .{ .op = .constant, .ty = matrix_ty, .operands = &.{}, .literal = &matrix_identity },
        .{ .op = .constant, .ty = .{ .scalar = .f32 }, .operands = &.{}, .literal = &scalar },
        .{ .op = .constant, .ty = vector_ty, .operands = &.{}, .literal = &vector },
        .{ .op = .matrix_times_scalar, .ty = matrix_ty, .operands = &.{ 0, 2 }, .literal = &.{} },
        .{ .op = .vector_times_matrix, .ty = vector_ty, .operands = &.{ 3, 1 }, .literal = &.{} },
        .{ .op = .matrix_times_matrix, .ty = matrix_ty, .operands = &.{ 0, 1 }, .literal = &.{} },
        .{ .op = .output, .ty = matrix_ty, .operands = &.{ 0, 4 }, .literal = &.{} },
        .{ .op = .output, .ty = vector_ty, .operands = &.{ 1, 5 }, .literal = &.{} },
        .{ .op = .output, .ty = matrix_ty, .operands = &.{ 2, 6 }, .literal = &.{} },
    };
    var source = try testProgram(&interfaces, &instructions);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    var scaled: [64]u8 = undefined;
    var transformed: [16]u8 = undefined;
    var multiplied: [64]u8 = undefined;
    try executor.execute(&.{}, &.{ .{ .interface = 0, .bytes = &scaled }, .{ .interface = 1, .bytes = &transformed }, .{ .interface = 2, .bytes = &multiplied } });
    for (0..16) |i| {
        try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatFromInt((i + 1) * 2)))), std.mem.readInt(u32, scaled[i * 4 ..][0..4], .little));
        try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatFromInt(i + 1)))), std.mem.readInt(u32, multiplied[i * 4 ..][0..4], .little));
    }
    for (0..4) |i| try std.testing.expectEqual(@as(u32, @bitCast(@as(f32, @floatFromInt(i + 1)))), std.mem.readInt(u32, transformed[i * 4 ..][0..4], .little));
    for (0..4096) |_| try executor.execute(&.{}, &.{ .{ .interface = 0, .bytes = &scaled }, .{ .interface = 1, .bytes = &transformed }, .{ .interface = 2, .bytes = &multiplied } });
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
    const expected_clone_allocations: usize = 5;
    const expected_executor_clone_stage_failures: usize = 5;
    const expected_executor_later_allocations: usize = 2;
    const expected_executor_allocations: usize = expected_executor_clone_stage_failures + expected_executor_later_allocations;
    const expected_key_allocations: usize = 9;
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
    try std.testing.expectEqual(expected_clone_allocations, clone_probe.allocations);
    for (0..expected_clone_allocations) |fail_index| {
        var direct = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, source.clone(direct.allocator()));
        try std.testing.expectEqual(direct.allocated_bytes, direct.freed_bytes);
        try std.testing.expectEqual(direct.allocations, direct.deallocations);

        var through_init = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Executor.init(through_init.allocator(), &source));
        try std.testing.expectEqual(through_init.allocated_bytes, through_init.freed_bytes);
        try std.testing.expectEqual(through_init.allocations, through_init.deallocations);
    }
    var setup_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var complete = try Executor.init(setup_probe.allocator(), &source);
    complete.deinit();
    try std.testing.expectEqual(setup_probe.allocated_bytes, setup_probe.freed_bytes);
    try std.testing.expectEqual(setup_probe.allocations, setup_probe.deallocations);
    try std.testing.expectEqual(expected_executor_allocations, setup_probe.allocations);
    for (expected_executor_clone_stage_failures..expected_executor_allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, Executor.init(failing.allocator(), &source));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
    }
    var key_probe = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = std.math.maxInt(usize) });
    var key = try ExecutableKey.init(key_probe.allocator(), &source, .{ .isa = 0, .render_state = .{0} ** 32 });
    key.deinit(key_probe.allocator());
    try std.testing.expectEqual(key_probe.allocated_bytes, key_probe.freed_bytes);
    try std.testing.expectEqual(key_probe.allocations, key_probe.deallocations);
    try std.testing.expectEqual(expected_key_allocations, key_probe.allocations);
    for (0..expected_key_allocations) |fail_index| {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, ExecutableKey.init(failing.allocator(), &source, .{ .isa = 0, .render_state = .{0} ** 32 }));
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expectEqual(failing.allocations, failing.deallocations);
    }
    std.debug.print("allocation failure matrix: Program.clone={d} Executor.init.clone_stage={d} Executor.init.other={d} ExecutableKey={d} outstanding_allocations=0 outstanding_bytes=0\n", .{ expected_clone_allocations, expected_executor_clone_stage_failures, expected_executor_later_allocations, expected_key_allocations });
}

fn frontendOpcodeOffset(words: []const u32, opcode: u16, occurrence: usize) usize {
    var cursor: usize = 5;
    var seen: usize = 0;
    while (cursor < words.len) : (cursor += words[cursor] >> 16) if (@as(u16, @truncate(words[cursor])) == opcode) {
        if (seen == occurrence) return cursor;
        seen += 1;
    };
    return std.math.maxInt(usize);
}

fn frontendAccessVariant(allocator: std.mem.Allocator, width: u32, matrix: bool, member_count: u32, member_index: u32) ![]u32 {
    var words: std.ArrayList(u32) = .empty;
    try words.appendSlice(allocator, &frontend.uniform_vertex);
    const output_decoration = frontendOpcodeOffset(words.items, 71, 0);
    words.items[output_decoration + 2] = 30; // Location replaces BuiltIn.
    words.items[frontendOpcodeOffset(words.items, 23, 0) + 3] = width;
    const member_type: u32 = if (matrix) 8 else 7;
    if (matrix) {
        const structure = frontendOpcodeOffset(words.items, 30, 0);
        try words.insertSlice(allocator, structure, &.{ (4 << 16) | 24, 8, 7, 4 });
        words.items[frontendOpcodeOffset(words.items, 30, 0) + 2] = member_type;
        words.items[frontendOpcodeOffset(words.items, 32, 0) + 3] = member_type;
        words.items[frontendOpcodeOffset(words.items, 32, 2) + 3] = member_type;
        words.items[frontendOpcodeOffset(words.items, 61, 0) + 1] = member_type;
    }
    if (member_count == 2) {
        const structure = frontendOpcodeOffset(words.items, 30, 0);
        try words.insertSlice(allocator, structure + 3, &.{member_type});
        words.items[structure] += 1 << 16;
        const first_member_decoration = frontendOpcodeOffset(words.items, 72, 0);
        try words.insertSlice(allocator, first_member_decoration + 5, &.{ (5 << 16) | 72, 12, 1, 35, 64 });
    }
    words.items[frontendOpcodeOffset(words.items, 43, 0) + 3] = member_index;
    return words.toOwnedSlice(allocator);
}

fn frontendDynamicAccessVariant(allocator: std.mem.Allocator, constant_words: []const u32) ![]u32 {
    var words: std.ArrayList(u32) = .empty;
    try words.appendSlice(allocator, constant_words);
    const access = frontendOpcodeOffset(words.items, 65, 0);
    try words.insertSlice(allocator, access, &.{ (5 << 16) | 128, 3, 44, 20, 20 });
    words.items[frontendOpcodeOffset(words.items, 65, 0) + 4] = 44;
    return words.toOwnedSlice(allocator);
}

test "generated profile v1 constant access admissions initialize executor and dynamic indices stop at frontend" {
    const expected_constant_admissions: usize = 12;
    const expected_dynamic_rejections: usize = 12;
    var constant_admissions: usize = 0;
    var dynamic_rejections: usize = 0;
    try std.testing.expectEqual(std.math.maxInt(usize), frontendOpcodeOffset(&frontend.uniform_vertex, 999, 0));
    for ([_]struct { width: u32, matrix: bool }{ .{ .width = 2, .matrix = false }, .{ .width = 3, .matrix = false }, .{ .width = 4, .matrix = false }, .{ .width = 4, .matrix = true } }) |composite| {
        for ([_][2]u32{ .{ 1, 0 }, .{ 2, 0 }, .{ 2, 1 } }) |member_case| {
            const words = try frontendAccessVariant(std.testing.allocator, composite.width, composite.matrix, member_case[0], member_case[1]);
            defer std.testing.allocator.free(words);
            var program = try frontend.compile(std.testing.allocator, words, .vertex, "main", &.{});
            defer program.deinit(std.testing.allocator);
            var access_seen: usize = 0;
            for (program.instructions) |instruction| if (instruction.op == .access) {
                access_seen += 1;
                for (instruction.operands[1..]) |index_id| {
                    try std.testing.expectEqual(ir.Op.constant, program.instructions[index_id].op);
                    try std.testing.expectEqual(ir.Type{ .scalar = .u32 }, program.instructions[index_id].ty);
                    try std.testing.expectEqual(member_case[1], std.mem.readInt(u32, program.instructions[index_id].literal[0..4], .little));
                }
            };
            try std.testing.expectEqual(@as(usize, 1), access_seen);
            try std.testing.expectEqual(@as(u3, @intCast(composite.width)), program.instructions[1].ty.columns);
            try std.testing.expectEqual(@as(u3, if (composite.matrix) 4 else 1), program.instructions[1].ty.rows);
            var executor = try Executor.init(std.testing.allocator, &program);
            executor.deinit();
            constant_admissions += 1;

            const dynamic = try frontendDynamicAccessVariant(std.testing.allocator, words);
            defer std.testing.allocator.free(dynamic);
            try std.testing.expectError(error.Unsupported, frontend.compile(std.testing.allocator, dynamic, .vertex, "main", &.{}));
            dynamic_rejections += 1;
        }
    }
    try std.testing.expectEqual(expected_constant_admissions, constant_admissions);
    try std.testing.expectEqual(expected_dynamic_rejections, dynamic_rejections);
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

fn runPropertyCase(op: ir.Op, result_ty: ir.Type, source_ty_override: ?ir.Type, convert_from: ?ir.Scalar) !void {
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
        .input, .uniform, .storage => {
            interfaces[0] = .{ .storage = if (op == .input) .input else .uniform, .ty = result_ty, .location = if (op == .input) 0 else null, .descriptor_set = if (op == .uniform) 0 else null, .binding = if (op == .uniform) 0 else null, .block = op == .uniform, .member_count = if (op == .uniform) 1 else 0 };
            if (op == .storage) interfaces[0] = .{ .storage = .output, .ty = result_ty, .descriptor_set = 0, .binding = 0 };
            if (op == .uniform) interfaces[0].members[0] = .{ .ty = result_ty, .offset = 0 };
            interface_count = 1;
            bindings[0] = .{ .interface = 0, .bytes = input_bytes[0..try byteSize(result_ty)] };
            binding_count = 1;
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{0}, &.{});
            if (op == .storage) {
                outputs[0] = .{ .interface = 0, .bytes = output_bytes[0..try byteSize(result_ty)] };
                output_count = 1;
            }
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
            const source_ty = source_ty_override orelse return error.InvalidType;
            const source = try propertyConstant(arena, &instructions, source_ty);
            const selector: u32 = source_ty.columns - 1;
            result_id = try propertyInstruction(arena, &instructions, .extract, result_ty, &.{ source, selector }, &.{});
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
        .select => {
            const condition = try propertyConstant(arena, &instructions, .{ .scalar = .bool });
            const when_true = try propertyConstant(arena, &instructions, result_ty);
            const when_false = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, .select, result_ty, &.{ condition, when_true, when_false }, &.{});
        },
        .fneg, .ineg, .bit_not, .convert => {
            var source_ty = result_ty;
            if (convert_from) |scalar| source_ty.scalar = scalar;
            const source = try propertyConstant(arena, &instructions, source_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{source}, &.{});
        },
        .iadd, .isub, .imul, .bit_or, .bit_xor, .bit_and, .udiv, .sdiv, .umod, .srem, .smod, .shl_logical, .shr_logical, .shr_arithmetic, .fadd, .fsub, .fmul, .fdiv, .frem => {
            const a = try propertyConstant(arena, &instructions, result_ty);
            const b = try propertyConstant(arena, &instructions, result_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ a, b }, &.{});
        },
        .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle => {
            const source_scalar: ir.Scalar = switch (op) {
                .sgt, .sge, .slt, .sle => .i32,
                else => .u32,
            };
            const source_ty = ir.Type{ .scalar = source_scalar };
            const a = try propertyConstant(arena, &instructions, source_ty);
            const b = try propertyConstant(arena, &instructions, source_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ a, b }, &.{});
        },
        .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge => {
            const source_ty = ir.Type{ .scalar = .f32 };
            const a = try propertyConstant(arena, &instructions, source_ty);
            const b = try propertyConstant(arena, &instructions, source_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ a, b }, &.{});
        },
        .logical_eq, .logical_ne, .logical_or, .logical_and => {
            const source_ty = ir.Type{ .scalar = .bool };
            const a = try propertyConstant(arena, &instructions, source_ty);
            const b = try propertyConstant(arena, &instructions, source_ty);
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ a, b }, &.{});
        },
        .logical_not => {
            const source = try propertyConstant(arena, &instructions, .{ .scalar = .bool });
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{source}, &.{});
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
        .matrix_times_scalar => {
            const matrix = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4, .rows = 4 });
            const scalar = try propertyConstant(arena, &instructions, .{ .scalar = .f32 });
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ matrix, scalar }, &.{});
        },
        .vector_times_matrix => {
            const vector = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4 });
            const matrix = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4, .rows = 4 });
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ vector, matrix }, &.{});
        },
        .matrix_times_matrix => {
            const left = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4, .rows = 4 });
            const right = try propertyConstant(arena, &instructions, .{ .scalar = .f32, .columns = 4, .rows = 4 });
            result_id = try propertyInstruction(arena, &instructions, op, result_ty, &.{ left, right }, &.{});
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
    try std.testing.expectEqual(op, instructions.items[result_id].op);
    try std.testing.expectEqual(result_ty, instructions.items[result_id].ty);
    if (op == .extract) {
        const source_ty = source_ty_override.?;
        try std.testing.expect(source_ty.rows == 1 and source_ty.columns >= 2 and source_ty.columns <= 4);
        try std.testing.expectEqual(ir.Type{ .scalar = source_ty.scalar }, result_ty);
        try std.testing.expectEqual(@as(usize, 2), instructions.items[result_id].operands.len);
        try std.testing.expectEqual(@as(u32, source_ty.columns - 1), instructions.items[result_id].operands[1]);
    }
    var source = try testProgram(interfaces[0..interface_count], instructions.items);
    defer std.testing.allocator.free(source.bytes);
    var executor = try Executor.init(std.testing.allocator, &source);
    defer executor.deinit();
    try executor.execute(bindings[0..binding_count], outputs[0..output_count]);
    const first = executor.values[result_id];
    try std.testing.expectEqual(result_ty, first.ty);
    try std.testing.expectEqual(try lanes(result_ty), first.lanes());
    if (op == .extract) {
        const expected_bits: u32 = if (result_ty.scalar == .f32) @bitCast(@as(f32, 1)) else 1;
        try std.testing.expectEqual(expected_bits, first.bits[0]);
    }
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
        inline for ([_]ir.Op{ .constant, .input, .uniform, .storage, .access, .output }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        }
        if (is_numeric and (is_vector or ty.rows == 4)) inline for ([_]ir.Op{ .constant_composite, .composite }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_non_matrix) {
            try runPropertyCase(.shuffle, ty, null, null);
            totals[@intFromEnum(ir.Op.shuffle)] += 1;
        }
        if (is_float) inline for ([_]ir.Op{ .fneg, .fadd, .fsub, .fmul, .fdiv, .frem }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_integer) inline for ([_]ir.Op{ .iadd, .isub, .imul }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (ty.scalar == .i32) {
            try runPropertyCase(.ineg, ty, null, null);
            totals[@intFromEnum(ir.Op.ineg)] += 1;
        }
        if (is_integer) inline for ([_]ir.Op{ .bit_or, .bit_xor, .bit_and }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_integer) {
            try runPropertyCase(.bit_not, ty, null, null);
            totals[@intFromEnum(ir.Op.bit_not)] += 1;
        }
        if (ty.scalar == .u32) inline for ([_]ir.Op{ .udiv, .umod }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (ty.scalar == .i32) inline for ([_]ir.Op{ .sdiv, .srem, .smod }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (is_integer) inline for ([_]ir.Op{ .shl_logical, .shr_logical }) |op| {
            try runPropertyCase(op, ty, null, null);
            totals[@intFromEnum(op)] += 1;
        };
        if (ty.scalar == .i32) {
            try runPropertyCase(.shr_arithmetic, ty, null, null);
            totals[@intFromEnum(ir.Op.shr_arithmetic)] += 1;
        }
        if (is_float and is_vector) {
            try runPropertyCase(.vector_times_scalar, ty, null, null);
            totals[@intFromEnum(ir.Op.vector_times_scalar)] += 1;
        }
        if (is_numeric and is_non_matrix) for ([_]ir.Scalar{ .i32, .u32, .f32 }) |from| if (from != ty.scalar) {
            try runPropertyCase(.convert, ty, null, from);
            totals[@intFromEnum(ir.Op.convert)] += 1;
        };
    }
    for (property_types) |source_ty| if (source_ty.scalar != .bool and source_ty.rows == 1 and source_ty.columns > 1) {
        try runPropertyCase(.extract, .{ .scalar = source_ty.scalar }, source_ty, null);
        totals[@intFromEnum(ir.Op.extract)] += 1;
    };
    try runPropertyCase(.matrix_times_vector, .{ .scalar = .f32, .columns = 4 }, null, null);
    totals[@intFromEnum(ir.Op.matrix_times_vector)] += 1;
    try runPropertyCase(.matrix_times_scalar, .{ .scalar = .f32, .columns = 4, .rows = 4 }, null, null);
    totals[@intFromEnum(ir.Op.matrix_times_scalar)] += 1;
    try runPropertyCase(.vector_times_matrix, .{ .scalar = .f32, .columns = 4 }, null, null);
    totals[@intFromEnum(ir.Op.vector_times_matrix)] += 1;
    try runPropertyCase(.matrix_times_matrix, .{ .scalar = .f32, .columns = 4, .rows = 4 }, null, null);
    totals[@intFromEnum(ir.Op.matrix_times_matrix)] += 1;
    try runPropertyCase(.select, .{ .scalar = .u32 }, null, null);
    totals[@intFromEnum(ir.Op.select)] += 1;
    inline for ([_]ir.Op{ .ieq, .ine, .ugt, .uge, .ult, .ule, .sgt, .sge, .slt, .sle }) |op| {
        try runPropertyCase(op, .{ .scalar = .bool }, null, null);
        totals[@intFromEnum(op)] += 1;
    }
    inline for ([_]ir.Op{ .ford_eq, .funord_eq, .ford_ne, .funord_ne, .ford_lt, .funord_lt, .ford_gt, .funord_gt, .ford_le, .funord_le, .ford_ge, .funord_ge }) |op| {
        try runPropertyCase(op, .{ .scalar = .bool }, null, null);
        totals[@intFromEnum(op)] += 1;
    }
    inline for ([_]ir.Op{ .logical_eq, .logical_ne, .logical_or, .logical_and, .logical_not }) |op| {
        try runPropertyCase(op, .{ .scalar = .bool }, null, null);
        totals[@intFromEnum(op)] += 1;
    }
    const expected = [_]usize{ 14, 10, 14, 14, 14, 10, 9, 13, 5, 8, 8, 5, 5, 5, 5, 3, 1, 24, 14, 1, 14, 8, 4, 8, 8, 8, 8, 4, 4, 4, 4, 4, 8, 8, 4, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
    const expected_full = expected ++ [_]usize{1} ** 4 ++ [_]usize{5} ++ [_]usize{1} ** 3;
    try std.testing.expectEqualSlices(usize, expected_full[0..totals.len], &totals);
    var total: usize = 0;
    for (totals) |count| {
        try std.testing.expect(count > 0);
        total += count;
    }
    try std.testing.expectEqual(@as(usize, 315), total);
    std.debug.print("generated property matrix: operations=66 type_families=scalar+vec2+vec3+vec4+mat4 valid={d} per_operation={any}\n", .{ total, totals });
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
    try std.testing.expectEqual(@as(usize, 66), malformed);
    try std.testing.expectEqual(@as(usize, 41), bounds);
    try std.testing.expectEqual(@as(usize, 14), aliases);
    try std.testing.expectEqual(@as(usize, 4), rollback);
    try std.testing.expectEqual(@as(usize, 5), runtime_nan);
    try std.testing.expectEqual(@as(usize, 5), signed_zero);
    std.debug.print("generated property categories: malformed=66 bounds=41 aliases=14 rollback_after_late_failure=4 runtime_nan=5 signed_zero=5\n", .{});
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

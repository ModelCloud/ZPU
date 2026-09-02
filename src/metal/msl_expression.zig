// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Allocation-free lowering and execution for the portable Float32 MSL
//! expression profile.  The bytecode is copied into ZPU's deferred CPU
//! command stream; it never contains or calls an Apple Metal object.

const std = @import("std");

pub const version: u32 = 1;
pub const max_instructions: usize = 48;

pub const Op = enum(u8) {
    input = 1,
    constant,
    negate,
    add,
    subtract,
    multiply,
    divide,
    absolute,
    floor,
    ceil,
    round,
    trunc,
    fract,
    sin,
    cos,
    tan,
    asin,
    acos,
    atan,
    sinh,
    cosh,
    tanh,
    exp,
    exp2,
    log,
    log2,
    sqrt,
    rsqrt,
    pow,
    minimum,
    maximum,
    fma,
    clamp,
    mix,
};

pub const Instruction = extern struct {
    op: u8 = 0,
    a: u8 = 0,
    b: u8 = 0,
    c: u8 = 0,
    immediate: f32 = 0,
};

pub const Program = extern struct {
    version: u32 = 0,
    instruction_count: u32 = 0,
    element_limit: u32 = 0,
    output_value: u8 = 0,
    input_count: u8 = 0,
    reserved: [2]u8 = .{ 0, 0 },
    instructions: [max_instructions]Instruction = [_]Instruction{.{}} ** max_instructions,
};

comptime {
    if (@sizeOf(Instruction) != 8 or @sizeOf(Program) != 400) {
        @compileError("Float32 expression ABI layout changed");
    }
}

pub const CompileError = error{
    InvalidExpression,
    ProgramTooLarge,
};

const Parser = struct {
    source: []const u8,
    cursor: usize = 0,
    program: *Program,

    fn parse(self: *Parser) CompileError!void {
        const result = try self.parseAdditive();
        if (self.cursor != self.source.len) return error.InvalidExpression;
        self.program.output_value = result;
    }

    fn parseAdditive(self: *Parser) CompileError!u8 {
        var left = try self.parseMultiplicative();
        while (self.cursor < self.source.len) {
            const op: Op = switch (self.source[self.cursor]) {
                '+' => .add,
                '-' => .subtract,
                else => break,
            };
            self.cursor += 1;
            const right = try self.parseMultiplicative();
            left = try self.emit(op, left, right, 0, 0);
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) CompileError!u8 {
        var left = try self.parseUnary();
        while (self.cursor < self.source.len) {
            const op: Op = switch (self.source[self.cursor]) {
                '*' => .multiply,
                '/' => .divide,
                else => break,
            };
            self.cursor += 1;
            const right = try self.parseUnary();
            left = try self.emit(op, left, right, 0, 0);
        }
        return left;
    }

    fn parseUnary(self: *Parser) CompileError!u8 {
        if (self.consume('-')) {
            return self.emit(.negate, try self.parseUnary(), 0, 0, 0);
        }
        if (self.consume('+')) return self.parseUnary();
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Parser) CompileError!u8 {
        if (self.consume('(')) {
            const value = try self.parseAdditive();
            if (!self.consume(')')) return error.InvalidExpression;
            return value;
        }
        if (self.cursor >= self.source.len) return error.InvalidExpression;
        if ((self.source[self.cursor] == 'x' or self.source[self.cursor] == 'y') and
            (self.cursor + 1 == self.source.len or !identifierCharacter(self.source[self.cursor + 1])))
        {
            const input_index: u8 = if (self.source[self.cursor] == 'x') 0 else 1;
            self.cursor += 1;
            self.program.input_count = @max(self.program.input_count, input_index + 1);
            return self.emit(.input, input_index, 0, 0, 0);
        }
        if (digit(self.source[self.cursor]) or self.source[self.cursor] == '.') return self.parseNumber();
        if (identifierStart(self.source[self.cursor])) return self.parseCall();
        return error.InvalidExpression;
    }

    fn parseNumber(self: *Parser) CompileError!u8 {
        const start = self.cursor;
        var saw_digit = false;
        while (self.cursor < self.source.len and digit(self.source[self.cursor])) : (self.cursor += 1) saw_digit = true;
        if (self.consume('.')) {
            while (self.cursor < self.source.len and digit(self.source[self.cursor])) : (self.cursor += 1) saw_digit = true;
        }
        if (!saw_digit) return error.InvalidExpression;
        if (self.cursor < self.source.len and (self.source[self.cursor] == 'e' or self.source[self.cursor] == 'E')) {
            self.cursor += 1;
            if (self.cursor < self.source.len and (self.source[self.cursor] == '+' or self.source[self.cursor] == '-')) self.cursor += 1;
            const exponent_start = self.cursor;
            while (self.cursor < self.source.len and digit(self.source[self.cursor])) : (self.cursor += 1) {}
            if (self.cursor == exponent_start) return error.InvalidExpression;
        }
        const number_end = self.cursor;
        if (self.cursor < self.source.len and (self.source[self.cursor] == 'f' or self.source[self.cursor] == 'F')) self.cursor += 1;
        const value = std.fmt.parseFloat(f32, self.source[start..number_end]) catch return error.InvalidExpression;
        return self.emit(.constant, 0, 0, 0, value);
    }

    fn parseCall(self: *Parser) CompileError!u8 {
        const start = self.cursor;
        self.cursor += 1;
        while (self.cursor < self.source.len and identifierCharacter(self.source[self.cursor])) self.cursor += 1;
        const name = self.source[start..self.cursor];
        if (!self.consume('(')) return error.InvalidExpression;
        const a = try self.parseAdditive();
        var b: u8 = 0;
        var c: u8 = 0;
        var arity: u8 = 1;
        if (self.consume(',')) {
            b = try self.parseAdditive();
            arity = 2;
            if (self.consume(',')) {
                c = try self.parseAdditive();
                arity = 3;
            }
        }
        if (!self.consume(')')) return error.InvalidExpression;
        const function = functionOp(name, arity) orelse return error.InvalidExpression;
        return self.emit(function, a, b, c, 0);
    }

    fn consume(self: *Parser, byte: u8) bool {
        if (self.cursor >= self.source.len or self.source[self.cursor] != byte) return false;
        self.cursor += 1;
        return true;
    }

    fn emit(self: *Parser, op: Op, a: u8, b: u8, c: u8, immediate: f32) CompileError!u8 {
        const index = self.program.instruction_count;
        if (index >= max_instructions or index > std.math.maxInt(u8)) return error.ProgramTooLarge;
        self.program.instructions[index] = .{
            .op = @intFromEnum(op),
            .a = a,
            .b = b,
            .c = c,
            .immediate = immediate,
        };
        self.program.instruction_count += 1;
        return @intCast(index);
    }
};

fn digit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn identifierStart(byte: u8) bool {
    return (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or byte == '_';
}

fn identifierCharacter(byte: u8) bool {
    return identifierStart(byte) or digit(byte);
}

fn functionOp(name: []const u8, arity: u8) ?Op {
    if (arity == 1) {
        const unary = .{
            .{ "abs", Op.absolute }, .{ "floor", Op.floor }, .{ "ceil", Op.ceil },
            .{ "round", Op.round },  .{ "trunc", Op.trunc }, .{ "fract", Op.fract },
            .{ "sin", Op.sin },      .{ "cos", Op.cos },     .{ "tan", Op.tan },
            .{ "asin", Op.asin },    .{ "acos", Op.acos },   .{ "atan", Op.atan },
            .{ "sinh", Op.sinh },    .{ "cosh", Op.cosh },   .{ "tanh", Op.tanh },
            .{ "exp", Op.exp },      .{ "exp2", Op.exp2 },   .{ "log", Op.log },
            .{ "log2", Op.log2 },    .{ "sqrt", Op.sqrt },   .{ "rsqrt", Op.rsqrt },
        };
        inline for (unary) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    } else if (arity == 2) {
        const binary = .{
            .{ "pow", Op.pow }, .{ "min", Op.minimum }, .{ "max", Op.maximum },
        };
        inline for (binary) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    } else if (arity == 3) {
        const ternary = .{
            .{ "fma", Op.fma }, .{ "clamp", Op.clamp }, .{ "mix", Op.mix },
        };
        inline for (ternary) |entry| if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

pub fn compile(source: []const u8, element_limit: u32, output: *Program) CompileError!void {
    return compileWithInputCount(source, element_limit, 1, output);
}

pub fn compileWithInputCount(source: []const u8, element_limit: u32, input_count: u8, output: *Program) CompileError!void {
    output.* = .{};
    if (source.len == 0 or element_limit == 0 or input_count == 0 or input_count > 2) return error.InvalidExpression;
    output.version = version;
    output.element_limit = element_limit;
    var parser = Parser{ .source = source, .program = output };
    parser.parse() catch |err| {
        output.* = .{};
        return err;
    };
    if (output.input_count > input_count) {
        output.* = .{};
        return error.InvalidExpression;
    }
    output.input_count = input_count;
}

pub fn validate(program: *const Program) bool {
    if (program.version != version or program.element_limit == 0 or
        program.input_count == 0 or program.input_count > 2 or
        program.instruction_count == 0 or program.instruction_count > max_instructions or
        program.output_value >= program.instruction_count) return false;
    for (program.instructions[0..program.instruction_count], 0..) |instruction, index| {
        if (instruction.op < @intFromEnum(Op.input) or instruction.op > @intFromEnum(Op.mix)) return false;
        const op: Op = @enumFromInt(instruction.op);
        if (op == .input and instruction.a >= program.input_count) return false;
        const unary = switch (op) {
            .negate, .absolute, .floor, .ceil, .round, .trunc, .fract, .sin, .cos, .tan, .asin, .acos, .atan, .sinh, .cosh, .tanh, .exp, .exp2, .log, .log2, .sqrt, .rsqrt => true,
            else => false,
        };
        const binary = switch (op) {
            .add, .subtract, .multiply, .divide, .pow, .minimum, .maximum => true,
            else => false,
        };
        const ternary = switch (op) {
            .fma, .clamp, .mix => true,
            else => false,
        };
        if ((unary or binary or ternary) and instruction.a >= index) return false;
        if ((binary or ternary) and instruction.b >= index) return false;
        if (ternary and instruction.c >= index) return false;
    }
    return true;
}

pub fn evaluate(program: *const Program, input: f32) error{InvalidProgram}!f32 {
    return evaluateInputs(program, .{ input, 0 });
}

pub fn evaluateInputs(program: *const Program, inputs: [2]f32) error{InvalidProgram}!f32 {
    if (!validate(program)) return error.InvalidProgram;
    var values = [_]f32{0} ** max_instructions;
    for (program.instructions[0..program.instruction_count], 0..) |instruction, index| {
        const op: Op = @enumFromInt(instruction.op);
        const a = values[instruction.a];
        const b = values[instruction.b];
        const c = values[instruction.c];
        values[index] = switch (op) {
            .input => inputs[instruction.a],
            .constant => instruction.immediate,
            .negate => -a,
            .add => a + b,
            .subtract => a - b,
            .multiply => a * b,
            .divide => a / b,
            .absolute => @abs(a),
            .floor => @floor(a),
            .ceil => @ceil(a),
            .round => @round(a),
            .trunc => @trunc(a),
            .fract => a - @floor(a),
            .sin => @sin(a),
            .cos => @cos(a),
            .tan => @tan(a),
            .asin => std.math.asin(a),
            .acos => std.math.acos(a),
            .atan => std.math.atan(a),
            .sinh => std.math.sinh(a),
            .cosh => std.math.cosh(a),
            .tanh => std.math.tanh(a),
            .exp => std.math.exp(a),
            .exp2 => std.math.exp2(a),
            .log => @log(a),
            .log2 => @log2(a),
            .sqrt => @sqrt(a),
            .rsqrt => 1.0 / @sqrt(a),
            .pow => std.math.pow(f32, a, b),
            .minimum => @min(a, b),
            .maximum => @max(a, b),
            .fma => @mulAdd(f32, a, b, c),
            .clamp => @min(@max(a, b), c),
            .mix => a + (b - a) * c,
        };
    }
    return values[program.output_value];
}

test "composed expression compiles and evaluates without allocation" {
    var program: Program = .{};
    try compile("sin(x)*0.5+cos(x)", 12, &program);
    try std.testing.expect(validate(&program));
    try std.testing.expectApproxEqAbs(@sin(@as(f32, 0.75)) * 0.5 + @cos(@as(f32, 0.75)), try evaluate(&program, 0.75), 0.000001);
}

test "two-input expression preserves explicit input arity" {
    var program: Program = .{};
    try compileWithInputCount("fma(x,y,0.25)", 8, 2, &program);
    try std.testing.expectEqual(@as(u8, 2), program.input_count);
    try std.testing.expectApproxEqAbs(@as(f32, -5.75), try evaluateInputs(&program, .{ 2.0, -3.0 }), 0.000001);
    try std.testing.expectError(error.InvalidExpression, compileWithInputCount("x+y", 8, 1, &program));
}

test "malformed and oversized expressions fail closed" {
    var program: Program = .{};
    try std.testing.expectError(error.InvalidExpression, compile("sin(x)+unknown(x)", 12, &program));
    try std.testing.expectEqual(@as(u32, 0), program.version);
    try std.testing.expectError(error.InvalidExpression, compile("x;output[0]=1", 12, &program));
    try std.testing.expectError(error.ProgramTooLarge, compile("sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(sin(x)))))))))))))))))))))))))))))))))))))))))))))))))", 12, &program));
}

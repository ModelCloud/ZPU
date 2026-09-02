// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Portable CPU tensor execution contracts for ZPU CPU/ZML integrations.
//!
//! Optional adapters may consume this ABI, but this module deliberately knows
//! nothing about Metal, Foundation, or the host operating system. It accepts
//! raw storage views so a ZML CPU backend can be inserted without changing a
//! caller's layout or lifetime semantics. The reference implementation is
//! also the exact-layout fallback for views that cannot be represented by a
//! dense compiler buffer.

const builtin = @import("builtin");
const std = @import("std");

pub const max_rank: usize = 16;
pub const max_inputs: usize = 2;
pub const max_named_inputs: usize = 16;
pub const max_named_outputs: usize = 16;

pub const CpuArchitecture = enum(u32) {
    unknown = 0,
    arm64 = 1,
    x86_64 = 2,
};

pub const cpu_feature_advsimd: u32 = 1 << 0;
pub const cpu_feature_avx: u32 = 1 << 1;
pub const cpu_feature_avx2: u32 = 1 << 2;

/// Return the architecture selected when this artifact was compiled. This is
/// intentionally not a runtime host probe: a ZML bridge owns runtime CPU
/// checks and remains free to select scalar, AdvSIMD/NEON, or AVX code paths.
pub fn compiledCpuArch() CpuArchitecture {
    return switch (builtin.cpu.arch) {
        .aarch64 => .arm64,
        .x86_64 => .x86_64,
        else => .unknown,
    };
}

/// Return ISA features enabled in this artifact's compile target. No
/// platform headers, OS calls, or Metal/PJRT dependencies are involved.
pub fn compiledCpuFeatures() u32 {
    return switch (builtin.cpu.arch) {
        .aarch64 => if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.aarch64.Feature.neon)))
            cpu_feature_advsimd
        else
            0,
        .x86_64 => blk: {
            var features: u32 = 0;
            if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx))) {
                features |= cpu_feature_avx;
            }
            if (builtin.cpu.features.isEnabled(@intFromEnum(std.Target.x86.Feature.avx2))) {
                features |= cpu_feature_avx2;
            }
            break :blk features;
        },
        else => 0,
    };
}

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = -1,
    unsupported = -2,
    out_of_memory = -3,
};

/// A tensor view whose strides are measured in logical elements.  For 4-bit
/// tensors, each element occupies one nibble and `offset_bytes` points to the
/// first backing byte; the element parity selects the low or high nibble.
pub const TensorView = extern struct {
    data: ?[*]u8,
    byte_length: usize,
    offset_bytes: usize,
    rank: u32,
    element_bits: u32,
    dimensions: [max_rank]usize,
    strides: [max_rank]usize,
};

/// `permutation[output_axis]` names the source axis used by that output axis.
/// This is the same convention used by StableHLO transpose and by the ZPU
/// render-IR transpose implementation.
pub const TransposeArguments = extern struct {
    source: TensorView,
    destination: TensorView,
    permutation: [max_rank]u32,
};

/// Versioned optional CPU provider ABI.  The callback is deliberately
/// operation-specific for now: it gives a future ZML bridge a small, stable
/// insertion point without pretending that arbitrary ML graphs are already
/// supported by this layer.
pub const backend_abi_version: u32 = 1;
pub const TransposeFn = *const fn (
    context: ?*anyopaque,
    arguments: *const TransposeArguments,
) callconv(.c) c_int;
pub const Backend = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    transpose: ?TransposeFn,
};

pub const Operation = enum(u32) {
    identity = 1,
    transpose = 2,
    add = 3,
    subtract = 4,
    divide = 5,
    multiply = 6,
    matmul = 7,
};

pub const ElementType = enum(u32) {
    float32 = 1,
    float16 = 2,
    bfloat16 = 3,
    int8 = 4,
    uint8 = 5,
    int16 = 6,
    uint16 = 7,
    int32 = 8,
    uint32 = 9,
    int4 = 10,
    uint4 = 11,
};

pub const OperationArguments = extern struct {
    operation: u32,
    element_type: u32,
    input_count: u32,
    reserved: u32,
    inputs: [max_inputs]TensorView,
    destination: TensorView,
    permutation: [max_rank]u32,
};

pub const OperationFn = *const fn (
    context: ?*anyopaque,
    arguments: *const OperationArguments,
) callconv(.c) c_int;
pub const OperationBackend = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    operation: ?OperationFn,
};
pub const operation_backend_abi_version: u32 = 1;

/// Signature advertised by a named CPU provider. The provider owns the
/// graph/function and may use any CPU implementation or ISA it supports.
pub const NamedOperationSignature = extern struct {
    input_count: u32,
    element_type: u32,
};

pub const NamedOperationArguments = extern struct {
    function_name: ?[*]const u8,
    function_name_length: usize,
    input_count: u32,
    element_type: u32,
    reserved: u32,
    inputs: [max_inputs]TensorView,
    destination: TensorView,
    permutation: [max_rank]u32,
};

pub const NamedOperationQueryFn = *const fn (
    context: ?*anyopaque,
    function_name: [*]const u8,
    function_name_length: usize,
    signature: *NamedOperationSignature,
) callconv(.c) c_int;
pub const NamedOperationFn = *const fn (
    context: ?*anyopaque,
    arguments: *const NamedOperationArguments,
) callconv(.c) c_int;
pub const NamedOperationBackend = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    query: ?NamedOperationQueryFn,
    operation: ?NamedOperationFn,
};
pub const named_operation_backend_abi_version: u32 = 1;

/// Additive named-provider ABI for graph entry points with more than two
/// inputs.  The pointed arrays and tensor storage are borrowed only for the
/// duration of the callback.  Keeping this separate from the v1 inline-array
/// structure preserves binary compatibility for existing providers.
pub const NamedOperationArgumentsV2 = extern struct {
    function_name: ?[*]const u8,
    function_name_length: usize,
    input_count: u32,
    element_type: u32,
    reserved: u32,
    inputs: ?[*]const TensorView,
    destination: TensorView,
    permutation: ?[*]const u32,
};
pub const NamedOperationV2Fn = *const fn (
    context: ?*anyopaque,
    arguments: *const NamedOperationArgumentsV2,
) callconv(.c) c_int;
pub const NamedOperationBackendV2 = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    query: ?NamedOperationQueryFn,
    operation: ?NamedOperationV2Fn,
};
pub const named_operation_backend_v2_abi_version: u32 = 2;

/// Additive named-provider ABI for graph functions with multiple outputs or
/// per-binding element types. The older named ABIs remain source and binary
/// compatible for providers that do not need this metadata.
pub const NamedOperationSignatureV3 = extern struct {
    input_count: u32,
    output_count: u32,
    input_element_types: [max_named_inputs]u32,
    output_element_types: [max_named_outputs]u32,
};

pub const NamedOperationQueryV3Fn = *const fn (
    context: ?*anyopaque,
    function_name: [*]const u8,
    function_name_length: usize,
    signature: *NamedOperationSignatureV3,
) callconv(.c) c_int;

pub const NamedOperationArgumentsV3 = extern struct {
    function_name: ?[*]const u8,
    function_name_length: usize,
    input_count: u32,
    output_count: u32,
    reserved: u32,
    inputs: ?[*]const TensorView,
    input_element_types: ?[*]const u32,
    outputs: ?[*]TensorView,
    output_element_types: ?[*]const u32,
    permutation: ?[*]const u32,
};
pub const NamedOperationV3Fn = *const fn (
    context: ?*anyopaque,
    arguments: *const NamedOperationArgumentsV3,
) callconv(.c) c_int;
pub const NamedOperationBackendV3 = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    query: ?NamedOperationQueryV3Fn,
    operation: ?NamedOperationV3Fn,
};
pub const named_operation_backend_v3_abi_version: u32 = 3;

/// Optional discovery callback for the named provider. The returned name is
/// borrowed until the next catalog callback or catalog replacement; the caller
/// copies it if it needs to retain it. Signatures are obtained through the
/// provider query callback.
pub const NamedOperationNameFn = *const fn (
    context: ?*anyopaque,
    index: usize,
    function_name: *?[*]const u8,
    function_name_length: *usize,
) callconv(.c) c_int;
pub const NamedOperationCatalog = extern struct {
    abi_version: u32,
    context: ?*anyopaque,
    count: usize,
    name_at: ?NamedOperationNameFn,
};
pub const named_operation_catalog_abi_version: u32 = 1;

var backend_mutex: std.atomic.Mutex = .unlocked;
var registered_backend: ?Backend = null;
var registered_operation_backend: ?OperationBackend = null;
var registered_named_operation_backend: ?NamedOperationBackend = null;
var registered_named_operation_backend_v2: ?NamedOperationBackendV2 = null;
var registered_named_operation_backend_v3: ?NamedOperationBackendV3 = null;
var registered_named_operation_catalog: ?NamedOperationCatalog = null;

fn lockBackend() void {
    while (!backend_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn backendSnapshot() ?Backend {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_backend;
}

fn operationBackendSnapshot() ?OperationBackend {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_operation_backend;
}

fn namedOperationBackendSnapshot() ?NamedOperationBackend {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_named_operation_backend;
}

fn namedOperationBackendV2Snapshot() ?NamedOperationBackendV2 {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_named_operation_backend_v2;
}

fn namedOperationBackendV3Snapshot() ?NamedOperationBackendV3 {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_named_operation_backend_v3;
}

fn namedOperationCatalogSnapshot() ?NamedOperationCatalog {
    lockBackend();
    defer backend_mutex.unlock();
    return registered_named_operation_catalog;
}

fn checkedAdd(a: usize, b: usize) ?usize {
    if (b > std.math.maxInt(usize) - a) return null;
    return a + b;
}

fn checkedMul(a: usize, b: usize) ?usize {
    if (a != 0 and b > std.math.maxInt(usize) / a) return null;
    return a * b;
}

fn elementByteSize(bits: u32) ?usize {
    return switch (bits) {
        4, 8 => 1,
        16 => 2,
        32 => 4,
        else => null,
    };
}

const ViewInfo = struct {
    rank: usize,
    element_bits: u32,
    element_bytes: usize,
    element_count: usize,
    span_bytes: usize,
};

fn validateView(view: *const TensorView) ?ViewInfo {
    const data = view.data orelse return null;
    _ = data;
    const rank: usize = view.rank;
    if (rank > max_rank) return null;
    const element_bytes = elementByteSize(view.element_bits) orelse return null;

    var element_count: usize = 1;
    var max_element: usize = 0;
    for (0..rank) |axis| {
        const dimension = view.dimensions[axis];
        const stride = view.strides[axis];
        if (dimension == 0 or stride == 0) return null;
        element_count = checkedMul(element_count, dimension) orelse return null;
        const tail = checkedMul(dimension - 1, stride) orelse return null;
        max_element = checkedAdd(max_element, tail) orelse return null;
    }

    const span_bytes = if (view.element_bits == 4)
        (max_element / 2) + 1
    else blk: {
        const last = checkedMul(max_element, element_bytes) orelse return null;
        break :blk checkedAdd(last, element_bytes) orelse return null;
    };
    const end = checkedAdd(view.offset_bytes, span_bytes) orelse return null;
    if (end > view.byte_length) return null;

    return .{
        .rank = rank,
        .element_bits = view.element_bits,
        .element_bytes = element_bytes,
        .element_count = element_count,
        .span_bytes = span_bytes,
    };
}

fn validatePermutation(arguments: *const TransposeArguments, source: ViewInfo, destination: ViewInfo) bool {
    if (source.rank != destination.rank or source.element_bits != destination.element_bits) return false;
    var seen: [max_rank]bool = @splat(false);
    for (0..source.rank) |output_axis| {
        const source_axis: usize = arguments.permutation[output_axis];
        if (source_axis >= source.rank or seen[source_axis]) return false;
        seen[source_axis] = true;
        if (destination_rank_dimension(arguments, output_axis) != source_dimension(arguments, source_axis)) return false;
    }
    return true;
}

fn source_dimension(arguments: *const TransposeArguments, axis: usize) usize {
    return arguments.source.dimensions[axis];
}

fn destination_rank_dimension(arguments: *const TransposeArguments, axis: usize) usize {
    return arguments.destination.dimensions[axis];
}

fn logicalElementOffset(view: *const TensorView, coordinates: []const usize) ?usize {
    var element: usize = 0;
    for (coordinates, 0..) |coordinate, axis| {
        const product = checkedMul(coordinate, view.strides[axis]) orelse return null;
        element = checkedAdd(element, product) orelse return null;
    }
    return element;
}

fn byteOffset(view: *const TensorView, info: ViewInfo, element: usize) ?usize {
    if (info.element_bits == 4) return checkedAdd(view.offset_bytes, element / 2);
    const byte_element = checkedMul(element, info.element_bytes) orelse return null;
    return checkedAdd(view.offset_bytes, byte_element);
}

fn readNibble(view: *const TensorView, info: ViewInfo, element: usize) ?u8 {
    const offset = byteOffset(view, info, element) orelse return null;
    const data = view.data orelse return null;
    if (offset >= view.byte_length) return null;
    return (data[offset] >> @as(u3, @intCast((element & 1) * 4))) & 0x0f;
}

fn writeNibble(view: *const TensorView, info: ViewInfo, element: usize, value: u8) bool {
    const offset = byteOffset(view, info, element) orelse return false;
    const data = view.data orelse return false;
    if (offset >= view.byte_length) return false;
    const shift: u3 = @intCast((element & 1) * 4);
    const mask: u8 = @as(u8, 0x0f) << shift;
    data[offset] = (data[offset] & ~mask) | ((value & 0x0f) << shift);
    return true;
}

fn copyElement(source: *const TensorView, source_info: ViewInfo, source_element: usize, destination: *const TensorView, destination_info: ViewInfo, destination_element: usize) bool {
    if (source_info.element_bits == 4) {
        const value = readNibble(source, source_info, source_element) orelse return false;
        return writeNibble(destination, destination_info, destination_element, value);
    }
    const source_offset = byteOffset(source, source_info, source_element) orelse return false;
    const destination_offset = byteOffset(destination, destination_info, destination_element) orelse return false;
    const source_data = source.data orelse return false;
    const destination_data = destination.data orelse return false;
    if (source_offset > source.byte_length - source_info.element_bytes or
        destination_offset > destination.byte_length - destination_info.element_bytes) return false;
    @memcpy(destination_data[destination_offset .. destination_offset + destination_info.element_bytes], source_data[source_offset .. source_offset + source_info.element_bytes]);
    return true;
}

fn storageRange(view: *const TensorView, info: ViewInfo) ?struct { start: usize, end: usize } {
    const data = view.data orelse return null;
    const base = @intFromPtr(data);
    const start = checkedAdd(base, view.offset_bytes) orelse return null;
    const end = checkedAdd(start, info.span_bytes) orelse return null;
    return .{ .start = start, .end = end };
}

fn rangesOverlap(source: *const TensorView, source_info: ViewInfo, destination: *const TensorView, destination_info: ViewInfo) bool {
    const source_range = storageRange(source, source_info) orelse return true;
    const destination_range = storageRange(destination, destination_info) orelse return true;
    return source_range.start < destination_range.end and destination_range.start < source_range.end;
}

fn denseStrides(dimensions: []const usize, strides: *[max_rank]usize) void {
    var stride: usize = 1;
    for (dimensions, 0..) |dimension, axis| {
        strides[axis] = stride;
        stride = checkedMul(stride, dimension) orelse 0;
    }
}

fn copySourceToDense(source: *const TensorView, source_info: ViewInfo, dense: []u8) bool {
    const dense_bytes_per_element = if (source_info.element_bits == 4) 1 else source_info.element_bytes;
    const expected_bytes = if (source_info.element_bits == 4)
        (source_info.element_count + 1) / 2
    else
        checkedMul(source_info.element_count, dense_bytes_per_element) orelse return false;
    if (dense.len < expected_bytes) return false;

    var coordinates: [max_rank]usize = @splat(0);
    var dense_view: TensorView = std.mem.zeroes(TensorView);
    dense_view.data = dense.ptr;
    dense_view.byte_length = dense.len;
    dense_view.rank = @intCast(source_info.rank);
    dense_view.element_bits = source_info.element_bits;
    for (0..source_info.rank) |axis| dense_view.dimensions[axis] = source.dimensions[axis];
    denseStrides(source.dimensions[0..source_info.rank], &dense_view.strides);
    for (0..source_info.element_count) |element| {
        const source_element = logicalElementOffset(source, coordinates[0..source_info.rank]) orelse return false;
        if (!copyElement(source, source_info, source_element, &dense_view, source_info, element)) return false;
        incrementCoordinates(&coordinates, source.dimensions[0..source_info.rank]);
    }
    return true;
}

fn denseByteCount(info: ViewInfo) ?usize {
    if (info.element_bits == 4) return info.element_count / 2 + info.element_count % 2;
    return checkedMul(info.element_count, info.element_bytes);
}

fn makeDenseView(template: TensorView, info: ViewInfo, storage: []u8) TensorView {
    var view: TensorView = std.mem.zeroes(TensorView);
    view.data = storage.ptr;
    view.byte_length = storage.len;
    view.rank = @intCast(info.rank);
    view.element_bits = info.element_bits;
    for (0..info.rank) |axis| view.dimensions[axis] = template.dimensions[axis];
    denseStrides(template.dimensions[0..info.rank], &view.strides);
    return view;
}

fn copyDenseToDestination(dense: *const TensorView, dense_info: ViewInfo, destination: *const TensorView, destination_info: ViewInfo) bool {
    var output_coordinates: [max_rank]usize = @splat(0);
    for (0..destination_info.element_count) |element| {
        const destination_element = logicalElementOffset(destination, output_coordinates[0..destination_info.rank]) orelse return false;
        if (!copyElement(dense, dense_info, element, destination, destination_info, destination_element)) {
            return false;
        }
        incrementCoordinates(&output_coordinates, destination.dimensions[0..destination_info.rank]);
    }
    return true;
}

fn providerStatus(raw: c_int) Status {
    return switch (raw) {
        @intFromEnum(Status.ok) => .ok,
        @intFromEnum(Status.invalid_argument) => .invalid_argument,
        @intFromEnum(Status.unsupported) => .unsupported,
        @intFromEnum(Status.out_of_memory) => .out_of_memory,
        else => .invalid_argument,
    };
}

fn operationInputCount(kind: Operation) ?usize {
    return switch (kind) {
        .identity, .transpose => 1,
        .add, .subtract, .divide, .multiply, .matmul => 2,
    };
}

fn operationFromRaw(raw: u32) ?Operation {
    return switch (raw) {
        @intFromEnum(Operation.identity) => .identity,
        @intFromEnum(Operation.transpose) => .transpose,
        @intFromEnum(Operation.add) => .add,
        @intFromEnum(Operation.subtract) => .subtract,
        @intFromEnum(Operation.divide) => .divide,
        @intFromEnum(Operation.multiply) => .multiply,
        @intFromEnum(Operation.matmul) => .matmul,
        else => null,
    };
}

fn elementTypeFromRaw(raw: u32) ?ElementType {
    return switch (raw) {
        @intFromEnum(ElementType.float32) => .float32,
        @intFromEnum(ElementType.float16) => .float16,
        @intFromEnum(ElementType.bfloat16) => .bfloat16,
        @intFromEnum(ElementType.int8) => .int8,
        @intFromEnum(ElementType.uint8) => .uint8,
        @intFromEnum(ElementType.int16) => .int16,
        @intFromEnum(ElementType.uint16) => .uint16,
        @intFromEnum(ElementType.int32) => .int32,
        @intFromEnum(ElementType.uint32) => .uint32,
        @intFromEnum(ElementType.int4) => .int4,
        @intFromEnum(ElementType.uint4) => .uint4,
        else => null,
    };
}

fn elementBitsForType(element_type: ElementType) u32 {
    return switch (element_type) {
        .float32, .int32, .uint32 => 32,
        .float16, .bfloat16, .int16, .uint16 => 16,
        .int8, .uint8 => 8,
        .int4, .uint4 => 4,
    };
}

fn validateTypedView(view: *const TensorView, element_type: ElementType) ?ViewInfo {
    const info = validateView(view) orelse return null;
    if (info.element_bits != elementBitsForType(element_type)) return null;
    return info;
}

fn sameShape(left: *const TensorView, right: *const TensorView) bool {
    if (left.rank != right.rank) return false;
    const rank: usize = left.rank;
    for (0..rank) |axis| {
        if (left.dimensions[axis] != right.dimensions[axis]) return false;
    }
    return true;
}

fn readElementBits(view: *const TensorView, info: ViewInfo, element: usize) ?u64 {
    if (info.element_bits == 4) {
        const value = readNibble(view, info, element) orelse return null;
        return value;
    }
    const offset = byteOffset(view, info, element) orelse return null;
    const data = view.data orelse return null;
    if (offset > view.byte_length or info.element_bytes > view.byte_length - offset) return null;
    var value: u64 = 0;
    for (0..info.element_bytes) |byte| {
        value |= @as(u64, data[offset + byte]) << @as(u6, @intCast(byte * 8));
    }
    return value;
}

fn writeElementBits(view: *const TensorView, info: ViewInfo, element: usize, value: u64) bool {
    if (info.element_bits == 4) return writeNibble(view, info, element, @truncate(value));
    const offset = byteOffset(view, info, element) orelse return false;
    const data = view.data orelse return false;
    if (offset > view.byte_length or info.element_bytes > view.byte_length - offset) return false;
    for (0..info.element_bytes) |byte| {
        data[offset + byte] = @truncate(value >> @as(u6, @intCast(byte * 8)));
    }
    return true;
}

fn f32FromBits(value: u64) f32 {
    return @bitCast(@as(u32, @truncate(value)));
}

fn f32ToBits(value: f32) u64 {
    return @as(u64, @as(u32, @bitCast(value)));
}

fn f16FromBits(value: u64) f16 {
    return @bitCast(@as(u16, @truncate(value)));
}

fn f16ToBits(value: f16) u64 {
    return @as(u64, @as(u16, @bitCast(value)));
}

fn bfloat16FromBits(value: u64) f32 {
    const bits: u32 = @as(u32, @truncate(value)) << 16;
    return @bitCast(bits);
}

fn bfloat16ToBits(value: f32) u64 {
    const bits: u32 = @bitCast(value);
    const rounded = bits +% (0x7fff + ((bits >> 16) & 1));
    return @as(u64, rounded >> 16);
}

fn binaryElement(operation_kind: Operation, element_type: ElementType, left: u64, right: u64) ?u64 {
    switch (element_type) {
        .float32 => {
            const left_value = f32FromBits(left);
            const right_value = f32FromBits(right);
            const result = switch (operation_kind) {
                .add => left_value + right_value,
                .subtract => left_value - right_value,
                .divide => left_value / right_value,
                .multiply => left_value * right_value,
                else => return null,
            };
            return f32ToBits(result);
        },
        .float16 => {
            const left_value = f16FromBits(left);
            const right_value = f16FromBits(right);
            const result: f16 = switch (operation_kind) {
                .add => left_value + right_value,
                .subtract => left_value - right_value,
                .multiply => left_value * right_value,
                .divide => left_value / right_value,
                else => return null,
            };
            return f16ToBits(result);
        },
        .bfloat16 => {
            const left_value = bfloat16FromBits(left);
            const right_value = bfloat16FromBits(right);
            const result = switch (operation_kind) {
                .add => left_value + right_value,
                .subtract => left_value - right_value,
                .multiply => left_value * right_value,
                .divide => left_value / right_value,
                else => return null,
            };
            return bfloat16ToBits(result);
        },
        .int4, .uint4, .int8, .uint8, .int16, .uint16, .int32, .uint32 => {
            if (operation_kind == .divide) return null;
            const bits = elementBitsForType(element_type);
            const mask = (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
            return switch (operation_kind) {
                .add => (left +% right) & mask,
                .subtract => (left -% right) & mask,
                .multiply => (left *% right) & mask,
                else => null,
            };
        },
    }
}

fn referenceOperation(operation_kind: Operation, element_type: ElementType, arguments: *const OperationArguments, input_info: [max_inputs]?ViewInfo, dense_inputs: [max_inputs]TensorView, dense_destination: TensorView, destination_info: ViewInfo) Status {
    const source_info = input_info[0] orelse return .invalid_argument;
    var output = dense_destination;

    switch (operation_kind) {
        .identity => {
            if (!sameShape(&arguments.inputs[0], &arguments.destination)) return .invalid_argument;
            if (!copyDenseToDestination(&dense_inputs[0], source_info, &arguments.destination, destination_info)) {
                return .invalid_argument;
            }
            return .ok;
        },
        .transpose => {
            var transpose_arguments = TransposeArguments{
                .source = dense_inputs[0],
                .destination = output,
                .permutation = arguments.permutation,
            };
            const status = referenceTranspose(&transpose_arguments);
            if (status != .ok) return status;
            if (!copyDenseToDestination(&output, destination_info, &arguments.destination, destination_info)) {
                return .invalid_argument;
            }
            return .ok;
        },
        .add, .subtract, .divide, .multiply => {
            if (!sameShape(&arguments.inputs[0], &arguments.inputs[1]) or
                !sameShape(&arguments.inputs[0], &arguments.destination)) return .invalid_argument;
            const right_info = input_info[1] orelse return .invalid_argument;
            for (0..source_info.element_count) |element| {
                const left_value = readElementBits(&dense_inputs[0], source_info, element) orelse return .invalid_argument;
                const right_value = readElementBits(&dense_inputs[1], right_info, element) orelse return .invalid_argument;
                const result = binaryElement(operation_kind, element_type, left_value, right_value) orelse return .unsupported;
                if (!writeElementBits(&output, destination_info, element, result)) return .invalid_argument;
            }
            if (!copyDenseToDestination(&output, destination_info, &arguments.destination, destination_info)) {
                return .invalid_argument;
            }
            return .ok;
        },
        .matmul => {
            const right_info = input_info[1] orelse return .invalid_argument;
            if (source_info.rank != 2 or right_info.rank != 2 or destination_info.rank != 2 or
                arguments.inputs[0].dimensions[1] != arguments.inputs[1].dimensions[0] or
                arguments.destination.dimensions[0] != arguments.inputs[0].dimensions[0] or
                arguments.destination.dimensions[1] != arguments.inputs[1].dimensions[1])
            {
                return .invalid_argument;
            }
            const rows = arguments.inputs[0].dimensions[0];
            const reduction = arguments.inputs[0].dimensions[1];
            const columns = arguments.inputs[1].dimensions[1];
            for (0..rows) |row| {
                for (0..columns) |column| {
                    var result: u64 = 0;
                    switch (element_type) {
                        .float32 => {
                            var sum: f32 = 0;
                            for (0..reduction) |index| {
                                const left_value = readElementBits(&dense_inputs[0], source_info, row * reduction + index) orelse return .invalid_argument;
                                const right_value = readElementBits(&dense_inputs[1], right_info, index * columns + column) orelse return .invalid_argument;
                                sum = @mulAdd(f32, f32FromBits(left_value), f32FromBits(right_value), sum);
                            }
                            result = f32ToBits(sum);
                        },
                        .float16 => {
                            var sum: f16 = 0;
                            for (0..reduction) |index| {
                                const left_value = readElementBits(&dense_inputs[0], source_info, row * reduction + index) orelse return .invalid_argument;
                                const right_value = readElementBits(&dense_inputs[1], right_info, index * columns + column) orelse return .invalid_argument;
                                sum = @mulAdd(f16, f16FromBits(left_value), f16FromBits(right_value), sum);
                            }
                            result = f16ToBits(sum);
                        },
                        .bfloat16 => {
                            var sum: f32 = 0;
                            for (0..reduction) |index| {
                                const left_value = readElementBits(&dense_inputs[0], source_info, row * reduction + index) orelse return .invalid_argument;
                                const right_value = readElementBits(&dense_inputs[1], right_info, index * columns + column) orelse return .invalid_argument;
                                sum += bfloat16FromBits(left_value) * bfloat16FromBits(right_value);
                            }
                            result = bfloat16ToBits(sum);
                        },
                        .int4, .uint4, .int8, .uint8, .int16, .uint16, .int32, .uint32 => {
                            const bits = elementBitsForType(element_type);
                            const mask = (@as(u64, 1) << @as(u6, @intCast(bits))) - 1;
                            var sum: u64 = 0;
                            for (0..reduction) |index| {
                                const left_value = readElementBits(&dense_inputs[0], source_info, row * reduction + index) orelse return .invalid_argument;
                                const right_value = readElementBits(&dense_inputs[1], right_info, index * columns + column) orelse return .invalid_argument;
                                sum = (sum +% ((left_value & mask) *% (right_value & mask))) & mask;
                            }
                            result = sum;
                        },
                    }
                    const output_element = row * columns + column;
                    if (!writeElementBits(&output, destination_info, output_element, result)) return .invalid_argument;
                }
            }
            if (!copyDenseToDestination(&output, destination_info, &arguments.destination, destination_info)) {
                return .invalid_argument;
            }
            return .ok;
        },
    }
}

/// Stage an operation's raw ZPU views into dense CPU views for the optional
/// ZML/cpu provider. The provider never sees an Apple resource or an
/// Apple-specific tensor layout. A successful provider call is scattered back
/// into the original destination only after the callback returns successfully.
pub fn operation(arguments: *const OperationArguments) Status {
    const operation_kind = operationFromRaw(arguments.operation) orelse return .invalid_argument;
    const element_type = elementTypeFromRaw(arguments.element_type) orelse return .invalid_argument;
    const expected_inputs = operationInputCount(operation_kind) orelse return .invalid_argument;
    if (arguments.input_count != expected_inputs or arguments.reserved != 0) return .invalid_argument;

    var input_info: [max_inputs]?ViewInfo = @splat(null);
    var input_storage: [max_inputs]?[]u8 = @splat(null);
    defer for (&input_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_inputs: [max_inputs]TensorView = undefined;
    for (0..expected_inputs) |index| {
        input_info[index] = validateTypedView(&arguments.inputs[index], element_type) orelse return .invalid_argument;
        const info = input_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        input_storage[index] = storage;
        @memset(storage, 0);
        if (!copySourceToDense(&arguments.inputs[index], info, storage)) return .invalid_argument;
        dense_inputs[index] = makeDenseView(arguments.inputs[index], info, storage);
    }

    const destination_info = validateTypedView(&arguments.destination, element_type) orelse return .invalid_argument;

    // Preserve the original, specialized transpose-provider ABI when a
    // caller reaches this operation entry point. The generic operation
    // provider is intentionally a separate extension; without this bridge a
    // legacy transpose provider would be hidden by the exact reference path
    // below and Metal-shaped transpose dispatches could not reach ZML/cpu.
    if (operation_kind == .transpose) {
        var transpose_arguments = TransposeArguments{
            .source = arguments.inputs[0],
            .destination = arguments.destination,
            .permutation = arguments.permutation,
        };
        if (!validatePermutation(&transpose_arguments, input_info[0].?, destination_info)) {
            return .invalid_argument;
        }
        if (tryProvider(&transpose_arguments, input_info[0].?, destination_info)) |status| {
            if (status != .unsupported) return status;
        }
    }

    const destination_bytes = denseByteCount(destination_info) orelse return .invalid_argument;

    // Validate the complete portable ABI before looking for an optional
    // provider. A malformed call must have the same result whether a ZML/cpu
    // provider is installed or not; `unsupported` is reserved for a valid
    // operation/type combination for which this portable layer has no
    // reference implementation.
    const destination_storage = std.heap.c_allocator.alloc(u8, destination_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(destination_storage);
    @memset(destination_storage, 0);
    const dense_destination = makeDenseView(arguments.destination, destination_info, destination_storage);
    var dense_arguments = OperationArguments{
        .operation = arguments.operation,
        .element_type = arguments.element_type,
        .input_count = arguments.input_count,
        .reserved = 0,
        .inputs = dense_inputs,
        .destination = dense_destination,
        .permutation = arguments.permutation,
    };
    if (operationBackendSnapshot()) |backend| {
        const callback = backend.operation orelse return .unsupported;
        const status = providerStatus(callback(backend.context, &dense_arguments));
        if (status != .unsupported) {
            if (status != .ok) return status;
            if (!std.meta.eql(dense_arguments.destination, dense_destination)) return .invalid_argument;
            const validated_dense_destination = validateView(&dense_destination) orelse return .invalid_argument;
            if (!copyDenseToDestination(&dense_destination, validated_dense_destination, &arguments.destination, destination_info)) return .invalid_argument;
            return .ok;
        }
    }
    return referenceOperation(operation_kind, element_type, arguments, input_info, dense_inputs, dense_destination, destination_info);
}

fn validNamedOperationName(name: ?[*]const u8, length: usize) bool {
    return name != null and length != 0;
}

/// Ask the registered provider whether a named CPU graph/function is
/// available. The caller owns the returned signature storage.
pub fn namedOperationSupported(name: []const u8, signature: *NamedOperationSignature) Status {
    if (name.len == 0) return .invalid_argument;
    const v2_backend = namedOperationBackendV2Snapshot();
    const status = if (v2_backend) |backend| blk: {
        const callback = backend.query orelse break :blk Status.unsupported;
        break :blk providerStatus(callback(backend.context, name.ptr, name.len, signature));
    } else if (namedOperationBackendSnapshot()) |backend| blk: {
        const callback = backend.query orelse break :blk Status.unsupported;
        break :blk providerStatus(callback(backend.context, name.ptr, name.len, signature));
    } else return .unsupported;
    if (status != .ok) return status;
    const input_limit = if (v2_backend != null) max_named_inputs else max_inputs;
    if (signature.input_count == 0 or signature.input_count > input_limit or
        elementTypeFromRaw(signature.element_type) == null) return .invalid_argument;
    return .ok;
}

pub fn namedOperationCount() usize {
    const catalog = namedOperationCatalogSnapshot() orelse return 0;
    return catalog.count;
}

/// Return one provider-owned function name for library discovery. The name is
/// valid until the next catalog callback or catalog replacement; callers must
/// copy it when retaining it in an object graph.
pub fn namedOperationNameAt(index: usize, name: *?[*]const u8, length: *usize) Status {
    name.* = null;
    length.* = 0;
    const catalog = namedOperationCatalogSnapshot() orelse return .unsupported;
    if (index >= catalog.count) return .invalid_argument;
    const callback = catalog.name_at orelse return .unsupported;
    const status = providerStatus(callback(catalog.context, index, name, length));
    if (status != .ok) return status;
    if (name.* == null or length.* == 0) return .invalid_argument;
    return .ok;
}

/// Stage a named provider operation through the same dense CPU boundary used
/// by fixed operations. The provider receives the function name and no ZPU,
/// Metal, or platform-specific storage/layout object. `argument_capacity`
/// preserves the v1 inline-array limit while allowing v2 pointer arguments to
/// carry a larger graph input list.
fn namedOperationWithViews(
    function_name: [*]const u8,
    function_name_length: usize,
    input_count: u32,
    element_type: u32,
    inputs: [*]const TensorView,
    destination: *const TensorView,
    permutation: [*]const u32,
    argument_capacity: usize,
) Status {
    if (!validNamedOperationName(function_name, function_name_length) or
        input_count == 0 or input_count > max_named_inputs or input_count > argument_capacity)
    {
        return .invalid_argument;
    }
    const v2_backend = namedOperationBackendV2Snapshot();
    const legacy_backend = if (v2_backend == null) namedOperationBackendSnapshot() else null;
    var signature = NamedOperationSignature{ .input_count = 0, .element_type = 0 };
    const name = function_name[0..function_name_length];
    if (v2_backend) |backend| {
        const query = backend.query orelse return .unsupported;
        const query_status = providerStatus(query(backend.context, name.ptr, name.len, &signature));
        if (query_status != .ok) return query_status;
    } else if (legacy_backend) |backend| {
        const query = backend.query orelse return .unsupported;
        const query_status = providerStatus(query(backend.context, name.ptr, name.len, &signature));
        if (query_status != .ok) return query_status;
    } else return .unsupported;
    if (signature.input_count == 0 or signature.input_count > argument_capacity or
        (v2_backend == null and signature.input_count > max_inputs) or
        signature.input_count != input_count or elementTypeFromRaw(signature.element_type) == null or
        element_type != signature.element_type) return .invalid_argument;
    const signature_type = elementTypeFromRaw(signature.element_type).?;

    var input_info: [max_named_inputs]?ViewInfo = @splat(null);
    var input_storage: [max_named_inputs]?[]u8 = @splat(null);
    defer for (&input_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_inputs: [max_named_inputs]TensorView = undefined;
    for (0..signature.input_count) |index| {
        input_info[index] = validateTypedView(&inputs[index], signature_type) orelse return .invalid_argument;
        const info = input_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        input_storage[index] = storage;
        @memset(storage, 0);
        if (!copySourceToDense(&inputs[index], info, storage)) return .invalid_argument;
        dense_inputs[index] = makeDenseView(inputs[index], info, storage);
    }

    const destination_info = validateTypedView(destination, signature_type) orelse return .invalid_argument;
    const destination_bytes = denseByteCount(destination_info) orelse return .invalid_argument;
    const destination_storage = std.heap.c_allocator.alloc(u8, destination_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(destination_storage);
    @memset(destination_storage, 0);
    const dense_destination = makeDenseView(destination.*, destination_info, destination_storage);
    var dense_permutation: [max_rank]u32 = @splat(0);
    for (0..destination_info.rank) |index| dense_permutation[index] = permutation[index];

    const status = if (v2_backend) |backend| blk: {
        const callback = backend.operation orelse break :blk Status.unsupported;
        var dense_arguments = NamedOperationArgumentsV2{
            .function_name = name.ptr,
            .function_name_length = name.len,
            .input_count = input_count,
            .element_type = element_type,
            .reserved = 0,
            .inputs = dense_inputs[0..signature.input_count].ptr,
            .destination = dense_destination,
            .permutation = dense_permutation[0..].ptr,
        };
        const provider_status = providerStatus(callback(backend.context, &dense_arguments));
        if (!std.meta.eql(dense_arguments.destination, dense_destination)) break :blk Status.invalid_argument;
        break :blk provider_status;
    } else if (legacy_backend) |backend| blk: {
        const callback = backend.operation orelse break :blk Status.unsupported;
        var legacy_inputs: [max_inputs]TensorView = std.mem.zeroes([max_inputs]TensorView);
        for (0..signature.input_count) |index| legacy_inputs[index] = dense_inputs[index];
        var dense_arguments = NamedOperationArguments{
            .function_name = name.ptr,
            .function_name_length = name.len,
            .input_count = input_count,
            .element_type = element_type,
            .reserved = 0,
            .inputs = legacy_inputs,
            .destination = dense_destination,
            .permutation = dense_permutation,
        };
        const provider_status = providerStatus(callback(backend.context, &dense_arguments));
        if (!std.meta.eql(dense_arguments.destination, dense_destination)) break :blk Status.invalid_argument;
        break :blk provider_status;
    } else Status.unsupported;
    if (status != .ok) return status;

    const validated_dense_destination = validateView(&dense_destination) orelse return .invalid_argument;
    if (!copyDenseToDestination(&dense_destination, validated_dense_destination, destination, destination_info)) return .invalid_argument;
    return .ok;
}

/// Query the additive v3 provider ABI. Unlike the legacy signature, v3 keeps
/// input and output counts and element types per binding so a CPU graph
/// provider can represent mixed-precision networks without making the Metal
/// adapter guess or convert the graph.
pub fn namedOperationSupportedV3(name: []const u8, signature: *NamedOperationSignatureV3) Status {
    if (name.len == 0) return .invalid_argument;
    const backend = namedOperationBackendV3Snapshot() orelse return .unsupported;
    const callback = backend.query orelse return .unsupported;
    var candidate = std.mem.zeroes(NamedOperationSignatureV3);
    const status = providerStatus(callback(backend.context, name.ptr, name.len, &candidate));
    if (status != .ok) return status;
    if (candidate.input_count == 0 or candidate.input_count > max_named_inputs or
        candidate.output_count == 0 or candidate.output_count > max_named_outputs) return .invalid_argument;
    for (0..candidate.input_count) |index| {
        if (elementTypeFromRaw(candidate.input_element_types[index]) == null) return .invalid_argument;
    }
    for (0..candidate.output_count) |index| {
        if (elementTypeFromRaw(candidate.output_element_types[index]) == null) return .invalid_argument;
    }
    signature.* = candidate;
    return .ok;
}

/// Stage a v3 named provider call into dense, offset-zero CPU views. Outputs
/// are copied back independently only after the provider returns success, so
/// one graph call can safely expose multiple ZPU-owned output tensors.
fn namedOperationV3WithViews(
    function_name: [*]const u8,
    function_name_length: usize,
    input_count: u32,
    inputs: [*]const TensorView,
    input_element_types: [*]const u32,
    output_count: u32,
    outputs: [*]TensorView,
    output_element_types: [*]const u32,
    permutation: [*]const u32,
) Status {
    if (!validNamedOperationName(function_name, function_name_length) or
        input_count == 0 or input_count > max_named_inputs or
        output_count == 0 or output_count > max_named_outputs) return .invalid_argument;
    const backend = namedOperationBackendV3Snapshot() orelse return .unsupported;
    const query = backend.query orelse return .unsupported;
    var signature = std.mem.zeroes(NamedOperationSignatureV3);
    const name = function_name[0..function_name_length];
    const query_status = providerStatus(query(backend.context, name.ptr, name.len, &signature));
    if (query_status != .ok) return query_status;
    if (signature.input_count != input_count or signature.output_count != output_count) return .invalid_argument;
    for (0..input_count) |index| {
        if (signature.input_element_types[index] != input_element_types[index] or
            elementTypeFromRaw(signature.input_element_types[index]) == null) return .invalid_argument;
    }
    for (0..output_count) |index| {
        if (signature.output_element_types[index] != output_element_types[index] or
            elementTypeFromRaw(signature.output_element_types[index]) == null) return .invalid_argument;
    }

    var input_info: [max_named_inputs]?ViewInfo = @splat(null);
    var input_storage: [max_named_inputs]?[]u8 = @splat(null);
    defer for (&input_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_inputs: [max_named_inputs]TensorView = undefined;
    for (0..input_count) |index| {
        const element_type = elementTypeFromRaw(input_element_types[index]).?;
        input_info[index] = validateTypedView(&inputs[index], element_type) orelse return .invalid_argument;
        const info = input_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        input_storage[index] = storage;
        @memset(storage, 0);
        if (!copySourceToDense(&inputs[index], info, storage)) return .invalid_argument;
        dense_inputs[index] = makeDenseView(inputs[index], info, storage);
    }

    var output_info: [max_named_outputs]?ViewInfo = @splat(null);
    var output_storage: [max_named_outputs]?[]u8 = @splat(null);
    defer for (&output_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_outputs: [max_named_outputs]TensorView = undefined;
    for (0..output_count) |index| {
        const element_type = elementTypeFromRaw(output_element_types[index]).?;
        output_info[index] = validateTypedView(&outputs[index], element_type) orelse return .invalid_argument;
        const info = output_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        output_storage[index] = storage;
        @memset(storage, 0);
        dense_outputs[index] = makeDenseView(outputs[index], info, storage);
    }

    const callback = backend.operation orelse return .unsupported;
    var dense_permutation: [max_rank]u32 = @splat(0);
    @memcpy(&dense_permutation, permutation[0..max_rank]);
    var dense_arguments = NamedOperationArgumentsV3{
        .function_name = name.ptr,
        .function_name_length = name.len,
        .input_count = input_count,
        .output_count = output_count,
        .reserved = 0,
        .inputs = dense_inputs[0..input_count].ptr,
        .input_element_types = input_element_types,
        .outputs = dense_outputs[0..output_count].ptr,
        .output_element_types = output_element_types,
        .permutation = dense_permutation[0..].ptr,
    };
    const status = providerStatus(callback(backend.context, &dense_arguments));
    if (status != .ok) return status;
    if (!std.meta.eql(dense_arguments.inputs, dense_inputs[0..input_count].ptr) or
        !std.meta.eql(dense_arguments.input_element_types, input_element_types) or
        !std.meta.eql(dense_arguments.outputs, dense_outputs[0..output_count].ptr) or
        !std.meta.eql(dense_arguments.output_element_types, output_element_types) or
        !std.meta.eql(dense_arguments.permutation, dense_permutation[0..].ptr)) return .invalid_argument;
    const provider_outputs = dense_arguments.outputs orelse return .invalid_argument;
    for (0..output_count) |index| {
        // The provider may write through the output data pointers, but it
        // must not redirect or reshape a staged view. Scattering a mutated
        // view would otherwise let provider metadata escape the dense CPU
        // boundary and could copy from an unrelated allocation.
        if (!std.meta.eql(dense_outputs[index], provider_outputs[index])) return .invalid_argument;
        const info = output_info[index].?;
        if (!copyDenseToDestination(&dense_outputs[index], info, &outputs[index], info)) return .invalid_argument;
    }
    return .ok;
}

pub fn namedOperation(arguments: *const NamedOperationArguments) Status {
    if (arguments.reserved != 0) return .invalid_argument;
    const name = arguments.function_name orelse return .invalid_argument;
    return namedOperationWithViews(name, arguments.function_name_length, arguments.input_count, arguments.element_type, arguments.inputs[0..].ptr, &arguments.destination, arguments.permutation[0..].ptr, max_inputs);
}

pub fn namedOperationV2(arguments: *const NamedOperationArgumentsV2) Status {
    if (arguments.reserved != 0) return .invalid_argument;
    const name = arguments.function_name orelse return .invalid_argument;
    const inputs = arguments.inputs orelse return .invalid_argument;
    const permutation = arguments.permutation orelse return .invalid_argument;
    return namedOperationWithViews(name, arguments.function_name_length, arguments.input_count, arguments.element_type, inputs, &arguments.destination, permutation, max_named_inputs);
}

pub fn namedOperationV3(arguments: *const NamedOperationArgumentsV3) Status {
    if (arguments.reserved != 0) return .invalid_argument;
    const name = arguments.function_name orelse return .invalid_argument;
    const inputs = arguments.inputs orelse return .invalid_argument;
    const input_element_types = arguments.input_element_types orelse return .invalid_argument;
    const outputs = arguments.outputs orelse return .invalid_argument;
    const output_element_types = arguments.output_element_types orelse return .invalid_argument;
    const permutation = arguments.permutation orelse return .invalid_argument;
    return namedOperationV3WithViews(name, arguments.function_name_length, arguments.input_count,
        inputs, input_element_types, arguments.output_count, outputs, output_element_types, permutation);
}

/// Stage a strided ZPU view into dense CPU memory for the optional provider.
///
/// ZML's CPU buffer import contract is intentionally narrower than the public
/// tensor-view contract: the provider sees offset-zero, axis-0-fast, dense
/// buffers only. A provider decline leaves the original destination untouched
/// and falls through to the exact strided ZPU reference path.
fn tryProvider(arguments: *const TransposeArguments, source_info: ViewInfo, destination_info: ViewInfo) ?Status {
    const backend = backendSnapshot() orelse return null;
    const callback = backend.transpose orelse return .unsupported;
    const source_bytes = denseByteCount(source_info) orelse return .invalid_argument;
    const destination_bytes = denseByteCount(destination_info) orelse return .invalid_argument;
    const source_storage = std.heap.c_allocator.alloc(u8, source_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(source_storage);
    const destination_storage = std.heap.c_allocator.alloc(u8, destination_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(destination_storage);
    @memset(source_storage, 0);
    @memset(destination_storage, 0);

    if (!copySourceToDense(&arguments.source, source_info, source_storage)) return .invalid_argument;
    const dense_source = makeDenseView(arguments.source, source_info, source_storage);
    const dense_destination = makeDenseView(arguments.destination, destination_info, destination_storage);
    var dense_arguments = TransposeArguments{
        .source = dense_source,
        .destination = dense_destination,
        .permutation = arguments.permutation,
    };
    const status = providerStatus(callback(backend.context, &dense_arguments));
    if (status != .ok) return status;

    if (!std.meta.eql(dense_arguments.destination, dense_destination)) return .invalid_argument;
    const validated_dense_destination = validateView(&dense_destination) orelse return .invalid_argument;
    if (!copyDenseToDestination(&dense_destination, validated_dense_destination, &arguments.destination, destination_info)) return .invalid_argument;
    return .ok;
}

fn incrementCoordinates(coordinates: *[max_rank]usize, dimensions: []const usize) void {
    for (0..dimensions.len) |axis| {
        coordinates[axis] += 1;
        if (coordinates[axis] < dimensions[axis]) return;
        coordinates[axis] = 0;
    }
}

/// Execute the exact raw-view tensor transpose. This is kept separate from
/// `transpose` so an optional provider test/bridge can use the reference
/// implementation on already-dense buffers without recursively re-entering
/// provider dispatch.
pub fn referenceTranspose(arguments: *const TransposeArguments) Status {
    const source_info = validateView(&arguments.source) orelse return .invalid_argument;
    const destination_info = validateView(&arguments.destination) orelse return .invalid_argument;
    if (!validatePermutation(arguments, source_info, destination_info)) return .invalid_argument;

    var dense_storage: ?[]u8 = null;
    defer if (dense_storage) |storage| std.heap.c_allocator.free(storage);

    var source = arguments.source;
    var source_view_info = source_info;
    if (rangesOverlap(&source, source_view_info, &arguments.destination, destination_info)) {
        const dense_bytes = if (source_info.element_bits == 4)
            (source_info.element_count + 1) / 2
        else
            checkedMul(source_info.element_count, source_info.element_bytes) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, dense_bytes) catch return .out_of_memory;
        dense_storage = storage;
        if (!copySourceToDense(&source, source_info, storage)) return .invalid_argument;
        source = .{
            .data = storage.ptr,
            .byte_length = storage.len,
            .offset_bytes = 0,
            .rank = @intCast(source_info.rank),
            .element_bits = source_info.element_bits,
            .dimensions = arguments.source.dimensions,
            .strides = undefined,
        };
        denseStrides(source.dimensions[0..source_info.rank], &source.strides);
        source_view_info = validateView(&source) orelse return .invalid_argument;
    }

    var output_coordinates: [max_rank]usize = @splat(0);
    for (0..destination_info.element_count) |_| {
        var source_coordinates: [max_rank]usize = @splat(0);
        for (0..destination_info.rank) |output_axis| {
            const source_axis: usize = arguments.permutation[output_axis];
            source_coordinates[source_axis] = output_coordinates[output_axis];
        }
        const source_element = logicalElementOffset(&source, source_coordinates[0..source_info.rank]) orelse return .invalid_argument;
        const destination_element_offset = logicalElementOffset(&arguments.destination, output_coordinates[0..destination_info.rank]) orelse return .invalid_argument;
        if (!copyElement(&source, source_view_info, source_element, &arguments.destination, destination_info, destination_element_offset)) {
            return .invalid_argument;
        }
        incrementCoordinates(&output_coordinates, arguments.destination.dimensions[0..destination_info.rank]);
    }
    return .ok;
}

/// Execute through the optional CPU provider, then fall back to the exact
/// ZPU implementation when no provider is installed or it returns unsupported.
pub fn transpose(arguments: *const TransposeArguments) Status {
    const source_info = validateView(&arguments.source) orelse return .invalid_argument;
    const destination_info = validateView(&arguments.destination) orelse return .invalid_argument;
    if (!validatePermutation(arguments, source_info, destination_info)) return .invalid_argument;
    if (tryProvider(arguments, source_info, destination_info)) |status| {
        if (status != .unsupported) return status;
    }
    return referenceTranspose(arguments);
}

pub export fn zpu_cpu_ml_set_backend(backend: ?*const Backend) callconv(.c) c_int {
    if (backend) |candidate| {
        if (candidate.abi_version != backend_abi_version or candidate.transpose == null) {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_backend = if (backend) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_compiled_cpu_arch() callconv(.c) u32 {
    return @intFromEnum(compiledCpuArch());
}

pub export fn zpu_cpu_ml_compiled_cpu_features() callconv(.c) u32 {
    return compiledCpuFeatures();
}

pub export fn zpu_cpu_ml_transpose(arguments: ?*const TransposeArguments) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(transpose(args));
}

pub export fn zpu_cpu_ml_set_operation_backend(backend: ?*const OperationBackend) callconv(.c) c_int {
    if (backend) |candidate| {
        if (candidate.abi_version != operation_backend_abi_version or candidate.operation == null) {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_operation_backend = if (backend) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_operation(arguments: ?*const OperationArguments) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(operation(args));
}

pub export fn zpu_cpu_ml_named_operation_supported(
    function_name: ?[*]const u8,
    function_name_length: usize,
    signature: ?*NamedOperationSignature,
) callconv(.c) c_int {
    const name = function_name orelse return @intFromEnum(Status.invalid_argument);
    const output = signature orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperationSupported(name[0..function_name_length], output));
}

pub export fn zpu_cpu_ml_named_operation_supported_v3(
    function_name: ?[*]const u8,
    function_name_length: usize,
    signature: ?*NamedOperationSignatureV3,
) callconv(.c) c_int {
    const name = function_name orelse return @intFromEnum(Status.invalid_argument);
    const output = signature orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperationSupportedV3(name[0..function_name_length], output));
}

pub export fn zpu_cpu_ml_set_named_operation_backend(
    backend: ?*const NamedOperationBackend,
) callconv(.c) c_int {
    if (backend) |candidate| {
        if (candidate.abi_version != named_operation_backend_abi_version or
            candidate.query == null or candidate.operation == null)
        {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_named_operation_backend = if (backend) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_set_named_operation_backend_v2(
    backend: ?*const NamedOperationBackendV2,
) callconv(.c) c_int {
    if (backend) |candidate| {
        if (candidate.abi_version != named_operation_backend_v2_abi_version or
            candidate.query == null or candidate.operation == null)
        {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_named_operation_backend_v2 = if (backend) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_set_named_operation_backend_v3(
    backend: ?*const NamedOperationBackendV3,
) callconv(.c) c_int {
    if (backend) |candidate| {
        if (candidate.abi_version != named_operation_backend_v3_abi_version or
            candidate.query == null or candidate.operation == null)
        {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_named_operation_backend_v3 = if (backend) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_set_named_operation_catalog(
    catalog: ?*const NamedOperationCatalog,
) callconv(.c) c_int {
    if (catalog) |candidate| {
        if (candidate.abi_version != named_operation_catalog_abi_version or candidate.name_at == null) {
            return @intFromEnum(Status.invalid_argument);
        }
    }
    lockBackend();
    defer backend_mutex.unlock();
    registered_named_operation_catalog = if (catalog) |candidate| candidate.* else null;
    return @intFromEnum(Status.ok);
}

pub export fn zpu_cpu_ml_named_operation_count() callconv(.c) usize {
    return namedOperationCount();
}

pub export fn zpu_cpu_ml_named_operation_name_at(
    index: usize,
    function_name: ?*?[*]const u8,
    function_name_length: ?*usize,
) callconv(.c) c_int {
    const output_name = function_name orelse return @intFromEnum(Status.invalid_argument);
    const output_length = function_name_length orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperationNameAt(index, output_name, output_length));
}

pub export fn zpu_cpu_ml_named_operation(
    arguments: ?*const NamedOperationArguments,
) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperation(args));
}

pub export fn zpu_cpu_ml_named_operation_v2(
    arguments: ?*const NamedOperationArgumentsV2,
) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperationV2(args));
}

pub export fn zpu_cpu_ml_named_operation_v3(
    arguments: ?*const NamedOperationArgumentsV3,
) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(namedOperationV3(args));
}

fn testView(comptime T: type, data: []T, rank: u32, dimensions: [max_rank]usize, strides: [max_rank]usize) TensorView {
    return .{
        .data = @ptrCast(data.ptr),
        .byte_length = @sizeOf(T) * data.len,
        .offset_bytes = 0,
        .rank = rank,
        .element_bits = @intCast(@sizeOf(T) * 8),
        .dimensions = dimensions,
        .strides = strides,
    };
}

const ProviderProbe = struct {
    calls: usize = 0,
    source_offset: usize = 0,
    destination_offset: usize = 0,
    source_stride: usize = 0,
    destination_stride: usize = 0,
};

const DestinationMutationProbe = struct {
    calls: usize = 0,
    foreign_storage: [8]u32 = [_]u32{0} ** 8,
};

const OperationProbe = struct {
    calls: usize = 0,
    operation: u32 = 0,
    element_type: u32 = 0,
    source_stride: usize = 0,
    destination_stride: usize = 0,
    source_tail_dimension: usize = 0,
    source_tail_stride: usize = 0,
    destination_tail_dimension: usize = 0,
    destination_tail_stride: usize = 0,
};

const NamedOperationProbe = struct {
    query_calls: usize = 0,
    operation_calls: usize = 0,
    name_matches: bool = false,
    source_stride: usize = 0,
    destination_stride: usize = 0,
};

const NamedOperationCatalogProbe = struct {
    names: []const []const u8,
    calls: usize = 0,
};

const NamedOperationV2Probe = struct {
    query_calls: usize = 0,
    operation_calls: usize = 0,
    dense_stride: usize = 0,
};

const NamedOperationV3Probe = struct {
    query_calls: usize = 0,
    operation_calls: usize = 0,
    input_stride: usize = 0,
    first_output_stride: usize = 0,
    second_output_stride: usize = 0,
};

fn referenceProvider(context: ?*anyopaque, arguments: *const TransposeArguments) callconv(.c) c_int {
    const probe = @as(*ProviderProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.calls += 1;
    probe.source_offset = arguments.source.offset_bytes;
    probe.destination_offset = arguments.destination.offset_bytes;
    probe.source_stride = arguments.source.strides[1];
    probe.destination_stride = arguments.destination.strides[1];
    return @intFromEnum(referenceTranspose(arguments));
}

fn decliningProvider(context: ?*anyopaque, arguments: *const TransposeArguments) callconv(.c) c_int {
    const probe = @as(*ProviderProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.calls += 1;
    _ = arguments;
    return @intFromEnum(Status.unsupported);
}

fn destinationMutationProvider(context: ?*anyopaque, arguments: *const TransposeArguments) callconv(.c) c_int {
    const probe = @as(*DestinationMutationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.calls += 1;
    // Providers receive a const argument record. This deliberate test-only
    // mutation models an unsafe foreign provider attempting to redirect the
    // output pointer; the staging boundary must reject it before any scatter.
    const mutable_arguments = @constCast(arguments);
    mutable_arguments.destination.data = @ptrCast(probe.foreign_storage[0..].ptr);
    return @intFromEnum(Status.ok);
}

fn addOperationProvider(context: ?*anyopaque, arguments: *const OperationArguments) callconv(.c) c_int {
    const probe = @as(*OperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.calls += 1;
    probe.operation = arguments.operation;
    probe.element_type = arguments.element_type;
    probe.source_stride = arguments.inputs[0].strides[1];
    probe.destination_stride = arguments.destination.strides[1];
    probe.source_tail_dimension = arguments.inputs[0].dimensions[2];
    probe.source_tail_stride = arguments.inputs[0].strides[2];
    probe.destination_tail_dimension = arguments.destination.dimensions[2];
    probe.destination_tail_stride = arguments.destination.strides[2];
    if (arguments.operation != @intFromEnum(Operation.add) or
        arguments.element_type != @intFromEnum(ElementType.uint32) or
        arguments.input_count != 2 or arguments.inputs[0].offset_bytes != 0 or
        arguments.inputs[1].offset_bytes != 0 or arguments.destination.offset_bytes != 0 or
        arguments.inputs[0].strides[0] != 1 or arguments.inputs[0].strides[1] != 2 or
        arguments.inputs[1].strides[0] != 1 or arguments.inputs[1].strides[1] != 2 or
        arguments.destination.strides[0] != 1 or arguments.destination.strides[1] != 2)
    {
        return @intFromEnum(Status.invalid_argument);
    }
    const left = @as([*]const u32, @ptrCast(@alignCast(arguments.inputs[0].data orelse return @intFromEnum(Status.invalid_argument))));
    const right = @as([*]const u32, @ptrCast(@alignCast(arguments.inputs[1].data orelse return @intFromEnum(Status.invalid_argument))));
    const output = @as([*]u32, @ptrCast(@alignCast(arguments.destination.data orelse return @intFromEnum(Status.invalid_argument))));
    for (0..6) |index| output[index] = left[index] + right[index];
    return @intFromEnum(Status.ok);
}

fn namedTransposeQuery(context: ?*anyopaque, function_name: [*]const u8, function_name_length: usize, signature: *NamedOperationSignature) callconv(.c) c_int {
    const probe = @as(*NamedOperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.query_calls += 1;
    if (!std.mem.eql(u8, function_name[0..function_name_length], "zml_cpu_transpose")) {
        return @intFromEnum(Status.unsupported);
    }
    signature.* = .{
        .input_count = 1,
        .element_type = @intFromEnum(ElementType.uint32),
    };
    return @intFromEnum(Status.ok);
}

fn namedTransposeProvider(context: ?*anyopaque, arguments: *const NamedOperationArguments) callconv(.c) c_int {
    const probe = @as(*NamedOperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.operation_calls += 1;
    const function_name = arguments.function_name orelse return @intFromEnum(Status.invalid_argument);
    probe.name_matches = std.mem.eql(u8, function_name[0..arguments.function_name_length], "zml_cpu_transpose");
    probe.source_stride = arguments.inputs[0].strides[1];
    probe.destination_stride = arguments.destination.strides[1];
    if (!probe.name_matches or arguments.input_count != 1 or
        arguments.element_type != @intFromEnum(ElementType.uint32) or
        arguments.inputs[0].offset_bytes != 0 or arguments.destination.offset_bytes != 0 or
        arguments.inputs[0].strides[0] != 1 or arguments.inputs[0].strides[1] != 2 or
        arguments.destination.strides[0] != 1 or arguments.destination.strides[1] != 3)
    {
        return @intFromEnum(Status.invalid_argument);
    }
    var transpose_arguments = TransposeArguments{
        .source = arguments.inputs[0],
        .destination = arguments.destination,
        .permutation = arguments.permutation,
    };
    return @intFromEnum(referenceTranspose(&transpose_arguments));
}

fn namedOperationNameAtProvider(
    context: ?*anyopaque,
    index: usize,
    function_name: *?[*]const u8,
    function_name_length: *usize,
) callconv(.c) c_int {
    const probe = @as(*NamedOperationCatalogProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    if (index >= probe.names.len) return @intFromEnum(Status.invalid_argument);
    probe.calls += 1;
    function_name.* = probe.names[index].ptr;
    function_name_length.* = probe.names[index].len;
    return @intFromEnum(Status.ok);
}

fn namedSum3Query(context: ?*anyopaque, function_name: [*]const u8, function_name_length: usize, signature: *NamedOperationSignature) callconv(.c) c_int {
    const probe = @as(*NamedOperationV2Probe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.query_calls += 1;
    if (!std.mem.eql(u8, function_name[0..function_name_length], "zml_cpu_sum3_f32")) {
        return @intFromEnum(Status.unsupported);
    }
    signature.* = .{
        .input_count = 3,
        .element_type = @intFromEnum(ElementType.float32),
    };
    return @intFromEnum(Status.ok);
}

fn namedSum3Provider(context: ?*anyopaque, arguments: *const NamedOperationArgumentsV2) callconv(.c) c_int {
    const probe = @as(*NamedOperationV2Probe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.operation_calls += 1;
    const function_name = arguments.function_name orelse return @intFromEnum(Status.invalid_argument);
    if (!std.mem.eql(u8, function_name[0..arguments.function_name_length], "zml_cpu_sum3_f32") or
        arguments.input_count != 3 or arguments.element_type != @intFromEnum(ElementType.float32))
    {
        return @intFromEnum(Status.invalid_argument);
    }
    const inputs = arguments.inputs orelse return @intFromEnum(Status.invalid_argument);
    const output = @as([*]f32, @ptrCast(@alignCast(arguments.destination.data orelse return @intFromEnum(Status.invalid_argument))));
    probe.dense_stride = arguments.destination.strides[1];
    if (arguments.destination.offset_bytes != 0 or arguments.destination.strides[0] != 1 or
        arguments.destination.strides[1] != 2)
    {
        return @intFromEnum(Status.invalid_argument);
    }
    for (0..6) |index| {
        var value: f32 = 0;
        for (0..3) |input_index| {
            const input = inputs[input_index];
            const data = @as([*]const f32, @ptrCast(@alignCast(input.data orelse return @intFromEnum(Status.invalid_argument))));
            value += data[index];
        }
        output[index] = value;
    }
    return @intFromEnum(Status.ok);
}

fn namedSplitQuery(context: ?*anyopaque, function_name: [*]const u8,
                   function_name_length: usize, signature: *NamedOperationSignatureV3) callconv(.c) c_int {
    const probe = @as(*NamedOperationV3Probe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.query_calls += 1;
    if (!std.mem.eql(u8, function_name[0..function_name_length], "zml_cpu_split_f32")) {
        return @intFromEnum(Status.unsupported);
    }
    signature.* = std.mem.zeroes(NamedOperationSignatureV3);
    signature.input_count = 1;
    signature.output_count = 2;
    signature.input_element_types[0] = @intFromEnum(ElementType.float32);
    signature.output_element_types[0] = @intFromEnum(ElementType.float32);
    signature.output_element_types[1] = @intFromEnum(ElementType.float32);
    return @intFromEnum(Status.ok);
}

fn namedSplitProvider(context: ?*anyopaque, arguments: *const NamedOperationArgumentsV3) callconv(.c) c_int {
    const probe = @as(*NamedOperationV3Probe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.operation_calls += 1;
    const function_name = arguments.function_name orelse return @intFromEnum(Status.invalid_argument);
    const inputs = arguments.inputs orelse return @intFromEnum(Status.invalid_argument);
    const input_element_types = arguments.input_element_types orelse return @intFromEnum(Status.invalid_argument);
    const outputs = arguments.outputs orelse return @intFromEnum(Status.invalid_argument);
    const output_element_types = arguments.output_element_types orelse return @intFromEnum(Status.invalid_argument);
    const permutation = arguments.permutation orelse return @intFromEnum(Status.invalid_argument);
    if (!std.mem.eql(u8, function_name[0..arguments.function_name_length], "zml_cpu_split_f32") or
        arguments.input_count != 1 or arguments.output_count != 2 or
        input_element_types[0] != @intFromEnum(ElementType.float32) or
        output_element_types[0] != @intFromEnum(ElementType.float32) or
        output_element_types[1] != @intFromEnum(ElementType.float32) or permutation[0] != 0)
    {
        return @intFromEnum(Status.invalid_argument);
    }
    probe.input_stride = inputs[0].strides[1];
    probe.first_output_stride = outputs[0].strides[1];
    probe.second_output_stride = outputs[1].strides[1];
    if (inputs[0].offset_bytes != 0 or outputs[0].offset_bytes != 0 or outputs[1].offset_bytes != 0 or
        inputs[0].strides[0] != 1 or inputs[0].strides[1] != 2 or
        outputs[0].strides[0] != 1 or outputs[0].strides[1] != 2 or
        outputs[1].strides[0] != 1 or outputs[1].strides[1] != 2)
    {
        return @intFromEnum(Status.invalid_argument);
    }
    const input = @as([*]const f32, @ptrCast(@alignCast(inputs[0].data orelse return @intFromEnum(Status.invalid_argument))));
    const first_output = @as([*]f32, @ptrCast(@alignCast(outputs[0].data orelse return @intFromEnum(Status.invalid_argument))));
    const second_output = @as([*]f32, @ptrCast(@alignCast(outputs[1].data orelse return @intFromEnum(Status.invalid_argument))));
    for (0..6) |index| {
        first_output[index] = input[index] + 1.0;
        second_output[index] = input[index] * 2.0;
    }
    return @intFromEnum(Status.ok);
}

fn legacyThreeInputQuery(context: ?*anyopaque, function_name: [*]const u8,
                         function_name_length: usize, signature: *NamedOperationSignature) callconv(.c) c_int {
    const probe = @as(*NamedOperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.query_calls += 1;
    if (!std.mem.eql(u8, function_name[0..function_name_length], "zml_cpu_legacy_three_input")) {
        return @intFromEnum(Status.unsupported);
    }
    signature.* = .{
        .input_count = 3,
        .element_type = @intFromEnum(ElementType.float32),
    };
    return @intFromEnum(Status.ok);
}

fn legacyThreeInputProvider(context: ?*anyopaque, arguments: *const NamedOperationArguments) callconv(.c) c_int {
    const probe = @as(*NamedOperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    _ = arguments;
    probe.operation_calls += 1;
    return @intFromEnum(Status.invalid_argument);
}

fn providerTestArguments(source_storage: []u32, destination_storage: []u32, dimensions: [max_rank]usize, output_dimensions: [max_rank]usize, strides: [max_rank]usize, output_strides: [max_rank]usize) TransposeArguments {
    return .{
        .source = testView(u32, source_storage, 2, dimensions, strides),
        .destination = testView(u32, destination_storage, 2, output_dimensions, output_strides),
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
}

test "optional CPU provider receives dense views and preserves raw layout" {
    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 1;
    source_storage[1] = 2;
    source_storage[4] = 3;
    source_storage[5] = 4;
    source_storage[8] = 5;
    source_storage[9] = 6;
    var destination_storage = [_]u32{0xdeadbeef} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = providerTestArguments(&source_storage, &destination_storage, dimensions, output_dimensions, strides, output_strides);
    var probe = ProviderProbe{};
    const context: *anyopaque = @ptrCast(&probe);
    const backend = Backend{
        .abi_version = backend_abi_version,
        .context = context,
        .transpose = referenceProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_backend(&backend));
    defer _ = zpu_cpu_ml_set_backend(null);

    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.source_offset);
    try std.testing.expectEqual(@as(usize, 0), probe.destination_offset);
    try std.testing.expectEqual(@as(usize, 2), probe.source_stride);
    try std.testing.expectEqual(@as(usize, 3), probe.destination_stride);
    try std.testing.expectEqual(@as(u32, 1), destination_storage[0]);
    try std.testing.expectEqual(@as(u32, 3), destination_storage[1]);
    try std.testing.expectEqual(@as(u32, 5), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 2), destination_storage[4]);
    try std.testing.expectEqual(@as(u32, 4), destination_storage[5]);
    try std.testing.expectEqual(@as(u32, 6), destination_storage[6]);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), destination_storage[3]);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), destination_storage[7]);
}

test "unsupported CPU provider falls back to exact ZPU transpose" {
    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 11;
    source_storage[1] = 12;
    source_storage[4] = 13;
    source_storage[5] = 14;
    source_storage[8] = 15;
    source_storage[9] = 16;
    var destination_storage = [_]u32{0xcafebabe} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = providerTestArguments(&source_storage, &destination_storage, dimensions, output_dimensions, strides, output_strides);
    var probe = ProviderProbe{};
    const context: *anyopaque = @ptrCast(&probe);
    const backend = Backend{
        .abi_version = backend_abi_version,
        .context = context,
        .transpose = decliningProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_backend(&backend));
    defer _ = zpu_cpu_ml_set_backend(null);

    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(u32, 11), destination_storage[0]);
    try std.testing.expectEqual(@as(u32, 13), destination_storage[1]);
    try std.testing.expectEqual(@as(u32, 15), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 12), destination_storage[4]);
    try std.testing.expectEqual(@as(u32, 14), destination_storage[5]);
    try std.testing.expectEqual(@as(u32, 16), destination_storage[6]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[3]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[7]);
}

test "CPU provider cannot redirect staged destination ownership" {
    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 1;
    source_storage[1] = 2;
    source_storage[4] = 3;
    source_storage[5] = 4;
    source_storage[8] = 5;
    source_storage[9] = 6;
    var destination_storage = [_]u32{0xcafebabe} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = providerTestArguments(&source_storage, &destination_storage, dimensions, output_dimensions, strides, output_strides);
    var probe = DestinationMutationProbe{};
    const backend = Backend{
        .abi_version = backend_abi_version,
        .context = @ptrCast(&probe),
        .transpose = destinationMutationProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_backend(&backend));
    defer _ = zpu_cpu_ml_set_backend(null);

    try std.testing.expectEqual(Status.invalid_argument, transpose(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqualSlices(u32, &([_]u32{0xcafebabe} ** 8), &destination_storage);
    try std.testing.expectEqual(@as(u32, 0), probe.foreign_storage[0]);
}

test "optional CPU operation provider receives dense ZML views" {
    var left_storage = [_]u32{0} ** 12;
    var right_storage = [_]u32{0} ** 12;
    left_storage[0] = 1;
    left_storage[1] = 2;
    left_storage[4] = 3;
    left_storage[5] = 4;
    left_storage[8] = 5;
    left_storage[9] = 6;
    right_storage[0] = 10;
    right_storage[1] = 20;
    right_storage[4] = 30;
    right_storage[5] = 40;
    right_storage[8] = 50;
    right_storage[9] = 60;
    var destination_storage = [_]u32{0xcafebabe} ** 12;
    const dimensions = [_]usize{ 2, 3, 99 } ++ [_]usize{0} ** (max_rank - 3);
    const strides = [_]usize{ 1, 4, 77 } ++ [_]usize{0} ** (max_rank - 3);
    const arguments = OperationArguments{
        .operation = @intFromEnum(Operation.add),
        .element_type = @intFromEnum(ElementType.uint32),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{
            .{ .data = @ptrCast(left_storage[0..].ptr), .byte_length = left_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = strides },
            .{ .data = @ptrCast(right_storage[0..].ptr), .byte_length = right_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = strides },
        },
        .destination = .{ .data = @ptrCast(destination_storage[0..].ptr), .byte_length = destination_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = strides },
        .permutation = @splat(0),
    };
    var probe = OperationProbe{};
    const backend = OperationBackend{
        .abi_version = operation_backend_abi_version,
        .context = @ptrCast(&probe),
        .operation = addOperationProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_operation_backend(&backend));
    defer _ = zpu_cpu_ml_set_operation_backend(null);

    try std.testing.expectEqual(Status.ok, operation(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@intFromEnum(Operation.add), probe.operation);
    try std.testing.expectEqual(@intFromEnum(ElementType.uint32), probe.element_type);
    try std.testing.expectEqual(@as(usize, 2), probe.source_stride);
    try std.testing.expectEqual(@as(usize, 2), probe.destination_stride);
    try std.testing.expectEqual(@as(usize, 0), probe.source_tail_dimension);
    try std.testing.expectEqual(@as(usize, 0), probe.source_tail_stride);
    try std.testing.expectEqual(@as(usize, 0), probe.destination_tail_dimension);
    try std.testing.expectEqual(@as(usize, 0), probe.destination_tail_stride);
    try std.testing.expectEqual(@as(u32, 11), destination_storage[0]);
    try std.testing.expectEqual(@as(u32, 22), destination_storage[1]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 33), destination_storage[4]);
    try std.testing.expectEqual(@as(u32, 44), destination_storage[5]);
    try std.testing.expectEqual(@as(u32, 55), destination_storage[8]);
    try std.testing.expectEqual(@as(u32, 66), destination_storage[9]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[3]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[6]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[7]);

    var invalid_arguments = arguments;
    invalid_arguments.element_type = @intFromEnum(ElementType.uint8);
    try std.testing.expectEqual(Status.invalid_argument, operation(&invalid_arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    invalid_arguments = arguments;
    invalid_arguments.reserved = 1;
    try std.testing.expectEqual(Status.invalid_argument, operation(&invalid_arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "operation transpose preserves the legacy CPU provider bridge" {
    _ = zpu_cpu_ml_set_operation_backend(null);

    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 1;
    source_storage[1] = 2;
    source_storage[4] = 3;
    source_storage[5] = 4;
    source_storage[8] = 5;
    source_storage[9] = 6;
    var destination_storage = [_]u32{0xcafebabe} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = OperationArguments{
        .operation = @intFromEnum(Operation.transpose),
        .element_type = @intFromEnum(ElementType.uint32),
        .input_count = 1,
        .reserved = 0,
        .inputs = .{ testView(u32, &source_storage, 2, dimensions, strides), std.mem.zeroes(TensorView) },
        .destination = testView(u32, &destination_storage, 2, output_dimensions, output_strides),
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    var probe = ProviderProbe{};
    const backend = Backend{
        .abi_version = backend_abi_version,
        .context = @ptrCast(&probe),
        .transpose = referenceProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_backend(&backend));
    defer _ = zpu_cpu_ml_set_backend(null);

    try std.testing.expectEqual(Status.ok, operation(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.source_offset);
    try std.testing.expectEqual(@as(usize, 0), probe.destination_offset);
    try std.testing.expectEqual(@as(usize, 2), probe.source_stride);
    try std.testing.expectEqual(@as(usize, 3), probe.destination_stride);
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 3, 5, 0xcafebabe, 2, 4, 6, 0xcafebabe }, &destination_storage);
}

test "CPU operation validates views before provider selection" {
    var arguments: OperationArguments = std.mem.zeroes(OperationArguments);
    arguments.operation = @intFromEnum(Operation.add);
    arguments.element_type = @intFromEnum(ElementType.uint32);
    arguments.input_count = 2;
    try std.testing.expectEqual(Status.invalid_argument, operation(&arguments));
}

test "fixed CPU operations fall back to exact strided reference math" {
    _ = zpu_cpu_ml_set_operation_backend(null);

    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const strided = [_]usize{ 1, 3 } ++ [_]usize{0} ** (max_rank - 2);
    var left = [_]f32{ 1, 2, 999, 3, 4, 999, 5, 6 };
    var right = [_]f32{ 10, 20, 999, 30, 40, 999, 50, 60 };
    var output = [_]f32{ -99, -99, -99, -99, -99, -99, -99, -99 };
    const arguments = OperationArguments{
        .operation = @intFromEnum(Operation.add),
        .element_type = @intFromEnum(ElementType.float32),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{ testView(f32, &left, 2, dimensions, strided), testView(f32, &right, 2, dimensions, strided) },
        .destination = testView(f32, &output, 2, dimensions, strided),
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&arguments));
    try std.testing.expectEqualSlices(f32, &[_]f32{ 11, 22, -99, 33, 44, -99, 55, 66 }, &output);

    const left_dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const right_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const left_strides = [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const right_strides = [_]usize{ 1, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2);
    var matrix_left = [_]f32{ 1, 2, 3, 4, 5, 6 };
    var matrix_right = [_]f32{ 7, 8, 9, 10, 11, 12 };
    var matrix_output = [_]f32{ -99, -99, -99, -99 };
    const matrix_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.matmul),
        .element_type = @intFromEnum(ElementType.float32),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{
            testView(f32, &matrix_left, 2, left_dimensions, left_strides),
            testView(f32, &matrix_right, 2, right_dimensions, right_strides),
        },
        .destination = testView(f32, &matrix_output, 2, output_dimensions, output_strides),
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&matrix_arguments));
    try std.testing.expectEqualSlices(f32, &[_]f32{ 58, 64, 139, 154 }, &matrix_output);

    const vector_dimensions = [_]usize{2} ++ [_]usize{0} ** (max_rank - 1);
    const vector_strides = [_]usize{1} ++ [_]usize{0} ** (max_rank - 1);
    var half_left = [_]f16{ 1.5, -2.0 };
    var half_right = [_]f16{ 2.0, 0.5 };
    var half_output = [_]f16{ -99.0, -99.0 };
    const half_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.multiply),
        .element_type = @intFromEnum(ElementType.float16),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{ testView(f16, &half_left, 1, vector_dimensions, vector_strides), testView(f16, &half_right, 1, vector_dimensions, vector_strides) },
        .destination = testView(f16, &half_output, 1, vector_dimensions, vector_strides),
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&half_arguments));
    try std.testing.expectEqualSlices(f16, &[_]f16{ 3.0, -1.0 }, &half_output);

    var half_division_output = [_]f16{ -99.0, -99.0 };
    var half_division_arguments = half_arguments;
    half_division_arguments.operation = @intFromEnum(Operation.divide);
    half_division_arguments.destination = testView(f16, &half_division_output, 1, vector_dimensions, vector_strides);
    try std.testing.expectEqual(Status.ok, operation(&half_division_arguments));
    try std.testing.expectEqualSlices(f16, &[_]f16{ 0.75, -4.0 }, &half_division_output);

    var bfloat_left = [_]u16{ 0x3f80, 0xc000 };
    var bfloat_right = [_]u16{ 0x4000, 0x3f80 };
    var bfloat_output = [_]u16{ 0xffff, 0xffff };
    const bfloat_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.add),
        .element_type = @intFromEnum(ElementType.bfloat16),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{ testView(u16, &bfloat_left, 1, vector_dimensions, vector_strides), testView(u16, &bfloat_right, 1, vector_dimensions, vector_strides) },
        .destination = testView(u16, &bfloat_output, 1, vector_dimensions, vector_strides),
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&bfloat_arguments));
    try std.testing.expectEqualSlices(u16, &[_]u16{ 0x4040, 0xbf80 }, &bfloat_output);

    var bfloat_division_output = [_]u16{ 0xffff, 0xffff };
    var bfloat_division_arguments = bfloat_arguments;
    bfloat_division_arguments.operation = @intFromEnum(Operation.divide);
    bfloat_division_arguments.destination = testView(u16, &bfloat_division_output, 1, vector_dimensions, vector_strides);
    try std.testing.expectEqual(Status.ok, operation(&bfloat_division_arguments));
    try std.testing.expectEqualSlices(u16, &[_]u16{ 0x3f00, 0xc000 }, &bfloat_division_output);

    var integer_left = [_]u8{ 0xff, 2, 3, 4 };
    var integer_right = [_]u8{ 2, 3, 4, 5 };
    var integer_output = [_]u8{ 0, 0, 0, 0 };
    const integer_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.matmul),
        .element_type = @intFromEnum(ElementType.uint8),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{
            testView(u8, &integer_left, 2, [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2), [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2)),
            testView(u8, &integer_right, 2, [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2), [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2)),
        },
        .destination = testView(u8, &integer_output, 2, [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2), [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2)),
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&integer_arguments));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 6, 7, 22, 29 }, &integer_output);

    const packed_dimensions = [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const packed_strides = [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2);
    var uint4_left = [_]u8{ 0x21, 0x43 };
    var uint4_right = [_]u8{ 0x65, 0x87 };
    var uint4_output = [_]u8{ 0xa5, 0xa5 };
    const uint4_left_view = TensorView{
        .data = @ptrCast(uint4_left[0..].ptr), .byte_length = uint4_left.len,
        .offset_bytes = 0, .rank = 2, .element_bits = 4,
        .dimensions = packed_dimensions, .strides = packed_strides,
    };
    const uint4_right_view = TensorView{
        .data = @ptrCast(uint4_right[0..].ptr), .byte_length = uint4_right.len,
        .offset_bytes = 0, .rank = 2, .element_bits = 4,
        .dimensions = packed_dimensions, .strides = packed_strides,
    };
    const uint4_output_view = TensorView{
        .data = @ptrCast(uint4_output[0..].ptr), .byte_length = uint4_output.len,
        .offset_bytes = 0, .rank = 2, .element_bits = 4,
        .dimensions = packed_dimensions, .strides = packed_strides,
    };
    const uint4_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.matmul),
        .element_type = @intFromEnum(ElementType.uint4),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{ uint4_left_view, uint4_right_view },
        .destination = uint4_output_view,
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&uint4_arguments));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x63, 0x2b }, &uint4_output);

    var int4_left = [_]u8{ 0x2f, 0xe3 };
    var int4_right = [_]u8{ 0xd1, 0x84 };
    var int4_output = [_]u8{ 0xa5, 0xa5 };
    const int4_arguments = OperationArguments{
        .operation = @intFromEnum(Operation.matmul),
        .element_type = @intFromEnum(ElementType.int4),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{
            .{ .data = @ptrCast(int4_left[0..].ptr), .byte_length = int4_left.len,
               .offset_bytes = 0, .rank = 2, .element_bits = 4,
               .dimensions = packed_dimensions, .strides = packed_strides },
            .{ .data = @ptrCast(int4_right[0..].ptr), .byte_length = int4_right.len,
               .offset_bytes = 0, .rank = 2, .element_bits = 4,
               .dimensions = packed_dimensions, .strides = packed_strides },
        },
        .destination = .{ .data = @ptrCast(int4_output[0..].ptr), .byte_length = int4_output.len,
                          .offset_bytes = 0, .rank = 2, .element_bits = 4,
                          .dimensions = packed_dimensions, .strides = packed_strides },
        .permutation = [_]u32{0} ** max_rank,
    };
    try std.testing.expectEqual(Status.ok, operation(&int4_arguments));
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x37, 0x7b }, &int4_output);
}

test "named CPU provider receives a portable graph name and dense transpose views" {
    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 1;
    source_storage[1] = 2;
    source_storage[4] = 3;
    source_storage[5] = 4;
    source_storage[8] = 5;
    source_storage[9] = 6;
    var destination_storage = [_]u32{0xcafebabe} ** 12;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const source_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const destination_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const function_name = "zml_cpu_transpose";
    const arguments = NamedOperationArguments{
        .function_name = function_name,
        .function_name_length = function_name.len,
        .input_count = 1,
        .element_type = @intFromEnum(ElementType.uint32),
        .reserved = 0,
        .inputs = .{ .{
            .data = @ptrCast(source_storage[0..].ptr),
            .byte_length = source_storage.len * @sizeOf(u32),
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 32,
            .dimensions = dimensions,
            .strides = source_strides,
        }, std.mem.zeroes(TensorView) },
        .destination = .{
            .data = @ptrCast(destination_storage[0..].ptr),
            .byte_length = destination_storage.len * @sizeOf(u32),
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 32,
            .dimensions = output_dimensions,
            .strides = destination_strides,
        },
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    var probe = NamedOperationProbe{};
    const backend = NamedOperationBackend{
        .abi_version = named_operation_backend_abi_version,
        .context = @ptrCast(&probe),
        .query = namedTransposeQuery,
        .operation = namedTransposeProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_named_operation_backend(&backend));
    defer _ = zpu_cpu_ml_set_named_operation_backend(null);

    var signature = NamedOperationSignature{ .input_count = 0, .element_type = 0 };
    try std.testing.expectEqual(Status.ok, namedOperationSupported(function_name, &signature));
    try std.testing.expectEqual(@as(u32, 1), signature.input_count);
    try std.testing.expectEqual(@intFromEnum(ElementType.uint32), signature.element_type);
    try std.testing.expectEqual(Status.ok, namedOperation(&arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
    try std.testing.expect(probe.name_matches);
    try std.testing.expectEqual(@as(usize, 2), probe.source_stride);
    try std.testing.expectEqual(@as(usize, 3), probe.destination_stride);
    try std.testing.expectEqual(@as(u32, 1), destination_storage[0]);
    try std.testing.expectEqual(@as(u32, 3), destination_storage[1]);
    try std.testing.expectEqual(@as(u32, 5), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 2), destination_storage[4]);
    try std.testing.expectEqual(@as(u32, 4), destination_storage[5]);
    try std.testing.expectEqual(@as(u32, 6), destination_storage[6]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[3]);
    try std.testing.expectEqual(@as(u32, 0xcafebabe), destination_storage[7]);

    var invalid_arguments = arguments;
    invalid_arguments.reserved = 1;
    try std.testing.expectEqual(Status.invalid_argument, namedOperation(&invalid_arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
}

test "named CPU provider catalog exposes discoverable function names" {
    const names = [_][]const u8{ "zml_cpu_transpose", "zml_cpu_add" };
    var probe = NamedOperationCatalogProbe{ .names = &names };
    const catalog = NamedOperationCatalog{
        .abi_version = named_operation_catalog_abi_version,
        .context = @ptrCast(&probe),
        .count = names.len,
        .name_at = namedOperationNameAtProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_named_operation_catalog(&catalog));
    defer _ = zpu_cpu_ml_set_named_operation_catalog(null);

    try std.testing.expectEqual(names.len, namedOperationCount());
    var function_name: ?[*]const u8 = null;
    var function_name_length: usize = 0;
    try std.testing.expectEqual(
        Status.ok,
        namedOperationNameAt(1, &function_name, &function_name_length),
    );
    try std.testing.expectEqualStrings("zml_cpu_add", function_name.?[0..function_name_length]);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(
        Status.invalid_argument,
        namedOperationNameAt(names.len, &function_name, &function_name_length),
    );
    try std.testing.expectEqual(@as(?[*]const u8, null), function_name);
    try std.testing.expectEqual(@as(usize, 0), function_name_length);
}

test "named CPU provider v2 carries a generic three-input graph" {
    var left_storage = [_]f32{0} ** 12;
    var middle_storage = [_]f32{0} ** 12;
    var right_storage = [_]f32{0} ** 12;
    for (0..6) |index| {
        const row = index / 2;
        const column = index % 2;
        const storage_index = column + row * 4;
        left_storage[storage_index] = @floatFromInt(index + 1);
        middle_storage[storage_index] = @floatFromInt((index + 1) * 10);
        right_storage[storage_index] = @floatFromInt((index + 1) * 100);
    }
    var destination_storage = [_]f32{12345.0} ** 12;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const inputs = [_]TensorView{
        testView(f32, &left_storage, 2, dimensions, strides),
        testView(f32, &middle_storage, 2, dimensions, strides),
        testView(f32, &right_storage, 2, dimensions, strides),
    };
    const arguments = NamedOperationArgumentsV2{
        .function_name = "zml_cpu_sum3_f32",
        .function_name_length = "zml_cpu_sum3_f32".len,
        .input_count = 3,
        .element_type = @intFromEnum(ElementType.float32),
        .reserved = 0,
        .inputs = inputs[0..].ptr,
        .destination = testView(f32, &destination_storage, 2, dimensions, strides),
        .permutation = ([_]u32{ 0, 1 } ++ [_]u32{0} ** (max_rank - 2))[0..].ptr,
    };
    var probe = NamedOperationV2Probe{};
    const backend = NamedOperationBackendV2{
        .abi_version = named_operation_backend_v2_abi_version,
        .context = @ptrCast(&probe),
        .query = namedSum3Query,
        .operation = namedSum3Provider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_named_operation_backend_v2(&backend));
    defer _ = zpu_cpu_ml_set_named_operation_backend_v2(null);

    var signature = NamedOperationSignature{ .input_count = 0, .element_type = 0 };
    try std.testing.expectEqual(Status.ok, namedOperationSupported("zml_cpu_sum3_f32", &signature));
    try std.testing.expectEqual(@as(u32, 3), signature.input_count);
    try std.testing.expectEqual(Status.ok, namedOperationV2(&arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
    try std.testing.expectEqual(@as(usize, 2), probe.dense_stride);
    try std.testing.expectEqual(@as(f32, 111), destination_storage[0]);
    try std.testing.expectEqual(@as(f32, 222), destination_storage[1]);
    try std.testing.expectEqual(@as(f32, 333), destination_storage[4]);
    try std.testing.expectEqual(@as(f32, 444), destination_storage[5]);
    try std.testing.expectEqual(@as(f32, 555), destination_storage[8]);
    try std.testing.expectEqual(@as(f32, 666), destination_storage[9]);
    try std.testing.expectEqual(@as(f32, 12345.0), destination_storage[2]);
    try std.testing.expectEqual(@as(f32, 12345.0), destination_storage[3]);

    var invalid_arguments = arguments;
    invalid_arguments.reserved = 1;
    try std.testing.expectEqual(Status.invalid_argument, namedOperationV2(&invalid_arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
}

test "named CPU provider v3 carries multi-output dense views" {
    var input_storage = [_]f32{0} ** 12;
    input_storage[0] = 1;
    input_storage[1] = 2;
    input_storage[4] = 3;
    input_storage[5] = 4;
    input_storage[8] = 5;
    input_storage[9] = 6;
    var first_output_storage = [_]f32{12345.0} ** 12;
    var second_output_storage = [_]f32{12345.0} ** 12;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    var inputs = [_]TensorView{testView(f32, &input_storage, 2, dimensions, strides)};
    var outputs = [_]TensorView{
        testView(f32, &first_output_storage, 2, dimensions, strides),
        testView(f32, &second_output_storage, 2, dimensions, strides),
    };
    const input_element_types = [_]u32{@intFromEnum(ElementType.float32)};
    const output_element_types = [_]u32{
        @intFromEnum(ElementType.float32),
        @intFromEnum(ElementType.float32),
    };
    const arguments = NamedOperationArgumentsV3{
        .function_name = "zml_cpu_split_f32",
        .function_name_length = "zml_cpu_split_f32".len,
        .input_count = 1,
        .output_count = 2,
        .reserved = 0,
        .inputs = inputs[0..].ptr,
        .input_element_types = input_element_types[0..].ptr,
        .outputs = outputs[0..].ptr,
        .output_element_types = output_element_types[0..].ptr,
        .permutation = ([_]u32{0} ++ [_]u32{0} ** (max_rank - 1))[0..].ptr,
    };
    var probe = NamedOperationV3Probe{};
    const backend = NamedOperationBackendV3{
        .abi_version = named_operation_backend_v3_abi_version,
        .context = @ptrCast(&probe),
        .query = namedSplitQuery,
        .operation = namedSplitProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_named_operation_backend_v3(&backend));
    defer _ = zpu_cpu_ml_set_named_operation_backend_v3(null);

    var signature = std.mem.zeroes(NamedOperationSignatureV3);
    try std.testing.expectEqual(Status.ok, namedOperationSupportedV3("zml_cpu_split_f32", &signature));
    try std.testing.expectEqual(@as(u32, 1), signature.input_count);
    try std.testing.expectEqual(@as(u32, 2), signature.output_count);
    try std.testing.expectEqual(Status.ok, namedOperationV3(&arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
    try std.testing.expectEqual(@as(usize, 2), probe.input_stride);
    try std.testing.expectEqual(@as(usize, 2), probe.first_output_stride);
    try std.testing.expectEqual(@as(usize, 2), probe.second_output_stride);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 2, 3, 12345, 12345, 4, 5, 12345, 12345, 6, 7, 12345, 12345 }, &first_output_storage);
    try std.testing.expectEqualSlices(f32, &[_]f32{ 2, 4, 12345, 12345, 6, 8, 12345, 12345, 10, 12, 12345, 12345 }, &second_output_storage);

    var invalid_arguments = arguments;
    invalid_arguments.reserved = 1;
    try std.testing.expectEqual(Status.invalid_argument, namedOperationV3(&invalid_arguments));
    try std.testing.expectEqual(@as(usize, 2), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.operation_calls);
}

test "v2 named entry point rejects over-limit legacy provider signatures" {
    var left_storage = [_]f32{1};
    var middle_storage = [_]f32{2};
    var right_storage = [_]f32{3};
    var destination_storage = [_]f32{0};
    const dimensions = [_]usize{1} ++ [_]usize{0} ** (max_rank - 1);
    const strides = [_]usize{1} ++ [_]usize{0} ** (max_rank - 1);
    const inputs = [_]TensorView{
        testView(f32, &left_storage, 1, dimensions, strides),
        testView(f32, &middle_storage, 1, dimensions, strides),
        testView(f32, &right_storage, 1, dimensions, strides),
    };
    const arguments = NamedOperationArgumentsV2{
        .function_name = "zml_cpu_legacy_three_input",
        .function_name_length = "zml_cpu_legacy_three_input".len,
        .input_count = 3,
        .element_type = @intFromEnum(ElementType.float32),
        .reserved = 0,
        .inputs = inputs[0..].ptr,
        .destination = testView(f32, &destination_storage, 1, dimensions, strides),
        .permutation = ([_]u32{0} ++ [_]u32{0} ** (max_rank - 1))[0..].ptr,
    };
    var probe = NamedOperationProbe{};
    const backend = NamedOperationBackend{
        .abi_version = named_operation_backend_abi_version,
        .context = @ptrCast(&probe),
        .query = legacyThreeInputQuery,
        .operation = legacyThreeInputProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_named_operation_backend(&backend));
    defer _ = zpu_cpu_ml_set_named_operation_backend(null);

    try std.testing.expectEqual(Status.invalid_argument, namedOperationV2(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.query_calls);
    try std.testing.expectEqual(@as(usize, 0), probe.operation_calls);
    try std.testing.expectEqual(@as(f32, 0), destination_storage[0]);
}

test "optional CPU provider preserves packed 4-bit tensor padding" {
    var source_storage = [_]u8{0} ** 8;
    source_storage[0] = 0x21;
    source_storage[2] = 0x43;
    source_storage[4] = 0x65;
    var destination_storage = [_]u8{0xaa} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    var arguments = TransposeArguments{
        .source = .{
            .data = source_storage[0..].ptr,
            .byte_length = source_storage.len,
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 4,
            .dimensions = dimensions,
            .strides = strides,
        },
        .destination = .{
            .data = destination_storage[0..].ptr,
            .byte_length = destination_storage.len,
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 4,
            .dimensions = output_dimensions,
            .strides = output_strides,
        },
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    var probe = ProviderProbe{};
    const context: *anyopaque = @ptrCast(&probe);
    const backend = Backend{
        .abi_version = backend_abi_version,
        .context = context,
        .transpose = referenceProvider,
    };
    try std.testing.expectEqual(@as(c_int, 0), zpu_cpu_ml_set_backend(&backend));
    defer _ = zpu_cpu_ml_set_backend(null);

    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 2), probe.source_stride);
    try std.testing.expectEqual(@as(usize, 3), probe.destination_stride);
    try std.testing.expectEqual(@as(u8, 0x31), destination_storage[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), destination_storage[1]);
    try std.testing.expectEqual(@as(u8, 0x42), destination_storage[2]);
    try std.testing.expectEqual(@as(u8, 0xa6), destination_storage[3]);
    try std.testing.expectEqual(@as(u8, 0xaa), destination_storage[4]);
}

test "CPU transpose preserves Metal element strides and raw bytes" {
    var source_storage = [_]u32{0} ** 12;
    source_storage[0] = 0x3f800001;
    source_storage[1] = 0x40000002;
    source_storage[4] = 0x40400003;
    source_storage[5] = 0x40800004;
    source_storage[8] = 0x40a00005;
    source_storage[9] = 0x40c00006;
    var destination_storage = [_]u32{0xdeadbeef} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = TransposeArguments{
        .source = testView(u32, &source_storage, 2, dimensions, strides),
        .destination = testView(u32, &destination_storage, 2, output_dimensions, output_strides),
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqual(@as(u32, 0x3f800001), destination_storage[0]);
    try std.testing.expectEqual(@as(u32, 0x40400003), destination_storage[1]);
    try std.testing.expectEqual(@as(u32, 0x40a00005), destination_storage[2]);
    try std.testing.expectEqual(@as(u32, 0x40000002), destination_storage[4]);
    try std.testing.expectEqual(@as(u32, 0x40800004), destination_storage[5]);
    try std.testing.expectEqual(@as(u32, 0x40c00006), destination_storage[6]);
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), destination_storage[3]);
}

test "CPU transpose preserves packed Int4 nibbles" {
    var source_storage = [_]u8{0} ** 8;
    // Logical source dimensions are [2, 3], with the second axis padded to
    // four elements.  Values by logical coordinate are 1..6.
    source_storage[0] = 0x21;
    source_storage[2] = 0x43;
    source_storage[4] = 0x65;
    var destination_storage = [_]u8{0xaa} ** 8;
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const output_dimensions = [_]usize{ 3, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    const output_strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2);
    var arguments = TransposeArguments{
        .source = .{
            .data = source_storage[0..].ptr,
            .byte_length = source_storage.len,
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 4,
            .dimensions = dimensions,
            .strides = strides,
        },
        .destination = .{
            .data = destination_storage[0..].ptr,
            .byte_length = destination_storage.len,
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 4,
            .dimensions = output_dimensions,
            .strides = output_strides,
        },
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqual(@as(u8, 0x31), destination_storage[0]);
    try std.testing.expectEqual(@as(u8, 0xa5), destination_storage[1]);
    try std.testing.expectEqual(@as(u8, 0x42), destination_storage[2]);
    try std.testing.expectEqual(@as(u8, 0xa6), destination_storage[3]);
    try std.testing.expectEqual(@as(u8, 0xaa), destination_storage[4]);
}

test "CPU transpose snapshots overlapping storage before writing" {
    var storage = [_]u32{ 1, 2, 3, 4 };
    const dimensions = [_]usize{ 2, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const strides = [_]usize{ 1, 2 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = TransposeArguments{
        .source = testView(u32, &storage, 2, dimensions, strides),
        .destination = testView(u32, &storage, 2, dimensions, strides),
        .permutation = [_]u32{ 1, 0 } ++ [_]u32{0} ** (max_rank - 2),
    };
    try std.testing.expectEqual(Status.ok, transpose(&arguments));
    try std.testing.expectEqualSlices(u32, &[_]u32{ 1, 3, 2, 4 }, &storage);
}

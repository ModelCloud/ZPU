// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Portable CPU tensor execution contracts used by the Metal-shaped layer.
//!
//! The public Metal adapter owns the object graph and the tensor ABI.  This
//! module deliberately knows nothing about Metal, Foundation, or the host
//! operating system.  It accepts raw storage views so an optional ZML CPU
//! backend can be inserted without changing the adapter's layout or lifetime
//! semantics.  The reference implementation is also the exact-layout
//! fallback for views that cannot be represented by a dense compiler buffer.

const std = @import("std");

pub const max_rank: usize = 16;
pub const max_inputs: usize = 2;

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
    var dense_view: TensorView = .{
        .data = dense.ptr,
        .byte_length = dense.len,
        .offset_bytes = 0,
        .rank = @intCast(source_info.rank),
        .element_bits = source_info.element_bits,
        .dimensions = source.dimensions,
        .strides = undefined,
    };
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
    var view = template;
    view.data = storage.ptr;
    view.byte_length = storage.len;
    view.offset_bytes = 0;
    view.strides = undefined;
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

/// Stage an operation's raw ZPU views into dense CPU views for the optional
/// ZML/cpu provider. The provider never sees an Apple resource or an
/// Apple-specific tensor layout. A successful provider call is scattered back
/// into the original destination only after the callback returns successfully.
pub fn operation(arguments: *const OperationArguments) Status {
    const operation_kind = operationFromRaw(arguments.operation) orelse return .invalid_argument;
    _ = elementTypeFromRaw(arguments.element_type) orelse return .invalid_argument;
    const expected_inputs = operationInputCount(operation_kind) orelse return .invalid_argument;
    if (arguments.input_count != expected_inputs) return .invalid_argument;
    const backend = operationBackendSnapshot() orelse return .unsupported;
    const callback = backend.operation orelse return .unsupported;

    var input_info: [max_inputs]?ViewInfo = @splat(null);
    var input_storage: [max_inputs]?[]u8 = @splat(null);
    defer for (&input_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_inputs: [max_inputs]TensorView = undefined;
    for (0..expected_inputs) |index| {
        input_info[index] = validateView(&arguments.inputs[index]) orelse return .invalid_argument;
        const info = input_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        input_storage[index] = storage;
        @memset(storage, 0);
        if (!copySourceToDense(&arguments.inputs[index], info, storage)) return .invalid_argument;
        dense_inputs[index] = makeDenseView(arguments.inputs[index], info, storage);
    }

    const destination_info = validateView(&arguments.destination) orelse return .invalid_argument;
    const destination_bytes = denseByteCount(destination_info) orelse return .invalid_argument;
    const destination_storage = std.heap.c_allocator.alloc(u8, destination_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(destination_storage);
    @memset(destination_storage, 0);
    var dense_arguments = OperationArguments{
        .operation = arguments.operation,
        .element_type = arguments.element_type,
        .input_count = arguments.input_count,
        .reserved = 0,
        .inputs = dense_inputs,
        .destination = makeDenseView(arguments.destination, destination_info, destination_storage),
        .permutation = arguments.permutation,
    };
    const status = providerStatus(callback(backend.context, &dense_arguments));
    if (status != .ok) return status;
    const validated_dense_destination = validateView(&dense_arguments.destination) orelse return .invalid_argument;
    if (!copyDenseToDestination(&dense_arguments.destination, validated_dense_destination, &arguments.destination, destination_info)) return .invalid_argument;
    return .ok;
}

fn validNamedOperationName(name: ?[*]const u8, length: usize) bool {
    return name != null and length != 0;
}

/// Ask the registered provider whether a named CPU graph/function is
/// available. The caller owns the returned signature storage.
pub fn namedOperationSupported(name: []const u8, signature: *NamedOperationSignature) Status {
    if (name.len == 0) return .invalid_argument;
    const backend = namedOperationBackendSnapshot() orelse return .unsupported;
    const callback = backend.query orelse return .unsupported;
    const status = providerStatus(callback(backend.context, name.ptr, name.len, signature));
    if (status != .ok) return status;
    if (signature.input_count == 0 or signature.input_count > max_inputs or
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
/// Metal, or platform-specific storage/layout object.
pub fn namedOperation(arguments: *const NamedOperationArguments) Status {
    if (!validNamedOperationName(arguments.function_name, arguments.function_name_length)) {
        return .invalid_argument;
    }
    const backend = namedOperationBackendSnapshot() orelse return .unsupported;
    const query = backend.query orelse return .unsupported;
    const callback = backend.operation orelse return .unsupported;
    var signature = NamedOperationSignature{ .input_count = 0, .element_type = 0 };
    const name = arguments.function_name.?[0..arguments.function_name_length];
    const query_status = providerStatus(query(backend.context, name.ptr, name.len, &signature));
    if (query_status != .ok) return query_status;
    if (signature.input_count == 0 or signature.input_count > max_inputs or
        arguments.input_count != signature.input_count or
        arguments.element_type != signature.element_type or
        elementTypeFromRaw(arguments.element_type) == null) return .invalid_argument;

    var input_info: [max_inputs]?ViewInfo = @splat(null);
    var input_storage: [max_inputs]?[]u8 = @splat(null);
    defer for (&input_storage) |*storage| {
        if (storage.*) |bytes| std.heap.c_allocator.free(bytes);
    };
    var dense_inputs: [max_inputs]TensorView = undefined;
    for (0..signature.input_count) |index| {
        input_info[index] = validateView(&arguments.inputs[index]) orelse return .invalid_argument;
        const info = input_info[index].?;
        const byte_count = denseByteCount(info) orelse return .invalid_argument;
        const storage = std.heap.c_allocator.alloc(u8, byte_count) catch return .out_of_memory;
        input_storage[index] = storage;
        @memset(storage, 0);
        if (!copySourceToDense(&arguments.inputs[index], info, storage)) return .invalid_argument;
        dense_inputs[index] = makeDenseView(arguments.inputs[index], info, storage);
    }

    const destination_info = validateView(&arguments.destination) orelse return .invalid_argument;
    const destination_bytes = denseByteCount(destination_info) orelse return .invalid_argument;
    const destination_storage = std.heap.c_allocator.alloc(u8, destination_bytes) catch return .out_of_memory;
    defer std.heap.c_allocator.free(destination_storage);
    @memset(destination_storage, 0);
    var dense_arguments = NamedOperationArguments{
        .function_name = name.ptr,
        .function_name_length = name.len,
        .input_count = arguments.input_count,
        .element_type = arguments.element_type,
        .reserved = 0,
        .inputs = dense_inputs,
        .destination = makeDenseView(arguments.destination, destination_info, destination_storage),
        .permutation = arguments.permutation,
    };
    const status = providerStatus(callback(backend.context, &dense_arguments));
    if (status != .ok) return status;
    const validated_dense_destination = validateView(&dense_arguments.destination) orelse return .invalid_argument;
    if (!copyDenseToDestination(&dense_arguments.destination, validated_dense_destination, &arguments.destination, destination_info)) return .invalid_argument;
    return .ok;
}

/// Stage a Metal/ZPU view into dense CPU memory for the optional provider.
///
/// ZML's CPU buffer import contract is intentionally narrower than Metal's
/// tensor view contract: the provider sees offset-zero, axis-0-fast, dense
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

    const validated_dense_destination = validateView(&dense_arguments.destination) orelse return .invalid_argument;
    if (!copyDenseToDestination(&dense_arguments.destination, validated_dense_destination, &arguments.destination, destination_info)) return .invalid_argument;
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

const OperationProbe = struct {
    calls: usize = 0,
    operation: u32 = 0,
    element_type: u32 = 0,
    source_stride: usize = 0,
    destination_stride: usize = 0,
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

fn addOperationProvider(context: ?*anyopaque, arguments: *const OperationArguments) callconv(.c) c_int {
    const probe = @as(*OperationProbe, @ptrCast(@alignCast(context orelse return @intFromEnum(Status.invalid_argument))));
    probe.calls += 1;
    probe.operation = arguments.operation;
    probe.element_type = arguments.element_type;
    probe.source_stride = arguments.inputs[0].strides[1];
    probe.destination_stride = arguments.destination.strides[1];
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
    const dimensions = [_]usize{ 2, 3 } ++ [_]usize{0} ** (max_rank - 2);
    const arguments = OperationArguments{
        .operation = @intFromEnum(Operation.add),
        .element_type = @intFromEnum(ElementType.uint32),
        .input_count = 2,
        .reserved = 0,
        .inputs = .{
            .{ .data = @ptrCast(left_storage[0..].ptr), .byte_length = left_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2) },
            .{ .data = @ptrCast(right_storage[0..].ptr), .byte_length = right_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2) },
        },
        .destination = .{ .data = @ptrCast(destination_storage[0..].ptr), .byte_length = destination_storage.len * @sizeOf(u32), .offset_bytes = 0, .rank = 2, .element_bits = 32, .dimensions = dimensions, .strides = [_]usize{ 1, 4 } ++ [_]usize{0} ** (max_rank - 2) },
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

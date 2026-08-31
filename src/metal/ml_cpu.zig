// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Portable CPU tensor execution contracts for the Metal-shaped layer.
//!
//! The public Metal adapter owns the object graph and the tensor ABI.  This
//! module deliberately knows nothing about Metal, Foundation, or the host
//! operating system.  It accepts raw storage views so an optional ZML CPU
//! backend can be inserted without changing Metal's layout or lifetime
//! semantics.  The reference implementation is also the exact-layout
//! fallback for views that cannot be represented by a dense compiler buffer.

const std = @import("std");

pub const max_rank: usize = 16;

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

fn copyElement(source: *const TensorView, source_info: ViewInfo, source_element: usize,
               destination: *const TensorView, destination_info: ViewInfo, destination_element: usize) bool {
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
    @memcpy(destination_data[destination_offset .. destination_offset + destination_info.element_bytes],
        source_data[source_offset .. source_offset + source_info.element_bytes]);
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

fn incrementCoordinates(coordinates: *[max_rank]usize, dimensions: []const usize) void {
    for (0..dimensions.len) |axis| {
        coordinates[axis] += 1;
        if (coordinates[axis] < dimensions[axis]) return;
        coordinates[axis] = 0;
    }
}

/// Execute a raw tensor transpose on CPU.  This function has no Metal or
/// operating-system dependency and is suitable as the ABI-preserving fallback
/// beneath either ZPU's scalar path or an optional ZML CPU plan.
pub fn transpose(arguments: *const TransposeArguments) Status {
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

pub export fn zpu_metal_cpu_ml_transpose(arguments: ?*const TransposeArguments) callconv(.c) c_int {
    const args = arguments orelse return @intFromEnum(Status.invalid_argument);
    return @intFromEnum(transpose(args));
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

const std = @import("std");

pub const magic: u32 = 0x0723_0203;
pub const ingestion_version: u32 = 1;
pub const serialization_version: u32 = 1;
/// Vulkan 1.0 advertises support for SPIR-V 1.0. No later SPIR-V capability is
/// exposed by this driver, so ingestion deliberately accepts exactly 1.0.
pub const supported_spirv_version: u32 = 0x0001_0000;
pub const max_code_bytes: usize = 1024 * 1024;
pub const max_id_bound: u32 = 0x003f_ffff;

pub const ParseError = error{
    Empty,
    MisalignedSize,
    TooLarge,
    TruncatedHeader,
    BadMagic,
    BadVersion,
    BadSchema,
    BadBound,
    BadInstruction,
    OutOfMemory,
};

pub const Identity = struct {
    ingestion: u32,
    serialization: u32,
    digest: [32]u8,

    pub fn eql(a: Identity, b: Identity) bool {
        return a.ingestion == b.ingestion and
            a.serialization == b.serialization and
            std.mem.eql(u8, &a.digest, &b.digest);
    }
};

pub const Module = struct {
    words: []u32,
    identity: Identity,

    pub fn parse(allocator: std.mem.Allocator, source: []const u32) ParseError!Module {
        const byte_len = std.math.mul(usize, source.len, @sizeOf(u32)) catch return error.TooLarge;
        if (byte_len == 0) return error.Empty;
        if (byte_len > max_code_bytes) return error.TooLarge;
        try validate(source);

        const owned = allocator.dupe(u32, source) catch return error.OutOfMemory;
        return .{ .words = owned, .identity = identify(owned) };
    }

    pub fn deinit(module: *Module, allocator: std.mem.Allocator) void {
        allocator.free(module.words);
        module.* = undefined;
    }

    pub fn eql(a: *const Module, b: *const Module) bool {
        return a.identity.eql(b.identity) and std.mem.eql(u32, a.words, b.words);
    }
};

pub fn validateByteSize(code_size: usize) ParseError!usize {
    if (code_size == 0) return error.Empty;
    if (code_size % @sizeOf(u32) != 0) return error.MisalignedSize;
    if (code_size > max_code_bytes) return error.TooLarge;
    return code_size / @sizeOf(u32);
}

fn validate(words: []const u32) ParseError!void {
    if (words.len < 5) return error.TruncatedHeader;
    if (words[0] != magic) return error.BadMagic;
    if (words[1] != supported_spirv_version) return error.BadVersion;
    if (words[3] == 0 or words[3] > max_id_bound) return error.BadBound;
    if (words[4] != 0) return error.BadSchema;

    var offset: usize = 5;
    while (offset < words.len) {
        const instruction_words: usize = words[offset] >> 16;
        if (instruction_words == 0 or instruction_words > words.len - offset) return error.BadInstruction;
        offset += instruction_words;
    }
}

fn identify(words: []const u32) Identity {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var encoded: [4]u8 = undefined;
    std.mem.writeInt(u32, &encoded, ingestion_version, .little);
    hash.update(&encoded);
    std.mem.writeInt(u32, &encoded, serialization_version, .little);
    hash.update(&encoded);
    for (words) |word| {
        std.mem.writeInt(u32, &encoded, word, .little);
        hash.update(&encoded);
    }
    return .{
        .ingestion = ingestion_version,
        .serialization = serialization_version,
        .digest = hash.finalResult(),
    };
}

test "module owns exact words and identity is deterministic and content-sensitive" {
    var source = [_]u32{ magic, 0x0001_0000, 0, 2, 0, 0x0001_0000 };
    var first = try Module.parse(std.testing.allocator, &source);
    defer first.deinit(std.testing.allocator);
    var second = try Module.parse(std.testing.allocator, &source);
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(first.eql(&second));
    try std.testing.expect(first.identity.eql(second.identity));
    try std.testing.expectEqual(ingestion_version, first.identity.ingestion);
    try std.testing.expectEqual(serialization_version, first.identity.serialization);
    try std.testing.expectEqualSlices(u8, &.{
        0xf2, 0xfb, 0x1e, 0x8b, 0x1d, 0x9c, 0xba, 0xf8,
        0x4e, 0x35, 0x2d, 0x03, 0x1a, 0xe5, 0xec, 0xd7,
        0x61, 0x2d, 0xf7, 0xc6, 0x33, 0x58, 0x71, 0xaf,
        0x2c, 0xb4, 0x79, 0x8b, 0xe3, 0x10, 0x47, 0x79,
    }, &first.identity.digest);
    source[5] = 0x0001_0001;
    try std.testing.expectEqual(@as(u32, 0x0001_0000), first.words[5]);
    var different = try Module.parse(std.testing.allocator, &source);
    defer different.deinit(std.testing.allocator);
    try std.testing.expect(!first.eql(&different));
    try std.testing.expect(!first.identity.eql(different.identity));

    var collision_words = [_]u32{ magic, supported_spirv_version, 0, 2, 0, 0x0001_0001 };
    const forced_collision = Module{ .words = &collision_words, .identity = first.identity };
    try std.testing.expect(first.identity.eql(forced_collision.identity));
    try std.testing.expect(!first.eql(&forced_collision));
}

test "identity hashes version metadata and semantic words as canonical little endian bytes" {
    const words = [_]u32{ magic, supported_spirv_version, 0, 2, 0, 0x0001_0000 };
    const semantic_bytes = [_]u8{
        0x01, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00,
        0x03, 0x02, 0x23, 0x07, 0x00, 0x00, 0x01, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x00,
    };
    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&semantic_bytes, &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &identify(&words).digest);
}

test "supported SPIR-V version policy accepts only 1.0" {
    const rejected = [_]u32{
        0,
        supported_spirv_version - 1,
        supported_spirv_version + 1,
        0x0001_0100,
        0x0001_0600,
        0x0002_0000,
        std.math.maxInt(u32),
    };
    for (rejected) |version| {
        const words = [_]u32{ magic, version, 0, 1, 0 };
        try std.testing.expectError(error.BadVersion, Module.parse(std.testing.allocator, &words));
    }
    var accepted = try Module.parse(std.testing.allocator, &.{ magic, supported_spirv_version, 0, 1, 0 });
    accepted.deinit(std.testing.allocator);
}

test "byte size and every structural boundary are rejected" {
    try std.testing.expectError(error.Empty, validateByteSize(0));
    try std.testing.expectError(error.MisalignedSize, validateByteSize(5));
    try std.testing.expectError(error.TooLarge, validateByteSize(max_code_bytes + 4));
    try std.testing.expectEqual(@as(usize, 5), try validateByteSize(20));

    const cases = [_]struct { expected: ParseError, words: []const u32 }{
        .{ .expected = error.Empty, .words = &.{} },
        .{ .expected = error.TruncatedHeader, .words = &.{ magic, 0x0001_0000, 0, 1 } },
        .{ .expected = error.BadMagic, .words = &.{ 0, 0x0001_0000, 0, 1, 0 } },
        .{ .expected = error.BadVersion, .words = &.{ magic, 0x0000_0000, 0, 1, 0 } },
        .{ .expected = error.BadBound, .words = &.{ magic, 0x0001_0000, 0, 0, 0 } },
        .{ .expected = error.BadBound, .words = &.{ magic, 0x0001_0000, 0, max_id_bound + 1, 0 } },
        .{ .expected = error.BadSchema, .words = &.{ magic, 0x0001_0000, 0, 1, 1 } },
        .{ .expected = error.BadInstruction, .words = &.{ magic, 0x0001_0000, 0, 1, 0, 0 } },
        .{ .expected = error.BadInstruction, .words = &.{ magic, 0x0001_0000, 0, 1, 0, 0x0002_0000 } },
    };
    for (cases) |case| try std.testing.expectError(case.expected, Module.parse(std.testing.allocator, case.words));

    const oversized = try std.testing.allocator.alloc(u32, max_code_bytes / 4 + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.TooLarge, Module.parse(std.testing.allocator, oversized));
}

test "allocation failure leaves source ownership untouched" {
    const words = [_]u32{ magic, 0x0001_0000, 0, 1, 0 };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, Module.parse(failing.allocator(), &words));
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

const std = @import("std");
const frontend = @import("frontend");
const ir = frontend.ir;

const seed: u64 = 0x5a50_5549_5233_4431;

fn freeInstructions(items: []ir.Instruction) void {
    for (items) |item| {
        std.testing.allocator.free(item.operands);
        std.testing.allocator.free(item.literal);
    }
    std.testing.allocator.free(items);
}

test "seed-replay arbitrary byte and structured instruction corpus is total" {
    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var storage: [128]u32 = undefined;
    for (0..2048) |_| {
        random.bytes(std.mem.sliceAsBytes(&storage));
        const length = random.uintLessThan(usize, storage.len + 1);
        if (frontend.decode.Module.decode(std.testing.allocator, storage[0..length])) |module_value| {
            var module = module_value;
            module.deinit(std.testing.allocator);
        } else |_| {}
        if (frontend.compile(std.testing.allocator, storage[0..length], if (random.boolean()) .vertex else .fragment, "main", &.{})) |program_value| {
            var program = program_value;
            program.deinit(std.testing.allocator);
        } else |_| {}
    }

    for (0..2048) |_| {
        var words = frontend.positive_vertex;
        const offset = 5 + random.uintLessThan(usize, words.len - 5);
        if (random.boolean()) words[offset] ^= @as(u32, 1) << @intCast(random.uintLessThan(u6, 32)) else words[offset] = random.int(u32);
        if (frontend.compile(std.testing.allocator, &words, .vertex, "main", &.{})) |program_value| {
            var program = program_value;
            program.deinit(std.testing.allocator);
        } else |_| {}
    }
}

test "seed-replay valid profile and canonicalization property corpus" {
    var prng = std.Random.DefaultPrng.init(seed ^ 0xa5a5_a5a5_a5a5_a5a5);
    const random = prng.random();
    for (0..256) |_| {
        var words = frontend.positive_vertex;
        var cursor: usize = 5;
        while (cursor < words.len) : (cursor += words[cursor] >> 16) {
            if (@as(u16, @truncate(words[cursor])) == 43) {
                const finite_bits = random.int(u32) & 0x7f7f_ffff;
                words[cursor + 3] = finite_bits;
                break;
            }
        }
        var program = try frontend.compile(std.testing.allocator, &words, .vertex, "main", &.{});
        defer program.deinit(std.testing.allocator);
        const once = try ir.canonicalize(std.testing.allocator, program.instructions);
        defer freeInstructions(once);
        const twice = try ir.canonicalize(std.testing.allocator, once);
        defer freeInstructions(twice);
        const first_bytes = try ir.serialize(std.testing.allocator, program.stage, program.entry_name, program.interfaces, once);
        defer std.testing.allocator.free(first_bytes);
        const second_bytes = try ir.serialize(std.testing.allocator, program.stage, program.entry_name, program.interfaces, twice);
        defer std.testing.allocator.free(second_bytes);
        try std.testing.expectEqualSlices(u8, first_bytes, second_bytes);
        try std.testing.expect(ir.identify(first_bytes).eql(ir.identify(second_bytes)));
    }
}

test "seed-replay declaration permutation property corpus" {
    var prng = std.Random.DefaultPrng.init(seed ^ 0x4445_434c_5045_524d);
    const random = prng.random();
    for (0..256) |_| {
        var reordered = frontend.rich_vertex;
        var cursor: usize = 5;
        while (@as(u16, @truncate(reordered[cursor])) != 44) cursor += reordered[cursor] >> 16;
        const first_len: usize = reordered[cursor] >> 16;
        const second = cursor + first_len;
        const second_len: usize = reordered[second] >> 16;
        var temporary: [18]u32 = undefined;
        @memcpy(temporary[0..first_len], reordered[cursor..second]);
        std.mem.copyForwards(u32, reordered[cursor..][0..second_len], reordered[second..][0..second_len]);
        @memcpy(reordered[cursor + second_len ..][0..first_len], temporary[0..first_len]);
        const finite = random.int(u32) & 0x7f7f_ffff;
        var replacement: [4]u8 = undefined;
        std.mem.writeInt(u32, &replacement, finite, .little);
        const specs = [_]frontend.Specialization{.{ .id = 7, .bytes = &replacement }};
        var original = try frontend.compile(std.testing.allocator, &frontend.rich_vertex, .vertex, "main", &specs);
        defer original.deinit(std.testing.allocator);
        var permuted = try frontend.compile(std.testing.allocator, &reordered, .vertex, "main", &specs);
        defer permuted.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, original.bytes, permuted.bytes);
        try std.testing.expect(original.identity.eql(permuted.identity));
    }
}

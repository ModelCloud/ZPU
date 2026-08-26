//! Single source of truth for the separately compiled eight-lane kernel ABI.
//!
//! Both sides derive their declarations from this file:
//! - `simd/dispatch.zig` resolves the extern symbols via `@extern`.
//! - `x86_64_v3_kernels.zig` publishes the implementations via `@export`.
//! - `tools/isa_disasm_gate.sh` matches these exact exported symbol names as
//!   the only legitimate VEX-carrying functions; a test below asserts the
//!   gate script stays in sync with this list.

pub const fill_span_8_name = "zpu_v3_fill_span_8";
pub const blend_span_8_name = "zpu_v3_blend_span_8";
pub const blend_pixels_8_name = "zpu_v3_blend_pixels_8";

pub const FillSpan8Fn = *const fn ([*]u8, usize, usize, usize, u8, u32) callconv(.c) void;
pub const BlendSpan8Fn = *const fn ([*]u8, usize, usize, usize, u8, u32) callconv(.c) void;
pub const BlendPixels8Fn = *const fn ([*]u8, usize, usize, [*]const u8, usize, usize, u8) callconv(.c) void;

/// Exact exported symbol names. The disassembly gate treats these (matched on
/// the final dot-separated component) as the only functions allowed to carry
/// VEX-encoded instructions.
pub const exported_symbols = [_][]const u8{ fill_span_8_name, blend_span_8_name, blend_pixels_8_name };

test "gate script pins the same kernel symbol set" {
    const io = std.testing.io;
    const script = try std.Io.Dir.cwd().readFileAlloc(
        io,
        "tools/isa_disasm_gate.sh",
        std.testing.allocator,
        .limited(1 << 20),
    );
    defer std.testing.allocator.free(script);
    for (exported_symbols) |name| {
        try std.testing.expect(std.mem.indexOf(u8, script, name) != null);
    }
}

const std = @import("std");

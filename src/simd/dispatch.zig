const builtin = @import("builtin");
const s = @import("../surface.zig");
const scalar = @import("../raster/scalar.zig");
const vector = @import("vector.zig");

/// Portable vectors carry no host-ISA promise. AVX2 is host gated. AVX-512 is
/// excluded pending controlled evidence that it improves frame-time tails.
pub const Backend = enum { scalar, portable_vector, avx2 };

pub fn available(backend: Backend) bool {
    if (backend == .scalar or backend == .portable_vector) return true;
    if (builtin.cpu.arch != .x86_64 and builtin.cpu.arch != .x86) return false;
    const leaf1 = cpuid(1, 0);
    const osxsave = leaf1.c & (1 << 27) != 0;
    const avx = leaf1.c & (1 << 28) != 0;
    if (!osxsave or !avx) return false;
    const xcr0 = xgetbv();
    if ((xcr0 & 0x6) != 0x6) return false;
    const leaf7 = cpuid(7, 0);
    return leaf7.b & (1 << 5) != 0;
}

pub fn best() Backend {
    if (available(.avx2)) return .avx2;
    return .portable_vector;
}

pub fn fillSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.fillSpan(row, start, count, format, color),
        .portable_vector => vector.fill(4, row, start, count, format, color),
        .avx2 => vector.fill(8, row, start, count, format, color),
    }
}
pub fn blendSpan(backend: Backend, row: []u8, start: usize, count: usize, format: s.Format, color: s.Color) void {
    switch (backend) {
        .scalar => scalar.blendSpan(row, start, count, format, color),
        .portable_vector => vector.blend(4, row, start, count, format, color),
        .avx2 => vector.blend(8, row, start, count, format, color),
    }
}
pub fn blendPixels(backend: Backend, row: []u8, start: usize, source: []const u8, count: usize, format: s.Format) void {
    switch (backend) {
        .scalar => scalar.blendPixels(row, start, source, count, format),
        .portable_vector => vector.blendPixels(4, row, start, source, count, format),
        .avx2 => vector.blendPixels(8, row, start, source, count, format),
    }
}

const Cpuid = struct { a: u32, b: u32, c: u32, d: u32 };
fn cpuid(leaf: u32, subleaf: u32) Cpuid {
    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var a: u32 = leaf;
        var b: u32 = undefined;
        var c: u32 = subleaf;
        var d: u32 = undefined;
        asm volatile ("cpuid"
            : [a] "+{eax}" (a),
              [b] "={ebx}" (b),
              [c] "+{ecx}" (c),
              [d] "={edx}" (d),
            :
            : .{ .memory = true });
        return .{ .a = a, .b = b, .c = c, .d = d };
    } else return .{ .a = 0, .b = 0, .c = 0, .d = 0 };
}
fn xgetbv() u64 {
    if (comptime builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .x86) {
        var eax: u32 = undefined;
        var edx: u32 = undefined;
        asm volatile ("xgetbv"
            : [eax] "={eax}" (eax),
              [edx] "={edx}" (edx),
            : [ecx] "{ecx}" (@as(u32, 0)),
        );
        return (@as(u64, edx) << 32) | eax;
    } else return 0;
}

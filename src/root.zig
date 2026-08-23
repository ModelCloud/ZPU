//! ZPU CPU graphics foundation and experimental loader-compatible Vulkan ICD.
pub const surface = @import("surface.zig");
pub const raster = @import("raster/raster.zig");
pub const simd = @import("simd/dispatch.zig");
pub const command = @import("command/processor.zig");
pub const vulkan = @import("vulkan/icd.zig");
pub const platform = @import("platform/presenter.zig");

test {
    _ = @import("tests.zig");
    _ = @import("vulkan/driver.zig");
}

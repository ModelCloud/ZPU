// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Dedicated test root for the Metal layer. It keeps the Metal unit tests
//! runnable on macOS without pulling the Linux Vulkan/XCB driver graph into
//! the test process.

test {
    _ = @import("metal/abi.zig");
    _ = @import("metal/mapping.zig");
    _ = @import("metal/raster3d.zig");
    _ = @import("metal/cpu.zig");
    _ = @import("cpu_ml.zig");
    _ = @import("metal/c_api.zig");
    _ = @import("metal/runtime.zig");
}

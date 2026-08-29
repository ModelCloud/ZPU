// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! ZPU's native CPU Metal layer. The public surface uses Metal concepts but
//! does not pretend to be Apple's Objective-C runtime ABI.
pub const abi = @import("metal/abi.zig");
pub const mapping = @import("metal/mapping.zig");
pub const cpu = @import("metal/cpu.zig");
pub const raster3d = @import("metal/raster3d.zig");
pub const runtime = @import("metal/runtime.zig");

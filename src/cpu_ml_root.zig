// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

//! Standalone root for the host-OS-neutral CPU ML provider seam.
//!
//! This root intentionally imports no Apple or Metal module.  It is packaged
//! separately so a ZML CPU provider can use the same ABI on macOS, iOS,
//! Linux, or another supported target without pulling in an Apple SDK.

const ml_cpu = @import("metal/ml_cpu.zig");

comptime {
    _ = ml_cpu;
}

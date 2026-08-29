// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

#ifndef ZPU_METAL_APPLE_H
#define ZPU_METAL_APPLE_H

#if defined(__APPLE__)
#import <Metal/Metal.h>

/* Explicit opt-in factory for the ZPU CPU-backed Metal-shaped object graph.
 * This does not interpose Apple's MTLCreateSystemDefaultDevice symbol. */
id<MTLDevice> ZPUMetalCreateSystemDefaultDevice(void);

/* Create a Metal-shaped CPU function descriptor for a function name known by
 * the ZPU runtime. This is metadata only: it does not compile MSL. */
id<MTLFunction> ZPUMetalCreateCPUFunction(id<MTLDevice> device, NSString *name);
#endif

#endif

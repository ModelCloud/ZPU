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

/* Create a CPU-owned drawable around an existing ZPU texture. Presentation
 * is a logical CPU operation: it never imports CAMetalLayer, IOSurface, or an
 * Apple drawable. The texture remains owned by the device returned from
 * ZPUMetalCreateSystemDefaultDevice and can be rendered into before the
 * drawable is presented. */
API_AVAILABLE(macos(10.11), ios(8.0))
id<MTLDrawable> ZPUMetalCreateCPUDrawable(id<MTLTexture> texture);

/* Allocate CPU-owned Metal 4 commit options. The returned object can be
 * passed to MTL4CommandQueue commit:count:options: and accepts native
 * MTL4CommitFeedbackHandler blocks without invoking Apple's GPU runtime. */
API_AVAILABLE(macos(26.0), ios(26.0))
MTL4CommitOptions *ZPUMetalCreateCPUCommitOptions(void);
#endif

#endif

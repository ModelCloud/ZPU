/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include "zpu/metal.h"

_Static_assert(ZPU_METAL_ABI_VERSION == 25u, "Metal ABI version drift");
_Static_assert(ZPU_METAL_DEPTH16_UNORM == 250, "Depth16Unorm value drift");
_Static_assert(ZPU_METAL_DEPTH24_UNORM_STENCIL8 == 255, "Depth24Unorm_Stencil8 value drift");
_Static_assert(ZPU_METAL_DEPTH32_FLOAT_STENCIL8 == 260, "Depth32Float_Stencil8 value drift");
_Static_assert(ZPU_METAL_X32_STENCIL8 == 261, "X32_Stencil8 value drift");
_Static_assert(ZPU_METAL_X24_STENCIL8 == 262, "X24_Stencil8 value drift");
_Static_assert(sizeof(zpu_metal_color) == 16, "color layout drift");
_Static_assert(sizeof(zpu_metal_vertex) == 32, "vertex layout drift");
_Static_assert(sizeof(zpu_metal_viewport) == 24, "viewport layout drift");
_Static_assert(sizeof(zpu_metal_render_pass_descriptor) == 28, "pass layout drift");
_Static_assert(sizeof(zpu_metal_draw_state) == 44, "draw state layout drift");
_Static_assert(sizeof(zpu_metal_surface) == 40, "surface layout drift");
_Static_assert(sizeof(zpu_metal_stats) == 48, "stats layout drift");
_Static_assert(sizeof(zpu_metal_texture_descriptor) == 12, "texture descriptor layout drift");

int main(void) {
    return zpu_metal_max_cpu_cores(ZPU_METAL_2D) == 1 &&
                   zpu_metal_max_cpu_cores(ZPU_METAL_3D) == 2
               ? 0
               : 1;
}

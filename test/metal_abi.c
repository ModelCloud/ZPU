/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include "zpu/metal.h"

_Static_assert(ZPU_METAL_ABI_VERSION == 6u, "Metal ABI version drift");
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

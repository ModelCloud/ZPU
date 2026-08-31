/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <string.h>

#include "zpu/cpu_ml.h"

struct probe {
    int calls;
};

static int add_u32(void *context, const zpu_cpu_ml_operation_arguments *arguments) {
    struct probe *probe = (struct probe *)context;
    if (arguments == NULL || arguments->operation != ZPU_CPU_ML_OPERATION_ADD ||
        arguments->element_type != ZPU_CPU_ML_ELEMENT_UINT32 || arguments->input_count != 2 ||
        arguments->inputs[0].offset_bytes != 0 || arguments->inputs[1].offset_bytes != 0 ||
        arguments->destination.offset_bytes != 0 || arguments->inputs[0].strides[0] != 1 ||
        arguments->inputs[0].strides[1] != 2 || arguments->destination.strides[1] != 2) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t *left = (const uint32_t *)arguments->inputs[0].data;
    const uint32_t *right = (const uint32_t *)arguments->inputs[1].data;
    uint32_t *output = (uint32_t *)arguments->destination.data;
    if (left == NULL || right == NULL || output == NULL) return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    ++probe->calls;
    for (size_t index = 0; index < 6; ++index) output[index] = left[index] + right[index];
    return ZPU_CPU_ML_STATUS_OK;
}

int main(void) {
    if (zpu_cpu_ml_set_operation_backend(NULL) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_operation(NULL) != ZPU_CPU_ML_STATUS_INVALID_ARGUMENT) return 90;

    uint32_t left[12] = {1, 2, 0, 0, 3, 4, 0, 0, 5, 6, 0, 0};
    uint32_t right[12] = {10, 20, 0, 0, 30, 40, 0, 0, 50, 60, 0, 0};
    uint32_t output[12];
    for (size_t index = 0; index < 12; ++index) output[index] = UINT32_C(0xcafebabe);
    struct probe probe = {0};
    const zpu_cpu_ml_operation_backend backend = {
        .abi_version = ZPU_CPU_ML_OPERATION_ABI_VERSION,
        .context = &probe,
        .operation = add_u32,
    };
    const zpu_cpu_ml_operation_arguments arguments = {
        .operation = ZPU_CPU_ML_OPERATION_ADD,
        .element_type = ZPU_CPU_ML_ELEMENT_UINT32,
        .input_count = 2,
        .reserved = 0,
        .inputs = {
            {
                .data = (uint8_t *)left,
                .byte_length = sizeof(left),
                .offset_bytes = 0,
                .rank = 2,
                .element_bits = 32,
                .dimensions = {2, 3},
                .strides = {1, 4},
            },
            {
                .data = (uint8_t *)right,
                .byte_length = sizeof(right),
                .offset_bytes = 0,
                .rank = 2,
                .element_bits = 32,
                .dimensions = {2, 3},
                .strides = {1, 4},
            },
        },
        .destination = {
            .data = (uint8_t *)output,
            .byte_length = sizeof(output),
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 32,
            .dimensions = {2, 3},
            .strides = {1, 4},
        },
        .permutation = {0},
    };
    if (zpu_cpu_ml_set_operation_backend(&backend) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_operation(&arguments) != ZPU_CPU_ML_STATUS_OK || probe.calls != 1 ||
        output[0] != 11 || output[1] != 22 || output[4] != 33 || output[5] != 44 ||
        output[8] != 55 || output[9] != 66 || output[2] != UINT32_C(0xcafebabe) ||
        output[3] != UINT32_C(0xcafebabe) || output[6] != UINT32_C(0xcafebabe) ||
        output[7] != UINT32_C(0xcafebabe) ||
        zpu_cpu_ml_set_operation_backend(NULL) != ZPU_CPU_ML_STATUS_OK) return 91;
    return 0;
}

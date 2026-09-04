/* Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
 * SPDX-License-Identifier: Apache-2.0 */
#include <stdint.h>
#include <string.h>

#include "zpu/cpu_ml.h"

struct probe {
    int calls;
    int named_query_calls;
    int named_calls;
    int catalog_calls;
    int named_v2_query_calls;
    int named_v2_calls;
    int named_v3_query_calls;
    int named_v3_calls;
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

static int named_query(void *context, const char *function_name, size_t function_name_length,
                       zpu_cpu_ml_named_operation_signature *signature) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || function_name == NULL || signature == NULL) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->named_query_calls;
    if (function_name_length != strlen("zml_cpu_transpose") ||
        memcmp(function_name, "zml_cpu_transpose", function_name_length) != 0) {
        return ZPU_CPU_ML_STATUS_UNSUPPORTED;
    }
    signature->input_count = 1;
    signature->element_type = ZPU_CPU_ML_ELEMENT_UINT32;
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_transpose(void *context, const zpu_cpu_ml_named_operation_arguments *arguments) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || arguments == NULL || arguments->function_name == NULL ||
        arguments->function_name_length != strlen("zml_cpu_transpose") ||
        memcmp(arguments->function_name, "zml_cpu_transpose", arguments->function_name_length) != 0 ||
        arguments->input_count != 1 || arguments->element_type != ZPU_CPU_ML_ELEMENT_UINT32 ||
        arguments->inputs[0].offset_bytes != 0 || arguments->destination.offset_bytes != 0 ||
        arguments->inputs[0].strides[0] != 1 || arguments->inputs[0].strides[1] != 2 ||
        arguments->destination.strides[0] != 1 || arguments->destination.strides[1] != 3) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    const uint32_t *source = (const uint32_t *)arguments->inputs[0].data;
    uint32_t *destination = (uint32_t *)arguments->destination.data;
    if (source == NULL || destination == NULL) return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    ++probe->named_calls;
    for (size_t y = 0; y < 2; ++y) {
        for (size_t x = 0; x < 3; ++x) {
            destination[x + y * 3] = source[y + x * 2];
        }
    }
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_catalog_name_at(void *context, size_t index, const char **function_name,
                                 size_t *function_name_length) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || function_name == NULL || function_name_length == NULL || index != 0) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->catalog_calls;
    *function_name = "zml_cpu_transpose";
    *function_name_length = strlen("zml_cpu_transpose");
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_sum3_query(void *context, const char *function_name, size_t function_name_length,
                            zpu_cpu_ml_named_operation_signature *signature) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || function_name == NULL || signature == NULL) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->named_v2_query_calls;
    if (function_name_length != strlen("zml_cpu_sum3_f32") ||
        memcmp(function_name, "zml_cpu_sum3_f32", function_name_length) != 0) {
        return ZPU_CPU_ML_STATUS_UNSUPPORTED;
    }
    signature->input_count = 3;
    signature->element_type = ZPU_CPU_ML_ELEMENT_FLOAT32;
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_sum3(void *context, const zpu_cpu_ml_named_operation_arguments_v2 *arguments) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || arguments == NULL || arguments->function_name == NULL ||
        arguments->function_name_length != strlen("zml_cpu_sum3_f32") ||
        memcmp(arguments->function_name, "zml_cpu_sum3_f32", arguments->function_name_length) != 0 ||
        arguments->input_count != 3 || arguments->element_type != ZPU_CPU_ML_ELEMENT_FLOAT32 ||
        arguments->inputs == NULL || arguments->destination.data == NULL ||
        arguments->destination.rank != 2 || arguments->destination.dimensions[0] != 2 ||
        arguments->destination.dimensions[1] != 3 || arguments->destination.strides[0] != 1 ||
        arguments->destination.strides[1] != 2) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->named_v2_calls;
    for (size_t index = 0; index < 3; ++index) {
        if (arguments->inputs[index].data == NULL || arguments->inputs[index].rank != 2 ||
            arguments->inputs[index].dimensions[0] != 2 || arguments->inputs[index].dimensions[1] != 3 ||
            arguments->inputs[index].strides[0] != 1 || arguments->inputs[index].strides[1] != 2) {
            return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
        }
    }
    float *output = (float *)arguments->destination.data;
    const float *left = (const float *)arguments->inputs[0].data;
    const float *middle = (const float *)arguments->inputs[1].data;
    const float *right = (const float *)arguments->inputs[2].data;
    for (size_t index = 0; index < 6; ++index) output[index] = left[index] + middle[index] + right[index];
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_split_query(void *context, const char *function_name, size_t function_name_length,
                             zpu_cpu_ml_named_operation_signature_v3 *signature) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || function_name == NULL || signature == NULL) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->named_v3_query_calls;
    if (function_name_length != strlen("zml_cpu_split_f32") ||
        memcmp(function_name, "zml_cpu_split_f32", function_name_length) != 0) {
        return ZPU_CPU_ML_STATUS_UNSUPPORTED;
    }
    memset(signature, 0, sizeof(*signature));
    signature->input_count = 1;
    signature->output_count = 2;
    signature->input_element_types[0] = ZPU_CPU_ML_ELEMENT_FLOAT32;
    signature->output_element_types[0] = ZPU_CPU_ML_ELEMENT_FLOAT32;
    signature->output_element_types[1] = ZPU_CPU_ML_ELEMENT_FLOAT32;
    return ZPU_CPU_ML_STATUS_OK;
}

static int named_split(void *context, const zpu_cpu_ml_named_operation_arguments_v3 *arguments) {
    struct probe *probe = (struct probe *)context;
    if (probe == NULL || arguments == NULL || arguments->function_name == NULL ||
        arguments->function_name_length != strlen("zml_cpu_split_f32") ||
        memcmp(arguments->function_name, "zml_cpu_split_f32", arguments->function_name_length) != 0 ||
        arguments->input_count != 1 || arguments->output_count != 2 ||
        arguments->inputs == NULL || arguments->input_element_types == NULL ||
        arguments->outputs == NULL || arguments->output_element_types == NULL ||
        arguments->permutation == NULL ||
        arguments->input_element_types[0] != ZPU_CPU_ML_ELEMENT_FLOAT32 ||
        arguments->output_element_types[0] != ZPU_CPU_ML_ELEMENT_FLOAT32 ||
        arguments->output_element_types[1] != ZPU_CPU_ML_ELEMENT_FLOAT32 ||
        arguments->inputs[0].data == NULL || arguments->outputs[0].data == NULL ||
        arguments->outputs[1].data == NULL || arguments->inputs[0].strides[0] != 1 ||
        arguments->inputs[0].strides[1] != 2 || arguments->outputs[0].strides[0] != 1 ||
        arguments->outputs[0].strides[1] != 2 || arguments->outputs[1].strides[0] != 1 ||
        arguments->outputs[1].strides[1] != 2) {
        return ZPU_CPU_ML_STATUS_INVALID_ARGUMENT;
    }
    ++probe->named_v3_calls;
    const float *input = (const float *)arguments->inputs[0].data;
    float *first = (float *)arguments->outputs[0].data;
    float *second = (float *)arguments->outputs[1].data;
    for (size_t index = 0; index < 6; ++index) {
        first[index] = input[index] + 1.0f;
        second[index] = input[index] * 2.0f;
    }
    return ZPU_CPU_ML_STATUS_OK;
}

int main(void) {
    const uint32_t cpu_arch = zpu_cpu_ml_compiled_cpu_arch();
    const uint32_t cpu_features = zpu_cpu_ml_compiled_cpu_features();
    if (cpu_arch == ZPU_CPU_ML_CPU_ARCH_UNKNOWN ||
        ((cpu_features & ZPU_CPU_ML_CPU_FEATURE_AVX2) != 0 &&
         (cpu_features & ZPU_CPU_ML_CPU_FEATURE_AVX) == 0)) return 94;

    zpu_cpu_ml_operation_arguments malformed_operation = {0};
    malformed_operation.operation = ZPU_CPU_ML_OPERATION_ADD;
    malformed_operation.element_type = ZPU_CPU_ML_ELEMENT_UINT32;
    malformed_operation.input_count = 2;
    if (zpu_cpu_ml_set_operation_backend(NULL) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_operation(NULL) != ZPU_CPU_ML_STATUS_INVALID_ARGUMENT ||
        zpu_cpu_ml_operation(&malformed_operation) != ZPU_CPU_ML_STATUS_INVALID_ARGUMENT) return 90;

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

    uint32_t transpose_source[12] = {1, 2, 0, 0, 3, 4, 0, 0, 5, 6, 0, 0};
    uint32_t transpose_output[12];
    for (size_t index = 0; index < 12; ++index) transpose_output[index] = UINT32_C(0xcafebabe);
    const zpu_cpu_ml_named_operation_backend named_backend = {
        .abi_version = ZPU_CPU_ML_NAMED_OPERATION_ABI_VERSION,
        .context = &probe,
        .query = named_query,
        .operation = named_transpose,
    };
    const zpu_cpu_ml_named_operation_catalog catalog = {
        .abi_version = ZPU_CPU_ML_NAMED_OPERATION_CATALOG_ABI_VERSION,
        .context = &probe,
        .count = 1,
        .name_at = named_catalog_name_at,
    };
    zpu_cpu_ml_named_operation_signature signature = {0, 0};
    const zpu_cpu_ml_named_operation_arguments named_arguments = {
        .function_name = "zml_cpu_transpose",
        .function_name_length = strlen("zml_cpu_transpose"),
        .input_count = 1,
        .element_type = ZPU_CPU_ML_ELEMENT_UINT32,
        .reserved = 0,
        .inputs = {
            {
                .data = (uint8_t *)transpose_source,
                .byte_length = sizeof(transpose_source),
                .offset_bytes = 0,
                .rank = 2,
                .element_bits = 32,
                .dimensions = {2, 3},
                .strides = {1, 4},
            },
        },
        .destination = {
            .data = (uint8_t *)transpose_output,
            .byte_length = sizeof(transpose_output),
            .offset_bytes = 0,
            .rank = 2,
            .element_bits = 32,
            .dimensions = {3, 2},
            .strides = {1, 4},
        },
        .permutation = {1, 0},
    };
    const char *catalog_name = NULL;
    size_t catalog_name_length = 0;
    if (zpu_cpu_ml_set_named_operation_backend(&named_backend) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_set_named_operation_catalog(&catalog) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_named_operation_count() != 1 ||
        zpu_cpu_ml_named_operation_name_at(0, &catalog_name, &catalog_name_length) != ZPU_CPU_ML_STATUS_OK ||
        catalog_name_length != strlen("zml_cpu_transpose") ||
        memcmp(catalog_name, "zml_cpu_transpose", catalog_name_length) != 0 ||
        probe.catalog_calls != 1 ||
        zpu_cpu_ml_named_operation_supported("zml_cpu_transpose", strlen("zml_cpu_transpose"),
                                             &signature) != ZPU_CPU_ML_STATUS_OK ||
        signature.input_count != 1 || signature.element_type != ZPU_CPU_ML_ELEMENT_UINT32 ||
        zpu_cpu_ml_named_operation(&named_arguments) != ZPU_CPU_ML_STATUS_OK ||
        probe.named_query_calls != 2 || probe.named_calls != 1 ||
        transpose_output[0] != 1 || transpose_output[1] != 3 || transpose_output[2] != 5 ||
        transpose_output[4] != 2 || transpose_output[5] != 4 || transpose_output[6] != 6 ||
        transpose_output[3] != UINT32_C(0xcafebabe) ||
        transpose_output[7] != UINT32_C(0xcafebabe) ||
        zpu_cpu_ml_set_named_operation_catalog(NULL) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_set_named_operation_backend(NULL) != ZPU_CPU_ML_STATUS_OK) return 92;

    float sum3_left[12] = {1, 2, 0, 0, 3, 4, 0, 0, 5, 6, 0, 0};
    float sum3_middle[12] = {10, 20, 0, 0, 30, 40, 0, 0, 50, 60, 0, 0};
    float sum3_right[12] = {100, 200, 0, 0, 300, 400, 0, 0, 500, 600, 0, 0};
    float sum3_output[12];
    for (size_t index = 0; index < 12; ++index) sum3_output[index] = 777.0f;
    const zpu_cpu_ml_tensor_view sum3_inputs[3] = {
        {.data = (uint8_t *)sum3_left, .byte_length = sizeof(sum3_left), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
        {.data = (uint8_t *)sum3_middle, .byte_length = sizeof(sum3_middle), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
        {.data = (uint8_t *)sum3_right, .byte_length = sizeof(sum3_right), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
    };
    const zpu_cpu_ml_named_operation_backend_v2 named_backend_v2 = {
        .abi_version = ZPU_CPU_ML_NAMED_OPERATION_V2_ABI_VERSION,
        .context = &probe,
        .query = named_sum3_query,
        .operation = named_sum3,
    };
    zpu_cpu_ml_named_operation_signature v2_signature = {0, 0};
    const zpu_cpu_ml_named_operation_arguments_v2 named_arguments_v2 = {
        .function_name = "zml_cpu_sum3_f32",
        .function_name_length = strlen("zml_cpu_sum3_f32"),
        .input_count = 3,
        .element_type = ZPU_CPU_ML_ELEMENT_FLOAT32,
        .inputs = sum3_inputs,
        .destination = {
            .data = (uint8_t *)sum3_output, .byte_length = sizeof(sum3_output), .rank = 2,
            .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4},
        },
        .permutation = (const uint32_t[]){0, 1},
    };
    if (zpu_cpu_ml_set_named_operation_backend_v2(&named_backend_v2) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_named_operation_supported("zml_cpu_sum3_f32", strlen("zml_cpu_sum3_f32"),
                                             &v2_signature) != ZPU_CPU_ML_STATUS_OK ||
        v2_signature.input_count != 3 || v2_signature.element_type != ZPU_CPU_ML_ELEMENT_FLOAT32 ||
        zpu_cpu_ml_named_operation_v2(&named_arguments_v2) != ZPU_CPU_ML_STATUS_OK ||
        probe.named_v2_query_calls != 2 || probe.named_v2_calls != 1 ||
        sum3_output[0] != 111.0f || sum3_output[1] != 222.0f ||
        sum3_output[4] != 333.0f || sum3_output[5] != 444.0f ||
        sum3_output[8] != 555.0f || sum3_output[9] != 666.0f ||
        sum3_output[2] != 777.0f || sum3_output[3] != 777.0f ||
        zpu_cpu_ml_set_named_operation_backend_v2(NULL) != ZPU_CPU_ML_STATUS_OK) return 93;

    float split_input[12] = {1, 2, 0, 0, 3, 4, 0, 0, 5, 6, 0, 0};
    float split_first[12];
    float split_second[12];
    for (size_t index = 0; index < 12; ++index) {
        split_first[index] = 777.0f;
        split_second[index] = 888.0f;
    }
    const zpu_cpu_ml_tensor_view split_inputs[1] = {
        {.data = (uint8_t *)split_input, .byte_length = sizeof(split_input), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
    };
    zpu_cpu_ml_tensor_view split_outputs[2] = {
        {.data = (uint8_t *)split_first, .byte_length = sizeof(split_first), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
        {.data = (uint8_t *)split_second, .byte_length = sizeof(split_second), .rank = 2,
         .element_bits = 32, .dimensions = {2, 3}, .strides = {1, 4}},
    };
    const uint32_t split_input_types[1] = {ZPU_CPU_ML_ELEMENT_FLOAT32};
    const uint32_t split_output_types[2] = {ZPU_CPU_ML_ELEMENT_FLOAT32, ZPU_CPU_ML_ELEMENT_FLOAT32};
    const uint32_t split_permutation[ZPU_CPU_ML_MAX_RANK] = {0};
    const zpu_cpu_ml_named_operation_backend_v3 named_backend_v3 = {
        .abi_version = ZPU_CPU_ML_NAMED_OPERATION_V3_ABI_VERSION,
        .context = &probe,
        .query = named_split_query,
        .operation = named_split,
    };
    zpu_cpu_ml_named_operation_signature_v3 v3_signature = {0};
    const zpu_cpu_ml_named_operation_arguments_v3 named_arguments_v3 = {
        .function_name = "zml_cpu_split_f32",
        .function_name_length = strlen("zml_cpu_split_f32"),
        .input_count = 1,
        .output_count = 2,
        .reserved = 0,
        .inputs = split_inputs,
        .input_element_types = split_input_types,
        .outputs = split_outputs,
        .output_element_types = split_output_types,
        .permutation = split_permutation,
    };
    if (zpu_cpu_ml_set_named_operation_backend_v3(&named_backend_v3) != ZPU_CPU_ML_STATUS_OK ||
        zpu_cpu_ml_named_operation_supported_v3("zml_cpu_split_f32", strlen("zml_cpu_split_f32"),
                                                &v3_signature) != ZPU_CPU_ML_STATUS_OK ||
        v3_signature.input_count != 1 || v3_signature.output_count != 2 ||
        zpu_cpu_ml_named_operation_v3(&named_arguments_v3) != ZPU_CPU_ML_STATUS_OK ||
        probe.named_v3_query_calls != 2 || probe.named_v3_calls != 1 ||
        split_first[0] != 2.0f || split_first[1] != 3.0f || split_first[4] != 4.0f ||
        split_first[5] != 5.0f || split_first[8] != 6.0f || split_first[9] != 7.0f ||
        split_second[0] != 2.0f || split_second[1] != 4.0f || split_second[4] != 6.0f ||
        split_second[5] != 8.0f || split_second[8] != 10.0f || split_second[9] != 12.0f ||
        split_first[2] != 777.0f || split_first[3] != 777.0f ||
        split_second[2] != 888.0f || split_second[3] != 888.0f ||
        zpu_cpu_ml_set_named_operation_backend_v3(NULL) != ZPU_CPU_ML_STATUS_OK) return 94;
    return 0;
}

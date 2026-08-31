// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

#ifndef ZPU_CPU_ML_H
#define ZPU_CPU_ML_H

/*
 * Optional, host-OS-neutral CPU ML extension for the ZPU Metal-shaped layer.
 *
 * This header intentionally includes no Metal, Foundation, PJRT, or platform
 * headers. A provider such as a ZML CPU bridge may register here, but it must
 * consume ordinary CPU memory and may use whatever CPU ISA is appropriate for
 * the host (for example AdvSIMD on arm64 or AVX on x86_64). The adapter stages
 * non-dense ZPU tensor layouts before invoking the provider, so a provider is
 * never given an Apple Metal resource or an Apple-specific layout assumption.
 */

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ZPU_CPU_ML_BACKEND_ABI_VERSION 1u
#define ZPU_CPU_ML_OPERATION_ABI_VERSION 1u
#define ZPU_CPU_ML_MAX_RANK 16u
#define ZPU_CPU_ML_MAX_INPUTS 2u

enum {
    ZPU_CPU_ML_STATUS_OK = 0,
    ZPU_CPU_ML_STATUS_INVALID_ARGUMENT = -1,
    ZPU_CPU_ML_STATUS_UNSUPPORTED = -2,
    ZPU_CPU_ML_STATUS_OUT_OF_MEMORY = -3,
};

/* strides are measured in logical elements; 4-bit elements use one nibble */
typedef struct zpu_cpu_ml_tensor_view {
    uint8_t *data;
    size_t byte_length;
    size_t offset_bytes;
    uint32_t rank;
    uint32_t element_bits;
    size_t dimensions[ZPU_CPU_ML_MAX_RANK];
    size_t strides[ZPU_CPU_ML_MAX_RANK];
} zpu_cpu_ml_tensor_view;

/* permutation[output_axis] selects the source axis for that output axis */
typedef struct zpu_cpu_ml_transpose_arguments {
    zpu_cpu_ml_tensor_view source;
    zpu_cpu_ml_tensor_view destination;
    uint32_t permutation[ZPU_CPU_ML_MAX_RANK];
} zpu_cpu_ml_transpose_arguments;

typedef int (*zpu_cpu_ml_transpose_fn)(
    void *context,
    const zpu_cpu_ml_transpose_arguments *arguments);

typedef struct zpu_cpu_ml_backend {
    uint32_t abi_version;
    void *context;
    zpu_cpu_ml_transpose_fn transpose;
} zpu_cpu_ml_backend;

/* Stable operation identifiers used by a ZML CPU provider. */
enum {
    ZPU_CPU_ML_OPERATION_IDENTITY = 1,
    ZPU_CPU_ML_OPERATION_TRANSPOSE = 2,
    ZPU_CPU_ML_OPERATION_ADD = 3,
    ZPU_CPU_ML_OPERATION_SUBTRACT = 4,
    ZPU_CPU_ML_OPERATION_DIVIDE = 5,
    ZPU_CPU_ML_OPERATION_MULTIPLY = 6,
    ZPU_CPU_ML_OPERATION_MATMUL = 7,
};

/* Element identifiers are explicit because element_bits alone cannot
 * distinguish signed, unsigned, floating-point, and bfloat16 tensors. */
enum {
    ZPU_CPU_ML_ELEMENT_FLOAT32 = 1,
    ZPU_CPU_ML_ELEMENT_FLOAT16 = 2,
    ZPU_CPU_ML_ELEMENT_BFLOAT16 = 3,
    ZPU_CPU_ML_ELEMENT_INT8 = 4,
    ZPU_CPU_ML_ELEMENT_UINT8 = 5,
    ZPU_CPU_ML_ELEMENT_INT16 = 6,
    ZPU_CPU_ML_ELEMENT_UINT16 = 7,
    ZPU_CPU_ML_ELEMENT_INT32 = 8,
    ZPU_CPU_ML_ELEMENT_UINT32 = 9,
    ZPU_CPU_ML_ELEMENT_INT4 = 10,
    ZPU_CPU_ML_ELEMENT_UINT4 = 11,
};

typedef struct zpu_cpu_ml_operation_arguments {
    uint32_t operation;
    uint32_t element_type;
    uint32_t input_count;
    uint32_t reserved;
    zpu_cpu_ml_tensor_view inputs[ZPU_CPU_ML_MAX_INPUTS];
    zpu_cpu_ml_tensor_view destination;
    uint32_t permutation[ZPU_CPU_ML_MAX_RANK];
} zpu_cpu_ml_operation_arguments;

typedef int (*zpu_cpu_ml_operation_fn)(
    void *context,
    const zpu_cpu_ml_operation_arguments *arguments);

typedef struct zpu_cpu_ml_operation_backend {
    uint32_t abi_version;
    void *context;
    zpu_cpu_ml_operation_fn operation;
} zpu_cpu_ml_operation_backend;

/* Passing NULL unregisters the optional provider. */
int zpu_cpu_ml_set_backend(const zpu_cpu_ml_backend *backend);

/* Direct CPU execution using the registered provider or exact ZPU fallback. */
int zpu_cpu_ml_transpose(const zpu_cpu_ml_transpose_arguments *arguments);

/* Passing NULL unregisters the optional operation provider. */
int zpu_cpu_ml_set_operation_backend(const zpu_cpu_ml_operation_backend *backend);

/* Dispatch one registered operation through a CPU provider. This function
 * returns ZPU_CPU_ML_STATUS_UNSUPPORTED when no operation provider is
 * installed or the provider declines; the caller may then use its exact ZPU
 * reference path. */
int zpu_cpu_ml_operation(const zpu_cpu_ml_operation_arguments *arguments);

#ifdef __cplusplus
}
#endif

#endif /* ZPU_CPU_ML_H */

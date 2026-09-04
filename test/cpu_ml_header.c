// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

/* Deliberately include only the standalone public header. This translation
 * unit is compiled for foreign targets by cpu_ml_portability_gate.sh without
 * an Apple SDK sysroot. */
#include "zpu/cpu_ml.h"

_Static_assert(ZPU_CPU_ML_MAX_RANK == 16u, "CPU ML rank ABI drift");
_Static_assert(ZPU_CPU_ML_MAX_INPUTS == 2u, "CPU ML input ABI drift");
_Static_assert(ZPU_CPU_ML_MAX_NAMED_OUTPUTS == 16u, "CPU ML named output ABI drift");
_Static_assert(sizeof(zpu_cpu_ml_tensor_view) > 0, "CPU ML tensor ABI missing");
_Static_assert(sizeof(zpu_cpu_ml_operation_arguments) > sizeof(zpu_cpu_ml_tensor_view),
               "CPU ML operation ABI missing");
_Static_assert(sizeof(zpu_cpu_ml_named_operation_signature_v3) >
                   sizeof(zpu_cpu_ml_named_operation_signature),
               "CPU ML named v3 ABI missing");
_Static_assert(sizeof(zpu_cpu_ml_named_operation_arguments_v3) > 0,
               "CPU ML named arguments v3 ABI missing");

int zpu_cpu_ml_header_probe(void) {
    zpu_cpu_ml_tensor_view view = {0};
    zpu_cpu_ml_operation_arguments arguments = {0};
    arguments.inputs[0] = view;
    arguments.destination = view;
    return arguments.input_count;
}

// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

// An LLVM ORC differential test for the data-dependent inner portion of the
// live Chromium radial-gradient fragment fixture.  This is deliberately not
// linked into the Vulkan ICD yet: it establishes a narrow C ABI and proves
// generated code is equivalent before Render IR can select it at draw time.
// No fast-math flags are set anywhere in the generated IR.
#include <llvm-c/Core.h>
#include <llvm-c/Error.h>
#include <llvm-c/LLJIT.h>
#include <llvm-c/Orc.h>
#include <llvm-c/Target.h>
#include <llvm/Config/llvm-config.h>

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
    input_t = 0,
    input_coverage = 1,
    input_sample = 2,
    uniform_thresholds = 0,
    uniform_scale = 8,
    uniform_bias = 12,
    uniform_contrast = 16,
};

typedef void (*RadialFn)(const float *inputs, const float *uniforms, float *outputs);

static int consume_error(LLVMErrorRef error) {
    if (error == NULL) return 0;
    char *message = LLVMGetErrorMessage(error);
    if (message != NULL) {
        (void)fputs(message, stderr);
        (void)fputc('\n', stderr);
    }
    LLVMDisposeErrorMessage(message);
    return 1;
}

static float clamp_finite(float value, float lo, float hi) {
    return value < lo ? lo : (value > hi ? hi : value);
}

static void radial_reference(const float *inputs, const float *uniforms, float *outputs) {
    const float t = inputs[input_t];
    const uint32_t index = t < uniforms[uniform_thresholds + 1] ? 0u :
                           (t < uniforms[uniform_thresholds + 2] ? 1u :
                           (t < uniforms[uniform_thresholds + 3] ? 2u : 3u));
    const float alpha = uniforms[uniform_scale + index] * t + uniforms[uniform_bias + index];
    for (uint32_t lane = 0; lane != 4; ++lane) {
        const float linear = uniforms[uniform_scale + index] * t + uniforms[uniform_bias + index];
        const float adjusted = linear + (inputs[input_sample + lane] - 0.5f) * uniforms[uniform_contrast];
        const float color = lane == 3 ? alpha : clamp_finite(adjusted, 0.0f, alpha);
        outputs[lane] = color * inputs[input_coverage];
    }
}

static LLVMValueRef const_i32(LLVMContextRef context, uint32_t value) {
    return LLVMConstInt(LLVMInt32TypeInContext(context), value, 0);
}

static LLVMValueRef gep_f32(LLVMBuilderRef builder, LLVMTypeRef f32, LLVMValueRef base, LLVMValueRef index, const char *name) {
    return LLVMBuildGEP2(builder, f32, base, &index, 1, name);
}

static LLVMValueRef load_f32(LLVMBuilderRef builder, LLVMTypeRef f32, LLVMValueRef base, LLVMValueRef index, const char *name) {
    return LLVMBuildLoad2(builder, f32, gep_f32(builder, f32, base, index, name), name);
}

static void store_f32(LLVMBuilderRef builder, LLVMTypeRef f32, LLVMValueRef base, LLVMValueRef index, LLVMValueRef value) {
    LLVMBuildStore(builder, value, gep_f32(builder, f32, base, index, "out_ptr"));
}

static LLVMValueRef min_finite(LLVMBuilderRef builder, LLVMValueRef left, LLVMValueRef right, const char *name) {
    LLVMValueRef before = LLVMBuildFCmp(builder, LLVMRealOLT, left, right, "min_cmp");
    return LLVMBuildSelect(builder, before, left, right, name);
}

static LLVMValueRef max_finite(LLVMBuilderRef builder, LLVMValueRef left, LLVMValueRef right, const char *name) {
    LLVMValueRef before = LLVMBuildFCmp(builder, LLVMRealOGT, left, right, "max_cmp");
    return LLVMBuildSelect(builder, before, left, right, name);
}

static LLVMErrorRef build_radial_module(LLVMContextRef context, LLVMOrcThreadSafeContextRef thread_safe_context, LLVMOrcThreadSafeModuleRef *out_module) {
    LLVMTypeRef f32 = LLVMFloatTypeInContext(context);
    LLVMTypeRef ptr_f32 = LLVMPointerType(f32, 0);
    LLVMTypeRef params[] = { ptr_f32, ptr_f32, ptr_f32 };
    LLVMTypeRef signature = LLVMFunctionType(LLVMVoidTypeInContext(context), params, 3, 0);
    LLVMModuleRef module = LLVMModuleCreateWithNameInContext("zpu_orc_radial", context);
    LLVMValueRef function = LLVMAddFunction(module, "zpu_orc_radial_color", signature);
    LLVMBasicBlockRef block = LLVMAppendBasicBlockInContext(context, function, "entry");
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    LLVMPositionBuilderAtEnd(builder, block);
    LLVMValueRef inputs = LLVMGetParam(function, 0);
    LLVMValueRef uniforms = LLVMGetParam(function, 1);
    LLVMValueRef outputs = LLVMGetParam(function, 2);
    LLVMValueRef t = load_f32(builder, f32, inputs, const_i32(context, input_t), "t");
    LLVMValueRef low = LLVMBuildFCmp(builder, LLVMRealOLT, t, load_f32(builder, f32, uniforms, const_i32(context, uniform_thresholds + 1), "threshold_1"), "low");
    LLVMValueRef middle = LLVMBuildFCmp(builder, LLVMRealOLT, t, load_f32(builder, f32, uniforms, const_i32(context, uniform_thresholds + 2), "threshold_2"), "middle");
    LLVMValueRef high = LLVMBuildFCmp(builder, LLVMRealOLT, t, load_f32(builder, f32, uniforms, const_i32(context, uniform_thresholds + 3), "threshold_3"), "high");
    LLVMValueRef tail = LLVMBuildSelect(builder, high, const_i32(context, 2), const_i32(context, 3), "tail_index");
    LLVMValueRef head = LLVMBuildSelect(builder, middle, const_i32(context, 1), tail, "head_index");
    LLVMValueRef index = LLVMBuildSelect(builder, low, const_i32(context, 0), head, "index");
    LLVMValueRef scale_index = LLVMBuildAdd(builder, const_i32(context, uniform_scale), index, "scale_index");
    LLVMValueRef bias_index = LLVMBuildAdd(builder, const_i32(context, uniform_bias), index, "bias_index");
    LLVMValueRef scale = load_f32(builder, f32, uniforms, scale_index, "scale");
    LLVMValueRef bias = load_f32(builder, f32, uniforms, bias_index, "bias");
    LLVMValueRef linear = LLVMBuildFAdd(builder, LLVMBuildFMul(builder, scale, t, "scaled_t"), bias, "linear");
    LLVMValueRef contrast = load_f32(builder, f32, uniforms, const_i32(context, uniform_contrast), "contrast");
    LLVMValueRef coverage = load_f32(builder, f32, inputs, const_i32(context, input_coverage), "coverage");
    LLVMValueRef zero = LLVMConstReal(f32, 0.0);
    LLVMValueRef half = LLVMConstReal(f32, 0.5);
    for (uint32_t lane = 0; lane != 4; ++lane) {
        LLVMValueRef sample = load_f32(builder, f32, inputs, const_i32(context, input_sample + lane), "sample");
        LLVMValueRef adjusted = LLVMBuildFAdd(builder, linear, LLVMBuildFMul(builder, LLVMBuildFSub(builder, sample, half, "centered_sample"), contrast, "contrast_sample"), "adjusted");
        LLVMValueRef clamped = max_finite(builder, min_finite(builder, adjusted, linear, "clamp_hi"), zero, "clamp_lo");
        LLVMValueRef color = lane == 3 ? linear : clamped;
        store_f32(builder, f32, outputs, const_i32(context, lane), LLVMBuildFMul(builder, color, coverage, "covered"));
    }
    LLVMBuildRetVoid(builder);
    LLVMDisposeBuilder(builder);
    *out_module = LLVMOrcCreateNewThreadSafeModule(module, thread_safe_context);
    return *out_module == NULL ? LLVMCreateStringError("could not create thread-safe LLVM module") : LLVMErrorSuccess;
}

int main(void) {
    if (LLVM_VERSION_MAJOR != 22) return 2;
    if (LLVMInitializeNativeTarget() != 0 || LLVMInitializeNativeAsmPrinter() != 0 || LLVMInitializeNativeAsmParser() != 0) return 3;
    char *features = LLVMGetHostCPUFeatures();
    if (features == NULL) return 4;
    char *cpu_name = LLVMGetHostCPUName();
    if (cpu_name == NULL) {
        LLVMDisposeMessage(features);
        return 4;
    }
    if (getenv("ZPU_JIT_REPORT") != NULL) {
        (void)fprintf(stderr, "ZPU LLVM ORC host cpu=%s features=%s\n", cpu_name, features);
    }
    LLVMDisposeMessage(cpu_name);
    LLVMDisposeMessage(features);
    LLVMOrcLLJITRef jit = NULL;
    LLVMOrcJITTargetMachineBuilderRef target_machine = NULL;
    if (consume_error(LLVMOrcJITTargetMachineBuilderDetectHost(&target_machine))) return 5;
    LLVMOrcLLJITBuilderRef jit_builder = LLVMOrcCreateLLJITBuilder();
    if (jit_builder == NULL) {
        LLVMOrcDisposeJITTargetMachineBuilder(target_machine);
        return 5;
    }
    // DetectHost reads the process's actual CPUID/XCR0-enabled feature set.
    // Passing it explicitly keeps this test from silently targeting the
    // baseline build CPU and is the same gate the eventual Mosaic dispatcher
    // must use before selecting generated AVX-family code.
    LLVMOrcLLJITBuilderSetJITTargetMachineBuilder(jit_builder, target_machine);
    if (consume_error(LLVMOrcCreateLLJIT(&jit, jit_builder))) return 5;
    LLVMContextRef context = LLVMContextCreate();
    if (context == NULL) {
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 6;
    }
    LLVMOrcThreadSafeContextRef thread_safe_context = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context);
    if (thread_safe_context == NULL) {
        LLVMContextDispose(context);
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 7;
    }
    LLVMOrcThreadSafeModuleRef module = NULL;
    if (consume_error(build_radial_module(context, thread_safe_context, &module))) {
        LLVMOrcDisposeThreadSafeContext(thread_safe_context);
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 8;
    }
    LLVMOrcDisposeThreadSafeContext(thread_safe_context);
    if (consume_error(LLVMOrcLLJITAddLLVMIRModule(jit, LLVMOrcLLJITGetMainJITDylib(jit), module))) {
        LLVMOrcDisposeThreadSafeModule(module);
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 9;
    }
    LLVMOrcExecutorAddress address = 0;
    if (consume_error(LLVMOrcLLJITLookup(jit, &address, "zpu_orc_radial_color"))) {
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 10;
    }
    const float inputs[] = { 0.5f, 0.75f, 0.25f, 0.5f, 0.75f, 1.0f };
    const float uniforms[] = {
        0.0f, 0.25f, 0.75f, 1.0f, 0, 0, 0, 0,
        0.25f, 0.5f, 0.75f, 1.0f,
        0.125f, 0.25f, 0.375f, 0.5f,
        0.5f,
    };
    float expected[4] = { 0, 0, 0, 0 };
    float actual[4] = { 0, 0, 0, 0 };
    radial_reference(inputs, uniforms, expected);
    ((RadialFn)(uintptr_t)address)(inputs, uniforms, actual);
    const int result = memcmp(expected, actual, sizeof(actual)) == 0 ? 0 : 11;
    if (consume_error(LLVMOrcDisposeLLJIT(jit))) return 12;
    return result;
}

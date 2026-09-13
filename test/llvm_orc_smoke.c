// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

// This is intentionally a build-time smoke target, not part of the ICD. It
// proves that the pinned guest LLVM C API can create an ORC-managed native
// function before ZPU permits an experimental Render-IR-to-ORC handoff.
#include <llvm-c/Core.h>
#include <llvm-c/Error.h>
#include <llvm-c/LLJIT.h>
#include <llvm-c/Orc.h>
#include <llvm-c/Target.h>
#include <llvm/Config/llvm-config.h>

#include <stddef.h>
#include <stdio.h>
#include <stdint.h>

static int consume_error(LLVMErrorRef error) {
    if (error == NULL) {
        return 0;
    }
    char *message = LLVMGetErrorMessage(error);
    if (message != NULL) {
        (void)fputs(message, stderr);
        (void)fputc('\n', stderr);
    }
    LLVMDisposeErrorMessage(message);
    return 1;
}

int main(void) {
    // LLVM 22 is the reproducible guest toolchain pin for the experimental
    // backend. Do not silently accept another ABI merely because a system
    // libLLVM happens to be installed.
    if (LLVM_VERSION_MAJOR != 22) {
        return 2;
    }

    if (LLVMInitializeNativeTarget() != 0 || LLVMInitializeNativeAsmPrinter() != 0 || LLVMInitializeNativeAsmParser() != 0) {
        return 3;
    }
    LLVMOrcLLJITRef jit = NULL;
    if (consume_error(LLVMOrcCreateLLJIT(&jit, NULL))) {
        return 4;
    }
    LLVMContextRef context = LLVMContextCreate();
    if (context == NULL) {
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 5;
    }
    LLVMOrcThreadSafeContextRef thread_safe_context = LLVMOrcCreateNewThreadSafeContextFromLLVMContext(context);
    if (thread_safe_context == NULL) {
        LLVMContextDispose(context);
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 6;
    }
    LLVMModuleRef module = LLVMModuleCreateWithNameInContext("zpu_orc_smoke", context);
    LLVMTypeRef i32 = LLVMInt32TypeInContext(context);
    LLVMTypeRef parameters[] = {i32, i32};
    LLVMTypeRef signature = LLVMFunctionType(i32, parameters, 2, 0);
    LLVMValueRef function = LLVMAddFunction(module, "zpu_orc_smoke_add", signature);
    LLVMBasicBlockRef block = LLVMAppendBasicBlockInContext(context, function, "entry");
    LLVMBuilderRef builder = LLVMCreateBuilderInContext(context);
    LLVMPositionBuilderAtEnd(builder, block);
    LLVMValueRef sum = LLVMBuildAdd(builder, LLVMGetParam(function, 0), LLVMGetParam(function, 1), "sum");
    LLVMBuildRet(builder, sum);
    LLVMDisposeBuilder(builder);

    LLVMOrcThreadSafeModuleRef thread_safe_module = LLVMOrcCreateNewThreadSafeModule(module, thread_safe_context);
    LLVMOrcDisposeThreadSafeContext(thread_safe_context);
    if (consume_error(LLVMOrcLLJITAddLLVMIRModule(jit, LLVMOrcLLJITGetMainJITDylib(jit), thread_safe_module))) {
        LLVMOrcDisposeThreadSafeModule(thread_safe_module);
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 7;
    }
    LLVMOrcExecutorAddress address = 0;
    if (consume_error(LLVMOrcLLJITLookup(jit, &address, "zpu_orc_smoke_add"))) {
        (void)consume_error(LLVMOrcDisposeLLJIT(jit));
        return 8;
    }
    typedef int32_t (*AddFn)(int32_t, int32_t);
    AddFn add = (AddFn)(uintptr_t)address;
    const int result = add(19, 23) == 42 ? 0 : 9;
    if (consume_error(LLVMOrcDisposeLLJIT(jit))) {
        return 10;
    }
    return result;
}

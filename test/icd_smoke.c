// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

#define _POSIX_C_SOURCE 200809L
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef int32_t VkResult;
typedef void (*PFN_vkVoidFunction)(void);
typedef struct VkInstance_T *VkInstance;
typedef struct VkPhysicalDevice_T *VkPhysicalDevice;
typedef struct { int32_t sType; const void *pNext; uint32_t flags; const void *applicationInfo; uint32_t layerCount; const char *const *layers; uint32_t extensionCount; const char *const *extensions; } VkInstanceCreateInfo;
typedef VkResult (*Negotiate)(uint32_t *);
typedef PFN_vkVoidFunction (*GetProc)(VkInstance, const char *);
typedef VkResult (*CreateInstance)(const VkInstanceCreateInfo *, const void *, VkInstance *);
typedef VkResult (*EnumeratePhysicalDevices)(VkInstance, uint32_t *, VkPhysicalDevice *);
typedef void (*DestroyInstance)(VkInstance, const void *);

static void *symbol(void *library, const char *name) {
    void *value = dlsym(library, name);
    if (!value) fprintf(stderr, "missing %s: %s\n", name, dlerror());
    return value;
}

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!library) { fprintf(stderr, "dlopen: %s\n", dlerror()); return 3; }
    Negotiate negotiate = (Negotiate)symbol(library, "vk_icdNegotiateLoaderICDInterfaceVersion");
    GetProc get_proc = (GetProc)symbol(library, "vk_icdGetInstanceProcAddr");
    GetProc get_physical_proc = (GetProc)symbol(library, "vk_icdGetPhysicalDeviceProcAddr");
    if (!negotiate || !get_proc || !get_physical_proc) return 4;
    uint32_t version = 99;
    if (negotiate(&version) != 0 || version != 7 || negotiate(NULL) != -3) return 5;
    if (!get_proc(NULL, "vkCreateInstance") || get_proc(NULL, "vkDestroyInstance") || get_proc(NULL, "unsupported")) return 6;
    CreateInstance create = (CreateInstance)get_proc(NULL, "vkCreateInstance");
    VkInstanceCreateInfo info = { 1, NULL, 0, NULL, 0, NULL, 0, NULL };
    VkInstance instance = NULL;
    if (create(&info, NULL, &instance) != 0 || !instance || *(uintptr_t *)instance != 0x01CDC0DEu) return 7;
    EnumeratePhysicalDevices enumerate = (EnumeratePhysicalDevices)get_proc(instance, "vkEnumeratePhysicalDevices");
    DestroyInstance destroy = (DestroyInstance)get_proc(instance, "vkDestroyInstance");
    uint32_t count = 0; VkPhysicalDevice physical = NULL;
    if (!enumerate || !destroy || enumerate(instance, &count, NULL) != 0 || count != 1) return 8;
    if (enumerate(instance, &count, &physical) != 0 || !physical || *(uintptr_t *)physical != 0x01CDC0DEu) return 9;
    if (!get_physical_proc(instance, "vkGetPhysicalDeviceProperties") || get_physical_proc(instance, "vkDestroyInstance")) return 10;
    destroy(instance, NULL);
    dlclose(library);
    puts("ZPU ICD C-ABI smoke test passed");
    return 0;
}

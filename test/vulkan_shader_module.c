// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <vulkan/vulkan.h>

static int fail(const char *message, VkResult result) {
    fprintf(stderr, "%s: %d\n", message, result);
    return 1;
}

int main(void) {
    int status = 0;
    uint32_t *words = NULL;
    VkShaderModule shader = VK_NULL_HANDLE;
    VkDevice device = VK_NULL_HANDLE;
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
    };
    VkInstance instance = VK_NULL_HANDLE;
    VkResult result = vkCreateInstance(&instance_info, NULL, &instance);
    if (result != VK_SUCCESS) return fail("vkCreateInstance", result);

    uint32_t physical_count = 1;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    result = vkEnumeratePhysicalDevices(instance, &physical_count, &physical);
    if (result != VK_SUCCESS || physical_count != 1) {
        status = fail("vkEnumeratePhysicalDevices", result);
        goto cleanup;
    }
    const float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
    };
    result = vkCreateDevice(physical, &device_info, NULL, &device);
    if (result != VK_SUCCESS) {
        status = fail("vkCreateDevice", result);
        goto cleanup;
    }

    words = malloc(6 * sizeof(*words));
    if (!words) {
        status = 2;
        goto cleanup;
    }
    const uint32_t valid[] = { 0x07230203, 0x00010000, 0, 2, 0, 0x00010000 };
    for (size_t i = 0; i < 6; ++i) words[i] = valid[i];
    VkShaderModuleCreateInfo shader_info = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .codeSize = 6 * sizeof(*words),
        .pCode = words,
    };
    result = vkCreateShaderModule(device, &shader_info, NULL, &shader);
    words[5] = 0;
    free(words);
    words = NULL;
    if (result != VK_SUCCESS || shader == VK_NULL_HANDLE) {
        status = fail("valid owned shader module", result);
        goto cleanup;
    }
    vkDestroyShaderModule(device, shader, NULL);
    shader = VK_NULL_HANDLE;

    const uint32_t bad_magic[] = { 0, 0x00010000, 0, 1, 0 };
    shader_info.codeSize = sizeof(bad_magic);
    shader_info.pCode = bad_magic;
    shader = VK_NULL_HANDLE;
    result = vkCreateShaderModule(device, &shader_info, NULL, &shader);
    if (result != VK_ERROR_INVALID_SHADER_NV || shader != VK_NULL_HANDLE) {
        status = fail("bad magic rejection", result);
        goto cleanup;
    }
    shader_info.codeSize = sizeof(bad_magic) - 1;
    result = vkCreateShaderModule(device, &shader_info, NULL, &shader);
    if (result != VK_ERROR_INVALID_SHADER_NV || shader != VK_NULL_HANDLE) {
        status = fail("unaligned size rejection", result);
        goto cleanup;
    }

cleanup:
    free(words);
    if (shader != VK_NULL_HANDLE && device != VK_NULL_HANDLE) vkDestroyShaderModule(device, shader, NULL);
    if (device != VK_NULL_HANDLE) vkDestroyDevice(device, NULL);
    if (instance != VK_NULL_HANDLE) vkDestroyInstance(instance, NULL);
    if (status == 0) puts("ZPU Vulkan shader-module ABI test passed");
    return status;
}

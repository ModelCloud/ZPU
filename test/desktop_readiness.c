#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK_VK(expr) do { VkResult r_ = (expr); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d\n", #expr, r_); return 1; } } while (0)

static int has_extension(const VkExtensionProperties *extensions, uint32_t count, const char *name) {
    for (uint32_t i = 0; i < count; ++i)
        if (strcmp(extensions[i].extensionName, name) == 0) return 1;
    return 0;
}

static uint32_t count_device_procs(VkDevice device, const char *const *names, uint32_t count) {
    uint32_t found = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (vkGetDeviceProcAddr(device, names[i]) != NULL) {
            found += 1;
        } else {
            printf("missing_device_proc=%s\n", names[i]);
        }
    }
    return found;
}

static uint32_t count_instance_procs(VkInstance instance, const char *const *names, uint32_t count) {
    uint32_t found = 0;
    for (uint32_t i = 0; i < count; ++i) {
        if (vkGetInstanceProcAddr(instance, names[i]) != NULL) {
            found += 1;
        } else {
            printf("missing_instance_proc=%s\n", names[i]);
        }
    }
    return found;
}

int main(int argc, char **argv) {
    int require_ready = 0;
    if (argc == 2 && strcmp(argv[1], "--require-ready") == 0) {
        require_ready = 1;
    } else if (argc != 1) {
        fprintf(stderr, "usage: %s [--require-ready]\n", argv[0]);
        return 1;
    }

    uint32_t instance_extension_count = 0;
    CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_extension_count, NULL));
    VkExtensionProperties *instance_extensions = instance_extension_count == 0 ? NULL : calloc(instance_extension_count, sizeof(*instance_extensions));
    if (instance_extension_count != 0 && instance_extensions == NULL) return 1;
    CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_extension_count, instance_extensions));

    const int has_surface = has_extension(instance_extensions, instance_extension_count, VK_KHR_SURFACE_EXTENSION_NAME);
    const int has_xcb = has_extension(instance_extensions, instance_extension_count, "VK_KHR_xcb_surface");
    const int has_xlib = has_extension(instance_extensions, instance_extension_count, "VK_KHR_xlib_surface");
    const int has_x11 = has_xcb || has_xlib;
    const int has_wayland = has_extension(instance_extensions, instance_extension_count, "VK_KHR_wayland_surface");
    free(instance_extensions);

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "zpu-desktop-readiness", .apiVersion = VK_API_VERSION_1_0 };
    const char *platform_extension = has_xcb ? "VK_KHR_xcb_surface" : has_xlib ? "VK_KHR_xlib_surface" : has_wayland ? "VK_KHR_wayland_surface" : NULL;
    const char *enabled_instance_extensions[2];
    uint32_t enabled_instance_extension_count = 0;
    if (has_surface) enabled_instance_extensions[enabled_instance_extension_count++] = VK_KHR_SURFACE_EXTENSION_NAME;
    if (has_surface && platform_extension != NULL) enabled_instance_extensions[enabled_instance_extension_count++] = platform_extension;
    VkInstanceCreateInfo instance_info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = enabled_instance_extension_count, .ppEnabledExtensionNames = enabled_instance_extensions };
    VkInstance instance;
    CHECK_VK(vkCreateInstance(&instance_info, NULL, &instance));

    uint32_t physical_count = 0;
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, NULL));
    if (physical_count == 0) {
        fprintf(stderr, "no Vulkan physical device found\n");
        vkDestroyInstance(instance, NULL);
        return 1;
    }
    VkPhysicalDevice *physical_devices = calloc(physical_count, sizeof(*physical_devices));
    if (physical_devices == NULL) {
        vkDestroyInstance(instance, NULL);
        return 1;
    }
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, physical_devices));
    VkPhysicalDevice physical = physical_devices[0];
    free(physical_devices);

    const char *const surface_procs[] = {
        "vkDestroySurfaceKHR",
        "vkGetPhysicalDeviceSurfaceSupportKHR",
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
        "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
    };
    const uint32_t surface_proc_total = (uint32_t)(sizeof(surface_procs) / sizeof(surface_procs[0]));
    const uint32_t surface_proc_count = count_instance_procs(instance, surface_procs, surface_proc_total);
    const int has_platform_create_proc = vkGetInstanceProcAddr(instance, "vkCreateXcbSurfaceKHR") != NULL ||
                                         vkGetInstanceProcAddr(instance, "vkCreateXlibSurfaceKHR") != NULL ||
                                         vkGetInstanceProcAddr(instance, "vkCreateWaylandSurfaceKHR") != NULL;
    if (!has_platform_create_proc) printf("missing_instance_proc=platform_surface_create\n");

    VkPhysicalDeviceProperties properties;
    vkGetPhysicalDeviceProperties(physical, &properties);

    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_family_count, NULL);
    VkQueueFamilyProperties *queue_families = queue_family_count == 0 ? NULL : calloc(queue_family_count, sizeof(*queue_families));
    if (queue_family_count != 0 && queue_families == NULL) {
        vkDestroyInstance(instance, NULL);
        return 1;
    }
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_family_count, queue_families);
    uint32_t graphics_family = UINT32_MAX;
    for (uint32_t i = 0; i < queue_family_count; ++i)
        if ((queue_families[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0 && queue_families[i].queueCount != 0) {
            graphics_family = i;
            break;
        }
    free(queue_families);

    uint32_t device_extension_count = 0;
    CHECK_VK(vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, NULL));
    VkExtensionProperties *device_extensions = device_extension_count == 0 ? NULL : calloc(device_extension_count, sizeof(*device_extensions));
    if (device_extension_count != 0 && device_extensions == NULL) {
        vkDestroyInstance(instance, NULL);
        return 1;
    }
    CHECK_VK(vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, device_extensions));
    const int has_swapchain = has_extension(device_extensions, device_extension_count, VK_KHR_SWAPCHAIN_EXTENSION_NAME);
    free(device_extensions);

    VkFormatProperties format_properties;
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_B8G8R8A8_UNORM, &format_properties);
    const int has_color_attachment = (format_properties.optimalTilingFeatures & VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT) != 0;

    uint32_t render_proc_count = 0;
    uint32_t present_proc_count = 0;
    const char *const render_procs[] = {
        "vkCreateSemaphore",
        "vkDestroySemaphore",
        "vkCreateImageView",
        "vkDestroyImageView",
        "vkCreateShaderModule",
        "vkDestroyShaderModule",
        "vkCreateRenderPass",
        "vkDestroyRenderPass",
        "vkCreatePipelineLayout",
        "vkDestroyPipelineLayout",
        "vkCreateGraphicsPipelines",
        "vkDestroyPipeline",
        "vkCreateFramebuffer",
        "vkDestroyFramebuffer",
        "vkCmdBeginRenderPass",
        "vkCmdBindPipeline",
        "vkCmdDraw",
        "vkCmdEndRenderPass",
    };
    const char *const present_procs[] = {
        "vkCreateSwapchainKHR",
        "vkDestroySwapchainKHR",
        "vkGetSwapchainImagesKHR",
        "vkAcquireNextImageKHR",
        "vkQueuePresentKHR",
    };

    VkDevice device = VK_NULL_HANDLE;
    if (graphics_family != UINT32_MAX) {
        float priority = 1.0f;
        VkDeviceQueueCreateInfo queue_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = graphics_family, .queueCount = 1, .pQueuePriorities = &priority };
        const char *enabled_device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
        VkDeviceCreateInfo device_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info, .enabledExtensionCount = has_swapchain ? 1u : 0u, .ppEnabledExtensionNames = enabled_device_extensions };
        CHECK_VK(vkCreateDevice(physical, &device_info, NULL, &device));
        render_proc_count = count_device_procs(device, render_procs, (uint32_t)(sizeof(render_procs) / sizeof(render_procs[0])));
        present_proc_count = count_device_procs(device, present_procs, (uint32_t)(sizeof(present_procs) / sizeof(present_procs[0])));
    }

    const uint32_t render_proc_total = (uint32_t)(sizeof(render_procs) / sizeof(render_procs[0]));
    const uint32_t present_proc_total = (uint32_t)(sizeof(present_procs) / sizeof(present_procs[0]));
    const int has_platform_surface = has_x11 || has_wayland;
    const int ready = has_surface && has_platform_surface && surface_proc_count == surface_proc_total && has_platform_create_proc && has_swapchain && graphics_family != UINT32_MAX && has_color_attachment && render_proc_count == render_proc_total && present_proc_count == present_proc_total;

    printf("probe_version=1\n");
    printf("device=%s\n", properties.deviceName);
    printf("api_version=%u.%u.%u\n", VK_VERSION_MAJOR(properties.apiVersion), VK_VERSION_MINOR(properties.apiVersion), VK_VERSION_PATCH(properties.apiVersion));
    printf("graphics_queue=%s\n", graphics_family == UINT32_MAX ? "missing" : "available");
    printf("instance_extension.%s=%s\n", VK_KHR_SURFACE_EXTENSION_NAME, has_surface ? "available" : "missing");
    printf("platform_surface.x11=%s\n", has_x11 ? "available" : "missing");
    printf("platform_surface.wayland=%s\n", has_wayland ? "available" : "missing");
    printf("surface_entrypoints=%u/%u\n", surface_proc_count + (has_platform_create_proc ? 1u : 0u), surface_proc_total + 1);
    printf("device_extension.%s=%s\n", VK_KHR_SWAPCHAIN_EXTENSION_NAME, has_swapchain ? "available" : "missing");
    printf("format.B8G8R8A8_UNORM.optimal_color_attachment=%s\n", has_color_attachment ? "available" : "missing");
    printf("render_entrypoints=%u/%u\n", render_proc_count, render_proc_total);
    printf("present_entrypoints=%u/%u\n", present_proc_count, present_proc_total);
    printf("status=%s\n", ready ? "READY_FOR_WINDOW_TEST" : "NOT_READY");

    if (device != VK_NULL_HANDLE) vkDestroyDevice(device, NULL);
    vkDestroyInstance(instance, NULL);
    return require_ready && !ready ? 2 : 0;
}

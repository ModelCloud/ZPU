#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK_VK(expr) do { \
    VkResult result_ = (expr); \
    if (result_ != VK_SUCCESS) { \
        fprintf(stderr, "%s failed: %d\n", #expr, result_); \
        return 1; \
    } \
} while (0)
#define CHECK_TRUE(expr) do { \
    if (!(expr)) { \
        fprintf(stderr, "check failed: %s\n", #expr); \
        return 1; \
    } \
} while (0)

int main(void) {
    const char *instance_extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
        VK_EXT_HEADLESS_SURFACE_EXTENSION_NAME,
    };
    VkApplicationInfo application = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pApplicationName = "zpu-headless-present",
        .apiVersion = VK_API_VERSION_1_0,
    };
    VkInstanceCreateInfo instance_info = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pApplicationInfo = &application,
        .enabledExtensionCount = 2,
        .ppEnabledExtensionNames = instance_extensions,
    };
    VkInstance instance = VK_NULL_HANDLE;
    CHECK_VK(vkCreateInstance(&instance_info, NULL, &instance));

    uint32_t physical_count = 1;
    VkPhysicalDevice physical = VK_NULL_HANDLE;
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, &physical));
    CHECK_TRUE(physical_count == 1 && physical != VK_NULL_HANDLE);

    VkHeadlessSurfaceCreateInfoEXT surface_info = {
        .sType = VK_STRUCTURE_TYPE_HEADLESS_SURFACE_CREATE_INFO_EXT,
    };
    VkSurfaceKHR surface = VK_NULL_HANDLE;
    CHECK_VK(vkCreateHeadlessSurfaceEXT(instance, &surface_info, NULL, &surface));
    VkBool32 supported = VK_FALSE;
    CHECK_VK(vkGetPhysicalDeviceSurfaceSupportKHR(physical, 0, surface, &supported));
    CHECK_TRUE(supported == VK_TRUE);

    VkSurfaceCapabilitiesKHR capabilities;
    CHECK_VK(vkGetPhysicalDeviceSurfaceCapabilitiesKHR(physical, surface, &capabilities));
    CHECK_TRUE(capabilities.currentExtent.width == UINT32_MAX && capabilities.currentExtent.height == UINT32_MAX);
    CHECK_TRUE(capabilities.minImageExtent.width <= 16 && capabilities.minImageExtent.height <= 16 &&
               capabilities.maxImageExtent.width >= 16 && capabilities.maxImageExtent.height >= 16);

    uint32_t format_count = 0;
    CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &format_count, NULL));
    CHECK_TRUE(format_count > 0);
    VkSurfaceFormatKHR format;
    uint32_t one_format = 1;
    CHECK_VK(vkGetPhysicalDeviceSurfaceFormatsKHR(physical, surface, &one_format, &format));

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
        .queueFamilyIndex = 0,
        .queueCount = 1,
        .pQueuePriorities = &priority,
    };
    const char *device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo device_info = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = &queue_info,
        .enabledExtensionCount = 1,
        .ppEnabledExtensionNames = device_extensions,
    };
    VkDevice device = VK_NULL_HANDLE;
    CHECK_VK(vkCreateDevice(physical, &device_info, NULL, &device));
    VkQueue queue = VK_NULL_HANDLE;
    vkGetDeviceQueue(device, 0, 0, &queue);
    CHECK_TRUE(queue != VK_NULL_HANDLE);

    VkSwapchainCreateInfoKHR swapchain_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = 2,
        .imageFormat = format.format,
        .imageColorSpace = format.colorSpace,
        .imageExtent = { 16, 16 },
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    VkSwapchainKHR swapchain = VK_NULL_HANDLE;
    CHECK_VK(vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain));
    uint32_t image_count = 0;
    CHECK_VK(vkGetSwapchainImagesKHR(device, swapchain, &image_count, NULL));
    CHECK_TRUE(image_count >= 2);

    uint32_t image_index = UINT32_MAX;
    CHECK_VK(vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, VK_NULL_HANDLE, VK_NULL_HANDLE, &image_index));
    CHECK_TRUE(image_index < image_count);
    VkPresentInfoKHR present = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .swapchainCount = 1,
        .pSwapchains = &swapchain,
        .pImageIndices = &image_index,
    };
    CHECK_VK(vkQueuePresentKHR(queue, &present));
    CHECK_VK(vkQueueWaitIdle(queue));

    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);
    puts("headless_present_submission_complete=1");
    puts("headless_present_transport=no_xcb");
    return 0;
}

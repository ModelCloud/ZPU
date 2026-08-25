#include <vulkan/vulkan.h>
#include <xcb/xcb.h>
#include <vulkan/vulkan_xcb.h>
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define CHECK_VK(expr) do { VkResult r_ = (expr); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d\n", #expr, r_); return 1; } } while (0)
#define CHECK_TRUE(expr) do { if (!(expr)) { fprintf(stderr, "check failed: %s\n", #expr); return 1; } } while (0)

int main(void) {
    int screen_index = 0;
    xcb_connection_t *connection = xcb_connect(NULL, &screen_index);
    CHECK_TRUE(connection != NULL && xcb_connection_has_error(connection) == 0);
    const xcb_setup_t *setup = xcb_get_setup(connection);
    xcb_screen_iterator_t screens = xcb_setup_roots_iterator(setup);
    for (int i = 0; i < screen_index; ++i) xcb_screen_next(&screens);
    xcb_screen_t *screen = screens.data;
    CHECK_TRUE(screen != NULL && screen->root_depth == 24);

    const uint16_t width = 64, height = 64;
    xcb_window_t window = xcb_generate_id(connection);
    const uint32_t window_values[] = { screen->black_pixel, XCB_EVENT_MASK_EXPOSURE };
    xcb_create_window(connection, screen->root_depth, window, screen->root, 0, 0, width, height, 0,
                      XCB_WINDOW_CLASS_INPUT_OUTPUT, screen->root_visual,
                      XCB_CW_BACK_PIXEL | XCB_CW_EVENT_MASK, window_values);
    xcb_map_window(connection, window);
    CHECK_TRUE(xcb_flush(connection) > 0);

    const char *instance_extensions[] = { VK_KHR_SURFACE_EXTENSION_NAME, VK_KHR_XCB_SURFACE_EXTENSION_NAME };
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "zpu-xcb-present", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo instance_info = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app, .enabledExtensionCount = 2, .ppEnabledExtensionNames = instance_extensions };
    VkInstance instance;
    CHECK_VK(vkCreateInstance(&instance_info, NULL, &instance));

    uint32_t physical_count = 1;
    VkPhysicalDevice physical;
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, &physical));
    CHECK_TRUE(physical_count == 1);

    VkXcbSurfaceCreateInfoKHR surface_info = { .sType = VK_STRUCTURE_TYPE_XCB_SURFACE_CREATE_INFO_KHR, .connection = connection, .window = window };
    VkSurfaceKHR surface;
    CHECK_VK(vkCreateXcbSurfaceKHR(instance, &surface_info, NULL, &surface));
    VkBool32 presentation_supported = VK_FALSE;
    CHECK_VK(vkGetPhysicalDeviceSurfaceSupportKHR(physical, 0, surface, &presentation_supported));
    CHECK_TRUE(presentation_supported == VK_TRUE);

    float priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority };
    const char *device_extensions[] = { VK_KHR_SWAPCHAIN_EXTENSION_NAME };
    VkDeviceCreateInfo device_info = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &queue_info, .enabledExtensionCount = 1, .ppEnabledExtensionNames = device_extensions };
    VkDevice device;
    CHECK_VK(vkCreateDevice(physical, &device_info, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, 0, 0, &queue);

    VkSwapchainCreateInfoKHR swapchain_info = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .surface = surface,
        .minImageCount = 2,
        .imageFormat = VK_FORMAT_B8G8R8A8_UNORM,
        .imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR,
        .imageExtent = { width, height },
        .imageArrayLayers = 1,
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .preTransform = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR,
        .compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        .presentMode = VK_PRESENT_MODE_FIFO_KHR,
        .clipped = VK_TRUE,
    };
    VkSwapchainKHR swapchain;
    CHECK_VK(vkCreateSwapchainKHR(device, &swapchain_info, NULL, &swapchain));
    uint32_t image_count = 2;
    VkImage images[2];
    CHECK_VK(vkGetSwapchainImagesKHR(device, swapchain, &image_count, images));
    CHECK_TRUE(image_count == 2);

    VkImageViewCreateInfo view_info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .image = images[0],
        .viewType = VK_IMAGE_VIEW_TYPE_2D,
        .format = VK_FORMAT_B8G8R8A8_UNORM,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    VkImageView view;
    CHECK_VK(vkCreateImageView(device, &view_info, NULL, &view));

    VkAttachmentDescription attachment = {
        .format = VK_FORMAT_B8G8R8A8_UNORM,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR,
        .storeOp = VK_ATTACHMENT_STORE_OP_STORE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE,
        .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
    };
    VkAttachmentReference color_reference = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &color_reference };
    VkRenderPassCreateInfo render_pass_info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass };
    VkRenderPass render_pass;
    CHECK_VK(vkCreateRenderPass(device, &render_pass_info, NULL, &render_pass));
    VkFramebufferCreateInfo framebuffer_info = { .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = render_pass, .attachmentCount = 1, .pAttachments = &view, .width = width, .height = height, .layers = 1 };
    VkAttachmentDescription two_attachments[2] = { attachment, {
        .format = VK_FORMAT_D32_SFLOAT, .samples = VK_SAMPLE_COUNT_1_BIT,
        .loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR, .storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE,
        .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL,
    } };
    VkAttachmentReference depth_reference = { .attachment = 1, .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL };
    VkSubpassDescription color_depth_subpass = subpass;
    color_depth_subpass.pDepthStencilAttachment = &depth_reference;
    VkRenderPassCreateInfo color_depth_info = render_pass_info;
    color_depth_info.attachmentCount = 2;
    color_depth_info.pAttachments = two_attachments;
    color_depth_info.pSubpasses = &color_depth_subpass;
    VkRenderPass color_depth_render_pass;
    CHECK_VK(vkCreateRenderPass(device, &color_depth_info, NULL, &color_depth_render_pass));
    VkFramebufferCreateInfo missing_depth_info = framebuffer_info;
    missing_depth_info.renderPass = color_depth_render_pass;
    VkFramebuffer unpublished_framebuffer = (VkFramebuffer)(uintptr_t)0xfeed;
    CHECK_TRUE(vkCreateFramebuffer(device, &missing_depth_info, NULL, &unpublished_framebuffer) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_TRUE(unpublished_framebuffer == (VkFramebuffer)(uintptr_t)0xfeed);
    vkDestroyRenderPass(device, color_depth_render_pass, NULL);
    VkFramebuffer framebuffer;
    CHECK_VK(vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer));

    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CHECK_VK(vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo command_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer command;
    CHECK_VK(vkAllocateCommandBuffers(device, &command_info, &command));
    VkCommandBufferBeginInfo begin_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK_VK(vkBeginCommandBuffer(command, &begin_info));
    VkClearValue clear = { .color.float32 = { 0.125f, 0.5f, 0.875f, 1.0f } };
    VkRenderPassBeginInfo begin_render_pass = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = render_pass, .framebuffer = framebuffer, .renderArea = { { 0, 0 }, { width, height } }, .clearValueCount = 1, .pClearValues = &clear };
    vkCmdBeginRenderPass(command, &begin_render_pass, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdEndRenderPass(command);
    CHECK_VK(vkEndCommandBuffer(command));

    VkSemaphoreCreateInfo semaphore_info = { .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO };
    VkSemaphore acquired, rendered;
    CHECK_VK(vkCreateSemaphore(device, &semaphore_info, NULL, &acquired));
    CHECK_VK(vkCreateSemaphore(device, &semaphore_info, NULL, &rendered));
    uint32_t image_index = UINT32_MAX;
    CHECK_VK(vkAcquireNextImageKHR(device, swapchain, UINT64_MAX, acquired, VK_NULL_HANDLE, &image_index));
    CHECK_TRUE(image_index == 0);
    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .waitSemaphoreCount = 1, .pWaitSemaphores = &acquired, .pWaitDstStageMask = &wait_stage, .commandBufferCount = 1, .pCommandBuffers = &command, .signalSemaphoreCount = 1, .pSignalSemaphores = &rendered };
    CHECK_VK(vkQueueSubmit(queue, 1, &submit, VK_NULL_HANDLE));
    VkPresentInfoKHR present = { .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR, .waitSemaphoreCount = 1, .pWaitSemaphores = &rendered, .swapchainCount = 1, .pSwapchains = &swapchain, .pImageIndices = &image_index };
    CHECK_VK(vkQueuePresentKHR(queue, &present));
    CHECK_VK(vkQueueWaitIdle(queue));

    const char *untrusted_x11 = getenv("ZPU_UNTRUSTED_X11");
    if (untrusted_x11 != NULL && strcmp(untrusted_x11, "1") == 0) {
        /* X SECURITY deliberately forbids GetImage, even on this client's
         * window. Successful queue presentation is the strongest guest-side
         * check; trusted deterministic gates retain the exact pixel oracle. */
        puts("xcb_present_submission_complete=1");
        puts("xcb_present_expected_pixel=BGRA(223,127,31,255)");
        puts("xcb_present_readback=not_attempted_untrusted_x11");
    } else {
        xcb_get_image_cookie_t image_cookie = xcb_get_image(connection, XCB_IMAGE_FORMAT_Z_PIXMAP, window, width / 2, height / 2, 1, 1, UINT32_MAX);
        xcb_get_image_reply_t *image_reply = xcb_get_image_reply(connection, image_cookie, NULL);
        CHECK_TRUE(image_reply != NULL && xcb_get_image_data_length(image_reply) >= 4);
        const uint8_t *pixel = xcb_get_image_data(image_reply);
        CHECK_TRUE(pixel[0] == 223 && pixel[1] == 127 && pixel[2] == 31);
        printf("xcb_present_pixel=BGRA(%u,%u,%u,%u)\n", pixel[0], pixel[1], pixel[2], pixel[3]);
        free(image_reply);
    }
    const char *hold = getenv("ZPU_WINDOW_HOLD_SECONDS");
    if (hold != NULL) {
        char *end = NULL;
        errno = 0;
        unsigned long seconds = strtoul(hold, &end, 10);
        if (errno != 0 || end == hold || *end != '\0' || seconds > 10) {
            fprintf(stderr, "ZPU_WINDOW_HOLD_SECONDS must be an integer from 0 through 10\n");
            return 2;
        }
        sleep((unsigned int)seconds);
    }

    vkDestroySemaphore(device, rendered, NULL);
    vkDestroySemaphore(device, acquired, NULL);
    vkDestroyCommandPool(device, pool, NULL);
    vkDestroyFramebuffer(device, framebuffer, NULL);
    vkDestroyRenderPass(device, render_pass, NULL);
    vkDestroyImageView(device, view, NULL);
    vkDestroySwapchainKHR(device, swapchain, NULL);
    vkDestroyDevice(device, NULL);
    vkDestroySurfaceKHR(instance, surface, NULL);
    vkDestroyInstance(instance, NULL);
    xcb_destroy_window(connection, window);
    xcb_disconnect(connection);
    return 0;
}

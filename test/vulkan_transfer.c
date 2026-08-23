#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK_VK(expr) do { VkResult r_ = (expr); if (r_ != VK_SUCCESS) { fprintf(stderr, "%s failed: %d\n", #expr, r_); return 1; } } while (0)
#define CHECK_TRUE(expr) do { if (!(expr)) { fprintf(stderr, "check failed: %s\n", #expr); return 1; } } while (0)
enum { WIDTH = 240, HEIGHT = 240, BYTES = WIDTH * HEIGHT * 4 };

static int submit_wait(VkDevice device, VkQueue queue, VkCommandBuffer command, VkFence fence) {
    VkSubmitInfo submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command };
    CHECK_VK(vkQueueSubmit(queue, 1, &submit, fence));
    CHECK_VK(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX));
    CHECK_VK(vkResetFences(device, 1, &fence));
    return 0;
}

static int check_bytes(VkDevice device, VkDeviceMemory memory, const uint8_t *expected, const char *operation) {
    uint8_t *actual;
    CHECK_VK(vkMapMemory(device, memory, 0, VK_WHOLE_SIZE, 0, (void **)&actual));
    for (size_t i = 0; i < BYTES; ++i) if (actual[i] != expected[i]) {
        fprintf(stderr, "%s byte mismatch at %zu (pixel %zu channel %zu): expected %u actual %u\n", operation, i, i / 4, i % 4, expected[i], actual[i]);
        vkUnmapMemory(device, memory);
        return 1;
    }
    vkUnmapMemory(device, memory);
    return 0;
}

static uint32_t find_memory_type(VkPhysicalDevice physical, uint32_t bits) {
    VkPhysicalDeviceMemoryProperties p;
    vkGetPhysicalDeviceMemoryProperties(physical, &p);
    for (uint32_t i = 0; i < p.memoryTypeCount; ++i)
        if ((bits & (1u << i)) && (p.memoryTypes[i].propertyFlags & (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) == (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT)) return i;
    return UINT32_MAX;
}

static int allocate_bind_buffer(VkDevice device, VkPhysicalDevice physical, VkDeviceSize size, VkBufferUsageFlags usage, VkBuffer *buffer, VkDeviceMemory *memory) {
    VkBufferCreateInfo bi = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_VK(vkCreateBuffer(device, &bi, NULL, buffer));
    VkMemoryRequirements req;
    vkGetBufferMemoryRequirements(device, *buffer, &req);
    uint32_t type = find_memory_type(physical, req.memoryTypeBits);
    CHECK_TRUE(type != UINT32_MAX);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = type };
    CHECK_VK(vkAllocateMemory(device, &ai, NULL, memory));
    CHECK_VK(vkBindBufferMemory(device, *buffer, *memory, 0));
    return 0;
}

static int allocate_bind_image(VkDevice device, VkPhysicalDevice physical, VkFormat format, VkImage *image, VkDeviceMemory *memory) {
    VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = format, .extent = { WIDTH, HEIGHT, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR, .usage = VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    CHECK_VK(vkCreateImage(device, &ii, NULL, image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, *image, &req);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = find_memory_type(physical, req.memoryTypeBits) };
    CHECK_VK(vkAllocateMemory(device, &ai, NULL, memory));
    CHECK_VK(vkBindImageMemory(device, *image, *memory, 0));
    VkImageSubresource subresource = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT };
    VkSubresourceLayout layout;
    vkGetImageSubresourceLayout(device, *image, &subresource, &layout);
    CHECK_TRUE(layout.offset == 0 && layout.size == BYTES && layout.rowPitch == WIDTH * 4 && layout.arrayPitch == BYTES && layout.depthPitch == BYTES);
    return 0;
}

static void transition_image(VkCommandBuffer command, VkImage image) {
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}

int main(void) {
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "zpu-transfer-test", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    CHECK_VK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t physical_count = 1;
    VkPhysicalDevice physical;
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, &physical));
    CHECK_TRUE(physical_count == 1);
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice device;
    CHECK_VK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, 0, 0, &queue);

    VkImageFormatProperties ifp;
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp));
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp));
    CHECK_TRUE(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    VkImage bad_image;
    VkImageCreateInfo bad = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8_UNORM, .extent = { WIDTH, HEIGHT, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR, .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_TRUE(vkCreateImage(device, &bad, NULL, &bad_image) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    bad.format = VK_FORMAT_R8G8B8A8_UNORM;
    bad.extent.width = UINT32_MAX;
    CHECK_TRUE(vkCreateImage(device, &bad, NULL, &bad_image) == VK_ERROR_INITIALIZATION_FAILED);
    VkBuffer bad_buffer;
    VkBufferCreateInfo bad_buffer_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 16, .usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_TRUE(vkCreateBuffer(device, &bad_buffer_info, NULL, &bad_buffer) == VK_ERROR_INITIALIZATION_FAILED);

    VkBuffer misaligned;
    VkDeviceMemory misaligned_memory;
    VkBufferCreateInfo misaligned_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_VK(vkCreateBuffer(device, &misaligned_info, NULL, &misaligned));
    VkMemoryRequirements misaligned_req;
    vkGetBufferMemoryRequirements(device, misaligned, &misaligned_req);
    VkMemoryAllocateInfo misaligned_ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = misaligned_req.size + 4, .memoryTypeIndex = find_memory_type(physical, misaligned_req.memoryTypeBits) };
    CHECK_VK(vkAllocateMemory(device, &misaligned_ai, NULL, &misaligned_memory));
    CHECK_TRUE(vkBindBufferMemory(device, misaligned, misaligned_memory, 1) == VK_ERROR_INITIALIZATION_FAILED);
    vkDestroyBuffer(device, misaligned, NULL);
    vkFreeMemory(device, misaligned_memory, NULL);

    VkBuffer upload, staging, readback;
    VkDeviceMemory upload_memory, staging_memory, readback_memory;
    CHECK_VK(allocate_bind_buffer(device, physical, BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, &upload, &upload_memory));
    CHECK_VK(allocate_bind_buffer(device, physical, BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT, &staging, &staging_memory));
    CHECK_VK(allocate_bind_buffer(device, physical, BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &readback, &readback_memory));
    VkImage first, second, bgra, bgra_second;
    VkDeviceMemory first_memory, second_memory, bgra_memory, bgra_second_memory;
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_R8G8B8A8_UNORM, &first, &first_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_R8G8B8A8_UNORM, &second, &second_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_B8G8R8A8_UNORM, &bgra, &bgra_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_B8G8R8A8_UNORM, &bgra_second, &bgra_second_memory));

    uint8_t *mapped;
    CHECK_VK(vkMapMemory(device, upload_memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
    uint8_t *expected = malloc(BYTES);
    CHECK_TRUE(expected != NULL);
    for (uint32_t y = 0; y < HEIGHT; ++y) for (uint32_t x = 0; x < WIDTH; ++x) {
        size_t i = ((size_t)y * WIDTH + x) * 4;
        mapped[i + 0] = (uint8_t)(x ^ y); mapped[i + 1] = (uint8_t)(x + 3 * y); mapped[i + 2] = (uint8_t)(255 - x); mapped[i + 3] = 255;
        memcpy(expected + i, mapped + i, 4);
    }
    vkUnmapMemory(device, upload_memory);

    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CHECK_VK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer command;
    CHECK_VK(vkAllocateCommandBuffers(device, &cai, &command));
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    CHECK_VK(vkCreateFence(device, &fci, NULL, &fence));
    CHECK_TRUE(vkGetFenceStatus(device, fence) == VK_NOT_READY);

    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    transition_image(command, first);
    transition_image(command, second);
    transition_image(command, bgra);
    transition_image(command, bgra_second);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdFillBuffer(command, staging, 0, VK_WHOLE_SIZE, 0x11223344u);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (size_t i = 0; i < BYTES; i += 4) {
        expected[i + 0] = 0x44; expected[i + 1] = 0x33; expected[i + 2] = 0x22; expected[i + 3] = 0x11;
    }
    CHECK_VK(check_bytes(device, staging_memory, expected, "vkCmdFillBuffer"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    VkBufferCopy whole = { .size = BYTES };
    vkCmdCopyBuffer(command, upload, staging, 1, &whole);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (uint32_t y = 0; y < HEIGHT; ++y) for (uint32_t x = 0; x < WIDTH; ++x) {
        size_t i = ((size_t)y * WIDTH + x) * 4;
        expected[i + 0] = (uint8_t)(x ^ y); expected[i + 1] = (uint8_t)(x + 3 * y); expected[i + 2] = (uint8_t)(255 - x); expected[i + 3] = 255;
    }
    CHECK_VK(check_bytes(device, staging_memory, expected, "vkCmdCopyBuffer"));

    VkImageSubresourceRange range = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .levelCount = 1, .layerCount = 1 };
    VkClearColorValue blue = { .float32 = { 0.0f, 0.0f, 1.0f, 1.0f } };
    VkBufferImageCopy bir = { .imageSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .imageExtent = { WIDTH, HEIGHT, 1 } };
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdClearColorImage(command, second, VK_IMAGE_LAYOUT_GENERAL, &blue, 1, &range);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (size_t i = 0; i < BYTES; i += 4) {
        expected[i + 0] = 0; expected[i + 1] = 0; expected[i + 2] = 255; expected[i + 3] = 255;
    }
    CHECK_VK(check_bytes(device, second_memory, expected, "vkCmdClearColorImage RGBA"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyImageToBuffer(command, second, VK_IMAGE_LAYOUT_GENERAL, readback, 1, &bir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(check_bytes(device, readback_memory, expected, "vkCmdCopyImageToBuffer"));

    VkClearColorValue distinct = { .float32 = { 1.0f, 0.5f, 0.25f, 1.0f } };
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdClearColorImage(command, bgra, VK_IMAGE_LAYOUT_GENERAL, &distinct, 1, &range);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (size_t i = 0; i < BYTES; i += 4) {
        expected[i + 0] = 64; expected[i + 1] = 128; expected[i + 2] = 255; expected[i + 3] = 255;
    }
    CHECK_VK(check_bytes(device, bgra_memory, expected, "vkCmdClearColorImage BGRA"));

    CHECK_VK(vkMapMemory(device, upload_memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
    for (uint32_t y = 0; y < HEIGHT; ++y) for (uint32_t x = 0; x < WIDTH; ++x) {
        size_t i = ((size_t)y * WIDTH + x) * 4;
        expected[i + 0] = (uint8_t)(17 + x);
        expected[i + 1] = (uint8_t)(29 + 3 * y);
        expected[i + 2] = (uint8_t)(0xa5u ^ x ^ y);
        expected[i + 3] = (uint8_t)(255 - ((x + y) & 0x3f));
        memcpy(mapped + i, expected + i, 4);
    }
    vkUnmapMemory(device, upload_memory);
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyBufferToImage(command, upload, bgra, VK_IMAGE_LAYOUT_GENERAL, 1, &bir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(check_bytes(device, bgra_memory, expected, "vkCmdCopyBufferToImage BGRA"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyImageToBuffer(command, bgra, VK_IMAGE_LAYOUT_GENERAL, readback, 1, &bir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(check_bytes(device, readback_memory, expected, "vkCmdCopyImageToBuffer BGRA"));

    VkImageCopy ir = { .srcSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .dstSubresource = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1 }, .extent = { WIDTH, HEIGHT, 1 } };
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyImage(command, bgra, VK_IMAGE_LAYOUT_GENERAL, bgra_second, VK_IMAGE_LAYOUT_GENERAL, 1, &ir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(check_bytes(device, bgra_second_memory, expected, "vkCmdCopyImage BGRA"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyBufferToImage(command, staging, first, VK_IMAGE_LAYOUT_GENERAL, 1, &bir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (uint32_t y = 0; y < HEIGHT; ++y) for (uint32_t x = 0; x < WIDTH; ++x) {
        size_t i = ((size_t)y * WIDTH + x) * 4;
        expected[i + 0] = (uint8_t)(x ^ y); expected[i + 1] = (uint8_t)(x + 3 * y); expected[i + 2] = (uint8_t)(255 - x); expected[i + 3] = 255;
    }
    CHECK_VK(check_bytes(device, first_memory, expected, "vkCmdCopyBufferToImage"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdCopyImage(command, first, VK_IMAGE_LAYOUT_GENERAL, second, VK_IMAGE_LAYOUT_GENERAL, 1, &ir);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(vkQueueWaitIdle(queue)); CHECK_VK(vkDeviceWaitIdle(device));
    CHECK_VK(check_bytes(device, second_memory, expected, "vkCmdCopyImage"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    VkBufferCopy invalid = { .srcOffset = BYTES - 2, .size = 4 };
    vkCmdCopyBuffer(command, upload, staging, 1, &invalid);
    CHECK_TRUE(vkEndCommandBuffer(command) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdClearColorImage(command, second, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, &blue, 1, &range);
    CHECK_TRUE(vkEndCommandBuffer(command) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    VkImageMemoryBarrier unsupported_barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .srcAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
        .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT | VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_GENERAL,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = first,
        .subresourceRange = { VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &unsupported_barrier);
    CHECK_TRUE(vkEndCommandBuffer(command) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_TRUE(vkQueueSubmit(queue, 0, NULL, fence) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_TRUE(vkGetFenceStatus(device, fence) == VK_NOT_READY);
    CHECK_TRUE(vkWaitForFences(device, 1, &fence, VK_TRUE, 0) == VK_TIMEOUT);

    free(expected);
    vkDestroyFence(device, fence, NULL);
    vkFreeCommandBuffers(device, pool, 1, &command); vkDestroyCommandPool(device, pool, NULL);
    vkDestroyImage(device, bgra_second, NULL); vkFreeMemory(device, bgra_second_memory, NULL); vkDestroyImage(device, bgra, NULL); vkFreeMemory(device, bgra_memory, NULL); vkDestroyImage(device, second, NULL); vkFreeMemory(device, second_memory, NULL); vkDestroyImage(device, first, NULL); vkFreeMemory(device, first_memory, NULL);
    vkDestroyBuffer(device, readback, NULL); vkFreeMemory(device, readback_memory, NULL); vkDestroyBuffer(device, staging, NULL); vkFreeMemory(device, staging_memory, NULL); vkDestroyBuffer(device, upload, NULL); vkFreeMemory(device, upload_memory, NULL);
    vkDestroyDevice(device, NULL); vkDestroyInstance(instance, NULL);
    printf("exact transfer bytes: %u/%u; pixels: %u/%u\n", BYTES, BYTES, WIDTH * HEIGHT, WIDTH * HEIGHT);
    return 0;
}

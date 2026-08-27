#include <vulkan/vulkan.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// The transfer test exercises Vulkan 1.4 host-image-copy / subresource-layout
// commands. System headers older than 1.4 do not declare these types, so define
// the small subset the test needs when they are missing.
#ifndef VK_VERSION_1_4
# ifndef VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2
#  define VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2 1000338003
# endif
# ifndef VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2
#  define VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2 1000338002
# endif
# ifndef VK_STRUCTURE_TYPE_SUBRESOURCE_HOST_MEMCPY_SIZE
#  define VK_STRUCTURE_TYPE_SUBRESOURCE_HOST_MEMCPY_SIZE 1000270008
# endif
# ifndef VkImageSubresource2
 typedef struct VkImageSubresource2 {
     VkStructureType       sType;
     void*                 pNext;
     VkImageSubresource    imageSubresource;
 } VkImageSubresource2;
# endif
# ifndef VkSubresourceLayout2
 typedef struct VkSubresourceLayout2 {
     VkStructureType    sType;
     void*              pNext;
     VkSubresourceLayout subresourceLayout;
 } VkSubresourceLayout2;
# endif
# ifndef VkSubresourceHostMemcpySize
 typedef struct VkSubresourceHostMemcpySize {
     VkStructureType    sType;
     void*              pNext;
     VkDeviceSize       size;
 } VkSubresourceHostMemcpySize;
# endif
#endif
#ifndef VK_VERSION_1_4
typedef void (VKAPI_PTR *PFN_vkGetImageSubresourceLayout2)(VkDevice device, VkImage image, const VkImageSubresource2* pSubresource, VkSubresourceLayout2* pLayout);
#endif

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

static int allocate_bind_depth_image(VkDevice device, VkPhysicalDevice physical, VkImage *image, VkDeviceMemory *memory) {
    VkImageCreateInfo ii = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_D32_SFLOAT, .extent = { WIDTH, HEIGHT, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED };
    CHECK_VK(vkCreateImage(device, &ii, NULL, image));
    VkMemoryRequirements req;
    vkGetImageMemoryRequirements(device, *image, &req);
    VkMemoryAllocateInfo ai = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = req.size, .memoryTypeIndex = find_memory_type(physical, req.memoryTypeBits) };
    CHECK_VK(vkAllocateMemory(device, &ai, NULL, memory));
    CHECK_VK(vkBindImageMemory(device, *image, *memory, 0));
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

static void transition_depth_image(VkCommandBuffer command, VkImage image) {
    VkImageMemoryBarrier barrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_UNDEFINED,
        .newLayout = VK_IMAGE_LAYOUT_GENERAL,
        .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresourceRange = { VK_IMAGE_ASPECT_DEPTH_BIT, 0, 1, 0, 1 },
    };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, 0, NULL, 0, NULL, 1, &barrier);
}

int main(void) {
    uint32_t layer_count = 0;
    CHECK_VK(vkEnumerateInstanceLayerProperties(&layer_count, NULL));
    uint32_t instance_extension_count = 0;
    CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_extension_count, NULL));
    CHECK_TRUE(instance_extension_count >= 2 && instance_extension_count <= 64);
    VkExtensionProperties instance_extensions[64];
    CHECK_VK(vkEnumerateInstanceExtensionProperties(NULL, &instance_extension_count, instance_extensions));
    int found_surface = 0, found_xcb_surface = 0;
    for (uint32_t i = 0; i < instance_extension_count; ++i) {
        found_surface |= strcmp(instance_extensions[i].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0;
        found_xcb_surface |= strcmp(instance_extensions[i].extensionName, "VK_KHR_xcb_surface") == 0;
    }
    CHECK_TRUE(found_surface && found_xcb_surface);
    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .pApplicationName = "zpu-transfer-test", .apiVersion = VK_API_VERSION_1_0 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance instance;
    CHECK_VK(vkCreateInstance(&ici, NULL, &instance));
    uint32_t physical_count = 1;
    VkPhysicalDevice physical;
    CHECK_VK(vkEnumeratePhysicalDevices(instance, &physical_count, &physical));
    CHECK_TRUE(physical_count == 1);
    VkPhysicalDeviceFeatures physical_features;
    memset(&physical_features, 0xff, sizeof(physical_features));
    vkGetPhysicalDeviceFeatures(physical, &physical_features);
    const uint8_t *feature_bytes = (const uint8_t *)&physical_features;
    for (size_t i = 0; i < sizeof(physical_features); ++i) CHECK_TRUE(feature_bytes[i] == 0);
    uint32_t sparse_property_count = 1;
    VkSparseImageFormatProperties sparse_properties[1];
    vkGetPhysicalDeviceSparseImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_SAMPLE_COUNT_1_BIT, VK_IMAGE_USAGE_SAMPLED_BIT, VK_IMAGE_TILING_OPTIMAL, &sparse_property_count, sparse_properties);
    CHECK_TRUE(sparse_property_count == 0);
    uint32_t queue_family_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_family_count, NULL);
    CHECK_TRUE(queue_family_count == 1);
    VkQueueFamilyProperties queue_family;
    queue_family_count = 1;
    vkGetPhysicalDeviceQueueFamilyProperties(physical, &queue_family_count, &queue_family);
    CHECK_TRUE(queue_family_count == 1);
    CHECK_TRUE(queue_family.queueFlags == (VK_QUEUE_GRAPHICS_BIT | VK_QUEUE_COMPUTE_BIT | VK_QUEUE_TRANSFER_BIT));
    CHECK_TRUE(queue_family.queueCount == 1 && queue_family.timestampValidBits == 64);
    CHECK_TRUE(queue_family.minImageTransferGranularity.width == 1 && queue_family.minImageTransferGranularity.height == 1 && queue_family.minImageTransferGranularity.depth == 1);
    VkPhysicalDeviceMemoryProperties physical_memory;
    vkGetPhysicalDeviceMemoryProperties(physical, &physical_memory);
    CHECK_TRUE(physical_memory.memoryTypeCount == 1 && physical_memory.memoryHeapCount == 1);
    CHECK_TRUE(physical_memory.memoryTypes[0].propertyFlags == (VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT | VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT));
    CHECK_TRUE(physical_memory.memoryTypes[0].heapIndex == 0);
    CHECK_TRUE(physical_memory.memoryHeaps[0].size == 256ull * 1024ull * 1024ull && physical_memory.memoryHeaps[0].flags == 0);
    uint32_t device_extension_count = 0;
    CHECK_VK(vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, NULL));
    CHECK_TRUE(device_extension_count >= 2 && device_extension_count <= 64);
    VkExtensionProperties device_extensions[64];
    CHECK_VK(vkEnumerateDeviceExtensionProperties(physical, NULL, &device_extension_count, device_extensions));
    int found_swapchain = 0, found_present_timing = 0;
    for (uint32_t i = 0; i < device_extension_count; ++i) {
        found_swapchain |= strcmp(device_extensions[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0;
        found_present_timing |= strcmp(device_extensions[i].extensionName, "VK_EXT_present_timing") == 0;
    }
    CHECK_TRUE(found_swapchain && found_present_timing);
    layer_count = 0;
    CHECK_VK(vkEnumerateDeviceLayerProperties(physical, &layer_count, NULL));
    float priority = 1.0f;
    VkDeviceQueueCreateInfo qci = { .sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO, .queueFamilyIndex = 0, .queueCount = 1, .pQueuePriorities = &priority };
    VkDeviceCreateInfo dci = { .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO, .queueCreateInfoCount = 1, .pQueueCreateInfos = &qci };
    VkDevice device;
    CHECK_VK(vkCreateDevice(physical, &dci, NULL, &device));
    VkQueue queue;
    vkGetDeviceQueue(device, 0, 0, &queue);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkFlushMappedMemoryRanges") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkInvalidateMappedMemoryRanges") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetDeviceMemoryCommitment") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetImageSparseMemoryRequirements") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkResetCommandPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdExecuteCommands") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdClearDepthStencilImage") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetLineWidth") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetBlendConstants") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetDepthBias") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetDepthBounds") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetStencilCompareMask") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetStencilWriteMask") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetStencilReference") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdPushConstants") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdBindIndexBuffer") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdBindVertexBuffers") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdDrawIndexed") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdDrawIndirect") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdDrawIndexedIndirect") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdUpdateBuffer") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkQueueBindSparse") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetRenderAreaGranularity") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCreateEvent") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkDestroyEvent") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetEventStatus") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkSetEvent") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkResetEvent") != NULL);
    PFN_vkGetImageSubresourceLayout2 vkGetImageSubresourceLayout2_fn = (PFN_vkGetImageSubresourceLayout2)vkGetDeviceProcAddr(device, "vkGetImageSubresourceLayout2");
    CHECK_TRUE(vkGetImageSubresourceLayout2_fn != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdSetEvent") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdResetEvent") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdWaitEvents") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetPipelineCacheData") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkMergePipelineCaches") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCreateDescriptorPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkDestroyDescriptorPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkResetDescriptorPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkAllocateDescriptorSets") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkFreeDescriptorSets") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCreateQueryPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkDestroyQueryPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkGetQueryPoolResults") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdResetQueryPool") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdBeginQuery") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdEndQuery") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdWriteTimestamp") != NULL);
    CHECK_TRUE(vkGetDeviceProcAddr(device, "vkCmdCopyQueryPoolResults") != NULL);

    VkPipelineCacheCreateInfo pipeline_cache_info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO };
    VkPipelineCache pipeline_caches[2];
    CHECK_VK(vkCreatePipelineCache(device, &pipeline_cache_info, NULL, &pipeline_caches[0]));
    size_t pipeline_cache_size = 0;
    CHECK_VK(vkGetPipelineCacheData(device, pipeline_caches[0], &pipeline_cache_size, NULL));
    CHECK_TRUE(pipeline_cache_size == 32);
    uint8_t pipeline_cache_data[32];
    CHECK_VK(vkGetPipelineCacheData(device, pipeline_caches[0], &pipeline_cache_size, pipeline_cache_data));
    pipeline_cache_info.initialDataSize = pipeline_cache_size;
    pipeline_cache_info.pInitialData = pipeline_cache_data;
    CHECK_VK(vkCreatePipelineCache(device, &pipeline_cache_info, NULL, &pipeline_caches[1]));
    CHECK_VK(vkMergePipelineCaches(device, pipeline_caches[0], 1, &pipeline_caches[1]));

    VkDescriptorSetLayoutBinding descriptor_binding = { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_VERTEX_BIT };
    VkDescriptorSetLayoutCreateInfo descriptor_layout_info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 1, .pBindings = &descriptor_binding };
    VkDescriptorSetLayout descriptor_layout;
    CHECK_VK(vkCreateDescriptorSetLayout(device, &descriptor_layout_info, NULL, &descriptor_layout));
    VkPushConstantRange push_range = { .stageFlags = VK_SHADER_STAGE_ALL, .offset = 0, .size = 128 };
    VkPipelineLayoutCreateInfo push_layout_info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &descriptor_layout, .pushConstantRangeCount = 1, .pPushConstantRanges = &push_range };
    VkPipelineLayout push_layout;
    CHECK_VK(vkCreatePipelineLayout(device, &push_layout_info, NULL, &push_layout));
    VkDescriptorPoolSize descriptor_pool_size = { .type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 2 };
    VkDescriptorPoolCreateInfo descriptor_pool_info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .flags = VK_DESCRIPTOR_POOL_CREATE_FREE_DESCRIPTOR_SET_BIT, .maxSets = 2, .poolSizeCount = 1, .pPoolSizes = &descriptor_pool_size };
    VkDescriptorPool descriptor_pool;
    CHECK_VK(vkCreateDescriptorPool(device, &descriptor_pool_info, NULL, &descriptor_pool));
    VkDescriptorSetLayout descriptor_layouts[2] = { descriptor_layout, descriptor_layout };
    VkDescriptorSetAllocateInfo descriptor_allocate = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = descriptor_pool, .descriptorSetCount = 2, .pSetLayouts = descriptor_layouts };
    VkDescriptorSet descriptor_sets[2];
    CHECK_VK(vkAllocateDescriptorSets(device, &descriptor_allocate, descriptor_sets));
    CHECK_VK(vkFreeDescriptorSets(device, descriptor_pool, 1, &descriptor_sets[0]));
    descriptor_allocate.descriptorSetCount = 1;
    CHECK_VK(vkAllocateDescriptorSets(device, &descriptor_allocate, &descriptor_sets[0]));
    CHECK_VK(vkResetDescriptorPool(device, descriptor_pool, 0));

    VkAttachmentDescription attachment = { .format = VK_FORMAT_B8G8R8A8_UNORM, .samples = VK_SAMPLE_COUNT_1_BIT, .loadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .storeOp = VK_ATTACHMENT_STORE_OP_STORE, .stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE, .stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE, .initialLayout = VK_IMAGE_LAYOUT_UNDEFINED, .finalLayout = VK_IMAGE_LAYOUT_GENERAL };
    VkAttachmentReference color_attachment = { .attachment = 0, .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL };
    VkSubpassDescription subpass = { .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &color_attachment };
    VkRenderPassCreateInfo render_pass_info = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &attachment, .subpassCount = 1, .pSubpasses = &subpass };
    VkRenderPass render_pass;
    CHECK_VK(vkCreateRenderPass(device, &render_pass_info, NULL, &render_pass));
    VkExtent2D granularity = { 0, 0 };
    vkGetRenderAreaGranularity(device, render_pass, &granularity);
    CHECK_TRUE(granularity.width == 1 && granularity.height == 1);

    VkFormatProperties fp;
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, &fp);
    CHECK_TRUE(fp.linearTilingFeatures == (VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT));
    CHECK_TRUE(fp.optimalTilingFeatures == fp.linearTilingFeatures && fp.bufferFeatures == 0);
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8G8B8A8_SRGB, &fp);
    CHECK_TRUE(fp.linearTilingFeatures == VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT && fp.optimalTilingFeatures == VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT && fp.bufferFeatures == 0);
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_B8G8R8A8_UNORM, &fp);
    CHECK_TRUE(fp.linearTilingFeatures == (VK_FORMAT_FEATURE_COLOR_ATTACHMENT_BIT | VK_FORMAT_FEATURE_TRANSFER_SRC_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT));
    CHECK_TRUE(fp.optimalTilingFeatures == fp.linearTilingFeatures && fp.bufferFeatures == 0);
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_D32_SFLOAT, &fp);
    CHECK_TRUE(fp.linearTilingFeatures == 0 && fp.optimalTilingFeatures == (VK_FORMAT_FEATURE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_FORMAT_FEATURE_TRANSFER_DST_BIT) && fp.bufferFeatures == 0);
    vkGetPhysicalDeviceFormatProperties(physical, VK_FORMAT_R8_UNORM, &fp);
    CHECK_TRUE(fp.linearTilingFeatures == 0 && fp.optimalTilingFeatures == 0 && fp.bufferFeatures == 0);

    VkImageFormatProperties ifp;
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_SRC_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp));
    CHECK_TRUE(ifp.maxExtent.width == 8192 && ifp.maxExtent.height == 8192 && ifp.maxExtent.depth == 1);
    CHECK_TRUE(ifp.maxMipLevels == 1 && ifp.maxArrayLayers == 256 && ifp.sampleCounts == VK_SAMPLE_COUNT_1_BIT && ifp.maxResourceSize == 256ull * 1024ull * 1024ull);
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_B8G8R8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp));
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_SAMPLED_BIT, 0, &ifp));
    CHECK_VK(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_D32_SFLOAT, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_OPTIMAL, VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, 0, &ifp));
    CHECK_TRUE(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_SAMPLED_BIT, 0, &ifp) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    CHECK_TRUE(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8G8B8A8_SRGB, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    CHECK_TRUE(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_D32_SFLOAT, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT, 0, &ifp) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    CHECK_TRUE(vkGetPhysicalDeviceImageFormatProperties(physical, VK_FORMAT_R8_UNORM, VK_IMAGE_TYPE_2D, VK_IMAGE_TILING_LINEAR, VK_IMAGE_USAGE_TRANSFER_DST_BIT, 0, &ifp) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    VkImage bad_image;
    VkImageCreateInfo bad = { .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8_UNORM, .extent = { WIDTH, HEIGHT, 1 }, .mipLevels = 1, .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_LINEAR, .usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_TRUE(vkCreateImage(device, &bad, NULL, &bad_image) == VK_ERROR_FORMAT_NOT_SUPPORTED);
    bad.format = VK_FORMAT_R8G8B8A8_UNORM;
    bad.extent.width = UINT32_MAX;
    CHECK_TRUE(vkCreateImage(device, &bad, NULL, &bad_image) == VK_ERROR_INITIALIZATION_FAILED);
    VkBuffer bad_buffer;
    VkBufferCreateInfo bad_buffer_info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 16, .usage = VK_BUFFER_USAGE_STORAGE_TEXEL_BUFFER_BIT, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
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
    CHECK_VK(allocate_bind_buffer(device, physical, BYTES, VK_BUFFER_USAGE_TRANSFER_SRC_BIT | VK_BUFFER_USAGE_TRANSFER_DST_BIT | VK_BUFFER_USAGE_INDEX_BUFFER_BIT | VK_BUFFER_USAGE_VERTEX_BUFFER_BIT, &staging, &staging_memory));
    CHECK_VK(allocate_bind_buffer(device, physical, BYTES, VK_BUFFER_USAGE_TRANSFER_DST_BIT, &readback, &readback_memory));
    VkImage first, second, bgra, bgra_second, depth_transfer;
    VkDeviceMemory first_memory, second_memory, bgra_memory, bgra_second_memory, depth_transfer_memory;
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_R8G8B8A8_UNORM, &first, &first_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_R8G8B8A8_UNORM, &second, &second_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_B8G8R8A8_UNORM, &bgra, &bgra_memory));
    CHECK_VK(allocate_bind_image(device, physical, VK_FORMAT_B8G8R8A8_UNORM, &bgra_second, &bgra_second_memory));
    VkSubresourceHostMemcpySize host_memcpy_size = { .sType = VK_STRUCTURE_TYPE_SUBRESOURCE_HOST_MEMCPY_SIZE, .size = UINT64_MAX };
    VkSubresourceLayout2 layout2 = { .sType = VK_STRUCTURE_TYPE_SUBRESOURCE_LAYOUT_2, .pNext = &host_memcpy_size };
    VkImageSubresource2 subresource2 = { .sType = VK_STRUCTURE_TYPE_IMAGE_SUBRESOURCE_2, .imageSubresource = { .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT, .mipLevel = 0, .arrayLayer = 0 } };
    vkGetImageSubresourceLayout2_fn(device, first, &subresource2, &layout2);
    CHECK_TRUE(layout2.subresourceLayout.offset == 0 && layout2.subresourceLayout.size == BYTES && layout2.subresourceLayout.rowPitch == WIDTH * 4 && host_memcpy_size.size == BYTES);
    CHECK_VK(allocate_bind_depth_image(device, physical, &depth_transfer, &depth_transfer_memory));
    uint32_t sparse_requirement_count = 1;
    VkSparseImageMemoryRequirements sparse_requirement;
    vkGetImageSparseMemoryRequirements(device, first, &sparse_requirement_count, &sparse_requirement);
    CHECK_TRUE(sparse_requirement_count == 0);

    uint8_t *mapped;
    CHECK_VK(vkMapMemory(device, upload_memory, 0, VK_WHOLE_SIZE, 0, (void **)&mapped));
    uint8_t *expected = malloc(BYTES);
    CHECK_TRUE(expected != NULL);
    for (uint32_t y = 0; y < HEIGHT; ++y) for (uint32_t x = 0; x < WIDTH; ++x) {
        size_t i = ((size_t)y * WIDTH + x) * 4;
        mapped[i + 0] = (uint8_t)(x ^ y); mapped[i + 1] = (uint8_t)(x + 3 * y); mapped[i + 2] = (uint8_t)(255 - x); mapped[i + 3] = 255;
        memcpy(expected + i, mapped + i, 4);
    }
    VkMappedMemoryRange mapped_range = { .sType = VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE, .memory = upload_memory, .offset = 0, .size = VK_WHOLE_SIZE };
    CHECK_VK(vkFlushMappedMemoryRanges(device, 1, &mapped_range));
    CHECK_VK(vkInvalidateMappedMemoryRanges(device, 1, &mapped_range));
    vkUnmapMemory(device, upload_memory);

    VkCommandPoolCreateInfo pci = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CHECK_VK(vkCreateCommandPool(device, &pci, NULL, &pool));
    VkCommandBufferAllocateInfo cai = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer command;
    CHECK_VK(vkAllocateCommandBuffers(device, &cai, &command));
    cai.level = VK_COMMAND_BUFFER_LEVEL_SECONDARY;
    VkCommandBuffer secondary_command;
    CHECK_VK(vkAllocateCommandBuffers(device, &cai, &secondary_command));
    cai.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    VkCommandBufferBeginInfo begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    VkFenceCreateInfo fci = { .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO };
    VkFence fence;
    CHECK_VK(vkCreateFence(device, &fci, NULL, &fence));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdDrawIndexed(command, 0, 0, 0, 0, 0);
    CHECK_TRUE(vkEndCommandBuffer(command) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_TRUE(vkGetFenceStatus(device, fence) == VK_NOT_READY);
    CHECK_VK(vkQueueBindSparse(queue, 0, NULL, fence));
    CHECK_VK(vkWaitForFences(device, 1, &fence, VK_TRUE, UINT64_MAX));
    CHECK_VK(vkResetFences(device, 1, &fence));
    VkEventCreateInfo event_info = { .sType = VK_STRUCTURE_TYPE_EVENT_CREATE_INFO };
    VkEvent event;
    CHECK_VK(vkCreateEvent(device, &event_info, NULL, &event));
    CHECK_TRUE(vkGetEventStatus(device, event) == VK_EVENT_RESET);
    CHECK_VK(vkSetEvent(device, event));
    CHECK_TRUE(vkGetEventStatus(device, event) == VK_EVENT_SET);
    CHECK_VK(vkResetEvent(device, event));
    VkQueryPoolCreateInfo query_info = { .sType = VK_STRUCTURE_TYPE_QUERY_POOL_CREATE_INFO, .queryType = VK_QUERY_TYPE_TIMESTAMP, .queryCount = 2 };
    VkQueryPool query_pool;
    CHECK_VK(vkCreateQueryPool(device, &query_info, NULL, &query_pool));

    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdResetQueryPool(command, query_pool, 0, 2);
    vkCmdWriteTimestamp(command, VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, query_pool, 0);
    vkCmdWriteTimestamp(command, VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, query_pool, 1);
    vkCmdCopyQueryPoolResults(command, query_pool, 0, 2, staging, 0, 16, VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WITH_AVAILABILITY_BIT);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    uint64_t query_results[2] = { 0, 0 };
    CHECK_VK(vkGetQueryPoolResults(device, query_pool, 0, 2, sizeof(query_results), query_results, sizeof(uint64_t), VK_QUERY_RESULT_64_BIT | VK_QUERY_RESULT_WAIT_BIT));
    CHECK_TRUE(query_results[0] != 0 && query_results[1] >= query_results[0]);
    CHECK_VK(vkResetCommandBuffer(command, 0));

    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    VkMemoryBarrier memory_barrier = { .sType = VK_STRUCTURE_TYPE_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT };
    VkBufferMemoryBarrier buffer_barrier = { .sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER, .srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT, .dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT, .srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED, .buffer = staging, .offset = 0, .size = VK_WHOLE_SIZE };
    vkCmdPipelineBarrier(command, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, VK_DEPENDENCY_BY_REGION_BIT, 1, &memory_barrier, 1, &buffer_barrier, 0, NULL);
    transition_image(command, first);
    transition_image(command, second);
    transition_image(command, bgra);
    transition_image(command, bgra_second);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_VK(vkResetCommandPool(device, pool, VK_COMMAND_POOL_RESET_RELEASE_RESOURCES_BIT));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdSetEvent(command, event, VK_PIPELINE_STAGE_TRANSFER_BIT);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_TRUE(vkGetEventStatus(device, event) == VK_EVENT_SET);
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdResetEvent(command, event, VK_PIPELINE_STAGE_TRANSFER_BIT);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    CHECK_TRUE(vkGetEventStatus(device, event) == VK_EVENT_RESET);
    CHECK_VK(vkSetEvent(device, event));
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    // A host-signaled event participates in a legacy wait only when HOST is
    // included in the first synchronization scope.
    vkCmdWaitEvents(command, 1, &event, VK_PIPELINE_STAGE_HOST_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT, 0, NULL, 0, NULL, 0, NULL);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdSetLineWidth(command, 1.0f);
    const float blend_constants[4] = { 0.125f, 0.25f, 0.5f, 1.0f };
    vkCmdSetBlendConstants(command, blend_constants);
    vkCmdSetDepthBias(command, 1.25f, 0.0f, -2.5f);
    vkCmdSetDepthBounds(command, 0.25f, 0.75f);
    vkCmdSetStencilCompareMask(command, VK_STENCIL_FACE_FRONT_AND_BACK, 0x12345678u);
    vkCmdSetStencilWriteMask(command, VK_STENCIL_FACE_FRONT_BIT, 0xabcdef01u);
    vkCmdSetStencilReference(command, VK_STENCIL_FACE_BACK_BIT, 0x87654321u);
    const uint8_t push_bytes[16] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    vkCmdPushConstants(command, push_layout, VK_SHADER_STAGE_VERTEX_BIT | VK_SHADER_STAGE_FRAGMENT_BIT, 16, sizeof(push_bytes), push_bytes);
    const VkDeviceSize vertex_offset = 16;
    vkCmdBindVertexBuffers(command, 0, 1, &staging, &vertex_offset);
    vkCmdBindIndexBuffer(command, staging, 16, VK_INDEX_TYPE_UINT32);
    vkCmdFillBuffer(command, staging, 0, VK_WHOLE_SIZE, 0x11223344u);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (size_t i = 0; i < BYTES; i += 4) {
        expected[i + 0] = 0x44; expected[i + 1] = 0x33; expected[i + 2] = 0x22; expected[i + 3] = 0x11;
    }
    CHECK_VK(check_bytes(device, staging_memory, expected, "vkCmdFillBuffer"));

    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    uint8_t update_payload[16] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    uint8_t update_snapshot[16];
    memcpy(update_snapshot, update_payload, sizeof(update_snapshot));
    vkCmdUpdateBuffer(command, staging, 8, sizeof(update_payload), update_payload);
    memset(update_payload, 0xff, sizeof(update_payload));
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    memcpy(expected + 8, update_snapshot, sizeof(update_snapshot));
    CHECK_VK(check_bytes(device, staging_memory, expected, "vkCmdUpdateBuffer caller ownership"));

    VkCommandBufferInheritanceInfo inheritance = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_INHERITANCE_INFO };
    VkCommandBufferBeginInfo secondary_begin = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO, .pInheritanceInfo = &inheritance };
    CHECK_VK(vkBeginCommandBuffer(secondary_command, &secondary_begin));
    vkCmdFillBuffer(secondary_command, staging, 0, VK_WHOLE_SIZE, 0x55667788u);
    CHECK_VK(vkEndCommandBuffer(secondary_command));
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdExecuteCommands(command, 1, &secondary_command);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    for (size_t i = 0; i < BYTES; i += 4) {
        expected[i + 0] = 0x88; expected[i + 1] = 0x77; expected[i + 2] = 0x66; expected[i + 3] = 0x55;
    }
    CHECK_VK(check_bytes(device, staging_memory, expected, "vkCmdExecuteCommands secondary order"));
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkResetCommandBuffer(secondary_command, 0));

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
    transition_depth_image(command, depth_transfer);
    VkClearDepthStencilValue depth_clear = { .depth = 0.25f, .stencil = 0xffffffffu };
    VkImageSubresourceRange depth_range = { .aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT, .levelCount = 1, .layerCount = 1 };
    vkCmdClearDepthStencilImage(command, depth_transfer, VK_IMAGE_LAYOUT_GENERAL, &depth_clear, 1, &depth_range);
    CHECK_VK(vkEndCommandBuffer(command));
    CHECK_VK(submit_wait(device, queue, command, fence));
    float *depth_values;
    CHECK_VK(vkMapMemory(device, depth_transfer_memory, 0, VK_WHOLE_SIZE, 0, (void **)&depth_values));
    for (size_t i = 0; i < WIDTH * HEIGHT; ++i) CHECK_TRUE(depth_values[i] == 0.25f);
    vkUnmapMemory(device, depth_transfer_memory);

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
    CHECK_VK(vkResetCommandBuffer(command, 0));
    CHECK_VK(vkBeginCommandBuffer(command, &begin));
    vkCmdFillBuffer(command, staging, 0, 0, 0xffffffffu);
    CHECK_TRUE(vkEndCommandBuffer(command) == VK_ERROR_INITIALIZATION_FAILED);
    VkSubmitInfo rejected_submit = { .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &command };
    CHECK_TRUE(vkQueueSubmit(queue, 1, &rejected_submit, fence) == VK_ERROR_INITIALIZATION_FAILED);
    CHECK_TRUE(vkGetFenceStatus(device, fence) == VK_NOT_READY);
    CHECK_VK(check_bytes(device, staging_memory, expected, "zero-size vkCmdFillBuffer rejection"));
    CHECK_VK(vkQueueSubmit(queue, 0, NULL, fence));
    CHECK_VK(vkGetFenceStatus(device, fence));
    CHECK_VK(vkWaitForFences(device, 1, &fence, VK_TRUE, 0));

    free(expected);
    vkDestroyPipelineCache(device, pipeline_caches[1], NULL);
    vkDestroyPipelineCache(device, pipeline_caches[0], NULL);
    vkDestroyDescriptorPool(device, descriptor_pool, NULL);
    vkDestroyPipelineLayout(device, push_layout, NULL);
    vkDestroyDescriptorSetLayout(device, descriptor_layout, NULL);
    vkDestroyQueryPool(device, query_pool, NULL);
    vkDestroyEvent(device, event, NULL);
    vkDestroyRenderPass(device, render_pass, NULL);
    vkDestroyFence(device, fence, NULL);
    vkFreeCommandBuffers(device, pool, 1, &secondary_command); vkFreeCommandBuffers(device, pool, 1, &command); vkDestroyCommandPool(device, pool, NULL);
    vkDestroyImage(device, depth_transfer, NULL); vkFreeMemory(device, depth_transfer_memory, NULL); vkDestroyImage(device, bgra_second, NULL); vkFreeMemory(device, bgra_second_memory, NULL); vkDestroyImage(device, bgra, NULL); vkFreeMemory(device, bgra_memory, NULL); vkDestroyImage(device, second, NULL); vkFreeMemory(device, second_memory, NULL); vkDestroyImage(device, first, NULL); vkFreeMemory(device, first_memory, NULL);
    vkDestroyBuffer(device, readback, NULL); vkFreeMemory(device, readback_memory, NULL); vkDestroyBuffer(device, staging, NULL); vkFreeMemory(device, staging_memory, NULL); vkDestroyBuffer(device, upload, NULL); vkFreeMemory(device, upload_memory, NULL);
    vkDestroyDevice(device, NULL); vkDestroyInstance(instance, NULL);
    printf("exact transfer bytes: %u/%u; pixels: %u/%u\n", BYTES, BYTES, WIDTH * HEIGHT, WIDTH * HEIGHT);
    return 0;
}

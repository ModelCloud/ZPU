// Copyright 2026 Qubitium (qubitium@modelcloud.ai) and ModelCloud team
// SPDX-License-Identifier: Apache-2.0

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

static uint32_t memory_type(VkPhysicalDevice physical, uint32_t bits) {
    VkPhysicalDeviceMemoryProperties properties;
    vkGetPhysicalDeviceMemoryProperties(physical, &properties);
    for (uint32_t i = 0; i < properties.memoryTypeCount; ++i) {
        const VkMemoryPropertyFlags required = VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT;
        if ((bits & (1u << i)) != 0 && (properties.memoryTypes[i].propertyFlags & required) == required) return i;
    }
    return UINT32_MAX;
}

static int allocate_buffer(VkDevice device, VkPhysicalDevice physical, VkDeviceSize size, VkBufferUsageFlags usage,
                           VkBuffer *buffer, VkDeviceMemory *memory) {
    VkBufferCreateInfo info = { .sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = size, .usage = usage, .sharingMode = VK_SHARING_MODE_EXCLUSIVE };
    CHECK_VK(vkCreateBuffer(device, &info, NULL, buffer));
    VkMemoryRequirements requirements;
    vkGetBufferMemoryRequirements(device, *buffer, &requirements);
    VkMemoryAllocateInfo allocation = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type(physical, requirements.memoryTypeBits) };
    CHECK_TRUE(allocation.memoryTypeIndex != UINT32_MAX);
    CHECK_VK(vkAllocateMemory(device, &allocation, NULL, memory));
    CHECK_VK(vkBindBufferMemory(device, *buffer, *memory, 0));
    return 0;
}

static int allocate_image(VkDevice device, VkPhysicalDevice physical, VkFormat format, VkExtent2D extent,
                          VkImageTiling tiling, VkImageUsageFlags usage, VkImageLayout initial_layout,
                          VkImage *image, VkDeviceMemory *memory) {
    VkImageCreateInfo info = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = format,
        .extent = { extent.width, extent.height, 1 }, .mipLevels = 1, .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = tiling, .usage = usage,
        .sharingMode = VK_SHARING_MODE_EXCLUSIVE, .initialLayout = initial_layout,
    };
    CHECK_VK(vkCreateImage(device, &info, NULL, image));
    VkMemoryRequirements requirements;
    vkGetImageMemoryRequirements(device, *image, &requirements);
    VkMemoryAllocateInfo allocation = { .sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = requirements.size, .memoryTypeIndex = memory_type(physical, requirements.memoryTypeBits) };
    CHECK_TRUE(allocation.memoryTypeIndex != UINT32_MAX);
    CHECK_VK(vkAllocateMemory(device, &allocation, NULL, memory));
    CHECK_VK(vkBindImageMemory(device, *image, *memory, 0));
    return 0;
}

static int load_vkcube_shaders(uint32_t **vertex, size_t *vertex_size, uint32_t **fragment, size_t *fragment_size) {
    FILE *file = fopen("/usr/bin/vkcube", "rb");
    CHECK_TRUE(file != NULL && fseek(file, 0, SEEK_END) == 0);
    long length = ftell(file);
    CHECK_TRUE(length > 0 && fseek(file, 0, SEEK_SET) == 0);
    uint8_t *bytes = malloc((size_t)length);
    CHECK_TRUE(bytes != NULL && fread(bytes, 1, (size_t)length, file) == (size_t)length);
    fclose(file);
    const uint8_t magic[4] = { 3, 2, 35, 7 };
    size_t offsets[2] = { 0, 0 }, found = 0;
    for (size_t i = 0; i + 4 <= (size_t)length && found < 2; ++i) if (memcmp(bytes + i, magic, 4) == 0) offsets[found++] = i;
    CHECK_TRUE(found == 2 && offsets[0] + 390 * 4 <= (size_t)length && offsets[1] + 661 * 4 <= (size_t)length);
    *vertex_size = 390 * 4;
    *fragment_size = 661 * 4;
    *vertex = malloc(*vertex_size);
    *fragment = malloc(*fragment_size);
    CHECK_TRUE(*vertex != NULL && *fragment != NULL);
    memcpy(*vertex, bytes + offsets[0], *vertex_size);
    memcpy(*fragment, bytes + offsets[1], *fragment_size);
    free(bytes);
    return 0;
}

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
    VkFramebuffer framebuffer;
    CHECK_VK(vkCreateFramebuffer(device, &framebuffer_info, NULL, &framebuffer));

    VkImage depth_image;
    VkDeviceMemory depth_memory;
    CHECK_VK(allocate_image(device, physical, VK_FORMAT_D32_SFLOAT, (VkExtent2D){ width, height }, VK_IMAGE_TILING_OPTIMAL,
                            VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                            VK_IMAGE_LAYOUT_UNDEFINED, &depth_image, &depth_memory));
    VkImageViewCreateInfo depth_view_info = view_info;
    depth_view_info.image = depth_image;
    depth_view_info.format = VK_FORMAT_D32_SFLOAT;
    depth_view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    VkImageView depth_view;
    CHECK_VK(vkCreateImageView(device, &depth_view_info, NULL, &depth_view));
    const VkImageView draw_attachments[2] = { view, depth_view };
    VkFramebufferCreateInfo draw_framebuffer_info = framebuffer_info;
    draw_framebuffer_info.renderPass = color_depth_render_pass;
    draw_framebuffer_info.attachmentCount = 2;
    draw_framebuffer_info.pAttachments = draw_attachments;
    VkFramebuffer draw_framebuffer;
    CHECK_VK(vkCreateFramebuffer(device, &draw_framebuffer_info, NULL, &draw_framebuffer));

    VkImage texture_image;
    VkDeviceMemory texture_memory;
    CHECK_VK(allocate_image(device, physical, VK_FORMAT_R8G8B8A8_SRGB, (VkExtent2D){ 1, 1 }, VK_IMAGE_TILING_OPTIMAL,
                            VK_IMAGE_USAGE_SAMPLED_BIT, VK_IMAGE_LAYOUT_PREINITIALIZED, &texture_image, &texture_memory));
    uint8_t *texture_bytes;
    CHECK_VK(vkMapMemory(device, texture_memory, 0, VK_WHOLE_SIZE, 0, (void **)&texture_bytes));
    memset(texture_bytes, 255, 4);
    vkUnmapMemory(device, texture_memory);
    VkImageViewCreateInfo texture_view_info = view_info;
    texture_view_info.image = texture_image;
    texture_view_info.format = VK_FORMAT_R8G8B8A8_SRGB;
    VkImageView texture_view;
    CHECK_VK(vkCreateImageView(device, &texture_view_info, NULL, &texture_view));
    VkSamplerCreateInfo sampler_info = { .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO };
    VkSampler sampler;
    CHECK_VK(vkCreateSampler(device, &sampler_info, NULL, &sampler));

    VkBuffer uniform_buffer, index_buffer, indirect_buffer;
    VkDeviceMemory uniform_memory, index_memory, indirect_memory;
    CHECK_VK(allocate_buffer(device, physical, 160, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, &uniform_buffer, &uniform_memory));
    CHECK_VK(allocate_buffer(device, physical, 8, VK_BUFFER_USAGE_INDEX_BUFFER_BIT, &index_buffer, &index_memory));
    CHECK_VK(allocate_buffer(device, physical, 40, VK_BUFFER_USAGE_INDIRECT_BUFFER_BIT, &indirect_buffer, &indirect_memory));
    float *uniform;
    CHECK_VK(vkMapMemory(device, uniform_memory, 0, VK_WHOLE_SIZE, 0, (void **)&uniform));
    memset(uniform, 0, 160);
    uniform[0] = uniform[5] = uniform[10] = uniform[15] = 1.0f;
    const float vertices[24] = {
        -0.8f, -0.8f, 0.2f, 1.0f, 0.8f, -0.8f, 0.2f, 1.0f, 0.0f, 0.8f, 0.2f, 1.0f,
        0.0f, 0.0f, 0.0f, 0.0f, 1.0f, 0.0f, 0.0f, 0.0f, 0.5f, 1.0f, 0.0f, 0.0f,
    };
    memcpy(uniform + 16, vertices, sizeof(vertices));
    vkUnmapMemory(device, uniform_memory);
    uint16_t *indices;
    CHECK_VK(vkMapMemory(device, index_memory, 0, VK_WHOLE_SIZE, 0, (void **)&indices));
    indices[0] = 99;
    indices[1] = 1;
    indices[2] = 2;
    indices[3] = 3;
    vkUnmapMemory(device, index_memory);
    uint32_t *indirect_words;
    CHECK_VK(vkMapMemory(device, indirect_memory, 0, VK_WHOLE_SIZE, 0, (void **)&indirect_words));
    indirect_words[0] = 3;
    indirect_words[1] = 2;
    indirect_words[2] = 1;
    indirect_words[3] = (uint32_t)-1;
    indirect_words[4] = 0;
    indirect_words[5] = 3;
    indirect_words[6] = 2;
    indirect_words[7] = 0;
    indirect_words[8] = 0;
    indirect_words[9] = 0;
    vkUnmapMemory(device, indirect_memory);

    const VkDescriptorSetLayoutBinding layout_bindings[2] = {
        { .binding = 0, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_VERTEX_BIT },
        { .binding = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .descriptorCount = 1, .stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT },
    };
    VkDescriptorSetLayoutCreateInfo descriptor_layout_info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO, .bindingCount = 2, .pBindings = layout_bindings };
    VkDescriptorSetLayout descriptor_layout;
    CHECK_VK(vkCreateDescriptorSetLayout(device, &descriptor_layout_info, NULL, &descriptor_layout));
    VkPipelineLayoutCreateInfo pipeline_layout_info = { .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO, .setLayoutCount = 1, .pSetLayouts = &descriptor_layout };
    VkPipelineLayout pipeline_layout;
    CHECK_VK(vkCreatePipelineLayout(device, &pipeline_layout_info, NULL, &pipeline_layout));
    const VkDescriptorPoolSize pool_sizes[2] = {
        { VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, 1 }, { VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, 1 },
    };
    VkDescriptorPoolCreateInfo descriptor_pool_info = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO, .maxSets = 1, .poolSizeCount = 2, .pPoolSizes = pool_sizes };
    VkDescriptorPool descriptor_pool;
    CHECK_VK(vkCreateDescriptorPool(device, &descriptor_pool_info, NULL, &descriptor_pool));
    VkDescriptorSetAllocateInfo descriptor_allocate = { .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO, .descriptorPool = descriptor_pool, .descriptorSetCount = 1, .pSetLayouts = &descriptor_layout };
    VkDescriptorSet descriptor_set;
    CHECK_VK(vkAllocateDescriptorSets(device, &descriptor_allocate, &descriptor_set));
    VkDescriptorBufferInfo descriptor_buffer = { uniform_buffer, 0, 160 };
    VkDescriptorImageInfo descriptor_image = { sampler, texture_view, VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL };
    const VkWriteDescriptorSet descriptor_writes[2] = {
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 0, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, .pBufferInfo = &descriptor_buffer },
        { .sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET, .dstSet = descriptor_set, .dstBinding = 1, .descriptorCount = 1, .descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, .pImageInfo = &descriptor_image },
    };
    vkUpdateDescriptorSets(device, 2, descriptor_writes, 0, NULL);

    uint32_t *vertex_words, *fragment_words;
    size_t vertex_size, fragment_size;
    CHECK_VK(load_vkcube_shaders(&vertex_words, &vertex_size, &fragment_words, &fragment_size));
    VkShaderModuleCreateInfo vertex_module_info = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = vertex_size, .pCode = vertex_words };
    VkShaderModuleCreateInfo fragment_module_info = { .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO, .codeSize = fragment_size, .pCode = fragment_words };
    VkShaderModule vertex_module, fragment_module;
    CHECK_VK(vkCreateShaderModule(device, &vertex_module_info, NULL, &vertex_module));
    CHECK_VK(vkCreateShaderModule(device, &fragment_module_info, NULL, &fragment_module));
    free(vertex_words);
    free(fragment_words);
    const VkPipelineShaderStageCreateInfo shader_stages[2] = {
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = vertex_module, .pName = "main" },
        { .sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = fragment_module, .pName = "main" },
    };
    VkPipelineVertexInputStateCreateInfo vertex_input = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO };
    VkPipelineInputAssemblyStateCreateInfo input_assembly = { .sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST };
    VkPipelineViewportStateCreateInfo viewport_state = { .sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1 };
    VkPipelineRasterizationStateCreateInfo rasterization = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL,
        .cullMode = VK_CULL_MODE_NONE, .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1.0f,
    };
    VkPipelineMultisampleStateCreateInfo multisample = { .sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT };
    VkPipelineDepthStencilStateCreateInfo depth_stencil = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO,
        .depthTestEnable = VK_TRUE, .depthWriteEnable = VK_TRUE, .depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL,
        .maxDepthBounds = 1.0f,
    };
    VkPipelineColorBlendAttachmentState blend_attachment = { .colorWriteMask = 0xf };
    VkPipelineColorBlendStateCreateInfo blend = { .sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &blend_attachment };
    const VkDynamicState dynamic_values[2] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dynamic = { .sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = dynamic_values };
    VkGraphicsPipelineCreateInfo pipeline_info = {
        .sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = shader_stages,
        .pVertexInputState = &vertex_input, .pInputAssemblyState = &input_assembly, .pViewportState = &viewport_state,
        .pRasterizationState = &rasterization, .pMultisampleState = &multisample, .pDepthStencilState = &depth_stencil,
        .pColorBlendState = &blend, .pDynamicState = &dynamic, .layout = pipeline_layout,
        .renderPass = color_depth_render_pass, .subpass = 0, .basePipelineIndex = -1,
    };
    VkPipeline pipeline;
    CHECK_VK(vkCreateGraphicsPipelines(device, VK_NULL_HANDLE, 1, &pipeline_info, NULL, &pipeline));

    VkCommandPoolCreateInfo pool_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO, .queueFamilyIndex = 0 };
    VkCommandPool pool;
    CHECK_VK(vkCreateCommandPool(device, &pool_info, NULL, &pool));
    VkCommandBufferAllocateInfo command_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = pool, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1 };
    VkCommandBuffer command;
    CHECK_VK(vkAllocateCommandBuffers(device, &command_info, &command));
    VkCommandBufferBeginInfo begin_info = { .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO };
    CHECK_VK(vkBeginCommandBuffer(command, &begin_info));
    const VkClearValue clears[2] = {
        { .color.float32 = { 0.2f, 0.2f, 0.2f, 1.0f } },
        { .depthStencil = { 1.0f, 0 } },
    };
    VkRenderPassBeginInfo begin_render_pass = { .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = color_depth_render_pass, .framebuffer = draw_framebuffer, .renderArea = { { 0, 0 }, { width, height } }, .clearValueCount = 2, .pClearValues = clears };
    vkCmdBeginRenderPass(command, &begin_render_pass, VK_SUBPASS_CONTENTS_INLINE);
    vkCmdBindPipeline(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
    vkCmdBindDescriptorSets(command, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline_layout, 0, 1, &descriptor_set, 0, NULL);
    VkViewport viewport = { 0, 0, width, height, 0, 1 };
    VkRect2D scissor = { { 0, 0 }, { width, height } };
    vkCmdSetViewport(command, 0, 1, &viewport);
    vkCmdSetScissor(command, 0, 1, &scissor);
    vkCmdBindIndexBuffer(command, index_buffer, 0, VK_INDEX_TYPE_UINT16);
    vkCmdDrawIndexedIndirect(command, indirect_buffer, 0, 1, 20);
    vkCmdDrawIndirect(command, indirect_buffer, 20, 1, 20);
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
        puts("xcb_present_expected_pixel=non_clear_indexed_draw");
        puts("xcb_present_readback=not_attempted_untrusted_x11");
    } else {
        xcb_get_image_cookie_t image_cookie = xcb_get_image(connection, XCB_IMAGE_FORMAT_Z_PIXMAP, window, width / 2, height / 2, 1, 1, UINT32_MAX);
        xcb_get_image_reply_t *image_reply = xcb_get_image_reply(connection, image_cookie, NULL);
        CHECK_TRUE(image_reply != NULL && xcb_get_image_data_length(image_reply) >= 4);
        const uint8_t *pixel = xcb_get_image_data(image_reply);
        CHECK_TRUE(pixel[0] != 51 || pixel[1] != 51 || pixel[2] != 51);
        printf("xcb_present_indexed_pixel=BGRA(%u,%u,%u,%u)\n", pixel[0], pixel[1], pixel[2], pixel[3]);
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
    vkDestroyPipeline(device, pipeline, NULL);
    vkDestroyShaderModule(device, fragment_module, NULL);
    vkDestroyShaderModule(device, vertex_module, NULL);
    vkDestroyDescriptorPool(device, descriptor_pool, NULL);
    vkDestroyPipelineLayout(device, pipeline_layout, NULL);
    vkDestroyDescriptorSetLayout(device, descriptor_layout, NULL);
    vkDestroyBuffer(device, index_buffer, NULL);
    vkFreeMemory(device, index_memory, NULL);
    vkDestroyBuffer(device, indirect_buffer, NULL);
    vkFreeMemory(device, indirect_memory, NULL);
    vkDestroyBuffer(device, uniform_buffer, NULL);
    vkFreeMemory(device, uniform_memory, NULL);
    vkDestroySampler(device, sampler, NULL);
    vkDestroyImageView(device, texture_view, NULL);
    vkDestroyImage(device, texture_image, NULL);
    vkFreeMemory(device, texture_memory, NULL);
    vkDestroyFramebuffer(device, draw_framebuffer, NULL);
    vkDestroyImageView(device, depth_view, NULL);
    vkDestroyImage(device, depth_image, NULL);
    vkFreeMemory(device, depth_memory, NULL);
    vkDestroyFramebuffer(device, framebuffer, NULL);
    vkDestroyRenderPass(device, color_depth_render_pass, NULL);
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

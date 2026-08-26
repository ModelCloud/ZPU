# Vulkan 1.0–1.4 core command matrix

Generated from the pinned Vulkan 1.4.360 inventory. Do not edit by hand; run `python3 tools/vulkan_command_matrix.py --write`.

`Dispatched` means a command name is exposed by a ZPU lookup table. `Implemented` means the command has an evidence-backed entry in the policy for ZPU's currently advertised narrow profile; it is not a claim of complete Vulkan 1.4 conformance. A narrow path, stub, opaque placeholder, or unaudited behavior should remain `No` until its advertised contract is explicit.

Current totals: **234 core commands**, **234 dispatched**, **234 narrow-profile evidence entries**.

| Core | Command | Description | Dispatched | Implemented |
| --- | --- | --- | --- | --- |
| 1.0 | `vkAllocateCommandBuffers` | Allocate command buffers. | Yes | Yes |
| 1.0 | `vkAllocateDescriptorSets` | Allocate descriptor sets. | Yes | Yes |
| 1.0 | `vkAllocateMemory` | Allocate memory. | Yes | Yes |
| 1.0 | `vkBeginCommandBuffer` | Begin command buffer. | Yes | Yes |
| 1.0 | `vkBindBufferMemory` | Bind buffer memory. | Yes | Yes |
| 1.0 | `vkBindImageMemory` | Bind image memory. | Yes | Yes |
| 1.0 | `vkCmdBeginQuery` | Record begin query in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBeginRenderPass` | Record begin render pass in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBindDescriptorSets` | Record bind descriptor sets in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBindIndexBuffer` | Record bind index buffer in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBindPipeline` | Record bind pipeline in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBindVertexBuffers` | Record bind vertex buffers in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdBlitImage` | Record blit image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdClearAttachments` | Record clear attachments in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdClearColorImage` | Record clear color image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdClearDepthStencilImage` | Record clear depth stencil image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdCopyBuffer` | Record copy buffer in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdCopyBufferToImage` | Record copy buffer to image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdCopyImage` | Record copy image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdCopyImageToBuffer` | Record copy image to buffer in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdCopyQueryPoolResults` | Record copy query pool results in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDispatch` | Record dispatch in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDispatchIndirect` | Record dispatch indirect in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDraw` | Record draw in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDrawIndexed` | Record draw indexed in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDrawIndexedIndirect` | Record draw indexed indirect in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdDrawIndirect` | Record draw indirect in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdEndQuery` | Record end query in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdEndRenderPass` | Record end render pass in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdExecuteCommands` | Record execute commands in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdFillBuffer` | Record fill buffer in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdNextSubpass` | Record next subpass in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdPipelineBarrier` | Record pipeline barrier in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdPushConstants` | Record push constants in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdResetEvent` | Record reset event in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdResetQueryPool` | Record reset query pool in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdResolveImage` | Record resolve image in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetBlendConstants` | Record set blend constants in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetDepthBias` | Record set depth bias in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetDepthBounds` | Record set depth bounds in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetEvent` | Record set event in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetLineWidth` | Record set line width in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetScissor` | Record set scissor in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetStencilCompareMask` | Record set stencil compare mask in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetStencilReference` | Record set stencil reference in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetStencilWriteMask` | Record set stencil write mask in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdSetViewport` | Record set viewport in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdUpdateBuffer` | Record update buffer in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdWaitEvents` | Record wait events in a command buffer. | Yes | Yes |
| 1.0 | `vkCmdWriteTimestamp` | Record write timestamp in a command buffer. | Yes | Yes |
| 1.0 | `vkCreateBuffer` | Create buffer. | Yes | Yes |
| 1.0 | `vkCreateBufferView` | Create buffer view. | Yes | Yes |
| 1.0 | `vkCreateCommandPool` | Create command pool. | Yes | Yes |
| 1.0 | `vkCreateComputePipelines` | Create compute pipelines. | Yes | Yes |
| 1.0 | `vkCreateDescriptorPool` | Create descriptor pool. | Yes | Yes |
| 1.0 | `vkCreateDescriptorSetLayout` | Create descriptor set layout. | Yes | Yes |
| 1.0 | `vkCreateDevice` | Create device. | Yes | Yes |
| 1.0 | `vkCreateEvent` | Create event. | Yes | Yes |
| 1.0 | `vkCreateFence` | Create fence. | Yes | Yes |
| 1.0 | `vkCreateFramebuffer` | Create framebuffer. | Yes | Yes |
| 1.0 | `vkCreateGraphicsPipelines` | Create graphics pipelines. | Yes | Yes |
| 1.0 | `vkCreateImage` | Create image. | Yes | Yes |
| 1.0 | `vkCreateImageView` | Create image view. | Yes | Yes |
| 1.0 | `vkCreateInstance` | Create instance. | Yes | Yes |
| 1.0 | `vkCreatePipelineCache` | Create pipeline cache. | Yes | Yes |
| 1.0 | `vkCreatePipelineLayout` | Create pipeline layout. | Yes | Yes |
| 1.0 | `vkCreateQueryPool` | Create query pool. | Yes | Yes |
| 1.0 | `vkCreateRenderPass` | Create render pass. | Yes | Yes |
| 1.0 | `vkCreateSampler` | Create sampler. | Yes | Yes |
| 1.0 | `vkCreateSemaphore` | Create semaphore. | Yes | Yes |
| 1.0 | `vkCreateShaderModule` | Create shader module. | Yes | Yes |
| 1.0 | `vkDestroyBuffer` | Destroy buffer. | Yes | Yes |
| 1.0 | `vkDestroyBufferView` | Destroy buffer view. | Yes | Yes |
| 1.0 | `vkDestroyCommandPool` | Destroy command pool. | Yes | Yes |
| 1.0 | `vkDestroyDescriptorPool` | Destroy descriptor pool. | Yes | Yes |
| 1.0 | `vkDestroyDescriptorSetLayout` | Destroy descriptor set layout. | Yes | Yes |
| 1.0 | `vkDestroyDevice` | Destroy device. | Yes | Yes |
| 1.0 | `vkDestroyEvent` | Destroy event. | Yes | Yes |
| 1.0 | `vkDestroyFence` | Destroy fence. | Yes | Yes |
| 1.0 | `vkDestroyFramebuffer` | Destroy framebuffer. | Yes | Yes |
| 1.0 | `vkDestroyImage` | Destroy image. | Yes | Yes |
| 1.0 | `vkDestroyImageView` | Destroy image view. | Yes | Yes |
| 1.0 | `vkDestroyInstance` | Destroy instance. | Yes | Yes |
| 1.0 | `vkDestroyPipeline` | Destroy pipeline. | Yes | Yes |
| 1.0 | `vkDestroyPipelineCache` | Destroy pipeline cache. | Yes | Yes |
| 1.0 | `vkDestroyPipelineLayout` | Destroy pipeline layout. | Yes | Yes |
| 1.0 | `vkDestroyQueryPool` | Destroy query pool. | Yes | Yes |
| 1.0 | `vkDestroyRenderPass` | Destroy render pass. | Yes | Yes |
| 1.0 | `vkDestroySampler` | Destroy sampler. | Yes | Yes |
| 1.0 | `vkDestroySemaphore` | Destroy semaphore. | Yes | Yes |
| 1.0 | `vkDestroyShaderModule` | Destroy shader module. | Yes | Yes |
| 1.0 | `vkDeviceWaitIdle` | Perform the device operation wait idle. | Yes | Yes |
| 1.0 | `vkEndCommandBuffer` | End command buffer. | Yes | Yes |
| 1.0 | `vkEnumerateDeviceExtensionProperties` | Enumerate device extension properties. | Yes | Yes |
| 1.0 | `vkEnumerateDeviceLayerProperties` | Enumerate device layer properties. | Yes | Yes |
| 1.0 | `vkEnumerateInstanceExtensionProperties` | Enumerate instance extension properties. | Yes | Yes |
| 1.0 | `vkEnumerateInstanceLayerProperties` | Enumerate instance layer properties. | Yes | Yes |
| 1.0 | `vkEnumeratePhysicalDevices` | Enumerate physical devices. | Yes | Yes |
| 1.0 | `vkFlushMappedMemoryRanges` | Flush mapped memory ranges. | Yes | Yes |
| 1.0 | `vkFreeCommandBuffers` | Free command buffers. | Yes | Yes |
| 1.0 | `vkFreeDescriptorSets` | Free descriptor sets. | Yes | Yes |
| 1.0 | `vkFreeMemory` | Free memory. | Yes | Yes |
| 1.0 | `vkGetBufferMemoryRequirements` | Query buffer memory requirements. | Yes | Yes |
| 1.0 | `vkGetDeviceMemoryCommitment` | Query device memory commitment. | Yes | Yes |
| 1.0 | `vkGetDeviceProcAddr` | Query device proc addr. | Yes | Yes |
| 1.0 | `vkGetDeviceQueue` | Query device queue. | Yes | Yes |
| 1.0 | `vkGetEventStatus` | Query event status. | Yes | Yes |
| 1.0 | `vkGetFenceStatus` | Query fence status. | Yes | Yes |
| 1.0 | `vkGetImageMemoryRequirements` | Query image memory requirements. | Yes | Yes |
| 1.0 | `vkGetImageSparseMemoryRequirements` | Query image sparse memory requirements. | Yes | Yes |
| 1.0 | `vkGetImageSubresourceLayout` | Query image subresource layout. | Yes | Yes |
| 1.0 | `vkGetInstanceProcAddr` | Query instance proc addr. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceFeatures` | Query physical device features. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceFormatProperties` | Query physical device format properties. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceImageFormatProperties` | Query physical device image format properties. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceMemoryProperties` | Query physical device memory properties. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceProperties` | Query physical device properties. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceQueueFamilyProperties` | Query physical device queue family properties. | Yes | Yes |
| 1.0 | `vkGetPhysicalDeviceSparseImageFormatProperties` | Query physical device sparse image format properties. | Yes | Yes |
| 1.0 | `vkGetPipelineCacheData` | Query pipeline cache data. | Yes | Yes |
| 1.0 | `vkGetQueryPoolResults` | Query query pool results. | Yes | Yes |
| 1.0 | `vkGetRenderAreaGranularity` | Query render area granularity. | Yes | Yes |
| 1.0 | `vkInvalidateMappedMemoryRanges` | Invalidate mapped memory ranges. | Yes | Yes |
| 1.0 | `vkMapMemory` | Map memory. | Yes | Yes |
| 1.0 | `vkMergePipelineCaches` | Merge pipeline caches. | Yes | Yes |
| 1.0 | `vkQueueBindSparse` | Perform bind sparse on a queue. | Yes | Yes |
| 1.0 | `vkQueueSubmit` | Perform submit on a queue. | Yes | Yes |
| 1.0 | `vkQueueWaitIdle` | Perform wait idle on a queue. | Yes | Yes |
| 1.0 | `vkResetCommandBuffer` | Reset command buffer. | Yes | Yes |
| 1.0 | `vkResetCommandPool` | Reset command pool. | Yes | Yes |
| 1.0 | `vkResetDescriptorPool` | Reset descriptor pool. | Yes | Yes |
| 1.0 | `vkResetEvent` | Reset event. | Yes | Yes |
| 1.0 | `vkResetFences` | Reset fences. | Yes | Yes |
| 1.0 | `vkSetEvent` | Set event. | Yes | Yes |
| 1.0 | `vkUnmapMemory` | Unmap memory. | Yes | Yes |
| 1.0 | `vkUpdateDescriptorSets` | Update descriptor sets. | Yes | Yes |
| 1.0 | `vkWaitForFences` | Wait for for fences. | Yes | Yes |
| 1.1 | `vkBindBufferMemory2` | Bind buffer memory2. | Yes | Yes |
| 1.1 | `vkBindImageMemory2` | Bind image memory2. | Yes | Yes |
| 1.1 | `vkCmdDispatchBase` | Record dispatch base in a command buffer. | Yes | Yes |
| 1.1 | `vkCmdSetDeviceMask` | Record set device mask in a command buffer. | Yes | Yes |
| 1.1 | `vkCreateDescriptorUpdateTemplate` | Create descriptor update template. | Yes | Yes |
| 1.1 | `vkCreateSamplerYcbcrConversion` | Create sampler ycbcr conversion. | Yes | Yes |
| 1.1 | `vkDestroyDescriptorUpdateTemplate` | Destroy descriptor update template. | Yes | Yes |
| 1.1 | `vkDestroySamplerYcbcrConversion` | Destroy sampler ycbcr conversion. | Yes | Yes |
| 1.1 | `vkEnumerateInstanceVersion` | Enumerate instance version. | Yes | Yes |
| 1.1 | `vkEnumeratePhysicalDeviceGroups` | Enumerate physical device groups. | Yes | Yes |
| 1.1 | `vkGetBufferMemoryRequirements2` | Query buffer memory requirements2. | Yes | Yes |
| 1.1 | `vkGetDescriptorSetLayoutSupport` | Query descriptor set layout support. | Yes | Yes |
| 1.1 | `vkGetDeviceGroupPeerMemoryFeatures` | Query device group peer memory features. | Yes | Yes |
| 1.1 | `vkGetDeviceQueue2` | Query device queue2. | Yes | Yes |
| 1.1 | `vkGetImageMemoryRequirements2` | Query image memory requirements2. | Yes | Yes |
| 1.1 | `vkGetImageSparseMemoryRequirements2` | Query image sparse memory requirements2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceExternalBufferProperties` | Query physical device external buffer properties. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceExternalFenceProperties` | Query physical device external fence properties. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceExternalSemaphoreProperties` | Query physical device external semaphore properties. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceFeatures2` | Query physical device features2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceFormatProperties2` | Query physical device format properties2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceImageFormatProperties2` | Query physical device image format properties2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceMemoryProperties2` | Query physical device memory properties2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceProperties2` | Query physical device properties2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceQueueFamilyProperties2` | Query physical device queue family properties2. | Yes | Yes |
| 1.1 | `vkGetPhysicalDeviceSparseImageFormatProperties2` | Query physical device sparse image format properties2. | Yes | Yes |
| 1.1 | `vkTrimCommandPool` | Perform trim command pool. | Yes | Yes |
| 1.1 | `vkUpdateDescriptorSetWithTemplate` | Update descriptor set with template. | Yes | Yes |
| 1.2 | `vkCmdBeginRenderPass2` | Record begin render pass2 in a command buffer. | Yes | Yes |
| 1.2 | `vkCmdDrawIndexedIndirectCount` | Record draw indexed indirect count in a command buffer. | Yes | Yes |
| 1.2 | `vkCmdDrawIndirectCount` | Record draw indirect count in a command buffer. | Yes | Yes |
| 1.2 | `vkCmdEndRenderPass2` | Record end render pass2 in a command buffer. | Yes | Yes |
| 1.2 | `vkCmdNextSubpass2` | Record next subpass2 in a command buffer. | Yes | Yes |
| 1.2 | `vkCreateRenderPass2` | Create render pass2. | Yes | Yes |
| 1.2 | `vkGetBufferDeviceAddress` | Query buffer device address. | Yes | Yes |
| 1.2 | `vkGetBufferOpaqueCaptureAddress` | Query buffer opaque capture address. | Yes | Yes |
| 1.2 | `vkGetDeviceMemoryOpaqueCaptureAddress` | Query device memory opaque capture address. | Yes | Yes |
| 1.2 | `vkGetSemaphoreCounterValue` | Query semaphore counter value. | Yes | Yes |
| 1.2 | `vkResetQueryPool` | Reset query pool. | Yes | Yes |
| 1.2 | `vkSignalSemaphore` | Signal semaphore. | Yes | Yes |
| 1.2 | `vkWaitSemaphores` | Wait for semaphores. | Yes | Yes |
| 1.3 | `vkCmdBeginRendering` | Record begin rendering in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdBindVertexBuffers2` | Record bind vertex buffers2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdBlitImage2` | Record blit image2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdCopyBuffer2` | Record copy buffer2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdCopyBufferToImage2` | Record copy buffer to image2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdCopyImage2` | Record copy image2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdCopyImageToBuffer2` | Record copy image to buffer2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdEndRendering` | Record end rendering in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdPipelineBarrier2` | Record pipeline barrier2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdResetEvent2` | Record reset event2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdResolveImage2` | Record resolve image2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetCullMode` | Record set cull mode in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetDepthBiasEnable` | Record set depth bias enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetDepthBoundsTestEnable` | Record set depth bounds test enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetDepthCompareOp` | Record set depth compare op in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetDepthTestEnable` | Record set depth test enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetDepthWriteEnable` | Record set depth write enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetEvent2` | Record set event2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetFrontFace` | Record set front face in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetPrimitiveRestartEnable` | Record set primitive restart enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetPrimitiveTopology` | Record set primitive topology in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetRasterizerDiscardEnable` | Record set rasterizer discard enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetScissorWithCount` | Record set scissor with count in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetStencilOp` | Record set stencil op in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetStencilTestEnable` | Record set stencil test enable in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdSetViewportWithCount` | Record set viewport with count in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdWaitEvents2` | Record wait events2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCmdWriteTimestamp2` | Record write timestamp2 in a command buffer. | Yes | Yes |
| 1.3 | `vkCreatePrivateDataSlot` | Create private data slot. | Yes | Yes |
| 1.3 | `vkDestroyPrivateDataSlot` | Destroy private data slot. | Yes | Yes |
| 1.3 | `vkGetDeviceBufferMemoryRequirements` | Query device buffer memory requirements. | Yes | Yes |
| 1.3 | `vkGetDeviceImageMemoryRequirements` | Query device image memory requirements. | Yes | Yes |
| 1.3 | `vkGetDeviceImageSparseMemoryRequirements` | Query device image sparse memory requirements. | Yes | Yes |
| 1.3 | `vkGetPhysicalDeviceToolProperties` | Query physical device tool properties. | Yes | Yes |
| 1.3 | `vkGetPrivateData` | Query private data. | Yes | Yes |
| 1.3 | `vkQueueSubmit2` | Perform submit2 on a queue. | Yes | Yes |
| 1.3 | `vkSetPrivateData` | Set private data. | Yes | Yes |
| 1.4 | `vkCmdBindDescriptorSets2` | Record bind descriptor sets2 in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdBindIndexBuffer2` | Record bind index buffer2 in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdPushConstants2` | Record push constants2 in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdPushDescriptorSet` | Record push descriptor set in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdPushDescriptorSet2` | Record push descriptor set2 in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdPushDescriptorSetWithTemplate` | Record push descriptor set with template in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdPushDescriptorSetWithTemplate2` | Record push descriptor set with template2 in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdSetLineStipple` | Record set line stipple in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdSetRenderingAttachmentLocations` | Record set rendering attachment locations in a command buffer. | Yes | Yes |
| 1.4 | `vkCmdSetRenderingInputAttachmentIndices` | Record set rendering input attachment indices in a command buffer. | Yes | Yes |
| 1.4 | `vkCopyImageToImage` | Copy image to image. | Yes | Yes |
| 1.4 | `vkCopyImageToMemory` | Copy image to memory. | Yes | Yes |
| 1.4 | `vkCopyMemoryToImage` | Copy memory to image. | Yes | Yes |
| 1.4 | `vkGetDeviceImageSubresourceLayout` | Query device image subresource layout. | Yes | Yes |
| 1.4 | `vkGetImageSubresourceLayout2` | Query image subresource layout2. | Yes | Yes |
| 1.4 | `vkGetRenderingAreaGranularity` | Query rendering area granularity. | Yes | Yes |
| 1.4 | `vkMapMemory2` | Map memory2. | Yes | Yes |
| 1.4 | `vkTransitionImageLayout` | Transition image layout. | Yes | Yes |
| 1.4 | `vkUnmapMemory2` | Unmap memory2. | Yes | Yes |

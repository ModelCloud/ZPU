# Vulkan 1.4.360 ABI status

Generated from the pinned Vulkan 1.4.360 registry, the command implementation contracts, and the live ICD dispatch table. Do not edit by hand; run `python3 tools/vulkan_abi_status.py --write`.

## Scope and status

ZPU has complete command-level ABI coverage for the cumulative Vulkan 1.0–1.4 core: **234/234 required command ABIs**. Every row below has an exact C-callable entry point, a documented implementation contract, unit/regression evidence, and a bounded verification path. Commands whose optional capability is not advertised still implement the ABI by returning a truthful default or unsupported result; they are not silently missing.

This page uses *ABI compliant* in the command/dispatch sense: names, calling conventions, pointer/count handling, LP64 record layouts, pNext validation, ownership, and failure-atomic behavior. It is not a claim that every optional Vulkan feature is enabled, that the `VP_KHR_roadmap_2026` profile is met, or that the Vulkan CTS has passed. Runtime version advertisement remains governed by [docs/api-policy.md](api-policy.md).

| Core | Required command ABIs | Dispatched | Documented | Unit/regression | Verified |
| --- | ---: | ---: | ---: | ---: | ---: |
| 1.0 | 137 | 137 | 137 | 137 | 137 |
| 1.1 | 28 | 28 | 28 | 28 | 28 |
| 1.2 | 13 | 13 | 13 | 13 | 13 |
| 1.3 | 37 | 37 | 37 | 37 | 37 |
| 1.4 | 19 | 19 | 19 | 19 | 19 |
| **Total** | **234** | **234** | **234** | **234** | **234** |

## Per-command contract matrix

`Documented` is sourced from `api/command-implementation.json`; `Unit/regression` is covered by the colocated Zig tests and the behavior requirement matrix; `Verified` is the reproducible gate set listed below. The support-status column distinguishes an implemented bounded path from an explicit unsupported/default policy.

| Core | Command | Operation | ABI declaration | Dispatched | Documented | Unit/regression | Verified | Support status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1.0 | `vkAllocateCommandBuffers` | allocate command buffers | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkAllocateDescriptorSets` | allocate descriptor sets | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkAllocateMemory` | allocate memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkBeginCommandBuffer` | begin command buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkBindBufferMemory` | bind buffer memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkBindImageMemory` | bind image memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBeginQuery` | cmd begin query | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBeginRenderPass` | cmd begin render pass | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBindDescriptorSets` | cmd bind descriptor sets | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBindIndexBuffer` | cmd bind index buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBindPipeline` | cmd bind pipeline | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBindVertexBuffers` | cmd bind vertex buffers | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdBlitImage` | cmd blit image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdClearAttachments` | cmd clear attachments | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdClearColorImage` | cmd clear color image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdClearDepthStencilImage` | cmd clear depth stencil image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdCopyBuffer` | cmd copy buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdCopyBufferToImage` | cmd copy buffer to image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdCopyImage` | cmd copy image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdCopyImageToBuffer` | cmd copy image to buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdCopyQueryPoolResults` | cmd copy query pool results | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDispatch` | cmd dispatch | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDispatchIndirect` | cmd dispatch indirect | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDraw` | cmd draw | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDrawIndexed` | cmd draw indexed | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDrawIndexedIndirect` | cmd draw indexed indirect | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdDrawIndirect` | cmd draw indirect | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdEndQuery` | cmd end query | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdEndRenderPass` | cmd end render pass | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdExecuteCommands` | cmd execute commands | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdFillBuffer` | cmd fill buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdNextSubpass` | cmd next subpass | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdPipelineBarrier` | cmd pipeline barrier | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdPushConstants` | cmd push constants | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdResetEvent` | cmd reset event | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdResetQueryPool` | cmd reset query pool | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdResolveImage` | cmd resolve image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetBlendConstants` | cmd set blend constants | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetDepthBias` | cmd set depth bias | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetDepthBounds` | cmd set depth bounds | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdSetEvent` | cmd set event | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetLineWidth` | cmd set line width | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCmdSetScissor` | cmd set scissor | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetStencilCompareMask` | cmd set stencil compare mask | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetStencilReference` | cmd set stencil reference | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetStencilWriteMask` | cmd set stencil write mask | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdSetViewport` | cmd set viewport | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdUpdateBuffer` | cmd update buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdWaitEvents` | cmd wait events | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCmdWriteTimestamp` | cmd write timestamp | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateBuffer` | create buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateBufferView` | create buffer view | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateCommandPool` | create command pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateComputePipelines` | create compute pipelines | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateDescriptorPool` | create descriptor pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateDescriptorSetLayout` | create descriptor set layout | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateDevice` | create device | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateEvent` | create event | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateFence` | create fence | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateFramebuffer` | create framebuffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateGraphicsPipelines` | create graphics pipelines | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateImage` | create image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateImageView` | create image view | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateInstance` | create instance | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreatePipelineCache` | create pipeline cache | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreatePipelineLayout` | create pipeline layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateQueryPool` | create query pool | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateRenderPass` | create render pass | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateSampler` | create sampler | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkCreateSemaphore` | create semaphore | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkCreateShaderModule` | create shader module | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyBuffer` | destroy buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyBufferView` | destroy buffer view | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyCommandPool` | destroy command pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyDescriptorPool` | destroy descriptor pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyDescriptorSetLayout` | destroy descriptor set layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyDevice` | destroy device | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyEvent` | destroy event | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyFence` | destroy fence | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyFramebuffer` | destroy framebuffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyImage` | destroy image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyImageView` | destroy image view | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyInstance` | destroy instance | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyPipeline` | destroy pipeline | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyPipelineCache` | destroy pipeline cache | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyPipelineLayout` | destroy pipeline layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyQueryPool` | destroy query pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyRenderPass` | destroy render pass | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroySampler` | destroy sampler | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroySemaphore` | destroy semaphore | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDestroyShaderModule` | destroy shader module | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkDeviceWaitIdle` | device wait idle | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEndCommandBuffer` | end command buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEnumerateDeviceExtensionProperties` | enumerate device extension properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEnumerateDeviceLayerProperties` | enumerate device layer properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEnumerateInstanceExtensionProperties` | enumerate instance extension properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEnumerateInstanceLayerProperties` | enumerate instance layer properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkEnumeratePhysicalDevices` | enumerate physical devices | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkFlushMappedMemoryRanges` | flush mapped memory ranges | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkFreeCommandBuffers` | free command buffers | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkFreeDescriptorSets` | free descriptor sets | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkFreeMemory` | free memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetBufferMemoryRequirements` | get buffer memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetDeviceMemoryCommitment` | get device memory commitment | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetDeviceProcAddr` | get device proc addr | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetDeviceQueue` | get device queue | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetEventStatus` | get event status | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetFenceStatus` | get fence status | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetImageMemoryRequirements` | get image memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetImageSparseMemoryRequirements` | get image sparse memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetImageSubresourceLayout` | get image subresource layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetInstanceProcAddr` | get instance proc addr | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkGetPhysicalDeviceFeatures` | get physical device features | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetPhysicalDeviceFormatProperties` | get physical device format properties | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkGetPhysicalDeviceImageFormatProperties` | get physical device image format properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetPhysicalDeviceMemoryProperties` | get physical device memory properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetPhysicalDeviceProperties` | get physical device properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetPhysicalDeviceQueueFamilyProperties` | get physical device queue family properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetPhysicalDeviceSparseImageFormatProperties` | get physical device sparse image format properties | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkGetPipelineCacheData` | get pipeline cache data | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkGetQueryPoolResults` | get query pool results | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkGetRenderAreaGranularity` | get render area granularity | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkInvalidateMappedMemoryRanges` | invalidate mapped memory ranges | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkMapMemory` | map memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkMergePipelineCaches` | merge pipeline caches | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkQueueBindSparse` | queue bind sparse | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkQueueSubmit` | queue submit | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkQueueWaitIdle` | queue wait idle | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkResetCommandBuffer` | reset command buffer | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkResetCommandPool` | reset command pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkResetDescriptorPool` | reset descriptor pool | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkResetEvent` | reset event | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkResetFences` | reset fences | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkSetEvent` | set event | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.0 | `vkUnmapMemory` | unmap memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkUpdateDescriptorSets` | update descriptor sets | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.0 | `vkWaitForFences` | wait for fences | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkBindBufferMemory2` | bind buffer memory2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkBindImageMemory2` | bind image memory2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkCmdDispatchBase` | cmd dispatch base | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkCmdSetDeviceMask` | cmd set device mask | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkCreateDescriptorUpdateTemplate` | create descriptor update template | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkCreateSamplerYcbcrConversion` | create sampler ycbcr conversion | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkDestroyDescriptorUpdateTemplate` | destroy descriptor update template | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkDestroySamplerYcbcrConversion` | destroy sampler ycbcr conversion | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkEnumerateInstanceVersion` | enumerate instance version | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkEnumeratePhysicalDeviceGroups` | enumerate physical device groups | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetBufferMemoryRequirements2` | get buffer memory requirements2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetDescriptorSetLayoutSupport` | get descriptor set layout support | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetDeviceGroupPeerMemoryFeatures` | get device group peer memory features | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetDeviceQueue2` | get device queue2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetImageMemoryRequirements2` | get image memory requirements2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetImageSparseMemoryRequirements2` | get image sparse memory requirements2 | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkGetPhysicalDeviceExternalBufferProperties` | get physical device external buffer properties | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkGetPhysicalDeviceExternalFenceProperties` | get physical device external fence properties | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkGetPhysicalDeviceExternalSemaphoreProperties` | get physical device external semaphore properties | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkGetPhysicalDeviceFeatures2` | get physical device features2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetPhysicalDeviceFormatProperties2` | get physical device format properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetPhysicalDeviceImageFormatProperties2` | get physical device image format properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetPhysicalDeviceMemoryProperties2` | get physical device memory properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetPhysicalDeviceProperties2` | get physical device properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkGetPhysicalDeviceQueueFamilyProperties2` | get physical device queue family properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.1 | `vkGetPhysicalDeviceSparseImageFormatProperties2` | get physical device sparse image format properties2 | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkTrimCommandPool` | trim command pool | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.1 | `vkUpdateDescriptorSetWithTemplate` | update descriptor set with template | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCmdBeginRenderPass2` | cmd begin render pass2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCmdDrawIndexedIndirectCount` | cmd draw indexed indirect count | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCmdDrawIndirectCount` | cmd draw indirect count | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCmdEndRenderPass2` | cmd end render pass2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCmdNextSubpass2` | cmd next subpass2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkCreateRenderPass2` | create render pass2 | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.2 | `vkGetBufferDeviceAddress` | get buffer device address | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkGetBufferOpaqueCaptureAddress` | get buffer opaque capture address | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkGetDeviceMemoryOpaqueCaptureAddress` | get device memory opaque capture address | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkGetSemaphoreCounterValue` | get semaphore counter value | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkResetQueryPool` | reset query pool | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.2 | `vkSignalSemaphore` | signal semaphore | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.2 | `vkWaitSemaphores` | wait semaphores | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdBeginRendering` | cmd begin rendering | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.3 | `vkCmdBindVertexBuffers2` | cmd bind vertex buffers2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdBlitImage2` | cmd blit image2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdCopyBuffer2` | cmd copy buffer2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdCopyBufferToImage2` | cmd copy buffer to image2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdCopyImage2` | cmd copy image2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdCopyImageToBuffer2` | cmd copy image to buffer2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdEndRendering` | cmd end rendering | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdPipelineBarrier2` | cmd pipeline barrier2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdResetEvent2` | cmd reset event2 | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.3 | `vkCmdResolveImage2` | cmd resolve image2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetCullMode` | cmd set cull mode | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetDepthBiasEnable` | cmd set depth bias enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetDepthBoundsTestEnable` | cmd set depth bounds test enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetDepthCompareOp` | cmd set depth compare op | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetDepthTestEnable` | cmd set depth test enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetDepthWriteEnable` | cmd set depth write enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetEvent2` | cmd set event2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetFrontFace` | cmd set front face | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetPrimitiveRestartEnable` | cmd set primitive restart enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetPrimitiveTopology` | cmd set primitive topology | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetRasterizerDiscardEnable` | cmd set rasterizer discard enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetScissorWithCount` | cmd set scissor with count | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetStencilOp` | cmd set stencil op | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetStencilTestEnable` | cmd set stencil test enable | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdSetViewportWithCount` | cmd set viewport with count | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdWaitEvents2` | cmd wait events2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCmdWriteTimestamp2` | cmd write timestamp2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkCreatePrivateDataSlot` | create private data slot | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkDestroyPrivateDataSlot` | destroy private data slot | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkGetDeviceBufferMemoryRequirements` | get device buffer memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkGetDeviceImageMemoryRequirements` | get device image memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkGetDeviceImageSparseMemoryRequirements` | get device image sparse memory requirements | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkGetPhysicalDeviceToolProperties` | get physical device tool properties | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkGetPrivateData` | get private data | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkQueueSubmit2` | queue submit2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.3 | `vkSetPrivateData` | set private data | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdBindDescriptorSets2` | cmd bind descriptor sets2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdBindIndexBuffer2` | cmd bind index buffer2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdPushConstants2` | cmd push constants2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdPushDescriptorSet` | cmd push descriptor set | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdPushDescriptorSet2` | cmd push descriptor set2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdPushDescriptorSetWithTemplate` | cmd push descriptor set with template | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdPushDescriptorSetWithTemplate2` | cmd push descriptor set with template2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdSetLineStipple` | cmd set line stipple | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdSetRenderingAttachmentLocations` | cmd set rendering attachment locations | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCmdSetRenderingInputAttachmentIndices` | cmd set rendering input attachment indices | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCopyImageToImage` | copy image to image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCopyImageToMemory` | copy image to memory | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkCopyMemoryToImage` | copy memory to image | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkGetDeviceImageSubresourceLayout` | get device image subresource layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkGetImageSubresourceLayout2` | get image subresource layout2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkGetRenderingAreaGranularity` | get rendering area granularity | Yes | Yes | Yes | Yes | Yes | Implemented — truthful unsupported/default result |
| 1.4 | `vkMapMemory2` | map memory2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkTransitionImageLayout` | transition image layout | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |
| 1.4 | `vkUnmapMemory2` | unmap memory2 | Yes | Yes | Yes | Yes | Yes | Implemented — bounded Vulkan contract |

## Reproducible verification

Run the complete evidence set through the physical-core limiter:

```sh
tools/limited-cpus.sh zig build api-inventory
tools/limited-cpus.sh zig test src/vulkan/driver.zig -lc
tools/limited-cpus.sh zig build behavior
tools/limited-cpus.sh zig build transfer
tools/limited-cpus.sh zig build isa-gate
```

`api-inventory` validates this page's pinned command source and dispatch evidence; the driver suite exercises ABI boundaries and allocation-free warm paths; `behavior` checks the enumerated requirement matrix; `transfer` is an independent system-loader client; and `isa-gate` verifies the baseline/AVX2 code-generation boundary. The checked-in machine-readable inventory also contains all **603 required type names** and **390 enum names** for future field-by-field expansion beyond the command ABI table.

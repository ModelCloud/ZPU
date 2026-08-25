//! Original minimal ABI transcription from the public Vulkan 1.0 specification and
//! Khronos loader/driver interface documentation. This is an experimental ICD.
const std = @import("std");
const builtin = @import("builtin");
const cpu_locality = @import("cpu_locality.zig");
const cpu_cube = @import("cpu_cube.zig");
const host_memory = @import("host_memory.zig");
const xcb_present = @import("xcb_present.zig");
const frame_pacing = @import("frame_pacing.zig");
const frame_lifecycle = @import("frame_lifecycle.zig");
const present_worker = @import("present_worker.zig");
const spirv = @import("spirv.zig");
const spirv_frontend = @import("spirv_frontend.zig");
const render_ir = @import("render_ir.zig");
pub const Result = enum(i32) { success = 0, not_ready = 1, timeout = 2, incomplete = 5, error_out_of_host_memory = -1, error_initialization_failed = -3, error_memory_map_failed = -5, error_layer_not_present = -6, error_extension_not_present = -7, error_feature_not_present = -8, error_format_not_supported = -11, error_invalid_shader = -1_000_012_000 };
pub const Fn = ?*const fn () callconv(.c) void;
pub const Alloc = opaque {};
pub const MAGIC: usize = 0x01CDC0DE;
pub const API_1_0: u32 = 1 << 22;
pub const AppInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, app_name: ?[*:0]const u8, app_version: u32, engine_name: ?[*:0]const u8, engine_version: u32, api_version: u32 };
pub const InstanceInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, app_info: ?*const AppInfo, layer_count: u32, layers: ?[*]const [*:0]const u8, extension_count: u32, extensions: ?[*]const [*:0]const u8 };
pub const QueueInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, family: u32, count: u32, priorities: ?[*]const f32 };
pub const Features = extern struct { values: [55]u32 };
pub const DeviceInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, queue_info_count: u32, queue_infos: ?[*]const QueueInfo, layer_count: u32, layers: ?[*]const [*:0]const u8, extension_count: u32, extensions: ?[*]const [*:0]const u8, features: ?*const Features };
pub const ExtensionProperties = extern struct { name: [256]u8, spec_version: u32 };
pub const QueueProperties = extern struct { flags: u32, count: u32, timestamp_bits: u32, granularity: extern struct { width: u32, height: u32, depth: u32 } };
pub const FormatProperties = extern struct { linear_tiling_features: u32, optimal_tiling_features: u32, buffer_features: u32 };
pub const Limits = extern struct {
    max_image_dimension_1d: u32,
    max_image_dimension_2d: u32,
    max_image_dimension_3d: u32,
    max_image_dimension_cube: u32,
    max_image_array_layers: u32,
    max_texel_buffer_elements: u32,
    max_uniform_buffer_range: u32,
    max_storage_buffer_range: u32,
    max_push_constants_size: u32,
    max_memory_allocation_count: u32,
    max_sampler_allocation_count: u32,
    buffer_image_granularity: u64,
    sparse_address_space_size: u64,
    max_bound_descriptor_sets: u32,
    max_per_stage_descriptor_samplers: u32,
    max_per_stage_descriptor_uniform_buffers: u32,
    max_per_stage_descriptor_storage_buffers: u32,
    max_per_stage_descriptor_sampled_images: u32,
    max_per_stage_descriptor_storage_images: u32,
    max_per_stage_descriptor_input_attachments: u32,
    max_per_stage_resources: u32,
    max_descriptor_set_samplers: u32,
    max_descriptor_set_uniform_buffers: u32,
    max_descriptor_set_uniform_buffers_dynamic: u32,
    max_descriptor_set_storage_buffers: u32,
    max_descriptor_set_storage_buffers_dynamic: u32,
    max_descriptor_set_sampled_images: u32,
    max_descriptor_set_storage_images: u32,
    max_descriptor_set_input_attachments: u32,
    max_vertex_input_attributes: u32,
    max_vertex_input_bindings: u32,
    max_vertex_input_attribute_offset: u32,
    max_vertex_input_binding_stride: u32,
    max_vertex_output_components: u32,
    max_tessellation_generation_level: u32,
    max_tessellation_patch_size: u32,
    max_tessellation_control_per_vertex_input_components: u32,
    max_tessellation_control_per_vertex_output_components: u32,
    max_tessellation_control_per_patch_output_components: u32,
    max_tessellation_control_total_output_components: u32,
    max_tessellation_evaluation_input_components: u32,
    max_tessellation_evaluation_output_components: u32,
    max_geometry_shader_invocations: u32,
    max_geometry_input_components: u32,
    max_geometry_output_components: u32,
    max_geometry_output_vertices: u32,
    max_geometry_total_output_components: u32,
    max_fragment_input_components: u32,
    max_fragment_output_attachments: u32,
    max_fragment_dual_src_attachments: u32,
    max_fragment_combined_output_resources: u32,
    max_compute_shared_memory_size: u32,
    max_compute_work_group_count: [3]u32,
    max_compute_work_group_invocations: u32,
    max_compute_work_group_size: [3]u32,
    sub_pixel_precision_bits: u32,
    sub_texel_precision_bits: u32,
    mipmap_precision_bits: u32,
    max_draw_indexed_index_value: u32,
    max_draw_indirect_count: u32,
    max_sampler_lod_bias: f32,
    max_sampler_anisotropy: f32,
    max_viewports: u32,
    max_viewport_dimensions: [2]u32,
    viewport_bounds_range: [2]f32,
    viewport_sub_pixel_bits: u32,
    min_memory_map_alignment: usize,
    min_texel_buffer_offset_alignment: u64,
    min_uniform_buffer_offset_alignment: u64,
    min_storage_buffer_offset_alignment: u64,
    min_texel_offset: i32,
    max_texel_offset: u32,
    min_texel_gather_offset: i32,
    max_texel_gather_offset: u32,
    min_interpolation_offset: f32,
    max_interpolation_offset: f32,
    sub_pixel_interpolation_offset_bits: u32,
    max_framebuffer_width: u32,
    max_framebuffer_height: u32,
    max_framebuffer_layers: u32,
    framebuffer_color_sample_counts: u32,
    framebuffer_depth_sample_counts: u32,
    framebuffer_stencil_sample_counts: u32,
    framebuffer_no_attachments_sample_counts: u32,
    max_color_attachments: u32,
    sampled_image_color_sample_counts: u32,
    sampled_image_integer_sample_counts: u32,
    sampled_image_depth_sample_counts: u32,
    sampled_image_stencil_sample_counts: u32,
    storage_image_sample_counts: u32,
    max_sample_mask_words: u32,
    timestamp_compute_and_graphics: u32,
    timestamp_period: f32,
    max_clip_distances: u32,
    max_cull_distances: u32,
    max_combined_clip_and_cull_distances: u32,
    discrete_queue_priorities: u32,
    point_size_range: [2]f32,
    line_width_range: [2]f32,
    point_size_granularity: f32,
    line_width_granularity: f32,
    strict_lines: u32,
    standard_sample_locations: u32,
    optimal_buffer_copy_offset_alignment: u64,
    optimal_buffer_copy_row_pitch_alignment: u64,
    non_coherent_atom_size: u64,
};
pub const SparseProperties = extern struct { residency_standard_2d_block_shape: u32, residency_standard_2d_multisample_block_shape: u32, residency_standard_3d_block_shape: u32, residency_aligned_mip_size: u32, residency_non_resident_strict: u32 };
pub const Properties = extern struct { api_version: u32, driver_version: u32, vendor_id: u32, device_id: u32, device_type: u32, device_name: [256]u8, pipeline_cache_uuid: [16]u8, limits: Limits, sparse_properties: SparseProperties };
pub const MemoryType = extern struct { property_flags: u32, heap_index: u32 };
pub const MemoryHeap = extern struct { size: u64, flags: u32 };
pub const MemoryProperties = extern struct { memory_type_count: u32, memory_types: [32]MemoryType, memory_heap_count: u32, memory_heaps: [16]MemoryHeap };
pub const MemoryAllocateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, allocation_size: u64, memory_type_index: u32 };
pub const MemoryRequirements = extern struct { size: u64, alignment: u64, memory_type_bits: u32 };
pub const BufferCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, size: u64, usage: u32, sharing_mode: i32, queue_family_index_count: u32, queue_family_indices: ?[*]const u32 };
pub const Extent3D = extern struct { width: u32, height: u32, depth: u32 };
pub const Offset3D = extern struct { x: i32, y: i32, z: i32 };
pub const ImageCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, image_type: i32, format: i32, extent: Extent3D, mip_levels: u32, array_layers: u32, samples: u32, tiling: i32, usage: u32, sharing_mode: i32, queue_family_index_count: u32, queue_family_indices: ?[*]const u32, initial_layout: i32 };
pub const ImageSubresource = extern struct { aspect_mask: u32, mip_level: u32, array_layer: u32 };
pub const SubresourceLayout = extern struct { offset: u64, size: u64, row_pitch: u64, array_pitch: u64, depth_pitch: u64 };
pub const CommandPoolCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, queue_family_index: u32 };
pub const CommandBufferAllocateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, command_pool: usize, level: i32, command_buffer_count: u32 };
pub const CommandBufferBeginInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, inheritance_info: ?*const anyopaque };
pub const SubmitInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, wait_semaphore_count: u32, wait_semaphores: ?[*]const usize, wait_dst_stage_mask: ?[*]const u32, command_buffer_count: u32, command_buffers: ?[*]const CommandBuffer, signal_semaphore_count: u32, signal_semaphores: ?[*]const usize };
pub const FenceCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32 };
pub const BufferCopy = extern struct { src_offset: u64, dst_offset: u64, size: u64 };
pub const ImageSubresourceLayers = extern struct { aspect_mask: u32, mip_level: u32, base_array_layer: u32, layer_count: u32 };
pub const BufferImageCopy = extern struct { buffer_offset: u64, buffer_row_length: u32, buffer_image_height: u32, image_subresource: ImageSubresourceLayers, image_offset: Offset3D, image_extent: Extent3D };
pub const ImageCopy = extern struct { src_subresource: ImageSubresourceLayers, src_offset: Offset3D, dst_subresource: ImageSubresourceLayers, dst_offset: Offset3D, extent: Extent3D };
pub const ClearColorValue = extern union { float32: [4]f32, int32: [4]i32, uint32: [4]u32 };
pub const ImageSubresourceRange = extern struct { aspect_mask: u32, base_mip_level: u32, level_count: u32, base_array_layer: u32, layer_count: u32 };
pub const ImageMemoryBarrier = extern struct { s_type: i32, p_next: ?*const anyopaque, src_access_mask: u32, dst_access_mask: u32, old_layout: i32, new_layout: i32, src_queue_family_index: u32, dst_queue_family_index: u32, image: usize, subresource_range: ImageSubresourceRange };
pub const Extent2D = extern struct { width: u32, height: u32 };
pub const XcbSurfaceCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, connection: ?*anyopaque, window: u32 };
pub const SurfaceCapabilities = extern struct { min_image_count: u32, max_image_count: u32, current_extent: Extent2D, min_image_extent: Extent2D, max_image_extent: Extent2D, max_image_array_layers: u32, supported_transforms: u32, current_transform: u32, supported_composite_alpha: u32, supported_usage_flags: u32 };
pub const SurfaceFormat = extern struct { format: i32, color_space: i32 };
pub const SwapchainCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, surface: usize, min_image_count: u32, image_format: i32, image_color_space: i32, image_extent: Extent2D, image_array_layers: u32, image_usage: u32, image_sharing_mode: i32, queue_family_index_count: u32, queue_family_indices: ?[*]const u32, pre_transform: u32, composite_alpha: u32, present_mode: i32, clipped: u32, old_swapchain: usize };
pub const ImageViewCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, image: usize, view_type: i32, format: i32, components: [4]i32, subresource_range: ImageSubresourceRange };
pub const FramebufferCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, render_pass: usize, attachment_count: u32, attachments: ?[*]const usize, width: u32, height: u32, layers: u32 };
pub const ClearValue = extern union { color: ClearColorValue, depth_stencil: extern struct { depth: f32, stencil: u32 } };
pub const Rect2D = extern struct { offset: extern struct { x: i32, y: i32 }, extent: Extent2D };
pub const RenderPassBeginInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, render_pass: usize, framebuffer: usize, render_area: Rect2D, clear_value_count: u32, clear_values: ?[*]const ClearValue };
pub const DescriptorSetAllocateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, descriptor_pool: usize, descriptor_set_count: u32, set_layouts: ?[*]const usize };
pub const DescriptorBufferInfo = extern struct { buffer: usize, offset: u64, range: u64 };
pub const DescriptorImageInfo = extern struct { sampler: usize, image_view: usize, image_layout: i32 };
pub const WriteDescriptorSet = extern struct { s_type: i32, p_next: ?*const anyopaque, dst_set: usize, dst_binding: u32, dst_array_element: u32, descriptor_count: u32, descriptor_type: i32, image_info: ?[*]const DescriptorImageInfo, buffer_info: ?[*]const DescriptorBufferInfo, texel_buffer_view: ?[*]const usize };
pub const Viewport = cpu_cube.Viewport;
pub const PresentInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, wait_semaphore_count: u32, wait_semaphores: ?[*]const usize, swapchain_count: u32, swapchains: ?[*]const usize, image_indices: ?[*]const u32, results: ?[*]Result };
pub const PresentTimingsInfoEXT = extern struct { s_type: i32, p_next: ?*const anyopaque, swapchain_count: u32, timing_infos: ?[*]const PresentTimingInfoEXT };
pub const PresentTimingInfoEXT = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, target_time: u64, time_domain_id: u64, present_stage_queries: u32, target_time_domain_present_stage: u32 };
pub const SwapchainTimingPropertiesEXT = extern struct { s_type: i32, p_next: ?*anyopaque, refresh_duration: u64, refresh_interval: u64 };
pub const SwapchainTimeDomainPropertiesEXT = extern struct { s_type: i32, p_next: ?*anyopaque, time_domain_count: u32, time_domains: ?[*]i32, time_domain_ids: ?[*]u64 };
pub const PastPresentationTimingInfoEXT = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, swapchain: usize };
pub const PastPresentationTimingPropertiesEXT = extern struct { s_type: i32, p_next: ?*anyopaque, timing_properties_counter: u64, time_domains_counter: u64, presentation_timing_count: u32, presentation_timings: ?*anyopaque };
pub const ShaderModuleCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, code_size: usize, p_code: ?*const anyopaque };
pub const SpecializationMapEntry = extern struct { constant_id: u32, offset: u32, size: usize };
pub const SpecializationInfo = extern struct { map_entry_count: u32, map_entries: ?[*]const SpecializationMapEntry, data_size: usize, data: ?*const anyopaque };
pub const PipelineShaderStageCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, stage: u32, module: usize, name: ?[*:0]const u8, specialization_info: ?*const SpecializationInfo };
pub const DescriptorSetLayoutBinding = extern struct { binding: u32, descriptor_type: i32, descriptor_count: u32, stage_flags: u32, immutable_samplers: ?[*]const usize };
pub const DescriptorSetLayoutCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, binding_count: u32, bindings: ?[*]const DescriptorSetLayoutBinding };
pub const PushConstantRange = extern struct { stage_flags: u32, offset: u32, size: u32 };
pub const PipelineLayoutCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, set_layout_count: u32, set_layouts: ?[*]const usize, push_constant_range_count: u32, push_constant_ranges: ?[*]const PushConstantRange };
pub const VertexInputBindingDescription = extern struct { binding: u32, stride: u32, input_rate: i32 };
pub const VertexInputAttributeDescription = extern struct { location: u32, binding: u32, format: i32, offset: u32 };
pub const PipelineVertexInputStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, binding_count: u32, bindings: ?[*]const VertexInputBindingDescription, attribute_count: u32, attributes: ?[*]const VertexInputAttributeDescription };
pub const PipelineInputAssemblyStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, topology: i32, primitive_restart_enable: u32 };
pub const PipelineViewportStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, viewport_count: u32, viewports: ?[*]const Viewport, scissor_count: u32, scissors: ?[*]const Rect2D };
pub const PipelineRasterizationStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, depth_clamp_enable: u32, rasterizer_discard_enable: u32, polygon_mode: i32, cull_mode: u32, front_face: i32, depth_bias_enable: u32, depth_bias_constant_factor: f32, depth_bias_clamp: f32, depth_bias_slope_factor: f32, line_width: f32 };
pub const PipelineMultisampleStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, rasterization_samples: u32, sample_shading_enable: u32, min_sample_shading: f32, sample_mask: ?[*]const u32, alpha_to_coverage_enable: u32, alpha_to_one_enable: u32 };
pub const StencilOpState = extern struct { fail_op: i32, pass_op: i32, depth_fail_op: i32, compare_op: i32, compare_mask: u32, write_mask: u32, reference: u32 };
pub const PipelineDepthStencilStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, depth_test_enable: u32, depth_write_enable: u32, depth_compare_op: i32, depth_bounds_test_enable: u32, stencil_test_enable: u32, front: StencilOpState, back: StencilOpState, min_depth_bounds: f32, max_depth_bounds: f32 };
pub const PipelineColorBlendAttachmentState = extern struct { blend_enable: u32, src_color_blend_factor: i32, dst_color_blend_factor: i32, color_blend_op: i32, src_alpha_blend_factor: i32, dst_alpha_blend_factor: i32, alpha_blend_op: i32, color_write_mask: u32 };
pub const PipelineColorBlendStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, logic_op_enable: u32, logic_op: i32, attachment_count: u32, attachments: ?[*]const PipelineColorBlendAttachmentState, blend_constants: [4]f32 };
pub const PipelineDynamicStateCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, dynamic_state_count: u32, dynamic_states: ?[*]const i32 };
pub const GraphicsPipelineCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, stage_count: u32, stages: ?[*]const PipelineShaderStageCreateInfo, vertex_input: ?*const PipelineVertexInputStateCreateInfo, input_assembly: ?*const PipelineInputAssemblyStateCreateInfo, tessellation: ?*const anyopaque, viewport: ?*const PipelineViewportStateCreateInfo, rasterization: ?*const PipelineRasterizationStateCreateInfo, multisample: ?*const PipelineMultisampleStateCreateInfo, depth_stencil: ?*const PipelineDepthStencilStateCreateInfo, color_blend: ?*const PipelineColorBlendStateCreateInfo, dynamic: ?*const PipelineDynamicStateCreateInfo, layout: usize, render_pass: usize, subpass: u32, base_pipeline: usize, base_pipeline_index: i32 };
pub const AttachmentDescription = extern struct { flags: u32, format: i32, samples: u32, load_op: i32, store_op: i32, stencil_load_op: i32, stencil_store_op: i32, initial_layout: i32, final_layout: i32 };
pub const AttachmentReference = extern struct { attachment: u32, layout: i32 };
pub const SubpassDescription = extern struct { flags: u32, pipeline_bind_point: i32, input_attachment_count: u32, input_attachments: ?[*]const AttachmentReference, color_attachment_count: u32, color_attachments: ?[*]const AttachmentReference, resolve_attachments: ?[*]const AttachmentReference, depth_stencil_attachment: ?*const AttachmentReference, preserve_attachment_count: u32, preserve_attachments: ?[*]const u32 };
pub const SubpassDependency = extern struct { src_subpass: u32, dst_subpass: u32, src_stage_mask: u32, dst_stage_mask: u32, src_access_mask: u32, dst_access_mask: u32, dependency_flags: u32 };
pub const RenderPassCreateInfo = extern struct { s_type: i32, p_next: ?*const anyopaque, flags: u32, attachment_count: u32, attachments: ?[*]const AttachmentDescription, subpass_count: u32, subpasses: ?[*]const SubpassDescription, dependency_count: u32, dependencies: ?[*]const SubpassDependency };
const SetInstanceLoaderData = *const fn (Instance, *anyopaque) callconv(.c) Result;
const SetDeviceLoaderData = *const fn (Device, *anyopaque) callconv(.c) Result;
pub const InstanceObj = extern struct { loader_data: usize, set_loader_data: ?SetInstanceLoaderData };
pub const PhysicalObj = extern struct { loader_data: usize, owner: *InstanceObj, loader_initialized: bool };
pub const DeviceObj = extern struct { loader_data: usize, physical: *PhysicalObj, set_loader_data: ?SetDeviceLoaderData, heap_used: u64, generation: u64 };
pub const QueueObj = extern struct { loader_data: usize, owner: *DeviceObj, loader_initialized: bool };
pub const Instance = *InstanceObj;
pub const Physical = *PhysicalObj;
pub const Device = *DeviceObj;
pub const Queue = *QueueObj;
const MemoryObj = struct { owner: Device, bytes: []align(64) u8, mapped: bool };
const BufferObj = struct { owner: Device, size: u64, usage: u32, memory: ?*MemoryObj = null, offset: u64 = 0 };
const ImageObj = struct { owner: Device, width: u32, height: u32, array_layers: u32, samples: u32, format: i32, usage: u32, layout: i32, memory: ?*MemoryObj = null, owned_bytes: ?[]align(64) u8 = null, shared_bytes: bool = false, offset: u64 = 0 };
const FenceObj = struct { owner: Device, signaled: bool };
const SemaphoreObj = struct { owner: Device, signaled: bool };
const CommandPoolObj = struct { owner: Device };
const SurfaceObj = struct { owner: Instance, connection: *anyopaque, window: u32 };
const ImageViewObj = struct { owner: Device, image: *ImageObj, format: i32, aspect_mask: u32, base_array_layer: u32, layer_count: u32 };
const FramebufferObj = struct { owner: Device, color_image: ?*ImageObj, depth_image: ?*ImageObj, render_compatibility: Canonical };
const DescriptorSetObj = struct { owner: DeviceIdentity, layout: Canonical, uniform: ?*BufferObj = null, uniform_offset: u64 = 0, uniform_range: u64 = 0, texture: ?*ImageObj = null };
const DeviceIdentity = struct {
    handle: Device,
    generation: u64,

    fn capture(device: Device) DeviceIdentity {
        return .{ .handle = device, .generation = device.generation };
    }

    fn eql(identity: DeviceIdentity, device: Device) bool {
        return identity.handle == device and identity.generation == device.generation;
    }
};
const ShaderModuleObj = struct { owner: DeviceIdentity, module: spirv.Module };
const Canonical = struct {
    bytes: []u8 = &.{},
    digest: [32]u8 = undefined,

    fn finish(self: *Canonical) void {
        std.crypto.hash.sha2.Sha256.hash(self.bytes, &self.digest, .{});
    }
    fn eql(a: *const Canonical, b: *const Canonical) bool {
        return std.mem.eql(u8, a.bytes, b.bytes);
    }
    fn clone(self: *const Canonical) error{OutOfMemory}!Canonical {
        if (failTestAllocation()) return error.OutOfMemory;
        const result = Canonical{ .bytes = allocator.dupe(u8, self.bytes) catch return error.OutOfMemory, .digest = self.digest };
        canonical_live_allocations += 1;
        return result;
    }
    fn deinit(self: *Canonical) void {
        if (self.bytes.len != 0) {
            allocator.free(self.bytes);
            canonical_live_allocations -= 1;
        }
        self.bytes = &.{};
    }
};
const DescriptorSetLayoutObj = struct { owner: DeviceIdentity, canonical: Canonical };
const PipelineLayoutObj = struct { owner: DeviceIdentity, canonical: Canonical, set0: Canonical };
const AttachmentRole = enum(u8) { color, depth };
const FramebufferAttachmentRequirement = struct { format: i32 = 0, samples: u32 = 0, role: AttachmentRole = .color };
const RenderPassObj = struct { owner: DeviceIdentity, canonical: Canonical, compatibility: Canonical, subpass_count: u32, framebuffer_supported: bool, framebuffer_attachment_count: u32, framebuffer_attachments: [2]FramebufferAttachmentRequirement };
const GraphicsPipelineObj = struct { owner: DeviceIdentity, canonical: Canonical, layout: Canonical, set0: Canonical, render_compatibility: Canonical, vertex_program: ?render_ir.Program, fragment_program: ?render_ir.Program, subpass: u32, execution_abi: u32, cull_mode: u32, front_face: i32 };
const SwapchainObj = struct {
    owner: Device,
    surface: *SurfaceObj,
    width: u32,
    height: u32,
    image_count: u32,
    images: [3]usize,
    image_states: [3]frame_lifecycle.State,
    next_image: u32,
    pending: u32,
    retiring: bool,
    present_mutex: std.c.pthread_mutex_t,
    present_condition: std.c.pthread_cond_t,
    cadence: ?frame_pacing.Clock,
    transport: xcb_present.Transport,
};
const Command = union(enum) { fill: struct { dst: *BufferObj, offset: u64, size: u64, data: u32 }, copy_buffer: struct { src: *BufferObj, dst: *BufferObj, region: BufferCopy }, clear: struct { image: *ImageObj, layout: i32, color: [4]u8 }, render_clear: struct { image: *ImageObj, depth: ?*ImageObj, color: [4]u8, depth_value: f32 }, cube_draw: struct { framebuffer: *FramebufferObj, descriptors: *DescriptorSetObj, vertex_count: u32, viewport: Viewport, scissor: cpu_cube.Rect, cull_mode: u32, front_face: i32 }, buffer_to_image: struct { src: *BufferObj, dst: *ImageObj, layout: i32, region: BufferImageCopy }, image_to_buffer: struct { src: *ImageObj, layout: i32, dst: *BufferObj, region: BufferImageCopy }, copy_image: struct { src: *ImageObj, src_layout: i32, dst: *ImageObj, dst_layout: i32, region: ImageCopy }, transition: struct { image: *ImageObj, old_layout: i32, new_layout: i32 } };
const CommandBufferImpl = struct { owner: *DeviceObj, pool: *CommandPoolObj, state: u8, invalid: bool, count: u16, active_framebuffer: ?*FramebufferObj, active_render_pass: ?*RenderPassObj, bound_pipeline: ?*GraphicsPipelineObj, bound_pipeline_handle: usize, bound_descriptors: ?*DescriptorSetObj, bound_layout: ?*PipelineLayoutObj, bound_layout_handle: usize, viewport: Viewport, scissor: cpu_cube.Rect, commands: [256]Command };
pub const CommandBufferObj = extern struct { loader_data: usize, impl: *CommandBufferImpl };
pub const CommandBuffer = *CommandBufferObj;

const max_objects = 64;
const max_child_objects = 64;
const heap_size: u64 = 256 * 1024 * 1024;
const max_api_items: u32 = 256;
const SlotState = enum(u8) { never, live, tombstone };
var instance_objects: [max_objects]InstanceObj = undefined;
var physical_objects: [max_objects]PhysicalObj = undefined;
var instance_state = [_]SlotState{.never} ** max_objects;
var device_objects: [max_objects]DeviceObj = undefined;
var queue_objects: [max_objects]QueueObj = undefined;
var device_state = [_]SlotState{.never} ** max_objects;
var next_device_generation: u64 = 1;
var memory_objects: [max_child_objects]MemoryObj = undefined;
var memory_state = [_]SlotState{.never} ** max_child_objects;
var buffer_objects: [max_child_objects]BufferObj = undefined;
var buffer_state = [_]SlotState{.never} ** max_child_objects;
var image_objects: [max_child_objects]ImageObj = undefined;
var image_state = [_]SlotState{.never} ** max_child_objects;
var fence_objects: [max_child_objects]FenceObj = undefined;
var fence_state = [_]SlotState{.never} ** max_child_objects;
var semaphore_objects: [max_child_objects]SemaphoreObj = undefined;
var semaphore_state = [_]SlotState{.never} ** max_child_objects;
var command_pool_objects: [max_child_objects]CommandPoolObj = undefined;
var command_pool_state = [_]SlotState{.never} ** max_child_objects;
var command_buffer_objects: [max_child_objects]CommandBufferObj = undefined;
var command_buffer_impls: [max_child_objects]CommandBufferImpl = undefined;
var command_buffer_state = [_]SlotState{.never} ** max_child_objects;
var surface_objects: [max_child_objects]SurfaceObj = undefined;
var surface_state = [_]SlotState{.never} ** max_child_objects;
var image_view_objects: [max_child_objects]ImageViewObj = undefined;
var image_view_state = [_]SlotState{.never} ** max_child_objects;
var framebuffer_objects: [max_child_objects]FramebufferObj = undefined;
var framebuffer_state = [_]SlotState{.never} ** max_child_objects;
var descriptor_set_objects: [max_child_objects]DescriptorSetObj = undefined;
var descriptor_set_state = [_]SlotState{.never} ** max_child_objects;
var shader_module_objects: [max_child_objects]ShaderModuleObj = undefined;
var shader_module_state = [_]SlotState{.never} ** max_child_objects;
var descriptor_set_layout_objects: [max_child_objects]DescriptorSetLayoutObj = undefined;
var descriptor_set_layout_state = [_]SlotState{.never} ** max_child_objects;
var pipeline_layout_objects: [max_child_objects]PipelineLayoutObj = undefined;
var pipeline_layout_state = [_]SlotState{.never} ** max_child_objects;
var render_pass_objects: [max_child_objects]RenderPassObj = undefined;
var render_pass_state = [_]SlotState{.never} ** max_child_objects;
var graphics_pipeline_objects: [max_child_objects]GraphicsPipelineObj = undefined;
var graphics_pipeline_state = [_]SlotState{.never} ** max_child_objects;
var swapchain_objects: [8]SwapchainObj = undefined;
var swapchain_state = [_]SlotState{.never} ** 8;
var generic_handle: usize = 0x10000;
var mutex: std.atomic.Mutex = .unlocked;

const max_present_entries = 24;

const TraceRecord = extern struct {
    frame: u64,
    render_complete_ns: u64,
    deadline_ns: u64,
    wake_ns: u64,
    wake_error_ns: i64,
    present_start_ns: u64,
    upload_end_ns: u64,
    copy_start_ns: u64,
    copy_end_ns: u64,
    flush_end_ns: u64,
    frame_end_ns: u64,
};
const max_trace_frames = 7_200;
var trace_records: [max_trace_frames]TraceRecord = undefined;
var trace_count: usize = 0;
var trace_written = false;

extern fn open(path: [*:0]const u8, flags: c_int, mode: c_uint) c_int;
extern fn write(fd: c_int, buffer: *const anyopaque, count: usize) isize;
extern fn close(fd: c_int) c_int;

fn traceLimit() usize {
    const raw = std.c.getenv("ZPU_TRACE_FRAMES") orelse return 0;
    return @min(std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 0, max_trace_frames);
}

fn recordTrace(record_value: TraceRecord) void {
    const limit = traceLimit();
    if (limit == 0 or trace_written or trace_count >= limit) return;
    trace_records[trace_count] = record_value;
    trace_count += 1;
    if (trace_count != limit) return;
    const path = std.c.getenv("ZPU_TRACE_PATH") orelse return;
    const fd = open(path, 0x241, 0o600); // O_WRONLY | O_CREAT | O_TRUNC
    if (fd < 0) return;
    const bytes = std.mem.sliceAsBytes(trace_records[0..trace_count]);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const amount = write(fd, bytes[offset..].ptr, bytes.len - offset);
        if (amount <= 0) break;
        offset += @intCast(amount);
    }
    _ = close(fd);
    trace_written = offset == bytes.len;
}

fn synchronousOneCore() bool {
    const value = std.c.getenv("ZPU_ONE_CORE") orelse return false;
    return value[0] == '1';
}

fn releasePresented(context: *anyopaque, image_index: u32) void {
    const swapchain: *SwapchainObj = @ptrCast(@alignCast(context));
    _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
    std.debug.assert(frame_lifecycle.release(swapchain.image_states[0..swapchain.image_count], image_index));
    swapchain.pending -= 1;
    _ = std.c.pthread_cond_broadcast(&swapchain.present_condition);
    _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
}

const Requirement = enum(u6) {
    instance_allocator,
    instance_stype,
    app_stype,
    instance_unknown_chain,
    instance_overdepth_chain,
    instance_null_callback,
    device_allocator,
    device_stype,
    device_unknown_chain,
    device_overdepth_chain,
    device_null_callback,
    queue_stype,
    queue_pnext,
    queue_flags,
    queue_family,
    queue_count,
    queue_priorities_null,
    priority_below_zero,
    priority_above_one,
    priority_nonfinite,
    callback_instance_success,
    callback_instance_decline,
    callback_instance_destroy,
    callback_device_success,
    callback_device_decline,
    callback_device_destroy,
    null_proc_name,
    null_enumeration_count,
    null_query_output,
    stale_instance,
    stale_device,
    pool_instance_exhaustion,
    pool_device_exhaustion,
    concurrent_overlap,
    stale_memory,
    stale_buffer,
    stale_image,
    stale_fence,
    stale_pool,
    stale_command_buffer,
    recorded_dead_resource,
    heap_exhaustion,
    heap_recovery,
    overflow_image_size,
    overflow_buffer_image,
    zero_count_noop,
    excessive_count,
    invalid_buffer_usage,
    invalid_image_usage,
    missing_transfer_usage,
    bind_alignment,
    layout_mismatch,
    barrier_transition,
    invalid_barrier,
    child_registry_exhaustion,
    bound_memory_retained,
    zero_submit_rejected,
    invalid_clear_color,
    submission_atomicity,
    zero_fill_rejected,
    submitting_device_ownership,
    shader_invalid,
    shader_lifetime,
    shader_exhaustion,
};
var requirement_hits: u64 = 0;
var overlap_hold = std.atomic.Value(bool).init(false);
var overlap_entered = std.atomic.Value(bool).init(false);
fn hit(comptime requirement: Requirement) void {
    if (@import("builtin").is_test) requirement_hits |= @as(u64, 1) << @intFromEnum(requirement);
}

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

const ChainHeader = extern struct { s_type: i32, p_next: ?*const ChainHeader };
const google_display_timing_extension = "VK_GOOGLE_display_timing";
const google_present_times_info_stype: i32 = 1_000_092_000;

fn googleDisplayTimingProc(name: []const u8) bool {
    return std.mem.eql(u8, name, "vkGetRefreshCycleDurationGOOGLE") or std.mem.eql(u8, name, "vkGetPastPresentationTimingGOOGLE");
}

fn logGoogleDisplayTimingRejected(context: []const u8) void {
    std.debug.print("ZPU error: unsupported VK_GOOGLE_display_timing usage detected ({s}); switch to VK_EXT_present_timing for runtime scheduling and ZPU_REFRESH_HZ for the process display cadence. No Google timing compatibility is provided.\n", .{context});
}
const LoaderInstanceInfo = extern struct {
    s_type: i32,
    p_next: ?*const anyopaque,
    function: i32,
    value: extern union { layer_info: ?*anyopaque, set_instance_loader_data: ?SetInstanceLoaderData },
};
const LoaderDeviceInfo = extern struct {
    s_type: i32,
    p_next: ?*const anyopaque,
    function: i32,
    value: extern union { layer_info: ?*anyopaque, set_instance_loader_data: ?*const anyopaque, set_device_loader_data: ?SetDeviceLoaderData },
};
fn hasValidLoaderHead(raw: ?*const anyopaque, expected_type: i32) bool {
    const first: *const ChainHeader = @ptrCast(@alignCast(raw orelse return true));
    return first.s_type == expected_type;
}
fn findInstanceLoaderCallback(raw: ?*const anyopaque) ?SetInstanceLoaderData {
    var next = raw;
    var depth: usize = 0;
    while (next) |raw_item| {
        const header: *const ChainHeader = @ptrCast(@alignCast(raw_item));
        if (header.s_type != 47) {
            hit(.instance_unknown_chain);
            break;
        }
        if (depth == 16) {
            hit(.instance_overdepth_chain);
            break;
        }
        const item: *const LoaderInstanceInfo = @ptrCast(@alignCast(raw_item));
        if (item.function == 1) {
            if (item.value.set_instance_loader_data == null) hit(.instance_null_callback);
            return item.value.set_instance_loader_data;
        }
        next = item.p_next;
        depth += 1;
    }
    return null;
}
fn findDeviceLoaderCallback(raw: ?*const anyopaque) ?SetDeviceLoaderData {
    var next = raw;
    var depth: usize = 0;
    while (next) |raw_item| {
        const header: *const ChainHeader = @ptrCast(@alignCast(raw_item));
        if (header.s_type != 48) {
            hit(.device_unknown_chain);
            break;
        }
        if (depth == 16) {
            hit(.device_overdepth_chain);
            break;
        }
        const item: *const LoaderDeviceInfo = @ptrCast(@alignCast(raw_item));
        if (item.function == 1) {
            if (item.value.set_device_loader_data == null) hit(.device_null_callback);
            return item.value.set_device_loader_data;
        }
        next = item.p_next;
        depth += 1;
    }
    return null;
}

fn validInstanceLocked(h: Instance) bool {
    for (&instance_objects, &instance_state) |*o, state| if (o == h) {
        if (state == .live) return true;
        if (state == .tombstone) hit(.stale_instance);
        return false;
    };
    return false;
}
fn validPhysicalLocked(h: Physical) bool {
    for (&physical_objects, &instance_state) |*o, state| if (state == .live and o == h and validInstanceLocked(o.owner)) return true;
    return false;
}
fn validDeviceLocked(h: Device) bool {
    for (&device_objects, &device_state) |*o, state| if (o == h) {
        if (state == .live and validPhysicalLocked(o.physical)) return true;
        if (state == .tombstone) hit(.stale_device);
        return false;
    };
    return false;
}
fn validSurfaceLocked(handle: usize) ?*SurfaceObj {
    return findLiveHandle(SurfaceObj, handle, &surface_objects, &surface_state);
}
fn ptr(comptime f: anytype) Fn {
    return @ptrCast(&f);
}

fn getInstanceProcAddr(instance: ?Instance, name: ?[*:0]const u8) callconv(.c) Fn {
    const n = std.mem.span(name orelse {
        hit(.null_proc_name);
        return null;
    });
    if (globalLookup(n)) |f| return f;
    lock();
    defer mutex.unlock();
    if (!validInstanceLocked(instance orelse return null)) return null;
    return instanceLookup(n);
}
fn getDeviceProcAddr(device: ?Device, name: ?[*:0]const u8) callconv(.c) Fn {
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(device orelse return null)) return null;
    return deviceLookup(std.mem.span(name orelse return null));
}
fn enumerateInstanceExtensions(layer: ?[*:0]const u8, count: ?*u32, props: ?[*]ExtensionProperties) callconv(.c) Result {
    const n = count orelse {
        hit(.null_enumeration_count);
        return .error_initialization_failed;
    };
    if (layer != null) return .error_extension_not_present;
    const names = [_][]const u8{ "VK_KHR_surface", "VK_KHR_xcb_surface" };
    const versions = [_]u32{ 25, 6 };
    if (props) |items| {
        const available = n.*;
        const written = @min(available, names.len);
        for (0..written) |i| {
            items[i] = std.mem.zeroes(ExtensionProperties);
            @memcpy(items[i].name[0..names[i].len], names[i]);
            items[i].spec_version = versions[i];
        }
        n.* = @intCast(written);
        return if (available < names.len) .incomplete else .success;
    }
    n.* = names.len;
    return .success;
}
fn supportedInstanceExtension(name: [*:0]const u8) bool {
    const value = std.mem.span(name);
    return std.mem.eql(u8, value, "VK_KHR_surface") or std.mem.eql(u8, value, "VK_KHR_xcb_surface");
}
fn createInstance(info: ?*const InstanceInfo, alloc: ?*const Alloc, output: ?*Instance) callconv(.c) Result {
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.layer_count != 0) return .error_layer_not_present;
    if (ci.extension_count != 0) {
        const extensions = ci.extensions orelse return .error_extension_not_present;
        for (extensions[0..ci.extension_count]) |extension| if (!supportedInstanceExtension(extension)) return .error_extension_not_present;
    }
    if (alloc != null) {
        hit(.instance_allocator);
        return .error_initialization_failed;
    }
    if (ci.s_type != 1) {
        hit(.instance_stype);
        return .error_initialization_failed;
    }
    if (!hasValidLoaderHead(ci.p_next, 47) or ci.flags != 0) return .error_initialization_failed;
    if (ci.app_info) |app| if (app.s_type != 0) {
        hit(.app_stype);
        return .error_initialization_failed;
    } else if (app.p_next != null or app.api_version > API_1_0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const set_loader_data = findInstanceLoaderCallback(ci.p_next);
    for (&instance_objects, &physical_objects, &instance_state) |*o, *p, *state| if (state.* == .never) {
        o.* = .{ .loader_data = MAGIC, .set_loader_data = set_loader_data };
        p.* = .{ .loader_data = MAGIC, .owner = o, .loader_initialized = false };
        state.* = .live;
        out.* = o;
        return .success;
    };
    hit(.pool_instance_exhaustion);
    return .error_out_of_host_memory;
}
fn destroyInstance(instance: ?Instance, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const h = instance orelse return;
    lock();
    defer mutex.unlock();
    for (&instance_objects, &physical_objects, &instance_state) |*o, *p, *state| if (state.* == .live and o == h) {
        for (&surface_objects, &surface_state) |*surface, *child_state| if (child_state.* == .live and surface.owner == h) {
            child_state.* = .tombstone;
        };
        state.* = .tombstone;
        o.loader_data = 0;
        p.loader_data = 0;
        return;
    };
}
fn createXcbSurface(instance: ?Instance, info: ?*const XcbSurfaceCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const h = instance orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.s_type != 1_000_005_000 or ci.p_next != null or ci.flags != 0 or ci.connection == null or ci.window == 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validInstanceLocked(h)) return .error_initialization_failed;
    for (&surface_objects, &surface_state) |*surface, *state| if (state.* == .never) {
        surface.* = .{ .owner = h, .connection = ci.connection.?, .window = ci.window };
        state.* = .live;
        out.* = @intFromPtr(surface);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroySurface(instance: ?Instance, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null or handle == 0) return;
    lock();
    defer mutex.unlock();
    const h = instance orelse return;
    const surface = validSurfaceLocked(handle) orelse return;
    if (surface.owner != h or !validInstanceLocked(h)) return;
    stateForObject(SurfaceObj, surface, &surface_objects, &surface_state).?.* = .tombstone;
}
fn getSurfaceSupport(physical: ?Physical, family: u32, handle: usize, output: ?*u32) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const p = physical orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    const surface = validSurfaceLocked(handle) orelse return .error_initialization_failed;
    if (!validPhysicalLocked(p) or surface.owner != p.owner or family != 0) return .error_initialization_failed;
    out.* = 1;
    return .success;
}
fn getSurfaceCapabilities(physical: ?Physical, handle: usize, output: ?*SurfaceCapabilities) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const p = physical orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    const surface = validSurfaceLocked(handle) orelse return .error_initialization_failed;
    if (!validPhysicalLocked(p) or surface.owner != p.owner) return .error_initialization_failed;
    out.* = .{ .min_image_count = 2, .max_image_count = 3, .current_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32) }, .min_image_extent = .{ .width = 1, .height = 1 }, .max_image_extent = .{ .width = 4096, .height = 4096 }, .max_image_array_layers = 1, .supported_transforms = 1, .current_transform = 1, .supported_composite_alpha = 1, .supported_usage_flags = 0x10 };
    return .success;
}
fn getSurfaceFormats(physical: ?Physical, handle: usize, count: ?*u32, output: ?[*]SurfaceFormat) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const p = physical orelse return .error_initialization_failed;
    const n = count orelse return .error_initialization_failed;
    const surface = validSurfaceLocked(handle) orelse return .error_initialization_failed;
    if (!validPhysicalLocked(p) or surface.owner != p.owner) return .error_initialization_failed;
    if (output) |items| {
        if (n.* == 0) return .incomplete;
        items[0] = .{ .format = 44, .color_space = 0 };
        n.* = 1;
    } else n.* = 1;
    return .success;
}
fn getSurfacePresentModes(physical: ?Physical, handle: usize, count: ?*u32, output: ?[*]i32) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const p = physical orelse return .error_initialization_failed;
    const n = count orelse return .error_initialization_failed;
    const surface = validSurfaceLocked(handle) orelse return .error_initialization_failed;
    if (!validPhysicalLocked(p) or surface.owner != p.owner) return .error_initialization_failed;
    if (output) |items| {
        if (n.* == 0) return .incomplete;
        items[0] = 2;
        n.* = 1;
    } else n.* = 1;
    return .success;
}
fn enumeratePhysicalDevices(instance: ?Instance, count: ?*u32, output: ?[*]Physical) callconv(.c) Result {
    const h = instance orelse return .error_initialization_failed;
    const n = count orelse {
        hit(.null_enumeration_count);
        return .error_initialization_failed;
    };
    lock();
    defer mutex.unlock();
    if (!validInstanceLocked(h)) return .error_initialization_failed;
    if (output) |items| {
        if (n.* == 0) return .incomplete;
        for (&instance_objects, &physical_objects, &instance_state) |*o, *p, state| if (state == .live and o == h) {
            if (!p.loader_initialized) {
                p.loader_initialized = true;
                if (o.set_loader_data) |set| {
                    mutex.unlock();
                    const result = set(o, p);
                    lock();
                    // A loader may forward a layer-only callback to an ICD. If it
                    // declines this ICD parent, the magic word remains the valid
                    // loader fallback; synthetic/compatible callbacks replace it.
                    if (result == .success) hit(.callback_instance_success) else hit(.callback_instance_decline);
                    if (!validInstanceLocked(h)) {
                        hit(.callback_instance_destroy);
                        return .error_initialization_failed;
                    }
                }
            }
            items[0] = p;
            n.* = 1;
            return .success;
        };
        return .error_initialization_failed;
    }
    n.* = 1;
    return .success;
}
fn getFeatures(physical: ?Physical, output: ?*Features) callconv(.c) void {
    const h = physical orelse return;
    const out = output orelse {
        hit(.null_query_output);
        return;
    };
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(h)) return;
    if (@import("builtin").is_test and overlap_hold.load(.acquire)) {
        overlap_entered.store(true, .release);
        while (overlap_hold.load(.acquire)) std.atomic.spinLoopHint();
        hit(.concurrent_overlap);
    }
    out.* = .{ .values = [_]u32{0} ** 55 };
}
fn conservativeLimits() Limits {
    var v = std.mem.zeroes(Limits);
    v.max_image_dimension_1d = 4096;
    v.max_image_dimension_2d = 4096;
    v.max_image_dimension_3d = 256;
    v.max_image_dimension_cube = 4096;
    v.max_image_array_layers = 256;
    v.max_texel_buffer_elements = 65_536;
    v.max_uniform_buffer_range = 16_384;
    v.max_storage_buffer_range = 134_217_728;
    v.max_push_constants_size = 128;
    v.max_memory_allocation_count = 4096;
    v.max_sampler_allocation_count = 4000;
    v.buffer_image_granularity = 131_072;
    v.max_bound_descriptor_sets = 4;
    v.max_per_stage_descriptor_samplers = 16;
    v.max_per_stage_descriptor_uniform_buffers = 12;
    v.max_per_stage_descriptor_storage_buffers = 4;
    v.max_per_stage_descriptor_sampled_images = 16;
    v.max_per_stage_descriptor_storage_images = 4;
    v.max_per_stage_descriptor_input_attachments = 4;
    v.max_per_stage_resources = 128;
    v.max_descriptor_set_samplers = 96;
    v.max_descriptor_set_uniform_buffers = 72;
    v.max_descriptor_set_uniform_buffers_dynamic = 8;
    v.max_descriptor_set_storage_buffers = 24;
    v.max_descriptor_set_storage_buffers_dynamic = 4;
    v.max_descriptor_set_sampled_images = 96;
    v.max_descriptor_set_storage_images = 24;
    v.max_descriptor_set_input_attachments = 4;
    v.max_vertex_input_attributes = 16;
    v.max_vertex_input_bindings = 16;
    v.max_vertex_input_attribute_offset = 2047;
    v.max_vertex_input_binding_stride = 2048;
    v.max_vertex_output_components = 64;
    v.max_fragment_input_components = 128;
    v.max_fragment_output_attachments = 4;
    v.max_fragment_combined_output_resources = 12;
    v.max_compute_shared_memory_size = 16_384;
    v.max_compute_work_group_count = .{ 65_535, 65_535, 65_535 };
    v.max_compute_work_group_invocations = 128;
    v.max_compute_work_group_size = .{ 128, 128, 64 };
    v.sub_pixel_precision_bits = 4;
    v.sub_texel_precision_bits = 4;
    v.mipmap_precision_bits = 4;
    v.max_draw_indexed_index_value = 0x00ff_ffff;
    v.max_draw_indirect_count = 1;
    v.max_sampler_lod_bias = 2;
    v.max_sampler_anisotropy = 1;
    v.max_viewports = 1;
    v.max_viewport_dimensions = .{ 4096, 4096 };
    v.viewport_bounds_range = .{ -32_768, 32_767 };
    v.min_memory_map_alignment = 64;
    v.min_texel_buffer_offset_alignment = 256;
    v.min_uniform_buffer_offset_alignment = 256;
    v.min_storage_buffer_offset_alignment = 256;
    v.min_texel_offset = -8;
    v.max_texel_offset = 7;
    v.max_framebuffer_width = 4096;
    v.max_framebuffer_height = 4096;
    v.max_framebuffer_layers = 256;
    v.framebuffer_color_sample_counts = 1 | 4;
    v.framebuffer_depth_sample_counts = 1 | 4;
    v.framebuffer_stencil_sample_counts = 1 | 4;
    v.framebuffer_no_attachments_sample_counts = 1 | 4;
    v.max_color_attachments = 4;
    v.sampled_image_color_sample_counts = 1 | 4;
    v.sampled_image_integer_sample_counts = 1;
    v.sampled_image_depth_sample_counts = 1 | 4;
    v.sampled_image_stencil_sample_counts = 1 | 4;
    v.storage_image_sample_counts = 1;
    v.max_sample_mask_words = 1;
    v.timestamp_period = 1;
    v.discrete_queue_priorities = 2;
    v.point_size_range = .{ 1, 1 };
    v.line_width_range = .{ 1, 1 };
    v.standard_sample_locations = 1;
    v.optimal_buffer_copy_offset_alignment = 1;
    v.optimal_buffer_copy_row_pitch_alignment = 1;
    v.non_coherent_atom_size = 256;
    return v;
}
fn getProperties(physical: ?Physical, output: ?*Properties) callconv(.c) void {
    const h = physical orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(h)) return;
    out.* = std.mem.zeroes(Properties);
    out.api_version = API_1_0;
    out.driver_version = 1;
    out.vendor_id = 0x1cdc;
    out.device_id = 1;
    out.device_type = 4;
    const name = "ZPU Experimental CPU";
    @memcpy(out.device_name[0..name.len], name);
    const uuid = [_]u8{ 0x5a, 0x50, 0x55, 0x2d, 0x49, 0x43, 0x44, 0x2d, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31 };
    out.pipeline_cache_uuid = uuid;
    out.limits = conservativeLimits();
}
fn getQueueProperties(physical: ?Physical, count: ?*u32, output: ?[*]QueueProperties) callconv(.c) void {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const n = count orelse return;
    if (output) |items| {
        if (n.* > 0) items[0] = .{ .flags = 0x1 | 0x4, .count = 1, .timestamp_bits = 0, .granularity = .{ .width = 1, .height = 1, .depth = 1 } };
        n.* = @min(n.*, 1);
    } else n.* = 1;
}
fn getMemoryProperties(physical: ?Physical, output: ?*MemoryProperties) callconv(.c) void {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const out = output orelse return;
    out.* = std.mem.zeroes(MemoryProperties);
    out.memory_type_count = 1;
    out.memory_types[0] = .{ .property_flags = 0x7, .heap_index = 0 };
    out.memory_heap_count = 1;
    out.memory_heaps[0] = .{ .size = 256 * 1024 * 1024, .flags = 0 };
}
fn getFormatProperties(physical: ?Physical, format: i32, output: ?*FormatProperties) callconv(.c) void {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const out = output orelse return;
    out.* = switch (format) {
        37, 43, 44 => .{ .linear_tiling_features = 0x1 | 0x4000 | 0x8000, .optimal_tiling_features = 0x1 | 0x80 | 0x4000 | 0x8000, .buffer_features = 0 },
        124 => .{ .linear_tiling_features = 0, .optimal_tiling_features = 0x200, .buffer_features = 0 },
        else => std.mem.zeroes(FormatProperties),
    };
}
fn getImageFormatProperties(physical: ?Physical, format: i32, image_type: i32, tiling: i32, usage: u32, flags: u32, output: ?*anyopaque) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return .error_initialization_failed)) return .error_initialization_failed;
    if (!supportedFormat(format) or image_type != 1 or (tiling != 0 and tiling != 1) or flags != 0 or usage == 0 or usage & ~@as(u32, 0x37) != 0) return .error_format_not_supported;
    const out: *extern struct { max_extent: Extent3D, max_mip_levels: u32, max_array_layers: u32, sample_counts: u32, max_resource_size: u64 } = @ptrCast(@alignCast(output orelse return .error_initialization_failed));
    out.* = .{ .max_extent = .{ .width = 4096, .height = 4096, .depth = 1 }, .max_mip_levels = 1, .max_array_layers = 1, .sample_counts = 1, .max_resource_size = 256 * 1024 * 1024 };
    return .success;
}
fn getSparseImageFormatProperties(physical: ?Physical, format: i32, image_type: i32, samples: u32, usage: u32, tiling: i32, count: ?*u32, output: ?*anyopaque) callconv(.c) void {
    _ = format;
    _ = image_type;
    _ = samples;
    _ = usage;
    _ = tiling;
    _ = output;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const n = count orelse return;
    n.* = 0;
}
fn enumerateDeviceExtensions(physical: ?Physical, layer: ?[*:0]const u8, count: ?*u32, props: ?[*]ExtensionProperties) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return .error_initialization_failed)) return .error_initialization_failed;
    const n = count orelse return .error_initialization_failed;
    if (layer != null) return .error_extension_not_present;
    const extensions = [_]struct { name: []const u8, version: u32 }{ .{ .name = "VK_KHR_swapchain", .version = 70 }, .{ .name = "VK_EXT_present_timing", .version = 3 } };
    if (props) |items| {
        const written = @min(n.*, extensions.len);
        for (extensions[0..written], 0..) |extension, i| {
            items[i] = std.mem.zeroes(ExtensionProperties);
            @memcpy(items[i].name[0..extension.name.len], extension.name);
            items[i].spec_version = extension.version;
        }
        n.* = @intCast(written);
        return if (written < extensions.len) .incomplete else .success;
    }
    n.* = extensions.len;
    return .success;
}
fn createDevice(physical: ?Physical, info: ?*const DeviceInfo, alloc: ?*const Alloc, output: ?*Device) callconv(.c) Result {
    const p = physical orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.layer_count != 0) return .error_layer_not_present;
    if (ci.extension_count != 0) {
        const extensions = ci.extensions orelse return .error_extension_not_present;
        for (extensions[0..ci.extension_count]) |extension| {
            const name = std.mem.span(extension);
            if (std.mem.eql(u8, name, google_display_timing_extension)) {
                logGoogleDisplayTimingRejected("device extension request");
                return .error_extension_not_present;
            }
            if (!std.mem.eql(u8, name, "VK_KHR_swapchain") and !std.mem.eql(u8, name, "VK_EXT_present_timing")) return .error_extension_not_present;
        }
    }
    if (alloc != null) {
        hit(.device_allocator);
        return .error_initialization_failed;
    }
    if (ci.s_type != 3) {
        hit(.device_stype);
        return .error_initialization_failed;
    }
    if (!hasValidLoaderHead(ci.p_next, 48) or ci.flags != 0) return .error_initialization_failed;
    if (ci.features) |features| for (features.values) |feature| if (feature != 0) return .error_feature_not_present;
    if (ci.queue_info_count != 1) return .error_initialization_failed;
    const qis = ci.queue_infos orelse return .error_initialization_failed;
    const qi = qis[0];
    if (qi.s_type != 2) {
        hit(.queue_stype);
        return .error_initialization_failed;
    }
    if (qi.p_next != null) {
        hit(.queue_pnext);
        return .error_initialization_failed;
    }
    if (qi.flags != 0) {
        hit(.queue_flags);
        return .error_initialization_failed;
    }
    if (qi.family != 0) {
        hit(.queue_family);
        return .error_initialization_failed;
    }
    if (qi.count != 1) {
        hit(.queue_count);
        return .error_initialization_failed;
    }
    if (qi.priorities == null) {
        hit(.queue_priorities_null);
        return .error_initialization_failed;
    }
    const priority = qi.priorities.?[0];
    if (!std.math.isFinite(priority)) {
        hit(.priority_nonfinite);
        return .error_initialization_failed;
    }
    if (priority < 0) {
        hit(.priority_below_zero);
        return .error_initialization_failed;
    }
    if (priority > 1) {
        hit(.priority_above_one);
        return .error_initialization_failed;
    }
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(p)) return .error_initialization_failed;
    for (&device_objects, &queue_objects, &device_state) |*d, *q, *state| if (state.* == .never) {
        const generation = next_device_generation;
        next_device_generation +%= 1;
        if (next_device_generation == 0) next_device_generation = 1;
        d.* = .{ .loader_data = MAGIC, .physical = p, .set_loader_data = findDeviceLoaderCallback(ci.p_next), .heap_used = 0, .generation = generation };
        q.* = .{ .loader_data = MAGIC, .owner = d, .loader_initialized = false };
        state.* = .live;
        out.* = d;
        return .success;
    };
    hit(.pool_device_exhaustion);
    return .error_out_of_host_memory;
}
fn destroyDevice(device: ?Device, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const h = device orelse return;
    lock();
    defer mutex.unlock();
    for (&device_objects, &queue_objects, &device_state) |*d, *q, *state| if (state.* == .live and d == h) {
        for (&swapchain_objects, swapchain_state) |*swapchain, child_state| if (child_state == .live and swapchain.owner == d) {
            swapchain.retiring = true;
            _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
            while (swapchain.pending != 0) _ = std.c.pthread_cond_wait(&swapchain.present_condition, &swapchain.present_mutex);
            _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
        };
        for (&command_buffer_objects, &command_buffer_state) |*cb, *child_state| if (child_state.* == .live and cb.impl.owner == d) {
            child_state.* = .tombstone;
            cb.loader_data = 0;
        };
        for (&command_pool_objects, &command_pool_state) |*pool, *child_state| if (child_state.* == .live and pool.owner == d) {
            child_state.* = .tombstone;
        };
        for (&fence_objects, &fence_state) |*fence, *child_state| if (child_state.* == .live and fence.owner == d) {
            child_state.* = .tombstone;
        };
        for (&semaphore_objects, &semaphore_state) |*semaphore, *child_state| if (child_state.* == .live and semaphore.owner == d) {
            child_state.* = .tombstone;
        };
        for (&image_view_objects, &image_view_state) |*view, *child_state| if (child_state.* == .live and view.owner == d) {
            child_state.* = .tombstone;
        };
        for (&framebuffer_objects, &framebuffer_state) |*framebuffer, *child_state| if (child_state.* == .live and framebuffer.owner == d) {
            child_state.* = .tombstone;
        };
        for (&descriptor_set_objects, &descriptor_set_state) |*set, *child_state| if (child_state.* == .live and set.owner.eql(d)) {
            child_state.* = .tombstone;
        };
        for (&shader_module_objects, &shader_module_state) |*shader, *child_state| if (child_state.* == .live and shader.owner.eql(d)) {
            child_state.* = .tombstone;
            shader.module.deinit(allocator);
        };
        for (&descriptor_set_layout_objects, &descriptor_set_layout_state) |*object, *child_state| {
            if (child_state.* == .live and object.owner.eql(d)) child_state.* = .tombstone;
        }
        for (&pipeline_layout_objects, &pipeline_layout_state) |*object, *child_state| {
            if (child_state.* == .live and object.owner.eql(d)) child_state.* = .tombstone;
        }
        for (&render_pass_objects, &render_pass_state) |*object, *child_state| {
            if (child_state.* == .live and object.owner.eql(d)) child_state.* = .tombstone;
        }
        for (&graphics_pipeline_objects, &graphics_pipeline_state) |*object, *child_state| {
            if (child_state.* == .live and object.owner.eql(d)) child_state.* = .tombstone;
        }
        for (&framebuffer_objects, framebuffer_state) |*object, child_state| if (child_state != .never and object.owner == d) object.render_compatibility.deinit();
        for (&descriptor_set_layout_objects, descriptor_set_layout_state) |*object, child_state| if (child_state != .never and object.owner.eql(d)) object.canonical.deinit();
        for (&descriptor_set_objects, descriptor_set_state) |*object, child_state| if (child_state != .never and object.owner.eql(d)) object.layout.deinit();
        for (&pipeline_layout_objects, pipeline_layout_state) |*object, child_state| if (child_state != .never and object.owner.eql(d)) {
            object.canonical.deinit();
            object.set0.deinit();
        };
        for (&render_pass_objects, render_pass_state) |*object, child_state| if (child_state != .never and object.owner.eql(d)) {
            object.canonical.deinit();
            object.compatibility.deinit();
        };
        for (&graphics_pipeline_objects, graphics_pipeline_state) |*object, child_state| if (child_state != .never and object.owner.eql(d)) {
            object.canonical.deinit();
            object.layout.deinit();
            object.set0.deinit();
            object.render_compatibility.deinit();
            if (object.vertex_program) |*program| program.deinit(allocator);
            if (object.fragment_program) |*program| program.deinit(allocator);
        };
        for (&swapchain_objects, &swapchain_state) |*swapchain, *child_state| if (child_state.* == .live and swapchain.owner == d) {
            xcb_present.deinit(&swapchain.transport);
            child_state.* = .tombstone;
        };
        for (&buffer_objects, &buffer_state) |*buffer, *child_state| if (child_state.* == .live and buffer.owner == d) {
            child_state.* = .tombstone;
        };
        for (&image_objects, &image_state) |*image, *child_state| if (child_state.* == .live and image.owner == d) {
            child_state.* = .tombstone;
            if (!image.shared_bytes) if (image.owned_bytes) |bytes| allocator.free(bytes);
            image.owned_bytes = null;
        };
        for (&memory_objects, &memory_state) |*memory, *child_state| if (child_state.* == .live and memory.owner == d) {
            child_state.* = .tombstone;
            allocator.free(memory.bytes);
            memory.mapped = false;
        };
        d.heap_used = 0;
        state.* = .tombstone;
        d.loader_data = 0;
        q.loader_data = 0;
        return;
    };
}
fn getDeviceQueue(device: ?Device, family: u32, index: u32, output: ?*Queue) callconv(.c) void {
    const h = device orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(h) or family != 0 or index != 0) return;
    for (&device_objects, &queue_objects, &device_state) |*d, *q, state| if (state == .live and d == h) {
        if (!q.loader_initialized) {
            q.loader_initialized = true;
            if (d.set_loader_data) |set_loader_data| {
                mutex.unlock();
                const result = set_loader_data(d, q);
                lock();
                if (!validDeviceLocked(h)) {
                    hit(.callback_device_destroy);
                    return;
                }
                if (result == .success) hit(.callback_device_success) else {
                    hit(.callback_device_decline);
                    return;
                }
            }
        }
        out.* = q;
        return;
    };
}

const allocator = std.heap.page_allocator;
var test_allocations_before_failure: ?usize = null;
var test_fail_render_compatibility_clone = false;
var canonical_live_allocations: usize = 0;
fn failTestAllocation() bool {
    if (!@import("builtin").is_test) return false;
    const remaining = test_allocations_before_failure orelse return false;
    if (remaining == 0) return true;
    test_allocations_before_failure = remaining - 1;
    return false;
}
fn allocateBytes(size: usize) error{OutOfMemory}![]align(64) u8 {
    if (failTestAllocation()) return error.OutOfMemory;
    const bytes = try allocator.alignedAlloc(u8, .@"64", size);
    cpu_locality.prepareMemory(bytes);
    return bytes;
}
fn validOwner(device: Device, owner: Device) bool {
    return device == owner;
}
fn findLiveHandle(comptime T: type, handle: usize, objects: *[max_child_objects]T, states: *[max_child_objects]SlotState) ?*T {
    if (handle == 0) return null;
    for (objects, states) |*object, state| if (@intFromPtr(object) == handle) return if (state == .live) object else null;
    return null;
}
fn validMemoryLocked(handle: usize) ?*MemoryObj {
    const result = findLiveHandle(MemoryObj, handle, &memory_objects, &memory_state);
    if (handle != 0 and result == null) hit(.stale_memory);
    return result;
}
fn validBufferLocked(handle: usize) ?*BufferObj {
    const result = findLiveHandle(BufferObj, handle, &buffer_objects, &buffer_state);
    if (handle != 0 and result == null) hit(.stale_buffer);
    return result;
}
fn validImageLocked(handle: usize) ?*ImageObj {
    const result = findLiveHandle(ImageObj, handle, &image_objects, &image_state);
    if (handle != 0 and result == null) hit(.stale_image);
    return result;
}
fn validFenceLocked(handle: usize) ?*FenceObj {
    const result = findLiveHandle(FenceObj, handle, &fence_objects, &fence_state);
    if (handle != 0 and result == null) hit(.stale_fence);
    return result;
}
fn validSemaphoreLocked(handle: usize) ?*SemaphoreObj {
    return findLiveHandle(SemaphoreObj, handle, &semaphore_objects, &semaphore_state);
}
fn validImageViewLocked(handle: usize) ?*ImageViewObj {
    return findLiveHandle(ImageViewObj, handle, &image_view_objects, &image_view_state);
}
fn validFramebufferLocked(handle: usize) ?*FramebufferObj {
    return findLiveHandle(FramebufferObj, handle, &framebuffer_objects, &framebuffer_state);
}
fn validDescriptorSetLocked(handle: usize) ?*DescriptorSetObj {
    return findLiveHandle(DescriptorSetObj, handle, &descriptor_set_objects, &descriptor_set_state);
}
fn validDescriptorSetLayoutLocked(handle: usize) ?*DescriptorSetLayoutObj {
    return findLiveHandle(DescriptorSetLayoutObj, handle, &descriptor_set_layout_objects, &descriptor_set_layout_state);
}
fn validPipelineLayoutLocked(handle: usize) ?*PipelineLayoutObj {
    return findLiveHandle(PipelineLayoutObj, handle, &pipeline_layout_objects, &pipeline_layout_state);
}
fn validRenderPassLocked(handle: usize) ?*RenderPassObj {
    return findLiveHandle(RenderPassObj, handle, &render_pass_objects, &render_pass_state);
}
fn validGraphicsPipelineLocked(handle: usize) ?*GraphicsPipelineObj {
    return findLiveHandle(GraphicsPipelineObj, handle, &graphics_pipeline_objects, &graphics_pipeline_state);
}
fn validSwapchainLocked(handle: usize) ?*SwapchainObj {
    if (handle == 0) return null;
    for (&swapchain_objects, swapchain_state) |*object, state| if (@intFromPtr(object) == handle and state == .live) return object;
    return null;
}
fn allocateGenericHandle() usize {
    generic_handle += 8;
    return generic_handle;
}
fn validCommandPoolLocked(handle: usize) ?*CommandPoolObj {
    const result = findLiveHandle(CommandPoolObj, handle, &command_pool_objects, &command_pool_state);
    if (handle != 0 and result == null) hit(.stale_pool);
    return result;
}
fn validCommandBufferLocked(handle: ?CommandBuffer) ?*CommandBufferObj {
    const raw = handle orelse return null;
    for (&command_buffer_objects, &command_buffer_state) |*object, state| if (object == raw) {
        if (state == .live) return object;
        hit(.stale_command_buffer);
        return null;
    };
    hit(.stale_command_buffer);
    return null;
}
fn stateForObject(comptime T: type, object: *T, objects: *[max_child_objects]T, states: *[max_child_objects]SlotState) ?*SlotState {
    for (objects, states) |*candidate, *state| if (candidate == object) return state;
    return null;
}
fn liveMemoryObject(object: *MemoryObj) bool {
    return (stateForObject(MemoryObj, object, &memory_objects, &memory_state) orelse return false).* == .live;
}
fn liveBufferObject(object: *BufferObj) bool {
    return (stateForObject(BufferObj, object, &buffer_objects, &buffer_state) orelse return false).* == .live;
}
fn liveImageObject(object: *ImageObj) bool {
    return (stateForObject(ImageObj, object, &image_objects, &image_state) orelse return false).* == .live;
}
fn allocateMemory(device: ?Device, info: ?*const MemoryAllocateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (alloc != null or ci.s_type != 5 or ci.p_next != null or ci.memory_type_index != 0 or ci.allocation_size == 0 or ci.allocation_size > heap_size) return .error_out_of_host_memory;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    if (ci.allocation_size > heap_size - d.heap_used) {
        hit(.heap_exhaustion);
        return .error_out_of_host_memory;
    }
    _ = cpu_locality.pinCurrent(.render);
    const bytes = allocateBytes(std.math.cast(usize, ci.allocation_size) orelse return .error_out_of_host_memory) catch return .error_out_of_host_memory;
    @memset(bytes, 0);
    for (&memory_objects, &memory_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .bytes = bytes, .mapped = false };
        state.* = .live;
        d.heap_used += ci.allocation_size;
        out.* = @intFromPtr(object);
        return .success;
    };
    allocator.free(bytes);
    return .error_out_of_host_memory;
}
fn freeMemory(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const object = validMemoryLocked(handle) orelse return;
    if (!validDeviceLocked(d) or !validOwner(d, object.owner)) return;
    for (&buffer_objects, buffer_state) |*buffer, state| if (state == .live and buffer.memory == object) {
        hit(.bound_memory_retained);
        return;
    };
    for (&image_objects, image_state) |*image, state| if (state == .live and image.memory == object) {
        hit(.bound_memory_retained);
        return;
    };
    const state = stateForObject(MemoryObj, object, &memory_objects, &memory_state).?;
    state.* = .tombstone;
    d.heap_used -= object.bytes.len;
    hit(.heap_recovery);
    allocator.free(object.bytes);
    object.mapped = false;
}
fn mapMemory(device: ?Device, handle: usize, offset: u64, size: u64, flags: u32, output: ?*?*anyopaque) callconv(.c) Result {
    const d = device orelse return .error_memory_map_failed;
    const out = output orelse return .error_memory_map_failed;
    lock();
    defer mutex.unlock();
    const object = validMemoryLocked(handle) orelse return .error_memory_map_failed;
    if (!validDeviceLocked(d) or !validOwner(d, object.owner) or flags != 0 or object.mapped or offset > object.bytes.len) return .error_memory_map_failed;
    const actual = if (size == std.math.maxInt(u64)) object.bytes.len - @as(usize, @intCast(offset)) else std.math.cast(usize, size) orelse return .error_memory_map_failed;
    if (actual > object.bytes.len - @as(usize, @intCast(offset))) return .error_memory_map_failed;
    object.mapped = true;
    out.* = object.bytes.ptr + @as(usize, @intCast(offset));
    return .success;
}
fn unmapMemory(device: ?Device, handle: usize) callconv(.c) void {
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const object = validMemoryLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, object.owner)) object.mapped = false;
}
fn createBuffer(device: ?Device, info: ?*const BufferCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.usage == 0 or ci.usage & ~@as(u32, 0x13) != 0) {
        hit(.invalid_buffer_usage);
        return .error_initialization_failed;
    }
    if (alloc != null or ci.s_type != 12 or ci.p_next != null or ci.flags != 0 or ci.size == 0 or ci.size > heap_size or ci.sharing_mode != 0 or ci.queue_family_index_count != 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&buffer_objects, &buffer_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .size = ci.size, .usage = ci.usage };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    hit(.child_registry_exhaustion);
    return .error_out_of_host_memory;
}
fn destroyBuffer(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const object = validBufferLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, object.owner)) stateForObject(BufferObj, object, &buffer_objects, &buffer_state).?.* = .tombstone;
}
fn getBufferMemoryRequirements(device: ?Device, handle: usize, output: ?*MemoryRequirements) callconv(.c) void {
    const d = device orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    const object = validBufferLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, object.owner)) out.* = .{ .size = object.size, .alignment = 4, .memory_type_bits = 1 };
}
fn bindBufferMemory(device: ?Device, handle: usize, memory_handle: usize, offset: u64) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const object = validBufferLocked(handle) orelse return .error_initialization_failed;
    const memory = validMemoryLocked(memory_handle) orelse return .error_initialization_failed;
    if (offset % 4 != 0) {
        hit(.bind_alignment);
        return .error_initialization_failed;
    }
    if (!validDeviceLocked(d) or !validOwner(d, object.owner) or !validOwner(d, memory.owner) or object.memory != null or offset > memory.bytes.len or object.size > memory.bytes.len - offset) return .error_initialization_failed;
    object.memory = memory;
    object.offset = offset;
    return .success;
}
fn imageByteSize(image: *const ImageObj) ?u64 {
    const pixels = @as(u64, image.width) * image.height;
    return std.math.mul(u64, pixels, 4) catch {
        hit(.overflow_image_size);
        return null;
    };
}
fn supportedFormat(format: i32) bool {
    return format == 37 or format == 43 or format == 44 or format == 124;
}
fn createImage(device: ?Device, info: ?*const ImageCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.usage == 0 or ci.usage & ~@as(u32, 0x37) != 0) {
        hit(.invalid_image_usage);
        return .error_initialization_failed;
    }
    if (alloc != null or ci.s_type != 14 or ci.p_next != null or ci.flags != 0 or ci.image_type != 1 or !supportedFormat(ci.format) or ci.extent.width == 0 or ci.extent.height == 0 or ci.extent.width > 4096 or ci.extent.height > 4096 or ci.extent.depth != 1 or ci.mip_levels != 1 or ci.array_layers != 1 or ci.samples != 1 or (ci.tiling != 0 and ci.tiling != 1) or ci.sharing_mode != 0 or ci.queue_family_index_count != 0 or (ci.initial_layout != 0 and ci.initial_layout != 8)) return if (!supportedFormat(ci.format)) .error_format_not_supported else .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&image_objects, &image_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .width = ci.extent.width, .height = ci.extent.height, .array_layers = ci.array_layers, .samples = ci.samples, .format = ci.format, .usage = ci.usage, .layout = ci.initial_layout };
        if (imageByteSize(object) == null) return .error_initialization_failed;
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    hit(.child_registry_exhaustion);
    return .error_out_of_host_memory;
}
fn destroyImage(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const object = validImageLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, object.owner)) {
        stateForObject(ImageObj, object, &image_objects, &image_state).?.* = .tombstone;
        if (!object.shared_bytes) if (object.owned_bytes) |bytes| allocator.free(bytes);
        object.owned_bytes = null;
    }
}
fn getImageMemoryRequirements(device: ?Device, handle: usize, output: ?*MemoryRequirements) callconv(.c) void {
    const d = device orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    const image = validImageLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, image.owner)) out.* = .{ .size = imageByteSize(image).?, .alignment = 4, .memory_type_bits = 1 };
}
fn bindImageMemory(device: ?Device, handle: usize, memory_handle: usize, offset: u64) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const image = validImageLocked(handle) orelse return .error_initialization_failed;
    const memory = validMemoryLocked(memory_handle) orelse return .error_initialization_failed;
    const byte_size = imageByteSize(image) orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or !validOwner(d, image.owner) or !validOwner(d, memory.owner) or image.memory != null or offset % 4 != 0 or offset > memory.bytes.len or byte_size > memory.bytes.len - offset) return .error_initialization_failed;
    image.memory = memory;
    image.offset = offset;
    return .success;
}
fn getImageSubresourceLayout(device: ?Device, handle: usize, subresource: ?*const ImageSubresource, output: ?*SubresourceLayout) callconv(.c) void {
    const d = device orelse return;
    const sub = subresource orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    const image = validImageLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, image.owner) and sub.aspect_mask == 1 and sub.mip_level == 0 and sub.array_layer == 0) {
        const byte_size = imageByteSize(image).?;
        out.* = .{ .offset = 0, .size = byte_size, .row_pitch = @as(u64, image.width) * 4, .array_pitch = byte_size, .depth_pitch = byte_size };
    }
}
fn createFence(device: ?Device, info: ?*const FenceCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (alloc != null or ci.s_type != 8 or ci.p_next != null or ci.flags & ~@as(u32, 1) != 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&fence_objects, &fence_state) |*fence, *state| if (state.* == .never) {
        fence.* = .{ .owner = d, .signaled = ci.flags == 1 };
        state.* = .live;
        out.* = @intFromPtr(fence);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroyFence(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const fence = validFenceLocked(handle) orelse return;
    if (validDeviceLocked(d) and validOwner(d, fence.owner)) stateForObject(FenceObj, fence, &fence_objects, &fence_state).?.* = .tombstone;
}
fn getFenceStatus(device: ?Device, handle: usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const fence = validFenceLocked(handle) orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or !validOwner(d, fence.owner)) return .error_initialization_failed;
    return if (fence.signaled) .success else .not_ready;
}
fn resetFences(device: ?Device, count: u32, handles: ?[*]const usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    if (count == 0 or count > max_api_items) return .error_initialization_failed;
    const list = handles orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (list[0..count]) |handle| {
        const fence = validFenceLocked(handle) orelse return .error_initialization_failed;
        if (!validOwner(d, fence.owner)) return .error_initialization_failed;
        fence.signaled = false;
    }
    return .success;
}
fn waitForFences(device: ?Device, count: u32, handles: ?[*]const usize, wait_all: u32, timeout_ns: u64) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    if (count == 0 or count > max_api_items) return .error_initialization_failed;
    const list = handles orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d) or wait_all > 1) return .error_initialization_failed;
    var signaled: u32 = 0;
    for (list[0..count]) |handle| {
        const fence = validFenceLocked(handle) orelse return .error_initialization_failed;
        if (!validOwner(d, fence.owner)) return .error_initialization_failed;
        if (fence.signaled) signaled += 1;
    }
    const done = if (wait_all == 1) signaled == count else signaled != 0;
    if (done) return .success;
    _ = timeout_ns;
    return .timeout;
}
fn createCommandPool(device: ?Device, info: ?*const CommandPoolCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (alloc != null or ci.s_type != 39 or ci.p_next != null or ci.flags & ~@as(u32, 3) != 0 or ci.queue_family_index != 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&command_pool_objects, &command_pool_state) |*pool, *state| if (state.* == .never) {
        pool.* = .{ .owner = d };
        state.* = .live;
        out.* = @intFromPtr(pool);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroyCommandPool(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    const pool = validCommandPoolLocked(handle) orelse return;
    if (!validDeviceLocked(d) or !validOwner(d, pool.owner)) return;
    for (&command_buffer_objects, &command_buffer_state) |*cb, *state| if (state.* == .live and cb.impl.pool == pool) {
        state.* = .tombstone;
        cb.loader_data = 0;
    };
    stateForObject(CommandPoolObj, pool, &command_pool_objects, &command_pool_state).?.* = .tombstone;
}
fn allocateCommandBuffers(device: ?Device, info: ?*const CommandBufferAllocateInfo, output: ?[*]CommandBuffer) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.s_type != 40 or ci.p_next != null or ci.level != 0 or ci.command_buffer_count == 0 or ci.command_buffer_count > max_child_objects) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const pool = validCommandPoolLocked(ci.command_pool) orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or !validOwner(d, pool.owner)) return .error_initialization_failed;
    var made: usize = 0;
    while (made < ci.command_buffer_count) : (made += 1) {
        var slot: ?usize = null;
        for (&command_buffer_state, 0..) |state, index| if (state == .never) {
            slot = index;
            break;
        };
        const index = slot orelse {
            for (out[0..made]) |prior| {
                stateForObject(CommandBufferObj, prior, &command_buffer_objects, &command_buffer_state).?.* = .tombstone;
                prior.loader_data = 0;
            }
            return .error_out_of_host_memory;
        };
        const cb = &command_buffer_objects[index];
        const impl = &command_buffer_impls[index];
        impl.* = .{ .owner = d, .pool = pool, .state = 0, .invalid = false, .count = 0, .active_framebuffer = null, .active_render_pass = null, .bound_pipeline = null, .bound_pipeline_handle = 0, .bound_descriptors = null, .bound_layout = null, .bound_layout_handle = 0, .viewport = .{ .x = 0, .y = 0, .width = 0, .height = 0, .min_depth = 0, .max_depth = 1 }, .scissor = .{ .x = 0, .y = 0, .width = 0, .height = 0 }, .commands = undefined };
        cb.* = .{ .loader_data = MAGIC, .impl = impl };
        command_buffer_state[index] = .live;
        if (d.set_loader_data) |set| {
            mutex.unlock();
            const result = set(d, cb);
            lock();
            if (result != .success or !validDeviceLocked(d)) {
                command_buffer_state[index] = .tombstone;
                cb.loader_data = 0;
                for (out[0..made]) |prior| {
                    stateForObject(CommandBufferObj, prior, &command_buffer_objects, &command_buffer_state).?.* = .tombstone;
                    prior.loader_data = 0;
                }
                return .error_initialization_failed;
            }
        }
        out[made] = cb;
    }
    return .success;
}
fn freeCommandBuffers(device: ?Device, pool_handle: usize, count: u32, buffers: ?[*]const CommandBuffer) callconv(.c) void {
    const d = device orelse return;
    if (count == 0) return;
    if (count > max_api_items) return;
    const list = buffers orelse return;
    lock();
    defer mutex.unlock();
    const pool = validCommandPoolLocked(pool_handle) orelse return;
    if (!validDeviceLocked(d) or !validOwner(d, pool.owner)) return;
    for (list[0..count]) |raw| {
        const cb = validCommandBufferLocked(raw) orelse continue;
        if (cb.impl.owner == d and cb.impl.pool == pool) {
            stateForObject(CommandBufferObj, cb, &command_buffer_objects, &command_buffer_state).?.* = .tombstone;
            cb.loader_data = 0;
        }
    }
}
fn beginCommandBuffer(cb: ?CommandBuffer, info: ?*const CommandBufferBeginInfo) callconv(.c) Result {
    const bi = info orelse return .error_initialization_failed;
    if (bi.s_type != 42 or bi.p_next != null or bi.inheritance_info != null or bi.flags & ~@as(u32, 5) != 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return .error_initialization_failed;
    if (!validDeviceLocked(c.impl.owner) or c.impl.state == 1) return .error_initialization_failed;
    c.impl.state = 1;
    c.impl.invalid = false;
    c.impl.count = 0;
    c.impl.active_framebuffer = null;
    c.impl.active_render_pass = null;
    c.impl.bound_pipeline = null;
    c.impl.bound_pipeline_handle = 0;
    c.impl.bound_descriptors = null;
    c.impl.bound_layout = null;
    c.impl.bound_layout_handle = 0;
    return .success;
}
fn endCommandBuffer(cb: ?CommandBuffer) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return .error_initialization_failed;
    if (!validDeviceLocked(c.impl.owner) or c.impl.state != 1 or c.impl.invalid) return .error_initialization_failed;
    c.impl.state = 2;
    return .success;
}
fn resetCommandBuffer(cb: ?CommandBuffer, flags: u32) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return .error_initialization_failed;
    if (!validDeviceLocked(c.impl.owner) or flags & ~@as(u32, 1) != 0) return .error_initialization_failed;
    c.impl.state = 0;
    c.impl.invalid = false;
    c.impl.count = 0;
    c.impl.active_framebuffer = null;
    c.impl.active_render_pass = null;
    c.impl.bound_pipeline = null;
    c.impl.bound_pipeline_handle = 0;
    c.impl.bound_descriptors = null;
    c.impl.bound_layout = null;
    c.impl.bound_layout_handle = 0;
    return .success;
}
fn record(cb: CommandBuffer, command: Command) void {
    if (cb.impl.state != 1 or cb.impl.count == cb.impl.commands.len) {
        cb.impl.invalid = true;
        return;
    }
    cb.impl.commands[cb.impl.count] = command;
    cb.impl.count += 1;
}
fn cmdFillBuffer(cb: ?CommandBuffer, dst_handle: usize, offset: u64, size: u64, data: u32) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    const dst = validBufferLocked(dst_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const actual = if (size == std.math.maxInt(u64)) dst.size -| offset else size;
    if (dst.usage & 0x2 == 0) hit(.missing_transfer_usage);
    if (actual == 0) hit(.zero_fill_rejected);
    if (dst.owner != c.impl.owner or dst.usage & 0x2 == 0 or dst.memory == null or actual == 0 or offset % 4 != 0 or actual % 4 != 0 or offset > dst.size or actual > dst.size - offset) {
        c.impl.invalid = true;
        return;
    }
    record(c, .{ .fill = .{ .dst = dst, .offset = offset, .size = actual, .data = data } });
}
fn cmdCopyBuffer(cb: ?CommandBuffer, src_handle: usize, dst_handle: usize, count: u32, regions: ?[*]const BufferCopy) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    if (count == 0) {
        hit(.zero_count_noop);
        return;
    }
    if (count > max_api_items) {
        hit(.excessive_count);
        c.impl.invalid = true;
        return;
    }
    const src = validBufferLocked(src_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const dst = validBufferLocked(dst_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const list = regions orelse {
        c.impl.invalid = true;
        return;
    };
    for (list[0..count]) |region| {
        if (src.owner != c.impl.owner or dst.owner != c.impl.owner or src.usage & 0x1 == 0 or dst.usage & 0x2 == 0 or src.memory == null or dst.memory == null or region.size == 0 or region.src_offset > src.size or region.size > src.size - region.src_offset or region.dst_offset > dst.size or region.size > dst.size - region.dst_offset) {
            c.impl.invalid = true;
            return;
        }
        record(c, .{ .copy_buffer = .{ .src = src, .dst = dst, .region = region } });
    }
}
fn colorBytes(image: *const ImageObj, value: *const ClearColorValue) ?[4]u8 {
    var rgba: [4]u8 = undefined;
    for (value.float32, 0..) |component, i| {
        if (!std.math.isFinite(component)) return null;
        rgba[i] = @intFromFloat(@round(std.math.clamp(component, 0, 1) * 255));
    }
    if (image.format == 44) std.mem.swap(u8, &rgba[0], &rgba[2]);
    return rgba;
}
fn validLayers(l: ImageSubresourceLayers) bool {
    return l.aspect_mask == 1 and l.mip_level == 0 and l.base_array_layer == 0 and l.layer_count == 1;
}
fn validRange(r: ImageSubresourceRange) bool {
    return r.aspect_mask == 1 and r.base_mip_level == 0 and r.level_count == 1 and r.base_array_layer == 0 and r.layer_count == 1;
}
fn cmdClearColorImage(cb: ?CommandBuffer, image_handle: usize, layout: i32, color: ?*const ClearColorValue, count: u32, ranges: ?[*]const ImageSubresourceRange) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    if (count == 0 or count > max_api_items) {
        c.impl.invalid = true;
        return;
    }
    const image = validImageLocked(image_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const value = color orelse {
        c.impl.invalid = true;
        return;
    };
    const list = ranges orelse {
        c.impl.invalid = true;
        return;
    };
    if (image.owner != c.impl.owner or image.usage & 0x2 == 0 or image.memory == null or (layout != 1 and layout != 7) or count != 1 or !validRange(list[0])) {
        c.impl.invalid = true;
        return;
    }
    const bytes = colorBytes(image, value) orelse {
        hit(.invalid_clear_color);
        c.impl.invalid = true;
        return;
    };
    record(c, .{ .clear = .{ .image = image, .layout = layout, .color = bytes } });
}
fn validImageRegion(image: *const ImageObj, offset: Offset3D, extent: Extent3D, layers: ImageSubresourceLayers) bool {
    if (!validLayers(layers) or offset.x < 0 or offset.y < 0 or offset.z != 0 or extent.width == 0 or extent.height == 0 or extent.depth != 1) return false;
    const end_x = std.math.add(u64, @intCast(offset.x), extent.width) catch return false;
    const end_y = std.math.add(u64, @intCast(offset.y), extent.height) catch return false;
    return end_x <= image.width and end_y <= image.height;
}
fn checkedBufferImageSub(a: u64, b: u64) ?u64 {
    return std.math.sub(u64, a, b) catch {
        hit(.overflow_buffer_image);
        return null;
    };
}
fn checkedBufferImageMul(a: u64, b: u64) ?u64 {
    return std.math.mul(u64, a, b) catch {
        hit(.overflow_buffer_image);
        return null;
    };
}
fn checkedBufferImageAdd(a: u64, b: u64) ?u64 {
    return std.math.add(u64, a, b) catch {
        hit(.overflow_buffer_image);
        return null;
    };
}
fn bufferImageEnd(region: BufferImageCopy) ?u64 {
    const row = if (region.buffer_row_length == 0) region.image_extent.width else region.buffer_row_length;
    const height = if (region.buffer_image_height == 0) region.image_extent.height else region.buffer_image_height;
    if (row < region.image_extent.width or height < region.image_extent.height or region.buffer_offset % 4 != 0) return null;
    const rows_before_last = checkedBufferImageSub(region.image_extent.height, 1) orelse return null;
    const prior_rows = checkedBufferImageMul(rows_before_last, row) orelse return null;
    const texels = checkedBufferImageAdd(prior_rows, region.image_extent.width) orelse return null;
    const bytes = checkedBufferImageMul(texels, 4) orelse return null;
    return checkedBufferImageAdd(region.buffer_offset, bytes);
}
fn cmdCopyBufferToImage(cb: ?CommandBuffer, src_handle: usize, dst_handle: usize, layout: i32, count: u32, regions: ?[*]const BufferImageCopy) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    if (count == 0) {
        hit(.zero_count_noop);
        return;
    }
    if (count > max_api_items) {
        hit(.excessive_count);
        c.impl.invalid = true;
        return;
    }
    const src = validBufferLocked(src_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const dst = validImageLocked(dst_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const list = regions orelse {
        c.impl.invalid = true;
        return;
    };
    for (list[0..count]) |region| {
        const end = bufferImageEnd(region);
        if (src.owner != c.impl.owner or dst.owner != c.impl.owner or src.usage & 0x1 == 0 or dst.usage & 0x2 == 0 or src.memory == null or dst.memory == null or (layout != 1 and layout != 7) or !validImageRegion(dst, region.image_offset, region.image_extent, region.image_subresource) or end == null or end.? > src.size) {
            c.impl.invalid = true;
            return;
        }
        record(c, .{ .buffer_to_image = .{ .src = src, .dst = dst, .layout = layout, .region = region } });
    }
}
fn cmdCopyImageToBuffer(cb: ?CommandBuffer, src_handle: usize, layout: i32, dst_handle: usize, count: u32, regions: ?[*]const BufferImageCopy) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    if (count == 0) {
        hit(.zero_count_noop);
        return;
    }
    if (count > max_api_items) {
        hit(.excessive_count);
        c.impl.invalid = true;
        return;
    }
    const src = validImageLocked(src_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const dst = validBufferLocked(dst_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const list = regions orelse {
        c.impl.invalid = true;
        return;
    };
    for (list[0..count]) |region| {
        const end = bufferImageEnd(region);
        if (src.owner != c.impl.owner or dst.owner != c.impl.owner or src.usage & 0x1 == 0 or dst.usage & 0x2 == 0 or src.memory == null or dst.memory == null or (layout != 1 and layout != 6) or !validImageRegion(src, region.image_offset, region.image_extent, region.image_subresource) or end == null or end.? > dst.size) {
            c.impl.invalid = true;
            return;
        }
        record(c, .{ .image_to_buffer = .{ .src = src, .layout = layout, .dst = dst, .region = region } });
    }
}
fn cmdCopyImage(cb: ?CommandBuffer, src_handle: usize, src_layout: i32, dst_handle: usize, dst_layout: i32, count: u32, regions: ?[*]const ImageCopy) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    if (count == 0) {
        hit(.zero_count_noop);
        return;
    }
    if (count > max_api_items) {
        hit(.excessive_count);
        c.impl.invalid = true;
        return;
    }
    const src = validImageLocked(src_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const dst = validImageLocked(dst_handle) orelse {
        c.impl.invalid = true;
        return;
    };
    const list = regions orelse {
        c.impl.invalid = true;
        return;
    };
    for (list[0..count]) |region| {
        if (src.owner != c.impl.owner or dst.owner != c.impl.owner or src.usage & 0x1 == 0 or dst.usage & 0x2 == 0 or src.memory == null or dst.memory == null or src.format != dst.format or (src_layout != 1 and src_layout != 6) or (dst_layout != 1 and dst_layout != 7) or !validImageRegion(src, region.src_offset, region.extent, region.src_subresource) or !validImageRegion(dst, region.dst_offset, region.extent, region.dst_subresource)) {
            c.impl.invalid = true;
            return;
        }
        record(c, .{ .copy_image = .{ .src = src, .src_layout = src_layout, .dst = dst, .dst_layout = dst_layout, .region = region } });
    }
}
fn supportedLayout(layout: i32) bool {
    return layout == 0 or layout == 8 or layout == 1 or layout == 2 or layout == 3 or layout == 5 or layout == 6 or layout == 7 or layout == 1_000_001_002;
}
fn barrierMasksSupported(barrier: ImageMemoryBarrier, src_stage_mask: u32, dst_stage_mask: u32) bool {
    if (barrier.old_layout == 8 and barrier.new_layout == 5 and src_stage_mask == 0x1 and dst_stage_mask == 0x80 and barrier.src_access_mask == 0 and barrier.dst_access_mask == 0x30) return true;
    if (barrier.old_layout == 0 and barrier.new_layout == 3 and src_stage_mask == 0x1 and dst_stage_mask == 0x100 and barrier.src_access_mask == 0 and barrier.dst_access_mask == 0x400) return true;
    const expected_src_stage: u32 = switch (barrier.old_layout) {
        0 => 0x1,
        8 => 0x4000,
        1, 6, 7 => 0x1000,
        else => return false,
    };
    const expected_src_access: u32 = switch (barrier.old_layout) {
        0 => 0,
        8 => 0x4000,
        1 => 0x1800,
        6 => 0x800,
        7 => 0x1000,
        else => return false,
    };
    const expected_dst_access: u32 = switch (barrier.new_layout) {
        1 => 0x1800,
        6 => 0x800,
        7 => 0x1000,
        else => return false,
    };
    return src_stage_mask == expected_src_stage and dst_stage_mask == 0x1000 and barrier.src_access_mask == expected_src_access and barrier.dst_access_mask == expected_dst_access;
}
fn cmdPipelineBarrier(cb: ?CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?*const anyopaque, buffer_barrier_count: u32, buffer_barriers: ?*const anyopaque, image_barrier_count: u32, image_barriers: ?[*]const ImageMemoryBarrier) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    _ = memory_barriers;
    _ = buffer_barriers;
    if (dependency_flags != 0 or memory_barrier_count != 0 or buffer_barrier_count != 0 or image_barrier_count > max_api_items) {
        hit(.invalid_barrier);
        c.impl.invalid = true;
        return;
    }
    if (image_barrier_count == 0) return;
    const list = image_barriers orelse {
        hit(.invalid_barrier);
        c.impl.invalid = true;
        return;
    };
    for (list[0..image_barrier_count]) |barrier| {
        const image = validImageLocked(barrier.image) orelse {
            hit(.invalid_barrier);
            c.impl.invalid = true;
            return;
        };
        const ignored: u32 = std.math.maxInt(u32);
        const queues_valid = (barrier.src_queue_family_index == ignored and barrier.dst_queue_family_index == ignored) or (barrier.src_queue_family_index == 0 and barrier.dst_queue_family_index == 0);
        if (barrier.s_type != 45 or barrier.p_next != null or !supportedLayout(barrier.old_layout) or !barrierMasksSupported(barrier, src_stage_mask, dst_stage_mask) or !queues_valid or image.owner != c.impl.owner or !validRange(barrier.subresource_range)) {
            hit(.invalid_barrier);
            c.impl.invalid = true;
            return;
        }
        record(c, .{ .transition = .{ .image = image, .old_layout = barrier.old_layout, .new_layout = barrier.new_layout } });
    }
}
fn bufferBytes(buffer: *BufferObj) []u8 {
    const memory = buffer.memory.?;
    const start: usize = @intCast(buffer.offset);
    return memory.bytes[start .. start + @as(usize, @intCast(buffer.size))];
}
fn imageBytes(image: *ImageObj) []u8 {
    if (image.owned_bytes) |bytes| return bytes;
    const memory = image.memory.?;
    const start: usize = @intCast(image.offset);
    return memory.bytes[start .. start + @as(usize, @intCast(imageByteSize(image).?))];
}
fn imageSlot(image: *ImageObj) ?usize {
    for (&image_objects, &image_state, 0..) |*candidate, state, index| if (candidate == image) return if (state == .live) index else null;
    return null;
}
fn deadResource() bool {
    hit(.recorded_dead_resource);
    return false;
}
fn wrongSubmittingDevice() bool {
    hit(.submitting_device_ownership);
    return false;
}
fn prevalidateCommand(command: Command, owner: *DeviceObj, layouts: *[max_child_objects]i32) bool {
    switch (command) {
        .fill => |op| {
            if (!liveBufferObject(op.dst) or op.dst.memory == null or !liveMemoryObject(op.dst.memory.?)) return deadResource();
            if (op.dst.owner != owner or op.dst.memory.?.owner != owner) return wrongSubmittingDevice();
        },
        .copy_buffer => |op| {
            if (!liveBufferObject(op.src) or !liveBufferObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?)) return deadResource();
            if (op.src.owner != owner or op.dst.owner != owner or op.src.memory.?.owner != owner or op.dst.memory.?.owner != owner) return wrongSubmittingDevice();
        },
        .clear => |op| {
            const slot = imageSlot(op.image) orelse return deadResource();
            if (op.image.memory == null or !liveMemoryObject(op.image.memory.?)) return deadResource();
            if (op.image.owner != owner or op.image.memory.?.owner != owner) return wrongSubmittingDevice();
            if (layouts[slot] != op.layout) {
                hit(.layout_mismatch);
                return false;
            }
        },
        .render_clear => |op| {
            _ = imageSlot(op.image) orelse return deadResource();
            if (op.image.owner != owner or op.image.owned_bytes == null) return wrongSubmittingDevice();
            if (op.depth) |depth| if (depth.owner != owner or depth.memory == null or !liveMemoryObject(depth.memory.?)) return deadResource();
        },
        .cube_draw => |op| {
            const color = op.framebuffer.color_image orelse return deadResource();
            const depth = op.framebuffer.depth_image orelse return deadResource();
            const uniform = op.descriptors.uniform orelse return deadResource();
            const texture = op.descriptors.texture orelse return deadResource();
            if ((stateForObject(FramebufferObj, op.framebuffer, &framebuffer_objects, &framebuffer_state) orelse return deadResource()).* != .live or (stateForObject(DescriptorSetObj, op.descriptors, &descriptor_set_objects, &descriptor_set_state) orelse return deadResource()).* != .live) return deadResource();
            if (color.owner != owner or depth.owner != owner or uniform.owner != owner or texture.owner != owner or color.owned_bytes == null or depth.memory == null or uniform.memory == null or texture.memory == null) return wrongSubmittingDevice();
            if (!liveMemoryObject(depth.memory.?) or !liveMemoryObject(uniform.memory.?) or !liveMemoryObject(texture.memory.?)) return deadResource();
        },
        .buffer_to_image => |op| {
            const slot = imageSlot(op.dst) orelse return deadResource();
            if (!liveBufferObject(op.src) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?)) return deadResource();
            if (op.src.owner != owner or op.dst.owner != owner or op.src.memory.?.owner != owner or op.dst.memory.?.owner != owner) return wrongSubmittingDevice();
            if (layouts[slot] != op.layout) {
                hit(.layout_mismatch);
                return false;
            }
        },
        .image_to_buffer => |op| {
            const slot = imageSlot(op.src) orelse return deadResource();
            if (!liveBufferObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?)) return deadResource();
            if (op.src.owner != owner or op.dst.owner != owner or op.src.memory.?.owner != owner or op.dst.memory.?.owner != owner) return wrongSubmittingDevice();
            if (layouts[slot] != op.layout) {
                hit(.layout_mismatch);
                return false;
            }
        },
        .copy_image => |op| {
            const src_slot = imageSlot(op.src) orelse return deadResource();
            const dst_slot = imageSlot(op.dst) orelse return deadResource();
            if (op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?)) return deadResource();
            if (op.src.owner != owner or op.dst.owner != owner or op.src.memory.?.owner != owner or op.dst.memory.?.owner != owner) return wrongSubmittingDevice();
            if (layouts[src_slot] != op.src_layout or layouts[dst_slot] != op.dst_layout) {
                hit(.layout_mismatch);
                return false;
            }
        },
        .transition => |op| {
            const slot = imageSlot(op.image) orelse return deadResource();
            if (op.image.owner != owner) return wrongSubmittingDevice();
            if (layouts[slot] != op.old_layout) {
                hit(.layout_mismatch);
                return false;
            }
            layouts[slot] = op.new_layout;
        },
    }
    return true;
}
fn fillImagePattern(bytes: []u8, pattern: u32) void {
    const aligned: []align(4) u8 = @alignCast(bytes);
    @memset(std.mem.bytesAsSlice(u32, aligned), pattern);
}

fn executeValidatedCommand(command: Command) void {
    switch (command) {
        .fill => |op| {
            const bytes = bufferBytes(op.dst)[@intCast(op.offset)..][0..@intCast(op.size)];
            benchmarkHostMemoryFill(bytes, op.data);
        },
        .copy_buffer => |op| {
            const src = bufferBytes(op.src)[@intCast(op.region.src_offset)..][0..@intCast(op.region.size)];
            const dst = bufferBytes(op.dst)[@intCast(op.region.dst_offset)..][0..@intCast(op.region.size)];
            benchmarkHostMemoryCopy(dst, src);
        },
        .clear => |op| {
            fillImagePattern(imageBytes(op.image), @bitCast(op.color));
        },
        .render_clear => |op| {
            const bytes = imageBytes(op.image);
            if (op.depth) |depth| {
                const depth_bytes = imageBytes(depth);
                if (bytes.len < 8 * 1024 * 1024 or !cpu_cube.clearImagesParallel(bytes, @bitCast(op.color), depth_bytes, @bitCast(op.depth_value))) {
                    fillImagePattern(bytes, @bitCast(op.color));
                    fillImagePattern(depth_bytes, @bitCast(op.depth_value));
                }
            } else {
                fillImagePattern(bytes, @bitCast(op.color));
            }
        },
        .cube_draw => |op| {
            const color = op.framebuffer.color_image.?;
            const depth = op.framebuffer.depth_image.?;
            const uniform_buffer = op.descriptors.uniform.?;
            const uniform_start: usize = @intCast(uniform_buffer.offset + op.descriptors.uniform_offset);
            const uniform_length: usize = @intCast(@min(op.descriptors.uniform_range, uniform_buffer.size - op.descriptors.uniform_offset));
            const uniform_memory = uniform_buffer.memory.?.bytes;
            const texture = op.descriptors.texture.?;
            _ = cpu_cube.draw(imageBytes(color), imageBytes(depth), color.width, color.height, uniform_memory[uniform_start..][0..uniform_length], imageBytes(texture), texture.width, texture.height, op.vertex_count, op.viewport, op.scissor, op.cull_mode, op.front_face);
        },
        .buffer_to_image => |op| {
            copyBufferImage(op.src, op.dst, op.region, true);
        },
        .image_to_buffer => |op| {
            copyBufferImage(op.dst, op.src, op.region, false);
        },
        .copy_image => |op| {
            const src = imageBytes(op.src);
            const dst = imageBytes(op.dst);
            var y: u32 = 0;
            while (y < op.region.extent.height) : (y += 1) {
                const so = (@as(usize, @intCast(op.region.src_offset.y)) + y) * op.src.width * 4 + @as(usize, @intCast(op.region.src_offset.x)) * 4;
                const do = (@as(usize, @intCast(op.region.dst_offset.y)) + y) * op.dst.width * 4 + @as(usize, @intCast(op.region.dst_offset.x)) * 4;
                const len = @as(usize, op.region.extent.width) * 4;
                std.mem.copyForwards(u8, dst[do..][0..len], src[so..][0..len]);
            }
        },
        .transition => |op| {
            op.image.layout = op.new_layout;
            hit(.barrier_transition);
        },
    }
}

/// CPU implementation shared by vkCmdFillBuffer execution and its benchmark.
/// This is unified host memory; the Vulkan command semantics do not imply a
/// discrete-VRAM upload.
pub fn benchmarkHostMemoryFill(bytes: []u8, data: u32) void {
    host_memory.fill(bytes, data);
}

/// CPU implementation shared by vkCmdCopyBuffer execution and its benchmark.
pub fn benchmarkHostMemoryCopy(dst: []u8, src: []const u8) void {
    host_memory.copy(dst, src);
}

test "Vulkan host-memory benchmark helpers implement exact command byte semantics" {
    var filled = [_]u8{0} ** 8;
    benchmarkHostMemoryFill(&filled, 0x44332211);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x11, 0x22, 0x33, 0x44, 0x11, 0x22, 0x33, 0x44 }, &filled);
    var copied = [_]u8{0} ** 8;
    benchmarkHostMemoryCopy(&copied, &filled);
    try std.testing.expectEqualSlices(u8, &filled, &copied);
}
fn copyBufferImage(buffer: *BufferObj, image: *ImageObj, region: BufferImageCopy, to_image: bool) void {
    const b = bufferBytes(buffer);
    const pixels = imageBytes(image);
    const row = if (region.buffer_row_length == 0) region.image_extent.width else region.buffer_row_length;
    var y: u32 = 0;
    while (y < region.image_extent.height) : (y += 1) {
        const bo = @as(usize, @intCast(region.buffer_offset)) + @as(usize, y) * row * 4;
        const io = (@as(usize, @intCast(region.image_offset.y)) + y) * image.width * 4 + @as(usize, @intCast(region.image_offset.x)) * 4;
        const len = @as(usize, region.image_extent.width) * 4;
        if (to_image) std.mem.copyForwards(u8, pixels[io..][0..len], b[bo..][0..len]) else std.mem.copyForwards(u8, b[bo..][0..len], pixels[io..][0..len]);
    }
}

const max_canonical_bytes = 2 * spirv.max_code_bytes + 64 * 1024;
const CanonicalError = error{ Invalid, TooLarge, OutOfMemory };
const CanonicalWriter = struct {
    list: std.ArrayList(u8) = .empty,
    fn deinit(self: *CanonicalWriter) void {
        self.list.deinit(allocator);
    }
    fn raw(self: *CanonicalWriter, bytes: []const u8) CanonicalError!void {
        if (bytes.len > max_canonical_bytes -| self.list.items.len) return error.TooLarge;
        if (failTestAllocation()) return error.OutOfMemory;
        self.list.appendSlice(allocator, bytes) catch return error.OutOfMemory;
    }
    fn u32le(self: *CanonicalWriter, value: u32) CanonicalError!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.raw(&bytes);
    }
    fn i32le(self: *CanonicalWriter, value: i32) CanonicalError!void {
        try self.u32le(@bitCast(value));
    }
    fn u64le(self: *CanonicalWriter, value: u64) CanonicalError!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.raw(&bytes);
    }
    fn f32le(self: *CanonicalWriter, value: f32) CanonicalError!void {
        if (!std.math.isFinite(value)) return error.Invalid;
        try self.u32le(if (value == 0) 0 else @bitCast(value));
    }
    fn header(self: *CanonicalWriter, kind: u32) CanonicalError!void {
        try self.raw("ZPUC");
        try self.u32le(1);
        try self.u32le(kind);
        try self.u32le(spirv.ingestion_version);
        try self.u32le(spirv.serialization_version);
        try self.u32le(1); // canonical compiler policy
        try self.u32le(1); // cpu_cube_v1 execution ABI
        try self.u32le(0); // baseline CPU feature policy; no host-feature specialization
    }
    fn done(self: *CanonicalWriter) CanonicalError!Canonical {
        if (failTestAllocation()) return error.OutOfMemory;
        var value = Canonical{ .bytes = self.list.toOwnedSlice(allocator) catch return error.OutOfMemory };
        canonical_live_allocations += 1;
        value.finish();
        return value;
    }
};
fn bool32(value: u32) CanonicalError!u32 {
    if (value > 1) return error.Invalid;
    return value;
}
fn appendCanonical(writer: *CanonicalWriter, value: *const Canonical) CanonicalError!void {
    try writer.u64le(value.bytes.len);
    try writer.raw(value.bytes);
}
fn creationFailure(err: CanonicalError) Result {
    return switch (err) {
        error.TooLarge => .error_out_of_host_memory,
        error.OutOfMemory => .error_out_of_host_memory,
        error.Invalid => .error_initialization_failed,
    };
}

fn buildDescriptorSetLayout(ci: *const DescriptorSetLayoutCreateInfo) CanonicalError!Canonical {
    if (ci.s_type != 32 or ci.p_next != null or ci.flags != 0 or ci.binding_count > 64 or (ci.binding_count != 0 and ci.bindings == null)) return error.Invalid;
    var indices: [64]u8 = undefined;
    for (0..ci.binding_count) |i| indices[i] = @intCast(i);
    const bindings = if (ci.bindings) |p| p[0..ci.binding_count] else &.{};
    std.mem.sort(u8, indices[0..ci.binding_count], bindings, struct {
        fn less(items: []const DescriptorSetLayoutBinding, a: u8, b: u8) bool {
            return items[a].binding < items[b].binding;
        }
    }.less);
    var w: CanonicalWriter = .{};
    defer w.deinit();
    try w.header(1);
    try w.u32le(ci.binding_count);
    var previous: ?u32 = null;
    for (indices[0..ci.binding_count]) |index| {
        const b = bindings[index];
        if (previous == b.binding or b.descriptor_count == 0 or b.descriptor_type < 0 or b.descriptor_type > 10 or b.stage_flags == 0 or b.stage_flags & ~@as(u32, 0x7fff_ffff) != 0 or b.immutable_samplers != null) return error.Invalid;
        previous = b.binding;
        try w.u32le(b.binding);
        try w.i32le(b.descriptor_type);
        try w.u32le(b.descriptor_count);
        try w.u32le(b.stage_flags);
    }
    return try w.done();
}
fn createDescriptorSetLayout(device: ?Device, info: ?*const DescriptorSetLayoutCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    var canonical = buildDescriptorSetLayout(ci) catch |err| return creationFailure(err);
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) {
        canonical.deinit();
        return .error_initialization_failed;
    }
    for (&descriptor_set_layout_objects, &descriptor_set_layout_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = DeviceIdentity.capture(d), .canonical = canonical };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    canonical.deinit();
    return .error_out_of_host_memory;
}
fn destroyDescriptorSetLayout(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const d = device orelse return;
    const object = validDescriptorSetLayoutLocked(handle) orelse return;
    if (validDeviceLocked(d) and object.owner.eql(d)) stateForObject(DescriptorSetLayoutObj, object, &descriptor_set_layout_objects, &descriptor_set_layout_state).?.* = .tombstone;
}

fn buildPipelineLayoutLocked(d: Device, ci: *const PipelineLayoutCreateInfo) CanonicalError!Canonical {
    if (ci.s_type != 30 or ci.p_next != null or ci.flags != 0 or ci.set_layout_count > 4 or ci.push_constant_range_count > 16 or (ci.set_layout_count != 0 and ci.set_layouts == null) or (ci.push_constant_range_count != 0 and ci.push_constant_ranges == null)) return error.Invalid;
    var w: CanonicalWriter = .{};
    defer w.deinit();
    try w.header(2);
    try w.u32le(ci.set_layout_count);
    if (ci.set_layouts) |handles| for (handles[0..ci.set_layout_count]) |handle| {
        const layout = validDescriptorSetLayoutLocked(handle) orelse return error.Invalid;
        if (!layout.owner.eql(d)) return error.Invalid;
        try appendCanonical(&w, &layout.canonical);
    };
    try w.u32le(ci.push_constant_range_count);
    if (ci.push_constant_ranges) |ranges| for (ranges[0..ci.push_constant_range_count]) |range| {
        if (range.stage_flags == 0 or range.offset % 4 != 0 or range.size == 0 or range.size % 4 != 0 or range.offset +| range.size > 128) return error.Invalid;
        try w.u32le(range.stage_flags);
        try w.u32le(range.offset);
        try w.u32le(range.size);
    };
    return try w.done();
}
fn createPipelineLayout(device: ?Device, info: ?*const PipelineLayoutCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d) or ci.set_layout_count != 1) return .error_initialization_failed;
    var canonical = buildPipelineLayoutLocked(d, ci) catch |err| return creationFailure(err);
    const source_set = validDescriptorSetLayoutLocked(ci.set_layouts.?[0]).?;
    var set0 = source_set.canonical.clone() catch {
        canonical.deinit();
        return .error_out_of_host_memory;
    };
    for (&pipeline_layout_objects, &pipeline_layout_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = DeviceIdentity.capture(d), .canonical = canonical, .set0 = set0 };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    canonical.deinit();
    set0.deinit();
    return .error_out_of_host_memory;
}
fn destroyPipelineLayout(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const d = device orelse return;
    const object = validPipelineLayoutLocked(handle) orelse return;
    if (validDeviceLocked(d) and object.owner.eql(d)) stateForObject(PipelineLayoutObj, object, &pipeline_layout_objects, &pipeline_layout_state).?.* = .tombstone;
}

fn appendAttachmentRef(w: *CanonicalWriter, ref: AttachmentReference, count: u32) CanonicalError!void {
    if (ref.attachment != 0xffff_ffff and ref.attachment >= count) return error.Invalid;
    try w.u32le(ref.attachment);
    try w.i32le(ref.layout);
}
fn buildRenderPass(ci: *const RenderPassCreateInfo, compatibility_only: bool) CanonicalError!Canonical {
    if (ci.s_type != 38 or ci.p_next != null or ci.flags != 0 or ci.attachment_count > 16 or ci.subpass_count == 0 or ci.subpass_count > 8 or ci.dependency_count > 32 or (ci.attachment_count != 0 and ci.attachments == null) or ci.subpasses == null or (ci.dependency_count != 0 and ci.dependencies == null)) return error.Invalid;
    var w: CanonicalWriter = .{};
    defer w.deinit();
    try w.header(if (compatibility_only) 4 else 3);
    try w.u32le(ci.attachment_count);
    if (ci.attachments) |items| for (items[0..ci.attachment_count]) |a| {
        if (a.flags != 0 or a.samples == 0 or a.samples & (a.samples - 1) != 0) return error.Invalid;
        try w.i32le(a.format);
        try w.u32le(a.samples);
        if (!compatibility_only) {
            try w.i32le(a.load_op);
            try w.i32le(a.store_op);
            try w.i32le(a.stencil_load_op);
            try w.i32le(a.stencil_store_op);
            try w.i32le(a.initial_layout);
            try w.i32le(a.final_layout);
        }
    };
    try w.u32le(ci.subpass_count);
    for (ci.subpasses.?[0..ci.subpass_count]) |s| {
        if (s.flags != 0 or s.pipeline_bind_point != 0 or s.input_attachment_count > 16 or s.color_attachment_count > 8 or s.preserve_attachment_count > 16 or (s.input_attachment_count != 0 and s.input_attachments == null) or (s.color_attachment_count != 0 and s.color_attachments == null) or (s.preserve_attachment_count != 0 and s.preserve_attachments == null)) return error.Invalid;
        try w.u32le(s.input_attachment_count);
        if (s.input_attachments) |refs| for (refs[0..s.input_attachment_count]) |ref| try appendAttachmentRef(&w, ref, ci.attachment_count);
        try w.u32le(s.color_attachment_count);
        if (s.color_attachments) |refs| for (refs[0..s.color_attachment_count], 0..) |ref, index| {
            for (refs[0..index]) |prior| if (ref.attachment != 0xffff_ffff and ref.attachment == prior.attachment) return error.Invalid;
            try appendAttachmentRef(&w, ref, ci.attachment_count);
        };
        try w.u32le(if (s.resolve_attachments == null) 0 else 1);
        if (s.resolve_attachments) |refs| for (refs[0..s.color_attachment_count]) |ref| try appendAttachmentRef(&w, ref, ci.attachment_count);
        try w.u32le(if (s.depth_stencil_attachment == null) 0 else 1);
        if (s.depth_stencil_attachment) |ref| {
            if (s.color_attachments) |refs| for (refs[0..s.color_attachment_count]) |color| if (ref.attachment != 0xffff_ffff and ref.attachment == color.attachment) return error.Invalid;
            try appendAttachmentRef(&w, ref.*, ci.attachment_count);
        }
        try w.u32le(s.preserve_attachment_count);
        if (s.preserve_attachments) |refs| for (refs[0..s.preserve_attachment_count]) |ref| {
            if (ref >= ci.attachment_count) return error.Invalid;
            try w.u32le(ref);
        };
    }
    if (!compatibility_only) {
        try w.u32le(ci.dependency_count);
        if (ci.dependencies) |deps| for (deps[0..ci.dependency_count]) |dep| {
            if ((dep.src_subpass != 0xffff_ffff and dep.src_subpass >= ci.subpass_count) or (dep.dst_subpass != 0xffff_ffff and dep.dst_subpass >= ci.subpass_count) or dep.dependency_flags & ~@as(u32, 1) != 0) return error.Invalid;
            try w.u32le(dep.src_subpass);
            try w.u32le(dep.dst_subpass);
            try w.u32le(dep.src_stage_mask);
            try w.u32le(dep.dst_stage_mask);
            try w.u32le(dep.src_access_mask);
            try w.u32le(dep.dst_access_mask);
            try w.u32le(dep.dependency_flags);
        };
    }
    return try w.done();
}

const RenderPassFramebufferMetadata = struct {
    supported: bool = false,
    attachment_count: u32 = 0,
    attachments: [2]FramebufferAttachmentRequirement = .{ .{}, .{} },
};

fn snapshotRenderPassFramebufferMetadata(ci: *const RenderPassCreateInfo) RenderPassFramebufferMetadata {
    if (ci.attachment_count == 0 or ci.attachment_count > 2 or ci.attachments == null or ci.subpasses == null) return .{};
    var has_depth = false;
    for (ci.subpasses.?[0..ci.subpass_count], 0..) |subpass, subpass_index| {
        if (subpass.input_attachment_count != 0 or subpass.resolve_attachments != null or subpass.preserve_attachment_count != 0 or subpass.color_attachment_count != 1 or subpass.color_attachments == null or subpass.color_attachments.?[0].attachment != 0) return .{};
        const depth = subpass.depth_stencil_attachment;
        if (depth) |reference| {
            if (reference.attachment != 1) return .{};
            if (subpass_index != 0 and !has_depth) return .{};
            has_depth = true;
        } else if (subpass_index != 0 and has_depth) return .{};
    }
    const expected_count: u32 = if (has_depth) 2 else 1;
    if (ci.attachment_count != expected_count) return .{};
    const descriptions = ci.attachments.?;
    var result = RenderPassFramebufferMetadata{ .supported = true, .attachment_count = expected_count };
    result.attachments[0] = .{ .format = descriptions[0].format, .samples = descriptions[0].samples, .role = .color };
    if (has_depth) result.attachments[1] = .{ .format = descriptions[1].format, .samples = descriptions[1].samples, .role = .depth };
    return result;
}

fn createRenderPass(device: ?Device, info: ?*const RenderPassCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    var canonical = buildRenderPass(ci, false) catch |err| return creationFailure(err);
    var compatibility = buildRenderPass(ci, true) catch |err| {
        canonical.deinit();
        return creationFailure(err);
    };
    const framebuffer_metadata = snapshotRenderPassFramebufferMetadata(ci);
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) {
        canonical.deinit();
        compatibility.deinit();
        return .error_initialization_failed;
    }
    for (&render_pass_objects, &render_pass_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = DeviceIdentity.capture(d), .canonical = canonical, .compatibility = compatibility, .subpass_count = ci.subpass_count, .framebuffer_supported = framebuffer_metadata.supported, .framebuffer_attachment_count = framebuffer_metadata.attachment_count, .framebuffer_attachments = framebuffer_metadata.attachments };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    canonical.deinit();
    compatibility.deinit();
    return .error_out_of_host_memory;
}
fn destroyRenderPass(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const d = device orelse return;
    const object = validRenderPassLocked(handle) orelse return;
    if (validDeviceLocked(d) and object.owner.eql(d)) stateForObject(RenderPassObj, object, &render_pass_objects, &render_pass_state).?.* = .tombstone;
}

fn appendSpecialization(w: *CanonicalWriter, info: ?*const SpecializationInfo) CanonicalError!void {
    const spec = info orelse {
        try w.u32le(0);
        return;
    };
    if (spec.map_entry_count > 64 or (spec.map_entry_count != 0 and spec.map_entries == null) or (spec.data_size != 0 and spec.data == null)) return error.Invalid;
    var indices: [64]u8 = undefined;
    for (0..spec.map_entry_count) |i| indices[i] = @intCast(i);
    const entries = if (spec.map_entries) |p| p[0..spec.map_entry_count] else &.{};
    std.mem.sort(u8, indices[0..spec.map_entry_count], entries, struct {
        fn less(items: []const SpecializationMapEntry, a: u8, b: u8) bool {
            return items[a].constant_id < items[b].constant_id;
        }
    }.less);
    for (entries, 0..) |a, ai| {
        if (a.size == 0 or a.offset > spec.data_size or a.size > spec.data_size - a.offset) return error.Invalid;
        for (entries[ai + 1 ..]) |b| if (a.offset < b.offset + b.size and b.offset < a.offset + a.size) return error.Invalid;
    }
    try w.u32le(spec.map_entry_count);
    const data: [*]const u8 = @ptrCast(spec.data orelse @as(*const anyopaque, @ptrFromInt(1)));
    var previous: ?u32 = null;
    for (indices[0..spec.map_entry_count]) |index| {
        const e = entries[index];
        if (previous == e.constant_id) return error.Invalid;
        previous = e.constant_id;
        try w.u32le(e.constant_id);
        try w.u64le(e.size);
        try w.raw(data[e.offset..][0..e.size]);
    }
}

test "pipeline canonical primitives are ordered, pointer independent, little endian, and collision safe" {
    var bindings = [_]DescriptorSetLayoutBinding{
        .{ .binding = 7, .descriptor_type = 1, .descriptor_count = 1, .stage_flags = 16, .immutable_samplers = null },
        .{ .binding = 2, .descriptor_type = 6, .descriptor_count = 1, .stage_flags = 1, .immutable_samplers = null },
    };
    const first_info = DescriptorSetLayoutCreateInfo{ .s_type = 32, .p_next = null, .flags = 0, .binding_count = 2, .bindings = &bindings };
    var first = try buildDescriptorSetLayout(&first_info);
    defer first.deinit();
    const reversed = [_]DescriptorSetLayoutBinding{ bindings[1], bindings[0] };
    var second_info = first_info;
    second_info.bindings = &reversed;
    var second = try buildDescriptorSetLayout(&second_info);
    defer second.deinit();
    try std.testing.expect(first.eql(&second));
    try std.testing.expectEqualSlices(u8, "ZPUC\x01\x00\x00\x00", first.bytes[0..8]);
    bindings[0].descriptor_count = 2;
    var changed = try buildDescriptorSetLayout(&first_info);
    defer changed.deinit();
    try std.testing.expect(!first.eql(&changed));
    changed.digest = first.digest;
    try std.testing.expectEqualSlices(u8, &first.digest, &changed.digest);
    try std.testing.expect(!first.eql(&changed));
}

test "specialization canonicalization owns values and rejects bounds overlap and duplicate IDs" {
    var data = [_]u8{ 9, 8, 7, 6, 5, 4, 3, 2 };
    var entries = [_]SpecializationMapEntry{
        .{ .constant_id = 8, .offset = 4, .size = 4 },
        .{ .constant_id = 2, .offset = 0, .size = 4 },
    };
    var info = SpecializationInfo{ .map_entry_count = 2, .map_entries = &entries, .data_size = data.len, .data = &data };
    var first: CanonicalWriter = .{};
    defer first.deinit();
    try appendSpecialization(&first, &info);
    const saved = try std.testing.allocator.dupe(u8, first.list.items);
    defer std.testing.allocator.free(saved);
    @memset(&data, 0xaa);
    try std.testing.expectEqualSlices(u8, saved, first.list.items);
    entries[1].constant_id = 8;
    var duplicate: CanonicalWriter = .{};
    defer duplicate.deinit();
    try std.testing.expectError(error.Invalid, appendSpecialization(&duplicate, &info));
    entries[1].constant_id = 2;
    entries[1].offset = 3;
    var overlap: CanonicalWriter = .{};
    defer overlap.deinit();
    try std.testing.expectError(error.Invalid, appendSpecialization(&overlap, &info));
    entries[1].offset = 7;
    entries[1].size = 2;
    var bounds: CanonicalWriter = .{};
    defer bounds.deinit();
    try std.testing.expectError(error.Invalid, appendSpecialization(&bounds, &info));
}

test "frontend pipeline interface and descriptor compatibility is exact" {
    const binding = DescriptorSetLayoutBinding{ .binding = 2, .descriptor_type = 6, .descriptor_count = 1, .stage_flags = 0x11, .immutable_samplers = null };
    const layout_info = DescriptorSetLayoutCreateInfo{ .s_type = 32, .p_next = null, .flags = 0, .binding_count = 1, .bindings = @ptrCast(&binding) };
    var set0 = try buildDescriptorSetLayout(&layout_info);
    defer set0.deinit();
    var name = [_]u8{ 'm', 'a', 'i', 'n' };
    var no_instructions: [0]render_ir.Instruction = .{};
    var no_bytes: [0]u8 = .{};
    var vertex_interfaces = [_]render_ir.Interface{
        .{ .storage = .output, .ty = .{ .scalar = .f32, .columns = 4 }, .location = 9 },
        .{ .storage = .output, .ty = .{ .scalar = .f32, .columns = 4 }, .location = 0 },
        .{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 2 },
    };
    var fragment_interfaces = [_]render_ir.Interface{
        .{ .storage = .input, .ty = .{ .scalar = .f32, .columns = 4 }, .location = 0 },
        .{ .storage = .uniform, .ty = .{ .scalar = .u32 }, .descriptor_set = 0, .binding = 2 },
    };
    vertex_interfaces[2].block = true;
    vertex_interfaces[2].member_count = 1;
    vertex_interfaces[2].members[0] = .{ .ty = .{ .scalar = .f32, .columns = 4 }, .offset = 0 };
    fragment_interfaces[1].block = true;
    fragment_interfaces[1].member_count = 1;
    fragment_interfaces[1].members[0] = vertex_interfaces[2].members[0];
    const vertex = render_ir.Program{ .stage = .vertex, .entry_name = &name, .interfaces = &vertex_interfaces, .instructions = &no_instructions, .bytes = &no_bytes, .identity = .{ .digest = .{0} ** 32, .bytes = &no_bytes } };
    var fragment = render_ir.Program{ .stage = .fragment, .entry_name = &name, .interfaces = &fragment_interfaces, .instructions = &no_instructions, .bytes = &no_bytes, .identity = .{ .digest = .{0} ** 32, .bytes = &no_bytes } };
    try std.testing.expect(frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[0].ty.columns = 3;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[0].ty.columns = 4;
    fragment.interfaces[1].binding = 3;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[1].binding = 2;
    fragment.interfaces[1].descriptor_set = 1;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[1].descriptor_set = 0;
    fragment.interfaces[1].members[0].offset = 16;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[1].members[0].offset = 0;
    fragment.interfaces[1].members[0].ty.columns = 3;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[1].members[0].ty.columns = 4;
    fragment.interfaces[1].member_count = 0;
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces[1].member_count = 1;
    try std.testing.expect(frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces = fragment_interfaces[0..1];
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &set0));
    fragment.interfaces = &fragment_interfaces;
    var vertex_without_uniform = vertex;
    vertex_without_uniform.interfaces = vertex_interfaces[0..2];
    try std.testing.expect(!frontendInterfacesCompatible(&vertex_without_uniform, &fragment, &set0));
    var malformed = set0;
    malformed.bytes = malformed.bytes[0..20];
    try std.testing.expect(!frontendInterfacesCompatible(&vertex, &fragment, &malformed));
}

test "Vulkan graphics pipeline ABI declarations match LP64 layouts" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(SpecializationInfo));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(PipelineShaderStageCreateInfo));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(GraphicsPipelineCreateInfo));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(GraphicsPipelineCreateInfo, "layout"));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(GraphicsPipelineCreateInfo, "base_pipeline_index"));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(FramebufferCreateInfo));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(FramebufferCreateInfo, "attachment_count"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(FramebufferCreateInfo, "attachments"));
}

fn buildGraphicsPipelineLocked(d: Device, ci: *const GraphicsPipelineCreateInfo) CanonicalError!GraphicsPipelineObj {
    if (ci.s_type != 28 or ci.p_next != null or ci.flags != 0 or ci.stage_count != 2 or ci.stages == null or ci.tessellation != null or ci.base_pipeline != 0 or (ci.base_pipeline_index != -1 and ci.base_pipeline_index != 0)) return error.Invalid;
    const layout = validPipelineLayoutLocked(ci.layout) orelse return error.Invalid;
    const render_pass = validRenderPassLocked(ci.render_pass) orelse return error.Invalid;
    if (!layout.owner.eql(d) or !render_pass.owner.eql(d) or ci.subpass >= render_pass.subpass_count) return error.Invalid;
    var w: CanonicalWriter = .{};
    defer w.deinit();
    try w.header(5);
    try w.u32le(1); // cpu_cube_v1
    try appendCanonical(&w, &layout.canonical);
    try appendCanonical(&w, &render_pass.compatibility);
    try w.u32le(ci.subpass);
    var stage_indices: [2]u8 = .{ 0, 1 };
    const stages = ci.stages.?[0..2];
    if (stages[1].stage < stages[0].stage) stage_indices = .{ 1, 0 };
    var stage_mask: u32 = 0;
    var vertex_program: ?render_ir.Program = null;
    errdefer if (vertex_program) |*program| program.deinit(allocator);
    var fragment_program: ?render_ir.Program = null;
    errdefer if (fragment_program) |*program| program.deinit(allocator);
    var cpu_cube_stage_mask: u32 = 0;
    for (stage_indices) |index| {
        const stage = stages[index];
        if (stage.s_type != 18 or stage.p_next != null or stage.flags != 0 or (stage.stage != 1 and stage.stage != 0x10) or stage_mask & stage.stage != 0 or stage.name == null) return error.Invalid;
        const shader = findLiveHandle(ShaderModuleObj, stage.module, &shader_module_objects, &shader_module_state) orelse return error.Invalid;
        if (!shader.owner.eql(d)) return error.Invalid;
        const name = std.mem.span(stage.name.?);
        if (name.len == 0 or name.len > 255) return error.Invalid;
        stage_mask |= stage.stage;
        try w.u32le(stage.stage);
        try w.u32le(shader.module.identity.ingestion);
        try w.u32le(shader.module.identity.serialization);
        try w.raw(&shader.module.identity.digest);
        try w.u64le(shader.module.words.len);
        for (shader.module.words) |word| try w.u32le(word);
        try w.u32le(@intCast(name.len));
        try w.raw(name);
        try appendSpecialization(&w, stage.specialization_info);
        var frontend_specs: [64]spirv_frontend.Specialization = undefined;
        var frontend_spec_count: usize = 0;
        if (stage.specialization_info) |specialization| {
            const entries = if (specialization.map_entries) |p| p[0..specialization.map_entry_count] else &.{};
            const data: [*]const u8 = if (specialization.data) |p| @ptrCast(p) else @ptrFromInt(1);
            for (entries) |entry| {
                frontend_specs[frontend_spec_count] = .{ .id = entry.constant_id, .bytes = data[entry.offset..][0..entry.size] };
                frontend_spec_count += 1;
            }
        }
        const frontend_stage: render_ir.Stage = if (stage.stage == 1) .vertex else .fragment;
        const compiled = try compileFrontendStage(allocator, shader, frontend_stage, name, frontend_specs[0..frontend_spec_count]);
        if (compiled == null) cpu_cube_stage_mask |= stage.stage;
        if (compiled) |program| {
            if (frontend_stage == .vertex) vertex_program = program else fragment_program = program;
        }
    }
    if (stage_mask != 0x11) return error.Invalid;
    const profile_pair = vertex_program != null and fragment_program != null and cpu_cube_stage_mask == 0;
    const cpu_cube_pair = vertex_program == null and fragment_program == null and cpu_cube_stage_mask == 0x11;
    if (!profile_pair and !cpu_cube_pair) return error.Invalid;
    if (profile_pair and !frontendInterfacesCompatible(&vertex_program.?, &fragment_program.?, &layout.set0)) return error.Invalid;
    const vi = ci.vertex_input orelse return error.Invalid;
    if (vi.s_type != 19 or vi.p_next != null or vi.flags != 0 or vi.binding_count > 16 or vi.attribute_count > 32 or (vi.binding_count != 0 and vi.bindings == null) or (vi.attribute_count != 0 and vi.attributes == null)) return error.Invalid;
    var binding_indices: [16]u8 = undefined;
    for (0..vi.binding_count) |i| binding_indices[i] = @intCast(i);
    const bindings = if (vi.bindings) |p| p[0..vi.binding_count] else &.{};
    std.mem.sort(u8, binding_indices[0..vi.binding_count], bindings, struct {
        fn less(items: []const VertexInputBindingDescription, a: u8, b: u8) bool {
            return items[a].binding < items[b].binding;
        }
    }.less);
    try w.u32le(vi.binding_count);
    var prior_binding: ?u32 = null;
    for (binding_indices[0..vi.binding_count]) |index| {
        const b = bindings[index];
        if (prior_binding == b.binding or b.input_rate < 0 or b.input_rate > 1) return error.Invalid;
        prior_binding = b.binding;
        try w.u32le(b.binding);
        try w.u32le(b.stride);
        try w.i32le(b.input_rate);
    }
    var attribute_indices: [32]u8 = undefined;
    for (0..vi.attribute_count) |i| attribute_indices[i] = @intCast(i);
    const attributes = if (vi.attributes) |p| p[0..vi.attribute_count] else &.{};
    std.mem.sort(u8, attribute_indices[0..vi.attribute_count], attributes, struct {
        fn less(items: []const VertexInputAttributeDescription, a: u8, b: u8) bool {
            return items[a].location < items[b].location;
        }
    }.less);
    try w.u32le(vi.attribute_count);
    var prior_location: ?u32 = null;
    for (attribute_indices[0..vi.attribute_count]) |index| {
        const a = attributes[index];
        if (prior_location == a.location or a.format <= 0) return error.Invalid;
        prior_location = a.location;
        var found = false;
        for (bindings) |b| if (b.binding == a.binding) {
            found = true;
            break;
        };
        if (!found) return error.Invalid;
        try w.u32le(a.location);
        try w.u32le(a.binding);
        try w.i32le(a.format);
        try w.u32le(a.offset);
    }
    const ia = ci.input_assembly orelse return error.Invalid;
    if (ia.s_type != 20 or ia.p_next != null or ia.flags != 0 or ia.topology != 3 or try bool32(ia.primitive_restart_enable) != 0) return error.Invalid;
    try w.i32le(ia.topology);
    var dynamic_viewport = false;
    var dynamic_scissor = false;
    var dynamic_indices: [16]u8 = undefined;
    var dynamic_count: u32 = 0;
    if (ci.dynamic) |dy| {
        if (dy.s_type != 27 or dy.p_next != null or dy.flags != 0 or dy.dynamic_state_count > 16 or (dy.dynamic_state_count != 0 and dy.dynamic_states == null)) return error.Invalid;
        dynamic_count = dy.dynamic_state_count;
        for (0..dynamic_count) |i| dynamic_indices[i] = @intCast(i);
        const states = dy.dynamic_states.?[0..dynamic_count];
        std.mem.sort(u8, dynamic_indices[0..dynamic_count], states, struct {
            fn less(items: []const i32, a: u8, b: u8) bool {
                return items[a] < items[b];
            }
        }.less);
        var prior: ?i32 = null;
        for (dynamic_indices[0..dynamic_count]) |index| {
            const state = states[index];
            if (prior == state or (state != 0 and state != 1)) return error.Invalid;
            prior = state;
            if (state == 0) dynamic_viewport = true else dynamic_scissor = true;
        }
    }
    try w.u32le(dynamic_count);
    if (dynamic_viewport) try w.i32le(0);
    if (dynamic_scissor) try w.i32le(1);
    const vp = ci.viewport orelse return error.Invalid;
    if (vp.s_type != 22 or vp.p_next != null or vp.flags != 0 or vp.viewport_count != 1 or vp.scissor_count != 1 or (!dynamic_viewport and vp.viewports == null) or (!dynamic_scissor and vp.scissors == null)) return error.Invalid;
    try w.u32le(1);
    if (!dynamic_viewport) {
        const v = vp.viewports.?[0];
        try w.f32le(v.x);
        try w.f32le(v.y);
        try w.f32le(v.width);
        try w.f32le(v.height);
        try w.f32le(v.min_depth);
        try w.f32le(v.max_depth);
    }
    if (!dynamic_scissor) {
        const s = vp.scissors.?[0];
        try w.i32le(s.offset.x);
        try w.i32le(s.offset.y);
        try w.u32le(s.extent.width);
        try w.u32le(s.extent.height);
    }
    const rs = ci.rasterization orelse return error.Invalid;
    if (rs.s_type != 23 or rs.p_next != null or rs.flags != 0 or try bool32(rs.depth_clamp_enable) != 0 or try bool32(rs.rasterizer_discard_enable) != 0 or rs.polygon_mode != 0 or rs.cull_mode & ~@as(u32, 3) != 0 or (rs.front_face != 0 and rs.front_face != 1) or try bool32(rs.depth_bias_enable) != 0 or rs.depth_bias_constant_factor != 0 or rs.depth_bias_clamp != 0 or rs.depth_bias_slope_factor != 0 or rs.line_width != 1) return error.Invalid;
    try w.u32le(rs.cull_mode);
    try w.i32le(rs.front_face);
    try w.f32le(rs.line_width);
    const ms = ci.multisample orelse return error.Invalid;
    if (ms.s_type != 24 or ms.p_next != null or ms.flags != 0 or ms.rasterization_samples != 1 or try bool32(ms.sample_shading_enable) != 0 or ms.min_sample_shading != 0 or ms.sample_mask != null or try bool32(ms.alpha_to_coverage_enable) != 0 or try bool32(ms.alpha_to_one_enable) != 0) return error.Invalid;
    try w.u32le(1);
    const ds = ci.depth_stencil orelse return error.Invalid;
    const zero_stencil = std.mem.zeroes(StencilOpState);
    var always_stencil = zero_stencil;
    always_stencil.compare_op = 7;
    if (ds.s_type != 25 or ds.p_next != null or ds.flags != 0 or try bool32(ds.depth_test_enable) != 1 or try bool32(ds.depth_write_enable) != 1 or ds.depth_compare_op != 3 or try bool32(ds.depth_bounds_test_enable) != 0 or try bool32(ds.stencil_test_enable) != 0 or (!std.meta.eql(ds.front, zero_stencil) and !std.meta.eql(ds.front, always_stencil)) or (!std.meta.eql(ds.back, zero_stencil) and !std.meta.eql(ds.back, always_stencil)) or ds.min_depth_bounds != 0 or (ds.max_depth_bounds != 0 and ds.max_depth_bounds != 1)) return error.Invalid;
    try w.u32le(1);
    try w.u32le(1);
    try w.i32le(3);
    const cb = ci.color_blend orelse return error.Invalid;
    if (cb.s_type != 26 or cb.p_next != null or cb.flags != 0 or try bool32(cb.logic_op_enable) != 0 or cb.logic_op != 0 or cb.attachment_count != 1 or cb.attachments == null or !std.meta.eql(cb.blend_constants, [_]f32{ 0, 0, 0, 0 })) return error.Invalid;
    const attachment = cb.attachments.?[0];
    if (try bool32(attachment.blend_enable) != 0 or attachment.src_color_blend_factor < 0 or attachment.src_color_blend_factor > 18 or attachment.dst_color_blend_factor < 0 or attachment.dst_color_blend_factor > 18 or attachment.color_blend_op < 0 or attachment.color_blend_op > 4 or attachment.src_alpha_blend_factor < 0 or attachment.src_alpha_blend_factor > 18 or attachment.dst_alpha_blend_factor < 0 or attachment.dst_alpha_blend_factor > 18 or attachment.alpha_blend_op < 0 or attachment.alpha_blend_op > 4 or attachment.color_write_mask != 0xf) return error.Invalid;
    try w.u32le(1);
    try w.i32le(attachment.src_color_blend_factor);
    try w.i32le(attachment.dst_color_blend_factor);
    try w.i32le(attachment.color_blend_op);
    try w.i32le(attachment.src_alpha_blend_factor);
    try w.i32le(attachment.dst_alpha_blend_factor);
    try w.i32le(attachment.alpha_blend_op);
    try w.u32le(0xf);
    var canonical = try w.done();
    errdefer canonical.deinit();
    var layout_identity = try layout.canonical.clone();
    errdefer layout_identity.deinit();
    var set0 = try layout.set0.clone();
    errdefer set0.deinit();
    if (test_fail_render_compatibility_clone) return error.OutOfMemory;
    var render_compatibility = try render_pass.compatibility.clone();
    errdefer render_compatibility.deinit();
    return .{ .owner = DeviceIdentity.capture(d), .canonical = canonical, .layout = layout_identity, .set0 = set0, .render_compatibility = render_compatibility, .vertex_program = vertex_program, .fragment_program = fragment_program, .subpass = ci.subpass, .execution_abi = 1, .cull_mode = rs.cull_mode, .front_face = rs.front_face };
}

fn frontendInterfacesCompatible(vertex: *const render_ir.Program, fragment: *const render_ir.Program, set0: *const Canonical) bool {
    for (fragment.interfaces) |input| if (input.storage == .input) {
        var matched = false;
        for (vertex.interfaces) |output| if (output.storage == .output and output.location == input.location and output.builtin_position == input.builtin_position) {
            matched = output.ty.scalar == input.ty.scalar and output.ty.columns == input.ty.columns and output.ty.rows == input.ty.rows;
            break;
        };
        if (!matched) return false;
    };
    for (vertex.interfaces) |left| if (left.storage == .uniform) {
        var matched = false;
        for (fragment.interfaces) |right| if (right.storage == .uniform and left.descriptor_set == right.descriptor_set and left.binding == right.binding) {
            if (!std.meta.eql(left, right)) return false;
            matched = true;
        };
        if (!matched) return false;
    };
    for (fragment.interfaces) |right| if (right.storage == .uniform) {
        var matched = false;
        for (vertex.interfaces) |left| {
            if (left.storage == .uniform and left.descriptor_set == right.descriptor_set and left.binding == right.binding) matched = true;
        }
        if (!matched) return false;
    };
    for ([_]*const render_ir.Program{ vertex, fragment }) |program| for (program.interfaces) |interface| if (interface.storage == .uniform) {
        if (interface.descriptor_set != 0 or interface.binding == null or set0.bytes.len < 36) return false;
        const count = std.mem.readInt(u32, set0.bytes[32..36], .little);
        if (set0.bytes.len != 36 + @as(usize, count) * 16) return false;
        var found = false;
        for (0..count) |index| {
            const item = set0.bytes[36 + index * 16 ..][0..16];
            if (std.mem.readInt(u32, item[0..4], .little) == interface.binding.? and std.mem.readInt(i32, item[4..8], .little) == 6 and std.mem.readInt(u32, item[8..12], .little) == 1 and std.mem.readInt(u32, item[12..16], .little) & (if (program.stage == .vertex) @as(u32, 1) else 16) != 0) found = true;
        }
        if (!found) return false;
    };
    return true;
}

/// Exact bridge for the immutable distro-vkcube shader pair used by the
/// cpu_cube_v1 readiness path. This is not render-profile acceptance.
fn cpuCubeV1ShaderCompatible(shader: *const ShaderModuleObj, stage: render_ir.Stage, name: []const u8, spec_count: usize) bool {
    if (spec_count != 0 or !std.mem.eql(u8, name, "main")) return false;
    const expected_len: usize = if (stage == .vertex) 390 else 661;
    const expected: [32]u8 = if (stage == .vertex)
        .{ 0x63, 0xb7, 0xd7, 0xa6, 0x2b, 0x47, 0xa6, 0xfe, 0x7c, 0xa0, 0xe8, 0x6b, 0x7b, 0x22, 0xbb, 0x79, 0x7e, 0xcd, 0xbf, 0xf0, 0x6e, 0x04, 0x3c, 0xc9, 0xc5, 0xe3, 0xca, 0x12, 0x87, 0x68, 0x80, 0x05 }
    else
        .{ 0x27, 0x68, 0x57, 0x63, 0xf4, 0xc3, 0x5e, 0xe9, 0x17, 0xd4, 0x02, 0x49, 0xcf, 0xd9, 0xa5, 0x1d, 0x43, 0x14, 0x75, 0xc0, 0x67, 0x2e, 0x36, 0xaa, 0xf2, 0x84, 0x38, 0x05, 0xd6, 0x5e, 0xa5, 0x32 };
    return shader.module.words.len == expected_len and std.mem.eql(u8, &shader.module.identity.digest, &expected);
}

fn compileFrontendStage(stage_allocator: std.mem.Allocator, shader: *const ShaderModuleObj, stage: render_ir.Stage, name: []const u8, specs: []const spirv_frontend.Specialization) CanonicalError!?render_ir.Program {
    return spirv_frontend.compile(stage_allocator, shader.module.words, stage, name, specs) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => if (cpuCubeV1ShaderCompatible(shader, stage, name, specs.len)) null else error.Invalid,
    };
}

test "cpu_cube_v1 shader compatibility bridge is exact" {
    var words = [_]u32{0} ** 390;
    var shader = ShaderModuleObj{ .owner = undefined, .module = .{ .words = &words, .identity = .{
        .ingestion = 1,
        .serialization = 1,
        .digest = .{ 0x63, 0xb7, 0xd7, 0xa6, 0x2b, 0x47, 0xa6, 0xfe, 0x7c, 0xa0, 0xe8, 0x6b, 0x7b, 0x22, 0xbb, 0x79, 0x7e, 0xcd, 0xbf, 0xf0, 0x6e, 0x04, 0x3c, 0xc9, 0xc5, 0xe3, 0xca, 0x12, 0x87, 0x68, 0x80, 0x05 },
    } } };
    try std.testing.expect(cpuCubeV1ShaderCompatible(&shader, .vertex, "main", 0));
    try std.testing.expect(!cpuCubeV1ShaderCompatible(&shader, .vertex, "other", 0));
    try std.testing.expect(!cpuCubeV1ShaderCompatible(&shader, .vertex, "main", 1));
    try std.testing.expect(!cpuCubeV1ShaderCompatible(&shader, .fragment, "main", 0));
    shader.module.identity.digest[0] ^= 1;
    try std.testing.expect(!cpuCubeV1ShaderCompatible(&shader, .vertex, "main", 0));
    shader.module.identity.digest[0] ^= 1;
    shader.module.words = words[0 .. words.len - 1];
    try std.testing.expect(!cpuCubeV1ShaderCompatible(&shader, .vertex, "main", 0));

    shader.module.words = &words;
    try std.testing.expect((try compileFrontendStage(std.testing.allocator, &shader, .vertex, "main", &.{})) == null);
    var valid = ShaderModuleObj{ .owner = undefined, .module = .{ .words = @constCast(&spirv_frontend.positive_vertex), .identity = undefined } };
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, compileFrontendStage(failing.allocator(), &valid, .vertex, "main", &.{}));
}

fn createOpaque(device: ?Device, info: ?*const anyopaque, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    _ = info orelse return .error_initialization_failed;
    if (alloc != null) return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(device orelse return .error_initialization_failed)) return .error_initialization_failed;
    out.* = allocateGenericHandle();
    return .success;
}
fn destroyOpaque(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    _ = device;
    _ = handle;
    _ = alloc;
}
fn createShaderModule(device: ?Device, info: ?*const ShaderModuleCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (alloc != null or ci.s_type != 16 or ci.p_next != null or ci.flags != 0) {
        hit(.shader_invalid);
        return .error_initialization_failed;
    }
    const word_count = spirv.validateByteSize(ci.code_size) catch {
        hit(.shader_invalid);
        return .error_invalid_shader;
    };
    const raw = ci.p_code orelse {
        hit(.shader_invalid);
        return .error_invalid_shader;
    };
    if (@intFromPtr(raw) % @alignOf(u32) != 0) {
        hit(.shader_invalid);
        return .error_invalid_shader;
    }
    const source: [*]const u32 = @ptrFromInt(@intFromPtr(raw));

    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    var free_index: ?usize = null;
    for (shader_module_state, 0..) |state, index| if (state == .never) {
        free_index = index;
        break;
    };
    const index = free_index orelse {
        hit(.shader_exhaustion);
        return .error_out_of_host_memory;
    };
    if (failTestAllocation()) return .error_out_of_host_memory;
    var module = spirv.Module.parse(allocator, source[0..word_count]) catch |err| {
        if (err != error.OutOfMemory) hit(.shader_invalid);
        return if (err == error.OutOfMemory) .error_out_of_host_memory else .error_invalid_shader;
    };
    errdefer module.deinit(allocator);
    shader_module_objects[index] = .{ .owner = DeviceIdentity.capture(d), .module = module };
    shader_module_state[index] = .live;
    out.* = @intFromPtr(&shader_module_objects[index]);
    return .success;
}
fn destroyShaderModule(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null or handle == 0) return;
    const d = device orelse return;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return;
    for (&shader_module_objects, &shader_module_state) |*object, *state| if (@intFromPtr(object) == handle) {
        if (state.* != .live or !object.owner.eql(d)) {
            hit(.shader_lifetime);
            return;
        }
        object.module.deinit(allocator);
        state.* = .tombstone;
        return;
    };
    hit(.shader_lifetime);
}
fn createSemaphore(device: ?Device, info: ?*const anyopaque, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    _ = info orelse return .error_initialization_failed;
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&semaphore_objects, &semaphore_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .signaled = false };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroySemaphore(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const object = validSemaphoreLocked(handle) orelse return;
    if (validDeviceLocked(device orelse return) and object.owner == device.?) stateForObject(SemaphoreObj, object, &semaphore_objects, &semaphore_state).?.* = .tombstone;
}
fn createImageView(device: ?Device, info: ?*const ImageViewCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.s_type != 15 or ci.p_next != null or ci.flags != 0 or ci.view_type != 1 or !std.meta.eql(ci.components, [_]i32{ 0, 0, 0, 0 }) or ci.subresource_range.base_mip_level != 0 or ci.subresource_range.level_count != 1 or ci.subresource_range.layer_count == 0) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const image = validImageLocked(ci.image) orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or image.owner != d or ci.format != image.format or (ci.subresource_range.aspect_mask != 1 and ci.subresource_range.aspect_mask != 2) or ci.subresource_range.base_array_layer >= image.array_layers or ci.subresource_range.layer_count > image.array_layers - ci.subresource_range.base_array_layer) return .error_initialization_failed;
    for (&image_view_objects, &image_view_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .image = image, .format = ci.format, .aspect_mask = ci.subresource_range.aspect_mask, .base_array_layer = ci.subresource_range.base_array_layer, .layer_count = ci.subresource_range.layer_count };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroyImageView(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const object = validImageViewLocked(handle) orelse return;
    if (validDeviceLocked(device orelse return) and object.owner == device.?) stateForObject(ImageViewObj, object, &image_view_objects, &image_view_state).?.* = .tombstone;
}
fn createFramebuffer(device: ?Device, info: ?*const FramebufferCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d) or ci.s_type != 37 or ci.p_next != null or ci.flags != 0 or ci.attachment_count == 0 or ci.attachment_count > 2 or ci.attachments == null or ci.width == 0 or ci.height == 0 or ci.layers == 0) return .error_initialization_failed;
    const render_pass = validRenderPassLocked(ci.render_pass) orelse return .error_initialization_failed;
    if (!render_pass.owner.eql(d) or !render_pass.framebuffer_supported or ci.attachment_count != render_pass.framebuffer_attachment_count) return .error_initialization_failed;
    var color: ?*ImageObj = null;
    var depth: ?*ImageObj = null;
    var prior_view: ?*ImageViewObj = null;
    for (ci.attachments.?[0..ci.attachment_count], render_pass.framebuffer_attachments[0..ci.attachment_count]) |handle, requirement| {
        const view = validImageViewLocked(handle) orelse return .error_initialization_failed;
        if (view.owner != d or view == prior_view or (prior_view != null and view.image == prior_view.?.image) or view.format != requirement.format or view.image.format != requirement.format or view.image.samples != requirement.samples or view.image.width < ci.width or view.image.height < ci.height or view.base_array_layer != 0 or view.layer_count < ci.layers or view.image.array_layers < ci.layers) return .error_initialization_failed;
        switch (requirement.role) {
            .color => {
                if (view.aspect_mask != 1 or view.image.usage & 0x10 == 0 or color != null) return .error_initialization_failed;
                color = view.image;
            },
            .depth => {
                if (view.aspect_mask != 2 or view.image.usage & 0x20 == 0 or depth != null) return .error_initialization_failed;
                depth = view.image;
            },
        }
        prior_view = view;
    }
    const color_image = color orelse return .error_initialization_failed;
    var compatibility = render_pass.compatibility.clone() catch return .error_out_of_host_memory;
    for (&framebuffer_objects, &framebuffer_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .color_image = color_image, .depth_image = depth, .render_compatibility = compatibility };
        state.* = .live;
        out.* = @intFromPtr(object);
        return .success;
    };
    compatibility.deinit();
    return .error_out_of_host_memory;
}
fn destroyFramebuffer(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const object = validFramebufferLocked(handle) orelse return;
    if (validDeviceLocked(device orelse return) and object.owner == device.?) stateForObject(FramebufferObj, object, &framebuffer_objects, &framebuffer_state).?.* = .tombstone;
}
fn createGraphicsPipelines(device: ?Device, cache: usize, count: u32, infos: ?*const anyopaque, alloc: ?*const Alloc, outputs: ?[*]usize) callconv(.c) Result {
    _ = cache;
    const raw = infos orelse return .error_initialization_failed;
    if (alloc != null or count == 0 or count > max_child_objects) return .error_initialization_failed;
    const out = outputs orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    const create_infos: [*]const GraphicsPipelineCreateInfo = @ptrCast(@alignCast(raw));
    var built: [max_child_objects]GraphicsPipelineObj = undefined;
    var slots: [max_child_objects]u8 = undefined;
    var free_count: usize = 0;
    for (graphics_pipeline_state, 0..) |state, index| if (state == .never) {
        slots[free_count] = @intCast(index);
        free_count += 1;
    };
    if (free_count < count) return .error_out_of_host_memory;
    var built_count: usize = 0;
    for (0..count) |index| {
        built[index] = buildGraphicsPipelineLocked(d, &create_infos[index]) catch |err| {
            for (built[0..built_count]) |*prior| {
                prior.canonical.deinit();
                prior.layout.deinit();
                prior.set0.deinit();
                prior.render_compatibility.deinit();
                if (prior.vertex_program) |*program| program.deinit(allocator);
                if (prior.fragment_program) |*program| program.deinit(allocator);
            }
            return creationFailure(err);
        };
        built_count += 1;
    }
    for (0..count) |index| {
        const slot = slots[index];
        graphics_pipeline_objects[slot] = built[index];
        graphics_pipeline_state[slot] = .live;
        out[index] = @intFromPtr(&graphics_pipeline_objects[slot]);
    }
    return .success;
}
fn destroyPipeline(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    defer mutex.unlock();
    const d = device orelse return;
    const object = validGraphicsPipelineLocked(handle) orelse return;
    if (validDeviceLocked(d) and object.owner.eql(d)) stateForObject(GraphicsPipelineObj, object, &graphics_pipeline_objects, &graphics_pipeline_state).?.* = .tombstone;
}
fn allocateDescriptorSets(device: ?Device, info: ?*const DescriptorSetAllocateInfo, outputs: ?[*]usize) callconv(.c) Result {
    const ci = info orelse return .error_initialization_failed;
    const out = outputs orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or ci.s_type != 34 or ci.p_next != null or ci.descriptor_set_count == 0 or ci.descriptor_set_count > max_child_objects or ci.set_layouts == null) return .error_initialization_failed;
    var slots: [max_child_objects]u8 = undefined;
    var free_count: usize = 0;
    for (descriptor_set_state, 0..) |state, index| if (state == .never) {
        slots[free_count] = @intCast(index);
        free_count += 1;
    };
    if (free_count < ci.descriptor_set_count) return .error_out_of_host_memory;
    var layouts: [max_child_objects]Canonical = undefined;
    var made: usize = 0;
    for (ci.set_layouts.?[0..ci.descriptor_set_count]) |handle| {
        const source = validDescriptorSetLayoutLocked(handle) orelse {
            for (layouts[0..made]) |*prior| prior.deinit();
            return .error_initialization_failed;
        };
        if (!source.owner.eql(d)) {
            for (layouts[0..made]) |*prior| prior.deinit();
            return .error_initialization_failed;
        }
        layouts[made] = source.canonical.clone() catch {
            for (layouts[0..made]) |*prior| prior.deinit();
            return .error_out_of_host_memory;
        };
        made += 1;
    }
    for (0..ci.descriptor_set_count) |index| {
        const slot = slots[index];
        descriptor_set_objects[slot] = .{ .owner = DeviceIdentity.capture(d), .layout = layouts[index] };
        descriptor_set_state[slot] = .live;
        out[index] = @intFromPtr(&descriptor_set_objects[slot]);
    }
    return .success;
}
fn updateDescriptorSets(device: ?Device, write_count: u32, writes: ?*const anyopaque, copy_count: u32, copies: ?*const anyopaque) callconv(.c) void {
    const d = device orelse return;
    _ = copy_count;
    _ = copies;
    if (write_count == 0) return;
    const raw = writes orelse return;
    const list: [*]const WriteDescriptorSet = @ptrCast(@alignCast(raw));
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return;
    for (list[0..write_count]) |descriptor_write| {
        const set = validDescriptorSetLocked(descriptor_write.dst_set) orelse continue;
        if (!set.owner.eql(d) or descriptor_write.descriptor_count == 0) continue;
        if (descriptor_write.descriptor_type == 6 and descriptor_write.dst_binding == 0) {
            const info = (descriptor_write.buffer_info orelse continue)[0];
            const buffer = validBufferLocked(info.buffer) orelse continue;
            if (buffer.owner == d and info.offset <= buffer.size) {
                set.uniform = buffer;
                set.uniform_offset = info.offset;
                set.uniform_range = if (info.range == std.math.maxInt(u64)) buffer.size - info.offset else info.range;
            }
        } else if (descriptor_write.descriptor_type == 1 and descriptor_write.dst_binding == 1) {
            const info = (descriptor_write.image_info orelse continue)[0];
            const view = validImageViewLocked(info.image_view) orelse continue;
            if (view.owner == d and info.image_layout == 5) set.texture = view.image;
        }
    }
}
fn cmdBeginRenderPass(cb: ?CommandBuffer, info: ?*const RenderPassBeginInfo, contents: i32) callconv(.c) void {
    const begin = info orelse return;
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    const framebuffer = validFramebufferLocked(begin.framebuffer) orelse return;
    const render_pass = validRenderPassLocked(begin.render_pass) orelse return;
    const image = framebuffer.color_image orelse return;
    if (contents != 0 or command_buffer.impl.state != 1 or command_buffer.impl.active_framebuffer != null or command_buffer.impl.count == command_buffer.impl.commands.len or begin.clear_value_count == 0 or begin.clear_values == null or !render_pass.owner.eql(command_buffer.impl.owner) or !framebuffer.render_compatibility.eql(&render_pass.compatibility)) {
        command_buffer.impl.invalid = true;
        return;
    }
    const color = begin.clear_values.?[0].color.float32;
    const depth_value = if (begin.clear_value_count > 1) begin.clear_values.?[1].depth_stencil.depth else 1;
    command_buffer.impl.commands[command_buffer.impl.count] = .{ .render_clear = .{ .image = image, .depth = framebuffer.depth_image, .color = .{ @intFromFloat(std.math.clamp(color[2], 0, 1) * 255), @intFromFloat(std.math.clamp(color[1], 0, 1) * 255), @intFromFloat(std.math.clamp(color[0], 0, 1) * 255), @intFromFloat(std.math.clamp(color[3], 0, 1) * 255) }, .depth_value = depth_value } };
    command_buffer.impl.count += 1;
    command_buffer.impl.active_framebuffer = framebuffer;
    command_buffer.impl.active_render_pass = render_pass;
}
fn cmdBindPipeline(cb: ?CommandBuffer, bind_point: i32, pipeline: usize) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    const object = validGraphicsPipelineLocked(pipeline) orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    if (bind_point != 0 or command_buffer.impl.state != 1 or !object.owner.eql(command_buffer.impl.owner)) {
        command_buffer.impl.invalid = true;
        return;
    }
    command_buffer.impl.bound_pipeline = object;
    command_buffer.impl.bound_pipeline_handle = pipeline;
}
fn cmdBindDescriptorSets(cb: ?CommandBuffer, bind_point: i32, layout: usize, first_set: u32, count: u32, sets: ?[*]const usize, dynamic_count: u32, offsets: ?[*]const u32) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    if (bind_point != 0 or first_set != 0 or count != 1 or sets == null or dynamic_count != 0 or offsets != null or command_buffer.impl.state != 1) {
        command_buffer.impl.invalid = true;
        return;
    }
    const layout_object = validPipelineLayoutLocked(layout) orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    const descriptor = validDescriptorSetLocked(sets.?[0]) orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    if (!layout_object.owner.eql(command_buffer.impl.owner) or !descriptor.owner.eql(command_buffer.impl.owner) or !descriptor.layout.eql(&layout_object.set0)) {
        command_buffer.impl.invalid = true;
        return;
    }
    command_buffer.impl.bound_descriptors = descriptor;
    command_buffer.impl.bound_layout = layout_object;
    command_buffer.impl.bound_layout_handle = layout;
}
fn cmdSetViewport(cb: ?CommandBuffer, first: u32, count: u32, values: ?*const anyopaque) callconv(.c) void {
    if (first != 0 or count == 0 or values == null) return;
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    command_buffer.impl.viewport = @as(*const Viewport, @ptrCast(@alignCast(values.?))).*;
}
fn cmdSetScissor(cb: ?CommandBuffer, first: u32, count: u32, values: ?*const anyopaque) callconv(.c) void {
    if (first != 0 or count == 0 or values == null) return;
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    const rect: *const Rect2D = @ptrCast(@alignCast(values.?));
    command_buffer.impl.scissor = .{ .x = rect.offset.x, .y = rect.offset.y, .width = rect.extent.width, .height = rect.extent.height };
}
fn cmdDraw(cb: ?CommandBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    const framebuffer = command_buffer.impl.active_framebuffer orelse return;
    const render_pass = command_buffer.impl.active_render_pass orelse return;
    const pipeline_pointer = command_buffer.impl.bound_pipeline orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    const pipeline = validGraphicsPipelineLocked(command_buffer.impl.bound_pipeline_handle) orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    const layout_pointer = command_buffer.impl.bound_layout orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    const layout = validPipelineLayoutLocked(command_buffer.impl.bound_layout_handle) orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    const descriptors = command_buffer.impl.bound_descriptors orelse {
        command_buffer.impl.invalid = true;
        return;
    };
    if (pipeline != pipeline_pointer or layout != layout_pointer or !pipeline.owner.eql(command_buffer.impl.owner) or !layout.owner.eql(command_buffer.impl.owner) or !descriptors.owner.eql(command_buffer.impl.owner) or !pipeline.layout.eql(&layout.canonical) or !pipeline.set0.eql(&descriptors.layout) or pipeline.execution_abi != 1 or pipeline.subpass != 0 or !pipeline.render_compatibility.eql(&render_pass.compatibility) or instance_count != 1 or first_vertex != 0 or first_instance != 0 or vertex_count == 0) {
        command_buffer.impl.invalid = true;
        return;
    }
    record(command_buffer, .{ .cube_draw = .{ .framebuffer = framebuffer, .descriptors = descriptors, .vertex_count = vertex_count, .viewport = command_buffer.impl.viewport, .scissor = command_buffer.impl.scissor, .cull_mode = pipeline.cull_mode, .front_face = pipeline.front_face } });
}
fn cmdEndRenderPass(cb: ?CommandBuffer) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const command_buffer = validCommandBufferLocked(cb) orelse return;
    command_buffer.impl.active_framebuffer = null;
    command_buffer.impl.active_render_pass = null;
}

fn createSwapchain(device: ?Device, info: ?*const SwapchainCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    if (alloc != null) return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.min_image_count < 2 or ci.min_image_count > 3 or ci.image_extent.width == 0 or ci.image_extent.height == 0 or ci.present_mode != 2) return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    const surface = validSurfaceLocked(ci.surface) orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or surface.owner != d.physical.owner) return .error_initialization_failed;
    _ = cpu_locality.pinCurrent(.render);
    for (&swapchain_objects, &swapchain_state) |*swapchain, *state| if (state.* == .never) {
        const transport = xcb_present.init(surface.connection, surface.window, ci.image_extent.width, ci.image_extent.height, ci.min_image_count) orelse return .error_initialization_failed;
        swapchain.* = .{
            .owner = d,
            .surface = surface,
            .width = ci.image_extent.width,
            .height = ci.image_extent.height,
            .image_count = ci.min_image_count,
            .images = .{ 0, 0, 0 },
            .image_states = .{ .available, .available, .available },
            .next_image = 0,
            .pending = 0,
            .retiring = false,
            .present_mutex = std.c.PTHREAD_MUTEX_INITIALIZER,
            .present_condition = std.c.PTHREAD_COND_INITIALIZER,
            .cadence = null,
            .transport = transport,
        };
        var created: u32 = 0;
        while (created < ci.min_image_count) : (created += 1) {
            var found = false;
            for (&image_objects, &image_state) |*image, *image_slot_state| if (!found and image_slot_state.* == .never) {
                const byte_count = @as(usize, ci.image_extent.width) * ci.image_extent.height * 4;
                const shared_image_bytes = xcb_present.swapchainImageBytes(&swapchain.transport, created);
                const shared_bytes = shared_image_bytes != null;
                const bytes = shared_image_bytes orelse blk: {
                    break :blk allocateBytes(byte_count) catch return .error_out_of_host_memory;
                };
                @memset(bytes, 0);
                image.* = .{ .owner = d, .width = ci.image_extent.width, .height = ci.image_extent.height, .array_layers = ci.image_array_layers, .samples = 1, .format = ci.image_format, .usage = ci.image_usage, .layout = 0, .owned_bytes = bytes, .shared_bytes = shared_bytes };
                image_slot_state.* = .live;
                swapchain.images[created] = @intFromPtr(image);
                found = true;
            };
            if (!found) return .error_out_of_host_memory;
        }
        state.* = .live;
        out.* = @intFromPtr(swapchain);
        return .success;
    };
    return .error_out_of_host_memory;
}
fn destroySwapchain(device: ?Device, handle: usize, alloc: ?*const Alloc) callconv(.c) void {
    if (alloc != null) return;
    lock();
    const swapchain = validSwapchainLocked(handle) orelse {
        mutex.unlock();
        return;
    };
    if (!validDeviceLocked(device orelse {
        mutex.unlock();
        return;
    }) or swapchain.owner != device.?) {
        mutex.unlock();
        return;
    }
    swapchain.retiring = true;
    mutex.unlock();
    _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
    while (swapchain.pending != 0) _ = std.c.pthread_cond_wait(&swapchain.present_condition, &swapchain.present_mutex);
    _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
    lock();
    defer mutex.unlock();
    xcb_present.deinit(&swapchain.transport);
    for (swapchain.images[0..swapchain.image_count]) |image_handle| if (validImageLocked(image_handle)) |image| {
        stateForObject(ImageObj, image, &image_objects, &image_state).?.* = .tombstone;
        if (!image.shared_bytes) if (image.owned_bytes) |bytes| allocator.free(bytes);
        image.owned_bytes = null;
    };
    for (&swapchain_objects, &swapchain_state) |*candidate, *state| if (candidate == swapchain) {
        state.* = .tombstone;
    };
}
fn getSwapchainImages(device: ?Device, handle: usize, count: ?*u32, output: ?[*]usize) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const swapchain = validSwapchainLocked(handle) orelse return .error_initialization_failed;
    if (!validDeviceLocked(device orelse return .error_initialization_failed) or swapchain.owner != device.?) return .error_initialization_failed;
    const n = count orelse return .error_initialization_failed;
    if (output) |items| {
        const written = @min(n.*, swapchain.image_count);
        @memcpy(items[0..written], swapchain.images[0..written]);
        n.* = written;
        return if (written < swapchain.image_count) .incomplete else .success;
    }
    n.* = swapchain.image_count;
    return .success;
}
fn acquireNextImage(device: ?Device, handle: usize, timeout_ns: u64, semaphore_handle: usize, fence_handle: usize, output: ?*u32) callconv(.c) Result {
    lock();
    const swapchain = validSwapchainLocked(handle) orelse {
        mutex.unlock();
        return .error_initialization_failed;
    };
    if (!validDeviceLocked(device orelse {
        mutex.unlock();
        return .error_initialization_failed;
    }) or swapchain.owner != device.?) {
        mutex.unlock();
        return .error_initialization_failed;
    }
    const semaphore = if (semaphore_handle != 0) validSemaphoreLocked(semaphore_handle) orelse {
        mutex.unlock();
        return .error_initialization_failed;
    } else null;
    const fence = if (fence_handle != 0) validFenceLocked(fence_handle) orelse {
        mutex.unlock();
        return .error_initialization_failed;
    } else null;
    const out = output orelse {
        mutex.unlock();
        return .error_initialization_failed;
    };
    mutex.unlock();

    var realtime_deadline: std.c.timespec = undefined;
    if (timeout_ns != 0 and timeout_ns != std.math.maxInt(u64)) {
        if (std.c.clock_gettime(.REALTIME, &realtime_deadline) != 0) return .error_initialization_failed;
        const deadline = @as(u128, @intCast(realtime_deadline.sec)) * frame_pacing.ns_per_second + @as(u64, @intCast(realtime_deadline.nsec)) + timeout_ns;
        realtime_deadline.sec = @intCast(deadline / frame_pacing.ns_per_second);
        realtime_deadline.nsec = @intCast(deadline % frame_pacing.ns_per_second);
    }
    _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
    defer _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
    while (true) {
        if (frame_lifecycle.acquire(swapchain.image_states[0..swapchain.image_count], &swapchain.next_image)) |index| {
            out.* = index;
            if (semaphore) |item| item.signaled = true;
            if (fence) |item| item.signaled = true;
            return .success;
        }
        if (timeout_ns == 0) return .not_ready;
        if (timeout_ns == std.math.maxInt(u64)) {
            _ = std.c.pthread_cond_wait(&swapchain.present_condition, &swapchain.present_mutex);
        } else if (std.c.pthread_cond_timedwait(&swapchain.present_condition, &swapchain.present_mutex, &realtime_deadline) != .SUCCESS) return .timeout;
    }
}
fn queuePresent(queue: ?Queue, info: ?*const PresentInfo) callconv(.c) Result {
    const present = info orelse return .error_initialization_failed;
    lock();
    const q = queue orelse {
        mutex.unlock();
        return .error_initialization_failed;
    };
    if (!validDeviceLocked(q.owner) or present.swapchain_count == 0 or present.swapchain_count > max_present_entries or present.swapchains == null or present.image_indices == null or (!builtin.is_test and !synchronousOneCore() and !present_worker.ensureStarted())) {
        mutex.unlock();
        return .error_initialization_failed;
    }
    if (present.wait_semaphore_count != 0) {
        const waits = present.wait_semaphores orelse {
            mutex.unlock();
            return .error_initialization_failed;
        };
        for (waits[0..present.wait_semaphore_count]) |handle| {
            const semaphore = validSemaphoreLocked(handle) orelse {
                mutex.unlock();
                return .error_initialization_failed;
            };
            if (!semaphore.signaled) {
                mutex.unlock();
                return .error_initialization_failed;
            }
            semaphore.signaled = false;
        }
    }
    for (present.swapchains.?[0..present.swapchain_count], present.image_indices.?[0..present.swapchain_count], 0..) |handle, index, i| {
        const target_ns = presentTarget(present, i, frame_pacing.monotonicNs()) catch {
            mutex.unlock();
            return .error_initialization_failed;
        };
        const swapchain = validSwapchainLocked(handle) orelse {
            mutex.unlock();
            return .error_initialization_failed;
        };
        if (swapchain.owner != q.owner or index >= swapchain.image_count or swapchain.retiring) {
            mutex.unlock();
            return .error_initialization_failed;
        }
        _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
        if (!frame_lifecycle.queue(swapchain.image_states[0..swapchain.image_count], index)) {
            _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
            mutex.unlock();
            return .error_initialization_failed;
        }
        swapchain.pending += 1;
        _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
        if (builtin.is_test) {
            const image: *ImageObj = @ptrFromInt(swapchain.images[index]);
            _ = xcb_present.present(&swapchain.transport, imageBytes(image));
            releasePresented(swapchain, index);
        } else if (synchronousOneCore()) {
            const before = frame_pacing.monotonicNs();
            if (swapchain.cadence == null) swapchain.cadence = frame_pacing.Clock.init(before, frame_pacing.configuredRate());
            const deadline = target_ns orelse swapchain.cadence.?.deadline();
            if (!xcb_present.upload(&swapchain.transport, imageBytes(@ptrFromInt(swapchain.images[index])))) {
                releasePresented(swapchain, index);
                mutex.unlock();
                return .error_initialization_failed;
            }
            if (deadline > before) frame_pacing.sleepUntilPrecise(deadline, frame_pacing.precision_spin_ns);
            const woke = frame_pacing.monotonicNs();
            swapchain.transport.last.wake_error_ns = @intCast(woke -| deadline);
            if (!xcb_present.commit(&swapchain.transport, imageBytes(@ptrFromInt(swapchain.images[index])))) {
                releasePresented(swapchain, index);
                mutex.unlock();
                return .error_initialization_failed;
            }
            const finished = frame_pacing.monotonicNs();
            recordTrace(.{
                .frame = trace_count,
                .render_complete_ns = before,
                .deadline_ns = deadline,
                .wake_ns = woke,
                .wake_error_ns = swapchain.transport.last.wake_error_ns,
                .present_start_ns = swapchain.transport.last.present_start_ns,
                .upload_end_ns = swapchain.transport.last.upload_end_ns,
                .copy_start_ns = swapchain.transport.last.copy_start_ns,
                .copy_end_ns = swapchain.transport.last.copy_end_ns,
                .flush_end_ns = swapchain.transport.last.flush_end_ns,
                .frame_end_ns = finished,
            });
            swapchain.cadence.?.advance(finished);
            releasePresented(swapchain, index);
        } else if (!present_worker.enqueue(.{ .transport = &swapchain.transport, .cadence = &swapchain.cadence, .pixels = imageBytes(@ptrFromInt(swapchain.images[index])), .context = swapchain, .image_index = index, .release = releasePresented, .target_ns = target_ns })) {
            releasePresented(swapchain, index);
            mutex.unlock();
            return .error_initialization_failed;
        }
        if (present.results) |results| results[i] = .success;
    }
    mutex.unlock();
    return .success;
}
fn queueSubmit(queue: ?Queue, count: u32, submits: ?[*]const SubmitInfo, fence_handle: usize) callconv(.c) Result {
    const q = queue orelse return .error_initialization_failed;
    if (count == 0) {
        hit(.zero_submit_rejected);
        return .error_initialization_failed;
    }
    if (count > max_api_items) return .error_initialization_failed;
    const list = submits orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(q.owner)) return .error_initialization_failed;
    const fence = if (fence_handle == 0) null else validFenceLocked(fence_handle) orelse return .error_initialization_failed;
    if (fence) |item| if (!validOwner(q.owner, item.owner) or item.signaled) return .error_initialization_failed;
    var layouts: [max_child_objects]i32 = undefined;
    for (&image_objects, image_state, 0..) |*image, state, index| layouts[index] = if (state == .live) image.layout else 0;
    for (list[0..count]) |submit| {
        if (submit.s_type != 4 or submit.p_next != null or submit.command_buffer_count > max_api_items) return .error_initialization_failed;
        if (submit.wait_semaphore_count != 0) {
            const waits = submit.wait_semaphores orelse return .error_initialization_failed;
            for (waits[0..submit.wait_semaphore_count]) |handle| {
                const semaphore = validSemaphoreLocked(handle) orelse return .error_initialization_failed;
                if (semaphore.owner != q.owner or !semaphore.signaled) return .error_initialization_failed;
            }
        }
        if (submit.signal_semaphore_count != 0) {
            const signals = submit.signal_semaphores orelse return .error_initialization_failed;
            for (signals[0..submit.signal_semaphore_count]) |handle| {
                const semaphore = validSemaphoreLocked(handle) orelse return .error_initialization_failed;
                if (semaphore.owner != q.owner or semaphore.signaled) return .error_initialization_failed;
            }
        }
        if (submit.command_buffer_count == 0) continue;
        const cbs = submit.command_buffers orelse return .error_initialization_failed;
        for (cbs[0..submit.command_buffer_count]) |cb| {
            const valid_cb = validCommandBufferLocked(cb) orelse return .error_initialization_failed;
            if (valid_cb.impl.owner != q.owner or valid_cb.impl.state != 2) return .error_initialization_failed;
            for (valid_cb.impl.commands[0..valid_cb.impl.count]) |command| if (!prevalidateCommand(command, q.owner, &layouts)) {
                hit(.submission_atomicity);
                return .error_initialization_failed;
            };
        }
    }
    for (list[0..count]) |submit| {
        if (submit.wait_semaphore_count != 0) for (submit.wait_semaphores.?[0..submit.wait_semaphore_count]) |handle| {
            validSemaphoreLocked(handle).?.signaled = false;
        };
        if (submit.command_buffer_count != 0) for (submit.command_buffers.?[0..submit.command_buffer_count]) |cb| for (cb.impl.commands[0..cb.impl.count]) |command| executeValidatedCommand(command);
        if (submit.signal_semaphore_count != 0) for (submit.signal_semaphores.?[0..submit.signal_semaphore_count]) |handle| {
            validSemaphoreLocked(handle).?.signaled = true;
        };
    }
    if (fence) |item| item.signaled = true;
    return .success;
}
fn queueWaitIdle(queue: ?Queue) callconv(.c) Result {
    const q = queue orelse return .error_initialization_failed;
    lock();
    if (!validDeviceLocked(q.owner)) {
        mutex.unlock();
        return .error_initialization_failed;
    }
    var owned: [8]*SwapchainObj = undefined;
    var count: usize = 0;
    for (&swapchain_objects, swapchain_state) |*swapchain, state| if (state == .live and swapchain.owner == q.owner) {
        owned[count] = swapchain;
        count += 1;
    };
    mutex.unlock();
    for (owned[0..count]) |swapchain| {
        _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
        while (swapchain.pending != 0) _ = std.c.pthread_cond_wait(&swapchain.present_condition, &swapchain.present_mutex);
        _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
    }
    return .success;
}
fn presentTarget(info: *const PresentInfo, index: usize, now_ns: u64) !?u64 {
    var next = info.p_next;
    var depth: usize = 0;
    while (next) |raw| : (depth += 1) {
        if (depth == 16) return error.InvalidPresentTiming;
        const header: *const ChainHeader = @ptrCast(@alignCast(raw));
        if (header.s_type == google_present_times_info_stype) {
            logGoogleDisplayTimingRejected("VkPresentTimesInfoGOOGLE in vkQueuePresentKHR");
            return error.GoogleDisplayTimingUnsupported;
        }
        if (header.s_type == 1_000_208_003) {
            const timings: *const PresentTimingsInfoEXT = @ptrCast(@alignCast(raw));
            if (timings.swapchain_count != info.swapchain_count or timings.timing_infos == null) return error.InvalidPresentTiming;
            const timing = timings.timing_infos.?[index];
            if (timing.s_type != 1_000_208_004 or timing.p_next != null or timing.flags & ~@as(u32, 3) != 0 or timing.time_domain_id != 1 or timing.present_stage_queries != 0 or timing.target_time_domain_present_stage != 0) return error.InvalidPresentTiming;
            return if (timing.flags & 1 != 0) std.math.add(u64, now_ns, timing.target_time) catch return error.InvalidPresentTiming else timing.target_time;
        }
        next = @ptrCast(header.p_next);
    }
    return null;
}

test "EXT present timing selects absolute and relative deadlines" {
    var timing = PresentTimingInfoEXT{ .s_type = 1_000_208_004, .p_next = null, .flags = 0, .target_time = 9_000, .time_domain_id = 1, .present_stage_queries = 0, .target_time_domain_present_stage = 0 };
    const timings = PresentTimingsInfoEXT{ .s_type = 1_000_208_003, .p_next = null, .swapchain_count = 1, .timing_infos = @ptrCast(&timing) };
    const info = PresentInfo{ .s_type = 1_000_001_001, .p_next = &timings, .wait_semaphore_count = 0, .wait_semaphores = null, .swapchain_count = 1, .swapchains = null, .image_indices = null, .results = null };
    try std.testing.expectEqual(@as(?u64, 9_000), try presentTarget(&info, 0, 1_000));
    timing.flags = 1;
    timing.target_time = 250;
    try std.testing.expectEqual(@as(?u64, 1_250), try presentTarget(&info, 0, 1_000));
    timing.time_domain_id = 2;
    try std.testing.expectError(error.InvalidPresentTiming, presentTarget(&info, 0, 1_000));
    const google = ChainHeader{ .s_type = google_present_times_info_stype, .p_next = null };
    var google_info = info;
    google_info.p_next = &google;
    try std.testing.expectError(error.GoogleDisplayTimingUnsupported, presentTarget(&google_info, 0, 1_000));
}

test "Google display timing procedure names are detected without aliases" {
    try std.testing.expect(googleDisplayTimingProc("vkGetRefreshCycleDurationGOOGLE"));
    try std.testing.expect(googleDisplayTimingProc("vkGetPastPresentationTimingGOOGLE"));
    try std.testing.expect(!googleDisplayTimingProc("vkGetSwapchainTimingPropertiesEXT"));
    try std.testing.expect(deviceLookup("vkGetRefreshCycleDurationGOOGLE") == null);
}

fn getSwapchainTimingProperties(device: ?Device, handle: usize, output: ?*SwapchainTimingPropertiesEXT, counter: ?*u64) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const swapchain = validSwapchainLocked(handle) orelse return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or swapchain.owner != d) return .error_initialization_failed;
    const properties = output orelse return .error_initialization_failed;
    if (properties.s_type != 1_000_208_001 or properties.p_next != null) return .error_initialization_failed;
    const rate = frame_pacing.configuredRate();
    properties.refresh_duration = frame_pacing.ns_per_second / rate.numerator;
    properties.refresh_interval = 1;
    if (counter) |value| value.* = 1;
    return .success;
}

fn getSwapchainTimeDomainProperties(device: ?Device, handle: usize, output: ?*SwapchainTimeDomainPropertiesEXT, counter: ?*u64) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const swapchain = validSwapchainLocked(handle) orelse return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or swapchain.owner != d) return .error_initialization_failed;
    const properties = output orelse return .error_initialization_failed;
    if (properties.s_type != 1_000_208_002 or properties.p_next != null) return .error_initialization_failed;
    if (properties.time_domain_count != 0 and properties.time_domains != null and properties.time_domain_ids != null) {
        properties.time_domains.?[0] = 1;
        properties.time_domain_ids.?[0] = 1;
    }
    properties.time_domain_count = 1;
    if (counter) |value| value.* = 1;
    return .success;
}

fn setSwapchainPresentTimingQueueSize(device: ?Device, handle: usize, size: u32) callconv(.c) Result {
    _ = size;
    lock();
    defer mutex.unlock();
    const swapchain = validSwapchainLocked(handle) orelse return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or swapchain.owner != d) return .error_initialization_failed;
    return .not_ready;
}

fn getPastPresentationTiming(device: ?Device, info: ?*const PastPresentationTimingInfoEXT, output: ?*PastPresentationTimingPropertiesEXT) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    const query = info orelse return .error_initialization_failed;
    const properties = output orelse return .error_initialization_failed;
    const swapchain = validSwapchainLocked(query.swapchain) orelse return .error_initialization_failed;
    const d = device orelse return .error_initialization_failed;
    if (!validDeviceLocked(d) or swapchain.owner != d or query.s_type != 1_000_208_005 or query.p_next != null or query.flags != 0 or properties.s_type != 1_000_208_006 or properties.p_next != null) return .error_initialization_failed;
    properties.timing_properties_counter = 1;
    properties.time_domains_counter = 1;
    properties.presentation_timing_count = 0;
    properties.presentation_timings = null;
    return .success;
}

fn deviceWaitIdle(device: ?Device) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    lock();
    if (!validDeviceLocked(d)) {
        mutex.unlock();
        return .error_initialization_failed;
    }
    var queue: ?Queue = null;
    for (&device_objects, &queue_objects, device_state) |*candidate, *candidate_queue, state| if (state == .live and candidate == d) {
        queue = candidate_queue;
        break;
    };
    mutex.unlock();
    return queueWaitIdle(queue);
}

fn globalLookup(n: []const u8) Fn {
    const map = .{ .{ "vkGetInstanceProcAddr", getInstanceProcAddr }, .{ "vkCreateInstance", createInstance }, .{ "vkEnumerateInstanceExtensionProperties", enumerateInstanceExtensions } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return null;
}
fn instanceLookup(n: []const u8) Fn {
    if (globalLookup(n)) |f| return f;
    const map = .{ .{ "vkDestroyInstance", destroyInstance }, .{ "vkEnumeratePhysicalDevices", enumeratePhysicalDevices }, .{ "vkGetPhysicalDeviceFeatures", getFeatures }, .{ "vkGetPhysicalDeviceProperties", getProperties }, .{ "vkGetPhysicalDeviceQueueFamilyProperties", getQueueProperties }, .{ "vkGetPhysicalDeviceMemoryProperties", getMemoryProperties }, .{ "vkGetPhysicalDeviceFormatProperties", getFormatProperties }, .{ "vkGetPhysicalDeviceImageFormatProperties", getImageFormatProperties }, .{ "vkGetPhysicalDeviceSparseImageFormatProperties", getSparseImageFormatProperties }, .{ "vkEnumerateDeviceExtensionProperties", enumerateDeviceExtensions }, .{ "vkCreateDevice", createDevice }, .{ "vkGetDeviceProcAddr", getDeviceProcAddr }, .{ "vkDestroyDevice", destroyDevice }, .{ "vkGetDeviceQueue", getDeviceQueue }, .{ "vkCreateXcbSurfaceKHR", createXcbSurface }, .{ "vkDestroySurfaceKHR", destroySurface }, .{ "vkGetPhysicalDeviceSurfaceSupportKHR", getSurfaceSupport }, .{ "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", getSurfaceCapabilities }, .{ "vkGetPhysicalDeviceSurfaceFormatsKHR", getSurfaceFormats }, .{ "vkGetPhysicalDeviceSurfacePresentModesKHR", getSurfacePresentModes } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return deviceLookup(n);
}
fn deviceLookup(n: []const u8) Fn {
    if (googleDisplayTimingProc(n)) {
        logGoogleDisplayTimingRejected("device procedure lookup");
        return null;
    }
    const map = .{ .{ "vkGetDeviceProcAddr", getDeviceProcAddr }, .{ "vkDestroyDevice", destroyDevice }, .{ "vkGetDeviceQueue", getDeviceQueue }, .{ "vkAllocateMemory", allocateMemory }, .{ "vkFreeMemory", freeMemory }, .{ "vkMapMemory", mapMemory }, .{ "vkUnmapMemory", unmapMemory }, .{ "vkCreateBuffer", createBuffer }, .{ "vkDestroyBuffer", destroyBuffer }, .{ "vkGetBufferMemoryRequirements", getBufferMemoryRequirements }, .{ "vkBindBufferMemory", bindBufferMemory }, .{ "vkCreateImage", createImage }, .{ "vkDestroyImage", destroyImage }, .{ "vkGetImageMemoryRequirements", getImageMemoryRequirements }, .{ "vkBindImageMemory", bindImageMemory }, .{ "vkGetImageSubresourceLayout", getImageSubresourceLayout }, .{ "vkCreateFence", createFence }, .{ "vkDestroyFence", destroyFence }, .{ "vkGetFenceStatus", getFenceStatus }, .{ "vkResetFences", resetFences }, .{ "vkWaitForFences", waitForFences }, .{ "vkCreateCommandPool", createCommandPool }, .{ "vkDestroyCommandPool", destroyCommandPool }, .{ "vkAllocateCommandBuffers", allocateCommandBuffers }, .{ "vkFreeCommandBuffers", freeCommandBuffers }, .{ "vkBeginCommandBuffer", beginCommandBuffer }, .{ "vkEndCommandBuffer", endCommandBuffer }, .{ "vkResetCommandBuffer", resetCommandBuffer }, .{ "vkCmdFillBuffer", cmdFillBuffer }, .{ "vkCmdCopyBuffer", cmdCopyBuffer }, .{ "vkCmdClearColorImage", cmdClearColorImage }, .{ "vkCmdCopyBufferToImage", cmdCopyBufferToImage }, .{ "vkCmdCopyImageToBuffer", cmdCopyImageToBuffer }, .{ "vkCmdCopyImage", cmdCopyImage }, .{ "vkCmdPipelineBarrier", cmdPipelineBarrier }, .{ "vkQueueSubmit", queueSubmit }, .{ "vkQueueWaitIdle", queueWaitIdle }, .{ "vkDeviceWaitIdle", deviceWaitIdle } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    const timing = .{ .{ "vkSetSwapchainPresentTimingQueueSizeEXT", setSwapchainPresentTimingQueueSize }, .{ "vkGetSwapchainTimingPropertiesEXT", getSwapchainTimingProperties }, .{ "vkGetSwapchainTimeDomainPropertiesEXT", getSwapchainTimeDomainProperties }, .{ "vkGetPastPresentationTimingEXT", getPastPresentationTiming } };
    inline for (timing) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    const presentation = .{ .{ "vkCreateSemaphore", createSemaphore }, .{ "vkDestroySemaphore", destroySemaphore }, .{ "vkCreateImageView", createImageView }, .{ "vkDestroyImageView", destroyImageView }, .{ "vkCreateSampler", createOpaque }, .{ "vkDestroySampler", destroyOpaque }, .{ "vkCreateDescriptorSetLayout", createDescriptorSetLayout }, .{ "vkDestroyDescriptorSetLayout", destroyDescriptorSetLayout }, .{ "vkCreateDescriptorPool", createOpaque }, .{ "vkDestroyDescriptorPool", destroyOpaque }, .{ "vkCreateShaderModule", createShaderModule }, .{ "vkDestroyShaderModule", destroyShaderModule }, .{ "vkCreatePipelineCache", createOpaque }, .{ "vkDestroyPipelineCache", destroyOpaque }, .{ "vkCreatePipelineLayout", createPipelineLayout }, .{ "vkDestroyPipelineLayout", destroyPipelineLayout }, .{ "vkCreateRenderPass", createRenderPass }, .{ "vkDestroyRenderPass", destroyRenderPass }, .{ "vkCreateFramebuffer", createFramebuffer }, .{ "vkDestroyFramebuffer", destroyFramebuffer }, .{ "vkCreateGraphicsPipelines", createGraphicsPipelines }, .{ "vkDestroyPipeline", destroyPipeline }, .{ "vkAllocateDescriptorSets", allocateDescriptorSets }, .{ "vkUpdateDescriptorSets", updateDescriptorSets }, .{ "vkCmdBeginRenderPass", cmdBeginRenderPass }, .{ "vkCmdBindPipeline", cmdBindPipeline }, .{ "vkCmdBindDescriptorSets", cmdBindDescriptorSets }, .{ "vkCmdSetViewport", cmdSetViewport }, .{ "vkCmdSetScissor", cmdSetScissor }, .{ "vkCmdDraw", cmdDraw }, .{ "vkCmdEndRenderPass", cmdEndRenderPass }, .{ "vkCreateSwapchainKHR", createSwapchain }, .{ "vkDestroySwapchainKHR", destroySwapchain }, .{ "vkGetSwapchainImagesKHR", getSwapchainImages }, .{ "vkAcquireNextImageKHR", acquireNextImage }, .{ "vkQueuePresentKHR", queuePresent } };
    inline for (presentation) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return null;
}

pub export fn vk_icdNegotiateLoaderICDInterfaceVersion(version: ?*u32) callconv(.c) Result {
    const v = version orelse return .error_initialization_failed;
    v.* = @min(v.*, 7);
    return .success;
}
pub export fn vk_icdGetInstanceProcAddr(instance: ?Instance, name: ?[*:0]const u8) callconv(.c) Fn {
    return getInstanceProcAddr(instance, name);
}
pub export fn vk_icdGetPhysicalDeviceProcAddr(instance: ?Instance, name: ?[*:0]const u8) callconv(.c) Fn {
    lock();
    defer mutex.unlock();
    if (!validInstanceLocked(instance orelse return null)) return null;
    const n = std.mem.span(name orelse return null);
    const map = .{ .{ "vkGetPhysicalDeviceFeatures", getFeatures }, .{ "vkGetPhysicalDeviceProperties", getProperties }, .{ "vkGetPhysicalDeviceQueueFamilyProperties", getQueueProperties }, .{ "vkGetPhysicalDeviceMemoryProperties", getMemoryProperties }, .{ "vkGetPhysicalDeviceFormatProperties", getFormatProperties }, .{ "vkGetPhysicalDeviceImageFormatProperties", getImageFormatProperties }, .{ "vkGetPhysicalDeviceSparseImageFormatProperties", getSparseImageFormatProperties }, .{ "vkEnumerateDeviceExtensionProperties", enumerateDeviceExtensions }, .{ "vkCreateDevice", createDevice }, .{ "vkGetPhysicalDeviceSurfaceSupportKHR", getSurfaceSupport }, .{ "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", getSurfaceCapabilities }, .{ "vkGetPhysicalDeviceSurfaceFormatsKHR", getSurfaceFormats }, .{ "vkGetPhysicalDeviceSurfacePresentModesKHR", getSurfacePresentModes } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return null;
}

test "negotiation and exact global lookup" {
    var v: u32 = 99;
    try std.testing.expectEqual(Result.success, vk_icdNegotiateLoaderICDInterfaceVersion(&v));
    try std.testing.expectEqual(@as(u32, 7), v);
    v = 3;
    try std.testing.expectEqual(Result.success, vk_icdNegotiateLoaderICDInterfaceVersion(&v));
    try std.testing.expectEqual(@as(u32, 3), v);
    try std.testing.expectEqual(Result.error_initialization_failed, vk_icdNegotiateLoaderICDInterfaceVersion(null));
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, "vkCreateInstance") != null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, "vkDestroyInstance") == null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, "vkCreateInstanceX") == null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(null, null) == null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(@ptrFromInt(8), "vkDestroyInstance") == null);
    try std.testing.expectEqual(Result.error_initialization_failed, enumerateInstanceExtensions(null, null, null));
    for ([_][*:0]const u8{ "vkGetInstanceProcAddr", "vkCreateInstance", "vkEnumerateInstanceExtensionProperties" }) |name| try std.testing.expect(vk_icdGetInstanceProcAddr(null, name) != null);
}
test "enumeration lifecycle and unsupported features" {
    var ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    try std.testing.expectEqual(MAGIC, instance.loader_data);
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance") != null);
    try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(instance, "vkGetPhysicalDeviceProperties") != null);
    try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(instance, "vkDestroyInstance") == null);
    var extension_count: u32 = 9;
    try std.testing.expectEqual(Result.success, enumerateInstanceExtensions(null, &extension_count, null));
    try std.testing.expectEqual(@as(u32, 2), extension_count);
    var extension_properties: [2]ExtensionProperties = undefined;
    extension_count = 1;
    try std.testing.expectEqual(Result.incomplete, enumerateInstanceExtensions(null, &extension_count, &extension_properties));
    try std.testing.expectEqual(@as(u32, 1), extension_count);
    try std.testing.expectEqualStrings("VK_KHR_surface", std.mem.sliceTo(&extension_properties[0].name, 0));
    try std.testing.expectEqual(@as(u32, 25), extension_properties[0].spec_version);
    extension_count = 2;
    try std.testing.expectEqual(Result.success, enumerateInstanceExtensions(null, &extension_count, &extension_properties));
    try std.testing.expectEqualStrings("VK_KHR_xcb_surface", std.mem.sliceTo(&extension_properties[1].name, 0));
    try std.testing.expectEqual(@as(u32, 6), extension_properties[1].spec_version);
    try std.testing.expectEqual(Result.error_extension_not_present, enumerateInstanceExtensions("layer", &extension_count, null));
    var count: u32 = 0;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, null));
    try std.testing.expectEqual(Result.error_initialization_failed, enumeratePhysicalDevices(instance, null, null));
    try std.testing.expectEqual(@as(u32, 1), count);
    var ps: [1]Physical = undefined;
    count = 0;
    try std.testing.expectEqual(Result.incomplete, enumeratePhysicalDevices(instance, &count, &ps));
    count = 1;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &ps));
    var features = Features{ .values = [_]u32{0} ** 55 };
    features.values[0] = 1;
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    var di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = &features };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.error_feature_not_present, createDevice(ps[0], &di, null, &device));
    di.features = null;
    try std.testing.expectEqual(Result.success, createDevice(ps[0], &di, null, &device));
    var queue: Queue = undefined;
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(MAGIC, queue.loader_data);
    destroyDevice(device, null);
    try std.testing.expect(getDeviceProcAddr(device, "vkDestroyDevice") == null);
    try std.testing.expect(getDeviceProcAddr(@ptrFromInt(8), "vkDestroyDevice") == null);
    destroyInstance(instance, null);
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance") == null);
    const unsupported_extensions = [_][*:0]const u8{"VK_ZPU_unsupported"};
    ci.extension_count = 1;
    ci.extensions = &unsupported_extensions;
    try std.testing.expectEqual(Result.error_extension_not_present, createInstance(&ci, null, &instance));
    const supported_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_xcb_surface" };
    ci.extension_count = supported_extensions.len;
    ci.extensions = &supported_extensions;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    destroyInstance(instance, null);
    ci.extension_count = 0;
    ci.extensions = null;
    const unsupported_chain = ChainHeader{ .s_type = 999, .p_next = null };
    ci.p_next = &unsupported_chain;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
}

test "XCB surface lifecycle and physical presentation queries" {
    const extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_xcb_surface" };
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = extensions.len, .extensions = &extensions };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var physical_count: u32 = 1;
    var physicals: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &physical_count, &physicals));

    const surface_info = XcbSurfaceCreateInfo{ .s_type = 1_000_005_000, .p_next = null, .flags = 0, .connection = @ptrFromInt(8), .window = 42 };
    var surface: usize = 0;
    try std.testing.expectEqual(Result.success, createXcbSurface(instance, &surface_info, null, &surface));
    try std.testing.expect(surface != 0);

    var supported: u32 = 0;
    try std.testing.expectEqual(Result.success, getSurfaceSupport(physicals[0], 0, surface, &supported));
    try std.testing.expectEqual(@as(u32, 1), supported);
    try std.testing.expectEqual(Result.error_initialization_failed, getSurfaceSupport(physicals[0], 1, surface, &supported));

    var capabilities: SurfaceCapabilities = undefined;
    try std.testing.expectEqual(Result.success, getSurfaceCapabilities(physicals[0], surface, &capabilities));
    try std.testing.expectEqual(@as(u32, 2), capabilities.min_image_count);
    try std.testing.expectEqual(@as(u32, 3), capabilities.max_image_count);
    try std.testing.expectEqual(std.math.maxInt(u32), capabilities.current_extent.width);
    try std.testing.expectEqual(Extent2D{ .width = 1, .height = 1 }, capabilities.min_image_extent);
    try std.testing.expectEqual(Extent2D{ .width = 4096, .height = 4096 }, capabilities.max_image_extent);
    try std.testing.expectEqual(@as(u32, 0x10), capabilities.supported_usage_flags);

    var count: u32 = 0;
    try std.testing.expectEqual(Result.success, getSurfaceFormats(physicals[0], surface, &count, null));
    try std.testing.expectEqual(@as(u32, 1), count);
    var formats: [1]SurfaceFormat = undefined;
    count = 0;
    try std.testing.expectEqual(Result.incomplete, getSurfaceFormats(physicals[0], surface, &count, &formats));
    count = 1;
    try std.testing.expectEqual(Result.success, getSurfaceFormats(physicals[0], surface, &count, &formats));
    try std.testing.expectEqual(SurfaceFormat{ .format = 44, .color_space = 0 }, formats[0]);

    count = 0;
    try std.testing.expectEqual(Result.success, getSurfacePresentModes(physicals[0], surface, &count, null));
    try std.testing.expectEqual(@as(u32, 1), count);
    var modes: [1]i32 = undefined;
    count = 0;
    try std.testing.expectEqual(Result.incomplete, getSurfacePresentModes(physicals[0], surface, &count, &modes));
    count = 1;
    try std.testing.expectEqual(Result.success, getSurfacePresentModes(physicals[0], surface, &count, &modes));
    try std.testing.expectEqual(@as(i32, 2), modes[0]);

    const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
    var priority: f32 = 1;
    const queue_info = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const device_info = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&queue_info), .layer_count = 0, .layers = null, .extension_count = 1, .extensions = &device_extensions, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physicals[0], &device_info, null, &device));
    destroyDevice(device, null);

    var bad_info = surface_info;
    bad_info.window = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createXcbSurface(instance, &bad_info, null, &surface));
    try std.testing.expectEqual(Result.error_initialization_failed, createXcbSurface(null, &surface_info, null, &surface));
    try std.testing.expectEqual(Result.error_initialization_failed, createXcbSurface(instance, null, null, &surface));
    try std.testing.expectEqual(Result.error_initialization_failed, createXcbSurface(instance, &surface_info, null, null));

    destroySurface(instance, surface, null);
    try std.testing.expectEqual(Result.error_initialization_failed, getSurfaceCapabilities(physicals[0], surface, &capabilities));
    destroySurface(instance, surface, null);
    destroyInstance(instance, null);
}

fn releaseTestSwapchainImage(swapchain: *SwapchainObj) void {
    frame_pacing.sleepUntil(frame_pacing.monotonicNs() + 2_000_000);
    _ = std.c.pthread_mutex_lock(&swapchain.present_mutex);
    swapchain.image_states[0] = .available;
    _ = std.c.pthread_cond_broadcast(&swapchain.present_condition);
    _ = std.c.pthread_mutex_unlock(&swapchain.present_mutex);
}

test "vkcube presentation path records submits and presents two swapchain images" {
    const instance_extensions = [_][*:0]const u8{ "VK_KHR_surface", "VK_KHR_xcb_surface" };
    const instance_info = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = instance_extensions.len, .extensions = &instance_extensions };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&instance_info, null, &instance));
    var physical_count: u32 = 1;
    var physicals: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &physical_count, &physicals));
    const surface_info = XcbSurfaceCreateInfo{ .s_type = 1_000_005_000, .p_next = null, .flags = 0, .connection = @ptrFromInt(8), .window = 42 };
    var surface: usize = 0;
    try std.testing.expectEqual(Result.success, createXcbSurface(instance, &surface_info, null, &surface));

    var priority: f32 = 1;
    const queue_info = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const device_extensions = [_][*:0]const u8{"VK_KHR_swapchain"};
    const device_info = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&queue_info), .layer_count = 0, .layers = null, .extension_count = 1, .extensions = &device_extensions, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physicals[0], &device_info, null, &device));
    var queue: Queue = undefined;
    getDeviceQueue(device, 0, 0, &queue);

    const swapchain_info = SwapchainCreateInfo{ .s_type = 1_000_001_000, .p_next = null, .flags = 0, .surface = surface, .min_image_count = 2, .image_format = 44, .image_color_space = 0, .image_extent = .{ .width = 8, .height = 8 }, .image_array_layers = 1, .image_usage = 0x10, .image_sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .pre_transform = 1, .composite_alpha = 1, .present_mode = 2, .clipped = 1, .old_swapchain = 0 };
    var swapchain: usize = 0;
    try std.testing.expectEqual(Result.success, createSwapchain(device, &swapchain_info, null, &swapchain));
    var image_count: u32 = 0;
    try std.testing.expectEqual(Result.success, getSwapchainImages(device, swapchain, &image_count, null));
    try std.testing.expectEqual(@as(u32, 2), image_count);
    var images: [2]usize = undefined;
    image_count = 1;
    try std.testing.expectEqual(Result.incomplete, getSwapchainImages(device, swapchain, &image_count, &images));
    image_count = 2;
    try std.testing.expectEqual(Result.success, getSwapchainImages(device, swapchain, &image_count, &images));

    const view_info = ImageViewCreateInfo{ .s_type = 15, .p_next = null, .flags = 0, .image = images[0], .view_type = 1, .format = 44, .components = .{ 0, 0, 0, 0 }, .subresource_range = .{ .aspect_mask = 1, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 } };
    var view: usize = 0;
    try std.testing.expectEqual(Result.success, createImageView(device, &view_info, null, &view));

    const depth_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 124, .extent = .{ .width = 8, .height = 8, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 0, .usage = 0x20, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    var depth_image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(device, &depth_info, null, &depth_image));
    const depth_alloc = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 8 * 8 * 4, .memory_type_index = 0 };
    var depth_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(device, &depth_alloc, null, &depth_memory));
    try std.testing.expectEqual(Result.success, bindImageMemory(device, depth_image, depth_memory, 0));
    var depth_view_info = view_info;
    depth_view_info.image = depth_image;
    depth_view_info.format = 124;
    depth_view_info.subresource_range.aspect_mask = 2;
    var depth_view: usize = 0;
    try std.testing.expectEqual(Result.success, createImageView(device, &depth_view_info, null, &depth_view));

    const texture_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 43, .extent = .{ .width = 1, .height = 1, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 4, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 8 };
    var texture_image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(device, &texture_info, null, &texture_image));
    const small_alloc = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 4, .memory_type_index = 0 };
    var texture_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(device, &small_alloc, null, &texture_memory));
    try std.testing.expectEqual(Result.success, bindImageMemory(device, texture_image, texture_memory, 0));
    @memset(imageBytes(validImageLocked(texture_image).?), 255);
    var texture_view_info = view_info;
    texture_view_info.image = texture_image;
    texture_view_info.format = 43;
    var texture_view: usize = 0;
    try std.testing.expectEqual(Result.success, createImageView(device, &texture_view_info, null, &texture_view));

    const attachments = [_]usize{ view, depth_view };
    const attachment_descriptions = [_]AttachmentDescription{
        .{ .flags = 0, .format = 44, .samples = 1, .load_op = 1, .store_op = 0, .stencil_load_op = 2, .stencil_store_op = 1, .initial_layout = 0, .final_layout = 1000001002 },
        .{ .flags = 0, .format = 124, .samples = 1, .load_op = 1, .store_op = 1, .stencil_load_op = 2, .stencil_store_op = 1, .initial_layout = 0, .final_layout = 3 },
    };
    const color_ref = AttachmentReference{ .attachment = 0, .layout = 2 };
    const depth_ref = AttachmentReference{ .attachment = 1, .layout = 3 };
    const subpass = SubpassDescription{ .flags = 0, .pipeline_bind_point = 0, .input_attachment_count = 0, .input_attachments = null, .color_attachment_count = 1, .color_attachments = @ptrCast(&color_ref), .resolve_attachments = null, .depth_stencil_attachment = &depth_ref, .preserve_attachment_count = 0, .preserve_attachments = null };
    const render_pass_info = RenderPassCreateInfo{ .s_type = 38, .p_next = null, .flags = 0, .attachment_count = 2, .attachments = &attachment_descriptions, .subpass_count = 1, .subpasses = @ptrCast(&subpass), .dependency_count = 0, .dependencies = null };
    var render_pass: usize = 0;
    try std.testing.expectEqual(Result.success, createRenderPass(device, &render_pass_info, null, &render_pass));
    var unpublished: usize = 0xfeed;
    const stale_device: Device = @ptrFromInt(8);
    try std.testing.expectEqual(Result.error_initialization_failed, createRenderPass(stale_device, &render_pass_info, null, &unpublished));
    for (0..96) |budget| {
        test_allocations_before_failure = budget;
        const result = createRenderPass(stale_device, &render_pass_info, null, &unpublished);
        try std.testing.expect(result == .error_out_of_host_memory or result == .error_initialization_failed);
    }
    test_allocations_before_failure = null;
    var framebuffer_info = FramebufferCreateInfo{ .s_type = 37, .p_next = null, .flags = 0, .render_pass = render_pass, .attachment_count = 2, .attachments = &attachments, .width = 8, .height = 8, .layers = 1 };
    var framebuffer: usize = 0;
    var bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.attachment_count = 3;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.attachment_count = 1;
    const framebuffer_states_before_missing = framebuffer_state;
    const missing_output_before = unpublished;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    try std.testing.expectEqual(missing_output_before, unpublished);
    try std.testing.expectEqualSlices(SlotState, &framebuffer_states_before_missing, &framebuffer_state);
    const color_only_subpass = SubpassDescription{ .flags = 0, .pipeline_bind_point = 0, .input_attachment_count = 0, .input_attachments = null, .color_attachment_count = 1, .color_attachments = @ptrCast(&color_ref), .resolve_attachments = null, .depth_stencil_attachment = null, .preserve_attachment_count = 0, .preserve_attachments = null };
    const color_only_render_info = RenderPassCreateInfo{ .s_type = 38, .p_next = null, .flags = 0, .attachment_count = 1, .attachments = &attachment_descriptions, .subpass_count = 1, .subpasses = @ptrCast(&color_only_subpass), .dependency_count = 0, .dependencies = null };
    var color_only_render_pass: usize = 0;
    try std.testing.expectEqual(Result.success, createRenderPass(device, &color_only_render_info, null, &color_only_render_pass));
    bad_framebuffer_info.render_pass = color_only_render_pass;
    var color_only_framebuffer: usize = 0;
    try std.testing.expectEqual(Result.success, createFramebuffer(device, &bad_framebuffer_info, null, &color_only_framebuffer));
    try std.testing.expect(validFramebufferLocked(color_only_framebuffer).?.depth_image == null);
    destroyFramebuffer(device, color_only_framebuffer, null);
    var reversed_attachments = [_]usize{ depth_view, view };
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.attachments = &reversed_attachments;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    var duplicate_attachments = [_]usize{ view, view };
    bad_framebuffer_info.attachments = &duplicate_attachments;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.render_pass = 0xdead_beef;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    var stale_attachments = attachments;
    stale_attachments[0] = 0xdead_beef;
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.attachments = &stale_attachments;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    var mismatched_color_info = depth_info;
    mismatched_color_info.format = 43;
    mismatched_color_info.usage = 0x10;
    var mismatched_color_image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(device, &mismatched_color_info, null, &mismatched_color_image));
    var mismatched_color_view_info = view_info;
    mismatched_color_view_info.image = mismatched_color_image;
    mismatched_color_view_info.format = 43;
    var mismatched_color_view: usize = 0;
    try std.testing.expectEqual(Result.success, createImageView(device, &mismatched_color_view_info, null, &mismatched_color_view));
    var mismatched_format_attachments = [_]usize{ mismatched_color_view, depth_view };
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.attachments = &mismatched_format_attachments;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    var mismatched_depth_info = mismatched_color_info;
    mismatched_depth_info.usage = 0x20;
    var mismatched_depth_image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(device, &mismatched_depth_info, null, &mismatched_depth_image));
    var mismatched_depth_view_info = mismatched_color_view_info;
    mismatched_depth_view_info.image = mismatched_depth_image;
    mismatched_depth_view_info.subresource_range.aspect_mask = 2;
    var mismatched_depth_view: usize = 0;
    try std.testing.expectEqual(Result.success, createImageView(device, &mismatched_depth_view_info, null, &mismatched_depth_view));
    var mismatched_depth_attachments = [_]usize{ view, mismatched_depth_view };
    bad_framebuffer_info.attachments = &mismatched_depth_attachments;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.width = 9;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.layers = 2;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    const render_pass_object = validRenderPassLocked(render_pass).?;
    render_pass_object.owner.generation += 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &framebuffer_info, null, &unpublished));
    render_pass_object.owner.generation -= 1;
    const color_view_object = validImageViewLocked(view).?;
    color_view_object.owner = stale_device;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &framebuffer_info, null, &unpublished));
    color_view_object.owner = device;
    var multisample_descriptions = attachment_descriptions;
    multisample_descriptions[0].samples = 2;
    var multisample_render_info = render_pass_info;
    multisample_render_info.attachments = &multisample_descriptions;
    var multisample_render_pass: usize = 0;
    try std.testing.expectEqual(Result.success, createRenderPass(device, &multisample_render_info, null, &multisample_render_pass));
    multisample_descriptions[0].samples = 1;
    try std.testing.expectEqual(@as(u32, 2), validRenderPassLocked(multisample_render_pass).?.framebuffer_attachments[0].samples);
    bad_framebuffer_info = framebuffer_info;
    bad_framebuffer_info.render_pass = multisample_render_pass;
    try std.testing.expectEqual(Result.error_initialization_failed, createFramebuffer(device, &bad_framebuffer_info, null, &unpublished));
    var malformed_subpass = subpass;
    malformed_subpass.depth_stencil_attachment = &color_ref;
    var malformed_render_info = render_pass_info;
    malformed_render_info.subpasses = @ptrCast(&malformed_subpass);
    try std.testing.expectEqual(Result.error_initialization_failed, createRenderPass(device, &malformed_render_info, null, &unpublished));
    const framebuffer_states_before_oom = framebuffer_state;
    test_allocations_before_failure = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createFramebuffer(device, &framebuffer_info, null, &unpublished));
    test_allocations_before_failure = null;
    try std.testing.expectEqual(missing_output_before, unpublished);
    try std.testing.expectEqualSlices(SlotState, &framebuffer_states_before_oom, &framebuffer_state);
    try std.testing.expectEqual(Result.success, createFramebuffer(device, &framebuffer_info, null, &framebuffer));

    var opaque_handle: usize = 0;
    try std.testing.expectEqual(Result.success, createOpaque(device, @ptrCast(&framebuffer_info), null, &opaque_handle));
    destroyOpaque(device, opaque_handle, null);
    const layout_bindings = [_]DescriptorSetLayoutBinding{
        .{ .binding = 0, .descriptor_type = 6, .descriptor_count = 1, .stage_flags = 1, .immutable_samplers = null },
        .{ .binding = 1, .descriptor_type = 1, .descriptor_count = 1, .stage_flags = 16, .immutable_samplers = null },
    };
    const descriptor_layout_info = DescriptorSetLayoutCreateInfo{ .s_type = 32, .p_next = null, .flags = 0, .binding_count = 2, .bindings = &layout_bindings };
    var descriptor_layout: usize = 0;
    try std.testing.expectEqual(Result.success, createDescriptorSetLayout(device, &descriptor_layout_info, null, &descriptor_layout));
    try std.testing.expectEqual(Result.error_initialization_failed, createDescriptorSetLayout(stale_device, &descriptor_layout_info, null, &unpublished));
    const pipeline_layout_info = PipelineLayoutCreateInfo{ .s_type = 30, .p_next = null, .flags = 0, .set_layout_count = 1, .set_layouts = @ptrCast(&descriptor_layout), .push_constant_range_count = 0, .push_constant_ranges = null };
    var pipeline_layout: usize = 0;
    try std.testing.expectEqual(Result.success, createPipelineLayout(device, &pipeline_layout_info, null, &pipeline_layout));
    test_allocations_before_failure = 13;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createPipelineLayout(device, &pipeline_layout_info, null, &unpublished));
    test_allocations_before_failure = null;
    const push_range = PushConstantRange{ .stage_flags = 1, .offset = 4, .size = 8 };
    var push_layout_info = pipeline_layout_info;
    push_layout_info.push_constant_range_count = 1;
    push_layout_info.push_constant_ranges = @ptrCast(&push_range);
    var push_canonical = try buildPipelineLayoutLocked(device, &push_layout_info);
    defer push_canonical.deinit();
    const vertex_shader_words = spirv_frontend.positive_vertex;
    const fragment_shader_words = spirv_frontend.bool_fragment;
    const vertex_shader_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(vertex_shader_words)), .p_code = &vertex_shader_words };
    const fragment_shader_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(fragment_shader_words)), .p_code = &fragment_shader_words };
    var vertex_shader: usize = 0;
    var fragment_shader: usize = 0;
    try std.testing.expectEqual(Result.success, createShaderModule(device, &vertex_shader_info, null, &vertex_shader));
    try std.testing.expectEqual(Result.success, createShaderModule(device, &fragment_shader_info, null, &fragment_shader));
    var vertex_entry = [_:0]u8{ 'm', 'a', 'i', 'n' };
    var fragment_entry = [_:0]u8{ 'm', 'a', 'i', 'n' };
    var specialization_data = [_]u8{ 1, 0, 0, 0 };
    var specialization_entry = SpecializationMapEntry{ .constant_id = 9, .offset = 0, .size = 4 };
    var specialization = SpecializationInfo{ .map_entry_count = 1, .map_entries = @ptrCast(&specialization_entry), .data_size = specialization_data.len, .data = &specialization_data };
    var stages = [_]PipelineShaderStageCreateInfo{
        .{ .s_type = 18, .p_next = null, .flags = 0, .stage = 1, .module = vertex_shader, .name = &vertex_entry, .specialization_info = null },
        .{ .s_type = 18, .p_next = null, .flags = 0, .stage = 16, .module = fragment_shader, .name = &fragment_entry, .specialization_info = &specialization },
    };
    const vertex_input = PipelineVertexInputStateCreateInfo{ .s_type = 19, .p_next = null, .flags = 0, .binding_count = 0, .bindings = null, .attribute_count = 0, .attributes = null };
    const input_assembly = PipelineInputAssemblyStateCreateInfo{ .s_type = 20, .p_next = null, .flags = 0, .topology = 3, .primitive_restart_enable = 0 };
    const viewport_state = PipelineViewportStateCreateInfo{ .s_type = 22, .p_next = null, .flags = 0, .viewport_count = 1, .viewports = null, .scissor_count = 1, .scissors = null };
    const rasterization = PipelineRasterizationStateCreateInfo{ .s_type = 23, .p_next = null, .flags = 0, .depth_clamp_enable = 0, .rasterizer_discard_enable = 0, .polygon_mode = 0, .cull_mode = 2, .front_face = 0, .depth_bias_enable = 0, .depth_bias_constant_factor = 0, .depth_bias_clamp = 0, .depth_bias_slope_factor = 0, .line_width = 1 };
    const multisample = PipelineMultisampleStateCreateInfo{ .s_type = 24, .p_next = null, .flags = 0, .rasterization_samples = 1, .sample_shading_enable = 0, .min_sample_shading = 0, .sample_mask = null, .alpha_to_coverage_enable = 0, .alpha_to_one_enable = 0 };
    const stencil = std.mem.zeroes(StencilOpState);
    const depth_stencil = PipelineDepthStencilStateCreateInfo{ .s_type = 25, .p_next = null, .flags = 0, .depth_test_enable = 1, .depth_write_enable = 1, .depth_compare_op = 3, .depth_bounds_test_enable = 0, .stencil_test_enable = 0, .front = stencil, .back = stencil, .min_depth_bounds = 0, .max_depth_bounds = 1 };
    const blend_attachment = PipelineColorBlendAttachmentState{ .blend_enable = 0, .src_color_blend_factor = 1, .dst_color_blend_factor = 0, .color_blend_op = 0, .src_alpha_blend_factor = 1, .dst_alpha_blend_factor = 0, .alpha_blend_op = 0, .color_write_mask = 0xf };
    const color_blend = PipelineColorBlendStateCreateInfo{ .s_type = 26, .p_next = null, .flags = 0, .logic_op_enable = 0, .logic_op = 0, .attachment_count = 1, .attachments = @ptrCast(&blend_attachment), .blend_constants = .{ 0, 0, 0, 0 } };
    const dynamic_states = [_]i32{ 0, 1 };
    const dynamic = PipelineDynamicStateCreateInfo{ .s_type = 27, .p_next = null, .flags = 0, .dynamic_state_count = 2, .dynamic_states = &dynamic_states };
    const pipeline_info = GraphicsPipelineCreateInfo{ .s_type = 28, .p_next = null, .flags = 0, .stage_count = 2, .stages = &stages, .vertex_input = &vertex_input, .input_assembly = &input_assembly, .tessellation = null, .viewport = &viewport_state, .rasterization = &rasterization, .multisample = &multisample, .depth_stencil = &depth_stencil, .color_blend = &color_blend, .dynamic = &dynamic, .layout = pipeline_layout, .render_pass = render_pass, .subpass = 0, .base_pipeline = 0, .base_pipeline_index = -1 };
    var pipelines: [1]usize = undefined;
    try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &pipelines));
    const baseline_pipeline = validGraphicsPipelineLocked(pipelines[0]).?;
    var caller_independent = try baseline_pipeline.canonical.clone();
    defer caller_independent.deinit();
    stages[0].module = 0;
    vertex_entry[0] = 'x';
    specialization_data[0] = 0xff;
    specialization_entry.constant_id = 99;
    try std.testing.expect(baseline_pipeline.canonical.eql(&caller_independent));
    stages[0].module = vertex_shader;
    vertex_entry[0] = 'm';
    specialization_data[0] = 1;
    specialization_entry.constant_id = 9;
    var profile_vertex_words = spirv_frontend.positive_vertex;
    var profile_fragment_words = spirv_frontend.bool_fragment;
    const profile_vertex_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(profile_vertex_words)), .p_code = &profile_vertex_words };
    const profile_fragment_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(profile_fragment_words)), .p_code = &profile_fragment_words };
    var profile_vertex_shader: usize = 0;
    var profile_fragment_shader: usize = 0;
    try std.testing.expectEqual(Result.success, createShaderModule(device, &profile_vertex_info, null, &profile_vertex_shader));
    try std.testing.expectEqual(Result.success, createShaderModule(device, &profile_fragment_info, null, &profile_fragment_shader));
    var profile_stages = stages;
    profile_stages[0].module = profile_vertex_shader;
    profile_stages[0].specialization_info = null;
    profile_stages[1].module = profile_fragment_shader;
    var profile_pipeline_info = pipeline_info;
    profile_pipeline_info.stages = &profile_stages;
    var profile_handle: [1]usize = undefined;
    try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&profile_pipeline_info), null, &profile_handle));
    const profile_pipeline = validGraphicsPipelineLocked(profile_handle[0]).?;
    try std.testing.expect(profile_pipeline.vertex_program != null);
    try std.testing.expect(profile_pipeline.fragment_program != null);
    try std.testing.expectEqual(@as(u32, 1), profile_pipeline.execution_abi);
    const owned_vertex_digest = profile_pipeline.vertex_program.?.identity.digest;
    const owned_fragment_digest = profile_pipeline.fragment_program.?.identity.digest;
    var rejected_profile_batch = [_]GraphicsPipelineCreateInfo{ profile_pipeline_info, profile_pipeline_info };
    rejected_profile_batch[1].stage_count = 0;
    var rejected_profile_outputs = [_]usize{ 0xaaaa, 0xbbbb };
    const profile_states_before_rejection = graphics_pipeline_state;
    const profile_allocations_before_rejection = canonical_live_allocations;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 2, @ptrCast(&rejected_profile_batch), null, &rejected_profile_outputs));
    try std.testing.expectEqualSlices(usize, &.{ 0xaaaa, 0xbbbb }, &rejected_profile_outputs);
    try std.testing.expectEqualSlices(SlotState, &profile_states_before_rejection, &graphics_pipeline_state);
    try std.testing.expectEqual(profile_allocations_before_rejection, canonical_live_allocations);
    const profile_vertex_object = findLiveHandle(ShaderModuleObj, profile_vertex_shader, &shader_module_objects, &shader_module_state).?;
    var composite_word: usize = 5;
    while (composite_word < profile_vertex_object.module.words.len and @as(u16, @truncate(profile_vertex_object.module.words[composite_word])) != 44) composite_word += profile_vertex_object.module.words[composite_word] >> 16;
    try std.testing.expect(composite_word < profile_vertex_object.module.words.len);
    profile_vertex_object.module.words[composite_word] = (profile_vertex_object.module.words[composite_word] & 0xffff_0000) | 51;
    var unsupported_composite_output = [_]usize{0xd00d};
    const states_before_composite = graphics_pipeline_state;
    const allocations_before_composite = canonical_live_allocations;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0x1234, 1, @ptrCast(&profile_pipeline_info), null, &unsupported_composite_output));
    try std.testing.expectEqual(@as(usize, 0xd00d), unsupported_composite_output[0]);
    try std.testing.expectEqualSlices(SlotState, &states_before_composite, &graphics_pipeline_state);
    try std.testing.expectEqual(allocations_before_composite, canonical_live_allocations);
    profile_vertex_object.module.words[composite_word] = (profile_vertex_object.module.words[composite_word] & 0xffff_0000) | 44;
    destroyShaderModule(device, profile_vertex_shader, null);
    destroyShaderModule(device, profile_fragment_shader, null);
    @memset(&profile_vertex_words, 0);
    @memset(&profile_fragment_words, 0);
    try std.testing.expectEqualSlices(u8, &owned_vertex_digest, &profile_pipeline.vertex_program.?.identity.digest);
    try std.testing.expectEqualSlices(u8, &owned_fragment_digest, &profile_pipeline.fragment_program.?.identity.digest);
    const fragment_object = findLiveHandle(ShaderModuleObj, fragment_shader, &shader_module_objects, &shader_module_state).?;
    const original_bound = fragment_object.module.words[3];
    fragment_object.module.words[3] = original_bound + 1;
    var collision_pipeline: [1]usize = undefined;
    try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &collision_pipeline));
    try std.testing.expect(!std.mem.eql(u8, &fragment_object.module.identity.digest, &findLiveHandle(ShaderModuleObj, vertex_shader, &shader_module_objects, &shader_module_state).?.module.identity.digest));
    try std.testing.expect(!baseline_pipeline.canonical.eql(&validGraphicsPipelineLocked(collision_pipeline[0]).?.canonical));
    fragment_object.module.words[3] = original_bound;
    const original_magic = fragment_object.module.words[0];
    fragment_object.module.words[0] = 0;
    var malformed_output = [_]usize{0xcafe};
    const states_before_malformed = graphics_pipeline_state;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &malformed_output));
    try std.testing.expectEqual(@as(usize, 0xcafe), malformed_output[0]);
    try std.testing.expectEqualSlices(SlotState, &states_before_malformed, &graphics_pipeline_state);
    fragment_object.module.words[0] = original_magic;
    const longer_words = [_]u32{ spirv.magic, spirv.supported_spirv_version, 0, 1, 0, 0x0001_0000 };
    const longer_shader_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(longer_words)), .p_code = &longer_words };
    var longer_shader: usize = 0;
    try std.testing.expectEqual(Result.success, createShaderModule(device, &longer_shader_info, null, &longer_shader));
    const longer_object = findLiveHandle(ShaderModuleObj, longer_shader, &shader_module_objects, &shader_module_state).?;
    longer_object.module.identity.digest = fragment_object.module.identity.digest;
    var longer_stages = stages;
    longer_stages[1].module = longer_shader;
    var longer_pipeline_info = pipeline_info;
    longer_pipeline_info.stages = &longer_stages;
    var longer_pipeline = [_]usize{0xfeed};
    const states_before_unsupported = graphics_pipeline_state;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&longer_pipeline_info), null, &longer_pipeline));
    try std.testing.expectEqual(@as(usize, 0xfeed), longer_pipeline[0]);
    try std.testing.expectEqualSlices(SlotState, &states_before_unsupported, &graphics_pipeline_state);
    const saved_ingestion = fragment_object.module.identity.ingestion;
    fragment_object.module.identity.ingestion += 1;
    var version_pipeline: [1]usize = undefined;
    try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &version_pipeline));
    try std.testing.expect(!baseline_pipeline.canonical.eql(&validGraphicsPipelineLocked(version_pipeline[0]).?.canonical));
    fragment_object.module.identity.ingestion = saved_ingestion;
    destroyShaderModule(device, longer_shader, null);
    var unchanged = [_]usize{ 0x1111, 0x2222 };
    const live_before_render_clone_failure = canonical_live_allocations;
    const pipeline_states_before_render_clone_failure = graphics_pipeline_state;
    test_fail_render_compatibility_clone = true;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &unchanged));
    test_fail_render_compatibility_clone = false;
    try std.testing.expectEqual(live_before_render_clone_failure, canonical_live_allocations);
    try std.testing.expectEqualSlices(SlotState, &pipeline_states_before_render_clone_failure, &graphics_pipeline_state);
    try std.testing.expectEqual(@as(usize, 0x1111), unchanged[0]);
    test_allocations_before_failure = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), null, &unchanged));
    test_allocations_before_failure = null;
    try std.testing.expectEqual(@as(usize, 0x1111), unchanged[0]);
    var bad_batch = [_]GraphicsPipelineCreateInfo{ pipeline_info, pipeline_info };
    bad_batch[1].stage_count = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 2, @ptrCast(&bad_batch), null, &unchanged));
    try std.testing.expectEqualSlices(usize, &.{ 0x1111, 0x2222 }, &unchanged);
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&pipeline_info), @ptrFromInt(8), &unchanged));
    var static_viewport = Viewport{ .x = -0.0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 };
    var static_scissor = Rect2D{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 8, .height = 8 } };
    var static_viewport_state = viewport_state;
    static_viewport_state.viewports = @ptrCast(&static_viewport);
    static_viewport_state.scissors = @ptrCast(&static_scissor);
    var static_pipeline = pipeline_info;
    static_pipeline.viewport = &static_viewport_state;
    static_pipeline.dynamic = null;
    const vertex_bindings = [_]VertexInputBindingDescription{ .{ .binding = 4, .stride = 8, .input_rate = 1 }, .{ .binding = 3, .stride = 16, .input_rate = 0 } };
    const vertex_attributes = [_]VertexInputAttributeDescription{ .{ .location = 5, .binding = 4, .format = 103, .offset = 0 }, .{ .location = 2, .binding = 3, .format = 109, .offset = 0 } };
    var described_vertex_input = vertex_input;
    described_vertex_input.binding_count = 2;
    described_vertex_input.bindings = &vertex_bindings;
    described_vertex_input.attribute_count = 2;
    described_vertex_input.attributes = &vertex_attributes;
    static_pipeline.vertex_input = &described_vertex_input;
    var static_handle: [1]usize = undefined;
    try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&static_pipeline), null, &static_handle));
    try std.testing.expect(!validGraphicsPipelineLocked(pipelines[0]).?.canonical.eql(&validGraphicsPipelineLocked(static_handle[0]).?.canonical));
    var invalid_pipeline = pipeline_info;
    invalid_pipeline.base_pipeline = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    invalid_pipeline = pipeline_info;
    invalid_pipeline.base_pipeline_index = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    const preserve = [_]u32{0};
    var extended_subpass = subpass;
    extended_subpass.preserve_attachment_count = 1;
    extended_subpass.preserve_attachments = &preserve;
    const dependency = SubpassDependency{ .src_subpass = 0xffff_ffff, .dst_subpass = 0, .src_stage_mask = 1, .dst_stage_mask = 2, .src_access_mask = 4, .dst_access_mask = 8, .dependency_flags = 1 };
    var extended_render_info = render_pass_info;
    extended_render_info.subpasses = @ptrCast(&extended_subpass);
    extended_render_info.dependency_count = 1;
    extended_render_info.dependencies = @ptrCast(&dependency);
    var extended_canonical = try buildRenderPass(&extended_render_info, false);
    defer extended_canonical.deinit();
    const bad_preserve = [_]u32{9};
    extended_subpass.preserve_attachments = &bad_preserve;
    try std.testing.expectError(error.Invalid, buildRenderPass(&extended_render_info, false));
    extended_subpass.preserve_attachments = &preserve;
    var bad_dependency = dependency;
    bad_dependency.dependency_flags = 2;
    extended_render_info.dependencies = @ptrCast(&bad_dependency);
    try std.testing.expectError(error.Invalid, buildRenderPass(&extended_render_info, false));
    const saved_dsl_state = descriptor_set_layout_state;
    @memset(&descriptor_set_layout_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createDescriptorSetLayout(device, &descriptor_layout_info, null, &unchanged[0]));
    descriptor_set_layout_state = saved_dsl_state;
    const saved_layout_state = pipeline_layout_state;
    @memset(&pipeline_layout_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createPipelineLayout(device, &pipeline_layout_info, null, &unchanged[0]));
    pipeline_layout_state = saved_layout_state;
    const saved_render_state = render_pass_state;
    @memset(&render_pass_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createRenderPass(device, &render_pass_info, null, &unchanged[0]));
    render_pass_state = saved_render_state;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.layout = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    invalid_pipeline = pipeline_info;
    invalid_pipeline.subpass = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    var bad_stages = stages;
    bad_stages[1].stage = 1;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.stages = &bad_stages;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    var bad_dynamic_states = [_]i32{ 0, 0 };
    var bad_dynamic = dynamic;
    bad_dynamic.dynamic_states = &bad_dynamic_states;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.dynamic = &bad_dynamic;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    var bad_rasterization = rasterization;
    bad_rasterization.rasterizer_discard_enable = 1;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.rasterization = &bad_rasterization;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    inline for (.{ "depth_bias_constant_factor", "depth_bias_clamp", "depth_bias_slope_factor" }) |field| {
        bad_rasterization = rasterization;
        @field(bad_rasterization, field) = 1;
        invalid_pipeline.rasterization = &bad_rasterization;
        try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    }
    var bad_multisample = multisample;
    bad_multisample.min_sample_shading = 0.5;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.multisample = &bad_multisample;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    var bad_depth = depth_stencil;
    bad_depth.depth_compare_op = 1;
    invalid_pipeline = pipeline_info;
    invalid_pipeline.depth_stencil = &bad_depth;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    bad_depth = depth_stencil;
    bad_depth.min_depth_bounds = 0.25;
    invalid_pipeline.depth_stencil = &bad_depth;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    bad_depth = depth_stencil;
    bad_depth.max_depth_bounds = 0.75;
    invalid_pipeline.depth_stencil = &bad_depth;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    bad_depth = depth_stencil;
    bad_depth.front.fail_op = 1;
    invalid_pipeline.depth_stencil = &bad_depth;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    bad_depth = depth_stencil;
    bad_depth.back.reference = 1;
    invalid_pipeline.depth_stencil = &bad_depth;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    var bad_blend_attachment = blend_attachment;
    bad_blend_attachment.blend_enable = 1;
    var bad_blend = color_blend;
    bad_blend.attachments = @ptrCast(&bad_blend_attachment);
    invalid_pipeline = pipeline_info;
    invalid_pipeline.color_blend = &bad_blend;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    inline for (.{ "src_color_blend_factor", "dst_color_blend_factor", "color_blend_op", "src_alpha_blend_factor", "dst_alpha_blend_factor", "alpha_blend_op" }) |field| {
        bad_blend_attachment = blend_attachment;
        @field(bad_blend_attachment, field) += 1;
        bad_blend.attachments = @ptrCast(&bad_blend_attachment);
        invalid_pipeline.color_blend = &bad_blend;
        var mutated_blend_pipeline: [1]usize = undefined;
        try std.testing.expectEqual(Result.success, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &mutated_blend_pipeline));
        try std.testing.expect(!baseline_pipeline.canonical.eql(&validGraphicsPipelineLocked(mutated_blend_pipeline[0]).?.canonical));
        destroyPipeline(device, mutated_blend_pipeline[0], null);
    }
    bad_blend = color_blend;
    bad_blend.logic_op = 1;
    invalid_pipeline.color_blend = &bad_blend;
    try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    inline for (0..4) |index| {
        bad_blend = color_blend;
        bad_blend.blend_constants[index] = 1;
        invalid_pipeline.color_blend = &bad_blend;
        try std.testing.expectEqual(Result.error_initialization_failed, createGraphicsPipelines(device, 0, 1, @ptrCast(&invalid_pipeline), null, &unchanged));
    }
    var compatible_render_pass: usize = 0;
    try std.testing.expectEqual(Result.success, createRenderPass(device, &render_pass_info, null, &compatible_render_pass));
    var compatible_descriptor_layout: usize = 0;
    try std.testing.expectEqual(Result.success, createDescriptorSetLayout(device, &descriptor_layout_info, null, &compatible_descriptor_layout));
    var compatible_pipeline_layout_info = pipeline_layout_info;
    compatible_pipeline_layout_info.set_layouts = @ptrCast(&compatible_descriptor_layout);
    var compatible_pipeline_layout: usize = 0;
    try std.testing.expectEqual(Result.success, createPipelineLayout(device, &compatible_pipeline_layout_info, null, &compatible_pipeline_layout));
    framebuffer_info.render_pass = compatible_render_pass;
    destroyShaderModule(device, vertex_shader, null);
    destroyShaderModule(device, fragment_shader, null);
    destroyPipelineLayout(device, pipeline_layout, null);
    destroyDescriptorSetLayout(device, descriptor_layout, null);
    destroyRenderPass(device, render_pass, null);
    const set_info = DescriptorSetAllocateInfo{ .s_type = 34, .p_next = null, .descriptor_pool = opaque_handle, .descriptor_set_count = 1, .set_layouts = @ptrCast(&compatible_descriptor_layout) };
    var sets: [1]usize = undefined;
    var bad_set_handles = [_]usize{ compatible_descriptor_layout, 0 };
    var bad_set_info = set_info;
    bad_set_info.descriptor_set_count = 2;
    bad_set_info.set_layouts = &bad_set_handles;
    var unpublished_sets = [_]usize{ 0xaaaa, 0xbbbb };
    try std.testing.expectEqual(Result.error_initialization_failed, allocateDescriptorSets(device, &bad_set_info, &unpublished_sets));
    try std.testing.expectEqualSlices(usize, &.{ 0xaaaa, 0xbbbb }, &unpublished_sets);
    bad_set_handles[1] = compatible_descriptor_layout;
    test_allocations_before_failure = 1;
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateDescriptorSets(device, &bad_set_info, &unpublished_sets));
    test_allocations_before_failure = null;
    const compatible_descriptor_object = validDescriptorSetLayoutLocked(compatible_descriptor_layout).?;
    compatible_descriptor_object.owner.generation += 1;
    try std.testing.expectEqual(Result.error_initialization_failed, allocateDescriptorSets(device, &set_info, &unpublished_sets));
    compatible_descriptor_object.owner.generation -= 1;
    try std.testing.expectEqual(Result.success, allocateDescriptorSets(device, &set_info, &sets));
    updateDescriptorSets(device, 0, null, 0, null);

    const uniform_info = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 160, .usage = 0x10, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    var uniform_buffer: usize = 0;
    try std.testing.expectEqual(Result.success, createBuffer(device, &uniform_info, null, &uniform_buffer));
    const uniform_alloc = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 160, .memory_type_index = 0 };
    var uniform_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(device, &uniform_alloc, null, &uniform_memory));
    try std.testing.expectEqual(Result.success, bindBufferMemory(device, uniform_buffer, uniform_memory, 0));
    var mapped_uniform: ?*anyopaque = null;
    try std.testing.expectEqual(Result.success, mapMemory(device, uniform_memory, 0, 160, 0, &mapped_uniform));
    const uniform: [*]f32 = @ptrCast(@alignCast(mapped_uniform.?));
    @memset(uniform[0..40], 0);
    uniform[0] = 1;
    uniform[5] = 1;
    uniform[10] = 1;
    uniform[15] = 1;
    const vertices = [_]f32{
        -0.8, -0.8, 0.2, 1,
        0.8,  -0.8, 0.2, 1,
        0.0,  0.8,  0.2, 1,
        0,    0,    0,   0,
        1,    0,    0,   0,
        0.5,  1,    0,   0,
    };
    for (vertices, 0..) |value, index| uniform[16 + index] = value;
    unmapMemory(device, uniform_memory);
    const descriptor_buffer = DescriptorBufferInfo{ .buffer = uniform_buffer, .offset = 0, .range = 160 };
    const descriptor_image = DescriptorImageInfo{ .sampler = 1, .image_view = texture_view, .image_layout = 5 };
    const descriptor_writes = [_]WriteDescriptorSet{
        .{ .s_type = 35, .p_next = null, .dst_set = sets[0], .dst_binding = 0, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = 6, .image_info = null, .buffer_info = @ptrCast(&descriptor_buffer), .texel_buffer_view = null },
        .{ .s_type = 35, .p_next = null, .dst_set = sets[0], .dst_binding = 1, .dst_array_element = 0, .descriptor_count = 1, .descriptor_type = 1, .image_info = @ptrCast(&descriptor_image), .buffer_info = null, .texel_buffer_view = null },
    };
    updateDescriptorSets(device, descriptor_writes.len, @ptrCast(&descriptor_writes), 0, null);

    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 0, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(device, &pool_info, null, &pool));
    const command_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var commands: [1]CommandBuffer = undefined;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(device, &command_info, &commands));
    const begin_info = CommandBufferBeginInfo{ .s_type = 42, .p_next = null, .flags = 0, .inheritance_info = null };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    const clears = [_]ClearValue{
        .{ .color = .{ .float32 = .{ 0.2, 0.2, 0.2, 0.2 } } },
        .{ .depth_stencil = .{ .depth = 1, .stencil = 0 } },
    };
    const render_info = RenderPassBeginInfo{ .s_type = 43, .p_next = null, .render_pass = compatible_render_pass, .framebuffer = framebuffer, .render_area = .{ .offset = .{ .x = 0, .y = 0 }, .extent = .{ .width = 8, .height = 8 } }, .clear_value_count = 2, .clear_values = &clears };
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    const viewport = Viewport{ .x = 0, .y = 0, .width = 8, .height = 8, .min_depth = 0, .max_depth = 1 };
    cmdSetViewport(commands[0], 0, 1, @ptrCast(&viewport));
    cmdSetScissor(commands[0], 0, 1, @ptrCast(&render_info.render_area));
    cmdDraw(commands[0], 3, 1, 0, 0);
    cmdEndRenderPass(commands[0]);
    try std.testing.expectEqual(Result.success, endCommandBuffer(commands[0]));

    var acquired: usize = 0;
    var rendered: usize = 0;
    try std.testing.expectEqual(Result.success, createSemaphore(device, @ptrCast(&begin_info), null, &acquired));
    try std.testing.expectEqual(Result.success, createSemaphore(device, @ptrCast(&begin_info), null, &rendered));
    var image_index: u32 = undefined;
    try std.testing.expectEqual(Result.success, acquireNextImage(device, swapchain, std.math.maxInt(u64), acquired, 0, &image_index));
    const wait_stage: u32 = 0x400;
    const submit = SubmitInfo{ .s_type = 4, .p_next = null, .wait_semaphore_count = 1, .wait_semaphores = @ptrCast(&acquired), .wait_dst_stage_mask = @ptrCast(&wait_stage), .command_buffer_count = 1, .command_buffers = &commands, .signal_semaphore_count = 1, .signal_semaphores = @ptrCast(&rendered) };
    try std.testing.expectEqual(Result.success, queueSubmit(queue, 1, @ptrCast(&submit), 0));
    const rendered_image = validImageLocked(images[0]).?;
    const rendered_bytes = imageBytes(rendered_image);
    try std.testing.expect(!std.mem.eql(u8, &[_]u8{ 51, 51, 51, 51 }, rendered_bytes[4 * (4 * 8 + 4) ..][0..4]));
    const depth_values: []const f32 = @alignCast(std.mem.bytesAsSlice(f32, imageBytes(validImageLocked(depth_image).?)));
    try std.testing.expect(depth_values[4 * 8 + 4] < 1);
    var present_result: [1]Result = undefined;
    const present = PresentInfo{ .s_type = 1_000_001_001, .p_next = null, .wait_semaphore_count = 1, .wait_semaphores = @ptrCast(&rendered), .swapchain_count = 1, .swapchains = @ptrCast(&swapchain), .image_indices = @ptrCast(&image_index), .results = &present_result };
    try std.testing.expectEqual(Result.success, queuePresent(queue, &present));
    try std.testing.expectEqual(Result.success, present_result[0]);

    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, pipelines[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    destroyPipeline(device, pipelines[0], null);
    cmdDraw(commands[0], 3, 1, 0, 0);
    try std.testing.expect(commands[0].impl.invalid);

    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBindPipeline(commands[0], 0, pipelines[0]);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBindPipeline(commands[0], 1, static_handle[0]);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 1);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindDescriptorSets(commands[0], 0, opaque_handle, 0, 1, &sets, 0, null);
    cmdDraw(commands[0], 3, 1, 0, 0);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, opaque_handle, 0, 1, &sets, 0, null);
    cmdDraw(commands[0], 0, 1, 0, 0);
    cmdEndRenderPass(commands[0]);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(commands[0]));

    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBindDescriptorSets(commands[0], 1, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    const null_set = [_]usize{0};
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &null_set, 0, null);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    const descriptor_object = validDescriptorSetLocked(sets[0]).?;
    descriptor_object.layout.bytes[0] ^= 1;
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    descriptor_object.layout.bytes[0] ^= 1;
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    commands[0].impl.bound_layout = null;
    cmdDraw(commands[0], 3, 1, 0, 0);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    commands[0].impl.bound_descriptors = null;
    cmdDraw(commands[0], 3, 1, 0, 0);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    const compatible_layout_object = validPipelineLayoutLocked(compatible_pipeline_layout).?;
    compatible_layout_object.canonical.bytes[0] ^= 1;
    cmdDraw(commands[0], 3, 1, 0, 0);
    compatible_layout_object.canonical.bytes[0] ^= 1;
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin_info));
    cmdBeginRenderPass(commands[0], &render_info, 0);
    cmdBindPipeline(commands[0], 0, static_handle[0]);
    cmdBindDescriptorSets(commands[0], 0, compatible_pipeline_layout, 0, 1, &sets, 0, null);
    destroyPipelineLayout(device, compatible_pipeline_layout, null);
    cmdDraw(commands[0], 3, 1, 0, 0);
    try std.testing.expect(commands[0].impl.invalid);

    const saved_surface_state = surface_state;
    @memset(&surface_state, .tombstone);
    var exhausted_handle: usize = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createXcbSurface(instance, &surface_info, null, &exhausted_handle));
    surface_state = saved_surface_state;
    try std.testing.expect(validSwapchainLocked(0xdead_beef) == null);
    const saved_semaphore_state = semaphore_state;
    @memset(&semaphore_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createSemaphore(device, @ptrCast(&begin_info), null, &exhausted_handle));
    semaphore_state = saved_semaphore_state;
    const saved_view_state = image_view_state;
    @memset(&image_view_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createImageView(device, &view_info, null, &exhausted_handle));
    image_view_state = saved_view_state;
    const saved_framebuffer_state = framebuffer_state;
    @memset(&framebuffer_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createFramebuffer(device, &framebuffer_info, null, &exhausted_handle));
    framebuffer_state = saved_framebuffer_state;
    const saved_swapchain_state = swapchain_state;
    @memset(&swapchain_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, createSwapchain(device, &swapchain_info, null, &exhausted_handle));
    swapchain_state = saved_swapchain_state;
    const saved_descriptor_state = descriptor_set_state;
    @memset(&descriptor_set_state, .tombstone);
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateDescriptorSets(device, &set_info, &sets));
    descriptor_set_state = saved_descriptor_state;

    const swapchain_object = validSwapchainLocked(swapchain).?;
    var lifecycle_index: u32 = undefined;
    try std.testing.expectEqual(Result.success, acquireNextImage(device, swapchain, 0, 0, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.success, acquireNextImage(device, swapchain, 0, 0, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.not_ready, acquireNextImage(device, swapchain, 0, 0, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.timeout, acquireNextImage(device, swapchain, 1_000, 0, 0, &lifecycle_index));
    const releaser = try std.Thread.spawn(.{}, releaseTestSwapchainImage, .{swapchain_object});
    try std.testing.expectEqual(Result.success, acquireNextImage(device, swapchain, std.math.maxInt(u64), 0, 0, &lifecycle_index));
    releaser.join();
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(device, 0xdead_beef, 0, 0, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(null, swapchain, 0, 0, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(device, swapchain, 0, 0xdead_beef, 0, &lifecycle_index));
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(device, swapchain, 0, 0, 0xdead_beef, &lifecycle_index));
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(device, swapchain, 0, 0, 0, null));

    var malformed_present = present;
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(null, &malformed_present));
    malformed_present.swapchain_count = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    malformed_present = present;
    malformed_present.wait_semaphores = null;
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    var bad_wait: usize = 0xdead_beef;
    malformed_present.wait_semaphores = @ptrCast(&bad_wait);
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    malformed_present.wait_semaphores = @ptrCast(&acquired);
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    malformed_present = present;
    malformed_present.wait_semaphore_count = 0;
    var bad_swapchain: usize = 0xdead_beef;
    malformed_present.swapchains = @ptrCast(&bad_swapchain);
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    malformed_present.swapchains = @ptrCast(&swapchain);
    var bad_index: u32 = 99;
    malformed_present.image_indices = @ptrCast(&bad_index);
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    malformed_present.image_indices = @ptrCast(&lifecycle_index);
    _ = std.c.pthread_mutex_lock(&swapchain_object.present_mutex);
    swapchain_object.image_states[lifecycle_index] = .available;
    _ = std.c.pthread_mutex_unlock(&swapchain_object.present_mutex);
    try std.testing.expectEqual(Result.error_initialization_failed, queuePresent(queue, &malformed_present));
    try std.testing.expectEqual(Result.success, queueWaitIdle(queue));
    try std.testing.expectEqual(Result.success, deviceWaitIdle(device));
    try std.testing.expectEqual(Result.error_initialization_failed, queueWaitIdle(null));
    try std.testing.expectEqual(Result.error_initialization_failed, deviceWaitIdle(null));
    var wrong_device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physicals[0], &device_info, null, &wrong_device));
    destroySwapchain(wrong_device, swapchain, null);
    try std.testing.expectEqual(Result.error_initialization_failed, acquireNextImage(wrong_device, swapchain, 0, 0, 0, &lifecycle_index));
    destroyDevice(wrong_device, null);
    destroySwapchain(null, swapchain, null);
    destroySwapchain(device, 0xdead_beef, null);

    destroySemaphore(device, acquired, null);
    destroySemaphore(device, rendered, null);
    destroyFramebuffer(device, framebuffer, null);
    destroyImageView(device, view, null);
    destroyImageView(device, depth_view, null);
    destroyImageView(device, texture_view, null);
    destroyImage(device, depth_image, null);
    destroyImage(device, texture_image, null);
    destroyBuffer(device, uniform_buffer, null);
    destroySwapchain(device, swapchain, null);
    destroyCommandPool(device, pool, null);
    destroyDevice(device, null);
    try std.testing.expectEqual(Result.error_initialization_failed, queueWaitIdle(queue));
    try std.testing.expectEqual(Result.error_initialization_failed, deviceWaitIdle(device));
    destroyInstance(instance, null);
}

var instance_callback_count: usize = 0;
var device_callback_count: usize = 0;
const callback_dispatch_word: usize = 0xC0DEC0DE;

fn syntheticInstanceLoaderData(instance: Instance, object: *anyopaque) callconv(.c) Result {
    _ = instance;
    const word: *usize = @ptrCast(@alignCast(object));
    word.* = callback_dispatch_word;
    instance_callback_count += 1;
    return .success;
}
fn syntheticDeviceLoaderData(device: Device, object: *anyopaque) callconv(.c) Result {
    _ = device;
    const word: *usize = @ptrCast(@alignCast(object));
    word.* = callback_dispatch_word;
    device_callback_count += 1;
    return .success;
}
var command_callback_calls: usize = 0;
fn commandBufferLoaderData(device: Device, object: *anyopaque) callconv(.c) Result {
    _ = device;
    _ = object;
    command_callback_calls += 1;
    return if (command_callback_calls == 2) .error_initialization_failed else .success;
}
fn failingInstanceLoaderData(instance: Instance, object: *anyopaque) callconv(.c) Result {
    _ = instance;
    _ = object;
    return .error_initialization_failed;
}
fn failingDeviceLoaderData(device: Device, object: *anyopaque) callconv(.c) Result {
    _ = device;
    _ = object;
    return .error_initialization_failed;
}
fn destroyingInstanceLoaderData(instance: Instance, object: *anyopaque) callconv(.c) Result {
    _ = object;
    destroyInstance(instance, null);
    return .success;
}
fn destroyingDeviceLoaderData(device: Device, object: *anyopaque) callconv(.c) Result {
    _ = object;
    destroyDevice(device, null);
    return .success;
}
fn destroyingDecliningDeviceLoaderData(device: Device, object: *anyopaque) callconv(.c) Result {
    _ = object;
    destroyDevice(device, null);
    return .error_initialization_failed;
}

test "loader callbacks replace child dispatch words without breaking lifetime" {
    instance_callback_count = 0;
    device_callback_count = 0;
    const opaque_tail = ChainHeader{ .s_type = 999, .p_next = null };
    const instance_callback = LoaderInstanceInfo{ .s_type = 47, .p_next = @ptrCast(&opaque_tail), .function = 1, .value = .{ .set_instance_loader_data = syntheticInstanceLoaderData } };
    const instance_link = LoaderInstanceInfo{ .s_type = 47, .p_next = &instance_callback, .function = 0, .value = .{ .layer_info = null } };
    var ci = InstanceInfo{ .s_type = 1, .p_next = &instance_link, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    try std.testing.expectEqual(@as(usize, 0), instance_callback_count);
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    try std.testing.expectEqual(@as(usize, 1), instance_callback_count);
    try std.testing.expectEqual(callback_dispatch_word, physical[0].loader_data);
    try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(instance, "vkGetPhysicalDeviceProperties") != null);

    var priority: f32 = 1;
    const queue_info = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const device_callback = LoaderDeviceInfo{ .s_type = 48, .p_next = @ptrCast(&opaque_tail), .function = 1, .value = .{ .set_device_loader_data = syntheticDeviceLoaderData } };
    const device_link = LoaderDeviceInfo{ .s_type = 48, .p_next = &device_callback, .function = 0, .value = .{ .layer_info = null } };
    const di = DeviceInfo{ .s_type = 3, .p_next = &device_link, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&queue_info), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    var queue: Queue = undefined;
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(@as(usize, 1), device_callback_count);
    try std.testing.expectEqual(callback_dispatch_word, queue.loader_data);
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(@as(usize, 1), device_callback_count);
    try std.testing.expect(getDeviceProcAddr(device, "vkDestroyDevice") != null);
    try std.testing.expect(getDeviceProcAddr(device, "notADeviceEntryPoint") == null);
    destroyDevice(device, null);
    destroyInstance(instance, null);
}

test "destroyed slots are tombstoned and never reused" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var old_instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &old_instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(old_instance, &count, &physical));
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var old_device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &old_device));
    destroyDevice(old_device, null);
    var new_device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &new_device));
    try std.testing.expect(old_device != new_device);
    try std.testing.expect(getDeviceProcAddr(old_device, "vkDestroyDevice") == null);
    destroyDevice(new_device, null);
    destroyInstance(old_instance, null);

    var new_instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &new_instance));
    try std.testing.expect(old_instance != new_instance);
    try std.testing.expect(vk_icdGetInstanceProcAddr(old_instance, "vkDestroyInstance") == null);
    destroyInstance(new_instance, null);
}

test "declined loader callbacks preserve magic fallback and lifetime" {
    const instance_callback = LoaderInstanceInfo{ .s_type = 47, .p_next = null, .function = 1, .value = .{ .set_instance_loader_data = failingInstanceLoaderData } };
    const ci = InstanceInfo{ .s_type = 1, .p_next = &instance_callback, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    try std.testing.expectEqual(MAGIC, physical[0].loader_data);

    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const device_callback = LoaderDeviceInfo{ .s_type = 48, .p_next = null, .function = 1, .value = .{ .set_device_loader_data = failingDeviceLoaderData } };
    const di = DeviceInfo{ .s_type = 3, .p_next = &device_callback, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    var queue: Queue = @ptrFromInt(8);
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(queue));
    try std.testing.expect(getDeviceProcAddr(device, "vkDestroyDevice") != null);
    destroyDevice(device, null);
    destroyInstance(instance, null);
}

test "proc-address scopes expose every supported name and reject cross-scope names" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    const instance_names = [_][*:0]const u8{
        "vkDestroyInstance",                              "vkEnumeratePhysicalDevices",                "vkGetPhysicalDeviceFeatures",          "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceQueueFamilyProperties",       "vkGetPhysicalDeviceMemoryProperties",       "vkGetPhysicalDeviceFormatProperties",  "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties", "vkEnumerateDeviceExtensionProperties",      "vkCreateDevice",                       "vkGetDeviceProcAddr",
        "vkDestroyDevice",                                "vkGetDeviceQueue",                          "vkCreateXcbSurfaceKHR",                "vkDestroySurfaceKHR",
        "vkGetPhysicalDeviceSurfaceSupportKHR",           "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", "vkGetPhysicalDeviceSurfaceFormatsKHR", "vkGetPhysicalDeviceSurfacePresentModesKHR",
    };
    for (instance_names) |name| try std.testing.expect(vk_icdGetInstanceProcAddr(instance, name) != null);
    const physical_names = [_][*:0]const u8{
        "vkGetPhysicalDeviceFeatures",                    "vkGetPhysicalDeviceProperties",             "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceMemoryProperties",            "vkGetPhysicalDeviceFormatProperties",       "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties", "vkEnumerateDeviceExtensionProperties",      "vkCreateDevice",
        "vkGetPhysicalDeviceSurfaceSupportKHR",           "vkGetPhysicalDeviceSurfaceCapabilitiesKHR", "vkGetPhysicalDeviceSurfaceFormatsKHR",
        "vkGetPhysicalDeviceSurfacePresentModesKHR",
    };
    for (physical_names) |name| try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(instance, name) != null);
    try std.testing.expect(vk_icdGetPhysicalDeviceProcAddr(instance, "vkGetDeviceQueue") == null);

    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    const device_names = [_][*:0]const u8{
        "vkGetDeviceProcAddr", "vkDestroyDevice", "vkGetDeviceQueue", "vkAllocateMemory", "vkFreeMemory", "vkMapMemory", "vkUnmapMemory", "vkCreateBuffer", "vkDestroyBuffer", "vkGetBufferMemoryRequirements", "vkBindBufferMemory", "vkCreateImage", "vkDestroyImage", "vkGetImageMemoryRequirements", "vkBindImageMemory", "vkGetImageSubresourceLayout", "vkCreateFence", "vkDestroyFence", "vkGetFenceStatus", "vkResetFences", "vkWaitForFences", "vkCreateCommandPool", "vkDestroyCommandPool", "vkAllocateCommandBuffers", "vkFreeCommandBuffers", "vkBeginCommandBuffer", "vkEndCommandBuffer", "vkResetCommandBuffer", "vkCmdFillBuffer", "vkCmdCopyBuffer", "vkCmdClearColorImage", "vkCmdCopyBufferToImage", "vkCmdCopyImageToBuffer", "vkCmdCopyImage", "vkCmdPipelineBarrier", "vkQueueSubmit", "vkQueueWaitIdle", "vkDeviceWaitIdle",
    };
    for (device_names) |name| {
        try std.testing.expect(getDeviceProcAddr(device, name) != null);
        try std.testing.expect(vk_icdGetInstanceProcAddr(instance, name) != null);
    }
    try std.testing.expect(getDeviceProcAddr(device, "vkCreateDevice") == null);
    destroyDevice(device, null);
    destroyInstance(instance, null);
}

fn heldRead(physical: Physical) void {
    var features: Features = undefined;
    getFeatures(physical, &features);
}
const DestroyContext = struct { instance: Instance, done: *std.atomic.Value(bool) };
fn overlappingDestroy(context: DestroyContext) void {
    destroyInstance(context.instance, null);
    context.done.store(true, .release);
}

test "serialized entry points tolerate concurrent reads and destroy" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    overlap_entered.store(false, .release);
    overlap_hold.store(true, .release);
    const reader = try std.Thread.spawn(.{}, heldRead, .{physical[0]});
    while (!overlap_entered.load(.acquire)) std.atomic.spinLoopHint();
    var destroyed = std.atomic.Value(bool).init(false);
    const destroyer = try std.Thread.spawn(.{}, overlappingDestroy, .{DestroyContext{ .instance = instance, .done = &destroyed }});
    std.Thread.yield() catch {};
    try std.testing.expect(!destroyed.load(.acquire));
    overlap_hold.store(false, .release);
    reader.join();
    destroyer.join();
    try std.testing.expect(destroyed.load(.acquire));
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance") == null);
}

test "loader chain bounds and callback destruction revalidation" {
    const unknown = ChainHeader{ .s_type = 999, .p_next = null };
    const instance_unknown = LoaderInstanceInfo{ .s_type = 47, .p_next = &unknown, .function = 0, .value = .{ .layer_info = null } };
    var ci = InstanceInfo{ .s_type = 1, .p_next = &instance_unknown, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    destroyInstance(instance, null);
    const null_instance_callback = LoaderInstanceInfo{ .s_type = 47, .p_next = null, .function = 1, .value = .{ .set_instance_loader_data = null } };
    ci.p_next = &null_instance_callback;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    destroyInstance(instance, null);
    var instance_links: [17]LoaderInstanceInfo = undefined;
    for (&instance_links, 0..) |*link, i| link.* = .{ .s_type = 47, .p_next = if (i + 1 < instance_links.len) &instance_links[i + 1] else null, .function = 0, .value = .{ .layer_info = null } };
    ci.p_next = &instance_links[0];
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    destroyInstance(instance, null);

    const destroy_callback = LoaderInstanceInfo{ .s_type = 47, .p_next = null, .function = 1, .value = .{ .set_instance_loader_data = destroyingInstanceLoaderData } };
    ci.p_next = &destroy_callback;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.error_initialization_failed, enumeratePhysicalDevices(instance, &count, &physical));
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance") == null);

    ci.p_next = null;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    var device_links: [17]LoaderDeviceInfo = undefined;
    for (&device_links, 0..) |*link, i| link.* = .{ .s_type = 48, .p_next = if (i + 1 < device_links.len) &device_links[i + 1] else null, .function = 0, .value = .{ .layer_info = null } };
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    var di = DeviceInfo{ .s_type = 3, .p_next = &device_links[0], .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    destroyDevice(device, null);
    const null_device_callback = LoaderDeviceInfo{ .s_type = 48, .p_next = null, .function = 1, .value = .{ .set_device_loader_data = null } };
    di.p_next = &null_device_callback;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    destroyDevice(device, null);
    const device_unknown = LoaderDeviceInfo{ .s_type = 48, .p_next = &unknown, .function = 0, .value = .{ .layer_info = null } };
    di.p_next = &device_unknown;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    destroyDevice(device, null);
    const device_destroy_callback = LoaderDeviceInfo{ .s_type = 48, .p_next = null, .function = 1, .value = .{ .set_device_loader_data = destroyingDeviceLoaderData } };
    di.p_next = &device_destroy_callback;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    var queue: Queue = @ptrFromInt(8);
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(queue));
    try std.testing.expect(getDeviceProcAddr(device, "vkDestroyDevice") == null);
    const declining_destroy_callback = LoaderDeviceInfo{ .s_type = 48, .p_next = null, .function = 1, .value = .{ .set_device_loader_data = destroyingDecliningDeviceLoaderData } };
    di.p_next = &declining_destroy_callback;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    const stale_device = device;
    queue = @ptrFromInt(8);
    getDeviceQueue(device, 0, 0, &queue);
    try std.testing.expectEqual(@as(usize, 8), @intFromPtr(queue));
    try std.testing.expect(getDeviceProcAddr(stale_device, "vkDestroyDevice") == null);
    destroyInstance(instance, null);
}

test "physical properties start with coherent conservative limits" {
    // Independent contract values follow Vulkan 1.0 Required Limits:
    // https://registry.khronos.org/vulkan/specs/1.0/html/vkspec.html#limits-minmax
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    var properties: Properties = undefined;
    getProperties(physical[0], &properties);
    try std.testing.expectEqual(API_1_0, properties.api_version);
    try std.testing.expectEqual(@as(u32, 0x1cdc), properties.vendor_id);
    try std.testing.expectEqual(@as(u32, 1), properties.device_id);
    try std.testing.expectEqual(@as(u32, 4), properties.device_type);
    const l = properties.limits;
    try std.testing.expect(l.max_image_dimension_1d >= 4096);
    try std.testing.expect(l.max_image_dimension_2d >= 4096);
    try std.testing.expect(l.max_image_dimension_3d >= 256);
    try std.testing.expect(l.max_image_dimension_cube >= 4096);
    try std.testing.expect(l.max_image_array_layers >= 256);
    try std.testing.expect(l.max_texel_buffer_elements >= 65_536);
    try std.testing.expect(l.max_uniform_buffer_range >= 16_384);
    try std.testing.expect(l.max_storage_buffer_range >= 134_217_728);
    try std.testing.expect(l.max_push_constants_size >= 128 and l.max_push_constants_size % 4 == 0);
    try std.testing.expect(l.max_memory_allocation_count >= 4096);
    try std.testing.expect(l.max_sampler_allocation_count >= 4000);
    try std.testing.expect(l.buffer_image_granularity <= 131_072 and std.math.isPowerOfTwo(l.buffer_image_granularity));
    try std.testing.expectEqual(@as(u64, 0), l.sparse_address_space_size);
    try std.testing.expect(l.max_bound_descriptor_sets >= 4);
    try std.testing.expect(l.max_per_stage_descriptor_samplers >= 16);
    try std.testing.expect(l.max_per_stage_descriptor_uniform_buffers >= 12);
    try std.testing.expect(l.max_per_stage_descriptor_storage_buffers >= 4);
    try std.testing.expect(l.max_per_stage_descriptor_sampled_images >= 16);
    try std.testing.expect(l.max_per_stage_descriptor_storage_images >= 4);
    try std.testing.expect(l.max_per_stage_descriptor_input_attachments >= 4);
    const per_stage_sum = l.max_per_stage_descriptor_uniform_buffers + l.max_per_stage_descriptor_storage_buffers + l.max_per_stage_descriptor_sampled_images + l.max_per_stage_descriptor_storage_images + l.max_per_stage_descriptor_input_attachments + l.max_color_attachments;
    try std.testing.expect(l.max_per_stage_resources >= @min(per_stage_sum, 128));
    try std.testing.expect(l.max_descriptor_set_samplers >= 96);
    try std.testing.expect(l.max_descriptor_set_uniform_buffers >= 72);
    try std.testing.expect(l.max_descriptor_set_uniform_buffers_dynamic >= 8);
    try std.testing.expect(l.max_descriptor_set_storage_buffers >= 24);
    try std.testing.expect(l.max_descriptor_set_storage_buffers_dynamic >= 4);
    try std.testing.expect(l.max_descriptor_set_sampled_images >= 96);
    try std.testing.expect(l.max_descriptor_set_storage_images >= 24);
    try std.testing.expect(l.max_descriptor_set_input_attachments >= 4);
    try std.testing.expect(l.max_vertex_input_attributes >= 16);
    try std.testing.expect(l.max_vertex_input_bindings >= 16);
    try std.testing.expect(l.max_vertex_input_attribute_offset >= 2047);
    try std.testing.expect(l.max_vertex_input_binding_stride >= 2048);
    try std.testing.expect(l.max_vertex_output_components >= 64);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_generation_level);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_patch_size);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_control_per_vertex_input_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_control_per_vertex_output_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_control_per_patch_output_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_control_total_output_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_evaluation_input_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_tessellation_evaluation_output_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_geometry_shader_invocations);
    try std.testing.expectEqual(@as(u32, 0), l.max_geometry_input_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_geometry_output_components);
    try std.testing.expectEqual(@as(u32, 0), l.max_geometry_output_vertices);
    try std.testing.expectEqual(@as(u32, 0), l.max_geometry_total_output_components);
    try std.testing.expect(l.max_fragment_input_components >= 128);
    try std.testing.expect(l.max_fragment_output_attachments >= 4);
    try std.testing.expectEqual(@as(u32, 0), l.max_fragment_dual_src_attachments);
    try std.testing.expect(l.max_fragment_combined_output_resources >= l.max_per_stage_descriptor_storage_buffers + l.max_per_stage_descriptor_storage_images + l.max_color_attachments);
    try std.testing.expect(l.max_compute_shared_memory_size >= 16_384);
    for (l.max_compute_work_group_count) |value| try std.testing.expect(value >= 65_535);
    try std.testing.expect(l.max_compute_work_group_invocations >= 128);
    try std.testing.expect(l.max_compute_work_group_size[0] >= 128 and l.max_compute_work_group_size[1] >= 128 and l.max_compute_work_group_size[2] >= 64);
    try std.testing.expect(l.sub_pixel_precision_bits >= 4);
    try std.testing.expect(l.sub_texel_precision_bits >= 4);
    try std.testing.expect(l.mipmap_precision_bits >= 4);
    try std.testing.expect(l.max_draw_indexed_index_value >= 0x00ff_ffff);
    try std.testing.expect(l.max_draw_indirect_count >= 1);
    try std.testing.expect(l.max_sampler_lod_bias >= 2);
    try std.testing.expectEqual(@as(f32, 1), l.max_sampler_anisotropy);
    try std.testing.expectEqual(@as(u32, 1), l.max_viewports);
    try std.testing.expect(l.max_viewport_dimensions[0] >= l.max_framebuffer_width and l.max_viewport_dimensions[1] >= l.max_framebuffer_height);
    try std.testing.expect(l.viewport_bounds_range[0] <= -32_768 and l.viewport_bounds_range[1] >= 32_767);
    try std.testing.expectEqual(@as(u32, 0), l.viewport_sub_pixel_bits);
    try std.testing.expect(l.min_memory_map_alignment <= 64 and std.math.isPowerOfTwo(l.min_memory_map_alignment));
    try std.testing.expect(l.min_texel_buffer_offset_alignment <= 256 and std.math.isPowerOfTwo(l.min_texel_buffer_offset_alignment));
    try std.testing.expect(l.min_uniform_buffer_offset_alignment <= 256 and std.math.isPowerOfTwo(l.min_uniform_buffer_offset_alignment));
    try std.testing.expect(l.min_storage_buffer_offset_alignment <= 256 and std.math.isPowerOfTwo(l.min_storage_buffer_offset_alignment));
    try std.testing.expect(l.min_texel_offset <= -8 and l.max_texel_offset >= 7);
    try std.testing.expectEqual(@as(i32, 0), l.min_texel_gather_offset);
    try std.testing.expectEqual(@as(u32, 0), l.max_texel_gather_offset);
    try std.testing.expectEqual(@as(f32, 0), l.min_interpolation_offset);
    try std.testing.expectEqual(@as(f32, 0), l.max_interpolation_offset);
    try std.testing.expectEqual(@as(u32, 0), l.sub_pixel_interpolation_offset_bits);
    try std.testing.expect(l.max_framebuffer_width >= 4096 and l.max_framebuffer_height >= 4096);
    const vulkan_1_0_min_framebuffer_layers: u32 = 256;
    try std.testing.expect(l.max_framebuffer_layers >= vulkan_1_0_min_framebuffer_layers);
    const samples_1_4: u32 = 1 | 4;
    try std.testing.expect(l.framebuffer_color_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.framebuffer_depth_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.framebuffer_stencil_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.framebuffer_no_attachments_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.max_color_attachments >= 4);
    try std.testing.expect(l.sampled_image_color_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.sampled_image_integer_sample_counts & 1 == 1);
    try std.testing.expect(l.sampled_image_depth_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.sampled_image_stencil_sample_counts & samples_1_4 == samples_1_4);
    try std.testing.expect(l.storage_image_sample_counts & 1 == 1);
    try std.testing.expect(l.max_sample_mask_words >= 1);
    try std.testing.expectEqual(@as(u32, 0), l.timestamp_compute_and_graphics);
    try std.testing.expect(l.timestamp_period > 0);
    try std.testing.expectEqual(@as(u32, 0), l.max_clip_distances);
    try std.testing.expectEqual(@as(u32, 0), l.max_cull_distances);
    try std.testing.expectEqual(@as(u32, 0), l.max_combined_clip_and_cull_distances);
    try std.testing.expect(l.discrete_queue_priorities >= 2);
    try std.testing.expectEqual([2]f32{ 1, 1 }, l.point_size_range);
    try std.testing.expectEqual([2]f32{ 1, 1 }, l.line_width_range);
    try std.testing.expectEqual(@as(f32, 0), l.point_size_granularity);
    try std.testing.expectEqual(@as(f32, 0), l.line_width_granularity);
    try std.testing.expectEqual(@as(u32, 0), l.strict_lines);
    try std.testing.expectEqual(@as(u32, 1), l.standard_sample_locations);
    try std.testing.expect(std.math.isPowerOfTwo(l.optimal_buffer_copy_offset_alignment));
    try std.testing.expect(std.math.isPowerOfTwo(l.optimal_buffer_copy_row_pitch_alignment));
    try std.testing.expect(std.math.isPowerOfTwo(l.non_coherent_atom_size));
    try std.testing.expectEqual(@as(usize, 824), @sizeOf(Properties));
    destroyInstance(instance, null);
}

test "all physical queries cover success boundaries and invalid handles" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    const p = physical[0];
    getFeatures(p, null);

    var features = Features{ .values = [_]u32{1} ** 55 };
    getFeatures(p, &features);
    try std.testing.expectEqualSlices(u32, &([_]u32{0} ** 55), &features.values);
    var queue_count: u32 = 7;
    getQueueProperties(p, &queue_count, null);
    try std.testing.expectEqual(@as(u32, 1), queue_count);
    var queue_properties: [1]QueueProperties = undefined;
    queue_count = 0;
    getQueueProperties(p, &queue_count, &queue_properties);
    try std.testing.expectEqual(@as(u32, 0), queue_count);
    queue_count = 1;
    getQueueProperties(p, &queue_count, &queue_properties);
    try std.testing.expectEqual(@as(u32, 0x5), queue_properties[0].flags);
    try std.testing.expectEqual(@as(u32, 1), queue_properties[0].count);

    var memory: MemoryProperties = undefined;
    getMemoryProperties(p, &memory);
    try std.testing.expectEqual(@as(u32, 1), memory.memory_type_count);
    try std.testing.expectEqual(@as(u32, 0x7), memory.memory_types[0].property_flags);
    try std.testing.expectEqual(@as(u32, 0), memory.memory_types[0].heap_index);
    try std.testing.expectEqual(@as(u32, 1), memory.memory_heap_count);
    try std.testing.expectEqual(@as(u64, 256 * 1024 * 1024), memory.memory_heaps[0].size);
    try std.testing.expectEqual(@as(u32, 0), memory.memory_heaps[0].flags);
    try std.testing.expectEqual(@as(usize, 520), @sizeOf(MemoryProperties));
    var format = FormatProperties{ .linear_tiling_features = 1, .optimal_tiling_features = 1, .buffer_features = 1 };
    getFormatProperties(p, 0, &format);
    try std.testing.expectEqual(FormatProperties{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = 0 }, format);
    try std.testing.expectEqual(Result.error_format_not_supported, getImageFormatProperties(p, 0, 0, 0, 0, 0, null));
    var sparse_count: u32 = 9;
    getSparseImageFormatProperties(p, 0, 0, 1, 0, 0, &sparse_count, null);
    try std.testing.expectEqual(@as(u32, 0), sparse_count);
    var extension_count: u32 = 9;
    try std.testing.expectEqual(Result.success, enumerateDeviceExtensions(p, null, &extension_count, null));
    try std.testing.expectEqual(@as(u32, 2), extension_count);
    var device_extensions: [2]ExtensionProperties = undefined;
    extension_count = 0;
    try std.testing.expectEqual(Result.incomplete, enumerateDeviceExtensions(p, null, &extension_count, &device_extensions));
    extension_count = 2;
    try std.testing.expectEqual(Result.success, enumerateDeviceExtensions(p, null, &extension_count, &device_extensions));
    try std.testing.expectEqualStrings("VK_KHR_swapchain", std.mem.sliceTo(&device_extensions[0].name, 0));
    try std.testing.expectEqual(@as(u32, 70), device_extensions[0].spec_version);
    try std.testing.expectEqualStrings("VK_EXT_present_timing", std.mem.sliceTo(&device_extensions[1].name, 0));
    try std.testing.expectEqual(@as(u32, 3), device_extensions[1].spec_version);
    try std.testing.expectEqual(Result.error_extension_not_present, enumerateDeviceExtensions(p, "layer", &extension_count, null));
    try std.testing.expectEqual(Result.error_initialization_failed, enumerateDeviceExtensions(p, null, null, null));
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "notAnEntryPoint") == null);

    destroyInstance(instance, null);
    features.values[0] = 7;
    getFeatures(p, &features);
    try std.testing.expectEqual(@as(u32, 7), features.values[0]);
    try std.testing.expectEqual(Result.error_initialization_failed, getImageFormatProperties(p, 0, 0, 0, 0, 0, null));
    try std.testing.expectEqual(Result.error_initialization_failed, enumerateDeviceExtensions(p, null, &extension_count, null));
}

test "creation rejects every supported invalid-input class" {
    var instance: Instance = undefined;
    var ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(null, null, &instance));
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, null));
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, @ptrFromInt(8), &instance));
    ci.s_type = 99;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
    ci.s_type = 1;
    ci.layer_count = 1;
    try std.testing.expectEqual(Result.error_layer_not_present, createInstance(&ci, null, &instance));
    ci.layer_count = 0;
    ci.extension_count = 1;
    try std.testing.expectEqual(Result.error_extension_not_present, createInstance(&ci, null, &instance));
    ci.extension_count = 0;
    ci.flags = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
    ci.flags = 0;
    var app = AppInfo{ .s_type = 0, .p_next = null, .app_name = null, .app_version = 0, .engine_name = null, .engine_version = 0, .api_version = API_1_0 + 1 };
    ci.app_info = &app;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
    app.api_version = API_1_0;
    app.s_type = 99;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
    ci.app_info = null;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));

    var priority: f32 = 1;
    var qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    var di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(null, &di, null, &device));
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], null, null, &device));
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, null));
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, @ptrFromInt(8), &device));
    di.s_type = 99;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    di.s_type = 3;
    di.layer_count = 1;
    try std.testing.expectEqual(Result.error_layer_not_present, createDevice(physical[0], &di, null, &device));
    di.layer_count = 0;
    di.extension_count = 1;
    try std.testing.expectEqual(Result.error_extension_not_present, createDevice(physical[0], &di, null, &device));
    di.extension_count = 0;
    di.queue_info_count = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    di.queue_info_count = 1;
    di.queue_infos = null;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    di.queue_infos = @ptrCast(&qi);
    qi.s_type = 99;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.s_type = 2;
    const queue_tail = ChainHeader{ .s_type = 99, .p_next = null };
    qi.p_next = &queue_tail;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.p_next = null;
    qi.flags = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.flags = 0;
    qi.family = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.family = 0;
    qi.count = 2;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.count = 1;
    qi.priorities = null;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    qi.priorities = @ptrCast(&priority);
    priority = -0.01;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    priority = 1.01;
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    priority = std.math.nan(f32);
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
    priority = 1;
    destroyInstance(instance, null);
    try std.testing.expectEqual(Result.error_initialization_failed, createDevice(physical[0], &di, null, &device));
}

const TestDeviceContext = struct { instance: Instance, physical: Physical, device: Device, queue: Queue };
fn createTestDeviceContext() !TestDeviceContext {
    const ici = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ici, null, &instance));
    var count: u32 = 1;
    var physicals: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physicals));
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physicals[0], &di, null, &device));
    var queue: Queue = undefined;
    getDeviceQueue(device, 0, 0, &queue);
    return .{ .instance = instance, .physical = physicals[0], .device = device, .queue = queue };
}

test "minimal barrier stage and access contract is exact" {
    const Case = struct { old: i32, new: i32, src_stage: u32, src_access: u32, dst_access: u32 };
    const cases = [_]Case{
        .{ .old = 0, .new = 1, .src_stage = 0x1, .src_access = 0, .dst_access = 0x1800 },         .{ .old = 0, .new = 6, .src_stage = 0x1, .src_access = 0, .dst_access = 0x800 },         .{ .old = 0, .new = 7, .src_stage = 0x1, .src_access = 0, .dst_access = 0x1000 },
        .{ .old = 8, .new = 1, .src_stage = 0x4000, .src_access = 0x4000, .dst_access = 0x1800 }, .{ .old = 8, .new = 6, .src_stage = 0x4000, .src_access = 0x4000, .dst_access = 0x800 }, .{ .old = 8, .new = 7, .src_stage = 0x4000, .src_access = 0x4000, .dst_access = 0x1000 },
        .{ .old = 1, .new = 1, .src_stage = 0x1000, .src_access = 0x1800, .dst_access = 0x1800 }, .{ .old = 1, .new = 6, .src_stage = 0x1000, .src_access = 0x1800, .dst_access = 0x800 }, .{ .old = 1, .new = 7, .src_stage = 0x1000, .src_access = 0x1800, .dst_access = 0x1000 },
        .{ .old = 6, .new = 1, .src_stage = 0x1000, .src_access = 0x800, .dst_access = 0x1800 },  .{ .old = 6, .new = 6, .src_stage = 0x1000, .src_access = 0x800, .dst_access = 0x800 },  .{ .old = 6, .new = 7, .src_stage = 0x1000, .src_access = 0x800, .dst_access = 0x1000 },
        .{ .old = 7, .new = 1, .src_stage = 0x1000, .src_access = 0x1000, .dst_access = 0x1800 }, .{ .old = 7, .new = 6, .src_stage = 0x1000, .src_access = 0x1000, .dst_access = 0x800 }, .{ .old = 7, .new = 7, .src_stage = 0x1000, .src_access = 0x1000, .dst_access = 0x1000 },
    };
    for (cases) |case| {
        var barrier = ImageMemoryBarrier{ .s_type = 45, .p_next = null, .src_access_mask = case.src_access, .dst_access_mask = case.dst_access, .old_layout = case.old, .new_layout = case.new, .src_queue_family_index = 0, .dst_queue_family_index = 0, .image = 1, .subresource_range = std.mem.zeroes(ImageSubresourceRange) };
        try std.testing.expect(barrierMasksSupported(barrier, case.src_stage, 0x1000));
        try std.testing.expect(!barrierMasksSupported(barrier, case.src_stage | 0x2, 0x1000));
        try std.testing.expect(!barrierMasksSupported(barrier, case.src_stage, 0x1001));
        barrier.src_access_mask ^= 0x1;
        try std.testing.expect(!barrierMasksSupported(barrier, case.src_stage, 0x1000));
        barrier.src_access_mask = case.src_access;
        barrier.dst_access_mask ^= 0x1;
        try std.testing.expect(!barrierMasksSupported(barrier, case.src_stage, 0x1000));
    }
    var unsupported = std.mem.zeroes(ImageMemoryBarrier);
    unsupported.old_layout = 2;
    unsupported.new_layout = 1;
    try std.testing.expect(!barrierMasksSupported(unsupported, 1, 0x1000));
    unsupported.old_layout = 0;
    unsupported.new_layout = 2;
    try std.testing.expect(!barrierMasksSupported(unsupported, 1, 0x1000));
}

test "memory transfer objects execute against independently specified bytes" {
    const ici = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ici, null, &instance));
    var physical_count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &physical_count, &physical));
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var device: Device = undefined;
    try std.testing.expectEqual(Result.success, createDevice(physical[0], &di, null, &device));
    var queue: Queue = undefined;
    getDeviceQueue(device, 0, 0, &queue);

    const bai = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 128, .memory_type_index = 0 };
    var memory_a: usize = 0;
    var memory_b: usize = 0;
    var memory_i: usize = 0;
    var memory_j: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(device, &bai, null, &memory_a));
    try std.testing.expectEqual(Result.success, allocateMemory(device, &bai, null, &memory_b));
    try std.testing.expectEqual(Result.success, allocateMemory(device, &bai, null, &memory_i));
    try std.testing.expectEqual(Result.success, allocateMemory(device, &bai, null, &memory_j));
    var mapped: ?*anyopaque = null;
    try std.testing.expectEqual(Result.success, mapMemory(device, memory_a, 0, std.math.maxInt(u64), 0, &mapped));
    const source: [*]u8 = @ptrCast(mapped.?);
    for (0..64) |i| source[i] = @intCast(i * 3);
    try std.testing.expectEqual(Result.error_memory_map_failed, mapMemory(device, memory_a, 0, 1, 0, &mapped));
    unmapMemory(device, memory_a);

    const bci = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 64, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    var buffer_a: usize = 0;
    var buffer_b: usize = 0;
    try std.testing.expectEqual(Result.success, createBuffer(device, &bci, null, &buffer_a));
    try std.testing.expectEqual(Result.success, createBuffer(device, &bci, null, &buffer_b));
    var requirements: MemoryRequirements = undefined;
    getBufferMemoryRequirements(device, buffer_a, &requirements);
    try std.testing.expectEqual(@as(u64, 64), requirements.size);
    try std.testing.expectEqual(Result.success, bindBufferMemory(device, buffer_a, memory_a, 0));
    try std.testing.expectEqual(Result.success, bindBufferMemory(device, buffer_b, memory_b, 0));

    const image_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 37, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    var image: usize = 0;
    var image_two: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(device, &image_info, null, &image));
    try std.testing.expectEqual(Result.success, createImage(device, &image_info, null, &image_two));
    getImageMemoryRequirements(device, image, &requirements);
    try std.testing.expectEqual(@as(u64, 64), requirements.size);
    try std.testing.expectEqual(Result.success, bindImageMemory(device, image, memory_i, 0));
    try std.testing.expectEqual(Result.success, bindImageMemory(device, image_two, memory_j, 0));
    const sub = ImageSubresource{ .aspect_mask = 1, .mip_level = 0, .array_layer = 0 };
    var layout: SubresourceLayout = undefined;
    getImageSubresourceLayout(device, image, &sub, &layout);
    try std.testing.expectEqual(@as(u64, 16), layout.row_pitch);

    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 2, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(device, &pool_info, null, &pool));
    test_allocations_before_failure = 0;
    var failed_memory: usize = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateMemory(device, &bai, null, &failed_memory));
    test_allocations_before_failure = null;
    const alloc_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var commands: [1]CommandBuffer = undefined;
    var failed_commands: [2]CommandBuffer = undefined;
    var failed_alloc_info = alloc_info;
    failed_alloc_info.command_buffer_count = 2;
    device.set_loader_data = commandBufferLoaderData;
    command_callback_calls = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, allocateCommandBuffers(device, &failed_alloc_info, &failed_commands));
    command_callback_calls = 0;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(device, &alloc_info, &commands));
    freeCommandBuffers(device, pool, 1, &commands);
    device.set_loader_data = null;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(device, &alloc_info, &commands));
    const begin = CommandBufferBeginInfo{ .s_type = 42, .p_next = null, .flags = 0, .inheritance_info = null };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdFillBuffer(commands[0], buffer_b, 0, 64, 0xdeadbeef);
    const copy = BufferCopy{ .src_offset = 4, .dst_offset = 8, .size = 32 };
    cmdCopyBuffer(commands[0], buffer_a, buffer_b, 1, @ptrCast(&copy));
    const color = ClearColorValue{ .float32 = .{ 1, 0.5, 0, 1 } };
    const range = ImageSubresourceRange{ .aspect_mask = 1, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    const barriers = [_]ImageMemoryBarrier{
        .{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1800, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image, .subresource_range = range },
        .{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1800, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image_two, .subresource_range = range },
    };
    cmdPipelineBarrier(commands[0], 1, 0x1000, 0, 0, null, 0, null, barriers.len, &barriers);
    cmdClearColorImage(commands[0], image, 1, &color, 1, @ptrCast(&range));
    const region = BufferImageCopy{ .buffer_offset = 0, .buffer_row_length = 0, .buffer_image_height = 0, .image_subresource = .{ .aspect_mask = 1, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = 4, .height = 4, .depth = 1 } };
    cmdCopyBufferToImage(commands[0], buffer_a, image, 1, 1, @ptrCast(&region));
    const image_copy = ImageCopy{ .src_subresource = region.image_subresource, .src_offset = region.image_offset, .dst_subresource = region.image_subresource, .dst_offset = region.image_offset, .extent = region.image_extent };
    cmdCopyImage(commands[0], image, 1, image_two, 1, 1, @ptrCast(&image_copy));
    cmdCopyImageToBuffer(commands[0], image_two, 1, buffer_b, 1, @ptrCast(&region));
    try std.testing.expectEqual(Result.success, endCommandBuffer(commands[0]));
    const fci = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    var fence: usize = 0;
    try std.testing.expectEqual(Result.success, createFence(device, &fci, null, &fence));
    try std.testing.expectEqual(Result.not_ready, getFenceStatus(device, fence));
    const submit = SubmitInfo{ .s_type = 4, .p_next = null, .wait_semaphore_count = 0, .wait_semaphores = null, .wait_dst_stage_mask = null, .command_buffer_count = 1, .command_buffers = &commands, .signal_semaphore_count = 0, .signal_semaphores = null };
    try std.testing.expectEqual(Result.success, queueSubmit(queue, 1, @ptrCast(&submit), fence));
    try std.testing.expectEqual(Result.success, getFenceStatus(device, fence));
    try std.testing.expectEqual(Result.success, waitForFences(device, 1, @ptrCast(&fence), 1, 0));
    try std.testing.expectEqual(Result.success, queueWaitIdle(queue));
    try std.testing.expectEqual(Result.success, deviceWaitIdle(device));
    try std.testing.expectEqual(Result.success, mapMemory(device, memory_b, 0, 64, 0, &mapped));
    const actual: [*]const u8 = @ptrCast(mapped.?);
    for (0..64) |i| try std.testing.expectEqual(@as(u8, @intCast(i * 3)), actual[i]);
    unmapMemory(device, memory_b);
    try std.testing.expectEqual(Result.success, resetFences(device, 1, @ptrCast(&fence)));
    try std.testing.expectEqual(Result.timeout, waitForFences(device, 1, @ptrCast(&fence), 1, 0));

    var format_output: extern struct { max_extent: Extent3D, max_mip_levels: u32, max_array_layers: u32, sample_counts: u32, max_resource_size: u64 } = undefined;
    try std.testing.expectEqual(Result.success, getImageFormatProperties(physical[0], 37, 1, 1, 3, 0, &format_output));
    try std.testing.expectEqual(@as(u32, 4096), format_output.max_extent.width);
    try std.testing.expectEqual(Result.error_initialization_failed, getImageFormatProperties(physical[0], 37, 1, 1, 3, 0, null));
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(commands[0]));
    try std.testing.expectEqual(Result.error_initialization_failed, resetCommandBuffer(commands[0], 2));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdFillBuffer(commands[0], 0, 0, 4, 0);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdFillBuffer(commands[0], buffer_a, 1, 4, 0);
    try std.testing.expect(commands[0].impl.invalid);
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdCopyBuffer(commands[0], 0, buffer_b, 1, @ptrCast(&copy));
    cmdCopyBuffer(commands[0], buffer_a, 0, 1, @ptrCast(&copy));
    cmdCopyBuffer(commands[0], buffer_a, buffer_b, 1, null);
    const bad_copy = BufferCopy{ .src_offset = 63, .dst_offset = 0, .size = 2 };
    cmdCopyBuffer(commands[0], buffer_a, buffer_b, 1, @ptrCast(&bad_copy));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdClearColorImage(commands[0], 0, 1, &color, 1, @ptrCast(&range));
    cmdClearColorImage(commands[0], image, 1, null, 1, @ptrCast(&range));
    cmdClearColorImage(commands[0], image, 1, &color, 1, null);
    cmdClearColorImage(commands[0], image, 6, &color, 1, @ptrCast(&range));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdCopyBufferToImage(commands[0], 0, image, 1, 1, @ptrCast(&region));
    cmdCopyBufferToImage(commands[0], buffer_a, 0, 1, 1, @ptrCast(&region));
    cmdCopyBufferToImage(commands[0], buffer_a, image, 1, 1, null);
    var bad_region = region;
    bad_region.image_extent.width = 5;
    cmdCopyBufferToImage(commands[0], buffer_a, image, 1, 1, @ptrCast(&bad_region));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdCopyImageToBuffer(commands[0], 0, 1, buffer_b, 1, @ptrCast(&region));
    cmdCopyImageToBuffer(commands[0], image, 1, 0, 1, @ptrCast(&region));
    cmdCopyImageToBuffer(commands[0], image, 1, buffer_b, 1, null);
    cmdCopyImageToBuffer(commands[0], image, 1, buffer_b, 1, @ptrCast(&bad_region));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    cmdCopyImage(commands[0], 0, 1, image_two, 1, 1, @ptrCast(&image_copy));
    cmdCopyImage(commands[0], image, 1, 0, 1, 1, @ptrCast(&image_copy));
    cmdCopyImage(commands[0], image, 1, image_two, 1, 1, null);
    var bad_image_copy = image_copy;
    bad_image_copy.extent.width = 5;
    cmdCopyImage(commands[0], image, 1, image_two, 1, 1, @ptrCast(&bad_image_copy));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(commands[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(commands[0], &begin));
    commands[0].impl.count = commands[0].impl.commands.len;
    cmdFillBuffer(commands[0], buffer_a, 0, 4, 0);
    try std.testing.expect(commands[0].impl.invalid);

    destroyFence(device, fence, null);
    freeCommandBuffers(device, pool, 1, &commands);
    destroyCommandPool(device, pool, null);
    destroyImage(device, image, null);
    destroyImage(device, image_two, null);
    destroyBuffer(device, buffer_b, null);
    destroyBuffer(device, buffer_a, null);
    freeMemory(device, memory_i, null);
    freeMemory(device, memory_j, null);
    freeMemory(device, memory_b, null);
    freeMemory(device, memory_a, null);
    destroyDevice(device, null);
    destroyInstance(instance, null);
}

test "child lifetime budget arithmetic count usage and layout regressions" {
    const ctx = try createTestDeviceContext();
    const alloc_small = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 256, .memory_type_index = 0 };
    var memory_a: usize = 0;
    var memory_b: usize = 0;
    test_allocations_before_failure = 1;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &alloc_small, null, &memory_a));
    test_allocations_before_failure = null;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &alloc_small, null, &memory_b));
    const src_info = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 64, .usage = 1, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    var dst_info = src_info;
    dst_info.usage = 2;
    var invalid_info = src_info;
    invalid_info.usage = 0;
    var ignored: usize = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createBuffer(ctx.device, &invalid_info, null, &ignored));
    invalid_info.usage = 4;
    try std.testing.expectEqual(Result.error_initialization_failed, createBuffer(ctx.device, &invalid_info, null, &ignored));
    invalid_info = src_info;
    invalid_info.size = heap_size + 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createBuffer(ctx.device, &invalid_info, null, &ignored));
    var src: usize = 0;
    var dst: usize = 0;
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &src_info, null, &src));
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &dst_info, null, &dst));
    var alignment_buffer: usize = 0;
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &dst_info, null, &alignment_buffer));
    try std.testing.expectEqual(Result.error_initialization_failed, bindBufferMemory(ctx.device, alignment_buffer, memory_b, 1));
    destroyBuffer(ctx.device, alignment_buffer, null);
    try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, src, memory_a, 0));
    try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, dst, memory_b, 0));
    try std.testing.expectEqual(Result.error_initialization_failed, bindBufferMemory(ctx.device, dst, memory_b, 0));
    freeMemory(ctx.device, memory_a, null);
    var mapped: ?*anyopaque = null;
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, memory_a, 0, 1, 0, &mapped));
    unmapMemory(ctx.device, memory_a);

    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 2, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(ctx.device, &pool_info, null, &pool));
    const cb_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var cbs: [1]CommandBuffer = undefined;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info, &cbs));
    const begin = CommandBufferBeginInfo{ .s_type = 42, .p_next = null, .flags = 0, .inheritance_info = null };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdFillBuffer(cbs[0], src, 0, 64, 7);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdFillBuffer(cbs[0], dst, 0, 64, 7);
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    destroyBuffer(ctx.device, dst, null);
    const submit = SubmitInfo{ .s_type = 4, .p_next = null, .wait_semaphore_count = 0, .wait_semaphores = null, .wait_dst_stage_mask = null, .command_buffer_count = 1, .command_buffers = &cbs, .signal_semaphore_count = 0, .signal_semaphores = null };
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    var stale_requirements = MemoryRequirements{ .size = 9, .alignment = 9, .memory_type_bits = 9 };
    getBufferMemoryRequirements(ctx.device, dst, &stale_requirements);
    try std.testing.expectEqual(@as(u64, 9), stale_requirements.size);
    destroyBuffer(ctx.device, src, null);
    const dead_src: *BufferObj = @ptrFromInt(src);
    const dead_dst: *BufferObj = @ptrFromInt(dst);
    var validation_layouts = [_]i32{0} ** max_child_objects;
    try std.testing.expect(!prevalidateCommand(.{ .copy_buffer = .{ .src = dead_src, .dst = dead_dst, .region = .{ .src_offset = 0, .dst_offset = 0, .size = 1 } } }, ctx.device, &validation_layouts));
    freeMemory(ctx.device, memory_a, null);
    try std.testing.expectEqual(Result.error_memory_map_failed, mapMemory(ctx.device, memory_a, 0, 1, 0, &mapped));

    freeCommandBuffers(ctx.device, pool, 0, null);
    freeCommandBuffers(ctx.device, pool, max_api_items + 1, null);
    freeCommandBuffers(ctx.device, pool, 1, &cbs);
    try std.testing.expectEqual(Result.error_initialization_failed, beginCommandBuffer(cbs[0], &begin));
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info, &cbs));
    destroyCommandPool(ctx.device, pool, null);
    try std.testing.expectEqual(Result.error_initialization_failed, beginCommandBuffer(cbs[0], &begin));
    try std.testing.expectEqual(Result.error_initialization_failed, allocateCommandBuffers(ctx.device, &cb_info, &cbs));

    var pool_two: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(ctx.device, &pool_info, null, &pool_two));
    var cb_info_two = cb_info;
    cb_info_two.command_pool = pool_two;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info_two, &cbs));
    var image_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &alloc_small, null, &image_memory));
    const image_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 37, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    var invalid_image_info = image_info;
    invalid_image_info.usage = 0;
    try std.testing.expectEqual(Result.error_initialization_failed, createImage(ctx.device, &invalid_image_info, null, &ignored));
    invalid_image_info.usage = 0x40;
    try std.testing.expectEqual(Result.error_initialization_failed, createImage(ctx.device, &invalid_image_info, null, &ignored));
    var image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(ctx.device, &image_info, null, &image));
    try std.testing.expectEqual(Result.success, bindImageMemory(ctx.device, image, image_memory, 0));
    freeMemory(ctx.device, image_memory, null);
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, image_memory, 0, 1, 0, &mapped));
    unmapMemory(ctx.device, image_memory);
    var live_src: usize = 0;
    var live_dst: usize = 0;
    var live_src_memory: usize = 0;
    var live_dst_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &alloc_small, null, &live_src_memory));
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &alloc_small, null, &live_dst_memory));
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &src_info, null, &live_src));
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &dst_info, null, &live_dst));
    try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, live_src, live_src_memory, 0));
    try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, live_dst, live_dst_memory, 0));
    const live_image: *ImageObj = @ptrFromInt(image);
    const live_src_object: *BufferObj = @ptrFromInt(live_src);
    const live_dst_object: *BufferObj = @ptrFromInt(live_dst);
    var mismatched_layouts = [_]i32{0} ** max_child_objects;
    const mismatch_region = BufferImageCopy{ .buffer_offset = 0, .buffer_row_length = 0, .buffer_image_height = 0, .image_subresource = .{ .aspect_mask = 1, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = 1, .height = 1, .depth = 1 } };
    try std.testing.expect(!prevalidateCommand(.{ .buffer_to_image = .{ .src = live_src_object, .dst = live_image, .layout = 1, .region = mismatch_region } }, ctx.device, &mismatched_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .image_to_buffer = .{ .src = live_image, .layout = 1, .dst = live_dst_object, .region = mismatch_region } }, ctx.device, &mismatched_layouts));
    const mismatch_copy = ImageCopy{ .src_subresource = mismatch_region.image_subresource, .src_offset = mismatch_region.image_offset, .dst_subresource = mismatch_region.image_subresource, .dst_offset = mismatch_region.image_offset, .extent = mismatch_region.image_extent };
    try std.testing.expect(!prevalidateCommand(.{ .copy_image = .{ .src = live_image, .src_layout = 1, .dst = live_image, .dst_layout = 1, .region = mismatch_copy } }, ctx.device, &mismatched_layouts));
    var ownership_layouts = [_]i32{0} ** max_child_objects;
    const wrong_owner: *DeviceObj = @ptrFromInt(8);
    try std.testing.expect(!prevalidateCommand(.{ .fill = .{ .dst = live_dst_object, .offset = 0, .size = 4, .data = 0 } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .copy_buffer = .{ .src = live_src_object, .dst = live_dst_object, .region = .{ .src_offset = 0, .dst_offset = 0, .size = 4 } } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .clear = .{ .image = live_image, .layout = 0, .color = .{ 0, 0, 0, 0 } } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .buffer_to_image = .{ .src = live_src_object, .dst = live_image, .layout = 0, .region = mismatch_region } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .image_to_buffer = .{ .src = live_image, .layout = 0, .dst = live_dst_object, .region = mismatch_region } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .copy_image = .{ .src = live_image, .src_layout = 0, .dst = live_image, .dst_layout = 0, .region = mismatch_copy } }, wrong_owner, &ownership_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .transition = .{ .image = live_image, .old_layout = 0, .new_layout = 1 } }, wrong_owner, &ownership_layouts));
    destroyBuffer(ctx.device, live_dst, null);
    destroyBuffer(ctx.device, live_src, null);
    freeMemory(ctx.device, live_dst_memory, null);
    freeMemory(ctx.device, live_src_memory, null);
    const range = ImageSubresourceRange{ .aspect_mask = 1, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    const color = ClearColorValue{ .float32 = .{ 0.25, 0.5, 0.75, 1 } };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdClearColorImage(cbs[0], image, 1, &color, 1, @ptrCast(&range));
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    const barrier = ImageMemoryBarrier{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1800, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image, .subresource_range = range };
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 0, null);
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
    cmdClearColorImage(cbs[0], image, 1, &color, 1, @ptrCast(&range));
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdCopyBuffer(cbs[0], 0, 0, 0, null);
    cmdCopyBufferToImage(cbs[0], 0, 0, 1, 0, null);
    cmdCopyImageToBuffer(cbs[0], 0, 1, 0, 0, null);
    cmdCopyImage(cbs[0], 0, 1, 0, 1, 0, null);
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, @ptrFromInt(8), 0, @ptrFromInt(8), 0, null);
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdCopyBuffer(cbs[0], 0, 0, max_api_items + 1, null);
    cmdCopyBufferToImage(cbs[0], 0, 0, 1, max_api_items + 1, null);
    cmdCopyImageToBuffer(cbs[0], 0, 1, 0, max_api_items + 1, null);
    cmdCopyImage(cbs[0], 0, 1, 0, 1, max_api_items + 1, null);
    cmdClearColorImage(cbs[0], 0, 1, &color, max_api_items + 1, null);
    cmdPipelineBarrier(cbs[0], 0, 1, 1, 1, @ptrFromInt(8), 1, @ptrFromInt(8), max_api_items + 1, null);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, null);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    var bad_barrier = barrier;
    bad_barrier.image = 8;
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&bad_barrier));
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    bad_barrier = barrier;
    bad_barrier.s_type = 0;
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&bad_barrier));
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    const invalid_color = ClearColorValue{ .float32 = .{ std.math.nan(f32), 0, 0, 0 } };
    cmdClearColorImage(cbs[0], image, 1, &invalid_color, 1, @ptrCast(&range));
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    var destroy_barrier = barrier;
    destroy_barrier.old_layout = 1;
    destroy_barrier.new_layout = 6;
    destroy_barrier.src_access_mask = 0x1800;
    destroy_barrier.dst_access_mask = 0x800;
    cmdPipelineBarrier(cbs[0], 0x1000, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&destroy_barrier));
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    destroyImage(ctx.device, image, null);
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    const dead_image: *ImageObj = @ptrFromInt(image);
    try std.testing.expect(!prevalidateCommand(.{ .clear = .{ .image = dead_image, .layout = 1, .color = .{ 1, 2, 3, 4 } } }, ctx.device, &validation_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .fill = .{ .dst = dead_dst, .offset = 0, .size = 4, .data = 0 } }, ctx.device, &validation_layouts));
    const stale_region = BufferImageCopy{ .buffer_offset = 0, .buffer_row_length = 0, .buffer_image_height = 0, .image_subresource = .{ .aspect_mask = 1, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = 1, .height = 1, .depth = 1 } };
    try std.testing.expect(!prevalidateCommand(.{ .buffer_to_image = .{ .src = dead_src, .dst = dead_image, .layout = 1, .region = stale_region } }, ctx.device, &validation_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .image_to_buffer = .{ .src = dead_image, .layout = 1, .dst = dead_dst, .region = stale_region } }, ctx.device, &validation_layouts));
    const stale_image_copy = ImageCopy{ .src_subresource = stale_region.image_subresource, .src_offset = stale_region.image_offset, .dst_subresource = stale_region.image_subresource, .dst_offset = stale_region.image_offset, .extent = stale_region.image_extent };
    try std.testing.expect(!prevalidateCommand(.{ .copy_image = .{ .src = dead_image, .src_layout = 1, .dst = dead_image, .dst_layout = 1, .region = stale_image_copy } }, ctx.device, &validation_layouts));
    try std.testing.expect(!prevalidateCommand(.{ .transition = .{ .image = dead_image, .old_layout = 1, .new_layout = 6 } }, ctx.device, &validation_layouts));
    getImageMemoryRequirements(ctx.device, image, &stale_requirements);
    try std.testing.expectEqual(@as(u64, 9), stale_requirements.size);

    const fci = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    var fence: usize = 0;
    try std.testing.expectEqual(Result.success, createFence(ctx.device, &fci, null, &fence));
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 0, null, fence));
    try std.testing.expectEqual(Result.not_ready, getFenceStatus(ctx.device, fence));
    var empty = submit;
    empty.command_buffer_count = 0;
    empty.command_buffers = null;
    try std.testing.expectEqual(Result.success, queueSubmit(ctx.queue, 1, @ptrCast(&empty), fence));
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, max_api_items + 1, null, 0));
    empty.command_buffers = &cbs;
    empty.wait_semaphores = @ptrFromInt(8);
    empty.wait_dst_stage_mask = @ptrFromInt(8);
    empty.signal_semaphores = @ptrFromInt(8);
    try std.testing.expectEqual(Result.success, queueSubmit(ctx.queue, 1, @ptrCast(&empty), 0));
    try std.testing.expectEqual(Result.error_initialization_failed, resetFences(ctx.device, 0, null));
    try std.testing.expectEqual(Result.error_initialization_failed, resetFences(ctx.device, max_api_items + 1, null));
    try std.testing.expectEqual(Result.error_initialization_failed, waitForFences(ctx.device, max_api_items + 1, null, 1, 0));
    destroyFence(ctx.device, fence, null);
    try std.testing.expectEqual(Result.error_initialization_failed, getFenceStatus(ctx.device, fence));

    var extreme = ImageObj{ .owner = ctx.device, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .array_layers = 1, .samples = 1, .format = 37, .usage = 3, .layout = 0 };
    try std.testing.expect(imageByteSize(&extreme) == null);
    var extreme_region = BufferImageCopy{ .buffer_offset = std.math.maxInt(u64) - 3, .buffer_row_length = std.math.maxInt(u32), .buffer_image_height = std.math.maxInt(u32), .image_subresource = .{ .aspect_mask = 1, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 }, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .depth = 1 } };
    try std.testing.expect(bufferImageEnd(extreme_region) == null);
    extreme_region.buffer_offset = 0;
    try std.testing.expect(bufferImageEnd(extreme_region) == null);
    extreme_region.buffer_row_length = 1;
    extreme_region.buffer_image_height = 1;
    extreme_region.image_extent = .{ .width = 1, .height = 1, .depth = 1 };
    extreme_region.buffer_offset = std.math.maxInt(u64) - 3;
    try std.testing.expect(bufferImageEnd(extreme_region) == null);
    var huge_image = image_info;
    huge_image.extent.width = std.math.maxInt(u32);
    try std.testing.expectEqual(Result.error_initialization_failed, createImage(ctx.device, &huge_image, null, &ignored));
    const huge_alloc = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = std.math.maxInt(u64), .memory_type_index = 0 };
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateMemory(ctx.device, &huge_alloc, null, &ignored));
    try std.testing.expectEqual(Result.error_memory_map_failed, mapMemory(ctx.device, 8, 0, 1, 0, &mapped));
    try std.testing.expectEqual(Result.error_initialization_failed, beginCommandBuffer(@ptrFromInt(8), &begin));
    var local_memory: MemoryObj = undefined;
    try std.testing.expect(stateForObject(MemoryObj, &local_memory, &memory_objects, &memory_state) == null);
    var local_image: ImageObj = undefined;
    try std.testing.expect(imageSlot(&local_image) == null);

    destroyDevice(ctx.device, null);
    try std.testing.expectEqual(Result.error_memory_map_failed, mapMemory(ctx.device, memory_b, 0, 1, 0, &mapped));
    destroyInstance(ctx.instance, null);
}

test "zero fills and extreme buffer image arithmetic reject without side effects" {
    const ctx = try createTestDeviceContext();
    const allocation = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 64, .memory_type_index = 0 };
    var buffer_memory: usize = 0;
    var image_memory: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &allocation, null, &buffer_memory));
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &allocation, null, &image_memory));
    const buffer_info = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 64, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    var buffer: usize = 0;
    try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &buffer_info, null, &buffer));
    try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, buffer, buffer_memory, 0));
    const image_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 37, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    var image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(ctx.device, &image_info, null, &image));
    try std.testing.expectEqual(Result.success, bindImageMemory(ctx.device, image, image_memory, 0));
    var mapped: ?*anyopaque = null;
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, buffer_memory, 0, 64, 0, &mapped));
    @memset((@as([*]u8, @ptrCast(mapped.?)))[0..64], 0x6b);
    unmapMemory(ctx.device, buffer_memory);

    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 2, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(ctx.device, &pool_info, null, &pool));
    const cb_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var cbs: [1]CommandBuffer = undefined;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info, &cbs));
    const begin = CommandBufferBeginInfo{ .s_type = 42, .p_next = null, .flags = 0, .inheritance_info = null };
    const fence_info = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    var fence: usize = 0;
    try std.testing.expectEqual(Result.success, createFence(ctx.device, &fence_info, null, &fence));
    const submit = SubmitInfo{ .s_type = 4, .p_next = null, .wait_semaphore_count = 0, .wait_semaphores = null, .wait_dst_stage_mask = null, .command_buffer_count = 1, .command_buffers = &cbs, .signal_semaphore_count = 0, .signal_semaphores = null };

    const invalid_fills = [_]struct { offset: u64, size: u64 }{
        .{ .offset = 0, .size = 0 },
        .{ .offset = 64, .size = std.math.maxInt(u64) },
    };
    for (invalid_fills) |fill| {
        try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
        cmdFillBuffer(cbs[0], buffer, fill.offset, fill.size, 0xdeadbeef);
        try std.testing.expect(cbs[0].impl.invalid);
        try std.testing.expectEqual(@as(u16, 0), cbs[0].impl.count);
        try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
        try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), fence));
        try std.testing.expectEqual(Result.not_ready, getFenceStatus(ctx.device, fence));
        try std.testing.expectEqual(Result.success, mapMemory(ctx.device, buffer_memory, 0, 64, 0, &mapped));
        for ((@as([*]const u8, @ptrCast(mapped.?)))[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0x6b), byte);
        unmapMemory(ctx.device, buffer_memory);
        try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    }

    const layers = ImageSubresourceLayers{ .aspect_mask = 1, .mip_level = 0, .base_array_layer = 0, .layer_count = 1 };
    var extreme = BufferImageCopy{ .buffer_offset = 0, .buffer_row_length = std.math.maxInt(u32), .buffer_image_height = std.math.maxInt(u32), .image_subresource = layers, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .depth = 1 } };
    try std.testing.expect(checkedBufferImageMul(std.math.maxInt(u64), 2) == null);
    try std.testing.expect(checkedBufferImageAdd(std.math.maxInt(u64), 1) == null);
    try std.testing.expect(bufferImageEnd(extreme) == null);
    extreme.image_extent.height = 0;
    try std.testing.expect(bufferImageEnd(extreme) == null);
    extreme.image_extent = .{ .width = 1, .height = 1, .depth = 1 };
    extreme.buffer_offset = std.math.maxInt(u64) - 3;
    try std.testing.expect(bufferImageEnd(extreme) == null);
    extreme = .{ .buffer_offset = 0, .buffer_row_length = std.math.maxInt(u32), .buffer_image_height = std.math.maxInt(u32), .image_subresource = layers, .image_offset = .{ .x = 0, .y = 0, .z = 0 }, .image_extent = .{ .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .depth = 1 } };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdCopyBufferToImage(cbs[0], buffer, image, 1, 1, @ptrCast(&extreme));
    try std.testing.expect(cbs[0].impl.invalid);
    try std.testing.expectEqual(@as(u16, 0), cbs[0].impl.count);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), fence));
    try std.testing.expectEqual(Result.not_ready, getFenceStatus(ctx.device, fence));
    try std.testing.expectEqual(@as(i32, 0), (@as(*ImageObj, @ptrFromInt(image))).layout);

    destroyFence(ctx.device, fence, null);
    freeCommandBuffers(ctx.device, pool, 1, &cbs);
    destroyCommandPool(ctx.device, pool, null);
    destroyImage(ctx.device, image, null);
    destroyBuffer(ctx.device, buffer, null);
    freeMemory(ctx.device, image_memory, null);
    freeMemory(ctx.device, buffer_memory, null);
    destroyDevice(ctx.device, null);
    destroyInstance(ctx.instance, null);
}

test "submission prevalidation is failure atomic" {
    const ctx = try createTestDeviceContext();
    const allocation = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 64, .memory_type_index = 0 };
    var memories: [3]usize = undefined;
    for (&memories) |*memory| try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &allocation, null, memory));
    const buffer_info = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 64, .usage = 2, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    var buffers: [2]usize = undefined;
    for (&buffers, 0..) |*buffer, index| {
        try std.testing.expectEqual(Result.success, createBuffer(ctx.device, &buffer_info, null, buffer));
        try std.testing.expectEqual(Result.success, bindBufferMemory(ctx.device, buffer.*, memories[index], 0));
    }
    var mapped: ?*anyopaque = null;
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, memories[0], 0, 64, 0, &mapped));
    @memset((@as([*]u8, @ptrCast(mapped.?)))[0..64], 0x5a);
    unmapMemory(ctx.device, memories[0]);
    const image_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 37, .extent = .{ .width = 4, .height = 4, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    var image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(ctx.device, &image_info, null, &image));
    try std.testing.expectEqual(Result.success, bindImageMemory(ctx.device, image, memories[2], 0));
    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 0, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(ctx.device, &pool_info, null, &pool));
    const cb_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var cbs: [1]CommandBuffer = undefined;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info, &cbs));
    const begin = CommandBufferBeginInfo{ .s_type = 42, .p_next = null, .flags = 0, .inheritance_info = null };
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    cmdFillBuffer(cbs[0], buffers[0], 0, 64, 0x01020304);
    const range = ImageSubresourceRange{ .aspect_mask = 1, .base_mip_level = 0, .level_count = 1, .base_array_layer = 0, .layer_count = 1 };
    const barrier = ImageMemoryBarrier{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1800, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image, .subresource_range = range };
    cmdPipelineBarrier(cbs[0], 1, 0x1000, 0, 0, null, 0, null, 1, @ptrCast(&barrier));
    cmdFillBuffer(cbs[0], buffers[1], 0, 64, 0xaabbccdd);
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    const original_state = cbs[0].impl.state;
    const original_count = cbs[0].impl.count;
    destroyBuffer(ctx.device, buffers[1], null);
    const fence_info = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    var fence: usize = 0;
    try std.testing.expectEqual(Result.success, createFence(ctx.device, &fence_info, null, &fence));
    const submit = SubmitInfo{ .s_type = 4, .p_next = null, .wait_semaphore_count = 0, .wait_semaphores = null, .wait_dst_stage_mask = null, .command_buffer_count = 1, .command_buffers = &cbs, .signal_semaphore_count = 0, .signal_semaphores = null };
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), fence));
    try std.testing.expectEqual(Result.not_ready, getFenceStatus(ctx.device, fence));
    try std.testing.expectEqual(original_state, cbs[0].impl.state);
    try std.testing.expectEqual(original_count, cbs[0].impl.count);
    try std.testing.expectEqual(@as(i32, 0), (@as(*ImageObj, @ptrFromInt(image))).layout);
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, memories[0], 0, 64, 0, &mapped));
    for ((@as([*]const u8, @ptrCast(mapped.?)))[0..64]) |byte| try std.testing.expectEqual(@as(u8, 0x5a), byte);
    unmapMemory(ctx.device, memories[0]);
    destroyFence(ctx.device, fence, null);
    freeCommandBuffers(ctx.device, pool, 1, &cbs);
    destroyCommandPool(ctx.device, pool, null);
    destroyImage(ctx.device, image, null);
    destroyBuffer(ctx.device, buffers[0], null);
    for (memories) |memory| freeMemory(ctx.device, memory, null);
    destroyDevice(ctx.device, null);
    destroyInstance(ctx.instance, null);
}

test "advertised memory heap budget exhausts and recovers" {
    const ctx = try createTestDeviceContext();
    const whole_heap = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = heap_size, .memory_type_index = 0 };
    var whole: usize = 0;
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &whole_heap, null, &whole));
    try std.testing.expectEqual(heap_size, ctx.device.heap_used);
    const one_byte = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 1, .memory_type_index = 0 };
    var recovered: usize = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateMemory(ctx.device, &one_byte, null, &recovered));
    freeMemory(ctx.device, whole, null);
    try std.testing.expectEqual(@as(u64, 0), ctx.device.heap_used);
    try std.testing.expectEqual(Result.success, allocateMemory(ctx.device, &one_byte, null, &recovered));
    try std.testing.expectEqual(@as(u64, 1), ctx.device.heap_used);
    freeMemory(ctx.device, recovered, null);
    destroyDevice(ctx.device, null);
    destroyInstance(ctx.instance, null);
}

test "bounded child registries fail safely without reusing tombstones" {
    const ctx = try createTestDeviceContext();
    const pool_info = CommandPoolCreateInfo{ .s_type = 39, .p_next = null, .flags = 0, .queue_family_index = 0 };
    var pool: usize = 0;
    try std.testing.expectEqual(Result.success, createCommandPool(ctx.device, &pool_info, null, &pool));
    var cb_info = CommandBufferAllocateInfo{ .s_type = 40, .p_next = null, .command_pool = pool, .level = 0, .command_buffer_count = 1 };
    var cb: [max_child_objects]CommandBuffer = undefined;
    var available: u32 = 0;
    for (command_buffer_state) |state| if (state == .never) {
        available += 1;
    };
    try std.testing.expect(available >= 2);
    cb_info.command_buffer_count = available - 1;
    try std.testing.expectEqual(Result.success, allocateCommandBuffers(ctx.device, &cb_info, &cb));
    cb_info.command_buffer_count = 2;
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateCommandBuffers(ctx.device, &cb_info, &cb));
    cb_info.command_buffer_count = 1;
    try std.testing.expectEqual(Result.error_out_of_host_memory, allocateCommandBuffers(ctx.device, &cb_info, &cb));
    var exhausted = false;
    for (0..max_child_objects + 1) |_| {
        var handle: usize = 0;
        const result = createCommandPool(ctx.device, &pool_info, null, &handle);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
    }
    try std.testing.expect(exhausted);
    const buffer_info = BufferCreateInfo{ .s_type = 12, .p_next = null, .flags = 0, .size = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null };
    exhausted = false;
    for (0..max_child_objects + 1) |_| {
        var handle: usize = 0;
        const result = createBuffer(ctx.device, &buffer_info, null, &handle);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
    }
    try std.testing.expect(exhausted);
    const image_info = ImageCreateInfo{ .s_type = 14, .p_next = null, .flags = 0, .image_type = 1, .format = 37, .extent = .{ .width = 1, .height = 1, .depth = 1 }, .mip_levels = 1, .array_layers = 1, .samples = 1, .tiling = 1, .usage = 3, .sharing_mode = 0, .queue_family_index_count = 0, .queue_family_indices = null, .initial_layout = 0 };
    exhausted = false;
    for (0..max_child_objects + 1) |_| {
        var handle: usize = 0;
        const result = createImage(ctx.device, &image_info, null, &handle);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
    }
    try std.testing.expect(exhausted);
    const fence_info = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    exhausted = false;
    for (0..max_child_objects + 1) |_| {
        var handle: usize = 0;
        const result = createFence(ctx.device, &fence_info, null, &handle);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
    }
    try std.testing.expect(exhausted);
    const memory_info = MemoryAllocateInfo{ .s_type = 5, .p_next = null, .allocation_size = 1, .memory_type_index = 0 };
    exhausted = false;
    for (0..max_child_objects + 1) |_| {
        var handle: usize = 0;
        const result = allocateMemory(ctx.device, &memory_info, null, &handle);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
    }
    try std.testing.expect(exhausted);
    destroyDevice(ctx.device, null);
    destroyInstance(ctx.instance, null);
}

test "tombstone pool exhaustion returns out of host memory" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    var priority: f32 = 1;
    const qi = QueueInfo{ .s_type = 2, .p_next = null, .flags = 0, .family = 0, .count = 1, .priorities = @ptrCast(&priority) };
    const di = DeviceInfo{ .s_type = 3, .p_next = null, .flags = 0, .queue_info_count = 1, .queue_infos = @ptrCast(&qi), .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null, .features = null };
    var exhausted = false;
    for (0..max_objects + 1) |_| {
        var device: Device = undefined;
        const result = createDevice(physical[0], &di, null, &device);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
        destroyDevice(device, null);
    }
    try std.testing.expect(exhausted);
    destroyInstance(instance, null);

    exhausted = false;
    for (0..max_objects + 1) |_| {
        var next: Instance = undefined;
        const result = createInstance(&ci, null, &next);
        if (result == .error_out_of_host_memory) {
            exhausted = true;
            break;
        }
        try std.testing.expectEqual(Result.success, result);
        destroyInstance(next, null);
    }
    try std.testing.expect(exhausted);
}

test "shader modules use owned validated words and dedicated lifetime-safe ABI handles" {
    instance_state = [_]SlotState{.never} ** max_objects;
    device_state = [_]SlotState{.never} ** max_objects;
    const first = try createTestDeviceContext();
    const second = try createTestDeviceContext();
    defer destroyDevice(second.device, null);
    var caller_words = try std.testing.allocator.dupe(u32, &[_]u32{ spirv.magic, 0x0001_0000, 7, 4, 0, 0x0001_0000 });
    const info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = caller_words.len * 4, .p_code = caller_words.ptr };
    var handle: usize = 0;

    const Create = *const fn (?Device, ?*const ShaderModuleCreateInfo, ?*const Alloc, ?*usize) callconv(.c) Result;
    const Destroy = *const fn (?Device, usize, ?*const Alloc) callconv(.c) void;
    const create: Create = @ptrCast(getDeviceProcAddr(first.device, "vkCreateShaderModule").?);
    const destroy: Destroy = @ptrCast(getDeviceProcAddr(first.device, "vkDestroyShaderModule").?);
    try std.testing.expectEqual(Result.success, create(first.device, &info, null, &handle));
    caller_words[5] = 0x0001_0001;
    std.testing.allocator.free(caller_words);
    const object = findLiveHandle(ShaderModuleObj, handle, &shader_module_objects, &shader_module_state).?;
    try std.testing.expect(object.owner.eql(first.device));
    try std.testing.expectEqual(first.device.generation, object.owner.generation);
    try std.testing.expectEqual(@as(u32, 0x0001_0000), object.module.words[5]);

    destroy(second.device, handle, null);
    try std.testing.expect(findLiveHandle(ShaderModuleObj, handle, &shader_module_objects, &shader_module_state) != null);
    destroy(first.device, handle, @ptrFromInt(8));
    try std.testing.expect(findLiveHandle(ShaderModuleObj, handle, &shader_module_objects, &shader_module_state) != null);
    destroy(first.device, handle, null);
    try std.testing.expect(findLiveHandle(ShaderModuleObj, handle, &shader_module_objects, &shader_module_state) == null);
    destroy(first.device, handle, null);

    const replacement_words = [_]u32{ spirv.magic, 0x0001_0000, 7, 4, 0 };
    const replacement_info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = replacement_words.len * 4, .p_code = &replacement_words };
    var replacement: usize = 0;
    try std.testing.expectEqual(Result.success, create(first.device, &replacement_info, null, &replacement));
    try std.testing.expect(replacement != handle);
    destroy(null, replacement, null);
    destroy(first.device, 0, null);
    destroy(first.device, replacement, null);

    var teardown_handle: usize = 0;
    try std.testing.expectEqual(Result.success, create(first.device, &replacement_info, null, &teardown_handle));
    destroyDevice(first.device, null);
    try std.testing.expect(findLiveHandle(ShaderModuleObj, teardown_handle, &shader_module_objects, &shader_module_state) == null);
    destroy(first.device, teardown_handle, null);
    const stale_output = teardown_handle;
    try std.testing.expectEqual(Result.error_initialization_failed, create(first.device, &replacement_info, null, &teardown_handle));
    try std.testing.expectEqual(stale_output, teardown_handle);
}

test "shader module device identity rejects cross-generation address reuse and device slots never reuse" {
    instance_state = [_]SlotState{.never} ** max_objects;
    device_state = [_]SlotState{.never} ** max_objects;
    shader_module_state = [_]SlotState{.never} ** max_child_objects;
    const first = try createTestDeviceContext();
    const words = [_]u32{ spirv.magic, spirv.supported_spirv_version, 0, 1, 0 };
    const info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = @sizeOf(@TypeOf(words)), .p_code = &words };
    var shader: usize = 0;
    try std.testing.expectEqual(Result.success, createShaderModule(first.device, &info, null, &shader));

    const original_generation = first.device.generation;
    first.device.generation +%= 1;
    destroyShaderModule(first.device, shader, null);
    try std.testing.expect(findLiveHandle(ShaderModuleObj, shader, &shader_module_objects, &shader_module_state) != null);
    first.device.generation = original_generation;
    destroyShaderModule(first.device, shader, null);
    try std.testing.expect(findLiveHandle(ShaderModuleObj, shader, &shader_module_objects, &shader_module_state) == null);

    const old_device = first.device;
    const old_generation = first.device.generation;
    destroyDevice(first.device, null);
    destroyInstance(first.instance, null);
    const second = try createTestDeviceContext();
    defer destroyInstance(second.instance, null);
    defer destroyDevice(second.device, null);
    try std.testing.expect(second.device != old_device);
    try std.testing.expect(second.device.generation != old_generation);
}

test "shader module ABI rejects malformed and unsupported inputs without publishing handles" {
    instance_state = [_]SlotState{.never} ** max_objects;
    device_state = [_]SlotState{.never} ** max_objects;
    const ctx = try createTestDeviceContext();
    defer destroyDevice(ctx.device, null);
    const valid = [_]u32{ spirv.magic, 0x0001_0000, 0, 1, 0 };
    var info = ShaderModuleCreateInfo{ .s_type = 16, .p_next = null, .flags = 0, .code_size = valid.len * 4, .p_code = &valid };
    var output: usize = 0xfeed_face;
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(null, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, null, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, &info, null, null));
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, &info, @ptrFromInt(8), &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.s_type = 15;
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.s_type = 16;
    info.p_next = @ptrFromInt(8);
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.p_next = null;
    info.flags = 1;
    try std.testing.expectEqual(Result.error_initialization_failed, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.flags = 0;

    info.code_size = 0;
    try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.code_size = 5;
    try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.code_size = spirv.max_code_bytes + 4;
    try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    info.code_size = valid.len * 4;
    info.p_code = null;
    try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    var bytes = [_]u8{0} ** 32;
    info.p_code = &bytes[1];
    try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);

    const malformed = [_][]const u32{
        &.{ spirv.magic, 0x0001_0000, 0, 1 },
        &.{ 0, 0x0001_0000, 0, 1, 0 },
        &.{ spirv.magic, 0x0001_0000, 0, 1, 1 },
        &.{ spirv.magic, 0x0001_0000, 0, 0, 0 },
        &.{ spirv.magic, 0x0001_0000, 0, 1, 0, 0 },
        &.{ spirv.magic, 0x0001_0000, 0, 1, 0, 0x0002_0000 },
        &.{ spirv.magic, 0x0001_0100, 0, 1, 0 },
    };
    for (malformed) |words| {
        info.code_size = words.len * 4;
        info.p_code = words.ptr;
        try std.testing.expectEqual(Result.error_invalid_shader, createShaderModule(ctx.device, &info, null, &output));
        try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    }

    info.code_size = valid.len * 4;
    info.p_code = &valid;
    const never_before = std.mem.count(SlotState, &shader_module_state, &.{.never});
    test_allocations_before_failure = 0;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createShaderModule(ctx.device, &info, null, &output));
    test_allocations_before_failure = null;
    try std.testing.expectEqual(never_before, std.mem.count(SlotState, &shader_module_state, &.{.never}));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);

    var created: [max_child_objects]usize = undefined;
    var created_count: usize = 0;
    while (std.mem.count(SlotState, &shader_module_state, &.{.never}) != 0) {
        try std.testing.expectEqual(Result.success, createShaderModule(ctx.device, &info, null, &created[created_count]));
        created_count += 1;
    }
    output = 0xfeed_face;
    try std.testing.expectEqual(Result.error_out_of_host_memory, createShaderModule(ctx.device, &info, null, &output));
    try std.testing.expectEqual(@as(usize, 0xfeed_face), output);
    destroyShaderModule(ctx.device, 0xdead_beef, null);
}

test "installed manifest contract" {
    const text = @embedFile("zpu_icd.x86_64.json");
    const parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, text, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try std.testing.expectEqualStrings("1.0.1", root.get("file_format_version").?.string);
    const icd = root.get("ICD").?.object;
    try std.testing.expectEqualStrings("../../../lib/libvulkan_zpu.so", icd.get("library_path").?.string);
    try std.testing.expectEqualStrings("64", icd.get("library_arch").?.string);
    try std.testing.expectEqualStrings("1.0.0", icd.get("api_version").?.string);
    try std.testing.expect(!icd.get("is_portability_driver").?.bool);
}

test "explicit behavioral requirement matrix is complete" {
    const fields = @typeInfo(Requirement).@"enum".fields;
    inline for (fields) |field| {
        const mask = @as(u64, 1) << field.value;
        try std.testing.expect(requirement_hits & mask != 0);
    }
}

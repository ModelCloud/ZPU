//! Original minimal ABI transcription from the public Vulkan 1.0 specification and
//! Khronos loader/driver interface documentation. This is an experimental ICD.
const std = @import("std");
pub const Result = enum(i32) { success = 0, not_ready = 1, timeout = 2, incomplete = 5, error_out_of_host_memory = -1, error_initialization_failed = -3, error_memory_map_failed = -5, error_layer_not_present = -6, error_extension_not_present = -7, error_feature_not_present = -8, error_format_not_supported = -11 };
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
const SetInstanceLoaderData = *const fn (Instance, *anyopaque) callconv(.c) Result;
const SetDeviceLoaderData = *const fn (Device, *anyopaque) callconv(.c) Result;
pub const InstanceObj = extern struct { loader_data: usize, set_loader_data: ?SetInstanceLoaderData };
pub const PhysicalObj = extern struct { loader_data: usize, owner: *InstanceObj, loader_initialized: bool };
pub const DeviceObj = extern struct { loader_data: usize, physical: *PhysicalObj, set_loader_data: ?SetDeviceLoaderData, heap_used: u64 };
pub const QueueObj = extern struct { loader_data: usize, owner: *DeviceObj, loader_initialized: bool };
pub const Instance = *InstanceObj;
pub const Physical = *PhysicalObj;
pub const Device = *DeviceObj;
pub const Queue = *QueueObj;
const MemoryObj = struct { owner: Device, bytes: []align(64) u8, mapped: bool };
const BufferObj = struct { owner: Device, size: u64, usage: u32, memory: ?*MemoryObj = null, offset: u64 = 0 };
const ImageObj = struct { owner: Device, width: u32, height: u32, format: i32, usage: u32, layout: i32, memory: ?*MemoryObj = null, offset: u64 = 0 };
const FenceObj = struct { owner: Device, signaled: bool };
const CommandPoolObj = struct { owner: Device };
const Command = union(enum) { fill: struct { dst: *BufferObj, offset: u64, size: u64, data: u32 }, copy_buffer: struct { src: *BufferObj, dst: *BufferObj, region: BufferCopy }, clear: struct { image: *ImageObj, layout: i32, color: [4]u8 }, buffer_to_image: struct { src: *BufferObj, dst: *ImageObj, layout: i32, region: BufferImageCopy }, image_to_buffer: struct { src: *ImageObj, layout: i32, dst: *BufferObj, region: BufferImageCopy }, copy_image: struct { src: *ImageObj, src_layout: i32, dst: *ImageObj, dst_layout: i32, region: ImageCopy }, transition: struct { image: *ImageObj, old_layout: i32, new_layout: i32 } };
const CommandBufferImpl = struct { owner: *DeviceObj, pool: *CommandPoolObj, state: u8, invalid: bool, count: u16, commands: [256]Command };
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
var memory_objects: [max_child_objects]MemoryObj = undefined;
var memory_state = [_]SlotState{.never} ** max_child_objects;
var buffer_objects: [max_child_objects]BufferObj = undefined;
var buffer_state = [_]SlotState{.never} ** max_child_objects;
var image_objects: [max_child_objects]ImageObj = undefined;
var image_state = [_]SlotState{.never} ** max_child_objects;
var fence_objects: [max_child_objects]FenceObj = undefined;
var fence_state = [_]SlotState{.never} ** max_child_objects;
var command_pool_objects: [max_child_objects]CommandPoolObj = undefined;
var command_pool_state = [_]SlotState{.never} ** max_child_objects;
var command_buffer_objects: [max_child_objects]CommandBufferObj = undefined;
var command_buffer_impls: [max_child_objects]CommandBufferImpl = undefined;
var command_buffer_state = [_]SlotState{.never} ** max_child_objects;
var mutex: std.atomic.Mutex = .unlocked;

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
    empty_submission,
    invalid_clear_color,
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
    _ = props;
    n.* = 0;
    return .success;
}
fn createInstance(info: ?*const InstanceInfo, alloc: ?*const Alloc, output: ?*Instance) callconv(.c) Result {
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.layer_count != 0) return .error_layer_not_present;
    if (ci.extension_count != 0) return .error_extension_not_present;
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
        state.* = .tombstone;
        o.loader_data = 0;
        p.loader_data = 0;
        return;
    };
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
    out.memory_types[0] = .{ .property_flags = 0x6, .heap_index = 0 };
    out.memory_heap_count = 1;
    out.memory_heaps[0] = .{ .size = 256 * 1024 * 1024, .flags = 0 };
}
fn getFormatProperties(physical: ?Physical, format: i32, output: ?*FormatProperties) callconv(.c) void {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const out = output orelse return;
    out.* = .{ .linear_tiling_features = if (supportedFormat(format)) 0x4000 | 0x8000 else 0, .optimal_tiling_features = 0, .buffer_features = 0 };
}
fn getImageFormatProperties(physical: ?Physical, format: i32, image_type: i32, tiling: i32, usage: u32, flags: u32, output: ?*anyopaque) callconv(.c) Result {
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return .error_initialization_failed)) return .error_initialization_failed;
    if (!supportedFormat(format) or image_type != 1 or tiling != 1 or flags != 0 or usage == 0 or usage & ~@as(u32, 0x3) != 0) return .error_format_not_supported;
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
    _ = props;
    n.* = 0;
    return .success;
}
fn createDevice(physical: ?Physical, info: ?*const DeviceInfo, alloc: ?*const Alloc, output: ?*Device) callconv(.c) Result {
    const p = physical orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.layer_count != 0) return .error_layer_not_present;
    if (ci.extension_count != 0) return .error_extension_not_present;
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
        d.* = .{ .loader_data = MAGIC, .physical = p, .set_loader_data = findDeviceLoaderCallback(ci.p_next), .heap_used = 0 };
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
        for (&buffer_objects, &buffer_state) |*buffer, *child_state| if (child_state.* == .live and buffer.owner == d) {
            child_state.* = .tombstone;
        };
        for (&image_objects, &image_state) |*image, *child_state| if (child_state.* == .live and image.owner == d) {
            child_state.* = .tombstone;
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
fn failTestAllocation() bool {
    if (!@import("builtin").is_test) return false;
    const remaining = test_allocations_before_failure orelse return false;
    if (remaining == 0) return true;
    test_allocations_before_failure = remaining - 1;
    return false;
}
fn allocateBytes(size: usize) error{OutOfMemory}![]align(64) u8 {
    if (failTestAllocation()) return error.OutOfMemory;
    return allocator.alignedAlloc(u8, .@"64", size);
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
    if (ci.usage == 0 or ci.usage & ~@as(u32, 0x3) != 0) {
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
    return format == 37 or format == 44;
}
fn createImage(device: ?Device, info: ?*const ImageCreateInfo, alloc: ?*const Alloc, output: ?*usize) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    const ci = info orelse return .error_initialization_failed;
    const out = output orelse return .error_initialization_failed;
    if (ci.usage == 0 or ci.usage & ~@as(u32, 0x3) != 0) {
        hit(.invalid_image_usage);
        return .error_initialization_failed;
    }
    if (alloc != null or ci.s_type != 14 or ci.p_next != null or ci.flags != 0 or ci.image_type != 1 or !supportedFormat(ci.format) or ci.extent.width == 0 or ci.extent.height == 0 or ci.extent.width > 4096 or ci.extent.height > 4096 or ci.extent.depth != 1 or ci.mip_levels != 1 or ci.array_layers != 1 or ci.samples != 1 or ci.tiling != 1 or ci.sharing_mode != 0 or ci.queue_family_index_count != 0 or (ci.initial_layout != 0 and ci.initial_layout != 8)) return if (!supportedFormat(ci.format)) .error_format_not_supported else .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(d)) return .error_initialization_failed;
    for (&image_objects, &image_state) |*object, *state| if (state.* == .never) {
        object.* = .{ .owner = d, .width = ci.extent.width, .height = ci.extent.height, .format = ci.format, .usage = ci.usage, .layout = ci.initial_layout };
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
    if (validDeviceLocked(d) and validOwner(d, object.owner)) stateForObject(ImageObj, object, &image_objects, &image_state).?.* = .tombstone;
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
        impl.* = .{ .owner = d, .pool = pool, .state = 0, .invalid = false, .count = 0, .commands = undefined };
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
    if (dst.owner != c.impl.owner or dst.usage & 0x2 == 0 or dst.memory == null or offset % 4 != 0 or actual % 4 != 0 or offset > dst.size or actual > dst.size - offset) {
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
fn bufferImageEnd(region: BufferImageCopy) ?u64 {
    const row = if (region.buffer_row_length == 0) region.image_extent.width else region.buffer_row_length;
    const height = if (region.buffer_image_height == 0) region.image_extent.height else region.buffer_image_height;
    if (row < region.image_extent.width or height < region.image_extent.height or region.buffer_offset % 4 != 0) return null;
    const prior_rows = @as(u64, region.image_extent.height - 1) * row;
    const texels = prior_rows + region.image_extent.width;
    const bytes = std.math.mul(u64, texels, 4) catch {
        hit(.overflow_buffer_image);
        return null;
    };
    return std.math.add(u64, region.buffer_offset, bytes) catch {
        hit(.overflow_buffer_image);
        return null;
    };
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
    return layout == 0 or layout == 8 or layout == 1 or layout == 6 or layout == 7;
}
fn cmdPipelineBarrier(cb: ?CommandBuffer, src_stage_mask: u32, dst_stage_mask: u32, dependency_flags: u32, memory_barrier_count: u32, memory_barriers: ?*const anyopaque, buffer_barrier_count: u32, buffer_barriers: ?*const anyopaque, image_barrier_count: u32, image_barriers: ?[*]const ImageMemoryBarrier) callconv(.c) void {
    lock();
    defer mutex.unlock();
    const c = validCommandBufferLocked(cb) orelse return;
    _ = memory_barriers;
    _ = buffer_barriers;
    if (src_stage_mask == 0 or dst_stage_mask == 0 or dependency_flags != 0 or memory_barrier_count != 0 or buffer_barrier_count != 0 or image_barrier_count > max_api_items) {
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
        if (barrier.s_type != 45 or barrier.p_next != null or barrier.src_access_mask & ~@as(u32, 0x7800) != 0 or barrier.dst_access_mask & ~@as(u32, 0x7800) != 0 or !supportedLayout(barrier.old_layout) or (barrier.new_layout != 1 and barrier.new_layout != 6 and barrier.new_layout != 7) or !queues_valid or image.owner != c.impl.owner or !validRange(barrier.subresource_range)) {
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
    const memory = image.memory.?;
    const start: usize = @intCast(image.offset);
    return memory.bytes[start .. start + @as(usize, @intCast(imageByteSize(image).?))];
}
fn executeCommand(command: Command) bool {
    switch (command) {
        .fill => |op| {
            if (!liveBufferObject(op.dst) or op.dst.memory == null or !liveMemoryObject(op.dst.memory.?)) {
                hit(.recorded_dead_resource);
                return false;
            }
            const bytes = bufferBytes(op.dst)[@intCast(op.offset)..][0..@intCast(op.size)];
            var i: usize = 0;
            while (i < bytes.len) : (i += 4) std.mem.writeInt(u32, bytes[i..][0..4], op.data, .little);
        },
        .copy_buffer => |op| {
            if (!liveBufferObject(op.src) or !liveBufferObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?)) {
                hit(.recorded_dead_resource);
                return false;
            }
            const src = bufferBytes(op.src)[@intCast(op.region.src_offset)..][0..@intCast(op.region.size)];
            const dst = bufferBytes(op.dst)[@intCast(op.region.dst_offset)..][0..@intCast(op.region.size)];
            std.mem.copyForwards(u8, dst, src);
        },
        .clear => |op| {
            if (!liveImageObject(op.image) or op.image.memory == null or !liveMemoryObject(op.image.memory.?)) {
                hit(.recorded_dead_resource);
                return false;
            }
            if (op.image.layout != op.layout) {
                hit(.layout_mismatch);
                return false;
            }
            const bytes = imageBytes(op.image);
            var i: usize = 0;
            while (i < bytes.len) : (i += 4) @memcpy(bytes[i..][0..4], &op.color);
        },
        .buffer_to_image => |op| {
            if (!liveBufferObject(op.src) or !liveImageObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?) or op.dst.layout != op.layout) return false;
            copyBufferImage(op.src, op.dst, op.region, true);
        },
        .image_to_buffer => |op| {
            if (!liveImageObject(op.src) or !liveBufferObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?) or op.src.layout != op.layout) return false;
            copyBufferImage(op.dst, op.src, op.region, false);
        },
        .copy_image => |op| {
            if (!liveImageObject(op.src) or !liveImageObject(op.dst) or op.src.memory == null or op.dst.memory == null or !liveMemoryObject(op.src.memory.?) or !liveMemoryObject(op.dst.memory.?) or op.src.layout != op.src_layout or op.dst.layout != op.dst_layout) return false;
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
            if (!liveImageObject(op.image)) {
                hit(.recorded_dead_resource);
                return false;
            }
            if (op.image.layout != op.old_layout) {
                hit(.layout_mismatch);
                return false;
            }
            op.image.layout = op.new_layout;
            hit(.barrier_transition);
        },
    }
    return true;
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
fn queueSubmit(queue: ?Queue, count: u32, submits: ?[*]const SubmitInfo, fence_handle: usize) callconv(.c) Result {
    const q = queue orelse return .error_initialization_failed;
    if (count > max_api_items) return .error_initialization_failed;
    if (count == 0) hit(.empty_submission);
    const list = if (count == 0) null else submits orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    if (!validDeviceLocked(q.owner)) return .error_initialization_failed;
    const fence = if (fence_handle == 0) null else validFenceLocked(fence_handle) orelse return .error_initialization_failed;
    if (fence) |item| if (!validOwner(q.owner, item.owner) or item.signaled) return .error_initialization_failed;
    if (list) |items| {
        for (items[0..count]) |submit| {
            if (submit.s_type != 4 or submit.p_next != null or submit.wait_semaphore_count != 0 or submit.signal_semaphore_count != 0 or submit.command_buffer_count > max_api_items) return .error_initialization_failed;
            if (submit.command_buffer_count == 0) {
                continue;
            }
            const cbs = submit.command_buffers orelse return .error_initialization_failed;
            for (cbs[0..submit.command_buffer_count]) |cb| {
                const valid_cb = validCommandBufferLocked(cb) orelse return .error_initialization_failed;
                if (valid_cb.impl.owner != q.owner or valid_cb.impl.state != 2) return .error_initialization_failed;
                for (valid_cb.impl.commands[0..valid_cb.impl.count]) |command| if (!executeCommand(command)) return .error_initialization_failed;
            }
        }
    }
    if (fence) |item| item.signaled = true;
    return .success;
}
fn queueWaitIdle(queue: ?Queue) callconv(.c) Result {
    const q = queue orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    return if (validDeviceLocked(q.owner)) .success else .error_initialization_failed;
}
fn deviceWaitIdle(device: ?Device) callconv(.c) Result {
    const d = device orelse return .error_initialization_failed;
    lock();
    defer mutex.unlock();
    return if (validDeviceLocked(d)) .success else .error_initialization_failed;
}

fn globalLookup(n: []const u8) Fn {
    const map = .{ .{ "vkGetInstanceProcAddr", getInstanceProcAddr }, .{ "vkCreateInstance", createInstance }, .{ "vkEnumerateInstanceExtensionProperties", enumerateInstanceExtensions } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return null;
}
fn instanceLookup(n: []const u8) Fn {
    if (globalLookup(n)) |f| return f;
    const map = .{ .{ "vkDestroyInstance", destroyInstance }, .{ "vkEnumeratePhysicalDevices", enumeratePhysicalDevices }, .{ "vkGetPhysicalDeviceFeatures", getFeatures }, .{ "vkGetPhysicalDeviceProperties", getProperties }, .{ "vkGetPhysicalDeviceQueueFamilyProperties", getQueueProperties }, .{ "vkGetPhysicalDeviceMemoryProperties", getMemoryProperties }, .{ "vkGetPhysicalDeviceFormatProperties", getFormatProperties }, .{ "vkGetPhysicalDeviceImageFormatProperties", getImageFormatProperties }, .{ "vkGetPhysicalDeviceSparseImageFormatProperties", getSparseImageFormatProperties }, .{ "vkEnumerateDeviceExtensionProperties", enumerateDeviceExtensions }, .{ "vkCreateDevice", createDevice }, .{ "vkGetDeviceProcAddr", getDeviceProcAddr }, .{ "vkDestroyDevice", destroyDevice }, .{ "vkGetDeviceQueue", getDeviceQueue } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
    return deviceLookup(n);
}
fn deviceLookup(n: []const u8) Fn {
    const map = .{ .{ "vkGetDeviceProcAddr", getDeviceProcAddr }, .{ "vkDestroyDevice", destroyDevice }, .{ "vkGetDeviceQueue", getDeviceQueue }, .{ "vkAllocateMemory", allocateMemory }, .{ "vkFreeMemory", freeMemory }, .{ "vkMapMemory", mapMemory }, .{ "vkUnmapMemory", unmapMemory }, .{ "vkCreateBuffer", createBuffer }, .{ "vkDestroyBuffer", destroyBuffer }, .{ "vkGetBufferMemoryRequirements", getBufferMemoryRequirements }, .{ "vkBindBufferMemory", bindBufferMemory }, .{ "vkCreateImage", createImage }, .{ "vkDestroyImage", destroyImage }, .{ "vkGetImageMemoryRequirements", getImageMemoryRequirements }, .{ "vkBindImageMemory", bindImageMemory }, .{ "vkGetImageSubresourceLayout", getImageSubresourceLayout }, .{ "vkCreateFence", createFence }, .{ "vkDestroyFence", destroyFence }, .{ "vkGetFenceStatus", getFenceStatus }, .{ "vkResetFences", resetFences }, .{ "vkWaitForFences", waitForFences }, .{ "vkCreateCommandPool", createCommandPool }, .{ "vkDestroyCommandPool", destroyCommandPool }, .{ "vkAllocateCommandBuffers", allocateCommandBuffers }, .{ "vkFreeCommandBuffers", freeCommandBuffers }, .{ "vkBeginCommandBuffer", beginCommandBuffer }, .{ "vkEndCommandBuffer", endCommandBuffer }, .{ "vkResetCommandBuffer", resetCommandBuffer }, .{ "vkCmdFillBuffer", cmdFillBuffer }, .{ "vkCmdCopyBuffer", cmdCopyBuffer }, .{ "vkCmdClearColorImage", cmdClearColorImage }, .{ "vkCmdCopyBufferToImage", cmdCopyBufferToImage }, .{ "vkCmdCopyImageToBuffer", cmdCopyImageToBuffer }, .{ "vkCmdCopyImage", cmdCopyImage }, .{ "vkCmdPipelineBarrier", cmdPipelineBarrier }, .{ "vkQueueSubmit", queueSubmit }, .{ "vkQueueWaitIdle", queueWaitIdle }, .{ "vkDeviceWaitIdle", deviceWaitIdle } };
    inline for (map) |e| if (std.mem.eql(u8, n, e[0])) return ptr(e[1]);
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
    const map = .{ .{ "vkGetPhysicalDeviceFeatures", getFeatures }, .{ "vkGetPhysicalDeviceProperties", getProperties }, .{ "vkGetPhysicalDeviceQueueFamilyProperties", getQueueProperties }, .{ "vkGetPhysicalDeviceMemoryProperties", getMemoryProperties }, .{ "vkGetPhysicalDeviceFormatProperties", getFormatProperties }, .{ "vkGetPhysicalDeviceImageFormatProperties", getImageFormatProperties }, .{ "vkGetPhysicalDeviceSparseImageFormatProperties", getSparseImageFormatProperties }, .{ "vkEnumerateDeviceExtensionProperties", enumerateDeviceExtensions }, .{ "vkCreateDevice", createDevice } };
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
    try std.testing.expectEqual(@as(u32, 0), extension_count);
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
    ci.extension_count = 1;
    try std.testing.expectEqual(Result.error_extension_not_present, createInstance(&ci, null, &instance));
    ci.extension_count = 0;
    const unsupported_chain = ChainHeader{ .s_type = 999, .p_next = null };
    ci.p_next = &unsupported_chain;
    try std.testing.expectEqual(Result.error_initialization_failed, createInstance(&ci, null, &instance));
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
        "vkDestroyInstance",                              "vkEnumeratePhysicalDevices",           "vkGetPhysicalDeviceFeatures",         "vkGetPhysicalDeviceProperties",
        "vkGetPhysicalDeviceQueueFamilyProperties",       "vkGetPhysicalDeviceMemoryProperties",  "vkGetPhysicalDeviceFormatProperties", "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties", "vkEnumerateDeviceExtensionProperties", "vkCreateDevice",                      "vkGetDeviceProcAddr",
        "vkDestroyDevice",                                "vkGetDeviceQueue",
    };
    for (instance_names) |name| try std.testing.expect(vk_icdGetInstanceProcAddr(instance, name) != null);
    const physical_names = [_][*:0]const u8{
        "vkGetPhysicalDeviceFeatures",                    "vkGetPhysicalDeviceProperties",        "vkGetPhysicalDeviceQueueFamilyProperties",
        "vkGetPhysicalDeviceMemoryProperties",            "vkGetPhysicalDeviceFormatProperties",  "vkGetPhysicalDeviceImageFormatProperties",
        "vkGetPhysicalDeviceSparseImageFormatProperties", "vkEnumerateDeviceExtensionProperties", "vkCreateDevice",
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
    try std.testing.expectEqual(@as(u32, 0x6), memory.memory_types[0].property_flags);
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
    try std.testing.expectEqual(@as(u32, 0), extension_count);
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
        .{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1000, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image, .subresource_range = range },
        .{ .s_type = 45, .p_next = null, .src_access_mask = 0, .dst_access_mask = 0x1000, .old_layout = 0, .new_layout = 1, .src_queue_family_index = std.math.maxInt(u32), .dst_queue_family_index = std.math.maxInt(u32), .image = image_two, .subresource_range = range },
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
    try std.testing.expect(!executeCommand(.{ .copy_buffer = .{ .src = dead_src, .dst = dead_dst, .region = .{ .src_offset = 0, .dst_offset = 0, .size = 1 } } }));
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
    invalid_image_info.usage = 4;
    try std.testing.expectEqual(Result.error_initialization_failed, createImage(ctx.device, &invalid_image_info, null, &ignored));
    var image: usize = 0;
    try std.testing.expectEqual(Result.success, createImage(ctx.device, &image_info, null, &image));
    try std.testing.expectEqual(Result.success, bindImageMemory(ctx.device, image, image_memory, 0));
    freeMemory(ctx.device, image_memory, null);
    try std.testing.expectEqual(Result.success, mapMemory(ctx.device, image_memory, 0, 1, 0, &mapped));
    unmapMemory(ctx.device, image_memory);
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
    cmdPipelineBarrier(cbs[0], 1, 1, 0, 0, @ptrFromInt(8), 0, @ptrFromInt(8), 0, null);
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
    cmdPipelineBarrier(cbs[0], 1, 1, 0, 0, null, 0, null, 1, null);
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    var bad_barrier = barrier;
    bad_barrier.image = 8;
    cmdPipelineBarrier(cbs[0], 1, 1, 0, 0, null, 0, null, 1, @ptrCast(&bad_barrier));
    try std.testing.expectEqual(Result.error_initialization_failed, endCommandBuffer(cbs[0]));
    try std.testing.expectEqual(Result.success, resetCommandBuffer(cbs[0], 0));
    try std.testing.expectEqual(Result.success, beginCommandBuffer(cbs[0], &begin));
    bad_barrier = barrier;
    bad_barrier.s_type = 0;
    cmdPipelineBarrier(cbs[0], 1, 1, 0, 0, null, 0, null, 1, @ptrCast(&bad_barrier));
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
    cmdPipelineBarrier(cbs[0], 1, 1, 0, 0, null, 0, null, 1, @ptrCast(&destroy_barrier));
    try std.testing.expectEqual(Result.success, endCommandBuffer(cbs[0]));
    destroyImage(ctx.device, image, null);
    try std.testing.expectEqual(Result.error_initialization_failed, queueSubmit(ctx.queue, 1, @ptrCast(&submit), 0));
    const dead_image: *ImageObj = @ptrFromInt(image);
    try std.testing.expect(!executeCommand(.{ .clear = .{ .image = dead_image, .layout = 1, .color = .{ 1, 2, 3, 4 } } }));
    getImageMemoryRequirements(ctx.device, image, &stale_requirements);
    try std.testing.expectEqual(@as(u64, 9), stale_requirements.size);

    const fci = FenceCreateInfo{ .s_type = 8, .p_next = null, .flags = 0 };
    var fence: usize = 0;
    try std.testing.expectEqual(Result.success, createFence(ctx.device, &fci, null, &fence));
    try std.testing.expectEqual(Result.success, queueSubmit(ctx.queue, 0, null, fence));
    try std.testing.expectEqual(Result.success, getFenceStatus(ctx.device, fence));
    try std.testing.expectEqual(Result.success, resetFences(ctx.device, 1, @ptrCast(&fence)));
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

    var extreme = ImageObj{ .owner = ctx.device, .width = std.math.maxInt(u32), .height = std.math.maxInt(u32), .format = 37, .usage = 3, .layout = 0 };
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

    destroyDevice(ctx.device, null);
    try std.testing.expectEqual(Result.error_memory_map_failed, mapMemory(ctx.device, memory_b, 0, 1, 0, &mapped));
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
    std.debug.print("behavioral requirements: {d}/{d}\n", .{ fields.len, fields.len });
}

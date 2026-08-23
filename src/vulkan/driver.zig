//! Original minimal ABI transcription from the public Vulkan 1.0 specification and
//! Khronos loader/driver interface documentation. This is an experimental ICD.
const std = @import("std");
pub const Result = enum(i32) { success = 0, incomplete = 5, error_out_of_host_memory = -1, error_initialization_failed = -3, error_layer_not_present = -6, error_extension_not_present = -7, error_feature_not_present = -8, error_format_not_supported = -11 };
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
const SetInstanceLoaderData = *const fn (Instance, *anyopaque) callconv(.c) Result;
const SetDeviceLoaderData = *const fn (Device, *anyopaque) callconv(.c) Result;
pub const InstanceObj = extern struct { loader_data: usize, set_loader_data: ?SetInstanceLoaderData };
pub const PhysicalObj = extern struct { loader_data: usize, owner: *InstanceObj, loader_initialized: bool };
pub const DeviceObj = extern struct { loader_data: usize, physical: *PhysicalObj, set_loader_data: ?SetDeviceLoaderData };
pub const QueueObj = extern struct { loader_data: usize, owner: *DeviceObj, loader_initialized: bool };
pub const Instance = *InstanceObj;
pub const Physical = *PhysicalObj;
pub const Device = *DeviceObj;
pub const Queue = *QueueObj;

const max_objects = 64;
const SlotState = enum(u8) { never, live, tombstone };
var instance_objects: [max_objects]InstanceObj = undefined;
var physical_objects: [max_objects]PhysicalObj = undefined;
var instance_state = [_]SlotState{.never} ** max_objects;
var device_objects: [max_objects]DeviceObj = undefined;
var queue_objects: [max_objects]QueueObj = undefined;
var device_state = [_]SlotState{.never} ** max_objects;
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
    v.max_fragment_combined_output_resources = 4;
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
    v.viewport_bounds_range = .{ -8192, 8191 };
    v.min_memory_map_alignment = 64;
    v.min_texel_buffer_offset_alignment = 256;
    v.min_uniform_buffer_offset_alignment = 256;
    v.min_storage_buffer_offset_alignment = 256;
    v.min_texel_offset = -8;
    v.max_texel_offset = 7;
    v.min_interpolation_offset = -0.5;
    v.max_interpolation_offset = 0.4375;
    v.sub_pixel_interpolation_offset_bits = 4;
    v.max_framebuffer_width = 4096;
    v.max_framebuffer_height = 4096;
    v.max_framebuffer_layers = 1;
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
    _ = format;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return)) return;
    const out = output orelse return;
    out.* = .{ .linear_tiling_features = 0, .optimal_tiling_features = 0, .buffer_features = 0 };
}
fn getImageFormatProperties(physical: ?Physical, format: i32, image_type: i32, tiling: i32, usage: u32, flags: u32, output: ?*anyopaque) callconv(.c) Result {
    _ = format;
    _ = image_type;
    _ = tiling;
    _ = usage;
    _ = flags;
    _ = output;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(physical orelse return .error_initialization_failed)) return .error_initialization_failed;
    return .error_format_not_supported;
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
        d.* = .{ .loader_data = MAGIC, .physical = p, .set_loader_data = findDeviceLoaderCallback(ci.p_next) };
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
                if (result == .success) hit(.callback_device_success) else {
                    hit(.callback_device_decline);
                    return;
                }
                if (!validDeviceLocked(h)) {
                    hit(.callback_device_destroy);
                    return;
                }
            }
        }
        out.* = q;
        return;
    };
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
    return null;
}
fn deviceLookup(n: []const u8) Fn {
    const map = .{ .{ "vkGetDeviceProcAddr", getDeviceProcAddr }, .{ "vkDestroyDevice", destroyDevice }, .{ "vkGetDeviceQueue", getDeviceQueue } };
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
    for ([_][*:0]const u8{ "vkGetDeviceProcAddr", "vkDestroyDevice", "vkGetDeviceQueue" }) |name| try std.testing.expect(getDeviceProcAddr(device, name) != null);
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
    destroyInstance(instance, null);
}

test "physical properties start with coherent conservative limits" {
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
    try std.testing.expectEqualDeep(conservativeLimits(), properties.limits);
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

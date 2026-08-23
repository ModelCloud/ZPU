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
pub const Properties = extern struct { bytes: [824]u8 align(8) };
pub const MemoryProperties = extern struct { bytes: [520]u8 align(8) };
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
        if (header.s_type != 47 or depth == 16) break;
        const item: *const LoaderInstanceInfo = @ptrCast(@alignCast(raw_item));
        if (item.function == 1) return item.value.set_instance_loader_data;
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
        if (header.s_type != 48 or depth == 16) break;
        const item: *const LoaderDeviceInfo = @ptrCast(@alignCast(raw_item));
        if (item.function == 1) return item.value.set_device_loader_data;
        next = item.p_next;
        depth += 1;
    }
    return null;
}

fn validInstanceLocked(h: Instance) bool {
    for (&instance_objects, &instance_state) |*o, state| if (state == .live and o == h) return true;
    return false;
}
fn validPhysicalLocked(h: Physical) bool {
    for (&physical_objects, &instance_state) |*o, state| if (state == .live and o == h and validInstanceLocked(o.owner)) return true;
    return false;
}
fn validDeviceLocked(h: Device) bool {
    for (&device_objects, &device_state) |*o, state| if (state == .live and o == h and validPhysicalLocked(o.physical)) return true;
    return false;
}
fn ptr(comptime f: anytype) Fn {
    return @ptrCast(&f);
}

fn getInstanceProcAddr(instance: ?Instance, name: ?[*:0]const u8) callconv(.c) Fn {
    const n = std.mem.span(name orelse return null);
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
    const n = count orelse return .error_initialization_failed;
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
    if (alloc != null or ci.s_type != 1 or !hasValidLoaderHead(ci.p_next, 47) or ci.flags != 0) return .error_initialization_failed;
    if (ci.app_info) |app| if (app.s_type != 0 or app.p_next != null or app.api_version > API_1_0) return .error_initialization_failed;
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
    const n = count orelse return .error_initialization_failed;
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
                    _ = result;
                    if (!validInstanceLocked(h)) return .error_initialization_failed;
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
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(h)) return;
    out.* = .{ .values = [_]u32{0} ** 55 };
}
fn put32(bytes: []u8, offset: usize, value: u32) void {
    std.mem.writeInt(u32, bytes[offset..][0..4], value, .little);
}
fn getProperties(physical: ?Physical, output: ?*Properties) callconv(.c) void {
    const h = physical orelse return;
    const out = output orelse return;
    lock();
    defer mutex.unlock();
    if (!validPhysicalLocked(h)) return;
    @memset(&out.bytes, 0);
    put32(&out.bytes, 0, API_1_0);
    put32(&out.bytes, 4, 1);
    put32(&out.bytes, 8, 0x1cdc);
    put32(&out.bytes, 12, 1);
    put32(&out.bytes, 16, 4);
    const name = "ZPU Experimental CPU";
    @memcpy(out.bytes[20 .. 20 + name.len], name);
    const uuid = [_]u8{ 0x5a, 0x50, 0x55, 0x2d, 0x49, 0x43, 0x44, 0x2d, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x30, 0x31 };
    @memcpy(out.bytes[276..292], &uuid);
    put32(&out.bytes, 296, 4096);
    put32(&out.bytes, 300, 4096);
    put32(&out.bytes, 304, 256);
    put32(&out.bytes, 308, 256);
    put32(&out.bytes, 312, 256);
    put32(&out.bytes, 316, 65536);
    put32(&out.bytes, 320, 16384);
    put32(&out.bytes, 324, 16384);
    put32(&out.bytes, 328, 128);
    put32(&out.bytes, 332, 16);
    put32(&out.bytes, 336, 16);
    put32(&out.bytes, 340, 1);
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
    @memset(&out.bytes, 0);
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
    if (alloc != null or ci.s_type != 3 or !hasValidLoaderHead(ci.p_next, 48) or ci.flags != 0) return .error_initialization_failed;
    if (ci.features) |features| for (features.values) |feature| if (feature != 0) return .error_feature_not_present;
    if (ci.queue_info_count != 1) return .error_initialization_failed;
    const qis = ci.queue_infos orelse return .error_initialization_failed;
    const qi = qis[0];
    if (qi.s_type != 2 or qi.p_next != null or qi.flags != 0 or qi.family != 0 or qi.count != 1 or qi.priorities == null) return .error_initialization_failed;
    const priority = qi.priorities.?[0];
    if (!std.math.isFinite(priority) or priority < 0 or priority > 1) return .error_initialization_failed;
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
                if (result != .success or !validDeviceLocked(h)) return;
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
    try std.testing.expectEqual(@as(u32, 1), count);
    var ps: [1]Physical = undefined;
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

const StressContext = struct { instance: Instance, physical: Physical };
fn stressRead(context: *const StressContext) void {
    for (0..10_000) |_| {
        var count: u32 = 0;
        _ = enumeratePhysicalDevices(context.instance, &count, null);
        var features = Features{ .values = [_]u32{0} ** 55 };
        getFeatures(context.physical, &features);
        _ = vk_icdGetInstanceProcAddr(context.instance, "vkDestroyInstance");
    }
}

test "serialized entry points tolerate concurrent reads and destroy" {
    const ci = InstanceInfo{ .s_type = 1, .p_next = null, .flags = 0, .app_info = null, .layer_count = 0, .layers = null, .extension_count = 0, .extensions = null };
    var instance: Instance = undefined;
    try std.testing.expectEqual(Result.success, createInstance(&ci, null, &instance));
    var count: u32 = 1;
    var physical: [1]Physical = undefined;
    try std.testing.expectEqual(Result.success, enumeratePhysicalDevices(instance, &count, &physical));
    const context = StressContext{ .instance = instance, .physical = physical[0] };
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, stressRead, .{&context});
    destroyInstance(instance, null);
    for (threads) |thread| thread.join();
    try std.testing.expect(vk_icdGetInstanceProcAddr(instance, "vkDestroyInstance") == null);
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
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, properties.bytes[296..300], .little));
    try std.testing.expectEqual(@as(u32, 4096), std.mem.readInt(u32, properties.bytes[300..304], .little));
    try std.testing.expect(std.mem.readInt(u32, properties.bytes[304..308], .little) > 0);
    try std.testing.expect(std.mem.readInt(u32, properties.bytes[332..336], .little) > 0);
    destroyInstance(instance, null);
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

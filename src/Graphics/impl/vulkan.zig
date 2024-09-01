allocator: std.mem.Allocator,
vk_allocation_callbacks: vk.AllocationCallbacks,
vulkan_allocation_metadata: std.AutoArrayHashMapUnmanaged([*]u8, VulkanAllocationMetadata),

libvulkan: std.DynLib,

vkb: VulkanBaseDispatch,
vk_instance_dispatch: VulkanInstanceDispatch,
vk_device_dispatch: VulkanDeviceDispatch,

vk_instance: VulkanInstance,
vk_device: VulkanDevice,
vk_command_pool: vk.CommandPool,
vk_render_pass: vk.RenderPass,
vk_graphics_queue: vk.Queue,

image_format: vk.Format,
vk_memory_properties: vk.PhysicalDeviceMemoryProperties,
drm_format_modifier_properties_list: std.ArrayListUnmanaged(vk.DrmFormatModifierPropertiesEXT),
drm_format_modifier_list: std.ArrayListUnmanaged(u64),

render_buffers: std.AutoArrayHashMapUnmanaged(*RenderBuffer, void),

const VulkanImpl = @This();

pub fn create(allocator: std.mem.Allocator, options: seizer.Platform.CreateGraphicsOptions) seizer.Platform.CreateGraphicsError!seizer.Graphics {
    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);

    var library_prefixes = @"dynamic-library-utils".getLibrarySearchPaths(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LibraryLoadFailed,
    };
    defer library_prefixes.arena.deinit();

    // allocate a fixed memory location for fn_tables
    var libvulkan = @"dynamic-library-utils".loadFromPrefixes(library_prefixes.paths.items, "libvulkan.so") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.LibraryLoadFailed,
    };

    const vk_get_instance_proc_addr_fn = libvulkan.lookup(*const fn (vk.Instance, [*:0]const u8) callconv(.C) vk.PfnVoidFunction, "vkGetInstanceProcAddr") orelse return error.LibraryLoadFailed;

    this.* = .{
        .allocator = allocator,
        .vk_allocation_callbacks = .{
            .p_user_data = this,
            .pfn_allocation = _vkAllocation,
            .pfn_reallocation = _vkReallocation,
            .pfn_free = _vkFree,
        },
        .vulkan_allocation_metadata = .{},
        .libvulkan = libvulkan,
        .vkb = VulkanBaseDispatch.load(vk_get_instance_proc_addr_fn) catch return error.LibraryLoadFailed,

        .vk_instance_dispatch = undefined,
        .vk_instance = undefined,
        .vk_device_dispatch = undefined,
        .vk_device = undefined,
        .vk_command_pool = undefined,
        .vk_render_pass = undefined,
        .vk_graphics_queue = undefined,
        .image_format = undefined,
        .vk_memory_properties = undefined,
        .drm_format_modifier_properties_list = undefined,
        .drm_format_modifier_list = undefined,
        .render_buffers = undefined,
    };

    var vk_enabled_layers = std.ArrayList([*:0]const u8).init(this.allocator);
    defer vk_enabled_layers.deinit();

    {
        var layer_properties_count: u32 = undefined;
        _ = this.vkb.enumerateInstanceLayerProperties(&layer_properties_count, null) catch return error.InitializationFailed;
        const layer_properties = try this.allocator.alloc(vk.LayerProperties, layer_properties_count);
        defer this.allocator.free(layer_properties);
        _ = this.vkb.enumerateInstanceLayerProperties(&layer_properties_count, layer_properties.ptr) catch |err| switch (err) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.InitializationFailed,
        };

        for (layer_properties) |layer_property| {
            const end_of_name = std.mem.indexOfScalar(u8, &layer_property.layer_name, 0) orelse layer_property.layer_name.len;
            const name = layer_property.layer_name[0..end_of_name];
            if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
                if (builtin.mode == .Debug) {
                    try vk_enabled_layers.append("VK_LAYER_KHRONOS_validation");
                }
            }
        }
    }

    // TODO: Implement vulkan allocator interface
    const vk_instance_ptr = this.vkb.createInstance(&.{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = if (options.app_name) |name| name.ptr else null,
            .application_version = if (options.app_version) |version| vk.makeApiVersion(0, @intCast(version.major), @intCast(version.minor), @intCast(version.patch)) else 0,
            .p_engine_name = "seizer",
            .engine_version = vk.makeApiVersion(0, seizer.version.major, seizer.version.minor, seizer.version.patch),
            .api_version = vk.API_VERSION_1_2,
        },
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.ExtensionNotPresent,
        error.LayerNotPresent,
        error.IncompatibleDriver,
        error.Unknown,
        => return error.InitializationFailed,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        => |e| return e,
    };

    this.vk_instance_dispatch = VulkanInstanceDispatch.load(vk_instance_ptr, this.vkb.dispatch.vkGetInstanceProcAddr) catch return error.LibraryLoadFailed;

    this.* = .{
        .allocator = this.allocator,
        .vk_allocation_callbacks = this.vk_allocation_callbacks,
        .vulkan_allocation_metadata = this.vulkan_allocation_metadata,
        .libvulkan = this.libvulkan,
        .vkb = this.vkb,
        .vk_instance_dispatch = this.vk_instance_dispatch,

        .vk_instance = VulkanInstance.init(vk_instance_ptr, &this.vk_instance_dispatch),
        .vk_device_dispatch = undefined,
        .vk_device = undefined,
        .vk_command_pool = undefined,
        .vk_render_pass = undefined,
        .vk_graphics_queue = undefined,
        .image_format = undefined,
        .vk_memory_properties = undefined,
        .drm_format_modifier_properties_list = undefined,
        .drm_format_modifier_list = undefined,
        .render_buffers = undefined,
    };
    errdefer this.vk_instance.destroyInstance(null);

    const device_result = pickVkDevice(this.allocator, this.vk_instance) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.ExtensionNotPresent,
        error.FeatureNotPresent,
        error.LayerNotPresent,
        error.TooManyObjects,
        error.DeviceLost,
        error.Unknown,
        => return error.InitializationFailed,
        error.OutOfMemory,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        => |e| return e,
    };

    this.vk_device_dispatch = VulkanDeviceDispatch.load(device_result.ptr, this.vk_instance_dispatch.dispatch.vkGetDeviceProcAddr) catch return error.LibraryLoadFailed;
    this.* = .{
        .allocator = this.allocator,
        .vk_allocation_callbacks = this.vk_allocation_callbacks,
        .vulkan_allocation_metadata = this.vulkan_allocation_metadata,
        .libvulkan = this.libvulkan,
        .vkb = this.vkb,
        .vk_instance_dispatch = this.vk_instance_dispatch,
        .vk_instance = this.vk_instance,
        .vk_device_dispatch = this.vk_device_dispatch,

        .vk_device = VulkanDevice.init(device_result.ptr, &this.vk_device_dispatch),
        .vk_command_pool = undefined,
        .vk_render_pass = undefined,
        .vk_graphics_queue = undefined,
        .image_format = undefined,
        .vk_memory_properties = undefined,
        .drm_format_modifier_properties_list = undefined,
        .drm_format_modifier_list = undefined,
        .render_buffers = undefined,
    };
    errdefer this.vk_device.destroyDevice(null);

    const vk_command_pool = this.vk_device.createCommandPool(&vk.CommandPoolCreateInfo{
        .queue_family_index = device_result.queue_family_index,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.Unknown => return error.InitializationFailed,
        error.OutOfDeviceMemory => |e| return e,
    };
    errdefer this.vk_device.destroyCommandPool(vk_command_pool, null);

    this.* = .{
        .allocator = this.allocator,
        .vk_allocation_callbacks = this.vk_allocation_callbacks,
        .vulkan_allocation_metadata = this.vulkan_allocation_metadata,
        .libvulkan = this.libvulkan,
        .vkb = this.vkb,
        .vk_instance_dispatch = this.vk_instance_dispatch,
        .vk_instance = this.vk_instance,
        .vk_device_dispatch = this.vk_device_dispatch,
        .vk_device = this.vk_device,

        .vk_command_pool = vk_command_pool,
        .image_format = .r8g8b8a8_unorm,

        .vk_render_pass = undefined,
        .vk_graphics_queue = undefined,
        .vk_memory_properties = undefined,
        .drm_format_modifier_properties_list = undefined,
        .drm_format_modifier_list = undefined,
        .render_buffers = undefined,
    };

    // create render pass
    const vk_render_pass = this.vk_device.createRenderPass(&vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = &[_]vk.AttachmentDescription{
            .{
                .format = this.image_format,
                .samples = .{ .@"1_bit" = true },
                .load_op = .clear,
                .store_op = .store,
                .stencil_load_op = .dont_care,
                .stencil_store_op = .dont_care,
                .initial_layout = .undefined,
                .final_layout = .color_attachment_optimal,
            },
        },
        .subpass_count = 1,
        .p_subpasses = &[_]vk.SubpassDescription{
            .{
                .pipeline_bind_point = .graphics,
                .color_attachment_count = 1,
                .p_color_attachments = &[_]vk.AttachmentReference{
                    .{
                        .attachment = 0,
                        .layout = .color_attachment_optimal,
                    },
                },
            },
        },
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.Unknown => return error.InitializationFailed,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
    };
    errdefer this.vk_device.destroyRenderPass(vk_render_pass, null);

    this.* = .{
        .allocator = this.allocator,
        .vk_allocation_callbacks = this.vk_allocation_callbacks,
        .vulkan_allocation_metadata = this.vulkan_allocation_metadata,
        .libvulkan = this.libvulkan,
        .vkb = this.vkb,
        .vk_instance_dispatch = this.vk_instance_dispatch,
        .vk_instance = this.vk_instance,
        .vk_device_dispatch = this.vk_device_dispatch,
        .vk_device = this.vk_device,
        .vk_command_pool = this.vk_command_pool,
        .image_format = this.image_format,

        .vk_graphics_queue = this.vk_device.getDeviceQueue(device_result.queue_family_index, 0),
        .vk_render_pass = vk_render_pass,

        .vk_memory_properties = this.vk_instance.getPhysicalDeviceMemoryProperties(device_result.physical_device),
        .drm_format_modifier_properties_list = .{},
        .drm_format_modifier_list = .{},
        .render_buffers = .{},
    };

    // get format properties
    var vk_drm_modifier_properties = vk.DrmFormatModifierPropertiesListEXT{
        .drm_format_modifier_count = 0,
        .p_drm_format_modifier_properties = null,
    };
    var vk_format_properties = vk.FormatProperties2{
        .p_next = &vk_drm_modifier_properties,
        .format_properties = undefined,
    };
    this.vk_instance.getPhysicalDeviceFormatProperties2(device_result.physical_device, this.image_format, &vk_format_properties);

    try this.drm_format_modifier_properties_list.resize(this.allocator, vk_drm_modifier_properties.drm_format_modifier_count);
    vk_drm_modifier_properties = vk.DrmFormatModifierPropertiesListEXT{
        .drm_format_modifier_count = @intCast(this.drm_format_modifier_properties_list.items.len),
        .p_drm_format_modifier_properties = this.drm_format_modifier_properties_list.items.ptr,
    };

    this.vk_instance.getPhysicalDeviceFormatProperties2(device_result.physical_device, this.image_format, &vk_format_properties);

    try this.drm_format_modifier_list.resize(this.allocator, this.drm_format_modifier_properties_list.items.len);
    for (this.drm_format_modifier_properties_list.items, this.drm_format_modifier_list.items) |properties, *drm_modifier| {
        drm_modifier.* = properties.drm_format_modifier;
    }

    return this.graphics();
}

fn pickVkDevice(allocator: std.mem.Allocator, vk_instance: VulkanInstance) !struct { ptr: vk.Device, queue_family_index: u32, physical_device: vk.PhysicalDevice } {
    // vulkan device
    var physical_device_count: u32 = undefined;
    _ = vk_instance.enumeratePhysicalDevices(&physical_device_count, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.Unknown => return error.InitializationFailed,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        => |e| return e,
    };
    const physical_devices = try allocator.alloc(vk.PhysicalDevice, physical_device_count);
    defer allocator.free(physical_devices);
    _ = vk_instance.enumeratePhysicalDevices(&physical_device_count, physical_devices.ptr) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.Unknown => return error.InitializationFailed,
        error.OutOfDeviceMemory,
        error.InitializationFailed,
        => |e| return e,
    };

    var extension_properties = std.ArrayList(vk.ExtensionProperties).init(allocator);
    defer extension_properties.deinit();

    var queue_families = std.ArrayList(vk.QueueFamilyProperties).init(allocator);
    defer queue_families.deinit();

    var current_device_score: u32 = 0;
    var physical_device: ?vk.PhysicalDevice = null;
    var device_queue_create_info = vk.DeviceQueueCreateInfo{
        .queue_family_index = 0,
        .queue_count = 1,
        .p_queue_priorities = &.{1},
    };
    var enabled_device_extensions = [_][*:0]const u8{
        vk.extensions.khr_external_memory_fd.name,
        vk.extensions.ext_external_memory_dma_buf.name,
        vk.extensions.ext_image_drm_format_modifier.name,
    };
    var device_create_info = vk.DeviceCreateInfo{
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{device_queue_create_info},
        .enabled_extension_count = enabled_device_extensions.len,
        .pp_enabled_extension_names = &enabled_device_extensions,
    };
    for (physical_devices) |device| {
        const device_score: u32 = 1;

        var extension_property_count: u32 = undefined;
        _ = try vk_instance.enumerateDeviceExtensionProperties(device, null, &extension_property_count, null);
        try extension_properties.resize(extension_property_count);
        _ = try vk_instance.enumerateDeviceExtensionProperties(device, null, &extension_property_count, extension_properties.items.ptr);

        var has_vk_khr_external_memory_fd = false;
        var has_vk_ext_external_memory_dma_buf = false;
        var has_vk_ext_image_drm_format_modifier = false;
        for (extension_properties.items) |property| {
            const end_of_property_name = std.mem.indexOfScalar(u8, &property.extension_name, 0) orelse property.extension_name.len;
            const property_name = property.extension_name[0..end_of_property_name];
            if (std.mem.eql(u8, property_name, vk.extensions.khr_external_memory_fd.name)) {
                has_vk_khr_external_memory_fd = true;
            } else if (std.mem.eql(u8, property_name, vk.extensions.ext_external_memory_dma_buf.name)) {
                has_vk_ext_external_memory_dma_buf = true;
            } else if (std.mem.eql(u8, property_name, vk.extensions.ext_image_drm_format_modifier.name)) {
                has_vk_ext_image_drm_format_modifier = true;
            }
        }

        var queue_family_count: u32 = undefined;
        vk_instance.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);
        try queue_families.resize(queue_family_count);
        vk_instance.getPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.items.ptr);

        var graphics_queue: ?usize = null;
        for (queue_families.items, 0..) |queue_family, i| {
            if (queue_family.queue_flags.graphics_bit) {
                graphics_queue = i;
            }
        }

        if (has_vk_khr_external_memory_fd and
            has_vk_ext_external_memory_dma_buf and
            has_vk_ext_image_drm_format_modifier and
            graphics_queue != null and
            device_score > current_device_score)
        {
            physical_device = device;
            device_queue_create_info.queue_family_index = @intCast(graphics_queue.?);
            current_device_score = device_score;
        }
    }

    return .{
        .ptr = try vk_instance.createDevice(
            physical_device orelse return error.InitializationFailed,
            &device_create_info,
            null,
        ),
        .queue_family_index = device_queue_create_info.queue_family_index,
        .physical_device = physical_device.?,
    };
}

const VulkanAllocationMetadata = struct {
    size: usize,
    log2_align: u8,
    scope: vk.SystemAllocationScope,
};

pub fn _vkAllocation(userdata: ?*anyopaque, size: usize, alignment: usize, scope: vk.SystemAllocationScope) callconv(.C) ?*anyopaque {
    const this: *@This() = @ptrCast(@alignCast(userdata));

    this.vulkan_allocation_metadata.ensureUnusedCapacity(this.allocator, 1) catch return null;

    const log2_align: u8 = @intCast(std.math.log2(alignment));

    const ptr = this.allocator.rawAlloc(size, log2_align, 0) orelse return null;
    this.vulkan_allocation_metadata.putAssumeCapacity(ptr, .{
        .size = size,
        .log2_align = log2_align,
        .scope = scope,
    });
    std.log.debug("{s}:{} {s}({*}, {}, {}, {s}) -> {*}", .{ @src().file, @src().line, @src().fn_name, this, size, alignment, @tagName(scope), ptr });

    return ptr;
}

pub fn _vkReallocation(userdata: ?*anyopaque, original_ptr_opt: ?*anyopaque, new_size: usize, alignment: usize, scope: vk.SystemAllocationScope) callconv(.C) ?*anyopaque {
    const this: *@This() = @ptrCast(@alignCast(userdata));
    const original_ptr: [*]u8 = @ptrCast(original_ptr_opt orelse return _vkAllocation(this, new_size, alignment, scope));
    std.log.debug("{s}:{} {s}({*}, {*}, {}, {}, {s})", .{ @src().file, @src().line, @src().fn_name, this, original_ptr, new_size, alignment, @tagName(scope) });

    const meta = this.vulkan_allocation_metadata.getPtr(original_ptr) orelse {
        std.log.warn("Vulkan driver passed in unknown allocation {*} to {s}!", .{ original_ptr, @src().fn_name });
        return null;
    };

    std.log.debug("{s}:{} old alloc ({}b, align 2^{}, {s})", .{ @src().file, @src().line, meta.size, meta.log2_align, @tagName(meta.scope) });

    const original_alignment = @as(usize, 1) << @intCast(meta.log2_align);
    if (original_alignment != alignment) {
        std.log.warn("Vulkan driver passed in mismatched alignment to {s}; original allocation for {*} required align of {}, new align is {}!", .{
            @src().fn_name,
            original_ptr,
            original_alignment,
            alignment,
        });
        return null;
    }

    if (this.allocator.rawResize(original_ptr[0..new_size], meta.log2_align, new_size, 0)) {
        meta.size = new_size;
        return original_ptr;
    } else {
        const log2_align: u8 = @intCast(std.math.log2(alignment));

        const new_ptr = this.allocator.rawAlloc(new_size, log2_align, 0) orelse return null;
        const old_size = meta.size;
        @memcpy(new_ptr[0..old_size], original_ptr[0..old_size]);

        std.debug.assert(this.vulkan_allocation_metadata.swapRemove(original_ptr));
        this.vulkan_allocation_metadata.putAssumeCapacity(new_ptr, .{
            .size = new_size,
            .log2_align = log2_align,
            .scope = scope,
        });
        return new_ptr;
    }
}

pub fn _vkFree(userdata: ?*anyopaque, ptr_opt: ?*anyopaque) callconv(.C) void {
    const this: *@This() = @ptrCast(@alignCast(userdata));
    const ptr: [*]u8 = @ptrCast(ptr_opt orelse return);
    std.log.debug("{s}:{} {s}({*}, {*})", .{ @src().file, @src().line, @src().fn_name, this, ptr });

    const meta = this.vulkan_allocation_metadata.fetchSwapRemove(ptr) orelse {
        std.log.warn("Vulkan driver passed in unknown allocation {*}!", .{ptr});
        return;
    };

    this.allocator.rawFree(ptr[0..meta.value.size], meta.value.log2_align, 0);
}

pub fn graphics(this: *@This()) seizer.Graphics {
    return .{
        .pointer = this,
        .interface = &INTERFACE,
    };
}

pub const INTERFACE = seizer.Graphics.Interface.getTypeErasedFunctions(@This(), .{
    .driver = .vulkan,
    .destroy = destroy,
    .begin = _begin,
    .createShader = _createShader,
    .destroyShader = _destroyShader,
    .createTexture = _createTexture,
});

fn destroy(this: *@This()) void {
    while (this.render_buffers.count() > 0) {
        this.render_buffers.keys()[0].renderBuffer().release();
        this.render_buffers.swapRemoveAt(0);
    }
    this.render_buffers.deinit(this.allocator);

    this.vk_device.destroyRenderPass(this.vk_render_pass, null);
    this.vk_device.destroyCommandPool(this.vk_command_pool, null);
    this.vk_device.destroyDevice(null);
    this.vk_instance.destroyInstance(null);
    this.allocator.destroy(this);
}

fn _begin(this: *@This(), options: seizer.Graphics.BeginOptions) seizer.Graphics.BeginError!seizer.Graphics.CommandBuffer {
    var vk_command_buffers: [1]vk.CommandBuffer = undefined;
    this.vk_device.allocateCommandBuffers(&vk.CommandBufferAllocateInfo{
        .command_pool = this.vk_command_pool,
        .level = vk.CommandBufferLevel.primary,
        .command_buffer_count = vk_command_buffers.len,
    }, &vk_command_buffers) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
        error.Unknown => unreachable, // TODO
    };
    errdefer this.vk_device.freeCommandBuffers(this.vk_command_pool, vk_command_buffers.len, &vk_command_buffers);

    const render_buffer = RenderBuffer.create(
        this.allocator,
        this.vk_device,
        options.size,
        this.image_format,
        this.vk_memory_properties,
        this.vk_render_pass,
        this.drm_format_modifier_properties_list.items,
        this.drm_format_modifier_list.items,
    ) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => unreachable, // TODO
    };
    errdefer render_buffer.renderBuffer().release();

    this.vk_device.beginCommandBuffer(vk_command_buffers[0], &vk.CommandBufferBeginInfo{
        .flags = .{},
    }) catch unreachable;
    this.vk_device.cmdBeginRenderPass(vk_command_buffers[0], &vk.RenderPassBeginInfo{
        .render_pass = this.vk_render_pass,
        .framebuffer = render_buffer.vk_framebuffer,
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = render_buffer.size[0], .height = render_buffer.size[1] },
        },
        .clear_value_count = 1,
        .p_clear_values = &[_]vk.ClearValue{
            .{
                .color = vk.ClearColorValue{
                    .float_32 = options.clear_color orelse .{ 0, 0, 0, 1 },
                },
            },
        },
    }, .@"inline");

    this.vk_device.cmdSetViewport(vk_command_buffers[0], 0, 1, &[_]vk.Viewport{
        .{
            .x = 0,
            .y = 0,
            .width = @floatFromInt(render_buffer.size[0]),
            .height = @floatFromInt(render_buffer.size[1]),
            .min_depth = 0,
            .max_depth = 1,
        },
    });
    this.vk_device.cmdSetScissor(vk_command_buffers[0], 0, 1, &[_]vk.Rect2D{
        .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = vk.Extent2D{
                .width = render_buffer.size[0],
                .height = render_buffer.size[1],
            },
        },
    });

    const command_buffer = try CommandBuffer.create(this.allocator, this.vk_device, vk_command_buffers[0], this.vk_graphics_queue, render_buffer);
    // errdefer command_buffer.destroy();

    render_buffer.acquire();
    try this.render_buffers.put(this.allocator, render_buffer, {});

    return command_buffer.commandBuffer();
}

fn _createTexture(this: *@This(), allocator: std.mem.Allocator, image: zigimg.Image, options: seizer.Graphics.CreateTextureOptions) seizer.Graphics.CreateTextureError!seizer.Graphics.Texture {
    _ = this;
    _ = image;
    _ = allocator;
    _ = options;
    std.debug.panic("{s}:{} unimplemented", .{ @src().file, @src().line });
}

fn _createShader(this: *@This(), allocator: std.mem.Allocator, options: seizer.Graphics.Shader.CreateOptions) seizer.Graphics.Shader.CreateError!*seizer.Graphics.Shader {
    _ = this;
    _ = allocator;
    _ = options;
    std.debug.panic("{s}:{} unimplemented", .{ @src().file, @src().line });
}

fn _destroyShader(this: *@This(), shader: *seizer.Graphics.Shader) void {
    _ = this;
    _ = shader;
    std.debug.panic("{s}:{} unimplemented", .{ @src().file, @src().line });
}

const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    vk_device: VulkanDevice,

    vk_command_buffer: vk.CommandBuffer,
    vk_graphics_queue: vk.Queue,
    render_buffer: *RenderBuffer,

    pub fn create(allocator: std.mem.Allocator, vk_device: VulkanDevice, vk_command_buffer: vk.CommandBuffer, vk_graphics_queue: vk.Queue, render_buffer: *RenderBuffer) !*@This() {
        const this = try allocator.create(@This());
        errdefer allocator.destroy(this);

        this.* = .{
            .allocator = allocator,
            .vk_device = vk_device,
            .vk_command_buffer = vk_command_buffer,
            .vk_graphics_queue = vk_graphics_queue,
            .render_buffer = render_buffer,
        };
        return this;
    }

    pub fn commandBuffer(this: *@This()) seizer.Graphics.CommandBuffer {
        return .{
            .pointer = this,
            .interface = &CommandBuffer.INTERFACE,
        };
    }

    pub const INTERFACE = seizer.Graphics.CommandBuffer.Interface.getTypeErasedFunctions(@This(), .{
        .end = CommandBuffer.end,
    });

    fn end(this: *@This()) seizer.Graphics.CommandBuffer.EndError!seizer.Graphics.RenderBuffer {
        this.vk_device.cmdEndRenderPass(this.vk_command_buffer);
        this.vk_device.endCommandBuffer(this.vk_command_buffer) catch unreachable;

        this.vk_device.queueSubmit(this.vk_graphics_queue, 1, &[_]vk.SubmitInfo{
            .{
                // .wait_semaphore_count = 1,
                // .p_wait_semaphores = &[_]vk.Semaphore{image_available_semaphore},
                .command_buffer_count = 1,
                .p_command_buffers = &.{this.vk_command_buffer},
                // .signal_semaphore_count = 1,
                // .p_signal_semaphores = &[_]vk.Semaphore{render_finished_semaphore},
            },
        }, .null_handle) catch unreachable;

        const render_buffer = this.render_buffer.renderBuffer();
        this.allocator.destroy(this);
        return render_buffer;
    }
};

const RenderBuffer = struct {
    allocator: std.mem.Allocator,
    vk_device: VulkanDevice,
    reference_count: u32,

    size: [2]u32,
    image_format: vk.Format,
    vk_image: vk.Image,
    vk_device_memory: vk.DeviceMemory,
    vk_imageview: vk.ImageView,
    vk_framebuffer: vk.Framebuffer,
    drm_modifier_properties: vk.DrmFormatModifierPropertiesEXT,

    pub fn create(
        allocator: std.mem.Allocator,
        vk_device: VulkanDevice,
        size: [2]u32,
        image_format: vk.Format,
        vk_memory_properties: vk.PhysicalDeviceMemoryProperties,
        vk_render_pass: vk.RenderPass,
        drm_format_modifier_properties_list: []const vk.DrmFormatModifierPropertiesEXT,
        drm_format_modifiers: []const u64,
    ) !*@This() {
        const this = try allocator.create(@This());
        errdefer allocator.destroy(this);

        const vk_framebuffer_image = try vk_device.createImage(&vk.ImageCreateInfo{
            .p_next = &vk.ExternalMemoryImageCreateInfo{
                .handle_types = .{ .dma_buf_bit_ext = true },
                .p_next = &vk.ImageDrmFormatModifierListCreateInfoEXT{
                    .drm_format_modifier_count = @intCast(drm_format_modifiers.len),
                    .p_drm_format_modifiers = drm_format_modifiers.ptr,
                },
            },
            .image_type = .@"2d",
            .format = image_format,
            .extent = .{ .width = size[0], .height = size[1], .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .drm_format_modifier_ext,
            .usage = .{ .color_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer vk_device.destroyImage(vk_framebuffer_image, null);

        var image_drm_format_modifier_properties = vk.ImageDrmFormatModifierPropertiesEXT{ .drm_format_modifier = undefined };
        try vk_device.getImageDrmFormatModifierPropertiesEXT(vk_framebuffer_image, &image_drm_format_modifier_properties);
        var drm_modifier_properties = drm_format_modifier_properties_list[0];
        for (drm_format_modifier_properties_list) |properties| {
            if (properties.drm_format_modifier == image_drm_format_modifier_properties.drm_format_modifier) {
                drm_modifier_properties = properties;
                break;
            }
        }
        const memory_requirements = vk_device.getImageMemoryRequirements(vk_framebuffer_image);

        var memory_type_index: u32 = 0;
        for (vk_memory_properties.memory_types[0..vk_memory_properties.memory_type_count], 0..) |memory_type, i| {
            if (memory_requirements.memory_type_bits == memory_requirements.memory_type_bits & @as(u32, @bitCast(memory_type.property_flags))) {
                memory_type_index = @intCast(i);
            }
        }

        const vk_device_memory = try vk_device.allocateMemory(&vk.MemoryAllocateInfo{
            .p_next = &vk.ExportMemoryAllocateInfo{
                .handle_types = .{ .dma_buf_bit_ext = true },
            },
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        }, null);
        errdefer vk_device.freeMemory(vk_device_memory, null);

        try vk_device.bindImageMemory(vk_framebuffer_image, vk_device_memory, 0);

        const vk_image_view = try vk_device.createImageView(&vk.ImageViewCreateInfo{
            .image = vk_framebuffer_image,
            .view_type = .@"2d",
            .format = image_format,
            .components = .{ .r = .r, .g = .g, .b = .b, .a = .a },
            .subresource_range = .{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .base_mip_level = 0,
                .level_count = 1,
                .layer_count = 1,
                .base_array_layer = 0,
            },
        }, null);
        errdefer vk_device.destroyImageView(vk_image_view, null);

        const vk_framebuffer = try vk_device.createFramebuffer(&vk.FramebufferCreateInfo{
            .render_pass = vk_render_pass,
            .width = size[0],
            .height = size[1],
            .layers = 1,
            .attachment_count = 1,
            .p_attachments = &[_]vk.ImageView{vk_image_view},
        }, null);
        errdefer vk_device.destroyFramebuffer(vk_framebuffer, null);

        this.* = .{
            .allocator = allocator,
            .vk_device = vk_device,
            .reference_count = 1,

            .size = size,
            .image_format = image_format,
            .vk_image = vk_framebuffer_image,
            .vk_device_memory = vk_device_memory,
            .vk_imageview = vk_image_view,
            .vk_framebuffer = vk_framebuffer,
            .drm_modifier_properties = drm_modifier_properties,
        };

        return this;
    }

    pub fn renderBuffer(this: *@This()) seizer.Graphics.RenderBuffer {
        return .{
            .pointer = this,
            .interface = &RenderBuffer.INTERFACE,
        };
    }

    pub const INTERFACE = seizer.Graphics.RenderBuffer.Interface.getTypeErasedFunctions(@This(), .{
        .release = RenderBuffer._release,
        .getSize = RenderBuffer._getSize,
        .getDmaBufFormat = RenderBuffer._getDmaBufFormat,
        .getDmaBufPlanes = RenderBuffer._getDmaBufPlanes,
    });

    pub fn _release(this: *@This()) void {
        this.reference_count -= 1;
        if (this.reference_count == 0) {
            this.destroy();
        }
    }

    fn _getSize(this: *@This()) [2]u32 {
        return this.size;
    }

    fn _getDmaBufFormat(this: *@This()) seizer.Graphics.RenderBuffer.DmaBufFormat {
        return seizer.Graphics.RenderBuffer.DmaBufFormat{
            .fourcc = switch (this.image_format) {
                .r8g8b8a8_unorm => .ABGR8888,
                else => unreachable,
            },
            .plane_count = @intCast(this.drm_modifier_properties.drm_format_modifier_plane_count),
            .modifiers = this.drm_modifier_properties.drm_format_modifier,
        };
    }

    fn _getDmaBufPlanes(this: *@This(), buf: []seizer.Graphics.RenderBuffer.DmaBufPlane) []seizer.Graphics.RenderBuffer.DmaBufPlane {
        const memory_fd = this.vk_device.getMemoryFdKHR(&vk.MemoryGetFdInfoKHR{
            .memory = this.vk_device_memory,
            .handle_type = .{ .dma_buf_bit_ext = true },
        }) catch unreachable; // TODO

        const slice = buf[0..this.drm_modifier_properties.drm_format_modifier_plane_count];
        for (slice, 0..) |*dma_buf_plane, i| {
            const plane_layout = this.vk_device.getImageSubresourceLayout(this.vk_image, &vk.ImageSubresource{
                .aspect_mask = .{
                    .memory_plane_0_bit_ext = i == 0,
                    .memory_plane_1_bit_ext = i == 1,
                    .memory_plane_2_bit_ext = i == 2,
                },
                .mip_level = 0,
                .array_layer = 0,
            });
            dma_buf_plane.* = seizer.Graphics.RenderBuffer.DmaBufPlane{
                .fd = memory_fd,
                .index = @intCast(i),
                .offset = @intCast(plane_layout.offset),
                .stride = @intCast(plane_layout.row_pitch),
            };
        }

        return slice;
    }

    pub fn destroy(this: *@This()) void {
        this.vk_device.destroyFramebuffer(this.vk_framebuffer, null);
        this.vk_device.destroyImageView(this.vk_imageview, null);
        this.vk_device.freeMemory(this.vk_device_memory, null);
        this.vk_device.destroyImage(this.vk_image, null);

        this.allocator.destroy(this);
    }

    pub fn acquire(this: *@This()) void {
        this.reference_count += 1;
    }
};

const vk = @import("vulkan");
const vulkan_apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.extensions.khr_external_memory_fd,
    vk.extensions.ext_external_memory_dma_buf,
    vk.extensions.ext_image_drm_format_modifier,
};
const VulkanBaseDispatch = vk.BaseWrapper(vulkan_apis);
const VulkanInstanceDispatch = vk.InstanceWrapper(vulkan_apis);
const VulkanInstance = vk.InstanceProxy(vulkan_apis);
const VulkanDeviceDispatch = vk.DeviceWrapper(vulkan_apis);
const VulkanDevice = vk.DeviceProxy(vulkan_apis);

const @"dynamic-library-utils" = @import("dynamic-library-utils");
const zigimg = @import("zigimg");
const seizer = @import("../../seizer.zig");
const std = @import("std");
const builtin = @import("builtin");

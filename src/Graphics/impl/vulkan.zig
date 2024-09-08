allocator: std.mem.Allocator,
vk_allocation_callbacks: vk.AllocationCallbacks,
vulkan_allocation_metadata: std.AutoArrayHashMapUnmanaged([*]u8, VulkanAllocationMetadata),

libvulkan: std.DynLib,

vkb: *VulkanBaseDispatch,
vk_instance: VulkanInstance,
vk_device: VulkanDevice,

vk_command_pool: vk.CommandPool,
vk_descriptor_pool: vk.DescriptorPool,
vk_render_pass: vk.RenderPass,
vk_graphics_queue: vk.Queue,

image_format: vk.Format,
vk_memory_properties: vk.PhysicalDeviceMemoryProperties,
// drm_format_modifier_properties_list: std.ArrayListUnmanaged(vk.DrmFormatModifierPropertiesEXT),
// drm_format_modifier_list: std.ArrayListUnmanaged(u64),

render_buffers: std.AutoArrayHashMapUnmanaged(*RenderBuffer, void),

const VulkanImpl = @This();

const DEFAULT_IMAGE_FORMAT = .r8g8b8a8_unorm;

pub fn create(allocator: std.mem.Allocator, options: seizer.Platform.CreateGraphicsOptions) seizer.Platform.CreateGraphicsError!seizer.Graphics {
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

    const vkb = try allocator.create(VulkanBaseDispatch);
    errdefer allocator.destroy(vkb);
    vkb.* = VulkanBaseDispatch.load(vk_get_instance_proc_addr_fn) catch return error.LibraryLoadFailed;

    var vk_enabled_layers = std.ArrayList([*:0]const u8).init(allocator);
    defer vk_enabled_layers.deinit();

    {
        var layer_properties_count: u32 = undefined;
        _ = vkb.enumerateInstanceLayerProperties(&layer_properties_count, null) catch return error.InitializationFailed;
        const layer_properties = try allocator.alloc(vk.LayerProperties, layer_properties_count);
        defer allocator.free(layer_properties);
        _ = vkb.enumerateInstanceLayerProperties(&layer_properties_count, layer_properties.ptr) catch |err| switch (err) {
            error.OutOfHostMemory => return error.OutOfMemory,
            else => return error.InitializationFailed,
        };

        for (layer_properties) |layer_property| {
            const end_of_name = std.mem.indexOfScalar(u8, &layer_property.layer_name, 0) orelse layer_property.layer_name.len;
            const name = layer_property.layer_name[0..end_of_name];
            if (std.mem.eql(u8, name, "VK_LAYER_KHRONOS_validation")) {
                if (builtin.mode == .Debug) {
                    try vk_enabled_layers.append("VK_LAYER_KHRONOS_validation");
                    std.log.debug("khronos validation layers enabled", .{});
                }
            }
        }
    }

    // TODO: Implement vulkan allocator interface
    const vk_instance_ptr = vkb.createInstance(&.{
        .p_application_info = &vk.ApplicationInfo{
            .p_application_name = if (options.app_name) |name| name.ptr else null,
            .application_version = if (options.app_version) |version| vk.makeApiVersion(0, @intCast(version.major), @intCast(version.minor), @intCast(version.patch)) else 0,
            .p_engine_name = "seizer",
            .engine_version = vk.makeApiVersion(0, seizer.version.major, seizer.version.minor, seizer.version.patch),
            .api_version = vk.API_VERSION_1_2,
        },
        .enabled_layer_count = @intCast(vk_enabled_layers.items.len),
        .pp_enabled_layer_names = vk_enabled_layers.items.ptr,
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

    const vk_instance_dispatch = try allocator.create(VulkanInstanceDispatch);
    errdefer allocator.destroy(vk_instance_dispatch);
    vk_instance_dispatch.* = VulkanInstanceDispatch.load(vk_instance_ptr, vkb.dispatch.vkGetInstanceProcAddr) catch return error.LibraryLoadFailed;

    const vk_instance = VulkanInstance.init(vk_instance_ptr, vk_instance_dispatch);
    errdefer vk_instance.destroyInstance(null);

    const device_result = pickVkDevice(allocator, vk_instance) catch |err| switch (err) {
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

    const vk_device_dispatch = try allocator.create(VulkanDeviceDispatch);
    errdefer allocator.destroy(vk_device_dispatch);
    vk_device_dispatch.* = VulkanDeviceDispatch.load(device_result.ptr, vk_instance.wrapper.dispatch.vkGetDeviceProcAddr) catch return error.LibraryLoadFailed;

    const vk_device = VulkanDevice.init(device_result.ptr, vk_device_dispatch);
    errdefer vk_device.destroyDevice(null);

    const vk_command_pool = vk_device.createCommandPool(&vk.CommandPoolCreateInfo{
        .queue_family_index = device_result.queue_family_index,
        .flags = .{ .reset_command_buffer_bit = true },
    }, null) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        error.Unknown => return error.InitializationFailed,
        error.OutOfDeviceMemory => |e| return e,
    };
    errdefer vk_device.destroyCommandPool(vk_command_pool, null);

    // create render pass
    const vk_render_pass = vk_device.createRenderPass(&vk.RenderPassCreateInfo{
        .attachment_count = 1,
        .p_attachments = &[_]vk.AttachmentDescription{
            .{
                .format = DEFAULT_IMAGE_FORMAT,
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
    errdefer vk_device.destroyRenderPass(vk_render_pass, null);

    const vk_descriptor_pool = vk_device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
        .flags = .{ .free_descriptor_set_bit = true },
        .max_sets = 1000,
        .pool_size_count = 1,
        .p_pool_sizes = &[_]vk.DescriptorPoolSize{
            .{ .type = .uniform_buffer, .descriptor_count = 10 },
            .{ .type = .combined_image_sampler, .descriptor_count = 10 },
        },
    }, null) catch unreachable;

    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);

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
        .vkb = vkb,

        .vk_instance = vk_instance,
        .vk_device = vk_device,
        .vk_descriptor_pool = vk_descriptor_pool,
        .vk_command_pool = vk_command_pool,
        .image_format = DEFAULT_IMAGE_FORMAT,

        .vk_graphics_queue = this.vk_device.getDeviceQueue(device_result.queue_family_index, 0),
        .vk_render_pass = vk_render_pass,

        .vk_memory_properties = this.vk_instance.getPhysicalDeviceMemoryProperties(device_result.physical_device),
        // .drm_format_modifier_properties_list = .{},
        // .drm_format_modifier_list = .{},
        .render_buffers = .{},
    };

    // get format properties
    // var vk_drm_modifier_properties = vk.DrmFormatModifierPropertiesListEXT{
    //     .drm_format_modifier_count = 0,
    //     .p_drm_format_modifier_properties = null,
    // };
    // var vk_format_properties = vk.FormatProperties2{
    //     .p_next = &vk_drm_modifier_properties,
    //     .format_properties = undefined,
    // };
    // this.vk_instance.getPhysicalDeviceFormatProperties2(device_result.physical_device, this.image_format, &vk_format_properties);

    // try this.drm_format_modifier_properties_list.resize(this.allocator, vk_drm_modifier_properties.drm_format_modifier_count);
    // vk_drm_modifier_properties = vk.DrmFormatModifierPropertiesListEXT{
    //     .drm_format_modifier_count = @intCast(this.drm_format_modifier_properties_list.items.len),
    //     .p_drm_format_modifier_properties = this.drm_format_modifier_properties_list.items.ptr,
    // };

    // this.vk_instance.getPhysicalDeviceFormatProperties2(device_result.physical_device, this.image_format, &vk_format_properties);

    // try this.drm_format_modifier_list.resize(this.allocator, this.drm_format_modifier_properties_list.items.len);
    // for (this.drm_format_modifier_properties_list.items, this.drm_format_modifier_list.items) |properties, *drm_modifier| {
    //     drm_modifier.* = properties.drm_format_modifier;
    // }

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
        // vk.extensions.ext_image_drm_format_modifier.name,
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
        // var has_vk_ext_image_drm_format_modifier = false;
        for (extension_properties.items) |property| {
            const end_of_property_name = std.mem.indexOfScalar(u8, &property.extension_name, 0) orelse property.extension_name.len;
            const property_name = property.extension_name[0..end_of_property_name];
            if (std.mem.eql(u8, property_name, vk.extensions.khr_external_memory_fd.name)) {
                has_vk_khr_external_memory_fd = true;
            } else if (std.mem.eql(u8, property_name, vk.extensions.ext_external_memory_dma_buf.name)) {
                has_vk_ext_external_memory_dma_buf = true;
                // } else if (std.mem.eql(u8, property_name, vk.extensions.ext_image_drm_format_modifier.name)) {
                //     has_vk_ext_image_drm_format_modifier = true;
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
            // has_vk_ext_image_drm_format_modifier and
            graphics_queue != null and
            device_score > current_device_score)
        {
            physical_device = device;
            device_queue_create_info.queue_family_index = @intCast(graphics_queue.?);
            current_device_score = device_score;
        }
    }

    if (physical_device) |device| {
        const device_properties = vk_instance.getPhysicalDeviceProperties(device);
        const end_of_name = std.mem.indexOfScalar(u8, &device_properties.device_name, 0) orelse device_properties.device_name.len;
        const name = device_properties.device_name[0..end_of_name];
        std.log.debug("selected gpu = {s}", .{name});
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
    .destroyTexture = _destroyTexture,
    .createPipeline = _createPipeline,
    .destroyPipeline = _destroyPipeline,
    .createBuffer = _createBuffer,
    .destroyBuffer = _destroyBuffer,
    .releaseRenderBuffer = _releaseRenderBuffer,
});

fn destroy(this: *@This()) void {
    while (this.render_buffers.count() > 0) {
        _ = this.vk_device.waitForFences(1, &.{this.render_buffers.keys()[0].finished_fence}, vk.TRUE, 10 * std.time.ns_per_ms) catch unreachable;
        this.render_buffers.keys()[0].destroy();
        this.render_buffers.swapRemoveAt(0);
    }
    this.render_buffers.deinit(this.allocator);

    this.vk_device.destroyDescriptorPool(this.vk_descriptor_pool, null);
    this.vk_device.destroyRenderPass(this.vk_render_pass, null);
    this.vk_device.destroyCommandPool(this.vk_command_pool, null);
    this.vk_device.destroyDevice(null);
    this.vk_instance.destroyInstance(null);

    this.allocator.destroy(this.vk_device.wrapper);
    this.allocator.destroy(this.vk_instance.wrapper);
    this.allocator.destroy(this.vkb);
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

    // clear render buffers with a size that doesn't match current size
    {
        var i = this.render_buffers.count();
        while (i > 0) : (i -= 1) {
            const render_buffer = this.render_buffers.keys()[i - 1];
            const is_finished = this.vk_device.getFenceStatus(render_buffer.finished_fence) catch continue;
            if (is_finished != .success) {
                continue;
            }
            if (render_buffer.size[0] == options.size[0] and render_buffer.size[1] == options.size[1]) {
                continue;
            }
            render_buffer.destroy();
            this.render_buffers.swapRemoveAt(i - 1);
        }
    }

    const render_buffer = for (this.render_buffers.keys(), 0..) |render_buffer, i| {
        const is_finished = this.vk_device.getFenceStatus(render_buffer.finished_fence) catch continue;
        if (is_finished != .success) {
            continue;
        }
        this.render_buffers.swapRemoveAt(i);
        break render_buffer;
    } else RenderBuffer.create(
        this,
        options.size,
        this.image_format,
        this.vk_memory_properties,
        this.vk_render_pass,
        // this.drm_format_modifier_properties_list.items,
        // this.drm_format_modifier_list.items,
    ) catch |err| switch (err) {
        error.OutOfHostMemory => return error.OutOfMemory,
        else => unreachable, // TODO
    };
    errdefer render_buffer.renderBuffer().release();
    if (render_buffer.vk_descriptor_sets) |sets| {
        this.vk_device.freeDescriptorSets(this.vk_descriptor_pool, @intCast(sets.len), sets.ptr) catch unreachable;
        this.allocator.free(sets);
        render_buffer.vk_descriptor_sets = null;
    }
    this.vk_device.resetFences(1, &.{render_buffer.finished_fence}) catch unreachable;

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

    const command_buffer = try CommandBuffer.create(this.allocator, this.vk_device, vk_command_buffers[0], this.vk_descriptor_pool, this.vk_graphics_queue, render_buffer);
    // errdefer command_buffer.destroy();

    return command_buffer.commandBuffer();
}

const Texture = struct {
    vk_image: vk.Image,
    vk_device_memory: vk.DeviceMemory,
    vk_image_view: vk.ImageView,
    vk_sampler: vk.Sampler,
};

fn _createTexture(this: *@This(), image: zigimg.Image, options: seizer.Graphics.Texture.CreateOptions) seizer.Graphics.Texture.CreateError!*seizer.Graphics.Texture {
    const vk_copy_buffer = this.vk_device.createBuffer(&vk.BufferCreateInfo{
        .size = image.imageByteSize(),
        .usage = .{ .transfer_src_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch unreachable;
    defer this.vk_device.destroyBuffer(vk_copy_buffer, null);

    const copy_buffer_memory_requirements = this.vk_device.getBufferMemoryRequirements(vk_copy_buffer);
    const copy_buffer_memory_type_index = findMemoryTypeIndex(this.vk_memory_properties, copy_buffer_memory_requirements) orelse unreachable;

    const vk_copy_buffer_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
        .allocation_size = copy_buffer_memory_requirements.size,
        .memory_type_index = copy_buffer_memory_type_index,
    }, null) catch unreachable;
    defer this.vk_device.freeMemory(vk_copy_buffer_memory, null);

    // copy pixels to gpu
    {
        const texture_pixels: []u8 = @as([*]u8, @ptrCast((this.vk_device.mapMemory(vk_copy_buffer_memory, 0, image.imageByteSize(), .{}) catch unreachable).?))[0..image.imageByteSize()];
        defer this.vk_device.unmapMemory(vk_copy_buffer_memory);
        @memcpy(texture_pixels, image.rawBytes());
    }

    this.vk_device.bindBufferMemory(vk_copy_buffer, vk_copy_buffer_memory, 0) catch unreachable;

    // create an image object that will be the final destination of the pixels
    const vk_image = this.vk_device.createImage(&vk.ImageCreateInfo{
        .image_type = .@"2d",
        .format = switch (image.pixelFormat()) {
            .rgba32 => .r8g8b8a8_unorm,
            else => return error.UnsupportedFormat,
        },
        .extent = .{ .width = @intCast(image.width), .height = @intCast(image.height), .depth = 1 },
        .mip_levels = 1,
        .array_layers = 1,
        .samples = .{ .@"1_bit" = true },
        .tiling = .optimal,
        .usage = .{ .transfer_dst_bit = true, .sampled_bit = true },
        .sharing_mode = .exclusive,
        .initial_layout = .undefined,
    }, null) catch unreachable;
    errdefer this.vk_device.destroyImage(vk_image, null);

    const image_memory_requirements = this.vk_device.getImageMemoryRequirements(vk_image);
    const image_memory_type_index = findMemoryTypeIndex(this.vk_memory_properties, image_memory_requirements) orelse unreachable;

    const vk_image_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
        .allocation_size = image_memory_requirements.size,
        .memory_type_index = image_memory_type_index,
    }, null) catch unreachable;
    errdefer this.vk_device.freeMemory(vk_image_memory, null);

    this.vk_device.bindImageMemory(vk_image, vk_image_memory, 0) catch unreachable;

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
    defer this.vk_device.freeCommandBuffers(this.vk_command_pool, vk_command_buffers.len, &vk_command_buffers);

    this.vk_device.beginCommandBuffer(vk_command_buffers[0], &.{}) catch unreachable;

    const image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .old_layout = .undefined,
            .new_layout = .transfer_dst_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = vk_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{},
            .dst_access_mask = .{ .transfer_write_bit = true },
        },
    };
    this.vk_device.cmdPipelineBarrier(vk_command_buffers[0], .{ .top_of_pipe_bit = true }, .{ .transfer_bit = true }, .{}, 0, null, 0, null, image_barriers.len, image_barriers[0..]);

    this.vk_device.cmdCopyBufferToImage(
        vk_command_buffers[0],
        vk_copy_buffer,
        vk_image,
        .transfer_dst_optimal,
        1,
        &[1]vk.BufferImageCopy{
            .{
                .buffer_offset = 0,
                .buffer_row_length = 0,
                .buffer_image_height = 0,
                .image_subresource = vk.ImageSubresourceLayers{
                    .aspect_mask = .{ .color_bit = true },
                    .mip_level = 0,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
                .image_offset = vk.Offset3D{ .x = 0, .y = 0, .z = 0 },
                .image_extent = vk.Extent3D{ .width = @intCast(image.width), .height = @intCast(image.height), .depth = 1 },
            },
        },
    );

    const to_shader_image_barriers = [_]vk.ImageMemoryBarrier{
        .{
            .old_layout = .transfer_dst_optimal,
            .new_layout = .shader_read_only_optimal,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = vk_image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
            .src_access_mask = .{ .transfer_write_bit = true },
            .dst_access_mask = .{ .shader_read_bit = true },
        },
    };
    this.vk_device.cmdPipelineBarrier(vk_command_buffers[0], .{ .transfer_bit = true }, .{ .fragment_shader_bit = true }, .{}, 0, null, 0, null, to_shader_image_barriers.len, to_shader_image_barriers[0..]);

    this.vk_device.endCommandBuffer(vk_command_buffers[0]) catch unreachable;

    this.vk_device.queueSubmit(this.vk_graphics_queue, 1, &[1]vk.SubmitInfo{
        .{
            .command_buffer_count = vk_command_buffers.len,
            .p_command_buffers = vk_command_buffers[0..],
        },
    }, .null_handle) catch unreachable;
    this.vk_device.queueWaitIdle(this.vk_graphics_queue) catch unreachable;

    const vk_sampler = this.vk_device.createSampler(&vk.SamplerCreateInfo{
        .mag_filter = switch (options.mag_filter) {
            .nearest => .nearest,
            .linear => .linear,
        },
        .min_filter = switch (options.min_filter) {
            .nearest => .nearest,
            .linear => .linear,
        },
        .mipmap_mode = .nearest,
        .address_mode_u = switch (options.wrap[0]) {
            .repeat => .repeat,
            .clamp_to_edge => .clamp_to_edge,
        },
        .address_mode_v = switch (options.wrap[0]) {
            .repeat => .repeat,
            .clamp_to_edge => .clamp_to_edge,
        },
        .address_mode_w = .clamp_to_edge,

        .mip_lod_bias = 0,
        .anisotropy_enable = vk.FALSE,
        .max_anisotropy = 0,
        .compare_enable = vk.FALSE,
        .compare_op = .greater,
        .min_lod = 0,
        .max_lod = 0,
        .border_color = .float_transparent_black,
        .unnormalized_coordinates = vk.FALSE,
    }, null) catch unreachable;

    const vk_image_view = this.vk_device.createImageView(&vk.ImageViewCreateInfo{
        .image = vk_image,
        .view_type = .@"2d",
        .format = switch (image.pixelFormat()) {
            .rgba32 => .r8g8b8a8_unorm,
            else => return error.UnsupportedFormat,
        },
        .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
        .subresource_range = vk.ImageSubresourceRange{
            .aspect_mask = .{ .color_bit = true },
            .base_mip_level = 0,
            .level_count = 1,
            .base_array_layer = 0,
            .layer_count = 1,
        },
    }, null) catch unreachable;

    const texture = try this.allocator.create(Texture);
    texture.* = .{
        .vk_image = vk_image,
        .vk_device_memory = vk_image_memory,
        .vk_image_view = vk_image_view,
        .vk_sampler = vk_sampler,
    };

    return @ptrCast(texture);
}

fn _destroyTexture(this: *@This(), texture_opaque: *seizer.Graphics.Texture) void {
    const texture: *Texture = @ptrCast(@alignCast(texture_opaque));

    this.vk_device.destroyImageView(texture.vk_image_view, null);
    this.vk_device.destroyImage(texture.vk_image, null);
    this.vk_device.freeMemory(texture.vk_device_memory, null);
    this.vk_device.destroySampler(texture.vk_sampler, null);

    this.allocator.destroy(texture);
}

const Shader = struct {
    vk_shader: vk.ShaderModule,
    stage: seizer.Graphics.Shader.Target,
    entry_point_name: [:0]const u8,
};

fn _createShader(this: *@This(), options: seizer.Graphics.Shader.CreateOptions) seizer.Graphics.Shader.CreateError!*seizer.Graphics.Shader {
    const spirv = switch (options.source) {
        .glsl => return error.UnsupportedFormat,
        .spirv => |spirv| spirv,
    };

    const vk_shader = this.vk_device.createShaderModule(&vk.ShaderModuleCreateInfo{
        .code_size = spirv.len * @sizeOf(u32),
        .p_code = spirv.ptr,
    }, null) catch unreachable;
    errdefer this.vk_device.destroyShaderModule(vk_shader, null);

    const entry_point_name = try this.allocator.dupeZ(u8, options.entry_point_name);
    errdefer this.allocator.free(entry_point_name);

    const shader = try this.allocator.create(Shader);
    errdefer this.allocator.destroy(shader);

    shader.* = .{
        .vk_shader = vk_shader,
        .stage = options.target,
        .entry_point_name = entry_point_name,
    };

    return @ptrCast(shader);
}

fn _destroyShader(this: *@This(), shader_opaque: *seizer.Graphics.Shader) void {
    const shader: *Shader = @ptrCast(@alignCast(shader_opaque));

    this.vk_device.destroyShaderModule(shader.vk_shader, null);

    this.allocator.free(shader.entry_point_name);
    this.allocator.destroy(shader);
}

const Pipeline = struct {
    vk_pipeline_layout: vk.PipelineLayout,
    vk_pipeline: vk.Pipeline,
    vk_descriptor_set_layout: vk.DescriptorSetLayout,
    uniforms: std.AutoArrayHashMapUnmanaged(u32, Uniform),

    const Uniform = struct {
        buffer: vk.Buffer,
        memory: vk.DeviceMemory,
    };
};

fn _createPipeline(this: *@This(), options: seizer.Graphics.Pipeline.CreateOptions) seizer.Graphics.Pipeline.CreateError!*seizer.Graphics.Pipeline {
    const vertex_shader: *Shader = @ptrCast(@alignCast(options.vertex_shader));
    const fragment_shader: *Shader = @ptrCast(@alignCast(options.fragment_shader));
    const vk_shader_stages = [_]vk.PipelineShaderStageCreateInfo{
        vk.PipelineShaderStageCreateInfo{
            .stage = .{ .vertex_bit = true },
            .module = vertex_shader.vk_shader,
            .p_name = vertex_shader.entry_point_name.ptr,
        },
        vk.PipelineShaderStageCreateInfo{
            .stage = .{ .fragment_bit = true },
            .module = fragment_shader.vk_shader,
            .p_name = fragment_shader.entry_point_name.ptr,
        },
    };

    // key = binding, value = buffer
    var uniforms = std.AutoArrayHashMap(u32, Pipeline.Uniform).init(this.allocator);
    defer {
        for (uniforms.values()) |uniform| {
            this.vk_device.freeMemory(uniform.memory, null);
            this.vk_device.destroyBuffer(uniform.buffer, null);
        }
        uniforms.deinit();
    }

    const uniform_binding_list = try this.allocator.alloc(vk.DescriptorSetLayoutBinding, options.uniforms.len);
    defer this.allocator.free(uniform_binding_list);
    for (uniform_binding_list, options.uniforms) |*uniform_binding, uniform_description| {
        switch (uniform_description.type) {
            .buffer => {
                try uniforms.ensureUnusedCapacity(1);

                const vk_buffer = this.vk_device.createBuffer(&vk.BufferCreateInfo{
                    .size = uniform_description.size,
                    .usage = .{ .uniform_buffer_bit = true },
                    .sharing_mode = .exclusive,
                }, null) catch unreachable;

                const mem_requirements = this.vk_device.getBufferMemoryRequirements(vk_buffer);
                const mem_type_index = findMemoryTypeIndex(this.vk_memory_properties, mem_requirements) orelse unreachable;

                const vk_uniform_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
                    .allocation_size = mem_requirements.size,
                    .memory_type_index = mem_type_index,
                }, null) catch unreachable;

                this.vk_device.bindBufferMemory(vk_buffer, vk_uniform_memory, 0) catch unreachable;

                uniforms.putAssumeCapacity(uniform_description.binding, .{
                    .buffer = vk_buffer,
                    .memory = vk_uniform_memory,
                });
            },
            else => {},
        }
        uniform_binding.* = vk.DescriptorSetLayoutBinding{
            .binding = uniform_description.binding,
            .descriptor_type = switch (uniform_description.type) {
                .sampler2D => .combined_image_sampler,
                .buffer => .uniform_buffer,
            },
            .descriptor_count = uniform_description.count,
            .stage_flags = vk.ShaderStageFlags{
                .vertex_bit = uniform_description.stages.vertex,
                .fragment_bit = uniform_description.stages.fragment,
            },
        };
    }

    const vk_descriptor_set_layout = this.vk_device.createDescriptorSetLayout(&.{
        .binding_count = @intCast(uniform_binding_list.len),
        .p_bindings = uniform_binding_list.ptr,
    }, null) catch unreachable;
    errdefer this.vk_device.destroyDescriptorSetLayout(vk_descriptor_set_layout, null);

    const pipeline_layout = this.vk_device.createPipelineLayout(&vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{vk_descriptor_set_layout},
    }, null) catch unreachable;
    errdefer this.vk_device.destroyPipelineLayout(pipeline_layout, null);

    const vertex_attribute_descriptions = try this.allocator.alloc(vk.VertexInputAttributeDescription, options.vertex_layout.len);
    defer this.allocator.free(vertex_attribute_descriptions);

    for (vertex_attribute_descriptions, options.vertex_layout) |*attribute, vertex_layout| {
        attribute.* = vk.VertexInputAttributeDescription{
            .binding = 0,
            .location = vertex_layout.attribute_index,
            .format = switch (vertex_layout.type) {
                .f32 => switch (vertex_layout.len) {
                    1 => vk.Format.r32_sfloat,
                    2 => vk.Format.r32g32_sfloat,
                    3 => vk.Format.r32g32b32_sfloat,
                    else => |n| std.debug.panic("vertex at binding {} location {} has invalid length of {}", .{ 0, vertex_layout.attribute_index, n }),
                },
                .u8 => switch (vertex_layout.len) {
                    1 => vk.Format.r8_unorm,
                    2 => vk.Format.r8g8_unorm,
                    3 => vk.Format.r8g8b8_unorm,
                    4 => vk.Format.r8g8b8a8_unorm,
                    else => |n| std.debug.panic("vertex at binding {} location {} has invalid length of {}", .{ 0, vertex_layout.attribute_index, n }),
                },
            },
            .offset = vertex_layout.offset,
        };
    }

    const blend_info = if (options.blend) |blend|
        vk.PipelineColorBlendAttachmentState{
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            .blend_enable = vk.TRUE,
            .src_color_blend_factor = switch (blend.src_color_factor) {
                .one => .one,
                .zero => .zero,
                .src_alpha => .src_alpha,
                .one_minus_src_alpha => .one_minus_src_alpha,
            },
            .dst_color_blend_factor = switch (blend.dst_color_factor) {
                .one => .one,
                .zero => .zero,
                .src_alpha => .src_alpha,
                .one_minus_src_alpha => .one_minus_src_alpha,
            },
            .color_blend_op = switch (blend.color_op) {
                .add => .add,
            },
            .src_alpha_blend_factor = switch (blend.src_alpha_factor) {
                .one => .one,
                .zero => .zero,
                .src_alpha => .src_alpha,
                .one_minus_src_alpha => .one_minus_src_alpha,
            },
            .dst_alpha_blend_factor = switch (blend.dst_alpha_factor) {
                .one => .one,
                .zero => .zero,
                .src_alpha => .src_alpha,
                .one_minus_src_alpha => .one_minus_src_alpha,
            },
            .alpha_blend_op = switch (blend.alpha_op) {
                .add => .add,
            },
        }
    else
        vk.PipelineColorBlendAttachmentState{
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
            .blend_enable = 0,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .zero,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .zero,
            .alpha_blend_op = .add,
        };

    var pipelines: [1]vk.Pipeline = undefined;
    _ = this.vk_device.createGraphicsPipelines(.null_handle, 1, &[_]vk.GraphicsPipelineCreateInfo{
        .{
            .stage_count = vk_shader_stages.len,
            .p_stages = &vk_shader_stages,
            .p_vertex_input_state = &vk.PipelineVertexInputStateCreateInfo{
                .vertex_binding_description_count = 1,
                .p_vertex_binding_descriptions = &[_]vk.VertexInputBindingDescription{
                    .{
                        .binding = 0,
                        // TODO: improve options abstraction
                        .stride = options.vertex_layout[0].stride,
                        .input_rate = .vertex,
                    },
                },
                .vertex_attribute_description_count = @intCast(vertex_attribute_descriptions.len),
                .p_vertex_attribute_descriptions = vertex_attribute_descriptions.ptr,
            },
            .p_input_assembly_state = &vk.PipelineInputAssemblyStateCreateInfo{
                .topology = switch (options.primitive_type) {
                    .triangle => vk.PrimitiveTopology.triangle_list,
                },
                .primitive_restart_enable = 0,
            },
            .p_viewport_state = &vk.PipelineViewportStateCreateInfo{
                .viewport_count = 1,
                .scissor_count = 1,
            },
            .p_rasterization_state = &.{
                .depth_clamp_enable = 0,
                .rasterizer_discard_enable = 0,
                .polygon_mode = .fill,
                .front_face = .clockwise,
                .depth_bias_enable = 0,
                .depth_bias_constant_factor = 0,
                .depth_bias_clamp = 0,
                .depth_bias_slope_factor = 0,
                .line_width = 1,
            },
            .p_color_blend_state = &.{
                .logic_op_enable = 0,
                .logic_op = .copy,
                .blend_constants = .{ 0, 0, 0, 0 },
                .attachment_count = 1,
                .p_attachments = &[_]vk.PipelineColorBlendAttachmentState{blend_info},
            },
            .p_multisample_state = &.{
                .sample_shading_enable = 0,
                .rasterization_samples = vk.SampleCountFlags{ .@"1_bit" = true },
                .min_sample_shading = 1,
                .p_sample_mask = null,
                .alpha_to_coverage_enable = 0,
                .alpha_to_one_enable = 0,
            },
            .p_depth_stencil_state = null,
            .p_dynamic_state = &vk.PipelineDynamicStateCreateInfo{
                .dynamic_state_count = 2,
                .p_dynamic_states = &[_]vk.DynamicState{
                    .viewport,
                    .scissor,
                },
            },
            .layout = pipeline_layout,
            .render_pass = this.vk_render_pass,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        },
    }, null, &pipelines) catch unreachable;

    const pipeline = try this.allocator.create(Pipeline);
    errdefer this.allocator.destroy(pipeline);

    pipeline.* = .{
        .vk_pipeline = pipelines[0],
        .vk_pipeline_layout = pipeline_layout,
        .vk_descriptor_set_layout = vk_descriptor_set_layout,
        .uniforms = uniforms.unmanaged,
    };
    uniforms.unmanaged = .{};

    return @ptrCast(pipeline);
}

fn _destroyPipeline(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline) void {
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

    this.vk_device.destroyPipeline(pipeline.vk_pipeline, null);
    this.vk_device.destroyPipelineLayout(pipeline.vk_pipeline_layout, null);
    this.vk_device.destroyDescriptorSetLayout(pipeline.vk_descriptor_set_layout, null);
    pipeline.uniforms.deinit(this.allocator);

    this.allocator.destroy(pipeline);
}

const Buffer = struct {
    vk_buffer: vk.Buffer,
    vk_memory: vk.DeviceMemory,
};

fn _createBuffer(this: *@This(), options: seizer.Graphics.Buffer.CreateOptions) seizer.Graphics.Buffer.CreateError!*seizer.Graphics.Buffer {
    const vk_buffer = this.vk_device.createBuffer(&.{
        .size = options.size,
        .usage = .{ .vertex_buffer_bit = true },
        .sharing_mode = .exclusive,
    }, null) catch unreachable;

    const mem_requirements = this.vk_device.getBufferMemoryRequirements(vk_buffer);
    const mem_type_index = findMemoryTypeIndex(this.vk_memory_properties, mem_requirements) orelse unreachable;

    const vk_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
        .allocation_size = mem_requirements.size,
        .memory_type_index = mem_type_index,
    }, null) catch unreachable;

    this.vk_device.bindBufferMemory(vk_buffer, vk_memory, 0) catch unreachable;

    const buffer = try this.allocator.create(Buffer);
    errdefer this.allocator.destroy(buffer);

    buffer.* = .{
        .vk_buffer = vk_buffer,
        .vk_memory = vk_memory,
    };

    return @ptrCast(buffer);
}

fn _destroyBuffer(this: *@This(), buffer_opaque: *seizer.Graphics.Buffer) void {
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    this.vk_device.destroyBuffer(buffer.vk_buffer, null);
    this.vk_device.freeMemory(buffer.vk_memory, null);

    this.allocator.destroy(buffer);
}

fn _releaseRenderBuffer(this: *@This(), render_buffer_opaque: seizer.Graphics.RenderBuffer) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque.pointer));
    this.render_buffers.put(this.allocator, render_buffer, {}) catch unreachable;
}

const CommandBuffer = struct {
    allocator: std.mem.Allocator,
    vk_device: VulkanDevice,

    vk_command_buffer: vk.CommandBuffer,
    vk_descriptor_pool: vk.DescriptorPool,
    vk_graphics_queue: vk.Queue,
    render_buffer: *RenderBuffer,

    arena: std.heap.ArenaAllocator,
    descriptor_set_write_list: std.AutoArrayHashMapUnmanaged(u32, vk.WriteDescriptorSet) = .{},
    descriptor_sets: std.ArrayListUnmanaged(vk.DescriptorSet) = .{},

    pub fn create(allocator: std.mem.Allocator, vk_device: VulkanDevice, vk_command_buffer: vk.CommandBuffer, vk_descriptor_pool: vk.DescriptorPool, vk_graphics_queue: vk.Queue, render_buffer: *RenderBuffer) !*@This() {
        const this = try allocator.create(@This());
        errdefer allocator.destroy(this);

        this.* = .{
            .allocator = allocator,
            .vk_device = vk_device,
            .vk_command_buffer = vk_command_buffer,
            .vk_descriptor_pool = vk_descriptor_pool,
            .vk_graphics_queue = vk_graphics_queue,
            .render_buffer = render_buffer,
            .arena = std.heap.ArenaAllocator.init(allocator),
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
        .bindPipeline = CommandBuffer._bindPipeline,
        .drawPrimitives = CommandBuffer._drawPrimitives,
        .uploadToBuffer = CommandBuffer._uploadToBuffer,
        .bindVertexBuffer = CommandBuffer._bindVertexBuffer,
        .uploadUniformMatrix4F32 = CommandBuffer._uploadUniformMatrix4F32,
        .uploadUniformTexture = CommandBuffer._uploadUniformTexture,
        .end = CommandBuffer._end,
    });

    fn _bindPipeline(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline) void {
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

        var vk_descriptor_sets: [1]vk.DescriptorSet = undefined;
        this.vk_device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
            .descriptor_pool = this.vk_descriptor_pool,
            .descriptor_set_count = 1,
            .p_set_layouts = &.{pipeline.vk_descriptor_set_layout},
        }, &vk_descriptor_sets) catch unreachable;

        for (this.descriptor_set_write_list.values()) |*write_info| {
            write_info.dst_set = vk_descriptor_sets[0];
        }
        this.vk_device.updateDescriptorSets(@intCast(this.descriptor_set_write_list.count()), this.descriptor_set_write_list.values().ptr, 0, null);

        this.descriptor_sets.appendSlice(this.allocator, vk_descriptor_sets[0..]) catch unreachable;

        this.vk_device.cmdBindDescriptorSets(this.vk_command_buffer, .graphics, pipeline.vk_pipeline_layout, 0, 1, &vk_descriptor_sets, 0, null);
        this.vk_device.cmdBindPipeline(this.vk_command_buffer, .graphics, pipeline.vk_pipeline);
    }

    fn _drawPrimitives(this: *@This(), vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
        this.vk_device.cmdDraw(this.vk_command_buffer, vertex_count, instance_count, first_vertex, first_instance);
    }

    fn _uploadToBuffer(this: *@This(), buffer_opaque: *seizer.Graphics.Buffer, data: []const u8) void {
        const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

        // this.vk_device.cmdUpdateBuffer(this.vk_command_buffer, buffer.vk_buffer, 0, @intCast(data.len), @ptrCast(data.ptr));
        const mem_ptr: [*]u8 = @ptrCast(@alignCast(this.vk_device.mapMemory(buffer.vk_memory, 0, data.len, .{}) catch unreachable));
        const mem = mem_ptr[0..data.len];
        @memcpy(mem, data);
        this.vk_device.unmapMemory(buffer.vk_memory);
    }

    fn _bindVertexBuffer(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, vertex_buffer_opaque: *seizer.Graphics.Buffer) void {
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
        const vertex_buffer: *Buffer = @ptrCast(@alignCast(vertex_buffer_opaque));

        _ = pipeline;
        this.vk_device.cmdBindVertexBuffers(this.vk_command_buffer, 0, 1, &[1]vk.Buffer{vertex_buffer.vk_buffer}, &[1]vk.DeviceSize{0});
    }

    fn _uploadUniformMatrix4F32(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, binding: u32, matrix: [4][4]f32) void {
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

        const uniform = pipeline.uniforms.get(binding) orelse unreachable;
        const mem_ptr: *[4][4]f32 = @ptrCast(@alignCast(this.vk_device.mapMemory(uniform.memory, 0, @sizeOf([4][4]f32), .{}) catch unreachable));
        @memcpy(mem_ptr, &matrix);
        this.vk_device.unmapMemory(uniform.memory);

        const gop = this.descriptor_set_write_list.getOrPut(this.allocator, binding) catch unreachable;
        gop.value_ptr.* = vk.WriteDescriptorSet{
            .dst_set = undefined,
            .dst_binding = binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .uniform_buffer,
            .p_image_info = undefined,
            .p_buffer_info = (this.arena.allocator().dupe(vk.DescriptorBufferInfo, &[1]vk.DescriptorBufferInfo{.{
                .buffer = uniform.buffer,
                .offset = 0,
                .range = vk.WHOLE_SIZE,
            }}) catch unreachable).ptr,
            .p_texel_buffer_view = undefined,
        };
    }

    fn _uploadUniformTexture(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline, binding: u32, texture_opaque_opt: ?*seizer.Graphics.Texture) void {
        const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
        const texture: *Texture = @ptrCast(@alignCast(texture_opaque_opt orelse return));

        _ = pipeline;

        const gop = this.descriptor_set_write_list.getOrPut(this.allocator, binding) catch unreachable;
        gop.value_ptr.* = vk.WriteDescriptorSet{
            .dst_set = undefined,
            .dst_binding = binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .combined_image_sampler,
            .p_image_info = (this.arena.allocator().dupe(vk.DescriptorImageInfo, &[_]vk.DescriptorImageInfo{
                .{
                    .sampler = texture.vk_sampler,
                    .image_view = texture.vk_image_view,
                    .image_layout = .shader_read_only_optimal,
                },
            }) catch unreachable).ptr,
            .p_buffer_info = undefined,
            .p_texel_buffer_view = undefined,
        };
    }

    fn _end(this: *@This()) seizer.Graphics.CommandBuffer.EndError!seizer.Graphics.RenderBuffer {
        this.vk_device.cmdEndRenderPass(this.vk_command_buffer);
        this.vk_device.endCommandBuffer(this.vk_command_buffer) catch unreachable;

        this.vk_device.queueSubmit(this.vk_graphics_queue, 1, &[_]vk.SubmitInfo{
            .{
                // .wait_semaphore_count = 1,
                // .p_wait_semaphores = &[_]vk.Semaphore{image_available_semaphore},
                .command_buffer_count = 1,
                .p_command_buffers = &.{this.vk_command_buffer},
                // .signal_semaphore_count = 1,
                // .p_signal_semaphores = &[_]vk.Semaphore{this.render_buffer.finished_semaphore},
            },
        }, this.render_buffer.finished_fence) catch unreachable;

        if (this.descriptor_sets.items.len > 0) {
            this.render_buffer.vk_descriptor_sets = this.descriptor_sets.toOwnedSlice(this.allocator) catch unreachable;
        }
        this.descriptor_sets.deinit(this.allocator);
        this.descriptor_set_write_list.deinit(this.allocator);
        this.arena.deinit();

        const render_buffer = this.render_buffer.renderBuffer();
        this.allocator.destroy(this);
        return render_buffer;
    }
};

const RenderBuffer = struct {
    backend: *VulkanImpl,

    size: [2]u32,
    image_format: vk.Format,
    vk_image: vk.Image,
    vk_device_memory: vk.DeviceMemory,
    vk_imageview: vk.ImageView,
    vk_framebuffer: vk.Framebuffer,

    vk_descriptor_sets: ?[]const vk.DescriptorSet = null,
    // drm_modifier_properties: vk.DrmFormatModifierPropertiesEXT,
    finished_fence: vk.Fence,

    pub fn create(
        backend: *VulkanImpl,
        size: [2]u32,
        image_format: vk.Format,
        vk_memory_properties: vk.PhysicalDeviceMemoryProperties,
        vk_render_pass: vk.RenderPass,
        // drm_format_modifier_properties_list: []const vk.DrmFormatModifierPropertiesEXT,
        // drm_format_modifiers: []const u64,
    ) !*@This() {
        const this = try backend.allocator.create(@This());
        errdefer backend.allocator.destroy(this);

        const vk_framebuffer_image = try backend.vk_device.createImage(&vk.ImageCreateInfo{
            .p_next = &vk.ExternalMemoryImageCreateInfo{
                .handle_types = .{ .dma_buf_bit_ext = true },
                // .p_next = &vk.ImageDrmFormatModifierListCreateInfoEXT{
                //     .drm_format_modifier_count = @intCast(drm_format_modifiers.len),
                //     .p_drm_format_modifiers = drm_format_modifiers.ptr,
                // },
                // .p_next = &vk.ImageDrmFormatModifierExplicitCreateInfoEXT{
                //     .drm_format_modifier = 0,
                //     .drm_format_modifier_plane_count = switch (image_format) {
                //         .r8g8b8a8_unorm => 1,
                //         else => unreachable,
                //     },
                //     .p_plane_layouts = &[1]vk.SubresourceLayout{.{
                //         .offset = 0,
                //         .size = @intCast(size[0] * size[1] * 4),
                //         .row_pitch = @intCast(size[0] * 4),
                //         .array_pitch = 0,
                //         .depth_pitch = 0,
                //     }},
                // },
            },
            .image_type = .@"2d",
            .format = image_format,
            .extent = .{ .width = size[0], .height = size[1], .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .linear,
            .usage = .{ .color_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null);
        errdefer backend.vk_device.destroyImage(vk_framebuffer_image, null);

        // var image_drm_format_modifier_properties = vk.ImageDrmFormatModifierPropertiesEXT{ .drm_format_modifier = undefined };
        // try vk_device.getImageDrmFormatModifierPropertiesEXT(vk_framebuffer_image, &image_drm_format_modifier_properties);
        // var drm_modifier_properties = drm_format_modifier_properties_list[0];
        // for (drm_format_modifier_properties_list) |properties| {
        //     if (properties.drm_format_modifier == image_drm_format_modifier_properties.drm_format_modifier) {
        //         drm_modifier_properties = properties;
        //         break;
        //     }
        // }
        const memory_requirements = backend.vk_device.getImageMemoryRequirements(vk_framebuffer_image);

        var memory_type_index: u32 = 0;
        for (vk_memory_properties.memory_types[0..vk_memory_properties.memory_type_count], 0..) |memory_type, i| {
            if (memory_requirements.memory_type_bits == memory_requirements.memory_type_bits & @as(u32, @bitCast(memory_type.property_flags))) {
                memory_type_index = @intCast(i);
            }
        }

        const vk_device_memory = try backend.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
            .p_next = &vk.ExportMemoryAllocateInfo{
                .handle_types = .{ .dma_buf_bit_ext = true },
            },
            .allocation_size = memory_requirements.size,
            .memory_type_index = memory_type_index,
        }, null);
        errdefer backend.vk_device.freeMemory(vk_device_memory, null);

        try backend.vk_device.bindImageMemory(vk_framebuffer_image, vk_device_memory, 0);

        const vk_image_view = try backend.vk_device.createImageView(&vk.ImageViewCreateInfo{
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
        errdefer backend.vk_device.destroyImageView(vk_image_view, null);

        const vk_framebuffer = try backend.vk_device.createFramebuffer(&vk.FramebufferCreateInfo{
            .render_pass = vk_render_pass,
            .width = size[0],
            .height = size[1],
            .layers = 1,
            .attachment_count = 1,
            .p_attachments = &[_]vk.ImageView{vk_image_view},
        }, null);
        errdefer backend.vk_device.destroyFramebuffer(vk_framebuffer, null);

        const finished_fence = try backend.vk_device.createFence(&.{}, null);

        this.* = .{
            .backend = backend,

            .size = size,
            .image_format = image_format,
            .vk_image = vk_framebuffer_image,
            .vk_device_memory = vk_device_memory,
            .vk_imageview = vk_image_view,
            .vk_framebuffer = vk_framebuffer,
            // .drm_modifier_properties = drm_modifier_properties,

            .finished_fence = finished_fence,
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
        this.backend._releaseRenderBuffer(this.renderBuffer());
        // this.reference_count -= 1;
        // if (this.reference_count == 0) {
        //     this.destroy();
        // }
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
            .plane_count = 1,
            .modifiers = 0,
        };
    }

    fn _getDmaBufPlanes(this: *@This(), buf: []seizer.Graphics.RenderBuffer.DmaBufPlane) []seizer.Graphics.RenderBuffer.DmaBufPlane {
        const memory_fd = this.backend.vk_device.getMemoryFdKHR(&vk.MemoryGetFdInfoKHR{
            .memory = this.vk_device_memory,
            .handle_type = .{ .dma_buf_bit_ext = true },
        }) catch unreachable; // TODO

        const slice = buf[0..1];
        for (slice, 0..) |*dma_buf_plane, i| {
            const plane_layout = this.backend.vk_device.getImageSubresourceLayout(this.vk_image, &vk.ImageSubresource{
                .aspect_mask = .{
                    .color_bit = true,
                    // .memory_plane_0_bit_ext = i == 0,
                    // .memory_plane_1_bit_ext = i == 1,
                    // .memory_plane_2_bit_ext = i == 2,
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
        if (this.vk_descriptor_sets) |descriptors| {
            this.backend.vk_device.freeDescriptorSets(this.backend.vk_descriptor_pool, @intCast(descriptors.len), descriptors.ptr) catch unreachable;
            this.backend.allocator.free(descriptors);
            this.vk_descriptor_sets = null;
        }

        this.backend.vk_device.destroyFence(this.finished_fence, null);
        this.backend.vk_device.destroyFramebuffer(this.vk_framebuffer, null);
        this.backend.vk_device.destroyImageView(this.vk_imageview, null);
        this.backend.vk_device.freeMemory(this.vk_device_memory, null);
        this.backend.vk_device.destroyImage(this.vk_image, null);

        this.backend.allocator.destroy(this);
    }

    pub fn acquire(this: *@This()) void {
        this.reference_count += 1;
    }
};

fn findMemoryTypeIndex(vk_memory_properties: vk.PhysicalDeviceMemoryProperties, memory_requirements: vk.MemoryRequirements) ?u32 {
    for (vk_memory_properties.memory_types[0..vk_memory_properties.memory_type_count], 0..) |memory_type, i| {
        if (memory_requirements.memory_type_bits == memory_requirements.memory_type_bits & @as(u32, @bitCast(memory_type.property_flags))) {
            return @intCast(i);
        }
    }
    return null;
}

const vk = @import("vulkan");
const vulkan_apis: []const vk.ApiInfo = &.{
    vk.features.version_1_0,
    vk.features.version_1_1,
    vk.features.version_1_2,
    vk.extensions.khr_external_memory_fd,
    vk.extensions.ext_external_memory_dma_buf,
    // vk.extensions.ext_image_drm_format_modifier,
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

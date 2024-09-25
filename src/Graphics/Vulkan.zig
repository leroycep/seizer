allocator: std.mem.Allocator,

libvulkan: std.DynLib,

vkb: *VulkanBaseDispatch,
vk_instance: VulkanInstance,
vk_device: VulkanDevice,

vk_command_pool: vk.CommandPool,
vk_graphics_queue: vk.Queue,

vk_device_properties: vk.PhysicalDeviceProperties,
image_format: vk.Format,
vk_memory_properties: vk.PhysicalDeviceMemoryProperties,
// drm_format_modifier_properties_list: std.ArrayListUnmanaged(vk.DrmFormatModifierPropertiesEXT),
// drm_format_modifier_list: std.ArrayListUnmanaged(u64),

renderdoc: @import("renderdoc"),

const VulkanImpl = @This();

const DEFAULT_IMAGE_FORMAT = .b8g8r8a8_unorm;

pub const GRAPHICS_INTERFACE = seizer.meta.interfaceFromConcreteTypeFns(seizer.Graphics.Interface, @This(), .{
    .driver = .vulkan,
    .create = _create,
    .destroy = destroy,
    .createShader = _createShader,
    .destroyShader = _destroyShader,
    .createTexture = _createTexture,
    .destroyTexture = _destroyTexture,
    .createPipeline = _createPipeline,
    .destroyPipeline = _destroyPipeline,
    .createBuffer = _createBuffer,
    .destroyBuffer = _destroyBuffer,

    .createSwapchain = _createSwapchain,
    .destroySwapchain = _destroySwapchain,
    .swapchainGetRenderBuffer = _swapchainGetRenderBuffer,
    .swapchainPresentRenderBuffer = _swapchainPresentRenderBuffer,
    .swapchainReleaseRenderBuffer = _swapchainReleaseRenderBuffer,

    .beginRendering = _beginRendering,
    .endRendering = _endRendering,
    .bindPipeline = _bindPipeline,
    .drawPrimitives = _drawPrimitives,
    .uploadToBuffer = _uploadToBuffer,
    .bindVertexBuffer = _bindVertexBuffer,
    .uploadDescriptors = _uploadDescriptors,
    .bindDescriptorSet = _bindDescriptorSet,
    .pushConstants = _pushConstants,
    .setViewport = _setViewport,
    .setScissor = _setScissor,
});

pub fn _create(allocator: std.mem.Allocator, options: seizer.Graphics.CreateOptions) seizer.Graphics.CreateError!seizer.Graphics {
    const library_prefixes = options.library_search_prefixes orelse std.debug.panic("Graphics.create should have populated `library_search_prefixes` if the user did not", .{});

    const renderdoc = @import("renderdoc").loadUsingPrefixes(library_prefixes);

    // allocate a fixed memory location for fn_tables
    var libvulkan = @"dynamic-library-utils".loadFromPrefixes(library_prefixes, "libvulkan.so.1") catch |err| switch (err) {
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
            .api_version = vk.API_VERSION_1_3,
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

    const vk_device_properties = vk_instance.getPhysicalDeviceProperties(device_result.physical_device);

    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);

    this.* = .{
        .allocator = allocator,
        .libvulkan = libvulkan,
        .vkb = vkb,

        .vk_instance = vk_instance,
        .vk_device = vk_device,
        .vk_command_pool = vk_command_pool,
        .image_format = DEFAULT_IMAGE_FORMAT,

        .vk_graphics_queue = this.vk_device.getDeviceQueue(device_result.queue_family_index, 0),

        .vk_device_properties = vk_device_properties,
        .vk_memory_properties = this.vk_instance.getPhysicalDeviceMemoryProperties(device_result.physical_device),

        .renderdoc = renderdoc,
    };

    return .{
        .pointer = this,
        .interface = &GRAPHICS_INTERFACE,
    };
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

    var enabled_extensions = std.ArrayList([*:0]const u8).init(allocator);
    defer enabled_extensions.deinit();

    var queue_families = std.ArrayList(vk.QueueFamilyProperties).init(allocator);
    defer queue_families.deinit();

    var current_device_score: u32 = 0;
    var physical_device: ?vk.PhysicalDevice = null;
    var device_queue_create_info = vk.DeviceQueueCreateInfo{
        .queue_family_index = 0,
        .queue_count = 1,
        .p_queue_priorities = &.{1},
    };
    for (physical_devices) |device| {
        var device_score: u32 = 1;

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

        if (has_vk_ext_external_memory_dma_buf) device_score += 5;

        if (has_vk_khr_external_memory_fd and
            graphics_queue != null and
            device_score > current_device_score)
        {
            physical_device = device;
            device_queue_create_info.queue_family_index = @intCast(graphics_queue.?);
            current_device_score = device_score;

            enabled_extensions.shrinkRetainingCapacity(0);
            try enabled_extensions.append(vk.extensions.khr_external_memory_fd.name);
            if (has_vk_ext_external_memory_dma_buf) try enabled_extensions.append(vk.extensions.ext_external_memory_dma_buf.name);
        }
    }

    if (physical_device) |device| {
        const device_properties = vk_instance.getPhysicalDeviceProperties(device);
        const end_of_name = std.mem.indexOfScalar(u8, &device_properties.device_name, 0) orelse device_properties.device_name.len;
        const name = device_properties.device_name[0..end_of_name];
        std.log.debug("selected gpu = {s}", .{name});
    }

    var descriptor_indexing_features = vk.PhysicalDeviceDescriptorIndexingFeatures{
        .descriptor_binding_partially_bound = vk.TRUE,
        .runtime_descriptor_array = vk.TRUE,
        .shader_sampled_image_array_non_uniform_indexing = vk.TRUE,
    };
    var dynamic_rendering_features = vk.PhysicalDeviceDynamicRenderingFeatures{
        .p_next = &descriptor_indexing_features,
        .dynamic_rendering = vk.TRUE,
    };

    var device_create_info = vk.DeviceCreateInfo{
        .p_next = &dynamic_rendering_features,
        .queue_create_info_count = 1,
        .p_queue_create_infos = &.{device_queue_create_info},
        .enabled_extension_count = @intCast(enabled_extensions.items.len),
        .pp_enabled_extension_names = enabled_extensions.items.ptr,
    };

    const vk_device_ptr = try vk_instance.createDevice(
        physical_device orelse return error.InitializationFailed,
        &device_create_info,
        null,
    );

    return .{
        .ptr = vk_device_ptr,
        .queue_family_index = device_queue_create_info.queue_family_index,
        .physical_device = physical_device.?,
    };
}

fn destroy(this: *@This()) void {
    this.vk_device.destroyCommandPool(this.vk_command_pool, null);
    this.vk_device.destroyDevice(null);
    this.vk_instance.destroyInstance(null);

    this.allocator.destroy(this.vk_device.wrapper);
    this.allocator.destroy(this.vk_instance.wrapper);
    this.allocator.destroy(this.vkb);
    this.allocator.destroy(this);
}

const Texture = struct {
    vk_image: vk.Image,
    vk_device_memory: vk.DeviceMemory,
    vk_image_view: vk.ImageView,
    vk_sampler: vk.Sampler,
};

fn _createTexture(this: *@This(), image: zigimg.ImageUnmanaged, options: seizer.Graphics.Texture.CreateOptions) seizer.Graphics.Texture.CreateError!*seizer.Graphics.Texture {
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
            .grayscale16 => .r16_unorm,
            .float32 => .r32g32b32a32_sfloat,
            else => |f| {
                std.log.scoped(.seizer).warn("Unsupported image format {}", .{f});
                return error.UnsupportedFormat;
            },
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
            .grayscale16 => .r16_unorm,
            .float32 => .r32g32b32a32_sfloat,
            else => |f| {
                std.log.scoped(.seizer).warn("Unsupported image format {}", .{f});
                return error.UnsupportedFormat;
            },
        },
        .components = switch (image.pixelFormat()) {
            .rgba32 => .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .grayscale16 => .{ .r = .identity, .g = .r, .b = .r, .a = .identity },
            .float32 => .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            else => |f| {
                std.log.scoped(.seizer).warn("Unsupported image format {}", .{f});
                return error.UnsupportedFormat;
            },
        },
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

    const uniform_binding_list = try this.allocator.alloc(vk.DescriptorSetLayoutBinding, options.uniforms.len);
    defer this.allocator.free(uniform_binding_list);
    for (uniform_binding_list, options.uniforms) |*uniform_binding, uniform_description| {
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

    const descriptor_binding_flags_list = this.allocator.alloc(vk.DescriptorBindingFlags, uniform_binding_list.len) catch unreachable;
    defer this.allocator.free(descriptor_binding_flags_list);
    @memset(descriptor_binding_flags_list, vk.DescriptorBindingFlags{ .partially_bound_bit = true });

    const vk_descriptor_binding_flags_create_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
        .binding_count = @intCast(descriptor_binding_flags_list.len),
        .p_binding_flags = descriptor_binding_flags_list.ptr,
    };

    const vk_descriptor_set_layout = this.vk_device.createDescriptorSetLayout(&vk.DescriptorSetLayoutCreateInfo{
        .p_next = &vk_descriptor_binding_flags_create_info,
        .flags = .{ .update_after_bind_pool_bit = true },
        .binding_count = @intCast(uniform_binding_list.len),
        .p_bindings = uniform_binding_list.ptr,
    }, null) catch unreachable;
    errdefer this.vk_device.destroyDescriptorSetLayout(vk_descriptor_set_layout, null);

    var push_constant_ranges_buf: [1]vk.PushConstantRange = undefined;
    const push_constants_ranges_ptr: ?[*]vk.PushConstantRange = if (options.push_constants) |push_constants| copy_data: {
        push_constant_ranges_buf[0] = vk.PushConstantRange{
            .stage_flags = .{ .vertex_bit = push_constants.stages.vertex, .fragment_bit = push_constants.stages.fragment },
            .offset = 0,
            .size = push_constants.size,
        };
        break :copy_data push_constant_ranges_buf[0..1];
    } else null;

    const pipeline_layout = this.vk_device.createPipelineLayout(&vk.PipelineLayoutCreateInfo{
        .set_layout_count = 1,
        .p_set_layouts = &[_]vk.DescriptorSetLayout{vk_descriptor_set_layout},
        .push_constant_range_count = if (push_constants_ranges_ptr != null) 1 else 0,
        .p_push_constant_ranges = push_constants_ranges_ptr,
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

    var pipeline_create_info = vk.PipelineRenderingCreateInfo{
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachment_formats = &[_]vk.Format{this.image_format},
        .depth_attachment_format = .undefined,
        .stencil_attachment_format = .undefined,
    };

    const base_pipeline: ?*Pipeline = @ptrCast(@alignCast(options.base_pipeline));

    var pipelines: [1]vk.Pipeline = undefined;
    _ = this.vk_device.createGraphicsPipelines(.null_handle, 1, &[_]vk.GraphicsPipelineCreateInfo{
        .{
            .p_next = &pipeline_create_info,
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
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_handle = if (base_pipeline) |base| base.vk_pipeline else .null_handle,
            .base_pipeline_index = -1,
        },
    }, null, &pipelines) catch unreachable;

    const pipeline = try this.allocator.create(Pipeline);
    errdefer this.allocator.destroy(pipeline);

    pipeline.* = .{
        .vk_pipeline = pipelines[0],
        .vk_pipeline_layout = pipeline_layout,
        .vk_descriptor_set_layout = vk_descriptor_set_layout,
    };

    return @ptrCast(pipeline);
}

fn _destroyPipeline(this: *@This(), pipeline_opaque: *seizer.Graphics.Pipeline) void {
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

    this.vk_device.destroyPipeline(pipeline.vk_pipeline, null);
    this.vk_device.destroyPipelineLayout(pipeline.vk_pipeline_layout, null);
    this.vk_device.destroyDescriptorSetLayout(pipeline.vk_descriptor_set_layout, null);

    this.allocator.destroy(pipeline);
}

const Buffer = struct {
    vk_buffer: vk.Buffer,
    vk_memory: vk.DeviceMemory,
};

fn _createBuffer(this: *@This(), options: seizer.Graphics.Buffer.CreateOptions) seizer.Graphics.Buffer.CreateError!*seizer.Graphics.Buffer {
    const vk_buffer = this.vk_device.createBuffer(&.{
        .size = options.size,
        .usage = .{ .vertex_buffer_bit = true, .transfer_dst_bit = true },
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

const Swapchain = struct {
    vk_device: VulkanDevice,
    display: seizer.Display,
    size: [2]u32,
    image_format: vk.Format,
    vk_device_memory: vk.DeviceMemory,
    display_buffer_type: seizer.Display.Buffer.Type,

    elements: std.MultiArrayList(Element),
    render_buffers: std.heap.MemoryPool(RenderBuffer),

    const Element = struct {
        free: bool,
        vk_image: vk.Image,
        memory_offset: u64,
        vk_image_view: vk.ImageView,
        vk_fence_finished: vk.Fence,

        vk_command_buffer: vk.CommandBuffer,
        vk_descriptor_pool: vk.DescriptorPool,

        display_buffer: *seizer.Display.Buffer,
        vk_buffer_list: std.ArrayListUnmanaged(vk.Buffer),
        vk_device_memory_list: std.ArrayListUnmanaged(vk.DeviceMemory),
    };

    fn onDisplayBufferReleased(userdata: ?*anyopaque, display_buffer: *seizer.Display.Buffer) void {
        const swapchain: *Swapchain = @ptrCast(@alignCast(userdata));

        const element_index = std.mem.indexOfScalar(*seizer.Display.Buffer, swapchain.elements.items(.display_buffer), display_buffer) orelse {
            std.log.scoped(.seizer).warn("DisplayBuffer unknown to Vulkan swapchain: {*}", .{display_buffer});
            return;
        };

        swapchain.elements.items(.free)[element_index] = true;
    }
};

fn _createSwapchain(this: *@This(), display: seizer.Display, window: *seizer.Display.Window, options: seizer.Graphics.Swapchain.CreateOptions) seizer.Graphics.Swapchain.CreateError!*seizer.Graphics.Swapchain {
    _ = window;

    const display_buffer_type = if (display.isCreateBufferFromDMA_BUF_Supported())
        seizer.Display.Buffer.Type.dma_buf
    else
        seizer.Display.Buffer.Type.opaque_fd;

    const handle_type_flags: vk.ExternalMemoryHandleTypeFlags = switch (display_buffer_type) {
        .dma_buf => vk.ExternalMemoryHandleTypeFlags{ .dma_buf_bit_ext = true },
        .opaque_fd => vk.ExternalMemoryHandleTypeFlags{ .opaque_fd_bit = true },
    };

    var elements = std.MultiArrayList(Swapchain.Element){};
    errdefer {
        var slice = elements.slice();
        for (slice.items(.vk_image), slice.items(.vk_image_view)) |vk_image, vk_image_view| {
            this.vk_device.destroyImageView(vk_image_view, null);
            this.vk_device.destroyImage(vk_image, null);
        }
        elements.deinit(this.allocator);
    }

    try elements.resize(this.allocator, options.num_frames);
    const elements_slice = elements.slice();

    var total_memory_requirements = vk.MemoryRequirements{
        .size = 0,
        .alignment = 0,
        .memory_type_bits = 0,
    };
    for (elements_slice.items(.vk_image)) |*vk_image| {
        vk_image.* = this.vk_device.createImage(&vk.ImageCreateInfo{
            .p_next = &vk.ExternalMemoryImageCreateInfo{
                .handle_types = handle_type_flags,
            },
            .image_type = .@"2d",
            .format = this.image_format,
            .extent = .{ .width = options.size[0], .height = options.size[1], .depth = 1 },
            .mip_levels = 1,
            .array_layers = 1,
            .samples = .{ .@"1_bit" = true },
            .tiling = .linear,
            .usage = .{ .color_attachment_bit = true },
            .sharing_mode = .exclusive,
            .initial_layout = .undefined,
        }, null) catch unreachable;
        errdefer this.vk_device.destroyImage(vk_image, null);

        const image_memory_requirements = this.vk_device.getImageMemoryRequirements(vk_image.*);
        total_memory_requirements = .{
            .size = total_memory_requirements.size + image_memory_requirements.size,
            .alignment = @max(total_memory_requirements.alignment, image_memory_requirements.alignment),
            .memory_type_bits = total_memory_requirements.memory_type_bits | image_memory_requirements.memory_type_bits,
        };
    }

    // allocate device memory for images
    var memory_type_index: u32 = 0;
    for (this.vk_memory_properties.memory_types[0..this.vk_memory_properties.memory_type_count], 0..) |memory_type, i| {
        if (total_memory_requirements.memory_type_bits == total_memory_requirements.memory_type_bits & @as(u32, @bitCast(memory_type.property_flags))) {
            memory_type_index = @intCast(i);
        }
    }

    const vk_device_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
        .p_next = &vk.ExportMemoryAllocateInfo{
            .handle_types = handle_type_flags,
        },
        .allocation_size = total_memory_requirements.size,
        .memory_type_index = memory_type_index,
    }, null) catch unreachable;
    errdefer this.vk_device.freeMemory(vk_device_memory, null);

    var offset: u64 = 0;
    for (elements.items(.vk_image), elements.items(.memory_offset)) |vk_image, *memory_offset| {
        const image_memory_requirements = this.vk_device.getImageMemoryRequirements(vk_image);
        offset = std.mem.alignForward(u64, offset, image_memory_requirements.alignment);

        this.vk_device.bindImageMemory(vk_image, vk_device_memory, offset) catch unreachable;
        memory_offset.* = offset;

        offset += image_memory_requirements.size;
    }

    // create image views
    for (elements_slice.items(.vk_image_view), elements_slice.items(.vk_image)) |*vk_image_view, vk_image| {
        vk_image_view.* = this.vk_device.createImageView(&vk.ImageViewCreateInfo{
            .image = vk_image,
            .view_type = .@"2d",
            .format = this.image_format,
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
        }, null) catch unreachable;
        errdefer this.vk_device.destroyImageView(vk_image_view, null);
    }

    // allocate command buffers
    const vk_command_buffers = elements.items(.vk_command_buffer);
    this.vk_device.allocateCommandBuffers(&.{
        .command_pool = this.vk_command_pool,
        .command_buffer_count = @intCast(vk_command_buffers.len),
        .level = .primary,
    }, vk_command_buffers.ptr) catch unreachable;
    errdefer this.vk_device.freeCommandBuffers(this.vk_command_pool, @intCast(vk_command_buffers.len), vk_command_buffers.ptr);

    for (elements_slice.items(.vk_descriptor_pool)) |*vk_descriptor_pool| {
        vk_descriptor_pool.* = this.vk_device.createDescriptorPool(&vk.DescriptorPoolCreateInfo{
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = 10,
            .pool_size_count = 2,
            .p_pool_sizes = &[2]vk.DescriptorPoolSize{
                .{ .type = .uniform_buffer, .descriptor_count = 1024 },
                .{ .type = .combined_image_sampler, .descriptor_count = 1024 },
            },
        }, null) catch unreachable;
    }

    for (elements_slice.items(.vk_fence_finished)) |*vk_fence_finished| {
        vk_fence_finished.* = this.vk_device.createFence(&.{ .flags = .{ .signaled_bit = true } }, null) catch unreachable;
    }

    @memset(elements_slice.items(.free), true);

    const swapchain = try this.allocator.create(Swapchain);
    errdefer this.allocator.destroy(swapchain);
    swapchain.* = .{
        .vk_device = this.vk_device,
        .display = display,
        .size = options.size,
        .image_format = this.image_format,
        .vk_device_memory = vk_device_memory,

        .elements = elements,
        .render_buffers = try std.heap.MemoryPool(RenderBuffer).initPreheated(this.allocator, options.num_frames),
        .display_buffer_type = display_buffer_type,
    };

    const memory_fd = this.vk_device.getMemoryFdKHR(&vk.MemoryGetFdInfoKHR{
        .memory = vk_device_memory,
        .handle_type = handle_type_flags,
    }) catch unreachable; // TODO
    defer std.posix.close(memory_fd);

    const fourcc_format: seizer.Display.Buffer.FourCC = switch (this.image_format) {
        .r8g8b8a8_unorm => .ABGR8888,
        .b8g8r8a8_unorm => .ARGB8888,
        else => return error.UnsupportedFormat,
    };

    // create display buffer handles from image views
    switch (display_buffer_type) {
        .dma_buf => for (elements_slice.items(.display_buffer), elements_slice.items(.vk_image), elements_slice.items(.memory_offset)) |*display_buffer, vk_image, memory_offset| {
            const dmabuf_format = seizer.Display.Buffer.DmaBufFormat{
                .fourcc = fourcc_format,
                .plane_count = 1,
                .modifiers = 0,
            };

            var dma_buf_planes: [1]seizer.Display.Buffer.DmaBufPlane = undefined;

            const plane_layout = this.vk_device.getImageSubresourceLayout(vk_image, &vk.ImageSubresource{
                .aspect_mask = .{
                    .color_bit = true,
                    // .memory_plane_0_bit_ext = i == 0,
                    // .memory_plane_1_bit_ext = i == 1,
                    // .memory_plane_2_bit_ext = i == 2,
                },
                .mip_level = 0,
                .array_layer = 0,
            });

            dma_buf_planes[0] = .{
                .fd = memory_fd,
                .index = @intCast(0),
                .offset = @intCast(memory_offset + plane_layout.offset),
                .stride = @intCast(plane_layout.row_pitch),
            };

            display_buffer.* = display.createBufferFromDMA_BUF(.{
                .size = options.size,
                .format = dmabuf_format,
                .planes = &dma_buf_planes,
                .userdata = swapchain,
                .on_release = Swapchain.onDisplayBufferReleased,
            }) catch |err| switch (err) {
                error.ConnectionLost => return error.DisplayConnectionLost,
                else => |e| return e,
            };
        },
        .opaque_fd => for (elements_slice.items(.display_buffer), elements_slice.items(.vk_image), elements_slice.items(.memory_offset)) |*display_buffer, vk_image, memory_offset| {
            const layout = this.vk_device.getImageSubresourceLayout(vk_image, &vk.ImageSubresource{
                .aspect_mask = .{
                    .color_bit = true,
                },
                .mip_level = 0,
                .array_layer = 0,
            });

            display_buffer.* = display.createBufferFromOpaqueFd(.{
                .fd = memory_fd,
                .offset = @intCast(memory_offset + layout.offset),
                .pool_size = @intCast(total_memory_requirements.size),
                .size = options.size,
                .stride = @intCast(layout.row_pitch),
                .format = fourcc_format,
                .userdata = swapchain,
                .on_release = Swapchain.onDisplayBufferReleased,
            }) catch |err| switch (err) {
                error.ConnectionLost => return error.DisplayConnectionLost,
                else => |e| return e,
            };
        },
    }

    @memset(elements_slice.items(.vk_buffer_list), .{});
    @memset(elements_slice.items(.vk_device_memory_list), .{});

    return @ptrCast(swapchain);
}

fn _destroySwapchain(this: *@This(), swapchain_opaque: *seizer.Graphics.Swapchain) void {
    const swapchain: *Swapchain = @ptrCast(@alignCast(swapchain_opaque));

    const elements_slice = swapchain.elements.slice();

    for (elements_slice.items(.display_buffer)) |display_buffer| {
        swapchain.display.destroyBuffer(display_buffer);
    }

    _ = this.vk_device.waitForFences(@intCast(elements_slice.items(.vk_fence_finished).len), elements_slice.items(.vk_fence_finished).ptr, vk.TRUE, std.math.maxInt(u64)) catch unreachable;
    for (elements_slice.items(.vk_image_view), elements_slice.items(.vk_image), elements_slice.items(.vk_fence_finished), elements_slice.items(.vk_descriptor_pool)) |vk_image_view, vk_image, vk_fence_finished, vk_descriptor_pool| {
        this.vk_device.destroyImageView(vk_image_view, null);
        this.vk_device.destroyImage(vk_image, null);
        this.vk_device.destroyFence(vk_fence_finished, null);
        this.vk_device.destroyDescriptorPool(vk_descriptor_pool, null);
    }
    for (elements_slice.items(.vk_buffer_list), elements_slice.items(.vk_device_memory_list)) |*buffer_list, *device_memory_list| {
        for (buffer_list.items) |vk_buffer| {
            swapchain.vk_device.destroyBuffer(vk_buffer, null);
        }

        for (device_memory_list.items) |vk_device_memory| {
            swapchain.vk_device.freeMemory(vk_device_memory, null);
        }

        buffer_list.deinit(this.allocator);
        device_memory_list.deinit(this.allocator);
    }

    const vk_command_buffers = elements_slice.items(.vk_command_buffer);
    this.vk_device.freeCommandBuffers(this.vk_command_pool, @intCast(vk_command_buffers.len), vk_command_buffers.ptr);

    this.vk_device.freeMemory(swapchain.vk_device_memory, null);

    swapchain.elements.deinit(this.allocator);
    swapchain.render_buffers.deinit();

    this.allocator.destroy(swapchain);
}

fn _swapchainGetRenderBuffer(this: *@This(), swapchain_opaque: *seizer.Graphics.Swapchain, options: seizer.Graphics.Swapchain.GetRenderBufferOptions) seizer.Graphics.Swapchain.GetRenderBufferError!*seizer.Graphics.RenderBuffer {
    const swapchain: *Swapchain = @ptrCast(@alignCast(swapchain_opaque));
    _ = options;
    const render_buffer = try swapchain.render_buffers.create();
    errdefer swapchain.render_buffers.destroy(render_buffer);

    const slice = swapchain.elements.slice();
    for (slice.items(.free), slice.items(.vk_fence_finished), 0..) |*is_free, is_finished_fence, i| {
        if (!is_free.*) continue;

        const is_finished_status = this.vk_device.getFenceStatus(is_finished_fence) catch |err| switch (err) {
            error.OutOfHostMemory => return error.OutOfMemory,
            error.Unknown => |e| std.debug.panic("unknown error getting fence status: {}", .{e}),
            else => |e| return e,
        };
        if (is_finished_status != .success) continue;

        const element = slice.get(i);

        for (slice.items(.vk_buffer_list)[i].items) |vk_buffer| {
            this.vk_device.destroyBuffer(vk_buffer, null);
        }
        slice.items(.vk_buffer_list)[i].shrinkRetainingCapacity(0);

        for (slice.items(.vk_device_memory_list)[i].items) |vk_device_memory_list| {
            this.vk_device.freeMemory(vk_device_memory_list, null);
        }
        slice.items(.vk_device_memory_list)[i].shrinkRetainingCapacity(0);

        this.vk_device.resetFences(1, &.{element.vk_fence_finished}) catch |err| switch (err) {
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            error.Unknown => |e| std.log.scoped(.seizer).warn("Unknown error: {}", .{e}),
        };

        this.vk_device.resetDescriptorPool(element.vk_descriptor_pool, .{}) catch |err| switch (err) {
            error.Unknown => |e| std.log.scoped(.seizer).warn("Unknown error: {}", .{e}),
        };

        this.vk_device.beginCommandBuffer(element.vk_command_buffer, &vk.CommandBufferBeginInfo{}) catch |err| switch (err) {
            error.OutOfHostMemory => return error.OutOfMemory,
            error.OutOfDeviceMemory => return error.OutOfDeviceMemory,
            error.Unknown => |e| std.log.scoped(.seizer).warn("Unknown error: {}", .{e}),
        };

        render_buffer.* = .{
            .element_index = @intCast(i),
            .size = swapchain.size,
            .vk_image_view = element.vk_image_view,
            .vk_command_buffer = element.vk_command_buffer,
            .vk_descriptor_pool = element.vk_descriptor_pool,
            .vk_fence_finished = element.vk_fence_finished,
            .display_buffer = element.display_buffer,
            .vk_buffer_list = &slice.items(.vk_buffer_list)[i],
            .vk_device_memory_list = &slice.items(.vk_device_memory_list)[i],
        };

        is_free.* = false;

        return @ptrCast(render_buffer);
    }

    return error.OutOfRenderBuffers;
}

fn _swapchainPresentRenderBuffer(this: *@This(), display: seizer.Display, window: *seizer.Display.Window, swapchain_opaque: *seizer.Graphics.Swapchain, render_buffer_opaque: *seizer.Graphics.RenderBuffer) seizer.Graphics.Swapchain.PresentRenderBufferError!void {
    const swapchain: *Swapchain = @ptrCast(@alignCast(swapchain_opaque));
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));

    this.vk_device.endCommandBuffer(render_buffer.vk_command_buffer) catch unreachable;

    this.vk_device.queueSubmit(this.vk_graphics_queue, 1, &[1]vk.SubmitInfo{
        .{
            .command_buffer_count = 1,
            .p_command_buffers = &[1]vk.CommandBuffer{render_buffer.vk_command_buffer},
        },
    }, render_buffer.vk_fence_finished) catch unreachable;

    try display.windowPresentBuffer(window, render_buffer.display_buffer);

    if (this.renderdoc.api) |renderdoc_api| {
        if (renderdoc_api.IsFrameCapturing(null, null) == 1) {
            _ = renderdoc_api.EndFrameCapture(null, null);
        }
    }

    swapchain.render_buffers.destroy(render_buffer);
}

fn _swapchainReleaseRenderBuffer(this: *@This(), swapchain_opaque: *seizer.Graphics.Swapchain, render_buffer_opaque: *seizer.Graphics.RenderBuffer) void {
    const swapchain: *Swapchain = @ptrCast(@alignCast(swapchain_opaque));
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));

    this.vk_device.endCommandBuffer(render_buffer.vk_command_buffer) catch unreachable;

    swapchain.elements.items(.free)[render_buffer.element_index] = true;
    std.debug.panic("{s}:{} unimplemented", .{ @src().file, @src().line });
}

// RenderBuffer functions
fn _beginRendering(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, options: seizer.Graphics.RenderBuffer.BeginRenderingOptions) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    this.vk_device.cmdBeginRendering(render_buffer.vk_command_buffer, &vk.RenderingInfo{
        .render_area = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{ .width = render_buffer.size[0], .height = render_buffer.size[1] },
        },
        .layer_count = 1,
        .view_mask = 0,
        .color_attachment_count = 1,
        .p_color_attachments = &[_]vk.RenderingAttachmentInfo{
            .{
                .image_view = render_buffer.vk_image_view,
                .image_layout = .color_attachment_optimal,
                .resolve_mode = .{},
                .resolve_image_layout = .undefined,
                .load_op = .clear,
                .store_op = .store,
                .clear_value = .{
                    .color = .{ .float_32 = options.clear_color },
                },
            },
        },
    });
}

fn _endRendering(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    this.vk_device.cmdEndRendering(render_buffer.vk_command_buffer);
}

fn _bindPipeline(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pipeline_opaque: *seizer.Graphics.Pipeline) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

    // var vk_descriptor_sets: [1]vk.DescriptorSet = undefined;
    // this.vk_device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
    //     .descriptor_pool = this.vk_descriptor_pool,
    //     .descriptor_set_count = 1,
    //     .p_set_layouts = &.{pipeline.vk_descriptor_set_layout},
    // }, &vk_descriptor_sets) catch unreachable;

    // for (this.descriptor_set_write_list.items) |*write_info| {
    //     write_info.dst_set = vk_descriptor_sets[0];
    // }
    // this.vk_device.updateDescriptorSets(@intCast(this.descriptor_set_write_list.items.len), this.descriptor_set_write_list.items.ptr, 0, null);

    // this.descriptor_sets.appendSlice(this.allocator, vk_descriptor_sets[0..]) catch unreachable;

    this.vk_device.cmdBindPipeline(render_buffer.vk_command_buffer, .graphics, pipeline.vk_pipeline);
}

fn _drawPrimitives(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    this.vk_device.cmdDraw(render_buffer.vk_command_buffer, vertex_count, instance_count, first_vertex, first_instance);
}

fn _uploadToBuffer(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, buffer_opaque: *seizer.Graphics.Buffer, data: []const u8) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    this.vk_device.cmdUpdateBuffer(render_buffer.vk_command_buffer, buffer.vk_buffer, 0, @intCast(data.len), @ptrCast(data.ptr));
}

fn _bindVertexBuffer(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pipeline_opaque: *seizer.Graphics.Pipeline, vertex_buffer_opaque: *seizer.Graphics.Buffer) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
    const vertex_buffer: *Buffer = @ptrCast(@alignCast(vertex_buffer_opaque));

    _ = pipeline;
    this.vk_device.cmdBindVertexBuffers(render_buffer.vk_command_buffer, 0, 1, &[1]vk.Buffer{vertex_buffer.vk_buffer}, &[1]vk.DeviceSize{0});
}

fn _uploadDescriptors(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pipeline_opaque: *seizer.Graphics.Pipeline, options: seizer.Graphics.Pipeline.UploadDescriptorsOptions) *seizer.Graphics.DescriptorSet {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));

    var arena = std.heap.ArenaAllocator.init(this.allocator);
    defer arena.deinit();

    var vk_descriptor_sets: [1]vk.DescriptorSet = undefined;
    this.vk_device.allocateDescriptorSets(&vk.DescriptorSetAllocateInfo{
        .descriptor_pool = render_buffer.vk_descriptor_pool,
        .descriptor_set_count = 1,
        .p_set_layouts = &.{pipeline.vk_descriptor_set_layout},
    }, &vk_descriptor_sets) catch unreachable;

    const vk_write_descriptor_set_list = arena.allocator().alloc(vk.WriteDescriptorSet, options.writes.len) catch unreachable;

    for (vk_write_descriptor_set_list, options.writes) |*vk_write_descriptor_set, write| {
        switch (write.data) {
            .sampler2D => |textures| {
                const descriptor_image_infos = arena.allocator().alloc(vk.DescriptorImageInfo, textures.len) catch unreachable;
                for (descriptor_image_infos, textures) |*descriptor_info, texture_opaque| {
                    const texture: *Texture = @ptrCast(@alignCast(texture_opaque));
                    descriptor_info.* = vk.DescriptorImageInfo{
                        .sampler = texture.vk_sampler,
                        .image_view = texture.vk_image_view,
                        .image_layout = .read_only_optimal,
                    };
                }

                vk_write_descriptor_set.* = vk.WriteDescriptorSet{
                    .dst_set = vk_descriptor_sets[0],
                    .dst_binding = write.binding,
                    .dst_array_element = write.offset,
                    .descriptor_type = .combined_image_sampler,
                    .descriptor_count = @intCast(descriptor_image_infos.len),
                    .p_image_info = descriptor_image_infos.ptr,

                    .p_buffer_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
            .buffer => |buffer_data_list| {
                const vk_buffers = render_buffer.vk_buffer_list.addManyAsSlice(this.allocator, buffer_data_list.len) catch unreachable;

                var mem_requirements = vk.MemoryRequirements{ .size = 0, .alignment = 0, .memory_type_bits = 0 };
                for (buffer_data_list, vk_buffers) |buffer_data, *vk_buffer| {
                    vk_buffer.* = this.vk_device.createBuffer(&vk.BufferCreateInfo{
                        .size = buffer_data.len,
                        .usage = .{ .uniform_buffer_bit = true, .transfer_dst_bit = true },
                        .sharing_mode = .exclusive,
                    }, null) catch unreachable;

                    const buffer_mem_requirements = this.vk_device.getBufferMemoryRequirements(vk_buffer.*);

                    mem_requirements.size += buffer_mem_requirements.size;
                    mem_requirements.alignment = @max(mem_requirements.alignment, buffer_mem_requirements.alignment);
                    mem_requirements.memory_type_bits |= buffer_mem_requirements.memory_type_bits;
                }

                const mem_type_index = findMemoryTypeIndex(this.vk_memory_properties, mem_requirements) orelse unreachable;

                const vk_device_memory = this.vk_device.allocateMemory(&vk.MemoryAllocateInfo{
                    .allocation_size = mem_requirements.size,
                    .memory_type_index = mem_type_index,
                }, null) catch unreachable;
                render_buffer.vk_device_memory_list.append(this.allocator, vk_device_memory) catch unreachable;

                const descriptor_buffer_infos = arena.allocator().alloc(vk.DescriptorBufferInfo, buffer_data_list.len) catch unreachable;

                var mem_offset: u64 = 0;
                for (descriptor_buffer_infos, buffer_data_list, vk_buffers) |*descriptor_info, data, vk_buffer| {
                    this.vk_device.bindBufferMemory(vk_buffer, vk_device_memory, mem_offset) catch unreachable;

                    this.vk_device.cmdUpdateBuffer(render_buffer.vk_command_buffer, vk_buffer, 0, @intCast(data.len), data.ptr);

                    descriptor_info.* = vk.DescriptorBufferInfo{
                        .buffer = vk_buffer,
                        .offset = 0,
                        .range = @intCast(data.len),
                    };

                    const buffer_mem_requirements = this.vk_device.getBufferMemoryRequirements(vk_buffer);
                    mem_offset = std.mem.alignForward(u64, mem_offset + buffer_mem_requirements.size, buffer_mem_requirements.alignment);
                }

                vk_write_descriptor_set.* = vk.WriteDescriptorSet{
                    .dst_set = vk_descriptor_sets[0],
                    .dst_binding = write.binding,
                    .dst_array_element = write.offset,
                    .descriptor_type = .uniform_buffer,
                    .descriptor_count = @intCast(descriptor_buffer_infos.len),
                    .p_buffer_info = descriptor_buffer_infos.ptr,

                    .p_image_info = undefined,
                    .p_texel_buffer_view = undefined,
                };
            },
        }
    }

    this.vk_device.updateDescriptorSets(
        @intCast(vk_write_descriptor_set_list.len),
        vk_write_descriptor_set_list.ptr,
        0,
        null,
    );

    return @ptrFromInt(@intFromEnum(vk_descriptor_sets[0]));
}

fn _bindDescriptorSet(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pipeline_opaque: *seizer.Graphics.Pipeline, descriptor_set_opaque: *seizer.Graphics.DescriptorSet) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
    const vk_descriptor_set: vk.DescriptorSet = @enumFromInt(@intFromPtr(descriptor_set_opaque));

    this.vk_device.cmdBindDescriptorSets(render_buffer.vk_command_buffer, .graphics, pipeline.vk_pipeline_layout, 0, 1, &.{vk_descriptor_set}, 0, null);
}

fn _pushConstants(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pipeline_opaque: *seizer.Graphics.Pipeline, stages: seizer.Graphics.Pipeline.Stages, data: []const u8, offset: u32) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    const pipeline: *Pipeline = @ptrCast(@alignCast(pipeline_opaque));
    this.vk_device.cmdPushConstants(
        render_buffer.vk_command_buffer,
        pipeline.vk_pipeline_layout,
        .{ .vertex_bit = stages.vertex, .fragment_bit = stages.fragment },
        offset,
        @intCast(data.len),
        data.ptr,
    );
}

fn _setViewport(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, options: seizer.Graphics.RenderBuffer.SetViewportOptions) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    this.vk_device.cmdSetViewport(render_buffer.vk_command_buffer, 0, 1, &[_]vk.Viewport{
        .{
            .x = options.pos[0],
            .y = options.pos[1],
            .width = options.size[0],
            .height = options.size[1],
            .min_depth = options.min_depth,
            .max_depth = options.max_depth,
        },
    });
}

fn _setScissor(this: *@This(), render_buffer_opaque: *seizer.Graphics.RenderBuffer, pos: [2]i32, size: [2]u32) void {
    const render_buffer: *RenderBuffer = @ptrCast(@alignCast(render_buffer_opaque));
    this.vk_device.cmdSetScissor(render_buffer.vk_command_buffer, 0, 1, &[_]vk.Rect2D{
        .{
            .offset = .{ .x = pos[0], .y = pos[1] },
            .extent = vk.Extent2D{
                .width = size[0],
                .height = size[1],
            },
        },
    });
}

pub const RenderBuffer = struct {
    element_index: u32,
    size: [2]u32,
    vk_image_view: vk.ImageView,
    vk_descriptor_pool: vk.DescriptorPool,
    vk_command_buffer: vk.CommandBuffer,
    vk_fence_finished: vk.Fence,
    display_buffer: *seizer.Display.Buffer,

    vk_buffer_list: *std.ArrayListUnmanaged(vk.Buffer),
    vk_device_memory_list: *std.ArrayListUnmanaged(vk.DeviceMemory),
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
    vk.features.version_1_3,
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
const seizer = @import("../seizer.zig");
const std = @import("std");
const builtin = @import("builtin");

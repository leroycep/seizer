pub const impl = struct {
    pub const vulkan = @import("./Graphics/impl/vulkan.zig");
    pub const gles3v0 = @import("./Graphics/impl/gles3v0.zig");
};

const Graphics = @This();

pub const Error = error{};

pointer: ?*anyopaque,
interface: *const Interface,

pub const Interface = struct {
    driver: Driver,
    destroy: *const fn (?*anyopaque) void,
    createShader: *const fn (?*anyopaque, Shader.CreateOptions) Shader.CreateError!*Shader,
    destroyShader: *const fn (?*anyopaque, *Shader) void,
    createTexture: *const fn (?*anyopaque, zigimg.Image, Texture.CreateOptions) Texture.CreateError!*Texture,
    destroyTexture: *const fn (?*anyopaque, *Texture) void,
    createPipeline: *const fn (?*anyopaque, Pipeline.CreateOptions) Pipeline.CreateError!*Pipeline,
    destroyPipeline: *const fn (?*anyopaque, *Pipeline) void,
    createBuffer: *const fn (?*anyopaque, Buffer.CreateOptions) Buffer.CreateError!*Buffer,
    destroyBuffer: *const fn (?*anyopaque, *Buffer) void,
    createSwapchain: *const fn (?*anyopaque, seizer.Display, *seizer.Display.Window, Swapchain.CreateOptions) Swapchain.CreateError!*Swapchain,
    destroySwapchain: *const fn (?*anyopaque, *Swapchain) void,

    swapchainGetRenderBuffer: *const fn (?*anyopaque, *Swapchain, Swapchain.GetRenderBufferOptions) Swapchain.GetRenderBufferError!*RenderBuffer,
    swapchainPresentRenderBuffer: *const fn (?*anyopaque, seizer.Display, *seizer.Display.Window, *Swapchain, *RenderBuffer) Swapchain.PresentRenderBufferError!void,
    swapchainReleaseRenderBuffer: *const fn (?*anyopaque, *Swapchain, *RenderBuffer) void,

    beginRendering: *const fn (?*anyopaque, *RenderBuffer, RenderBuffer.BeginRenderingOptions) void,
    endRendering: *const fn (?*anyopaque, *RenderBuffer) void,
    bindPipeline: *const fn (?*anyopaque, *RenderBuffer, *Graphics.Pipeline) void,
    drawPrimitives: *const fn (?*anyopaque, *RenderBuffer, vertex_count: u32, instance_count: u32, first_vertex: u32, first_instance: u32) void,
    uploadToBuffer: *const fn (?*anyopaque, *RenderBuffer, buffer: *Graphics.Buffer, data: []const u8) void,
    bindVertexBuffer: *const fn (?*anyopaque, *RenderBuffer, pipeline: *Graphics.Pipeline, buffer: *Graphics.Buffer) void,
    uploadUniformTexture: *const fn (?*anyopaque, *RenderBuffer, *Graphics.Pipeline, binding: u32, index: u32, texture: ?*Graphics.Texture) void,
    uploadUniformBuffer: *const fn (?*anyopaque, *RenderBuffer, *Graphics.Pipeline, binding: u32, index: u32, data: []const u8, offset: u32) void,
    pushConstants: *const fn (?*anyopaque, *RenderBuffer, pipeline: *Graphics.Pipeline, stages: Graphics.Pipeline.Stages, data: []const u8, offset: u32) void,
    setScissor: *const fn (?*anyopaque, *RenderBuffer, position: [2]i32, size: [2]u32) void,
};

pub const Driver = enum(u32) {
    gles3v0,
    vulkan,
    _,
};

pub fn destroy(gfx: Graphics) void {
    return gfx.interface.destroy(gfx.pointer);
}

pub const Shader = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat, ShaderCompilationFailed };
    pub const CreateOptions = struct {
        sampler_count: u32,
        source: Source,
        target: Target,
        entry_point_name: []const u8,
    };
    pub const Source = union(enum) {
        glsl: [:0]const u8,
        spirv: []const u32,
    };
    pub const Target = enum {
        vertex,
        fragment,
    };
};

pub fn createShader(gfx: Graphics, options: Shader.CreateOptions) Shader.CreateError!*Shader {
    return gfx.interface.createShader(gfx.pointer, options);
}

pub fn destroyShader(gfx: Graphics, shader: *Shader) void {
    return gfx.interface.destroyShader(gfx.pointer, shader);
}

pub const Texture = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat };
    pub const CreateOptions = struct {
        min_filter: Filter = .nearest,
        mag_filter: Filter = .nearest,
        wrap: [2]Wrap = .{ .clamp_to_edge, .clamp_to_edge },
    };

    pub const Filter = enum {
        nearest,
        linear,
    };

    pub const Wrap = enum {
        clamp_to_edge,
        repeat,
    };
};

pub fn createTexture(gfx: Graphics, image: zigimg.Image, options: Texture.CreateOptions) Texture.CreateError!*Texture {
    return gfx.interface.createTexture(gfx.pointer, image, options);
}

pub fn destroyTexture(gfx: Graphics, texture: *Texture) void {
    return gfx.interface.destroyTexture(gfx.pointer, texture);
}

pub const Pipeline = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat, ShaderLinkingFailed };
    pub const CreateOptions = struct {
        vertex_shader: *Shader,
        fragment_shader: *Shader,
        blend: ?Blend,
        primitive_type: Primitive,
        push_constants: ?PushConstants,
        uniforms: []const UniformDescription,
        vertex_layout: []const VertexAttribute,
    };

    pub const Primitive = enum {
        triangle,
    };

    pub const Blend = struct {
        src_color_factor: Factor,
        dst_color_factor: Factor,
        color_op: Op,
        src_alpha_factor: Factor,
        dst_alpha_factor: Factor,
        alpha_op: Op,

        pub const Factor = enum {
            one,
            zero,
            src_alpha,
            one_minus_src_alpha,
        };

        pub const Op = enum {
            add,
        };
    };

    pub const PushConstants = struct {
        size: u32,
        stages: Stages,
    };

    pub const UniformDescription = struct {
        binding: u32,
        type: Type,
        count: u32,
        stages: Stages,
        size: u32,

        pub const Type = enum {
            sampler2D,
            buffer,
        };
    };
    pub const Stages = packed struct(u2) {
        vertex: bool = false,
        fragment: bool = false,
    };

    pub const VertexAttribute = struct {
        attribute_index: u32,
        buffer_slot: u32,
        len: u32,
        type: Type,
        normalized: bool,
        stride: u32,
        offset: u32,

        pub const Type = enum {
            f32,
            u8,
        };
    };
};

pub fn createPipeline(gfx: Graphics, options: Pipeline.CreateOptions) Pipeline.CreateError!*Pipeline {
    return gfx.interface.createPipeline(gfx.pointer, options);
}

pub fn destroyPipeline(gfx: Graphics, pipeline: *Pipeline) void {
    return gfx.interface.destroyPipeline(gfx.pointer, pipeline);
}

pub const Buffer = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat, ShaderLinkingFailed };
    pub const CreateOptions = struct {
        size: u32,
    };
};

pub fn createBuffer(gfx: Graphics, options: Buffer.CreateOptions) Buffer.CreateError!*Buffer {
    return gfx.interface.createBuffer(gfx.pointer, options);
}

pub fn destroyBuffer(gfx: Graphics, pipeline: *Buffer) void {
    return gfx.interface.destroyBuffer(gfx.pointer, pipeline);
}

pub const Swapchain = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat, DisplayConnectionLost };
    pub const CreateOptions = struct {
        num_frames: u32 = 3,
        size: [2]u32,
    };

    pub const GetRenderBufferError = error{ OutOfMemory, OutOfDeviceMemory, OutOfRenderBuffers, DeviceLost };
    pub const GetRenderBufferOptions = struct {};

    pub const PresentRenderBufferError = error{};
};

pub inline fn createSwapchain(gfx: Graphics, display: seizer.Display, window: *seizer.Display.Window, options: Swapchain.CreateOptions) Swapchain.CreateError!*Swapchain {
    return gfx.interface.createSwapchain(gfx.pointer, display, window, options);
}

pub inline fn destroySwapchain(gfx: Graphics, pipeline: *Swapchain) void {
    return gfx.interface.destroySwapchain(gfx.pointer, pipeline);
}

/// Gets a free RenderBuffer from the swapchain. Used as an image to render to. Don't forget to either present it
/// or release it.
pub inline fn swapchainGetRenderBuffer(gfx: Graphics, swapchain: *Swapchain, options: Swapchain.GetRenderBufferOptions) Swapchain.GetRenderBufferError!*RenderBuffer {
    return gfx.interface.swapchainGetRenderBuffer(gfx.pointer, swapchain, options);
}

pub inline fn swapchainPresentRenderBuffer(gfx: Graphics, display: seizer.Display, window: *seizer.Display.Window, swapchain: *Swapchain, render_buffer: *RenderBuffer) Swapchain.PresentRenderBufferError!void {
    return gfx.interface.swapchainPresentRenderBuffer(gfx.pointer, display, window, swapchain, render_buffer);
}

pub inline fn swapchainReleaseRenderBuffer(gfx: Graphics, swapchain: *Swapchain, render_buffer: *RenderBuffer) void {
    return gfx.interface.swapchainReleaseRenderBuffer(gfx.pointer, swapchain, render_buffer);
}

// RenderBuffer
pub const RenderBuffer = opaque {
    pub const BeginRenderingOptions = struct {
        clear_color: [4]f32 = .{ 0, 0, 0, 1 },
    };
};

pub inline fn beginRendering(gfx: Graphics, render_buffer: *RenderBuffer, options: RenderBuffer.BeginRenderingOptions) void {
    return gfx.interface.beginRendering(gfx.pointer, render_buffer, options);
}

pub inline fn endRendering(gfx: Graphics, render_buffer: *RenderBuffer) void {
    return gfx.interface.endRendering(gfx.pointer, render_buffer);
}

const seizer = @import("./seizer.zig");
const zigimg = @import("zigimg");
const std = @import("std");

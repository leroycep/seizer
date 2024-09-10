pub const CommandBuffer = @import("./Graphics/CommandBuffer.zig");
pub const RenderBuffer = @import("./Graphics/RenderBuffer.zig");

pub const impl = struct {
    pub const vulkan = @import("./Graphics/impl/vulkan.zig");
    pub const gles3v0 = @import("./Graphics/impl/gles3v0.zig");
};

const Graphics = @This();

pub const Error = error{};

pointer: ?*anyopaque,
interface: *const Interface,

pub const Driver = enum(u32) {
    gles3v0,
    vulkan,
    _,
};

pub fn destroy(gfx: Graphics) void {
    return gfx.interface.destroy(gfx);
}

pub const BeginOptions = struct {
    size: [2]u32,
    clear_color: ?[4]f32,
};

pub const BeginError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread };
pub fn begin(gfx: Graphics, options: BeginOptions) BeginError!CommandBuffer {
    return gfx.interface.begin(gfx, options);
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
    return gfx.interface.createShader(gfx, options);
}

pub fn destroyShader(gfx: Graphics, shader: *Shader) void {
    return gfx.interface.destroyShader(gfx, shader);
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
    return gfx.interface.createTexture(gfx, image, options);
}

pub fn destroyTexture(gfx: Graphics, texture: *Texture) void {
    return gfx.interface.destroyTexture(gfx, texture);
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
    return gfx.interface.createPipeline(gfx, options);
}

pub fn destroyPipeline(gfx: Graphics, pipeline: *Pipeline) void {
    return gfx.interface.destroyPipeline(gfx, pipeline);
}

pub const Buffer = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat, ShaderLinkingFailed };
    pub const CreateOptions = struct {
        size: u32,
    };
};

pub fn createBuffer(gfx: Graphics, options: Buffer.CreateOptions) Buffer.CreateError!*Buffer {
    return gfx.interface.createBuffer(gfx, options);
}

pub fn destroyBuffer(gfx: Graphics, pipeline: *Buffer) void {
    return gfx.interface.destroyBuffer(gfx, pipeline);
}

pub fn releaseRenderBuffer(gfx: Graphics, render_buffer: RenderBuffer) void {
    return gfx.interface.releaseRenderBuffer(gfx, render_buffer);
}

pub const Interface = struct {
    driver: Driver,
    destroy: *const fn (Graphics) void,
    begin: *const fn (Graphics, BeginOptions) BeginError!CommandBuffer,
    createShader: *const fn (Graphics, Shader.CreateOptions) Shader.CreateError!*Shader,
    destroyShader: *const fn (Graphics, *Shader) void,
    createTexture: *const fn (Graphics, zigimg.Image, Texture.CreateOptions) Texture.CreateError!*Texture,
    destroyTexture: *const fn (Graphics, *Texture) void,
    createPipeline: *const fn (Graphics, Pipeline.CreateOptions) Pipeline.CreateError!*Pipeline,
    destroyPipeline: *const fn (Graphics, *Pipeline) void,
    createBuffer: *const fn (Graphics, Buffer.CreateOptions) Buffer.CreateError!*Buffer,
    destroyBuffer: *const fn (Graphics, *Buffer) void,
    releaseRenderBuffer: *const fn (Graphics, RenderBuffer) void,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        driver: Driver,
        destroy: *const fn (*T) void,
        begin: *const fn (*T, options: BeginOptions) BeginError!CommandBuffer,
        createShader: *const fn (*T, Shader.CreateOptions) Shader.CreateError!*Shader,
        destroyShader: *const fn (*T, *Shader) void,
        createTexture: *const fn (*T, zigimg.Image, Texture.CreateOptions) Texture.CreateError!*Texture,
        destroyTexture: *const fn (*T, *Texture) void,
        createPipeline: *const fn (*T, Pipeline.CreateOptions) Pipeline.CreateError!*Pipeline,
        destroyPipeline: *const fn (*T, *Pipeline) void,
        createBuffer: *const fn (*T, Buffer.CreateOptions) Buffer.CreateError!*Buffer,
        destroyBuffer: *const fn (*T, *Buffer) void,
        releaseRenderBuffer: *const fn (*T, RenderBuffer) void,
    }) Interface {
        const type_erased_fns = struct {
            fn destroy(gfx: Graphics) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                typed_fns.destroy(t);
            }
            fn begin(gfx: Graphics, options: BeginOptions) BeginError!CommandBuffer {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.begin(t, options);
            }
            fn createShader(gfx: Graphics, options: Shader.CreateOptions) Shader.CreateError!*Shader {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createShader(t, options);
            }
            fn destroyShader(gfx: Graphics, shader: *Shader) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.destroyShader(t, shader);
            }
            fn createTexture(gfx: Graphics, image: zigimg.Image, options: Texture.CreateOptions) Texture.CreateError!*Texture {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createTexture(t, image, options);
            }
            fn destroyTexture(gfx: Graphics, texture: *Texture) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.destroyTexture(t, texture);
            }
            fn createPipeline(gfx: Graphics, options: Pipeline.CreateOptions) Pipeline.CreateError!*Pipeline {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createPipeline(t, options);
            }
            fn destroyPipeline(gfx: Graphics, pipeline: *Pipeline) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.destroyPipeline(t, pipeline);
            }
            fn createBuffer(gfx: Graphics, options: Buffer.CreateOptions) Buffer.CreateError!*Buffer {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createBuffer(t, options);
            }
            fn destroyBuffer(gfx: Graphics, pipeline: *Buffer) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.destroyBuffer(t, pipeline);
            }
            fn releaseRenderBuffer(gfx: Graphics, render_buffer: RenderBuffer) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.releaseRenderBuffer(t, render_buffer);
            }
        };
        return Interface{
            .driver = typed_fns.driver,
            .destroy = type_erased_fns.destroy,
            .begin = type_erased_fns.begin,
            .createShader = type_erased_fns.createShader,
            .destroyShader = type_erased_fns.destroyShader,
            .createTexture = type_erased_fns.createTexture,
            .destroyTexture = type_erased_fns.destroyTexture,
            .createPipeline = type_erased_fns.createPipeline,
            .destroyPipeline = type_erased_fns.destroyPipeline,
            .createBuffer = type_erased_fns.createBuffer,
            .destroyBuffer = type_erased_fns.destroyBuffer,
            .releaseRenderBuffer = type_erased_fns.releaseRenderBuffer,
        };
    }
};

const zigimg = @import("zigimg");
const std = @import("std");

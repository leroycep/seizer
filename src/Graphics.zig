pub const CommandBuffer = @import("./Graphics/CommandBuffer.zig");
pub const RenderBuffer = @import("./Graphics/RenderBuffer.zig");
pub const Texture = @import("./Graphics/Texture.zig");

pub const impl = struct {
    pub const vulkan = @import("./Graphics/impl/vulkan.zig");
    pub const gles3v0 = @import("./Graphics/impl/gles3v0.zig");
};

const Graphics = @This();

pub const Error = error{};

pointer: ?*anyopaque,
interface: *const Interface,

const Driver = enum(u32) {
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

pub const CreateTextureOptions = struct {
    min_filter: Texture.Filter = .nearest,
    mag_filter: Texture.Filter = .nearest,
    wrap: [2]Texture.Wrap = .{ .clamp_to_edge, .clamp_to_edge },
};

pub const Shader = opaque {
    pub const CreateError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat };
    pub const CreateOptions = struct {
        sampler_count: u32,
        source: Source,
        entry_point_name: []const u8,
    };
    pub const Source = union(enum) {
        glsl: [:0]const u8,
        spirv: []const u32,
    };
};

pub fn createShader(gfx: Graphics, allocator: std.mem.Allocator, options: Shader.CreateOptions) Shader.CreateError!*Shader {
    return gfx.interface.createShader(gfx, allocator, options);
}

pub fn destroyShader(gfx: Graphics, shader: *Shader) void {
    return gfx.interface.destroyShader(gfx, shader);
}

pub const CreateTextureError = error{ OutOfMemory, OutOfDeviceMemory, InUseOnOtherThread, UnsupportedFormat };
pub fn createTexture(gfx: Graphics, allocator: std.mem.Allocator, image: zigimg.Image, options: CreateTextureOptions) CreateTextureError!Texture {
    return gfx.interface.createTexture(gfx, allocator, image, options);
}

pub const Interface = struct {
    driver: Driver,
    destroy: *const fn (Graphics) void,
    begin: *const fn (Graphics, BeginOptions) BeginError!CommandBuffer,
    createShader: *const fn (Graphics, std.mem.Allocator, Shader.CreateOptions) Shader.CreateError!*Shader,
    destroyShader: *const fn (Graphics, *Shader) void,
    createTexture: *const fn (Graphics, std.mem.Allocator, zigimg.Image, CreateTextureOptions) CreateTextureError!Texture,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        driver: Driver,
        destroy: *const fn (*T) void,
        begin: *const fn (*T, options: BeginOptions) BeginError!CommandBuffer,
        createShader: *const fn (*T, std.mem.Allocator, Shader.CreateOptions) Shader.CreateError!*Shader,
        destroyShader: *const fn (*T, *Shader) void,
        createTexture: *const fn (*T, std.mem.Allocator, zigimg.Image, CreateTextureOptions) CreateTextureError!Texture,
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
            fn createShader(gfx: Graphics, allocator: std.mem.Allocator, options: Shader.CreateOptions) Shader.CreateError!*Shader {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createShader(t, allocator, options);
            }
            fn destroyShader(gfx: Graphics, shader: *Shader) void {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.destroyShader(t, shader);
            }
            fn createTexture(gfx: Graphics, allocator: std.mem.Allocator, image: zigimg.Image, options: CreateTextureOptions) CreateTextureError!Texture {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createTexture(t, allocator, image, options);
            }
        };
        return Interface{
            .driver = typed_fns.driver,
            .destroy = type_erased_fns.destroy,
            .begin = type_erased_fns.begin,
            .createShader = type_erased_fns.createShader,
            .destroyShader = type_erased_fns.destroyShader,
            .createTexture = type_erased_fns.createTexture,
        };
    }
};

const zigimg = @import("zigimg");
const std = @import("std");

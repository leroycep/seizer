pub const CommandBuffer = @import("./Graphics/CommandBuffer.zig");
pub const RenderBuffer = @import("./Graphics/RenderBuffer.zig");
pub const Texture = @import("./Graphics/Texture.zig");

pub const impl = struct {
    pub const gles3v0 = @import("./Graphics/impl/gles3v0.zig");
};

const Graphics = @This();

pub const Error = error{};

pointer: ?*anyopaque,
interface: *const Interface,

pub fn destroy(gfx: Graphics) void {
    return gfx.interface.destroy(gfx);
}

pub const BeginOptions = struct {
    size: [2]u32,
    clear_color: ?[4]f32,
};

pub const BeginError = error{ OutOfMemory, InUseOnOtherThread };
pub fn begin(gfx: Graphics, options: BeginOptions) BeginError!CommandBuffer {
    return gfx.interface.begin(gfx, options);
}

pub const CreateTextureOptions = struct {
    min_filter: Texture.Filter = .nearest,
    mag_filter: Texture.Filter = .nearest,
    wrap: [2]Texture.Wrap = .{ .clamp_to_edge, .clamp_to_edge },
};

pub const CreateTextureError = error{ OutOfMemory, InUseOnOtherThread, UnsupportedFormat };
pub fn createTexture(gfx: Graphics, allocator: std.mem.Allocator, image: zigimg.Image, options: CreateTextureOptions) CreateTextureError!Texture {
    return gfx.interface.createTexture(gfx, allocator, image, options);
}

pub const Interface = struct {
    destroy: *const fn (Graphics) void,
    begin: *const fn (Graphics, BeginOptions) BeginError!CommandBuffer,
    createTexture: *const fn (Graphics, std.mem.Allocator, zigimg.Image, CreateTextureOptions) CreateTextureError!Texture,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        destroy: *const fn (*T) void,
        begin: *const fn (*T, options: BeginOptions) BeginError!CommandBuffer,
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
            fn createTexture(gfx: Graphics, allocator: std.mem.Allocator, image: zigimg.Image, options: CreateTextureOptions) CreateTextureError!Texture {
                const t: *T = @ptrCast(@alignCast(gfx.pointer));
                return typed_fns.createTexture(t, allocator, image, options);
            }
        };
        return Interface{
            .destroy = type_erased_fns.destroy,
            .begin = type_erased_fns.begin,
            .createTexture = type_erased_fns.createTexture,
        };
    }
};

const zigimg = @import("zigimg");
const std = @import("std");

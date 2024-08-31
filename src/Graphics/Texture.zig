//! Pointer+VTable Pointer interface for an image that lives in GPU memory (or rather, an image that can be used for rendering).

const Texture = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub const Filter = enum {
    nearest,
    linear,
};

pub const Wrap = enum {
    clamp_to_edge,
    repeat,
};

pub fn release(render_buffer: Texture) void {
    return render_buffer.interface.release(render_buffer);
}

pub fn getSize(render_buffer: Texture) [2]u32 {
    return render_buffer.interface.getSize(render_buffer);
}

pub const Interface = struct {
    release: *const fn (Texture) void,
    getSize: *const fn (Texture) [2]u32,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        release: *const fn (*T) void,
        getSize: *const fn (*T) [2]u32,
    }) Interface {
        const type_erased_fns = struct {
            fn release(render_buffer: Texture) void {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.release(t);
            }
            fn getSize(render_buffer: Texture) [2]u32 {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.getSize(t);
            }
        };
        return Interface{
            .release = type_erased_fns.release,
            .getSize = type_erased_fns.getSize,
        };
    }
};

const std = @import("std");

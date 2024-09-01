const RenderBuffer = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub const DmaBufFormat = struct {
    fourcc: FourCC,
    plane_count: u32,
    modifiers: u64,

    pub const FourCC = enum(u32) {
        ARGB8888 = 'A' | 'R' << 8 | '2' << 16 | '4' << 24,
        XRGB8888 = 'X' | 'R' << 8 | '2' << 16 | '4' << 24,
        ABGR8888 = 'A' | 'B' << 8 | '2' << 16 | '4' << 24,
        BGRX8888 = 'B' | 'X' << 8 | '2' << 16 | '4' << 24,
        XBGR8888 = 'X' | 'B' << 8 | '2' << 16 | '4' << 24,
        _,
    };
};

pub fn release(render_buffer: RenderBuffer) void {
    return render_buffer.interface.release(render_buffer);
}

pub fn getSize(render_buffer: RenderBuffer) [2]u32 {
    return render_buffer.interface.getSize(render_buffer);
}

pub fn getDmaBufFormat(render_buffer: RenderBuffer) DmaBufFormat {
    return render_buffer.interface.getDmaBufFormat(render_buffer);
}

pub const DmaBufPlane = struct {
    fd: std.posix.fd_t,
    index: u32,
    offset: u32,
    stride: u32,
};

pub fn getDmaBufPlanes(render_buffer: RenderBuffer, planes_buf: []DmaBufPlane) []DmaBufPlane {
    return render_buffer.interface.getDmaBufPlanes(render_buffer, planes_buf);
}

pub const Interface = struct {
    release: *const fn (RenderBuffer) void,
    getSize: *const fn (RenderBuffer) [2]u32,
    getDmaBufFormat: *const fn (RenderBuffer) DmaBufFormat,
    getDmaBufPlanes: *const fn (RenderBuffer, []DmaBufPlane) []DmaBufPlane,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        release: *const fn (*T) void,
        getSize: *const fn (*T) [2]u32,
        getDmaBufFormat: *const fn (*T) DmaBufFormat,
        getDmaBufPlanes: *const fn (*T, []DmaBufPlane) []DmaBufPlane,
    }) Interface {
        const type_erased_fns = struct {
            fn release(render_buffer: RenderBuffer) void {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.release(t);
            }
            fn getSize(render_buffer: RenderBuffer) [2]u32 {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.getSize(t);
            }
            fn getDmaBufFormat(render_buffer: RenderBuffer) DmaBufFormat {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.getDmaBufFormat(t);
            }
            fn getDmaBufPlanes(render_buffer: RenderBuffer, planes_buf: []DmaBufPlane) []DmaBufPlane {
                const t: *T = @ptrCast(@alignCast(render_buffer.pointer));
                return typed_fns.getDmaBufPlanes(t, planes_buf);
            }
        };
        return Interface{
            .release = type_erased_fns.release,
            .getSize = type_erased_fns.getSize,
            .getDmaBufFormat = type_erased_fns.getDmaBufFormat,
            .getDmaBufPlanes = type_erased_fns.getDmaBufPlanes,
        };
    }
};

const std = @import("std");

//! This module abstracts over different windowing systems, or the lack thereof.

pub const Wayland = @import("./Display/Wayland.zig");

pub const DEFAULT_BACKENDS: []const *const Display.Interface = if (builtin.os.tag == .linux or builtin.os.tag.isBSD())
    &.{&Wayland.DISPLAY_INTERFACE}
else
    @compileError("Unsupported platform " ++ @tagName(builtin.os.tag));

const Display = @This();

pointer: ?*anyopaque,
interface: *const Interface,

pub const Interface = struct {
    name: []const u8,
    create: *const fn (std.mem.Allocator, *xev.Loop) CreateError!Display,
    destroy: *const fn (?*anyopaque) void,
    createWindow: *const fn (?*anyopaque, Window.CreateOptions) Window.CreateError!*Window,
    destroyWindow: *const fn (?*anyopaque, *Window) void,

    windowSetUserdata: *const fn (?*anyopaque, *Window, ?*anyopaque) void,
    windowGetUserdata: *const fn (?*anyopaque, *Window) ?*anyopaque,
    windowGetSize: *const fn (?*anyopaque, *Window) [2]f32,
    windowGetScale: *const fn (?*anyopaque, *Window) f32,
    windowPresentBuffer: *const fn (?*anyopaque, *Window, *Buffer) Window.PresentError!void,

    isCreateBufferFromDMA_BUF_Supported: *const fn (?*anyopaque) bool,
    isCreateBufferFromOpaqueFdSupported: *const fn (?*anyopaque) bool,

    createBufferFromDMA_BUF: *const fn (?*anyopaque, Buffer.CreateOptionsDMA_BUF) Buffer.CreateError!*Buffer,
    createBufferFromOpaqueFd: *const fn (?*anyopaque, Buffer.CreateOptionsOpaqueFd) Buffer.CreateError!*Buffer,

    destroyBuffer: *const fn (?*anyopaque, *Buffer) void,
};

pub const CreateOptions = struct {
    backends: []const *const Display.Interface = DEFAULT_BACKENDS,
};
pub const CreateError = error{ OutOfMemory, NoSupportedBackend, DisplayNotFound, ExtensionMissing, ConnectionLost };

pub const Window = opaque {
    pub const CreateOptions = struct {
        title: [:0]const u8,
        app_name: ?[:0]const u8 = null,
        on_event: ?*const fn (*Window, Event) anyerror!void = null,
        on_render: *const fn (*Window) anyerror!void,
        on_destroy: ?*const fn (*Window) void = null,
        size: [2]u32,
    };
    pub const CreateError = error{ OutOfMemory, ConnectionLost };

    pub const Event = union(enum) {
        resize: [2]f32,
        rescale: f32,
        should_close,
        input: seizer.input.Event,
    };

    pub const PresentError = error{ OutOfMemory, ConnectionLost };
};

pub fn create(allocator: std.mem.Allocator, loop: *xev.Loop, options: CreateOptions) CreateError!Display {
    for (options.backends) |backend_interface| {
        if (backend_interface.create(allocator, loop)) |display_backend| {
            return display_backend;
        } else |err| {
            std.log.scoped(.seizer).warn("Failed to create {s} display: {}", .{ backend_interface.name, err });
        }
    }

    return error.NoSupportedBackend;
}

pub fn destroy(this: @This()) void {
    return this.interface.destroy(this.pointer);
}

pub fn createWindow(this: @This(), options: Window.CreateOptions) Window.CreateError!*Window {
    return this.interface.createWindow(this.pointer, options);
}

pub fn destroyWindow(this: @This(), window: *Window) void {
    return this.interface.destroyWindow(this.pointer, window);
}

pub fn windowGetSize(this: @This(), window: *Window) [2]f32 {
    return this.interface.windowGetSize(this.pointer, window);
}

pub fn windowGetScale(this: @This(), window: *Window) f32 {
    return this.interface.windowGetScale(this.pointer, window);
}

pub fn windowPresentBuffer(this: @This(), window: *Window, buffer: *Buffer) Window.PresentError!void {
    return this.interface.windowPresentBuffer(this.pointer, window, buffer);
}

pub fn windowSetUserdata(this: @This(), window: *Window, userdata: ?*anyopaque) void {
    return this.interface.windowSetUserdata(this.pointer, window, userdata);
}

pub fn windowGetUserdata(this: @This(), window: *Window) ?*anyopaque {
    return this.interface.windowGetUserdata(this.pointer, window);
}

// -- Display Buffers --
pub const Buffer = opaque {
    pub const CreateOptionsDMA_BUF = struct {
        size: [2]u32,
        scale: f32,
        format: DmaBufFormat,
        planes: []const DmaBufPlane,
        userdata: ?*anyopaque,
        on_release: *const fn (?*anyopaque, *Buffer) void,
    };
    pub const CreateOptionsOpaqueFd = struct {
        fd: std.posix.fd_t,
        offset: u32,
        pool_size: u32,
        size: [2]u32,
        scale: f32,
        stride: u32,
        format: FourCC,

        userdata: ?*anyopaque,
        on_release: *const fn (?*anyopaque, *Buffer) void,
    };
    pub const CreateError = error{ OutOfMemory, ConnectionLost, UnsupportedFormat };

    pub const DmaBufFormat = struct {
        fourcc: FourCC,
        plane_count: u32,
        modifiers: u64,
    };

    pub const FourCC = enum(u32) {
        ARGB8888 = 'A' | 'R' << 8 | '2' << 16 | '4' << 24,
        XRGB8888 = 'X' | 'R' << 8 | '2' << 16 | '4' << 24,
        ABGR8888 = 'A' | 'B' << 8 | '2' << 16 | '4' << 24,
        BGRX8888 = 'B' | 'X' << 8 | '2' << 16 | '4' << 24,
        XBGR8888 = 'X' | 'B' << 8 | '2' << 16 | '4' << 24,
        _,
    };

    pub const DmaBufPlane = struct {
        fd: std.posix.fd_t,
        index: u32,
        offset: u32,
        stride: u32,
    };

    pub const Type = enum {
        opaque_fd,
        dma_buf,
    };
};

pub fn isCreateBufferFromDMA_BUF_Supported(this: @This()) bool {
    return this.interface.isCreateBufferFromDMA_BUF_Supported(this.pointer);
}

pub fn isCreateBufferFromOpaqueFdSupported(this: @This()) bool {
    return this.interface.isCreateBufferFromOpaqueFdSupported(this.pointer);
}

pub fn createBufferFromDMA_BUF(this: @This(), options: Buffer.CreateOptionsDMA_BUF) Buffer.CreateError!*Buffer {
    return this.interface.createBufferFromDMA_BUF(this.pointer, options);
}

pub fn createBufferFromOpaqueFd(this: @This(), options: Buffer.CreateOptionsOpaqueFd) Buffer.CreateError!*Buffer {
    return this.interface.createBufferFromOpaqueFd(this.pointer, options);
}

pub fn destroyBuffer(this: @This(), buffer: *Buffer) void {
    return this.interface.destroyBuffer(this.pointer, buffer);
}

const builtin = @import("builtin");
const seizer = @import("./seizer.zig");
const std = @import("std");
const xev = @import("xev");

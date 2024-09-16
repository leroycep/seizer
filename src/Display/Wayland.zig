const Wayland = @This();

allocator: std.mem.Allocator,

connection: wayland.Conn,
registry: *wayland.wayland.wl_registry,
globals: Globals = .{},

// (wl_surface id, window)
windows: std.AutoArrayHashMapUnmanaged(u32, *Window) = .{},
seats: std.ArrayListUnmanaged(*Seat) = .{},

on_event_fn: ?*const fn (event: seizer.input.Event) anyerror!void = null,

pub const DISPLAY_INTERFACE = seizer.meta.interfaceFromConcreteTypeFns(seizer.Display.Interface, @This(), .{
    .name = "Wayland",
    .create = _create,
    .destroy = _destroy,
    .createWindow = _createWindow,
    .destroyWindow = _destroyWindow,

    .windowGetSize = _windowGetSize,
    .windowPresentBuffer = _windowPresentBuffer,

    .createBufferFromDMA_BUF = _createBufferFromDMA_BUF,
    .destroyBuffer = _destroyBuffer,
});

pub fn _create(allocator: std.mem.Allocator, loop: *xev.Loop) seizer.Display.CreateError!seizer.Display {
    // initialize wayland connection
    const connection_path = wayland.getDisplayPath(allocator) catch |err| switch (err) {
        error.EnvironmentVariableNotFound => return error.DisplayNotFound,
        else => |e| return e,
    };
    defer allocator.free(connection_path);

    // allocate this
    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);
    this.* = .{
        .allocator = allocator,

        .connection = undefined,
        .registry = undefined,
    };

    // open connection to wayland server
    this.connection.connect(loop, allocator, connection_path) catch |err| switch (err) {
        error.FileNotFound => return error.DisplayNotFound,
        else => |e| std.debug.panic("Unexpected error: {}", .{e}),
    };
    errdefer this.connection.deinit();

    this.registry = this.connection.getRegistry() catch |err| switch (err) {
        else => |e| std.debug.panic("Unexpected error: {}", .{e}),
    };
    this.registry.on_event = onRegistryEvent;
    this.registry.userdata = this;

    this.connection.dispatchUntilSync(loop) catch |err| switch (err) {
        else => |e| std.debug.panic("Unexpected error: {}", .{e}),
    };
    if (this.globals.wl_compositor == null) {
        std.log.scoped(.seizer).warn("wayland: wl_compositor extension missing", .{});
        return error.ExtensionMissing;
    }
    if (this.globals.xdg_wm_base == null) {
        std.log.scoped(.seizer).warn("wayland: xdg_wm_base extension missing", .{});
        return error.ExtensionMissing;
    }
    if (this.globals.zwp_linux_dmabuf_v1 == null) {
        std.log.scoped(.seizer).warn("wayland: zwp_linux_dmabuf_v1 extension missing", .{});
        return error.ExtensionMissing;
    }

    this.globals.xdg_wm_base.?.on_event = onXdgWmBaseEvent;

    return seizer.Display{
        .pointer = this,
        .interface = &DISPLAY_INTERFACE,
    };
}

pub fn _destroy(this: *@This()) void {
    // for (this.windows.items) |window| {
    //     window.destroy();
    // }
    this.windows.deinit(this.allocator);

    for (this.seats.items) |seat| {
        this.allocator.destroy(seat);
    }
    this.seats.deinit(this.allocator);

    this.connection.deinit();

    this.allocator.destroy(this);
}

const Globals = struct {
    wl_compositor: ?*wayland.wayland.wl_compositor = null,
    xdg_wm_base: ?*xdg_shell.xdg_wm_base = null,
    zwp_linux_dmabuf_v1: ?*linux_dmabuf_v1.zwp_linux_dmabuf_v1 = null,
};

fn onRegistryEvent(registry: *wayland.wayland.wl_registry, userdata: ?*anyopaque, event: wayland.wayland.wl_registry.Event) void {
    const this: *@This() = @ptrCast(@alignCast(userdata));
    switch (event) {
        .global => |global| {
            const global_interface = global.interface orelse return;
            if (std.mem.eql(u8, global_interface, wayland.wayland.wl_compositor.INTERFACE.name) and global.version >= wayland.wayland.wl_compositor.INTERFACE.version) {
                this.globals.wl_compositor = registry.bind(wayland.wayland.wl_compositor, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, xdg_shell.xdg_wm_base.INTERFACE.name) and global.version >= xdg_shell.xdg_wm_base.INTERFACE.version) {
                this.globals.xdg_wm_base = registry.bind(xdg_shell.xdg_wm_base, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.name) and global.version >= linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.version) {
                this.globals.zwp_linux_dmabuf_v1 = registry.bind(linux_dmabuf_v1.zwp_linux_dmabuf_v1, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, wayland.wayland.wl_seat.INTERFACE.name) and global.version >= wayland.wayland.wl_seat.INTERFACE.version) {
                this.seats.ensureUnusedCapacity(this.allocator, 1) catch return;

                const seat = this.allocator.create(Seat) catch return;
                const wl_seat = registry.bind(wayland.wayland.wl_seat, global.name) catch {
                    this.allocator.destroy(seat);
                    return;
                };
                seat.* = .{
                    .wayland_manager = this,
                    .wl_seat = wl_seat,
                    .focused_window = null,
                };
                seat.wl_seat.userdata = seat;
                seat.wl_seat.on_event = Seat.onSeatCallback;
                this.seats.appendAssumeCapacity(seat);
            }
        },
        .global_remove => {},
    }
}

fn onXdgWmBaseEvent(xdg_wm_base: *xdg_shell.xdg_wm_base, userdata: ?*anyopaque, event: xdg_shell.xdg_wm_base.Event) void {
    _ = userdata;
    switch (event) {
        .ping => |conf| {
            xdg_wm_base.pong(conf.serial) catch |e| {
                std.log.warn("Failed to ack ping: {}", .{e});
            };
        },
    }
}

fn _createWindow(this: *@This(), options: seizer.Display.Window.CreateOptions) seizer.Display.Window.CreateError!*seizer.Display.Window {
    try this.windows.ensureUnusedCapacity(this.allocator, 1);

    const size = [2]c_int{ @intCast(options.size[0]), @intCast(options.size[1]) };

    const wl_surface = try this.globals.wl_compositor.?.create_surface();
    const xdg_surface = try this.globals.xdg_wm_base.?.get_xdg_surface(wl_surface);
    const xdg_toplevel = try xdg_surface.get_toplevel();
    try wl_surface.commit();

    const window = try this.allocator.create(Window);
    errdefer this.allocator.destroy(window);

    window.* = .{
        .wayland = this,

        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,

        .on_event = options.on_event,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,

        .new_window_size = size,
        .window_size = size,
    };

    window.xdg_surface.userdata = window;
    window.xdg_toplevel.userdata = window;
    window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
    window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;

    // Queue up an initial frame of rendering. We use a sync callback because surfaces will not give
    // frame callbacks until they have bound a buffer and committed at least once.
    // const sync_callback = try this.connection.sync();
    // sync_callback.on_event = Window.onFrameCallback;
    // sync_callback.userdata = window;

    this.windows.putAssumeCapacity(window.wl_surface.id, window);

    return @ptrCast(window);
}

fn _destroyWindow(this: *@This(), window_opaque: *seizer.Display.Window) void {
    const window: *Window = @ptrCast(@alignCast(window_opaque));

    if (window.on_destroy) |on_destroy| {
        on_destroy(@ptrCast(window));
    }

    // hide window
    window.wl_surface.attach(null, 0, 0) catch {};
    window.wl_surface.commit() catch {};

    // destroy surfaces
    window.xdg_toplevel.destroy() catch {};
    window.xdg_surface.destroy() catch {};
    window.wl_surface.destroy() catch {};

    this.allocator.destroy(window);
}

fn _windowGetSize(this: *@This(), window_opaque: *seizer.Display.Window) [2]u32 {
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    _ = this;

    return [2]u32{
        @intCast(window.window_size[0]),
        @intCast(window.window_size[1]),
    };
}

fn _windowPresentBuffer(this: *@This(), window_opaque: *seizer.Display.Window, buffer_opaque: *seizer.Display.Buffer) void {
    _ = this;
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    window.setupFrameCallback() catch unreachable;

    window.wl_surface.attach(buffer.wl_buffer, 0, 0) catch unreachable;
    window.wl_surface.damage_buffer(0, 0, @intCast(buffer.size[0]), @intCast(buffer.size[1])) catch unreachable;
    window.wl_surface.commit() catch unreachable;
}

const Buffer = struct {
    size: [2]u32,
    wl_buffer: *wayland.wayland.wl_buffer,
    userdata: ?*anyopaque,
    on_release: *const fn (?*anyopaque, *seizer.Display.Buffer) void,

    fn onWlBufferEvent(wl_buffer: *wayland.wayland.wl_buffer, userdata: ?*anyopaque, event: wayland.wayland.wl_buffer.Event) void {
        _ = wl_buffer;
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .release => {
                this.on_release(this.userdata, @ptrCast(this));
            },
        }
    }
};

fn _createBufferFromDMA_BUF(this: *@This(), options: seizer.Display.Buffer.CreateOptions) seizer.Display.Buffer.CreateError!*seizer.Display.Buffer {
    const wl_dmabuf_buffer_params = try this.globals.zwp_linux_dmabuf_v1.?.create_params();
    defer wl_dmabuf_buffer_params.destroy() catch {};

    for (options.planes) |plane| {
        try wl_dmabuf_buffer_params.add(
            @enumFromInt(plane.fd),
            @intCast(plane.index),
            @intCast(plane.offset),
            @intCast(plane.stride),
            @intCast((options.format.modifiers >> 32) & 0xFFFF_FFFF),
            @intCast((options.format.modifiers) & 0xFFFF_FFFF),
        );
    }

    const wl_buffer = try wl_dmabuf_buffer_params.create_immed(
        @intCast(options.size[0]),
        @intCast(options.size[1]),
        @intFromEnum(options.format.fourcc),
        .{ .y_invert = false, .interlaced = false, .bottom_first = false },
    );
    const buffer = try this.allocator.create(Buffer);
    buffer.* = .{
        .size = options.size,
        .wl_buffer = wl_buffer,
        .userdata = options.userdata,
        .on_release = options.on_release,
    };

    wl_buffer.userdata = buffer;
    wl_buffer.on_event = Buffer.onWlBufferEvent;

    return @ptrCast(buffer);
}

fn _destroyBuffer(this: *@This(), buffer_opaque: *seizer.Display.Buffer) void {
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    buffer.wl_buffer.destroy() catch unreachable;

    this.allocator.destroy(buffer);
}

const Window = struct {
    wayland: *Wayland,

    wl_surface: *wayland.wayland.wl_surface,
    xdg_surface: *xdg_shell.xdg_surface,
    xdg_toplevel: *xdg_shell.xdg_toplevel,

    on_event: ?*const fn (*seizer.Display.Window, seizer.Display.Window.Event) anyerror!void,
    on_render: *const fn (*seizer.Display.Window) anyerror!void,
    on_destroy: ?*const fn (*seizer.Display.Window) void,

    frame_callback: ?*wayland.wayland.wl_callback = null,

    new_window_size: [2]c_int,
    window_size: [2]c_int,

    userdata: ?*anyopaque = null,

    pub fn getSize(userdata: ?*anyopaque) [2]u32 {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));

        return .{ @intCast(this.window_size[0]), @intCast(this.window_size[1]) };
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }

    pub fn setUserdata(userdata: ?*anyopaque, user_userdata: ?*anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.userdata = user_userdata;
    }

    pub fn getUserdata(this_ptr: ?*anyopaque) ?*anyopaque {
        const this: *@This() = @ptrCast(@alignCast(this_ptr.?));
        return this.userdata;
    }

    fn onXdgSurfaceEvent(xdg_surface: *xdg_shell.xdg_surface, userdata: ?*anyopaque, event: xdg_shell.xdg_surface.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .configure => |conf| {
                xdg_surface.ack_configure(conf.serial) catch |e| {
                    std.log.warn("Failed to ack configure: {}", .{e});
                    return;
                };

                this.window_size = this.new_window_size;
                if (this.on_event) |on_event| {
                    on_event(@ptrCast(this), .{ .resize = [2]u32{
                        @intCast(this.window_size[0]),
                        @intCast(this.window_size[1]),
                    } }) catch |err| {
                        std.debug.print("error returned from window event: {}\n", .{err});
                        if (@errorReturnTrace()) |err_ret_trace| {
                            std.debug.dumpStackTrace(err_ret_trace.*);
                        }
                    };
                }

                if (this.frame_callback == null) {
                    const sync_callback = this.wayland.connection.sync() catch unreachable;
                    sync_callback.on_event = Window.onFrameCallback;
                    sync_callback.userdata = this;
                }
            },
        }
    }

    fn onXdgToplevelEvent(xdg_toplevel: *xdg_shell.xdg_toplevel, userdata: ?*anyopaque, event: xdg_shell.xdg_toplevel.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = xdg_toplevel;
        switch (event) {
            .close => if (this.on_event) |on_event| {
                on_event(@ptrCast(this), .should_close) catch |err| {
                    std.debug.print("error returned from window event: {}\n", .{err});
                    if (@errorReturnTrace()) |err_ret_trace| {
                        std.debug.dumpStackTrace(err_ret_trace.*);
                    }
                };
            },
            .configure => |cfg| {
                if (cfg.width > 0 and cfg.height > 0) {
                    this.new_window_size[0] = cfg.width;
                    this.new_window_size[1] = cfg.height;
                }
            },
        }
    }

    fn setupFrameCallback(this: *@This()) !void {
        if (this.frame_callback != null) return;
        this.frame_callback = try this.wl_surface.frame();
        this.frame_callback.?.on_event = onFrameCallback;
        this.frame_callback.?.userdata = this;
    }

    fn onFrameCallback(callback: *wayland.wayland.wl_callback, userdata: ?*anyopaque, event: wayland.wayland.wl_callback.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = callback;
        switch (event) {
            .done => {
                this.frame_callback = null;
                this.on_render(@ptrCast(this)) catch |err| {
                    std.debug.print("{s}\n", .{@errorName(err)});
                    if (@errorReturnTrace()) |trace| {
                        std.debug.dumpStackTrace(trace.*);
                    }
                    return;
                };

                // if (this.wayland.renderdoc.api) |renderdoc_api| {
                //     if (renderdoc_api.IsFrameCapturing(null, null) == 1) {
                //         _ = renderdoc_api.EndFrameCapture(null, null);
                //     }
                // }
            },
        }
    }
};

const Seat = struct {
    wayland_manager: *Wayland,
    wl_seat: *wayland.wayland.wl_seat,
    wl_pointer: ?*wayland.wayland.wl_pointer = null,
    wl_keyboard: ?*wayland.wayland.wl_keyboard = null,

    focused_window: ?*Window,
    pointer_pos: [2]f32 = .{ 0, 0 },
    scroll_vector: [2]f32 = .{ 0, 0 },

    fn onSeatCallback(seat: *wayland.wayland.wl_seat, userdata: ?*anyopaque, event: wayland.wayland.wl_seat.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata));
        _ = seat;
        switch (event) {
            .capabilities => |capabilities| {
                if (capabilities.capabilities.keyboard) {
                    if (this.wl_keyboard == null) {
                        this.wl_keyboard = this.wl_seat.get_keyboard() catch return;
                        this.wl_keyboard.?.userdata = this;
                        this.wl_keyboard.?.on_event = onKeyboardCallback;
                    }
                } else {
                    if (this.wl_keyboard) |keyboard| {
                        keyboard.release() catch return;
                        this.wl_keyboard = null;
                    }
                }

                if (capabilities.capabilities.pointer) {
                    if (this.wl_pointer == null) {
                        this.wl_pointer = this.wl_seat.get_pointer() catch return;
                        this.wl_pointer.?.userdata = this;
                        this.wl_pointer.?.on_event = onPointerCallback;
                    }
                } else {
                    if (this.wl_pointer) |pointer| {
                        pointer.release() catch return;
                        this.wl_pointer = null;
                    }
                }
            },
            .name => {},
        }
    }

    fn onKeyboardCallback(seat: *wayland.wayland.wl_keyboard, userdata: ?*anyopaque, event: wayland.wayland.wl_keyboard.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata));
        _ = seat;
        switch (event) {
            .key => |k| {
                const key: seizer.input.keyboard.Key = @enumFromInt(@as(u16, @intCast(k.key)));

                if (this.wayland_manager.on_event_fn) |on_event| {
                    on_event(seizer.input.Event{ .key = .{
                        .key = key,
                        .scancode = k.key,
                        .action = switch (k.state) {
                            .pressed => .press,
                            .released => .release,
                        },
                        .mods = .{},
                    } }) catch |err| {
                        std.debug.print("{s}\n", .{@errorName(err)});
                        if (@errorReturnTrace()) |trace| {
                            std.debug.dumpStackTrace(trace.*);
                        }
                    };
                }

                // const actions = this.wayland_manager.key_bindings.get(.{ .keyboard = key }) orelse return;
                // for (actions.items) |action| {
                //     action.on_event(k.state == .pressed) catch |err| {
                //         std.debug.print("{s}\n", .{@errorName(err)});
                //         if (@errorReturnTrace()) |trace| {
                //             std.debug.dumpStackTrace(trace.*);
                //         }
                //         break;
                //     };
                // }
            },
            else => {},
        }
    }

    fn onPointerCallback(seat: *wayland.wayland.wl_pointer, userdata: ?*anyopaque, event: wayland.wayland.wl_pointer.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata));
        _ = seat;
        switch (event) {
            .enter => |enter| {
                // TODO: set cursor image
                this.focused_window = this.wayland_manager.windows.get(enter.surface);
            },
            .leave => |leave| {
                const left_window = this.wayland_manager.windows.get(leave.surface);
                if (std.meta.eql(left_window, this.focused_window)) {
                    this.focused_window = null;
                }
            },
            .motion => |motion| {
                if (this.focused_window) |window| {
                    if (window.on_event) |on_event| {
                        this.pointer_pos = [2]f32{ motion.surface_x.toFloat(f32), motion.surface_y.toFloat(f32) };
                        on_event(@ptrCast(window), seizer.Display.Window.Event{ .input = .{ .hover = .{
                            .pos = this.pointer_pos,
                            .modifiers = .{ .left = false, .right = false, .middle = false },
                        } } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                }
            },
            .button => |button| {
                if (this.focused_window) |window| {
                    if (window.on_event) |on_event| {
                        on_event(@ptrCast(window), seizer.Display.Window.Event{ .input = .{ .click = .{
                            .pos = this.pointer_pos,
                            .button = @enumFromInt(button.button),
                            .pressed = button.state == .pressed,
                        } } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                }
            },
            .axis => |axis| {
                switch (axis.axis) {
                    .horizontal_scroll => this.scroll_vector[0] += axis.value.toFloat(f32),
                    .vertical_scroll => this.scroll_vector[1] += axis.value.toFloat(f32),
                }
            },
            .frame => {
                if (this.focused_window) |window| {
                    if (window.on_event) |on_event| {
                        on_event(@ptrCast(window), seizer.Display.Window.Event{ .input = .{ .scroll = .{
                            .offset = this.scroll_vector,
                        } } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                }
                this.scroll_vector = .{ 0, 0 };
            },
            else => {},
        }
    }
};

const linux_dmabuf_v1 = @import("wayland-protocols").stable.@"linux-dmabuf-v1";
const xdg_shell = @import("wayland-protocols").stable.@"xdg-shell";
const wayland = @import("wayland");

const builtin = @import("builtin");
const xev = @import("xev");
const seizer = @import("../seizer.zig");
const std = @import("std");

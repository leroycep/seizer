const Wayland = @This();

allocator: std.mem.Allocator,

connection: shimizu.Connection,
connection_recv_completion: xev.Completion = undefined,

registry: shimizu.Object.WithInterface(wayland.wl_registry),
globals: Globals = .{},

xdg_wm_base_listener: shimizu.Listener = undefined,

// (wl_surface id, window)
windows: std.AutoArrayHashMapUnmanaged(shimizu.Object.WithInterface(wayland.wl_surface), *Window) = .{},
seats: std.ArrayListUnmanaged(*Seat) = .{},

pub const DISPLAY_INTERFACE = seizer.meta.interfaceFromConcreteTypeFns(seizer.Display.Interface, @This(), .{
    .name = "Wayland",
    .create = _create,
    .destroy = _destroy,
    .createWindow = _createWindow,
    .destroyWindow = _destroyWindow,

    .windowGetSize = _windowGetSize,
    .windowGetScale = _windowGetScale,
    .windowPresentBuffer = _windowPresentBuffer,
    .windowSetUserdata = _windowSetUserdata,
    .windowGetUserdata = _windowGetUserdata,

    .isCreateBufferFromDMA_BUF_Supported = _isCreateBufferFromDMA_BUF_Supported,
    .isCreateBufferFromOpaqueFdSupported = _isCreateBufferFromOpaqueFdSupported,

    .createBufferFromDMA_BUF = _createBufferFromDMA_BUF,
    .createBufferFromOpaqueFd = _createBufferFromOpaqueFd,

    .destroyBuffer = _destroyBuffer,
});

pub fn _create(allocator: std.mem.Allocator, loop: *xev.Loop) seizer.Display.CreateError!seizer.Display {
    // allocate this
    const this = try allocator.create(@This());
    errdefer allocator.destroy(this);
    this.* = .{
        .allocator = allocator,

        .connection = undefined,
        .registry = undefined,
    };

    // open connection to wayland server
    this.connection = shimizu.openConnection(allocator, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.DisplayNotFound,
        else => |e| std.debug.panic("Unexpected error: {}", .{e}),
    };
    errdefer this.connection.close();

    const display = this.connection.getDisplayProxy();
    const registry = display.sendRequest(.get_registry, .{}) catch |err| switch (err) {
        else => |e| std.debug.panic("Unexpected error: {}", .{e}),
    };
    this.registry = registry.id;
    registry.setEventListener(&this.globals.listener, onRegistryEvent, this);

    {
        var sync_is_done: bool = false;
        var wl_callback_listener: shimizu.Listener = undefined;
        const wl_callback = display.sendRequest(.sync, .{}) catch |err| switch (err) {
            else => |e| std.debug.panic("Unexpected error: {}", .{e}),
        };
        wl_callback.setEventListener(&wl_callback_listener, onWlCallbackSetTrue, &sync_is_done);
        while (!sync_is_done) {
            this.connection.recv() catch |err| switch (err) {
                else => |e| std.debug.panic("Unexpected error: {}", .{e}),
            };
        }
    }
    if (this.globals.wl_compositor == null) {
        log.warn("wayland: wl_compositor extension missing", .{});
        return error.ExtensionMissing;
    }
    if (this.globals.xdg_wm_base == null) {
        log.warn("wayland: xdg_wm_base extension missing", .{});
        return error.ExtensionMissing;
    }
    if (this.globals.zwp_linux_dmabuf_v1 == null and this.globals.wl_shm == null) {
        log.warn("wayland: zwp_linux_dmabuf_v1 extension missing", .{});
        log.warn("wayland: wl_shm extension missing", .{});
        return error.ExtensionMissing;
    }

    const xdg_wm_base = shimizu.Proxy(xdg_shell.xdg_wm_base){ .connection = &this.connection, .id = this.globals.xdg_wm_base.? };
    xdg_wm_base.setEventListener(&this.xdg_wm_base_listener, onXdgWmBaseEvent, null);

    this.connection_recv_completion = .{
        .op = .{ .recvmsg = .{
            .fd = this.connection.socket,
            .msghdr = this.connection.getRecvMsgHdr(),
        } },
        .callback = onConnectionRecvMessage,
    };
    loop.add(&this.connection_recv_completion);

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
        seat.destroy();
    }
    this.seats.deinit(this.allocator);

    this.connection.close();

    this.allocator.destroy(this);
}

fn onConnectionRecvMessage(userdata: ?*anyopaque, loop: *xev.Loop, completion: *xev.Completion, result: xev.Result) xev.CallbackAction {
    _ = userdata;
    _ = loop;
    const this: *@This() = @fieldParentPtr("connection_recv_completion", completion);
    if (result.recvmsg) |num_bytes_read| {
        this.connection.processRecvMsgReturn(num_bytes_read) catch |err| {
            log.warn("error processing messages from wayland: {}", .{err});
        };
        this.connection_recv_completion.op.recvmsg.msghdr = this.connection.getRecvMsgHdr();
        return .rearm;
    } else |err| {
        log.err("error receiving messages from wayland compositor: {}", .{err});
        return .disarm;
    }
}

fn onWlCallbackSetTrue(listener: *shimizu.Listener, wl_callback: shimizu.Proxy(wayland.wl_callback), event: wayland.wl_callback.Event) !void {
    _ = wl_callback;
    _ = event;

    const bool_ptr: *bool = @ptrCast(listener.userdata);
    bool_ptr.* = true;
}

const Globals = struct {
    listener: shimizu.Listener = undefined,

    wl_compositor: ?shimizu.Object.WithInterface(wayland.wl_compositor) = null,
    xdg_wm_base: ?shimizu.Object.WithInterface(xdg_shell.xdg_wm_base) = null,
    zwp_linux_dmabuf_v1: ?shimizu.Object.WithInterface(linux_dmabuf_v1.zwp_linux_dmabuf_v1) = null,
    wl_shm: ?shimizu.Object.WithInterface(wayland.wl_shm) = null,
    xdg_decoration_manager: ?shimizu.Object.WithInterface(xdg_decoration.zxdg_decoration_manager_v1) = null,

    wp_viewporter: ?shimizu.Object.WithInterface(viewporter.wp_viewporter) = null,
    wp_fractional_scale_manager_v1: ?shimizu.Object.WithInterface(fractional_scale_v1.wp_fractional_scale_manager_v1) = null,
};

fn onRegistryEvent(listener: *shimizu.Listener, registry: shimizu.Proxy(wayland.wl_registry), event: wayland.wl_registry.Event) !void {
    const globals: *Globals = @fieldParentPtr("listener", listener);
    const this: *@This() = @fieldParentPtr("globals", globals);

    switch (event) {
        .global => |global| {
            if (std.mem.eql(u8, global.interface, wayland.wl_seat.NAME) and global.version >= wayland.wl_seat.VERSION) {
                this.seats.ensureUnusedCapacity(this.allocator, 1) catch return;

                const seat = this.allocator.create(Seat) catch return;
                const wl_seat = try registry.connection.createObject(wayland.wl_seat);
                try registry.sendRequest(.bind, .{ .name = global.name, .id = wl_seat.id.asGenericNewId() });

                seat.* = .{
                    .wayland_manager = this,
                    .wl_seat = wl_seat,
                    .focused_window = null,
                };
                wl_seat.setEventListener(&seat.listener, Seat.onSeatCallback, seat);

                this.seats.appendAssumeCapacity(seat);
            } else inline for (@typeInfo(Globals).Struct.fields) |field| {
                if (@typeInfo(field.type) != .Optional) continue;
                const INTERFACE = @typeInfo(field.type).Optional.child._SPECIFIED_INTERFACE;

                if (std.mem.eql(u8, global.interface, INTERFACE.NAME) and global.version >= INTERFACE.VERSION) {
                    const object = try registry.connection.createObject(INTERFACE);
                    try registry.sendRequest(.bind, .{ .name = global.name, .id = object.id.asGenericNewId() });
                    @field(this.globals, field.name) = object.id;
                }
            } else {
                log.debug("unknown wayland global object: {}@{?s} version {}", .{ global.name, global.interface, global.version });
            }
        },
        .global_remove => {},
    }
}

fn onXdgWmBaseEvent(listener: *shimizu.Listener, xdg_wm_base: shimizu.Proxy(xdg_shell.xdg_wm_base), event: xdg_shell.xdg_wm_base.Event) !void {
    _ = listener;
    switch (event) {
        .ping => |conf| {
            try xdg_wm_base.sendRequest(.pong, .{ .serial = conf.serial });
        },
    }
}

fn _createWindow(this: *@This(), options: seizer.Display.Window.CreateOptions) seizer.Display.Window.CreateError!*seizer.Display.Window {
    try this.windows.ensureUnusedCapacity(this.allocator, 1);

    const size = [2]c_int{ @intCast(options.size[0]), @intCast(options.size[1]) };

    const wl_surface = this.connection.sendRequest(wayland.wl_compositor, this.globals.wl_compositor.?, .create_surface, .{}) catch return error.ConnectionLost;
    const xdg_surface = this.connection.sendRequest(xdg_shell.xdg_wm_base, this.globals.xdg_wm_base.?, .get_xdg_surface, .{ .surface = wl_surface.id }) catch return error.ConnectionLost;
    const xdg_toplevel = xdg_surface.sendRequest(.get_toplevel, .{}) catch return error.ConnectionLost;

    const xdg_toplevel_decoration: ?shimizu.Proxy(xdg_decoration.zxdg_toplevel_decoration_v1) = if (this.globals.xdg_decoration_manager) |deco_man|
        this.connection.sendRequest(xdg_decoration.zxdg_decoration_manager_v1, deco_man, .get_toplevel_decoration, .{ .toplevel = xdg_toplevel.id }) catch return error.ConnectionLost
    else
        null;

    const wp_viewport: ?shimizu.Proxy(viewporter.wp_viewport) = if (this.globals.wp_viewporter) |wp_viewporter|
        this.connection.sendRequest(viewporter.wp_viewporter, wp_viewporter, .get_viewport, .{ .surface = wl_surface.id }) catch return error.ConnectionLost
    else
        null;

    const wp_fractional_scale: ?shimizu.Proxy(fractional_scale_v1.wp_fractional_scale_v1) = if (this.globals.wp_fractional_scale_manager_v1) |scale_man|
        this.connection.sendRequest(fractional_scale_v1.wp_fractional_scale_manager_v1, scale_man, .get_fractional_scale, .{ .surface = wl_surface.id }) catch return error.ConnectionLost
    else
        null;

    wl_surface.sendRequest(.commit, .{}) catch return error.ConnectionLost;

    const window = try this.allocator.create(Window);
    errdefer this.allocator.destroy(window);

    window.* = .{
        .wayland = this,

        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .xdg_toplevel_decoration = xdg_toplevel_decoration,
        .wp_viewport = wp_viewport,
        .wp_fractional_scale = wp_fractional_scale,

        .on_event = options.on_event,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,

        .current_configuration = .{
            .window_size = .{ 0, 0 },
            .decoration_mode = .client_side,
        },
        .new_configuration = .{
            .window_size = size,
            .decoration_mode = .client_side,
        },
    };

    window.xdg_surface.setEventListener(&window.xdg_surface_listener, Window.onXdgSurfaceEvent, null);
    window.xdg_toplevel.setEventListener(&window.xdg_toplevel_listener, Window.onXdgToplevelEvent, null);

    if (window.xdg_toplevel_decoration) |decoration| {
        decoration.setEventListener(&window.xdg_toplevel_decoration_listener, Window.onXdgToplevelDecorationEvent, null);
    }
    if (window.wp_fractional_scale) |frac_scale| {
        frac_scale.setEventListener(&window.wp_fractional_scale_listener, Window.onWpFractionalScale, null);
    }

    window.xdg_toplevel.sendRequest(.set_title, .{ .title = options.title }) catch return error.ConnectionLost;
    if (options.app_name) |app_name| {
        window.xdg_toplevel.sendRequest(.set_app_id, .{ .app_id = app_name }) catch return error.ConnectionLost;
    }

    this.windows.putAssumeCapacity(window.wl_surface.id, window);

    return @ptrCast(window);
}

fn _destroyWindow(this: *@This(), window_opaque: *seizer.Display.Window) void {
    const window: *Window = @ptrCast(@alignCast(window_opaque));

    if (window.on_destroy) |on_destroy| {
        on_destroy(@ptrCast(window));
    }

    // hide window
    window.wl_surface.sendRequest(.attach, .{ .buffer = @enumFromInt(0), .x = 0, .y = 0 }) catch {};
    window.wl_surface.sendRequest(.commit, .{}) catch {};

    // destroy surfaces
    if (window.xdg_toplevel_decoration) |decoration| decoration.sendRequest(.destroy, .{}) catch {};
    window.xdg_toplevel.sendRequest(.destroy, .{}) catch {};
    window.xdg_surface.sendRequest(.destroy, .{}) catch {};
    window.wl_surface.sendRequest(.destroy, .{}) catch {};

    // TODO: remove window listeners from types
    // window.xdg_toplevel.userdata = null;
    // window.xdg_surface.userdata = null;
    // window.wl_surface.userdata = null;

    // window.xdg_toplevel.on_event = null;
    // window.xdg_surface.on_event = null;
    // window.wl_surface.on_event = null;

    // if (window.frame_callback) |frame_callback| {
    //     frame_callback.userdata = null;
    //     frame_callback.on_event = null;
    // }

    for (this.seats.items) |seat| {
        if (seat.focused_window) |focused_window| {
            if (focused_window == window) {
                seat.focused_window = null;
                break;
            }
        }
    }

    this.allocator.destroy(window);
}

fn _windowGetSize(this: *@This(), window_opaque: *seizer.Display.Window) [2]f32 {
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    _ = this;

    return [2]f32{
        @floatFromInt(window.current_configuration.window_size[0]),
        @floatFromInt(window.current_configuration.window_size[1]),
    };
}

fn _windowGetScale(this: *@This(), window_opaque: *seizer.Display.Window) f32 {
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    _ = this;

    return @as(f32, @floatFromInt(window.preferred_scale)) / 120.0;
}

fn _windowSetUserdata(this: *@This(), window_opaque: *seizer.Display.Window, userdata: ?*anyopaque) void {
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    _ = this;

    window.userdata = userdata;
}

fn _windowGetUserdata(this: *@This(), window_opaque: *seizer.Display.Window) ?*anyopaque {
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    _ = this;

    return window.userdata;
}

fn _windowPresentBuffer(this: *@This(), window_opaque: *seizer.Display.Window, buffer_opaque: *seizer.Display.Buffer) seizer.Display.Window.PresentError!void {
    _ = this;
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    window.setupFrameCallback() catch return error.ConnectionLost;

    window.wl_surface.sendRequest(.attach, .{ .buffer = buffer.wl_buffer.id, .x = 0, .y = 0 }) catch return error.ConnectionLost;
    window.wl_surface.sendRequest(.damage_buffer, .{
        .x = 0,
        .y = 0,
        .width = @intCast(buffer.size[0]),
        .height = @intCast(buffer.size[1]),
    }) catch return error.ConnectionLost;
    if (window.wp_viewport) |viewport| {
        viewport.sendRequest(.set_source, .{
            .x = shimizu.Fixed.fromFloat(f32, 0),
            .y = shimizu.Fixed.fromFloat(f32, 0),
            .width = shimizu.Fixed.fromInt(@intCast(buffer.size[0]), 0),
            .height = shimizu.Fixed.fromInt(@intCast(buffer.size[1]), 0),
        }) catch return error.ConnectionLost;
        viewport.sendRequest(.set_destination, .{
            .width = @intFromFloat(@as(f32, @floatFromInt(buffer.size[0])) * buffer.scale),
            .height = @intFromFloat(@as(f32, @floatFromInt(buffer.size[1])) * buffer.scale),
        }) catch return error.ConnectionLost;
    }
    window.wl_surface.sendRequest(.commit, .{}) catch return error.ConnectionLost;
}

const Buffer = struct {
    allocator: std.mem.Allocator,
    size: [2]u32,
    scale: f32,
    wl_buffer: shimizu.Proxy(wayland.wl_buffer),
    listener: shimizu.Listener,
    delete_listener: shimizu.DeleteListener,
    userdata: ?*anyopaque,
    on_release: ?*const fn (?*anyopaque, *seizer.Display.Buffer) void,

    fn onWlBufferDelete(connection: *shimizu.Connection, object: shimizu.Object, object_info: shimizu.ObjectInfo) void {
        _ = connection;
        _ = object;
        const this: *@This() = @fieldParentPtr("delete_listener", object_info.delete_listener.?);
        this.allocator.destroy(this);
    }

    fn onWlBufferEvent(listener: *shimizu.Listener, wl_buffer: shimizu.Proxy(wayland.wl_buffer), event: wayland.wl_buffer.Event) !void {
        const this: *@This() = @fieldParentPtr("listener", listener);
        _ = wl_buffer;
        switch (event) {
            .release => if (this.on_release) |on_release| {
                on_release(this.userdata, @ptrCast(this));
            },
        }
    }
};

fn _isCreateBufferFromDMA_BUF_Supported(this: *@This()) bool {
    return this.globals.zwp_linux_dmabuf_v1 != null;
}
fn _isCreateBufferFromOpaqueFdSupported(this: *@This()) bool {
    return this.globals.wl_shm != null;
}

fn _createBufferFromDMA_BUF(this: *@This(), options: seizer.Display.Buffer.CreateOptionsDMA_BUF) seizer.Display.Buffer.CreateError!*seizer.Display.Buffer {
    const wl_dmabuf_buffer_params = this.connection.sendRequest(
        linux_dmabuf_v1.zwp_linux_dmabuf_v1,
        this.globals.zwp_linux_dmabuf_v1.?,
        .create_params,
        .{},
    ) catch return error.ConnectionLost;
    defer wl_dmabuf_buffer_params.sendRequest(.destroy, .{}) catch {};

    for (options.planes) |plane| {
        wl_dmabuf_buffer_params.sendRequest(.add, .{
            .fd = @enumFromInt(plane.fd),
            .plane_idx = @intCast(plane.index),
            .offset = @intCast(plane.offset),
            .stride = @intCast(plane.stride),
            .modifier_hi = @intCast((options.format.modifiers >> 32) & 0xFFFF_FFFF),
            .modifier_lo = @intCast((options.format.modifiers) & 0xFFFF_FFFF),
        }) catch return error.ConnectionLost;
    }

    const wl_buffer = wl_dmabuf_buffer_params.sendRequest(.create_immed, .{
        .width = @intCast(options.size[0]),
        .height = @intCast(options.size[1]),
        .format = @intFromEnum(options.format.fourcc),
        .flags = .{ .y_invert = false, .interlaced = false, .bottom_first = false },
    }) catch return error.ConnectionLost;
    const buffer = try this.allocator.create(Buffer);
    buffer.* = .{
        .allocator = this.allocator,
        .size = options.size,
        .scale = options.scale,
        .wl_buffer = wl_buffer,
        .listener = undefined,
        .delete_listener = .{ .callback = Buffer.onWlBufferDelete },
        .userdata = options.userdata,
        .on_release = options.on_release,
    };

    wl_buffer.setEventListener(&buffer.listener, Buffer.onWlBufferEvent, null);
    const wl_buffer_info = wl_buffer.connection.objects.getPtr(wl_buffer.id.asObject()).?;
    wl_buffer_info.delete_listener = &buffer.delete_listener;

    return @ptrCast(buffer);
}

fn _createBufferFromOpaqueFd(this: *@This(), options: seizer.Display.Buffer.CreateOptionsOpaqueFd) seizer.Display.Buffer.CreateError!*seizer.Display.Buffer {
    log.debug("creating opaque fd display buffer", .{});
    const size: i32 = @intCast(options.pool_size);
    const wl_shm_pool = this.connection.sendRequest(wayland.wl_shm, this.globals.wl_shm.?, .create_pool, .{ .fd = @enumFromInt(options.fd), .size = size }) catch return error.ConnectionLost;

    const wl_buffer = wl_shm_pool.sendRequest(.create_buffer, .{
        .offset = @intCast(options.offset),
        .width = @intCast(options.size[0]),
        .height = @intCast(options.size[1]),
        .stride = @intCast(options.stride),
        .format = switch (options.format) {
            .ARGB8888 => .argb8888,
            else => @enumFromInt(@intFromEnum(options.format)),
        },
    }) catch return error.ConnectionLost;

    const buffer = try this.allocator.create(Buffer);
    buffer.* = .{
        .allocator = this.allocator,
        .size = options.size,
        .scale = options.scale,
        .wl_buffer = wl_buffer,
        .listener = undefined,
        .delete_listener = .{ .callback = Buffer.onWlBufferDelete },
        .userdata = options.userdata,
        .on_release = options.on_release,
    };

    wl_buffer.setEventListener(&buffer.listener, Buffer.onWlBufferEvent, null);
    const wl_buffer_info = wl_buffer.connection.objects.getPtr(wl_buffer.id.asObject()).?;
    wl_buffer_info.delete_listener = &buffer.delete_listener;

    return @ptrCast(buffer);
}

fn _destroyBuffer(this: *@This(), buffer_opaque: *seizer.Display.Buffer) void {
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));
    _ = this;

    // tell the wayland server to destroy this buffer.
    // We wait until the server tells us it is deleted to destroy the memory on our side.
    // (See Buffer.onWlDelete)
    buffer.wl_buffer.sendRequest(.destroy, .{}) catch unreachable;
    buffer.userdata = null;
    buffer.on_release = null;
}

const Window = struct {
    wayland: *Wayland,

    wl_surface: shimizu.Proxy(wayland.wl_surface),
    xdg_surface: shimizu.Proxy(xdg_shell.xdg_surface),
    xdg_toplevel: shimizu.Proxy(xdg_shell.xdg_toplevel),
    xdg_toplevel_decoration: ?shimizu.Proxy(xdg_decoration.zxdg_toplevel_decoration_v1),
    wp_viewport: ?shimizu.Proxy(viewporter.wp_viewport),
    wp_fractional_scale: ?shimizu.Proxy(fractional_scale_v1.wp_fractional_scale_v1),

    xdg_surface_listener: shimizu.Listener = undefined,
    xdg_toplevel_listener: shimizu.Listener = undefined,
    xdg_toplevel_decoration_listener: shimizu.Listener = undefined,
    wp_fractional_scale_listener: shimizu.Listener = undefined,

    on_event: ?*const fn (*seizer.Display.Window, seizer.Display.Window.Event) anyerror!void,
    on_render: *const fn (*seizer.Display.Window) anyerror!void,
    on_destroy: ?*const fn (*seizer.Display.Window) void,

    frame_callback: ?shimizu.Proxy(wayland.wl_callback) = null,
    frame_callback_listener: shimizu.Listener = undefined,

    new_configuration: Configuration,
    current_configuration: Configuration,

    preferred_scale: u32 = 120,

    userdata: ?*anyopaque = null,

    const Configuration = struct {
        window_size: [2]c_int,
        decoration_mode: xdg_decoration.zxdg_toplevel_decoration_v1.Mode,
    };

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }

    fn onXdgSurfaceEvent(listener: *shimizu.Listener, xdg_surface: shimizu.Proxy(xdg_shell.xdg_surface), event: xdg_shell.xdg_surface.Event) !void {
        const this: *@This() = @fieldParentPtr("xdg_surface_listener", listener);
        switch (event) {
            .configure => |conf| {
                if (this.xdg_toplevel_decoration) |decoration| {
                    if (this.current_configuration.decoration_mode != this.new_configuration.decoration_mode) {
                        try decoration.sendRequest(.set_mode, .{ .mode = this.new_configuration.decoration_mode });
                        this.current_configuration.decoration_mode = this.new_configuration.decoration_mode;
                    }
                }

                if (!std.mem.eql(c_int, &this.current_configuration.window_size, &this.new_configuration.window_size)) {
                    this.current_configuration.window_size = this.new_configuration.window_size;
                    if (this.on_event) |on_event| {
                        on_event(@ptrCast(this), .{ .resize = [2]f32{
                            @floatFromInt(this.current_configuration.window_size[0]),
                            @floatFromInt(this.current_configuration.window_size[1]),
                        } }) catch |err| {
                            std.debug.print("error returned from window event: {}\n", .{err});
                            if (@errorReturnTrace()) |err_ret_trace| {
                                std.debug.dumpStackTrace(err_ret_trace.*);
                            }
                        };
                    }
                }

                try xdg_surface.sendRequest(.ack_configure, .{ .serial = conf.serial });

                if (this.frame_callback == null) {
                    this.frame_callback = try this.wayland.connection.getDisplayProxy().sendRequest(.sync, .{});
                    this.frame_callback.?.setEventListener(&this.frame_callback_listener, Window.onFrameCallback, null);
                }
            },
        }
    }

    fn onXdgToplevelEvent(listener: *shimizu.Listener, xdg_toplevel: shimizu.Proxy(xdg_shell.xdg_toplevel), event: xdg_shell.xdg_toplevel.Event) !void {
        const this: *@This() = @fieldParentPtr("xdg_toplevel_listener", listener);
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
                    this.new_configuration.window_size[0] = cfg.width;
                    this.new_configuration.window_size[1] = cfg.height;
                }
            },
            else => {},
        }
    }

    fn onXdgToplevelDecorationEvent(listener: *shimizu.Listener, xdg_toplevel_decoration: shimizu.Proxy(xdg_decoration.zxdg_toplevel_decoration_v1), event: xdg_decoration.zxdg_toplevel_decoration_v1.Event) !void {
        const this: *@This() = @fieldParentPtr("xdg_toplevel_decoration_listener", listener);
        _ = xdg_toplevel_decoration;
        switch (event) {
            .configure => |cfg| {
                if (cfg.mode == .server_side) {
                    this.new_configuration.decoration_mode = .server_side;
                }
            },
        }
    }

    fn onWpFractionalScale(listener: *shimizu.Listener, wp_fractional_scale: shimizu.Proxy(fractional_scale_v1.wp_fractional_scale_v1), event: fractional_scale_v1.wp_fractional_scale_v1.Event) !void {
        const this: *@This() = @fieldParentPtr("wp_fractional_scale_listener", listener);
        _ = wp_fractional_scale;
        switch (event) {
            .preferred_scale => |preferred| {
                this.preferred_scale = preferred.scale;
                if (this.on_event) |on_event| {
                    on_event(@ptrCast(this), .{ .rescale = @as(f32, @floatFromInt(this.preferred_scale)) / 120.0 }) catch |err| {
                        std.debug.print("error returned from window event: {}\n", .{err});
                        if (@errorReturnTrace()) |err_ret_trace| {
                            std.debug.dumpStackTrace(err_ret_trace.*);
                        }
                    };
                }
            },
        }
    }

    fn setupFrameCallback(this: *@This()) !void {
        if (this.frame_callback != null) return;
        this.frame_callback = try this.wl_surface.sendRequest(.frame, .{});
        this.frame_callback.?.setEventListener(&this.frame_callback_listener, onFrameCallback, this);
    }

    fn onFrameCallback(listener: *shimizu.Listener, callback: shimizu.Proxy(wayland.wl_callback), event: wayland.wl_callback.Event) !void {
        const this: *@This() = @fieldParentPtr("frame_callback_listener", listener);
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
            },
        }
    }
};

const Seat = struct {
    wayland_manager: *Wayland,
    wl_seat: shimizu.Proxy(wayland.wl_seat),
    wl_pointer: ?shimizu.Proxy(wayland.wl_pointer) = null,
    wl_keyboard: ?shimizu.Proxy(wayland.wl_keyboard) = null,

    listener: shimizu.Listener = undefined,

    focused_window: ?*Window,
    pointer_pos: [2]f32 = .{ 0, 0 },
    scroll_vector: [2]f32 = .{ 0, 0 },
    cursor_wl_surface: ?shimizu.Proxy(wayland.wl_surface) = null,
    wp_viewport: ?shimizu.Proxy(viewporter.wp_viewport) = null,

    pointer_listener: shimizu.Listener = undefined,
    pointer_serial: u32 = 0,
    cursor_fractional_scale: ?shimizu.Proxy(fractional_scale_v1.wp_fractional_scale_v1) = null,
    cursor_fractional_scale_listener: shimizu.Listener = undefined,
    pointer_scale: u32 = 120,

    keyboard_listener: shimizu.Listener = undefined,
    keymap: ?xkb.Keymap = null,
    keymap_state: xkb.Keymap.State = undefined,
    keyboard_repeat_rate: u32 = 0,
    keyboard_repeat_delay: u32 = 0,

    fn destroy(this: *@This()) void {
        if (this.keymap) |*keymap| keymap.deinit();
        this.wayland_manager.allocator.destroy(this);
    }

    fn onSeatCallback(listener: *shimizu.Listener, wl_seat: shimizu.Proxy(wayland.wl_seat), event: wayland.wl_seat.Event) !void {
        const this: *Seat = @fieldParentPtr("listener", listener);
        _ = wl_seat;
        switch (event) {
            .capabilities => |capabilities| {
                if (capabilities.capabilities.keyboard) {
                    if (this.wl_keyboard == null) {
                        this.wl_keyboard = try this.wl_seat.sendRequest(.get_keyboard, .{});
                        this.wl_keyboard.?.setEventListener(&this.keyboard_listener, Seat.onKeyboardCallback, this);
                    }
                } else {
                    if (this.wl_keyboard) |keyboard| {
                        try keyboard.sendRequest(.release, .{});
                        this.wl_keyboard = null;
                    }
                }

                if (capabilities.capabilities.pointer) {
                    if (this.wl_pointer == null) {
                        this.wl_pointer = try this.wl_seat.sendRequest(.get_pointer, .{});
                        this.wl_pointer.?.setEventListener(&this.pointer_listener, Seat.onPointerCallback, null);
                    }
                    if (this.cursor_wl_surface == null) {
                        this.cursor_wl_surface = try this.wayland_manager.connection.sendRequest(wayland.wl_compositor, this.wayland_manager.globals.wl_compositor.?, .create_surface, .{});

                        if (this.wayland_manager.globals.wp_viewporter) |wp_viewporter| {
                            this.wp_viewport = try this.wayland_manager.connection.sendRequest(viewporter.wp_viewporter, wp_viewporter, .get_viewport, .{ .surface = this.cursor_wl_surface.?.id });
                        }

                        if (this.wayland_manager.globals.wp_fractional_scale_manager_v1) |scale_man| {
                            this.cursor_fractional_scale = try this.wayland_manager.connection.sendRequest(fractional_scale_v1.wp_fractional_scale_manager_v1, scale_man, .get_fractional_scale, .{ .surface = this.cursor_wl_surface.?.id });
                            // this.cursor_fractional_scale.?.userdata = this;
                            // this.cursor_fractional_scale.?.on_event = onCursorFractionalScaleEvent;
                        }
                    }
                } else {
                    if (this.wl_pointer) |pointer| {
                        pointer.sendRequest(.release, .{}) catch {};
                        this.wl_pointer = null;
                    }
                    if (this.wp_viewport) |wp_viewport| {
                        wp_viewport.sendRequest(.destroy, .{}) catch {};
                        this.wp_viewport = null;
                    }
                    if (this.cursor_fractional_scale) |frac_scale| {
                        frac_scale.sendRequest(.destroy, .{}) catch {};
                        this.cursor_fractional_scale = null;
                    }
                    if (this.cursor_wl_surface) |surface| {
                        surface.sendRequest(.destroy, .{}) catch {};
                        this.cursor_wl_surface = null;
                    }
                }
            },
            .name => {},
        }
    }

    fn onKeyboardCallback(listener: *shimizu.Listener, wl_keyboard: shimizu.Proxy(wayland.wl_keyboard), event: wayland.wl_keyboard.Event) !void {
        const this: *@This() = @fieldParentPtr("keyboard_listener", listener);
        _ = wl_keyboard;
        switch (event) {
            .keymap => |keymap_info| {
                defer std.posix.close(@intCast(@intFromEnum(keymap_info.fd)));
                if (keymap_info.format != .xkb_v1) return;

                const new_keymap_source = std.posix.mmap(null, keymap_info.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, @intFromEnum(keymap_info.fd), 0) catch |err| {
                    log.warn("Failed to mmap keymap from wayland compositor: {}", .{err});
                    return;
                };
                defer std.posix.munmap(new_keymap_source);

                if (this.keymap) |*old_keymap| {
                    old_keymap.deinit();
                    this.keymap = null;
                }
                this.keymap = xkb.Keymap.fromString(this.wayland_manager.allocator, new_keymap_source) catch |err| {
                    log.warn("failed to parse keymap: {}", .{err});
                    if (@errorReturnTrace()) |trace| std.debug.dumpStackTrace(trace.*);
                    return;
                };
            },
            .repeat_info => |repeat_info| {
                this.keyboard_repeat_rate = @intCast(repeat_info.rate);
                this.keyboard_repeat_delay = @intCast(repeat_info.delay);
            },
            .modifiers => |m| {
                this.keymap_state = xkb.Keymap.State{
                    .base_modifiers = @bitCast(m.mods_depressed),
                    .latched_modifiers = @bitCast(m.mods_latched),
                    .locked_modifiers = @bitCast(m.mods_locked),
                    .group = @intCast(m.group),
                };
            },
            .key => |k| if (this.keymap) |keymap| {
                const scancode = evdevToSeizer(k.key);
                const symbol = keymap.getSymbol(@enumFromInt(k.key + 8), this.keymap_state) orelse return;
                const key = xkbSymbolToSeizerKey(symbol);
                const xkb_modifiers = this.keymap_state.getModifiers();

                if (this.focused_window) |window| {
                    if (window.on_event) |on_event| {
                        on_event(@ptrCast(window), .{ .input = seizer.input.Event{ .key = .{
                            .key = key,
                            .scancode = scancode,
                            .action = switch (k.state) {
                                .pressed => .press,
                                .released => .release,
                            },
                            .mods = .{
                                .shift = xkb_modifiers.shift,
                                .caps_lock = xkb_modifiers.lock,
                                .control = xkb_modifiers.control,
                            },
                        } } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                }

                if (this.focused_window) |window| {
                    if (window.on_event) |on_event| {
                        if (symbol.character) |character| {
                            if (k.state == .pressed) {
                                var text_utf8 = std.BoundedArray(u8, 16){};
                                text_utf8.resize(std.unicode.utf8CodepointSequenceLength(character) catch unreachable) catch unreachable;
                                _ = std.unicode.utf8Encode(character, text_utf8.slice()) catch unreachable;

                                on_event(@ptrCast(window), .{ .input = seizer.input.Event{ .text = .{
                                    .text = text_utf8,
                                } } }) catch |err| {
                                    std.debug.print("{s}\n", .{@errorName(err)});
                                    if (@errorReturnTrace()) |trace| {
                                        std.debug.dumpStackTrace(trace.*);
                                    }
                                };
                            }
                        }
                    }
                }
            },
            else => {},
        }
    }

    fn onPointerCallback(listener: *shimizu.Listener, pointer: shimizu.Proxy(wayland.wl_pointer), event: wayland.wl_pointer.Event) !void {
        const this: *@This() = @fieldParentPtr("pointer_listener", listener);
        _ = pointer;
        switch (event) {
            .enter => |enter| {
                this.focused_window = this.wayland_manager.windows.get(enter.surface);
                this.pointer_serial = enter.serial;
                this.updateCursorImage() catch {};
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
                // },
                // .frame => {
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

    fn onCursorFractionalScaleEvent(wp_fractional_scale: *fractional_scale_v1.wp_fractional_scale_v1, userdata: ?*anyopaque, event: fractional_scale_v1.wp_fractional_scale_v1.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = wp_fractional_scale;
        switch (event) {
            .preferred_scale => |preferred| {
                this.pointer_scale = preferred.scale;
                this.updateCursorImage() catch {};
            },
        }
    }

    fn updateCursorImage(this: *@This()) !void {
        if (!this.wayland_manager._isCreateBufferFromOpaqueFdSupported()) return;

        const width_hint: seizer.tvg.rendering.SizeHint = if (this.wp_viewport != null) .{ .width = (32 * this.pointer_scale) / 120 } else .inherit;
        // set cursor image
        var default_cursor_image = try seizer.tvg.rendering.renderBuffer(
            seizer.platform.allocator(),
            seizer.platform.allocator(),
            width_hint,
            .x16,
            @embedFile("./cursor_none.tvg"),
        );
        defer default_cursor_image.deinit(seizer.platform.allocator());

        const pixel_bytes = std.mem.sliceAsBytes(default_cursor_image.pixels);

        const default_cursor_image_fd = try std.posix.memfd_create("default_cursor", 0);
        defer std.posix.close(default_cursor_image_fd);

        try std.posix.ftruncate(default_cursor_image_fd, pixel_bytes.len);

        const fd_bytes = std.posix.mmap(null, @intCast(pixel_bytes.len), std.posix.PROT.WRITE | std.posix.PROT.READ, .{ .TYPE = .SHARED }, default_cursor_image_fd, 0) catch @panic("could not mmap cursor fd");
        defer std.posix.munmap(fd_bytes);

        @memcpy(fd_bytes, pixel_bytes);

        const wl_shm_pool = this.wayland_manager.connection.sendRequest(
            wayland.wl_shm,
            this.wayland_manager.globals.wl_shm.?,
            .create_pool,
            .{
                .fd = @enumFromInt(default_cursor_image_fd),
                .size = @intCast(pixel_bytes.len),
            },
        ) catch return error.ConnectionLost;
        defer wl_shm_pool.sendRequest(.destroy, .{}) catch {};

        const cursor_buffer = try wl_shm_pool.sendRequest(.create_buffer, .{
            .offset = 0,
            .width = @intCast(default_cursor_image.width),
            .height = @intCast(default_cursor_image.height),
            .stride = @intCast(default_cursor_image.width * @sizeOf(seizer.tvg.rendering.Color8)),
            .format = .argb8888,
        });

        const surface = this.cursor_wl_surface orelse return;

        try surface.sendRequest(.attach, .{ .buffer = cursor_buffer.id, .x = 0, .y = 0 });
        try surface.sendRequest(.damage_buffer, .{ .x = 0, .y = 0, .width = std.math.maxInt(i32), .height = std.math.maxInt(i32) });
        if (this.wp_viewport) |viewport| {
            try viewport.sendRequest(.set_source, .{
                .x = shimizu.Fixed.fromInt(0, 0),
                .y = shimizu.Fixed.fromInt(0, 0),
                .width = shimizu.Fixed.fromInt(@intCast(default_cursor_image.width), 0),
                .height = shimizu.Fixed.fromInt(@intCast(default_cursor_image.height), 0),
            });
            try viewport.sendRequest(.set_destination, .{
                .width = 32,
                .height = 32,
            });
        }
        try surface.sendRequest(.commit, .{});
        try this.wl_pointer.?.sendRequest(.set_cursor, .{
            .serial = this.pointer_serial,
            .surface = this.cursor_wl_surface.?.id,
            .hotspot_x = 9,
            .hotspot_y = 5,
        });
    }
};

const evdevToSeizer = @import("./Wayland/evdev_to_seizer.zig").evdevToSeizer;
const xkbSymbolToSeizerKey = @import("./Wayland/xkb_to_seizer.zig").xkbSymbolToSeizerKey;

const wayland = shimizu.core;

// stable protocols
const viewporter = @import("wayland-protocols").viewporter;
const linux_dmabuf_v1 = @import("wayland-protocols").linux_dmabuf_v1;
const xdg_shell = @import("wayland-protocols").xdg_shell;

// unstable protocols
const xdg_decoration = @import("wayland-unstable").xdg_decoration_unstable_v1;
const fractional_scale_v1 = @import("wayland-unstable").fractional_scale_v1;

const log = std.log.scoped(.seizer);

const shimizu = @import("shimizu");
const builtin = @import("builtin");
const xkb = @import("xkb");
const xev = @import("xev");
const seizer = @import("../seizer.zig");
const std = @import("std");

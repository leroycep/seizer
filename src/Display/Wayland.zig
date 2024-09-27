const Wayland = @This();

allocator: std.mem.Allocator,

connection: wayland.Conn,
registry: *wayland.wayland.wl_registry,
globals: Globals = .{},

// (wl_surface id, window)
windows: std.AutoArrayHashMapUnmanaged(u32, *Window) = .{},
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
    if (this.globals.zwp_linux_dmabuf_v1 == null and this.globals.wl_shm == null) {
        std.log.scoped(.seizer).warn("wayland: zwp_linux_dmabuf_v1 extension missing", .{});
        std.log.scoped(.seizer).warn("wayland: wl_shm extension missing", .{});
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
        seat.destroy();
    }
    this.seats.deinit(this.allocator);

    this.connection.deinit();

    this.allocator.destroy(this);
}

const Globals = struct {
    wl_compositor: ?*wayland.wayland.wl_compositor = null,
    xdg_wm_base: ?*xdg_shell.xdg_wm_base = null,
    zwp_linux_dmabuf_v1: ?*linux_dmabuf_v1.zwp_linux_dmabuf_v1 = null,
    wl_shm: ?*wayland.wayland.wl_shm = null,
    xdg_decoration_manager: ?*xdg_decoration.zxdg_decoration_manager_v1 = null,

    wp_viewporter: ?*viewporter.wp_viewporter = null,
    wp_fractional_scale_manager_v1: ?*fractional_scale_v1.wp_fractional_scale_manager_v1 = null,
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
            } else if (std.mem.eql(u8, global_interface, wayland.wayland.wl_shm.INTERFACE.name) and global.version >= wayland.wayland.wl_shm.INTERFACE.version) {
                this.globals.wl_shm = registry.bind(wayland.wayland.wl_shm, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, xdg_decoration.zxdg_decoration_manager_v1.INTERFACE.name) and global.version >= xdg_decoration.zxdg_decoration_manager_v1.INTERFACE.version) {
                this.globals.xdg_decoration_manager = registry.bind(xdg_decoration.zxdg_decoration_manager_v1, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, viewporter.wp_viewporter.INTERFACE.name) and global.version >= viewporter.wp_viewporter.INTERFACE.version) {
                this.globals.wp_viewporter = registry.bind(viewporter.wp_viewporter, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, fractional_scale_v1.wp_fractional_scale_manager_v1.INTERFACE.name) and global.version >= fractional_scale_v1.wp_fractional_scale_manager_v1.INTERFACE.version) {
                this.globals.wp_fractional_scale_manager_v1 = registry.bind(fractional_scale_v1.wp_fractional_scale_manager_v1, global.name) catch return;
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
            } else {
                std.log.debug("unknown wayland global object: {}@{?s} version {}", .{ global.name, global.interface, global.version });
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
    const xdg_toplevel_decoration: ?*xdg_decoration.zxdg_toplevel_decoration_v1 = if (this.globals.xdg_decoration_manager) |deco_man|
        try deco_man.get_toplevel_decoration(xdg_toplevel)
    else
        null;

    const wp_viewport: ?*viewporter.wp_viewport = if (this.globals.wp_viewporter) |wp_viewporter|
        try wp_viewporter.get_viewport(wl_surface)
    else
        null;

    const wp_fractional_scale: ?*fractional_scale_v1.wp_fractional_scale_v1 = if (this.globals.wp_fractional_scale_manager_v1) |scale_man|
        try scale_man.get_fractional_scale(wl_surface)
    else
        null;

    try wl_surface.commit();

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

    window.xdg_surface.userdata = window;
    window.xdg_toplevel.userdata = window;
    window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
    window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;

    if (window.xdg_toplevel_decoration) |decoration| {
        decoration.userdata = window;
        decoration.on_event = Window.onXdgToplevelDecorationEvent;
    }
    if (window.wp_fractional_scale) |frac_scale| {
        frac_scale.userdata = window;
        frac_scale.on_event = Window.onWpFractionalScale;
    }

    try window.xdg_toplevel.set_title(options.title);
    if (options.app_name) |app_name| {
        try window.xdg_toplevel.set_app_id(app_name);
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
    window.wl_surface.attach(null, 0, 0) catch {};
    window.wl_surface.commit() catch {};

    // destroy surfaces
    if (window.xdg_toplevel_decoration) |decoration| decoration.destroy() catch {};
    window.xdg_toplevel.destroy() catch {};
    window.xdg_surface.destroy() catch {};
    window.wl_surface.destroy() catch {};

    window.xdg_toplevel.userdata = null;
    window.xdg_surface.userdata = null;
    window.wl_surface.userdata = null;

    window.xdg_toplevel.on_event = null;
    window.xdg_surface.on_event = null;
    window.wl_surface.on_event = null;

    if (window.frame_callback) |frame_callback| {
        frame_callback.userdata = null;
        frame_callback.on_event = null;
    }

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

fn _windowPresentBuffer(this: *@This(), window_opaque: *seizer.Display.Window, buffer_opaque: *seizer.Display.Buffer) !void {
    _ = this;
    const window: *Window = @ptrCast(@alignCast(window_opaque));
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));

    try window.setupFrameCallback();

    try window.wl_surface.attach(buffer.wl_buffer, 0, 0);
    try window.wl_surface.damage_buffer(0, 0, @intCast(buffer.size[0]), @intCast(buffer.size[1]));
    if (window.wp_viewport) |viewport| {
        try viewport.set_source(
            wayland.fixed.fromFloat(f32, 0),
            wayland.fixed.fromFloat(f32, 0),
            wayland.fixed.fromInt(@intCast(buffer.size[0]), 0),
            wayland.fixed.fromInt(@intCast(buffer.size[1]), 0),
        );
        try viewport.set_destination(
            @intFromFloat(@as(f32, @floatFromInt(buffer.size[0])) * buffer.scale),
            @intFromFloat(@as(f32, @floatFromInt(buffer.size[1])) * buffer.scale),
        );
    }
    try window.wl_surface.commit();
}

const Buffer = struct {
    allocator: std.mem.Allocator,
    size: [2]u32,
    scale: f32,
    wl_buffer: *wayland.wayland.wl_buffer,
    userdata: ?*anyopaque,
    on_release: ?*const fn (?*anyopaque, *seizer.Display.Buffer) void,

    fn onWlBufferDelete(wl_buffer: *wayland.wayland.wl_buffer, userdata: ?*anyopaque) void {
        _ = wl_buffer;
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.allocator.destroy(this);
    }

    fn onWlBufferEvent(wl_buffer: *wayland.wayland.wl_buffer, userdata: ?*anyopaque, event: wayland.wayland.wl_buffer.Event) void {
        _ = wl_buffer;
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
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
        .allocator = this.allocator,
        .size = options.size,
        .scale = options.scale,
        .wl_buffer = wl_buffer,
        .userdata = options.userdata,
        .on_release = options.on_release,
    };

    wl_buffer.userdata = buffer;
    wl_buffer.on_delete = Buffer.onWlBufferDelete;
    wl_buffer.on_event = Buffer.onWlBufferEvent;

    return @ptrCast(buffer);
}

fn _createBufferFromOpaqueFd(this: *@This(), options: seizer.Display.Buffer.CreateOptionsOpaqueFd) seizer.Display.Buffer.CreateError!*seizer.Display.Buffer {
    std.log.debug("creating opaque fd display buffer", .{});
    const size: i32 = @intCast(options.pool_size);
    const wl_shm_pool = try this.globals.wl_shm.?.create_pool(@enumFromInt(options.fd), size);

    const wl_buffer = try wl_shm_pool.create_buffer(
        @intCast(options.offset),
        @intCast(options.size[0]),
        @intCast(options.size[1]),
        @intCast(options.stride),
        switch (options.format) {
            .ARGB8888 => .argb8888,
            else => @enumFromInt(@intFromEnum(options.format)),
        },
    );

    const buffer = try this.allocator.create(Buffer);
    buffer.* = .{
        .allocator = this.allocator,
        .size = options.size,
        .scale = options.scale,
        .wl_buffer = wl_buffer,
        .userdata = options.userdata,
        .on_release = options.on_release,
    };

    wl_buffer.userdata = buffer;
    wl_buffer.on_delete = Buffer.onWlBufferDelete;
    wl_buffer.on_event = Buffer.onWlBufferEvent;

    return @ptrCast(buffer);
}

fn _destroyBuffer(this: *@This(), buffer_opaque: *seizer.Display.Buffer) void {
    const buffer: *Buffer = @ptrCast(@alignCast(buffer_opaque));
    _ = this;

    // tell the wayland server to destroy this buffer.
    // We wait until the server tells us it is deleted to destroy the memory on our side.
    // (See Buffer.onWlDelete)
    buffer.wl_buffer.destroy() catch unreachable;
    buffer.userdata = null;
    buffer.on_release = null;
}

const Window = struct {
    wayland: *Wayland,

    wl_surface: *wayland.wayland.wl_surface,
    xdg_surface: *xdg_shell.xdg_surface,
    xdg_toplevel: *xdg_shell.xdg_toplevel,
    xdg_toplevel_decoration: ?*xdg_decoration.zxdg_toplevel_decoration_v1,
    wp_viewport: ?*viewporter.wp_viewport,
    wp_fractional_scale: ?*fractional_scale_v1.wp_fractional_scale_v1,

    on_event: ?*const fn (*seizer.Display.Window, seizer.Display.Window.Event) anyerror!void,
    on_render: *const fn (*seizer.Display.Window) anyerror!void,
    on_destroy: ?*const fn (*seizer.Display.Window) void,

    frame_callback: ?*wayland.wayland.wl_callback = null,

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

    fn onXdgSurfaceEvent(xdg_surface: *xdg_shell.xdg_surface, userdata: ?*anyopaque, event: xdg_shell.xdg_surface.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        switch (event) {
            .configure => |conf| {
                if (this.xdg_toplevel_decoration) |decoration| {
                    if (this.current_configuration.decoration_mode != this.new_configuration.decoration_mode) {
                        decoration.set_mode(this.new_configuration.decoration_mode) catch {};
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

                xdg_surface.ack_configure(conf.serial) catch |e| {
                    std.log.warn("Failed to ack configure: {}", .{e});
                    return;
                };

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
                    this.new_configuration.window_size[0] = cfg.width;
                    this.new_configuration.window_size[1] = cfg.height;
                }
            },
        }
    }

    fn onXdgToplevelDecorationEvent(xdg_toplevel_decoration: *xdg_decoration.zxdg_toplevel_decoration_v1, userdata: ?*anyopaque, event: xdg_decoration.zxdg_toplevel_decoration_v1.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = xdg_toplevel_decoration;
        switch (event) {
            .configure => |cfg| {
                if (cfg.mode == .server_side) {
                    this.new_configuration.decoration_mode = .server_side;
                }
            },
        }
    }

    fn onWpFractionalScale(wp_fractional_scale: *fractional_scale_v1.wp_fractional_scale_v1, userdata: ?*anyopaque, event: fractional_scale_v1.wp_fractional_scale_v1.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
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
    cursor_wl_surface: ?*wayland.wayland.wl_surface = null,
    wp_viewport: ?*viewporter.wp_viewport = null,

    pointer_serial: u32 = 0,
    cursor_fractional_scale: ?*fractional_scale_v1.wp_fractional_scale_v1 = null,
    pointer_scale: u32 = 120,

    keymap: ?xkb.Keymap = null,
    keymap_state: xkb.Keymap.State = undefined,
    keyboard_repeat_rate: u32 = 0,
    keyboard_repeat_delay: u32 = 0,

    fn destroy(this: *@This()) void {
        if (this.keymap) |*keymap| keymap.deinit();
        this.wayland_manager.allocator.destroy(this);
    }

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
                    if (this.cursor_wl_surface == null) {
                        this.cursor_wl_surface = this.wayland_manager.globals.wl_compositor.?.create_surface() catch return;

                        if (this.wayland_manager.globals.wp_viewporter) |wp_viewporter| {
                            this.wp_viewport = wp_viewporter.get_viewport(this.cursor_wl_surface.?) catch return;
                        }

                        if (this.wayland_manager.globals.wp_fractional_scale_manager_v1) |scale_man| {
                            this.cursor_fractional_scale = scale_man.get_fractional_scale(this.cursor_wl_surface.?) catch return;
                            this.cursor_fractional_scale.?.userdata = this;
                            this.cursor_fractional_scale.?.on_event = onCursorFractionalScaleEvent;
                        }
                    }
                } else {
                    if (this.wl_pointer) |pointer| {
                        pointer.release() catch {};
                        this.wl_pointer = null;
                    }
                    if (this.wp_viewport) |wp_viewport| {
                        wp_viewport.destroy() catch {};
                        this.wp_viewport = null;
                    }
                    if (this.cursor_fractional_scale) |frac_scale| {
                        frac_scale.destroy() catch {};
                        this.cursor_fractional_scale = null;
                    }
                    if (this.cursor_wl_surface) |surface| {
                        surface.destroy() catch {};
                        this.cursor_wl_surface = null;
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
            .keymap => |keymap_info| {
                defer std.posix.close(@intCast(@intFromEnum(keymap_info.fd)));
                if (keymap_info.format != .xkb_v1) return;

                const new_keymap_source = std.posix.mmap(null, keymap_info.size, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, @intFromEnum(keymap_info.fd), 0) catch |err| {
                    std.log.warn("Failed to mmap keymap from wayland compositor: {}", .{err});
                    return;
                };
                defer std.posix.munmap(new_keymap_source);

                if (this.keymap) |*old_keymap| {
                    old_keymap.deinit();
                    this.keymap = null;
                }
                this.keymap = xkb.Keymap.fromString(this.wayland_manager.allocator, new_keymap_source) catch |err| {
                    std.log.warn("failed to parse keymap: {}", .{err});
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

    fn onPointerCallback(pointer: *wayland.wayland.wl_pointer, userdata: ?*anyopaque, event: wayland.wayland.wl_pointer.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata));
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
            // else => {},
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

        const wl_shm_pool = try this.wayland_manager.globals.wl_shm.?.create_pool(@enumFromInt(default_cursor_image_fd), @intCast(pixel_bytes.len));
        defer wl_shm_pool.destroy() catch {};

        const cursor_buffer = try wl_shm_pool.create_buffer(
            0,
            @intCast(default_cursor_image.width),
            @intCast(default_cursor_image.height),
            @intCast(default_cursor_image.width * @sizeOf(seizer.tvg.rendering.Color8)),
            .argb8888,
        );

        const surface = this.cursor_wl_surface orelse return;

        try surface.attach(cursor_buffer, 0, 0);
        try surface.damage_buffer(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
        if (this.wp_viewport) |viewport| {
            try viewport.set_source(
                wayland.fixed.fromInt(0, 0),
                wayland.fixed.fromInt(0, 0),
                wayland.fixed.fromInt(@intCast(default_cursor_image.width), 0),
                wayland.fixed.fromInt(@intCast(default_cursor_image.height), 0),
            );
            try viewport.set_destination(32, 32);
        }
        try surface.commit();
        try this.wl_pointer.?.set_cursor(this.pointer_serial, this.cursor_wl_surface, 9, 5);
    }
};

const evdevToSeizer = @import("./Wayland/evdev_to_seizer.zig").evdevToSeizer;
const xkbSymbolToSeizerKey = @import("./Wayland/xkb_to_seizer.zig").xkbSymbolToSeizerKey;

const fractional_scale_v1 = @import("wayland-protocols").staging.@"fractional-scale-v1";
const viewporter = @import("wayland-protocols").stable.viewporter;
const linux_dmabuf_v1 = @import("wayland-protocols").stable.@"linux-dmabuf-v1";
const xdg_shell = @import("wayland-protocols").stable.@"xdg-shell";
const xdg_decoration = @import("wayland-protocols").unstable.@"xdg-decoration-unstable-v1";
const wayland = @import("wayland");

const builtin = @import("builtin");
const xkb = @import("xkb");
const xev = @import("xev");
const seizer = @import("../seizer.zig");
const std = @import("std");

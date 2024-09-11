/// This is similar to `seizer.Platform` by providing a way to abstract over different platforms. It differs from `seizer.Platform`
/// by being runtime known. It is only designed to paper over differences in Wayland and bare EGL.
pub const WindowManager = union(enum) {
    wayland: *Wayland,
    bare_egl: *BareEGL,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        loop: *xev.Loop,
        key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),
        renderdoc: *@import("renderdoc"),
    };

    pub fn init(options: InitOptions) !@This() {
        // Go through each window manager one-by-one and see if we can initialize any without error.

        if (Wayland.init(options)) |wayland| {
            return .{ .wayland = wayland };
        } else |err| {
            std.log.warn("Failed to open Wayland display: {}", .{err});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        }

        if (BareEGL.init(options)) |bare_egl| {
            return .{ .bare_egl = bare_egl };
        } else |err| {
            std.log.warn("Failed to open bare EGL display: {}", .{err});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
        }

        return error.UnknownWindowManager;
    }

    pub fn deinit(this: @This()) void {
        switch (this) {
            inline else => |manager| return manager.deinit(),
        }
    }

    pub fn createWindow(this: @This(), options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
        switch (this) {
            inline else => |manager| return manager.createWindow(options),
        }
    }

    pub fn shouldClose(this: @This()) bool {
        switch (this) {
            inline else => |manager| return manager.shouldClose(),
        }
    }

    pub fn presentFrame(this: @This()) void {
        switch (this) {
            inline else => |manager| try manager.presentFrame(),
        }
    }

    pub fn update(this: @This()) !void {
        switch (this) {
            inline else => |manager| try manager.update(),
        }
    }

    pub fn setEventCallback(this: @This(), new_on_event_callback: ?*const fn (event: seizer.input.Event) anyerror!void) void {
        switch (this) {
            inline else => |manager| manager.on_event_fn = new_on_event_callback,
        }
    }
};

const Wayland = struct {
    allocator: std.mem.Allocator,

    connection: wayland.Conn,
    registry: *wayland.wayland.wl_registry,
    globals: Globals = .{},

    windows: std.ArrayListUnmanaged(*Window) = .{},
    seats: std.ArrayListUnmanaged(*Seat) = .{},

    on_event_fn: ?*const fn (event: seizer.input.Event) anyerror!void = null,
    key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),

    renderdoc: *@import("renderdoc"),

    pub fn init(options: WindowManager.InitOptions) !*@This() {
        // initialize wayland connection
        const connection_path = try wayland.getDisplayPath(options.allocator);
        defer options.allocator.free(connection_path);

        // allocate this
        const this = try options.allocator.create(@This());
        errdefer options.allocator.destroy(this);
        this.* = .{
            .allocator = options.allocator,

            .connection = undefined,
            .registry = undefined,

            .key_bindings = options.key_bindings,

            .renderdoc = options.renderdoc,
        };

        // open connection to wayland server
        try this.connection.connect(options.loop, options.allocator, connection_path);
        errdefer this.connection.deinit();

        this.registry = try this.connection.getRegistry();
        this.registry.on_event = onRegistryEvent;
        this.registry.userdata = this;

        try this.connection.dispatchUntilSync(options.loop);
        if (this.globals.wl_compositor == null or this.globals.xdg_wm_base == null or this.globals.zwp_linux_dmabuf_v1 == null) {
            return error.MissingWaylandProtocol;
        }

        this.globals.xdg_wm_base.?.on_event = onXdgWmBaseEvent;

        return this;
    }

    pub fn deinit(this: *@This()) void {
        for (this.windows.items) |window| {
            window.destroy();
        }
        this.windows.deinit(this.allocator);

        for (this.seats.items) |seat| {
            this.allocator.destroy(seat);
        }
        this.seats.deinit(this.allocator);

        this.connection.deinit();

        this.allocator.destroy(this);
    }

    fn shouldClose(this: *@This()) bool {
        return this.windows.items.len <= 0;
    }

    fn update(this: *@This()) !void {
        {
            var i: usize = this.windows.items.len;
            while (i > 0) : (i -= 1) {
                const window = this.windows.items[i - 1];
                if (window.should_close) {
                    _ = this.windows.swapRemove(i - 1);
                    window.destroy();
                }
            }
        }
        for (this.windows.items) |window| {
            if (window.should_render) {
                try window.render();
            }
        }
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

    fn createWindow(this: *@This(), options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
        const size = if (options.size) |s| [2]c_int{ @intCast(s[0]), @intCast(s[1]) } else [2]c_int{ 640, 480 };

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
            .should_close = false,

            .on_render = options.on_render,
            .on_destroy = options.on_destroy,

            .new_window_size = size,
            .window_size = [_]c_int{ 0, 0 },
        };

        window.xdg_surface.userdata = window;
        window.xdg_toplevel.userdata = window;
        window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
        window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;

        try this.windows.append(this.allocator, window);

        return window.window();
    }

    const Window = struct {
        wayland: *Wayland,

        wl_surface: *wayland.wayland.wl_surface,
        xdg_surface: *xdg_shell.xdg_surface,
        xdg_toplevel: *xdg_shell.xdg_toplevel,
        should_close: bool,
        should_render: bool = true,

        render_buffers: std.AutoHashMapUnmanaged(*wayland.wayland.wl_buffer, seizer.Graphics.RenderBuffer) = .{},

        on_render: *const fn (seizer.Window) anyerror!void,
        on_destroy: ?*const fn (seizer.Window) void,

        new_window_size: [2]c_int,
        window_size: [2]c_int,

        userdata: ?*anyopaque = null,

        pub const INTERFACE = seizer.Window.Interface{
            .getSize = getSize,
            .getFramebufferSize = getSize,
            .presentFrame = presentFrame,
            .setShouldClose = setShouldClose,
            .setUserdata = setUserdata,
            .getUserdata = getUserdata,
        };

        pub fn destroy(this: *@This()) void {
            if (this.on_destroy) |on_destroy| {
                on_destroy(this.window());
            }

            // hide window
            this.wl_surface.attach(null, 0, 0) catch {};
            this.wl_surface.commit() catch {};

            // destroy surfaces
            this.xdg_toplevel.destroy() catch {};
            this.xdg_surface.destroy() catch {};
            this.wl_surface.destroy() catch {};

            // destroy render buffers
            var render_buffer_iter = this.render_buffers.iterator();
            while (render_buffer_iter.next()) |entry| {
                entry.key_ptr.*.on_event = null;
                entry.key_ptr.*.userdata = null;
                entry.value_ptr.release();
            }
            this.render_buffers.deinit(this.wayland.allocator);

            this.wayland.allocator.destroy(this);
        }

        pub fn window(this: *@This()) seizer.Window {
            return seizer.Window{
                .pointer = this,
                .interface = &INTERFACE,
            };
        }

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
                    this.should_render = true;

                    this.window_size = this.new_window_size;
                },
            }
        }

        fn onXdgToplevelEvent(xdg_toplevel: *xdg_shell.xdg_toplevel, userdata: ?*anyopaque, event: xdg_shell.xdg_toplevel.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = xdg_toplevel;
            switch (event) {
                .close => this.should_close = true,
                .configure => |cfg| {
                    if (cfg.width > 0 and cfg.height > 0) {
                        this.new_window_size[0] = cfg.width;
                        this.new_window_size[1] = cfg.height;
                    }
                },
            }
        }

        fn setupFrameCallback(this: *@This()) !void {
            const frame_callback = try this.wl_surface.frame();
            frame_callback.on_event = onFrameCallback;
            frame_callback.userdata = this;
        }

        fn render(this_window: *Window) !void {
            if (this_window.window_size[0] == 0 and this_window.window_size[1] == 0) return;

            // if (this_window.wayland.renderdoc.api) |renderdoc_api| {
            //     renderdoc_api.StartFrameCapture(null, null);
            // }

            this_window.on_render(this_window.window()) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                this_window.should_close = true;
                return;
            };

            if (this_window.wayland.renderdoc.api) |renderdoc_api| {
                if (renderdoc_api.IsFrameCapturing(null, null) == 1) {
                    _ = renderdoc_api.EndFrameCapture(null, null);
                }
            }

            this_window.should_render = false;
        }

        fn presentFrame(userdata: ?*anyopaque, render_buffer: seizer.Graphics.RenderBuffer) anyerror!void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));

            const wl_dmabuf_buffer_params = try this.wayland.globals.zwp_linux_dmabuf_v1.?.create_params();
            defer wl_dmabuf_buffer_params.destroy() catch {};

            const dmabuf_format = render_buffer.getDmaBufFormat();

            var dmabuf_planes_buf: [10]seizer.Graphics.RenderBuffer.DmaBufPlane = undefined;
            const dmabuf_planes = render_buffer.getDmaBufPlanes(dmabuf_planes_buf[0..]);
            for (dmabuf_planes) |plane| {
                try wl_dmabuf_buffer_params.add(
                    @enumFromInt(plane.fd),
                    @intCast(plane.index),
                    @intCast(plane.offset),
                    @intCast(plane.stride),
                    @intCast((dmabuf_format.modifiers >> 32) & 0xFFFF_FFFF),
                    @intCast((dmabuf_format.modifiers) & 0xFFFF_FFFF),
                );
            }

            const wl_buffer = try wl_dmabuf_buffer_params.create_immed(
                @intCast(render_buffer.getSize()[0]),
                @intCast(render_buffer.getSize()[1]),
                @intFromEnum(dmabuf_format.fourcc),
                .{ .y_invert = false, .interlaced = false, .bottom_first = false },
            );
            wl_buffer.userdata = this;
            wl_buffer.on_event = onBufferEvent;

            try this.render_buffers.put(this.wayland.allocator, wl_buffer, render_buffer);

            try this.setupFrameCallback();

            try this.wl_surface.attach(wl_buffer, 0, 0);
            try this.wl_surface.damage_buffer(0, 0, @intCast(render_buffer.getSize()[0]), @intCast(render_buffer.getSize()[1]));
            try this.wl_surface.commit();
        }

        fn onBufferEvent(wl_buffer: *wayland.wayland.wl_buffer, userdata: ?*anyopaque, event: wayland.wayland.wl_buffer.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            switch (event) {
                .release => {
                    const entry = this.render_buffers.fetchRemove(wl_buffer) orelse return;
                    entry.value.release();
                },
            }
        }

        fn onFrameCallback(callback: *wayland.wayland.wl_callback, userdata: ?*anyopaque, event: wayland.wayland.wl_callback.Event) void {
            const this_window: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = callback;
            switch (event) {
                .done => {
                    this_window.should_render = true;
                },
            }
        }
    };

    const Seat = struct {
        wayland_manager: *Wayland,
        wl_seat: *wayland.wayland.wl_seat,
        wl_pointer: ?*wayland.wayland.wl_pointer = null,
        wl_keyboard: ?*wayland.wayland.wl_keyboard = null,

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

                    const actions = this.wayland_manager.key_bindings.get(.{ .keyboard = key }) orelse return;
                    for (actions.items) |action| {
                        action.on_event(k.state == .pressed) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                            break;
                        };
                    }
                },
                else => {},
            }
        }

        fn onPointerCallback(seat: *wayland.wayland.wl_pointer, userdata: ?*anyopaque, event: wayland.wayland.wl_pointer.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata));
            _ = seat;
            switch (event) {
                .motion => |motion| {
                    if (this.wayland_manager.on_event_fn) |on_event| {
                        this.pointer_pos = [2]f32{ motion.surface_x.toFloat(f32), motion.surface_y.toFloat(f32) };
                        on_event(seizer.input.Event{ .hover = .{
                            .pos = this.pointer_pos,
                            .modifiers = .{ .left = false, .right = false, .middle = false },
                        } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                },
                .button => |button| {
                    if (this.wayland_manager.on_event_fn) |on_event| {
                        on_event(seizer.input.Event{ .click = .{
                            .pos = this.pointer_pos,
                            .button = @enumFromInt(button.button),
                            .pressed = button.state == .pressed,
                        } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
                    }
                },
                .axis => |axis| {
                    switch (axis.axis) {
                        .horizontal_scroll => this.scroll_vector[0] += axis.value.toFloat(f32),
                        .vertical_scroll => this.scroll_vector[1] += axis.value.toFloat(f32),
                    }
                },
                .frame => {
                    if (this.wayland_manager.on_event_fn) |on_event| {
                        on_event(seizer.input.Event{ .scroll = .{
                            .offset = this.scroll_vector,
                        } }) catch |err| {
                            std.debug.print("{s}\n", .{@errorName(err)});
                            if (@errorReturnTrace()) |trace| {
                                std.debug.dumpStackTrace(trace.*);
                            }
                        };
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
};

pub const BareEGL = struct {
    allocator: std.mem.Allocator,
    on_event_fn: ?*const fn (event: seizer.input.Event) anyerror!void = null,
    key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),

    windows: std.ArrayListUnmanaged(*Window) = .{},

    pub fn init(options: WindowManager.InitOptions) !*@This() {
        const this = try options.allocator.create(@This());
        this.* = .{
            .allocator = options.allocator,
            .key_bindings = options.key_bindings,
        };
        return this;
    }

    pub fn deinit(this: *@This()) void {
        for (this.windows.items) |window| {
            window.destroy();
        }
        this.windows.deinit(this.allocator);

        this.allocator.destroy(this);
    }

    fn shouldClose(this: *@This()) bool {
        return this.windows.items.len <= 0;
    }

    fn update(this: *@This()) !void {
        var i: usize = this.windows.items.len;
        while (i > 0) : (i -= 1) {
            const window = this.windows.items[i - 1];
            if (window.should_close) {
                _ = this.windows.swapRemove(i - 1);
                window.destroy();
            }
        }

        for (this.windows.items) |window| {
            window.on_render(window.window()) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                return;
            };
        }
    }

    fn createWindow(this: *@This(), options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
        if (true) return error.Unimplemented;
        var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.surface_type),    EGL.WINDOW_BIT,
            @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
            @intFromEnum(EGL.Attrib.red_size),        8,
            @intFromEnum(EGL.Attrib.blue_size),       8,
            @intFromEnum(EGL.Attrib.green_size),      8,
            @intFromEnum(EGL.Attrib.none),
        };
        const num_configs = try this.display.chooseConfig(&attrib_list, null);

        if (num_configs == 0) {
            return error.NoSuitableConfigs;
        }

        const configs_buffer = try this.allocator.alloc(*EGL.Config.Handle, @intCast(num_configs));
        defer this.allocator.free(configs_buffer);

        const configs_len = try this.display.chooseConfig(&attrib_list, configs_buffer);
        const configs = configs_buffer[0..configs_len];

        const surface = try this.display.createWindowSurface(configs[0], null, null);

        try this.egl.bindAPI(.opengl_es);
        var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.context_major_version), 3,
            @intFromEnum(EGL.Attrib.context_minor_version), 0,
            @intFromEnum(EGL.Attrib.none),
        };
        const egl_context = try this.display.createContext(configs[0], null, &context_attrib_list);

        try this.display.makeCurrent(surface, surface, egl_context);

        const window = try this.allocator.create(Window);
        errdefer this.allocator.destroy(window);

        window.* = .{
            .allocator = this.allocator,
            .egl_display = this.display,
            .surface = surface,
            .egl_context = egl_context,
            .should_close = false,

            .gl_binding = undefined,
            .on_render = options.on_render,
            .on_destroy = options.on_destroy,
        };

        // const loader = GlBindingLoader{ .egl = this.egl };
        // window.gl_binding.init(loader);
        // gl.makeBindingCurrent(&window.gl_binding);

        // gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

        try this.windows.append(this.allocator, window);

        return window.window();
    }

    const Window = struct {
        allocator: std.mem.Allocator,
        egl_display: EGL.Display,
        surface: EGL.Surface,
        egl_context: EGL.Context,
        should_close: bool,

        // gl_binding: gl.Binding,
        on_render: *const fn (seizer.Window) anyerror!void,
        on_destroy: ?*const fn (seizer.Window) void,

        userdata: ?*anyopaque = null,

        pub const INTERFACE = seizer.Window.Interface{
            .getSize = getSize,
            .getFramebufferSize = getSize,
            .setShouldClose = setShouldClose,
            .presentFrame = presentFrame,
            .setUserdata = setUserdata,
            .getUserdata = getUserdata,
        };

        pub fn destroy(this: *@This()) void {
            if (this.on_destroy) |on_destroy| {
                on_destroy(this.window());
            }
            this.egl_display.destroySurface(this.surface);
            this.allocator.destroy(this);
        }

        pub fn window(this: *@This()) seizer.Window {
            return seizer.Window{
                .pointer = this,
                .interface = &INTERFACE,
            };
        }

        pub fn getSize(userdata: ?*anyopaque) [2]u32 {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));

            const width = this.egl_display.querySurface(this.surface, .width) catch unreachable;
            const height = this.egl_display.querySurface(this.surface, .height) catch unreachable;

            return .{ @intCast(width), @intCast(height) };
        }

        pub fn presentFrame(userdata: ?*anyopaque, render_buffer: seizer.Graphics.RenderBuffer) anyerror!void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = render_buffer;
            try this.egl_display.swapBuffers(this.surface);
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
    };
};

const builtin = @import("builtin");
const xev = @import("xev");
const EGL = @import("EGL");
const seizer = @import("../../seizer.zig");
const EvDev = @import("./evdev.zig");
const std = @import("std");

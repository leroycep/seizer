/// This is similar to `seizer.Platform` by providing a way to abstract over different platforms. It differs from `seizer.Platform`
/// by being runtime known. It is only designed to paper over differences in Wayland and bare EGL.
pub const WindowManager = union(enum) {
    wayland: *Wayland,
    bare_egl: *BareEGL,

    pub const InitOptions = struct {
        allocator: std.mem.Allocator,
        egl: *const EGL,
        key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),
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

    pub fn createWindow(this: @This(), options: seizer.Platform.CreateWindowOptions, egl_display: EGL.Display) anyerror!seizer.Window {
        switch (this) {
            inline else => |manager| return manager.createWindow(options, egl_display),
        }
    }

    pub fn shouldClose(this: @This()) bool {
        switch (this) {
            inline else => |manager| return manager.shouldClose(),
        }
    }

    pub fn update(this: @This()) !void {
        switch (this) {
            inline else => |manager| try manager.update(),
        }
    }
};

const Wayland = struct {
    allocator: std.mem.Allocator,

    connection: wayland.Conn,
    registry: *wayland.wayland.wl_registry,
    globals: Globals = .{},

    egl: *const EGL,
    egl_mesa_image_dma_buf_export: EGL.MESA.image_dma_buf_export,
    egl_khr_image_base: EGL.KHR.image_base,

    windows: std.ArrayListUnmanaged(*Window) = .{},
    seats: std.ArrayListUnmanaged(*Seat) = .{},

    key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),

    pub fn init(options: WindowManager.InitOptions) !*@This() {
        // initialize wayland connection
        const connection_path = try wayland.getDisplayPath(options.allocator);
        defer options.allocator.free(connection_path);

        var connection = try wayland.Conn.init(options.allocator, connection_path);
        errdefer connection.deinit();

        // Get required EGL extensions
        const egl_mesa_image_dma_buf_export = try EGL.loadExtension(EGL.MESA.image_dma_buf_export, options.egl.functions);
        const egl_khr_image_base = try EGL.loadExtension(EGL.KHR.image_base, options.egl.functions);

        const this = try options.allocator.create(@This());
        this.* = .{
            .allocator = options.allocator,

            .connection = connection,
            .registry = undefined,

            .egl = options.egl,
            .egl_mesa_image_dma_buf_export = egl_mesa_image_dma_buf_export,
            .egl_khr_image_base = egl_khr_image_base,

            .key_bindings = options.key_bindings,
        };

        this.registry = try this.connection.getRegistry();
        this.registry.on_event = onRegistryEvent;
        this.registry.userdata = this;

        try this.connection.dispatchUntilSync();
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
        // TODO: bring all file waiting together
        try this.connection.dispatchUntilSync();
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
                        .key_bindings = this.key_bindings,
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

    fn createWindow(this: *@This(), options: seizer.Platform.CreateWindowOptions, egl_display: EGL.Display) anyerror!seizer.Window {
        const size = if (options.size) |s| [2]c_int{ @intCast(s[0]), @intCast(s[1]) } else [2]c_int{ 640, 480 };

        const wl_surface = try this.globals.wl_compositor.?.create_surface();
        const xdg_surface = try this.globals.xdg_wm_base.?.get_xdg_surface(wl_surface);
        const xdg_toplevel = try xdg_surface.get_toplevel();
        try wl_surface.commit();

        var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
            @intFromEnum(EGL.Attrib.red_size),        8,
            @intFromEnum(EGL.Attrib.blue_size),       8,
            @intFromEnum(EGL.Attrib.green_size),      8,
            @intFromEnum(EGL.Attrib.none),
        };
        const num_configs = try egl_display.chooseConfig(&attrib_list, null);

        if (num_configs == 0) {
            return error.NoSuitableConfigs;
        }

        const configs_buffer = try this.allocator.alloc(*EGL.Config.Handle, @intCast(num_configs));
        defer this.allocator.free(configs_buffer);

        const configs_len = try egl_display.chooseConfig(&attrib_list, configs_buffer);
        const configs = configs_buffer[0..configs_len];

        try this.egl.bindAPI(.opengl_es);
        var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.context_major_version), 3,
            @intFromEnum(EGL.Attrib.context_minor_version), 0,
            @intFromEnum(EGL.Attrib.none),
        };
        const egl_context = try egl_display.createContext(configs[0], null, &context_attrib_list);

        try egl_display.makeCurrent(null, null, egl_context);

        const window = try this.allocator.create(Window);
        errdefer this.allocator.destroy(window);

        window.* = .{
            .wayland = this,

            .egl_display = egl_display,
            .egl_context = egl_context,
            .wl_surface = wl_surface,
            .xdg_surface = xdg_surface,
            .xdg_toplevel = xdg_toplevel,
            .should_close = false,

            .gl_binding = undefined,
            .on_render = options.on_render,
            .on_destroy = options.on_destroy,

            .new_window_size = size,
            .window_size = [_]c_int{ 0, 0 },
        };

        const loader = GlBindingLoader{ .egl = this.egl };
        window.gl_binding.init(loader);
        gl.makeBindingCurrent(&window.gl_binding);

        window.xdg_surface.userdata = window;
        window.xdg_toplevel.userdata = window;
        window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
        window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;
        try this.connection.dispatchUntilSync();

        try this.windows.append(this.allocator, window);

        return window.window();
    }

    const Window = struct {
        wayland: *Wayland,

        egl_display: EGL.Display,
        egl_context: EGL.Context,
        wl_surface: *wayland.wayland.wl_surface,
        xdg_surface: *xdg_shell.xdg_surface,
        xdg_toplevel: *xdg_shell.xdg_toplevel,
        should_close: bool,
        should_render: bool = true,

        free_framebuffers: std.BoundedArray(*Framebuffer, 16) = .{},
        framebuffers: std.BoundedArray(*Framebuffer, 16) = .{},

        gl_binding: gl.Binding,
        on_render: *const fn (seizer.Window) anyerror!void,
        on_destroy: ?*const fn (seizer.Window) void,

        new_window_size: [2]c_int,
        window_size: [2]c_int,

        pub const INTERFACE = seizer.Window.Interface{
            .getSize = getSize,
            .getFramebufferSize = getSize,
            .setShouldClose = setShouldClose,
        };

        pub fn destroy(this: *@This()) void {
            if (this.on_destroy) |on_destroy| {
                on_destroy(this.window());
            }

            for (this.framebuffers.slice()) |f| {
                f.destroy(this.egl_display);
            }
            for (this.free_framebuffers.slice()) |f| {
                f.destroy(this.egl_display);
            }

            this.wl_surface.destroy() catch {};

            this.wayland.allocator.destroy(this);
        }

        pub fn window(this: *@This()) seizer.Window {
            return seizer.Window{
                .pointer = this,
                .interface = &INTERFACE,
            };
        }

        pub fn getSize(userdata: ?*anyopaque) [2]f32 {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));

            return .{ @floatFromInt(this.window_size[0]), @floatFromInt(this.window_size[1]) };
        }

        pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            this.should_close = should_close;
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
            gl.makeBindingCurrent(&this_window.gl_binding);

            const framebuffer = this_window.getFramebuffer(this_window.window_size) catch |e| {
                std.log.warn("Failed to get framebuffer: {}; window_size = {}x{}", .{ e, this_window.window_size[0], this_window.window_size[1] });
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                this_window.should_close = true;
                return;
            };
            framebuffer.bind();
            gl.viewport(0, 0, this_window.window_size[0], this_window.window_size[1]);

            this_window.on_render(this_window.window()) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                this_window.should_close = true;
                return;
            };

            gl.flush();

            try this_window.setupFrameCallback();

            try this_window.wl_surface.set_buffer_transform(@intFromEnum(wayland.wayland.wl_output.Transform.flipped_180));
            try this_window.wl_surface.attach(framebuffer.wl_buffer.?, 0, 0);
            try this_window.wl_surface.damage_buffer(0, 0, framebuffer.size[0], framebuffer.size[1]);
            try this_window.wl_surface.commit();

            this_window.should_render = false;
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

        pub fn getFramebuffer(this: *Window, size: [2]c_int) !*Framebuffer {
            while (this.free_framebuffers.popOrNull()) |framebuffer| {
                if (std.mem.eql(c_int, &framebuffer.size, &size)) {
                    return framebuffer;
                }
                framebuffer.destroy(this.egl_display);
            }

            const framebuffer = try this.createFramebuffer(size, this.egl_display);
            try this.framebuffers.append(framebuffer);
            return framebuffer;
        }

        pub fn createFramebuffer(this: *Window, size: [2]c_int, egl_display: EGL.Display) !*Framebuffer {
            const framebuffer = try this.wayland.allocator.create(Framebuffer);
            framebuffer.* = .{
                .allocator = this.wayland.allocator,
                .window = this,
                .wl_buffer = null,
                .egl_image = undefined,
                .size = size,
            };
            errdefer framebuffer.destroy(this.egl_display);

            gl.genRenderbuffers(framebuffer.gl_render_buffers.len, &framebuffer.gl_render_buffers);
            gl.genFramebuffers(framebuffer.gl_framebuffer_objects.len, &framebuffer.gl_framebuffer_objects);

            gl.bindRenderbuffer(gl.RENDERBUFFER, framebuffer.gl_render_buffers[0]);
            gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGB8, size[0], size[1]);

            gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer.gl_framebuffer_objects[0]);
            gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, framebuffer.gl_render_buffers[0]);

            framebuffer.egl_image = try this.wayland.egl_khr_image_base.createImage(
                egl_display,
                this.egl_context,
                .gl_renderbuffer,
                @ptrFromInt(@as(usize, @intCast(framebuffer.gl_render_buffers[0]))),
                null,
            );

            const dmabuf_image = try this.wayland.egl_mesa_image_dma_buf_export.exportImageAlloc(this.wayland.allocator, egl_display, framebuffer.egl_image);
            defer dmabuf_image.deinit();

            const wl_dmabuf_buffer_params = try this.wayland.globals.zwp_linux_dmabuf_v1.?.create_params();
            defer wl_dmabuf_buffer_params.destroy() catch {};

            for (0.., dmabuf_image.dmabuf_fds, dmabuf_image.offsets, dmabuf_image.strides) |plane, fd, offset, stride| {
                try wl_dmabuf_buffer_params.add(
                    @enumFromInt(fd),
                    @intCast(plane),
                    @intCast(offset),
                    @intCast(stride),
                    @intCast((dmabuf_image.modifiers >> 32) & 0xFFFF_FFFF),
                    @intCast((dmabuf_image.modifiers) & 0xFFFF_FFFF),
                );
            }

            framebuffer.wl_buffer = try wl_dmabuf_buffer_params.create_immed(
                @intCast(size[0]),
                @intCast(size[1]),
                @intCast(dmabuf_image.fourcc),
                .{ .y_invert = false, .interlaced = false, .bottom_first = false },
            );
            framebuffer.wl_buffer.?.userdata = framebuffer;
            framebuffer.wl_buffer.?.on_event = Framebuffer.onBufferEvent;

            return framebuffer;
        }
    };

    const Framebuffer = struct {
        allocator: std.mem.Allocator,
        window: *Window,
        gl_render_buffers: [1]gl.Uint = .{0},
        gl_framebuffer_objects: [1]gl.Uint = .{0},
        egl_image: EGL.KHR.image_base.Image,
        wl_buffer: ?*wayland.wayland.wl_buffer,
        size: [2]c_int,

        pub fn bind(framebuffer: *Framebuffer) void {
            gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer.gl_framebuffer_objects[0]);
            gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, framebuffer.gl_render_buffers[0]);
        }

        pub fn destroy(framebuffer: *Framebuffer, egl_display: EGL.Display) void {
            if (framebuffer.wl_buffer) |wl_buffer| wl_buffer.destroy() catch {};
            framebuffer.window.wayland.egl_khr_image_base.destroyImage(egl_display, framebuffer.egl_image) catch {};
            gl.deleteRenderbuffers(framebuffer.gl_render_buffers.len, &framebuffer.gl_render_buffers);
            gl.deleteFramebuffers(framebuffer.gl_framebuffer_objects.len, &framebuffer.gl_framebuffer_objects);
            framebuffer.allocator.destroy(framebuffer);
        }

        fn onBufferEvent(buffer: *wayland.wayland.wl_buffer, userdata: ?*anyopaque, event: wayland.wayland.wl_buffer.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            _ = buffer;
            switch (event) {
                .release => {
                    this.window.free_framebuffers.append(this) catch {};
                    if (std.mem.indexOfScalar(*Framebuffer, this.window.framebuffers.slice(), this)) |index| {
                        _ = this.window.framebuffers.swapRemove(index);
                    }
                },
            }
        }
    };

    const Seat = struct {
        key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),
        wl_seat: *wayland.wayland.wl_seat,
        wl_keyboard: ?*wayland.wayland.wl_keyboard = null,

        fn onSeatCallback(seat: *wayland.wayland.wl_seat, userdata: ?*anyopaque, event: wayland.wayland.wl_seat.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata));
            _ = seat;
            switch (event) {
                .capabilities => |capabilities| {
                    std.log.debug("seat capabilities = {}", .{capabilities});

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
                },
                .name => |n| {
                    std.log.debug("seat name = \"{}\"", .{std.zig.fmtEscapes(n.name orelse "")});
                },
            }
        }

        fn onKeyboardCallback(seat: *wayland.wayland.wl_keyboard, userdata: ?*anyopaque, event: wayland.wayland.wl_keyboard.Event) void {
            const this: *@This() = @ptrCast(@alignCast(userdata));
            _ = seat;
            switch (event) {
                .key => |k| {
                    const key: EvDev.KEY = @enumFromInt(@as(u16, @intCast(k.key)));

                    const actions = this.key_bindings.get(.{ .keyboard = key }) orelse return;
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
    };

    const linux_dmabuf_v1 = @import("wayland-protocols").stable.@"linux-dmabuf-v1";
    const xdg_shell = @import("wayland-protocols").stable.@"xdg-shell";
    const wayland = @import("wayland");
};

pub const BareEGL = struct {
    allocator: std.mem.Allocator,
    egl: *const EGL,
    key_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),

    windows: std.ArrayListUnmanaged(*Window) = .{},

    pub fn init(options: WindowManager.InitOptions) !*@This() {
        const this = try options.allocator.create(@This());
        this.* = .{
            .allocator = options.allocator,
            .egl = options.egl,
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
            gl.makeBindingCurrent(&window.gl_binding);
            window.on_render(window.window()) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                return;
            };
            window.swapBuffers();
        }
    }

    fn createWindow(this: *@This(), options: seizer.Platform.CreateWindowOptions, egl_display: EGL.Display) anyerror!seizer.Window {
        var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.surface_type),    EGL.WINDOW_BIT,
            @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
            @intFromEnum(EGL.Attrib.red_size),        8,
            @intFromEnum(EGL.Attrib.blue_size),       8,
            @intFromEnum(EGL.Attrib.green_size),      8,
            @intFromEnum(EGL.Attrib.none),
        };
        const num_configs = try egl_display.chooseConfig(&attrib_list, null);

        if (num_configs == 0) {
            return error.NoSuitableConfigs;
        }

        const configs_buffer = try this.allocator.alloc(*EGL.Config.Handle, @intCast(num_configs));
        defer this.allocator.free(configs_buffer);

        const configs_len = try egl_display.chooseConfig(&attrib_list, configs_buffer);
        const configs = configs_buffer[0..configs_len];

        const surface = try egl_display.createWindowSurface(configs[0], null, null);

        try this.egl.bindAPI(.opengl_es);
        var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
            @intFromEnum(EGL.Attrib.context_major_version), 3,
            @intFromEnum(EGL.Attrib.context_minor_version), 0,
            @intFromEnum(EGL.Attrib.none),
        };
        const egl_context = try egl_display.createContext(configs[0], null, &context_attrib_list);

        try egl_display.makeCurrent(surface, surface, egl_context);

        const window = try this.allocator.create(Window);
        errdefer this.allocator.destroy(window);

        window.* = .{
            .allocator = this.allocator,
            .egl_display = egl_display,
            .surface = surface,
            .egl_context = egl_context,
            .should_close = false,

            .gl_binding = undefined,
            .on_render = options.on_render,
            .on_destroy = options.on_destroy,
        };

        const loader = GlBindingLoader{ .egl = this.egl };
        window.gl_binding.init(loader);
        gl.makeBindingCurrent(&window.gl_binding);

        gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

        try this.windows.append(this.allocator, window);

        return window.window();
    }

    const Window = struct {
        allocator: std.mem.Allocator,
        egl_display: EGL.Display,
        surface: EGL.Surface,
        egl_context: EGL.Context,
        should_close: bool,

        gl_binding: gl.Binding,
        on_render: *const fn (seizer.Window) anyerror!void,
        on_destroy: ?*const fn (seizer.Window) void,

        pub const INTERFACE = seizer.Window.Interface{
            .getSize = getSize,
            .getFramebufferSize = getSize,
            .setShouldClose = setShouldClose,
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

        pub fn getSize(userdata: ?*anyopaque) [2]f32 {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));

            const width = this.egl_display.querySurface(this.surface, .width) catch unreachable;
            const height = this.egl_display.querySurface(this.surface, .height) catch unreachable;

            return .{ @floatFromInt(width), @floatFromInt(height) };
        }

        pub fn swapBuffers(this: *@This()) void {
            this.egl_display.swapBuffers(this.surface) catch |err| {
                std.log.warn("failed to swap buffers: {}", .{err});
            };
        }

        pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
            const this: *@This() = @ptrCast(@alignCast(userdata.?));
            this.should_close = should_close;
        }
    };
};

pub const GlBindingLoader = struct {
    egl: *const EGL,
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(this: @This(), command_name: [:0]const u8) ?AnyCFnPtr {
        return this.egl.functions.eglGetProcAddress(command_name);
    }

    pub fn extensionSupported(this: @This(), extension_name: [:0]const u8) bool {
        _ = this;
        _ = extension_name;
        return true;
    }
};

const EGL = @import("EGL");
const gl = seizer.gl;
const seizer = @import("../../seizer.zig");
const EvDev = @import("./evdev.zig");
const std = @import("std");

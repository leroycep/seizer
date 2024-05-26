var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var egl: EGL = undefined;
var egl_mesa_image_dma_buf_export: EGL.MESA.image_dma_buf_export = undefined;
var egl_khr_image_base: EGL.KHR.image_base = undefined;
var egl_display: EGL.Display = undefined;
var evdev: EvDev = undefined;
var windows: std.ArrayListUnmanaged(*Window) = .{};
var wl_connection: wayland.Conn = undefined;
var wl_registry: *wayland.wayland.wl_registry = undefined;
var wl_globals: Globals = undefined;

var seats: std.ArrayListUnmanaged(*Seat) = .{};
var key_bindings: std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)) = .{};

pub const PLATFORM = seizer.Platform{
    .name = "wayland",
    .main = main,
    .gl = @import("gl"),
    .allocator = getAllocator,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
    .writeFile = writeFile,
    .readFile = readFile,
};

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    defer _ = gpa.deinit();

    windows = .{};
    defer {
        for (windows.items) |window| {
            window.destroy();
        }
        windows.deinit(gpa.allocator());
    }

    // init wayland connection
    const conn_path = try wayland.getDisplayPath(gpa.allocator());
    defer gpa.allocator().free(conn_path);

    wl_connection = try wayland.Conn.init(gpa.allocator(), conn_path);
    defer wl_connection.deinit();

    seats = .{};
    key_bindings = .{};
    defer {
        for (seats.items) |seat| {
            gpa.allocator().destroy(seat);
        }
        seats.deinit(gpa.allocator());

        var iter = key_bindings.iterator();
        while (iter.next()) |kb| {
            kb.value_ptr.deinit(gpa.allocator());
        }
        key_bindings.deinit(gpa.allocator());
    }

    wl_globals = .{};
    wl_registry = try wl_connection.getRegistry();
    wl_registry.on_event = onRegistryEvent;

    try wl_connection.dispatchUntilSync();
    if (wl_globals.wl_compositor == null or wl_globals.xdg_wm_base == null or wl_globals.zwp_linux_dmabuf_v1 == null) {
        return error.MissingWaylandProtocol;
    }

    wl_globals.xdg_wm_base.?.on_event = onXdgWmBaseEvent;

    // init this
    {
        var library_prefixes = try getLibrarySearchPaths(gpa.allocator());
        defer library_prefixes.arena.deinit();

        egl = try EGL.loadUsingPrefixes(library_prefixes.paths.items);
    }
    defer {
        egl.deinit();
    }

    egl_mesa_image_dma_buf_export = try EGL.loadExtension(EGL.MESA.image_dma_buf_export, egl.functions);
    egl_khr_image_base = try EGL.loadExtension(EGL.KHR.image_base, egl.functions);

    egl_display = egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.EGLGetDisplay;
    };
    _ = try egl_display.initialize();
    defer egl_display.terminate();

    evdev = try EvDev.init(gpa.allocator(), .{});
    defer evdev.deinit();

    try evdev.scanForDevices();

    // Call root module's `init()` function
    root.init() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    while (windows.items.len > 0) {
        // TODO: bring all file waiting together
        try wl_connection.dispatchUntilSync();
        evdev.updateEventDevices() catch |err| {
            std.debug.print("{s}\n", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            break;
        };
        {
            var i: usize = windows.items.len;
            while (i > 0) : (i -= 1) {
                const window = windows.items[i - 1];
                if (window.should_close) {
                    _ = windows.swapRemove(i - 1);
                    window.destroy();
                }
            }
        }
        for (windows.items) |window| {
            if (window.should_render) {
                try window.render();
            }
        }
    }
}

fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

const Globals = struct {
    wl_compositor: ?*wayland.wayland.wl_compositor = null,
    xdg_wm_base: ?*xdg_shell.xdg_wm_base = null,
    zwp_linux_dmabuf_v1: ?*linux_dmabuf_v1.zwp_linux_dmabuf_v1 = null,
};

fn onRegistryEvent(registry: *wayland.wayland.wl_registry, userdata: ?*anyopaque, event: wayland.wayland.wl_registry.Event) void {
    _ = userdata;
    switch (event) {
        .global => |global| {
            std.log.debug("{s}:{} global {} = {?s} v{}", .{ @src().file, @src().line, global.name, global.interface, global.version });
            const global_interface = global.interface orelse return;
            if (std.mem.eql(u8, global_interface, wayland.wayland.wl_compositor.INTERFACE.name) and global.version >= wayland.wayland.wl_compositor.INTERFACE.version) {
                wl_globals.wl_compositor = registry.bind(wayland.wayland.wl_compositor, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, xdg_shell.xdg_wm_base.INTERFACE.name) and global.version >= xdg_shell.xdg_wm_base.INTERFACE.version) {
                wl_globals.xdg_wm_base = registry.bind(xdg_shell.xdg_wm_base, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.name) and global.version >= linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.version) {
                wl_globals.zwp_linux_dmabuf_v1 = registry.bind(linux_dmabuf_v1.zwp_linux_dmabuf_v1, global.name) catch return;
            } else if (std.mem.eql(u8, global_interface, wayland.wayland.wl_seat.INTERFACE.name) and global.version >= wayland.wayland.wl_seat.INTERFACE.version) {
                seats.ensureUnusedCapacity(gpa.allocator(), 1) catch return;

                const seat = gpa.allocator().create(Seat) catch return;
                const wl_seat = registry.bind(wayland.wayland.wl_seat, global.name) catch {
                    gpa.allocator().destroy(seat);
                    return;
                };
                seat.* = .{
                    .wl_seat = wl_seat,
                };
                seat.wl_seat.userdata = seat;
                seat.wl_seat.on_event = Seat.onSeatCallback;
                seats.appendAssumeCapacity(seat);
            }
        },
        .global_remove => {},
    }
}

pub fn createWindow(options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
    const size = if (options.size) |s| [2]c_int{ @intCast(s[0]), @intCast(s[1]) } else [2]c_int{ 640, 480 };

    const wl_surface = try wl_globals.wl_compositor.?.create_surface();
    const xdg_surface = try wl_globals.xdg_wm_base.?.get_xdg_surface(wl_surface);
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

    const configs_buffer = try gpa.allocator().alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer gpa.allocator().free(configs_buffer);

    const configs_len = try egl_display.chooseConfig(&attrib_list, configs_buffer);
    const configs = configs_buffer[0..configs_len];

    try egl.bindAPI(.opengl_es);
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 3,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = try egl_display.createContext(configs[0], null, &context_attrib_list);

    try egl_display.makeCurrent(null, null, egl_context);

    const window = try gpa.allocator().create(Window);
    errdefer gpa.allocator().destroy(window);

    window.* = .{
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

    const loader = GlBindingLoader{ .egl = egl };
    window.gl_binding.init(loader);
    gl.makeBindingCurrent(&window.gl_binding);

    window.xdg_surface.userdata = window;
    window.xdg_toplevel.userdata = window;
    window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
    window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;
    try wl_connection.dispatchUntilSync();

    try windows.append(gpa.allocator(), window);

    return window.window();
}

pub const GlBindingLoader = struct {
    egl: EGL,
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

fn onXdgWmBaseEvent(xdg_wm_base: *xdg_shell.xdg_wm_base, userdata: ?*anyopaque, event: xdg_shell.xdg_wm_base.Event) void {
    _ = userdata;
    switch (event) {
        .ping => |conf| {
            std.log.debug("ping!", .{});
            xdg_wm_base.pong(conf.serial) catch |e| {
                std.log.warn("Failed to ack configure: {}", .{e});
            };
        },
    }
}

fn onWPLinuxDMABUF_SurfaceFeedback(feedback: *linux_dmabuf_v1.zwp_linux_dmabuf_feedback_v1, userdata: ?*anyopaque, event: linux_dmabuf_v1.zwp_linux_dmabuf_feedback_v1.Event) void {
    _ = feedback;
    _ = userdata;
    switch (event) {
        .done => std.log.debug("dmabuf feedback done = {}", .{event}),
        .format_table => |ft| std.log.debug("dmabuf feedback format_table = fd@{}, {} bytes", .{ ft.fd, ft.size }),
        .main_device => |main_device| {
            if (main_device.device.len == @sizeOf(std.os.linux.dev_t)) {
                var device: std.os.linux.dev_t = undefined;
                @memcpy(std.mem.asBytes(&device), main_device.device);
                std.log.debug("dmabuf feedback main_device = {}", .{device});
            } else {
                std.log.debug("dmabuf feedback main_device = \"{}\"", .{std.zig.fmtEscapes(main_device.device)});
            }
        },
        .tranche_formats => |tranche_formats| {
            const formats: []const u16 = @as([*]const u16, @ptrCast(@alignCast(tranche_formats.indices.ptr)))[0 .. tranche_formats.indices.len / @sizeOf(u16)];
            std.log.debug("dmabuf feedback tranche formats = {any}", .{formats});
        },
        else => std.log.debug("dmabuf feedback {}", .{event}),
    }
}

const Window = struct {
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
            f.destroy();
        }
        for (this.free_framebuffers.slice()) |f| {
            f.destroy();
        }

        this.wl_surface.destroy() catch {};

        gpa.allocator().destroy(this);
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
            framebuffer.destroy();
        }

        const framebuffer = try this.createFramebuffer(size);
        try this.framebuffers.append(framebuffer);
        return framebuffer;
    }

    pub fn createFramebuffer(this_window: *Window, size: [2]c_int) !*Framebuffer {
        const framebuffer = try gpa.allocator().create(Framebuffer);
        framebuffer.* = .{
            .allocator = gpa.allocator(),
            .window = this_window,
            .wl_buffer = null,
            .egl_image = undefined,
            .size = size,
        };
        errdefer framebuffer.destroy();

        gl.genRenderbuffers(framebuffer.gl_render_buffers.len, &framebuffer.gl_render_buffers);
        gl.genFramebuffers(framebuffer.gl_framebuffer_objects.len, &framebuffer.gl_framebuffer_objects);

        gl.bindRenderbuffer(gl.RENDERBUFFER, framebuffer.gl_render_buffers[0]);
        gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGB8, size[0], size[1]);

        gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer.gl_framebuffer_objects[0]);
        gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, framebuffer.gl_render_buffers[0]);

        framebuffer.egl_image = try egl_khr_image_base.createImage(
            egl_display,
            this_window.egl_context,
            .gl_renderbuffer,
            @ptrFromInt(@as(usize, @intCast(framebuffer.gl_render_buffers[0]))),
            null,
        );

        const dmabuf_image = try egl_mesa_image_dma_buf_export.exportImageAlloc(gpa.allocator(), egl_display, framebuffer.egl_image);
        defer dmabuf_image.deinit();

        const wl_dmabuf_buffer_params = try wl_globals.zwp_linux_dmabuf_v1.?.create_params();
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

    pub fn destroy(framebuffer: *Framebuffer) void {
        if (framebuffer.wl_buffer) |wl_buffer| wl_buffer.destroy() catch {};
        egl_khr_image_base.destroyImage(egl_display, framebuffer.egl_image) catch {};
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

pub fn addButtonInput(options: seizer.Platform.AddButtonInputOptions) anyerror!void {
    try evdev.addButtonInput(options);

    for (options.default_bindings) |button_code| {
        switch (button_code) {
            .gamepad => {},
            .keyboard => |key| {
                const gop = try key_bindings.getOrPut(gpa.allocator(), .{ .keyboard = key });
                if (!gop.found_existing) {
                    gop.value_ptr.* = .{};
                }
                try gop.value_ptr.append(gpa.allocator(), options);
            },
        }
    }
}

const Seat = struct {
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
        _ = this;
        _ = seat;
        switch (event) {
            .key => |k| {
                const key: EvDev.KEY = @enumFromInt(@as(u16, @intCast(k.key)));

                const actions = key_bindings.get(.{ .keyboard = key }) orelse return;
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

pub fn writeFile(options: seizer.Platform.WriteFileOptions) void {
    linuxbsd_fs.writeFile(gpa.allocator(), options);
}

pub fn readFile(options: seizer.Platform.ReadFileOptions) void {
    linuxbsd_fs.readFile(gpa.allocator(), options);
}

const LibraryPaths = struct {
    arena: std.heap.ArenaAllocator,
    paths: std.ArrayListUnmanaged([]const u8),
};

pub fn getLibrarySearchPaths(allocator: std.mem.Allocator) !LibraryPaths {
    var path_arena_allocator = std.heap.ArenaAllocator.init(allocator);
    errdefer path_arena_allocator.deinit();
    const arena = path_arena_allocator.allocator();

    var prefixes_to_try = std.ArrayList([]const u8).init(arena);

    try prefixes_to_try.append(try arena.dupe(u8, "."));
    try prefixes_to_try.append(try arena.dupe(u8, ""));
    try prefixes_to_try.append(try arena.dupe(u8, "/usr/lib/"));
    if (std.process.getEnvVarOwned(arena, "NIX_LD_LIBRARY_PATH")) |path_list| {
        var path_list_iter = std.mem.tokenize(u8, path_list, ":");
        while (path_list_iter.next()) |path| {
            try prefixes_to_try.append(path);
        }
    } else |_| {}

    var path_buf: [std.fs.MAX_PATH_BYTES]u8 = undefined;
    const exe_dir_path = try std.fs.selfExeDirPath(&path_buf);
    var dir_to_search_opt: ?[]const u8 = exe_dir_path;
    while (dir_to_search_opt) |dir_to_search| : (dir_to_search_opt = std.fs.path.dirname(dir_to_search)) {
        try prefixes_to_try.append(try std.fs.path.join(arena, &.{ dir_to_search, "lib" }));
    }

    return LibraryPaths{
        .arena = path_arena_allocator,
        .paths = prefixes_to_try.moveToUnmanaged(),
    };
}

const EvDev = @import("./linuxbsd/evdev.zig");

const linuxbsd_fs = @import("./linuxbsd/fs.zig");

const linux_dmabuf_v1 = @import("wayland-protocols").stable.@"linux-dmabuf-v1";
const xdg_shell = @import("wayland-protocols").stable.@"xdg-shell";
const wayland = @import("wayland");
const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

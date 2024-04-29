egl: EGL,
egl_mesa_image_dma_buf_export: EGL.MESA.image_dma_buf_export,
egl_display: EGL.Display,
evdev: EvDev,
windows: std.ArrayListUnmanaged(*Window),
wl_connection: wayland.Conn,
wl_registry: *wayland.core.Registry,
wl_globals: Globals,

const Linux = @This();

pub const BACKEND = seizer.backend.Backend{
    .name = "wayland",
    .main = main,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
};

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const this = try gpa.allocator().create(@This());
    defer gpa.allocator().destroy(this);

    // init wayland connection
    const conn_path = try wayland.getDisplayPath(gpa.allocator());
    defer gpa.allocator().free(conn_path);

    this.wl_connection = try wayland.Conn.init(gpa.allocator(), conn_path);
    defer this.wl_connection.deinit();

    this.wl_registry = try this.wl_connection.getRegistry();
    this.wl_registry.userdata = &this.wl_globals;
    this.wl_registry.on_event = Globals.onRegistryEvent;

    try this.wl_connection.dispatchUntilSync();
    if (this.wl_globals.wl_compositor == null or this.wl_globals.xdg_wm_base == null or this.wl_globals.zwp_linux_dmabuf_v1 == null) {
        return error.MissingWaylandProtocol;
    }

    this.wl_globals.xdg_wm_base.?.on_event = onXdgWmBaseEvent;

    // init this
    {
        var library_prefixes = try seizer.backend.getLibrarySearchPaths(gpa.allocator());
        defer library_prefixes.arena.deinit();

        this.egl = try EGL.loadUsingPrefixes(library_prefixes.paths.items);
    }
    defer {
        this.egl.deinit();
    }

    this.egl_mesa_image_dma_buf_export = try EGL.loadExtension(EGL.MESA.image_dma_buf_export, this.egl.functions);

    this.egl_display = this.egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.EGLGetDisplay;
    };
    _ = try this.egl_display.initialize();
    defer this.egl_display.terminate();

    this.evdev = try EvDev.init(gpa.allocator(), .{});
    defer this.evdev.deinit();

    try this.evdev.scanForDevices();

    this.windows = .{};
    defer this.windows.deinit(gpa.allocator());

    var seizer_context = seizer.Context{
        .gpa = gpa.allocator(),
        .backend_userdata = this,
        .backend = &BACKEND,
    };

    // Call root module's `init()` function
    root.init(&seizer_context) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    while (this.windows.items.len > 0) {
        // TODO: bring all file waiting together
        try this.wl_connection.dispatchUntilSync();
        this.evdev.updateEventDevices() catch |err| {
            std.debug.print("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            break;
        };
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
            gl.makeBindingCurrent(&window.gl_binding);
            window.on_render(window.window()) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                break;
            };
            window.swapBuffers();
        }
    }
}

const Globals = struct {
    wl_compositor: ?*wayland.core.Compositor = null,
    xdg_wm_base: ?*wayland.xdg_shell.xdg_wm_base = null,
    zwp_linux_dmabuf_v1: ?*wayland.linux_dmabuf_v1.zwp_linux_dmabuf_v1 = null,

    fn onRegistryEvent(registry: *wayland.core.Registry, userdata: ?*anyopaque, event: wayland.core.Registry.Event) void {
        const this: *Globals = @ptrCast(@alignCast(userdata));
        switch (event) {
            .global => |global| {
                std.log.debug("{s}:{} global {} = {s} v{}", .{ @src().file, @src().line, global.name, global.interface, global.version });
                if (std.mem.eql(u8, global.interface, wayland.core.Compositor.INTERFACE.name) and global.version >= wayland.core.Compositor.INTERFACE.version) {
                    this.wl_compositor = registry.bind(wayland.core.Compositor, global.name) catch return;
                } else if (std.mem.eql(u8, global.interface, wayland.xdg_shell.xdg_wm_base.INTERFACE.name) and global.version >= wayland.xdg_shell.xdg_wm_base.INTERFACE.version) {
                    this.xdg_wm_base = registry.bind(wayland.xdg_shell.xdg_wm_base, global.name) catch return;
                } else if (std.mem.eql(u8, global.interface, wayland.linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.name) and global.version >= wayland.linux_dmabuf_v1.zwp_linux_dmabuf_v1.INTERFACE.version) {
                    this.zwp_linux_dmabuf_v1 = registry.bind(wayland.linux_dmabuf_v1.zwp_linux_dmabuf_v1, global.name) catch return;
                }
            },
            .global_remove => {},
        }
    }
};

pub fn createWindow(context: *seizer.Context, options: seizer.Context.CreateWindowOptions) anyerror!seizer.Window {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));

    const size = if (options.size) |s| [2]c_int{ @intCast(s[0]), @intCast(s[1]) } else [2]c_int{ 640, 480 };

    const wl_surface = try this.wl_globals.wl_compositor.?.create_surface();

    const xdg_surface = try this.wl_globals.xdg_wm_base.?.get_xdg_surface(wl_surface);
    xdg_surface.on_event = onXdgSurfaceEvent;

    const xdg_toplevel = try xdg_surface.get_toplevel();
    xdg_toplevel.on_event = onXdgToplevelEvent;

    try wl_surface.commit();

    // const surface_feedback = try this.wl_globals.zwp_linux_dmabuf_v1.?.get_surface_feedback(wl_surface);
    // surface_feedback.on_event = onWPLinuxDMABUF_SurfaceFeedback;

    // try this.wl_connection.dispatchUntilSync();

    var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        // @intFromEnum(EGL.Attrib.surface_type),    EGL.WINDOW_BIT,
        @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
        @intFromEnum(EGL.Attrib.red_size),        8,
        @intFromEnum(EGL.Attrib.blue_size),       8,
        @intFromEnum(EGL.Attrib.green_size),      8,
        @intFromEnum(EGL.Attrib.none),
    };
    const num_configs = try this.egl_display.chooseConfig(&attrib_list, null);

    if (num_configs == 0) {
        return error.NoSuitableConfigs;
    }

    const configs_buffer = try context.gpa.alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer context.gpa.free(configs_buffer);

    const configs_len = try this.egl_display.chooseConfig(&attrib_list, configs_buffer);
    const configs = configs_buffer[0..configs_len];

    // const surface = try this.egl_display.createWindowSurface(configs[0], null, null);

    try this.egl.bindAPI(.opengl_es);
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 2,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = try this.egl_display.createContext(configs[0], null, &context_attrib_list);

    try this.egl_display.makeCurrent(null, null, egl_context);

    const window = try context.gpa.create(Window);
    errdefer context.gpa.destroy(window);

    window.* = .{
        .allocator = context.gpa,
        .egl_display = this.egl_display,
        .egl_context = egl_context,
        .wl_surface = wl_surface,
        .xdg_surface = xdg_surface,
        .xdg_toplevel = xdg_toplevel,
        .wl_buffer = undefined,
        .should_close = false,

        .gl_framebuffer_object = undefined,

        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,

        .window_size = size,
    };

    const loader = GlBindingLoader{ .egl = this.egl };
    window.gl_binding.init(loader);
    gl.makeBindingCurrent(&window.gl_binding);

    var render_buffers: [1]gl.Uint = undefined;
    gl.genRenderbuffers(render_buffers.len, &render_buffers);
    gl.bindRenderbuffer(gl.RENDERBUFFER, render_buffers[0]);
    gl.renderbufferStorage(gl.RENDERBUFFER, gl.RGB8, size[0], size[1]);

    var framebuffer_objects: [1]gl.Uint = undefined;
    gl.genFramebuffers(framebuffer_objects.len, &framebuffer_objects);
    gl.bindFramebuffer(gl.FRAMEBUFFER, framebuffer_objects[0]);
    gl.framebufferRenderbuffer(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.RENDERBUFFER, render_buffers[0]);
    window.gl_framebuffer_object = framebuffer_objects[0];

    const egl_image = this.egl.functions.eglCreateImage(
        this.egl_display.ptr,
        window.egl_context.ptr,
        .gl_renderbuffer,
        @ptrFromInt(@as(usize, @intCast(render_buffers[0]))),
        null,
    );

    var fourcc: c_int = undefined;
    var num_planes: c_int = undefined;
    _ = this.egl_mesa_image_dma_buf_export.eglExportDMABUFImageQueryMESA(
        this.egl_display.ptr,
        @ptrCast(egl_image.?),
        &fourcc,
        &num_planes,
        null,
    );
    std.log.debug("fourcc = {}, num_planes = {}", .{ fourcc, num_planes });

    var dmabuf_fd: [1]c_int = undefined;
    var stride: [1]EGL.Int = undefined;
    var offset: [1]EGL.Int = undefined;
    _ = this.egl_mesa_image_dma_buf_export.eglExportDMABUFImageMESA(
        this.egl_display.ptr,
        @ptrCast(egl_image.?),
        &dmabuf_fd,
        &stride,
        &offset,
    );
    std.log.debug("dmabuf = {}, stride = {}, offset = {}", .{ dmabuf_fd[0], stride[0], offset[0] });

    try this.wl_connection.dispatchUntilSync();
    // window.wl_surface.userdata = window;
    window.xdg_surface.userdata = window;
    window.xdg_toplevel.userdata = window;
    // window.wl_surface.on_event = Window.onWlSurfaceEvent;
    window.xdg_surface.on_event = Window.onXdgSurfaceEvent;
    window.xdg_toplevel.on_event = Window.onXdgToplevelEvent;

    const wl_dmabuf_buffer_params = try this.wl_globals.zwp_linux_dmabuf_v1.?.create_params();
    try wl_dmabuf_buffer_params.add(@enumFromInt(dmabuf_fd[0]), 0, @intCast(offset[0]), @intCast(stride[0]), 0, 0);
    window.wl_buffer = try wl_dmabuf_buffer_params.create_immed(@intCast(size[0]), @intCast(size[1]), @intCast(fourcc), .{ .y_invert = false, .interlaced = false, .bottom_first = false });

    try window.wl_surface.attach(window.wl_buffer, 0, 0);
    try window.wl_surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32));
    try window.wl_surface.commit();

    try this.wl_connection.dispatchUntilSync();

    gl.viewport(0, 0, size[0], size[1]);

    try this.windows.append(context.gpa, window);

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

fn onXdgWmBaseEvent(xdg_wm_base: *wayland.xdg_shell.xdg_wm_base, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_wm_base.Event) void {
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

fn onXdgSurfaceEvent(xdg_surface: *wayland.xdg_shell.xdg_surface, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_surface.Event) void {
    _ = userdata;
    switch (event) {
        .configure => |conf| {
            xdg_surface.ack_configure(conf.serial) catch |e| {
                std.log.warn("Failed to ack configure: {}", .{e});
            };
        },
    }
}

fn onXdgToplevelEvent(xdg_toplevel: *wayland.xdg_shell.xdg_toplevel, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_toplevel.Event) void {
    _ = xdg_toplevel;
    _ = userdata;
    switch (event) {
        else => std.log.debug("{}", .{event}),
    }
}

fn onWPLinuxDMABUF_SurfaceFeedback(feedback: *wayland.linux_dmabuf_v1.zwp_linux_dmabuf_feedback_v1, userdata: ?*anyopaque, event: wayland.linux_dmabuf_v1.zwp_linux_dmabuf_feedback_v1.Event) void {
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
    allocator: std.mem.Allocator,
    egl_display: EGL.Display,
    egl_context: EGL.Context,
    wl_surface: *wayland.core.Surface,
    xdg_surface: *wayland.xdg_shell.xdg_surface,
    xdg_toplevel: *wayland.xdg_shell.xdg_toplevel,
    wl_buffer: *wayland.core.Buffer,
    should_close: bool,

    gl_framebuffer_object: gl.Uint,

    gl_binding: gl.Binding,
    on_render: *const fn (seizer.Window) anyerror!void,
    on_destroy: ?*const fn (seizer.Window) void,

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
        // this.display.destroySurface(this.surface);
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

        return .{ @floatFromInt(this.window_size[0]), @floatFromInt(this.window_size[1]) };
    }

    pub fn swapBuffers(this: *@This()) void {
        // _ = this;
        this.wl_surface.damage(0, 0, std.math.maxInt(i32), std.math.maxInt(i32)) catch {};
        this.wl_surface.commit() catch {};
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }

    fn onXdgSurfaceEvent(xdg_surface: *wayland.xdg_shell.xdg_surface, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_surface.Event) void {
        _ = userdata;
        switch (event) {
            .configure => |conf| {
                xdg_surface.ack_configure(conf.serial) catch |e| {
                    std.log.warn("Failed to ack configure: {}", .{e});
                };
            },
        }
    }

    fn onXdgToplevelEvent(xdg_toplevel: *wayland.xdg_shell.xdg_toplevel, userdata: ?*anyopaque, event: wayland.xdg_shell.xdg_toplevel.Event) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        _ = xdg_toplevel;
        switch (event) {
            .close => this.should_close = true,
            else => std.log.debug("{}", .{event}),
        }
    }
};

pub fn addButtonInput(context: *seizer.Context, options: seizer.Context.AddButtonInputOptions) anyerror!void {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));
    try this.evdev.addButtonInput(options);
}

const EvDev = @import("./linux/evdev.zig");

const wayland = @import("wayland");
const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

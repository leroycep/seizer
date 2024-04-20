egl: EGL,
display: EGL.Display,

const Linux = @This();

pub const BACKEND = seizer.backend.Backend{
    .name = "linux",
    .main = main,
    .createWindow = createWindow,
};

pub fn main() bool {
    // const seizer = @import("../seizer.zig");
    // const gl = seizer.gl;
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const this = gpa.allocator().create(@This()) catch return true;
    defer gpa.allocator().destroy(this);

    // init this
    {
        var library_prefixes = seizer.backend.getLibrarySearchPaths(gpa.allocator()) catch return true;
        defer library_prefixes.arena.deinit();

        this.egl = EGL.loadUsingPrefixes(library_prefixes.paths.items) catch |err| {
            std.log.warn("Failed to load EGL: {}", .{err});
            return true;
        };
    }
    defer {
        this.egl.deinit();
    }

    this.display = this.egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return true;
    };
    _ = this.display.initialize() catch |err| {
        std.log.warn("Failed to initialize EGL display: {}", .{err});
        return true;
    };
    defer this.display.terminate();

    var seizer_context = seizer.Context{
        .gpa = gpa.allocator(),
        .backend_userdata = this,
        .backend = &BACKEND,
    };
    defer seizer_context.deinit();

    // Call root module's `init()` function
    root.init(&seizer_context) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return false;
    };
    while (true) {
        for (seizer_context.windows.items) |window| {
            gl.makeBindingCurrent(&window.gl_binding);
            window.on_render(window) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                return false;
            };
            window.swapBuffers();
        }
    }

    return false;
}

pub fn createWindow(context: *seizer.Context, options: seizer.Context.CreateWindowOptions) anyerror!*seizer.Window {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));

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

    const configs_buffer = try context.gpa.alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer context.gpa.free(configs_buffer);

    const configs_len = try this.display.chooseConfig(&attrib_list, configs_buffer);
    const configs = configs_buffer[0..configs_len];

    const surface = try this.display.createWindowSurface(configs[0], null, null);

    try this.egl.bindAPI(.opengl_es);
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 2,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = try this.display.createContext(configs[0], null, &context_attrib_list);

    try this.display.makeCurrent(surface, surface, egl_context);

    const window = try context.gpa.create(seizer.Window);
    errdefer context.gpa.destroy(window);

    const linux_window = try context.gpa.create(Window);
    errdefer context.gpa.destroy(linux_window);

    linux_window.* = .{
        .display = this.display,
        .surface = surface,
        .egl_context = egl_context,
    };

    window.* = .{
        .pointer = linux_window,
        .interface = &Window.INTERFACE,
        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };
    const loader = GlBindingLoader{ .egl = this.egl };
    window.gl_binding.init(loader);
    gl.makeBindingCurrent(&window.gl_binding);

    gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

    try context.windows.append(context.gpa, window);

    return window;
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

const Window = struct {
    display: EGL.Display,
    surface: EGL.Surface,
    egl_context: EGL.Context,

    pub const INTERFACE = seizer.Window.Interface{
        .destroy = destroy,
        .getSize = getSize,
        .getFramebufferSize = getSize,
        .swapBuffers = swapBuffers,
    };

    pub fn destroy(userdata: ?*anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.display.destroySurface(this.surface);
    }

    pub fn getSize(userdata: ?*anyopaque) [2]f32 {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));

        const width = this.display.querySurface(this.surface, .width) catch unreachable;
        const height = this.display.querySurface(this.surface, .height) catch unreachable;

        return .{ @floatFromInt(width), @floatFromInt(height) };
    }

    pub fn swapBuffers(userdata: ?*anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.display.swapBuffers(this.surface) catch |err| {
            std.log.warn("failed to swap buffers: {}", .{err});
        };
    }
};

const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const std = @import("std");

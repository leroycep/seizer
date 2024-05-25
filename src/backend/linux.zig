egl: EGL,
display: EGL.Display,
evdev: EvDev,
windows: std.ArrayListUnmanaged(*Window),

const Linux = @This();

pub const BACKEND = seizer.backend.Backend{
    .name = "linux",
    .main = main,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
    .write_file_fn = writeFile,
    .read_file_fn = readFile,
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

    // init this
    {
        var library_prefixes = try seizer.backend.getLibrarySearchPaths(gpa.allocator());
        defer library_prefixes.arena.deinit();

        this.egl = EGL.loadUsingPrefixes(library_prefixes.paths.items) catch |err| {
            std.log.warn("Failed to load EGL: {}", .{err});
            return err;
        };
    }
    defer {
        this.egl.deinit();
    }

    this.display = this.egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.NoDisplay;
    };
    _ = try this.display.initialize();
    defer this.display.terminate();

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
        this.evdev.updateEventDevices() catch |err| {
            std.debug.print("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return;
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
                return;
            };
            window.swapBuffers();
        }
    }
}

pub fn createWindow(context: *seizer.Context, options: seizer.Context.CreateWindowOptions) anyerror!seizer.Window {
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

    const linux_window = try context.gpa.create(Window);
    errdefer context.gpa.destroy(linux_window);

    linux_window.* = .{
        .allocator = context.gpa,
        .display = this.display,
        .surface = surface,
        .egl_context = egl_context,
        .should_close = false,

        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };

    const loader = GlBindingLoader{ .egl = this.egl };
    linux_window.gl_binding.init(loader);
    gl.makeBindingCurrent(&linux_window.gl_binding);

    gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

    try this.windows.append(context.gpa, linux_window);

    return linux_window.window();
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
    allocator: std.mem.Allocator,
    display: EGL.Display,
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
        this.display.destroySurface(this.surface);
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

        const width = this.display.querySurface(this.surface, .width) catch unreachable;
        const height = this.display.querySurface(this.surface, .height) catch unreachable;

        return .{ @floatFromInt(width), @floatFromInt(height) };
    }

    pub fn swapBuffers(this: *@This()) void {
        this.display.swapBuffers(this.surface) catch |err| {
            std.log.warn("failed to swap buffers: {}", .{err});
        };
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }
};

pub fn addButtonInput(context: *seizer.Context, options: seizer.Context.AddButtonInputOptions) anyerror!void {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));
    try this.evdev.addButtonInput(options);
}

pub fn writeFile(ctx: *seizer.Context, options: seizer.Context.WriteFileOptions) void {
    if (writeFileWithError(ctx, options)) {
        options.callback(options.userdata, {});
    } else |err| {
        switch (err) {
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn writeFileWithError(ctx: *seizer.Context, options: seizer.Context.WriteFileOptions) !void {
    const app_data_dir_path = try std.fs.getAppDataDir(ctx.gpa, options.appname);
    defer ctx.gpa.free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    try app_data_dir.writeFile2(.{
        .sub_path = options.path,
        .data = options.data,
    });
}

pub fn readFile(ctx: *seizer.Context, options: seizer.Context.ReadFileOptions) void {
    if (readFileWithError(ctx, options)) |read_bytes| {
        options.callback(options.userdata, read_bytes);
    } else |err| {
        switch (err) {
            error.FileNotFound => options.callback(options.userdata, error.NotFound),
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn readFileWithError(ctx: *seizer.Context, options: seizer.Context.ReadFileOptions) ![]u8 {
    const app_data_dir_path = try std.fs.getAppDataDir(ctx.gpa, options.appname);
    defer ctx.gpa.free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    const read_buffer = try app_data_dir.readFile(options.path, options.buffer);
    return read_buffer;
}

const EvDev = @import("./linux/evdev.zig");

const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

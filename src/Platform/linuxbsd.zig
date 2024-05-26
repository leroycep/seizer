pub const PLATFORM = seizer.Platform{
    .name = "linuxbsd",
    .main = main,
    .gl = @import("gl"),
    .allocator = getAllocator,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
    .writeFile = writeFile,
    .readFile = readFile,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var egl: EGL = undefined;
var display: EGL.Display = undefined;
var evdev: EvDev = undefined;
var windows: std.ArrayListUnmanaged(*Window) = .{};

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    defer _ = gpa.deinit();

    const this = try gpa.allocator().create(@This());
    defer gpa.allocator().destroy(this);

    // init this
    {
        var library_prefixes = try getLibrarySearchPaths(gpa.allocator());
        defer library_prefixes.arena.deinit();

        egl = EGL.loadUsingPrefixes(library_prefixes.paths.items) catch |err| {
            std.log.warn("Failed to load EGL: {}", .{err});
            return err;
        };
    }
    defer {
        egl.deinit();
    }

    display = egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.NoDisplay;
    };
    _ = try display.initialize();
    defer display.terminate();

    evdev = try EvDev.init(gpa.allocator(), .{});
    defer evdev.deinit();

    try evdev.scanForDevices();

    windows = .{};
    defer windows.deinit(gpa.allocator());

    // Call root module's `init()` function
    root.init() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    while (windows.items.len > 0) {
        evdev.updateEventDevices() catch |err| {
            std.debug.print("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return;
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

pub fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn createWindow(options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
    var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.surface_type),    EGL.WINDOW_BIT,
        @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
        @intFromEnum(EGL.Attrib.red_size),        8,
        @intFromEnum(EGL.Attrib.blue_size),       8,
        @intFromEnum(EGL.Attrib.green_size),      8,
        @intFromEnum(EGL.Attrib.none),
    };
    const num_configs = try display.chooseConfig(&attrib_list, null);

    if (num_configs == 0) {
        return error.NoSuitableConfigs;
    }

    const configs_buffer = try gpa.allocator().alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer gpa.allocator().free(configs_buffer);

    const configs_len = try display.chooseConfig(&attrib_list, configs_buffer);
    const configs = configs_buffer[0..configs_len];

    const surface = try display.createWindowSurface(configs[0], null, null);

    try egl.bindAPI(.opengl_es);
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 2,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = try display.createContext(configs[0], null, &context_attrib_list);

    try display.makeCurrent(surface, surface, egl_context);

    const linux_window = try gpa.allocator().create(Window);
    errdefer gpa.allocator().destroy(linux_window);

    linux_window.* = .{
        .surface = surface,
        .egl_context = egl_context,
        .should_close = false,

        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };

    const loader = GlBindingLoader{};
    linux_window.gl_binding.init(loader);
    gl.makeBindingCurrent(&linux_window.gl_binding);

    gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

    try windows.append(gpa.allocator(), linux_window);

    return linux_window.window();
}

pub const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(this: @This(), command_name: [:0]const u8) ?AnyCFnPtr {
        _ = this;
        return egl.functions.eglGetProcAddress(command_name);
    }

    pub fn extensionSupported(this: @This(), extension_name: [:0]const u8) bool {
        _ = this;
        _ = extension_name;
        return true;
    }
};

const Window = struct {
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
        display.destroySurface(this.surface);
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

        const width = display.querySurface(this.surface, .width) catch unreachable;
        const height = display.querySurface(this.surface, .height) catch unreachable;

        return .{ @floatFromInt(width), @floatFromInt(height) };
    }

    pub fn swapBuffers(this: *@This()) void {
        display.swapBuffers(this.surface) catch |err| {
            std.log.warn("failed to swap buffers: {}", .{err});
        };
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }
};

pub fn addButtonInput(options: seizer.Platform.AddButtonInputOptions) anyerror!void {
    try evdev.addButtonInput(options);
}

pub fn writeFile(options: seizer.Platform.WriteFileOptions) void {
    if (writeFileWithError(options)) {
        options.callback(options.userdata, {});
    } else |err| {
        switch (err) {
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn writeFileWithError(options: seizer.Platform.WriteFileOptions) !void {
    const app_data_dir_path = try std.fs.getAppDataDir(gpa.allocator(), options.appname);
    defer gpa.allocator().free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    try app_data_dir.writeFile2(.{
        .sub_path = options.path,
        .data = options.data,
    });
}

pub fn readFile(options: seizer.Platform.ReadFileOptions) void {
    if (readFileWithError(options)) |read_bytes| {
        options.callback(options.userdata, read_bytes);
    } else |err| {
        switch (err) {
            error.FileNotFound => options.callback(options.userdata, error.NotFound),
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn readFileWithError(options: seizer.Platform.ReadFileOptions) ![]u8 {
    const app_data_dir_path = try std.fs.getAppDataDir(gpa.allocator(), options.appname);
    defer gpa.allocator().free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    const read_buffer = try app_data_dir.readFile(options.path, options.buffer);
    return read_buffer;
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

pub const EvDev = @import("./linuxbsd/evdev.zig");

const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

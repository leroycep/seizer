pub const mach_glfw = @import("mach-glfw");
pub usingnamespace mach_glfw;

pub const SEIZER_BACKEND = @import("../seizer.zig").backend.Backend{
    .main = seizer_backend_main(),
};
pub fn seizer_backend_main() !void {
    const seizer = @import("../seizer.zig");
    const gl = seizer.gl;
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa.allocator());

    _ = seizer.backend.glfw.setErrorCallback(defaultErrorCallback);

    if (!seizer.backend.glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}\n", .{seizer.backend.glfw.getErrorString()});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.terminate();

    // Make a context object
    var context = seizer.Context{ .gpa = gpa.allocator() };
    defer context.deinit();

    // Call root module's `init()` function
    try root.init(&context);

    while (context.anyWindowsOpen()) {
        mach_glfw.pollEvents();
        for (context.windows.items) |window| {
            gl.makeBindingCurrent(&window.gl_binding);
            try window.on_render(window);
            window.glfw_window.swapBuffers();
        }
    }
}

pub fn seizer_context_createWindow(context: *@import("../seizer.zig").Context, options: @import("../seizer.zig").Context.CreateWindowOptions) anyerror!*@import("../seizer.zig").Window {
    const seizer = @import("../seizer.zig");
    const gl = seizer.gl;

    try context.windows.ensureUnusedCapacity(context.gpa, 1);

    const window = try context.gpa.create(seizer.Window);
    errdefer context.gpa.destroy(window);

    const glfw_window = seizer.backend.glfw.Window.create(options.size[0], options.size[1], options.title, null, null, .{}) orelse return error.GlfwCreateWindow;
    errdefer glfw_window.destroy();

    seizer.backend.glfw.makeContextCurrent(glfw_window);

    window.* = .{
        .glfw_window = glfw_window,
        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };
    window.gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&window.gl_binding);

    context.windows.appendAssumeCapacity(window);

    const callbacks = struct {
        fn framebuffer_size(_: mach_glfw.Window, width: u32, height: u32) void {
            gl.viewport(
                0,
                0,
                @intCast(width),
                @intCast(height),
            );
        }
    };
    // Set up input callbacks
    glfw_window.setFramebufferSizeCallback(callbacks.framebuffer_size);

    return window;
}

/// This function will pre-emptively load libraries so GLFW will detect Wayland on NixOS.
pub fn loadDynamicLibraries(gpa: std.mem.Allocator) !void {
    var path_arena_allocator = std.heap.ArenaAllocator.init(gpa);
    defer path_arena_allocator.deinit();
    const arena = path_arena_allocator.allocator();

    var prefixes_to_try = std.ArrayList([]const u8).init(arena);

    try prefixes_to_try.append(try arena.dupe(u8, "."));
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

    _ = tryLoadDynamicLibrariesFromPrefixes(arena, prefixes_to_try.items, "libwayland-client.so") catch {};
    _ = tryLoadDynamicLibrariesFromPrefixes(arena, prefixes_to_try.items, "libwayland-cursor.so") catch {};
    _ = tryLoadDynamicLibrariesFromPrefixes(arena, prefixes_to_try.items, "libwayland-egl.so") catch {};
    _ = tryLoadDynamicLibrariesFromPrefixes(arena, prefixes_to_try.items, "libxkbcommon.so") catch {};
    _ = tryLoadDynamicLibrariesFromPrefixes(arena, prefixes_to_try.items, "libEGL.so") catch {};
}

pub fn tryLoadDynamicLibrariesFromPrefixes(gpa: std.mem.Allocator, prefixes: []const []const u8, library_name: []const u8) !std.DynLib {
    for (prefixes) |prefix| {
        const path = try std.fs.path.join(gpa, &.{ prefix, library_name });
        defer gpa.free(path);

        const lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        return lib;
    }
    return error.FileNotFound;
}

pub const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCFnPtr {
        return mach_glfw.getProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return mach_glfw.ExtensionSupported(extension_name);
    }
};

pub fn defaultErrorCallback(err_code: mach_glfw.ErrorCode, description: [:0]const u8) void {
    std.log.scoped(.glfw).warn("{}: {?s}\n", .{ err_code, description });
}

const std = @import("std");

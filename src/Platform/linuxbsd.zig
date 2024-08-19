pub const PLATFORM = seizer.Platform{
    .name = "linuxbsd",
    .main = main,
    .gl = @import("gl"),
    .allocator = getAllocator,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
    .writeFile = writeFile,
    .readFile = readFile,
    .setDeinitCallback = setDeinitFn,
    .setEventCallback = setEventCallback,
};

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var egl: EGL = undefined;
var loop: xev.Loop = undefined;
var evdev: EvDev = undefined;
var key_bindings: std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)) = .{};
var window_manager: WindowManager = undefined;
var deinit_fn: ?seizer.Platform.DeinitFn = null;

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    defer _ = gpa.deinit();

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

    loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var display = egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return error.NoDisplay;
    };
    _ = try display.initialize();
    defer display.terminate();

    defer {
        var iter = key_bindings.valueIterator();
        while (iter.next()) |actions| {
            actions.deinit(gpa.allocator());
        }
        key_bindings.deinit(gpa.allocator());
    }

    evdev = try EvDev.init(gpa.allocator(), &loop, &key_bindings);
    defer evdev.deinit();
    try evdev.scanForDevices();

    window_manager = try WindowManager.init(.{
        .allocator = gpa.allocator(),
        .egl = &egl,
        .display = display,
        .key_bindings = &key_bindings,
        .loop = &loop,
    });
    defer window_manager.deinit();

    // Call root module's `init()` function
    root.init() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    defer {
        if (deinit_fn) |deinit| {
            deinit();
        }
    }
    while (!window_manager.shouldClose()) {
        try loop.run(.once);
        try window_manager.update();
    }
}

pub fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn createWindow(options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
    return window_manager.createWindow(options);
}

pub fn addButtonInput(options: seizer.Platform.AddButtonInputOptions) anyerror!void {
    for (options.default_bindings) |button_code| {
        const gop = try key_bindings.getOrPut(gpa.allocator(), button_code);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(gpa.allocator(), options);
    }
}

pub fn writeFile(options: seizer.Platform.WriteFileOptions) void {
    linuxbsd_fs.writeFile(gpa.allocator(), options);
}

pub fn readFile(options: seizer.Platform.ReadFileOptions) void {
    linuxbsd_fs.readFile(gpa.allocator(), options);
}

fn setEventCallback(new_on_event_callback: ?*const fn (event: seizer.input.Event) anyerror!void) void {
    window_manager.setEventCallback(new_on_event_callback);
}

fn setDeinitFn(new_deinit_fn: ?seizer.Platform.DeinitFn) void {
    deinit_fn = new_deinit_fn;
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
pub const WindowManager = @import("./linuxbsd/window_manager.zig").WindowManager;

const linuxbsd_fs = @import("./linuxbsd/fs.zig");

const xev = @import("xev");
const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

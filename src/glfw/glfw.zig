pub const c = @import("./c.zig");

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
        return c.glfwGetProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return c.glfwExtensionSupported(extension_name);
    }
};

pub fn defaultErrorCallback(err: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.log.scoped(.glfw).warn("0x{x}: {?s}\n", .{ err, description });
}

const std = @import("std");

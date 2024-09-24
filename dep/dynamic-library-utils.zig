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
    if (std.process.getEnvVarOwned(arena, "LD_LIBRARY_PATH")) |path_list| {
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

pub fn loadFromPrefixes(prefixes: []const []const u8, library_name: []const u8) !std.DynLib {
    const dyn_lib = load_lib: for (prefixes) |prefix| {
        var path_buffer: [std.fs.MAX_PATH_BYTES]u8 = undefined;
        @memcpy(path_buffer[0..prefix.len], prefix);

        var path = path_buffer[0..prefix.len];
        if (path_buffer[prefix.len -| 1] == '/') {
            @memcpy(path_buffer[prefix.len..][0..library_name.len], library_name);
            path = path_buffer[0 .. prefix.len + library_name.len];
        } else if (prefix.len == 0) {
            @memcpy(path_buffer[0..library_name.len], library_name);
            path = path_buffer[0..library_name.len];
        } else {
            path_buffer[prefix.len] = '/';
            @memcpy(path_buffer[prefix.len + 1 ..][0..library_name.len], library_name);
            path = path_buffer[0 .. prefix.len + 1 + library_name.len];
        }

        const lib = std.DynLib.open(path) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => |e| return e,
        };
        break :load_lib lib;
    } else {
        std.log.warn("could not load \"{s}\", searched paths:", .{library_name});
        for (prefixes) |prefix| {
            std.log.warn("\t{s}", .{prefix});
        }
        return error.NotFound;
    };

    return dyn_lib;
}

pub fn populateFunctionTable(dyn_lib: *std.DynLib, FnTable: type) !FnTable {
    var fn_table: FnTable = undefined;

    const fields = std.meta.fields(FnTable);
    inline for (fields) |field| {
        @field(fn_table, field.name) = dyn_lib.lookup(field.type, field.name) orelse {
            std.log.warn("function not found: \"{}\"", .{std.zig.fmtEscapes(field.name)});
            return error.FunctionNotFound;
        };
    }

    return fn_table;
}

const std = @import("std");

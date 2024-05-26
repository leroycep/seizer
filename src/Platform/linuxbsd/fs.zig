pub fn writeFile(allocator: std.mem.Allocator, options: seizer.Platform.WriteFileOptions) void {
    if (writeFileWithError(allocator, options)) {
        options.callback(options.userdata, {});
    } else |err| {
        switch (err) {
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn writeFileWithError(allocator: std.mem.Allocator, options: seizer.Platform.WriteFileOptions) !void {
    const app_data_dir_path = try std.fs.getAppDataDir(allocator, options.appname);
    defer allocator.free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    try app_data_dir.writeFile2(.{
        .sub_path = options.path,
        .data = options.data,
    });
}

pub fn readFile(allocator: std.mem.Allocator, options: seizer.Platform.ReadFileOptions) void {
    if (readFileWithError(allocator, options)) |read_bytes| {
        options.callback(options.userdata, read_bytes);
    } else |err| {
        switch (err) {
            error.FileNotFound => options.callback(options.userdata, error.NotFound),
            else => std.debug.panic("{}", .{err}),
        }
    }
}

fn readFileWithError(allocator: std.mem.Allocator, options: seizer.Platform.ReadFileOptions) ![]u8 {
    const app_data_dir_path = try std.fs.getAppDataDir(allocator, options.appname);
    defer allocator.free(app_data_dir_path);

    var app_data_dir = try std.fs.cwd().makeOpenPath(app_data_dir_path, .{});
    defer app_data_dir.close();

    const read_buffer = try app_data_dir.readFile(options.path, options.buffer);
    return read_buffer;
}

const seizer = @import("../../seizer.zig");
const std = @import("std");

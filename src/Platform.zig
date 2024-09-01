pub const wasm = @import("Platform/wasm.zig");
pub const linuxbsd = @import("Platform/linuxbsd.zig");

const Platform = @This();

name: []const u8,
/// should return true if the next backend should be tried
main: fn () anyerror!void,
allocator: fn () std.mem.Allocator,
createGraphics: fn (allocator: std.mem.Allocator, options: CreateGraphicsOptions) CreateGraphicsError!seizer.Graphics,
createWindow: fn (options: CreateWindowOptions) anyerror!seizer.Window,
addButtonInput: fn (options: AddButtonInputOptions) anyerror!void,
writeFile: fn (options: WriteFileOptions) void,
readFile: fn (options: ReadFileOptions) void,
setDeinitCallback: fn (?DeinitFn) void,
setEventCallback: fn (?*const fn (event: seizer.input.Event) anyerror!void) void,

pub const DeinitFn = *const fn () void;

pub const CreateGraphicsError = error{ OutOfMemory, OutOfDeviceMemory, LibraryLoadFailed, InitializationFailed };
pub const CreateGraphicsOptions = struct {
    app_name: ?[:0]const u8 = null,
    app_version: ?std.SemanticVersion = null,
};

pub const CreateWindowOptions = struct {
    title: [:0]const u8,
    on_render: *const fn (seizer.Window) anyerror!void,
    on_destroy: ?*const fn (seizer.Window) void = null,
    size: ?[2]u32 = null,
};

pub const AddButtonInputOptions = struct {
    title: []const u8,
    on_event: *const fn (pressed: bool) anyerror!void,
    default_bindings: []const Binding,
};

pub const Binding = union(enum) {
    keyboard: input.keyboard.Key,
    gamepad: input.gamepad.Button,
};

pub const FileError = error{NotFound};
pub const WriteFileCallbackFn = *const fn (userdata: ?*anyopaque, FileError!void) void;
pub const ReadFileCallbackFn = *const fn (userdata: ?*anyopaque, FileError![]const u8) void;

pub const WriteFileOptions = struct {
    appname: []const u8,
    path: []const u8,
    data: []const u8,
    callback: WriteFileCallbackFn,
    userdata: ?*anyopaque,
};

pub const ReadFileOptions = struct {
    appname: []const u8,
    path: []const u8,
    buffer: []u8,
    callback: ReadFileCallbackFn,
    userdata: ?*anyopaque,
};

const input = @import("./input.zig");
const seizer = @import("./seizer.zig");
const std = @import("std");

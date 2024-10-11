pub const wasm = @import("Platform/wasm.zig");
pub const linuxbsd = @import("Platform/linuxbsd.zig");

const Platform = @This();

name: []const u8,
/// should return true if the next backend should be tried
main: fn () anyerror!void,
allocator: fn () std.mem.Allocator,
loop: fn () *xev.Loop,
setShouldExit: fn (should_exit: bool) void,

writeFile: fn (options: WriteFileOptions) void,
readFile: fn (options: ReadFileOptions) void,
setDeinitCallback: fn (?DeinitFn) void,
setEventCallback: fn (?*const fn (event: seizer.input.Event) anyerror!void) void,

getTracer: fn () otel.trace.Tracer,

pub const DeinitFn = *const fn () void;

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
const otel = @import("opentelemetry");
const seizer = @import("./seizer.zig");
const std = @import("std");
const xev = @import("xev");

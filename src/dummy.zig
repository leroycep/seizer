const std = @import("std");

pub const gl = @compileError("Unimplemented");

pub fn run(comptime app: App) void {}
pub fn quit() void {}
pub fn now() i64 {}

pub const FetchError = error{
    FileNotFound,
    OutOfMemory,
    Unknown,
};
pub fn fetch(allocator: *std.mem.Allocator, file_name: []const u8) FetchError![]const u8 {
    @compileError("Unimplemented");
}

pub fn randomBytes(slice: []u8) void {}

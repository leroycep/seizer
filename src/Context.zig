const std = @import("std");
const seizer = @import("seizer.zig");
const gl = seizer.gl;

gpa: std.mem.Allocator,
backend_userdata: ?*anyopaque,
backend: *const seizer.backend.Backend,
windows: std.ArrayListUnmanaged(*seizer.Window) = .{},

pub fn deinit(this: *@This()) void {
    for (this.windows.items) |window| {
        window.destroy();
        this.gpa.destroy(window);
    }
    this.windows.deinit(this.gpa);
}

pub const CreateWindowOptions = struct {
    title: [:0]const u8,
    on_render: *const fn (*seizer.Window) anyerror!void,
    on_destroy: ?*const fn (*seizer.Window) void = null,
    size: ?[2]u32 = null,
};
pub fn createWindow(this: *@This(), options: CreateWindowOptions) anyerror!*seizer.Window {
    return this.backend.createWindow(this, options);
}
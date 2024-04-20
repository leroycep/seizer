const seizer = @import("seizer.zig");
const gl = seizer.gl;

gl_binding: gl.Binding,
pointer: ?*anyopaque,
interface: *const Interface,
on_render: *const fn (*seizer.Window) anyerror!void,
on_destroy: ?*const fn (*seizer.Window) void,

const Window = @This();

pub const Interface = struct {
    destroy: *const fn (?*anyopaque) void,
    getSize: *const fn (?*anyopaque) [2]f32,
    getFramebufferSize: *const fn (?*anyopaque) [2]f32,
    swapBuffers: *const fn (?*anyopaque) void,
};

pub fn destroy(this: *@This()) void {
    if (this.on_destroy) |on_destroy| on_destroy(this);
    this.interface.destroy(this.pointer);
}

pub fn getSize(this: @This()) [2]f32 {
    return this.interface.getSize(this.pointer);
}

pub fn getFramebufferSize(this: @This()) [2]f32 {
    return this.interface.getFramebufferSize(this.pointer);
}

pub fn swapBuffers(this: @This()) void {
    return this.interface.swapBuffers(this.pointer);
}

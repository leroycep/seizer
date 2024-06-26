const seizer = @import("seizer.zig");
const gl = seizer.gl;

pointer: ?*anyopaque,
interface: *const Interface,

const Window = @This();

pub const Interface = struct {
    getSize: *const fn (?*anyopaque) [2]f32,
    getFramebufferSize: *const fn (?*anyopaque) [2]f32,
    setShouldClose: *const fn (?*anyopaque, should_close: bool) void,
};

pub fn getSize(this: @This()) [2]f32 {
    return this.interface.getSize(this.pointer);
}

pub fn getFramebufferSize(this: @This()) [2]f32 {
    return this.interface.getFramebufferSize(this.pointer);
}

pub fn setShouldClose(this: @This(), should_close: bool) void {
    return this.interface.setShouldClose(this.pointer, should_close);
}

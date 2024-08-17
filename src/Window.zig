const seizer = @import("seizer.zig");

pointer: ?*anyopaque,
interface: *const Interface,

const Window = @This();

pub const Interface = struct {
    getSize: *const fn (?*anyopaque) [2]f32,
    getFramebufferSize: *const fn (?*anyopaque) [2]f32,
    createGfxContext: *const fn (?*anyopaque) seizer.Gfx,
    setShouldClose: *const fn (?*anyopaque, should_close: bool) void,
    swapBuffers: *const fn (?*anyopaque) anyerror!void,
};

pub fn getSize(this: @This()) [2]f32 {
    return this.interface.getSize(this.pointer);
}

pub fn getFramebufferSize(this: @This()) [2]f32 {
    return this.interface.getFramebufferSize(this.pointer);
}

pub fn createGfxContext(this: @This()) seizer.Gfx {
    return this.interface.createGfxContext(this.pointer);
}

pub fn setShouldClose(this: @This(), should_close: bool) void {
    return this.interface.setShouldClose(this.pointer, should_close);
}

pub fn swapBuffers(this: @This()) anyerror!void {
    return this.interface.swapBuffers(this.pointer);
}

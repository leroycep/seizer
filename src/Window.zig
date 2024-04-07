const seizer = @import("seizer.zig");
const gl = seizer.gl;

gl_binding: gl.Binding,
glfw_window: seizer.backend.glfw.Window,
on_render: *const fn (*seizer.Window) anyerror!void,
on_destroy: ?*const fn (*seizer.Window) void,

pub fn destroy(this: *@This()) void {
    if (this.on_destroy) |on_destroy| on_destroy(this);
    this.glfw_window.destroy();
}

pub fn getSize(this: @This()) [2]f32 {
    const window_size = this.glfw_window.getSize();
    return [2]f32{
        @floatFromInt(window_size.width),
        @floatFromInt(window_size.height),
    };
}

pub fn getFramebufferSize(this: @This()) [2]f32 {
    const framebuffer_size = this.glfw_window.getFramebufferSize();
    return [2]f32{
        @floatFromInt(framebuffer_size.width),
        @floatFromInt(framebuffer_size.height),
    };
}

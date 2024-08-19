pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;

pub fn init() !void {
    _ = try seizer.platform.createWindow(.{
        .title = "window 1",
        .on_render = render1,
    });

    _ = try seizer.platform.createWindow(.{
        .title = "window 2",
        .on_render = render2,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    canvas.deinit();
}

fn render1(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    _ = c.writeText(.{ window.getSize()[0] / 2, window.getSize()[1] / 2 }, "Window 1", .{});
    canvas.end();

    try window.swapBuffers();
}

fn render2(window: seizer.Window) !void {
    gl.clearColor(0, 0, 0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    _ = c.writeText(.{ window.getSize()[0] / 2, window.getSize()[1] / 2 }, "Window 2", .{});

    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

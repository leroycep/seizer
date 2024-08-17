pub const main = seizer.main;

var gfx: seizer.Gfx = undefined;

pub fn init() !void {
    const window = try seizer.platform.createWindow(.{
        .title = "Bitmap Font - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    gfx = window.createGfxContext();
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    // canvas.deinit();
}

fn render(window: seizer.Window) !void {
    gfx.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    gfx.clear(.{ .color = .{ 0.7, 0.5, 0.5, 1.0 } });

    _ = gfx.writeText(.{ 50, 50 }, "Hello, world!", .{});

    gfx.end(.{});

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

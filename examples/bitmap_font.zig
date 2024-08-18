pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;

pub fn init() !void {
    _ = try seizer.platform.createWindow(.{
        .title = "Bitmap Font - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    canvas.deinit();
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    var pos = [2]f32{ 50, 50 };
    pos[1] += c.writeText(pos, "Hello, world!", .{})[1];
    pos[1] += c.writeText(pos, "Hello, world!", .{ .color = .{ 0x00, 0x00, 0x00, 0xFF } })[1];
    pos[1] += c.writeText(pos, "Hello, world!", .{ .background = .{ 0x00, 0x00, 0x00, 0xFF } })[1];

    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

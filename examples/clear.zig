pub const main = seizer.main;

var gfx: seizer.Gfx = undefined;

pub fn init() !void {
    const window = try seizer.platform.createWindow(.{
        .title = "Clear - Seizer Example",
        .on_render = render,
    });

    gfx = window.createGfxContext();
}

fn render(window: seizer.Window) !void {
    gfx.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    gfx.clear(.{ .color = .{ 0.7, 0.5, 0.5, 1.0 } });
    gfx.end(.{});

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;

pub const main = seizer.main;

pub fn init() !void {
    _ = try seizer.platform.createWindow(.{
        .title = "Clear - Seizer Example",
        .on_render = render,
    });
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;

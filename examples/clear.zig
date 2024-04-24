pub const main = seizer.main;

pub fn init(context: *seizer.Context) !void {
    _ = try context.createWindow(.{
        .title = "Clear - Seizer Example",
        .on_render = render,
    });
}

fn render(window: seizer.Window) !void {
    _ = window;
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

const seizer = @import("seizer");
const gl = seizer.gl;

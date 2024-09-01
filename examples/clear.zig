pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{
        .app_name = "Clear - Seizer Example",
    });
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "Clear - Seizer Example",
        .on_render = render,
    });

    seizer.platform.setDeinitCallback(deinit);
}

fn deinit() void {
    gfx.destroy();
}

fn render(window: seizer.Window) !void {
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");

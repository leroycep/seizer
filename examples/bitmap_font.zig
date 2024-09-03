pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});

    _ = try seizer.platform.createWindow(.{
        .title = "Bitmap Font - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    seizer.platform.setDeinitCallback(deinit);
}

/// This is a global deinit, not window specific. This is important because windows can hold onto Graphics resources.
fn deinit() void {
    canvas.deinit();
    gfx.destroy();
}

fn render(window: seizer.Window) !void {
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    var pos = [2]f32{ 50, 50 };
    pos[1] += c.writeText(pos, "Hello, world!", .{})[1];
    pos[1] += c.writeText(pos, "Hello, world!", .{ .color = .{ 0x00, 0x00, 0x00, 0xFF } })[1];
    pos[1] += c.writeText(pos, "Hello, world!", .{ .background = .{ 0x00, 0x00, 0x00, 0xFF } })[1];

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

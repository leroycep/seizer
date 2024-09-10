pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;
var shield_texture: *seizer.Graphics.Texture = undefined;
var shield_size: [2]f32 = .{ 0, 0 };

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "TinyVG - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var shield_image = try seizer.tvg.rendering.renderBuffer(seizer.platform.allocator(), seizer.platform.allocator(), .inherit, null, &shield_icon_tvg);
    defer shield_image.deinit(seizer.platform.allocator());

    shield_size = .{
        @floatFromInt(shield_image.width),
        @floatFromInt(shield_image.height),
    };

    shield_texture = try gfx.createTexture(
        seizer.zigimg.Image{
            .width = shield_image.width,
            .height = shield_image.height,
            .pixels = .{ .rgba32 = @ptrCast(shield_image.pixels) },
        },
        .{},
    );
    errdefer gfx.destroyTexture(shield_texture);

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    canvas.deinit();
    gfx.destroyTexture(shield_texture);
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

    c.rect(.{ 50, 50 }, shield_size, .{ .texture = shield_texture });

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const shield_icon_tvg = [_]u8{
    0x72, 0x56, 0x01, 0x42, 0x18, 0x18, 0x02, 0x29, 0xad, 0xff, 0xff, 0xff,
    0xf1, 0xe8, 0xff, 0x03, 0x02, 0x00, 0x04, 0x05, 0x03, 0x30, 0x04, 0x00,
    0x0c, 0x14, 0x02, 0x2c, 0x03, 0x0c, 0x42, 0x1b, 0x57, 0x30, 0x5c, 0x03,
    0x45, 0x57, 0x54, 0x42, 0x54, 0x2c, 0x02, 0x14, 0x45, 0x44, 0x03, 0x40,
    0x4b, 0x38, 0x51, 0x30, 0x54, 0x03, 0x28, 0x51, 0x20, 0x4b, 0x1b, 0x44,
    0x03, 0x1a, 0x42, 0x19, 0x40, 0x18, 0x3e, 0x03, 0x18, 0x37, 0x23, 0x32,
    0x30, 0x32, 0x03, 0x3d, 0x32, 0x48, 0x37, 0x48, 0x3e, 0x03, 0x47, 0x40,
    0x46, 0x42, 0x45, 0x44, 0x30, 0x14, 0x03, 0x36, 0x14, 0x3c, 0x19, 0x3c,
    0x20, 0x03, 0x3c, 0x26, 0x37, 0x2c, 0x30, 0x2c, 0x03, 0x2a, 0x2c, 0x24,
    0x27, 0x24, 0x20, 0x03, 0x24, 0x1a, 0x29, 0x14, 0x30, 0x14, 0x00,
};

const seizer = @import("seizer");
const std = @import("std");

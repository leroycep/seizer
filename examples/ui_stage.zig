pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;
var ui_texture: *seizer.Graphics.Texture = undefined;
var stage: *seizer.ui.Stage = undefined;

pub fn init() !void {
    seizer.platform.setEventCallback(onEvent);

    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "UI Stage - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var ui_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("./assets/ui.png"));
    defer ui_image.deinit();

    ui_texture = try gfx.createTexture(ui_image, .{});
    errdefer gfx.destroyTexture(ui_texture);

    stage = try seizer.ui.Stage.create(seizer.platform.allocator(), .{
        .padding = .{
            .min = .{ 16, 16 },
            .max = .{ 16, 16 },
        },
        .text_font = &canvas.font,
        .text_scale = 1,
        .text_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) }, .{ .pos = .{ 0, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
        .background_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    });
    errdefer stage.destroy();

    var flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer flexbox.element().release();
    flexbox.justification = .center;
    flexbox.cross_align = .center;
    stage.setRoot(flexbox.element());

    const frame = try seizer.ui.Element.Frame.create(stage);
    defer frame.element().release();
    try flexbox.appendChild(frame.element());

    var frame_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer frame_flexbox.element().release();
    frame_flexbox.justification = .center;
    frame_flexbox.cross_align = .center;
    frame.setChild(frame_flexbox.element());

    const hello_world_label = try seizer.ui.Element.Label.create(stage, "Hello, world!");
    defer hello_world_label.element().release();
    hello_world_label.style = stage.default_style.with(.{
        .text_color = .{ 0x00, 0x00, 0x00, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) }, .{ .pos = .{ 48, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
    });
    try frame_flexbox.appendChild(hello_world_label.element());

    const hello_button = try seizer.ui.Element.Button.create(stage, "Hello");
    defer hello_button.element().release();

    hello_button.default_style.padding = .{
        .min = .{ 8, 7 },
        .max = .{ 8, 9 },
    };
    hello_button.default_style.text_color = .{ 0x00, 0x00, 0x00, 0xFF };
    hello_button.default_style.background_color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
    hello_button.default_style.background_ninepatch = seizer.NinePatch.initv(ui_texture, [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) }, .{ .pos = .{ 120, 24 }, .size = .{ 24, 24 } }, .{ 8, 8 });

    hello_button.hovered_style.padding = .{
        .min = .{ 8, 8 },
        .max = .{ 8, 8 },
    };
    hello_button.hovered_style.text_color = .{ 0x00, 0x00, 0x00, 0xFF };
    hello_button.hovered_style.background_color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
    hello_button.hovered_style.background_ninepatch = seizer.NinePatch.initv(ui_texture, [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) }, .{ .pos = .{ 96, 0 }, .size = .{ 24, 24 } }, .{ 8, 8 });

    hello_button.clicked_style.padding = .{
        .min = .{ 8, 9 },
        .max = .{ 8, 7 },
    };
    hello_button.clicked_style.text_color = .{ 0x00, 0x00, 0x00, 0xFF };
    hello_button.clicked_style.background_color = .{ 0xFF, 0xFF, 0xFF, 0xFF };
    hello_button.clicked_style.background_ninepatch = seizer.NinePatch.initv(ui_texture, [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) }, .{ .pos = .{ 120, 0 }, .size = .{ 24, 24 } }, .{ 8, 8 });

    try frame_flexbox.appendChild(hello_button.element());

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    stage.destroy();
    gfx.destroyTexture(ui_texture);
    canvas.deinit();
    gfx.destroy();
}

fn onEvent(event: seizer.input.Event) !void {
    if (stage.processEvent(event) == null) {
        // add game control here, as the event wasn't applicable to the GUI
    }
}

fn render(window: seizer.Window) !void {
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    const window_size = [2]f32{ @floatFromInt(window.getSize()[0]), @floatFromInt(window.getSize()[1]) };

    stage.needs_layout = true;
    stage.render(c, window_size);

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

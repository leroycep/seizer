pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;
var ui_texture: *seizer.Graphics.Texture = undefined;
var character_texture: *seizer.Graphics.Texture = undefined;
var stage: *seizer.ui.Stage = undefined;

pub fn init() !void {
    seizer.platform.setEventCallback(onEvent);

    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "UI Stage - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var ui_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("./assets/ui.png"));
    defer ui_image.deinit();

    const ui_image_size = [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) };

    ui_texture = try gfx.createTexture(ui_image, .{});
    errdefer gfx.destroyTexture(ui_texture);

    var character_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("./assets/wedge.png"));
    defer character_image.deinit();

    character_texture = try gfx.createTexture(character_image, .{});
    errdefer gfx.destroyTexture(character_texture);

    stage = try seizer.ui.Stage.create(seizer.platform.allocator(), .{
        .padding = .{
            .min = .{ 16, 16 },
            .max = .{ 16, 16 },
        },
        .text_font = &canvas.font,
        .text_scale = 1,
        .text_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, ui_image_size, .{ .pos = .{ 0, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
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

    const frame_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer frame_flexbox.element().release();
    frame.setChild(frame_flexbox.element());
    frame_flexbox.cross_align = .center;

    const title_label = try seizer.ui.Element.Label.create(stage, "Images in PanZoom");
    defer title_label.element().release();
    title_label.style = stage.default_style.with(.{
        .text_color = .{ 0x00, 0x00, 0x00, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, ui_image_size, .{ .pos = .{ 48, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
    });
    try frame_flexbox.appendChild(title_label.element());

    const pan_zoom = try seizer.ui.Element.PanZoom.create(stage);
    defer pan_zoom.element().release();
    try frame_flexbox.appendChild(pan_zoom.element());

    const pan_zoom_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer pan_zoom_flexbox.element().release();
    try pan_zoom.appendChild(pan_zoom_flexbox.element());

    const character_image_element = try seizer.ui.Element.Image.create(stage, character_texture, .{ @intCast(character_image.width), @intCast(character_image.height) });
    defer character_image_element.element().release();
    try pan_zoom_flexbox.appendChild(character_image_element.element());

    const image_element = try seizer.ui.Element.Image.create(stage, ui_texture, ui_image_size);
    defer image_element.element().release();
    try pan_zoom_flexbox.appendChild(image_element.element());

    const hello_button = try seizer.ui.Element.Button.create(stage, "Hello");
    defer hello_button.element().release();
    try pan_zoom_flexbox.appendChild(hello_button.element());
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    stage.destroy();
    gfx.destroyTexture(character_texture);
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

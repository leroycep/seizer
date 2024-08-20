pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var ui_texture: seizer.Texture = undefined;
var character_texture: seizer.Texture = undefined;
var stage: *seizer.ui.Stage = undefined;

pub fn init() !void {
    seizer.platform.setEventCallback(onEvent);
    _ = try seizer.platform.createWindow(.{
        .title = "UI Stage - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    ui_texture = try seizer.Texture.initFromFileContents(seizer.platform.allocator(), @embedFile("./assets/ui.png"), .{});
    errdefer ui_texture.deinit();

    character_texture = try seizer.Texture.initFromFileContents(seizer.platform.allocator(), @embedFile("./assets/wedge.png"), .{});
    errdefer character_texture.deinit();

    stage = try seizer.ui.Stage.create(seizer.platform.allocator(), .{
        .padding = .{
            .min = .{ 16, 16 },
            .max = .{ 16, 16 },
        },
        .text_font = &canvas.font,
        .text_scale = 1,
        .text_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, .{ .pos = .{ 0, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
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

    const pan_zoom = try seizer.ui.Element.PanZoom.create(stage);
    defer pan_zoom.element().release();
    frame.setChild(pan_zoom.element());

    const pan_zoom_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer pan_zoom_flexbox.element().release();
    try pan_zoom.appendChild(pan_zoom_flexbox.element());

    const character_image_element = try seizer.ui.Element.Image.create(stage, character_texture);
    defer character_image_element.element().release();
    try pan_zoom_flexbox.appendChild(character_image_element.element());

    const image_element = try seizer.ui.Element.Image.create(stage, ui_texture);
    defer image_element.element().release();
    try pan_zoom_flexbox.appendChild(image_element.element());

    const hello_button = try seizer.ui.Element.Button.create(stage, "Hello");
    defer hello_button.element().release();
    try pan_zoom_flexbox.appendChild(hello_button.element());
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    stage.destroy();
    character_texture.deinit();
    ui_texture.deinit();
    canvas.deinit();
}

fn onEvent(event: seizer.input.Event) !void {
    if (stage.processEvent(event) == null) {
        // add game control here, as the event wasn't applicable to the GUI
    }
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    stage.needs_layout = true;
    stage.render(c, window.getSize());

    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

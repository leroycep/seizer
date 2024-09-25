pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;

var ui_texture: *seizer.Graphics.Texture = undefined;
var character_texture: *seizer.Graphics.Texture = undefined;

var canvas: seizer.Canvas = undefined;
var stage: *seizer.ui.Stage = undefined;

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "UI Stage - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    var ui_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("./assets/ui.png"));
    defer ui_image.deinit();

    const ui_image_size = [2]u32{ @intCast(ui_image.width), @intCast(ui_image.height) };

    ui_texture = try gfx.createTexture(ui_image.toUnmanaged(), .{});
    errdefer gfx.destroyTexture(ui_texture);

    var character_image = try seizer.zigimg.Image.fromMemory(seizer.platform.allocator(), @embedFile("./assets/wedge.png"));
    defer character_image.deinit();

    character_texture = try gfx.createTexture(character_image.toUnmanaged(), .{});
    errdefer gfx.destroyTexture(character_texture);

    // initialize ui stage and elements
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

    const frame = try seizer.ui.Element.Frame.create(stage);
    defer frame.element().release();

    const frame_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer frame_flexbox.element().release();
    frame_flexbox.cross_align = .center;

    const title_label = try seizer.ui.Element.Label.create(stage, "Images in PanZoom");
    defer title_label.element().release();
    title_label.style = stage.default_style.with(.{
        .text_color = .{ 0x00, 0x00, 0x00, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, ui_image_size, .{ .pos = .{ 48, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
    });

    const pan_zoom = try seizer.ui.Element.PanZoom.create(stage);
    defer pan_zoom.element().release();

    const pan_zoom_flexbox = try seizer.ui.Element.FlexBox.create(stage);
    defer pan_zoom_flexbox.element().release();

    const character_image_element = try seizer.ui.Element.Image.create(stage, character_texture, .{ @intCast(character_image.width), @intCast(character_image.height) });
    defer character_image_element.element().release();

    const image_element = try seizer.ui.Element.Image.create(stage, ui_texture, ui_image_size);
    defer image_element.element().release();

    const hello_button = try seizer.ui.Element.Button.create(stage, "Hello");
    defer hello_button.element().release();

    const text_field = try seizer.ui.Element.TextField.create(stage);
    defer text_field.element().release();

    // put elements into containers
    stage.setRoot(flexbox.element());

    try flexbox.appendChild(frame.element());

    frame.setChild(frame_flexbox.element());

    try frame_flexbox.appendChild(title_label.element());
    try frame_flexbox.appendChild(pan_zoom.element());

    try pan_zoom.appendChild(pan_zoom_flexbox.element());

    try pan_zoom_flexbox.appendChild(character_image_element.element());
    try pan_zoom_flexbox.appendChild(image_element.element());
    try pan_zoom_flexbox.appendChild(hello_button.element());
    try pan_zoom_flexbox.appendChild(text_field.element());

    // setup global deinit callback
    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    display.destroyWindow(window_global);
    if (swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    stage.destroy();
    gfx.destroyTexture(character_texture);
    gfx.destroyTexture(ui_texture);
    canvas.deinit();
    gfx.destroy();
    display.destroy();
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    _ = window;
    switch (event) {
        .should_close => seizer.platform.setShouldExit(true),
        .resize, .rescale => {
            if (swapchain_opt) |swapchain| {
                gfx.destroySwapchain(swapchain);
                swapchain_opt = null;
            }
            stage.needs_layout = true;
        },
        .input => |input| _ = stage.processEvent(input),
    }
}

fn render(window: *seizer.Display.Window) !void {
    const window_size = display.windowGetSize(window);
    const window_scale = display.windowGetScale(window);

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size, .scale = window_scale });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    const c = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .window_scale = window_scale,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    stage.render(c, window_size);

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

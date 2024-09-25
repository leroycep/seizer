pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;
var canvas: seizer.Canvas = undefined;

var ui_texture: *seizer.Graphics.Texture = undefined;
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

    ui_texture = try gfx.createTexture(ui_image.toUnmanaged(), .{});
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
    display.destroyWindow(window_global);
    if (swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    stage.destroy();
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
        .input => |input_event| if (stage.processEvent(input_event) == null) {
            // add game control here, as the event wasn't applicable to the GUI
        },
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

pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;
var canvas: seizer.Canvas = undefined;

var shield_texture: *seizer.Graphics.Texture = undefined;
var shield_size: [2]f32 = .{ 0, 0 };

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Sprite Batch - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
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
        seizer.zigimg.ImageUnmanaged{
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
    if (swapchain_opt) |swapchain| {
        gfx.destroySwapchain(swapchain);
        swapchain_opt = null;
    }
    canvas.deinit();
    display.destroyWindow(window_global);
    gfx.destroyTexture(shield_texture);
    gfx.destroy();
    display.destroy();
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    _ = window;
    switch (event) {
        .should_close => seizer.platform.setShouldExit(true),
        .resize => {
            if (swapchain_opt) |swapchain| {
                gfx.destroySwapchain(swapchain);
                swapchain_opt = null;
            }
        },
        .input => {},
    }
}

fn render(window: *seizer.Display.Window) !void {
    const window_size = display.windowGetSize(window);

    // begin rendering
    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    gfx.interface.setViewport(gfx.pointer, render_buffer, .{
        .pos = .{ 0, 0 },
        .size = [2]f32{ @floatFromInt(window_size[0]), @floatFromInt(window_size[1]) },
    });
    gfx.interface.setScissor(gfx.pointer, render_buffer, .{ 0, 0 }, window_size);

    const c = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    c.rect(.{ 50, 50 }, shield_size, .{ .texture = shield_texture });

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
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

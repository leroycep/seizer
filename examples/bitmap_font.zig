pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;

var font: seizer.Canvas.Font = undefined;
var canvas: seizer.Canvas = undefined;

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Bitmap Font - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
        .on_render = render,
    });

    font = try seizer.Canvas.Font.fromFileContents(
        seizer.platform.allocator(),
        gfx,
        @embedFile("./assets/PressStart2P_8.fnt"),
        &.{
            .{ .name = "PressStart2P_8.png", .contents = @embedFile("./assets/PressStart2P_8.png") },
        },
    );
    errdefer font.deinit();

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    seizer.platform.setDeinitCallback(deinit);
}

/// This is a global deinit, not window specific. This is important because windows can hold onto Graphics resources.
fn deinit() void {
    font.deinit();
    canvas.deinit();
    if (swapchain_opt) |swapchain| {
        gfx.destroySwapchain(swapchain);
        swapchain_opt = null;
    }
    display.destroyWindow(window_global);
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
        },
        .input => {},
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

    var pos = [2]f32{ 50, 50 };
    pos[1] += c.writeText(&font, pos, "Hello, world!", .{})[1];
    pos[1] += c.writeText(&font, pos, "Hello, world!", .{ .color = .{ 0x00, 0x00, 0x00, 0xFF } })[1];
    pos[1] += c.writeText(&font, pos, "Hello, world!", .{ .background = .{ 0x00, 0x00, 0x00, 0xFF } })[1];
    pos[1] += c.printText(&font, pos, "pos = <{}, {}>", .{ pos[0], pos[1] }, .{})[1];

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

pub const main = seizer.main;

var display: seizer.Display = undefined;
var window_global: *seizer.Display.Window = undefined;
var gfx: seizer.Graphics = undefined;
var swapchain_opt: ?*seizer.Graphics.Swapchain = null;

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    window_global = try display.createWindow(.{
        .title = "Clear - Seizer Example",
        .on_event = onWindowEvent,
        .on_render = render,
        .size = .{ 640, 480 },
    });

    seizer.platform.setDeinitCallback(deinit);
}

fn deinit() void {
    if (swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    display.destroyWindow(window_global);
    gfx.destroy();
    display.destroy();
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    _ = window;
    switch (event) {
        .should_close => seizer.platform.setShouldExit(true),
        .resize => |r| {
            std.log.info("resize window = {}x{}", .{ r[0], r[1] });
            if (swapchain_opt) |swapchain| {
                gfx.destroySwapchain(swapchain);
                swapchain_opt = null;
            }
        },
    }
}

fn render(window: *seizer.Display.Window) !void {
    const window_size = display.windowGetSize(window);

    const swapchain = swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size });
        swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    gfx.beginRendering(render_buffer, .{
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });
    gfx.endRendering(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

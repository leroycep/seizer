pub const main = seizer.main;

var display: seizer.Display = undefined;
var gfx: seizer.Graphics = undefined;
var font: seizer.Canvas.Font = undefined;
var canvas: seizer.Canvas = undefined;

var next_window_id: usize = 1;
var open_window_count: usize = 0;

const WindowData = struct {
    title: ?[:0]const u8 = null,
    swapchain_opt: ?*seizer.Graphics.Swapchain,
};

pub fn init() !void {
    display = try seizer.Display.create(seizer.platform.allocator(), seizer.platform.loop(), .{});
    errdefer display.destroy();

    gfx = try seizer.Graphics.create(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    const window_data = try seizer.platform.allocator().create(WindowData);
    errdefer seizer.platform.allocator().destroy(window_data);

    const first_window = try display.createWindow(.{
        .title = "Multi Window - Seizer Example",
        .size = .{ 640, 480 },
        .on_event = onWindowEvent,
        .on_render = render,
        .on_destroy = onWindowDestroyed,
    });
    window_data.* = .{ .title = null, .swapchain_opt = null };
    display.windowSetUserdata(first_window, window_data);
    open_window_count += 1;

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

pub fn deinit() void {
    font.deinit();
    canvas.deinit();
    gfx.destroy();
    display.destroy();
}

pub fn onWindowDestroyed(window: *seizer.Display.Window) void {
    const window_data: *WindowData = @ptrCast(@alignCast(display.windowGetUserdata(window)));
    if (window_data.title) |title| seizer.platform.allocator().free(title);
    if (window_data.swapchain_opt) |swapchain| gfx.destroySwapchain(swapchain);
    seizer.platform.allocator().destroy(window_data);

    open_window_count -= 1;
    if (open_window_count == 0) {
        seizer.platform.setShouldExit(true);
    }
}

fn onWindowEvent(window: *seizer.Display.Window, event: seizer.Display.Window.Event) !void {
    const window_data: *WindowData = @ptrCast(@alignCast(display.windowGetUserdata(window)));
    switch (event) {
        .should_close => display.destroyWindow(window),
        .resize, .rescale => {
            if (window_data.swapchain_opt) |swapchain| {
                gfx.destroySwapchain(swapchain);
                window_data.swapchain_opt = null;
            }
        },
        .input => |input_event| switch (input_event) {
            .key => |key| switch (key.key) {
                .unicode => |unicode| switch (unicode) {
                    'n' => if (key.action == .press) {
                        const n_window_data = try seizer.platform.allocator().create(WindowData);

                        const title = try std.fmt.allocPrintZ(seizer.platform.allocator(), "Window {}", .{next_window_id});
                        const n_window = try display.createWindow(.{
                            .title = title,
                            .size = .{ 640, 480 },
                            .on_event = onWindowEvent,
                            .on_render = render,
                            .on_destroy = onWindowDestroyed,
                        });
                        n_window_data.* = .{
                            .title = title,
                            .swapchain_opt = null,
                        };
                        display.windowSetUserdata(n_window, n_window_data);
                        next_window_id += 1;
                        open_window_count += 1;
                    },
                    else => {},
                },
                else => {},
            },

            else => {},
        },
    }
}

fn render(window: *seizer.Display.Window) !void {
    const window_data: *WindowData = @ptrCast(@alignCast(display.windowGetUserdata(window)));
    const window_size = display.windowGetSize(window);
    const window_scale = display.windowGetScale(window);

    const swapchain = window_data.swapchain_opt orelse create_swapchain: {
        const new_swapchain = try gfx.createSwapchain(display, window, .{ .size = window_size, .scale = window_scale });
        window_data.swapchain_opt = new_swapchain;
        break :create_swapchain new_swapchain;
    };

    const render_buffer = try gfx.swapchainGetRenderBuffer(swapchain, .{});

    const c = canvas.begin(render_buffer, .{
        .window_size = window_size,
        .window_scale = window_scale,
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    if (window_data.title) |title| {
        _ = c.writeText(&font, .{ window_size[0] / 2, window_size[1] / 2 }, title, .{
            .scale = 3,
            .@"align" = .center,
            .baseline = .middle,
        });
    } else {
        _ = c.writeText(&font, .{ window_size[0] / 2, window_size[1] / 2 }, "Press N to spawn new window", .{
            .scale = 3,
            .@"align" = .center,
            .baseline = .middle,
        });
    }

    canvas.end(render_buffer);

    try gfx.swapchainPresentRenderBuffer(display, window, swapchain, render_buffer);
}

const seizer = @import("seizer");
const std = @import("std");

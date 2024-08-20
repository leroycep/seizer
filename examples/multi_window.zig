pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var next_window_id: usize = 1;

pub fn init() !void {
    seizer.platform.setEventCallback(onEvent);

    _ = try seizer.platform.createWindow(.{
        .title = "Multi Window - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    canvas.deinit();
}

fn onEvent(event: seizer.input.Event) anyerror!void {
    switch (event) {
        .key => |key| switch (key.key) {
            .n => if (key.action == .press) {
                const title = try std.fmt.allocPrintZ(seizer.platform.allocator(), "Window {}", .{next_window_id});
                const n_window = try seizer.platform.createWindow(.{
                    .title = title,
                    .on_render = nWindowRender,
                    .on_destroy = nWindowDeinit,
                });
                n_window.setUserdata(title.ptr);
                next_window_id += 1;
            },
            else => {},
        },

        else => {},
    }
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    _ = c.writeText(.{ window.getSize()[0] / 2, window.getSize()[1] / 2 }, "Press N to spawn new window", .{
        .@"align" = .center,
    });
    canvas.end();

    try window.swapBuffers();
}

pub fn nWindowDeinit(window: seizer.Window) void {
    const title: [*:0]u8 = @ptrCast(window.getUserdata());
    seizer.platform.allocator().free(std.mem.span(title));
}

fn nWindowRender(window: seizer.Window) !void {
    const title: [*:0]u8 = @ptrCast(window.getUserdata());

    gl.clearColor(0, 0, 0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    _ = c.writeText(.{ window.getSize()[0] / 2, window.getSize()[1] / 2 }, std.mem.span(title), .{
        .@"align" = .center,
    });

    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

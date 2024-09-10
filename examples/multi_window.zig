pub const main = seizer.main;

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;
var next_window_id: usize = 1;

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    seizer.platform.setEventCallback(onEvent);

    _ = try seizer.platform.createWindow(.{
        .title = "Multi Window - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
    errdefer canvas.deinit();

    seizer.platform.setDeinitCallback(deinit);
}

pub fn deinit() void {
    canvas.deinit();
    gfx.destroy();
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
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    const window_size = [2]f32{ @floatFromInt(window.getSize()[0]), @floatFromInt(window.getSize()[1]) };

    _ = c.writeText(.{ window_size[0] / 2, window_size[1] / 2 }, "Press N to spawn new window", .{
        .scale = 3,
        .@"align" = .center,
        .baseline = .middle,
    });

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

pub fn nWindowDeinit(window: seizer.Window) void {
    const title: [*:0]u8 = @ptrCast(window.getUserdata());
    seizer.platform.allocator().free(std.mem.span(title));
}

fn nWindowRender(window: seizer.Window) !void {
    const title: [*:0]u8 = @ptrCast(window.getUserdata());

    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    const window_size = [2]f32{ @floatFromInt(window.getSize()[0]), @floatFromInt(window.getSize()[1]) };

    _ = c.writeText(.{ window_size[0] / 2, window_size[1] / 2 }, std.mem.span(title), .{
        .scale = 3,
        .@"align" = .center,
        .baseline = .middle,
    });

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

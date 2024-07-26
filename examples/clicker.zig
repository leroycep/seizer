pub const main = seizer.main;

const APPNAME = "seizer-example-clicker";

var canvas: seizer.Canvas = undefined;

var clicks: ?u64 = null;

var clicks_read_buffer: [8]u8 = undefined;

pub fn init() !void {
    _ = try seizer.platform.createWindow(.{
        .title = "Clicker - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    try seizer.platform.addButtonInput(.{
        .title = "click",
        .on_event = onClick,
        .default_bindings = &.{
            .{ .gamepad = .a },
            .{ .keyboard = .z },
        },
    });

    seizer.platform.readFile(.{
        .appname = APPNAME,
        .path = "clicks",
        .buffer = &clicks_read_buffer,
        .callback = onClicksFileRead,
        .userdata = null,
    });
}

fn onClicksFileRead(userdata: ?*anyopaque, result: seizer.Platform.FileError![]const u8) void {
    _ = userdata;
    if (result) |file_contents| {
        clicks = std.mem.readInt(u64, file_contents[0..8], .little);
    } else |_| {
        clicks = 0;
    }
}

fn onClicksFileWritten(userdata: ?*anyopaque, result: seizer.Platform.FileError!void) void {
    const clicks_write_buffer: *u64 = @ptrCast(@alignCast(userdata));
    _ = result catch {};
    seizer.platform.allocator().destroy(clicks_write_buffer);
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    canvas.deinit();
}

fn onClick(pressed: bool) !void {
    if (pressed) {
        if (clicks) |*c| {
            c.* += 1;

            const clicks_write_buffer = try seizer.platform.allocator().create(u64);
            std.mem.writeInt(u64, std.mem.asBytes(clicks_write_buffer), c.*, .little);
            seizer.platform.writeFile(.{
                .appname = APPNAME,
                .path = "clicks",
                .data = std.mem.asBytes(clicks_write_buffer),
                .callback = onClicksFileWritten,
                .userdata = clicks_write_buffer,
            });
        }
    }
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    const window_size = window.getSize();

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    _ = canvas.printText(.{ window_size[0] / 2, window_size[1] / 2 }, "Clicks: {?}", .{clicks}, .{
        .scale = 3,
        .@"align" = .center,
        .baseline = .middle,
    });
    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

pub const main = seizer.main;

const APPNAME = "seizer-example-clicker";

var gfx: seizer.Graphics = undefined;
var canvas: seizer.Canvas = undefined;

var clicks: ?u64 = null;

var clicks_read_buffer: [8]u8 = undefined;

pub fn init() !void {
    gfx = try seizer.platform.createGraphics(seizer.platform.allocator(), .{});
    errdefer gfx.destroy();

    _ = try seizer.platform.createWindow(.{
        .title = "Clicker - Seizer Example",
        .on_render = render,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), gfx, .{});
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

    seizer.platform.setDeinitCallback(deinit);
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

pub fn deinit() void {
    canvas.deinit();
    gfx.destroy();
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
    const cmd_buf = try gfx.begin(.{
        .size = window.getSize(),
        .clear_color = .{ 0.7, 0.5, 0.5, 1.0 },
    });

    const c = canvas.begin(cmd_buf, .{
        .window_size = window.getSize(),
    });

    const window_size = [2]f32{ @floatFromInt(window.getSize()[0]), @floatFromInt(window.getSize()[1]) };

    _ = c.printText(.{ window_size[0] / 2, window_size[1] / 2 }, "Clicks: {?}", .{clicks}, .{
        .scale = 3,
        .@"align" = .center,
        .baseline = .middle,
    });

    canvas.end(cmd_buf);

    try window.presentFrame(try cmd_buf.end());
}

const seizer = @import("seizer");
const std = @import("std");

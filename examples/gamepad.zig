pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;

var perform_action_input: bool = false;
var cancel_input: bool = false;

pub fn init(context: *seizer.Context) !void {
    _ = try context.createWindow(.{
        .title = "Gamepad - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(context.gpa, .{});
    errdefer canvas.deinit();

    try context.addButtonInput(.{
        .title = "perform_action",
        .on_event = onPerformAction,
        .default_bindings = &.{.a},
    });

    try context.addButtonInput(.{
        .title = "cancel",
        .on_event = onCancel,
        .default_bindings = &.{.b},
    });
}

pub fn deinit(window: *seizer.Window) void {
    _ = window;
    canvas.deinit();
}

fn onPerformAction(pressed: bool) !void {
    perform_action_input = pressed;
}

fn onCancel(pressed: bool) !void {
    cancel_input = pressed;
}

fn render(window: *seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    var text_writer = canvas.textWriter(.{});
    const console = text_writer.writer();

    try console.print("Buttons\n", .{});
    try console.print("perform_action = {}\n", .{perform_action_input});
    try console.print("cancel = {}\n", .{cancel_input});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;

var leftshoulder_input: bool = false;
var perform_action_input: bool = false;
var cancel_input: bool = false;

var window_global: *seizer.Window = undefined;

pub fn init(context: *seizer.Context) !void {
    window_global = try context.createWindow(.{
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

    try context.addButtonInput(.{
        .title = "leftshoulder",
        .on_event = onLeftShoulder,
        .default_bindings = &.{.leftshoulder},
    });

    try context.addButtonInput(.{
        .title = "quit",
        .on_event = onQuit,
        .default_bindings = &.{.back},
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

fn onLeftShoulder(pressed: bool) !void {
    leftshoulder_input = pressed;
}

fn onQuit(pressed: bool) !void {
    if (!pressed) return;
    window_global.setShouldClose(true);
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
    try console.print("leftshoulder = {}\n", .{leftshoulder_input});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

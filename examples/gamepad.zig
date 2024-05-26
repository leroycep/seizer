pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;

var leftshoulder_input: bool = false;
var perform_action_input: bool = false;
var cancel_input: bool = false;

var window_global: seizer.Window = undefined;

pub fn init() !void {
    window_global = try seizer.platform.createWindow(.{
        .title = "Gamepad - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    try seizer.platform.addButtonInput(.{
        .title = "perform_action",
        .on_event = onPerformAction,
        .default_bindings = &.{
            .{ .gamepad = .a },
            .{ .keyboard = .z },
        },
    });

    try seizer.platform.addButtonInput(.{
        .title = "cancel",
        .on_event = onCancel,
        .default_bindings = &.{
            .{ .gamepad = .b },
            .{ .keyboard = .x },
        },
    });

    try seizer.platform.addButtonInput(.{
        .title = "leftshoulder",
        .on_event = onLeftShoulder,
        .default_bindings = &.{
            .{ .gamepad = .leftshoulder },
        },
    });

    try seizer.platform.addButtonInput(.{
        .title = "dpleft",
        .on_event = onDPadLeft,
        .default_bindings = &.{
            .{ .gamepad = .dpleft },
            .{ .keyboard = .left },
        },
    });
    try seizer.platform.addButtonInput(.{
        .title = "dpright",
        .on_event = onDPadRight,
        .default_bindings = &.{
            .{ .gamepad = .dpright },
            .{ .keyboard = .right },
        },
    });
    try seizer.platform.addButtonInput(.{
        .title = "dpup",
        .on_event = onDPadUp,
        .default_bindings = &.{
            .{ .gamepad = .dpup },
            .{ .keyboard = .up },
        },
    });
    try seizer.platform.addButtonInput(.{
        .title = "dpdown",
        .on_event = onDPadDown,
        .default_bindings = &.{
            .{ .gamepad = .dpdown },
            .{ .keyboard = .down },
        },
    });

    try seizer.platform.addButtonInput(.{
        .title = "quit",
        .on_event = onQuit,
        .default_bindings = &.{
            .{ .gamepad = .back },
            .{ .keyboard = .esc },
        },
    });
}

pub fn deinit(window: seizer.Window) void {
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

var dpad_left = false;
var dpad_right = false;
var dpad_up = false;
var dpad_down = false;
fn onDPadLeft(pressed: bool) !void {
    dpad_left = pressed;
}
fn onDPadRight(pressed: bool) !void {
    dpad_right = pressed;
}
fn onDPadUp(pressed: bool) !void {
    dpad_up = pressed;
}
fn onDPadDown(pressed: bool) !void {
    dpad_down = pressed;
}

fn render(window: seizer.Window) !void {
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

    try console.print("\nDPad\n", .{});
    try console.print("dpup = {}\n", .{dpad_up});
    try console.print("dpright = {}\n", .{dpad_right});
    try console.print("dpdown = {}\n", .{dpad_down});
    try console.print("dpleft = {}\n", .{dpad_left});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

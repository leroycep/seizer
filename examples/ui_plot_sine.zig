pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var ui_texture: seizer.Texture = undefined;
var _stage: *seizer.ui.Stage = undefined;

pub fn init() !void {
    seizer.platform.setEventCallback(onEvent);
    _ = try seizer.platform.createWindow(.{
        .title = "UI Stage - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(seizer.platform.allocator(), .{});
    errdefer canvas.deinit();

    ui_texture = try seizer.Texture.initFromFileContents(seizer.platform.allocator(), @embedFile("./assets/ui.png"), .{});
    errdefer ui_texture.deinit();

    _stage = try seizer.ui.Stage.create(seizer.platform.allocator(), .{
        .padding = .{
            .min = .{ 16, 16 },
            .max = .{ 16, 16 },
        },
        .text_font = &canvas.font,
        .text_scale = 1,
        .text_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, .{ .pos = .{ 0, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
        .background_color = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF },
    });
    errdefer _stage.destroy();

    var flexbox = try seizer.ui.Element.FlexBox.create(_stage);
    defer flexbox.element().release();
    flexbox.justification = .center;
    flexbox.cross_align = .center;
    _stage.setRoot(flexbox.element());

    const frame = try seizer.ui.Element.Frame.create(_stage);
    defer frame.element().release();
    try flexbox.appendChild(frame.element());

    var frame_flexbox = try seizer.ui.Element.FlexBox.create(_stage);
    defer frame_flexbox.element().release();
    frame_flexbox.justification = .center;
    frame_flexbox.cross_align = .center;
    frame.setChild(frame_flexbox.element());

    const hello_world_label = try seizer.ui.Element.Label.create(_stage, "y = sin(x)");
    defer hello_world_label.element().release();
    hello_world_label.style = _stage.default_style.with(.{
        .text_color = .{ 0x00, 0x00, 0x00, 0xFF },
        .background_image = seizer.NinePatch.initv(ui_texture, .{ .pos = .{ 48, 0 }, .size = .{ 48, 48 } }, .{ 16, 16 }),
    });
    try frame_flexbox.appendChild(hello_world_label.element());

    const sine_plot = try seizer.ui.Element.Plot.create(_stage);
    defer sine_plot.element().release();
    try sine_plot.lines.put(_stage.gpa, try _stage.gpa.dupe(u8, "y = sin(x)"), .{});
    sine_plot.x_range = .{ 0, std.math.tau };
    sine_plot.y_range = .{ -1, 1 };
    try frame_flexbox.appendChild(sine_plot.element());

    try sine_plot.lines.getPtr("y = sin(x)").?.x.ensureTotalCapacity(_stage.gpa, 360);
    try sine_plot.lines.getPtr("y = sin(x)").?.y.ensureTotalCapacity(_stage.gpa, 360);

    sine_plot.lines.getPtr("y = sin(x)").?.x.items.len = 360;
    sine_plot.lines.getPtr("y = sin(x)").?.y.items.len = 360;

    const x_array = sine_plot.lines.getPtr("y = sin(x)").?.x.items;
    const y_array = sine_plot.lines.getPtr("y = sin(x)").?.y.items;
    for (x_array, y_array, 0..) |*x, *y, i| {
        x.* = std.math.tau * @as(f32, @floatFromInt(i)) / 360;
        y.* = @sin(x.*);
    }
}

pub fn deinit(window: seizer.Window) void {
    _ = window;
    _stage.destroy();
    ui_texture.deinit();
    canvas.deinit();
}

fn onEvent(event: seizer.input.Event) !void {
    if (_stage.processEvent(event) == null) {
        // add game control here, as the event wasn't applicable to the GUI
    }
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    const c = canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });

    _stage.needs_layout = true;
    _stage.render(c, window.getSize());

    canvas.end();

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

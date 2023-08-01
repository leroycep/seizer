//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.
const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");
const store = seizer.ui.store;
const geom = seizer.geometry;
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;
const BitmapFont = seizer.font.Bitmap;
const NinePatch = seizer.ninepatch.NinePatch;
const Stage = seizer.ui.Stage;
const Observer = seizer.ui.Observer;
const Store = seizer.ui.store.Store;
const LayoutEngine = seizer.ui.LayoutEngine;
const Painter = seizer.ui.Painter;

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .init = init,
    .event = event,
    .deinit = deinit,
    .render = render,
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var stage: Stage = undefined;

// Assets
var font: BitmapFont = undefined;
var texture: Texture = undefined;
var batch: SpriteBatch = undefined;

var increment: usize = undefined;
var decrement: usize = undefined;
var counter_label: usize = undefined;
var counter_ref: store.Ref = undefined;
var text_ref: store.Ref = undefined;
var textinput: usize = undefined;

var is_typing = false;
var cursor: f32 = 0;

/// All of the possible frame styles for nodes
const NodeStyle = enum(u16) {
    None,
    Frame,
    Nameplate,
    Label,
    Input,
    InputEdit,
    Keyrest,
    Keyup,
    Keydown,

    pub fn asInt(style: NodeStyle) u16 {
        return @intFromEnum(style);
    }

    pub fn frame(style: NodeStyle) seizer.ui.Node {
        return seizer.ui.Node{ .style = @intFromEnum(style) };
    }
};

const button_transitions = [_]Observer.Transition{
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Keyrest), .event = .enter, .end = @intFromEnum(NodeStyle.Keyup) },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Keyup), .event = .exit, .end = @intFromEnum(NodeStyle.Keyrest) },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Keyup), .event = .press, .end = @intFromEnum(NodeStyle.Keydown) },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Keydown), .event = .exit, .end = @intFromEnum(NodeStyle.Keyrest) },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Keydown), .event = .release, .end = @intFromEnum(NodeStyle.Keyup), .emit = 1 },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.Input), .event = .press, .end = @intFromEnum(NodeStyle.InputEdit), .emit = 2 },
    Observer.Transition{ .begin = @intFromEnum(NodeStyle.InputEdit), .event = .onblur, .end = @intFromEnum(NodeStyle.Input), .emit = 3 },
};

fn init() !void {
    font = try seizer.font.Bitmap.init(gpa.allocator(), .{
        .font_contents = @embedFile("assets/PressStart2P_8.fnt"),
        .pages = &.{
            .{
                .name = "PressStart2P_8.png",
                .image = @embedFile("assets/PressStart2P_8.png"),
            },
        },
    });
    errdefer font.deinit();

    texture = try Texture.initFromMemory(gpa.allocator(), @embedFile("assets/ui.png"), .{});
    errdefer texture.deinit();

    batch = try SpriteBatch.init(gpa.allocator(), .{ 1, 1 });

    stage = try Stage.init(gpa.allocator(), &font, &batch, &button_transitions);
    stage.painter.scale = 2;

    try stage.painter.addStyle(@intFromEnum(NodeStyle.Frame), NinePatch.initv(texture, .{ 0, 0, 48, 48 }, .{ 16, 16 }), geom.Rect{ 16, 16, 16, 16 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Nameplate), NinePatch.initv(texture, .{ 48, 0, 48, 48 }, .{ 16, 16 }), geom.Rect{ 16, 16, 16, 16 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Label), NinePatch.initv(texture, .{ 96, 24, 12, 12 }, .{ 4, 4 }), geom.Rect{ 4, 4, 4, 4 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Input), NinePatch.initv(texture, .{ 96, 24, 12, 12 }, .{ 4, 4 }), geom.Rect{ 4, 4, 4, 4 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.InputEdit), NinePatch.initv(texture, .{ 96, 24, 12, 12 }, .{ 4, 4 }), geom.Rect{ 4, 4, 4, 4 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Keyrest), NinePatch.initv(texture, .{ 96, 0, 24, 24 }, .{ 8, 8 }), geom.Rect{ 8, 7, 8, 9 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Keyup), NinePatch.initv(texture, .{ 120, 24, 24, 24 }, .{ 8, 8 }), geom.Rect{ 8, 8, 8, 8 });
    try stage.painter.addStyle(@intFromEnum(NodeStyle.Keydown), NinePatch.initv(texture, .{ 120, 0, 24, 24 }, .{ 8, 8 }), geom.Rect{ 8, 9, 8, 7 });

    // Create values in the store to be used by the UI
    const name_ref = try stage.store.new(.{ .Bytes = "Hello, World!" });
    counter_ref = try stage.store.new(.{ .Int = 0 });
    const dec_label_ref = try stage.store.new(.{ .Bytes = "<" });
    const inc_label_ref = try stage.store.new(.{ .Bytes = ">" });
    text_ref = try stage.store.new(.{ .Bytes = "" });

    // Create the layout for the UI
    const center = try stage.layout.insert(null, NodeStyle.frame(.None).container(.Center));
    const frame = try stage.layout.insert(center, NodeStyle.frame(.Frame).container(.VList));
    const nameplate = try stage.layout.insert(frame, NodeStyle.frame(.Nameplate).dataValue(name_ref));
    _ = nameplate;

    // Counter
    const counter_center = try stage.layout.insert(frame, NodeStyle.frame(.None).container(.Center));
    const counter = try stage.layout.insert(counter_center, NodeStyle.frame(.None).container(.HList));
    decrement = try stage.layout.insert(counter, NodeStyle.frame(.Keyrest).dataValue(dec_label_ref));
    const label_center = try stage.layout.insert(counter, NodeStyle.frame(.None).container(.Center));
    counter_label = try stage.layout.insert(label_center, NodeStyle.frame(.Label).dataValue(counter_ref));
    increment = try stage.layout.insert(counter, NodeStyle.frame(.Keyrest).dataValue(inc_label_ref));

    // Text input
    textinput = try stage.layout.insert(frame, NodeStyle.frame(.Input).dataValue(text_ref));

    stage.sizeAll();
}

fn deinit() void {
    stage.deinit();
    font.deinit();
    batch.deinit();
    _ = gpa.deinit();
}

fn event(e: seizer.event.Event) !void {
    if (stage.event(e)) |action| action: {
        if (action.emit_blur == 3) is_typing = false;
        switch (action.emit) {
            2 => is_typing = true,
            1 => {
                var node = action.node orelse break :action;
                if (node.handle == increment) {
                    var count = stage.store.get(counter_ref);
                    count.Int += 1;
                    try stage.store.set(.Int, counter_ref, count.Int);
                } else if (node.handle == decrement) {
                    var count = stage.store.get(counter_ref);
                    count.Int -= 1;
                    try stage.store.set(.Int, counter_ref, count.Int);
                }
                stage.layout.modified = true;
                if (stage.layout.get_node(counter_label)) |label| {
                    const size = stage.size(label);
                    stage.layout.update_min_size(counter_label, size);
                }
            },
            else => {},
        }
    }
    switch (e) {
        .TextInput => |input| {
            if (is_typing) {
                const string = stage.store.get(text_ref).Bytes;
                const new_string = try std.mem.concat(gpa.allocator(), u8, &.{ string, input.text() });
                defer gpa.allocator().free(new_string);
                cursor = font.calcTextWidth(new_string, stage.painter.scale);
                try stage.store.set(.Bytes, text_ref, new_string);
            }
        },
        .KeyDown => |key| {
            if (key.key == .BACKSPACE and is_typing) {
                const string = stage.store.get(text_ref).Bytes;
                const len = string.len -| 1;
                const new_string = string[0..len];
                cursor = font.calcTextWidth(new_string, stage.painter.scale);
                try stage.store.set(.Bytes, text_ref, new_string);
            }
        },
        .Quit => seizer.backend.quit(),
        else => {},
    }
}

// Error
fn render(alpha: f64) !void {
    _ = alpha;

    // Resize gl viewport to match window
    const screen_size = seizer.getScreenSize();
    gl.viewport(0, 0, screen_size[0], screen_size[1]);
    batch.setSize(screen_size);

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    stage.paintAll(.{ 0, 0, screen_size[0], screen_size[1] });

    if (is_typing) cursor: {
        const node = stage.layout.get_node(textinput) orelse break :cursor;
        const rect = geom.rect.itof(node.bounds + node.padding * geom.Rect{ 1, 1, -1, -1 });
        batch.drawBitmapText(.{
            .text = "_",
            .font = font,
            .pos = .{ rect[0] + cursor, rect[1] },
            // .textBaseline = .Top,
            .color = .{ 0, 0, 0, 0xFF },
            .scale = stage.painter.scale,
        });
    }

    batch.flush();
}

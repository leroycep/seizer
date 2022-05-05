//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.
const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");
const store = seizer.ui.store;
const math = seizer.math;
const geom = seizer.geometry;
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;
const BitmapFont = seizer.font.Bitmap;
const NinePatch = seizer.ninepatch.NinePatch;
const UIStage = seizer.ui.Stage;
const Stage = UIStage(NodeStyle, Painter, store.Ref);

const NodeStyle = enum { None, Frame, Nameplate, Label, Keyup, Keydown };

const Painter = struct {
    batch: *SpriteBatch,
    store: store.Store,
    font: *BitmapFont,
    ninepatch: std.EnumMap(NodeStyle, NinePatch),
    scale: f32,

    pub fn deinit(painter: *Painter) void {
        painter.store.deinit();
    }

    pub fn size(painter: *Painter, node: Stage.Node) geom.Vec2 {
        if (node.data) |data| {
            const value = painter.store.get(data);
            switch (value) {
                .Bytes => |string| {
                    const width = painter.font.calcTextWidth(string, painter.scale);
                    const height = painter.font.lineHeight * painter.scale;
                    return geom.vec.ftoi(geom.Vec2f{ width, height });
                },
                else => {},
            }
        }
        return geom.Vec2{ 0, 0 };
    }

    pub fn padding(painter: *Painter, node: Stage.Node) geom.Rect {
        _ = painter;
        const scale = @splat(4, @floatToInt(i32, painter.scale));
        switch (node.style) {
            .None => return geom.Rect{ 0, 0, 0, 0 } * scale,
            .Frame => return geom.Rect{ 16, 16, 16, 16 } * scale,
            .Nameplate => return geom.Rect{ 16, 16, 16, 16 } * scale,
            .Label => return geom.Rect{ 4, 4, 4, 4 } * scale,
            .Keyup => return geom.Rect{ 8, 8, 8, 8 } * scale,
            .Keydown => return geom.Rect{ 8, 8, 8, 8 } * scale,
        }
    }

    pub fn paint(painter: *Painter, node: Stage.Node) void {
        if (painter.ninepatch.get(node.style)) |ninepatch| {
            ninepatch.draw(painter.batch, geom.rect.itof(node.bounds), painter.scale);
        }
        if (node.data) |data| {
            const value = painter.store.get(data);
            const vec2 = math.Vec2f.init;
            const area = node.bounds + (node.padding * geom.Rect{ 1, 1, -1, -1 });
            const top_left = vec2(@intToFloat(f32, area[0]), @intToFloat(f32, area[1]));
            switch (value) {
                .Bytes => |string| painter.font.drawText(painter.batch, string, top_left, .{
                    .textBaseline = .Top,
                    .scale = painter.scale,
                    .color = seizer.batch.Color.BLACK,
                }),
                else => {},
            }
        }
    }
};

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .init = init,
    .deinit = deinit,
    .render = render,
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var batch: SpriteBatch = undefined;
var stage: Stage = undefined;
var painter_global: Painter = undefined;

// Assets
var font: BitmapFont = undefined;
var uitexture: Texture = undefined;

fn init() !void {
    font = try BitmapFont.initFromFile(gpa.allocator(), "PressStart2P_8.fnt");
    errdefer font.deinit();

    uitexture = try Texture.initFromFile(gpa.allocator(), "ui.png", .{});
    errdefer uitexture.deinit();

    batch = try SpriteBatch.init(gpa.allocator(), .{ .x = 1, .y = 1 });

    painter_global = Painter{
        .batch = &batch,
        .store = store.Store.init(gpa.allocator()),
        .font = &font,
        .ninepatch = std.EnumMap(NodeStyle, NinePatch).init(.{
            .Frame = NinePatch.initv(uitexture, .{ 0, 0, 48, 48 }, .{ 16, 16 }),
            .Nameplate = NinePatch.initv(uitexture, .{ 48, 0, 48, 48 }, .{ 16, 16 }),
            .Label = NinePatch.initv(uitexture, .{ 96, 24, 12, 12 }, .{ 4, 4 }),
            .Keyup = NinePatch.initv(uitexture, .{ 96, 0, 24, 24 }, .{ 8, 8 }),
            .Keydown = NinePatch.initv(uitexture, .{ 120, 0, 24, 24 }, .{ 8, 8 }),
        }),
        .scale = 2,
    };
    stage = try Stage.init(gpa.allocator(), &painter_global);

    const name_ref = try painter_global.store.new(.{ .Bytes = "Hello, World!" });
    const counter_ref = try painter_global.store.new(.{.Int = 0});
    const counter_label_ref = try painter_global.store.new(.{.Bytes = "0"});
    const dec_label_ref = try painter_global.store.new(.{.Bytes = "<"});
    const inc_label_ref = try painter_global.store.new(.{.Bytes = ">"});
    _ = counter_ref;

    const center = try stage.insert(null, Stage.Node.center(.None));
    const frame = try stage.insert(center, Stage.Node.vlist(.Frame));
    const nameplate = try stage.insert(frame, Stage.Node.relative(.Nameplate).dataValue(name_ref));
    const counter_center = try stage.insert(frame, Stage.Node.center(.None));
    const counter = try stage.insert(counter_center, Stage.Node.hlist(.None));
    const decrement = try stage.insert(counter, Stage.Node.relative(.Keyup).dataValue(dec_label_ref));
    const label_center = try stage.insert(counter, Stage.Node.center(.None));
    const counter_label = try stage.insert(label_center, Stage.Node.relative(.Label).dataValue(counter_label_ref));
    const increment = try stage.insert(counter, Stage.Node.relative(.Keyup).dataValue(inc_label_ref));
    _ = nameplate;
    _ = decrement;
    _ = counter_label;
    _ = increment;
}

fn deinit() void {
    stage.deinit();
    painter_global.deinit();
    font.deinit();
    batch.deinit();
    _ = gpa.deinit();
}

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    _ = alpha;

    // Resize gl viewport to match window
    const screen_size = seizer.getScreenSize();
    gl.viewport(0, 0, screen_size.x, screen_size.y);
    batch.setSize(screen_size);

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    stage.layout(.{ 0, 0, screen_size.x, screen_size.y });
    stage.paint();

    font.drawText(&batch, "Hello, world!", .{ .x = 50, .y = 50 }, .{});
    batch.flush();
}

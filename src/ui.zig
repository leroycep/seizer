//! A simple backend agnostic UI library for zig. Provides tools to quickly layout
//! user interfaces in code and bring them to life on screen. Depends only on the
//! zig std library.

pub const store = @import("ui/store.zig");
pub const Observer = @import("ui/Observer.zig");
pub const LayoutEngine = @import("ui/LayoutEngine.zig");
pub const Node = LayoutEngine.Node;

const std = @import("std");
const seizer = @import("./seizer.zig");
const geom = seizer.geometry;
const SpriteBatch = seizer.batch.SpriteBatch;
const BitmapFont = seizer.font.Bitmap;

/// Manually init
pub const Stage = struct {
    store: store.Store,
    layout: LayoutEngine,
    painter: Painter,
    observer: Observer,

    pub fn deinit(stage: *Stage) void {
        stage.layout.deinit();
        stage.store.deinit();
        stage.painter.deinit();
    }

    pub fn size(stage: *Stage, node: seizer.ui.Node) geom.Vec2 {
        if (node.data) |data| {
            const value = stage.store.get(data);
            switch (value) {
                .Bytes => |string| {
                    const width = stage.painter.font.calcTextWidth(string, stage.painter.scale);
                    const height = stage.painter.font.lineHeight * stage.painter.scale;
                    return geom.vec.ftoi(geom.Vec2f{ width, height });
                },
                .Int => |int| {
                    var buf: [32]u8 = undefined;
                    const string = std.fmt.bufPrint(&buf, "{}", .{int}) catch buf[0..];
                    const width = stage.painter.font.calcTextWidth(string, stage.painter.scale);
                    const height = stage.painter.font.lineHeight * stage.painter.scale;
                    return geom.vec.ftoi(geom.Vec2f{ width, height });
                },
                else => {},
            }
        }
        return geom.Vec2{ 0, 0 };
    }

    pub fn sizeAll(stage: *Stage) void {
        for (stage.layout.nodes.items) |*node| {
            const n = node.*;
            if (stage.painter.padding.get(n.style)) |padding| {
                node.padding = padding * @splat(4, @floatToInt(i32, stage.painter.scale));
            }
            node.min_size = stage.size(n);
        }
    }

    pub fn event(stage: *Stage, evt: seizer.event.Event) ?Observer.NotifyResult {
        var mousepos: ?geom.Vec2 = null;
        switch (evt) {
            .MouseMotion => |mouse| mousepos = geom.Vec2{ mouse.pos.x, mouse.pos.y },
            .MouseButtonDown => |mouse| mousepos = geom.Vec2{ mouse.pos.x, mouse.pos.y },
            .MouseButtonUp => |mouse| mousepos = geom.Vec2{ mouse.pos.x, mouse.pos.y },
            else => {}, // Wait for next switch
        }
        if (mousepos) |p| {
            return stage.observer.notify_pointer(&stage.layout, evt, p);
        }
        return null;
    }

    pub fn paintAll(stage: *Stage, screen_size: geom.Rect) void {
        stage.layout.layout(screen_size);
        for (stage.layout.get_rects()) |node| {
            stage.painter.paint(stage.store, node);
        }
    }
};

/// Takes references to font and batch, user owns
pub const Painter = struct {
    font: *BitmapFont,
    batch: *SpriteBatch,
    padding: std.AutoHashMap(usize, geom.Rect),
    ninepatch: std.AutoHashMap(usize, seizer.ninepatch.NinePatch),
    scale: f32 = 1,

    pub fn init(alloc: std.mem.Allocator, font: *BitmapFont, batch: *SpriteBatch) @This() {
        return @This(){
            .font = font,
            .batch = batch,
            .padding = std.AutoHashMap(usize, geom.Rect).init(alloc),
            .ninepatch = std.AutoHashMap(usize, seizer.ninepatch.NinePatch).init(alloc),
        };
    }

    pub fn deinit(painter: *Painter) void {
        painter.padding.deinit();
        painter.ninepatch.deinit();
    }

    pub fn addStyle(painter: *Painter, style: usize, ninepatch: seizer.ninepatch.NinePatch, padding: geom.Rect) !void {
        try painter.padding.put(style, padding);
        try painter.ninepatch.put(style, ninepatch);
    }

    pub fn paint(painter: *Painter, _store: store.Store, node: seizer.ui.Node) void {
        if (painter.ninepatch.get(node.style)) |ninepatch| {
            ninepatch.draw(painter.batch, geom.rect.itof(node.bounds), painter.scale);
        }
        if (node.data) |data| {
            const value = _store.get(data);
            const vec2 = seizer.math.Vec2f.init;
            const area = node.bounds + (node.padding * geom.Rect{ 1, 1, -1, -1 });
            const top_left = vec2(@intToFloat(f32, area[0]), @intToFloat(f32, area[1]));
            switch (value) {
                .Bytes => |string| {
                    painter.font.drawText(painter.batch, string, top_left, .{
                        .textBaseline = .Top,
                        .scale = painter.scale,
                        .color = seizer.batch.Color.BLACK,
                        .area = geom.rect.itof(node.bounds),
                    });
                },
                .Int => |int| {
                    var buf: [32]u8 = undefined;
                    const string = std.fmt.bufPrint(&buf, "{}", .{int}) catch buf[0..];
                    painter.font.drawText(painter.batch, string, top_left, .{
                        .textBaseline = .Top,
                        .scale = painter.scale,
                        .color = seizer.batch.Color.BLACK,
                        .area = geom.rect.itof(node.bounds),
                    });
                },
                else => {},
            }
        }
    }
};

// pub const BoxStyle = union(enum) {
//     Blank,
//     Patch: seizer.ninepatch.NinePatch,
// };

// pub const ContentStyle = union(enum) {
//     Blank,
//     Text,
//     Number,
// };

// pub const StyleSheet = struct {

// };

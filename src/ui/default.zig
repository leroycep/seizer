const std = @import("std");
const ui = @import("../ui.zig");
const geom = @import("../geometry.zig");
const seizer = @import("seizer");
const Context = @import("../context.zig").Context;
const NineSlice = @import("../nineslice.zig").NineSlice;
const util = @import("../util.zig");

pub const DefaultStage = ui.Stage(NodeStyle, Painter, NodeData);
pub const DefaultNode = DefaultStage.Node;
pub const Audience = ui.Audience;
pub const EventData = ui.EventData;

pub fn init(ctx: *Context) !DefaultStage {
    const painter = try Painter.initAlloc(ctx);
    return DefaultStage.init(ctx.allocator, painter);
}

/// A simple default UI
pub const NodeData = union(enum) {
    const Text = struct { size: f32, text: []const u8 };
    /// Draws text to the screen. Pass a pointer to the text to be rendered.
    Label: Text,
};

pub const NodeStyle = enum {
    none,
    frame,
    nameplate,
    key,
    label,
};

pub const Painter = struct {
    ctx: *Context,
    frame9p: NineSlice,
    nameplate9p: NineSlice,
    keyup9p: NineSlice,
    keydown9p: NineSlice,
    label9p: NineSlice,
    scale: i32,
    scalef: f32,

    pub fn init(ctx: *Context) @This() {
        const vec2 = seizer.math.Vec(2, i32).init;
        // const vec2f = seizer.math.Vec(2, f32).init;
        const fs = @as(i32, @intCast(ctx.tilemap.ninepatches[0].size));
        const frame9p_size = vec2(fs, fs).intToFloat(f32);
        const frame9p_tl = vec2(ctx.tilemap.ninepatches[0].bounds[0], ctx.tilemap.ninepatches[0].bounds[1]);
        const frame9p_br = vec2(ctx.tilemap.ninepatches[0].bounds[2], ctx.tilemap.ninepatches[0].bounds[3]);
        const nps = @as(i32, @intCast(ctx.tilemap.ninepatches[1].size));
        const nameplate9p_size = vec2(nps, nps).intToFloat(f32);
        const nameplate9p_tl = vec2(ctx.tilemap.ninepatches[1].bounds[0], ctx.tilemap.ninepatches[1].bounds[1]);
        const nameplate9p_br = vec2(ctx.tilemap.ninepatches[1].bounds[2], ctx.tilemap.ninepatches[1].bounds[3]);
        const keysize = @as(i32, @intCast(ctx.tilemap.ninepatches[2].size));
        const key_size = vec2(keysize, keysize).intToFloat(f32);
        const keyup9p_tl = vec2(ctx.tilemap.ninepatches[2].bounds[0], ctx.tilemap.ninepatches[2].bounds[1]);
        const keyup9p_br = vec2(ctx.tilemap.ninepatches[2].bounds[2], ctx.tilemap.ninepatches[2].bounds[3]);
        const keydown9p_tl = vec2(ctx.tilemap.ninepatches[3].bounds[0], ctx.tilemap.ninepatches[3].bounds[1]);
        const keydown9p_br = vec2(ctx.tilemap.ninepatches[3].bounds[2], ctx.tilemap.ninepatches[3].bounds[3]);
        const label_size = @as(i32, @intCast(ctx.tilemap.ninepatches[4].size));
        const label9p_size = vec2(label_size, label_size).intToFloat(f32);
        const label9p_tl = vec2(ctx.tilemap.ninepatches[4].bounds[0], ctx.tilemap.ninepatches[4].bounds[1]);
        const label9p_br = vec2(ctx.tilemap.ninepatches[4].bounds[2], ctx.tilemap.ninepatches[4].bounds[3]);
        return @This(){
            .ctx = ctx,
            .frame9p = NineSlice.init(util.pixelToTex(&ctx.tileset_tex, frame9p_tl), util.pixelToTex(&ctx.tileset_tex, frame9p_br), frame9p_size, 2),
            .nameplate9p = NineSlice.init(util.pixelToTex(&ctx.tileset_tex, nameplate9p_tl), util.pixelToTex(&ctx.tileset_tex, nameplate9p_br), nameplate9p_size, 2),
            .keyup9p = NineSlice.init(util.pixelToTex(&ctx.tileset_tex, keyup9p_tl), util.pixelToTex(&ctx.tileset_tex, keyup9p_br), key_size, 2),
            .keydown9p = NineSlice.init(util.pixelToTex(&ctx.tileset_tex, keydown9p_tl), util.pixelToTex(&ctx.tileset_tex, keydown9p_br), key_size, 2),
            .label9p = NineSlice.init(util.pixelToTex(&ctx.tileset_tex, label9p_tl), util.pixelToTex(&ctx.tileset_tex, label9p_br), label9p_size, 2),
            .scale = 2,
            .scalef = 2,
        };
    }

    pub fn initAlloc(ctx: *Context) !*@This() {
        const this = try ctx.allocator.create(@This());
        this.* = @This().init(ctx);
        return this;
    }

    pub fn deinit(this: *@This()) void {
        this.ctx.allocator.destroy(this);
    }

    pub fn padding(this: *@This(), node: DefaultNode) geom.Rect {
        const scale = @splat(4, this.scale);
        const pad: geom.Rect = switch (node.style) {
            .none => .{ 0, 0, 0, 0 },
            .frame => @splat(4, @as(i32, 13)) * scale,
            .nameplate => geom.Rect{ 16, 12, 16, 12 } * scale,
            .key => geom.Rect{ 6, 5, 6, 8 } * scale,
            .label => geom.Rect{ 3, 4, 3, 4 } * scale,
        };
        return pad;
    }

    pub fn size(this: *@This(), node: DefaultNode) geom.Vec2 {
        if (node.data) |data| {
            switch (data) {
                .Label => |label| {
                    const line_height = this.ctx.font.lineHeight * label.size;
                    const line_width = this.ctx.font.calcTextWidth(label.text, label.size);
                    return geom.Vec2{
                        @as(i32, @intFromFloat(line_width)),
                        @as(i32, @intFromFloat(line_height)),
                    };
                },
            }
        }
        return .{ 0, 0 };
    }

    pub fn paint(this: *@This(), node: DefaultNode) void {
        var keydown = false;
        switch (node.style) {
            .none => {},
            .nameplate => {
                this.nameplate9p.draw(&this.ctx.flat, this.ctx.tileset_tex, geom.rect.itof(node.bounds));
            },
            .frame => {
                this.frame9p.draw(&this.ctx.flat, this.ctx.tileset_tex, geom.rect.itof(node.bounds));
            },
            .label => {
                this.label9p.draw(&this.ctx.flat, this.ctx.tileset_tex, geom.rect.itof(node.bounds));
            },
            .key => {
                if (node.pointer_pressed) {
                    keydown = true;
                    this.keydown9p.draw(&this.ctx.flat, this.ctx.tileset_tex, geom.rect.itof(node.bounds));
                } else {
                    this.keyup9p.draw(&this.ctx.flat, this.ctx.tileset_tex, geom.rect.itof(node.bounds));
                }
            },
        }
        const area = node.bounds + (geom.Rect{ 1, 1, -1, -1 } * node.padding);
        var left = geom.rect.left(area);
        var top = if (!keydown) geom.rect.top(area) else geom.rect.top(area) + this.scale;
        if (node.data) |data| {
            switch (data) {
                .Label => |label| {
                    const pos = seizer.math.Vec(2, f32).init(@as(f32, @floatFromInt(left)), @as(f32, @floatFromInt(top)));
                    this.ctx.font.drawText(&this.ctx.flat, label.text, pos, .{ .scale = label.size, .textBaseline = .Top, .color = .{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF } });
                },
            }
        }
    }
};

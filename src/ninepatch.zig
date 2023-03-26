const std = @import("std");
const seizer = @import("./seizer.zig");
const math = seizer.math;
const Vec2f = math.Vec(2, f32);
const vec2f = Vec2f.init;
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;
const Rect = seizer.batch.Rect;
const Quad = seizer.batch.Quad;
const geom = @import("geometry.zig");

pub const NinePatch = struct {
    tex: Texture,
    texPos1: Vec2f,
    texPos2: Vec2f,
    tile_size: Vec2f,

    pub fn initv(tex: Texture, aabb: geom.AABB, tile_size: geom.Vec2f) @This() {
        const rect = geom.aabb.as_rect(aabb);
        const tl = tex.pix2uv(geom.rect.top_left(rect));
        const br = tex.pix2uv(geom.rect.bottom_right(rect));
        return @This(){
            .tex = tex,
            .texPos1 = vec2f(tl[0], tl[1]),
            .texPos2 = vec2f(br[0], br[1]),
            .tile_size = vec2f(tile_size[0], tile_size[1]),
        };
    }

    pub fn init(texPos1: Vec2f, texPos2: Vec2f, tile_size: Vec2f) @This() {
        return @This(){
            .texPos1 = texPos1,
            .texPos2 = texPos2,
            .tile_size = tile_size,
        };
    }

    pub fn draw(this: @This(), renderer: *SpriteBatch, rect: geom.Rectf, scale: f32) void {
        const rects = this.getRects();
        const tl = geom.rect.top_leftf(rect);
        const size = geom.rect.sizef(rect);
        const quads = this.getQuads(vec2f(tl[0], tl[1]), vec2f(size[0], size[1]), scale);
        for (quads, 0..) |quad, i| {
            renderer.drawTexture(this.tex, quad.pos, .{ .size = quad.size, .rect = rects[i] });
        }
    }

    fn getQuads(this: @This(), pos: Vec2f, size: Vec2f, scale: f32) [9]Quad {
        const ts = this.tile_size.scale(scale);
        const inner_size = vec2f(size.x - ts.x * 2, size.y - ts.y * 2);

        const x1 = pos.x;
        const x2 = pos.x + ts.x;
        const x3 = pos.x + size.x - ts.x;

        const y1 = pos.y;
        const y2 = pos.y + ts.y;
        const y3 = pos.y + size.y - ts.y;

        return [9]Quad{
            // Inside first
            .{ .pos = vec2f(x2, y2), .size = inner_size }, // center
            // Edges second
            .{ .pos = vec2f(x2, y1), .size = vec2f(inner_size.x, ts.y) }, // top
            .{ .pos = vec2f(x1, y2), .size = vec2f(ts.x, inner_size.y) }, // left
            .{ .pos = vec2f(x3, y2), .size = vec2f(ts.x, inner_size.y) }, // right
            .{ .pos = vec2f(x2, y3), .size = vec2f(inner_size.x, ts.y) }, // bottom
            // Corners third
            .{ .pos = vec2f(x1, y1), .size = ts }, // tl
            .{ .pos = vec2f(x3, y1), .size = ts }, // tr
            .{ .pos = vec2f(x1, y3), .size = ts }, // bl
            .{ .pos = vec2f(x3, y3), .size = ts }, // br
        };
    }

    fn getRects(this: @This()) [9]Rect {
        const pos1 = this.texPos1;
        const pos2 = this.texPos2;
        const w = pos2.x - pos1.x;
        const h = pos2.y - pos1.y;
        const h1 = pos1.x;
        const h2 = pos1.x + w / 3;
        const h3 = pos1.x + 2 * w / 3;
        const h4 = pos2.x;
        const v1 = pos1.y;
        const v2 = pos1.y + h / 3;
        const v3 = pos1.y + 2 * h / 3;
        const v4 = pos2.y;
        return [9]Rect{
            // Inside first
            .{ .min = vec2f(h2, v2), .max = vec2f(h3, v3) },
            // Edges second
            .{ .min = vec2f(h2, v1), .max = vec2f(h3, v2) }, // top
            .{ .min = vec2f(h1, v2), .max = vec2f(h2, v3) }, // left
            .{ .min = vec2f(h3, v2), .max = vec2f(h4, v3) }, // right
            .{ .min = vec2f(h2, v3), .max = vec2f(h3, v4) }, // bottom
            // Corners third
            .{ .min = vec2f(h1, v1), .max = vec2f(h2, v2) }, // tl
            .{ .min = vec2f(h3, v1), .max = vec2f(h4, v2) }, // tr
            .{ .min = vec2f(h1, v3), .max = vec2f(h2, v4) }, // bl
            .{ .min = vec2f(h3, v3), .max = vec2f(h4, v4) }, // br
        };
    }
};

tex: *seizer.Graphics.Texture,
texPos1: [2]f32,
texPos2: [2]f32,
tile_size: [2]f32,

/// Creates a NinePatch with no outside edges, only a single image that will be stretched
pub fn initStretched(tex: *seizer.Graphics.Texture, texture_size: [2]u32, rect: geom.Rect(f32)) @This() {
    return initv(tex, texture_size, rect, .{ 0, 0 });
}

pub fn initv(tex: *seizer.Graphics.Texture, texture_size: [2]u32, rect: geom.Rect(f32), tile_size: [2]f32) @This() {
    const texture_sizef = [2]f32{
        @floatFromInt(texture_size[0]),
        @floatFromInt(texture_size[1]),
    };
    const top_left = rect.topLeft();
    const bottom_right = rect.bottomRight();
    return @This(){
        .tex = tex,
        .texPos1 = [2]f32{
            top_left[0] / texture_sizef[0],
            top_left[1] / texture_sizef[1],
        },
        .texPos2 = [2]f32{
            bottom_right[0] / texture_sizef[0],
            bottom_right[1] / texture_sizef[1],
        },
        .tile_size = tile_size,
    };
}

pub fn init(tex: *seizer.Graphics.Texture, texPos1: [2]f32, texPos2: [2]f32, tile_size: [2]f32) @This() {
    return @This(){
        .tex = tex,
        .texPos1 = texPos1,
        .texPos2 = texPos2,
        .tile_size = tile_size,
    };
}

const DrawOptions = struct {
    scale: f32 = 1,
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
};
pub fn draw(this: @This(), canvas: Canvas.Transformed, rect: geom.Rect(f32), options: DrawOptions) void {
    const uv_rects = this.getRectsUV();
    const tl = rect.topLeft();
    const size = rect.size;
    const pos_rects = this.getRectsPos(tl, size, options.scale);
    for (pos_rects, uv_rects) |pos_rect, uv_rect| {
        canvas.rect(pos_rect.pos, pos_rect.size, .{
            .texture = this.tex,
            .uv = uv_rect,
            .color = options.color,
        });
    }
}

fn getRectsPos(this: @This(), pos: [2]f32, size: [2]f32, scale: f32) [9]geom.Rect(f32) {
    const ts = .{
        this.tile_size[0] * scale,
        this.tile_size[1] * scale,
    };
    const inner_size = .{ size[0] - ts[0] * 2, size[1] - ts[1] * 2 };

    const x1 = pos[0];
    const x2 = pos[0] + ts[0];
    const x3 = pos[0] + size[0] - ts[0];

    const y1 = pos[1];
    const y2 = pos[1] + ts[1];
    const y3 = pos[1] + size[1] - ts[1];

    return [9]geom.Rect(f32){
        // Inside first
        .{ .pos = .{ x2, y2 }, .size = inner_size }, // center
        // Edges second
        .{ .pos = .{ x2, y1 }, .size = .{ inner_size[0], ts[1] } }, // top
        .{ .pos = .{ x1, y2 }, .size = .{ ts[0], inner_size[1] } }, // left
        .{ .pos = .{ x3, y2 }, .size = .{ ts[0], inner_size[1] } }, // right
        .{ .pos = .{ x2, y3 }, .size = .{ inner_size[0], ts[1] } }, // bottom
        // Corners third
        .{ .pos = .{ x1, y1 }, .size = ts }, // tl
        .{ .pos = .{ x3, y1 }, .size = ts }, // tr
        .{ .pos = .{ x1, y3 }, .size = ts }, // bl
        .{ .pos = .{ x3, y3 }, .size = ts }, // br
    };
}

fn getRectsUV(this: @This()) [9]geom.AABB(f32) {
    const pos1 = this.texPos1;
    const pos2 = this.texPos2;
    const w = pos2[0] - pos1[0];
    const h = pos2[1] - pos1[1];
    const h1 = pos1[0];
    const h2 = pos1[0] + w / 3;
    const h3 = pos1[0] + 2 * w / 3;
    const h4 = pos2[0];
    const v1 = pos1[1];
    const v2 = pos1[1] + h / 3;
    const v3 = pos1[1] + 2 * h / 3;
    const v4 = pos2[1];
    return [9]geom.AABB(f32){
        // Inside first
        .{ .min = .{ h2, v2 }, .max = .{ h3, v3 } },
        // Edges second
        .{ .min = .{ h2, v1 }, .max = .{ h3, v2 } }, // top
        .{ .min = .{ h1, v2 }, .max = .{ h2, v3 } }, // left
        .{ .min = .{ h3, v2 }, .max = .{ h4, v3 } }, // right
        .{ .min = .{ h2, v3 }, .max = .{ h3, v4 } }, // bottom
        // Corners third
        .{ .min = .{ h1, v1 }, .max = .{ h2, v2 } }, // tl
        .{ .min = .{ h3, v1 }, .max = .{ h4, v2 } }, // tr
        .{ .min = .{ h1, v3 }, .max = .{ h2, v4 } }, // bl
        .{ .min = .{ h3, v3 }, .max = .{ h4, v4 } }, // br
    };
}

const std = @import("std");
const seizer = @import("./seizer.zig");
const Canvas = seizer.Canvas;
const geom = @import("geometry.zig");

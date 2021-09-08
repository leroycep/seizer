//! This file implements the loading and rendering of Bitmap fonts in the AngelCode font
//! format. AngelCode fonts can be generated with a tool, either the original one from AngelCode,
//! or Hiero, which was made for libgdx.
//!
//! [AngelCode BMFont]: http://www.angelcode.com/products/bmfont/
//! [Hiero]: https://github.com/libgdx/libgdx/wiki/Hiero

const std = @import("std");
const seizer = @import("../seizer.zig");
const gl = seizer.gl;
const math = seizer.math;
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;
const Color = seizer.batch.Color;

const ArrayList = std.ArrayList;

const util = @import("util");
const Vec2f = math.Vec(2, f32);
const vec2f = Vec2f.init;

const MAX_FILESIZE = 50000;

pub const Bitmap = struct {
    pages: []Texture,
    glyphs: std.AutoHashMap(u32, Glyph),
    lineHeight: f32,
    base: f32,
    scale: Vec2f,

    const Glyph = struct {
        page: u32,
        pos: Vec2f,
        size: Vec2f,
        offset: Vec2f,
        xadvance: f32,
    };

    pub fn initFromFile(allocator: *std.mem.Allocator, filename: []const u8) !@This() {
        const contents = try seizer.fetch(allocator, filename, MAX_FILESIZE);
        defer allocator.free(contents);

        const base_path = std.fs.path.dirname(filename) orelse "./";

        var pages = ArrayList(Texture).init(allocator);
        var glyphs = std.AutoHashMap(u32, Glyph).init(allocator);
        var lineHeight: f32 = undefined;
        var base: f32 = undefined;
        var scaleW: f32 = 0;
        var scaleH: f32 = 0;
        var expected_num_pages: usize = 0;

        var line_iter = std.mem.tokenize(u8, contents, "\n\r");
        while (line_iter.next()) |line| {
            var pair_iter = std.mem.tokenize(u8, line, " \t");

            const kind = pair_iter.next() orelse continue;

            if (std.mem.eql(u8, "char", kind)) {
                var id: ?u32 = null;
                var x: f32 = undefined;
                var y: f32 = undefined;
                var width: f32 = undefined;
                var height: f32 = undefined;
                var xoffset: f32 = undefined;
                var yoffset: f32 = undefined;
                var xadvance: f32 = undefined;
                var page: u32 = undefined;

                while (pair_iter.next()) |pair| {
                    var kv_iter = std.mem.split(u8, pair, "=");
                    const key = kv_iter.next().?;
                    const value = kv_iter.rest();

                    if (std.mem.eql(u8, "id", key)) {
                        id = try std.fmt.parseInt(u32, value, 10);
                    } else if (std.mem.eql(u8, "x", key)) {
                        x = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "y", key)) {
                        y = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "width", key)) {
                        width = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "height", key)) {
                        height = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "xoffset", key)) {
                        xoffset = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "yoffset", key)) {
                        yoffset = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "xadvance", key)) {
                        xadvance = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "page", key)) {
                        page = try std.fmt.parseInt(u32, value, 10);
                    } else if (std.mem.eql(u8, "chnl", key)) {
                        // TODO
                    } else {
                        std.log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                    }
                }

                if (id == null) {
                    return error.InvalidFormat;
                }

                try glyphs.put(id.?, .{
                    .page = page,
                    .pos = vec2f(x, y),
                    .size = vec2f(width, height),
                    .offset = vec2f(xoffset, yoffset),
                    .xadvance = xadvance,
                });
            } else if (std.mem.eql(u8, "common", kind)) {
                while (pair_iter.next()) |pair| {
                    var kv_iter = std.mem.split(u8, pair, "=");
                    const key = kv_iter.next().?;
                    const value = kv_iter.rest();

                    if (std.mem.eql(u8, "lineHeight", key)) {
                        lineHeight = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "base", key)) {
                        base = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "scaleW", key)) {
                        scaleW = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "scaleH", key)) {
                        scaleH = try std.fmt.parseFloat(f32, value);
                    } else if (std.mem.eql(u8, "packed", key)) {
                        // TODO
                    } else if (std.mem.eql(u8, "pages", key)) {
                        expected_num_pages = try std.fmt.parseInt(usize, value, 10);
                    } else {
                        std.log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                    }
                }
            } else if (std.mem.eql(u8, "page", kind)) {
                var id: u32 = @intCast(u32, pages.items.len);
                var page_filename = try allocator.alloc(u8, 0);
                defer allocator.free(page_filename);

                while (pair_iter.next()) |pair| {
                    var kv_iter = std.mem.split(u8, pair, "=");
                    const key = kv_iter.next().?;
                    const value = kv_iter.rest();

                    if (std.mem.eql(u8, "id", key)) {
                        id = try std.fmt.parseInt(u32, value, 10);
                    } else if (std.mem.eql(u8, "file", key)) {
                        const trimmed = std.mem.trim(u8, value, "\"");
                        page_filename = try std.fs.path.join(allocator, &[_][]const u8{ base_path, trimmed });
                    } else {
                        std.log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                    }
                }

                try pages.resize(id + 1);
                pages.items[id] = try Texture.initFromFile(allocator, page_filename, .{});
            }
        }

        if (pages.items.len != expected_num_pages) {
            std.log.warn("Font pages expected {} != font pages found {}", .{ expected_num_pages, pages.items.len });
        }

        return @This(){
            .pages = pages.toOwnedSlice(),
            .glyphs = glyphs,
            .lineHeight = lineHeight,
            .base = base,
            .scale = vec2f(scaleW, scaleH),
        };
    }

    pub fn deinit(this: *@This()) void {
        this.glyphs.allocator.free(this.pages);
        this.glyphs.deinit();
    }

    const TextAlign = enum { Left, Center, Right };
    const TextBaseline = enum { Bottom, Middle, Top };

    const DrawOptions = struct {
        textAlign: TextAlign = .Left,
        textBaseline: TextBaseline = .Bottom,
        color: Color = Color.WHITE,
        scale: f32 = 1,
    };

    pub fn drawText(this: @This(), drawbatcher: *SpriteBatch, text: []const u8, pos: Vec2f, options: DrawOptions) void {
        var x = switch (options.textAlign) {
            .Left, .Right => pos.x,
            .Center => pos.x - (this.calcTextWidth(text, options.scale) / 2),
        };
        var y = switch (options.textBaseline) {
            .Bottom => pos.y - std.math.floor(this.lineHeight * options.scale),
            .Middle => pos.y - std.math.floor(this.lineHeight * options.scale / 2),
            .Top => pos.y,
        };
        const direction: f32 = switch (options.textAlign) {
            .Left, .Center => 1,
            .Right => -1,
        };

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const char = switch (options.textAlign) {
                .Left, .Center => text[i],
                .Right => text[text.len - 1 - i],
            };
            if (this.glyphs.get(char)) |glyph| {
                const xadvance = (glyph.xadvance * options.scale);
                const offset = glyph.offset.scale(options.scale);
                const texture = this.pages[glyph.page];
                // const quad = math.Quad.init(glyph.pos.x, glyph.pos.y, glyph.size.x, glyph.size.y, this.scale.x, this.scale.y);
                const textureSize = texture.size.intToFloat(f32);

                const textAlignOffset = switch (options.textAlign) {
                    .Left, .Center => 0,
                    .Right => -xadvance,
                };

                const renderPos = vec2f(
                    x + offset.x + textAlignOffset,
                    y + offset.y,
                );

                const glyphPos = glyph.pos.divv(textureSize);

                drawbatcher.drawTexture(texture, renderPos, .{
                    .rect = .{ .min = glyphPos, .max = glyph.pos.addv(glyph.size).divv(textureSize) },
                    .size = glyph.size.scale(options.scale),
                    .color = options.color,
                });

                x += direction * xadvance;
            }
        }
    }

    pub fn calcTextWidth(this: @This(), text: []const u8, scale: f32) f32 {
        var total_width: f32 = 0;
        for (text) |char| {
            if (this.glyphs.get(char)) |glyph| {
                const xadvance = (glyph.xadvance * scale);
                total_width += xadvance;
            }
        }
        return total_width;
    }

    pub const GlyphLayout = struct {
        texture: Texture,
        uv1: Vec2f,
        uv2: Vec2f,
        pos: Vec2f,
        size: Vec2f,
    };

    pub const TextLayout = struct {
        glyphs: std.ArrayList(GlyphLayout),
        size: Vec2f,

        pub fn deinit(this: *@This()) void {
            this.glyphs.deinit();
        }

        pub fn draw(this: @This(), drawbatcher: *SpriteBatch, pos: Vec2f) void {
            for (this.glyphs.items) |g| {
                drawbatcher.drawTextureRect(g.texture, g.uv1, g.uv2, g.pos.addv(pos), g.size);
            }
        }
    };

    const LayoutOptions = struct {
        //textAlign: TextAlign = .Left,
        //textBaseline: TextBaseline = .Bottom,
        maxWidth: ?f32 = null,
        // color: math.Color = math.Color.white,
        scale: f32 = 1,
    };

    pub fn layoutText(this: @This(), allocator: *std.mem.Allocator, text: []const u8, options: LayoutOptions) !TextLayout {
        var layout_glyphs = std.ArrayList(GlyphLayout).init(allocator);
        errdefer layout_glyphs.deinit();

        var x: f32 = 0;
        var y: f32 = 0;
        const direction: f32 = 1;

        var width: f32 = 0;

        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const char = text[i];
            if (this.glyphs.get(char)) |glyph| {
                const xadvance = (glyph.xadvance * options.scale);
                const offset = glyph.offset.scale(options.scale);
                const texture = this.pages[glyph.page];
                // const quad = math.Quad.init(glyph.pos.x, glyph.pos.y, glyph.size.x, glyph.size.y, this.scale.x, this.scale.y);
                const textureSize = texture.size.intToFloat(f32);

                if (options.maxWidth != null and x + direction * xadvance > options.maxWidth.?) {
                    x = 0;
                    y += std.math.floor(this.lineHeight * options.scale);
                }

                const textAlignOffset = 0;
                const renderPos = vec2f(
                    x + offset.x + textAlignOffset,
                    y + offset.y,
                );

                const glyph_pos = glyph.pos.divv(textureSize);
                const render_size = glyph.size.scale(options.scale);

                try layout_glyphs.append(.{
                    .texture = texture,
                    .uv1 = glyph_pos,
                    .uv2 = glyph.pos.addv(glyph.size).divv(textureSize),
                    .pos = renderPos,
                    .size = render_size,
                });

                x += direction * xadvance;
                if (x > width) {
                    width = x;
                }
            }
        }

        return TextLayout{
            .glyphs = layout_glyphs,
            .size = vec2f(width, y + std.math.floor(this.lineHeight * options.scale)),
        };
    }
};

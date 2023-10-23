/// This file implements the loading and rendering of Bitmap fonts in the AngelCode font
/// format. AngelCode fonts can be generated with a tool, either the original one from AngelCode,
/// or Hiero, which was made for libgdx.
///
/// [AngelCode BMFont]: http://www.angelcode.com/products/bmfont/
/// [Hiero]: https://github.com/libgdx/libgdx/wiki/Hiero
pages: std.AutoHashMap(u32, []const u8),
glyphs: std.AutoHashMap(u32, Glyph),
lineHeight: f32,
base: f32,
scale: [2]f32,

const Glyph = struct {
    page: u32,
    pos: [2]f32,
    size: [2]f32,
    offset: [2]f32,
    xadvance: f32,
};

const Font = @This();

pub fn parse(allocator: std.mem.Allocator, font_contents: []const u8) !@This() {
    var pages = std.AutoHashMap(u32, []const u8).init(allocator);
    var glyphs = std.AutoHashMap(u32, Glyph).init(allocator);
    var lineHeight: f32 = undefined;
    var base: f32 = undefined;
    var scaleW: f32 = 0;
    var scaleH: f32 = 0;
    var expected_num_pages: usize = 0;

    var next_page_id: u32 = 0;

    var line_iter = std.mem.tokenize(u8, font_contents, "\n\r");
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
                .pos = .{ x, y },
                .size = .{ width, height },
                .offset = .{ xoffset, yoffset },
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
            var id: u32 = next_page_id;
            var page_filename: ?[]const u8 = null;

            while (pair_iter.next()) |pair| {
                var kv_iter = std.mem.split(u8, pair, "=");
                const key = kv_iter.next().?;
                const value = kv_iter.rest();

                if (std.mem.eql(u8, "id", key)) {
                    id = try std.fmt.parseInt(u32, value, 10);
                } else if (std.mem.eql(u8, "file", key)) {
                    page_filename = std.mem.trim(u8, value, "\"");
                } else {
                    std.log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                }
            }

            if (page_filename == null) {
                return error.NoFilenameSpecifiedForPage;
            }

            try pages.put(id, page_filename.?);
            next_page_id = @max(id + 1, next_page_id + 1);
        }
    }

    if (pages.count() != expected_num_pages) {
        std.log.warn("Font pages expected {} != font pages found {}", .{ expected_num_pages, pages.count() });
    }

    return @This(){
        .pages = pages,
        .glyphs = glyphs,
        .lineHeight = lineHeight,
        .base = base,
        .scale = .{ scaleW, scaleH },
    };
}

pub fn deinit(this: *@This()) void {
    this.pages.deinit();
    this.glyphs.deinit();
}

const TextAlign = enum { Left, Center, Right };
const TextBaseline = enum { Bottom, Middle, Top };

pub fn textSize(this: @This(), text: []const u8, scale: f32) [2]f32 {
    var layouter = this.textLayouter(scale);
    layouter.writer().writeAll(text) catch {};
    return layouter.textSize();
}

pub fn fmtTextSize(this: @This(), comptime fmt: []const u8, args: anytype, scale: f32) [2]f32 {
    var layouter = this.textLayouter(scale);
    layouter.writer().print(fmt, args) catch {};
    return layouter.textSize();
}

pub fn textLayouter(this: *const @This(), scale: f32) TextLayouter {
    return TextLayouter{
        .font = this,
        .scale = scale,
    };
}

pub const TextLayouter = struct {
    font: *const Font,
    scale: f32,
    pos: [2]f32 = .{ 0, 0 },
    max_width: f32 = 0,

    pub fn addCharacter(this: *@This(), character: u21) void {
        if (character == '\n') {
            this.pos[1] += this.font.lineHeight * this.scale;
            this.pos[0] = 0;
            return;
        }
        if (this.font.glyphs.get(character)) |glyph| {
            const xadvance = (glyph.xadvance * this.scale);
            this.pos[0] += xadvance;
            this.max_width = @max(this.pos[0], this.max_width);
        }
    }

    /// TODO: Support non-ascii text
    pub fn addText(this: *@This(), text: []const u8) void {
        for (text) |char| {
            this.addCharacter(char);
        }
    }

    pub fn textSize(this: @This()) [2]f32 {
        return .{
            this.max_width,
            this.pos[1] + this.font.lineHeight * this.scale,
        };
    }

    pub fn writer(this: *@This()) Writer {
        return Writer{
            .context = this,
        };
    }

    pub const Writer = std.io.Writer(*@This(), error{}, write);

    pub fn write(this: *@This(), bytes: []const u8) error{}!usize {
        this.addText(bytes);
        return bytes.len;
    }
};

pub const GlyphLayout = struct {
    page: u32,
    uv1: [2]f32,
    uv2: [2]f32,
    pos: [2]f32,
    size: [2]f32,
};

pub const PositionedGlyph = struct {
    page: u32,
    uv1: [2]f32,
    uv2: [2]f32,
    pos: [2]f32,
    size: [2]f32,
};

const LayoutOptions = struct {
    // TODO: textAlign: TextAlign = .Left,
    // TODO: textBaseline: TextBaseline = .Bottom,
    maxWidth: ?f32 = null,
    scale: f32 = 1,
};

pub fn layoutText(this: @This(), allocator: std.mem.Allocator, text: []const u8, options: LayoutOptions, glyphs_out: *std.MultiArrayList(PositionedGlyph)) !void {
    var x: f32 = 0;
    var y: f32 = 0;
    const direction: f32 = 1;

    var width: f32 = 0;

    for (text) |char| {
        // TODO: Handle unknown glyphs
        const glyph = this.glyphs.get(char) orelse continue;

        const xadvance = (glyph.xadvance * options.scale);
        const offset = [2]f32{
            glyph.offset[0] * options.scale,
            glyph.offset[1] * options.scale,
        };
        const texture = this.pages[glyph.page];
        const textureSize = [2]f32{
            @as(f32, @floatFromInt(texture.size[0])),
            @as(f32, @floatFromInt(texture.size[1])),
        };

        if (options.maxWidth != null and x + direction * xadvance > options.maxWidth.?) {
            x = 0;
            y += @floor(this.lineHeight * options.scale);
        }

        const textAlignOffset = 0;
        const renderPos = .{
            x + offset.x + textAlignOffset,
            y + offset.y,
        };

        try glyphs_out.append(allocator, .{
            .texture = texture,
            .uv1 = .{
                glyph.pos[0] / textureSize[0],
                glyph.pos[1] / textureSize[1],
            },
            .uv2 = .{
                (glyph.pos[0] + glyph.size[0]) / textureSize[0],
                (glyph.pos[1] + glyph.size[1]) / textureSize[1],
            },
            .pos = renderPos,
            .size = .{
                glyph.size[0] * options.scale,
                glyph.size[1] * options.scale,
            },
        });

        x += direction * xadvance;
        if (x > width) {
            width = x;
        }
    }

    return glyphs_out;
}

const MAX_FILESIZE = 50000;

const std = @import("std");
const utils = @import("utils");
const zigimg = @import("zigimg");
const gl = @import("zgl");

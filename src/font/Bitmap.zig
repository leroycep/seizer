/// This file implements the loading and rendering of Bitmap fonts in the AngelCode font
/// format. AngelCode fonts can be generated with a tool, either the original one from AngelCode,
/// or Hiero, which was made for libgdx.
///
/// [AngelCode BMFont]: http://www.angelcode.com/products/bmfont/
/// [Hiero]: https://github.com/libgdx/libgdx/wiki/Hiero
pages: std.AutoHashMap(u32, seizer.Texture),
glyphs: std.AutoHashMap(u32, Glyph),
lineHeight: f32,
base: f32,
scale: [2]f32,

pub const Options = struct {
    font_contents: []const u8,
    pages: []const Page,

    pub const Page = struct {
        name: []const u8,
        image: []const u8,
    };
};

pub const Glyph = struct {
    page: u32,
    pos: [2]f32,
    size: [2]f32,
    offset: [2]f32,
    xadvance: f32,
};

pub fn init(allocator: std.mem.Allocator, options: Options) !@This() {
    var pages = std.AutoHashMap(u32, seizer.Texture).init(allocator);
    var glyphs = std.AutoHashMap(u32, Glyph).init(allocator);
    var lineHeight: f32 = undefined;
    var base: f32 = undefined;
    var scaleW: f32 = 0;
    var scaleH: f32 = 0;
    var expected_num_pages: usize = 0;

    var next_page_id: u32 = 0;

    var line_iter = std.mem.tokenize(u8, options.font_contents, "\n\r");
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

            const page = for (options.pages) |page| {
                if (std.mem.eql(u8, page.name, page_filename.?)) {
                    break page;
                }
            } else {
                return error.UknownFontPageFilename;
            };

            const texture = try seizer.Texture.initFromMemory(allocator, page.image, .{});

            try pages.put(id, texture);
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
    var iter = this.pages.valueIterator();
    while (iter.next()) |texture| {
        texture.deinit();
    }
    this.pages.deinit();
    this.glyphs.deinit();
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

const MAX_FILESIZE = 50000;

const std = @import("std");
const utils = @import("utils");
const zigimg = @import("zigimg");
const seizer = @import("../seizer.zig");
const gl = seizer.gl;

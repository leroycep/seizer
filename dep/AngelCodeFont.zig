//! This file implements the loading and layouting of Bitmap fonts in the AngelCode font
//! format. AngelCode fonts can be generated with a tool, either the original one from AngelCode,
//! or Hiero, which was made for libgdx.
//!
//! [AngelCode BMFont]: http://www.angelcode.com/products/bmfont/
//! [Hiero]: https://github.com/libgdx/libgdx/wiki/Hiero
allocator: std.mem.Allocator,
pages: std.AutoHashMapUnmanaged(u32, []const u8),
glyphs: GlyphMap,
lineHeight: f32,
base: f32,
scale: [2]f32,

pub const Page = struct {
    filename: []const u8,
};

const GlyphMap = std.AutoHashMapUnmanaged(Glyph.Id, Glyph);
pub const Glyph = struct {
    page: u32,
    pos: [2]f32,
    size: [2]f32,
    offset: [2]f32,
    xadvance: f32,

    pub const Id = u32;
};

const Font = @This();

pub fn parse(allocator: std.mem.Allocator, font_contents: []const u8) !@This() {
    var pages = std.AutoHashMapUnmanaged(u32, []const u8){};
    defer pages.deinit(allocator);
    var glyphs = GlyphMap{};
    defer glyphs.deinit(allocator);
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
                    log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                }
            }

            if (id == null) {
                return error.InvalidFormat;
            }

            try glyphs.put(allocator, @intCast(id.?), .{
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
                    log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
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
                    log.warn("unknown pair for {s} kind: {s}", .{ kind, pair });
                }
            }

            if (page_filename == null) {
                return error.NoFilenameSpecifiedForPage;
            }

            try pages.put(allocator, id, page_filename.?);
            next_page_id = @max(id + 1, next_page_id + 1);
        }
    }

    if (pages.count() != expected_num_pages) {
        log.warn("Font pages expected {} != font pages found {}", .{ expected_num_pages, pages.count() });
    }

    return @This(){
        .allocator = allocator,
        .pages = pages.move(),
        .glyphs = glyphs.move(),
        .lineHeight = lineHeight,
        .base = base,
        .scale = .{ scaleW, scaleH },
    };
}

pub fn deinit(this: *@This()) void {
    this.pages.deinit(this.allocator);
    this.glyphs.deinit(this.allocator);
}

pub fn textSize(glyphs: *const GlyphMap, line_height: f32, text: []const u8, scale: f32) [2]f32 {
    var layout = textLayout(glyphs, line_height, text, .{ .pos = .{ 0, 0 }, .scale = scale });
    while (layout.next()) |_| {}
    return layout.size;
}

const VoidTextLayout = struct {
    pub fn onGlyphFn(_: void, _: TextLayout.Item) void {}
    pub const Writer = TextLayoutWriter(void, VoidTextLayout.onGlyphFn);
};

pub fn fmtTextSize(glyphs: *const GlyphMap, line_height: f32, comptime format: []const u8, args: anytype, scale: f32) [2]f32 {
    var void_layout_writer: VoidTextLayout.Writer = .{
        .context = {},
        .text_layout = .{
            .glyphs = glyphs,
            .text = "",
            .current_offset = .{ 0, 0 },
            .line_height = line_height,
            .options = .{ .pos = .{ 0, 0 }, .scale = scale },
        },
    };
    void_layout_writer.writer().print(format, args) catch {};
    return void_layout_writer.text_layout.size;
}

pub fn textLayout(glyphs: *const GlyphMap, line_height: f32, text: []const u8, options: TextLayout.Options) TextLayout {
    return .{
        .glyphs = glyphs,
        .text = text,
        .line_height = line_height,
        .current_offset = options.pos,
        .options = options,
    };
}

pub const TextLayout = struct {
    glyphs: *const GlyphMap,
    text: []const u8,
    line_height: f32,
    current_offset: [2]f32,
    index: usize = 0,
    options: Options = .{},
    direction: f32 = 1,
    size: [2]f32 = .{ 0, 0 },

    pub const Options = struct {
        pos: [2]f32 = .{ 0, 0 },
        scale: f32 = 1,
    };

    pub const Item = struct {
        glyph: Glyph,
        pos: [2]f32,
        size: [2]f32,
    };

    pub fn next(this: *@This()) ?Item {
        while (this.index < this.text.len) {
            const byte_count = std.unicode.utf8ByteSequenceLength(this.text[this.index]) catch {
                this.index += 1;
                continue;
            };
            defer this.index += byte_count;
            if (this.index + byte_count > this.text.len) {
                return null;
            }

            const character = std.unicode.utf8Decode(this.text[this.index..][0..byte_count]) catch {
                continue;
            };
            if (this.addCharacter(character)) |item| {
                return item;
            }
        }
        return null;
    }

    fn addCharacter(this: *@This(), character: u21) ?Item {
        if (character == '\n') {
            this.current_offset[1] += this.line_height * this.options.scale;
            this.current_offset[0] = this.options.pos[0];

            this.size = .{
                @max(this.current_offset[0] - this.options.pos[0], this.size[0]),
                @max(this.current_offset[1] - this.options.pos[1] + this.line_height * this.options.scale, this.size[1]),
            };
            return null;
        }
        const glyph = this.glyphs.get(character) orelse {
            var bytes_buffer: [4]u8 = undefined;
            const bytes_written = std.unicode.utf8Encode(character, &bytes_buffer) catch unreachable;
            const bytes = bytes_buffer[0..bytes_written];

            log.warn("No glyph found for character \"{'}\"", .{std.zig.fmtEscapes(bytes)});
            return null;
        };

        const xadvance = (glyph.xadvance * this.options.scale);
        const offset = [2]f32{
            glyph.offset[0] * this.options.scale,
            glyph.offset[1] * this.options.scale,
        };

        const item = Item{
            .glyph = glyph,
            .pos = .{
                this.current_offset[0] + offset[0],
                this.current_offset[1] + offset[1],
            },
            .size = .{
                glyph.size[0] * this.options.scale,
                glyph.size[1] * this.options.scale,
            },
        };

        this.current_offset[0] += this.direction * xadvance;
        this.size = .{
            @max(this.current_offset[0] - this.options.pos[0], this.size[0]),
            @max(this.current_offset[1] - this.options.pos[1] + this.line_height * this.options.scale, this.size[1]),
        };
        return item;
    }
};

pub fn TextLayoutWriter(
    Context: type,
    onGlyphFn: *const fn (Context, TextLayout.Item) void,
) type {
    return struct {
        context: Context,
        text_layout: TextLayout,

        pub const Writer = std.io.GenericWriter(*@This(), error{}, @This().write);

        pub fn writer(this: *@This()) Writer {
            return Writer{ .context = this };
        }

        pub fn write(this: *@This(), bytes: []const u8) error{}!usize {
            this.text_layout.text = bytes;
            this.text_layout.index = 0;
            while (this.text_layout.next()) |item| {
                onGlyphFn(this.context, item);
            }
            return bytes.len;
        }
    };
}

const log = std.log.scoped(.AngelCodeFont);

const std = @import("std");

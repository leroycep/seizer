glTexture: gl.Uint,
size: [2]usize,

pub fn init() !@This() {
    var tex: gl.Uint = 0;
    gl.genTextures(1, &tex);
    if (tex == 0) {
        return error.OpenGLFailure; // Couldn't generate a GL texture handle for some reason
    }

    return @This(){
        .glTexture = tex,
        .size = .{ 0, 0 },
    };
}

pub fn deinit(this: @This()) void {
    gl.deleteTextures(1, &this.glTexture);
}

pub fn pix2uv(tex: @This(), pixel: [2]f32) [2]f32 {
    return .{
        pixel[0] / @as(f32, @floatFromInt(tex.size[0])),
        pixel[1] / @as(f32, @floatFromInt(tex.size[1])),
    };
}

pub const Options = struct {
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,
};

pub const Filter = enum(gl.Int) {
    nearest = gl.NEAREST,
    linear = gl.LINEAR,
};

pub const Wrap = enum(gl.Int) {
    clamp_to_edge = gl.CLAMP_TO_EDGE,
    repeat = gl.REPEAT,
};

pub const InitFromFileOptions = struct {
    // general options
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,

    // tvg specific options
    tvg: ?struct {
        size_hint: tvg.rendering.SizeHint = .inherit,
        anti_aliasing: ?tvg.rendering.AntiAliasing = null,
    } = null,
};

/// Attempts to load the file using zigimg, and then attempts to load the using TinyVG. If both fail,
/// returns `error.UnsupportedFormat`.
pub fn initFromFileContents(alloc: std.mem.Allocator, contents: []const u8, options: InitFromFileOptions) !@This() {
    load_with_zigimg: {
        var image = seizer.zigimg.Image.fromMemory(alloc, contents) catch |err| switch (err) {
            error.Unsupported => break :load_with_zigimg,
            else => return err,
        };
        defer image.deinit();

        return initFromImage(alloc, image, .{
            .min_filter = options.min_filter,
            .mag_filter = options.mag_filter,
            .wrap_s = options.wrap_s,
            .wrap_t = options.wrap_t,
        });
    }

    load_with_tvg: {
        return initFromTVG(alloc, contents, if (options.tvg) |t| .{
            .min_filter = options.min_filter,
            .mag_filter = options.mag_filter,
            .wrap_s = options.wrap_s,
            .wrap_t = options.wrap_t,
            .size_hint = t.size_hint,
            .anti_aliasing = t.anti_aliasing,
        } else .{}) catch |err| switch (err) {
            error.InvalidData => break :load_with_tvg,
            else => return err,
        };
    }

    return error.Unsupported;
}

pub fn initFromImage(alloc: std.mem.Allocator, image: zigimg.Image, options: Options) !@This() {
    // Convert texture to RGBA32 format
    var pixelData = try alloc.alloc([4]u8, image.width * image.height);
    defer alloc.free(pixelData);

    var pixelsIterator = zigimg.color.PixelStorageIterator.init(&image.pixels);

    var i: usize = 0;
    while (pixelsIterator.next()) |color| : (i += 1) {
        const integer_color = color.toRgba(u8);
        pixelData[i][0] = integer_color.r;
        pixelData[i][1] = integer_color.g;
        pixelData[i][2] = integer_color.b;
        pixelData[i][3] = integer_color.a;
    }

    return initFromPixelsRGBA(.{ image.width, image.height }, pixelData, options);
}

const InitFromTVGOptions = struct {
    // general options
    min_filter: Filter = .nearest,
    mag_filter: Filter = .nearest,
    wrap_s: Wrap = .clamp_to_edge,
    wrap_t: Wrap = .clamp_to_edge,

    // tvg specific options
    size_hint: tvg.rendering.SizeHint = .inherit,
    anti_aliasing: ?tvg.rendering.AntiAliasing = null,
};

pub fn initFromTVG(alloc: std.mem.Allocator, tvg_bytes: []const u8, options: InitFromTVGOptions) !@This() {
    var image = try tvg.rendering.renderBuffer(alloc, alloc, options.size_hint, options.anti_aliasing, tvg_bytes);
    defer image.deinit(alloc);

    return try seizer.Texture.initFromPixelsRGBA(
        .{ image.width, image.height },
        @ptrCast(image.pixels[0 .. image.width * image.height]),
        .{},
    );
}

// TODO: allow formats other than RGBA and let OpenGL handle it by telling it what format it is in.
pub fn initFromPixelsRGBA(size: [2]usize, pixels: []const [4]u8, options: Options) !@This() {
    var this = try init();
    errdefer this.deinit();

    gl.bindTexture(gl.TEXTURE_2D, this.glTexture);
    defer gl.bindTexture(gl.TEXTURE_2D, 0);

    gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, @intCast(size[0]), @intCast(size[1]), 0, gl.RGBA, gl.UNSIGNED_BYTE, pixels.ptr);

    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, @intFromEnum(options.wrap_s));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, @intFromEnum(options.wrap_t));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, @intFromEnum(options.min_filter));
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, @intFromEnum(options.mag_filter));

    this.size = size;
    return this;
}

const std = @import("std");
const zigimg = @import("zigimg");
const seizer = @import("./seizer.zig");
const gl = seizer.gl;
const tvg = seizer.tvg;
const geom = seizer.geometry;

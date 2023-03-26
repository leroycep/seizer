const std = @import("std");
const zigimg = @import("zigimg");
const seizer = @import("./seizer.zig");
const gl = seizer.gl;
const geom = seizer.geometry;

pub const Texture = struct {
    glTexture: gl.GLuint,
    size: [2]usize,

    pub fn init() !@This() {
        var tex: gl.GLuint = 0;
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

    pub fn pix2uv(tex: @This(), pixel: geom.Vec2) geom.Vec2f {
        return geom.vec.itof(pixel) / geom.Vec2f{ @intToFloat(f32, tex.size.x), @intToFloat(f32, tex.size.y) };
    }

    pub const InitFromFileOptions = struct {
        minFilter: gl.GLint = gl.NEAREST,
        magFilter: gl.GLint = gl.NEAREST,
        wrapS: gl.GLint = gl.CLAMP_TO_EDGE,
        wrapT: gl.GLint = gl.CLAMP_TO_EDGE,
    };

    pub fn initFromMemory(alloc: std.mem.Allocator, image_contents: []const u8, options: InitFromFileOptions) !@This() {
        var this = try init();
        errdefer this.deinit();

        var load_res = try zigimg.Image.fromMemory(alloc, image_contents);
        defer load_res.deinit();

        gl.bindTexture(gl.TEXTURE_2D, this.glTexture);
        defer gl.bindTexture(gl.TEXTURE_2D, 0);
        const width = @intCast(c_int, load_res.width);
        const height = @intCast(c_int, load_res.height);

        // Convert texture to RGBA32 format
        var pixelData = try alloc.alloc(u8, load_res.width * load_res.height * 4);
        defer alloc.free(pixelData);

        // TODO: skip converting to RGBA and let OpenGL handle it by telling it what format it is in
        // Difficulties: Zigimg pixels are in reverse of what OpenGL expects, and opengl doesn't allow
        // specifying the order of pixels a limited set of options.
        var pixelsIterator = zigimg.color.PixelStorageIterator.init(&load_res.pixels);

        var i: usize = 0;
        while (pixelsIterator.next()) |color| : (i += 1) {
            const integer_color = color.toRgba(u8);
            pixelData[i * 4 + 0] = integer_color.r;
            pixelData[i * 4 + 1] = integer_color.g;
            pixelData[i * 4 + 2] = integer_color.b;
            pixelData[i * 4 + 3] = integer_color.a;
        }

        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, pixelData.ptr);

        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, options.wrapS);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, options.wrapT);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, options.minFilter);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, options.magFilter);

        this.size = .{ load_res.width, load_res.height };
        return this;
    }
};

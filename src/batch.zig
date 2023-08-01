const std = @import("std");
const seizer = @import("./seizer.zig");
const gl = seizer.gl;
const glUtil = seizer.glUtil;
const ArrayList = std.ArrayList;
const Texture = seizer.Texture;

const Vertex = struct {
    pos: [2]f32,
    uv: [2]f32,
    color: [4]u8,
};

pub const Color = extern struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const WHITE = Color{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF };
    pub const BLACK = Color{ .r = 0x00, .g = 0x00, .b = 0x00, .a = 0xFF };
};

pub const Quad = struct {
    pos: [2]f32,
    size: [2]f32,
};

/// A UV rectangle
pub const Rect = struct {
    min: [2]f32,
    max: [2]f32,
};

pub const SpriteBatch = struct {
    program: gl.GLuint,
    vertex_array_object: gl.GLuint,
    vertex_buffer_object: gl.GLuint,
    screenPosUniform: gl.GLint,
    screenPos: [2]i32,
    screenSizeUniform: gl.GLint,
    screenSize: [2]i32,
    draw_buffer: [1024]Vertex,
    num_vertices: usize,
    texture: gl.GLuint,
    clips: std.ArrayList(Quad),

    /// Font should be the name of the font texture and csv minus their extensions
    pub fn init(allocator: std.mem.Allocator, screenSize: [2]i32) !@This() {
        const program = try glUtil.compileShader(
            allocator,
            @embedFile("batch/sprite.vert"),
            @embedFile("batch/sprite.frag"),
        );

        var vbo: gl.GLuint = 0;
        gl.genBuffers(1, &vbo);
        if (vbo == 0)
            return error.OpenGlFailure;

        var vao: gl.GLuint = 0;
        gl.genVertexArrays(1, &vao);
        if (vao == 0)
            return error.OpenGlFailure;

        gl.bindVertexArray(vao);
        defer gl.bindVertexArray(0);

        gl.enableVertexAttribArray(0); // Position attribute
        gl.enableVertexAttribArray(1); // UV attribute
        gl.enableVertexAttribArray(2); // UV attribute

        gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "pos"))));
        gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "uv"))));
        gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, @sizeOf(Vertex), @as(?*const anyopaque, @ptrFromInt(@offsetOf(Vertex, "color"))));
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        return @This(){
            .program = program,
            .vertex_array_object = vao,
            .vertex_buffer_object = vbo,
            .screenSizeUniform = gl.getUniformLocation(program, "screenSize"),
            .screenSize = screenSize,
            .screenPosUniform = gl.getUniformLocation(program, "screenPos"),
            .screenPos = .{ 0, 0 },
            .draw_buffer = undefined,
            .num_vertices = 0,
            .texture = 0,
            .clips = std.ArrayList(Quad).init(allocator),
        };
    }

    pub fn deinit(this: @This()) void {
        gl.deleteProgram(this.program);
        gl.deleteVertexArrays(1, &this.vertex_array_object);
        gl.deleteBuffers(1, &this.vertex_buffer_object);
        this.clips.deinit();
    }

    pub fn setSize(this: *@This(), screenSize: [2]i32) void {
        this.screenSize = screenSize;
    }

    pub fn pushClip(this: *@This(), quad: Quad) void {
        this.flush();
        this.clips.append(quad) catch unreachable;
    }

    pub fn popClip(this: *@This()) void {
        this.flush();
        _ = this.clips.popOrNull();
    }

    pub const DrawBitmapTextOptions = struct {
        text: []const u8,
        font: seizer.font.Bitmap,
        pos: [2]f32,
        scale: f32 = 1.0,
        color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    };

    pub fn drawBitmapText(this: *@This(), options: DrawBitmapTextOptions) void {
        var direction: f32 = 1;
        var pos: [2]f32 = options.pos;
        for (options.text) |char| {
            const glyph = options.font.glyphs.get(char) orelse continue;

            // TODO: Display error of some kind
            const page = options.font.pages.get(glyph.page) orelse continue;

            const xadvance = (glyph.xadvance * options.scale);
            const offset = [2]f32{
                glyph.offset[0] * options.scale,
                glyph.offset[1] * options.scale,
            };
            const texture_size = [2]f32{
                @as(f32, @floatFromInt(page.size[0])),
                @as(f32, @floatFromInt(page.size[1])),
            };

            const textAlignOffset = 0;
            const render_pos = .{
                pos[0] + offset[0] + textAlignOffset,
                pos[1] + offset[1],
            };
            const render_size = .{
                glyph.size[0] * options.scale,
                glyph.size[1] * options.scale,
            };

            this.drawTexture(page, render_pos, .{
                .size = render_size,
                .color = options.color,
                .rect = .{
                    .min = .{
                        glyph.pos[0] / texture_size[0],
                        glyph.pos[1] / texture_size[1],
                    },
                    .max = .{
                        (glyph.pos[0] + glyph.size[0]) / texture_size[0],
                        (glyph.pos[1] + glyph.size[1]) / texture_size[1],
                    },
                },
            });

            pos[0] += direction * xadvance;
        }
    }

    pub const DrawTextureOptions = struct {
        size: ?[2]f32 = null,
        rect: Rect = .{
            .min = .{ 0, 0 },
            .max = .{ 1, 1 },
        },
        color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
    };

    pub fn drawTexture(this: *@This(), texture: Texture, pos: [2]f32, opts: DrawTextureOptions) void {
        const size = opts.size orelse [2]f32{
            @as(f32, @floatFromInt(texture.size[0])),
            @as(f32, @floatFromInt(texture.size[1])),
        };
        this.drawTextureRaw(
            texture.glTexture,
            opts.rect.min,
            opts.rect.max,
            pos,
            .{ pos[0] + size[0], pos[1] },
            .{ pos[0], pos[1] + size[1] },
            .{ pos[0] + size[0], pos[1] + size[1] },
            opts.color,
        );
    }

    // Takes an OpenGL texture handle, a couple of positions, and adds it to the batch
    pub fn drawTextureRaw(
        this: *@This(),
        texture: gl.GLuint,
        texPos1: [2]f32,
        texPos2: [2]f32,
        topLeft: [2]f32,
        topRight: [2]f32,
        botLeft: [2]f32,
        botRight: [2]f32,
        color: [4]u8,
    ) void {
        if (texture != this.texture) {
            this.flush();
            this.texture = texture;
        }
        if (this.num_vertices + 6 > this.draw_buffer.len) {
            this.flush();
        }
        this.draw_buffer[this.num_vertices..][0..6].* = [6]Vertex{
            Vertex{ // top left
                .pos = .{
                    topLeft[0] - 0.5,
                    topLeft[1] - 0.5,
                },
                .uv = texPos1,
                .color = color,
            },
            Vertex{ // bot left
                .pos = .{
                    botLeft[0] - 0.5,
                    botLeft[1] - 0.5,
                },
                .uv = .{
                    texPos1[0],
                    texPos2[1],
                },
                .color = color,
            },
            Vertex{ // top right
                .pos = .{
                    topRight[0] - 0.5,
                    topRight[1] - 0.5,
                },
                .uv = .{
                    texPos2[0],
                    texPos1[1],
                },
                .color = color,
            },
            Vertex{ // bot left
                .pos = .{
                    botLeft[0] - 0.5,
                    botLeft[1] - 0.5,
                },
                .uv = .{
                    texPos1[0],
                    texPos2[1],
                },
                .color = color,
            },
            Vertex{ // top right
                .pos = .{
                    topRight[0] - 0.5,
                    topRight[1] - 0.5,
                },
                .uv = .{
                    texPos2[0],
                    texPos1[1],
                },
                .color = color,
            },
            Vertex{ // bot right
                .pos = .{
                    botRight[0] - 0.5,
                    botRight[1] - 0.5,
                },
                .uv = .{
                    texPos2[0],
                    texPos2[1],
                },
                .color = color,
            },
        };
        this.num_vertices += 6;
    }

    pub fn flush(this: *@This()) void {
        if (this.clips.items.len == 0) {
            gl.disable(gl.SCISSOR_TEST);
        } else {
            gl.enable(gl.SCISSOR_TEST);
            const quad = this.clips.items[this.clips.items.len - 1];
            gl.scissor(
                @as(c_int, @intFromFloat(quad.pos[0] - 0.5)),
                @as(c_int, @intFromFloat(@floor(@as(f32, @floatFromInt(this.screenSize[1])) - quad.pos[1] - quad.size[1] - 0.5))),
                @as(c_int, @intFromFloat(quad.size[0])),
                @as(c_int, @intFromFloat(quad.size[1])),
            );
        }

        if (this.num_vertices == 0) return;

        gl.bindVertexArray(this.vertex_array_object);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.vertex_buffer_object);
        gl.bufferData(gl.ARRAY_BUFFER, @as(isize, @intCast(this.num_vertices)) * @sizeOf(Vertex), &this.draw_buffer, gl.STATIC_DRAW);
        defer this.num_vertices = 0;
        gl.bindVertexArray(0);
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        gl.useProgram(this.program);
        defer gl.useProgram(0);

        gl.disable(gl.DEPTH_TEST);
        defer gl.enable(gl.DEPTH_TEST);
        gl.disable(gl.CULL_FACE);
        defer gl.enable(gl.CULL_FACE);
        gl.enable(gl.BLEND);
        defer gl.disable(gl.BLEND);
        gl.depthFunc(gl.ALWAYS);
        defer gl.depthFunc(gl.LESS);
        gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, this.texture);

        gl.uniform2i(this.screenPosUniform, this.screenPos[0], this.screenPos[1]);
        gl.uniform2i(this.screenSizeUniform, this.screenSize[0], this.screenSize[1]);

        gl.bindVertexArray(this.vertex_array_object);
        defer gl.bindVertexArray(0);
        gl.drawArrays(gl.TRIANGLES, 0, @as(c_int, @intCast(this.num_vertices)));
    }
};

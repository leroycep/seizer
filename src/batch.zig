const std = @import("std");
const seizer = @import("./seizer.zig");
const gl = seizer.gl;
const glUtil = seizer.glUtil;
const math = seizer.math;
const Vec = math.Vec;
const Vec2i = math.Vec(2, i32);
const vec2i = Vec2i.init;
const Vec2f = math.Vec(2, f32);
const vec2f = Vec2f.init;
const Mat4f = math.Mat4(f32);
const ArrayList = std.ArrayList;
const Texture = seizer.Texture;

const Vertex = packed struct {
    x: f32,
    y: f32,
    u: f32,
    v: f32,
    color: Color,
};

pub const Color = packed struct {
    r: u8,
    g: u8,
    b: u8,
    a: u8,

    pub const WHITE = Color{ .r = 0xFF, .g = 0xFF, .b = 0xFF, .a = 0xFF };
};

pub const Quad = struct {
    pos: Vec2f,
    size: Vec2f,
};

/// A UV rectangle
pub const Rect = struct {
    min: Vec2f,
    max: Vec2f,
};

pub const SpriteBatch = struct {
    program: gl.GLuint,
    vertex_array_object: gl.GLuint,
    vertex_buffer_object: gl.GLuint,
    screenPosUniform: gl.GLint,
    screenPos: Vec2i,
    screenSizeUniform: gl.GLint,
    screenSize: Vec2i,
    draw_buffer: [1024]Vertex,
    num_vertices: usize,
    texture: gl.GLuint,
    clips: std.ArrayList(Quad),

    /// Font should be the name of the font texture and csv minus their extensions
    pub fn init(allocator: *std.mem.Allocator, screenSize: Vec2i) !@This() {
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
        gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const c_void, @offsetOf(Vertex, "x")));
        gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const c_void, @offsetOf(Vertex, "u")));
        gl.vertexAttribPointer(2, 4, gl.UNSIGNED_BYTE, gl.TRUE, @sizeOf(Vertex), @intToPtr(?*const c_void, @offsetOf(Vertex, "color")));
        gl.bindBuffer(gl.ARRAY_BUFFER, 0);

        return @This(){
            .program = program,
            .vertex_array_object = vao,
            .vertex_buffer_object = vbo,
            .screenSizeUniform = gl.getUniformLocation(program, "screenSize"),
            .screenSize = screenSize,
            .screenPosUniform = gl.getUniformLocation(program, "screenPos"),
            .screenPos = .{ .x = 0, .y = 0 },
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

    pub fn setSize(this: *@This(), screenSize: Vec2i) void {
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

    pub const DrawTextureOptions = struct {
        size: ?Vec2f = null,
        rect: Rect = .{
            .min = vec2f(0, 0),
            .max = vec2f(1, 1),
        },
        color: Color = Color.WHITE,
    };

    pub fn drawTexture(this: *@This(), texture: Texture, pos: Vec2f, opts: DrawTextureOptions) void {
        const size = opts.size orelse texture.size.intToFloat(f32);
        this.drawTextureRaw(texture.glTexture, opts.rect.min, opts.rect.max, pos, size, opts.color);
    }

    // Takes an OpenGL texture handle, a couple of positions, and adds it to the batch
    pub fn drawTextureRaw(this: *@This(), texture: gl.GLuint, texPos1: Vec2f, texPos2: Vec2f, pos: Vec2f, size: Vec2f, color: Color) void {
        if (texture != this.texture) {
            this.flush();
            this.texture = texture;
        }
        if (this.num_vertices + 6 > this.draw_buffer.len) {
            this.flush();
        }
        this.draw_buffer[this.num_vertices..][0..6].* = [6]Vertex{
            Vertex{ // top left
                .x = pos.x - 0.5,
                .y = pos.y - 0.5,
                .u = texPos1.x,
                .v = texPos1.y,
                .color = color,
            },
            Vertex{ // bot left
                .x = pos.x - 0.5,
                .y = pos.y + size.y - 0.5,
                .u = texPos1.x,
                .v = texPos2.y,
                .color = color,
            },
            Vertex{ // top right
                .x = pos.x + size.x - 0.5,
                .y = pos.y - 0.5,
                .u = texPos2.x,
                .v = texPos1.y,
                .color = color,
            },
            Vertex{ // bot left
                .x = pos.x - 0.5,
                .y = pos.y + size.y - 0.5,
                .u = texPos1.x,
                .v = texPos2.y,
                .color = color,
            },
            Vertex{ // top right
                .x = pos.x + size.x - 0.5,
                .y = pos.y - 0.5,
                .u = texPos2.x,
                .v = texPos1.y,
                .color = color,
            },
            Vertex{ // bot right
                .x = pos.x + size.x - 0.5,
                .y = pos.y + size.y - 0.5,
                .u = texPos2.x,
                .v = texPos2.y,
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
                @floatToInt(c_int, quad.pos.x - 0.5),
                @floatToInt(c_int, std.math.floor(@intToFloat(f32, this.screenSize.y) - quad.pos.y - quad.size.y - 0.5)),
                @floatToInt(c_int, quad.size.x),
                @floatToInt(c_int, quad.size.y),
            );
        }

        if (this.num_vertices == 0) return;

        gl.bindVertexArray(this.vertex_array_object);
        gl.bindBuffer(gl.ARRAY_BUFFER, this.vertex_buffer_object);
        gl.bufferData(gl.ARRAY_BUFFER, @intCast(isize, this.num_vertices) * @sizeOf(Vertex), &this.draw_buffer, gl.STATIC_DRAW);
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

        gl.uniform2i(this.screenPosUniform, this.screenPos.x, this.screenPos.y);
        gl.uniform2i(this.screenSizeUniform, this.screenSize.x, this.screenSize.y);

        gl.bindVertexArray(this.vertex_array_object);
        defer gl.bindVertexArray(0);
        gl.drawArrays(gl.TRIANGLES, 0, @intCast(c_int, this.num_vertices));
    }
};

//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.

const VERT_SHADER =
    \\ #version 300 es
    \\ layout(location = 0) in vec2 vertexPosition;
    \\ layout(location = 1) in vec2 texturePosition;
    \\
    \\ out vec2 uv;
    \\
    \\ void main() {
    \\   gl_Position = vec4(vertexPosition.xy, 0.0, 1.0);
    \\   uv = texturePosition;
    \\ }
;

const FRAG_SHADER =
    \\ #version 300 es
    \\ in highp vec2 uv;
    \\
    \\ layout(location = 0) out highp vec4 color;
    \\
    \\ uniform highp sampler2D texID;
    \\
    \\ void main() {
    \\   color = texture(texID, uv);
    \\ }
;

const Vertex = extern struct {
    // Position on screen
    x: f32,
    y: f32,
    // Position of in texture
    u: f32,
    v: f32,
};

const VERTS = [_]Vertex{
    // Triangle 1
    .{ .x = -0.5, .y = 0.5, .u = 0.0, .v = 0.0 },
    .{ .x = 0.5, .y = 0.5, .u = 1.0, .v = 0.0 },
    .{ .x = 0.5, .y = -0.5, .u = 1.0, .v = 1.0 },

    // Triangle 2
    .{ .x = -0.5, .y = 0.5, .u = 0.0, .v = 0.0 },
    .{ .x = 0.5, .y = -0.5, .u = 1.0, .v = 1.0 },
    .{ .x = -0.5, .y = -0.5, .u = 0.0, .v = 1.0 },
};

pub const main = seizer.main;

var player_texture: seizer.Texture = undefined;
var shader_program: gl.Uint = undefined;
var vbo: gl.Uint = undefined;
var vao: gl.Uint = undefined;

pub fn init() !void {
    _ = try seizer.platform.createWindow(.{
        .title = "Textures - Seizer Example",
        .on_render = render,
    });

    player_texture = try seizer.Texture.initFromFileContents(seizer.platform.allocator(), @embedFile("assets/wedge.png"), .{});
    std.log.info("Texture is {}x{} pixels", .{ player_texture.size[0], player_texture.size[1] });

    shader_program = try seizer.glUtil.compileShader(seizer.platform.allocator(), VERT_SHADER, FRAG_SHADER);

    // Create VBO to display texture
    gl.genBuffers(1, &vbo);
    if (vbo == 0)
        return error.OpenGlFailure;

    gl.genVertexArrays(1, &vao);
    if (vao == 0)
        return error.OpenGlFailure;

    gl.bindVertexArray(vao);
    defer gl.bindVertexArray(0);

    gl.enableVertexAttribArray(0); // Position attribute
    gl.enableVertexAttribArray(1); // UV attribute

    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "x")));
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @ptrFromInt(@offsetOf(Vertex, "u")));
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);

    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);
}

fn render(window: seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    // Draw VBO to screen
    gl.useProgram(shader_program);
    defer gl.useProgram(0);

    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, player_texture.glTexture);

    gl.bindVertexArray(vao);
    defer gl.bindVertexArray(0);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    defer gl.bindBuffer(gl.ARRAY_BUFFER, 0);
    gl.bufferData(gl.ARRAY_BUFFER, @as(isize, @intCast(VERTS.len)) * @sizeOf(Vertex), &VERTS, gl.STATIC_DRAW);

    gl.drawArrays(gl.TRIANGLES, 0, 6);

    try window.swapBuffers();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

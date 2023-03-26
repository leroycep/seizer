//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.
const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");
const Texture = seizer.Texture;

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .init = init,
    .deinit = deinit,
    .render = render,
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var player_texture: Texture = undefined;
var shader_program: gl.GLuint = undefined;
var vbo: gl.GLuint = 0;
var vao: gl.GLuint = 0;

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

fn init() !void {
    player_texture = try Texture.initFromMemory(gpa.allocator(), @embedFile("assets/wedge.png"), .{});
    errdefer player_texture.deinit();

    std.log.info("Texture is {}x{} pixels", .{ player_texture.size[0], player_texture.size[1] });

    shader_program = try seizer.glUtil.compileShader(gpa.allocator(), VERT_SHADER, FRAG_SHADER);

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
    gl.vertexAttribPointer(0, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const anyopaque, @offsetOf(Vertex, "x")));
    gl.vertexAttribPointer(1, 2, gl.FLOAT, gl.FALSE, @sizeOf(Vertex), @intToPtr(?*const anyopaque, @offsetOf(Vertex, "u")));
    gl.bindBuffer(gl.ARRAY_BUFFER, 0);
}

fn deinit() void {
    player_texture.deinit();
    _ = gpa.deinit();
}

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

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    _ = alpha;

    // Resize gl viewport to match window
    const screen_size = seizer.getScreenSize();
    gl.viewport(0, 0, screen_size[0], screen_size[1]);

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
    gl.bufferData(gl.ARRAY_BUFFER, @intCast(isize, VERTS.len) * @sizeOf(Vertex), &VERTS, gl.STATIC_DRAW);

    gl.drawArrays(gl.TRIANGLES, 0, 6);
}

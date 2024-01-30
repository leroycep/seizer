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

var gl_binding: gl.Binding = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa.allocator());

    _ = seizer.backend.glfw.c.glfwSetErrorCallback(&seizer.backend.glfw.defaultErrorCallback);

    const glfw_init_res = seizer.backend.glfw.c.glfwInit();
    if (glfw_init_res != 1) {
        std.debug.print("glfw init error: {}\n", .{glfw_init_res});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.c.glfwTerminate();

    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_OPENGL_DEBUG_CONTEXT, seizer.backend.glfw.c.GLFW_TRUE);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CLIENT_API, seizer.backend.glfw.c.GLFW_OPENGL_ES_API);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MINOR, 0);

    //  Open window
    const window = seizer.backend.glfw.c.glfwCreateWindow(640, 640, "Textures - Seizer", null, null) orelse return error.GlfwCreateWindow;
    errdefer seizer.backend.glfw.c.glfwDestroyWindow(window);

    seizer.backend.glfw.c.glfwMakeContextCurrent(window);

    gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&gl_binding);

    // Set up input callbacks
    _ = seizer.backend.glfw.c.glfwSetFramebufferSizeCallback(window, &glfw_framebuffer_size_callback);

    // Load texture
    var player_texture = try seizer.Texture.initFromFileContents(gpa.allocator(), @embedFile("assets/wedge.png"), .{});
    errdefer player_texture.deinit();

    std.log.info("Texture is {}x{} pixels", .{ player_texture.size[0], player_texture.size[1] });

    const shader_program = try seizer.glUtil.compileShader(gpa.allocator(), VERT_SHADER, FRAG_SHADER);

    // Create VBO to display texture
    var vbo: gl.Uint = 0;
    gl.genBuffers(1, &vbo);
    if (vbo == 0)
        return error.OpenGlFailure;

    var vao: gl.Uint = 0;
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

    while (seizer.backend.glfw.c.glfwWindowShouldClose(window) != seizer.backend.glfw.c.GLFW_TRUE) {
        seizer.backend.glfw.c.glfwPollEvents();

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

        seizer.backend.glfw.c.glfwSwapBuffers(window);
    }
}

fn glfw_framebuffer_size_callback(window: ?*seizer.backend.glfw.c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
    _ = window;
    gl.viewport(
        0,
        0,
        @intCast(width),
        @intCast(height),
    );
}

const GlBindingLoader = struct {
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(command_name: [:0]const u8) ?AnyCFnPtr {
        return seizer.backend.glfw.c.glfwGetProcAddress(command_name);
    }

    pub fn extensionSupported(extension_name: [:0]const u8) bool {
        return seizer.backend.glfw.c.glfwExtensionSupported(extension_name);
    }
};

fn error_callback_for_glfw(err: c_int, description: ?[*:0]const u8) callconv(.C) void {
    std.debug.print("Error 0x{x}: {?s}\n", .{ err, description });
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

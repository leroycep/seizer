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
    const window = seizer.backend.glfw.c.glfwCreateWindow(640, 640, "Bitmap Font - Seizer", null, null) orelse return error.GlfwCreateWindow;
    errdefer seizer.backend.glfw.c.glfwDestroyWindow(window);

    seizer.backend.glfw.c.glfwMakeContextCurrent(window);

    gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&gl_binding);

    // Set up input callbacks
    _ = seizer.backend.glfw.c.glfwSetFramebufferSizeCallback(window, &glfw_framebuffer_size_callback);

    var canvas = try seizer.Canvas.init(gpa.allocator(), .{});
    defer canvas.deinit(gpa.allocator());

    // load player texture
    var player_texture = try seizer.Texture.initFromMemory(gpa.allocator(), @embedFile("assets/wedge.png"), .{});
    defer player_texture.deinit();

    while (seizer.backend.glfw.c.glfwWindowShouldClose(window) != seizer.backend.glfw.c.GLFW_TRUE) {
        seizer.backend.glfw.c.glfwPollEvents();

        gl.clearColor(0.7, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        var window_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetWindowSize(window, &window_size[0], &window_size[1]);

        var framebuffer_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetFramebufferSize(window, &framebuffer_size[0], &framebuffer_size[1]);

        canvas.begin(.{
            .window_size = [2]f32{
                @floatFromInt(window_size[0]),
                @floatFromInt(window_size[1]),
            },
            .framebuffer_size = [2]f32{
                @floatFromInt(framebuffer_size[0]),
                @floatFromInt(framebuffer_size[1]),
            },
        });
        canvas.rect(.{ 50, 50 }, [2]f32{ @floatFromInt(player_texture.size[0]), @floatFromInt(player_texture.size[1]) }, .{ .texture = player_texture.glTexture });
        canvas.end();

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

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

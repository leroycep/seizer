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

    // render shield icon into a bitmap
    var shield_texture = try seizer.Texture.initFromTVG(gpa.allocator(), &shield_icon_tvg, .{});
    defer shield_texture.deinit();

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
        canvas.rect(.{ 50, 50 }, [2]f32{ @floatFromInt(shield_texture.size[0]), @floatFromInt(shield_texture.size[1]) }, .{ .texture = shield_texture.glTexture });
        canvas.end();

        seizer.backend.glfw.c.glfwSwapBuffers(window);
    }
}

const shield_icon_tvg = [_]u8{
    0x72, 0x56, 0x01, 0x42, 0x18, 0x18, 0x02, 0x29, 0xad, 0xff, 0xff, 0xff,
    0xf1, 0xe8, 0xff, 0x03, 0x02, 0x00, 0x04, 0x05, 0x03, 0x30, 0x04, 0x00,
    0x0c, 0x14, 0x02, 0x2c, 0x03, 0x0c, 0x42, 0x1b, 0x57, 0x30, 0x5c, 0x03,
    0x45, 0x57, 0x54, 0x42, 0x54, 0x2c, 0x02, 0x14, 0x45, 0x44, 0x03, 0x40,
    0x4b, 0x38, 0x51, 0x30, 0x54, 0x03, 0x28, 0x51, 0x20, 0x4b, 0x1b, 0x44,
    0x03, 0x1a, 0x42, 0x19, 0x40, 0x18, 0x3e, 0x03, 0x18, 0x37, 0x23, 0x32,
    0x30, 0x32, 0x03, 0x3d, 0x32, 0x48, 0x37, 0x48, 0x3e, 0x03, 0x47, 0x40,
    0x46, 0x42, 0x45, 0x44, 0x30, 0x14, 0x03, 0x36, 0x14, 0x3c, 0x19, 0x3c,
    0x20, 0x03, 0x3c, 0x26, 0x37, 0x2c, 0x30, 0x2c, 0x03, 0x2a, 0x2c, 0x24,
    0x27, 0x24, 0x20, 0x03, 0x24, 0x1a, 0x29, 0x14, 0x30, 0x14, 0x00,
};

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
const tvg = seizer.tvg;
const std = @import("std");

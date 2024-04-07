var gl_binding: gl.Binding = undefined;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa.allocator());

    _ = seizer.backend.glfw.setErrorCallback(seizer.backend.glfw.defaultErrorCallback);

    if (!seizer.backend.glfw.init(.{})) {
        std.log.err("failed to initialize GLFW: {?s}\n", .{seizer.backend.glfw.getErrorString()});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.terminate();

    //  Open window
    const window = seizer.backend.glfw.Window.create(640, 640, "Bitmap Font - Seizer", null, null, .{}) orelse return error.GlfwCreateWindow;
    defer window.destroy();

    seizer.backend.glfw.makeContextCurrent(window);

    gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&gl_binding);

    // Set up input callbacks
    window.setFramebufferSizeCallback(glfw_framebuffer_size_callback);

    var canvas = try seizer.Canvas.init(gpa.allocator(), .{});
    defer canvas.deinit(gpa.allocator());

    while (!window.shouldClose()) {
        seizer.backend.glfw.pollEvents();

        gl.clearColor(0.7, 0.5, 0.5, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        const window_size = window.getSize();
        const framebuffer_size = window.getFramebufferSize();
        canvas.begin(.{
            .window_size = [2]f32{
                @floatFromInt(window_size.width),
                @floatFromInt(window_size.height),
            },
            .framebuffer_size = [2]f32{
                @floatFromInt(framebuffer_size.width),
                @floatFromInt(framebuffer_size.height),
            },
        });
        _ = canvas.writeText(.{ 50, 50 }, "Hello, world!", .{});
        canvas.end();

        window.swapBuffers();
    }
}

fn glfw_framebuffer_size_callback(window: seizer.backend.glfw.Window, width: u32, height: u32) void {
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

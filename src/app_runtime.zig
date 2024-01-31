/// This is a module provided by the user of seizer! It should have a public function called init that accepts
/// a `*seizer.Stage` parameter.
const app = @import("app");

// var gl_binding: gl.Binding = undefined;

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    const args = try std.process.argsAlloc(gpa);
    defer std.process.argsFree(gpa, args);

    var stage = seizer.Stage{
        .gpa = gpa,
    };
    defer stage.deinit();

    if (!@hasDecl(app, "init")) {
        @compileError("App has no `init` function!");
    }
    try app.init(&stage);

    const handler = stage.handler orelse return;

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa);

    _ = seizer.backend.glfw.c.glfwSetErrorCallback(&seizer.backend.glfw.defaultErrorCallback);

    const glfw_init_res = seizer.backend.glfw.c.glfwInit();
    if (glfw_init_res != 1) {
        std.debug.print("glfw init error: {}\n", .{glfw_init_res});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.c.glfwTerminate();

    var past_paths = std.ArrayList([]const u8).init(gpa);
    defer past_paths.deinit();

    var current_path: []const u8 = if (args.len > 1) args[1] else "";

    // !!!Setup client state!!!

    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_OPENGL_DEBUG_CONTEXT, seizer.backend.glfw.c.GLFW_TRUE);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CLIENT_API, seizer.backend.glfw.c.GLFW_OPENGL_ES_API);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MAJOR, 3);
    seizer.backend.glfw.c.glfwWindowHint(seizer.backend.glfw.c.GLFW_CONTEXT_VERSION_MINOR, 0);

    //  Open window
    const glfw_window = seizer.backend.glfw.c.glfwCreateWindow(640, 640, "seizer", null, null) orelse return error.GlfwCreateWindow;
    defer seizer.backend.glfw.c.glfwDestroyWindow(glfw_window);

    seizer.backend.glfw.c.glfwMakeContextCurrent(glfw_window);

    var gl_binding: gl.Binding = undefined;
    gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&gl_binding);

    // Set up input callbacks
    _ = seizer.backend.glfw.c.glfwSetInputMode(glfw_window, seizer.backend.glfw.c.GLFW_STICKY_KEYS, seizer.backend.glfw.c.GLFW_TRUE);
    _ = seizer.backend.glfw.c.glfwSetInputMode(glfw_window, seizer.backend.glfw.c.GLFW_STICKY_MOUSE_BUTTONS, seizer.backend.glfw.c.GLFW_TRUE);
    _ = seizer.backend.glfw.c.glfwSetFramebufferSizeCallback(glfw_window, &glfw_framebuffer_size_callback);

    var canvas = try seizer.Canvas.init(stage.gpa, .{});
    defer canvas.deinit(stage.gpa);

    var source_textures = std.StringHashMap(seizer.Texture).init(gpa);
    defer source_textures.deinit();

    while (seizer.backend.glfw.c.glfwWindowShouldClose(glfw_window) != seizer.backend.glfw.c.GLFW_TRUE) {
        seizer.backend.glfw.c.glfwPollEvents();

        if (seizer.backend.glfw.c.glfwGetKey(glfw_window, seizer.backend.glfw.c.GLFW_KEY_BACKSPACE) == seizer.backend.glfw.c.GLFW_PRESS) {
            if (past_paths.popOrNull()) |previous_path| {
                current_path = previous_path;
            }
        }

        // get response
        var request_arena = std.heap.ArenaAllocator.init(gpa);
        defer request_arena.deinit();

        const response = try handler.interface.respond(handler.ptr, &stage, .{
            .arena = request_arena.allocator(),
            .path = current_path,
        });

        var elements: []const seizer.Screen.Element = &.{};
        switch (response) {
            .text => |text| {
                const stdout = std.io.getStdOut();
                try stdout.writeAll(text);
                seizer.backend.glfw.c.glfwSetWindowShouldClose(glfw_window, seizer.backend.glfw.c.GLFW_TRUE);
            },
            .image_data => {
                seizer.backend.glfw.c.glfwSetWindowShouldClose(glfw_window, seizer.backend.glfw.c.GLFW_TRUE);
            },

            .screen => |screen_elements| elements = screen_elements,
        }

        // Clear screen
        gl.clearColor(0.0, 0.0, 0.0, 1.0);
        gl.clear(gl.COLOR_BUFFER_BIT);

        var window_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetWindowSize(glfw_window, &window_size[0], &window_size[1]);

        var framebuffer_size: [2]c_int = undefined;
        seizer.backend.glfw.c.glfwGetFramebufferSize(glfw_window, &framebuffer_size[0], &framebuffer_size[1]);

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

        const mouse_button_state = seizer.backend.glfw.c.glfwGetMouseButton(glfw_window, seizer.backend.glfw.c.GLFW_MOUSE_BUTTON_LEFT);
        const is_pressed = mouse_button_state == seizer.backend.glfw.c.GLFW_PRESS;
        var mouse_pos_f64: [2]f64 = undefined;
        seizer.backend.glfw.c.glfwGetCursorPos(glfw_window, &mouse_pos_f64[0], &mouse_pos_f64[1]);

        // var text_writer = canvas.textWriter(.{});
        var pos = [2]f32{ 0, 0 };
        for (elements) |element| {
            switch (element) {
                .image => |image| {
                    const texture_gop = try source_textures.getOrPut(image.source);
                    if (!texture_gop.found_existing) {
                        var image_request_arena = std.heap.ArenaAllocator.init(gpa);
                        defer image_request_arena.deinit();

                        const image_data_response = try handler.interface.respond(handler.ptr, &stage, .{
                            .arena = image_request_arena.allocator(),
                            .path = image.source,
                        });
                        if (image_data_response != .image_data) return error.InvalidImage;
                        const image_data = image_data_response.image_data;

                        texture_gop.value_ptr.* = try seizer.Texture.initFromFileContents(stage.gpa, image_data, .{});
                    }
                    const texture = texture_gop.value_ptr;
                    canvas.rect(pos, [2]f32{ @floatFromInt(texture.size[0]), @floatFromInt(texture.size[1]) }, .{ .texture = texture_gop.value_ptr.glTexture });
                },
                .text => |text| {
                    const text_size = canvas.writeText(pos, text, .{ .scale = 1.0 });
                    pos[1] += text_size[1];
                },
                .link => |link| {
                    const text_size = canvas.writeText(pos, link.text, .{ .scale = 1.0 });
                    if (is_pressed and mouse_pos_f64[0] > pos[0] and mouse_pos_f64[1] > pos[1] and mouse_pos_f64[0] < pos[0] + text_size[0] and mouse_pos_f64[1] < pos[1] + text_size[1]) {
                        std.log.debug("link [{s}]({s}) clicked!", .{ link.text, link.href });
                        try past_paths.append(current_path);
                        current_path = link.href;
                    }
                    pos[1] += text_size[1];
                },
            }
        }

        canvas.end();
        seizer.backend.glfw.c.glfwSwapBuffers(glfw_window);
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

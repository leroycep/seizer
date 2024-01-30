/// This is a module provided by the user of seizer! It should have a public function called init that accepts
/// a `*seizer.Stage` parameter.
const app = @import("app");

var gl_binding: gl.Binding = undefined;

pub fn main() !void {
    var general_allocator = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = general_allocator.deinit();
    const gpa = general_allocator.allocator();

    var response_arena = std.heap.ArenaAllocator.init(gpa);
    defer response_arena.deinit();

    var stage = seizer.Stage{
        .gpa = gpa,
        .response_arena = response_arena.allocator(),
    };

    if (!@hasDecl(app, "init")) {
        @compileError("App has no `init` function!");
    }
    try app.init(&stage);

    const response = stage.default_response;

    // GLFW setup
    try seizer.backend.glfw.loadDynamicLibraries(gpa);

    _ = seizer.backend.glfw.c.glfwSetErrorCallback(&seizer.backend.glfw.defaultErrorCallback);

    const glfw_init_res = seizer.backend.glfw.c.glfwInit();
    if (glfw_init_res != 1) {
        std.debug.print("glfw init error: {}\n", .{glfw_init_res});
        std.process.exit(1);
    }
    defer seizer.backend.glfw.c.glfwTerminate();

    try response.interface.run(response.ptr, &stage);
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

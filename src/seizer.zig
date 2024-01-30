// NOTE: Sort the imports alphabetically, please

pub const backend = @import("./backend.zig");
pub const gl = @import("gl");
pub const tvg = @import("tvg");
pub const zigimg = @import("zigimg");

pub const Canvas = @import("./Canvas.zig");
pub const NinePatch = @import("./NinePatch.zig");
pub const Texture = @import("./Texture.zig");

pub const Stage = struct {
    /// A general purpose allocator
    gpa: std.mem.Allocator,
    response_arena: std.mem.Allocator,
    default_response: Response = Help.GLOBAL.response(),
    responses: std.StringArrayHashMapUnmanaged(Response) = .{},

    pub fn createWindow(stage: *Stage, options: Window.Options) !*Window {
        const window = try stage.response_arena.create(Window);
        window.* = .{
            .options = options,
        };
        return window;
    }
};

pub const Response = struct {
    ptr: *anyopaque,
    interface: Interface,

    pub const Interface = struct {
        run: *const fn (ptr: *anyopaque, stage: *Stage) anyerror!void,
    };
};

pub const Help = struct {
    pub var GLOBAL = Help{};

    pub fn response(this: *@This()) Response {
        return Response{
            .ptr = this,
            .interface = .{
                .run = run,
            },
        };
    }

    pub fn run(this_opaque_ptr: *anyopaque, stage: *Stage) anyerror!void {
        _ = this_opaque_ptr;
        std.debug.print("Commands\n", .{});
        for (stage.responses.keys()) |path| {
            std.debug.print("\t{s}\n", .{path});
        }
    }
};

pub const Window = struct {
    options: Options,

    glfw_window: ?*backend.glfw.c.GLFWwindow = null,
    gl_binding: gl.Binding = undefined,
    canvas: Canvas = undefined,

    pub const Options = struct {
        title: []const u8,
        render: struct {
            userdata: ?*anyopaque = null,
            function: *const fn (?*anyopaque, *Window, *Stage) anyerror!void,
        },
    };

    pub fn response(window: *Window) Response {
        return Response{
            .ptr = window,
            .interface = .{
                .run = run,
            },
        };
    }

    pub fn run(this_opaque_ptr: *anyopaque, stage: *Stage) anyerror!void {
        const this: *@This() = @ptrCast(@alignCast(this_opaque_ptr));

        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_OPENGL_DEBUG_CONTEXT, backend.glfw.c.GLFW_TRUE);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CLIENT_API, backend.glfw.c.GLFW_OPENGL_ES_API);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CONTEXT_VERSION_MINOR, 0);

        //  Open window
        this.glfw_window = backend.glfw.c.glfwCreateWindow(640, 640, this.options.title.ptr, null, null) orelse return error.GlfwCreateWindow;
        errdefer backend.glfw.c.glfwDestroyWindow(this.glfw_window);

        backend.glfw.c.glfwMakeContextCurrent(this.glfw_window);

        this.gl_binding.init(backend.glfw.GlBindingLoader);
        gl.makeBindingCurrent(&this.gl_binding);

        // Set up input callbacks
        _ = backend.glfw.c.glfwSetFramebufferSizeCallback(this.glfw_window, &glfw_framebuffer_size_callback);

        this.canvas = try Canvas.init(stage.gpa, .{});
        defer this.canvas.deinit(stage.gpa);

        while (backend.glfw.c.glfwWindowShouldClose(this.glfw_window) != backend.glfw.c.GLFW_TRUE) {
            backend.glfw.c.glfwPollEvents();

            try this.options.render.function(this.options.render.userdata, this, stage);

            backend.glfw.c.glfwSwapBuffers(this.glfw_window);
        }
    }

    fn glfw_framebuffer_size_callback(window: ?*backend.glfw.c.GLFWwindow, width: c_int, height: c_int) callconv(.C) void {
        _ = window;
        gl.viewport(
            0,
            0,
            @intCast(width),
            @intCast(height),
        );
    }
};

const std = @import("std");

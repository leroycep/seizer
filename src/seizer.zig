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
    handler: ?Handler = null,
    // response_arena: std.mem.Allocator,
    // responses: std.StringArrayHashMapUnmanaged(Response) = .{},

    // next_action: ?[]const u8 = null,

    // pub fn createWindow(stage: *Stage, options: Window.Options) !*Window {
    //     const window = try stage.response_arena.create(Window);
    //     window.* = .{
    //         .options = options,
    //     };
    //     return window;
    // }

    // pub fn addImage(stage: *Stage, path: []const u8, image_data: []const u8) !void {
    //     try stage.responses.put(stage.gpa, path, .{ .image = image_data });
    // }

    // pub fn addScreen(stage: *Stage, path: []const u8, options: Screen.Options) !*Screen {
    //     const screen = try stage.response_arena.create(Screen);
    //     screen.* = .{
    //         .arena = std.heap.ArenaAllocator.init(stage.gpa),
    //         .options = options,
    //     };
    //     try stage.responses.put(stage.gpa, path, screen.response());
    //     return screen;
    // }

    pub fn deinit(stage: *Stage) void {
        _ = stage;
        // for (stage.responses.values()) |response| {
        //     response.deinit();
        // }
        // stage.responses.deinit(stage.gpa);
    }
};

pub const Response = union(enum) {
    text: []const u8,
    image_data: []const u8,
    screen: []const Screen.Element,
};

pub const Request = struct {
    /// An arena that will be freed after the request is finished.
    arena: std.mem.Allocator,
    path: []const u8,
};

pub const Handler = struct {
    ptr: *anyopaque,
    interface: Interface,

    pub const Interface = struct {
        respond: *const fn (ptr: *anyopaque, stage: *Stage, request: Request) anyerror!Response,
        deinit: ?*const fn (ptr: *anyopaque) void = null,
    };

    pub fn deinit(handler: Handler) void {
        if (handler.interface.deinit) |deinit_function| {
            deinit_function(handler.ptr);
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
            .handler = Handler{
                .ptr = window,
                .interface = .{
                    .run = run,
                },
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

pub const StaticResponse = struct {
    data: []const u8,

    pub fn response(this: *@This()) Handler {
        return Handler{
            .ptr = this,
            .interface = .{
                .run = run,
            },
        };
    }

    pub fn run(this_opaque_ptr: *anyopaque, stage: *Stage) anyerror!void {
        const this: *@This() = @ptrCast(@alignCast(this_opaque_ptr));
        _ = stage;
        return this.data;
    }
};

pub const Screen = struct {
    options: Options,
    arena: std.heap.ArenaAllocator,
    elements: std.ArrayListUnmanaged(Element) = .{},

    pub const Element = union(enum) {
        text: []const u8,
        link: struct {
            text: []const u8,
            href: []const u8,
        },
        image: struct {
            source: []const u8,
        },
        canvas: struct {
            ptr: *anyopaque,
            render: *const fn (ptr: *anyopaque, canvas: *Canvas) anyerror!void,
        },
    };

    pub const Options = struct {};

    pub fn response(this: *@This()) Response {
        return Response{
            .handler = Handler{
                .ptr = this,
                .interface = .{
                    .run = run,
                    .deinit = deinit,
                },
            },
        };
    }

    pub fn addText(this: *@This(), text: []const u8) !void {
        try this.elements.append(this.arena.allocator(), Element{ .text = text });
    }

    pub fn addLink(this: *@This(), text: []const u8, href: []const u8) !void {
        try this.elements.append(this.arena.allocator(), Element{ .link = .{ .text = text, .href = href } });
    }

    pub fn run(this_opaque_ptr: *anyopaque, stage: *Stage) anyerror!void {
        const this: *@This() = @ptrCast(@alignCast(this_opaque_ptr));

        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_OPENGL_DEBUG_CONTEXT, backend.glfw.c.GLFW_TRUE);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CLIENT_API, backend.glfw.c.GLFW_OPENGL_ES_API);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CONTEXT_VERSION_MAJOR, 3);
        backend.glfw.c.glfwWindowHint(backend.glfw.c.GLFW_CONTEXT_VERSION_MINOR, 0);

        //  Open window
        const glfw_window = backend.glfw.c.glfwCreateWindow(640, 640, "seizer", null, null) orelse return error.GlfwCreateWindow;
        defer backend.glfw.c.glfwDestroyWindow(glfw_window);

        backend.glfw.c.glfwMakeContextCurrent(glfw_window);

        var gl_binding: gl.Binding = undefined;
        gl_binding.init(backend.glfw.GlBindingLoader);
        gl.makeBindingCurrent(&gl_binding);

        // Set up input callbacks
        _ = backend.glfw.c.glfwSetInputMode(glfw_window, backend.glfw.c.GLFW_STICKY_MOUSE_BUTTONS, backend.glfw.c.GLFW_TRUE);
        _ = backend.glfw.c.glfwSetFramebufferSizeCallback(glfw_window, &glfw_framebuffer_size_callback);

        var canvas = try Canvas.init(stage.gpa, .{});
        defer canvas.deinit(stage.gpa);

        while (backend.glfw.c.glfwWindowShouldClose(glfw_window) != backend.glfw.c.GLFW_TRUE) {
            backend.glfw.c.glfwPollEvents();

            gl.clearColor(0.0, 0.0, 0.0, 1.0);
            gl.clear(gl.COLOR_BUFFER_BIT);

            var window_size: [2]c_int = undefined;
            backend.glfw.c.glfwGetWindowSize(glfw_window, &window_size[0], &window_size[1]);

            var framebuffer_size: [2]c_int = undefined;
            backend.glfw.c.glfwGetFramebufferSize(glfw_window, &framebuffer_size[0], &framebuffer_size[1]);

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

            const mouse_button_state = backend.glfw.c.glfwGetMouseButton(glfw_window, backend.glfw.c.GLFW_MOUSE_BUTTON_LEFT);
            const is_pressed = mouse_button_state == backend.glfw.c.GLFW_PRESS;
            var mouse_pos_f64: [2]f64 = undefined;
            backend.glfw.c.glfwGetCursorPos(glfw_window, &mouse_pos_f64[0], &mouse_pos_f64[1]);

            // var text_writer = canvas.textWriter(.{});
            var pos = [2]f32{ 0, 0 };
            for (this.elements.items) |element| {
                switch (element) {
                    .text => |text| {
                        const text_size = canvas.writeText(pos, text, .{ .scale = 1.0 });
                        pos[1] += text_size[1];
                    },
                    .link => |link| {
                        const text_size = canvas.writeText(pos, link.text, .{ .scale = 1.0 });
                        if (is_pressed and mouse_pos_f64[0] > pos[0] and mouse_pos_f64[1] > pos[1] and mouse_pos_f64[0] < pos[0] + text_size[0] and mouse_pos_f64[1] < pos[1] + text_size[1]) {
                            std.log.debug("link [{s}]({s}) clicked!", .{ link.text, link.href });
                            stage.next_action = link.href;
                            backend.glfw.c.glfwSetWindowShouldClose(glfw_window, backend.glfw.c.GLFW_TRUE);
                        }
                        pos[1] += text_size[1];
                    },
                }
            }

            canvas.end();
            backend.glfw.c.glfwSwapBuffers(glfw_window);
        }

        // const stdout = std.io.getStdOut();
        // for (this.elements.items) |element| {
        //     switch (element) {
        //         .text => |text| try stdout.writeAll(text),
        //         .link => |link| try stdout.writer().print("[{s}]({s})", .{ link.text, link.href }),
        //     }
        // }
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

    pub fn deinit(this_opaque_ptr: *anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(this_opaque_ptr));
        this.arena.deinit();
    }
};

const std = @import("std");

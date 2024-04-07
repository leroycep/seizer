const std = @import("std");
const seizer = @import("seizer.zig");
const gl = seizer.gl;

gpa: std.mem.Allocator,
windows: std.ArrayListUnmanaged(*seizer.Window) = .{},

pub fn deinit(this: *@This()) void {
    for (this.windows.items) |window| {
        window.destroy();
        this.gpa.destroy(window);
    }
    this.windows.deinit(this.gpa);
}

pub fn createWindow(this: *@This(), options: struct {
    title: [:0]const u8,
    on_render: *const fn (*seizer.Window) anyerror!void,
    on_destroy: ?*const fn (*seizer.Window) void = null,
    size: [2]u32 = .{ 640, 480 },
}) !*seizer.Window {
    try this.windows.ensureUnusedCapacity(this.gpa, 1);

    const window = try this.gpa.create(seizer.Window);
    errdefer this.gpa.destroy(window);

    const glfw_window = seizer.backend.glfw.Window.create(options.size[0], options.size[1], options.title, null, null, .{}) orelse return error.GlfwCreateWindow;
    errdefer glfw_window.destroy();

    seizer.backend.glfw.makeContextCurrent(glfw_window);

    window.* = .{
        .glfw_window = glfw_window,
        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };
    window.gl_binding.init(seizer.backend.glfw.GlBindingLoader);
    gl.makeBindingCurrent(&window.gl_binding);

    this.windows.appendAssumeCapacity(window);

    // Set up input callbacks
    glfw_window.setFramebufferSizeCallback(glfw_framebuffer_size_callback);

    return window;
}

pub fn anyWindowsOpen(this: *@This()) bool {
    var index = this.windows.items.len;
    while (index > 0) : (index -= 1) {
        const window = this.windows.items[index - 1];
        if (!window.glfw_window.shouldClose()) {
            return true;
        } else {
            window.destroy();
            _ = this.windows.swapRemove(index - 1);
            this.gpa.destroy(window);
        }
    }
    return false;
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

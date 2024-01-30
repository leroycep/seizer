pub fn init(stage: *seizer.Stage) !void {
    const main_window = try stage.createWindow(.{
        .title = "seizer - example - image",
        .render = .{ .function = &render },
    });
    stage.default_response = main_window.response();
    log.debug("app initialized", .{});
}

// TODO: figure out better way to dynamically load assets
var player_texture_opt: ?seizer.Texture = null;

pub fn render(ptr: ?*anyopaque, window: *seizer.Window, stage: *seizer.Stage) !void {
    _ = ptr;

    const player_texture = player_texture_opt orelse (try seizer.Texture.initFromFileContents(stage.gpa, @embedFile("assets/wedge.png"), .{}));

    gl.clearColor(0.0, 0.0, 0.0, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    var window_size: [2]c_int = undefined;
    seizer.backend.glfw.c.glfwGetWindowSize(window.glfw_window, &window_size[0], &window_size[1]);

    var framebuffer_size: [2]c_int = undefined;
    seizer.backend.glfw.c.glfwGetFramebufferSize(window.glfw_window, &framebuffer_size[0], &framebuffer_size[1]);

    window.canvas.begin(.{
        .window_size = [2]f32{
            @floatFromInt(window_size[0]),
            @floatFromInt(window_size[1]),
        },
        .framebuffer_size = [2]f32{
            @floatFromInt(framebuffer_size[0]),
            @floatFromInt(framebuffer_size[1]),
        },
    });
    window.canvas.rect(.{ 50, 50 }, [2]f32{ @floatFromInt(player_texture.size[0]), @floatFromInt(player_texture.size[1]) }, .{ .texture = player_texture.glTexture });
    window.canvas.end();
}

const log = std.log.scoped(.example_clear);

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

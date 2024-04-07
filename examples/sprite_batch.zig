pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var player_texture: seizer.Texture = undefined;

pub fn init(context: *seizer.Context) !void {
    _ = try context.createWindow(.{
        .title = "Sprite Batch - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(context.gpa, .{});
    errdefer canvas.deinit();

    player_texture = try seizer.Texture.initFromFileContents(context.gpa, @embedFile("assets/wedge.png"), .{});
}

pub fn deinit(window: *seizer.Window) void {
    _ = window;
    canvas.deinit();
}

fn render(window: *seizer.Window) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    canvas.rect(.{ 50, 50 }, [2]f32{ @floatFromInt(player_texture.size[0]), @floatFromInt(player_texture.size[1]) }, .{ .texture = player_texture.glTexture });
    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

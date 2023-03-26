//! This example loads a texture from a file (using the Texture struct from seizer which uses image
//! parsing from zigimg), and then renders it to the screen. It avoids using the SpriteBatcher to
//! demonstrate how to render a textured rectangle to the screen at a low level.
const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");
const Texture = seizer.Texture;
const SpriteBatch = seizer.batch.SpriteBatch;

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .init = init,
    .deinit = deinit,
    .render = render,
});

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var player_texture: Texture = undefined;
var batch: SpriteBatch = undefined;

fn init() !void {
    player_texture = try Texture.initFromMemory(gpa.allocator(), @embedFile("assets/wedge.png"), .{});
    errdefer player_texture.deinit();

    batch = try SpriteBatch.init(gpa.allocator(), .{ 1, 1 });
}

fn deinit() void {
    player_texture.deinit();
    _ = gpa.deinit();
}

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    _ = alpha;

    // Resize gl viewport to match window
    const screen_size = seizer.getScreenSize();
    gl.viewport(0, 0, screen_size[0], screen_size[1]);
    batch.setSize(screen_size);

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    batch.drawTexture(player_texture, .{ 50, 50 }, .{});
    batch.flush();
}

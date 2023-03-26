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
var batch: SpriteBatch = undefined;
var font: seizer.font.Bitmap = undefined;

fn init() !void {
    font = try seizer.font.Bitmap.init(gpa.allocator(), .{
        .font_contents = @embedFile("assets/PressStart2P_8.fnt"),
        .pages = &.{
            .{
                .name = "PressStart2P_8.png",
                .image = @embedFile("assets/PressStart2P_8.png"),
            },
        },
    });
    errdefer font.deinit();

    batch = try SpriteBatch.init(gpa.allocator(), .{ 1, 1 });
}

fn deinit() void {
    font.deinit();
    batch.deinit();
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

    batch.drawBitmapText(.{
        .text = "Hello, world!",
        .font = font,
        .pos = .{ 50, 50 },
    });
    batch.flush();
}

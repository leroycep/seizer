const seizer = @import("seizer");
const gl = seizer.gl;
const builtin = @import("builtin");

// Call the comptime function `seizer.run`, which will ensure that everything is
// set up for the platform we are targeting.
pub usingnamespace seizer.run(.{
    .render = render,
});

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    _ = alpha;

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

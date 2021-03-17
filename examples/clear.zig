const seizer = @import("seizer");
const gl = seizer.gl;

// `main()` must return void, or else start.zig will try to print to stderr
// when an error occurs. Since the web target doesn't support stderr, it will
// fail to compile. So keep error unions out of `main`'s return type.
pub fn main() void {
    seizer.run(.{
        .render = render,
    });
}

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

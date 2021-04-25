const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;

// `main()` must return void, or else start.zig will try to print to stderr
// when an error occurs. Since the web target doesn't support stderr, it will
// fail to compile. So keep error unions out of `main`'s return type.
pub fn main() void {
    seizer.run(.{
        .init = init,
        .deinit = deinit,
        .update = update,
        .render = render,
    });
}

var gpa = std.heap.GeneralPurposeAllocator(.{}){};
var sound: seizer.audio.SoundHandle = undefined;
var sound_node: seizer.audio.NodeHandle = undefined;

fn init() !void {
    sound = try seizer.audio.engine.load(&gpa.allocator, "WilhelmScream.wav", 2 * 1024 * 1024);
    sound_node = seizer.audio.engine.createSoundNode(sound);
    seizer.audio.engine.connectToOutput(sound_node);
    seizer.audio.engine.play(sound_node);
}

fn deinit() void {
    seizer.audio.engine.deinit(sound);
    _ = gpa.deinit();
}

fn update(time: f64, delta: f64) !void {
    if (time > 1.5) {
        seizer.quit();
    }
}

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

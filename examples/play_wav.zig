const std = @import("std");
const seizer = @import("seizer");
const gl = seizer.gl;
const audio = seizer.audio;

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
var audioEngine: audio.Engine = undefined;
var sound: seizer.audio.SoundHandle = undefined;

fn init() !void {
    try audioEngine.init(&gpa.allocator);

    sound = try audioEngine.load(&gpa.allocator, "WilhelmScream.wav", 2 * 1024 * 1024);

    const sound_node = audioEngine.createSoundNode();
    const filter_node = audioEngine.createBiquadNode(sound_node, .{ .kind = .lowpass, .freq = 1000.0, .q = 1 });
    const mixer_node = try audioEngine.createMixerNode(&[_]audio.MixerInput{
        .{ .handle = sound_node, .gain = 1 },
    });
    audioEngine.connectToOutput(filter_node);

    const delay_node = try audioEngine.createDelayOutputNode(0.5);
    _ = try audioEngine.createDelayInputNode(sound_node, delay_node);
    audioEngine.connectToOutput(delay_node);

    audioEngine.play(sound_node, sound);
}

fn deinit() void {
    audioEngine.freeSound(sound);
    audioEngine.deinit();
    _ = gpa.deinit();
}

fn update(time: f64, delta: f64) !void {
    if (time > 2) {
        seizer.quit();
    }
}

// Errors are okay to return from the functions that you pass to `seizer.run()`.
fn render(alpha: f64) !void {
    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);
}

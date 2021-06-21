const std = @import("std");
const Timer = std.time.Timer;

pub const math = @import("math");
pub const event = @import("./event.zig");
pub const backend = if (std.builtin.cpu.arch == .wasm32) @import("web/web.zig") else @import("sdl/sdl.zig");
pub const glUtil = @import("./gl_util.zig");

pub usingnamespace backend;

pub const App = struct {
    init: fn () callconv(.Async) anyerror!void = onInitDoNothing,
    deinit: fn () void = onDeinitDoNothing,
    event: fn (event: event.Event) anyerror!void = onEventDoNothing,
    update: fn (currentTime: f64, delta: f64) anyerror!void = onUpdateDoNothing,
    render: fn (alpha: f64) anyerror!void,
    window: struct {
        title: [:0]const u8 = "Zig Game Engine",
        width: ?i32 = null,
        height: ?i32 = null,
    } = .{},
    maxDeltaSeconds: f64 = 0.25,
    tickDeltaSeconds: f64 = 16.0 / 1000.0,
    sdlControllerDBPath: ?[:0]const u8 = null,
};

fn onInitDoNothing() anyerror!void {}
fn onDeinitDoNothing() void {}
fn onEventDoNothing(e: event.Event) anyerror!void {
    // Do nothing but listen for the quit event
    switch (e) {
        .Quit => quit(),
        else => {},
    }
}
fn onUpdateDoNothing(currentTime: f64, delta: f64) anyerror!void {}

// Utility functions for generating/installing HTML or JS that are needed for the web target
pub const GenerateWebOptions = struct {
    includeAudioEngine: bool = true,
};

pub fn generateWebFiles(dir: std.fs.Dir, options: GenerateWebOptions) !void {
    try dir.writeFile("seizer.js", @embedFile("web/seizer.js"));
    if (options.includeAudioEngine) {
        try dir.writeFile("audio_engine.js", @embedFile("web/audio_engine.js"));
    }
}

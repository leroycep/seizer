const std = @import("std");
const builtin = @import("builtin");
const Timer = std.time.Timer;

// NOTE: Sort the imports alphabetically, please

pub const batch = @import("./batch.zig");
pub const backend = if (builtin.cpu.arch == .wasm32) @import("web/web.zig") else @import("sdl/sdl.zig");
pub const event = @import("./event.zig");
pub const font = @import("./font.zig");
pub const glUtil = @import("./gl_util.zig");
pub const geometry = @import("./geometry.zig");
pub const mem = @import("./mem.zig");
pub const ninepatch = @import("./ninepatch.zig");
pub const scene = @import("./scene.zig");
pub const ui = @import("./ui.zig");

pub usingnamespace backend;

pub const Texture = @import("./texture.zig").Texture;

pub const App = struct {
    init: *const fn () anyerror!void = onInitDoNothing,
    deinit: *const fn () void = onDeinitDoNothing,
    event: *const fn (event: event.Event) anyerror!void = onEventDoNothing,
    update: *const fn (currentTime: f64, delta: f64) anyerror!void = onUpdateDoNothing,
    render: *const fn (alpha: f64) anyerror!void,
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
        .Quit => backend.quit(),
        else => {},
    }
}
fn onUpdateDoNothing(currentTime: f64, delta: f64) anyerror!void {
    _ = currentTime;
    _ = delta;
}

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

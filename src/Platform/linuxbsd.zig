pub const PLATFORM = seizer.Platform{
    .name = "linuxbsd",
    .main = main,
    .allocator = getAllocator,
    .loop = _getLoop,
    .setShouldExit = _setShouldExit,
    .writeFile = writeFile,
    .readFile = readFile,
    .setDeinitCallback = setDeinitFn,
    .setEventCallback = setEventCallback,
    .getTracer = getTracer,
};

var gpa = std.heap.GeneralPurposeAllocator(.{ .retain_metadata = builtin.mode == .Debug }){};
var loop: xev.Loop = undefined;
// var evdev: EvDev = undefined;
var should_exit: bool = false;
var deinit_fn: ?seizer.Platform.DeinitFn = null;

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    defer _ = gpa.deinit();

    loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // evdev = try EvDev.init(gpa.allocator(), &loop);
    // defer evdev.deinit();
    // try evdev.scanForDevices();

    // Call root module's `init()` function
    root.init() catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return;
    };
    defer {
        if (deinit_fn) |deinit| {
            deinit();
        }
    }
    while (!should_exit) {
        try loop.run(.once);
    }
}

pub fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

fn _getLoop() *xev.Loop {
    return &loop;
}

fn _setShouldExit(new_should_exit: bool) void {
    should_exit = new_should_exit;
}

pub fn writeFile(options: seizer.Platform.WriteFileOptions) void {
    linuxbsd_fs.writeFile(gpa.allocator(), options);
}

pub fn readFile(options: seizer.Platform.ReadFileOptions) void {
    linuxbsd_fs.readFile(gpa.allocator(), options);
}

fn setEventCallback(new_on_event_callback: ?*const fn (event: seizer.input.Event) anyerror!void) void {
    _ = new_on_event_callback;
    // window_manager.setEventCallback(new_on_event_callback);
}

fn setDeinitFn(new_deinit_fn: ?seizer.Platform.DeinitFn) void {
    deinit_fn = new_deinit_fn;
}

var tracer: ?otel.trace.Tracer = null;
fn getTracer() otel.trace.Tracer {
    if (tracer == null) tracer = otel.api.trace.getTracer(.{ .name = "seizer", .version = "0.1.0" });
    return tracer;
}

pub const EvDev = @import("./linuxbsd/evdev.zig");

const linuxbsd_fs = @import("./linuxbsd/fs.zig");

const otel = @import("opentelemetry");
const xev = @import("xev");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

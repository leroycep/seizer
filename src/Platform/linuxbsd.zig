pub const PLATFORM = seizer.Platform{
    .name = "linuxbsd",
    .main = main,
    .allocator = getAllocator,
    .createGraphics = createGraphics,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
    .writeFile = writeFile,
    .readFile = readFile,
    .setDeinitCallback = setDeinitFn,
    .setEventCallback = setEventCallback,
};

var gpa = std.heap.GeneralPurposeAllocator(.{ .retain_metadata = builtin.mode == .Debug }){};
var loop: xev.Loop = undefined;
var evdev: EvDev = undefined;
var key_bindings: std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)) = .{};
var window_manager: WindowManager = undefined;
var deinit_fn: ?seizer.Platform.DeinitFn = null;

pub fn main() anyerror!void {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    defer _ = gpa.deinit();

    loop = try xev.Loop.init(.{});
    defer loop.deinit();

    defer {
        var iter = key_bindings.valueIterator();
        while (iter.next()) |actions| {
            actions.deinit(gpa.allocator());
        }
        key_bindings.deinit(gpa.allocator());
    }

    evdev = try EvDev.init(gpa.allocator(), &loop, &key_bindings);
    defer evdev.deinit();
    try evdev.scanForDevices();

    window_manager = try WindowManager.init(.{
        .allocator = gpa.allocator(),
        .key_bindings = &key_bindings,
        .loop = &loop,
    });
    defer window_manager.deinit();

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
    while (!window_manager.shouldClose()) {
        try loop.run(.once);
        try window_manager.update();
    }
}

pub fn getAllocator() std.mem.Allocator {
    return gpa.allocator();
}

pub fn createGraphics(allocator: std.mem.Allocator, options: seizer.Platform.CreateGraphicsOptions) seizer.Platform.CreateGraphicsError!seizer.Graphics {
    // if (seizer.Graphics.impl.vulkan.create(allocator, options)) |graphics| {
    //     return graphics;
    // } else |err| {
    //     std.log.warn("Failed to create vulkan context: {}", .{err});
    // }

    if (seizer.Graphics.impl.gles3v0.create(allocator, options)) |graphics| {
        return graphics;
    } else |err| {
        std.log.warn("Failed to create gles3v0 context: {}", .{err});
    }

    return error.InitializationFailed;
}

pub fn createWindow(options: seizer.Platform.CreateWindowOptions) anyerror!seizer.Window {
    return window_manager.createWindow(options);
}

pub fn addButtonInput(options: seizer.Platform.AddButtonInputOptions) anyerror!void {
    for (options.default_bindings) |button_code| {
        const gop = try key_bindings.getOrPut(gpa.allocator(), button_code);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(gpa.allocator(), options);
    }
}

pub fn writeFile(options: seizer.Platform.WriteFileOptions) void {
    linuxbsd_fs.writeFile(gpa.allocator(), options);
}

pub fn readFile(options: seizer.Platform.ReadFileOptions) void {
    linuxbsd_fs.readFile(gpa.allocator(), options);
}

fn setEventCallback(new_on_event_callback: ?*const fn (event: seizer.input.Event) anyerror!void) void {
    window_manager.setEventCallback(new_on_event_callback);
}

fn setDeinitFn(new_deinit_fn: ?seizer.Platform.DeinitFn) void {
    deinit_fn = new_deinit_fn;
}

pub const EvDev = @import("./linuxbsd/evdev.zig");
pub const WindowManager = @import("./linuxbsd/window_manager.zig").WindowManager;

const linuxbsd_fs = @import("./linuxbsd/fs.zig");

const xev = @import("xev");
const seizer = @import("../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

egl: EGL,
display: EGL.Display,
event_devices: std.ArrayListUnmanaged(EventDevice),
event_device_pollfds: std.ArrayListUnmanaged(std.posix.pollfd),
button_inputs: std.SegmentedList(seizer.Context.AddButtonInputOptions, 16),
button_bindings: std.AutoHashMapUnmanaged(seizer.Context.AddButtonInputOptions.ButtonCode, std.ArrayListUnmanaged(*seizer.Context.AddButtonInputOptions)),

const Linux = @This();

pub const BACKEND = seizer.backend.Backend{
    .name = "linux",
    .main = main,
    .createWindow = createWindow,
    .addButtonInput = addButtonInput,
};

pub fn main() bool {
    const root = @import("root");

    if (!@hasDecl(root, "init")) {
        @compileError("root module must contain init function");
    }

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const this = gpa.allocator().create(@This()) catch return true;
    defer gpa.allocator().destroy(this);

    // init this
    {
        var library_prefixes = seizer.backend.getLibrarySearchPaths(gpa.allocator()) catch return true;
        defer library_prefixes.arena.deinit();

        this.egl = EGL.loadUsingPrefixes(library_prefixes.paths.items) catch |err| {
            std.log.warn("Failed to load EGL: {}", .{err});
            return true;
        };
    }
    defer {
        this.egl.deinit();
    }

    this.display = this.egl.getDisplay(null) orelse {
        std.log.warn("Failed to get EGL display", .{});
        return true;
    };
    _ = this.display.initialize() catch |err| {
        std.log.warn("Failed to initialize EGL display: {}", .{err});
        return true;
    };
    defer this.display.terminate();

    {
        this.event_devices = .{};
        // TODO: listen for input devices being plugged in or unplugged
        var input_device_dir = std.fs.cwd().openDir("/dev/input/", .{ .iterate = true }) catch |e| {
            std.log.warn("Failed to open /dev/input/: {}", .{e});
            return true;
        };
        var input_device_iter = input_device_dir.iterateAssumeFirstIteration();
        while (true) {
            const dev_opt = input_device_iter.next() catch |e| {
                std.log.warn("Failed to iterate directory: {}", .{e});
                continue;
            };
            const dev = dev_opt orelse break;

            if (dev.kind != .character_device) continue;
            if (!std.mem.startsWith(u8, dev.name, "event")) continue;

            const std_file = input_device_dir.openFile(dev.name, .{}) catch |e| {
                std.log.warn("Failed to open input device: {}", .{e});
                continue;
            };

            const fd = std_file.handle;
            var ev_bits: [(0x1f + 7) / 8]u8 = undefined;
            _ = std.os.linux.getErrno(std.os.linux.ioctl(fd, @bitCast(EV_IOC_GBIT(0, ev_bits.len)), @intFromPtr(&ev_bits)));

            const ev_abs_byte_index = 0;
            const ev_abs_bit_index = 3;
            if ((ev_bits[ev_abs_byte_index] >> ev_abs_bit_index) & 1 == 0) {
                std_file.close();
                continue;
            }

            var event_device = EventDevice{
                .fd = fd,
                .name = undefined,
                .id = undefined,
                .button_mapping = .{},
                .axis_mapping = .{},
            };
            _ = std.os.linux.getErrno(std.os.linux.ioctl(fd, @bitCast(EV_IOC_GID), @intFromPtr(&event_device.id)));

            const controller_name_len = std.os.linux.ioctl(fd, @bitCast(EV_IOC_GNAME(event_device.name.len)), @intFromPtr(&event_device.name));
            if (std.os.linux.getErrno(controller_name_len) != .SUCCESS) {
                std.log.warn("Failed to get controller name: {}", .{std.os.linux.getErrno(controller_name_len)});
                continue;
            }
            const controller_name = event_device.name[0..controller_name_len -| 1];

            std.log.debug("\"{}\" (/dev/input/{s}) is a joystick", .{ std.zig.fmtEscapes(controller_name), dev.name });

            // TODO: load mappings from sdl controller mapping files
            event_device.button_mapping.put(gpa.allocator(), 304, .btn_a) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 305, .btn_b) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 307, .btn_x) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 306, .btn_y) catch unreachable;

            event_device.button_mapping.put(gpa.allocator(), 314, .btn_tl) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 315, .btn_tr) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 308, .btn_tl2) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 309, .btn_tr2) catch unreachable;

            event_device.button_mapping.put(gpa.allocator(), 310, .btn_select) catch unreachable;
            event_device.button_mapping.put(gpa.allocator(), 311, .btn_start) catch unreachable;

            event_device.axis_mapping.put(gpa.allocator(), 2, .x) catch unreachable;
            event_device.axis_mapping.put(gpa.allocator(), 3, .y) catch unreachable;
            event_device.axis_mapping.put(gpa.allocator(), 4, .rx) catch unreachable;
            event_device.axis_mapping.put(gpa.allocator(), 5, .ry) catch unreachable;

            this.event_devices.append(gpa.allocator(), event_device) catch return false;
        }
        this.event_device_pollfds = .{};
        this.event_device_pollfds.ensureUnusedCapacity(gpa.allocator(), this.event_devices.items.len) catch return false;
        this.button_inputs = .{};
        this.button_bindings = .{};
    }

    var seizer_context = seizer.Context{
        .gpa = gpa.allocator(),
        .backend_userdata = this,
        .backend = &BACKEND,
    };
    defer seizer_context.deinit();

    // Call root module's `init()` function
    root.init(&seizer_context) catch |err| {
        std.debug.print("{s}\n", .{@errorName(err)});
        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        return false;
    };
    while (seizer_context.windows.items.len > 0) {
        this.updateEventDevices() catch |err| {
            std.debug.print("{s}", .{@errorName(err)});
            if (@errorReturnTrace()) |trace| {
                std.debug.dumpStackTrace(trace.*);
            }
            return false;
        };
        {
            var i: usize = seizer_context.windows.items.len;
            while (i > 0) : (i -= 1) {
                const window = seizer_context.windows.items[i - 1];
                const linux_window: *Window = @ptrCast(@alignCast(window.pointer.?));
                if (linux_window.should_close) {
                    _ = seizer_context.windows.swapRemove(i - 1);
                    window.destroy();
                }
            }
        }
        for (seizer_context.windows.items) |window| {
            gl.makeBindingCurrent(&window.gl_binding);
            window.on_render(window) catch |err| {
                std.debug.print("{s}", .{@errorName(err)});
                if (@errorReturnTrace()) |trace| {
                    std.debug.dumpStackTrace(trace.*);
                }
                return false;
            };
            window.swapBuffers();
        }
    }

    return false;
}

pub fn createWindow(context: *seizer.Context, options: seizer.Context.CreateWindowOptions) anyerror!*seizer.Window {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));

    var attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.surface_type),    EGL.WINDOW_BIT,
        @intFromEnum(EGL.Attrib.renderable_type), EGL.OPENGL_ES2_BIT,
        @intFromEnum(EGL.Attrib.red_size),        8,
        @intFromEnum(EGL.Attrib.blue_size),       8,
        @intFromEnum(EGL.Attrib.green_size),      8,
        @intFromEnum(EGL.Attrib.none),
    };
    const num_configs = try this.display.chooseConfig(&attrib_list, null);

    if (num_configs == 0) {
        return error.NoSuitableConfigs;
    }

    const configs_buffer = try context.gpa.alloc(*EGL.Config.Handle, @intCast(num_configs));
    defer context.gpa.free(configs_buffer);

    const configs_len = try this.display.chooseConfig(&attrib_list, configs_buffer);
    const configs = configs_buffer[0..configs_len];

    const surface = try this.display.createWindowSurface(configs[0], null, null);

    try this.egl.bindAPI(.opengl_es);
    var context_attrib_list = [_:@intFromEnum(EGL.Attrib.none)]EGL.Int{
        @intFromEnum(EGL.Attrib.context_major_version), 2,
        @intFromEnum(EGL.Attrib.context_minor_version), 0,
        @intFromEnum(EGL.Attrib.none),
    };
    const egl_context = try this.display.createContext(configs[0], null, &context_attrib_list);

    try this.display.makeCurrent(surface, surface, egl_context);

    const window = try context.gpa.create(seizer.Window);
    errdefer context.gpa.destroy(window);

    const linux_window = try context.gpa.create(Window);
    errdefer context.gpa.destroy(linux_window);

    linux_window.* = .{
        .display = this.display,
        .surface = surface,
        .egl_context = egl_context,
        .should_close = false,
    };

    window.* = .{
        .pointer = linux_window,
        .interface = &Window.INTERFACE,
        .gl_binding = undefined,
        .on_render = options.on_render,
        .on_destroy = options.on_destroy,
    };
    const loader = GlBindingLoader{ .egl = this.egl };
    window.gl_binding.init(loader);
    gl.makeBindingCurrent(&window.gl_binding);

    gl.viewport(0, 0, if (options.size) |s| @intCast(s[0]) else 640, if (options.size) |s| @intCast(s[1]) else 480);

    try context.windows.append(context.gpa, window);

    return window;
}

pub const GlBindingLoader = struct {
    egl: EGL,
    const AnyCFnPtr = *align(@alignOf(fn () callconv(.C) void)) const anyopaque;

    pub fn getCommandFnPtr(this: @This(), command_name: [:0]const u8) ?AnyCFnPtr {
        return this.egl.functions.eglGetProcAddress(command_name);
    }

    pub fn extensionSupported(this: @This(), extension_name: [:0]const u8) bool {
        _ = this;
        _ = extension_name;
        return true;
    }
};

const Window = struct {
    display: EGL.Display,
    surface: EGL.Surface,
    egl_context: EGL.Context,
    should_close: bool,

    pub const INTERFACE = seizer.Window.Interface{
        .destroy = destroy,
        .getSize = getSize,
        .getFramebufferSize = getSize,
        .swapBuffers = swapBuffers,
        .setShouldClose = setShouldClose,
    };

    pub fn destroy(userdata: ?*anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.display.destroySurface(this.surface);
    }

    pub fn getSize(userdata: ?*anyopaque) [2]f32 {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));

        const width = this.display.querySurface(this.surface, .width) catch unreachable;
        const height = this.display.querySurface(this.surface, .height) catch unreachable;

        return .{ @floatFromInt(width), @floatFromInt(height) };
    }

    pub fn swapBuffers(userdata: ?*anyopaque) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.display.swapBuffers(this.surface) catch |err| {
            std.log.warn("failed to swap buffers: {}", .{err});
        };
    }

    pub fn setShouldClose(userdata: ?*anyopaque, should_close: bool) void {
        const this: *@This() = @ptrCast(@alignCast(userdata.?));
        this.should_close = should_close;
    }
};

const EventDevice = struct {
    fd: std.posix.fd_t,
    name: [256]u8,
    id: InputId,
    button_mapping: std.AutoHashMapUnmanaged(u16, InputEvent.KeyCode),
    axis_mapping: std.AutoHashMapUnmanaged(u16, InputEvent.Axis),
};

// TODO: varies based on architecture. Though I think x86_64 and arm use the same generic layout.
const IOC = packed struct(u32) {
    nr: u8,
    type: u8,
    size: u13,
    none: bool,
    write: bool,
    read: bool,
};

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

pub const EV_IOC_GID = IOC{
    .type = 'E',
    .nr = 0x02,
    .size = @sizeOf(InputId),
    .none = false,
    .read = true,
    .write = false,
};

pub fn EV_IOC_GNAME(len: u13) IOC {
    return IOC{
        .type = 'E',
        .nr = 0x06,
        .size = len,
        .none = false,
        .read = true,
        .write = false,
    };
}

pub fn EV_IOC_GBIT(ev: u8, len: u13) IOC {
    return IOC{
        .type = 'E',
        .nr = 0x20 + ev,
        .size = len,
        .none = false,
        .write = false,
        .read = true,
    };
}

const InputEvent = extern struct {
    time: std.posix.timeval,
    type: EventType,
    code: u16,
    value: c_int,

    const EventType = enum(u16) {
        syn = 0x00,
        key = 0x01,
        abs = 0x03,
        _,
    };

    const KeyCode = enum(u16) {
        // gamepad buttons
        btn_a = 0x130,
        btn_b = 0x131,
        btn_c = 0x132,
        btn_x = 0x133,
        btn_y = 0x134,
        btn_z = 0x135,
        btn_tl = 0x136,
        btn_tr = 0x137,
        btn_tl2 = 0x138,
        btn_tr2 = 0x139,
        btn_select = 0x13a,
        btn_start = 0x13b,
        btn_mode = 0x13c,
        btn_thumbl = 0x13d,
        btn_thumbr = 0x13e,

        btn_dpad_up = 0x220,
        btn_dpad_down = 0x221,
        btn_dpad_left = 0x222,
        btn_dpad_right = 0x223,
        _,
    };

    const Axis = enum(u16) {
        x = 0x00,
        y = 0x01,
        z = 0x02,
        rx = 0x03,
        ry = 0x04,
        rz = 0x05,
        hat0x = 0x10,
        hat0y = 0x11,
        hat1x = 0x12,
        hat1y = 0x13,
        hat2x = 0x14,
        hat2y = 0x15,
        hat3x = 0x16,
        hat3y = 0x17,
    };
};

pub fn addButtonInput(context: *seizer.Context, options: seizer.Context.AddButtonInputOptions) anyerror!void {
    const this: *@This() = @ptrCast(@alignCast(context.backend_userdata.?));

    const button_input = try this.button_inputs.addOne(context.gpa);
    button_input.* = options;

    for (options.default_bindings) |button_code| {
        const gop = try this.button_bindings.getOrPut(context.gpa, button_code);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{};
        }
        try gop.value_ptr.append(context.gpa, button_input);
    }
}

pub fn updateEventDevices(this: *@This()) !void {
    if (this.event_device_pollfds.items.len < this.event_devices.items.len and
        this.event_device_pollfds.capacity < this.event_devices.items.len)
    {
        std.debug.panic("pollfds not large enough!", .{});
    }

    this.event_device_pollfds.items.len = this.event_devices.items.len;
    for (this.event_device_pollfds.items, this.event_devices.items) |*pollfd, dev| {
        pollfd.* = .{ .fd = dev.fd, .events = std.posix.POLL.IN, .revents = undefined };
    }
    while (try std.posix.poll(this.event_device_pollfds.items, 0) > 0) {
        for (this.event_device_pollfds.items, this.event_devices.items) |pollfd, dev| {
            if (pollfd.revents & std.posix.POLL.IN == std.posix.POLL.IN) {
                var input_event: InputEvent = undefined;
                const bytes_read = try std.os.read(pollfd.fd, std.mem.asBytes(&input_event));
                if (bytes_read != @sizeOf(InputEvent)) {
                    continue;
                }

                switch (input_event.type) {
                    .key => {
                        const button_code: seizer.Context.AddButtonInputOptions.ButtonCode = switch (dev.button_mapping.get(input_event.code) orelse @as(InputEvent.KeyCode, @enumFromInt(0))) {
                            .btn_a => .a,
                            .btn_b => .b,
                            .btn_x => .x,
                            .btn_y => .y,

                            .btn_dpad_up => .dpad_up,
                            .btn_dpad_down => .dpad_down,
                            .btn_dpad_left => .dpad_left,
                            .btn_dpad_right => .dpad_right,

                            .btn_tl => .l1,
                            .btn_tl2 => .l2,
                            .btn_tr => .r1,
                            .btn_tr2 => .r2,

                            .btn_start => .start,
                            .btn_select => .select,

                            else => continue,
                        };
                        if (this.button_bindings.get(button_code)) |actions| {
                            for (actions.items) |action| {
                                try action.on_event(input_event.value > 0);
                            }
                        }
                    },
                    .abs => switch (dev.axis_mapping.get(input_event.code) orelse @as(InputEvent.Axis, @enumFromInt(input_event.code))) {
                        .hat0x => {
                            const code: seizer.Context.AddButtonInputOptions.ButtonCode = if (input_event.value > 0) .dpad_right else .dpad_left;
                            const anti_code: seizer.Context.AddButtonInputOptions.ButtonCode = if (input_event.value > 0) .dpad_left else .dpad_right;

                            const value = input_event.value != 0;
                            const anti_value = input_event.value != 0 and !value;

                            if (this.button_bindings.get(code)) |actions| {
                                for (actions.items) |action| {
                                    try action.on_event(value);
                                }
                            }

                            if (this.button_bindings.get(anti_code)) |actions| {
                                for (actions.items) |action| {
                                    try action.on_event(anti_value);
                                }
                            }
                        },
                        .hat0y => {
                            const code: seizer.Context.AddButtonInputOptions.ButtonCode = if (input_event.value > 0) .dpad_down else .dpad_up;
                            const anti_code: seizer.Context.AddButtonInputOptions.ButtonCode = if (input_event.value > 0) .dpad_up else .dpad_down;

                            const value = input_event.value != 0;
                            const anti_value = input_event.value != 0 and !value;

                            if (this.button_bindings.get(code)) |actions| {
                                for (actions.items) |action| {
                                    try action.on_event(value);
                                }
                            }

                            if (this.button_bindings.get(anti_code)) |actions| {
                                for (actions.items) |action| {
                                    try action.on_event(anti_value);
                                }
                            }
                        },
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }
}

const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../seizer.zig");
const std = @import("std");

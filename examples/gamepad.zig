pub const main = seizer.main;

var canvas: seizer.Canvas = undefined;
var dev_js0: std.posix.fd_t = undefined;
var gamepad: Gamepad = .{};

const Gamepad = struct {
    dpad: [2]f32 = .{ 0, 0 },
    left_joystick: [2]f32 = .{ 0, 0 },
    right_joystick: [2]f32 = .{ 0, 0 },

    north: bool = false,
    east: bool = false,
    south: bool = false,
    west: bool = false,

    left_bumper: bool = false,
    left_trigger: bool = false,
    right_bumper: bool = false,
    right_trigger: bool = false,

    start: bool = false,
    select: bool = false,
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
        btn_south = 0x130,
        btn_east = 0x131,
        btn_c = 0x132,
        btn_north = 0x133,
        btn_west = 0x134,
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

var controller_name_buffer: [256]u8 = undefined;
var controller_id: InputId = undefined;
var controller_button_mapping: std.AutoHashMapUnmanaged(u16, InputEvent.KeyCode) = .{};
var controller_axis_mapping: std.AutoHashMapUnmanaged(u16, InputEvent.Axis) = .{};

pub fn init(context: *seizer.Context) !void {
    _ = try context.createWindow(.{
        .title = "Gamepad - Seizer Example",
        .on_render = render,
        .on_destroy = deinit,
    });

    canvas = try seizer.Canvas.init(context.gpa, .{});
    errdefer canvas.deinit();

    dev_js0 = try std.posix.open("/dev/input/event1", .{ .ACCMODE = .RDONLY }, 0);

    _ = std.os.linux.getErrno(std.os.linux.ioctl(dev_js0, @bitCast(EV_IOC_GID), @intFromPtr(&controller_id)));
    _ = std.os.linux.getErrno(std.os.linux.ioctl(dev_js0, @bitCast(EV_IOC_GNAME(controller_name_buffer.len)), @intFromPtr(&controller_name_buffer)));

    try controller_button_mapping.put(context.gpa, 307, .btn_north);
    try controller_button_mapping.put(context.gpa, 304, .btn_east);
    try controller_button_mapping.put(context.gpa, 305, .btn_south);
    try controller_button_mapping.put(context.gpa, 306, .btn_west);

    try controller_button_mapping.put(context.gpa, 314, .btn_tl);
    try controller_button_mapping.put(context.gpa, 315, .btn_tr);
    try controller_button_mapping.put(context.gpa, 308, .btn_tl2);
    try controller_button_mapping.put(context.gpa, 309, .btn_tr2);

    try controller_button_mapping.put(context.gpa, 310, .btn_start);
    try controller_button_mapping.put(context.gpa, 311, .btn_select);

    try controller_axis_mapping.put(context.gpa, 2, .x);
    try controller_axis_mapping.put(context.gpa, 3, .y);
    try controller_axis_mapping.put(context.gpa, 4, .rx);
    try controller_axis_mapping.put(context.gpa, 5, .ry);
}

pub fn deinit(window: *seizer.Window) void {
    _ = window;
    std.posix.close(dev_js0);
    canvas.deinit();
}

fn render(window: *seizer.Window) !void {
    var pollfds = [_]std.posix.pollfd{
        .{ .fd = dev_js0, .events = std.posix.POLL.IN, .revents = std.posix.POLL.IN },
    };
    while (try std.posix.poll(&pollfds, 0) > 0) {
        for (pollfds) |pollfd| {
            if (pollfd.revents & std.posix.POLL.IN == std.posix.POLL.IN) {
                var input_event: InputEvent = undefined;
                const bytes_read = try std.os.read(pollfd.fd, std.mem.asBytes(&input_event));
                if (bytes_read != @sizeOf(InputEvent)) {
                    continue;
                }

                switch (input_event.type) {
                    .key => switch (controller_button_mapping.get(input_event.code) orelse @as(InputEvent.KeyCode, @enumFromInt(0))) {
                        .btn_north => gamepad.north = input_event.value > 0,
                        .btn_east => gamepad.east = input_event.value > 0,
                        .btn_south => gamepad.south = input_event.value > 0,
                        .btn_west => gamepad.west = input_event.value > 0,

                        // .btn_dpad_up => gamepad.dpad.up = input_event.value > 0,
                        // .btn_dpad_down => gamepad.dpad.down = input_event.value > 0,
                        // .btn_dpad_left => gamepad.dpad.left = input_event.value > 0,
                        // .btn_dpad_right => gamepad.dpad.right = input_event.value > 0,

                        .btn_tl => gamepad.left_bumper = input_event.value > 0,
                        .btn_tl2 => gamepad.left_trigger = input_event.value > 0,
                        .btn_tr => gamepad.right_bumper = input_event.value > 0,
                        .btn_tr2 => gamepad.right_trigger = input_event.value > 0,

                        .btn_start => gamepad.start = input_event.value > 0,
                        .btn_select => gamepad.select = input_event.value > 0,

                        else => {},
                    },
                    .abs => switch (controller_axis_mapping.get(input_event.code) orelse @as(InputEvent.Axis, @enumFromInt(input_event.code))) {
                        .x => gamepad.left_joystick[0] = @as(f32, @floatFromInt(input_event.value)) / 4096,
                        .y => gamepad.left_joystick[1] = @as(f32, @floatFromInt(input_event.value)) / 4096,
                        .rx => gamepad.right_joystick[0] = @as(f32, @floatFromInt(input_event.value)) / 4096,
                        .ry => gamepad.right_joystick[1] = @as(f32, @floatFromInt(input_event.value)) / 4096,
                        .hat0x => gamepad.dpad[0] = @as(f32, @floatFromInt(input_event.value)),
                        .hat0y => gamepad.dpad[1] = @as(f32, @floatFromInt(input_event.value)),
                        else => {},
                    },
                    else => {},
                }
            }
        }
    }

    gl.clearColor(0.7, 0.5, 0.5, 1.0);
    gl.clear(gl.COLOR_BUFFER_BIT);

    canvas.begin(.{
        .window_size = window.getSize(),
        .framebuffer_size = window.getFramebufferSize(),
    });
    var text_writer = canvas.textWriter(.{});
    const console = text_writer.writer();

    try console.print("Controller Info\n", .{});
    try console.print("guid = {}0000{}0000{}0000{}0000\n\n", .{
        std.fmt.fmtSliceHexLower(std.mem.asBytes(&controller_id.bustype)),
        std.fmt.fmtSliceHexLower(std.mem.asBytes(&controller_id.vendor)),
        std.fmt.fmtSliceHexLower(std.mem.asBytes(&controller_id.product)),
        std.fmt.fmtSliceHexLower(std.mem.asBytes(&controller_id.version)),
    });
    try console.print("name = {?s}\n\n", .{controller_name_buffer});

    try console.print("Left Joystick\n", .{});
    try console.print("x = {d:0.3}\n", .{gamepad.left_joystick[0]});
    try console.print("y = {d:0.3}\n", .{gamepad.left_joystick[1]});
    try console.print("\n", .{});

    try console.print("Right Joystick\n", .{});
    try console.print("x = {d:0.3}\n", .{gamepad.right_joystick[0]});
    try console.print("y = {d:0.3}\n", .{gamepad.right_joystick[1]});
    try console.print("\n", .{});

    try console.print("DPad\n", .{});
    try console.print("x = {d:0.3}\n", .{gamepad.dpad[0]});
    try console.print("y = {d:0.3}\n", .{gamepad.dpad[1]});
    try console.print("\n", .{});

    try console.print("Buttons\n", .{});
    try console.print("north = {}\n", .{gamepad.north});
    try console.print(" east = {}\n", .{gamepad.east});
    try console.print("south = {}\n", .{gamepad.south});
    try console.print(" west = {}\n", .{gamepad.west});
    try console.print("start = {}\n", .{gamepad.start});
    try console.print("select = {}\n", .{gamepad.select});
    try console.print("left bumper = {}\n", .{gamepad.left_bumper});
    try console.print("left trigger = {}\n", .{gamepad.left_trigger});
    try console.print("right bumper = {}\n", .{gamepad.right_bumper});
    try console.print("right trigger = {}\n", .{gamepad.right_trigger});

    canvas.end();
}

const seizer = @import("seizer");
const gl = seizer.gl;
const std = @import("std");

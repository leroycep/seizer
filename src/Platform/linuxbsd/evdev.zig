gpa: std.mem.Allocator,
devices: std.ArrayListUnmanaged(Device),
pollfds: std.ArrayListUnmanaged(std.posix.pollfd),
mapping_db: seizer.Gamepad.DB,
input_device_dir: std.fs.Dir,
button_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions)),

const EvDev = @This();

pub fn init(gpa: std.mem.Allocator, button_bindings: *const std.AutoHashMapUnmanaged(seizer.Platform.Binding, std.ArrayListUnmanaged(seizer.Platform.AddButtonInputOptions))) !EvDev {
    var mapping_db = try seizer.Gamepad.DB.init(gpa, .{});
    errdefer mapping_db.deinit();

    var input_device_dir = try std.fs.cwd().openDir("/dev/input/", .{ .iterate = true });
    errdefer input_device_dir.close();

    return EvDev{
        .gpa = gpa,
        .devices = .{},
        .pollfds = .{},
        .mapping_db = mapping_db,
        .input_device_dir = input_device_dir,
        .button_bindings = button_bindings,
    };
}

pub fn deinit(this: *@This()) void {
    for (this.devices.items) |*dev| {
        std.posix.close(dev.fd);
        dev.button_code_to_index.deinit(this.gpa);
        dev.abs_to_index.deinit(this.gpa);
    }
    this.devices.deinit(this.gpa);
    this.pollfds.deinit(this.gpa);

    this.mapping_db.deinit();
}

// TODO: replace with some kind of listener similar to inotify
/// Note: This will open devices multiple times.
pub fn scanForDevices(this: *@This()) !void {
    var input_device_iter = this.input_device_dir.iterate();
    while (try input_device_iter.next()) |dev| {
        if (dev.kind != .character_device) continue;
        if (!std.mem.startsWith(u8, dev.name, "event")) continue;

        const std_file = try this.input_device_dir.openFile(dev.name, .{});

        const device = Device.fromFile(this.gpa, std_file, &this.mapping_db) catch {
            std_file.close();
            continue;
        };

        try this.pollfds.ensureTotalCapacity(this.gpa, this.devices.items.len + 1);
        try this.devices.append(this.gpa, device);
    }
    std.log.debug("Found {} evdev input devices", .{this.devices.items.len});
}

const Device = struct {
    fd: std.posix.fd_t,
    name: Name,
    id: InputId,
    mapping: ?seizer.Gamepad.Mapping,
    button_code_to_index: std.AutoHashMapUnmanaged(u16, u16),
    abs_to_index: std.AutoHashMapUnmanaged(u16, AbsIndex),
    axis_count: u16,
    hat_count: u16,

    const Name = [256]u8;

    const AbsIndex = union(enum) {
        axis: u16,
        hat: struct { bool, u15 },
    };

    fn nameSlice(this: *const @This()) []const u8 {
        if (std.mem.indexOfScalar(u8, &this.name, 0)) |zero_index| {
            return this.name[0..zero_index];
        } else {
            return this.name[0..];
        }
    }

    pub fn fromFile(gpa: std.mem.Allocator, file: std.fs.File, mapping_db: *const seizer.Gamepad.DB) !Device {
        const fd = file.handle;
        var ev_bits = EV.Bits.initEmpty();
        _ = std.os.linux.ioctl(fd, IOCTL.GET_EV_BITS(0, @sizeOf(EV.Bits)), @intFromPtr(&ev_bits));

        if (!ev_bits.isSet(@intFromEnum(EV.ABS))) {
            return error.NotAGamepad;
        }

        var device = Device{
            .fd = fd,
            .name = undefined,
            .id = undefined,
            .mapping = null,
            .button_code_to_index = .{},
            .abs_to_index = .{},
            .hat_count = 0,
            .axis_count = 0,
        };
        _ = std.os.linux.ioctl(fd, IOCTL.GET_ID, @intFromPtr(&device.id));
        _ = std.os.linux.ioctl(fd, IOCTL.GET_NAME(@sizeOf(Device.Name)), @intFromPtr(&device.name));

        var key_bits = KEY.Bits.initEmpty();
        _ = std.os.linux.ioctl(fd, IOCTL.GET_EV_BITS(0x01, @sizeOf(KEY.Bits)), @intFromPtr(&key_bits.masks));
        for (1..KEY.MAX) |code| {
            if (key_bits.isSet(code)) {
                const button_index = device.button_code_to_index.count();
                try device.button_code_to_index.putNoClobber(gpa, @intCast(code), @intCast(button_index));
            }
        }

        var abs_bits = ABS.Bits.initEmpty();
        _ = std.os.linux.ioctl(fd, IOCTL.GET_EV_BITS(0x03, @sizeOf(ABS.Bits)), @intFromPtr(&abs_bits.masks));
        var prev_was_hat = false;
        for (1..ABS.MAX) |axis| {
            if (abs_bits.isSet(axis)) {
                var abs_info: ABS.Info = undefined;
                _ = std.os.linux.ioctl(fd, IOCTL.GET_ABS_INFO(@intCast(axis)), @intFromPtr(&abs_info));

                if (abs_info.minimum == -1 and abs_info.maximum == 1 or abs_info.minimum == 1 and abs_info.maximum == -1) {
                    if (prev_was_hat) {
                        const hat_index = device.hat_count - 1;
                        try device.abs_to_index.putNoClobber(gpa, @intCast(axis), .{ .hat = .{ prev_was_hat, @intCast(hat_index) } });
                        prev_was_hat = false;
                        continue;
                    }
                    // assume digital hat
                    const hat_index = device.hat_count;
                    try device.abs_to_index.putNoClobber(gpa, @intCast(axis), .{ .hat = .{ prev_was_hat, @intCast(hat_index) } });
                    device.hat_count += 1;
                    prev_was_hat = true;
                } else {
                    // assume digital hat
                    const axis_index = device.axis_count;
                    try device.abs_to_index.putNoClobber(gpa, @intCast(axis), .{ .axis = @intCast(axis_index) });
                    device.axis_count += 1;
                }
            }
        }

        const name_crc = crc16(0, device.nameSlice());

        {
            var guid: u128 = 0;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u16, device.id.bustype) else @byteSwap(@as(u16, device.id.bustype));
            guid <<= 16;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u16, name_crc) else @byteSwap(@as(u16, name_crc));
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.vendor) else @byteSwap(@as(u32, device.id.vendor));
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.product) else @byteSwap(@as(u32, device.id.product));
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.version) else @byteSwap(@as(u32, device.id.version));

            device.mapping = mapping_db.mappings.get(guid);
        }

        // Try the guid again; this time without the crc. Seems like it isn't populated on batocera on the RG35XXH?
        // Wish this had a spec instead of just code.
        if (device.mapping == null) {
            var guid: u128 = 0;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u16, device.id.bustype) else @byteSwap(@as(u16, device.id.bustype));
            guid <<= 16;
            // skip the name_crc
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.vendor) else @byteSwap(@as(u32, device.id.vendor));
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.product) else @byteSwap(@as(u32, device.id.product));
            guid <<= 32;
            guid |= if (builtin.cpu.arch.endian() == .big) @as(u32, device.id.version) else @byteSwap(@as(u32, device.id.version));

            device.mapping = mapping_db.mappings.get(guid);
        }

        return device;
    }
};

fn crc16(crc_initial: u16, data: []const u8) u16 {
    var crc: u16 = crc_initial;
    for (data) |b| {
        crc = crc16_for_byte(@truncate(crc ^ b)) ^ crc >> 8;
    }
    return crc;
}
fn crc16_for_byte(byte: u8) u16 {
    var b: u16 = byte;
    var crc: u16 = 0;
    for (0..8) |_| {
        const n: u16 = if ((crc ^ b) & 1 != 0) 0xA001 else 0;
        crc = n ^ crc >> 1;
        b >>= 1;
    }
    return crc;
}

test crc16 {
    try std.testing.expectEqual(@as(u16, 0x5827), crc16(0, "OpenSimHardware OSH PB Controller"));
}

pub const IOCTL = struct {
    pub const GET_ID = std.os.linux.IOCTL.IOR('E', 0x02, InputId);

    pub fn GET_NAME(comptime len: u13) u32 {
        return @bitCast(std.os.linux.IOCTL.IOR('E', 0x06, [len]u8));
    }

    pub fn GET_EV_BITS(ev: u8, comptime len: u13) u32 {
        return @bitCast(std.os.linux.IOCTL.IOR('E', 0x20 + ev, [len]u8));
    }

    pub fn GET_ABS_INFO(axis: u8) u32 {
        return @bitCast(std.os.linux.IOCTL.IOR('E', 0x40 + axis, ABS.Info));
    }
};

const InputId = extern struct {
    bustype: u16,
    vendor: u16,
    product: u16,
    version: u16,
};

pub const EV = enum(u8) {
    SYN = 0x00,
    KEY = 0x01,
    REL = 0x02,
    ABS = 0x03,
    MSC = 0x04,
    SW = 0x05,
    LED = 0x11,
    SND = 0x12,
    REP = 0x14,
    FF = 0x15,
    PWR = 0x16,
    FF_STATUS = 0x17,
    _,

    pub const MAX = 0x1f;
    pub const COUNT = (MAX + 1);
    pub const Bits = std.bit_set.ArrayBitSet(u8, COUNT);
};

pub const KEY = enum(u16) {
    esc = 1,
    @"1" = 2,
    @"2" = 3,
    @"3" = 4,
    @"4" = 5,
    @"5" = 6,
    @"6" = 7,
    @"7" = 8,
    @"8" = 9,
    @"9" = 10,
    @"0" = 11,

    minus = 12,
    equal = 13,
    backspace = 14,
    tab = 15,
    q = 16,
    w = 17,
    e = 18,
    r = 19,
    t = 20,
    y = 21,
    u = 22,
    i = 23,
    o = 24,
    p = 25,
    leftbrace = 26,
    rightbrace = 27,
    enter = 28,
    leftctrl = 29,
    a = 30,
    s = 31,
    d = 32,
    f = 33,
    g = 34,
    h = 35,
    j = 36,
    k = 37,
    l = 38,
    semicolon = 39,
    apostrophe = 40,
    grave = 41,
    leftshift = 42,
    backslash = 43,
    z = 44,
    x = 45,
    c = 46,
    v = 47,
    b = 48,
    n = 49,
    m = 50,
    comma = 51,
    dot = 52,
    slash = 53,
    rightshift = 54,
    kpasterisk = 55,
    leftalt = 56,
    space = 57,
    capslock = 58,
    f1 = 59,
    f2 = 60,
    f3 = 61,
    f4 = 62,
    f5 = 63,
    f6 = 64,
    f7 = 65,
    f8 = 66,
    f9 = 67,
    f10 = 68,
    numlock = 69,
    scrolllock = 70,
    kp7 = 71,
    kp8 = 72,
    kp9 = 73,
    kpminus = 74,
    kp4 = 75,
    kp5 = 76,
    kp6 = 77,
    kpplus = 78,
    kp1 = 79,
    kp2 = 80,
    kp3 = 81,
    kp0 = 82,
    kpdot = 83,

    up = 103,
    left = 105,
    right = 106,
    down = 108,

    // misc buttons
    btn_0 = 0x100,

    // joystick buttons
    btn_trigger = 0x120,

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

    pub const MAX = 0x2ff;
    pub const COUNT = (MAX + 1);
    pub const Bits = std.bit_set.ArrayBitSet(u8, COUNT);
};

const ABS = enum(u16) {
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
    _,

    const MAX = 0x3f;
    const Bits = std.bit_set.ArrayBitSet(u8, MAX);

    pub const Info = extern struct {
        value: i32,
        minimum: i32,
        maximum: i32,
        fuzz: i32,
        flat: i32,
        resolution: i32,
    };
};

const InputEvent = extern struct {
    time: std.posix.timeval,
    type: EV,
    code: u16,
    value: c_int,
};

pub fn updateEventDevices(this: *EvDev) !void {
    if (this.devices.items.len == 0) return;
    if (this.pollfds.items.len < this.devices.items.len and
        this.pollfds.capacity < this.devices.items.len)
    {
        std.debug.panic("pollfds not large enough!", .{});
    }

    this.pollfds.items.len = this.devices.items.len;
    for (this.pollfds.items, this.devices.items) |*pollfd, dev| {
        pollfd.* = .{ .fd = dev.fd, .events = std.posix.POLL.IN, .revents = undefined };
    }
    while (try std.posix.poll(this.pollfds.items, 0) > 0) {
        for (this.pollfds.items, this.devices.items) |pollfd, dev| {
            if (pollfd.revents & std.posix.POLL.IN == std.posix.POLL.IN) {
                var input_event: InputEvent = undefined;
                const bytes_read = try std.posix.read(pollfd.fd, std.mem.asBytes(&input_event));
                if (bytes_read != @sizeOf(InputEvent)) {
                    continue;
                }

                if (dev.mapping) |mapping| {
                    switch (input_event.type) {
                        .KEY => if (dev.button_code_to_index.get(input_event.code)) |btn_index| do_output: {
                            const output = mapping.buttons[btn_index] orelse break :do_output;
                            switch (output) {
                                .button => |gamepad_btn_code| if (this.button_bindings.get(.{ .gamepad = gamepad_btn_code })) |actions| {
                                    for (actions.items) |action| {
                                        try action.on_event(input_event.value > 0);
                                    }
                                },
                                .axis => {
                                    // TODO: implement
                                },
                            }
                        },
                        .ABS => if (dev.abs_to_index.get(input_event.code)) |abs_index| {
                            switch (abs_index) {
                                .axis => {
                                    // TODO: implement
                                },
                                .hat => |hat_isy_and_index| if (hat_isy_and_index[1] < mapping.hats.len) {
                                    const is_y = hat_isy_and_index[0];
                                    const hat_index = hat_isy_and_index[1];

                                    const hat_subindex: u2 =
                                        if (is_y and input_event.value <= 0)
                                        0
                                    else if (!is_y and input_event.value > 0)
                                        1
                                    else if (is_y and input_event.value > 0)
                                        2
                                    else if (!is_y and input_event.value <= 0)
                                        3
                                    else blk: {
                                        std.log.warn("this shouldn't be called ever", .{});
                                        break :blk 0;
                                    };
                                    const hat_anti_index: u2 = hat_subindex +% 2;

                                    const output = mapping.hats[hat_index][hat_subindex] orelse continue;
                                    switch (output) {
                                        .button => |gamepad_btn_code| if (this.button_bindings.get(.{ .gamepad = gamepad_btn_code })) |actions| {
                                            for (actions.items) |action| {
                                                try action.on_event(input_event.value != 0);
                                            }
                                        },
                                        .axis => {
                                            // TODO: implement
                                        },
                                    }

                                    const anti_output = mapping.hats[hat_index][hat_anti_index] orelse continue;
                                    switch (anti_output) {
                                        .button => |gamepad_btn_code| if (this.button_bindings.get(.{ .gamepad = gamepad_btn_code })) |actions| {
                                            for (actions.items) |action| {
                                                try action.on_event(false);
                                            }
                                        },
                                        .axis => {
                                            // TODO: implement
                                        },
                                    }
                                },
                            }
                        },
                        else => break,
                    }
                }
            }
        }
    }
}

const log = std.log.scoped(.seizer);

const gl = seizer.gl;
const EGL = @import("EGL");
const seizer = @import("../../seizer.zig");
const builtin = @import("builtin");
const std = @import("std");

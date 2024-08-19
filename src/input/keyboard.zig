/// Based on the linux evdev values
pub const Key = enum(u16) {
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

    rightctrl = 97,
    rightalt = 100,

    up = 103,
    left = 105,
    right = 106,
    down = 108,

    leftmeta = 125,

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

pub const ScanCode = u32;

pub const Action = enum {
    press,
    repeat,
    release,
};

pub const Modifiers = packed struct {
    shift: bool = false,
    control: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
};

const std = @import("std");

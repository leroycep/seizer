/// Values taken from the linux/input-event-codes.h
pub const Button = enum(u16) {
    left = 0x110,
    right = 0x111,
    middle = 0x112,
    side = 0x113,
    extra = 0x114,
    forward = 0x115,
    back = 0x116,
    task = 0x117,
};

pub const Modifiers = packed struct {
    left: bool,
    right: bool,
    middle: bool,
};

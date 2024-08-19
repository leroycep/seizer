pub const Button = enum {
    left,
    right,
    middle,
};

pub const Modifiers = packed struct {
    left: bool,
    right: bool,
    middle: bool,
};

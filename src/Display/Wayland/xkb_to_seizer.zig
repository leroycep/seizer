pub fn xkbSymbolToSeizerKey(symbol: xkb.Symbol) Key {
    if (symbol.character) |unicode_character| {
        return .{ .unicode = unicode_character };
    }
    return switch (symbol.code) {
        xkb.Symbol.NoSymbol.code,
        xkb.Symbol.VoidSymbol.code,
        => .unidentified,

        xkb.Symbol.Escape.code => .escape,
        xkb.Symbol.BackSpace.code => .backspace,

        xkb.Symbol.Control_L.code,
        xkb.Symbol.Control_R.code,
        => .control,

        xkb.Symbol.Shift_L.code,
        xkb.Symbol.Shift_R.code,
        => .shift,

        xkb.Symbol.Alt_L.code,
        xkb.Symbol.Alt_R.code,
        => .alt,

        xkb.Symbol.Meta_L.code,
        xkb.Symbol.Meta_R.code,
        xkb.Symbol.Super_L.code,
        xkb.Symbol.Super_R.code,
        => .meta,

        xkb.Symbol.Caps_Lock.code => .caps_lock,

        xkb.Symbol.F1.code => .f1,
        xkb.Symbol.F2.code => .f2,
        xkb.Symbol.F3.code => .f3,
        xkb.Symbol.F4.code => .f4,
        xkb.Symbol.F5.code => .f5,
        xkb.Symbol.F6.code => .f6,
        xkb.Symbol.F7.code => .f7,
        xkb.Symbol.F8.code => .f8,
        xkb.Symbol.F9.code => .f9,
        xkb.Symbol.F10.code => .f10,
        xkb.Symbol.F11.code => .f11,
        xkb.Symbol.F12.code => .f12,
        xkb.Symbol.F13.code => .f13,
        xkb.Symbol.F14.code => .f14,
        xkb.Symbol.F15.code => .f15,
        xkb.Symbol.F16.code => .f16,
        xkb.Symbol.F17.code => .f17,
        xkb.Symbol.F18.code => .f18,
        xkb.Symbol.F19.code => .f19,
        xkb.Symbol.F20.code => .f20,

        xkb.Symbol.Num_Lock.code => .num_lock,
        xkb.Symbol.Scroll_Lock.code => .scroll_lock,

        xkb.Symbol.Up.code => .arrow_up,
        xkb.Symbol.Left.code => .arrow_left,
        xkb.Symbol.Right.code => .arrow_right,
        xkb.Symbol.Down.code => .arrow_down,
        xkb.Symbol.Home.code => .home,
        xkb.Symbol.End.code => .end,
        xkb.Symbol.Prior.code => .page_up,
        xkb.Symbol.Next.code => .page_down,

        xkb.Symbol.Insert.code => .insert,

        else => |k| std.debug.panic("Unknown xkb Symbol code 0x{x}", .{k}),
    };
}

const Key = @import("../../seizer.zig").input.keyboard.Key;
const xkb = @import("xkb");
const std = @import("std");

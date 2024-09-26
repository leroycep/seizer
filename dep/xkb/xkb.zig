pub const AST = @import("./AST.zig");
pub const Parser = @import("./Parser.zig");
pub const Token = @import("./Token.zig");

pub const symbols = @import("./symbols.zig");

pub const Symbol = symbols.Symbol;

pub const Keymap = struct {
    keys: std.AutoHashMapUnmanaged(u32, Key),

    pub const Layout = struct {};

    pub const Key = struct {
        modifiers_filters: ModMask,
        modifer_map: std.AutoHashMapUnmanaged(ModMask, LevelIndex),
        levels: []const Level,

        pub const LevelIndex = enum(u8) { _ };
    };

    pub const Level = struct {
        symbols: []const Symbol,
    };

    pub const ModMask = u32;
    pub const State = struct {
        base_modifiers: ModMask,
        latched_modifiers: ModMask,
        locked_modifiers: ModMask,
        group: u32,
    };

    pub fn getSymbol(this: @This(), state: State, evdev_keycode: u32) ?Symbol {
        _ = this;
        _ = state;
        _ = evdev_keycode;
        return undefined;
    }

    pub fn getUnicode(this: @This(), state: State, evdev_keycode: u32) ?u21 {
        _ = this;
        _ = state;
        _ = evdev_keycode;
        return undefined;
    }
};

pub const Modifiers = packed struct(u32) {
    shift: bool = false,
    lock: bool = false,
    control: bool = false,
    mod1: bool = false,
    mod2: bool = false,
    mod3: bool = false,
    mod4: bool = false,
    mod5: bool = false,
    virtual: u24 = 0,

    pub fn eql(a: @This(), b: @This()) bool {
        const a_u32: u32 = @bitCast(a);
        const b_u32: u32 = @bitCast(b);
        return a_u32 == b_u32;
    }

    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0) {
            try writer.writeAll("xkb.Modifiers{ ");
            if (this.shift) try writer.writeAll("shift ");
            if (this.lock) try writer.writeAll("lock ");
            if (this.control) try writer.writeAll("control ");
            if (this.mod1) try writer.writeAll("mod1 ");
            if (this.mod2) try writer.writeAll("mod2 ");
            if (this.mod3) try writer.writeAll("mod3 ");
            if (this.mod4) try writer.writeAll("mod4 ");
            if (this.mod5) try writer.writeAll("mod5 ");
            if (this.virtual != 0) {
                try writer.print("virtual({b}) ", .{this.virtual});
            }
            try writer.writeAll("}");
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }
};

test {
    _ = AST;
    _ = Parser;
    _ = Token;
}

const std = @import("std");

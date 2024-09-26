allocator: std.mem.Allocator,
source: []const u8,
tokens: std.MultiArrayList(xkb.Token).Slice,
keymap: Keymap,

pub fn deinit(this: *@This()) void {
    this.keymap.deinit(this.allocator);
    this.tokens.deinit(this.allocator);
}

pub fn tokenString(this: @This(), token_index: TokenIndex) []const u8 {
    const source_index = this.tokens.items(.source_index)[@intFromEnum(token_index)];
    return xkb.Token.string(this.source, source_index) catch unreachable;
}

pub const SourceIndex = xkb.Token.SourceIndex;
pub const TokenIndex = enum(u32) { _ };
pub const Scancode = enum(u32) { _ };

pub const Keymap = struct {
    keycodes: ?Keycodes,
    types: ?Types,
    compatibility: ?Compatibility,
    symbols: ?Symbols,

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        if (this.keycodes) |*keycodes| keycodes.deinit(allocator);
        if (this.types) |*types| types.deinit(allocator);
        if (this.compatibility) |*compatibility| compatibility.deinit(allocator);
        if (this.symbols) |*syms| syms.deinit(allocator);
    }
};

pub const Keycodes = struct {
    name: TokenIndex,
    keycodes: []const Keycode = &.{},
    aliases: []const Alias = &.{},

    pub const Keycode = struct {
        keyname: TokenIndex,
        scancode: Scancode,
    };

    pub const Alias = struct {
        alias_keyname: TokenIndex,
        base_keyname: TokenIndex,
    };

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(this.keycodes);
        allocator.free(this.aliases);
    }
};

pub const Types = struct {
    name: TokenIndex,
    types: []const Type = &.{},

    pub const Type = struct {
        name: TokenIndex,
        modifiers: Modifiers = .{},
        modifier_mappings: []const ModifierMapping = &.{},
        level_names: []const TokenIndex = &.{},

        pub const ModifierMapping = struct {
            modifiers: Modifiers,
            level_index: u32,
        };

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            allocator.free(this.modifier_mappings);
            allocator.free(this.level_names);
        }
    };

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        for (this.types) |*t| {
            @constCast(t).deinit(allocator);
        }
        allocator.free(this.types);
    }
};

pub const Compatibility = struct {
    name: TokenIndex,

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        _ = this;
        _ = allocator;
    }
};

pub const Symbols = struct {
    name: TokenIndex,

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        _ = this;
        _ = allocator;
    }
};

pub const Modifiers = struct {
    real: Real = .{},
    virtual: u24 = 0,

    pub const Real = packed struct(u8) {
        shift: bool = false,
        lock: bool = false,
        control: bool = false,
        mod1: bool = false,
        mod2: bool = false,
        mod3: bool = false,
        mod4: bool = false,
        mod5: bool = false,

        pub fn format(
            this: @This(),
            comptime fmt: []const u8,
            options: std.fmt.FormatOptions,
            writer: anytype,
        ) !void {
            _ = options;
            if (fmt.len == 0) {
                if (this.shift) try writer.writeAll("shift ");
                if (this.lock) try writer.writeAll("lock ");
                if (this.control) try writer.writeAll("control ");
                if (this.mod1) try writer.writeAll("mod1 ");
                if (this.mod2) try writer.writeAll("mod2 ");
                if (this.mod3) try writer.writeAll("mod3 ");
                if (this.mod4) try writer.writeAll("mod4 ");
                if (this.mod5) try writer.writeAll("mod5 ");
            } else {
                @compileError("unknown format character: '" ++ fmt ++ "'");
            }
        }
    };

    pub fn eql(a: @This(), b: @This()) bool {
        const a_real_u8: u8 = @bitCast(a.real);
        const b_real_u8: u8 = @bitCast(b.real);
        return a_real_u8 == b_real_u8 and a.virtual == b.virtual;
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
            try this.real.format("", .{}, writer);
            if (this.virtual != 0) {
                try writer.print("virtual({b}) ", .{this.virtual});
            }
            try writer.writeAll("}");
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }
};

const xkb = @import("./xkb.zig");
const std = @import("std");

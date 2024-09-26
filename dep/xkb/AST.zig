allocator: std.mem.Allocator,
source: []const u8,
tokens: std.MultiArrayList(xkb.Token).Slice,
keymap: Keymap,

pub fn deinit(this: *@This()) void {
    this.keymap.deinit(this.allocator);
    this.tokens.deinit(this.allocator);
}

pub const SourceIndex = xkb.Token.SourceIndex;
pub const TokenIndex = enum(u32) { _ };
pub const Scancode = enum(u32) { _ };

pub const Keymap = struct {
    xkb_keycodes: ?Keycodes,
    xkb_types: ?Types,
    xkb_compatibility: ?Compatibility,
    xkb_symbols: ?Symbols,

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        if (this.xkb_keycodes) |*keycodes| keycodes.deinit(allocator);
        if (this.xkb_types) |*types| types.deinit(allocator);
        if (this.xkb_compatibility) |*compatibility| compatibility.deinit(allocator);
        if (this.xkb_symbols) |*syms| syms.deinit(allocator);
    }
};

pub const Keycodes = struct {
    name: TokenIndex,
    keycodes: std.StringHashMapUnmanaged(Scancode) = .{},

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        this.keycodes.deinit(allocator);
    }
};

pub const Types = struct {
    name: TokenIndex,
    types: std.StringHashMapUnmanaged(Type) = .{},

    pub const Type = struct {
        name: TokenIndex,
        modifiers: Modifiers = .{},
        modifier_mappings: std.AutoHashMapUnmanaged(Modifiers, u32) = .{},
        level_names: []const TokenIndex = &.{},

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            this.modifier_mappings.deinit(allocator);
            allocator.free(this.level_names);
        }
    };

    pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
        var iter = this.types.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.deinit(allocator);
        }
        this.types.deinit(allocator);
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

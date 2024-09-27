pub const AST = @import("./AST.zig");
pub const Parser = @import("./Parser.zig");
pub const Token = @import("./Token.zig");
pub const Symbol = @import("./Symbol.zig");

pub const Keymap = struct {
    allocator: std.mem.Allocator,
    keys: std.AutoHashMapUnmanaged(struct { AST.Scancode, GroupIndex, LevelIndex }, std.BoundedArray(Symbol, 4)),
    key_types: std.AutoHashMapUnmanaged(struct { AST.Scancode, GroupIndex }, TypeIndex),
    types: []const Type,

    pub const GroupIndex = u2;
    pub const LevelIndex = u8;
    pub const TypeIndex = enum(u32) { _ };

    pub const State = struct {
        base_modifiers: Modifiers,
        latched_modifiers: Modifiers,
        locked_modifiers: Modifiers,
        group: GroupIndex,

        pub fn getModifiers(this: @This()) Modifiers {
            var mods: u32 = @bitCast(this.base_modifiers);
            mods |= @bitCast(this.latched_modifiers);
            mods |= @bitCast(this.locked_modifiers);
            return @bitCast(mods);
        }
    };

    pub fn deinit(this: *@This()) void {
        this.keys.deinit(this.allocator);
        this.key_types.deinit(this.allocator);
        this.allocator.free(this.types);
    }

    pub fn getSymbol(this: @This(), evdev_keycode: AST.Scancode, state: State) ?Symbol {
        const key_type_index = this.key_types.get(.{ evdev_keycode, state.group }) orelse return null;
        const key_type = this.types[@intFromEnum(key_type_index)];

        const level = key_type.getLevel(state) orelse return null;

        const keysyms = this.keys.get(.{ evdev_keycode, state.group, level }) orelse return null;
        if (keysyms.slice().len == 0) return null;

        return keysyms.slice()[0];
    }

    const MAX_MAPPINGS = 64;

    pub const Type = struct {
        filter: Modifiers,
        mapping: std.BoundedArray(std.meta.Tuple(&.{ Modifiers, LevelIndex }), MAX_MAPPINGS),

        pub fn getLevel(this: @This(), state: State) ?LevelIndex {
            const modifiers = @as(u32, @bitCast(this.filter)) & @as(u32, @bitCast(state.getModifiers()));
            for (this.mapping.slice()) |mapping| {
                if (@as(u32, @bitCast(mapping[0])) == modifiers) return mapping[1];
            }
            return 0;
        }
    };

    pub fn fromString(allocator: std.mem.Allocator, source: []const u8) !@This() {
        var ast = try Parser.parse(allocator, source);
        defer ast.deinit();
        return try fromAST(allocator, ast);
    }

    pub fn fromAST(allocator: std.mem.Allocator, ast: AST) !@This() {
        var this = @This(){
            .allocator = allocator,
            .keys = .{},
            .key_types = .{},
            .types = &.{},
        };

        const ast_keycodes = ast.keymap.keycodes orelse return error.Invalid;
        const ast_types = ast.keymap.types orelse return error.Invalid;
        const ast_symbols = ast.keymap.symbols orelse return error.Invalid;

        const types = try this.allocator.alloc(Type, ast_types.types.len);
        errdefer this.allocator.free(this.types);
        this.types = types;

        var named_key_types = std.StringHashMap(TypeIndex).init(allocator);
        defer named_key_types.deinit();
        try named_key_types.ensureTotalCapacity(@intCast(ast_types.types.len));
        for (ast_types.types, 0..) |ast_type, i| {
            const name = ast.tokenString(ast_type.name);

            var mapping = std.BoundedArray(std.meta.Tuple(&.{ Modifiers, LevelIndex }), MAX_MAPPINGS){};
            for (ast_type.modifier_mappings) |map| {
                try mapping.append(.{
                    .{
                        .shift = map.modifiers.real.shift,
                        .lock = map.modifiers.real.lock,
                        .control = map.modifiers.real.control,
                        .mod1 = map.modifiers.real.mod1,
                        .mod2 = map.modifiers.real.mod2,
                        .mod3 = map.modifiers.real.mod3,
                        .mod4 = map.modifiers.real.mod4,
                        .mod5 = map.modifiers.real.mod5,
                        .virtual = map.modifiers.virtual,
                    },
                    @intCast(map.level_index - 1),
                });
            }

            types[i] = .{
                .filter = .{
                    .shift = ast_type.modifiers.real.shift,
                    .lock = ast_type.modifiers.real.lock,
                    .control = ast_type.modifiers.real.control,
                    .mod1 = ast_type.modifiers.real.mod1,
                    .mod2 = ast_type.modifiers.real.mod2,
                    .mod3 = ast_type.modifiers.real.mod3,
                    .mod4 = ast_type.modifiers.real.mod4,
                    .mod5 = ast_type.modifiers.real.mod5,
                    .virtual = ast_type.modifiers.virtual,
                },
                .mapping = mapping,
            };
            named_key_types.putAssumeCapacity(name, @enumFromInt(i));
        }

        var key_scancodes = std.StringHashMap(AST.Scancode).init(allocator);
        defer key_scancodes.deinit();
        try key_scancodes.ensureTotalCapacity(@intCast(ast_keycodes.keycodes.len + ast_keycodes.aliases.len));
        for (ast_keycodes.keycodes) |keycode| {
            key_scancodes.putAssumeCapacity(ast.tokenString(keycode.keyname), keycode.scancode);
        }
        for (ast_keycodes.aliases) |alias| {
            const scancode = key_scancodes.get(ast.tokenString(alias.base_keyname)) orelse continue;
            key_scancodes.putAssumeCapacity(ast.tokenString(alias.alias_keyname), scancode);
        }

        for (ast_symbols.keys) |ast_key| {
            const scancode = key_scancodes.get(ast.tokenString(ast_key.keyname)) orelse continue;
            for (ast_key.groups) |group| {
                const key_type: TypeIndex = if (ast_key.type_name) |type_name_token_index|
                    named_key_types.get(ast.tokenString(type_name_token_index)) orelse @enumFromInt(0)
                else if (group.levels.len == 1)
                    named_key_types.get("\"ONE_LEVEL\"") orelse @enumFromInt(0)
                else if (group.levels.len == 2 and
                    group.levels[0].character != null and group.levels[0].character.? < 128 and std.ascii.isLower(@intCast(group.levels[0].character.?)) and
                    group.levels[1].character != null and group.levels[1].character.? < 128 and std.ascii.isUpper(@intCast(group.levels[1].character.?)))
                    named_key_types.get("\"ALPHABETIC\"") orelse @enumFromInt(0)
                    // TODO: KEYPAD TWO_LEVEL
                else if (group.levels.len == 2)
                    named_key_types.get("\"TWO_LEVEL\"") orelse @enumFromInt(0)
                    // TODO: FOUR_LEVEL_ALPHABETIC
                    // TODO: FOUR_LEVEL_SEMIALPHABETIC
                    // TODO: FOUR_LEVEL_KEYPAD
                else if (group.levels.len == 4)
                    named_key_types.get("\"FOUR_LEVEL\"") orelse @enumFromInt(0)
                else
                    @enumFromInt(0);
                for (group.levels, 0..) |symbol, level| {
                    var generated_symbols = std.BoundedArray(Symbol, 4){};
                    try generated_symbols.append(symbol);

                    try this.keys.put(this.allocator, .{ scancode, @intCast(group.index - 1), @intCast(level) }, generated_symbols);

                    try this.key_types.put(this.allocator, .{ scancode, @intCast(group.index - 1) }, key_type);
                }
            }
        }

        return this;
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

pub fn initSymbolStringTable(allocator: std.mem.Allocator) !std.StringHashMap(Symbol) {
    var symbol_string_table = std.StringHashMap(Symbol).init(allocator);
    errdefer symbol_string_table.deinit();

    const symbol_info = @typeInfo(Symbol);
    try symbol_string_table.ensureTotalCapacity(symbol_info.Struct.decls.len);

    @setEvalBranchQuota(5000);
    inline for (symbol_info.Struct.decls) |decl| {
        symbol_string_table.putAssumeCapacityNoClobber(decl.name, @field(Symbol, decl.name));
    }

    return symbol_string_table;
}

test {
    _ = AST;
    _ = Parser;
    _ = Token;
}

const std = @import("std");

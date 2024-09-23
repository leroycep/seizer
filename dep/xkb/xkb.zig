// TODO: xkb_keymap {
// TODO: xkb_keycodes {}
// TODO: xkb_types {}
// TODO: xkb_compatibility {}
// TODO: xkb_symbols {}
// }

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

pub const Scancode = enum(u32) { _ };

pub const Parser = struct {
    pub const SourceIndex = enum(u32) { _ };

    pub const Token = struct {
        source_index: SourceIndex,
        type: Type,

        pub const Type = enum {
            end_of_file,

            // characters
            plus,
            open_brace,
            close_brace,
            open_paren,
            close_paren,
            open_bracket,
            close_bracket,
            dot,
            comma,
            semicolon,
            equals,

            // types
            string,
            integer,
            keyname,
            identifier,

            // keywords
            action,
            alias,
            alphanumeric_keys,
            alternate_group,
            alternate,
            augment,
            default,
            function_keys,
            group,
            hidden,
            include,
            indicator,
            interpret,
            key,
            keypad_keys,
            keys,
            logo,
            level_name,
            map,
            modifiers,
            modifier_map,
            modifier_keys,
            outline,
            overlay,
            override,
            partial,
            preserve,
            replace,
            row,
            section,
            shape,
            solid,
            text,
            type,
            virtual_modifiers,
            xkb_compatibility_map,
            xkb_geometry,
            xkb_keycodes,
            xkb_keymap,
            xkb_layout,
            xkb_semantics,
            xkb_symbols,
            xkb_types,

            pub const KEYWORDS = [_]Token.Type{
                .action,
                .alias,
                .alphanumeric_keys,
                .alternate_group,
                .alternate,
                .augment,
                .default,
                .function_keys,
                .group,
                .hidden,
                .include,
                .indicator,
                .interpret,
                .key,
                .keypad_keys,
                .keys,
                .level_name,
                .logo,
                .map,
                .modifiers,
                .modifier_map,
                .modifier_keys,
                .outline,
                .overlay,
                .override,
                .partial,
                .preserve,
                .replace,
                .row,
                .section,
                .shape,
                .solid,
                .text,
                .type,
                .virtual_modifiers,
                .xkb_compatibility_map,
                // TODO: legacy
                .xkb_geometry,
                .xkb_keycodes,
                .xkb_keymap,
                .xkb_layout,
                .xkb_semantics,
                .xkb_symbols,
                .xkb_types,
            };
            const KeywordAlias = struct {
                literal: [:0]const u8,
                type: Type,
            };
            pub const KEYWORD_ALIASES = [_]KeywordAlias{
                .{ .literal = "modmap", .type = .modifier_map },
                .{ .literal = "mod_map", .type = .modifier_map },
                .{ .literal = "xkb_compatibility", .type = .xkb_compatibility_map },
                .{ .literal = "xkb_compat_map", .type = .xkb_compatibility_map },
                .{ .literal = "xkb_compat", .type = .xkb_compatibility_map },
            };
        };
    };

    pub fn tokenString(source: []const u8, source_index: SourceIndex) ![]const u8 {
        var source_index_mut = @intFromEnum(source_index);
        const token = try nextToken(source, &source_index_mut);
        return source[@intFromEnum(token.source_index)..source_index_mut];
    }

    pub fn nextToken(source: []const u8, source_index: *u32) !Token {
        while (true) {
            if (source_index.* >= source.len) {
                return Token{
                    .source_index = @enumFromInt(source_index.*),
                    .type = .end_of_file,
                };
            }
            const index_before_switch_case = source_index.*;
            switch (source[source_index.*]) {
                ' ', '\n', '\t' => {
                    source_index.* += 1;
                    continue;
                },
                '{' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .open_brace,
                    };
                    source_index.* += 1;
                    return token;
                },
                '}' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .close_brace,
                    };
                    source_index.* += 1;
                    return token;
                },
                '(' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .open_paren,
                    };
                    source_index.* += 1;
                    return token;
                },
                ')' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .close_paren,
                    };
                    source_index.* += 1;
                    return token;
                },
                '[' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .open_bracket,
                    };
                    source_index.* += 1;
                    return token;
                },
                ']' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .close_bracket,
                    };
                    source_index.* += 1;
                    return token;
                },
                ',' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .comma,
                    };
                    source_index.* += 1;
                    return token;
                },
                ';' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .semicolon,
                    };
                    source_index.* += 1;
                    return token;
                },
                '+' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .plus,
                    };
                    source_index.* += 1;
                    return token;
                },
                '.' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .dot,
                    };
                    source_index.* += 1;
                    return token;
                },
                '=' => {
                    const token = Token{
                        .source_index = @enumFromInt(source_index.*),
                        .type = .equals,
                    };
                    source_index.* += 1;
                    return token;
                },
                '0'...'9' => {
                    const start_index = source_index.*;

                    // TODO: handle floats and hexadecimal?
                    const end_index = std.mem.indexOfNonePos(u8, source, source_index.*, "0123456789") orelse source.len;

                    const token = Token{
                        .source_index = @enumFromInt(start_index),
                        .type = .integer,
                    };
                    source_index.* = @intCast(end_index);

                    return token;
                },
                '"' => {
                    const start_index = source_index.*;

                    var backslash_before = false;
                    const end_index = for (source[source_index.* + 1 ..], source_index.* + 1..) |string_character, string_source_index| {
                        if (backslash_before) {
                            // TODO: octal number
                            backslash_before = false;
                        } else if (string_character == '\\') {
                            backslash_before = true;
                        } else if (string_character == '"') {
                            break string_source_index;
                        }
                    } else return error.UnexpectedEOF;

                    const token = Token{
                        .source_index = @enumFromInt(start_index),
                        .type = .string,
                    };
                    source_index.* = @intCast(end_index + 1);
                    return token;
                },
                '<' => {
                    const start_index = source_index.*;
                    const end_index = std.mem.indexOfScalarPos(u8, source, source_index.*, '>') orelse return error.UnexpectedEOF;

                    const token = Token{
                        .source_index = @enumFromInt(start_index),
                        .type = .keyname,
                    };
                    source_index.* = @intCast(end_index + 1);
                    return token;
                },
                else => |character| {
                    for (Token.Type.KEYWORDS) |keyword| {
                        const literal = @tagName(keyword);
                        // TODO: make sure it ends with a space or a bracket
                        if (std.mem.startsWith(u8, source[source_index.*..], literal)) {
                            const token = Token{
                                .source_index = @enumFromInt(source_index.*),
                                .type = keyword,
                            };
                            source_index.* += @intCast(literal.len);
                            return token;
                        }
                    }
                    for (Token.Type.KEYWORD_ALIASES) |alias| {
                        const literal = alias.literal;
                        // TODO: make sure it ends with a space or a bracket
                        if (std.mem.startsWith(u8, source[source_index.*..], literal)) {
                            const token = Token{
                                .source_index = @enumFromInt(source_index.*),
                                .type = alias.type,
                            };
                            source_index.* += @intCast(literal.len);
                            return token;
                        }
                    }
                    // only consider something an identifier after we've exhausted the other options
                    switch (character) {
                        'A'...'Z', 'a'...'z' => {
                            const start_index = source_index.*;

                            const end_index = for (source[source_index.* + 1 ..], source_index.* + 1..) |string_character, string_source_index| {
                                switch (string_character) {
                                    'A'...'Z', 'a'...'z', '0'...'9', '_' => {},
                                    else => break string_source_index,
                                }
                            } else return error.UnexpectedEOF;

                            const token = Token{
                                .source_index = @enumFromInt(start_index),
                                .type = .identifier,
                            };
                            source_index.* = @intCast(end_index);
                            return token;
                        },
                        else => {},
                    }
                },
            }
            std.debug.panic("Unhandled case:\n    \"{}\"\n    \"{}\"\n", .{ std.zig.fmtEscapes(source[index_before_switch_case..]), std.zig.fmtEscapes(source[source_index.*..]) });
        }
    }

    pub fn tokenize(allocator: std.mem.Allocator, source: []const u8) !std.MultiArrayList(Token) {
        std.debug.assert(source.len < std.math.maxInt(u32));

        var tokens = std.MultiArrayList(Token){};
        errdefer tokens.deinit(allocator);

        var source_index: u32 = 0;
        while (true) {
            const token = try nextToken(source, &source_index);
            try tokens.append(allocator, token);
            if (token.type == .end_of_file) break;
        }

        return tokens;
    }

    pub const xkb_keymap = struct {
        xkb_keycodes: ?xkb_keycodes,
        xkb_types: ?xkb_types,
        xkb_compatibility: ?xkb_compatibility,
        xkb_symbols: ?xkb_symbols,

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            if (this.xkb_keycodes) |*keycodes| keycodes.deinit(allocator);
            if (this.xkb_types) |*types| types.deinit(allocator);
            if (this.xkb_compatibility) |*compatibility| compatibility.deinit(allocator);
            if (this.xkb_symbols) |*syms| syms.deinit(allocator);
        }
    };
    pub const xkb_keycodes = struct {
        name: SourceIndex,
        keycodes: std.StringHashMapUnmanaged(Scancode) = .{},

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            this.keycodes.deinit(allocator);
        }
    };
    pub const xkb_types = struct {
        name: SourceIndex,
        types: std.StringHashMapUnmanaged(Type) = .{},

        pub const Type = struct {
            name: SourceIndex,
            modifiers: Modifiers = .{},
            modifier_mappings: std.AutoHashMapUnmanaged(Modifiers, u32) = .{},
            level_names: []const SourceIndex = &.{},

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
    pub const xkb_compatibility = struct {
        name: SourceIndex,

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            _ = this;
            _ = allocator;
        }
    };
    pub const xkb_symbols = struct {
        name: SourceIndex,

        pub fn deinit(this: *@This(), allocator: std.mem.Allocator) void {
            _ = this;
            _ = allocator;
        }
    };

    pub fn parse(allocator: std.mem.Allocator, source: []const u8) !xkb_keymap {
        var tokens = try tokenize(allocator, source);
        defer tokens.deinit(allocator);

        var result: ?xkb_keymap = null;
        errdefer if (result) |*r| r.deinit(allocator);

        var pos: u32 = 0;
        while (true) {
            switch (tokens.items(.type)[pos]) {
                .end_of_file => break,
                .xkb_keymap => if (result) |_| {
                    std.log.warn("multiple xkb_keymap blocks", .{});
                    return error.InvalidFormat;
                } else {
                    pos += 1;
                    result = try parse_xkb_keymap(allocator, source, tokens.slice(), &pos);
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos)});
                    return error.InvalidFormat;
                },
            }
        }

        if (result) |r| {
            return r;
        } else {
            std.log.warn("no xkb_keymap block in file", .{});
            return error.InvalidFormat;
        }
    }

    fn parse_xkb_keymap(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !xkb_keymap {
        var result = xkb_keymap{ .xkb_keycodes = null, .xkb_types = null, .xkb_compatibility = null, .xkb_symbols = null };
        errdefer result.deinit(allocator);

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_keymap: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                    return result;
                },
                .xkb_keycodes => if (result.xkb_keycodes) |_| {
                    std.log.warn("multiple xkb_keycodes blocks", .{});
                    return error.InvalidFormat;
                } else {
                    pos.* += 1;
                    result.xkb_keycodes = try parse_xkb_keycodes(allocator, source, tokens, pos);
                },
                .xkb_types => if (result.xkb_types) |_| {
                    std.log.warn("multiple xkb_types blocks", .{});
                    return error.InvalidFormat;
                } else {
                    pos.* += 1;
                    result.xkb_types = try parse_xkb_types(allocator, source, tokens, pos);
                },
                .xkb_compatibility_map => if (result.xkb_compatibility) |_| {
                    std.log.warn("multiple xkb_compatibility blocks", .{});
                    return error.InvalidFormat;
                } else {
                    pos.* += 1;
                    result.xkb_compatibility = try parse_xkb_compatibility(allocator, source, tokens, pos);
                },
                .xkb_symbols => if (result.xkb_symbols) |_| {
                    std.log.warn("multiple xkb_symbols blocks", .{});
                    return error.InvalidFormat;
                } else {
                    pos.* += 1;
                    result.xkb_symbols = try parse_xkb_symbols(allocator, source, tokens, pos);
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parse_xkb_keycodes(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !xkb_keycodes {
        if (tokens.items(.type)[pos.*] != .string) {
            std.log.warn("unexpected token in xkb_keycodes: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }

        var result = xkb_keycodes{ .name = tokens.items(.source_index)[pos.*] };
        errdefer result.deinit(allocator);

        pos.* += 1;

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_keycodes: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                    return result;
                },
                .keyname => {
                    const keyname_token_pos = pos.*;
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .integer) return error.InvalidFormat;
                    const integer_string = try Parser.tokenString(source, tokens.items(.source_index)[pos.*]);
                    const keycode: Scancode = @enumFromInt(try std.fmt.parseInt(u32, integer_string, 10));

                    const keyname_string = try Parser.tokenString(source, tokens.items(.source_index)[keyname_token_pos]);
                    try result.keycodes.put(allocator, keyname_string, keycode);

                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                },
                .alias => {
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .keyname) return error.InvalidFormat;
                    const keyname_token_pos = pos.*;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .keyname) return error.InvalidFormat;
                    const base_keyname_token_pos = pos.*;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    const base_keyname_string = try Parser.tokenString(source, tokens.items(.source_index)[base_keyname_token_pos]);
                    const keyname_string = try Parser.tokenString(source, tokens.items(.source_index)[keyname_token_pos]);

                    const base_scancode = result.keycodes.get(base_keyname_string) orelse {
                        std.log.warn("Alias of not yet defined keyname, {s}", .{base_keyname_string});
                        return error.UnknownKeyname;
                    };

                    try result.keycodes.put(allocator, keyname_string, base_scancode);
                },
                .indicator => {
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .integer) return error.InvalidFormat;
                    const indicator_index_token_pos = pos.*;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .string) return error.InvalidFormat;
                    const indicator_name_token_pos = pos.*;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    // we aren't making use of these, so we just discard them
                    _ = indicator_index_token_pos;
                    _ = indicator_name_token_pos;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parse_xkb_types(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !xkb_types {
        if (tokens.items(.type)[pos.*] != .string) {
            std.log.warn("unexpected token in xkb_types: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }

        var result = xkb_types{ .name = tokens.items(.source_index)[pos.*] };
        errdefer result.deinit(allocator);

        var virtual_modifiers = std.StringHashMapUnmanaged(u5){};
        defer virtual_modifiers.deinit(allocator);

        pos.* += 1;

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_types: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                    return result;
                },
                .virtual_modifiers => {
                    if (virtual_modifiers.count() > 0) {
                        std.log.warn("multiple virtual modifiers declarations: {}", .{tokens.get(pos.*)});
                        return error.MultipleVirutualModifiersDeclarations;
                    }
                    pos.* += 1;
                    virtual_modifiers = try parseVirtualModifiersDeclaration(allocator, source, tokens, pos);
                },
                .type => {
                    pos.* += 1;
                    const xkb_type = try parse_xkb_types_type(allocator, source, tokens, pos, virtual_modifiers);
                    const xkb_type_name = try tokenString(source, xkb_type.name);
                    try result.types.put(allocator, xkb_type_name, xkb_type);
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parse_xkb_types_type(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32, virtual_modifiers: std.StringHashMapUnmanaged(u5)) !xkb_types.Type {
        if (tokens.items(.type)[pos.*] != .string) {
            std.log.warn("unexpected token in xkb_types: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }

        var result = xkb_types.Type{ .name = tokens.items(.source_index)[pos.*] };
        errdefer result.deinit(allocator);
        var modifiers_already_parsed = false;

        var level_names = std.ArrayList(SourceIndex).init(allocator);
        defer level_names.deinit();

        pos.* += 1;

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_types: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    result.level_names = try level_names.toOwnedSlice();
                    return result;
                },
                .modifiers => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    if (modifiers_already_parsed) {
                        std.log.warn("modifiers for type {s} declared multiple times!", .{try tokenString(source, result.name)});
                        return error.MultipleModifierDeclarations;
                    }

                    result.modifiers = try parseModifiers(source, tokens, pos, virtual_modifiers);
                    modifiers_already_parsed = true;

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                },
                .map => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .open_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    const modifier_tokens_start_pos = pos.*;
                    const modifiers = try parseModifiers(source, tokens, pos, virtual_modifiers);
                    const modifier_tokens_end_pos = pos.*;

                    // const modifiers_token_types_slice = tokens.items(.types)[modifier_tokens_start_pos..modifier_tokens_end_pos];
                    const modifiers_token_source_index_slice = tokens.items(.source_index)[modifier_tokens_start_pos..modifier_tokens_end_pos];

                    if (tokens.items(.type)[pos.*] != .close_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    const level_index = try parseLevel(source, tokens, pos);

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    if (try result.modifier_mappings.fetchPut(allocator, modifiers, level_index)) |_| {
                        std.log.warn("type {s} has multiple modifier mappings for {}", .{ try tokenString(source, result.name), modifiers });
                        for (modifiers_token_source_index_slice, 0..) |idx, i| {
                            std.log.warn("token[{}] = {s}", .{ i, try tokenString(source, idx) });
                        }
                        return error.DuplicateModifierMapping;
                    }
                },
                .level_name => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .open_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    const level_index = try parseLevel(source, tokens, pos);

                    if (tokens.items(.type)[pos.*] != .close_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .string) return error.InvalidFormat;
                    const level_name_token_index = pos.*;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    try level_names.resize(level_index);
                    level_names.items[level_index - 1] = tokens.items(.source_index)[level_name_token_index];
                },
                .preserve => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .open_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    const modifier_combo = try parseModifiers(source, tokens, pos, virtual_modifiers);

                    if (tokens.items(.type)[pos.*] != .close_bracket) return error.InvalidFormat;
                    pos.* += 1;

                    if (tokens.items(.type)[pos.*] != .equals) return error.InvalidFormat;
                    pos.* += 1;

                    const preserved_modifiers = try parseModifiers(source, tokens, pos, virtual_modifiers);

                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;

                    // for now, we ignore the preserve statements and just move on
                    _ = modifier_combo;
                    _ = preserved_modifiers;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parseModifiers(source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32, virtual_modifiers: std.StringHashMapUnmanaged(u5)) !Modifiers {
        const start_pos = pos.*;

        var modifiers = Modifiers{};

        var next_should_be_flag = true;
        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .semicolon, .close_bracket => {
                    if (next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }
                    return modifiers;
                },
                .identifier => {
                    const identifier_token_index = pos.*;
                    pos.* += 1;
                    if (!next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }

                    const string = try tokenString(source, tokens.items(.source_index)[identifier_token_index]);
                    if (std.mem.eql(u8, string, "Shift")) {
                        if (modifiers.shift) {
                            std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                        }
                        modifiers.shift = true;
                    } else if (std.mem.eql(u8, string, "Lock")) {
                        if (modifiers.lock) {
                            std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                        }
                        modifiers.lock = true;
                    } else if (std.mem.eql(u8, string, "Control")) {
                        if (modifiers.control) {
                            std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                        }
                        modifiers.control = true;
                    } else if (std.mem.eql(u8, string, "None")) {
                        //
                    } else if (virtual_modifiers.get(string)) |virtual_modifier_index| {
                        const bit_shift = virtual_modifier_index - 8;
                        const prev_value: u1 = @truncate(modifiers.virtual >> bit_shift);
                        if (prev_value == 1) {
                            std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                        }
                        modifiers.virtual |= (@as(u24, 1) << bit_shift);
                    } else {
                        std.log.warn("unknown modifier \"{}\"", .{std.zig.fmtEscapes(string)});
                        return error.UnknownModifier;
                    }

                    next_should_be_flag = false;
                },
                .plus => {
                    pos.* += 1;
                    if (next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }
                    next_should_be_flag = true;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parse_xkb_compatibility(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !xkb_compatibility {
        _ = source;
        if (tokens.items(.type)[pos.*] != .string) {
            std.log.warn("unexpected token in xkb_compatibility: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }

        var result = xkb_compatibility{ .name = tokens.items(.source_index)[pos.*] };
        errdefer result.deinit(allocator);

        pos.* += 1;

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_compatibility: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                    return result;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parse_xkb_symbols(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !xkb_symbols {
        _ = source;
        if (tokens.items(.type)[pos.*] != .string) {
            std.log.warn("unexpected token in xkb_symbols: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }

        var result = xkb_symbols{ .name = tokens.items(.source_index)[pos.*] };
        errdefer result.deinit(allocator);

        pos.* += 1;

        if (tokens.items(.type)[pos.*] != .open_brace) {
            std.log.warn("unexpected token in xkb_symbols: {}", .{tokens.get(pos.*)});
            return error.InvalidFormat;
        }
        pos.* += 1;

        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .close_brace => {
                    pos.* += 1;
                    if (tokens.items(.type)[pos.*] != .semicolon) return error.InvalidFormat;
                    pos.* += 1;
                    return result;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parseVirtualModifiersDeclaration(allocator: std.mem.Allocator, source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !std.StringHashMapUnmanaged(u5) {
        const start_pos = pos.*;

        var virtual_modifiers = std.StringHashMapUnmanaged(u5){};
        errdefer virtual_modifiers.deinit(allocator);

        var current_virtual_modifier: u5 = 7;

        var next_should_be_flag = true;
        while (true) {
            switch (tokens.items(.type)[pos.*]) {
                .semicolon => {
                    pos.* += 1;
                    if (next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }
                    return virtual_modifiers;
                },
                .identifier => {
                    const identifier_token_index = pos.*;
                    pos.* += 1;
                    if (!next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }

                    const string = try tokenString(source, tokens.items(.source_index)[identifier_token_index]);
                    if (std.mem.eql(u8, string, "Shift") or std.mem.eql(u8, string, "Lock")) {
                        std.log.warn("real modifier \"{}\" declared as virtual modifier", .{std.zig.fmtEscapes(string)});
                        return error.InvalidFormat;
                    }

                    const gop = try virtual_modifiers.getOrPut(allocator, string);
                    if (gop.found_existing) {
                        std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                    } else {
                        current_virtual_modifier = try std.math.add(u5, current_virtual_modifier, 1);
                        gop.value_ptr.* = current_virtual_modifier;
                    }
                    next_should_be_flag = false;
                },
                .plus => {
                    pos.* += 1;
                    if (next_should_be_flag) {
                        std.log.warn("invalid modifiers tokens: {any}", .{tokens.items(.type)[start_pos..pos.*]});
                        return error.InvalidFormat;
                    }
                    next_should_be_flag = true;
                },
                else => {
                    std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                    return error.InvalidFormat;
                },
            }
        }
    }

    fn parseLevel(source: []const u8, tokens: std.MultiArrayList(Token).Slice, pos: *u32) !u32 {
        switch (tokens.items(.type)[pos.*]) {
            .identifier => {
                const identifier_token_index = pos.*;
                pos.* += 1;

                const string = try tokenString(source, tokens.items(.source_index)[identifier_token_index]);
                const LEVEL_STR = "level";
                if (!std.ascii.startsWithIgnoreCase(string, LEVEL_STR)) {
                    std.log.warn("invalid level index: \"{}\"", .{std.zig.fmtEscapes(string)});
                    return error.InvalidFormat;
                }

                const index_str = string[LEVEL_STR.len..];
                return try std.fmt.parseInt(u32, index_str, 10);
            },
            .integer => {
                const integer_token_index = pos.*;
                pos.* += 1;

                const index_str = try tokenString(source, tokens.items(.source_index)[integer_token_index]);
                return try std.fmt.parseInt(u32, index_str, 10);
            },
            else => {
                std.log.warn("unexpected token: {}", .{tokens.get(pos.*)});
                return error.InvalidFormat;
            },
        }
    }
};

fn expectTokenization(expected_token_types: []const Parser.Token.Type, source: []const u8) !void {
    var tokens = try Parser.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(Parser.Token.Type, expected_token_types, tokens.items(.type));
}

test "tokenize" {
    try expectTokenization(&.{ .xkb_keymap, .open_brace, .close_brace, .semicolon, .end_of_file }, "xkb_keymap { };");

    try expectTokenization(&.{ .keyname, .equals, .integer, .semicolon, .keyname, .equals, .integer, .semicolon, .end_of_file },
        \\ <TLDE> = 49;
        \\ <AE01> = 10;
        \\
    );
}

fn expectParse(expected_parse: Parser.xkb_keymap, source: []const u8) !void {
    var parsed = try Parser.parse(std.testing.allocator, source);
    defer parsed.deinit(std.testing.allocator);

    if (expected_parse.xkb_keycodes != null and parsed.xkb_keycodes == null) return error.TextExpectedEqual;
    if (expected_parse.xkb_keycodes == null and parsed.xkb_keycodes != null) return error.TextExpectedEqual;

    if (expected_parse.xkb_types != null and parsed.xkb_types == null) return error.TextExpectedEqual;
    if (expected_parse.xkb_types == null and parsed.xkb_types != null) return error.TextExpectedEqual;

    if (expected_parse.xkb_compatibility != null and parsed.xkb_compatibility == null) return error.TextExpectedEqual;
    if (expected_parse.xkb_compatibility == null and parsed.xkb_compatibility != null) return error.TextExpectedEqual;

    if (expected_parse.xkb_symbols != null and parsed.xkb_symbols == null) return error.TextExpectedEqual;
    if (expected_parse.xkb_symbols == null and parsed.xkb_symbols != null) return error.TextExpectedEqual;

    var failed = false;
    if (expected_parse.xkb_keycodes) |expected_xkb_keycodes| {
        const actual_xkb_keycodes = parsed.xkb_keycodes.?;

        if (actual_xkb_keycodes.name != expected_xkb_keycodes.name) {
            const expected_name = try Parser.tokenString(source, expected_xkb_keycodes.name);
            const actual_name = try Parser.tokenString(source, actual_xkb_keycodes.name);
            std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                expected_xkb_keycodes.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_keycodes.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }

        if (expected_xkb_keycodes.keycodes.count() != actual_xkb_keycodes.keycodes.count()) {
            var expected_keycode_iter = expected_xkb_keycodes.keycodes.iterator();
            while (expected_keycode_iter.next()) |expected_entry| {
                if (actual_xkb_keycodes.keycodes.get(expected_entry.key_ptr.*)) |_| {
                    //
                } else {
                    std.debug.print("Expected {s} to equal keycode {}, instead it was not found\n", .{ expected_entry.key_ptr.*, expected_entry.value_ptr.* });
                }
            }
            var actual_keycode_iter = actual_xkb_keycodes.keycodes.iterator();
            while (actual_keycode_iter.next()) |actual_entry| {
                if (expected_xkb_keycodes.keycodes.get(actual_entry.key_ptr.*)) |_| {
                    //
                } else {
                    std.debug.print("Found unexpected keycode {s} = {}\n", .{ actual_entry.key_ptr.*, actual_entry.value_ptr.* });
                }
            }
            return error.TestExpectedEqual;
        }
        var keycode_iter = expected_xkb_keycodes.keycodes.iterator();
        while (keycode_iter.next()) |expected_entry| {
            const actual_keycode = actual_xkb_keycodes.keycodes.get(expected_entry.key_ptr.*) orelse return error.TestExpectedEqual;

            if (expected_entry.value_ptr.* != actual_keycode) {
                std.debug.print("Expected {s} to equal keycode {}, instead found {}", .{ expected_entry.key_ptr.*, expected_entry.value_ptr.*, actual_keycode });
                return error.TestExpectedEqual;
            }
        }
    }

    if (expected_parse.xkb_types) |expected_xkb_types| {
        const actual_xkb_types = parsed.xkb_types.?;

        if (actual_xkb_types.name != expected_xkb_types.name) {
            const expected_name = try Parser.tokenString(source, expected_xkb_types.name);
            const actual_name = try Parser.tokenString(source, actual_xkb_types.name);
            std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                expected_xkb_types.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_types.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }

        var expected_keycode_iter = expected_xkb_types.types.iterator();
        while (expected_keycode_iter.next()) |expected_entry| {
            if (actual_xkb_types.types.get(expected_entry.key_ptr.*)) |actual_type| {
                if (actual_type.name != expected_entry.value_ptr.name) {
                    const expected_name = try Parser.tokenString(source, expected_entry.value_ptr.name);
                    const actual_name = try Parser.tokenString(source, actual_type.name);
                    std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                        expected_entry.value_ptr.name,
                        std.zig.fmtEscapes(expected_name),
                        actual_type.name,
                        std.zig.fmtEscapes(actual_name),
                    });
                    failed = true;
                }

                if (!Modifiers.eql(actual_type.modifiers, expected_entry.value_ptr.modifiers)) {
                    std.debug.print("expected {}, instead found {} \n", .{
                        expected_entry.value_ptr.modifiers,
                        actual_type.modifiers,
                    });
                    failed = true;
                }

                const min_level_names_len = @min(expected_entry.value_ptr.level_names.len, actual_type.level_names.len);
                for (expected_entry.value_ptr.level_names[0..min_level_names_len], actual_type.level_names[0..min_level_names_len]) |expected_source_index, actual_source_index| {
                    if (actual_source_index != expected_source_index) {
                        const expected_level_name = try Parser.tokenString(source, expected_source_index);
                        const actual_level_name = try Parser.tokenString(source, actual_source_index);
                        std.debug.print("level_name: expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                            expected_source_index,
                            std.zig.fmtEscapes(expected_level_name),
                            actual_source_index,
                            std.zig.fmtEscapes(actual_level_name),
                        });
                        failed = true;
                    }
                }
                if (expected_entry.value_ptr.level_names.len > actual_type.level_names.len) {
                    for (expected_entry.value_ptr.level_names[min_level_names_len..]) |source_index| {
                        const level_name = try Parser.tokenString(source, source_index);
                        std.debug.print("expected to find source index {} ({s}) as well\n", .{ source_index, level_name });
                    }
                    failed = true;
                } else if (expected_entry.value_ptr.level_names.len < actual_type.level_names.len) {
                    for (actual_type.level_names[min_level_names_len..]) |source_index| {
                        const level_name = try Parser.tokenString(source, source_index);
                        std.debug.print("found unexpected source index {} ({s}) as well\n", .{ source_index, level_name });
                    }
                    failed = true;
                }
            } else {
                std.debug.print("Expected to find type {s}, instead it was not found\n", .{expected_entry.key_ptr.*});
                failed = true;
            }
        }
        var actual_keycode_iter = actual_xkb_types.types.iterator();
        while (actual_keycode_iter.next()) |actual_entry| {
            if (expected_xkb_types.types.get(actual_entry.key_ptr.*)) |_| {
                //
            } else {
                std.debug.print("Found unexpected keycode {s}\n", .{actual_entry.key_ptr.*});
                failed = true;
            }
        }
    }

    if (expected_parse.xkb_compatibility) |expected_xkb_compatibility| {
        const actual_xkb_compatibility = parsed.xkb_compatibility.?;

        if (actual_xkb_compatibility.name != expected_xkb_compatibility.name) {
            const expected_name = try Parser.tokenString(source, expected_xkb_compatibility.name);
            const actual_name = try Parser.tokenString(source, actual_xkb_compatibility.name);
            std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                expected_xkb_compatibility.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_compatibility.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }
    }

    if (expected_parse.xkb_symbols) |expected_xkb_symbols| {
        const actual_xkb_symbols = parsed.xkb_symbols.?;

        if (actual_xkb_symbols.name != expected_xkb_symbols.name) {
            const expected_name = try Parser.tokenString(source, expected_xkb_symbols.name);
            const actual_name = try Parser.tokenString(source, actual_xkb_symbols.name);
            std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                expected_xkb_symbols.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_symbols.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }
    }

    if (failed) return error.TestExpectedEqual;
}

test "parse empty keymap" {
    try expectParse(.{ .xkb_keycodes = null, .xkb_types = null, .xkb_compatibility = null, .xkb_symbols = null }, "xkb_keymap { };");

    try expectParse(.{
        .xkb_keycodes = .{ .name = @enumFromInt(30) },
        .xkb_types = .{ .name = @enumFromInt(55) },
        .xkb_compatibility = .{ .name = @enumFromInt(89) },
        .xkb_symbols = .{ .name = @enumFromInt(125) },
    },
        \\xkb_keymap {
        \\    xkb_keycodes "KEYS" {};
        \\    xkb_types "TYPES" {};
        \\    xkb_compatibility "COMPATIBILITY" {};
        \\    xkb_symbols "SYMBOLS" {};
        \\};
    );
}

test "parse keycodes" {
    var test_data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_data_arena.deinit();

    try expectParse(.{
        .xkb_keycodes = .{
            .name = @enumFromInt(30),
            .keycodes = try hashmapFromEntries(std.StringHashMapUnmanaged(Scancode), []const u8, Scancode, test_data_arena.allocator(), &.{
                .{ "<TLDE>", @enumFromInt(49) },
                .{ "<AE01>", @enumFromInt(10) },
            }),
        },
        .xkb_types = null,
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_keycodes "KEYS" {
        \\       <TLDE> = 49;
        \\       <AE01> = 10;
        \\   };
        \\};
    );

    try expectParse(.{
        .xkb_keycodes = .{
            .name = @enumFromInt(30),
            .keycodes = try hashmapFromEntries(std.StringHashMapUnmanaged(Scancode), []const u8, Scancode, test_data_arena.allocator(), &.{
                .{ "<COMP>", @enumFromInt(42) },
                .{ "<MENU>", @enumFromInt(42) },
            }),
        },
        .xkb_types = null,
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_keycodes "KEYS" {
        \\       <COMP> = 42;
        \\       alias <MENU> = <COMP>;
        \\   };
        \\};
    );

    // we don't actually care about indicator LEDs for our use case, but we need to make sure that they don't cause a parse error.
    try expectParse(.{
        .xkb_keycodes = .{
            .name = @enumFromInt(30),
        },
        .xkb_types = null,
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_keycodes "KEYS" {
        \\        indicator 1 = "Caps Lock";
        \\        indicator 2 = "Num Lock";
        \\        indicator 3 = "Scroll Lock";
        \\   };
        \\};
    );
}

test "parse types" {
    var test_data_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer test_data_arena.deinit();

    try expectParse(.{
        .xkb_keycodes = null,
        .xkb_types = .{
            .name = @enumFromInt(27),
            .types = try hashmapFromEntries(std.StringHashMapUnmanaged(Parser.xkb_types.Type), []const u8, Parser.xkb_types.Type, test_data_arena.allocator(), &.{
                .{ "\"FOUR_LEVEL\"", .{ .name = @enumFromInt(49) } },
            }),
        },
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       type "FOUR_LEVEL" { };
        \\   };
        \\};
    );

    try expectParse(.{
        .xkb_keycodes = null,
        .xkb_types = .{
            .name = @enumFromInt(27),
            .types = try hashmapFromEntries(std.StringHashMapUnmanaged(Parser.xkb_types.Type), []const u8, Parser.xkb_types.Type, test_data_arena.allocator(), &.{
                .{ "\"TYPE\"", .{ .name = @enumFromInt(86), .modifiers = .{ .shift = true, .lock = true, .virtual = 0b1 } } },
            }),
        },
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       virtual_modifiers LevelThree;
        \\       type "TYPE" {
        \\           modifiers = Shift+Lock+LevelThree;
        \\       };
        \\   };
        \\};
    );

    try expectParse(.{
        .xkb_keycodes = null,
        .xkb_types = .{
            .name = @enumFromInt(27),
            .types = try hashmapFromEntries(std.StringHashMapUnmanaged(Parser.xkb_types.Type), []const u8, Parser.xkb_types.Type, test_data_arena.allocator(), &.{
                .{
                    "\"ALPHABETIC\"", .{
                        .name = @enumFromInt(49),
                        .modifiers = .{ .shift = true, .lock = true },
                        .modifier_mappings = try hashmapFromEntries(std.AutoHashMapUnmanaged(Modifiers, u32), Modifiers, u32, test_data_arena.allocator(), &.{
                            .{ .{}, 1 },
                            .{ .{ .shift = true }, 2 },
                            .{ .{ .lock = true }, 2 },
                            .{ .{ .shift = true, .lock = true }, 2 },
                        }),
                        .level_names = &.{
                            @enumFromInt(262), // "Base"
                            @enumFromInt(302), // "Caps",
                        },
                    },
                },
            }),
        },
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       type "ALPHABETIC" {
        \\           modifiers = Shift+Lock;
        \\           map[None] = Level1;
        \\           map[Shift] = Level2;
        \\           map[Lock] = Level2;
        \\           map[Shift+Lock] = Level2;
        \\           level_name[Level1] = "Base";
        \\           level_name[Level2] = "Caps";
        \\       };
        \\   };
        \\};
    );

    // we are ignoring preserve modifiers at the moment, but need to be able to parse them
    try expectParse(.{
        .xkb_keycodes = null,
        .xkb_types = .{
            .name = @enumFromInt(27),
            .types = try hashmapFromEntries(std.StringHashMapUnmanaged(Parser.xkb_types.Type), []const u8, Parser.xkb_types.Type, test_data_arena.allocator(), &.{
                .{
                    "\"PRESERVED\"", .{
                        .name = @enumFromInt(49),
                        .modifiers = .{ .control = true, .shift = true },
                    },
                },
            }),
        },
        .xkb_compatibility = null,
        .xkb_symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       type "PRESERVED" {
        \\           modifiers = Control+Shift;
        \\           preserve[Control+Shift] = Control;
        \\       };
        \\   };
        \\};
    );
}

fn hashmapFromEntries(HashMap: type, Key: type, Value: type, arena: std.mem.Allocator, key_values: []const struct { Key, Value }) !HashMap {
    var result = HashMap{};
    try result.ensureTotalCapacity(arena, @intCast(key_values.len));
    for (key_values) |kv| {
        result.putAssumeCapacityNoClobber(kv[0], kv[1]);
    }
    return result;
}

const std = @import("std");

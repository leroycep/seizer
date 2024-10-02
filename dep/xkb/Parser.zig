allocator: std.mem.Allocator,
source: []const u8,
tokens: std.MultiArrayList(xkb.Token).Slice,
pos: TokenIndex,

/// To make parsing symbols easier
symbol_string_table: std.StringHashMap(xkb.Symbol),

const Parser = @This();

pub fn parse(allocator: std.mem.Allocator, source: []const u8) !xkb.AST {
    var symbol_string_table = try xkb.initSymbolStringTable(allocator);
    defer symbol_string_table.deinit();

    var tokens = try tokenize(allocator, source);
    defer tokens.deinit(allocator);

    var keymap: ?xkb.AST.Keymap = null;
    errdefer if (keymap) |*r| r.deinit(allocator);

    var parser = Parser{
        .allocator = allocator,
        .source = source,
        .tokens = tokens.slice(),
        .pos = @enumFromInt(0),

        .symbol_string_table = symbol_string_table,
    };

    while (true) {
        switch (parser.currentTokenType()) {
            .end_of_file => break,
            .xkb_keymap => if (keymap) |_| {
                std.log.warn("multiple xkb_keymap blocks", .{});
                return error.InvalidFormat;
            } else {
                var info = DebugInfo{
                    .parser = &parser,
                    .parent_info = null,
                    .token_context = parser.incrementPos(),
                };

                keymap = try parser.parseXkbKeymap(&info);
            },
            else => {
                parser.addParseError(null, "unexpected token", parser.pos);
                return error.UnexpectedToken;
            },
        }
    }

    if (keymap) |k| {
        return xkb.AST{
            .allocator = allocator,
            .source = source,
            .tokens = tokens.toOwnedSlice(),
            .keymap = k,
        };
    } else {
        std.log.warn("no xkb_keymap block in file", .{});
        return error.InvalidFormat;
    }
}

fn tokenize(allocator: std.mem.Allocator, source: []const u8) !std.MultiArrayList(xkb.Token) {
    std.debug.assert(source.len < std.math.maxInt(u32));

    var tokens = std.MultiArrayList(xkb.Token){};
    errdefer tokens.deinit(allocator);

    var source_index: u32 = 0;
    while (true) {
        const token = try xkb.Token.next(source, &source_index);
        try tokens.append(allocator, token);
        if (token.type == .end_of_file) break;
    }

    return tokens;
}

pub fn addParseError(this: *@This(), debug_info: ?*DebugInfo, message: []const u8, token_index: TokenIndex) void {
    const token = this.tokens.get(@intFromEnum(token_index));
    const token_string = xkb.Token.string(this.source, token.source_index) catch unreachable;

    const start_of_line = std.mem.lastIndexOfScalar(u8, this.source[0..@intFromEnum(token.source_index)], '\n') orelse 0;
    const end_of_line = std.mem.indexOfScalarPos(u8, this.source, @intFromEnum(token.source_index), '\n') orelse this.source.len;
    const line = this.source[start_of_line + 1 .. end_of_line];

    std.log.warn("{s}; context = {?}; {s} {} \"{}\" \"{}\"", .{ message, debug_info, @tagName(token.type), token.source_index, std.zig.fmtEscapes(token_string), std.zig.fmtEscapes(line) });
}

pub const DebugInfo = struct {
    parser: *Parser,
    parent_info: ?*DebugInfo = null,
    token_context: ?TokenIndex = null,

    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        if (fmt.len == 0) {
            if (this.parent_info) |parent| {
                try parent.format(fmt, options, writer);
                try writer.writeAll(" -> ");
            }
            if (this.token_context) |context_token| {
                const source_index = this.parser.tokens.items(.source_index)[@intFromEnum(context_token)];
                const source_string = xkb.Token.string(this.parser.source, source_index) catch unreachable;

                try writer.writeAll(source_string);
            }
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }
};

pub fn addDebugInfo(this: *@This(), parent_info: ?*DebugInfo, token: TokenIndex) DebugInfo {
    return .{
        .parser = this,
        .parent_info = parent_info,
        .token_context = token,
    };
}

fn parseXkbKeymap(this: *@This(), debug_info: ?*DebugInfo) !xkb.AST.Keymap {
    var result = xkb.AST.Keymap{ .keycodes = null, .types = null, .compatibility = null, .symbols = null };
    errdefer result.deinit(this.allocator);

    _ = try this.parseExpectToken(debug_info, .open_brace);

    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(debug_info, .semicolon);
                return result;
            },
            .xkb_keycodes => if (result.keycodes) |_| {
                this.addParseError(debug_info, "multiple xkb_keycodes blocks", this.pos);
                return error.MultipleXkbKeycodesBlocks;
            } else {
                var info = this.addDebugInfo(debug_info, this.incrementPos());
                result.keycodes = try this.parseXkbKeycodes(&info);
            },
            .xkb_types => if (result.types) |_| {
                this.addParseError(debug_info, "multiple xkb_types blocks", this.pos);
                return error.MultipleXkbTypesBlocks;
            } else {
                var info = this.addDebugInfo(debug_info, this.incrementPos());
                result.types = try this.parseXkbTypes(&info);
            },
            .xkb_compatibility_map => if (result.compatibility) |_| {
                this.addParseError(debug_info, "multiple xkb_compatibility blocks", this.pos);
                return error.MultipleXkbCompatibilityBlocks;
            } else {
                var info = this.addDebugInfo(debug_info, this.incrementPos());
                result.compatibility = try this.parseXkbCompatibility(&info);
            },
            .xkb_symbols => if (result.symbols) |_| {
                this.addParseError(debug_info, "multiple xkb_symbols blocks", this.pos);
                return error.MultipleXkbSymbolsBlocks;
            } else {
                var info = this.addDebugInfo(debug_info, this.incrementPos());
                result.symbols = try this.parseXkbSymbols(&info);
            },
            else => {
                this.addParseError(debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseXkbKeycodes(this: *@This(), parent_debug_info: ?*DebugInfo) !xkb.AST.Keycodes {
    const name_index = try this.parseExpectToken(parent_debug_info, .string);

    var result = xkb.AST.Keycodes{ .name = name_index };
    errdefer result.deinit(this.allocator);

    var keycodes = std.ArrayList(xkb.AST.Keycodes.Keycode).init(this.allocator);
    defer keycodes.deinit();

    var aliases = std.ArrayList(xkb.AST.Keycodes.Alias).init(this.allocator);
    defer aliases.deinit();

    var debug_info = this.addDebugInfo(parent_debug_info, result.name);

    _ = try this.parseExpectToken(parent_debug_info, .open_brace);
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                result.keycodes = try keycodes.toOwnedSlice();
                result.aliases = try aliases.toOwnedSlice();

                return result;
            },
            .keyname => {
                const keyname_token_pos = this.incrementPos();

                _ = try this.parseExpectToken(&debug_info, .equals);
                const integer_token_index = try this.parseExpectToken(&debug_info, .integer);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                const integer_string = try xkb.Token.string(this.source, this.tokenSourceIndex(integer_token_index));
                const scancode: xkb.AST.Scancode = @enumFromInt(try std.fmt.parseInt(u32, integer_string, 10));

                try keycodes.append(.{
                    .keyname = keyname_token_pos,
                    .scancode = scancode,
                });
            },
            .alias => {
                _ = this.incrementPos();

                const keyname_token_pos = try this.parseExpectToken(&debug_info, .keyname);
                _ = try this.parseExpectToken(&debug_info, .equals);
                const base_keyname_token_pos = try this.parseExpectToken(&debug_info, .keyname);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                try aliases.append(.{
                    .alias_keyname = keyname_token_pos,
                    .base_keyname = base_keyname_token_pos,
                });
            },
            .indicator => {
                _ = this.incrementPos();

                const indicator_index_token_pos = try this.parseExpectToken(&debug_info, .integer);
                _ = try this.parseExpectToken(&debug_info, .equals);
                const indicator_name_token_pos = try this.parseExpectToken(&debug_info, .string);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                // we aren't making use of these, so we just discard them
                _ = indicator_index_token_pos;
                _ = indicator_name_token_pos;
            },
            .identifier => {
                const identifier_token_pos: TokenIndex = this.incrementPos();

                _ = try this.parseExpectToken(&debug_info, .equals);
                const value_token_pos = try this.parseExpectOneOf(&debug_info, &.{ .string, .integer });
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                // we aren't making use of these, so we just discard them
                _ = identifier_token_pos;
                _ = value_token_pos;
            },
            else => {
                this.addParseError(&debug_info, "unexpected token", this.pos);
                return error.InvalidFormat;
            },
        }
    }
}

fn parseXkbTypes(this: *@This(), debug_info: ?*DebugInfo) !xkb.AST.Types {
    const xkb_types_name = try this.parseExpectToken(debug_info, .string);

    var result = xkb.AST.Types{ .name = xkb_types_name };
    errdefer result.deinit(this.allocator);

    var virtual_modifiers = std.StringHashMapUnmanaged(u5){};
    defer virtual_modifiers.deinit(this.allocator);

    var types = std.ArrayList(xkb.AST.Types.Type).init(this.allocator);
    defer types.deinit();

    _ = try this.parseExpectToken(debug_info, .open_brace);

    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(debug_info, .semicolon);
                result.types = try types.toOwnedSlice();
                return result;
            },
            .virtual_modifiers => {
                if (virtual_modifiers.count() > 0) {
                    this.addParseError(debug_info, "multiple virtual modifiers declarations", this.pos);
                    return error.MultipleVirutualModifiersDeclarations;
                }
                _ = this.incrementPos();
                virtual_modifiers = try this.parseVirtualModifiersDeclaration(debug_info);
            },
            .type => {
                _ = this.incrementPos();

                const xkb_type = try this.parseXkbTypesType(virtual_modifiers, debug_info);
                try types.append(xkb_type);
            },
            else => {
                this.addParseError(debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseXkbTypesType(this: *@This(), virtual_modifiers: std.StringHashMapUnmanaged(u5), parent_debug_info: ?*DebugInfo) !xkb.AST.Types.Type {
    const xkb_types_type_name = try this.parseExpectToken(parent_debug_info, .string);

    var debug_info = this.addDebugInfo(parent_debug_info, xkb_types_type_name);

    var modifiers_already_parsed = false;

    var modifiers: xkb.AST.Modifiers = .{};

    var modifier_mappings = std.ArrayList(xkb.AST.Types.Type.ModifierMapping).init(this.allocator);
    defer modifier_mappings.deinit();

    var level_names = std.ArrayList(TokenIndex).init(this.allocator);
    defer level_names.deinit();

    _ = try this.parseExpectToken(&debug_info, .open_brace);
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();

                _ = try this.parseExpectToken(&debug_info, .semicolon);

                return .{
                    .name = xkb_types_type_name,
                    .modifiers = modifiers,
                    .modifier_mappings = try modifier_mappings.toOwnedSlice(),
                    .level_names = try level_names.toOwnedSlice(),
                };
            },
            .modifiers => {
                _ = this.incrementPos();

                _ = try this.parseExpectToken(&debug_info, .equals);

                if (modifiers_already_parsed) {
                    this.addParseError(&debug_info, "modifiers declared multiple times", this.pos);
                    return error.MultipleModifierDeclarations;
                }

                modifiers = try this.parseModifiers(virtual_modifiers, &debug_info);
                modifiers_already_parsed = true;

                _ = try this.parseExpectToken(&debug_info, .semicolon);
            },
            .map => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .open_bracket);

                const map_modifiers = try this.parseModifiers(virtual_modifiers, &debug_info);

                _ = try this.parseExpectToken(&debug_info, .close_bracket);
                _ = try this.parseExpectToken(&debug_info, .equals);
                const level_index = try this.parseLevel(&debug_info);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                try modifier_mappings.append(.{ .modifiers = map_modifiers, .level_index = level_index });
            },
            .level_name => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .open_bracket);
                const level_index = try this.parseLevel(&debug_info);
                _ = try this.parseExpectToken(&debug_info, .close_bracket);
                _ = try this.parseExpectToken(&debug_info, .equals);
                const level_name_token_index = try this.parseExpectToken(&debug_info, .string);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                try level_names.resize(level_index);
                level_names.items[level_index - 1] = level_name_token_index;
            },
            .preserve => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .open_bracket);
                const modifier_combo = try this.parseModifiers(virtual_modifiers, &debug_info);
                _ = try this.parseExpectToken(&debug_info, .close_bracket);
                _ = try this.parseExpectToken(&debug_info, .equals);
                const preserved_modifiers = try this.parseModifiers(virtual_modifiers, &debug_info);
                _ = try this.parseExpectToken(&debug_info, .semicolon);

                // for now, we ignore the preserve statements and just move on
                _ = modifier_combo;
                _ = preserved_modifiers;
            },
            else => {
                this.addParseError(&debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseModifiers(this: *@This(), virtual_modifiers: std.StringHashMapUnmanaged(u5), debug_info: ?*DebugInfo) !xkb.AST.Modifiers {
    var modifiers = xkb.AST.Modifiers{};

    var next_should_be_flag = true;
    while (true) {
        switch (this.currentTokenType()) {
            .semicolon, .close_bracket => {
                if (next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                return modifiers;
            },
            .identifier => {
                if (!next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }

                const identifier_token_index = this.incrementPos();

                const string = try xkb.Token.string(this.source, this.tokenSourceIndex(identifier_token_index));
                if (std.ascii.eqlIgnoreCase(string, "shift")) {
                    if (modifiers.real.shift) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.shift = true;
                } else if (std.ascii.eqlIgnoreCase(string, "lock")) {
                    if (modifiers.real.lock) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.lock = true;
                } else if (std.ascii.eqlIgnoreCase(string, "control")) {
                    if (modifiers.real.control) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.control = true;
                } else if (std.ascii.eqlIgnoreCase(string, "mod1")) {
                    if (modifiers.real.mod1) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.mod1 = true;
                } else if (std.ascii.eqlIgnoreCase(string, "mod2")) {
                    if (modifiers.real.mod2) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.mod2 = true;
                } else if (std.ascii.eqlIgnoreCase(string, "mod3")) {
                    if (modifiers.real.mod3) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.mod3 = true;
                } else if (std.ascii.eqlIgnoreCase(string, "mod4")) {
                    if (modifiers.real.mod4) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.mod4 = true;
                } else if (std.ascii.eqlIgnoreCase(string, "mod5")) {
                    if (modifiers.real.mod5) {
                        this.addParseError(debug_info, "modifier declared more than once", identifier_token_index);
                    }
                    modifiers.real.mod5 = true;
                } else if (std.ascii.eqlIgnoreCase(string, "None")) {
                    //
                } else if (virtual_modifiers.get(string)) |virtual_modifier_index| {
                    const bit_shift = virtual_modifier_index - 8;
                    const prev_value: u1 = @truncate(modifiers.virtual >> bit_shift);
                    if (prev_value == 1) {
                        std.log.warn("modifier \"{}\" declared more than once", .{std.zig.fmtEscapes(string)});
                    }
                    modifiers.virtual |= (@as(u24, 1) << bit_shift);
                } else {
                    this.addParseError(debug_info, "unknown modifier", identifier_token_index);
                    return error.UnknownModifier;
                }

                next_should_be_flag = false;
            },
            .plus => {
                if (next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                next_should_be_flag = true;
            },
            else => {
                this.addParseError(debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseXkbCompatibility(this: *@This(), parent_debug_info: ?*DebugInfo) !xkb.AST.Compatibility {
    const xkb_compatibility_name = try this.parseExpectToken(parent_debug_info, .string);

    var result = xkb.AST.Compatibility{ .name = xkb_compatibility_name };
    errdefer result.deinit(this.allocator);

    var debug_info = this.addDebugInfo(parent_debug_info, result.name);

    var virtual_modifiers = std.StringHashMapUnmanaged(u5){};
    defer virtual_modifiers.deinit(this.allocator);

    _ = try this.parseExpectToken(&debug_info, .open_brace);
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .semicolon);
                return result;
            },
            .virtual_modifiers => {
                if (virtual_modifiers.count() > 0) {
                    this.addParseError(&debug_info, "multiple virtual modifiers declarations", this.pos);
                    return error.MultipleVirutualModifiersDeclarations;
                }
                _ = this.incrementPos();
                virtual_modifiers = try this.parseVirtualModifiersDeclaration(&debug_info);
            },
            .interpret => {
                var interpret_debug_info = this.addDebugInfo(&debug_info, this.incrementPos());

                if (this.currentTokenType() == .dot) {
                    _ = this.incrementPos();
                    _ = try this.parseExpectToken(&interpret_debug_info, .identifier);
                    _ = try this.parseExpectToken(&interpret_debug_info, .equals);
                    _ = try this.parseExpectToken(&interpret_debug_info, .identifier);
                    _ = try this.parseExpectToken(&interpret_debug_info, .semicolon);
                } else {
                    try this.parseInterpretStatement(&interpret_debug_info);
                }
            },
            .indicator => {
                var indicator_debug_info = this.addDebugInfo(&debug_info, this.incrementPos());
                _ = try this.parseCompatIndicatorBlock(virtual_modifiers, &indicator_debug_info);
            },
            else => {
                this.addParseError(&debug_info, "unexpected token", this.pos);
                return error.InvalidFormat;
            },
        }
    }
}

fn parseInterpretStatement(this: *@This(), parent_debug_info: ?*DebugInfo) !void {
    const condition = try this.parseInterpretCondition(parent_debug_info);
    _ = condition;

    _ = try this.parseExpectToken(parent_debug_info, .open_brace);

    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                return;
            },
            .identifier => {
                const identifier_token_pos = this.incrementPos();

                _ = try this.parseExpectToken(parent_debug_info, .equals);
                const value_token_pos = try this.parseExpectOneOf(parent_debug_info, &.{ .string, .integer, .identifier });
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);

                // we aren't making use of these, so we just discard them
                _ = identifier_token_pos;
                _ = value_token_pos;
            },
            .action => {
                _ = this.incrementPos();

                _ = try this.parseExpectToken(parent_debug_info, .equals);
                const action = try this.parseExpectOneOf(parent_debug_info, &.{
                    .NoAction,
                    .SetMods,
                    .LatchMods,
                    .LockMods,
                    .SetGroup,
                    .LatchGroup,
                    .LockGroup,
                    .MovePointer,
                    .PointerButton,
                    .LockPointerButton,
                    .SetPointerDefault,
                    .SetControls,
                    .LockControls,
                    .TerminateServer,
                    .SwitchScreen,
                    .Private,
                });

                _ = try this.parseActionParams(parent_debug_info);

                // we aren't making use of these, so we just discard them
                _ = action;
            },
            else => {
                this.addParseError(parent_debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseCompatIndicatorBlock(this: *@This(), virtual_modifiers: std.StringHashMapUnmanaged(u5), parent_debug_info: ?*DebugInfo) !void {
    const indicator_name = try this.parseExpectToken(parent_debug_info, .string);
    _ = try this.parseExpectToken(parent_debug_info, .open_brace);

    _ = indicator_name;

    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                return;
            },
            .identifier => {
                const identifier_token_pos = this.incrementPos();

                _ = try this.parseExpectToken(parent_debug_info, .equals);
                const value_token_pos = try this.parseExpectOneOf(parent_debug_info, &.{ .string, .integer, .hexadecimal_integer, .identifier });
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);

                // we aren't making use of these, so we just discard them
                _ = identifier_token_pos;
                _ = value_token_pos;
            },
            .modifiers => {
                const identifier_token_pos = this.incrementPos();

                _ = try this.parseExpectToken(parent_debug_info, .equals);
                const modifiers = try this.parseModifiers(virtual_modifiers, parent_debug_info);
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);

                // we aren't making use of these, so we just discard them
                _ = identifier_token_pos;
                _ = modifiers;
            },
            else => {
                this.addParseError(parent_debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseInterpretCondition(this: *@This(), parent_debug_info: ?*DebugInfo) !void {
    const State = enum {
        default,
        identifier,
        match_operator,
        paren,
        paren_identifier,
    };
    var state = State.default;
    while (true) {
        switch (state) {
            .default => switch (this.currentTokenType()) {
                .open_brace => return,
                .identifier => {
                    _ = this.incrementPos();
                    state = .identifier;
                },
                .AnyOfOrNone,
                .AnyOf,
                .NoneOf,
                .AllOf,
                .Exactly,
                => {
                    _ = this.incrementPos();
                    state = .match_operator;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .identifier => switch (this.currentTokenType()) {
                .plus => {
                    _ = this.incrementPos();
                    state = .default;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .match_operator => switch (this.currentTokenType()) {
                .open_paren => {
                    _ = this.incrementPos();
                    state = .paren;
                },
                .plus => {
                    _ = this.incrementPos();
                    state = .default;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .paren => switch (this.currentTokenType()) {
                .identifier => {
                    _ = this.incrementPos();
                    state = .paren_identifier;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .paren_identifier => switch (this.currentTokenType()) {
                .close_paren => {
                    _ = this.incrementPos();
                    return;
                },
                .plus => {
                    _ = this.incrementPos();
                    state = .paren;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
        }
    }
}

fn parseActionParams(this: *@This(), parent_debug_info: ?*DebugInfo) !void {
    _ = try this.parseExpectToken(parent_debug_info, .open_paren);

    const State = enum {
        default,
        key,
        key_equals,
        kv,
    };

    var state = State.default;

    while (true) {
        switch (state) {
            .default => switch (this.currentTokenType()) {
                .close_paren => {
                    _ = this.incrementPos();
                    _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                    return;
                },
                .identifier, .modifiers, .group, .type => {
                    _ = this.incrementPos();
                    state = .key;
                },
                .exclaim => {
                    _ = this.incrementPos();
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .key => switch (this.currentTokenType()) {
                .close_paren => {
                    _ = this.incrementPos();
                    _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                    return;
                },
                .equals => {
                    _ = this.incrementPos();
                    state = .key_equals;
                },
                .comma => {
                    _ = this.incrementPos();
                    state = .default;
                },
                .open_bracket => {
                    _ = this.incrementPos();
                    _ = try this.parseExpectOneOf(parent_debug_info, &.{ .integer, .hexadecimal_integer });
                    _ = try this.parseExpectToken(parent_debug_info, .close_bracket);
                    _ = try this.parseExpectToken(parent_debug_info, .equals);
                    state = .key_equals;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .key_equals => switch (this.currentTokenType()) {
                .identifier, .integer, .default, .hexadecimal_integer => {
                    _ = this.incrementPos();
                    state = .kv;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
            .kv => switch (this.currentTokenType()) {
                .comma => {
                    _ = this.incrementPos();
                    state = .default;
                },
                .close_paren => {
                    _ = this.incrementPos();
                    _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                    return;
                },
                else => {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                },
            },
        }
    }
}

fn parseXkbSymbols(this: *@This(), parent_debug_info: ?*DebugInfo) !xkb.AST.Symbols {
    const xkb_symbols_name = try this.parseExpectToken(parent_debug_info, .string);

    var keys = std.ArrayList(xkb.AST.Symbols.Key).init(this.allocator);
    defer {
        for (keys.items) |*key| {
            key.deinit(this.allocator);
        }
        keys.deinit();
    }

    _ = try this.parseExpectToken(parent_debug_info, .open_brace);
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);
                return xkb.AST.Symbols{
                    .name = xkb_symbols_name,
                    .keys = try keys.toOwnedSlice(),
                };
            },
            .identifier => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(parent_debug_info, .open_bracket);
                const group_index = try this.parseGroupIndex(parent_debug_info);
                _ = try this.parseExpectToken(parent_debug_info, .close_bracket);
                _ = try this.parseExpectToken(parent_debug_info, .equals);
                const name_string_token_index = try this.parseExpectToken(parent_debug_info, .string);
                _ = try this.parseExpectToken(parent_debug_info, .semicolon);

                _ = group_index;
                _ = name_string_token_index;
            },
            .key => {
                _ = this.incrementPos();
                const key = try this.parseXkbSymbolsKeyBlock(parent_debug_info);
                try keys.append(key);
            },
            .modifier_map => {
                _ = this.incrementPos();
                _ = try this.parseXkbSymbolsModifierMapBlock(parent_debug_info);
            },
            else => {
                this.addParseError(parent_debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseXkbSymbolsKeyBlock(this: *@This(), parent_debug_info: ?*DebugInfo) !xkb.AST.Symbols.Key {
    const keyname_token_index = try this.parseExpectToken(parent_debug_info, .keyname);

    var debug_info = this.addDebugInfo(parent_debug_info, keyname_token_index);

    var type_name: ?TokenIndex = null;

    var groups = std.ArrayList(xkb.AST.Symbols.Group).init(this.allocator);
    defer {
        for (groups.items) |*group| {
            group.deinit(this.allocator);
        }
        groups.deinit();
    }

    _ = try this.parseExpectToken(&debug_info, .open_brace);
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .semicolon);
                return .{
                    .keyname = keyname_token_index,
                    .type_name = type_name,
                    .groups = try groups.toOwnedSlice(),
                };
            },
            .open_bracket => {
                const group = try groups.addOne();

                _ = this.incrementPos();
                const symbol_list = try this.parseSymbolList(&debug_info);
                _ = try this.parseExpectToken(&debug_info, .close_bracket);

                group.* = .{ .index = @intCast(groups.items.len), .levels = symbol_list };
            },
            .type => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .equals);
                if (type_name != null) {
                    this.addParseError(&debug_info, "key type declared more than once", this.pos);
                }
                type_name = try this.parseExpectToken(&debug_info, .string);
                _ = try this.parseExpectToken(&debug_info, .comma);
            },
            .symbols => {
                const group = try groups.addOne();

                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .open_bracket);
                const group_index = try this.parseGroupIndex(parent_debug_info);
                _ = try this.parseExpectToken(&debug_info, .close_bracket);
                _ = try this.parseExpectToken(&debug_info, .equals);
                _ = try this.parseExpectToken(&debug_info, .open_bracket);
                const symbol_list = try this.parseSymbolList(&debug_info);
                _ = try this.parseExpectToken(&debug_info, .close_bracket);

                group.* = .{ .index = group_index, .levels = symbol_list };
            },
            else => {
                this.addParseError(&debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseXkbSymbolsModifierMapBlock(this: *@This(), parent_debug_info: ?*DebugInfo) !void {
    const identifier_token_index = try this.parseExpectToken(parent_debug_info, .identifier);

    // var result = XkbSymbolsKeyBlock{ .keyname = keyname_token_index };
    // errdefer result.deinit(this.allocator);

    var debug_info = this.addDebugInfo(parent_debug_info, identifier_token_index);

    _ = try this.parseExpectToken(&debug_info, .open_brace);
    var next_should_be_identifier = true;
    while (true) {
        switch (this.currentTokenType()) {
            .close_brace => {
                _ = this.incrementPos();
                _ = try this.parseExpectToken(&debug_info, .semicolon);
                // return result;
                return;
            },
            .identifier, .keyname => {
                if (!next_should_be_identifier) {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                next_should_be_identifier = false;
            },
            .comma => {
                if (next_should_be_identifier) {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                next_should_be_identifier = true;
            },
            else => {
                this.addParseError(&debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseSymbolList(this: *@This(), parent_debug_info: ?*DebugInfo) ![]xkb.Symbol {
    var symbols = std.ArrayList(xkb.Symbol).init(this.allocator);
    defer symbols.deinit();

    var next_should_be_symbol = true;
    while (true) {
        switch (this.currentTokenType()) {
            .close_bracket => {
                return try symbols.toOwnedSlice();
            },
            .identifier, .integer => {
                if (!next_should_be_symbol) {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                next_should_be_symbol = false;

                const symbol_token_index = this.incrementPos();
                const symbol_string = try xkb.Token.string(this.source, this.tokenSourceIndex(symbol_token_index));
                const symbol = this.symbol_string_table.get(symbol_string) orelse {
                    this.addParseError(parent_debug_info, "unknown symbol", symbol_token_index);
                    continue;
                };

                try symbols.append(symbol);
            },
            .comma => {
                if (next_should_be_symbol) {
                    this.addParseError(parent_debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                next_should_be_symbol = true;
            },
            else => {
                this.addParseError(parent_debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseVirtualModifiersDeclaration(this: *@This(), debug_info: ?*DebugInfo) !std.StringHashMapUnmanaged(u5) {
    var virtual_modifiers = std.StringHashMapUnmanaged(u5){};
    errdefer virtual_modifiers.deinit(this.allocator);

    var current_virtual_modifier: u5 = 7;

    var next_should_be_flag = true;
    while (true) {
        switch (this.currentTokenType()) {
            .semicolon => {
                if (next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                return virtual_modifiers;
            },
            .identifier => {
                if (!next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                const identifier_token_index = this.incrementPos();

                const string = try xkb.Token.string(this.source, this.tokenSourceIndex(identifier_token_index));
                if (std.ascii.eqlIgnoreCase(string, "shift") or std.ascii.eqlIgnoreCase(string, "lock")) {
                    this.addParseError(debug_info, "real modifier declared as virtual modifier", identifier_token_index);
                    return error.RealModifierDeclaredVirtual;
                }

                const gop = try virtual_modifiers.getOrPut(this.allocator, string);
                if (gop.found_existing) {
                    this.addParseError(debug_info, "virtual modifier declared more than once", identifier_token_index);
                } else {
                    current_virtual_modifier = try std.math.add(u5, current_virtual_modifier, 1);
                    gop.value_ptr.* = current_virtual_modifier;
                }
                next_should_be_flag = false;
            },
            .comma => {
                if (next_should_be_flag) {
                    this.addParseError(debug_info, "unexpected token", this.pos);
                    return error.UnexpectedToken;
                }
                _ = this.incrementPos();
                next_should_be_flag = true;
            },
            else => {
                this.addParseError(debug_info, "unexpected token", this.pos);
                return error.UnexpectedToken;
            },
        }
    }
}

fn parseLevel(this: *@This(), debug_info: ?*DebugInfo) !u32 {
    switch (this.currentTokenType()) {
        .identifier => {
            const identifier_token_index = this.incrementPos();

            const string = try xkb.Token.string(this.source, this.tokenSourceIndex(identifier_token_index));
            const LEVEL_STR = "level";
            if (!std.ascii.startsWithIgnoreCase(string, LEVEL_STR)) {
                std.log.warn("invalid level index: \"{}\"", .{std.zig.fmtEscapes(string)});
                return error.InvalidFormat;
            }

            const index_str = string[LEVEL_STR.len..];
            return try std.fmt.parseInt(u32, index_str, 10);
        },
        .integer => {
            const integer_token_index = this.incrementPos();

            const index_str = try xkb.Token.string(this.source, this.tokenSourceIndex(integer_token_index));
            return try std.fmt.parseInt(u32, index_str, 10);
        },
        else => {
            this.addParseError(debug_info, "unexpected token", this.pos);
            return error.UnexpectedToken;
        },
    }
}

fn parseGroupIndex(this: *@This(), debug_info: ?*DebugInfo) !u32 {
    switch (this.currentTokenType()) {
        .identifier => {
            const identifier_token_index = this.incrementPos();

            const string = try xkb.Token.string(this.source, this.tokenSourceIndex(identifier_token_index));
            const GROUP_STR = "group";
            if (!std.ascii.startsWithIgnoreCase(string, GROUP_STR)) {
                std.log.warn("invalid level index: \"{}\"", .{std.zig.fmtEscapes(string)});
                return error.InvalidFormat;
            }

            const index_str = string[GROUP_STR.len..];
            return try std.fmt.parseInt(u32, index_str, 10);
        },
        .integer => {
            const integer_token_index = this.incrementPos();

            const index_str = try xkb.Token.string(this.source, this.tokenSourceIndex(integer_token_index));
            return try std.fmt.parseInt(u32, index_str, 10);
        },
        else => {
            this.addParseError(debug_info, "unexpected token", this.pos);
            return error.UnexpectedToken;
        },
    }
}

fn parseExpectToken(this: *@This(), debug_info: ?*DebugInfo, expected: xkb.Token.Type) !TokenIndex {
    const actual_type = this.currentTokenType();
    if (actual_type != expected) {
        this.addParseError(debug_info, "unexpected token", this.pos);
        return error.UnexpectedToken;
    }
    return this.incrementPos();
}

fn parseExpectOneOf(this: *@This(), debug_info: ?*DebugInfo, expected_list: []const xkb.Token.Type) !TokenIndex {
    const actual_type = this.currentTokenType();
    for (expected_list) |expected| {
        if (actual_type == expected) {
            return this.incrementPos();
        }
    }
    this.addParseError(debug_info, "unexpected token", this.pos);
    return error.UnexpectedToken;
}

fn currentTokenType(this: @This()) xkb.Token.Type {
    return this.tokens.items(.type)[@intFromEnum(this.pos)];
}

fn incrementPos(this: *@This()) TokenIndex {
    const index: TokenIndex = this.pos;
    this.pos = @enumFromInt(@as(u32, @intFromEnum(this.pos)) + 1);
    return index;
}

fn tokenType(this: @This(), index: TokenIndex) xkb.Token.Type {
    return this.tokens.items(.type)[@intFromEnum(index)];
}

fn tokenSourceIndex(this: @This(), index: TokenIndex) SourceIndex {
    return this.tokens.items(.source_index)[@intFromEnum(index)];
}

fn expectTokenization(expected_token_types: []const Parser.xkb.Token.Type, source: []const u8) !void {
    var tokens = try Parser.tokenize(std.testing.allocator, source);
    defer tokens.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(Parser.xkb.Token.Type, expected_token_types, tokens.items(.type));
}

test "tokenize" {
    try expectTokenization(&.{ .xkb_keymap, .open_brace, .close_brace, .semicolon, .end_of_file }, "xkb_keymap { };");

    try expectTokenization(&.{ .keyname, .equals, .integer, .semicolon, .keyname, .equals, .integer, .semicolon, .end_of_file },
        \\ <TLDE> = 49;
        \\ <AE01> = 10;
        \\
    );
}

fn expectParse(expected_parse: xkb.AST.Keymap, source: []const u8) !void {
    var parsed = try Parser.parse(std.testing.allocator, source);
    defer parsed.deinit();

    if (expected_parse.keycodes != null and parsed.keymap.keycodes == null) return error.TextExpectedEqual;
    if (expected_parse.keycodes == null and parsed.keymap.keycodes != null) return error.TextExpectedEqual;

    if (expected_parse.types != null and parsed.keymap.types == null) return error.TextExpectedEqual;
    if (expected_parse.types == null and parsed.keymap.types != null) return error.TextExpectedEqual;

    if (expected_parse.compatibility != null and parsed.keymap.compatibility == null) return error.TextExpectedEqual;
    if (expected_parse.compatibility == null and parsed.keymap.compatibility != null) return error.TextExpectedEqual;

    if (expected_parse.symbols != null and parsed.keymap.symbols == null) return error.TextExpectedEqual;
    if (expected_parse.symbols == null and parsed.keymap.symbols != null) return error.TextExpectedEqual;

    var failed = false;
    if (expected_parse.keycodes) |expected_xkb_keycodes| {
        const actual_xkb_keycodes = parsed.keymap.keycodes.?;

        if (actual_xkb_keycodes.name != expected_xkb_keycodes.name) {
            const expected_name = parsed.tokenString(expected_xkb_keycodes.name);
            const actual_name = parsed.tokenString(actual_xkb_keycodes.name);
            std.debug.print("expected token index {} (\"{}\"), instead found token index {} (\"{}\")\n", .{
                expected_xkb_keycodes.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_keycodes.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }

        try std.testing.expectEqualSlices(xkb.AST.Keycodes.Keycode, expected_xkb_keycodes.keycodes, actual_xkb_keycodes.keycodes);
    }

    if (expected_parse.types) |expected_xkb_types| {
        const actual_xkb_types = parsed.keymap.types.?;

        if (actual_xkb_types.name != expected_xkb_types.name) {
            const expected_name = parsed.tokenString(expected_xkb_types.name);
            const actual_name = parsed.tokenString(actual_xkb_types.name);
            std.debug.print("expected token index {} (\"{}\"), instead found token index {} (\"{}\")\n", .{
                expected_xkb_types.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_types.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }

        if (actual_xkb_types.types.len != expected_xkb_types.types.len) {
            // TODO
        } else {
            for (actual_xkb_types.types, expected_xkb_types.types) |actual_type, expected_type| {
                if (actual_type.name != expected_type.name) {
                    const expected_name = parsed.tokenString(expected_type.name);
                    const actual_name = parsed.tokenString(actual_type.name);
                    std.debug.print("expected {} (\"{}\"), instead found {} (\"{}\")\n", .{
                        expected_type.name,
                        std.zig.fmtEscapes(expected_name),
                        actual_type.name,
                        std.zig.fmtEscapes(actual_name),
                    });
                    failed = true;
                }

                if (!xkb.AST.Modifiers.eql(actual_type.modifiers, expected_type.modifiers)) {
                    std.debug.print("expected {}, instead found {} \n", .{
                        expected_type.modifiers,
                        actual_type.modifiers,
                    });
                    failed = true;
                }

                const min_level_names_len = @min(expected_type.level_names.len, actual_type.level_names.len);
                for (expected_type.level_names[0..min_level_names_len], actual_type.level_names[0..min_level_names_len]) |expected_source_index, actual_source_index| {
                    if (actual_source_index != expected_source_index) {
                        const expected_level_name = parsed.tokenString(expected_source_index);
                        const actual_level_name = parsed.tokenString(actual_source_index);
                        std.debug.print("level_name: expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                            expected_source_index,
                            std.zig.fmtEscapes(expected_level_name),
                            actual_source_index,
                            std.zig.fmtEscapes(actual_level_name),
                        });
                        failed = true;
                    }
                }
                if (expected_type.level_names.len > actual_type.level_names.len) {
                    for (expected_type.level_names[min_level_names_len..]) |token_index| {
                        const level_name = parsed.tokenString(token_index);
                        std.debug.print("expected to find {} ({s}) as well\n", .{ token_index, level_name });
                    }
                    failed = true;
                } else if (expected_type.level_names.len < actual_type.level_names.len) {
                    for (actual_type.level_names[min_level_names_len..]) |token_index| {
                        const level_name = parsed.tokenString(token_index);
                        std.debug.print("expected to find {} ({s}) as well\n", .{ token_index, level_name });
                    }
                    failed = true;
                }
            }
        }
    }

    if (expected_parse.compatibility) |expected_xkb_compatibility| {
        const actual_xkb_compatibility = parsed.keymap.compatibility.?;

        if (actual_xkb_compatibility.name != expected_xkb_compatibility.name) {
            const expected_name = parsed.tokenString(expected_xkb_compatibility.name);
            const actual_name = parsed.tokenString(actual_xkb_compatibility.name);
            std.debug.print("expected source index {} (\"{}\"), instead found source index {} (\"{}\")\n", .{
                expected_xkb_compatibility.name,
                std.zig.fmtEscapes(expected_name),
                actual_xkb_compatibility.name,
                std.zig.fmtEscapes(actual_name),
            });
            failed = true;
        }
    }

    if (expected_parse.symbols) |expected_xkb_symbols| {
        const actual_xkb_symbols = parsed.keymap.symbols.?;

        if (actual_xkb_symbols.name != expected_xkb_symbols.name) {
            const expected_name = parsed.tokenString(expected_xkb_symbols.name);
            const actual_name = parsed.tokenString(actual_xkb_symbols.name);
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
    try expectParse(.{ .keycodes = null, .types = null, .compatibility = null, .symbols = null }, "xkb_keymap { };");

    try expectParse(.{
        .keycodes = .{ .name = @enumFromInt(3) },
        .types = .{ .name = @enumFromInt(8) },
        .compatibility = .{ .name = @enumFromInt(13) },
        .symbols = .{ .name = @enumFromInt(18), .keys = &.{} },
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
    try expectParse(.{
        .keycodes = .{
            .name = @enumFromInt(3),
            .keycodes = &.{
                .{ .keyname = @enumFromInt(5), .scancode = @enumFromInt(49) }, // "<TLDE>"
                .{ .keyname = @enumFromInt(9), .scancode = @enumFromInt(10) }, // "<AE01>"
            },
        },
        .types = null,
        .compatibility = null,
        .symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_keycodes "KEYS" {
        \\       <TLDE> = 49;
        \\       <AE01> = 10;
        \\   };
        \\};
    );

    try expectParse(.{
        .keycodes = .{
            .name = @enumFromInt(3),
            .keycodes = &.{
                .{ .keyname = @enumFromInt(5), .scancode = @enumFromInt(42) }, // <COMP> = 42
            },
            .aliases = &.{
                .{ .alias_keyname = @enumFromInt(10), .base_keyname = @enumFromInt(12) }, // <MENU> = <COMP>
            },
        },
        .types = null,
        .compatibility = null,
        .symbols = null,
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
        .keycodes = .{
            .name = @enumFromInt(3),
        },
        .types = null,
        .compatibility = null,
        .symbols = null,
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
    try expectParse(.{
        .keycodes = null,
        .types = .{
            .name = @enumFromInt(3), // "TYPES"
            .types = &.{
                .{ .name = @enumFromInt(6) }, // "FOUR_LEVEL"
            },
        },
        .compatibility = null,
        .symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       type "FOUR_LEVEL" { };
        \\   };
        \\};
    );

    try expectParse(.{
        .keycodes = null,
        .types = .{
            .name = @enumFromInt(3), // "TYPES"
            .types = &.{
                .{
                    .name = @enumFromInt(9), // "TYPE"
                    .modifiers = .{ .real = .{ .shift = true, .lock = true }, .virtual = 0b1 },
                },
            },
        },
        .compatibility = null,
        .symbols = null,
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
        .keycodes = null,
        .types = .{
            .name = @enumFromInt(3), // "TYPES"
        },
        .compatibility = null,
        .symbols = null,
    },
        \\xkb_keymap {
        \\    xkb_types "TYPES" {
        \\       virtual_modifiers NumLock,Alt,LevelThree,LevelFive,Meta,Super,Hyper,ScrollLock;
        \\   };
        \\};
    );

    try expectParse(.{
        .keycodes = null,
        .types = .{
            .name = @enumFromInt(3), // "TYPES"
            .types = &.{
                .{
                    .name = @enumFromInt(6), // "ALPHABETIC"
                    .modifiers = .{ .real = .{ .shift = true, .lock = true } },
                    .modifier_mappings = &.{
                        .{ .modifiers = .{ .real = .{} }, .level_index = 1 },
                        .{ .modifiers = .{ .real = .{ .shift = true } }, .level_index = 2 },
                        .{ .modifiers = .{ .real = .{ .lock = true } }, .level_index = 2 },
                        .{ .modifiers = .{ .real = .{ .shift = true, .lock = true } }, .level_index = 2 },
                    },
                    .level_names = &.{
                        @enumFromInt(49), // "Base"
                        @enumFromInt(56), // "Caps",
                    },
                },
            },
        },
        .compatibility = null,
        .symbols = null,
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
        .keycodes = null,
        .types = .{
            .name = @enumFromInt(3), // "TYPES"
            .types = &.{
                .{
                    .name = @enumFromInt(6), // "PRESERVED"
                    .modifiers = .{ .real = .{ .control = true, .shift = true } },
                },
            },
        },
        .compatibility = null,
        .symbols = null,
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

const TokenIndex = xkb.AST.TokenIndex;
const SourceIndex = xkb.AST.SourceIndex;

const xkb = @import("./xkb.zig");
const std = @import("std");

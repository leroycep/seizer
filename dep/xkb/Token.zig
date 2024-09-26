source_index: SourceIndex,
type: Type,

const Token = @This();

pub const SourceIndex = enum(u32) { _ };

pub fn isIdentifierCharacter(character: u8) bool {
    switch (character) {
        'A'...'Z',
        'a'...'z',
        '0'...'9',
        '_',
        => return true,
        else => return false,
    }
}

pub const Type = enum {
    end_of_file,

    // characters
    exclaim,
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
    hexadecimal_integer,
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
    symbols,
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
    AnyOfOrNone,
    AnyOf,
    NoneOf,
    AllOf,
    Exactly,

    // Key actions keywords
    NoAction,
    SetMods,
    LatchMods,
    LockMods,
    SetGroup,
    LatchGroup,
    LockGroup,
    MovePointer,
    PointerButton,
    LockPointerButton,
    SetPointerDefault,
    SetControls,
    LockControls,
    TerminateServer,
    SwitchScreen,
    Private,

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
        .symbols,
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
        .AnyOfOrNone,
        .AnyOf,
        .NoneOf,
        .AllOf,
        .Exactly,
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
        .{ .literal = "Any", .type = .AnyOf },
        .{ .literal = "MovePtr", .type = .MovePointer },
        .{ .literal = "PtrBtn", .type = .PointerButton },
        .{ .literal = "LockPtrBtn", .type = .LockPointerButton },
        .{ .literal = "SetPtrDflt", .type = .SetPointerDefault },
        .{ .literal = "Terminate", .type = .TerminateServer },
    };
};

pub fn string(source: []const u8, source_index: SourceIndex) ![]const u8 {
    var source_index_mut = @intFromEnum(source_index);
    const token = try next(source, &source_index_mut);
    return source[@intFromEnum(token.source_index)..source_index_mut];
}

pub fn next(source: []const u8, source_index: *u32) !Token {
    while (true) {
        if (source_index.* >= source.len) {
            return Token{
                .source_index = @enumFromInt(source_index.*),
                .type = .end_of_file,
            };
        }
        const index_before_switch_case = source_index.*;
        switch (source[source_index.*]) {
            0 => {
                return Token{
                    .source_index = @enumFromInt(source_index.*),
                    .type = .end_of_file,
                };
            },
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
            '!' => {
                const token = Token{
                    .source_index = @enumFromInt(source_index.*),
                    .type = .exclaim,
                };
                source_index.* += 1;
                return token;
            },
            '+' => {
                const start_index = source_index.*;

                switch (source[source_index.* + 1]) {
                    '0'...'9' => {
                        // TODO: handle floats and hexadecimal?
                        const end_index = std.mem.indexOfNonePos(u8, source, source_index.* + 1, "0123456789") orelse source.len;

                        const token = Token{
                            .source_index = @enumFromInt(start_index),
                            .type = .integer,
                        };
                        source_index.* = @intCast(end_index);

                        return token;
                    },
                    else => {
                        const token = Token{
                            .source_index = @enumFromInt(source_index.*),
                            .type = .plus,
                        };
                        source_index.* += 1;
                        return token;
                    },
                }
            },
            '0'...'9', '-' => {
                const start_index = source_index.*;

                // TODO: handle floats and hexadecimal?
                const end_index = std.mem.indexOfNonePos(u8, source, source_index.* + 1, "0123456789") orelse source.len;
                if (source[end_index] == 'x' or source[end_index] == 'X') {
                    const hexadecimal_end = std.mem.indexOfNonePos(u8, source, end_index + 1, "0123456789abcdefABCDEF") orelse source.len;

                    const token = Token{
                        .source_index = @enumFromInt(start_index),
                        .type = .hexadecimal_integer,
                    };
                    source_index.* = @intCast(hexadecimal_end);

                    return token;
                }

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
                    if (std.mem.startsWith(u8, source[source_index.*..], literal) and !Token.isIdentifierCharacter(source[source_index.* + literal.len])) {
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
                    if (std.mem.startsWith(u8, source[source_index.*..], literal) and !Token.isIdentifierCharacter(source[source_index.* + literal.len])) {
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
        const start_of_line = std.mem.lastIndexOfScalar(u8, source[0..index_before_switch_case], '\n') orelse 0;
        const end_of_line = std.mem.indexOfScalarPos(u8, source, source_index.*, '\n') orelse source.len;
        std.debug.panic("Unhandled case: '{}'\n    \"{}\"\n", .{ std.zig.fmtEscapes(source[source_index.* .. source_index.* + 1]), std.zig.fmtEscapes(source[start_of_line..end_of_line]) });
    }
}

const std = @import("std");

pub const Button = enum {
    a,
    b,
    x,
    y,
    leftshoulder,
    rightshoulder,
    back,
    start,
    guide,
    leftstick,
    rightstick,
    dpup,
    dpdown,
    dpleft,
    dpright,
    misc1,
    paddle1,
    paddle2,
    paddle3,
    paddle4,
    touchpad,
    misc2,
    misc3,
    misc4,
    misc5,
    misc6,
};

pub const Axis = enum {
    leftx,
    lefty,
    rightx,
    righty,
    lefttrigger,
    righttrigger,
};

pub const Platform = enum {
    @"Mac OS X",
    Linux,
    Windows,
    Android,
    iOS,
};

/// SDL2 gamepad mapping format
pub const Mapping = struct {
    guid: u128,
    name_buffer: [128]u8,
    platform: Platform,
    // platform_buffer: [32]u8,
    buttons: [32]?Output = [_]?Output{null} ** 32,
    axes: [6]?AxisElement = [_]?AxisElement{null} ** 6,
    hats: [6][4]?Output = [1][4]?Output{[1]?Output{null} ** 4} ** 6,

    pub fn name(this: *const @This()) []const u8 {
        const sentinel_index = std.mem.indexOfScalar(u8, this.name_buffer[0..], 0) orelse this.name_buffer.len;
        return this.name_buffer[0..sentinel_index];
    }

    pub fn platform(this: *const @This()) []const u8 {
        const sentinel_index = std.mem.indexOfScalar(u8, this.platform_buffer[0..], 0) orelse this.platform_buffer.len;
        return this.platform_buffer[0..sentinel_index];
    }

    pub const AxisElement = struct {
        min: i16,
        max: i16,
        output: Output,
    };

    pub const Input = union(Tag) {
        button: u8,
        axis: struct { index: u8, min: i16, max: i16 },
        hat: struct { index: u8, mask: u16 },

        pub const Tag = enum(u8) {
            button = 'b',
            axis = 'a',
            hat = 'h',
        };

        pub fn parse(element_str: []const u8) !Input {
            var minimum: i16 = std.math.minInt(i16);
            var maximum: i16 = std.math.maxInt(i16);

            var current_str = element_str;
            if (current_str[0] == '+') {
                minimum = 0;
                current_str = current_str[1..];
            } else if (current_str[0] == '-') {
                maximum = 0;
                current_str = current_str[1..];
            }

            const in_type = try std.meta.intToEnum(Tag, current_str[0]);
            current_str = current_str[1..];
            switch (in_type) {
                .button => {
                    const index = try std.fmt.parseInt(u8, current_str, 10);

                    return Input{ .button = index };
                },
                .axis => {
                    const inverted = current_str[current_str.len - 1] == '~';
                    if (inverted) {
                        current_str = current_str[0 .. current_str.len - 1];
                    }
                    const index = try std.fmt.parseInt(u8, current_str, 10);

                    return Input{ .axis = .{
                        .index = index,
                        .min = if (inverted) maximum else minimum,
                        .max = if (inverted) minimum else maximum,
                    } };
                },
                .hat => {
                    const index_of_period = std.mem.indexOfScalar(u8, current_str, '.') orelse return error.InvalidFormat;

                    const hat_index_str = current_str[0..index_of_period];
                    const hat_bit_str = current_str[index_of_period + 1 ..];

                    const hat_index = try std.fmt.parseInt(u4, hat_index_str, 10);
                    const hat_bit = try std.fmt.parseInt(u4, hat_bit_str, 10);

                    return Input{ .hat = .{
                        .index = hat_index,
                        .mask = hat_bit,
                    } };
                },
            }
        }
    };
    pub const Output = union(enum) {
        button: Button,
        axis: struct { axis: Axis, min: i16, max: i16 },

        pub fn parse(output_str: []const u8) !Output {
            var minimum: i16 = std.math.minInt(i16);
            var maximum: i16 = std.math.maxInt(i16);

            var current_str = output_str;
            if (current_str[0] == '+') {
                minimum = 0;
                current_str = current_str[1..];
            } else if (current_str[0] == '-') {
                maximum = 0;
                current_str = current_str[1..];
            }

            if (std.meta.stringToEnum(Button, current_str)) |btn| {
                return Output{ .button = btn };
            } else if (std.meta.stringToEnum(Axis, current_str)) |axis| {
                switch (axis) {
                    .lefttrigger, .righttrigger => return Output{ .axis = .{ .axis = axis, .min = 0, .max = std.math.maxInt(i16) } },
                    else => return Output{ .axis = .{ .axis = axis, .min = minimum, .max = maximum } },
                }
            } else {
                return error.UnknownOutput;
            }
        }
    };

    pub fn parse(mapping_str: []const u8) !Mapping {
        var mapping: Mapping = undefined;
        @memset(&mapping.buttons, null);
        @memset(&mapping.axes, null);

        var csv_iter = std.mem.splitScalar(u8, mapping_str, ',');

        const guid_str = csv_iter.next() orelse return error.InvalidFormat;
        if (std.mem.eql(u8, guid_str, "xinput")) {
            mapping.guid = 0;
            for (std.mem.asBytes(&mapping.guid)[0..guid_str.len], guid_str) |*b, c| {
                b.* = c;
            }
        } else {
            if (guid_str.len != 32) return error.InvalidFormat;

            mapping.guid = try std.fmt.parseInt(u128, guid_str, 16);
        }

        const name_slice = csv_iter.next() orelse return error.InvalidFormat;
        const name_trunc_len = @min(name_slice.len, mapping.name_buffer.len);
        @memcpy(mapping.name_buffer[0..name_trunc_len], name_slice[0..name_trunc_len]);
        @memset(mapping.name_buffer[name_trunc_len..], 0);

        while (csv_iter.next()) |kv_str| {
            if (kv_str.len == 0) continue;

            const colon_index = std.mem.indexOfScalar(u8, kv_str, ':') orelse return error.InvalidFormat;
            const key = kv_str[0..colon_index];
            const value = kv_str[colon_index + 1 ..];

            if (std.mem.eql(u8, key, "platform")) {
                mapping.platform = std.meta.stringToEnum(Platform, value) orelse return error.InvalidPlatform;
                continue;
            }

            const output = Output.parse(key) catch |err| {
                switch (err) {
                    error.UnknownOutput => continue,
                    else => return err,
                }
            };
            const input = try Input.parse(value);

            switch (input) {
                .button => |i| if (i < mapping.buttons.len) {
                    mapping.buttons[i] = output;
                },
                .axis => |axis| if (axis.index < mapping.axes.len) {
                    mapping.axes[axis.index] = .{ .min = axis.min, .max = axis.max, .output = output };
                },
                .hat => |hat| if (hat.index < mapping.axes.len) {
                    switch (hat.mask) {
                        1 => mapping.hats[hat.index][0] = output,
                        2 => mapping.hats[hat.index][1] = output,
                        4 => mapping.hats[hat.index][2] = output,
                        8 => mapping.hats[hat.index][3] = output,
                        else => return error.Unimplemented,
                    }
                },
            }
        }

        return mapping;
    }
};

test "parse example mapping" {
    if (true) return error.SkipZigTest;
    const mapping_str =
        \\030000004c050000c405000000010000,PS4 Controller,a:b1,b:b2,back:b8,dpdown:h0.4,dpleft:h0.8,dpright:h0.2,dpup:h0.1,guide:b12,leftshoulder:b4,leftstick:b10,lefttrigger:a3,leftx:a0,lefty:a1,rightshoulder:b5,rightstick:b11,righttrigger:a4,rightx:a2,righty:a5,start:b9,x:b0,y:b3,platform:Mac OS X,
    ;
    const parsed = try Mapping.parse(mapping_str);
    try std.testing.expectEqual(@as(u128, 0x030000004c050000c405000000010000), parsed.guid);
    try std.testing.expectEqualStrings("PS4 Controller", parsed.name());
    try std.testing.expectEqual(Platform.@"Mac OS X", parsed.platform);
    try std.testing.expectEqualSlices(Mapping.Element, &.{
        .{ .input = .{ .button = 1 }, .output = .{ .button = .a } },
        .{ .input = .{ .button = 2 }, .output = .{ .button = .b } },
        .{ .input = .{ .button = 8 }, .output = .{ .button = .back } },
        .{ .input = .{ .hat = .{ .index = 0, .mask = 0b0100 } }, .output = .{ .button = .dpdown } },
        .{ .input = .{ .hat = .{ .index = 0, .mask = 0b1000 } }, .output = .{ .button = .dpleft } },
        .{ .input = .{ .hat = .{ .index = 0, .mask = 0b0010 } }, .output = .{ .button = .dpright } },
        .{ .input = .{ .hat = .{ .index = 0, .mask = 0b0001 } }, .output = .{ .button = .dpup } },
        .{ .input = .{ .button = 12 }, .output = .{ .button = .guide } },
        .{ .input = .{ .button = 4 }, .output = .{ .button = .leftshoulder } },
        .{ .input = .{ .button = 10 }, .output = .{ .button = .leftstick } },
        .{ .input = .{ .axis = .{ .index = 3, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .lefttrigger, .min = 0, .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .axis = .{ .index = 0, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .leftx, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .axis = .{ .index = 1, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .lefty, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .button = 5 }, .output = .{ .button = .rightshoulder } },
        .{ .input = .{ .button = 11 }, .output = .{ .button = .rightstick } },
        .{ .input = .{ .axis = .{ .index = 4, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .righttrigger, .min = 0, .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .axis = .{ .index = 2, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .rightx, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .axis = .{ .index = 5, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } }, .output = .{ .axis = .{ .axis = .righty, .min = std.math.minInt(i16), .max = std.math.maxInt(i16) } } },
        .{ .input = .{ .button = 9 }, .output = .{ .button = .start } },
        .{ .input = .{ .button = 0 }, .output = .{ .button = .x } },
        .{ .input = .{ .button = 3 }, .output = .{ .button = .y } },
    }, parsed.elements.slice());
}

pub const DB = struct {
    allocator: std.mem.Allocator,
    mappings: std.AutoHashMapUnmanaged(u128, Mapping),

    pub const InitOptions = struct {
        load_embedded_db: bool = true,
        load_from_env_vars: bool = true,
        print_errors: bool = true,
    };

    pub fn init(allocator: std.mem.Allocator, options: InitOptions) !DB {
        var this = DB{
            .allocator = allocator,
            .mappings = .{},
        };
        errdefer this.deinit();

        if (options.load_embedded_db) {
            const gamecontrollerdb_text = @embedFile("gamecontrollerdb.txt");
            _ = try this.loadGameControllerConfig(gamecontrollerdb_text, null);
        }

        if (options.load_from_env_vars) {
            var parse_diagnostics = ParseDiagnostics{ .errors = std.ArrayList(ParseDiagnostics.ErrorTrace).init(this.allocator) };

            update_gamepad_mappings_file: {
                const sdl_controller_config_filepath = std.process.getEnvVarOwned(allocator, "SDL_GAMECONTROLLERCONFIG_FILE") catch break :update_gamepad_mappings_file;
                defer allocator.free(sdl_controller_config_filepath);

                std.log.debug("Loading gamepad mappings from file: \"{}\"", .{std.zig.fmtEscapes(sdl_controller_config_filepath)});

                const controller_config_data = std.fs.cwd().readFileAllocOptions(
                    allocator,
                    sdl_controller_config_filepath,
                    512 * 1024 * 1024,
                    null,
                    @alignOf(u8),
                    0,
                ) catch break :update_gamepad_mappings_file;
                defer allocator.free(controller_config_data);

                if (try this.loadGameControllerConfig(controller_config_data, &parse_diagnostics)) {
                    defer parse_diagnostics.errors.deinit();
                    for (parse_diagnostics.errors.items) |trace| {
                        log.warn("failed to parse controller config {s}:{} = \"{}\"\n", .{ sdl_controller_config_filepath, trace.line_number, std.zig.fmtEscapes(trace.line) });
                    }
                }
            }
            update_gamepad_mappings: {
                const sdl_controller_config = std.process.getEnvVarOwned(allocator, "SDL_GAMECONTROLLERCONFIG") catch break :update_gamepad_mappings;
                defer allocator.free(sdl_controller_config);

                std.log.debug("Loading gamepad mappings from environment variable", .{});

                if (try this.loadGameControllerConfig(sdl_controller_config, &parse_diagnostics)) {
                    defer parse_diagnostics.errors.deinit();
                    for (parse_diagnostics.errors.items) |trace| {
                        log.warn("failed to parse controller config {s}:{} = \"{}\"\n", .{ "SDL_GAMECONTROLLERCONFIG", trace.line_number, std.zig.fmtEscapes(trace.line) });
                    }
                }
            }
        }

        return this;
    }

    pub fn deinit(this: *@This()) void {
        this.mappings.deinit(this.allocator);
    }

    const ParseDiagnostics = struct {
        errors: std.ArrayList(ErrorTrace),

        pub const ErrorTrace = struct {
            @"error": anyerror,
            line: []const u8,
            line_number: u32,
        };
    };

    pub fn loadGameControllerConfig(this: *@This(), gamecontrollerconfig: []const u8, diagnostics: ?*ParseDiagnostics) !bool {
        var line_iter = std.mem.splitAny(u8, gamecontrollerconfig, "\n");
        var line_num: u32 = 1;
        var was_error = false;
        while (line_iter.next()) |line| : (line_num += 1) {
            if (line.len == 0 or line[0] == '#') continue;
            const mapping = Mapping.parse(line) catch |e| {
                was_error = true;
                if (diagnostics) |d| {
                    const trace = ParseDiagnostics.ErrorTrace{
                        .@"error" = e,
                        .line = line,
                        .line_number = line_num,
                    };
                    d.errors.append(trace) catch {};
                }
                continue;
            };
            try this.mappings.put(this.allocator, mapping.guid, mapping);
        }

        return was_error;
    }
};

test "parse gamecontrollerdb.txt" {
    const gamecontrollerdb_text = @embedFile("gamecontrollerdb.txt");

    var db = try DB.init(std.testing.allocator, .{ .load_from_env_vars = false, .load_embedded_db = false });
    defer db.deinit();
    var diagnostics = DB.ParseDiagnostics{ .errors = std.ArrayList(DB.ParseDiagnostics.ErrorTrace).init(std.testing.allocator) };
    if (try db.loadGameControllerConfig(gamecontrollerdb_text, &diagnostics)) {
        for (diagnostics.errors.items) |trace| {
            std.debug.print("line {?} = \"{?}\"\n", .{ trace.line_number, std.zig.fmtEscapes(trace.line.?) });
        }
    }
}

const log = std.log.scoped(.seizer_gamepad);
const std = @import("std");

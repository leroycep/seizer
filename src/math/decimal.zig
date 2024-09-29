pub const Digit = enum(u4) {
    @"0" = 0,
    @"1" = 1,
    @"2" = 2,
    @"3" = 3,
    @"4" = 4,
    @"5" = 5,
    @"6" = 6,
    @"7" = 7,
    @"8" = 8,
    @"9" = 9,

    pub fn fromSmallU3(digit: u3) @This() {
        return @enumFromInt(digit);
    }

    pub fn toSmallU3(this: @This()) u3 {
        return @intCast(@intFromEnum(this));
    }

    pub fn fromBigU1(digit: u1) @This() {
        return switch (digit) {
            0 => .@"8",
            1 => .@"9",
        };
    }

    pub fn toBigU1(this: @This()) u1 {
        return switch (this) {
            .@"8" => 0,
            .@"9" => 1,
            else => std.debug.panic("invalid value {} for big u1 encoding", .{this}),
        };
    }

    pub fn toASCII(this: @This()) u7 {
        return switch (this) {
            .@"0" => '0',
            .@"1" => '1',
            .@"2" => '2',
            .@"3" => '3',
            .@"4" => '4',
            .@"5" => '5',
            .@"6" => '6',
            .@"7" => '7',
            .@"8" => '8',
            .@"9" => '9',
        };
    }

    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0) {
            try writer.writeByte(this.toASCII());
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }
};

/// Densely Packed Decimal Declet
pub const Declet = packed struct(u10) {
    bits: u10,

    fn asDigitArray(this: @This()) [3]Digit {
        switch (@as(u1, @truncate(this.bits >> 3))) {
            0 => return [3]Digit{
                Digit.fromSmallU3(@truncate(this.bits >> 7)),
                Digit.fromSmallU3(@truncate(this.bits >> 4)),
                Digit.fromSmallU3(@truncate(this.bits)),
            },
            1 => switch (@as(u2, @truncate(this.bits >> 1))) {
                0b00 => return [3]Digit{
                    Digit.fromSmallU3(@truncate(this.bits >> 7)),
                    Digit.fromSmallU3(@truncate(this.bits >> 4)),
                    Digit.fromBigU1(@truncate(this.bits)),
                },
                0b01 => return [3]Digit{
                    Digit.fromSmallU3(@truncate(this.bits >> 7)),
                    Digit.fromBigU1(@truncate(this.bits >> 4)),
                    Digit.fromSmallU3((@as(u3, @truncate(this.bits >> 4)) & 0b110) | (@as(u3, @truncate(this.bits)) & 0b1)),
                },
                0b10 => return [3]Digit{
                    Digit.fromBigU1(@truncate(this.bits >> 7)),
                    Digit.fromSmallU3(@truncate(this.bits >> 4)),
                    Digit.fromSmallU3((@as(u3, @truncate(this.bits >> 7)) & 0b110) | (@as(u3, @truncate(this.bits)) & 0b1)),
                },
                0b11 => switch (@as(u2, @truncate(this.bits >> 5))) {
                    0b00 => return [3]Digit{
                        Digit.fromBigU1(@truncate(this.bits >> 7)),
                        Digit.fromBigU1(@truncate(this.bits >> 4)),
                        Digit.fromSmallU3((@as(u3, @truncate(this.bits >> 7)) & 0b110) | (@as(u3, @truncate(this.bits)) & 0b1)),
                    },
                    0b01 => return [3]Digit{
                        Digit.fromBigU1(@truncate(this.bits >> 7)),
                        Digit.fromSmallU3((@as(u3, @truncate(this.bits >> 7)) & 0b110) | (@as(u3, @truncate(this.bits >> 4)) & 0b1)),
                        Digit.fromBigU1(@truncate(this.bits)),
                    },
                    0b10 => return [3]Digit{
                        Digit.fromSmallU3(@truncate(this.bits >> 7)),
                        Digit.fromBigU1(@truncate(this.bits >> 4)),
                        Digit.fromBigU1(@truncate(this.bits)),
                    },
                    0b11 => return [3]Digit{
                        Digit.fromBigU1(@truncate(this.bits >> 7)),
                        Digit.fromBigU1(@truncate(this.bits >> 4)),
                        Digit.fromBigU1(@truncate(this.bits)),
                    },
                },
            },
        }
    }

    test asDigitArray {
        try std.testing.expectEqualSlices(Digit, &.{ .@"0", .@"0", .@"0" }, &(Declet{ .bits = 0b000_000_0_000 }).asDigitArray());

        try std.testing.expectEqualSlices(Digit, &.{ .@"0", .@"0", .@"9" }, &(Declet{ .bits = 0b000_000_100_1 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"0", .@"9", .@"0" }, &(Declet{ .bits = 0b000_00_1_101_0 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"9", .@"0", .@"0" }, &(Declet{ .bits = 0b00_1_000_110_0 }).asDigitArray());

        try std.testing.expectEqualSlices(Digit, &.{ .@"0", .@"8", .@"7" }, &(Declet{ .bits = 0b000_11_0_101_1 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"8", .@"0", .@"7" }, &(Declet{ .bits = 0b11_0_000_110_1 }).asDigitArray());

        try std.testing.expectEqualSlices(Digit, &.{ .@"9", .@"9", .@"0" }, &(Declet{ .bits = 0b00_1_00_1_111_0 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"9", .@"0", .@"9" }, &(Declet{ .bits = 0b00_1_01_0_111_1 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"0", .@"9", .@"9" }, &(Declet{ .bits = 0b000_10_1_111_1 }).asDigitArray());

        try std.testing.expectEqualSlices(Digit, &.{ .@"8", .@"8", .@"7" }, &(Declet{ .bits = 0b11_0_00_0_111_1 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"8", .@"7", .@"8" }, &(Declet{ .bits = 0b11_0_01_1_111_0 }).asDigitArray());
        try std.testing.expectEqualSlices(Digit, &.{ .@"7", .@"8", .@"8" }, &(Declet{ .bits = 0b111_10_0_111_0 }).asDigitArray());

        try std.testing.expectEqualSlices(Digit, &.{ .@"9", .@"9", .@"9" }, &(Declet{ .bits = 0b00_1_11_1_111_1 }).asDigitArray());
    }

    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        if (fmt.len == 0) {
            switch (@as(u1, @truncate(this.bits >> 3))) {
                0 => {
                    try writer.writeByte(Digit.fromSmallU3(@truncate(this.bits >> 7)).toASCII());
                    try writer.writeByte(Digit.fromSmallU3(@truncate(this.bits >> 4)).toASCII());
                    try writer.writeByte(Digit.fromSmallU3(@truncate(this.bits)).toASCII());
                },
                1 => switch (@as(u2, @truncate(this.bits >> 1))) {
                    0b00 => {
                        try writer.writeByte(Digit.fromSmallU3(@truncate(this.bits >> 7)).toASCII());
                        try writer.writeByte(Digit.fromSmallU3(@truncate(this.bits >> 4)).toASCII());
                        try writer.writeByte(Digit.fromBigU1(@truncate(this.bits)).toASCII());
                    },
                    0b01 => @panic("unimplemented"),
                    0b10 => @panic("unimplemented"),
                    0b11 => switch (@as(u2, @truncate(this.bits >> 5))) {
                        0b00 => @panic("unimplemented"),
                        0b01 => @panic("unimplemented"),
                        0b10 => @panic("unimplemented"),
                        0b11 => @panic("unimplemented"),
                    },
                },
            }
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }
};

/// https://en.wikipedia.org/wiki/Decimal32_floating-point_format
/// Densely Packed Decimal
pub const Decimal32DPD = packed struct(u32) {
    declet0: Declet,
    declet1: Declet,
    combination: u11,
    sign: i1,

    // pub fn fromDigits(is_negative: bool, leading_value: Digit, fractional_digits: [6]Digit, exponent: i8) @This() {
    //     std.debug.assert(exponent >= -95);
    //     std.debug.assert(exponent <= 96);
    //     const exponent_biased: u16 = @intCast(@as(i16, exponent) + 101);
    //     return @This(){
    //         .sign = if (is_negative) 1 else 0,
    //         .combination = ,
    //     };
    // }

    // pub fn fromInts(significand: i21, exponent: i8) @This() {
    //     std.debug.assert(exponent >= -101);
    //     std.debug.assert(exponent <= 90);
    //     const exponent_biased: u8 = @intCast(@as(i16, exponent) + 101);
    //     return @This(){
    //         .sign = if (std.math.signbit(significand)) 1 else 0,
    //         .combination = switch (exponent_biased) {
    //             0...101 => {},
    //             else => unreachable,
    //         },
    //     };
    // }

    pub const CombinationValue = union(enum) {
        finite: struct {
            exponent: i8,
            leading_significand_digit: Digit,
        },
        infinite,
        nan,
    };

    pub fn getCombinationValue(this: @This()) CombinationValue {
        const ExponentBits = packed struct(u8) {
            lsbs: u6,
            msbs: u2,

            pub fn toI8(exponent_bits: @This()) i8 {
                const value: i16 = @as(u8, @bitCast(exponent_bits));
                return @intCast(value - 101);
            }
        };
        switch (@as(u2, @truncate(this.combination >> 9))) {
            else => |exponent_msbs| return CombinationValue{
                .finite = .{
                    .exponent = (ExponentBits{ .msbs = exponent_msbs, .lsbs = @truncate(this.combination) }).toI8(),
                    .leading_significand_digit = Digit.fromSmallU3(@truncate(this.combination >> 6)),
                },
            },
            0b11 => switch (@as(u2, @truncate(this.combination >> 7))) {
                else => |exponent_msbs| return CombinationValue{
                    .finite = .{
                        .exponent = (ExponentBits{ .msbs = exponent_msbs, .lsbs = @truncate(this.combination) }).toI8(),
                        .leading_significand_digit = Digit.fromBigU1(@truncate((this.combination >> 6) & 0b1)),
                    },
                },
                0b11 => switch (@as(u1, @truncate(this.combination >> 6))) {
                    0 => return .infinite,
                    1 => return .nan,
                },
            },
        }
    }

    fn significandAsDigitArray(this: @This()) ?[7]Digit {
        switch (this.getCombinationValue()) {
            .finite => |finite| {
                return [1]Digit{finite.leading_significand_digit} ++
                    this.declet1.asDigitArray() ++
                    this.declet0.asDigitArray();
            },
            else => return null,
        }
    }

    pub fn format(
        this: @This(),
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        _ = options;
        const combination_value = this.getCombinationValue();
        if (fmt.len == 0 or comptime std.mem.eql(u8, fmt, "e")) {
            switch (combination_value) {
                .finite => |finite| {
                    if (this.sign == -1) {
                        try writer.writeAll("-");
                    }
                    const digits = this.significandAsDigitArray().?;

                    const first_nonzero_index = for (digits, 0..) |digit, i| {
                        if (digit == .@"0") continue;
                        break i;
                    } else digits.len;

                    if (first_nonzero_index == digits.len) {
                        try writer.writeByte(Digit.@"0".toASCII());
                    } else {
                        for (digits[first_nonzero_index..]) |digit| {
                            try writer.writeByte(digit.toASCII());
                        }
                    }
                    try writer.writeByte('e');
                    try std.fmt.formatInt(finite.exponent, 10, .lower, .{}, writer);
                },
                .infinite => switch (this.sign) {
                    0 => try writer.writeAll("inf"),
                    -1 => try writer.writeAll("-inf"),
                },
                .nan => try writer.writeAll("NaN"),
            }
        } else if (comptime std.mem.eql(u8, fmt, "d")) {
            switch (combination_value) {
                .finite => |finite| {
                    if (this.sign == -1) {
                        try writer.writeAll("-");
                    }
                    const digits = this.significandAsDigitArray().?;

                    const first_nonzero_index = for (digits, 0..) |digit, i| {
                        if (digit == .@"0") continue;
                        break i;
                    } else digits.len;

                    if (first_nonzero_index == digits.len) {
                        try writer.writeByte(Digit.@"0".toASCII());
                        return;
                    }

                    if (finite.exponent >= 0) {
                        for (digits[first_nonzero_index..]) |digit| {
                            try writer.writeByte(digit.toASCII());
                        }
                        for (0..@intCast(finite.exponent)) |_| {
                            try writer.writeByte(Digit.@"0".toASCII());
                        }
                    } else if (@abs(finite.exponent) >= (digits.len - first_nonzero_index)) {
                        try writer.writeByte(Digit.@"0".toASCII());
                        try writer.writeByte('.');

                        const zeroes_before_significand: usize = @intCast(@abs(finite.exponent) - (digits.len - first_nonzero_index));
                        for (0..zeroes_before_significand) |_| {
                            try writer.writeByte(Digit.@"0".toASCII());
                        }

                        for (digits[first_nonzero_index..]) |digit| {
                            try writer.writeByte(digit.toASCII());
                        }
                    }
                },
                .infinite => switch (this.sign) {
                    0 => try writer.writeAll("inf"),
                    -1 => try writer.writeAll("-inf"),
                },
                .nan => try writer.writeAll("NaN"),
            }
        } else {
            @compileError("unknown format character: '" ++ fmt ++ "'");
        }
    }

    fn expectEqualBits(a: Decimal32DPD, b: Decimal32DPD) !void {
        const a_bits: u32 = @bitCast(a);
        const b_bits: u32 = @bitCast(b);
        if (a_bits != b_bits) {
            std.debug.print("Expected {b} {b:0>11} {} {}\n", .{ a.sign, a.combination, a.declet1, a.declet0 });
            std.debug.print("   Found {b} {b:0>11} {} {}\n", .{ b.sign, b.combination, b.declet1, b.declet0 });
            return error.ExpectedEqual;
        }
    }

    test "u32 bitcast" {
        try expectEqualBits(
            Decimal32DPD{ .sign = 0, .combination = 0b01_000_100101, .declet1 = .{ .bits = 0 }, .declet0 = .{ .bits = 1 } },
            @bitCast(@as(u32, 0b0_01_000_100101_0000000000_0000000001)),
        );
    }

    test "calculator exponential formatting" {
        try std.testing.expectFmt("1e-1", "{e}", .{Decimal32DPD{ .sign = 0, .combination = 0b01_000_100100, .declet1 = .{ .bits = 0 }, .declet0 = .{ .bits = 1 } }});
    }

    test "decimal formatting" {
        try std.testing.expectFmt("0.1", "{d}", .{Decimal32DPD{ .sign = 0, .combination = 0b01_000_100100, .declet1 = .{ .bits = 0 }, .declet0 = .{ .bits = 1 } }});
        try std.testing.expectFmt("100", "{d}", .{Decimal32DPD{ .sign = 0, .combination = 0b01_000_100111, .declet1 = .{ .bits = 0 }, .declet0 = .{ .bits = 1 } }});
        try std.testing.expectFmt("9001", "{d}", .{Decimal32DPD{ .sign = 0, .combination = 0b01_000_100101, .declet1 = .{ .bits = 0b000_000_100_1 }, .declet0 = .{ .bits = 0b000_000_0_001 } }});
        try std.testing.expectFmt("999", "{d}", .{Decimal32DPD{ .sign = 0, .combination = 0b01_000_100101, .declet1 = .{ .bits = 0 }, .declet0 = .{ .bits = 0b00_1_11_1_111_1 } }});
    }
};

comptime {
    _ = Digit;
    _ = Declet;
    _ = Decimal32DPD;
}

const std = @import("std");

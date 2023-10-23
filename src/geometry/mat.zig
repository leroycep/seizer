//! Matrix math operations

pub fn mul(comptime M: usize, comptime N: usize, comptime P: usize, comptime T: type, a: [N][M]T, b: [P][N]T) [P][M]T {
    var res: [P][M]T = undefined;

    for (&res, 0..) |*column, i| {
        for (column, 0..) |*c, j| {
            var va: @Vector(N, T) = undefined;
            comptime var k: usize = 0;
            inline while (k < N) : (k += 1) {
                va[k] = a[k][j];
            }

            const vb: @Vector(N, T) = b[i];

            c.* = @reduce(.Add, va * vb);
        }
    }

    return res;
}

const std = @import("std");

test mul {
    try std.testing.expectEqualDeep([3][4]f32{
        .{ 5, 8, 6, 11 },
        .{ 4, 9, 5, 9 },
        .{ 3, 5, 3, 6 },
    }, mul(
        4,
        3,
        3,
        f32,
        .{
            .{ 1, 2, 0, 1 },
            .{ 0, 1, 1, 1 },
            .{ 1, 1, 1, 2 },
        },
        .{
            .{ 1, 2, 4 },
            .{ 2, 3, 2 },
            .{ 1, 1, 2 },
        },
    ));

    try std.testing.expectEqualDeep([1][4]f32{
        .{ 1, 2, 3, 4 },
    }, mul(
        4,
        4,
        1,
        f32,
        .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 0, 0, 0, 1 },
        },
        .{
            .{ 1, 2, 3, 4 },
        },
    ));

    try std.testing.expectEqualDeep([4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 7, 9, 11, 1 },
    }, mul(
        4,
        4,
        4,
        f32,
        .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 2, 3, 4, 1 },
        },
        .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 5, 6, 7, 1 },
        },
    ));

    try std.testing.expectEqualDeep([4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 5, 6, 7, 0 },
    }, mul(
        4,
        4,
        4,
        f32,
        .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 2, 3, 4, 0 },
        },
        .{
            .{ 1, 0, 0, 0 },
            .{ 0, 1, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ 5, 6, 7, 0 },
        },
    ));
}

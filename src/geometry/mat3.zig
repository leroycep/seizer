pub fn identity(comptime T: type) [3][3]T {
    return .{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        .{ 0, 0, 1 },
    };
}

pub fn mulVec(comptime T: type, a: [3][3]T, b: [3]T) [3]T {
    return mat.mul(3, 3, 1, T, a, .{b})[0];
}

pub fn mul(comptime T: type, a: [3][3]T, b: [3][3]T) [3][3]T {
    return mat.mul(3, 3, 3, T, a, b);
}

/// Multiply all matrices in a list together
pub fn mulAll(comptime T: type, matrices: []const [3][3]T) [3][3]T {
    var res: [3][3]T = matrices[matrices.len - 1];

    for (0..matrices.len - 1) |i| {
        const inverse_i = (matrices.len - 2) - i;
        const left_matrix = matrices[inverse_i];
        res = mul(T, left_matrix, res);
    }

    return res;
}

pub fn translate(comptime T: type, translation: [2]T) [3][3]T {
    return .{
        .{ 1, 0, 0 },
        .{ 0, 1, 0 },
        translation ++ .{1},
    };
}

pub fn scale(comptime T: type, scaling: [2]T) [3][3]T {
    return .{
        .{ scaling[0], 0, 0 },
        .{ 0, scaling[1], 0 },
        .{ 0, 0, 1 },
    };
}

pub fn rotate(comptime T: type, turns: T) [3][3]T {
    return .{
        .{ @cos(turns * std.math.tau), @sin(turns * std.math.tau), 0 },
        .{ -@sin(turns * std.math.tau), @cos(turns * std.math.tau), 0 },
        .{ 0, 0, 1 },
    };
}

pub fn shear(comptime T: type, turns: [2]T) [3][3]T {
    return .{
        .{ 1, @tan(turns[1] * std.math.tau), 0 },
        .{ @tan(turns[0] * std.math.tau), 1, 0 },
        .{ 0, 0, 1 },
    };
}

pub fn orthographic(comptime T: type, left: T, right: T, bottom: T, top: T) [3][3]T {
    const widthRatio = 1 / (right - left);
    const heightRatio = 1 / (top - bottom);
    const tx = -(right + left) * widthRatio;
    const ty = -(top + bottom) * heightRatio;
    return .{
        .{ 2 * widthRatio, 0, 0 },
        .{ 0, 2 * heightRatio, 0 },
        .{ tx, ty, 1 },
    };
}

const std = @import("std");
const vec = @import("./vec.zig");
const mat = @import("./mat.zig");

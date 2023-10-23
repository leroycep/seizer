pub fn cross(comptime T: type, a: [3]T, b: [3]T) [3]T {
    return .{
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    };
}

test cross {
    try std.testing.expectEqualSlices(f32, &.{ 0, 1, 0 }, &cross(f32, .{ 0, 0, 1 }, .{ 1, 0, 0 }));
}

pub fn magnitude(comptime D: usize, comptime T: type, vector: @Vector(D, T)) T {
    return @sqrt(@reduce(.Add, vector * vector));
}

test magnitude {
    try std.testing.expectEqual(@as(f32, 1.0), magnitude(2, f32, .{ 0, 1 }));
    try std.testing.expectEqual(@as(f32, @sqrt(2.0)), magnitude(2, f32, .{ 1, 1 }));
    try std.testing.expectEqual(@as(f32, @sqrt(2.0)), magnitude(2, f32, .{ 1, -1 }));
}

pub fn normalize(comptime D: usize, comptime T: type, vector: @Vector(D, T)) @Vector(D, T) {
    return vector / @as(@Vector(D, T), @splat(magnitude(D, T, vector)));
}

test normalize {
    try std.testing.expectEqual(@Vector(2, f32){ 0, 1 }, normalize(2, f32, .{ 0, 10 }));
    try std.testing.expectEqual(@Vector(2, f32){ 1.0 / @sqrt(2.0), 1.0 / @sqrt(2.0) }, normalize(2, f32, .{ 5, 5 }));
}

const std = @import("std");

//! Defines geometry primitives

pub const mat4 = @import("./geometry/mat4.zig");
pub const vec = @import("./geometry/mat4.zig");

pub fn Rect(comptime T: type) type {
    return struct {
        pos: [2]T,
        size: [2]T,

        pub fn contains(this: @This(), point: [2]T) bool {
            return point[0] >= this.pos[0] and
                point[1] >= this.pos[1] and
                point[0] <= this.pos[0] + this.size[0] and
                point[1] <= this.pos[1] + this.size[1];
        }

        pub fn topLeft(this: @This()) [2]T {
            return this.pos;
        }

        pub fn bottomRight(this: @This()) [2]T {
            return [2]T{
                this.pos[0] + this.size[0],
                this.pos[1] + this.size[1],
            };
        }

        pub fn translate(this: @This(), amount: [2]T) @This() {
            return @This(){
                .pos = [2]T{
                    this.pos[0] + amount[0],
                    this.pos[1] + amount[1],
                },
                .size = this.size,
            };
        }
    };
}

// Defines a rectangular region, like a `Rect`, but stores the min and max coordinates instead of the
// position and size.
pub fn AABB(comptime T: type) type {
    return struct {
        min: [2]T,
        max: [2]T,

        pub fn contains(this: @This(), point: [2]T) bool {
            return point[0] >= this.min[0] and
                point[1] >= this.min[1] and
                point[0] <= this.max[0] and
                point[1] <= this.max[1];
        }

        pub fn topLeft(this: @This()) [2]T {
            return this.min;
        }

        pub fn bottomRight(this: @This()) [2]T {
            return this.max;
        }
    };
}

/// Defines a rectangular region relative to another rectangular region. In this case the numbers
/// represent how far inside another rectangle the min and max positions are.
pub fn Inset(comptime T: type) type {
    return struct {
        /// How far inward from the top left corner is this Inset?
        min: [2]T,
        /// How far inward from the bottom right corner is this Inset?
        max: [2]T,

        /// Gives the extra size that this inset would add, or a negative number if it would decrease
        /// the size.
        pub fn size(this: @This()) [2]f32 {
            return .{
                this.min[0] + this.max[0],
                this.min[1] + this.max[1],
            };
        }
    };
}

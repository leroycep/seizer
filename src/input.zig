pub const gamepad = @import("./input/gamepad.zig");
pub const keyboard = @import("./input/keyboard.zig");
pub const mouse = @import("./input/mouse.zig");

pub const Event = union(enum) {
    hover: Hover,
    click: Click,
    scroll: Scroll,
    text: Text,
    key: Key,

    pub const Hover = struct {
        pos: [2]f32,
        modifiers: mouse.Modifiers,

        pub fn transform(hover: Hover, transform_matrix: [4][4]f32) Hover {
            const transformed_pos = seizer.geometry.mat4.mulVec(f32, transform_matrix, .{
                hover.pos[0],
                hover.pos[1],
                0,
                1,
            })[0..2].*;
            return Hover{ .pos = transformed_pos, .modifiers = hover.modifiers };
        }
    };

    pub const Click = struct {
        pos: [2]f32,
        button: mouse.Button,
        pressed: bool,

        pub fn transform(click: Click, transform_matrix: [4][4]f32) Click {
            const transformed_pos = seizer.geometry.mat4.mulVec(f32, transform_matrix, .{
                click.pos[0],
                click.pos[1],
                0,
                1,
            })[0..2].*;
            return Click{
                .pos = transformed_pos,
                .button = click.button,
                .pressed = click.pressed,
            };
        }
    };

    pub const Scroll = struct {
        offset: [2]f32,
    };

    pub const Text = struct {
        text: std.BoundedArray(u8, 16),
    };

    pub const Key = struct {
        key: keyboard.Key,
        scancode: keyboard.Scancode,
        action: keyboard.Action,
        mods: keyboard.Modifiers,
    };

    pub fn transform(this: Event, matrix: [4][4]f32) Event {
        return switch (this) {
            .hover => |hover| .{ .hover = hover.transform(matrix) },
            .click => |click| .{ .click = click.transform(matrix) },
            else => this,
        };
    }
};

const seizer = @import("./seizer.zig");
const std = @import("std");

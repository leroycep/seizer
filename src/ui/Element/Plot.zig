stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,

lines: std.StringArrayHashMapUnmanaged(Line) = .{},
x_range: [2]f32 = .{ -1, 1 },
y_range: [2]f32 = .{ -1, 1 },
y_axis_type: AxisType = .linear,

pan_start: ?[2]f32 = null,

hovered_x: f32 = 0,
x_view_range: ?[2]f32 = null,
drag_start_pos: ?[2]f32 = null,

bg_color: [4]u8 = .{ 0x00, 0x00, 0x00, 0xFF },

output_size: [2]f32 = .{ 0, 0 },

pub const Line = struct {
    offset: [2]f32 = .{ 0, 0 },
    x: std.ArrayListUnmanaged(f32) = .{},
    y: std.ArrayListUnmanaged(f32) = .{},
    color: [4]u8 = .{ 0xFF, 0xFF, 0xFF, 0xFF },
};

pub const AxisType = enum {
    linear,
    log,
};

pub fn create(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .stage = stage,
    };
    return this;
}

pub fn element(this: *@This()) Element {
    return .{
        .ptr = this,
        .interface = &INTERFACE,
    };
}

const INTERFACE = Element.Interface.getTypeErasedFunctions(@This(), .{
    .acquire_fn = acquire,
    .release_fn = release,
    .set_parent_fn = setParent,
    .get_parent_fn = getParent,

    .process_event_fn = processEvent,
    .get_min_size_fn = getMinSize,
    .layout_fn = layout,
    .render_fn = render,
});

fn acquire(this: *@This()) void {
    this.reference_count += 1;
}

fn release(this: *@This()) void {
    this.reference_count -= 1;
    if (this.reference_count == 0) {
        for (this.lines.keys(), this.lines.values()) |title, *line| {
            this.stage.gpa.free(title);
            line.x.deinit(this.stage.gpa);
            line.y.deinit(this.stage.gpa);
        }

        this.lines.deinit(this.stage.gpa);

        this.stage.gpa.destroy(this);
    }
}

fn setParent(this: *@This(), new_parent: ?Element) void {
    this.parent = new_parent;
}

fn getParent(this: *@This()) ?Element {
    return this.parent;
}

fn processEvent(this: *@This(), event: seizer.input.Event) ?Element {
    switch (event) {
        .hover => |hover| {
            if (this.pan_start) |start| {
                const size = if (this.x_view_range) |vr| vr[1] - vr[0] else this.x_range[1] - this.x_range[0];

                const inverse = rangeTransformInverse(
                    this.output_size,
                    .{ .linear, this.y_axis_type },
                    .{
                        start[0],
                        this.y_range[0],
                    },
                    .{
                        start[0] + size,
                        this.y_range[1],
                    },
                );

                const new_min = seizer.geometry.mat4.mulVec(f32, inverse, .{
                    -hover.pos[0],
                    -hover.pos[1],
                    0,
                    1,
                })[0..2].*;

                this.x_view_range = [2]f32{
                    new_min[0],
                    new_min[0] + size,
                };
            }

            const inverse = rangeTransformInverse(
                this.output_size,
                .{ .linear, this.y_axis_type },
                .{
                    if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                    this.y_range[0],
                },
                .{
                    if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                    this.y_range[1],
                },
            );

            this.hovered_x = seizer.geometry.mat4.mulVec(f32, inverse, .{ hover.pos[0], 0, 0, 1 })[0];

            return this.element();
        },
        .click => |click| {
            switch (click.button) {
                .left => {
                    if (this.x_view_range) |_| {
                        this.x_view_range = null;

                        const inverse = rangeTransformInverse(
                            this.output_size,
                            .{ .linear, this.y_axis_type },
                            .{ this.x_range[0], this.y_range[0] },
                            .{ this.x_range[1], this.y_range[1] },
                        );

                        this.hovered_x = seizer.geometry.mat4.mulVec(f32, inverse, .{ click.pos[0], 0, 0, 1 })[0];

                        return this.element();
                    }

                    const inverse = rangeTransformInverse(
                        this.output_size,
                        .{ .linear, this.y_axis_type },
                        .{
                            if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                            this.y_range[0],
                        },
                        .{
                            if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                            this.y_range[1],
                        },
                    );
                    const pos = seizer.geometry.mat4.mulVec(f32, inverse, .{
                        click.pos[0],
                        click.pos[1],
                        0,
                        1,
                    })[0..2].*;

                    if (click.pressed) {
                        this.drag_start_pos = pos;

                        this.stage.capturePointer(this.element());
                    } else if (this.drag_start_pos) |start_pos| {
                        this.stage.releasePointer(this.element());

                        this.x_view_range = .{ @min(start_pos[0], pos[0]), @max(start_pos[0], pos[0]) };

                        // update hovered position
                        const new_transform = rangeTransform(
                            this.output_size,
                            .{ .linear, this.y_axis_type },
                            .{
                                if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                                this.y_range[0],
                            },
                            .{
                                if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                                this.y_range[1],
                            },
                        );
                        this.hovered_x = seizer.geometry.mat4.mulVec(f32, new_transform, .{
                            click.pos[0],
                            click.pos[1],
                            0,
                            1,
                        })[0];

                        this.drag_start_pos = null;
                    }
                },

                .middle => {
                    if (click.pressed) {
                        const inverse = rangeTransformInverse(
                            this.output_size,
                            .{ .linear, this.y_axis_type },
                            .{
                                if (this.x_view_range) |vr| vr[0] else this.x_range[0],
                                this.y_range[0],
                            },
                            .{
                                if (this.x_view_range) |vr| vr[1] else this.x_range[1],
                                this.y_range[1],
                            },
                        );

                        this.pan_start = seizer.geometry.mat4.mulVec(f32, inverse, .{
                            click.pos[0],
                            click.pos[1],
                            0,
                            1,
                        })[0..2].*;

                        this.stage.capturePointer(this.element());
                    } else {
                        this.pan_start = null;
                        this.stage.releasePointer(this.element());
                    }
                },

                else => {},
            }
        },
        else => {},
    }

    return this.element();
}

pub fn getMinSize(this: *@This()) [2]f32 {
    _ = this;
    return .{ 1, 1 };
}

pub fn layout(this: *@This(), min_size: [2]f32, max_size: [2]f32) [2]f32 {
    _ = min_size;
    this.output_size = max_size;
    return max_size;
}

fn render(this: *@This(), parent_canvas: Canvas.Transformed, rect: Rect) void {
    parent_canvas.rect(rect.pos, rect.size, .{
        .color = this.bg_color,
    });

    const canvas = parent_canvas
        .scissored(rect);

    // transform before sending the points to the canvas so that line size is the same size regardless of zoom
    const transform = rangeTransform(
        rect.size,
        .{ .linear, this.y_axis_type },
        .{
            if (this.x_view_range) |vr| vr[0] else this.x_range[0],
            this.y_range[0],
        },
        .{
            if (this.x_view_range) |vr| vr[1] else this.x_range[1],
            this.y_range[1],
        },
    );

    for (this.lines.values()) |line| {
        if (line.x.items.len < 2 or line.y.items.len < 2) continue;
        for (line.x.items[0 .. line.x.items.len - 1], line.x.items[1..], line.y.items[0 .. line.y.items.len - 1], line.y.items[1..]) |x0, x1, y0_raw, y1_raw| {
            const y0 = switch (this.y_axis_type) {
                .linear => y0_raw,
                .log => @log(y0_raw),
            };
            const y1 = switch (this.y_axis_type) {
                .linear => y1_raw,
                .log => @log(y1_raw),
            };

            const line_pos0 = seizer.geometry.mat4.mulVec(f32, transform, .{ x0 + line.offset[0], y0, 0, 1 })[0..2].*;
            const line_pos1 = seizer.geometry.mat4.mulVec(f32, transform, .{ x1 + line.offset[0], y1, 0, 1 })[0..2].*;

            canvas.line(
                .{ rect.pos[0] + line_pos0[0], rect.pos[1] + line_pos0[1] },
                .{ rect.pos[0] + line_pos1[0], rect.pos[1] + line_pos1[1] },
                .{ .width = 1.5, .color = line.color },
            );
        }
    }

    const hover_hline_pos = seizer.geometry.mat4.mulVec(f32, transform, .{ this.hovered_x, 0, 0, 1 })[0..2].*;
    if (this.drag_start_pos) |start_pos| {
        const drag_pos = seizer.geometry.mat4.mulVec(f32, transform, .{ start_pos[0], 0, 0, 1 })[0..2].*;
        canvas.rect(
            .{ rect.pos[0] + drag_pos[0], rect.pos[1] },
            .{ hover_hline_pos[0] - drag_pos[0], rect.size[1] },
            .{ .color = .{ 0xFF, 0xFF, 0x00, 0x80 } },
        );
    }
    if (std.meta.eql(this.stage.hovered_element, this.element())) {
        canvas.line(
            .{ rect.pos[0] + hover_hline_pos[0], rect.pos[1] },
            .{ rect.pos[0] + hover_hline_pos[0], rect.pos[1] + rect.size[1] },
            .{ .color = .{ 0xFF, 0xFF, 0x00, 0xFF } },
        );
    }
}

pub fn rangeTransform(out_size: [2]f32, axis_types: [2]AxisType, min_coord_raw: [2]f32, max_coord_raw: [2]f32) [4][4]f32 {
    const min_coord = [2]f32{
        switch (axis_types[0]) {
            .linear => min_coord_raw[0],
            .log => @log(min_coord_raw[0]),
        },
        switch (axis_types[1]) {
            .linear => min_coord_raw[1],
            .log => @log(min_coord_raw[1]),
        },
    };

    const size = [2]f32{
        switch (axis_types[0]) {
            .linear => max_coord_raw[0] - min_coord_raw[0],
            .log => @log(max_coord_raw[0]) - @log(min_coord_raw[1]),
        },
        switch (axis_types[1]) {
            .linear => max_coord_raw[1] - min_coord_raw[1],
            .log => @log(max_coord_raw[1]) - @log(min_coord_raw[1]),
        },
    };

    return seizer.geometry.mat4.mulAll(
        f32,
        &.{
            seizer.geometry.mat4.scale(f32, .{
                1,
                -1,
                1,
            }),
            seizer.geometry.mat4.translate(f32, .{
                0,
                -out_size[1],
                0,
            }),
            seizer.geometry.mat4.scale(f32, .{
                out_size[0] / size[0],
                out_size[1] / size[1],
                1,
            }),
            seizer.geometry.mat4.translate(f32, .{
                -min_coord[0],
                -min_coord[1],
                0,
            }),
        },
    );
}

pub fn rangeTransformInverse(out_size: [2]f32, axis_types: [2]AxisType, min_coord_raw: [2]f32, max_coord_raw: [2]f32) [4][4]f32 {
    const min_coord = [2]f32{
        switch (axis_types[0]) {
            .linear => min_coord_raw[0],
            .log => @log(min_coord_raw[0]),
        },
        switch (axis_types[1]) {
            .linear => min_coord_raw[1],
            .log => @log(min_coord_raw[1]),
        },
    };

    const size = [2]f32{
        switch (axis_types[0]) {
            .linear => max_coord_raw[0] - min_coord_raw[0],
            .log => @log(max_coord_raw[0]) - @log(min_coord_raw[1]),
        },
        switch (axis_types[1]) {
            .linear => max_coord_raw[1] - min_coord_raw[1],
            .log => @log(max_coord_raw[1]) - @log(min_coord_raw[1]),
        },
    };

    return seizer.geometry.mat4.mulAll(
        f32,
        &.{
            seizer.geometry.mat4.translate(f32, .{
                min_coord[0],
                min_coord[1],
                0,
            }),
            seizer.geometry.mat4.scale(f32, .{
                size[0] / out_size[0],
                size[1] / out_size[1],
                1,
            }),
            seizer.geometry.mat4.translate(f32, .{
                0,
                out_size[1],
                0,
            }),
            seizer.geometry.mat4.scale(f32, .{
                1,
                -1,
                1,
            }),
        },
    );
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.ui.Rect;
const Canvas = seizer.Canvas;
const std = @import("std");

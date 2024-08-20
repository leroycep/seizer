stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,

children: std.ArrayListUnmanaged(Child) = .{},
direction: Direction = .column,
justification: Justification = .start,
cross_align: CrossAlign = .start,

pub const Direction = enum {
    row,
    column,
};

pub const Justification = enum {
    start,
    center,
    space_between,
    end,
};

pub const CrossAlign = enum {
    start,
    center,
    end,
};

pub const Child = struct {
    rect: Rect,
    element: Element,
};

pub fn create(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .stage = stage,
    };
    return this;
}

pub fn appendChild(this: *@This(), child: Element) !void {
    try this.children.append(this.stage.gpa, .{ .rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } }, .element = child });
    child.acquire();
    child.setParent(this.element());
    this.stage.needs_layout = true;
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
        for (this.children.items) |child| {
            child.element.release();
        }
        this.children.deinit(this.stage.gpa);
        this.stage.gpa.destroy(this);
    }
}

fn setParent(this: *@This(), new_parent: ?Element) void {
    this.parent = new_parent;
}

fn getParent(this: *@This()) ?Element {
    return this.parent;
}

fn processEvent(this: *@This(), event: seizer.input.Event, transform: [4][4]f32) ?Element.Capture {
    switch (event) {
        .hover => |hover| {
            const hover_pos = seizer.geometry.mat4.mulVec(f32, transform, hover.pos ++ .{ 0, 1 })[0..2].*;
            for (this.children.items) |child| {
                if (child.rect.contains(hover_pos)) {
                    const child_transform = seizer.geometry.mat4.mul(f32, transform, seizer.geometry.mat4.translate(f32, .{
                        -child.rect.pos[0],
                        -child.rect.pos[1],
                        0,
                    }));

                    if (child.element.processEvent(event, child_transform)) |hovered| {
                        return hovered;
                    }
                }
            }
        },
        .click => |click| {
            const click_pos = seizer.geometry.mat4.mulVec(f32, transform, click.pos ++ .{ 0, 1 })[0..2].*;
            for (this.children.items) |child| {
                if (child.rect.contains(click_pos)) {
                    const child_transform = seizer.geometry.mat4.mul(f32, transform, seizer.geometry.mat4.translate(f32, .{
                        -child.rect.pos[0],
                        -child.rect.pos[1],
                        0,
                    }));

                    if (child.element.processEvent(event, child_transform)) |clicked| {
                        return clicked;
                    }
                }
            }
        },
        else => {},
    }
    return null;
}

pub fn getMinSize(this: *@This()) [2]f32 {
    const main_axis: usize = switch (this.direction) {
        .row => 0,
        .column => 1,
    };
    const cross_axis: usize = switch (this.direction) {
        .row => 1,
        .column => 0,
    };

    var min_size = [2]f32{ 0, 0 };
    for (this.children.items) |child| {
        const child_min = child.element.getMinSize();

        min_size[main_axis] += child_min[main_axis];
        min_size[cross_axis] = @max(min_size[cross_axis], child_min[cross_axis]);
    }
    return min_size;
}

pub fn layout(this: *@This(), min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const content_min_size = this.getMinSize();

    const main_axis: usize = switch (this.direction) {
        .row => 0,
        .column => 1,
    };
    const cross_axis: usize = switch (this.direction) {
        .row => 1,
        .column => 0,
    };

    // Do a first pass where we divide the space equally between the children
    const main_equal_space_per_child = max_size[main_axis] / @as(f32, @floatFromInt(this.children.items.len));

    var main_space_used: f32 = 0;
    var cross_min_width: f32 = min_size[cross_axis];
    var children_requesting_space: f32 = 0;
    for (this.children.items) |*child| {
        var constraint_min: [2]f32 = undefined;
        var constraint_max: [2]f32 = undefined;

        constraint_min[main_axis] = 0;
        constraint_min[cross_axis] = cross_min_width;

        constraint_max[main_axis] = main_equal_space_per_child;
        constraint_max[cross_axis] = max_size[cross_axis];

        child.rect.size = child.element.layout(constraint_min, constraint_max);
        if (child.rect.size[main_axis] >= main_equal_space_per_child) {
            children_requesting_space += 1;
        }

        main_space_used += child.rect.size[main_axis];
        cross_min_width = @max(cross_min_width, child.rect.size[cross_axis]);
    }

    // Do a second pass where we allocate more space to any children that used their full amount of space
    const MAX_ITERATIONS = 10;
    var iterations: usize = 0;
    while (main_space_used < max_size[main_axis] and children_requesting_space >= 0 and iterations < MAX_ITERATIONS) : (iterations += 1) {
        const main_space_per_grow = (max_size[main_axis] - main_space_used) / children_requesting_space;

        main_space_used = 0;
        cross_min_width = min_size[cross_axis];
        children_requesting_space = 0;
        for (this.children.items) |*child| {
            var constraint_min: [2]f32 = undefined;
            var constraint_max: [2]f32 = undefined;

            constraint_min[main_axis] = child.rect.size[main_axis];
            constraint_min[cross_axis] = child.rect.size[cross_axis];

            if (child.rect.size[main_axis] >= main_equal_space_per_child) {
                constraint_max[main_axis] = child.rect.size[main_axis] + main_space_per_grow;
            } else {
                constraint_max[main_axis] = child.rect.size[main_axis];
            }
            constraint_max[cross_axis] = max_size[cross_axis];

            child.rect.size = child.element.layout(constraint_min, constraint_max);
            if (child.rect.size[main_axis] >= main_equal_space_per_child) {
                children_requesting_space += 1;
            }

            main_space_used += child.rect.size[main_axis];
            cross_min_width = @max(cross_min_width, child.rect.size[cross_axis]);
        }
    }

    main_space_used = @max(content_min_size[main_axis], main_space_used);

    const num_items: f32 = @floatFromInt(this.children.items.len);

    const space_before: f32 = switch (this.justification) {
        .start, .space_between => 0,
        .center => (max_size[main_axis] - main_space_used) / 2,
        .end => max_size[main_axis] - main_space_used,
    };
    const space_between: f32 = switch (this.justification) {
        .start, .center, .end => 0,
        .space_between => (max_size[main_axis] - main_space_used) / @max(num_items - 1, 1),
    };
    const space_after: f32 = switch (this.justification) {
        .start => max_size[main_axis] - main_space_used,
        .center => (max_size[main_axis] - main_space_used) / 2,
        .space_between, .end => 0,
    };
    _ = space_after;

    const cross_axis_size = @min(max_size[cross_axis], cross_min_width);

    var main_pos: f32 = space_before;

    for (this.children.items) |*child| {
        child.rect.pos[main_axis] = main_pos;

        child.rect.pos[cross_axis] = switch (this.cross_align) {
            .start => 0,
            .center => (cross_axis_size - child.rect.size[cross_axis]) / 2,
            .end => cross_axis_size - child.rect.size[cross_axis],
        };

        main_pos += child.rect.size[main_axis] + space_between;
    }

    var bounds = [2]f32{ 0, 0 };
    bounds[main_axis] = max_size[main_axis];
    bounds[cross_axis] = cross_axis_size;
    return bounds;
}

fn render(this: *@This(), canvas: Canvas.Transformed, rect: Rect) void {
    for (this.children.items) |child| {
        child.element.render(canvas, .{
            .pos = .{
                rect.pos[0] + child.rect.pos[0],
                rect.pos[1] + child.rect.pos[1],
            },
            .size = child.rect.size,
        });
    }
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const std = @import("std");

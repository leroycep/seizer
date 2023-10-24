element: Element,
children: std.ArrayListUnmanaged(*Element) = .{},
direction: Direction = .column,
justification: Justification = .start,
cross_align: CrossAlign = .start,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .get_min_size_fn = getMinSize,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

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

pub fn new(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .element = .{
            .stage = stage,
            .interface = &INTERFACE,
        },
    };
    return this;
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    for (this.children.items) |child| {
        child.release();
    }
    this.children.deinit(this.element.stage.gpa);
    this.element.stage.gpa.destroy(this);
}

pub fn appendChild(this: *@This(), child: *Element) !void {
    try this.children.append(this.element.stage.gpa, child);
    child.acquire();
    child.parent = &this.element;
}

pub fn getMinSize(element: *Element) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

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
        const child_min = child.getMinSize();

        min_size[main_axis] += child_min[main_axis];
        min_size[cross_axis] = @max(min_size[cross_axis], child_min[cross_axis]);
    }
    return min_size;
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

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
    for (this.children.items) |child| {
        var constraint_min: [2]f32 = undefined;
        var constraint_max: [2]f32 = undefined;

        constraint_min[main_axis] = 0;
        constraint_min[cross_axis] = cross_min_width;

        constraint_max[main_axis] = main_equal_space_per_child;
        constraint_max[cross_axis] = max_size[cross_axis];

        child.rect.size = child.layout(constraint_min, constraint_max);
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
        for (this.children.items) |child| {
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

            child.rect.size = child.layout(constraint_min, constraint_max);
            if (child.rect.size[main_axis] >= main_equal_space_per_child) {
                children_requesting_space += 1;
            }

            main_space_used += child.rect.size[main_axis];
            cross_min_width = @max(cross_min_width, child.rect.size[cross_axis]);
        }
    }

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

    var main_pos: f32 = 0;
    main_pos += space_before;

    for (this.children.items) |child| {
        child.rect.pos[main_axis] = main_pos;

        child.rect.pos[cross_axis] = switch (this.cross_align) {
            .start => 0,
            .center => cross_min_width / 2 - child.rect.size[cross_axis] / 2,
            .end => cross_min_width - child.rect.size[cross_axis],
        };

        main_pos += child.rect.size[main_axis] + space_between;
    }

    var bounds = [2]f32{ 0, 0 };
    bounds[main_axis] = max_size[main_axis];
    bounds[cross_axis] = cross_min_width;
    return bounds;
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    for (this.children.items) |child| {
        child.render(canvas, .{
            .pos = .{
                rect.pos[0] + child.rect.pos[0],
                rect.pos[1] + child.rect.pos[1],
            },
            .size = child.rect.size,
        });
    }
}

fn onHover(element: *Element, pos_parent: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    const pos = .{
        pos_parent[0] - this.element.rect.pos[0],
        pos_parent[1] - this.element.rect.pos[1],
    };

    for (this.children.items) |child| {
        if (child.rect.contains(pos)) {
            if (child.onHover(pos)) |hovered| {
                return hovered;
            }
        }
    }
    return null;
}

fn onClick(element: *Element, event_parent: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const event = event_parent.translate(.{ -this.element.rect.pos[0], -this.element.rect.pos[1] });

    for (this.children.items) |child| {
        if (child.rect.contains(event.pos)) {
            if (child.onClick(event)) {
                return true;
            }
        }
    }

    return false;
}

const seizer = @import("../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const utils = @import("utils");
const std = @import("std");

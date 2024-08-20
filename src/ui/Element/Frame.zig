stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,
style: ui.Style,

child: ?Element = null,
child_rect: Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } },

pub fn create(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .stage = stage,
        .style = stage.default_style,
    };
    return this;
}

pub fn setChild(this: *@This(), new_child_opt: ?Element) void {
    if (new_child_opt) |new_child| {
        new_child.acquire();
    }
    if (this.child) |r| {
        r.release();
    }
    if (new_child_opt) |new_child| {
        new_child.setParent(this.element());
    }
    this.child = new_child_opt;
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
        if (this.child) |child| {
            child.release();
        }
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
    if (this.child == null) return null;

    const child_event = event.transform(seizer.geometry.mat4.translate(f32, .{
        -this.child_rect.pos[0],
        -this.child_rect.pos[1],
        0,
    }));

    switch (event) {
        .hover => |hover| {
            if (this.child_rect.contains(hover.pos)) {
                return this.child.?.processEvent(child_event);
            }
        },
        .click => |click| {
            if (this.child_rect.contains(click.pos)) {
                return this.child.?.processEvent(child_event);
            }
        },
        else => {},
    }
    return null;
}

fn getMinSize(this: *@This()) [2]f32 {
    const padding_size = this.style.padding.size();

    if (this.child) |child| {
        const child_size = child.getMinSize();
        return .{
            child_size[0] + padding_size[0],
            child_size[1] + padding_size[1],
        };
    }

    return padding_size;
}

pub fn layout(this: *@This(), min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const padding_size = this.style.padding.size();

    if (this.child) |child| {
        const child_size = child.layout(min_size, .{
            max_size[0] - padding_size[0],
            max_size[1] - padding_size[1],
        });
        this.child_rect = .{
            .pos = this.style.padding.min,
            .size = child_size,
        };
        return .{
            child_size[0] + padding_size[0],
            child_size[1] + padding_size[1],
        };
    }

    return padding_size;
}

fn render(this: *@This(), canvas: Canvas.Transformed, rect: Rect) void {
    this.style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = this.style.background_color,
    });

    if (this.child) |child| {
        child.render(canvas, .{
            .pos = .{
                rect.pos[0] + this.child_rect.pos[0],
                rect.pos[1] + this.child_rect.pos[1],
            },
            .size = this.child_rect.size,
        });
    }
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const std = @import("std");

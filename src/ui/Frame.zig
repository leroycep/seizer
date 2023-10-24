element: Element,
style: ui.Style,
child: ?*Element = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .get_min_size_fn = getMinSize,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
};

pub fn new(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .element = .{
            .stage = stage,
            .interface = &INTERFACE,
        },
        .style = stage.default_style,
    };
    return this;
}

pub fn setChild(this: *@This(), new_child_opt: ?*Element) void {
    if (new_child_opt) |new_child| {
        new_child.acquire();
    }
    if (this.child) |r| {
        r.release();
    }
    if (new_child_opt) |new_child| {
        new_child.parent = null;
    }
    this.child = new_child_opt;
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (this.child) |child| {
        child.release();
    }
    this.element.stage.gpa.destroy(this);
}

pub fn getMinSize(element: *Element) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

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

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;
    _ = max_size;

    const padding_size = this.style.padding.size();

    if (this.child) |child| {
        const child_size = child.getMinSize();
        _ = child.layout(child_size, child_size);
        child.rect = .{
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

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    this.style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = this.style.background_color,
    });

    if (this.child) |child| {
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

    if (this.child) |child| {
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

    if (this.child) |child| {
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

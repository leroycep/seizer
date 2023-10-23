element: Element,
text: []const u8,

style: ui.Style,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
};

pub fn new(stage: *ui.Stage, text: []const u8) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .element = .{
            .stage = stage,
            .interface = &INTERFACE,
        },
        .text = text,
        .style = stage.default_style,
    };
    return this;
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    this.element.stage.gpa.destroy(this);
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    _ = min_size;
    _ = max_size;

    const text_size = this.style.text_font.textSize(this.text, 1);

    return .{
        text_size[0] + this.style.padding.size()[0],
        text_size[1] + this.style.padding.size()[1],
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    this.style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = this.style.background_color,
    });

    _ = canvas.writeText(.{
        rect.pos[0] + this.style.padding.min[0],
        rect.pos[1] + this.style.padding.min[1],
    }, this.text, .{
        .color = this.style.text_color,
    });
}

const seizer = @import("../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const utils = @import("utils");
const std = @import("std");

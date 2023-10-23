element: Element,
text: []const u8,

default_style: ui.Style,
hovered_style: ui.Style,
clicked_style: ui.Style,

is_pressed: bool = false,
on_click: ?ui.Callable(fn (*@This()) void) = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .layout_fn = layout,
    .render_fn = render,
    .on_click_fn = onClick,
};

const RECT_COLOR_DEFAULT = [4]u8{ 0x30, 0x30, 0x30, 0xFF };
const RECT_COLOR_HOVERED = [4]u8{ 0x50, 0x50, 0x50, 0xFF };

const TEXT_COLOR_DEFAULT = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
const TEXT_COLOR_HOVERED = [4]u8{ 0xFF, 0xFF, 0x00, 0xFF };

pub fn new(stage: *ui.Stage, text: []const u8) !*@This() {
    const this = try stage.gpa.create(@This());
    const hovered_style = stage.default_style.with(.{
        .text_color = TEXT_COLOR_HOVERED,
        .background_color = RECT_COLOR_HOVERED,
    });
    this.* = .{
        .element = .{
            .stage = stage,
            .interface = &INTERFACE,
        },
        .text = text,
        .default_style = stage.default_style.with(.{
            .text_color = TEXT_COLOR_DEFAULT,
            .background_color = RECT_COLOR_DEFAULT,
        }),
        .hovered_style = hovered_style,
        .clicked_style = hovered_style,
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

    const is_hovered = this.element.stage.hovered_element == &this.element;
    const style = if (this.is_pressed) this.clicked_style else if (is_hovered) this.hovered_style else this.default_style;

    const text_size = style.text_font.textSize(this.text, 1);

    return .{
        text_size[0] + style.padding.size()[0],
        text_size[1] + style.padding.size()[1],
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);

    const is_hovered = this.element.stage.hovered_element == &this.element;
    const style = if (this.is_pressed) this.clicked_style else if (is_hovered) this.hovered_style else this.default_style;

    style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = style.background_color,
    });

    _ = canvas.writeText(.{
        rect.pos[0] + style.padding.min[0],
        rect.pos[1] + style.padding.min[1],
    }, this.text, .{
        .color = style.text_color,
    });
}

fn onClick(element: *Element, event: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr(@This(), "element", element);
    if (event.button == .left) {
        this.is_pressed = event.pressed;
    }

    if (!event.pressed or event.button != .left) return false;

    if (this.on_click) |on_click| {
        on_click.call(.{this});
    }

    return true;
}

const seizer = @import("../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const utils = @import("utils");
const std = @import("std");

stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,

text: std.ArrayListUnmanaged(u8),

default_style: ui.Style,
hovered_style: ui.Style,
clicked_style: ui.Style,

on_click: ?ui.Callable(fn (*@This()) void) = null,

const RECT_COLOR_DEFAULT = [4]u8{ 0x30, 0x30, 0x30, 0xFF };
const RECT_COLOR_HOVERED = [4]u8{ 0x50, 0x50, 0x50, 0xFF };

const TEXT_COLOR_DEFAULT = [4]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
const TEXT_COLOR_HOVERED = [4]u8{ 0xFF, 0xFF, 0x00, 0xFF };

pub fn create(stage: *ui.Stage, text: []const u8) !*@This() {
    const this = try stage.gpa.create(@This());
    const hovered_style = stage.default_style.with(.{
        .text_color = TEXT_COLOR_HOVERED,
        .background_color = RECT_COLOR_HOVERED,
    });

    var text_owned = std.ArrayListUnmanaged(u8){};
    errdefer text_owned.deinit(stage.gpa);
    try text_owned.appendSlice(stage.gpa, text);

    this.* = .{
        .stage = stage,
        .text = text_owned,
        .default_style = stage.default_style.with(.{
            .text_color = TEXT_COLOR_DEFAULT,
            .background_color = RECT_COLOR_DEFAULT,
        }),
        .hovered_style = hovered_style,
        .clicked_style = hovered_style,
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
    .render_fn = render,
});

fn acquire(this: *@This()) void {
    this.reference_count += 1;
}

fn release(this: *@This()) void {
    this.reference_count -= 1;
    if (this.reference_count == 0) {
        this.text.deinit(this.stage.gpa);
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
        .hover => return this.element(),
        .click => |click| {
            if (click.button == .left) {
                if (click.pressed) {
                    this.stage.capturePointer(this.element());

                    if (this.on_click) |on_click| {
                        on_click.call(.{this});
                    }
                } else {
                    this.stage.releasePointer(this.element());
                }
                return this.element();
            }
        },
        .key => |key| {
            switch (key.key) {
                .space, .enter => if (key.action == .press) {
                    this.stage.capturePointer(this.element());
                    if (this.on_click) |on_click| {
                        on_click.call(.{this});
                    }
                    return this.element();
                } else {
                    this.stage.releasePointer(this.element());
                },
                else => {},
            }
        },
        else => {},
    }

    return null;
}

pub fn getMinSize(this: *@This()) [2]f32 {
    const is_pressed = if (this.stage.pointer_capture_element) |pce| pce.ptr == this.element().ptr else false;
    const is_hovered = if (this.stage.hovered_element) |hovered| hovered.ptr == this.element().ptr else false;
    const style = if (is_pressed) this.clicked_style else if (is_hovered) this.hovered_style else this.default_style;

    const text_size = style.text_font.textSize(this.text.items, style.text_scale);
    return .{
        text_size[0] + style.padding.size()[0],
        text_size[1] + style.padding.size()[1],
    };
}

fn render(this: *@This(), canvas: Canvas.Transformed, rect: Rect) void {
    const is_pressed = if (this.stage.pointer_capture_element) |pce| pce.ptr == this.element().ptr else false;
    const is_hovered = if (this.stage.hovered_element) |hovered| hovered.ptr == this.element().ptr else false;
    const style = if (is_pressed) this.clicked_style else if (is_hovered) this.hovered_style else this.default_style;

    style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = style.background_color,
    });

    _ = canvas.writeText(.{
        rect.pos[0] + style.padding.min[0],
        rect.pos[1] + style.padding.min[1],
    }, this.text.items, .{
        .scale = style.text_scale,
        .color = style.text_color,
    });
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const std = @import("std");

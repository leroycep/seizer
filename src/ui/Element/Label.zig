stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,

text: []const u8,

style: ui.Style,

pub fn create(stage: *ui.Stage, text: []const u8) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .stage = stage,

        .text = text,
        .style = stage.default_style,
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
    _ = this;
    _ = event;
    _ = transform;
    return null;
}

fn getMinSize(this: *@This()) [2]f32 {
    const text_size = this.style.text_font.textSize(this.text, this.style.text_scale);
    return .{
        text_size[0] + this.style.padding.size()[0],
        text_size[1] + this.style.padding.size()[1],
    };
}

fn render(this: *@This(), canvas: Canvas.Transformed, rect: Rect) void {
    this.style.background_image.draw(canvas, rect, .{
        .scale = 1,
        .color = this.style.background_color,
    });

    _ = canvas.writeText(.{
        rect.pos[0] + this.style.padding.min[0],
        rect.pos[1] + this.style.padding.min[1],
    }, this.text, .{
        .scale = this.style.text_scale,
        .color = this.style.text_color,
    });
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const std = @import("std");

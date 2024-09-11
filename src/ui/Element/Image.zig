stage: *ui.Stage,
reference_count: usize = 1,
parent: ?Element = null,

texture: *seizer.Graphics.Texture,
texture_size: [2]u32,
source_rect: seizer.geometry.Rect(f32),

pub fn create(stage: *ui.Stage, texture: *seizer.Graphics.Texture, texture_size: [2]u32) !*@This() {
    const this = try stage.gpa.create(@This());
    errdefer stage.gpa.destroy(this);

    this.* = .{
        .stage = stage,

        .texture = texture,
        .texture_size = texture_size,
        .source_rect = .{
            .pos = .{ 0, 0 },
            .size = [2]f32{ @floatFromInt(texture_size[0]), @floatFromInt(texture_size[1]) },
        },
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

fn processEvent(this: *@This(), event: seizer.input.Event) ?Element {
    _ = this;
    _ = event;
    return null;
}

fn getMinSize(this: *@This()) [2]f32 {
    return this.source_rect.size;
}

fn render(this: *@This(), canvas: Canvas.Transformed, rect: Rect) void {
    const texture_sizef = [2]f32{
        @floatFromInt(this.texture_size[0]),
        @floatFromInt(this.texture_size[1]),
    };
    canvas.rect(rect.pos, this.source_rect.size, .{
        .texture = this.texture,
        .uv = .{
            .min = .{ this.source_rect.pos[0] / texture_sizef[0], this.source_rect.pos[1] / texture_sizef[1] },
            .max = .{ (this.source_rect.pos[0] + this.source_rect.size[0]) / texture_sizef[0], (this.source_rect.pos[1] + this.source_rect.size[1]) / texture_sizef[1] },
        },
    });
}

const seizer = @import("../../seizer.zig");
const ui = seizer.ui;
const Element = ui.Element;
const Rect = seizer.geometry.Rect(f32);
const Canvas = seizer.Canvas;
const std = @import("std");

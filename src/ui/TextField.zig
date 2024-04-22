element: Element,
text: std.ArrayListUnmanaged(u8) = .{},
/// Minimum width of the text area in ems.
width: f32 = 16,
cursor_pos: usize = 0,
selection_start: usize = 0,

default_style: ui.Style,
hovered_style: ui.Style,
focused_style: ui.Style,

on_enter: ?ui.Callable(fn (*@This()) void) = null,

const INTERFACE = Element.Interface{
    .destroy_fn = destroy,
    .get_min_size_fn = getMinSize,
    .layout_fn = layout,
    .render_fn = render,
    .on_hover_fn = onHover,
    .on_click_fn = onClick,
    .on_text_input_fn = onTextInput,
    .on_key_fn = onKey,
    .on_select_fn = onSelect,
};

pub fn new(stage: *ui.Stage) !*@This() {
    const this = try stage.gpa.create(@This());
    this.* = .{
        .element = .{
            .stage = stage,
            .interface = &INTERFACE,
        },
        .default_style = stage.default_style,
        .hovered_style = stage.default_style,
        .focused_style = stage.default_style,
    };
    return this;
}

pub fn destroy(element: *Element) void {
    const this: *@This() = @fieldParentPtr("element", element);
    this.text.clearAndFree(this.element.stage.gpa);
    this.cursor_pos = 0;
    this.selection_start = 0;
    this.element.stage.gpa.destroy(this);
}

const MARGIN = [2]f32{
    2,
    2,
};

pub fn getMinSize(element: *Element) [2]f32 {
    const this: *@This() = @fieldParentPtr("element", element);

    const is_hovered = this.element.stage.hovered_element == &this.element;
    const is_focused = this.element.stage.focused_element == &this.element;
    const style = if (is_focused) this.focused_style else if (is_hovered) this.hovered_style else this.default_style;

    return .{
        this.width * style.text_font.lineHeight * style.text_scale + style.padding.size()[0] + 2 * MARGIN[0],
        style.text_font.lineHeight * style.text_scale + style.padding.size()[1] + 2 * MARGIN[1],
    };
}

pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    const this: *@This() = @fieldParentPtr("element", element);
    _ = min_size;

    const is_hovered = this.element.stage.hovered_element == &this.element;
    const is_focused = this.element.stage.focused_element == &this.element;
    const style = if (is_focused) this.focused_style else if (is_hovered) this.hovered_style else this.default_style;

    return .{
        max_size[0],
        style.text_font.lineHeight * style.text_scale + style.padding.size()[1] + 2 * MARGIN[1],
    };
}

fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
    const this: *@This() = @fieldParentPtr("element", element);

    const is_hovered = this.element.stage.hovered_element == &this.element;
    const is_focused = this.element.stage.focused_element == &this.element;
    const style = if (is_focused) this.focused_style else if (is_hovered) this.hovered_style else this.default_style;

    style.background_image.draw(canvas, .{
        .pos = .{
            rect.pos[0] + MARGIN[0],
            rect.pos[1] + MARGIN[1],
        },
        .size = [2]f32{
            this.element.rect.size[0] - 2 * MARGIN[0],
            canvas.font.lineHeight * style.text_scale + style.padding.size()[1],
        },
    }, .{
        .scale = 1,
        .color = style.background_color,
    });

    const pre_cursor_size = style.text_font.textSize(this.text.items[0..this.cursor_pos], style.text_scale);

    const selection_start = @min(this.cursor_pos, this.selection_start);
    const selection_end = @max(this.cursor_pos, this.selection_start);

    const pre_selection_size = style.text_font.textSize(this.text.items[0..selection_start], style.text_scale);
    const selection_size = style.text_font.textSize(this.text.items[selection_start..selection_end], style.text_scale);

    canvas.pushScissor(.{
        rect.pos[0] + MARGIN[0],
        rect.pos[1] + MARGIN[1],
    }, .{
        this.element.rect.size[0] - 2 * MARGIN[0],
        style.text_font.lineHeight * style.text_scale + style.padding.size()[1],
    });
    defer canvas.popScissor();

    _ = canvas.writeText(.{
        rect.pos[0] + MARGIN[0] + style.padding.min[0],
        rect.pos[1] + MARGIN[1] + style.padding.min[1],
    }, this.text.items, .{
        .font = style.text_font,
        .scale = style.text_scale,
        .color = style.text_color,
    });
    if (is_focused) {
        canvas.rect(
            .{ rect.pos[0] + MARGIN[0] + style.padding.min[0] + pre_cursor_size[0], rect.pos[1] + MARGIN[1] + style.padding.min[1] },
            .{ style.text_scale, canvas.font.lineHeight * style.text_scale },
            .{
                .color = style.text_color,
            },
        );
        canvas.rect(
            .{ rect.pos[0] + MARGIN[0] + style.padding.min[0] + pre_selection_size[0], rect.pos[1] + MARGIN[1] + style.padding.min[1] },
            .{ selection_size[0], selection_size[1] },
            .{ .color = .{ 0xFF, 0xFF, 0xFF, 0xAA } },
        );
    }
}

fn onHover(element: *Element, pos_parent: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr("element", element);
    const pos = .{
        pos_parent[0] - this.element.rect.pos[0],
        pos_parent[1] - this.element.rect.pos[1],
    };

    const is_hovered = this.element.stage.focused_element == &this.element;
    const is_focused = this.element.stage.focused_element == &this.element;
    const style = if (is_focused) this.focused_style else if (is_hovered) this.hovered_style else this.default_style;

    if (this.element.stage.pointer_capture_element == &this.element) {
        const click_pos = [2]f32{
            pos[0] - MARGIN[0] - style.padding.min[0],
            pos[1] - MARGIN[1] - style.padding.min[1],
        };

        // check if the mouse is above or below the text field
        if (pos[1] < 0) {
            this.cursor_pos = 0;
            return &this.element;
        } else if (pos[1] > this.element.rect.size[1]) {
            this.cursor_pos = this.text.items.len;
            return &this.element;
        }

        // check if the mouse is to the left or the right of the text field
        if (pos[0] < 0) {
            this.cursor_pos = 0;
            return &this.element;
        } else if (pos[0] > this.element.rect.size[0]) {
            this.cursor_pos = this.text.items.len;
            return &this.element;
        }

        var layouter = style.text_font.textLayouter(style.text_scale);
        var prev_x: f32 = 0;
        for (this.text.items, 0..) |character, index| {
            layouter.addCharacter(character);
            if (click_pos[0] >= prev_x and click_pos[0] <= layouter.pos[0]) {
                const dist_prev = click_pos[0] - prev_x;
                const dist_this = layouter.pos[0] - click_pos[0];
                if (dist_prev < dist_this) {
                    this.cursor_pos = index;
                } else {
                    this.cursor_pos = index + 1;
                }
                break;
            }
            prev_x = layouter.pos[0];
        } else {
            this.cursor_pos = this.text.items.len;
        }
    }

    return &this.element;
}

fn onClick(element: *Element, event_parent: ui.event.Click) bool {
    const this: *@This() = @fieldParentPtr("element", element);

    const is_hovered = this.element.stage.focused_element == &this.element;
    const is_focused = this.element.stage.focused_element == &this.element;
    const style = if (is_focused) this.focused_style else if (is_hovered) this.hovered_style else this.default_style;

    const event = event_parent.translate(.{ -this.element.rect.pos[0], -this.element.rect.pos[1] });

    if (!event.pressed and event.button == .left and this.element.stage.pointer_capture_element == &this.element) {
        this.element.stage.pointer_capture_element = null;
    }
    if (!event.pressed or event.button != .left) return false;

    this.element.stage.focused_element = &this.element;
    this.element.stage.pointer_capture_element = &this.element;

    const click_pos = [2]f32{
        event.pos[0] - MARGIN[0] - style.padding.min[0],
        event.pos[1] - MARGIN[1] - style.padding.min[1],
    };

    var layouter = style.text_font.textLayouter(style.text_scale);
    var prev_x: f32 = 0;
    for (this.text.items, 0..) |character, index| {
        layouter.addCharacter(character);
        if (click_pos[0] >= prev_x and click_pos[0] <= layouter.pos[0]) {
            const dist_prev = click_pos[0] - prev_x;
            const dist_this = layouter.pos[0] - click_pos[0];
            if (dist_prev < dist_this) {
                this.selection_start = index;
                this.cursor_pos = index;
            } else {
                this.selection_start = index + 1;
                this.cursor_pos = index + 1;
            }
            break;
        }
        prev_x = layouter.pos[0];
    } else {
        this.selection_start = this.text.items.len;
        this.cursor_pos = this.text.items.len;
    }

    return true;
}

fn onTextInput(element: *Element, event: ui.event.TextInput) bool {
    const this: *@This() = @fieldParentPtr("element", element);

    // Delete any text that is currently selected
    const src_pos = @max(this.selection_start, this.cursor_pos);
    const overwrite_pos = @min(this.selection_start, this.cursor_pos);

    const bytes_removed = src_pos - overwrite_pos;
    std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
    this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

    this.cursor_pos = overwrite_pos;

    // Append new text
    this.text.insertSlice(this.element.stage.gpa, this.cursor_pos, event.text.slice()) catch @panic("OOM");
    this.cursor_pos += event.text.len;
    this.selection_start = this.cursor_pos;

    return true;
}

fn onKey(element: *Element, event: ui.event.Key) bool {
    const this: *@This() = @fieldParentPtr("element", element);
    if (this.element.stage.focused_element != &this.element) {
        // We don't want the TextField to absorb any other key events unless it is focused
        switch (event.key) {
            .enter => if (event.action == .press or event.action == .repeat) {
                this.element.stage.focused_element = &this.element;
                return true;
            },
            else => {},
        }
        return false;
    }
    switch (event.key) {
        .left => if (event.action == .press or event.action == .repeat) {
            this.cursor_pos = if (event.mods.control)
                0
            else
                nextLeft(this.text.items, this.cursor_pos);
            if (!event.mods.shift) {
                this.selection_start = this.cursor_pos;
            }
            return true;
        },
        .right => if (event.action == .press or event.action == .repeat) {
            this.cursor_pos = if (event.mods.control)
                this.text.items.len
            else
                nextRight(this.text.items, this.cursor_pos);
            if (!event.mods.shift) {
                this.selection_start = this.cursor_pos;
            }
            return true;
        },
        .backspace => if (event.action == .press or event.action == .repeat) {
            const src_pos = @max(this.selection_start, this.cursor_pos);
            const overwrite_pos = if (this.selection_start == this.cursor_pos)
                nextLeft(this.text.items, this.cursor_pos)
            else
                @min(this.selection_start, this.cursor_pos);

            const bytes_removed = src_pos - overwrite_pos;
            std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
            this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

            this.cursor_pos = overwrite_pos;
            this.selection_start = overwrite_pos;
            return true;
        },
        .delete => if (event.action == .press or event.action == .repeat) {
            const src_pos = if (this.selection_start == this.cursor_pos)
                nextRight(this.text.items, this.cursor_pos)
            else
                @max(this.selection_start, this.cursor_pos);
            const overwrite_pos = @min(this.selection_start, this.cursor_pos);

            const bytes_removed = src_pos - overwrite_pos;
            std.mem.copyForwards(u8, this.text.items[overwrite_pos..], this.text.items[src_pos..]);
            this.text.shrinkRetainingCapacity(this.text.items.len - bytes_removed);

            this.cursor_pos = overwrite_pos;
            this.selection_start = overwrite_pos;
            return true;
        },
        .enter => if (event.action == .press or event.action == .repeat) {
            if (this.on_enter) |on_enter| {
                on_enter.call(.{this});
            }
            return true;
        },
        .escape => if (event.action == .press or event.action == .repeat) {
            this.element.stage.focused_element = null;
        },
        else => {},
    }
    return true;
}

fn nextLeft(text: []const u8, pos: usize) usize {
    std.debug.assert(pos <= text.len);
    if (pos == 0) return 0;
    var new_pos = pos - 1;
    while (new_pos > 0 and text[new_pos] & 0b1000_0000 != 0b0000_0000) {
        new_pos -= 1;
    }
    return new_pos;
}

fn nextRight(text: []const u8, pos: usize) usize {
    std.debug.assert(pos <= text.len);
    if (pos == text.len) return text.len;
    var new_pos = pos + 1;
    while (new_pos < text.len and text[new_pos] & 0b1000_0000 != 0b0000_0000) {
        new_pos += 1;
    }
    return new_pos;
}

fn onSelect(element: *Element, direction: [2]f32) ?*Element {
    const this: *@This() = @fieldParentPtr("element", element);
    _ = direction;
    return &this.element;
}

const seizer = @import("../seizer.zig");
const Rect = seizer.geometry.Rect(f32);
const Element = ui.Element;
const ui = @import("../ui.zig");
const Canvas = @import("../Canvas.zig");
const std = @import("std");

pub const Button = @import("./Element/Button.zig");
pub const FlexBox = @import("./Element/FlexBox.zig");
pub const Frame = @import("./Element/Frame.zig");
pub const Image = @import("./Element/Image.zig");
pub const Label = @import("./Element/Label.zig");
pub const PanZoom = @import("./Element/PanZoom.zig");
pub const Plot = @import("./Element/Plot.zig");
pub const TextField = @import("./Element/TextField.zig");

ptr: ?*anyopaque,
interface: *const Interface,

const Element = @This();

pub const TransformedRect = struct {
    rect: Rect,
    transform: [4][4]f32,

    pub fn transformWithTranslation(this: @This()) [4][4]f32 {
        return seizer.geometry.mat4.mul(
            f32,
            seizer.geometry.mat4.translate(f32, .{ -this.rect.pos[0], -this.rect.pos[1], 0 }),
            this.transform,
        );
    }
};

pub const Interface = struct {
    acquire_fn: *const fn (Element) void,
    release_fn: *const fn (Element) void,
    set_parent_fn: *const fn (Element, ?Element) void,
    get_parent_fn: *const fn (Element) ?Element,
    get_child_rect_fn: *const fn (Element, child: Element) ?TransformedRect = getChildRectDefault,

    process_event_fn: *const fn (Element, event: seizer.input.Event) ?Element,
    get_min_size_fn: *const fn (Element) [2]f32,
    layout_fn: *const fn (Element, min_size: [2]f32, max_size: [2]f32) [2]f32 = layoutDefault,
    render_fn: *const fn (Element, Canvas.Transformed, Rect) void,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        acquire_fn: *const fn (*T) void,
        release_fn: *const fn (*T) void,
        set_parent_fn: *const fn (*T, ?Element) void,
        get_parent_fn: *const fn (*T) ?Element,
        get_child_rect_fn: ?*const fn (*T, child: Element) ?TransformedRect = null,

        process_event_fn: *const fn (*T, event: seizer.input.Event) ?Element,
        get_min_size_fn: *const fn (*T) [2]f32,
        layout_fn: ?*const fn (*T, min_size: [2]f32, max_size: [2]f32) [2]f32 = null,
        render_fn: *const fn (*T, Canvas.Transformed, Rect) void,
    }) Interface {
        const type_erased_fns = struct {
            fn acquire(element: Element) void {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.acquire_fn(t);
            }
            fn release(element: Element) void {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.release_fn(t);
            }
            fn setParent(element: Element, parent: ?Element) void {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.set_parent_fn(t, parent);
            }
            fn getParent(element: Element) ?Element {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.get_parent_fn(t);
            }
            fn getChildRect(element: Element, child: Element) ?TransformedRect {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                if (typed_fns.get_child_rect_fn) |get_child_rect_fn| {
                    return get_child_rect_fn(t, child);
                } else {
                    return element.getChildRectDefault(child);
                }
            }
            fn processEvent(element: Element, event: seizer.input.Event) ?Element {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.process_event_fn(t, event);
            }
            fn getMinSize(element: Element) [2]f32 {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.get_min_size_fn(t);
            }
            fn layout(element: Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                if (typed_fns.layout_fn) |layout_fn| {
                    return layout_fn(t, min_size, max_size);
                } else {
                    return element.layoutDefault(min_size, max_size);
                }
            }
            fn render(element: Element, canvas: Canvas.Transformed, rect: Rect) void {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.render_fn(t, canvas, rect);
            }
        };
        return Interface{
            .acquire_fn = type_erased_fns.acquire,
            .release_fn = type_erased_fns.release,
            .set_parent_fn = type_erased_fns.setParent,
            .get_parent_fn = type_erased_fns.getParent,
            .get_child_rect_fn = type_erased_fns.getChildRect,

            .process_event_fn = type_erased_fns.processEvent,
            .get_min_size_fn = type_erased_fns.getMinSize,
            .layout_fn = type_erased_fns.layout,
            .render_fn = type_erased_fns.render,
        };
    }
};

// Reference counting functions

pub fn acquire(element: Element) void {
    return element.interface.acquire_fn(element);
}

pub fn release(element: Element) void {
    return element.interface.release_fn(element);
}

// Parent setter/getter
pub fn setParent(element: Element, parent: ?Element) void {
    return element.interface.set_parent_fn(element, parent);
}

pub fn getParent(element: Element) ?Element {
    return element.interface.get_parent_fn(element);
}

// child rect query
pub fn getChildRect(element: Element, child: Element) ?TransformedRect {
    return element.interface.get_child_rect_fn(element, child);
}

// input handling
pub fn processEvent(element: Element, event: seizer.input.Event) ?Element {
    return element.interface.process_event_fn(element, event);
}

// layouting functions
pub fn getMinSize(element: Element) [2]f32 {
    return element.interface.get_min_size_fn(element);
}

pub fn layout(element: Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    return element.interface.layout_fn(element, min_size, max_size);
}

// rendering
pub fn render(element: Element, canvas: Canvas.Transformed, rect: Rect) void {
    return element.interface.render_fn(element, canvas, rect);
}

// Default functions

pub fn layoutDefault(element: Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    _ = min_size;
    _ = max_size;
    return element.getMinSize();
}

pub fn getChildRectDefault(element: Element, child: Element) ?TransformedRect {
    _ = element;
    _ = child;
    return null;
}

const Rect = seizer.ui.Rect;
const seizer = @import("../seizer.zig");
const std = @import("std");
const Canvas = @import("../Canvas.zig");

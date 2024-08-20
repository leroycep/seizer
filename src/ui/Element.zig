pub const Button = @import("./Element/Button.zig");
pub const FlexBox = @import("./Element/FlexBox.zig");
pub const Frame = @import("./Element/Frame.zig");
pub const Label = @import("./Element/Label.zig");
pub const TextField = @import("./Element/TextField.zig");

ptr: ?*anyopaque,
interface: *const Interface,

const Element = @This();

pub const Capture = struct {
    element: Element,
    transform: [4][4]f32,
};

pub const Interface = struct {
    acquire_fn: *const fn (Element) void,
    release_fn: *const fn (Element) void,
    set_parent_fn: *const fn (Element, ?Element) void,
    get_parent_fn: *const fn (Element) ?Element,

    process_event_fn: *const fn (Element, event: seizer.input.Event, transform: [4][4]f32) ?Element.Capture,
    get_min_size_fn: *const fn (Element) [2]f32,
    layout_fn: *const fn (Element, min_size: [2]f32, max_size: [2]f32) [2]f32 = layoutDefault,
    render_fn: *const fn (Element, Canvas.Transformed, Rect) void,

    pub fn getTypeErasedFunctions(comptime T: type, typed_fns: struct {
        acquire_fn: *const fn (*T) void,
        release_fn: *const fn (*T) void,
        set_parent_fn: *const fn (*T, ?Element) void,
        get_parent_fn: *const fn (*T) ?Element,

        process_event_fn: *const fn (*T, event: seizer.input.Event, transform: [4][4]f32) ?Element.Capture,
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
            fn processEvent(element: Element, event: seizer.input.Event, transform: [4][4]f32) ?Element.Capture {
                const t: *T = @ptrCast(@alignCast(element.ptr));
                return typed_fns.process_event_fn(t, event, transform);
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

            .process_event_fn = type_erased_fns.processEvent,
            .get_min_size_fn = type_erased_fns.getMinSize,
            .layout_fn = type_erased_fns.layout,
            .render_fn = type_erased_fns.render,
        };
    }
};

pub fn acquire(element: Element) void {
    return element.interface.acquire_fn(element);
}

pub fn release(element: Element) void {
    return element.interface.release_fn(element);
}

pub fn getMinSize(element: Element) [2]f32 {
    return element.interface.get_min_size_fn(element);
}

pub fn layout(element: Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    return element.interface.layout_fn(element, min_size, max_size);
}

pub fn render(element: Element, canvas: Canvas.Transformed, rect: Rect) void {
    return element.interface.render_fn(element, canvas, rect);
}

pub fn processEvent(element: Element, event: seizer.input.Event, transform: [4][4]f32) ?Element.Capture {
    return element.interface.process_event_fn(element, event, transform);
}

pub fn getTransform(element: Element) [4][4]f32 {
    return element.interface.get_transform_fn(element);
}

pub fn getNextSelection(element: Element, current_selection: ?Element, direction: [2]f32) ?Element {
    return element.interface.get_next_selection_fn(element, current_selection, direction);
}

pub fn setParent(element: Element, parent: ?Element) void {
    return element.interface.set_parent_fn(element, parent);
}

pub fn getParent(element: Element) ?Element {
    return element.interface.get_parent_fn(element);
}

// Default functions

pub fn layoutDefault(element: Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
    _ = min_size;
    _ = max_size;
    return element.getMinSize();
}

const Rect = seizer.geometry.Rect(f32);
const seizer = @import("../seizer.zig");
const std = @import("std");
const Canvas = @import("../Canvas.zig");

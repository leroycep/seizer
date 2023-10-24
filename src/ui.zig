pub const Button = @import("./ui/Button.zig");
pub const FlexBox = @import("./ui/FlexBox.zig");
pub const Frame = @import("./ui/Frame.zig");
pub const Label = @import("./ui/Label.zig");
pub const TextField = @import("./ui/TextField.zig");

pub const Stage = struct {
    gpa: std.mem.Allocator,

    default_style: Style,

    root: ?*Element = null,
    popups: std.AutoArrayHashMapUnmanaged(*Element, void) = .{},

    focused_element: ?*Element = null,
    hovered_element: ?*Element = null,
    pointer_capture_element: ?*Element = null,

    needs_layout: bool = true,
    cursor_shape: ?CursorShape = null,

    pub fn init(gpa: std.mem.Allocator, default_style: Style) !*@This() {
        const this = try gpa.create(@This());
        this.* = .{
            .gpa = gpa,
            .default_style = default_style,
        };
        return this;
    }

    pub fn destroy(this: *@This()) void {
        if (this.root) |r| {
            r.release();
        }
        for (this.popups.keys()) |popup| {
            popup.release();
        }
        this.popups.deinit(this.gpa);
        this.gpa.destroy(this);
    }

    pub fn setRoot(this: *@This(), new_root_opt: ?*Element) void {
        if (new_root_opt) |new_root| {
            new_root.acquire();
        }
        if (this.root) |r| {
            r.release();
        }
        if (new_root_opt) |new_root| {
            new_root.parent = null;
        }
        this.root = new_root_opt;
        this.needs_layout = true;
    }

    pub fn addPopup(this: *@This(), popup: *Element) !void {
        const gop = try this.popups.getOrPut(this.gpa, popup);
        if (!gop.found_existing) {
            popup.acquire();
            popup.parent = null;
            this.needs_layout = true;
        }
    }

    pub fn removePopup(this: *@This(), popup: *Element) bool {
        if (this.popups.swapRemove(popup)) {
            popup.release();
            return true;
        }
        return false;
    }

    pub fn render(this: *Stage, canvas: *Canvas, window_size: [2]f32) void {
        if (this.needs_layout) {
            if (this.root) |r| r.rect.size = r.layout(window_size, window_size);
            for (this.popups.keys()) |popup| {
                popup.rect.size = popup.layout(.{ 0, 0 }, window_size);
            }
            this.needs_layout = false;
        }

        if (this.root) |r| {
            r.render(canvas, r.rect);
        }
        for (this.popups.keys()) |popup| {
            popup.render(canvas, popup.rect);
        }
    }

    pub fn onHover(this: *Stage, pos: [2]f32) bool {
        this.cursor_shape = null;
        this.hovered_element = null;
        if (this.pointer_capture_element) |pce| {
            const transform = if (pce.parent) |parent| parent.getTransform() else seizer.geometry.mat4.identity(f32);
            const transformed_pos = seizer.geometry.mat4.mulVec(f32, transform, .{
                pos[0],
                pos[1],
                0,
                1,
            })[0..2].*;

            if (pce.onHover(transformed_pos)) |hovered| {
                this.hovered_element = hovered;
                return true;
            }
        }
        for (0..this.popups.keys().len) |i| {
            const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
            if (popup.rect.contains(pos)) {
                if (popup.onHover(pos)) |hovered| {
                    this.hovered_element = hovered;
                    return true;
                }
            }
        }
        if (this.root) |r| {
            if (r.onHover(pos)) |hovered| {
                this.hovered_element = hovered;
                return true;
            }
        }
        return false;
    }

    pub fn onClick(this: *Stage, e: event.Click) bool {
        if (e.pressed and e.button == .left) this.focused_element = null;
        if (this.pointer_capture_element) |pce| {
            const transform = if (pce.parent) |parent| parent.getTransform() else seizer.geometry.mat4.identity(f32);
            const transformed_pos = seizer.geometry.mat4.mulVec(f32, transform, .{
                e.pos[0],
                e.pos[1],
                0,
                1,
            })[0..2].*;
            const transformed_event = event.Click{
                .pos = transformed_pos,
                .button = e.button,
                .pressed = e.pressed,
            };

            if (pce.onClick(transformed_event)) {
                return true;
            }
        }
        for (0..this.popups.keys().len) |i| {
            const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
            if (popup.rect.contains(e.pos)) {
                if (popup.onClick(e)) {
                    if (this.popups.orderedRemove(popup)) {
                        this.popups.putAssumeCapacity(popup, {});
                    }
                    return true;
                }
            }
        }
        if (this.root) |r| {
            return r.onClick(e);
        }
        return false;
    }

    pub fn onScroll(this: *Stage, e: event.Scroll) bool {
        if (this.pointer_capture_element) |pce| {
            if (pce.onScroll(e)) {
                return true;
            }
        }

        var current_opt = this.hovered_element;
        while (current_opt) |current| : (current_opt = current.parent) {
            if (current.onScroll(e)) {
                return true;
            }
        }

        return false;
    }

    pub fn onTextInput(this: *Stage, e: event.TextInput) bool {
        if (this.focused_element) |focused| {
            if (focused.onTextInput(e)) {
                return true;
            }
        }
        return false;
    }

    pub fn onKey(this: *Stage, e: event.Key) bool {
        if (this.focused_element) |focused| {
            if (focused.onKey(e)) {
                return true;
            }
        }
        return false;
    }
};

pub const event = struct {
    pub const Hover = struct {
        pos: [2]f32,
        buttons: struct {
            left: bool,
            right: bool,
            middle: bool,
        },
    };

    pub const Click = struct {
        pos: [2]f32,
        button: enum {
            left,
            right,
            middle,
        },
        pressed: bool,

        pub fn translate(this: @This(), offset: [2]f32) @This() {
            return @This(){
                .pos = .{ this.pos[0] + offset[0], this.pos[1] + offset[1] },
                .button = this.button,
                .pressed = this.pressed,
            };
        }
    };

    pub const Scroll = struct {
        offset: [2]f32,
    };

    pub const TextInput = struct {
        text: std.BoundedArray(u8, 16),
    };

    // TODO: Make all of these fields enums; remove dependence on GLFW
    pub const Key = struct {
        key: enum(c_int) {
            up = seizer.backend.glfw.c.GLFW_KEY_UP,
            left = seizer.backend.glfw.c.GLFW_KEY_LEFT,
            right = seizer.backend.glfw.c.GLFW_KEY_RIGHT,
            down = seizer.backend.glfw.c.GLFW_KEY_DOWN,
            page_up = seizer.backend.glfw.c.GLFW_KEY_PAGE_UP,
            page_down = seizer.backend.glfw.c.GLFW_KEY_PAGE_DOWN,
            enter = seizer.backend.glfw.c.GLFW_KEY_ENTER,
            backspace = seizer.backend.glfw.c.GLFW_KEY_BACKSPACE,
            delete = seizer.backend.glfw.c.GLFW_KEY_DELETE,
            _,
        },
        scancode: c_int,
        action: enum(c_int) {
            press = seizer.backend.glfw.c.GLFW_PRESS,
            repeat = seizer.backend.glfw.c.GLFW_REPEAT,
            release = seizer.backend.glfw.c.GLFW_RELEASE,
        },
        mods: packed struct {
            shift: bool,
            control: bool,
            alt: bool,
            super: bool,
            caps_lock: bool,
            num_lock: bool,
        },
    };
};

pub const Element = struct {
    interface: *const Interface,
    stage: *Stage,
    reference_count: usize = 1,
    parent: ?*Element = null,
    rect: Rect = .{ .pos = .{ 0, 0 }, .size = .{ 0, 0 } },

    pub const Interface = struct {
        destroy_fn: *const fn (*Element) void,
        get_min_size_fn: *const fn (*Element) [2]f32,
        layout_fn: *const fn (*Element, min_size: [2]f32, max_size: [2]f32) [2]f32 = layoutDefault,
        render_fn: *const fn (*Element, *Canvas, Rect) void,
        on_hover_fn: *const fn (*Element, pos: [2]f32) ?*Element = onHoverDefault,
        on_click_fn: *const fn (*Element, event.Click) bool = onClickDefault,
        on_scroll_fn: *const fn (*Element, event.Scroll) bool = onScrollDefault,
        on_text_input_fn: *const fn (*Element, event.TextInput) bool = onTextInputDefault,
        on_key_fn: *const fn (*Element, event.Key) bool = onKeyDefault,
        get_transform_fn: *const fn (*Element) [4][4]f32 = getTransformDefault,
    };

    pub fn acquire(element: *Element) void {
        element.reference_count += 1;
    }

    pub fn release(element: *Element) void {
        element.reference_count -= 1;
        if (element.reference_count == 0) {
            element.destroy();
        }
    }

    pub fn destroy(element: *Element) void {
        if (element.stage.pointer_capture_element == element) {
            element.stage.pointer_capture_element = null;
        }
        return element.interface.destroy_fn(element);
    }

    pub fn getMinSize(element: *Element) [2]f32 {
        return element.interface.get_min_size_fn(element);
    }

    pub fn layout(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
        return element.interface.layout_fn(element, min_size, max_size);
    }

    pub fn render(element: *Element, canvas: *Canvas, rect: Rect) void {
        return element.interface.render_fn(element, canvas, rect);
    }

    pub fn onHover(element: *Element, pos: [2]f32) ?*Element {
        return element.interface.on_hover_fn(element, pos);
    }

    pub fn onClick(element: *Element, e: event.Click) bool {
        return element.interface.on_click_fn(element, e);
    }

    pub fn onScroll(element: *Element, e: event.Scroll) bool {
        return element.interface.on_scroll_fn(element, e);
    }

    pub fn onTextInput(element: *Element, e: event.TextInput) bool {
        return element.interface.on_text_input_fn(element, e);
    }

    pub fn onKey(element: *Element, e: event.Key) bool {
        return element.interface.on_key_fn(element, e);
    }

    pub fn getTransform(element: *Element) [4][4]f32 {
        return element.interface.get_transform_fn(element);
    }

    // Default functions

    pub fn layoutDefault(element: *Element, min_size: [2]f32, max_size: [2]f32) [2]f32 {
        _ = min_size;
        _ = max_size;
        return element.getMinSize();
    }

    pub fn onHoverDefault(element: *Element, pos: [2]f32) ?*Element {
        _ = pos;
        return element;
    }

    pub fn onClickDefault(element: *Element, e: event.Click) bool {
        _ = element;
        _ = e;
        return false;
    }

    pub fn onScrollDefault(element: *Element, e: event.Scroll) bool {
        _ = element;
        _ = e;
        return false;
    }

    pub fn onTextInputDefault(this: *Element, e: event.TextInput) bool {
        _ = this;
        _ = e;
        return false;
    }

    pub fn onKeyDefault(this: *Element, e: event.Key) bool {
        _ = this;
        _ = e;
        return false;
    }

    pub fn getTransformDefault(this: *Element) [4][4]f32 {
        const local = seizer.geometry.mat4.translate(f32, .{ -this.rect.pos[0], -this.rect.pos[1], 0 });
        if (this.parent) |parent| {
            return seizer.geometry.mat4.mul(f32, local, parent.getTransform());
        } else {
            return local;
        }
    }
};

pub const Style = struct {
    padding: seizer.geometry.Inset(f32),
    text_font: *const Font,
    text_scale: f32,
    text_color: [4]u8,
    background_image: seizer.NinePatch,
    background_color: [4]u8,

    /// Override specific fields without having to type them all out.
    pub fn with(inherited: @This(), overrides: struct {
        padding: ?seizer.geometry.Inset(f32) = null,
        text_font: ?*const Font = null,
        text_scale: ?f32 = null,
        text_color: ?[4]u8 = null,
        background_image: ?seizer.NinePatch = null,
        background_color: ?[4]u8 = null,
    }) @This() {
        return @This(){
            .padding = overrides.padding orelse inherited.padding,
            .text_font = overrides.text_font orelse inherited.text_font,
            .text_scale = overrides.text_scale orelse inherited.text_scale,
            .text_color = overrides.text_color orelse inherited.text_color,
            .background_image = overrides.background_image orelse inherited.background_image,
            .background_color = overrides.background_color orelse inherited.background_color,
        };
    }
};

pub const CursorShape = enum {
    move,
    horizontal_resize,
    vertical_resize,
    sw_to_ne_resize,
    nw_to_se_resize,
};

pub fn PrependParameterToFn(comptime Fn: anytype, comptime param: std.builtin.Type.Fn.Param) type {
    const info = @typeInfo(Fn);
    return @Type(.{
        .Fn = .{
            // Copy data from input function type
            .calling_convention = info.Fn.calling_convention,
            .alignment = info.Fn.alignment,
            .is_generic = info.Fn.is_generic,
            .is_var_args = info.Fn.is_var_args,
            .return_type = info.Fn.return_type,
            // Add new parameter to the beginning of the parameters
            .params = (.{param} ++ info.Fn.params),
        },
    });
}

pub fn Callable(comptime CallbackFn: anytype) type {
    const callback_fn_info = @typeInfo(CallbackFn);
    const Return = callback_fn_info.Fn.return_type orelse void;
    return struct {
        userdata: ?*anyopaque,
        callback: *const AnyopaqueCallbackFn,

        const AnyopaqueCallbackFn = PrependParameterToFn(CallbackFn, .{
            .is_generic = false,
            .is_noalias = false,
            .type = ?*anyopaque,
        });

        pub fn call(this: @This(), args: std.meta.ArgsTuple(CallbackFn)) Return {
            return @call(.auto, this.callback, .{this.userdata} ++ args);
        }
    };
}

const Rect = seizer.geometry.Rect(f32);
const seizer = @import("./seizer.zig");
const std = @import("std");
const Font = @import("./Canvas/Font.zig");
const Canvas = @import("./Canvas.zig");

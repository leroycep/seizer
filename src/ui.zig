pub const Element = @import("./ui/Element.zig");

pub const Rect = seizer.geometry.Rect(f32);

pub const Stage = struct {
    gpa: std.mem.Allocator,
    default_style: Style,

    root: ?Element = null,
    popups: std.AutoArrayHashMapUnmanaged(Element, void) = .{},

    focused_element: ?Element = null,
    hovered_element: ?Element = null,
    pointer_capture_element: ?Element = null,

    needs_layout: bool = true,
    cursor_shape: ?CursorShape = null,

    pub fn create(gpa: std.mem.Allocator, default_style: Style) !*@This() {
        const this = try gpa.create(@This());
        this.* = .{
            .gpa = gpa,
            .default_style = default_style,
        };
        return this;
    }

    pub fn destroy(this: *@This()) void {
        if (this.focused_element) |focused| {
            focused.release();
        }
        if (this.hovered_element) |hovered| {
            hovered.release();
        }
        if (this.pointer_capture_element) |pce| {
            pce.release();
        }
        if (this.root) |r| {
            r.release();
        }
        for (this.popups.keys()) |popup| {
            popup.release();
        }
        this.popups.deinit(this.gpa);
        this.gpa.destroy(this);
    }

    pub fn setRoot(this: *@This(), new_root_opt: ?Element) void {
        if (new_root_opt) |new_root| {
            new_root.acquire();
        }
        if (this.root) |r| {
            r.release();
        }
        if (new_root_opt) |new_root| {
            new_root.setParent(null);
        }
        this.root = new_root_opt;
        this.needs_layout = true;
    }

    pub fn addPopup(this: *@This(), popup: Element) !void {
        const gop = try this.popups.getOrPut(this.gpa, popup);
        if (!gop.found_existing) {
            popup.acquire();
            popup.parent = null;
            this.needs_layout = true;
        }
    }

    pub fn removePopup(this: *@This(), popup: Element) bool {
        if (this.popups.swapRemove(popup)) {
            popup.release();
            return true;
        }
        return false;
    }

    pub fn render(this: *Stage, canvas: Canvas.Transformed, window_size: [2]f32) void {
        if (this.needs_layout) {
            if (this.root) |r| _ = r.layout(window_size, window_size);
            for (this.popups.keys()) |popup| {
                _ = popup.layout(.{ 0, 0 }, window_size);
            }
            this.needs_layout = false;
        }

        if (this.root) |r| {
            r.render(canvas, .{ .pos = .{ 0, 0 }, .size = window_size });
        }
        for (this.popups.keys()) |popup| {
            popup.render(canvas, .{ .pos = .{ 0, 0 }, .size = window_size });
        }
    }

    pub fn processEvent(this: *Stage, event: seizer.input.Event) ?Element {
        switch (event) {
            .hover => |hover| {
                this.cursor_shape = null;
                this.setHoveredElement(null);
                if (this.pointer_capture_element) |pce| {
                    var transformed_event = event;
                    if (pce.getParent()) |parent| {
                        if (parent.getChildRect(pce)) |transformed_rect| {
                            transformed_event = seizer.input.Event{ .hover = hover.transform(transformed_rect.transformWithTranslation()) };
                        }
                    }
                    if (pce.processEvent(transformed_event)) |hovered| {
                        this.setHoveredElement(hovered);
                        return hovered;
                    }
                }

                var popup_index = this.popups.keys().len;
                while (popup_index > 0) : (popup_index -= 1) {
                    const popup = this.popups.keys()[popup_index - 1];
                    if (popup.processEvent(event)) |hovered| {
                        this.setHoveredElement(hovered);
                        return hovered;
                    }
                }

                if (this.root) |r| {
                    if (r.processEvent(event)) |hovered| {
                        this.setHoveredElement(hovered);
                        return hovered;
                    }
                }
                return null;
            },

            .click => |click| {
                if (click.pressed) {
                    this.setFocusedElement(null);
                }
                if (this.pointer_capture_element) |pce| {
                    var transformed_event = event;
                    if (pce.getParent()) |parent| {
                        if (parent.getChildRect(pce)) |transformed_rect| {
                            transformed_event = seizer.input.Event{ .click = click.transform(transformed_rect.transformWithTranslation()) };
                        }
                    }
                    if (pce.processEvent(transformed_event)) |clicked| {
                        return clicked;
                    }
                }

                // iterate backwards so orderedRemove works
                var popup_index = this.popups.keys().len;
                while (popup_index > 0) : (popup_index -= 1) {
                    const popup = this.popups.keys()[popup_index - 1];
                    if (popup.processEvent(event)) |clicked| {
                        if (this.popups.orderedRemove(popup)) {
                            this.popups.putAssumeCapacity(popup, {});
                        }
                        return clicked;
                    }
                }

                if (this.root) |r| {
                    if (r.processEvent(event)) |clicked| {
                        return clicked;
                    }
                }

                return null;
            },

            .scroll => |_| {
                if (this.pointer_capture_element) |pce| {
                    if (pce.processEvent(event)) |element| {
                        return element;
                    }
                }

                var current_opt = this.hovered_element;
                while (current_opt) |current| : (current_opt = current.getParent()) {
                    if (current.processEvent(event)) |element| {
                        return element;
                    }
                }

                return null;
            },

            .text => |_| {
                if (this.focused_element) |focused| {
                    if (focused.processEvent(event)) |element| {
                        return element;
                    }
                }
                return null;
            },

            .key => {
                if (this.focused_element) |focused| {
                    if (focused.processEvent(event)) |element| {
                        return element;
                    }
                }

                if (this.hovered_element) |hovered| {
                    if (hovered.processEvent(event)) |element| {
                        return element;
                    }
                }

                return null;
            },
        }
    }

    pub fn isPointerCaptureElement(this: *@This(), element: Element) bool {
        return this.pointer_capture_element != null and this.pointer_capture_element.?.ptr == element.ptr and this.pointer_capture_element.?.interface == element.interface;
    }

    pub fn capturePointer(this: *@This(), new_pointer_capture_element: Element) void {
        new_pointer_capture_element.acquire();
        if (this.pointer_capture_element) |pce| {
            pce.release();
        }
        this.pointer_capture_element = new_pointer_capture_element;
    }

    pub fn releasePointer(this: *@This(), element: Element) void {
        if (this.pointer_capture_element) |pce| {
            if (pce.ptr == element.ptr) {
                pce.release();
                this.pointer_capture_element = null;
            }
        }
    }

    pub fn setHoveredElement(this: *@This(), new_hover_opt: ?Element) void {
        if (new_hover_opt) |new_hover| {
            new_hover.acquire();
        }
        if (this.hovered_element) |focus| {
            focus.release();
        }
        this.hovered_element = new_hover_opt;
    }

    pub fn isHovered(this: *@This(), element: Element) bool {
        return this.hovered_element != null and this.hovered_element.?.ptr == element.ptr and this.hovered_element.?.interface == element.interface;
    }

    pub fn setFocusedElement(this: *@This(), new_focus_opt: ?Element) void {
        if (new_focus_opt) |new_focus| {
            new_focus.acquire();
        }
        if (this.focused_element) |focus| {
            focus.release();
        }
        this.focused_element = new_focus_opt;
    }

    pub fn isFocused(this: *@This(), element: Element) bool {
        return this.focused_element != null and this.focused_element.?.ptr == element.ptr and this.focused_element.?.interface == element.interface;
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

const input = @import("./input.zig");
const seizer = @import("./seizer.zig");
const std = @import("std");
const Font = @import("./Canvas/Font.zig");
const Canvas = @import("./Canvas.zig");

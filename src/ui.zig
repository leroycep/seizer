pub const Element = @import("./ui/Element.zig");

pub const Stage = struct {
    gpa: std.mem.Allocator,
    default_style: Style,

    root: ?Element = null,
    popups: std.AutoArrayHashMapUnmanaged(Element, void) = .{},

    focused_element: ?Element.Capture = null,
    hovered_element: ?Element.Capture = null,
    pointer_capture_element: ?Element.Capture = null,

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
            focused.element.release();
        }
        if (this.hovered_element) |hovered| {
            hovered.element.release();
        }
        if (this.pointer_capture_element) |pce| {
            pce.element.release();
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

    pub fn processEvent(this: *Stage, event: seizer.input.Event) ?Element.Capture {
        const IDENTITY_TRANSFORM = seizer.geometry.mat4.identity(f32);
        switch (event) {
            .hover => |hover| {
                this.cursor_shape = null;
                this.hovered_element = null;
                if (this.pointer_capture_element) |pce| {
                    if (pce.element.processEvent(event, pce.transform)) |hovered| {
                        this.hovered_element = hovered;
                        return hovered;
                    }
                }
                for (0..this.popups.keys().len) |i| {
                    const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
                    if (popup.rect.contains(hover.pos)) {
                        if (popup.processEvent(event, IDENTITY_TRANSFORM)) |hovered| {
                            this.hovered_element = hovered;
                            return hovered;
                        }
                    }
                }
                if (this.root) |r| {
                    if (r.processEvent(event, IDENTITY_TRANSFORM)) |hovered| {
                        this.hovered_element = hovered;
                        return hovered;
                    }
                }
                return null;
            },

            .click => |click| {
                if (click.pressed and click.button == .left) this.focused_element = null;
                if (this.pointer_capture_element) |pce| {
                    if (pce.element.processEvent(event, pce.transform)) |clicked| {
                        return clicked;
                    }
                }
                // iterate backwards so orderedRemove works
                for (0..this.popups.keys().len) |i| {
                    const popup = this.popups.keys()[this.popups.keys().len - 1 - i];
                    if (popup.processEvent(event, IDENTITY_TRANSFORM)) |clicked| {
                        if (this.popups.orderedRemove(popup)) {
                            this.popups.putAssumeCapacity(popup, {});
                        }
                        return clicked;
                    }
                }
                if (this.root) |r| {
                    return r.processEvent(event, IDENTITY_TRANSFORM);
                }
                return null;
            },

            .scroll => |_| {
                if (this.pointer_capture_element) |pce| {
                    if (pce.element.processEvent(event, pce.transform)) |element| {
                        return element;
                    }
                }

                var current_opt = this.hovered_element;
                while (current_opt) |current| : (current_opt = current.getParent()) {
                    if (current.processEvent(event, IDENTITY_TRANSFORM)) |element| {
                        return element;
                    }
                }

                return null;
            },

            .text_input => |_| {
                if (this.focused_element) |focused| {
                    if (focused.element.processEvent(event, focused.transform)) |element| {
                        return element;
                    }
                }
                return null;
            },

            .key => |key| {
                if (this.focused_element) |focused| {
                    if (focused.element.processEvent(event, focused.transform)) |element| {
                        return element;
                    }
                }

                if (this.hovered_element) |hovered| {
                    if (hovered.element.processEvent(event, hovered.transform)) |element| {
                        return element;
                    }
                }

                if (key.action != .press and key.action != .repeat) return null;
                const direction = switch (key.key) {
                    .up => [2]f32{ 0, -1 },
                    .down => [2]f32{ 0, 1 },
                    .left => [2]f32{ -1, 0 },
                    .right => [2]f32{ 1, 0 },
                    else => return null,
                };

                // If something is already hovered, ask it for the next element
                if (this.hovered_element) |hovered| {
                    if (hovered.element.getNextSelection(this.hovered_element, direction)) |next_selection| {
                        this.hovered_element = next_selection;
                        return next_selection;
                    }
                }

                // If nothing is hovered, select the root element
                this.hovered_element = this.root;

                return this.hovered_element;
            },
        }
    }

    pub fn capturePointer(this: *@This(), new_pointer_capture_element: *Element) void {
        new_pointer_capture_element.acquire();
        if (this.pointer_capture_element) |pce| {
            pce.release();
        }
        this.pointer_capture_element = new_pointer_capture_element;
    }

    pub fn releasePointer(this: *@This(), element: *Element) void {
        if (this.pointer_capture_element) |pce| {
            if (pce == element) {
                pce.release();
                this.pointer_capture_element = null;
            }
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

const input = @import("./input.zig");
const Rect = seizer.geometry.Rect(f32);
const seizer = @import("./seizer.zig");
const std = @import("std");
const Font = @import("./Canvas/Font.zig");
const Canvas = @import("./Canvas.zig");

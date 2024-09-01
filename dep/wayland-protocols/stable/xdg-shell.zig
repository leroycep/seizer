// Copyright © 2008-2013 Kristian Høgsberg
// Copyright © 2013      Rafael Antognolli
// Copyright © 2013      Jasper St. Pierre
// Copyright © 2010-2013 Intel Corporation
// Copyright © 2015-2017 Samsung Electronics Co., Ltd
// Copyright © 2015-2017 Red Hat Inc.
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice (including the next
// paragraph) shall be included in all copies or substantial portions of the
// Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
// THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
// DEALINGS IN THE SOFTWARE.

/// The xdg_wm_base interface is exposed as a global object enabling clients
/// to turn their wl_surfaces into windows in a desktop environment. It
/// defines the basic functionality needed for clients and the compositor to
/// create windows that can be dragged, resized, maximized, etc, as well as
/// creating transient windows such as popup menus.
pub const xdg_wm_base = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "xdg_wm_base",
        .version = 2,
        .delete = delete,
        .event_received = event_received,
    });

    pub fn object(this: *@This()) wayland.Object {
        return wayland.Object{
            .interface = &INTERFACE,
            .pointer = this,
        };
    }

    /// This should only be called when the wayland display sends the `delete_id` event
    pub fn delete(this: *@This()) void {
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = this.conn.deserializeAndLogErrors(Event, header, body) orelse return;
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// given wl_surface has another role
        role = 0,
        /// xdg_wm_base was destroyed before children
        defunct_surfaces = 1,
        /// the client tried to map or destroy a non-topmost popup
        not_the_topmost_popup = 2,
        /// the client specified an invalid popup parent surface
        invalid_popup_parent = 3,
        /// the client provided an invalid surface state
        invalid_surface_state = 4,
        /// the client provided an invalid positioner
        invalid_positioner = 5,
        /// the client didn’t respond to a ping event in time
        unresponsive = 6,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        create_positioner: struct {
            id: u32,
        },
        get_xdg_surface: struct {
            id: u32,
            surface: u32,
        },
        pong: struct {
            serial: u32,
        },
    };

    /// Destroy this xdg_wm_base object.
    ///
    /// Destroying a bound xdg_wm_base object while there are surfaces
    /// still alive created by this xdg_wm_base object instance is illegal
    /// and will result in a defunct_surfaces error.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Create a positioner object. A positioner object is used to position
    /// surfaces relative to some parent surface. See the interface description
    /// and xdg_surface.get_popup for details.
    pub fn create_positioner(
        this: @This(),
    ) !*xdg_positioner {
        const new_object = try this.conn.createObject(xdg_positioner);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_positioner = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// This creates an xdg_surface for the given surface. While xdg_surface
    /// itself is not a role, the corresponding surface may only be assigned
    /// a role extending xdg_surface, such as xdg_toplevel or xdg_popup. It is
    /// illegal to create an xdg_surface for a wl_surface which already has an
    /// assigned role and this will result in a role error.
    ///
    /// This creates an xdg_surface for the given surface. An xdg_surface is
    /// used as basis to define a role to a given surface, such as xdg_toplevel
    /// or xdg_popup. It also manages functionality shared between xdg_surface
    /// based surface roles.
    ///
    /// See the documentation of xdg_surface for more details about what an
    /// xdg_surface is and how it is used.
    pub fn get_xdg_surface(
        this: @This(),
        surface: *wayland.wayland.wl_surface,
    ) !*xdg_surface {
        const new_object = try this.conn.createObject(xdg_surface);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_xdg_surface = .{
                .id = new_object.id,
                .surface = surface.id,
            } },
        );
        return new_object;
    }

    /// A client must respond to a ping event with a pong request or
    /// the client may be deemed unresponsive. See xdg_wm_base.ping
    /// and xdg_wm_base.error.unresponsive.
    pub fn pong(
        this: @This(),
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .pong = .{
                .serial = serial,
            } },
        );
    }

    pub const Event = union(enum) {
        /// The ping event asks the client if it's still alive. Pass the
        /// serial specified in the event back to the compositor by sending
        /// a "pong" request back with the specified serial. See xdg_wm_base.pong.
        ///
        /// Compositors can use this to determine if the client is still
        /// alive. It's unspecified what will happen if the client doesn't
        /// respond to the ping request, or in what timeframe. Clients should
        /// try to respond in a reasonable amount of time. The “unresponsive”
        /// error is provided for compositors that wish to disconnect unresponsive
        /// clients.
        ///
        /// A compositor is free to ping in any way it wants, but a client must
        /// always respond to any xdg_wm_base object it created.
        ping: struct {
            serial: u32,
        },
    };
};

/// The xdg_positioner provides a collection of rules for the placement of a
/// child surface relative to a parent surface. Rules can be defined to ensure
/// the child surface remains within the visible area's borders, and to
/// specify how the child surface changes its position, such as sliding along
/// an axis, or flipping around a rectangle. These positioner-created rules are
/// constrained by the requirement that a child surface must intersect with or
/// be at least partially adjacent to its parent surface.
///
/// See the various requests for details about possible rules.
///
/// At the time of the request, the compositor makes a copy of the rules
/// specified by the xdg_positioner. Thus, after the request is complete the
/// xdg_positioner object can be destroyed or reused; further changes to the
/// object will have no effect on previous usages.
///
/// For an xdg_positioner object to be considered complete, it must have a
/// non-zero size set by set_size, and a non-zero anchor rectangle set by
/// set_anchor_rect. Passing an incomplete xdg_positioner object when
/// positioning a surface raises an invalid_positioner error.
pub const xdg_positioner = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "xdg_positioner",
        .version = 2,
        .delete = delete,
        .event_received = null,
    });

    pub fn object(this: *@This()) wayland.Object {
        return wayland.Object{
            .interface = &INTERFACE,
            .pointer = this,
        };
    }

    /// This should only be called when the wayland display sends the `delete_id` event
    pub fn delete(this: *@This()) void {
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }
    pub const Error = enum(u32) {
        /// invalid input provided
        invalid_input = 0,
    };

    pub const Anchor = enum(u32) {
        none = 0,
        top = 1,
        bottom = 2,
        left = 3,
        right = 4,
        top_left = 5,
        bottom_left = 6,
        top_right = 7,
        bottom_right = 8,
    };

    pub const Gravity = enum(u32) {
        none = 0,
        top = 1,
        bottom = 2,
        left = 3,
        right = 4,
        top_left = 5,
        bottom_left = 6,
        top_right = 7,
        bottom_right = 8,
    };

    pub const Constraint_adjustment = packed struct(u32) {
        slide_x: bool,
        slide_y: bool,
        flip_x: bool,
        flip_y: bool,
        resize_x: bool,
        resize_y: bool,
        padding_1: u26 = 0,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        set_size: struct {
            width: i32,
            height: i32,
        },
        set_anchor_rect: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        set_anchor: struct {
            anchor: Anchor,
        },
        set_gravity: struct {
            gravity: Gravity,
        },
        set_constraint_adjustment: struct {
            constraint_adjustment: Constraint_adjustment,
        },
        set_offset: struct {
            x: i32,
            y: i32,
        },
    };

    /// Notify the compositor that the xdg_positioner will no longer be used.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Set the size of the surface that is to be positioned with the positioner
    /// object. The size is in surface-local coordinates and corresponds to the
    /// window geometry. See xdg_surface.set_window_geometry.
    ///
    /// If a zero or negative size is set the invalid_input error is raised.
    pub fn set_size(
        this: @This(),
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_size = .{
                .width = width,
                .height = height,
            } },
        );
    }

    /// Specify the anchor rectangle within the parent surface that the child
    /// surface will be placed relative to. The rectangle is relative to the
    /// window geometry as defined by xdg_surface.set_window_geometry of the
    /// parent surface.
    ///
    /// When the xdg_positioner object is used to position a child surface, the
    /// anchor rectangle may not extend outside the window geometry of the
    /// positioned child's parent surface.
    ///
    /// If a negative size is set the invalid_input error is raised.
    pub fn set_anchor_rect(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_anchor_rect = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    /// Defines the anchor point for the anchor rectangle. The specified anchor
    /// is used derive an anchor point that the child surface will be
    /// positioned relative to. If a corner anchor is set (e.g. 'top_left' or
    /// 'bottom_right'), the anchor point will be at the specified corner;
    /// otherwise, the derived anchor point will be centered on the specified
    /// edge, or in the center of the anchor rectangle if no edge is specified.
    pub fn set_anchor(
        this: @This(),
        anchor: Anchor,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_anchor = .{
                .anchor = anchor,
            } },
        );
    }

    /// Defines in what direction a surface should be positioned, relative to
    /// the anchor point of the parent surface. If a corner gravity is
    /// specified (e.g. 'bottom_right' or 'top_left'), then the child surface
    /// will be placed towards the specified gravity; otherwise, the child
    /// surface will be centered over the anchor point on any axis that had no
    /// gravity specified. If the gravity is not in the ‘gravity’ enum, an
    /// invalid_input error is raised.
    pub fn set_gravity(
        this: @This(),
        gravity: Gravity,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_gravity = .{
                .gravity = gravity,
            } },
        );
    }

    /// Specify how the window should be positioned if the originally intended
    /// position caused the surface to be constrained, meaning at least
    /// partially outside positioning boundaries set by the compositor. The
    /// adjustment is set by constructing a bitmask describing the adjustment to
    /// be made when the surface is constrained on that axis.
    ///
    /// If no bit for one axis is set, the compositor will assume that the child
    /// surface should not change its position on that axis when constrained.
    ///
    /// If more than one bit for one axis is set, the order of how adjustments
    /// are applied is specified in the corresponding adjustment descriptions.
    ///
    /// The default adjustment is none.
    pub fn set_constraint_adjustment(
        this: @This(),
        constraint_adjustment: Constraint_adjustment,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_constraint_adjustment = .{
                .constraint_adjustment = constraint_adjustment,
            } },
        );
    }

    /// Specify the surface position offset relative to the position of the
    /// anchor on the anchor rectangle and the anchor on the surface. For
    /// example if the anchor of the anchor rectangle is at (x, y), the surface
    /// has the gravity bottom|right, and the offset is (ox, oy), the calculated
    /// surface position will be (x + ox, y + oy). The offset position of the
    /// surface is the one used for constraint testing. See
    /// set_constraint_adjustment.
    ///
    /// An example use case is placing a popup menu on top of a user interface
    /// element, while aligning the user interface element of the parent surface
    /// with some user interface element placed somewhere in the popup surface.
    pub fn set_offset(
        this: @This(),
        x: i32,
        y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_offset = .{
                .x = x,
                .y = y,
            } },
        );
    }
};

/// An interface that may be implemented by a wl_surface, for
/// implementations that provide a desktop-style user interface.
///
/// It provides a base set of functionality required to construct user
/// interface elements requiring management by the compositor, such as
/// toplevel windows, menus, etc. The types of functionality are split into
/// xdg_surface roles.
///
/// Creating an xdg_surface does not set the role for a wl_surface. In order
/// to map an xdg_surface, the client must create a role-specific object
/// using, e.g., get_toplevel, get_popup. The wl_surface for any given
/// xdg_surface can have at most one role, and may not be assigned any role
/// not based on xdg_surface.
///
/// A role must be assigned before any other requests are made to the
/// xdg_surface object.
///
/// The client must call wl_surface.commit on the corresponding wl_surface
/// for the xdg_surface state to take effect.
///
/// Creating an xdg_surface from a wl_surface which has a buffer attached or
/// committed is a client error, and any attempts by a client to attach or
/// manipulate a buffer prior to the first xdg_surface.configure call must
/// also be treated as errors.
///
/// After creating a role-specific object and setting it up, the client must
/// perform an initial commit without any buffer attached. The compositor
/// will reply with initial wl_surface state such as
/// wl_surface.preferred_buffer_scale followed by an xdg_surface.configure
/// event. The client must acknowledge it and is then allowed to attach a
/// buffer to map the surface.
///
/// Mapping an xdg_surface-based role surface is defined as making it
/// possible for the surface to be shown by the compositor. Note that
/// a mapped surface is not guaranteed to be visible once it is mapped.
///
/// For an xdg_surface to be mapped by the compositor, the following
/// conditions must be met:
/// (1) the client has assigned an xdg_surface-based role to the surface
/// (2) the client has set and committed the xdg_surface state and the
/// role-dependent state to the surface
/// (3) the client has committed a buffer to the surface
///
/// A newly-unmapped surface is considered to have met condition (1) out
/// of the 3 required conditions for mapping a surface if its role surface
/// has not been destroyed, i.e. the client must perform the initial commit
/// again before attaching a buffer.
pub const xdg_surface = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "xdg_surface",
        .version = 2,
        .delete = delete,
        .event_received = event_received,
    });

    pub fn object(this: *@This()) wayland.Object {
        return wayland.Object{
            .interface = &INTERFACE,
            .pointer = this,
        };
    }

    /// This should only be called when the wayland display sends the `delete_id` event
    pub fn delete(this: *@This()) void {
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = this.conn.deserializeAndLogErrors(Event, header, body) orelse return;
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// Surface was not fully constructed
        not_constructed = 1,
        /// Surface was already constructed
        already_constructed = 2,
        /// Attaching a buffer to an unconfigured surface
        unconfigured_buffer = 3,
        /// Invalid serial number when acking a configure event
        invalid_serial = 4,
        /// Width or height was zero or negative
        invalid_size = 5,
        /// Surface was destroyed before its role object
        defunct_role_object = 6,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        get_toplevel: struct {
            id: u32,
        },
        get_popup: struct {
            id: u32,
            parent: u32,
            positioner: u32,
        },
        set_window_geometry: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        ack_configure: struct {
            serial: u32,
        },
    };

    /// Destroy the xdg_surface object. An xdg_surface must only be destroyed
    /// after its role object has been destroyed, otherwise
    /// a defunct_role_object error is raised.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// This creates an xdg_toplevel object for the given xdg_surface and gives
    /// the associated wl_surface the xdg_toplevel role.
    ///
    /// See the documentation of xdg_toplevel for more details about what an
    /// xdg_toplevel is and how it is used.
    pub fn get_toplevel(
        this: @This(),
    ) !*xdg_toplevel {
        const new_object = try this.conn.createObject(xdg_toplevel);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_toplevel = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// This creates an xdg_popup object for the given xdg_surface and gives
    /// the associated wl_surface the xdg_popup role.
    ///
    /// If null is passed as a parent, a parent surface must be specified using
    /// some other protocol, before committing the initial state.
    ///
    /// See the documentation of xdg_popup for more details about what an
    /// xdg_popup is and how it is used.
    pub fn get_popup(
        this: @This(),
        parent: ?*xdg_surface,
        positioner: *xdg_positioner,
    ) !*xdg_popup {
        const new_object = try this.conn.createObject(xdg_popup);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_popup = .{
                .id = new_object.id,
                .parent = if (parent) |obj| obj.id else 0,
                .positioner = positioner.id,
            } },
        );
        return new_object;
    }

    /// The window geometry of a surface is its "visible bounds" from the
    /// user's perspective. Client-side decorations often have invisible
    /// portions like drop-shadows which should be ignored for the
    /// purposes of aligning, placing and constraining windows.
    ///
    /// The window geometry is double buffered, and will be applied at the
    /// time wl_surface.commit of the corresponding wl_surface is called.
    ///
    /// When maintaining a position, the compositor should treat the (x, y)
    /// coordinate of the window geometry as the top left corner of the window.
    /// A client changing the (x, y) window geometry coordinate should in
    /// general not alter the position of the window.
    ///
    /// Once the window geometry of the surface is set, it is not possible to
    /// unset it, and it will remain the same until set_window_geometry is
    /// called again, even if a new subsurface or buffer is attached.
    ///
    /// If never set, the value is the full bounds of the surface,
    /// including any subsurfaces. This updates dynamically on every
    /// commit. This unset is meant for extremely simple clients.
    ///
    /// The arguments are given in the surface-local coordinate space of
    /// the wl_surface associated with this xdg_surface, and may extend outside
    /// of the wl_surface itself to mark parts of the subsurface tree as part of
    /// the window geometry.
    ///
    /// When applied, the effective window geometry will be the set window
    /// geometry clamped to the bounding rectangle of the combined
    /// geometry of the surface of the xdg_surface and the associated
    /// subsurfaces.
    ///
    /// The effective geometry will not be recalculated unless a new call to
    /// set_window_geometry is done and the new pending surface state is
    /// subsequently applied.
    ///
    /// The width and height of the effective window geometry must be
    /// greater than zero. Setting an invalid size will raise an
    /// invalid_size error.
    pub fn set_window_geometry(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_window_geometry = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    /// When a configure event is received, if a client commits the
    /// surface in response to the configure event, then the client
    /// must make an ack_configure request sometime before the commit
    /// request, passing along the serial of the configure event.
    ///
    /// For instance, for toplevel surfaces the compositor might use this
    /// information to move a surface to the top left only when the client has
    /// drawn itself for the maximized or fullscreen state.
    ///
    /// If the client receives multiple configure events before it
    /// can respond to one, it only has to ack the last configure event.
    /// Acking a configure event that was never sent raises an invalid_serial
    /// error.
    ///
    /// A client is not required to commit immediately after sending
    /// an ack_configure request - it may even ack_configure several times
    /// before its next surface commit.
    ///
    /// A client may send multiple ack_configure requests before committing, but
    /// only the last request sent before a commit indicates which configure
    /// event the client really is responding to.
    ///
    /// Sending an ack_configure request consumes the serial number sent with
    /// the request, as well as serial numbers sent by all configure events
    /// sent on this xdg_surface prior to the configure event referenced by
    /// the committed serial.
    ///
    /// It is an error to issue multiple ack_configure requests referencing a
    /// serial from the same configure event, or to issue an ack_configure
    /// request referencing a serial from a configure event issued before the
    /// event identified by the last ack_configure request for the same
    /// xdg_surface. Doing so will raise an invalid_serial error.
    pub fn ack_configure(
        this: @This(),
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .ack_configure = .{
                .serial = serial,
            } },
        );
    }

    pub const Event = union(enum) {
        /// The configure event marks the end of a configure sequence. A configure
        /// sequence is a set of one or more events configuring the state of the
        /// xdg_surface, including the final xdg_surface.configure event.
        ///
        /// Where applicable, xdg_surface surface roles will during a configure
        /// sequence extend this event as a latched state sent as events before the
        /// xdg_surface.configure event. Such events should be considered to make up
        /// a set of atomically applied configuration states, where the
        /// xdg_surface.configure commits the accumulated state.
        ///
        /// Clients should arrange their surface for the new states, and then send
        /// an ack_configure request with the serial sent in this configure event at
        /// some point before committing the new surface.
        ///
        /// If the client receives multiple configure events before it can respond
        /// to one, it is free to discard all but the last event it received.
        configure: struct {
            serial: u32,
        },
    };
};

/// This interface defines an xdg_surface role which allows a surface to,
/// among other things, set window-like properties such as maximize,
/// fullscreen, and minimize, set application-specific metadata like title and
/// id, and well as trigger user interactive operations such as interactive
/// resize and move.
///
/// A xdg_toplevel by default is responsible for providing the full intended
/// visual representation of the toplevel, which depending on the window
/// state, may mean things like a title bar, window controls and drop shadow.
///
/// Unmapping an xdg_toplevel means that the surface cannot be shown
/// by the compositor until it is explicitly mapped again.
/// All active operations (e.g., move, resize) are canceled and all
/// attributes (e.g. title, state, stacking, ...) are discarded for
/// an xdg_toplevel surface when it is unmapped. The xdg_toplevel returns to
/// the state it had right after xdg_surface.get_toplevel. The client
/// can re-map the toplevel by perfoming a commit without any buffer
/// attached, waiting for a configure event and handling it as usual (see
/// xdg_surface description).
///
/// Attaching a null buffer to a toplevel unmaps the surface.
pub const xdg_toplevel = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "xdg_toplevel",
        .version = 2,
        .delete = delete,
        .event_received = event_received,
    });

    pub fn object(this: *@This()) wayland.Object {
        return wayland.Object{
            .interface = &INTERFACE,
            .pointer = this,
        };
    }

    /// This should only be called when the wayland display sends the `delete_id` event
    pub fn delete(this: *@This()) void {
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = this.conn.deserializeAndLogErrors(Event, header, body) orelse return;
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// provided value is
        ///         not a valid variant of the resize_edge enum
        invalid_resize_edge = 0,
        /// invalid parent toplevel
        invalid_parent = 1,
        /// client provided an invalid min or max size
        invalid_size = 2,
    };

    pub const Resize_edge = enum(u32) {
        none = 0,
        top = 1,
        bottom = 2,
        left = 4,
        top_left = 5,
        bottom_left = 6,
        right = 8,
        top_right = 9,
        bottom_right = 10,
    };

    pub const State = enum(u32) {
        /// the surface is maximized
        maximized = 1,
        /// the surface is fullscreen
        fullscreen = 2,
        /// the surface is being resized
        resizing = 3,
        /// the surface is now activated
        activated = 4,
        tiled_left = 5,
        tiled_right = 6,
        tiled_top = 7,
        tiled_bottom = 8,
        suspended = 9,
    };

    pub const Wm_capabilities = enum(u32) {};

    pub const Request = union(enum) {
        destroy: struct {},
        set_parent: struct {
            parent: u32,
        },
        set_title: struct {
            title: ?[:0]const u8,
        },
        set_app_id: struct {
            app_id: ?[:0]const u8,
        },
        show_window_menu: struct {
            seat: u32,
            serial: u32,
            x: i32,
            y: i32,
        },
        move: struct {
            seat: u32,
            serial: u32,
        },
        resize: struct {
            seat: u32,
            serial: u32,
            edges: Resize_edge,
        },
        set_max_size: struct {
            width: i32,
            height: i32,
        },
        set_min_size: struct {
            width: i32,
            height: i32,
        },
        set_maximized: struct {},
        unset_maximized: struct {},
        set_fullscreen: struct {
            output: u32,
        },
        unset_fullscreen: struct {},
        set_minimized: struct {},
    };

    /// This request destroys the role surface and unmaps the surface;
    /// see "Unmapping" behavior in interface section for details.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Set the "parent" of this surface. This surface should be stacked
    /// above the parent surface and all other ancestor surfaces.
    ///
    /// Parent surfaces should be set on dialogs, toolboxes, or other
    /// "auxiliary" surfaces, so that the parent is raised when the dialog
    /// is raised.
    ///
    /// Setting a null parent for a child surface unsets its parent. Setting
    /// a null parent for a surface which currently has no parent is a no-op.
    ///
    /// Only mapped surfaces can have child surfaces. Setting a parent which
    /// is not mapped is equivalent to setting a null parent. If a surface
    /// becomes unmapped, its children's parent is set to the parent of
    /// the now-unmapped surface. If the now-unmapped surface has no parent,
    /// its children's parent is unset. If the now-unmapped surface becomes
    /// mapped again, its parent-child relationship is not restored.
    ///
    /// The parent toplevel must not be one of the child toplevel's
    /// descendants, and the parent must be different from the child toplevel,
    /// otherwise the invalid_parent protocol error is raised.
    pub fn set_parent(
        this: @This(),
        parent: ?*xdg_toplevel,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_parent = .{
                .parent = if (parent) |obj| obj.id else 0,
            } },
        );
    }

    /// Set a short title for the surface.
    ///
    /// This string may be used to identify the surface in a task bar,
    /// window list, or other user interface elements provided by the
    /// compositor.
    ///
    /// The string must be encoded in UTF-8.
    pub fn set_title(
        this: @This(),
        title: ?[:0]const u8,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_title = .{
                .title = title,
            } },
        );
    }

    /// Set an application identifier for the surface.
    ///
    /// The app ID identifies the general class of applications to which
    /// the surface belongs. The compositor can use this to group multiple
    /// surfaces together, or to determine how to launch a new application.
    ///
    /// For D-Bus activatable applications, the app ID is used as the D-Bus
    /// service name.
    ///
    /// The compositor shell will try to group application surfaces together
    /// by their app ID. As a best practice, it is suggested to select app
    /// ID's that match the basename of the application's .desktop file.
    /// For example, "org.freedesktop.FooViewer" where the .desktop file is
    /// "org.freedesktop.FooViewer.desktop".
    ///
    /// Like other properties, a set_app_id request can be sent after the
    /// xdg_toplevel has been mapped to update the property.
    ///
    /// See the desktop-entry specification [0] for more details on
    /// application identifiers and how they relate to well-known D-Bus
    /// names and .desktop files.
    ///
    /// [0] https://standards.freedesktop.org/desktop-entry-spec/
    pub fn set_app_id(
        this: @This(),
        app_id: ?[:0]const u8,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_app_id = .{
                .app_id = app_id,
            } },
        );
    }

    /// Clients implementing client-side decorations might want to show
    /// a context menu when right-clicking on the decorations, giving the
    /// user a menu that they can use to maximize or minimize the window.
    ///
    /// This request asks the compositor to pop up such a window menu at
    /// the given position, relative to the local surface coordinates of
    /// the parent surface. There are no guarantees as to what menu items
    /// the window menu contains, or even if a window menu will be drawn
    /// at all.
    ///
    /// This request must be used in response to some sort of user action
    /// like a button press, key press, or touch down event.
    pub fn show_window_menu(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
        x: i32,
        y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .show_window_menu = .{
                .seat = seat.id,
                .serial = serial,
                .x = x,
                .y = y,
            } },
        );
    }

    /// Start an interactive, user-driven move of the surface.
    ///
    /// This request must be used in response to some sort of user action
    /// like a button press, key press, or touch down event. The passed
    /// serial is used to determine the type of interactive move (touch,
    /// pointer, etc).
    ///
    /// The server may ignore move requests depending on the state of
    /// the surface (e.g. fullscreen or maximized), or if the passed serial
    /// is no longer valid.
    ///
    /// If triggered, the surface will lose the focus of the device
    /// (wl_pointer, wl_touch, etc) used for the move. It is up to the
    /// compositor to visually indicate that the move is taking place, such as
    /// updating a pointer cursor, during the move. There is no guarantee
    /// that the device focus will return when the move is completed.
    pub fn move(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .move = .{
                .seat = seat.id,
                .serial = serial,
            } },
        );
    }

    /// Start a user-driven, interactive resize of the surface.
    ///
    /// This request must be used in response to some sort of user action
    /// like a button press, key press, or touch down event. The passed
    /// serial is used to determine the type of interactive resize (touch,
    /// pointer, etc).
    ///
    /// The server may ignore resize requests depending on the state of
    /// the surface (e.g. fullscreen or maximized).
    ///
    /// If triggered, the client will receive configure events with the
    /// "resize" state enum value and the expected sizes. See the "resize"
    /// enum value for more details about what is required. The client
    /// must also acknowledge configure events using "ack_configure". After
    /// the resize is completed, the client will receive another "configure"
    /// event without the resize state.
    ///
    /// If triggered, the surface also will lose the focus of the device
    /// (wl_pointer, wl_touch, etc) used for the resize. It is up to the
    /// compositor to visually indicate that the resize is taking place,
    /// such as updating a pointer cursor, during the resize. There is no
    /// guarantee that the device focus will return when the resize is
    /// completed.
    ///
    /// The edges parameter specifies how the surface should be resized, and
    /// is one of the values of the resize_edge enum. Values not matching
    /// a variant of the enum will cause the invalid_resize_edge protocol error.
    /// The compositor may use this information to update the surface position
    /// for example when dragging the top left corner. The compositor may also
    /// use this information to adapt its behavior, e.g. choose an appropriate
    /// cursor image.
    pub fn resize(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
        edges: Resize_edge,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .resize = .{
                .seat = seat.id,
                .serial = serial,
                .edges = edges,
            } },
        );
    }

    /// Set a maximum size for the window.
    ///
    /// The client can specify a maximum size so that the compositor does
    /// not try to configure the window beyond this size.
    ///
    /// The width and height arguments are in window geometry coordinates.
    /// See xdg_surface.set_window_geometry.
    ///
    /// Values set in this way are double-buffered. They will get applied
    /// on the next commit.
    ///
    /// The compositor can use this information to allow or disallow
    /// different states like maximize or fullscreen and draw accurate
    /// animations.
    ///
    /// Similarly, a tiling window manager may use this information to
    /// place and resize client windows in a more effective way.
    ///
    /// The client should not rely on the compositor to obey the maximum
    /// size. The compositor may decide to ignore the values set by the
    /// client and request a larger size.
    ///
    /// If never set, or a value of zero in the request, means that the
    /// client has no expected maximum size in the given dimension.
    /// As a result, a client wishing to reset the maximum size
    /// to an unspecified state can use zero for width and height in the
    /// request.
    ///
    /// Requesting a maximum size to be smaller than the minimum size of
    /// a surface is illegal and will result in an invalid_size error.
    ///
    /// The width and height must be greater than or equal to zero. Using
    /// strictly negative values for width or height will result in a
    /// invalid_size error.
    pub fn set_max_size(
        this: @This(),
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_max_size = .{
                .width = width,
                .height = height,
            } },
        );
    }

    /// Set a minimum size for the window.
    ///
    /// The client can specify a minimum size so that the compositor does
    /// not try to configure the window below this size.
    ///
    /// The width and height arguments are in window geometry coordinates.
    /// See xdg_surface.set_window_geometry.
    ///
    /// Values set in this way are double-buffered. They will get applied
    /// on the next commit.
    ///
    /// The compositor can use this information to allow or disallow
    /// different states like maximize or fullscreen and draw accurate
    /// animations.
    ///
    /// Similarly, a tiling window manager may use this information to
    /// place and resize client windows in a more effective way.
    ///
    /// The client should not rely on the compositor to obey the minimum
    /// size. The compositor may decide to ignore the values set by the
    /// client and request a smaller size.
    ///
    /// If never set, or a value of zero in the request, means that the
    /// client has no expected minimum size in the given dimension.
    /// As a result, a client wishing to reset the minimum size
    /// to an unspecified state can use zero for width and height in the
    /// request.
    ///
    /// Requesting a minimum size to be larger than the maximum size of
    /// a surface is illegal and will result in an invalid_size error.
    ///
    /// The width and height must be greater than or equal to zero. Using
    /// strictly negative values for width and height will result in a
    /// invalid_size error.
    pub fn set_min_size(
        this: @This(),
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_min_size = .{
                .width = width,
                .height = height,
            } },
        );
    }

    /// Maximize the surface.
    ///
    /// After requesting that the surface should be maximized, the compositor
    /// will respond by emitting a configure event. Whether this configure
    /// actually sets the window maximized is subject to compositor policies.
    /// The client must then update its content, drawing in the configured
    /// state. The client must also acknowledge the configure when committing
    /// the new content (see ack_configure).
    ///
    /// It is up to the compositor to decide how and where to maximize the
    /// surface, for example which output and what region of the screen should
    /// be used.
    ///
    /// If the surface was already maximized, the compositor will still emit
    /// a configure event with the "maximized" state.
    ///
    /// If the surface is in a fullscreen state, this request has no direct
    /// effect. It may alter the state the surface is returned to when
    /// unmaximized unless overridden by the compositor.
    pub fn set_maximized(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_maximized = .{} },
        );
    }

    /// Unmaximize the surface.
    ///
    /// After requesting that the surface should be unmaximized, the compositor
    /// will respond by emitting a configure event. Whether this actually
    /// un-maximizes the window is subject to compositor policies.
    /// If available and applicable, the compositor will include the window
    /// geometry dimensions the window had prior to being maximized in the
    /// configure event. The client must then update its content, drawing it in
    /// the configured state. The client must also acknowledge the configure
    /// when committing the new content (see ack_configure).
    ///
    /// It is up to the compositor to position the surface after it was
    /// unmaximized; usually the position the surface had before maximizing, if
    /// applicable.
    ///
    /// If the surface was already not maximized, the compositor will still
    /// emit a configure event without the "maximized" state.
    ///
    /// If the surface is in a fullscreen state, this request has no direct
    /// effect. It may alter the state the surface is returned to when
    /// unmaximized unless overridden by the compositor.
    pub fn unset_maximized(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .unset_maximized = .{} },
        );
    }

    /// Make the surface fullscreen.
    ///
    /// After requesting that the surface should be fullscreened, the
    /// compositor will respond by emitting a configure event. Whether the
    /// client is actually put into a fullscreen state is subject to compositor
    /// policies. The client must also acknowledge the configure when
    /// committing the new content (see ack_configure).
    ///
    /// The output passed by the request indicates the client's preference as
    /// to which display it should be set fullscreen on. If this value is NULL,
    /// it's up to the compositor to choose which display will be used to map
    /// this surface.
    ///
    /// If the surface doesn't cover the whole output, the compositor will
    /// position the surface in the center of the output and compensate with
    /// with border fill covering the rest of the output. The content of the
    /// border fill is undefined, but should be assumed to be in some way that
    /// attempts to blend into the surrounding area (e.g. solid black).
    ///
    /// If the fullscreened surface is not opaque, the compositor must make
    /// sure that other screen content not part of the same surface tree (made
    /// up of subsurfaces, popups or similarly coupled surfaces) are not
    /// visible below the fullscreened surface.
    pub fn set_fullscreen(
        this: @This(),
        output: ?*wayland.wayland.wl_output,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_fullscreen = .{
                .output = if (output) |obj| obj.id else 0,
            } },
        );
    }

    /// Make the surface no longer fullscreen.
    ///
    /// After requesting that the surface should be unfullscreened, the
    /// compositor will respond by emitting a configure event.
    /// Whether this actually removes the fullscreen state of the client is
    /// subject to compositor policies.
    ///
    /// Making a surface unfullscreen sets states for the surface based on the following:
    /// * the state(s) it may have had before becoming fullscreen
    /// * any state(s) decided by the compositor
    /// * any state(s) requested by the client while the surface was fullscreen
    ///
    /// The compositor may include the previous window geometry dimensions in
    /// the configure event, if applicable.
    ///
    /// The client must also acknowledge the configure when committing the new
    /// content (see ack_configure).
    pub fn unset_fullscreen(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .unset_fullscreen = .{} },
        );
    }

    /// Request that the compositor minimize your surface. There is no
    /// way to know if the surface is currently minimized, nor is there
    /// any way to unset minimization on this surface.
    ///
    /// If you are looking to throttle redrawing when minimized, please
    /// instead use the wl_surface.frame event for this, as this will
    /// also work with live previews on windows in Alt-Tab, Expose or
    /// similar compositor features.
    pub fn set_minimized(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_minimized = .{} },
        );
    }

    pub const Event = union(enum) {
        /// This configure event asks the client to resize its toplevel surface or
        /// to change its state. The configured state should not be applied
        /// immediately. See xdg_surface.configure for details.
        ///
        /// The width and height arguments specify a hint to the window
        /// about how its surface should be resized in window geometry
        /// coordinates. See set_window_geometry.
        ///
        /// If the width or height arguments are zero, it means the client
        /// should decide its own window dimension. This may happen when the
        /// compositor needs to configure the state of the surface but doesn't
        /// have any information about any previous or expected dimension.
        ///
        /// The states listed in the event specify how the width/height
        /// arguments should be interpreted, and possibly how it should be
        /// drawn.
        ///
        /// Clients must send an ack_configure in response to this event. See
        /// xdg_surface.configure and xdg_surface.ack_configure for details.
        configure: struct {
            width: i32,
            height: i32,
            states: []const u8,
        },

        /// The close event is sent by the compositor when the user
        /// wants the surface to be closed. This should be equivalent to
        /// the user clicking the close button in client-side decorations,
        /// if your application has any.
        ///
        /// This is only a request that the user intends to close the
        /// window. The client may choose to ignore this request, or show
        /// a dialog to ask the user to save their data, etc.
        close,
    };
};

/// A popup surface is a short-lived, temporary surface. It can be used to
/// implement for example menus, popovers, tooltips and other similar user
/// interface concepts.
///
/// A popup can be made to take an explicit grab. See xdg_popup.grab for
/// details.
///
/// When the popup is dismissed, a popup_done event will be sent out, and at
/// the same time the surface will be unmapped. See the xdg_popup.popup_done
/// event for details.
///
/// Explicitly destroying the xdg_popup object will also dismiss the popup and
/// unmap the surface. Clients that want to dismiss the popup when another
/// surface of their own is clicked should dismiss the popup using the destroy
/// request.
///
/// A newly created xdg_popup will be stacked on top of all previously created
/// xdg_popup surfaces associated with the same xdg_toplevel.
///
/// The parent of an xdg_popup must be mapped (see the xdg_surface
/// description) before the xdg_popup itself.
///
/// The client must call wl_surface.commit on the corresponding wl_surface
/// for the xdg_popup state to take effect.
pub const xdg_popup = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "xdg_popup",
        .version = 2,
        .delete = delete,
        .event_received = event_received,
    });

    pub fn object(this: *@This()) wayland.Object {
        return wayland.Object{
            .interface = &INTERFACE,
            .pointer = this,
        };
    }

    /// This should only be called when the wayland display sends the `delete_id` event
    pub fn delete(this: *@This()) void {
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = this.conn.deserializeAndLogErrors(Event, header, body) orelse return;
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// tried to grab after being mapped
        invalid_grab = 0,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        grab: struct {
            seat: u32,
            serial: u32,
        },
    };

    /// This destroys the popup. Explicitly destroying the xdg_popup
    /// object will also dismiss the popup, and unmap the surface.
    ///
    /// If this xdg_popup is not the "topmost" popup, the
    /// xdg_wm_base.not_the_topmost_popup protocol error will be sent.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// This request makes the created popup take an explicit grab. An explicit
    /// grab will be dismissed when the user dismisses the popup, or when the
    /// client destroys the xdg_popup. This can be done by the user clicking
    /// outside the surface, using the keyboard, or even locking the screen
    /// through closing the lid or a timeout.
    ///
    /// If the compositor denies the grab, the popup will be immediately
    /// dismissed.
    ///
    /// This request must be used in response to some sort of user action like a
    /// button press, key press, or touch down event. The serial number of the
    /// event should be passed as 'serial'.
    ///
    /// The parent of a grabbing popup must either be an xdg_toplevel surface or
    /// another xdg_popup with an explicit grab. If the parent is another
    /// xdg_popup it means that the popups are nested, with this popup now being
    /// the topmost popup.
    ///
    /// Nested popups must be destroyed in the reverse order they were created
    /// in, e.g. the only popup you are allowed to destroy at all times is the
    /// topmost one.
    ///
    /// When compositors choose to dismiss a popup, they may dismiss every
    /// nested grabbing popup as well. When a compositor dismisses popups, it
    /// will follow the same dismissing order as required from the client.
    ///
    /// If the topmost grabbing popup is destroyed, the grab will be returned to
    /// the parent of the popup, if that parent previously had an explicit grab.
    ///
    /// If the parent is a grabbing popup which has already been dismissed, this
    /// popup will be immediately dismissed. If the parent is a popup that did
    /// not take an explicit grab, an error will be raised.
    ///
    /// During a popup grab, the client owning the grab will receive pointer
    /// and touch events for all their surfaces as normal (similar to an
    /// "owner-events" grab in X11 parlance), while the top most grabbing popup
    /// will always have keyboard focus.
    pub fn grab(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .grab = .{
                .seat = seat.id,
                .serial = serial,
            } },
        );
    }

    pub const Event = union(enum) {
        /// This event asks the popup surface to configure itself given the
        /// configuration. The configured state should not be applied immediately.
        /// See xdg_surface.configure for details.
        ///
        /// The x and y arguments represent the position the popup was placed at
        /// given the xdg_positioner rule, relative to the upper left corner of the
        /// window geometry of the parent surface.
        ///
        /// For version 2 or older, the configure event for an xdg_popup is only
        /// ever sent once for the initial configuration. Starting with version 3,
        /// it may be sent again if the popup is setup with an xdg_positioner with
        /// set_reactive requested, or in response to xdg_popup.reposition requests.
        configure: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },

        /// The popup_done event is sent out when a popup is dismissed by the
        /// compositor. The client should destroy the xdg_popup object at this
        /// point.
        popup_done,
    };
};

const wayland = @import("wayland");
const std = @import("std");

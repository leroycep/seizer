// Copyright © 2018 Simon Ser
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

/// This interface allows a compositor to announce support for server-side
/// decorations.
/// 
/// A window decoration is a set of window controls as deemed appropriate by
/// the party managing them, such as user interface components used to move,
/// resize and change a window's state.
/// 
/// A client can use this protocol to request being decorated by a supporting
/// compositor.
/// 
/// If compositor and client do not negotiate the use of a server-side
/// decoration using this protocol, clients continue to self-decorate as they
/// see fit.
/// 
/// Warning! The protocol described in this file is experimental and
/// backward incompatible changes may be made. Backward compatible changes
/// may be added together with the corresponding interface version bump.
/// Backward incompatible changes are done by bumping the version number in
/// the protocol and interface names and resetting the interface version.
/// Once the protocol is to be declared stable, the 'z' prefix and the
/// version number in the protocol and interface names are removed and the
/// interface version number is reset.
pub const zxdg_decoration_manager_v1 = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_delete: ?*const fn(this: *@This(), userdata: ?*anyopaque) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
    .name = "zxdg_decoration_manager_v1",
    .version = 1,
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
        if (this.on_delete) |on_delete| on_delete(this, this.userdata);
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }
    pub const Request = union(enum) {
        destroy: struct {
        },
        get_toplevel_decoration: struct {
            id: u32,
            toplevel: u32,
        },
    };

    /// Destroy the decoration manager. This doesn't destroy objects created
    /// with the manager.
    pub fn destroy(
        this: @This(),
    ) !void {
try this.conn.send(
    Request,
    this.id,
    .{ .destroy = .{
    } },
);
    }

    /// Create a new decoration object associated with the given toplevel.
    /// 
    /// Creating an xdg_toplevel_decoration from an xdg_toplevel which has a
    /// buffer attached or committed is a client error, and any attempts by a
    /// client to attach or manipulate a buffer prior to the first
    /// xdg_toplevel_decoration.configure event must also be treated as
    /// errors.
    pub fn get_toplevel_decoration(
        this: @This(),
        toplevel: *wayland_protocols.stable.@"xdg-shell".xdg_toplevel,
    ) !*zxdg_toplevel_decoration_v1 {
const new_object = try this.conn.createObject(zxdg_toplevel_decoration_v1);
try this.conn.send(
    Request,
    this.id,
    .{ .get_toplevel_decoration = .{
        .id = new_object.id,
        .toplevel = toplevel.id,
    } },
);
return new_object;
    }

};

/// The decoration object allows the compositor to toggle server-side window
/// decorations for a toplevel surface. The client can request to switch to
/// another mode.
/// 
/// The xdg_toplevel_decoration object must be destroyed before its
/// xdg_toplevel.
pub const zxdg_toplevel_decoration_v1 = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_delete: ?*const fn(this: *@This(), userdata: ?*anyopaque) void = null,
    on_event: ?*const fn(this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
    .name = "zxdg_toplevel_decoration_v1",
    .version = 1,
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
        if (this.on_delete) |on_delete| on_delete(this, this.userdata);
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
        /// xdg_toplevel has a buffer attached before configure
        unconfigured_buffer = 0,
        /// xdg_toplevel already has a decoration object
        already_constructed = 1,
        /// xdg_toplevel destroyed before the decoration object
        orphaned = 2,
        /// invalid mode
        invalid_mode = 3,
    };

    pub const Mode = enum(u32) {
        /// no server-side window decoration
        client_side = 1,
        /// server-side window decoration
        server_side = 2,
    };

    pub const Request = union(enum) {
        destroy: struct {
        },
        set_mode: struct {
            mode: Mode,
        },
        unset_mode: struct {
        },
    };

    /// Switch back to a mode without any server-side decorations at the next
    /// commit.
    pub fn destroy(
        this: @This(),
    ) !void {
try this.conn.send(
    Request,
    this.id,
    .{ .destroy = .{
    } },
);
    }

    /// Set the toplevel surface decoration mode. This informs the compositor
    /// that the client prefers the provided decoration mode.
    /// 
    /// After requesting a decoration mode, the compositor will respond by
    /// emitting an xdg_surface.configure event. The client should then update
    /// its content, drawing it without decorations if the received mode is
    /// server-side decorations. The client must also acknowledge the configure
    /// when committing the new content (see xdg_surface.ack_configure).
    /// 
    /// The compositor can decide not to use the client's mode and enforce a
    /// different mode instead.
    /// 
    /// Clients whose decoration mode depend on the xdg_toplevel state may send
    /// a set_mode request in response to an xdg_surface.configure event and wait
    /// for the next xdg_surface.configure event to prevent unwanted state.
    /// Such clients are responsible for preventing configure loops and must
    /// make sure not to send multiple successive set_mode requests with the
    /// same decoration mode.
    /// 
    /// If an invalid mode is supplied by the client, the invalid_mode protocol
    /// error is raised by the compositor.
    pub fn set_mode(
        this: @This(),
        mode: Mode,
    ) !void {
try this.conn.send(
    Request,
    this.id,
    .{ .set_mode = .{
        .mode = mode,
    } },
);
    }

    /// Unset the toplevel surface decoration mode. This informs the compositor
    /// that the client doesn't prefer a particular decoration mode.
    /// 
    /// This request has the same semantics as set_mode.
    pub fn unset_mode(
        this: @This(),
    ) !void {
try this.conn.send(
    Request,
    this.id,
    .{ .unset_mode = .{
    } },
);
    }

    pub const Event = union(enum) {
        /// The configure event configures the effective decoration mode. The
        /// configured state should not be applied immediately. Clients must send an
        /// ack_configure in response to this event. See xdg_surface.configure and
        /// xdg_surface.ack_configure for details.
        /// 
        /// A configure event can be sent at any time. The specified mode must be
        /// obeyed by the client.
        configure: struct {
            mode: Mode,
        },

    };

};

const wayland = @import("wayland");
const wayland_protocols = @import("../protocols.zig");
const std = @import("std");

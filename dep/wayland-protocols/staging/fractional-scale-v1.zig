// Copyright © 2022 Kenny Levinsen
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

/// A global interface for requesting surfaces to use fractional scales.
pub const wp_fractional_scale_manager_v1 = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_delete: ?*const fn(this: *@This(), userdata: ?*anyopaque) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
    .name = "wp_fractional_scale_manager_v1",
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
    pub const Error = enum(u32) {
        /// the surface already has a fractional_scale object associated
        fractional_scale_exists = 0,
    };

    pub const Request = union(enum) {
        destroy: struct {
        },
        get_fractional_scale: struct {
            id: u32,
            surface: u32,
        },
    };

    /// Informs the server that the client will not be using this protocol
    /// object anymore. This does not affect any other objects,
    /// wp_fractional_scale_v1 objects included.
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

    /// Create an add-on object for the the wl_surface to let the compositor
    /// request fractional scales. If the given wl_surface already has a
    /// wp_fractional_scale_v1 object associated, the fractional_scale_exists
    /// protocol error is raised.
    pub fn get_fractional_scale(
        this: @This(),
        surface: *wayland.wayland.wl_surface,
    ) !*wp_fractional_scale_v1 {
const new_object = try this.conn.createObject(wp_fractional_scale_v1);
try this.conn.send(
    Request,
    this.id,
    .{ .get_fractional_scale = .{
        .id = new_object.id,
        .surface = surface.id,
    } },
);
return new_object;
    }

};

/// An additional interface to a wl_surface object which allows the compositor
/// to inform the client of the preferred scale.
pub const wp_fractional_scale_v1 = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_delete: ?*const fn(this: *@This(), userdata: ?*anyopaque) void = null,
    on_event: ?*const fn(this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
    .name = "wp_fractional_scale_v1",
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
    pub const Request = union(enum) {
        destroy: struct {
        },
    };

    /// Destroy the fractional scale object. When this object is destroyed,
    /// preferred_scale events will no longer be sent.
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

    pub const Event = union(enum) {
        /// Notification of a new preferred scale for this surface that the
        /// compositor suggests that the client should use.
        /// 
        /// The sent scale is the numerator of a fraction with a denominator of 120.
        preferred_scale: struct {
            scale: u32,
        },

    };

};

const wayland = @import("wayland");
const wayland_protocols = @import("../protocols.zig");
const std = @import("std");

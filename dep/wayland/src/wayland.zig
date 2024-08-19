// Copyright © 2008-2011 Kristian Høgsberg
// Copyright © 2010-2011 Intel Corporation
// Copyright © 2012-2013 Collabora, Ltd.
//
// Permission is hereby granted, free of charge, to any person
// obtaining a copy of this software and associated documentation files
// (the "Software"), to deal in the Software without restriction,
// including without limitation the rights to use, copy, modify, merge,
// publish, distribute, sublicense, and/or sell copies of the Software,
// and to permit persons to whom the Software is furnished to do so,
// subject to the following conditions:
//
// The above copyright notice and this permission notice (including the
// next paragraph) shall be included in all copies or substantial
// portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
// EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
// MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
// NONINFRINGEMENT.  IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS
// BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
// ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

/// The core global object.  This is a special singleton object.  It
/// is used for internal Wayland protocol features.
pub const wl_display = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_display",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// server couldn't find object
        invalid_object = 0,
        /// method doesn't exist on the specified interface or malformed request
        invalid_method = 1,
        /// server is out of memory
        no_memory = 2,
        /// implementation error in compositor
        implementation = 3,
    };

    pub const Request = union(enum) {
        sync: struct {
            callback: u32,
        },
        get_registry: struct {
            registry: u32,
        },
    };

    /// The sync request asks the server to emit the 'done' event
    /// on the returned wl_callback object.  Since requests are
    /// handled in-order and events are delivered in-order, this can
    /// be used as a barrier to ensure all previous requests and the
    /// resulting events have been handled.
    ///
    /// The object returned by this request will be destroyed by the
    /// compositor after the callback is fired and as such the client must not
    /// attempt to use it after that point.
    ///
    /// The callback_data passed in the callback is the event serial.
    pub fn sync(
        this: @This(),
    ) !*wl_callback {
        const new_object = try this.conn.createObject(wl_callback);
        try this.conn.send(
            Request,
            this.id,
            .{ .sync = .{
                .callback = new_object.id,
            } },
        );
        return new_object;
    }

    /// This request creates a registry object that allows the client
    /// to list and bind the global objects available from the
    /// compositor.
    ///
    /// It should be noted that the server side resources consumed in
    /// response to a get_registry request can only be released when the
    /// client disconnects, not when the client side proxy is destroyed.
    /// Therefore, clients should invoke get_registry as infrequently as
    /// possible to avoid wasting memory.
    pub fn get_registry(
        this: @This(),
    ) !*wl_registry {
        const new_object = try this.conn.createObject(wl_registry);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_registry = .{
                .registry = new_object.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {
        /// The error event is sent out when a fatal (non-recoverable)
        /// error has occurred.  The object_id argument is the object
        /// where the error occurred, most often in response to a request
        /// to that object.  The code identifies the error and is defined
        /// by the object interface.  As such, each interface defines its
        /// own set of error codes.  The message is a brief description
        /// of the error, for (debugging) convenience.
        @"error": struct {
            object_id: u32,
            code: u32,
            message: ?[:0]const u8,
        },

        /// This event is used internally by the object ID management
        /// logic. When a client deletes an object that it had created,
        /// the server will send this event to acknowledge that it has
        /// seen the delete request. When the client receives this event,
        /// it will know that it can safely reuse the object ID.
        delete_id: struct {
            id: u32,
        },
    };
};

/// The singleton global registry object.  The server has a number of
/// global objects that are available to all clients.  These objects
/// typically represent an actual object in the server (for example,
/// an input device) or they are singleton objects that provide
/// extension functionality.
///
/// When a client creates a registry object, the registry object
/// will emit a global event for each global currently in the
/// registry.  Globals come and go as a result of device or
/// monitor hotplugs, reconfiguration or other events, and the
/// registry will send out global and global_remove events to
/// keep the client up to date with the changes.  To mark the end
/// of the initial burst of events, the client can use the
/// wl_display.sync request immediately after calling
/// wl_display.get_registry.
///
/// A client can bind to a global object by using the bind
/// request.  This creates a client-side handle that lets the object
/// emit events to the client and lets the client invoke requests on
/// the object.
pub const wl_registry = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_registry",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        bind: struct {
            name: u32,
            id_interface: [:0]const u8,
            id_version: u32,
            id: u32,
        },
    };

    /// Binds a new, client-created object to the server using the
    /// specified name as the identifier.
    pub fn bind(this: @This(), comptime T: type, name: u32) !*T {
        const new_object = try this.conn.createObject(T);
        try this.conn.send(
            Request,
            this.id,
            .{ .bind = .{
                .name = name,
                .id_interface = T.INTERFACE.name,
                .id_version = T.INTERFACE.version,
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {
        /// Notify the client of global objects.
        ///
        /// The event notifies the client that a global object with
        /// the given name is now available, and it implements the
        /// given version of the given interface.
        global: struct {
            name: u32,
            interface: ?[:0]const u8,
            version: u32,
        },

        /// Notify the client of removed global objects.
        ///
        /// This event notifies the client that the global identified
        /// by name is no longer available.  If the client bound to
        /// the global using the bind request, the client should now
        /// destroy that object.
        ///
        /// The object remains valid and requests to the object will be
        /// ignored until the client destroys it, to avoid races between
        /// the global going away and a client sending a request to it.
        global_remove: struct {
            name: u32,
        },
    };
};

/// Clients can handle the 'done' event to get notified when
/// the related request is done.
///
/// Note, because wl_callback objects are created from multiple independent
/// factory interfaces, the wl_callback interface is frozen at version 1.
pub const wl_callback = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_callback",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {};

    pub const Event = union(enum) {
        /// Notify the client when the related request is done.
        done: struct {
            callback_data: u32,
        },
    };
};

/// A compositor.  This object is a singleton global.  The
/// compositor is in charge of combining the contents of multiple
/// surfaces into one displayable output.
pub const wl_compositor = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_compositor",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        create_surface: struct {
            id: u32,
        },
        create_region: struct {
            id: u32,
        },
    };

    /// Ask the compositor to create a new surface.
    pub fn create_surface(
        this: @This(),
    ) !*wayland.wayland.wl_surface {
        const new_object = try this.conn.createObject(wayland.wayland.wl_surface);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_surface = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// Ask the compositor to create a new region.
    pub fn create_region(
        this: @This(),
    ) !*wl_region {
        const new_object = try this.conn.createObject(wl_region);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_region = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {};
};

/// The wl_shm_pool object encapsulates a piece of memory shared
/// between the compositor and client.  Through the wl_shm_pool
/// object, the client can allocate shared memory wl_buffer objects.
/// All objects created through the same pool share the same
/// underlying mapped memory. Reusing the mapped memory avoids the
/// setup/teardown overhead and is useful when interactively resizing
/// a surface or for many small buffers.
pub const wl_shm_pool = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_shm_pool",
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        create_buffer: struct {
            id: u32,
            offset: i32,
            width: i32,
            height: i32,
            stride: i32,
            format: wl_shm.Format,
        },
        destroy: struct {},
        resize: struct {
            size: i32,
        },
    };

    /// Create a wl_buffer object from the pool.
    ///
    /// The buffer is created offset bytes into the pool and has
    /// width and height as specified.  The stride argument specifies
    /// the number of bytes from the beginning of one row to the beginning
    /// of the next.  The format is the pixel format of the buffer and
    /// must be one of those advertised through the wl_shm.format event.
    ///
    /// A buffer will keep a reference to the pool it was created from
    /// so it is valid to destroy the pool immediately after creating
    /// a buffer from it.
    pub fn create_buffer(
        this: @This(),
        offset: i32,
        width: i32,
        height: i32,
        stride: i32,
        format: wl_shm.Format,
    ) !*wayland.wayland.wl_buffer {
        const new_object = try this.conn.createObject(wayland.wayland.wl_buffer);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_buffer = .{
                .id = new_object.id,
                .offset = offset,
                .width = width,
                .height = height,
                .stride = stride,
                .format = format,
            } },
        );
        return new_object;
    }

    /// Destroy the shared memory pool.
    ///
    /// The mmapped memory will be released when all
    /// buffers that have been created from this pool
    /// are gone.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// This request will cause the server to remap the backing memory
    /// for the pool from the file descriptor passed when the pool was
    /// created, but using the new size.  This request can only be
    /// used to make the pool bigger.
    ///
    /// This request only changes the amount of bytes that are mmapped
    /// by the server and does not touch the file corresponding to the
    /// file descriptor passed at creation time. It is the client's
    /// responsibility to ensure that the file is at least as big as
    /// the new pool size.
    pub fn resize(
        this: @This(),
        size: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .resize = .{
                .size = size,
            } },
        );
    }

    pub const Event = union(enum) {};
};

/// A singleton global object that provides support for shared
/// memory.
///
/// Clients can create wl_shm_pool objects using the create_pool
/// request.
///
/// On binding the wl_shm object one or more format events
/// are emitted to inform clients about the valid pixel formats
/// that can be used for buffers.
pub const wl_shm = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_shm",
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// buffer format is not known
        invalid_format = 0,
        /// invalid size or stride during pool or buffer creation
        invalid_stride = 1,
        /// mmapping the file descriptor failed
        invalid_fd = 2,
    };

    pub const Format = enum(u32) {
        /// 32-bit ARGB format, [31:0] A:R:G:B 8:8:8:8 little endian
        argb8888 = 0,
        /// 32-bit RGB format, [31:0] x:R:G:B 8:8:8:8 little endian
        xrgb8888 = 1,
        /// 8-bit color index format, [7:0] C
        c8 = 538982467,
        /// 8-bit RGB format, [7:0] R:G:B 3:3:2
        rgb332 = 943867730,
        /// 8-bit BGR format, [7:0] B:G:R 2:3:3
        bgr233 = 944916290,
        /// 16-bit xRGB format, [15:0] x:R:G:B 4:4:4:4 little endian
        xrgb4444 = 842093144,
        /// 16-bit xBGR format, [15:0] x:B:G:R 4:4:4:4 little endian
        xbgr4444 = 842089048,
        /// 16-bit RGBx format, [15:0] R:G:B:x 4:4:4:4 little endian
        rgbx4444 = 842094674,
        /// 16-bit BGRx format, [15:0] B:G:R:x 4:4:4:4 little endian
        bgrx4444 = 842094658,
        /// 16-bit ARGB format, [15:0] A:R:G:B 4:4:4:4 little endian
        argb4444 = 842093121,
        /// 16-bit ABGR format, [15:0] A:B:G:R 4:4:4:4 little endian
        abgr4444 = 842089025,
        /// 16-bit RBGA format, [15:0] R:G:B:A 4:4:4:4 little endian
        rgba4444 = 842088786,
        /// 16-bit BGRA format, [15:0] B:G:R:A 4:4:4:4 little endian
        bgra4444 = 842088770,
        /// 16-bit xRGB format, [15:0] x:R:G:B 1:5:5:5 little endian
        xrgb1555 = 892424792,
        /// 16-bit xBGR 1555 format, [15:0] x:B:G:R 1:5:5:5 little endian
        xbgr1555 = 892420696,
        /// 16-bit RGBx 5551 format, [15:0] R:G:B:x 5:5:5:1 little endian
        rgbx5551 = 892426322,
        /// 16-bit BGRx 5551 format, [15:0] B:G:R:x 5:5:5:1 little endian
        bgrx5551 = 892426306,
        /// 16-bit ARGB 1555 format, [15:0] A:R:G:B 1:5:5:5 little endian
        argb1555 = 892424769,
        /// 16-bit ABGR 1555 format, [15:0] A:B:G:R 1:5:5:5 little endian
        abgr1555 = 892420673,
        /// 16-bit RGBA 5551 format, [15:0] R:G:B:A 5:5:5:1 little endian
        rgba5551 = 892420434,
        /// 16-bit BGRA 5551 format, [15:0] B:G:R:A 5:5:5:1 little endian
        bgra5551 = 892420418,
        /// 16-bit RGB 565 format, [15:0] R:G:B 5:6:5 little endian
        rgb565 = 909199186,
        /// 16-bit BGR 565 format, [15:0] B:G:R 5:6:5 little endian
        bgr565 = 909199170,
        /// 24-bit RGB format, [23:0] R:G:B little endian
        rgb888 = 875710290,
        /// 24-bit BGR format, [23:0] B:G:R little endian
        bgr888 = 875710274,
        /// 32-bit xBGR format, [31:0] x:B:G:R 8:8:8:8 little endian
        xbgr8888 = 875709016,
        /// 32-bit RGBx format, [31:0] R:G:B:x 8:8:8:8 little endian
        rgbx8888 = 875714642,
        /// 32-bit BGRx format, [31:0] B:G:R:x 8:8:8:8 little endian
        bgrx8888 = 875714626,
        /// 32-bit ABGR format, [31:0] A:B:G:R 8:8:8:8 little endian
        abgr8888 = 875708993,
        /// 32-bit RGBA format, [31:0] R:G:B:A 8:8:8:8 little endian
        rgba8888 = 875708754,
        /// 32-bit BGRA format, [31:0] B:G:R:A 8:8:8:8 little endian
        bgra8888 = 875708738,
        /// 32-bit xRGB format, [31:0] x:R:G:B 2:10:10:10 little endian
        xrgb2101010 = 808669784,
        /// 32-bit xBGR format, [31:0] x:B:G:R 2:10:10:10 little endian
        xbgr2101010 = 808665688,
        /// 32-bit RGBx format, [31:0] R:G:B:x 10:10:10:2 little endian
        rgbx1010102 = 808671314,
        /// 32-bit BGRx format, [31:0] B:G:R:x 10:10:10:2 little endian
        bgrx1010102 = 808671298,
        /// 32-bit ARGB format, [31:0] A:R:G:B 2:10:10:10 little endian
        argb2101010 = 808669761,
        /// 32-bit ABGR format, [31:0] A:B:G:R 2:10:10:10 little endian
        abgr2101010 = 808665665,
        /// 32-bit RGBA format, [31:0] R:G:B:A 10:10:10:2 little endian
        rgba1010102 = 808665426,
        /// 32-bit BGRA format, [31:0] B:G:R:A 10:10:10:2 little endian
        bgra1010102 = 808665410,
        /// packed YCbCr format, [31:0] Cr0:Y1:Cb0:Y0 8:8:8:8 little endian
        yuyv = 1448695129,
        /// packed YCbCr format, [31:0] Cb0:Y1:Cr0:Y0 8:8:8:8 little endian
        yvyu = 1431918169,
        /// packed YCbCr format, [31:0] Y1:Cr0:Y0:Cb0 8:8:8:8 little endian
        uyvy = 1498831189,
        /// packed YCbCr format, [31:0] Y1:Cb0:Y0:Cr0 8:8:8:8 little endian
        vyuy = 1498765654,
        /// packed AYCbCr format, [31:0] A:Y:Cb:Cr 8:8:8:8 little endian
        ayuv = 1448433985,
        /// 2 plane YCbCr Cr:Cb format, 2x2 subsampled Cr:Cb plane
        nv12 = 842094158,
        /// 2 plane YCbCr Cb:Cr format, 2x2 subsampled Cb:Cr plane
        nv21 = 825382478,
        /// 2 plane YCbCr Cr:Cb format, 2x1 subsampled Cr:Cb plane
        nv16 = 909203022,
        /// 2 plane YCbCr Cb:Cr format, 2x1 subsampled Cb:Cr plane
        nv61 = 825644622,
        /// 3 plane YCbCr format, 4x4 subsampled Cb (1) and Cr (2) planes
        yuv410 = 961959257,
        /// 3 plane YCbCr format, 4x4 subsampled Cr (1) and Cb (2) planes
        yvu410 = 961893977,
        /// 3 plane YCbCr format, 4x1 subsampled Cb (1) and Cr (2) planes
        yuv411 = 825316697,
        /// 3 plane YCbCr format, 4x1 subsampled Cr (1) and Cb (2) planes
        yvu411 = 825316953,
        /// 3 plane YCbCr format, 2x2 subsampled Cb (1) and Cr (2) planes
        yuv420 = 842093913,
        /// 3 plane YCbCr format, 2x2 subsampled Cr (1) and Cb (2) planes
        yvu420 = 842094169,
        /// 3 plane YCbCr format, 2x1 subsampled Cb (1) and Cr (2) planes
        yuv422 = 909202777,
        /// 3 plane YCbCr format, 2x1 subsampled Cr (1) and Cb (2) planes
        yvu422 = 909203033,
        /// 3 plane YCbCr format, non-subsampled Cb (1) and Cr (2) planes
        yuv444 = 875713881,
        /// 3 plane YCbCr format, non-subsampled Cr (1) and Cb (2) planes
        yvu444 = 875714137,
        /// [7:0] R
        r8 = 538982482,
        /// [15:0] R little endian
        r16 = 540422482,
        /// [15:0] R:G 8:8 little endian
        rg88 = 943212370,
        /// [15:0] G:R 8:8 little endian
        gr88 = 943215175,
        /// [31:0] R:G 16:16 little endian
        rg1616 = 842221394,
        /// [31:0] G:R 16:16 little endian
        gr1616 = 842224199,
        /// [63:0] x:R:G:B 16:16:16:16 little endian
        xrgb16161616f = 1211388504,
        /// [63:0] x:B:G:R 16:16:16:16 little endian
        xbgr16161616f = 1211384408,
        /// [63:0] A:R:G:B 16:16:16:16 little endian
        argb16161616f = 1211388481,
        /// [63:0] A:B:G:R 16:16:16:16 little endian
        abgr16161616f = 1211384385,
        /// [31:0] X:Y:Cb:Cr 8:8:8:8 little endian
        xyuv8888 = 1448434008,
        /// [23:0] Cr:Cb:Y 8:8:8 little endian
        vuy888 = 875713878,
        /// Y followed by U then V, 10:10:10. Non-linear modifier only
        vuy101010 = 808670550,
        /// [63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 10:6:10:6:10:6:10:6 little endian per 2 Y pixels
        y210 = 808530521,
        /// [63:0] Cr0:0:Y1:0:Cb0:0:Y0:0 12:4:12:4:12:4:12:4 little endian per 2 Y pixels
        y212 = 842084953,
        /// [63:0] Cr0:Y1:Cb0:Y0 16:16:16:16 little endian per 2 Y pixels
        y216 = 909193817,
        /// [31:0] A:Cr:Y:Cb 2:10:10:10 little endian
        y410 = 808531033,
        /// [63:0] A:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian
        y412 = 842085465,
        /// [63:0] A:Cr:Y:Cb 16:16:16:16 little endian
        y416 = 909194329,
        /// [31:0] X:Cr:Y:Cb 2:10:10:10 little endian
        xvyu2101010 = 808670808,
        /// [63:0] X:0:Cr:0:Y:0:Cb:0 12:4:12:4:12:4:12:4 little endian
        xvyu12_16161616 = 909334104,
        /// [63:0] X:Cr:Y:Cb 16:16:16:16 little endian
        xvyu16161616 = 942954072,
        /// [63:0]   A3:A2:Y3:0:Cr0:0:Y2:0:A1:A0:Y1:0:Cb0:0:Y0:0  1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian
        y0l0 = 810299481,
        /// [63:0]   X3:X2:Y3:0:Cr0:0:Y2:0:X1:X0:Y1:0:Cb0:0:Y0:0  1:1:8:2:8:2:8:2:1:1:8:2:8:2:8:2 little endian
        x0l0 = 810299480,
        /// [63:0]   A3:A2:Y3:Cr0:Y2:A1:A0:Y1:Cb0:Y0  1:1:10:10:10:1:1:10:10:10 little endian
        y0l2 = 843853913,
        /// [63:0]   X3:X2:Y3:Cr0:Y2:X1:X0:Y1:Cb0:Y0  1:1:10:10:10:1:1:10:10:10 little endian
        x0l2 = 843853912,
        yuv420_8bit = 942691673,
        yuv420_10bit = 808539481,
        xrgb8888_a8 = 943805016,
        xbgr8888_a8 = 943800920,
        rgbx8888_a8 = 943806546,
        bgrx8888_a8 = 943806530,
        rgb888_a8 = 943798354,
        bgr888_a8 = 943798338,
        rgb565_a8 = 943797586,
        bgr565_a8 = 943797570,
        /// non-subsampled Cr:Cb plane
        nv24 = 875714126,
        /// non-subsampled Cb:Cr plane
        nv42 = 842290766,
        /// 2x1 subsampled Cr:Cb plane, 10 bit per channel
        p210 = 808530512,
        /// 2x2 subsampled Cr:Cb plane 10 bits per channel
        p010 = 808530000,
        /// 2x2 subsampled Cr:Cb plane 12 bits per channel
        p012 = 842084432,
        /// 2x2 subsampled Cr:Cb plane 16 bits per channel
        p016 = 909193296,
        /// [63:0] A:x:B:x:G:x:R:x 10:6:10:6:10:6:10:6 little endian
        axbxgxrx106106106106 = 808534593,
        /// 2x2 subsampled Cr:Cb plane
        nv15 = 892425806,
        q410 = 808531025,
        q401 = 825242705,
        /// [63:0] x:R:G:B 16:16:16:16 little endian
        xrgb16161616 = 942953048,
        /// [63:0] x:B:G:R 16:16:16:16 little endian
        xbgr16161616 = 942948952,
        /// [63:0] A:R:G:B 16:16:16:16 little endian
        argb16161616 = 942953025,
        /// [63:0] A:B:G:R 16:16:16:16 little endian
        abgr16161616 = 942948929,
        /// [7:0] C0:C1:C2:C3:C4:C5:C6:C7 1:1:1:1:1:1:1:1 eight pixels/byte
        c1 = 538980675,
        /// [7:0] C0:C1:C2:C3 2:2:2:2 four pixels/byte
        c2 = 538980931,
        /// [7:0] C0:C1 4:4 two pixels/byte
        c4 = 538981443,
        /// [7:0] D0:D1:D2:D3:D4:D5:D6:D7 1:1:1:1:1:1:1:1 eight pixels/byte
        d1 = 538980676,
        /// [7:0] D0:D1:D2:D3 2:2:2:2 four pixels/byte
        d2 = 538980932,
        /// [7:0] D0:D1 4:4 two pixels/byte
        d4 = 538981444,
        /// [7:0] D
        d8 = 538982468,
        /// [7:0] R0:R1:R2:R3:R4:R5:R6:R7 1:1:1:1:1:1:1:1 eight pixels/byte
        r1 = 538980690,
        /// [7:0] R0:R1:R2:R3 2:2:2:2 four pixels/byte
        r2 = 538980946,
        /// [7:0] R0:R1 4:4 two pixels/byte
        r4 = 538981458,
        /// [15:0] x:R 6:10 little endian
        r10 = 540029266,
        /// [15:0] x:R 4:12 little endian
        r12 = 540160338,
        /// [31:0] A:Cr:Cb:Y 8:8:8:8 little endian
        avuy8888 = 1498764865,
        /// [31:0] X:Cr:Cb:Y 8:8:8:8 little endian
        xvuy8888 = 1498764888,
        /// 2x2 subsampled Cr:Cb plane 10 bits per channel packed
        p030 = 808661072,
    };

    pub const Request = union(enum) {
        create_pool: struct {
            id: u32,
            fd: wayland.fd_t,
            size: i32,
        },
        release: struct {},
    };

    /// Create a new wl_shm_pool object.
    ///
    /// The pool can be used to create shared memory based buffer
    /// objects.  The server will mmap size bytes of the passed file
    /// descriptor, to use as backing memory for the pool.
    pub fn create_pool(
        this: @This(),
        fd: wayland.fd_t,
        size: i32,
    ) !*wl_shm_pool {
        const new_object = try this.conn.createObject(wl_shm_pool);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_pool = .{
                .id = new_object.id,
                .fd = fd,
                .size = size,
            } },
        );
        return new_object;
    }

    /// Using this request a client can tell the server that it is not going to
    /// use the shm object anymore.
    ///
    /// Objects created via this interface remain unaffected.
    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// Informs the client about a valid pixel format that
        /// can be used for buffers. Known formats include
        /// argb8888 and xrgb8888.
        format: struct {
            format: Format,
        },
    };
};

/// A buffer provides the content for a wl_surface. Buffers are
/// created through factory interfaces such as wl_shm, wp_linux_buffer_params
/// (from the linux-dmabuf protocol extension) or similar. It has a width and
/// a height and can be attached to a wl_surface, but the mechanism by which a
/// client provides and updates the contents is defined by the buffer factory
/// interface.
///
/// If the buffer uses a format that has an alpha channel, the alpha channel
/// is assumed to be premultiplied in the electrical color channel values
/// (after transfer function encoding) unless otherwise specified.
///
/// Note, because wl_buffer objects are created from multiple independent
/// factory interfaces, the wl_buffer interface is frozen at version 1.
pub const wl_buffer = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_buffer",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        destroy: struct {},
    };

    /// Destroy a buffer. If and how you need to release the backing
    /// storage is defined by the buffer factory interface.
    ///
    /// For possible side-effects to a surface, see wl_surface.attach.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    pub const Event = union(enum) {
        /// Sent when this wl_buffer is no longer used by the compositor.
        /// The client is now free to reuse or destroy this buffer and its
        /// backing storage.
        ///
        /// If a client receives a release event before the frame callback
        /// requested in the same wl_surface.commit that attaches this
        /// wl_buffer to a surface, then the client is immediately free to
        /// reuse the buffer and its backing storage, and does not need a
        /// second buffer for the next surface content update. Typically
        /// this is possible, when the compositor maintains a copy of the
        /// wl_surface contents, e.g. as a GL texture. This is an important
        /// optimization for GL(ES) compositors with wl_shm clients.
        release,
    };
};

/// A wl_data_offer represents a piece of data offered for transfer
/// by another client (the source client).  It is used by the
/// copy-and-paste and drag-and-drop mechanisms.  The offer
/// describes the different mime types that the data can be
/// converted to and provides the mechanism for transferring the
/// data directly from the source client.
pub const wl_data_offer = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_data_offer",
        .version = 3,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// finish request was called untimely
        invalid_finish = 0,
        /// action mask contains invalid values
        invalid_action_mask = 1,
        /// action argument has an invalid value
        invalid_action = 2,
        /// offer doesn't accept this request
        invalid_offer = 3,
    };

    pub const Request = union(enum) {
        accept: struct {
            serial: u32,
            mime_type: ?[:0]const u8,
        },
        receive: struct {
            mime_type: ?[:0]const u8,
            fd: wayland.fd_t,
        },
        destroy: struct {},
        finish: struct {},
        set_actions: struct {
            dnd_actions: wl_data_device_manager.Dnd_action,
            preferred_action: wl_data_device_manager.Dnd_action,
        },
    };

    /// Indicate that the client can accept the given mime type, or
    /// NULL for not accepted.
    ///
    /// For objects of version 2 or older, this request is used by the
    /// client to give feedback whether the client can receive the given
    /// mime type, or NULL if none is accepted; the feedback does not
    /// determine whether the drag-and-drop operation succeeds or not.
    ///
    /// For objects of version 3 or newer, this request determines the
    /// final result of the drag-and-drop operation. If the end result
    /// is that no mime types were accepted, the drag-and-drop operation
    /// will be cancelled and the corresponding drag source will receive
    /// wl_data_source.cancelled. Clients may still use this event in
    /// conjunction with wl_data_source.action for feedback.
    pub fn accept(
        this: @This(),
        serial: u32,
        mime_type: ?[:0]const u8,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .accept = .{
                .serial = serial,
                .mime_type = mime_type,
            } },
        );
    }

    /// To transfer the offered data, the client issues this request
    /// and indicates the mime type it wants to receive.  The transfer
    /// happens through the passed file descriptor (typically created
    /// with the pipe system call).  The source client writes the data
    /// in the mime type representation requested and then closes the
    /// file descriptor.
    ///
    /// The receiving client reads from the read end of the pipe until
    /// EOF and then closes its end, at which point the transfer is
    /// complete.
    ///
    /// This request may happen multiple times for different mime types,
    /// both before and after wl_data_device.drop. Drag-and-drop destination
    /// clients may preemptively fetch data or examine it more closely to
    /// determine acceptance.
    pub fn receive(
        this: @This(),
        mime_type: ?[:0]const u8,
        fd: wayland.fd_t,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .receive = .{
                .mime_type = mime_type,
                .fd = fd,
            } },
        );
    }

    /// Destroy the data offer.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Notifies the compositor that the drag destination successfully
    /// finished the drag-and-drop operation.
    ///
    /// Upon receiving this request, the compositor will emit
    /// wl_data_source.dnd_finished on the drag source client.
    ///
    /// It is a client error to perform other requests than
    /// wl_data_offer.destroy after this one. It is also an error to perform
    /// this request after a NULL mime type has been set in
    /// wl_data_offer.accept or no action was received through
    /// wl_data_offer.action.
    ///
    /// If wl_data_offer.finish request is received for a non drag and drop
    /// operation, the invalid_finish protocol error is raised.
    pub fn finish(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .finish = .{} },
        );
    }

    /// Sets the actions that the destination side client supports for
    /// this operation. This request may trigger the emission of
    /// wl_data_source.action and wl_data_offer.action events if the compositor
    /// needs to change the selected action.
    ///
    /// This request can be called multiple times throughout the
    /// drag-and-drop operation, typically in response to wl_data_device.enter
    /// or wl_data_device.motion events.
    ///
    /// This request determines the final result of the drag-and-drop
    /// operation. If the end result is that no action is accepted,
    /// the drag source will receive wl_data_source.cancelled.
    ///
    /// The dnd_actions argument must contain only values expressed in the
    /// wl_data_device_manager.dnd_actions enum, and the preferred_action
    /// argument must only contain one of those values set, otherwise it
    /// will result in a protocol error.
    ///
    /// While managing an "ask" action, the destination drag-and-drop client
    /// may perform further wl_data_offer.receive requests, and is expected
    /// to perform one last wl_data_offer.set_actions request with a preferred
    /// action other than "ask" (and optionally wl_data_offer.accept) before
    /// requesting wl_data_offer.finish, in order to convey the action selected
    /// by the user. If the preferred action is not in the
    /// wl_data_offer.source_actions mask, an error will be raised.
    ///
    /// If the "ask" action is dismissed (e.g. user cancellation), the client
    /// is expected to perform wl_data_offer.destroy right away.
    ///
    /// This request can only be made on drag-and-drop offers, a protocol error
    /// will be raised otherwise.
    pub fn set_actions(
        this: @This(),
        dnd_actions: wl_data_device_manager.Dnd_action,
        preferred_action: wl_data_device_manager.Dnd_action,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_actions = .{
                .dnd_actions = dnd_actions,
                .preferred_action = preferred_action,
            } },
        );
    }

    pub const Event = union(enum) {
        /// Sent immediately after creating the wl_data_offer object.  One
        /// event per offered mime type.
        offer: struct {
            mime_type: ?[:0]const u8,
        },

        /// This event indicates the actions offered by the data source. It
        /// will be sent immediately after creating the wl_data_offer object,
        /// or anytime the source side changes its offered actions through
        /// wl_data_source.set_actions.
        source_actions: struct {
            source_actions: wl_data_device_manager.Dnd_action,
        },

        /// This event indicates the action selected by the compositor after
        /// matching the source/destination side actions. Only one action (or
        /// none) will be offered here.
        ///
        /// This event can be emitted multiple times during the drag-and-drop
        /// operation in response to destination side action changes through
        /// wl_data_offer.set_actions.
        ///
        /// This event will no longer be emitted after wl_data_device.drop
        /// happened on the drag-and-drop destination, the client must
        /// honor the last action received, or the last preferred one set
        /// through wl_data_offer.set_actions when handling an "ask" action.
        ///
        /// Compositors may also change the selected action on the fly, mainly
        /// in response to keyboard modifier changes during the drag-and-drop
        /// operation.
        ///
        /// The most recent action received is always the valid one. Prior to
        /// receiving wl_data_device.drop, the chosen action may change (e.g.
        /// due to keyboard modifiers being pressed). At the time of receiving
        /// wl_data_device.drop the drag-and-drop destination must honor the
        /// last action received.
        ///
        /// Action changes may still happen after wl_data_device.drop,
        /// especially on "ask" actions, where the drag-and-drop destination
        /// may choose another action afterwards. Action changes happening
        /// at this stage are always the result of inter-client negotiation, the
        /// compositor shall no longer be able to induce a different action.
        ///
        /// Upon "ask" actions, it is expected that the drag-and-drop destination
        /// may potentially choose a different action and/or mime type,
        /// based on wl_data_offer.source_actions and finally chosen by the
        /// user (e.g. popping up a menu with the available options). The
        /// final wl_data_offer.set_actions and wl_data_offer.accept requests
        /// must happen before the call to wl_data_offer.finish.
        action: struct {
            dnd_action: wl_data_device_manager.Dnd_action,
        },
    };
};

/// The wl_data_source object is the source side of a wl_data_offer.
/// It is created by the source client in a data transfer and
/// provides a way to describe the offered data and a way to respond
/// to requests to transfer the data.
pub const wl_data_source = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_data_source",
        .version = 3,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// action mask contains invalid values
        invalid_action_mask = 0,
        /// source doesn't accept this request
        invalid_source = 1,
    };

    pub const Request = union(enum) {
        offer: struct {
            mime_type: ?[:0]const u8,
        },
        destroy: struct {},
        set_actions: struct {
            dnd_actions: wl_data_device_manager.Dnd_action,
        },
    };

    /// This request adds a mime type to the set of mime types
    /// advertised to targets.  Can be called several times to offer
    /// multiple types.
    pub fn offer(
        this: @This(),
        mime_type: ?[:0]const u8,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .offer = .{
                .mime_type = mime_type,
            } },
        );
    }

    /// Destroy the data source.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Sets the actions that the source side client supports for this
    /// operation. This request may trigger wl_data_source.action and
    /// wl_data_offer.action events if the compositor needs to change the
    /// selected action.
    ///
    /// The dnd_actions argument must contain only values expressed in the
    /// wl_data_device_manager.dnd_actions enum, otherwise it will result
    /// in a protocol error.
    ///
    /// This request must be made once only, and can only be made on sources
    /// used in drag-and-drop, so it must be performed before
    /// wl_data_device.start_drag. Attempting to use the source other than
    /// for drag-and-drop will raise a protocol error.
    pub fn set_actions(
        this: @This(),
        dnd_actions: wl_data_device_manager.Dnd_action,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_actions = .{
                .dnd_actions = dnd_actions,
            } },
        );
    }

    pub const Event = union(enum) {
        /// Sent when a target accepts pointer_focus or motion events.  If
        /// a target does not accept any of the offered types, type is NULL.
        ///
        /// Used for feedback during drag-and-drop.
        target: struct {
            mime_type: ?[:0]const u8,
        },

        /// Request for data from the client.  Send the data as the
        /// specified mime type over the passed file descriptor, then
        /// close it.
        send: struct {
            mime_type: ?[:0]const u8,
            fd: wayland.fd_t,
        },

        /// This data source is no longer valid. There are several reasons why
        /// this could happen:
        ///
        /// - The data source has been replaced by another data source.
        /// - The drag-and-drop operation was performed, but the drop destination
        /// did not accept any of the mime types offered through
        /// wl_data_source.target.
        /// - The drag-and-drop operation was performed, but the drop destination
        /// did not select any of the actions present in the mask offered through
        /// wl_data_source.action.
        /// - The drag-and-drop operation was performed but didn't happen over a
        /// surface.
        /// - The compositor cancelled the drag-and-drop operation (e.g. compositor
        /// dependent timeouts to avoid stale drag-and-drop transfers).
        ///
        /// The client should clean up and destroy this data source.
        ///
        /// For objects of version 2 or older, wl_data_source.cancelled will
        /// only be emitted if the data source was replaced by another data
        /// source.
        cancelled,
        /// The user performed the drop action. This event does not indicate
        /// acceptance, wl_data_source.cancelled may still be emitted afterwards
        /// if the drop destination does not accept any mime type.
        ///
        /// However, this event might however not be received if the compositor
        /// cancelled the drag-and-drop operation before this event could happen.
        ///
        /// Note that the data_source may still be used in the future and should
        /// not be destroyed here.
        dnd_drop_performed,
        /// The drop destination finished interoperating with this data
        /// source, so the client is now free to destroy this data source and
        /// free all associated data.
        ///
        /// If the action used to perform the operation was "move", the
        /// source can now delete the transferred data.
        dnd_finished,
        /// This event indicates the action selected by the compositor after
        /// matching the source/destination side actions. Only one action (or
        /// none) will be offered here.
        ///
        /// This event can be emitted multiple times during the drag-and-drop
        /// operation, mainly in response to destination side changes through
        /// wl_data_offer.set_actions, and as the data device enters/leaves
        /// surfaces.
        ///
        /// It is only possible to receive this event after
        /// wl_data_source.dnd_drop_performed if the drag-and-drop operation
        /// ended in an "ask" action, in which case the final wl_data_source.action
        /// event will happen immediately before wl_data_source.dnd_finished.
        ///
        /// Compositors may also change the selected action on the fly, mainly
        /// in response to keyboard modifier changes during the drag-and-drop
        /// operation.
        ///
        /// The most recent action received is always the valid one. The chosen
        /// action may change alongside negotiation (e.g. an "ask" action can turn
        /// into a "move" operation), so the effects of the final action must
        /// always be applied in wl_data_offer.dnd_finished.
        ///
        /// Clients can trigger cursor surface changes from this point, so
        /// they reflect the current action.
        action: struct {
            dnd_action: wl_data_device_manager.Dnd_action,
        },
    };
};

/// There is one wl_data_device per seat which can be obtained
/// from the global wl_data_device_manager singleton.
///
/// A wl_data_device provides access to inter-client data transfer
/// mechanisms such as copy-and-paste and drag-and-drop.
pub const wl_data_device = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_data_device",
        .version = 3,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// given wl_surface has another role
        role = 0,
        /// source has already been used
        used_source = 1,
    };

    pub const Request = union(enum) {
        start_drag: struct {
            source: u32,
            origin: u32,
            icon: u32,
            serial: u32,
        },
        set_selection: struct {
            source: u32,
            serial: u32,
        },
        release: struct {},
    };

    /// This request asks the compositor to start a drag-and-drop
    /// operation on behalf of the client.
    ///
    /// The source argument is the data source that provides the data
    /// for the eventual data transfer. If source is NULL, enter, leave
    /// and motion events are sent only to the client that initiated the
    /// drag and the client is expected to handle the data passing
    /// internally. If source is destroyed, the drag-and-drop session will be
    /// cancelled.
    ///
    /// The origin surface is the surface where the drag originates and
    /// the client must have an active implicit grab that matches the
    /// serial.
    ///
    /// The icon surface is an optional (can be NULL) surface that
    /// provides an icon to be moved around with the cursor.  Initially,
    /// the top-left corner of the icon surface is placed at the cursor
    /// hotspot, but subsequent wl_surface.offset requests can move the
    /// relative position. Attach requests must be confirmed with
    /// wl_surface.commit as usual. The icon surface is given the role of
    /// a drag-and-drop icon. If the icon surface already has another role,
    /// it raises a protocol error.
    ///
    /// The input region is ignored for wl_surfaces with the role of a
    /// drag-and-drop icon.
    ///
    /// The given source may not be used in any further set_selection or
    /// start_drag requests. Attempting to reuse a previously-used source
    /// may send a used_source error.
    pub fn start_drag(
        this: @This(),
        source: *wl_data_source,
        origin: *wayland.wayland.wl_surface,
        icon: *wayland.wayland.wl_surface,
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .start_drag = .{
                .source = source.id,
                .origin = origin.id,
                .icon = icon.id,
                .serial = serial,
            } },
        );
    }

    /// This request asks the compositor to set the selection
    /// to the data from the source on behalf of the client.
    ///
    /// To unset the selection, set the source to NULL.
    ///
    /// The given source may not be used in any further set_selection or
    /// start_drag requests. Attempting to reuse a previously-used source
    /// may send a used_source error.
    pub fn set_selection(
        this: @This(),
        source: *wl_data_source,
        serial: u32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_selection = .{
                .source = source.id,
                .serial = serial,
            } },
        );
    }

    /// This request destroys the data device.
    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// The data_offer event introduces a new wl_data_offer object,
        /// which will subsequently be used in either the
        /// data_device.enter event (for drag-and-drop) or the
        /// data_device.selection event (for selections).  Immediately
        /// following the data_device.data_offer event, the new data_offer
        /// object will send out data_offer.offer events to describe the
        /// mime types it offers.
        data_offer: struct {
            id: wayland.NewId(wl_data_offer),
        },

        /// This event is sent when an active drag-and-drop pointer enters
        /// a surface owned by the client.  The position of the pointer at
        /// enter time is provided by the x and y arguments, in surface-local
        /// coordinates.
        enter: struct {
            serial: u32,
            surface: u32,
            x: wayland.fixed,
            y: wayland.fixed,
            id: u32,
        },

        /// This event is sent when the drag-and-drop pointer leaves the
        /// surface and the session ends.  The client must destroy the
        /// wl_data_offer introduced at enter time at this point.
        leave,
        /// This event is sent when the drag-and-drop pointer moves within
        /// the currently focused surface. The new position of the pointer
        /// is provided by the x and y arguments, in surface-local
        /// coordinates.
        motion: struct {
            time: u32,
            x: wayland.fixed,
            y: wayland.fixed,
        },

        /// The event is sent when a drag-and-drop operation is ended
        /// because the implicit grab is removed.
        ///
        /// The drag-and-drop destination is expected to honor the last action
        /// received through wl_data_offer.action, if the resulting action is
        /// "copy" or "move", the destination can still perform
        /// wl_data_offer.receive requests, and is expected to end all
        /// transfers with a wl_data_offer.finish request.
        ///
        /// If the resulting action is "ask", the action will not be considered
        /// final. The drag-and-drop destination is expected to perform one last
        /// wl_data_offer.set_actions request, or wl_data_offer.destroy in order
        /// to cancel the operation.
        drop,
        /// The selection event is sent out to notify the client of a new
        /// wl_data_offer for the selection for this device.  The
        /// data_device.data_offer and the data_offer.offer events are
        /// sent out immediately before this event to introduce the data
        /// offer object.  The selection event is sent to a client
        /// immediately before receiving keyboard focus and when a new
        /// selection is set while the client has keyboard focus.  The
        /// data_offer is valid until a new data_offer or NULL is received
        /// or until the client loses keyboard focus.  Switching surface with
        /// keyboard focus within the same client doesn't mean a new selection
        /// will be sent.  The client must destroy the previous selection
        /// data_offer, if any, upon receiving this event.
        selection: struct {
            id: u32,
        },
    };
};

/// The wl_data_device_manager is a singleton global object that
/// provides access to inter-client data transfer mechanisms such as
/// copy-and-paste and drag-and-drop.  These mechanisms are tied to
/// a wl_seat and this interface lets a client get a wl_data_device
/// corresponding to a wl_seat.
///
/// Depending on the version bound, the objects created from the bound
/// wl_data_device_manager object will have different requirements for
/// functioning properly. See wl_data_source.set_actions,
/// wl_data_offer.accept and wl_data_offer.finish for details.
pub const wl_data_device_manager = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_data_device_manager",
        .version = 3,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Dnd_action = packed struct(u32) {
        /// copy action
        copy: bool,
        /// move action
        move: bool,
        /// ask action
        ask: bool,
        padding_1: u29 = 0,
    };

    pub const Request = union(enum) {
        create_data_source: struct {
            id: u32,
        },
        get_data_device: struct {
            id: u32,
            seat: u32,
        },
    };

    /// Create a new data source.
    pub fn create_data_source(
        this: @This(),
    ) !*wl_data_source {
        const new_object = try this.conn.createObject(wl_data_source);
        try this.conn.send(
            Request,
            this.id,
            .{ .create_data_source = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// Create a new data device for a given seat.
    pub fn get_data_device(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
    ) !*wl_data_device {
        const new_object = try this.conn.createObject(wl_data_device);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_data_device = .{
                .id = new_object.id,
                .seat = seat.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {};
};

/// This interface is implemented by servers that provide
/// desktop-style user interfaces.
///
/// It allows clients to associate a wl_shell_surface with
/// a basic surface.
///
/// Note! This protocol is deprecated and not intended for production use.
/// For desktop-style user interfaces, use xdg_shell. Compositors and clients
/// should not implement this interface.
pub const wl_shell = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_shell",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// given wl_surface has another role
        role = 0,
    };

    pub const Request = union(enum) {
        get_shell_surface: struct {
            id: u32,
            surface: u32,
        },
    };

    /// Create a shell surface for an existing surface. This gives
    /// the wl_surface the role of a shell surface. If the wl_surface
    /// already has another role, it raises a protocol error.
    ///
    /// Only one shell surface can be associated with a given surface.
    pub fn get_shell_surface(
        this: @This(),
        surface: *wayland.wayland.wl_surface,
    ) !*wl_shell_surface {
        const new_object = try this.conn.createObject(wl_shell_surface);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_shell_surface = .{
                .id = new_object.id,
                .surface = surface.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {};
};

/// An interface that may be implemented by a wl_surface, for
/// implementations that provide a desktop-style user interface.
///
/// It provides requests to treat surfaces like toplevel, fullscreen
/// or popup windows, move, resize or maximize them, associate
/// metadata like title and class, etc.
///
/// On the server side the object is automatically destroyed when
/// the related wl_surface is destroyed. On the client side,
/// wl_shell_surface_destroy() must be called before destroying
/// the wl_surface object.
pub const wl_shell_surface = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_shell_surface",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Resize = packed struct(u32) {
        /// top edge
        top: bool,
        /// bottom edge
        bottom: bool,
        /// left edge
        left: bool,
        /// top and left edges
        top_left: bool,
        /// bottom and left edges
        bottom_left: bool,
        /// right edge
        right: bool,
        /// top and right edges
        top_right: bool,
        /// bottom and right edges
        bottom_right: bool,
        padding_1: u28 = 0,
    };

    pub const Transient = packed struct(u32) {
        /// do not set keyboard focus
        inactive: bool,
        padding_1: u31 = 0,
    };

    pub const Fullscreen_method = enum(u32) {
        /// no preference, apply default policy
        default = 0,
        /// scale, preserve the surface's aspect ratio and center on output
        scale = 1,
        /// switch output mode to the smallest mode that can fit the surface, add black borders to compensate size mismatch
        driver = 2,
        /// no upscaling, center on output and add black borders to compensate size mismatch
        fill = 3,
    };

    pub const Request = union(enum) {
        pong: struct {
            serial: u32,
        },
        move: struct {
            seat: u32,
            serial: u32,
        },
        resize: struct {
            seat: u32,
            serial: u32,
            edges: Resize,
        },
        set_toplevel: struct {},
        set_transient: struct {
            parent: u32,
            x: i32,
            y: i32,
            flags: Transient,
        },
        set_fullscreen: struct {
            method: Fullscreen_method,
            framerate: u32,
            output: u32,
        },
        set_popup: struct {
            seat: u32,
            serial: u32,
            parent: u32,
            x: i32,
            y: i32,
            flags: Transient,
        },
        set_maximized: struct {
            output: u32,
        },
        set_title: struct {
            title: ?[:0]const u8,
        },
        set_class: struct {
            class_: ?[:0]const u8,
        },
    };

    /// A client must respond to a ping event with a pong request or
    /// the client may be deemed unresponsive.
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

    /// Start a pointer-driven move of the surface.
    ///
    /// This request must be used in response to a button press event.
    /// The server may ignore move requests depending on the state of
    /// the surface (e.g. fullscreen or maximized).
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

    /// Start a pointer-driven resizing of the surface.
    ///
    /// This request must be used in response to a button press event.
    /// The server may ignore resize requests depending on the state of
    /// the surface (e.g. fullscreen or maximized).
    pub fn resize(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
        edges: Resize,
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

    /// Map the surface as a toplevel surface.
    ///
    /// A toplevel surface is not fullscreen, maximized or transient.
    pub fn set_toplevel(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_toplevel = .{} },
        );
    }

    /// Map the surface relative to an existing surface.
    ///
    /// The x and y arguments specify the location of the upper left
    /// corner of the surface relative to the upper left corner of the
    /// parent surface, in surface-local coordinates.
    ///
    /// The flags argument controls details of the transient behaviour.
    pub fn set_transient(
        this: @This(),
        parent: *wayland.wayland.wl_surface,
        x: i32,
        y: i32,
        flags: Transient,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_transient = .{
                .parent = parent.id,
                .x = x,
                .y = y,
                .flags = flags,
            } },
        );
    }

    /// Map the surface as a fullscreen surface.
    ///
    /// If an output parameter is given then the surface will be made
    /// fullscreen on that output. If the client does not specify the
    /// output then the compositor will apply its policy - usually
    /// choosing the output on which the surface has the biggest surface
    /// area.
    ///
    /// The client may specify a method to resolve a size conflict
    /// between the output size and the surface size - this is provided
    /// through the method parameter.
    ///
    /// The framerate parameter is used only when the method is set
    /// to "driver", to indicate the preferred framerate. A value of 0
    /// indicates that the client does not care about framerate.  The
    /// framerate is specified in mHz, that is framerate of 60000 is 60Hz.
    ///
    /// A method of "scale" or "driver" implies a scaling operation of
    /// the surface, either via a direct scaling operation or a change of
    /// the output mode. This will override any kind of output scaling, so
    /// that mapping a surface with a buffer size equal to the mode can
    /// fill the screen independent of buffer_scale.
    ///
    /// A method of "fill" means we don't scale up the buffer, however
    /// any output scale is applied. This means that you may run into
    /// an edge case where the application maps a buffer with the same
    /// size of the output mode but buffer_scale 1 (thus making a
    /// surface larger than the output). In this case it is allowed to
    /// downscale the results to fit the screen.
    ///
    /// The compositor must reply to this request with a configure event
    /// with the dimensions for the output on which the surface will
    /// be made fullscreen.
    pub fn set_fullscreen(
        this: @This(),
        method: Fullscreen_method,
        framerate: u32,
        output: *wayland.wayland.wl_output,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_fullscreen = .{
                .method = method,
                .framerate = framerate,
                .output = output.id,
            } },
        );
    }

    /// Map the surface as a popup.
    ///
    /// A popup surface is a transient surface with an added pointer
    /// grab.
    ///
    /// An existing implicit grab will be changed to owner-events mode,
    /// and the popup grab will continue after the implicit grab ends
    /// (i.e. releasing the mouse button does not cause the popup to
    /// be unmapped).
    ///
    /// The popup grab continues until the window is destroyed or a
    /// mouse button is pressed in any other client's window. A click
    /// in any of the client's surfaces is reported as normal, however,
    /// clicks in other clients' surfaces will be discarded and trigger
    /// the callback.
    ///
    /// The x and y arguments specify the location of the upper left
    /// corner of the surface relative to the upper left corner of the
    /// parent surface, in surface-local coordinates.
    pub fn set_popup(
        this: @This(),
        seat: *wayland.wayland.wl_seat,
        serial: u32,
        parent: *wayland.wayland.wl_surface,
        x: i32,
        y: i32,
        flags: Transient,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_popup = .{
                .seat = seat.id,
                .serial = serial,
                .parent = parent.id,
                .x = x,
                .y = y,
                .flags = flags,
            } },
        );
    }

    /// Map the surface as a maximized surface.
    ///
    /// If an output parameter is given then the surface will be
    /// maximized on that output. If the client does not specify the
    /// output then the compositor will apply its policy - usually
    /// choosing the output on which the surface has the biggest surface
    /// area.
    ///
    /// The compositor will reply with a configure event telling
    /// the expected new surface size. The operation is completed
    /// on the next buffer attach to this surface.
    ///
    /// A maximized surface typically fills the entire output it is
    /// bound to, except for desktop elements such as panels. This is
    /// the main difference between a maximized shell surface and a
    /// fullscreen shell surface.
    ///
    /// The details depend on the compositor implementation.
    pub fn set_maximized(
        this: @This(),
        output: *wayland.wayland.wl_output,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_maximized = .{
                .output = output.id,
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

    /// Set a class for the surface.
    ///
    /// The surface class identifies the general class of applications
    /// to which the surface belongs. A common convention is to use the
    /// file name (or the full path if it is a non-standard location) of
    /// the application's .desktop file as the class.
    pub fn set_class(
        this: @This(),
        class_: ?[:0]const u8,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_class = .{
                .class_ = class_,
            } },
        );
    }

    pub const Event = union(enum) {
        /// Ping a client to check if it is receiving events and sending
        /// requests. A client is expected to reply with a pong request.
        ping: struct {
            serial: u32,
        },

        /// The configure event asks the client to resize its surface.
        ///
        /// The size is a hint, in the sense that the client is free to
        /// ignore it if it doesn't resize, pick a smaller size (to
        /// satisfy aspect ratio or resize in steps of NxM pixels).
        ///
        /// The edges parameter provides a hint about how the surface
        /// was resized. The client may use this information to decide
        /// how to adjust its content to the new size (e.g. a scrolling
        /// area might adjust its content position to leave the viewable
        /// content unmoved).
        ///
        /// The client is free to dismiss all but the last configure
        /// event it received.
        ///
        /// The width and height arguments specify the size of the window
        /// in surface-local coordinates.
        configure: struct {
            edges: Resize,
            width: i32,
            height: i32,
        },

        /// The popup_done event is sent out when a popup grab is broken,
        /// that is, when the user clicks a surface that doesn't belong
        /// to the client owning the popup surface.
        popup_done,
    };
};

/// A surface is a rectangular area that may be displayed on zero
/// or more outputs, and shown any number of times at the compositor's
/// discretion. They can present wl_buffers, receive user input, and
/// define a local coordinate system.
///
/// The size of a surface (and relative positions on it) is described
/// in surface-local coordinates, which may differ from the buffer
/// coordinates of the pixel content, in case a buffer_transform
/// or a buffer_scale is used.
///
/// A surface without a "role" is fairly useless: a compositor does
/// not know where, when or how to present it. The role is the
/// purpose of a wl_surface. Examples of roles are a cursor for a
/// pointer (as set by wl_pointer.set_cursor), a drag icon
/// (wl_data_device.start_drag), a sub-surface
/// (wl_subcompositor.get_subsurface), and a window as defined by a
/// shell protocol (e.g. wl_shell.get_shell_surface).
///
/// A surface can have only one role at a time. Initially a
/// wl_surface does not have a role. Once a wl_surface is given a
/// role, it is set permanently for the whole lifetime of the
/// wl_surface object. Giving the current role again is allowed,
/// unless explicitly forbidden by the relevant interface
/// specification.
///
/// Surface roles are given by requests in other interfaces such as
/// wl_pointer.set_cursor. The request should explicitly mention
/// that this request gives a role to a wl_surface. Often, this
/// request also creates a new protocol object that represents the
/// role and adds additional functionality to wl_surface. When a
/// client wants to destroy a wl_surface, they must destroy this role
/// object before the wl_surface, otherwise a defunct_role_object error is
/// sent.
///
/// Destroying the role object does not remove the role from the
/// wl_surface, but it may stop the wl_surface from "playing the role".
/// For instance, if a wl_subsurface object is destroyed, the wl_surface
/// it was created for will be unmapped and forget its position and
/// z-order. It is allowed to create a wl_subsurface for the same
/// wl_surface again, but it is not allowed to use the wl_surface as
/// a cursor (cursor is a different role than sub-surface, and role
/// switching is not allowed).
pub const wl_surface = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_surface",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// buffer scale value is invalid
        invalid_scale = 0,
        /// buffer transform value is invalid
        invalid_transform = 1,
        /// buffer size is invalid
        invalid_size = 2,
        /// buffer offset is invalid
        invalid_offset = 3,
        /// surface was destroyed before its role object
        defunct_role_object = 4,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        attach: struct {
            buffer: u32,
            x: i32,
            y: i32,
        },
        damage: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        frame: struct {
            callback: u32,
        },
        set_opaque_region: struct {
            region: u32,
        },
        set_input_region: struct {
            region: u32,
        },
        commit: struct {},
        set_buffer_transform: struct {
            transform: i32,
        },
        set_buffer_scale: struct {
            scale: i32,
        },
        damage_buffer: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        offset: struct {
            x: i32,
            y: i32,
        },
    };

    /// Deletes the surface and invalidates its object ID.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Set a buffer as the content of this surface.
    ///
    /// The new size of the surface is calculated based on the buffer
    /// size transformed by the inverse buffer_transform and the
    /// inverse buffer_scale. This means that at commit time the supplied
    /// buffer size must be an integer multiple of the buffer_scale. If
    /// that's not the case, an invalid_size error is sent.
    ///
    /// The x and y arguments specify the location of the new pending
    /// buffer's upper left corner, relative to the current buffer's upper
    /// left corner, in surface-local coordinates. In other words, the
    /// x and y, combined with the new surface size define in which
    /// directions the surface's size changes. Setting anything other than 0
    /// as x and y arguments is discouraged, and should instead be replaced
    /// with using the separate wl_surface.offset request.
    ///
    /// When the bound wl_surface version is 5 or higher, passing any
    /// non-zero x or y is a protocol violation, and will result in an
    /// 'invalid_offset' error being raised. The x and y arguments are ignored
    /// and do not change the pending state. To achieve equivalent semantics,
    /// use wl_surface.offset.
    ///
    /// Surface contents are double-buffered state, see wl_surface.commit.
    ///
    /// The initial surface contents are void; there is no content.
    /// wl_surface.attach assigns the given wl_buffer as the pending
    /// wl_buffer. wl_surface.commit makes the pending wl_buffer the new
    /// surface contents, and the size of the surface becomes the size
    /// calculated from the wl_buffer, as described above. After commit,
    /// there is no pending buffer until the next attach.
    ///
    /// Committing a pending wl_buffer allows the compositor to read the
    /// pixels in the wl_buffer. The compositor may access the pixels at
    /// any time after the wl_surface.commit request. When the compositor
    /// will not access the pixels anymore, it will send the
    /// wl_buffer.release event. Only after receiving wl_buffer.release,
    /// the client may reuse the wl_buffer. A wl_buffer that has been
    /// attached and then replaced by another attach instead of committed
    /// will not receive a release event, and is not used by the
    /// compositor.
    ///
    /// If a pending wl_buffer has been committed to more than one wl_surface,
    /// the delivery of wl_buffer.release events becomes undefined. A well
    /// behaved client should not rely on wl_buffer.release events in this
    /// case. Alternatively, a client could create multiple wl_buffer objects
    /// from the same backing storage or use wp_linux_buffer_release.
    ///
    /// Destroying the wl_buffer after wl_buffer.release does not change
    /// the surface contents. Destroying the wl_buffer before wl_buffer.release
    /// is allowed as long as the underlying buffer storage isn't re-used (this
    /// can happen e.g. on client process termination). However, if the client
    /// destroys the wl_buffer before receiving the wl_buffer.release event and
    /// mutates the underlying buffer storage, the surface contents become
    /// undefined immediately.
    ///
    /// If wl_surface.attach is sent with a NULL wl_buffer, or the pending
    /// wl_buffer has been destroyed, the following wl_surface.commit will
    /// remove the surface content.
    pub fn attach(
        this: @This(),
        buffer: ?*wayland.wayland.wl_buffer,
        x: i32,
        y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .attach = .{
                .buffer = if (buffer) |b| b.id else 0,
                .x = x,
                .y = y,
            } },
        );
    }

    /// This request is used to describe the regions where the pending
    /// buffer is different from the current surface contents, and where
    /// the surface therefore needs to be repainted. The compositor
    /// ignores the parts of the damage that fall outside of the surface.
    ///
    /// Damage is double-buffered state, see wl_surface.commit.
    ///
    /// The damage rectangle is specified in surface-local coordinates,
    /// where x and y specify the upper left corner of the damage rectangle.
    ///
    /// The initial value for pending damage is empty: no damage.
    /// wl_surface.damage adds pending damage: the new pending damage
    /// is the union of old pending damage and the given rectangle.
    ///
    /// wl_surface.commit assigns pending damage as the current damage,
    /// and clears pending damage. The server will clear the current
    /// damage as it repaints the surface.
    ///
    /// Note! New clients should not use this request. Instead damage can be
    /// posted with wl_surface.damage_buffer which uses buffer coordinates
    /// instead of surface coordinates.
    pub fn damage(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .damage = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    /// Request a notification when it is a good time to start drawing a new
    /// frame, by creating a frame callback. This is useful for throttling
    /// redrawing operations, and driving animations.
    ///
    /// When a client is animating on a wl_surface, it can use the 'frame'
    /// request to get notified when it is a good time to draw and commit the
    /// next frame of animation. If the client commits an update earlier than
    /// that, it is likely that some updates will not make it to the display,
    /// and the client is wasting resources by drawing too often.
    ///
    /// The frame request will take effect on the next wl_surface.commit.
    /// The notification will only be posted for one frame unless
    /// requested again. For a wl_surface, the notifications are posted in
    /// the order the frame requests were committed.
    ///
    /// The server must send the notifications so that a client
    /// will not send excessive updates, while still allowing
    /// the highest possible update rate for clients that wait for the reply
    /// before drawing again. The server should give some time for the client
    /// to draw and commit after sending the frame callback events to let it
    /// hit the next output refresh.
    ///
    /// A server should avoid signaling the frame callbacks if the
    /// surface is not visible in any way, e.g. the surface is off-screen,
    /// or completely obscured by other opaque surfaces.
    ///
    /// The object returned by this request will be destroyed by the
    /// compositor after the callback is fired and as such the client must not
    /// attempt to use it after that point.
    ///
    /// The callback_data passed in the callback is the current time, in
    /// milliseconds, with an undefined base.
    pub fn frame(
        this: @This(),
    ) !*wl_callback {
        const new_object = try this.conn.createObject(wl_callback);
        try this.conn.send(
            Request,
            this.id,
            .{ .frame = .{
                .callback = new_object.id,
            } },
        );
        return new_object;
    }

    /// This request sets the region of the surface that contains
    /// opaque content.
    ///
    /// The opaque region is an optimization hint for the compositor
    /// that lets it optimize the redrawing of content behind opaque
    /// regions.  Setting an opaque region is not required for correct
    /// behaviour, but marking transparent content as opaque will result
    /// in repaint artifacts.
    ///
    /// The opaque region is specified in surface-local coordinates.
    ///
    /// The compositor ignores the parts of the opaque region that fall
    /// outside of the surface.
    ///
    /// Opaque region is double-buffered state, see wl_surface.commit.
    ///
    /// wl_surface.set_opaque_region changes the pending opaque region.
    /// wl_surface.commit copies the pending region to the current region.
    /// Otherwise, the pending and current regions are never changed.
    ///
    /// The initial value for an opaque region is empty. Setting the pending
    /// opaque region has copy semantics, and the wl_region object can be
    /// destroyed immediately. A NULL wl_region causes the pending opaque
    /// region to be set to empty.
    pub fn set_opaque_region(
        this: @This(),
        region: *wl_region,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_opaque_region = .{
                .region = region.id,
            } },
        );
    }

    /// This request sets the region of the surface that can receive
    /// pointer and touch events.
    ///
    /// Input events happening outside of this region will try the next
    /// surface in the server surface stack. The compositor ignores the
    /// parts of the input region that fall outside of the surface.
    ///
    /// The input region is specified in surface-local coordinates.
    ///
    /// Input region is double-buffered state, see wl_surface.commit.
    ///
    /// wl_surface.set_input_region changes the pending input region.
    /// wl_surface.commit copies the pending region to the current region.
    /// Otherwise the pending and current regions are never changed,
    /// except cursor and icon surfaces are special cases, see
    /// wl_pointer.set_cursor and wl_data_device.start_drag.
    ///
    /// The initial value for an input region is infinite. That means the
    /// whole surface will accept input. Setting the pending input region
    /// has copy semantics, and the wl_region object can be destroyed
    /// immediately. A NULL wl_region causes the input region to be set
    /// to infinite.
    pub fn set_input_region(
        this: @This(),
        region: *wl_region,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_input_region = .{
                .region = region.id,
            } },
        );
    }

    /// Surface state (input, opaque, and damage regions, attached buffers,
    /// etc.) is double-buffered. Protocol requests modify the pending state,
    /// as opposed to the current state in use by the compositor. A commit
    /// request atomically applies all pending state, replacing the current
    /// state. After commit, the new pending state is as documented for each
    /// related request.
    ///
    /// On commit, a pending wl_buffer is applied first, and all other state
    /// second. This means that all coordinates in double-buffered state are
    /// relative to the new wl_buffer coming into use, except for
    /// wl_surface.attach itself. If there is no pending wl_buffer, the
    /// coordinates are relative to the current surface contents.
    ///
    /// All requests that need a commit to become effective are documented
    /// to affect double-buffered state.
    ///
    /// Other interfaces may add further double-buffered surface state.
    pub fn commit(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .commit = .{} },
        );
    }

    /// This request sets an optional transformation on how the compositor
    /// interprets the contents of the buffer attached to the surface. The
    /// accepted values for the transform parameter are the values for
    /// wl_output.transform.
    ///
    /// Buffer transform is double-buffered state, see wl_surface.commit.
    ///
    /// A newly created surface has its buffer transformation set to normal.
    ///
    /// wl_surface.set_buffer_transform changes the pending buffer
    /// transformation. wl_surface.commit copies the pending buffer
    /// transformation to the current one. Otherwise, the pending and current
    /// values are never changed.
    ///
    /// The purpose of this request is to allow clients to render content
    /// according to the output transform, thus permitting the compositor to
    /// use certain optimizations even if the display is rotated. Using
    /// hardware overlays and scanning out a client buffer for fullscreen
    /// surfaces are examples of such optimizations. Those optimizations are
    /// highly dependent on the compositor implementation, so the use of this
    /// request should be considered on a case-by-case basis.
    ///
    /// Note that if the transform value includes 90 or 270 degree rotation,
    /// the width of the buffer will become the surface height and the height
    /// of the buffer will become the surface width.
    ///
    /// If transform is not one of the values from the
    /// wl_output.transform enum the invalid_transform protocol error
    /// is raised.
    pub fn set_buffer_transform(
        this: @This(),
        transform: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_buffer_transform = .{
                .transform = transform,
            } },
        );
    }

    /// This request sets an optional scaling factor on how the compositor
    /// interprets the contents of the buffer attached to the window.
    ///
    /// Buffer scale is double-buffered state, see wl_surface.commit.
    ///
    /// A newly created surface has its buffer scale set to 1.
    ///
    /// wl_surface.set_buffer_scale changes the pending buffer scale.
    /// wl_surface.commit copies the pending buffer scale to the current one.
    /// Otherwise, the pending and current values are never changed.
    ///
    /// The purpose of this request is to allow clients to supply higher
    /// resolution buffer data for use on high resolution outputs. It is
    /// intended that you pick the same buffer scale as the scale of the
    /// output that the surface is displayed on. This means the compositor
    /// can avoid scaling when rendering the surface on that output.
    ///
    /// Note that if the scale is larger than 1, then you have to attach
    /// a buffer that is larger (by a factor of scale in each dimension)
    /// than the desired surface size.
    ///
    /// If scale is not greater than 0 the invalid_scale protocol error is
    /// raised.
    pub fn set_buffer_scale(
        this: @This(),
        scale: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_buffer_scale = .{
                .scale = scale,
            } },
        );
    }

    /// This request is used to describe the regions where the pending
    /// buffer is different from the current surface contents, and where
    /// the surface therefore needs to be repainted. The compositor
    /// ignores the parts of the damage that fall outside of the surface.
    ///
    /// Damage is double-buffered state, see wl_surface.commit.
    ///
    /// The damage rectangle is specified in buffer coordinates,
    /// where x and y specify the upper left corner of the damage rectangle.
    ///
    /// The initial value for pending damage is empty: no damage.
    /// wl_surface.damage_buffer adds pending damage: the new pending
    /// damage is the union of old pending damage and the given rectangle.
    ///
    /// wl_surface.commit assigns pending damage as the current damage,
    /// and clears pending damage. The server will clear the current
    /// damage as it repaints the surface.
    ///
    /// This request differs from wl_surface.damage in only one way - it
    /// takes damage in buffer coordinates instead of surface-local
    /// coordinates. While this generally is more intuitive than surface
    /// coordinates, it is especially desirable when using wp_viewport
    /// or when a drawing library (like EGL) is unaware of buffer scale
    /// and buffer transform.
    ///
    /// Note: Because buffer transformation changes and damage requests may
    /// be interleaved in the protocol stream, it is impossible to determine
    /// the actual mapping between surface and buffer damage until
    /// wl_surface.commit time. Therefore, compositors wishing to take both
    /// kinds of damage into account will have to accumulate damage from the
    /// two requests separately and only transform from one to the other
    /// after receiving the wl_surface.commit.
    pub fn damage_buffer(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .damage_buffer = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    /// The x and y arguments specify the location of the new pending
    /// buffer's upper left corner, relative to the current buffer's upper
    /// left corner, in surface-local coordinates. In other words, the
    /// x and y, combined with the new surface size define in which
    /// directions the surface's size changes.
    ///
    /// Surface location offset is double-buffered state, see
    /// wl_surface.commit.
    ///
    /// This request is semantically equivalent to and the replaces the x and y
    /// arguments in the wl_surface.attach request in wl_surface versions prior
    /// to 5. See wl_surface.attach for details.
    pub fn offset(
        this: @This(),
        x: i32,
        y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .offset = .{
                .x = x,
                .y = y,
            } },
        );
    }

    pub const Event = union(enum) {
        /// This is emitted whenever a surface's creation, movement, or resizing
        /// results in some part of it being within the scanout region of an
        /// output.
        ///
        /// Note that a surface may be overlapping with zero or more outputs.
        enter: struct {
            output: u32,
        },

        /// This is emitted whenever a surface's creation, movement, or resizing
        /// results in it no longer having any part of it within the scanout region
        /// of an output.
        ///
        /// Clients should not use the number of outputs the surface is on for frame
        /// throttling purposes. The surface might be hidden even if no leave event
        /// has been sent, and the compositor might expect new surface content
        /// updates even if no enter event has been sent. The frame event should be
        /// used instead.
        leave: struct {
            output: u32,
        },
    };
};

/// A seat is a group of keyboards, pointer and touch devices. This
/// object is published as a global during start up, or when such a
/// device is hot plugged.  A seat typically has a pointer and
/// maintains a keyboard focus and a pointer focus.
pub const wl_seat = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_seat",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Capability = packed struct(u32) {
        /// the seat has pointer devices
        pointer: bool,
        /// the seat has one or more keyboards
        keyboard: bool,
        /// the seat has touch devices
        touch: bool,
        padding_1: u29 = 0,
    };

    pub const Error = enum(u32) {
        /// get_pointer, get_keyboard or get_touch called on seat without the matching capability
        missing_capability = 0,
    };

    pub const Request = union(enum) {
        get_pointer: struct {
            id: u32,
        },
        get_keyboard: struct {
            id: u32,
        },
        get_touch: struct {
            id: u32,
        },
        release: struct {},
    };

    /// The ID provided will be initialized to the wl_pointer interface
    /// for this seat.
    ///
    /// This request only takes effect if the seat has the pointer
    /// capability, or has had the pointer capability in the past.
    /// It is a protocol violation to issue this request on a seat that has
    /// never had the pointer capability. The missing_capability error will
    /// be sent in this case.
    pub fn get_pointer(
        this: @This(),
    ) !*wl_pointer {
        const new_object = try this.conn.createObject(wl_pointer);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_pointer = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// The ID provided will be initialized to the wl_keyboard interface
    /// for this seat.
    ///
    /// This request only takes effect if the seat has the keyboard
    /// capability, or has had the keyboard capability in the past.
    /// It is a protocol violation to issue this request on a seat that has
    /// never had the keyboard capability. The missing_capability error will
    /// be sent in this case.
    pub fn get_keyboard(
        this: @This(),
    ) !*wl_keyboard {
        const new_object = try this.conn.createObject(wl_keyboard);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_keyboard = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// The ID provided will be initialized to the wl_touch interface
    /// for this seat.
    ///
    /// This request only takes effect if the seat has the touch
    /// capability, or has had the touch capability in the past.
    /// It is a protocol violation to issue this request on a seat that has
    /// never had the touch capability. The missing_capability error will
    /// be sent in this case.
    pub fn get_touch(
        this: @This(),
    ) !*wl_touch {
        const new_object = try this.conn.createObject(wl_touch);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_touch = .{
                .id = new_object.id,
            } },
        );
        return new_object;
    }

    /// Using this request a client can tell the server that it is not going to
    /// use the seat object anymore.
    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// This is emitted whenever a seat gains or loses the pointer,
        /// keyboard or touch capabilities.  The argument is a capability
        /// enum containing the complete set of capabilities this seat has.
        ///
        /// When the pointer capability is added, a client may create a
        /// wl_pointer object using the wl_seat.get_pointer request. This object
        /// will receive pointer events until the capability is removed in the
        /// future.
        ///
        /// When the pointer capability is removed, a client should destroy the
        /// wl_pointer objects associated with the seat where the capability was
        /// removed, using the wl_pointer.release request. No further pointer
        /// events will be received on these objects.
        ///
        /// In some compositors, if a seat regains the pointer capability and a
        /// client has a previously obtained wl_pointer object of version 4 or
        /// less, that object may start sending pointer events again. This
        /// behavior is considered a misinterpretation of the intended behavior
        /// and must not be relied upon by the client. wl_pointer objects of
        /// version 5 or later must not send events if created before the most
        /// recent event notifying the client of an added pointer capability.
        ///
        /// The above behavior also applies to wl_keyboard and wl_touch with the
        /// keyboard and touch capabilities, respectively.
        capabilities: struct {
            capabilities: Capability,
        },

        /// In a multi-seat configuration the seat name can be used by clients to
        /// help identify which physical devices the seat represents.
        ///
        /// The seat name is a UTF-8 string with no convention defined for its
        /// contents. Each name is unique among all wl_seat globals. The name is
        /// only guaranteed to be unique for the current compositor instance.
        ///
        /// The same seat names are used for all clients. Thus, the name can be
        /// shared across processes to refer to a specific wl_seat global.
        ///
        /// The name event is sent after binding to the seat global. This event is
        /// only sent once per seat object, and the name does not change over the
        /// lifetime of the wl_seat global.
        ///
        /// Compositors may re-use the same seat name if the wl_seat global is
        /// destroyed and re-created later.
        name: struct {
            name: ?[:0]const u8,
        },
    };
};

/// The wl_pointer interface represents one or more input devices,
/// such as mice, which control the pointer location and pointer_focus
/// of a seat.
///
/// The wl_pointer interface generates motion, enter and leave
/// events for the surfaces that the pointer is located over,
/// and button and axis events for button presses, button releases
/// and scrolling.
pub const wl_pointer = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_pointer",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// given wl_surface has another role
        role = 0,
    };

    pub const Button_state = enum(u32) {
        /// the button is not pressed
        released = 0,
        /// the button is pressed
        pressed = 1,
    };

    pub const Axis = enum(u32) {
        /// vertical axis
        vertical_scroll = 0,
        /// horizontal axis
        horizontal_scroll = 1,
    };

    pub const Axis_source = enum(u32) {
        /// a physical wheel rotation
        wheel = 0,
        /// finger on a touch surface
        finger = 1,
        /// continuous coordinate space
        continuous = 2,
        /// a physical wheel tilt
        wheel_tilt = 3,
    };

    pub const Axis_relative_direction = enum(u32) {
        /// physical motion matches axis direction
        identical = 0,
        /// physical motion is the inverse of the axis direction
        inverted = 1,
    };

    pub const Request = union(enum) {
        set_cursor: struct {
            serial: u32,
            surface: u32,
            hotspot_x: i32,
            hotspot_y: i32,
        },
        release: struct {},
    };

    /// Set the pointer surface, i.e., the surface that contains the
    /// pointer image (cursor). This request gives the surface the role
    /// of a cursor. If the surface already has another role, it raises
    /// a protocol error.
    ///
    /// The cursor actually changes only if the pointer
    /// focus for this device is one of the requesting client's surfaces
    /// or the surface parameter is the current pointer surface. If
    /// there was a previous surface set with this request it is
    /// replaced. If surface is NULL, the pointer image is hidden.
    ///
    /// The parameters hotspot_x and hotspot_y define the position of
    /// the pointer surface relative to the pointer location. Its
    /// top-left corner is always at (x, y) - (hotspot_x, hotspot_y),
    /// where (x, y) are the coordinates of the pointer location, in
    /// surface-local coordinates.
    ///
    /// On wl_surface.offset requests to the pointer surface, hotspot_x
    /// and hotspot_y are decremented by the x and y parameters
    /// passed to the request. The offset must be applied by
    /// wl_surface.commit as usual.
    ///
    /// The hotspot can also be updated by passing the currently set
    /// pointer surface to this request with new values for hotspot_x
    /// and hotspot_y.
    ///
    /// The input region is ignored for wl_surfaces with the role of
    /// a cursor. When the use as a cursor ends, the wl_surface is
    /// unmapped.
    ///
    /// The serial parameter must match the latest wl_pointer.enter
    /// serial number sent to the client. Otherwise the request will be
    /// ignored.
    pub fn set_cursor(
        this: @This(),
        serial: u32,
        surface: *wayland.wayland.wl_surface,
        hotspot_x: i32,
        hotspot_y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_cursor = .{
                .serial = serial,
                .surface = surface.id,
                .hotspot_x = hotspot_x,
                .hotspot_y = hotspot_y,
            } },
        );
    }

    /// Using this request a client can tell the server that it is not going to
    /// use the pointer object anymore.
    ///
    /// This request destroys the pointer proxy object, so clients must not call
    /// wl_pointer_destroy() after using this request.
    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// Notification that this seat's pointer is focused on a certain
        /// surface.
        ///
        /// When a seat's focus enters a surface, the pointer image
        /// is undefined and a client should respond to this event by setting
        /// an appropriate pointer image with the set_cursor request.
        enter: struct {
            serial: u32,
            surface: u32,
            surface_x: wayland.fixed,
            surface_y: wayland.fixed,
        },

        /// Notification that this seat's pointer is no longer focused on
        /// a certain surface.
        ///
        /// The leave notification is sent before the enter notification
        /// for the new focus.
        leave: struct {
            serial: u32,
            surface: u32,
        },

        /// Notification of pointer location change. The arguments
        /// surface_x and surface_y are the location relative to the
        /// focused surface.
        motion: struct {
            time: u32,
            surface_x: wayland.fixed,
            surface_y: wayland.fixed,
        },

        /// Mouse button click and release notifications.
        ///
        /// The location of the click is given by the last motion or
        /// enter event.
        /// The time argument is a timestamp with millisecond
        /// granularity, with an undefined base.
        ///
        /// The button is a button code as defined in the Linux kernel's
        /// linux/input-event-codes.h header file, e.g. BTN_LEFT.
        ///
        /// Any 16-bit button code value is reserved for future additions to the
        /// kernel's event code list. All other button codes above 0xFFFF are
        /// currently undefined but may be used in future versions of this
        /// protocol.
        button: struct {
            serial: u32,
            time: u32,
            button: u32,
            state: Button_state,
        },

        /// Scroll and other axis notifications.
        ///
        /// For scroll events (vertical and horizontal scroll axes), the
        /// value parameter is the length of a vector along the specified
        /// axis in a coordinate space identical to those of motion events,
        /// representing a relative movement along the specified axis.
        ///
        /// For devices that support movements non-parallel to axes multiple
        /// axis events will be emitted.
        ///
        /// When applicable, for example for touch pads, the server can
        /// choose to emit scroll events where the motion vector is
        /// equivalent to a motion event vector.
        ///
        /// When applicable, a client can transform its content relative to the
        /// scroll distance.
        axis: struct {
            time: u32,
            axis: Axis,
            value: wayland.fixed,
        },

        /// Indicates the end of a set of events that logically belong together.
        /// A client is expected to accumulate the data in all events within the
        /// frame before proceeding.
        ///
        /// All wl_pointer events before a wl_pointer.frame event belong
        /// logically together. For example, in a diagonal scroll motion the
        /// compositor will send an optional wl_pointer.axis_source event, two
        /// wl_pointer.axis events (horizontal and vertical) and finally a
        /// wl_pointer.frame event. The client may use this information to
        /// calculate a diagonal vector for scrolling.
        ///
        /// When multiple wl_pointer.axis events occur within the same frame,
        /// the motion vector is the combined motion of all events.
        /// When a wl_pointer.axis and a wl_pointer.axis_stop event occur within
        /// the same frame, this indicates that axis movement in one axis has
        /// stopped but continues in the other axis.
        /// When multiple wl_pointer.axis_stop events occur within the same
        /// frame, this indicates that these axes stopped in the same instance.
        ///
        /// A wl_pointer.frame event is sent for every logical event group,
        /// even if the group only contains a single wl_pointer event.
        /// Specifically, a client may get a sequence: motion, frame, button,
        /// frame, axis, frame, axis_stop, frame.
        ///
        /// The wl_pointer.enter and wl_pointer.leave events are logical events
        /// generated by the compositor and not the hardware. These events are
        /// also grouped by a wl_pointer.frame. When a pointer moves from one
        /// surface to another, a compositor should group the
        /// wl_pointer.leave event within the same wl_pointer.frame.
        /// However, a client must not rely on wl_pointer.leave and
        /// wl_pointer.enter being in the same wl_pointer.frame.
        /// Compositor-specific policies may require the wl_pointer.leave and
        /// wl_pointer.enter event being split across multiple wl_pointer.frame
        /// groups.
        frame,
        /// Source information for scroll and other axes.
        ///
        /// This event does not occur on its own. It is sent before a
        /// wl_pointer.frame event and carries the source information for
        /// all events within that frame.
        ///
        /// The source specifies how this event was generated. If the source is
        /// wl_pointer.axis_source.finger, a wl_pointer.axis_stop event will be
        /// sent when the user lifts the finger off the device.
        ///
        /// If the source is wl_pointer.axis_source.wheel,
        /// wl_pointer.axis_source.wheel_tilt or
        /// wl_pointer.axis_source.continuous, a wl_pointer.axis_stop event may
        /// or may not be sent. Whether a compositor sends an axis_stop event
        /// for these sources is hardware-specific and implementation-dependent;
        /// clients must not rely on receiving an axis_stop event for these
        /// scroll sources and should treat scroll sequences from these scroll
        /// sources as unterminated by default.
        ///
        /// This event is optional. If the source is unknown for a particular
        /// axis event sequence, no event is sent.
        /// Only one wl_pointer.axis_source event is permitted per frame.
        ///
        /// The order of wl_pointer.axis_discrete and wl_pointer.axis_source is
        /// not guaranteed.
        axis_source: struct {
            axis_source: Axis_source,
        },

        /// Stop notification for scroll and other axes.
        ///
        /// For some wl_pointer.axis_source types, a wl_pointer.axis_stop event
        /// is sent to notify a client that the axis sequence has terminated.
        /// This enables the client to implement kinetic scrolling.
        /// See the wl_pointer.axis_source documentation for information on when
        /// this event may be generated.
        ///
        /// Any wl_pointer.axis events with the same axis_source after this
        /// event should be considered as the start of a new axis motion.
        ///
        /// The timestamp is to be interpreted identical to the timestamp in the
        /// wl_pointer.axis event. The timestamp value may be the same as a
        /// preceding wl_pointer.axis event.
        axis_stop: struct {
            time: u32,
            axis: Axis,
        },

        /// Discrete step information for scroll and other axes.
        ///
        /// This event carries the axis value of the wl_pointer.axis event in
        /// discrete steps (e.g. mouse wheel clicks).
        ///
        /// This event is deprecated with wl_pointer version 8 - this event is not
        /// sent to clients supporting version 8 or later.
        ///
        /// This event does not occur on its own, it is coupled with a
        /// wl_pointer.axis event that represents this axis value on a
        /// continuous scale. The protocol guarantees that each axis_discrete
        /// event is always followed by exactly one axis event with the same
        /// axis number within the same wl_pointer.frame. Note that the protocol
        /// allows for other events to occur between the axis_discrete and
        /// its coupled axis event, including other axis_discrete or axis
        /// events. A wl_pointer.frame must not contain more than one axis_discrete
        /// event per axis type.
        ///
        /// This event is optional; continuous scrolling devices
        /// like two-finger scrolling on touchpads do not have discrete
        /// steps and do not generate this event.
        ///
        /// The discrete value carries the directional information. e.g. a value
        /// of -2 is two steps towards the negative direction of this axis.
        ///
        /// The axis number is identical to the axis number in the associated
        /// axis event.
        ///
        /// The order of wl_pointer.axis_discrete and wl_pointer.axis_source is
        /// not guaranteed.
        axis_discrete: struct {
            axis: Axis,
            discrete: i32,
        },
    };
};

/// The wl_keyboard interface represents one or more keyboards
/// associated with a seat.
pub const wl_keyboard = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_keyboard",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Keymap_format = enum(u32) {
        /// no keymap; client must understand how to interpret the raw keycode
        no_keymap = 0,
        /// libxkbcommon compatible, null-terminated string; to determine the xkb keycode, clients must add 8 to the key event keycode
        xkb_v1 = 1,
    };

    pub const Key_state = enum(u32) {
        /// key is not pressed
        released = 0,
        /// key is pressed
        pressed = 1,
    };

    pub const Request = union(enum) {
        release: struct {},
    };

    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// This event provides a file descriptor to the client which can be
        /// memory-mapped in read-only mode to provide a keyboard mapping
        /// description.
        ///
        /// From version 7 onwards, the fd must be mapped with MAP_PRIVATE by
        /// the recipient, as MAP_SHARED may fail.
        keymap: struct {
            format: Keymap_format,
            fd: wayland.fd_t,
            size: u32,
        },

        /// Notification that this seat's keyboard focus is on a certain
        /// surface.
        ///
        /// The compositor must send the wl_keyboard.modifiers event after this
        /// event.
        enter: struct {
            serial: u32,
            surface: u32,
            keys: []const u8,
        },

        /// Notification that this seat's keyboard focus is no longer on
        /// a certain surface.
        ///
        /// The leave notification is sent before the enter notification
        /// for the new focus.
        ///
        /// After this event client must assume that no keys are pressed,
        /// it must stop key repeating if there's some going on and until
        /// it receives the next wl_keyboard.modifiers event, the client
        /// must also assume no modifiers are active.
        leave: struct {
            serial: u32,
            surface: u32,
        },

        /// A key was pressed or released.
        /// The time argument is a timestamp with millisecond
        /// granularity, with an undefined base.
        ///
        /// The key is a platform-specific key code that can be interpreted
        /// by feeding it to the keyboard mapping (see the keymap event).
        ///
        /// If this event produces a change in modifiers, then the resulting
        /// wl_keyboard.modifiers event must be sent after this event.
        ///
        /// The compositor must not send this event without a surface of the client
        /// having keyboard focus.
        key: struct {
            serial: u32,
            time: u32,
            key: u32,
            state: Key_state,
        },

        /// Notifies clients that the modifier and/or group state has
        /// changed, and it should update its local state.
        ///
        /// The compositor may send this event without a surface of the client
        /// having keyboard focus, for example to tie modifier information to
        /// pointer focus instead. If a modifier event with pressed modifiers is sent
        /// without a prior enter event, the client can assume the modifier state is
        /// valid until it receives the next wl_keyboard.modifiers event. In order to
        /// reset the modifier state again, the compositor can send a
        /// wl_keyboard.modifiers event with no pressed modifiers.
        modifiers: struct {
            serial: u32,
            mods_depressed: u32,
            mods_latched: u32,
            mods_locked: u32,
            group: u32,
        },

        /// Informs the client about the keyboard's repeat rate and delay.
        ///
        /// This event is sent as soon as the wl_keyboard object has been created,
        /// and is guaranteed to be received by the client before any key press
        /// event.
        ///
        /// Negative values for either rate or delay are illegal. A rate of zero
        /// will disable any repeating (regardless of the value of delay).
        ///
        /// This event can be sent later on as well with a new value if necessary,
        /// so clients should continue listening for the event past the creation
        /// of wl_keyboard.
        repeat_info: struct {
            rate: i32,
            delay: i32,
        },
    };
};

/// The wl_touch interface represents a touchscreen
/// associated with a seat.
///
/// Touch interactions can consist of one or more contacts.
/// For each contact, a series of events is generated, starting
/// with a down event, followed by zero or more motion events,
/// and ending with an up event. Events relating to the same
/// contact point can be identified by the ID of the sequence.
pub const wl_touch = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_touch",
        .version = 5,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        release: struct {},
    };

    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// A new touch point has appeared on the surface. This touch point is
        /// assigned a unique ID. Future events from this touch point reference
        /// this ID. The ID ceases to be valid after a touch up event and may be
        /// reused in the future.
        down: struct {
            serial: u32,
            time: u32,
            surface: u32,
            id: i32,
            x: wayland.fixed,
            y: wayland.fixed,
        },

        /// The touch point has disappeared. No further events will be sent for
        /// this touch point and the touch point's ID is released and may be
        /// reused in a future touch down event.
        up: struct {
            serial: u32,
            time: u32,
            id: i32,
        },

        /// A touch point has changed coordinates.
        motion: struct {
            time: u32,
            id: i32,
            x: wayland.fixed,
            y: wayland.fixed,
        },

        /// Indicates the end of a set of events that logically belong together.
        /// A client is expected to accumulate the data in all events within the
        /// frame before proceeding.
        ///
        /// A wl_touch.frame terminates at least one event but otherwise no
        /// guarantee is provided about the set of events within a frame. A client
        /// must assume that any state not updated in a frame is unchanged from the
        /// previously known state.
        frame,
        /// Sent if the compositor decides the touch stream is a global
        /// gesture. No further events are sent to the clients from that
        /// particular gesture. Touch cancellation applies to all touch points
        /// currently active on this client's surface. The client is
        /// responsible for finalizing the touch points, future touch points on
        /// this surface may reuse the touch point ID.
        cancel,
    };
};

/// An output describes part of the compositor geometry.  The
/// compositor works in the 'compositor coordinate system' and an
/// output corresponds to a rectangular area in that space that is
/// actually visible.  This typically corresponds to a monitor that
/// displays part of the compositor space.  This object is published
/// as global during start up, or when a monitor is hotplugged.
pub const wl_output = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_output",
        .version = 4,
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
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Subpixel = enum(u32) {
        /// unknown geometry
        unknown = 0,
        /// no geometry
        none = 1,
        /// horizontal RGB
        horizontal_rgb = 2,
        /// horizontal BGR
        horizontal_bgr = 3,
        /// vertical RGB
        vertical_rgb = 4,
        /// vertical BGR
        vertical_bgr = 5,
    };

    pub const Transform = enum(u32) {
        /// no transform
        normal = 0,
        /// 90 degrees counter-clockwise
        @"90" = 1,
        /// 180 degrees counter-clockwise
        @"180" = 2,
        /// 270 degrees counter-clockwise
        @"270" = 3,
        /// 180 degree flip around a vertical axis
        flipped = 4,
        /// flip and rotate 90 degrees counter-clockwise
        flipped_90 = 5,
        /// flip and rotate 180 degrees counter-clockwise
        flipped_180 = 6,
        /// flip and rotate 270 degrees counter-clockwise
        flipped_270 = 7,
    };

    pub const Mode = packed struct(u32) {
        /// indicates this is the current mode
        current: bool,
        /// indicates this is the preferred mode
        preferred: bool,
        padding_1: u30 = 0,
    };

    pub const Request = union(enum) {
        release: struct {},
    };

    /// Using this request a client can tell the server that it is not going to
    /// use the output object anymore.
    pub fn release(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .release = .{} },
        );
    }

    pub const Event = union(enum) {
        /// The geometry event describes geometric properties of the output.
        /// The event is sent when binding to the output object and whenever
        /// any of the properties change.
        ///
        /// The physical size can be set to zero if it doesn't make sense for this
        /// output (e.g. for projectors or virtual outputs).
        ///
        /// The geometry event will be followed by a done event (starting from
        /// version 2).
        ///
        /// Note: wl_output only advertises partial information about the output
        /// position and identification. Some compositors, for instance those not
        /// implementing a desktop-style output layout or those exposing virtual
        /// outputs, might fake this information. Instead of using x and y, clients
        /// should use xdg_output.logical_position. Instead of using make and model,
        /// clients should use name and description.
        geometry: struct {
            x: i32,
            y: i32,
            physical_width: i32,
            physical_height: i32,
            subpixel: i32,
            make: ?[:0]const u8,
            model: ?[:0]const u8,
            transform: i32,
        },

        /// The mode event describes an available mode for the output.
        ///
        /// The event is sent when binding to the output object and there
        /// will always be one mode, the current mode.  The event is sent
        /// again if an output changes mode, for the mode that is now
        /// current.  In other words, the current mode is always the last
        /// mode that was received with the current flag set.
        ///
        /// Non-current modes are deprecated. A compositor can decide to only
        /// advertise the current mode and never send other modes. Clients
        /// should not rely on non-current modes.
        ///
        /// The size of a mode is given in physical hardware units of
        /// the output device. This is not necessarily the same as
        /// the output size in the global compositor space. For instance,
        /// the output may be scaled, as described in wl_output.scale,
        /// or transformed, as described in wl_output.transform. Clients
        /// willing to retrieve the output size in the global compositor
        /// space should use xdg_output.logical_size instead.
        ///
        /// The vertical refresh rate can be set to zero if it doesn't make
        /// sense for this output (e.g. for virtual outputs).
        ///
        /// The mode event will be followed by a done event (starting from
        /// version 2).
        ///
        /// Clients should not use the refresh rate to schedule frames. Instead,
        /// they should use the wl_surface.frame event or the presentation-time
        /// protocol.
        ///
        /// Note: this information is not always meaningful for all outputs. Some
        /// compositors, such as those exposing virtual outputs, might fake the
        /// refresh rate or the size.
        mode: struct {
            flags: Mode,
            width: i32,
            height: i32,
            refresh: i32,
        },

        /// This event is sent after all other properties have been
        /// sent after binding to the output object and after any
        /// other property changes done after that. This allows
        /// changes to the output properties to be seen as
        /// atomic, even if they happen via multiple events.
        done,
        /// This event contains scaling geometry information
        /// that is not in the geometry event. It may be sent after
        /// binding the output object or if the output scale changes
        /// later. The compositor will emit a non-zero, positive
        /// value for scale. If it is not sent, the client should
        /// assume a scale of 1.
        ///
        /// A scale larger than 1 means that the compositor will
        /// automatically scale surface buffers by this amount
        /// when rendering. This is used for very high resolution
        /// displays where applications rendering at the native
        /// resolution would be too small to be legible.
        ///
        /// It is intended that scaling aware clients track the
        /// current output of a surface, and if it is on a scaled
        /// output it should use wl_surface.set_buffer_scale with
        /// the scale of the output. That way the compositor can
        /// avoid scaling the surface, and the client can supply
        /// a higher detail image.
        ///
        /// The scale event will be followed by a done event.
        scale: struct {
            factor: i32,
        },

        /// Many compositors will assign user-friendly names to their outputs, show
        /// them to the user, allow the user to refer to an output, etc. The client
        /// may wish to know this name as well to offer the user similar behaviors.
        ///
        /// The name is a UTF-8 string with no convention defined for its contents.
        /// Each name is unique among all wl_output globals. The name is only
        /// guaranteed to be unique for the compositor instance.
        ///
        /// The same output name is used for all clients for a given wl_output
        /// global. Thus, the name can be shared across processes to refer to a
        /// specific wl_output global.
        ///
        /// The name is not guaranteed to be persistent across sessions, thus cannot
        /// be used to reliably identify an output in e.g. configuration files.
        ///
        /// Examples of names include 'HDMI-A-1', 'WL-1', 'X11-1', etc. However, do
        /// not assume that the name is a reflection of an underlying DRM connector,
        /// X11 connection, etc.
        ///
        /// The name event is sent after binding the output object. This event is
        /// only sent once per output object, and the name does not change over the
        /// lifetime of the wl_output global.
        ///
        /// Compositors may re-use the same output name if the wl_output global is
        /// destroyed and re-created later. Compositors should avoid re-using the
        /// same name if possible.
        ///
        /// The name event will be followed by a done event.
        name: struct {
            name: ?[:0]const u8,
        },

        /// Many compositors can produce human-readable descriptions of their
        /// outputs. The client may wish to know this description as well, e.g. for
        /// output selection purposes.
        ///
        /// The description is a UTF-8 string with no convention defined for its
        /// contents. The description is not guaranteed to be unique among all
        /// wl_output globals. Examples might include 'Foocorp 11" Display' or
        /// 'Virtual X11 output via :1'.
        ///
        /// The description event is sent after binding the output object and
        /// whenever the description changes. The description is optional, and may
        /// not be sent at all.
        ///
        /// The description event will be followed by a done event.
        description: struct {
            description: ?[:0]const u8,
        },
    };
};

/// A region object describes an area.
///
/// Region objects are used to describe the opaque and input
/// regions of a surface.
pub const wl_region = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_region",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Request = union(enum) {
        destroy: struct {},
        add: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
        subtract: struct {
            x: i32,
            y: i32,
            width: i32,
            height: i32,
        },
    };

    /// Destroy the region.  This will invalidate the object ID.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Add the specified rectangle to the region.
    pub fn add(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .add = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    /// Subtract the specified rectangle from the region.
    pub fn subtract(
        this: @This(),
        x: i32,
        y: i32,
        width: i32,
        height: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .subtract = .{
                .x = x,
                .y = y,
                .width = width,
                .height = height,
            } },
        );
    }

    pub const Event = union(enum) {};
};

/// The global interface exposing sub-surface compositing capabilities.
/// A wl_surface, that has sub-surfaces associated, is called the
/// parent surface. Sub-surfaces can be arbitrarily nested and create
/// a tree of sub-surfaces.
///
/// The root surface in a tree of sub-surfaces is the main
/// surface. The main surface cannot be a sub-surface, because
/// sub-surfaces must always have a parent.
///
/// A main surface with its sub-surfaces forms a (compound) window.
/// For window management purposes, this set of wl_surface objects is
/// to be considered as a single window, and it should also behave as
/// such.
///
/// The aim of sub-surfaces is to offload some of the compositing work
/// within a window from clients to the compositor. A prime example is
/// a video player with decorations and video in separate wl_surface
/// objects. This should allow the compositor to pass YUV video buffer
/// processing to dedicated overlay hardware when possible.
pub const wl_subcompositor = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_subcompositor",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// the to-be sub-surface is invalid
        bad_surface = 0,
        /// the to-be sub-surface parent is invalid
        bad_parent = 1,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        get_subsurface: struct {
            id: u32,
            surface: u32,
            parent: u32,
        },
    };

    /// Informs the server that the client will not be using this
    /// protocol object anymore. This does not affect any other
    /// objects, wl_subsurface objects included.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// Create a sub-surface interface for the given surface, and
    /// associate it with the given parent surface. This turns a
    /// plain wl_surface into a sub-surface.
    ///
    /// The to-be sub-surface must not already have another role, and it
    /// must not have an existing wl_subsurface object. Otherwise the
    /// bad_surface protocol error is raised.
    ///
    /// Adding sub-surfaces to a parent is a double-buffered operation on the
    /// parent (see wl_surface.commit). The effect of adding a sub-surface
    /// becomes visible on the next time the state of the parent surface is
    /// applied.
    ///
    /// The parent surface must not be one of the child surface's descendants,
    /// and the parent must be different from the child surface, otherwise the
    /// bad_parent protocol error is raised.
    ///
    /// This request modifies the behaviour of wl_surface.commit request on
    /// the sub-surface, see the documentation on wl_subsurface interface.
    pub fn get_subsurface(
        this: @This(),
        surface: *wayland.wayland.wl_surface,
        parent: *wayland.wayland.wl_surface,
    ) !*wl_subsurface {
        const new_object = try this.conn.createObject(wl_subsurface);
        try this.conn.send(
            Request,
            this.id,
            .{ .get_subsurface = .{
                .id = new_object.id,
                .surface = surface.id,
                .parent = parent.id,
            } },
        );
        return new_object;
    }

    pub const Event = union(enum) {};
};

/// An additional interface to a wl_surface object, which has been
/// made a sub-surface. A sub-surface has one parent surface. A
/// sub-surface's size and position are not limited to that of the parent.
/// Particularly, a sub-surface is not automatically clipped to its
/// parent's area.
///
/// A sub-surface becomes mapped, when a non-NULL wl_buffer is applied
/// and the parent surface is mapped. The order of which one happens
/// first is irrelevant. A sub-surface is hidden if the parent becomes
/// hidden, or if a NULL wl_buffer is applied. These rules apply
/// recursively through the tree of surfaces.
///
/// The behaviour of a wl_surface.commit request on a sub-surface
/// depends on the sub-surface's mode. The possible modes are
/// synchronized and desynchronized, see methods
/// wl_subsurface.set_sync and wl_subsurface.set_desync. Synchronized
/// mode caches the wl_surface state to be applied when the parent's
/// state gets applied, and desynchronized mode applies the pending
/// wl_surface state directly. A sub-surface is initially in the
/// synchronized mode.
///
/// Sub-surfaces also have another kind of state, which is managed by
/// wl_subsurface requests, as opposed to wl_surface requests. This
/// state includes the sub-surface position relative to the parent
/// surface (wl_subsurface.set_position), and the stacking order of
/// the parent and its sub-surfaces (wl_subsurface.place_above and
/// .place_below). This state is applied when the parent surface's
/// wl_surface state is applied, regardless of the sub-surface's mode.
/// As the exception, set_sync and set_desync are effective immediately.
///
/// The main surface can be thought to be always in desynchronized mode,
/// since it does not have a parent in the sub-surfaces sense.
///
/// Even if a sub-surface is in desynchronized mode, it will behave as
/// in synchronized mode, if its parent surface behaves as in
/// synchronized mode. This rule is applied recursively throughout the
/// tree of surfaces. This means, that one can set a sub-surface into
/// synchronized mode, and then assume that all its child and grand-child
/// sub-surfaces are synchronized, too, without explicitly setting them.
///
/// Destroying a sub-surface takes effect immediately. If you need to
/// synchronize the removal of a sub-surface to the parent surface update,
/// unmap the sub-surface first by attaching a NULL wl_buffer, update parent,
/// and then destroy the sub-surface.
///
/// If the parent wl_surface object is destroyed, the sub-surface is
/// unmapped.
///
/// A sub-surface never has the keyboard focus of any seat.
///
/// The wl_surface.offset request is ignored: clients must use set_position
/// instead to move the sub-surface.
pub const wl_subsurface = struct {
    conn: *wayland.Conn,
    id: u32,
    userdata: ?*anyopaque = null,
    on_event: ?*const fn (this: *@This(), userdata: ?*anyopaque, event: Event) void = null,

    pub const INTERFACE = wayland.Object.Interface.fromStruct(@This(), .{
        .name = "wl_subsurface",
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
        this.conn.id_pool.destroy(this.id);
        this.conn.allocator.destroy(this);
    }

    /// This should only be called when the wayland display receives an event for this Object
    pub fn event_received(this: *@This(), header: wayland.Header, body: []const u32) void {
        if (this.on_event) |on_event| {
            const event = wayland.deserialize(Event, header, body) catch |e| {
                if (std.meta.intToEnum(@typeInfo(Event).Union.tag_type.?, header.size_and_opcode.opcode)) |kind| {
                    std.log.warn("{s}:{} failed to deserialize event \"{}\": {}", .{ @src().file, @src().line, std.zig.fmtEscapes(@tagName(kind)), e });
                } else |_| {
                    std.log.warn("{s}:{} failed to deserialize event {}: {}", .{ @src().file, @src().line, header.size_and_opcode.opcode, e });
                }
                return;
            };
            on_event(this, this.userdata, event);
        }
    }
    pub const Error = enum(u32) {
        /// wl_surface is not a sibling or the parent
        bad_surface = 0,
    };

    pub const Request = union(enum) {
        destroy: struct {},
        set_position: struct {
            x: i32,
            y: i32,
        },
        place_above: struct {
            sibling: u32,
        },
        place_below: struct {
            sibling: u32,
        },
        set_sync: struct {},
        set_desync: struct {},
    };

    /// The sub-surface interface is removed from the wl_surface object
    /// that was turned into a sub-surface with a
    /// wl_subcompositor.get_subsurface request. The wl_surface's association
    /// to the parent is deleted. The wl_surface is unmapped immediately.
    pub fn destroy(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .destroy = .{} },
        );
    }

    /// This schedules a sub-surface position change.
    /// The sub-surface will be moved so that its origin (top left
    /// corner pixel) will be at the location x, y of the parent surface
    /// coordinate system. The coordinates are not restricted to the parent
    /// surface area. Negative values are allowed.
    ///
    /// The scheduled coordinates will take effect whenever the state of the
    /// parent surface is applied.
    ///
    /// If more than one set_position request is invoked by the client before
    /// the commit of the parent surface, the position of a new request always
    /// replaces the scheduled position from any previous request.
    ///
    /// The initial position is 0, 0.
    pub fn set_position(
        this: @This(),
        x: i32,
        y: i32,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_position = .{
                .x = x,
                .y = y,
            } },
        );
    }

    /// This sub-surface is taken from the stack, and put back just
    /// above the reference surface, changing the z-order of the sub-surfaces.
    /// The reference surface must be one of the sibling surfaces, or the
    /// parent surface. Using any other surface, including this sub-surface,
    /// will cause a protocol error.
    ///
    /// The z-order is double-buffered. Requests are handled in order and
    /// applied immediately to a pending state. The final pending state is
    /// copied to the active state the next time the state of the parent
    /// surface is applied.
    ///
    /// A new sub-surface is initially added as the top-most in the stack
    /// of its siblings and parent.
    pub fn place_above(
        this: @This(),
        sibling: *wayland.wayland.wl_surface,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .place_above = .{
                .sibling = sibling.id,
            } },
        );
    }

    /// The sub-surface is placed just below the reference surface.
    /// See wl_subsurface.place_above.
    pub fn place_below(
        this: @This(),
        sibling: *wayland.wayland.wl_surface,
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .place_below = .{
                .sibling = sibling.id,
            } },
        );
    }

    /// Change the commit behaviour of the sub-surface to synchronized
    /// mode, also described as the parent dependent mode.
    ///
    /// In synchronized mode, wl_surface.commit on a sub-surface will
    /// accumulate the committed state in a cache, but the state will
    /// not be applied and hence will not change the compositor output.
    /// The cached state is applied to the sub-surface immediately after
    /// the parent surface's state is applied. This ensures atomic
    /// updates of the parent and all its synchronized sub-surfaces.
    /// Applying the cached state will invalidate the cache, so further
    /// parent surface commits do not (re-)apply old state.
    ///
    /// See wl_subsurface for the recursive effect of this mode.
    pub fn set_sync(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_sync = .{} },
        );
    }

    /// Change the commit behaviour of the sub-surface to desynchronized
    /// mode, also described as independent or freely running mode.
    ///
    /// In desynchronized mode, wl_surface.commit on a sub-surface will
    /// apply the pending state directly, without caching, as happens
    /// normally with a wl_surface. Calling wl_surface.commit on the
    /// parent surface has no effect on the sub-surface's wl_surface
    /// state. This mode allows a sub-surface to be updated on its own.
    ///
    /// If cached state exists when wl_surface.commit is called in
    /// desynchronized mode, the pending state is added to the cached
    /// state, and applied as a whole. This invalidates the cache.
    ///
    /// Note: even if a sub-surface is set to desynchronized, a parent
    /// sub-surface may override it to behave as synchronized. For details,
    /// see wl_subsurface.
    ///
    /// If a surface's parent surface behaves as desynchronized, then
    /// the cached state is applied on set_desync.
    pub fn set_desync(
        this: @This(),
    ) !void {
        try this.conn.send(
            Request,
            this.id,
            .{ .set_desync = .{} },
        );
    }

    pub const Event = union(enum) {};
};

const wayland = @import("./main.zig");
const std = @import("std");
